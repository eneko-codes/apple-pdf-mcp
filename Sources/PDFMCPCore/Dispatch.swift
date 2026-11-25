import Foundation

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
public struct PDFTools: ToolHandler {
    private let store: any PDFStore
    private let scope: PathScope
    private let format: Format
    private let timeout: Duration

    public init(
        store: any PDFStore, configuration: Configuration = Configuration(),
        timeout: Duration = ToolCatalog.callTimeout
    ) {
        self.store = store
        self.format = Format()
        self.scope = PathScope(configuration: configuration, store: store)
        self.timeout = timeout
    }

    /// Every call runs against a deadline, so a PDFKit call that never returns still ends
    /// in an answer that says how to ask for less. The stuck work is abandoned, not
    /// stopped, which is why the error of a tool that writes says the change may still
    /// have been made.
    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<String, any Error>.success(try run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            let writes =
                ToolCatalog.all().first { $0.name == parameters.name }?.annotations.readOnlyHint
                != true
            return failure(
                ToolError.timedOut(seconds: Int(timeout.components.seconds), writes: writes),
                tool: parameters.name, since: started)
        }
    }

    private func failure(
        _ error: any Error, tool: String, since started: ContinuousClock.Instant
    ) -> ToolOutput {
        Diagnostics.toolFailed(tool, error: error, since: started)
        let message =
            (error as? ToolError)?.message
            ?? ToolError.storeFailure(error.localizedDescription).message
        return ToolOutput(text: message, isError: true)
    }

    private func run(_ parameters: ToolCall) throws -> String {
        guard ToolCatalog.all().contains(where: { $0.name == parameters.name }) else {
            throw ToolError.unknownTool(parameters.name)
        }
        let arguments = Arguments(parameters.arguments)
        try arguments.requireOnly(ToolCatalog.argumentNames(of: parameters.name))

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
            throw ToolError.unknownTool(parameters.name)
        }
    }

    private func status() -> String {
        format.status(
            readProbes: scope.probeRoots(), writeProbes: scope.probeWriteRoots(),
            binaryPath: Self.binaryPath)
    }

    private func read(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let outlineQuery = try arguments.optionalString("outline_query")
        let showOutline = try arguments.bool("include_outline", default: true) || outlineQuery != nil
        let outlinePage = try arguments.page(
            defaultLimit: ToolCatalog.defaultOutlineLimit, limits: ToolCatalog.outlineLimitRange)
        let characterOffset = try arguments.int(
            "character_offset", default: 0, in: ToolCatalog.offsetRange)
        let maxCharacters = try arguments.int(
            "max_characters", default: ToolCatalog.defaultMaxCharacters,
            in: ToolCatalog.maxCharactersRange)
        let asked = try arguments.pageRange()
        // 'outline_query' answers "what page is this on?" without reading the document, so a
        // caller who names a query and no range gets page 1's text, not every page's.
        let range =
            asked?.range ?? (outlineQuery != nil ? PageRange(first: 1, last: 1) : nil)
        let password = try arguments.optionalString("password")
        var notices = arguments.notices
        let content = try store.readPDF(path, pages: range, password: password)

        if content.isEncrypted { throw ToolError.pdfEncrypted(path: path.path) }
        if let range, range.first > content.pageCount, content.pageCount > 0 {
            throw ToolError.pageOutOfDocument(
                argument: "first_page", page: range.first, pageCount: content.pageCount)
        }
        // A scan is pages with no text at all. Saying so is the whole difference between
        // "this file is empty" and "this file needs vision_ocr".
        guard content.hasTextLayer || content.pageCount == 0 else {
            throw ToolError.noTextLayer(path: path.path, pageCount: content.pageCount)
        }
        if let asked, asked.lastGiven, asked.range.last > content.pageCount,
            content.pageCount > 0
        {
            notices.append(
                Notice.adjusted(
                    argument: "last_page", asked: asked.range.last,
                    range: 1...content.pageCount, used: content.pageCount))
        }
        let request = Format.ReadRequest(
            range: range, outlineQuery: outlineQuery, showOutline: showOutline,
            outlineLimit: outlinePage.limit, outlineOffset: outlinePage.offset,
            characterOffset: characterOffset, maxCharacters: maxCharacters)
        return format.pdf(content, path: path.path, request: request, notices: notices)
    }

    private func search(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let query = try arguments.requiredString("query")
        let caseSensitive = try arguments.bool("case_sensitive", default: false)
        let accentSensitive = try arguments.bool("accent_sensitive", default: false)
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultSearchLimit, limits: ToolCatalog.searchLimitRange)
        let password = try arguments.optionalString("password")
        let matches = try store.searchPDF(
            path, query: query, caseSensitive: caseSensitive, accentSensitive: accentSensitive,
            password: password)
        return format.search(
            matches, path: path.path, query: query, limit: page.limit, offset: page.offset,
            notices: arguments.notices)
    }

    private func listAnnotations(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultAnnotationLimit,
            limits: ToolCatalog.annotationLimitRange)
        let password = try arguments.optionalString("password")
        let entries = try store.listAnnotations(path, password: password)
        return format.annotations(
            entries, path: path.path, limit: page.limit, offset: page.offset,
            notices: arguments.notices)
    }

    private func listFormFields(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultFormFieldLimit,
            limits: ToolCatalog.formFieldLimitRange)
        let password = try arguments.optionalString("password")
        let fields = try store.listFormFields(path, password: password)
        return format.formFields(
            fields, path: path.path, limit: page.limit, offset: page.offset,
            notices: arguments.notices)
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
            try Arguments.requireOnly(fields, in: "sources[]", allowed: ["path", "pages"])
            guard let rawPath = fields["path"]?.stringValue, !rawPath.isEmpty else {
                throw ToolError.badArgument(name: "sources[].path", reason: "missing or empty")
            }
            let path = try scope.resolve(rawPath)
            var pages: [Int]? = nil
            if let listed = fields["pages"], !listed.isNull {
                guard case .array(let pageValues) = listed else {
                    throw ToolError.badArgument(name: "sources[].pages", reason: "a list was expected")
                }
                pages = try pageValues.map { value in
                    guard let number = value.intValue else {
                        throw ToolError.badArgument(
                            name: "sources[].pages", reason: "each page number must be an integer"
                        )
                    }
                    try Arguments.check(
                        number, named: "sources[].pages", in: ToolCatalog.pageNumberRange)
                    return number
                }
            }
            return PDFMergeSource(path: path, pages: pages)
        }
    }

    /// `rotations` is a JSON array of `{page, degrees}` objects. A degree count that is not
    /// a multiple of 90 is refused here, before it can reach PDFKit, whose setter raises an
    /// exception that cannot be caught for it.
    private func parseRotations(from arguments: Arguments) throws -> [PDFPageRotation] {
        try arguments.requiredArray("rotations").map { element in
            guard case .object(let fields) = element else {
                throw ToolError.badArgument(
                    name: "rotations", reason: "each entry must be an object")
            }
            try Arguments.requireOnly(fields, in: "rotations[]", allowed: ["page", "degrees"])
            guard let page = fields["page"]?.intValue else {
                throw ToolError.badArgument(name: "rotations[].page", reason: "missing integer")
            }
            try Arguments.check(page, named: "rotations[].page", in: ToolCatalog.pageNumberRange)
            guard let degrees = fields["degrees"]?.intValue else {
                throw ToolError.badArgument(
                    name: "rotations[].degrees", reason: "missing integer")
            }
            guard ToolCatalog.rotationDegrees.contains(degrees) else {
                throw ToolError.badArgument(
                    name: "rotations[].degrees",
                    reason:
                        "one of "
                        + ToolCatalog.rotationDegrees.map(String.init).joined(separator: ", ")
                        + " was expected")
            }
            return PDFPageRotation(page: page, degrees: degrees)
        }
    }

    private func addAnnotation(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let page = try arguments.requiredIdentifier("page", in: ToolCatalog.pageNumberRange)
        let kindName = try arguments.requiredString("kind")
        guard let kind = PDFAnnotationKind(rawValue: kindName) else {
            throw ToolError.badArgument(
                name: "kind",
                reason: "'\(ToolStandard.echo(kindName))' is not a recognised annotation kind")
        }
        let annotation = PDFNewAnnotation(
            page: page, kind: kind, x: try arguments.requiredDouble("x"),
            y: try arguments.requiredDouble("y"), width: try arguments.requiredDouble("width"),
            height: try arguments.requiredDouble("height"),
            contents: try arguments.optionalString("contents"),
            color: try arguments.optionalString("color"),
            interiorColor: try arguments.optionalString("interior_color"))
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        let index = try store.addAnnotation(annotation, to: path, output: output)
        return "Added \(kindName) annotation [\(index)] to page \(page) of \(output.path)."
    }

    private func removeAnnotation(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let page = try arguments.requiredIdentifier("page", in: ToolCatalog.pageNumberRange)
        let index = try arguments.requiredIdentifier(
            "index", in: ToolCatalog.annotationIndexRange)
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        try store.removeAnnotation(path, page: page, index: index, to: output)
        return "Removed annotation [\(index)] from page \(page) of \(output.path)."
    }

    private func highlightText(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let query = try arguments.requiredString("query")
        let caseSensitive = try arguments.bool("case_sensitive", default: false)
        let accentSensitive = try arguments.bool("accent_sensitive", default: false)
        let color = try arguments.optionalString("color")
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        let count = try store.highlightText(
            path, query: query, caseSensitive: caseSensitive, accentSensitive: accentSensitive,
            color: color, to: output)
        return
            "Highlighted \(count) occurrence\(count == 1 ? "" : "s") of \"\(ToolStandard.echo(query))\" in \(output.path)."
    }

    private func fillForm(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let values = try arguments.requiredStringMap("fields")
        let flatten = try arguments.bool("flatten", default: false)
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        let filled = try store.fillForm(path, values: values, flatten: flatten, to: output)
        return
            "Set \(filled) field\(filled == 1 ? "" : "s") in \(output.path)"
            + (flatten ? ", flattened." : ".")
    }

    private func setPassword(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let userPassword = try arguments.optionalString("user_password")
        let explicitOwnerPassword = try arguments.optionalString("owner_password")
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
            title: try arguments.optionalString("title"),
            author: try arguments.optionalString("author"),
            subject: try arguments.optionalString("subject"),
            keywords: try parseKeywords(from: arguments))
        let output = try scope.resolveForWrite(try arguments.requiredString("output_path"))
        try store.setMetadata(path, update: update, to: output)
        return "Updated metadata, wrote \(output.path)."
    }

    private func parsePermissions(from arguments: Arguments) throws -> Set<PDFPermission>? {
        guard let raw = try arguments.optionalArray("permissions") else { return nil }
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
        guard let raw = try arguments.optionalArray("keywords") else { return nil }
        return try raw.map { value in
            guard let string = value.stringValue else {
                throw ToolError.badArgument(name: "keywords", reason: "each keyword must be a string")
            }
            return string
        }
    }

    private func renderPage(_ arguments: Arguments) throws -> String {
        let path = try scope.resolve(try arguments.requiredString("path"))
        let page = try arguments.requiredIdentifier("page", in: ToolCatalog.pageNumberRange)
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
        let scale = try arguments.optionalDouble("scale") ?? ToolCatalog.defaultScale
        guard ToolCatalog.scaleRange.contains(scale) else {
            throw ToolError.badArgument(
                name: "scale",
                reason:
                    "a number from \(ToolCatalog.scaleRange.lowerBound) to "
                    + "\(ToolCatalog.scaleRange.upperBound) was expected")
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
            try Arguments.requireOnly(fields, in: "regions[]", allowed: ["page", "rects"])
            guard let page = fields["page"]?.intValue else {
                throw ToolError.badArgument(name: "regions[].page", reason: "missing integer")
            }
            try Arguments.check(page, named: "regions[].page", in: ToolCatalog.pageNumberRange)
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
        try Arguments.requireOnly(
            fields, in: "regions[].rects[]", allowed: ["x", "y", "width", "height"])
        func number(_ key: String) throws -> Double {
            guard let raw = fields[key] else {
                throw ToolError.badArgument(name: "regions[].rects", reason: "missing '\(key)'")
            }
            return try Arguments.number(raw, named: "regions[].rects." + key)
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
