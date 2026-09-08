import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never touches the disk directly — everything goes through `PDFStore`, which is what
/// lets the tests drive every branch below against an in-memory scope with no real files
/// and no TCC grant.
///
/// Every path argument, without exception, is turned into a `ScopedPath` (input) or a
/// `WriteScopedPath` (output) by `PathScope.resolve`/`resolveForWrite` before it is used.
/// There is no other way to obtain either, so a tool added later cannot forget the check —
/// and cannot hand a read-scoped path to a store method expecting a write destination: it
/// will not compile either way.
public struct PDFTools: Sendable {
    private let store: any PDFStore
    private let scope: PathScope
    private let format: Format

    public init(store: any PDFStore, configuration: Configuration = Configuration()) {
        self.store = store
        self.format = Format()
        self.scope = PathScope(configuration: configuration, store: store)
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) throws -> String {
        let arguments = Arguments(parameters.arguments)

        switch parameters.name {
        case ToolCatalog.statusName:
            return status()

        case ToolCatalog.readName:
            return try read(arguments)

        case ToolCatalog.searchName:
            return try search(arguments)

        case ToolCatalog.listAnnotationsName:
            return try listAnnotations(arguments)

        case ToolCatalog.listFormFieldsName:
            return try listFormFields(arguments)

        case ToolCatalog.mergePagesName:
            return try mergePages(arguments)

        case ToolCatalog.rotatePagesName:
            return try rotatePages(arguments)

        case ToolCatalog.addAnnotationName:
            return try addAnnotation(arguments)

        case ToolCatalog.removeAnnotationName:
            return try removeAnnotation(arguments)

        case ToolCatalog.highlightTextName:
            return try highlightText(arguments)

        case ToolCatalog.fillFormName:
            return try fillForm(arguments)

        case ToolCatalog.setPasswordName:
            return try setPassword(arguments)

        case ToolCatalog.removePasswordName:
            return try removePassword(arguments)

        case ToolCatalog.setMetadataName:
            return try setMetadata(arguments)

        case ToolCatalog.renderPageName:
            return try renderPage(arguments)

        case ToolCatalog.redactPagesName:
            return try redactPages(arguments)

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    private func status() -> String {
        format.status(
            readProbes: scope.probeRoots(), writeProbes: scope.probeWriteRoots(),
            binaryPath: Self.binaryPath)
    }

    private func read(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let outlineQuery = arguments.optionalString("outline_query")
        let explicitRange = try arguments.pageRange()
        // 'outline_query' answers "what page is this on?" without reading the document,
        // but leaving the range unset falls through to "the whole document" — so a caller
        // who names a query and forgets to bound pages gets every page's text back anyway.
        // Defaulting to page 1 only applies when the caller gave no range of their own.
        let range = explicitRange ?? (outlineQuery != nil ? PageRange(first: 1, last: 1) : nil)
        let password = arguments.optionalString("password")
        var content = try store.readPDF(path, pages: range, password: password)

        if content.isEncrypted { throw ToolError.pdfEncrypted(path: path.path) }
        // A scan is pages with no text at all. Saying so is the whole difference between
        // "this file is empty" and "this file needs vision_ocr".
        guard content.hasTextLayer || content.pageCount == 0 else {
            throw ToolError.noTextLayer(path: path.path, pageCount: content.pageCount)
        }
        if !arguments.bool("include_outline", default: true) {
            content = PDFContent(
                pageCount: content.pageCount, pages: content.pages, outline: [],
                metadata: content.metadata, isEncrypted: content.isEncrypted)
        }
        return format.pdf(content, path: path.path, range: range, outlineQuery: outlineQuery)
    }

    private func search(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let query = try arguments.requiredString("query")
        let caseSensitive = arguments.bool("case_sensitive", default: false)
        let accentSensitive = arguments.bool("accent_sensitive", default: false)
        let password = arguments.optionalString("password")
        let matches = try store.searchPDF(
            path, query: query, caseSensitive: caseSensitive, accentSensitive: accentSensitive,
            password: password)
        return format.search(matches, path: path.path, query: query)
    }

    private func listAnnotations(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let password = arguments.optionalString("password")
        let entries = try store.listAnnotations(path, password: password)
        return format.annotations(entries, path: path.path)
    }

    private func listFormFields(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let password = arguments.optionalString("password")
        let fields = try store.listFormFields(path, password: password)
        return format.formFields(fields, path: path.path)
    }

    private func mergePages(_ arguments: Arguments) throws -> String {
        let sources = try mergeSources(from: arguments)
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        let pageCount = try store.mergePages(sources, to: output)
        return "Wrote \(pageCount) page\(pageCount == 1 ? "" : "s") to \(output.path)."
    }

    private func rotatePages(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let rotations = try parseRotations(from: arguments)
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        let pageCount = try store.rotatePages(path, rotations: rotations, to: output)
        return
            "Wrote \(pageCount) page\(pageCount == 1 ? "" : "s") to \(output.path), "
            + "\(rotations.count) rotation\(rotations.count == 1 ? "" : "s") applied."
    }

    /// `sources` is a JSON array of `{path, pages?}` objects — structured enough that it
    /// is parsed here directly rather than through a generic `Arguments` helper. `path` is
    /// resolved through the read scope per element, exactly as any other input path is.
    private func mergeSources(from arguments: Arguments) throws -> [PDFMergeSource] {
        try arguments.requiredArray("sources").map { element in
            guard case .object(let fields) = element else {
                throw ToolError.badArgument(
                    name: "sources", reason: "each source must be an object")
            }
            guard let rawPath = fields["path"]?.stringValue, !rawPath.isEmpty else {
                throw ToolError.badArgument(name: "sources[].path", reason: "missing or empty")
            }
            let path = try scope.resolve(rawPath)
            var pages: [Int]? = nil
            if case .array(let pageValues)? = fields["pages"] {
                pages = try pageValues.map { value in
                    guard let number = value.intValue else {
                        throw ToolError.badArgument(
                            name: "sources[].pages", reason: "each page number must be an integer"
                        )
                    }
                    return number
                }
            }
            return PDFMergeSource(path: path, pages: pages)
        }
    }

    /// `rotations` is a JSON array of `{page, degrees}` objects. The degrees-must-be-a-
    /// multiple-of-90 check happens in `SystemPDFStore`, not here — this only checks the
    /// shape, not the value.
    private func parseRotations(from arguments: Arguments) throws -> [PDFPageRotation] {
        try arguments.requiredArray("rotations").map { element in
            guard case .object(let fields) = element else {
                throw ToolError.badArgument(
                    name: "rotations", reason: "each entry must be an object")
            }
            guard let page = fields["page"]?.intValue else {
                throw ToolError.badArgument(name: "rotations[].page", reason: "missing integer")
            }
            guard let degrees = fields["degrees"]?.intValue else {
                throw ToolError.badArgument(
                    name: "rotations[].degrees", reason: "missing integer")
            }
            return PDFPageRotation(page: page, degrees: degrees)
        }
    }

    private func addAnnotation(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let page = try arguments.requiredInt("page")
        let kindName = try arguments.requiredString("kind")
        guard let kind = PDFAnnotationKind(rawValue: kindName) else {
            throw ToolError.badArgument(
                name: "kind", reason: "'\(kindName)' is not a recognised annotation kind")
        }
        let annotation = PDFNewAnnotation(
            page: page, kind: kind, x: try arguments.requiredDouble("x"),
            y: try arguments.requiredDouble("y"), width: try arguments.requiredDouble("width"),
            height: try arguments.requiredDouble("height"),
            contents: arguments.optionalString("contents"), color: arguments.optionalString("color"),
            interiorColor: arguments.optionalString("interior_color"))
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        let index = try store.addAnnotation(annotation, to: path, output: output)
        return "Added \(kindName) annotation [\(index)] to page \(page) of \(output.path)."
    }

    private func removeAnnotation(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let page = try arguments.requiredInt("page")
        let index = try arguments.requiredInt("index")
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        try store.removeAnnotation(path, page: page, index: index, to: output)
        return "Removed annotation [\(index)] from page \(page) of \(output.path)."
    }

    private func highlightText(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let query = try arguments.requiredString("query")
        let caseSensitive = arguments.bool("case_sensitive", default: false)
        let accentSensitive = arguments.bool("accent_sensitive", default: false)
        let color = arguments.optionalString("color")
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        let count = try store.highlightText(
            path, query: query, caseSensitive: caseSensitive, accentSensitive: accentSensitive,
            color: color, to: output)
        return
            "Highlighted \(count) occurrence\(count == 1 ? "" : "s") of \"\(query)\" in \(output.path)."
    }

    private func fillForm(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let values = try arguments.requiredStringMap("fields")
        let flatten = arguments.bool("flatten", default: false)
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        let filled = try store.fillForm(path, values: values, flatten: flatten, to: output)
        return
            "Set \(filled) field\(filled == 1 ? "" : "s") in \(output.path)"
            + (flatten ? ", flattened." : ".")
    }

    private func setPassword(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let userPassword = arguments.optionalString("user_password")
        let explicitOwnerPassword = arguments.optionalString("owner_password")
        guard userPassword != nil || explicitOwnerPassword != nil else {
            throw ToolError.badArgument(
                name: "owner_password",
                reason: "give at least one of user_password or owner_password")
        }
        let ownerPassword = explicitOwnerPassword ?? userPassword!
        let permissions = try parsePermissions(from: arguments) ?? Set(PDFPermission.allCases)
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        try store.setPassword(
            path, userPassword: userPassword, ownerPassword: ownerPassword,
            permissions: permissions, to: output)
        return "Password-protected \(output.path)."
    }

    private func removePassword(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let password = try arguments.requiredString("password")
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        try store.removePassword(path, password: password, to: output)
        return "Removed password protection, wrote \(output.path)."
    }

    private func setMetadata(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let update = PDFMetadataUpdate(
            title: arguments.optionalString("title"), author: arguments.optionalString("author"),
            subject: arguments.optionalString("subject"),
            keywords: try parseKeywords(from: arguments))
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        try store.setMetadata(path, update: update, to: output)
        return "Updated metadata, wrote \(output.path)."
    }

    private func parsePermissions(from arguments: Arguments) throws -> Set<PDFPermission>? {
        guard let raw = arguments.optionalArray("permissions") else { return nil }
        var result: Set<PDFPermission> = []
        for value in raw {
            guard let name = value.stringValue, let permission = PDFPermission(rawValue: name)
            else {
                throw ToolError.badArgument(
                    name: "permissions", reason: "an unrecognised permission was given")
            }
            result.insert(permission)
        }
        return result
    }

    private func parseKeywords(from arguments: Arguments) throws -> [String]? {
        guard let raw = arguments.optionalArray("keywords") else { return nil }
        return try raw.map { value in
            guard let string = value.stringValue else {
                throw ToolError.badArgument(name: "keywords", reason: "each keyword must be a string")
            }
            return string
        }
    }

    private func renderPage(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let page = try arguments.requiredInt("page")
        let scale = try Self.validatedScale(arguments)
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        try store.renderPage(path, page: page, scale: scale, to: output)
        return "Rendered page \(page) to \(output.path)."
    }

    private func redactPages(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let regions = try parseRedactionRegions(from: arguments)
        let scale = try Self.validatedScale(arguments)
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        let count = try store.redactPages(path, regions: regions, scale: scale, to: output)
        return
            "Redacted \(count) page\(count == 1 ? "" : "s") in \(output.path). "
            + "Every page listed is now image-only and has no text layer."
    }

    private static func validatedScale(_ arguments: Arguments) throws -> Double {
        let scale = try arguments.optionalDouble("scale") ?? 2.0
        guard scale > 0 else {
            throw ToolError.badArgument(name: "scale", reason: "must be greater than 0")
        }
        return scale
    }

    /// `regions` is a JSON array of `{page, rects: [{x, y, width, height}]}` objects.
    private func parseRedactionRegions(from arguments: Arguments) throws -> [PDFRedactionRegion] {
        try arguments.requiredArray("regions").map { element in
            guard case .object(let fields) = element else {
                throw ToolError.badArgument(
                    name: "regions", reason: "each entry must be an object")
            }
            guard let page = fields["page"]?.intValue else {
                throw ToolError.badArgument(name: "regions[].page", reason: "missing integer")
            }
            guard case .array(let rectValues)? = fields["rects"], !rectValues.isEmpty else {
                throw ToolError.badArgument(
                    name: "regions[].rects", reason: "missing or empty")
            }
            let rects = try rectValues.map { try Self.parseRect($0) }
            return PDFRedactionRegion(page: page, rects: rects)
        }
    }

    private static func parseRect(_ value: Value) throws -> PDFPageRect {
        guard case .object(let fields) = value else {
            throw ToolError.badArgument(name: "regions[].rects", reason: "each rect must be an object")
        }
        func number(_ key: String) throws -> Double {
            guard let raw = fields[key] else {
                throw ToolError.badArgument(name: "regions[].rects", reason: "missing '\(key)'")
            }
            if let value = raw.doubleValue { return value }
            if let value = raw.intValue { return Double(value) }
            throw ToolError.badArgument(name: "regions[].rects", reason: "'\(key)' must be a number")
        }
        return PDFPageRect(
            x: try number("x"), y: try number("y"), width: try number("width"),
            height: try number("height"))
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
