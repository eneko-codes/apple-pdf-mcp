import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// The only file in this repository that touches the real disk.
///
/// Everything above the `PDFStore` seam is proven against an in-memory scope. This is
/// the part that cannot be, so it is kept as thin as it can be: no policy, no
/// formatting, no decisions about what is allowed — those all happen above, and by the
/// time a `ScopedPath` reaches any method here it has already passed the allow-list.
public struct SystemPDFStore: PDFStore {

    /// Computed rather than stored: `FileManager` is not `Sendable`, so it cannot be
    /// held by a type that is. The shared instance is the only one documented as safe
    /// to use from several threads, and nothing here ever wanted a different one.
    private var fileManager: FileManager { .default }

    public init() {}

    // MARK: - Resolution

    /// Expands `~`, standardises away `.` and `..`, and resolves every symlink.
    ///
    /// A missing leaf is normal enough to tolerate — the same resolution the sibling
    /// filesystem server uses — so it walks up to the deepest ancestor that does exist,
    /// canonicalises that, and re-appends the components below it. Canonicalising only
    /// what exists is what stops a symlinked parent from hiding the real destination
    /// from the scope check.
    public func canonicalise(_ path: String) throws -> CanonicalPath {
        let expanded = (path as NSString).expandingTildeInPath
        // A relative path has no meaning here: the process's working directory is
        // whatever Claude Desktop happened to spawn it in, which is nobody's intent.
        guard expanded.hasPrefix("/") else {
            throw ToolError.badArgument(
                name: "path",
                reason: "'\(path)' is not absolute. Give a full path, or one starting with ~")
        }

        let standardised = URL(fileURLWithPath: expanded).standardizedFileURL
        if fileManager.fileExists(atPath: standardised.path) {
            return CanonicalPath(path: standardised.resolvingSymlinksInPath().path, exists: true)
        }

        var missing: [String] = []
        var ancestor = standardised
        while ancestor.path != "/" {
            missing.append(ancestor.lastPathComponent)
            ancestor = ancestor.deletingLastPathComponent()
            if fileManager.fileExists(atPath: ancestor.path) {
                let resolved = missing.reversed().reduce(ancestor.resolvingSymlinksInPath()) {
                    $0.appendingPathComponent($1)
                }
                return CanonicalPath(path: resolved.path, exists: false)
            }
        }
        return CanonicalPath(path: standardised.path, exists: false)
    }

    // MARK: - Status

    public func probe(_ path: String) -> RootState {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else {
            return fileManager.isReadableFile(atPath: path) ? .reachable : .notPermitted
        }
        // The only honest test of a TCC-protected folder is to open it: the path exists
        // and is perfectly visible, and the refusal only arrives on the first read.
        do {
            _ = try fileManager.contentsOfDirectory(atPath: path)
            return .reachable
        } catch {
            return Self.isPermissionError(error) ? .notPermitted : .missing
        }
    }

    // MARK: - Reads

    public func readPDF(_ path: ScopedPath, pages: PageRange?, password: String?) throws
        -> PDFContent
    {
        let document = try open(path, password: password)
        // A locked document reports its page count as 0 and yields nothing, which reads
        // as an empty PDF unless the lock is checked for first.
        if document.isLocked {
            return PDFContent(
                pageCount: document.pageCount, pages: [], outline: [], metadata: [],
                isEncrypted: true)
        }

        let range = (pages ?? PageRange(first: 1, last: document.pageCount))
            .clamped(to: max(document.pageCount, 1))
        var extracted: [PDFContent.Page] = []
        if document.pageCount > 0 {
            for number in range.first...range.last {
                guard let page = document.page(at: number - 1) else { continue }
                extracted.append(PDFContent.Page(number: number, text: page.string ?? ""))
            }
        }

        return PDFContent(
            pageCount: document.pageCount, pages: extracted,
            outline: Self.outline(of: document), metadata: Self.metadata(of: document),
            isEncrypted: false)
    }

    public func searchPDF(
        _ path: ScopedPath, query: String, caseSensitive: Bool, accentSensitive: Bool,
        password: String?
    ) throws -> [PDFSearchMatch] {
        let document = try openOrThrowIfLocked(path, password: password)
        let options = Self.compareOptions(
            caseSensitive: caseSensitive, accentSensitive: accentSensitive)
        return Self.find(query, in: document, options: options).compactMap { selection in
            guard let page = selection.pages.first else { return nil }
            // A selection covering only the raw match reads as a bare fragment; extending
            // it to the line it sits on turns a bare word into the sentence it appears in,
            // which is what makes a hit useful without opening the page.
            selection.extendForLineBoundaries()
            let text = (selection.string ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
            return PDFSearchMatch(page: document.index(for: page) + 1, text: text)
        }
    }

    public func listAnnotations(_ path: ScopedPath, password: String?) throws
        -> [PDFAnnotationEntry]
    {
        let document = try openOrThrowIfLocked(path, password: password)
        var entries: [PDFAnnotationEntry] = []
        for pageNumber in 0..<document.pageCount {
            guard let page = document.page(at: pageNumber) else { continue }
            for (index, annotation) in page.annotations.enumerated() {
                let bounds = annotation.bounds
                entries.append(
                    PDFAnnotationEntry(
                        page: pageNumber + 1, index: index,
                        type: annotation.type ?? "(unknown)",
                        contents: annotation.contents, author: annotation.userName,
                        x: bounds.origin.x, y: bounds.origin.y, width: bounds.width,
                        height: bounds.height))
            }
        }
        return entries
    }

    public func listFormFields(_ path: ScopedPath, password: String?) throws -> [PDFFormField] {
        let document = try openOrThrowIfLocked(path, password: password)
        var fields: [PDFFormField] = []
        for pageNumber in 0..<document.pageCount {
            guard let page = document.page(at: pageNumber) else { continue }
            for (index, annotation) in page.annotations.enumerated() {
                guard annotation.type == "Widget" else { continue }
                fields.append(
                    PDFFormField(
                        page: pageNumber + 1, index: index, name: annotation.fieldName,
                        kind: Self.kind(of: annotation.widgetFieldType),
                        value: annotation.widgetStringValue, isReadOnly: annotation.isReadOnly))
            }
        }
        return fields
    }

    // MARK: - Writes

    public func mergePages(_ sources: [PDFMergeSource], to output: WriteScopedPath) throws -> Int
    {
        let result = PDFDocument()
        for source in sources {
            let document = try openOrThrowIfLocked(source.path, password: nil)
            let numbers =
                source.pages ?? (document.pageCount > 0 ? Array(1...document.pageCount) : [])
            for number in numbers {
                guard number >= 1, number <= document.pageCount,
                    let page = document.page(at: number - 1)
                else {
                    throw ToolError.badArgument(
                        name: "sources",
                        reason:
                            "page \(number) does not exist in \(source.path.path) "
                            + "(\(document.pageCount) page(s))")
                }
                result.insert(page, at: result.pageCount)
            }
        }
        try write(result, to: output)
        return result.pageCount
    }

    public func rotatePages(
        _ path: ScopedPath, rotations: [PDFPageRotation], to output: WriteScopedPath
    ) throws -> Int {
        let document = try openOrThrowIfLocked(path, password: nil)
        for rotation in rotations {
            guard rotation.page >= 1, rotation.page <= document.pageCount,
                let page = document.page(at: rotation.page - 1)
            else {
                throw ToolError.badArgument(
                    name: "rotations",
                    reason:
                        "page \(rotation.page) does not exist in \(path.path) "
                        + "(\(document.pageCount) page(s))")
            }
            // PDFPage.rotation's setter raises an Objective-C exception for anything that
            // is not a multiple of 90 — not a Swift error, so try/catch cannot stop it
            // from taking the whole process down. This guard is load-bearing, not belt
            // and suspenders, however redundant it looks next to the schema's own enum.
            guard rotation.degrees % 90 == 0 else {
                throw ToolError.badArgument(
                    name: "rotations", reason: "\(rotation.degrees) is not a multiple of 90")
            }
            page.rotation = rotation.degrees
        }
        try write(document, to: output)
        return document.pageCount
    }

    public func addAnnotation(
        _ annotation: PDFNewAnnotation, to path: ScopedPath, output: WriteScopedPath
    ) throws -> Int {
        let document = try openOrThrowIfLocked(path, password: nil)
        guard annotation.page >= 1, annotation.page <= document.pageCount,
            let page = document.page(at: annotation.page - 1)
        else {
            throw ToolError.badArgument(
                name: "page",
                reason: "page \(annotation.page) does not exist (\(document.pageCount) page(s))")
        }

        let rect = CGRect(
            x: annotation.x, y: annotation.y, width: annotation.width, height: annotation.height)
        let pdfAnnotation = PDFAnnotation(
            bounds: rect, forType: Self.subtype(for: annotation.kind), withProperties: nil)
        pdfAnnotation.contents = annotation.contents
        pdfAnnotation.color =
            annotation.color.flatMap(Self.color(fromHex:)) ?? Self.defaultColor(for: annotation.kind)

        switch annotation.kind {
        case .highlight, .underline, .strikeOut:
            // Markup annotations draw from their quad points, not their bounds — a
            // Highlight with bounds but no quads renders as nothing on some readers.
            pdfAnnotation.quadrilateralPoints = Self.quad(for: CGRect(origin: .zero, size: rect.size))
        case .square, .circle:
            if let hex = annotation.interiorColor, let fill = Self.color(fromHex: hex) {
                pdfAnnotation.interiorColor = fill
            }
        case .note, .freeText:
            break
        }

        page.addAnnotation(pdfAnnotation)
        let index = page.annotations.count - 1
        try write(document, to: output)
        return index
    }

    public func removeAnnotation(
        _ path: ScopedPath, page pageNumber: Int, index: Int, to output: WriteScopedPath
    ) throws {
        let document = try openOrThrowIfLocked(path, password: nil)
        guard pageNumber >= 1, pageNumber <= document.pageCount,
            let page = document.page(at: pageNumber - 1)
        else {
            throw ToolError.badArgument(
                name: "page",
                reason: "page \(pageNumber) does not exist (\(document.pageCount) page(s))")
        }
        guard index >= 0, index < page.annotations.count else {
            throw ToolError.badArgument(
                name: "index",
                reason:
                    "annotation \(index) does not exist on page \(pageNumber) "
                    + "(\(page.annotations.count) annotation(s))")
        }
        // A note (Text) annotation is created by PDFKit paired with a Popup annotation
        // carrying the same contents, and the popup is a separate entry on the page.
        // Removing the note alone leaves that popup orphaned — still listed, still holding
        // the very text the caller asked to remove.
        //
        // Finding that popup is harder than it looks, and all the obvious routes were
        // measured failing: `target.popup` vends a different object than the one in
        // `page.annotations` (===, isEqual: and == all false, its `.page` differs, and even
        // its bounds differ — 304,690,128x64 vended vs 324,714,72x36 stored), so passing it
        // to removeAnnotation silently does nothing, and neither rect-matching nor setting
        // `target.popup = nil` drops it either. Matching on contents is what actually works.
        //
        // The cost of that: two notes on one page with identical text would drop both
        // popups. The surviving note keeps its text and only loses its popup window, so the
        // failure mode is cosmetic — where leaving the popup behind is not, since it holds
        // a copy of the very text the caller asked to remove.
        let target = page.annotations[index]
        if target.popup != nil, let contents = target.contents {
            page.removeAnnotation(target)
            for candidate in page.annotations
            where candidate.type == "Popup" && candidate.contents == contents {
                page.removeAnnotation(candidate)
            }
        } else {
            page.removeAnnotation(target)
        }
        try write(document, to: output)
    }

    public func highlightText(
        _ path: ScopedPath, query: String, caseSensitive: Bool, accentSensitive: Bool,
        color: String?, to output: WriteScopedPath
    ) throws -> Int {
        let document = try openOrThrowIfLocked(path, password: nil)
        let options = Self.compareOptions(
            caseSensitive: caseSensitive, accentSensitive: accentSensitive)
        let highlightColor = color.flatMap(Self.color(fromHex:)) ?? Self.defaultColor(for: .highlight)

        var highlighted = 0
        for match in Self.find(query, in: document, options: options) {
            guard let page = match.pages.first else { continue }
            // A match can cross a line break; one quad per line is what keeps the
            // highlight following the text instead of covering the whitespace between
            // lines with a single rectangle.
            let lineSelections = match.selectionsByLine()
            let lineRects = (lineSelections.isEmpty ? [match] : lineSelections)
                .map { $0.bounds(for: page) }
            guard let union = lineRects.dropFirst().reduce(lineRects.first, { $0?.union($1) })
            else { continue }

            let annotation = PDFAnnotation(bounds: union, forType: .highlight, withProperties: nil)
            annotation.color = highlightColor
            annotation.quadrilateralPoints = lineRects.flatMap { rect -> [NSValue] in
                let local = CGRect(
                    x: rect.minX - union.minX, y: rect.minY - union.minY, width: rect.width,
                    height: rect.height)
                return Self.quad(for: local)
            }
            page.addAnnotation(annotation)
            highlighted += 1
        }
        try write(document, to: output)
        return highlighted
    }

    public func fillForm(
        _ path: ScopedPath, values: [String: String], flatten: Bool, to output: WriteScopedPath
    ) throws -> Int {
        let document = try openOrThrowIfLocked(path, password: nil)
        var unmatched = Set(values.keys)
        var filled = 0
        for pageNumber in 0..<document.pageCount {
            guard let page = document.page(at: pageNumber) else { continue }
            for annotation in page.annotations {
                guard annotation.type == "Widget", annotation.widgetFieldType != .signature,
                    let name = annotation.fieldName, let value = values[name]
                else { continue }
                annotation.widgetStringValue = value
                unmatched.remove(name)
                filled += 1
            }
        }
        guard unmatched.isEmpty else {
            let names = unmatched.sorted().map { "'\($0)'" }.joined(separator: ", ")
            throw ToolError.badArgument(
                name: "fields", reason: "no field named \(names) exists in this document")
        }

        if flatten {
            guard
                document.write(
                    to: URL(fileURLWithPath: output.path),
                    withOptions: [.burnInAnnotationsOption: true])
            else {
                throw ToolError.storeFailure("PDFKit could not write to \(output.path)")
            }
        } else {
            try write(document, to: output)
        }
        return filled
    }

    public func setPassword(
        _ path: ScopedPath, userPassword: String?, ownerPassword: String,
        permissions: Set<PDFPermission>, to output: WriteScopedPath
    ) throws {
        let document = try openOrThrowIfLocked(path, password: nil)
        var options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: ownerPassword,
            .accessPermissionsOption: Self.bitmask(for: permissions),
        ]
        if let userPassword { options[.userPasswordOption] = userPassword }
        guard document.write(to: URL(fileURLWithPath: output.path), withOptions: options) else {
            throw ToolError.storeFailure("PDFKit could not write to \(output.path)")
        }
    }

    public func removePassword(
        _ path: ScopedPath, password: String, to output: WriteScopedPath
    ) throws {
        let document = try open(path, password: password)
        guard !document.isLocked else { throw ToolError.pdfEncrypted(path: path.path) }

        // Unlocking is not decrypting. PDFKit keeps the document's security handler after
        // unlock(withPassword:) — `isEncrypted` stays true by design, Apple documents that
        // — and every write path that preserves the handler writes the encryption straight
        // back out: write(to:), write(to:withOptions: [:]) and dataRepresentation() were
        // all measured producing a still-locked file. Only a document built fresh, with
        // the pages moved into it, comes out genuinely plain.
        let plain = PDFDocument()
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        for page in pages { plain.insert(page, at: plain.pageCount) }
        plain.documentAttributes = document.documentAttributes
        plain.outlineRoot = document.outlineRoot
        try write(plain, to: output)
    }

    public func setMetadata(
        _ path: ScopedPath, update: PDFMetadataUpdate, to output: WriteScopedPath
    ) throws {
        let document = try openOrThrowIfLocked(path, password: nil)
        var attributes = document.documentAttributes ?? [:]
        if let title = update.title { attributes[PDFDocumentAttribute.titleAttribute.rawValue] = title }
        if let author = update.author {
            attributes[PDFDocumentAttribute.authorAttribute.rawValue] = author
        }
        if let subject = update.subject {
            attributes[PDFDocumentAttribute.subjectAttribute.rawValue] = subject
        }
        if let keywords = update.keywords {
            attributes[PDFDocumentAttribute.keywordsAttribute.rawValue] = keywords
        }
        document.documentAttributes = attributes
        try write(document, to: output)
    }

    public func renderPage(
        _ path: ScopedPath, page pageNumber: Int, scale: Double, to output: WriteScopedPath
    ) throws {
        let document = try openOrThrowIfLocked(path, password: nil)
        guard pageNumber >= 1, pageNumber <= document.pageCount,
            let page = document.page(at: pageNumber - 1)
        else {
            throw ToolError.badArgument(
                name: "page",
                reason: "page \(pageNumber) does not exist (\(document.pageCount) page(s))")
        }
        let image = try Self.rasterize(page, scale: scale)
        try Self.writePNG(image, to: output)
    }

    public func redactPages(
        _ path: ScopedPath, regions: [PDFRedactionRegion], scale: Double, to output: WriteScopedPath
    ) throws -> Int {
        let document = try openOrThrowIfLocked(path, password: nil)
        for region in regions {
            guard region.page >= 1, region.page <= document.pageCount,
                let page = document.page(at: region.page - 1)
            else {
                throw ToolError.badArgument(
                    name: "regions",
                    reason:
                        "page \(region.page) does not exist (\(document.pageCount) page(s))")
            }
            // Rendered with the page's own rotation already baked in (drawWithBox:toContext:
            // draws as displayed), so the replacement page needs none of its own — applying
            // rotation again would rotate an already-rotated picture.
            let image = try Self.rasterize(page, scale: scale, redactions: region.rects)
            guard let replacement = PDFPage(image: image) else {
                throw ToolError.storeFailure(
                    "PDFKit could not build a replacement page for page \(region.page)")
            }
            let index = region.page - 1
            document.removePage(at: index)
            document.insert(replacement, at: index)
        }
        try write(document, to: output)
        return regions.count
    }

    // MARK: - Helpers

    /// Accent-insensitive by default, and that default is load-bearing rather than a
    /// convenience. One published document routinely spells the same term two ways —
    /// "resume" in one section and "résumé" in another, "cafe" and "café", a name with and
    /// without its diacritic. Accent-exact search then finds one set of occurrences or the
    /// other and never both, while reporting a clean count that looks complete, which is a
    /// worse failure than finding nothing. A caller who genuinely needs the distinction can
    /// ask for it.
    private static func compareOptions(caseSensitive: Bool, accentSensitive: Bool)
        -> NSString.CompareOptions
    {
        var options: NSString.CompareOptions = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        if !accentSensitive { options.insert(.diacriticInsensitive) }
        return options
    }

    /// `findString` matches against the page's own text, where a wrap is a literal "\n" —
    /// so a phrase typed the way a person says it, with a space between the words, finds
    /// nothing at all when the document happens to wrap at exactly that space. Measured:
    /// "Confidential Information" returned 0 hits on a page whose text holds
    /// "Confidential\nInformation", while the same phrase with the newline matched.
    ///
    /// Silently returning "no matches" for a phrase plainly present on the page is the
    /// worst possible answer, so a multi-word query that finds nothing is retried with each
    /// space in turn standing in for the break. A phrase that wraps at two points at once
    /// would still be missed; that needs a query long enough to span three lines, which is
    /// rare enough to leave alone rather than chase with more permutations.
    private static func find(
        _ query: String, in document: PDFDocument, options: NSString.CompareOptions
    ) -> [PDFSelection] {
        let direct = document.findString(query, withOptions: options)
        if !direct.isEmpty { return direct }

        for spaceIndex in query.indices where query[spaceIndex] == " " {
            var variant = query
            variant.replaceSubrange(spaceIndex...spaceIndex, with: "\n")
            let hits = document.findString(variant, withOptions: options)
            if !hits.isEmpty { return hits }
        }
        return []
    }

    /// Renders `page` into a bitmap `scale` times its point size, optionally painting
    /// opaque black boxes over `redactions` into that same bitmap before extracting it —
    /// the two calls this backs (`renderPage`, `redactPages`) differ only in whether
    /// `redactions` is empty, and in what they do with the resulting image afterward.
    private static func rasterize(
        _ page: PDFPage, scale: Double, redactions: [PDFPageRect] = []
    ) throws -> NSImage {
        let box: PDFDisplayBox = .mediaBox
        let bounds = page.bounds(for: box)
        let pixelWidth = max(1, Int((bounds.width * scale).rounded()))
        let pixelHeight = max(1, Int((bounds.height * scale).rounded()))

        guard
            let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw ToolError.storeFailure("could not create a bitmap context to render this page")
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        page.draw(with: box, to: context)

        // Painted after the page content, in the same unscaled point-space the caller's
        // rect arguments are already in — the context's own scale transform above is what
        // makes that line up with the pixel buffer without any manual conversion here.
        if !redactions.isEmpty {
            context.setFillColor(NSColor.black.cgColor)
            for rect in redactions {
                context.fill(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
            }
        }

        guard let cgImage = context.makeImage() else {
            throw ToolError.storeFailure("could not extract the rendered page image")
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: bounds.width, height: bounds.height))
    }

    private static func writePNG(_ image: NSImage, to output: WriteScopedPath) throws {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw ToolError.storeFailure("could not encode the rendered page as PNG")
        }
        do {
            try data.write(to: URL(fileURLWithPath: output.path))
        } catch {
            throw ToolError.storeFailure(
                "could not write \(output.path): \(error.localizedDescription)")
        }
    }

    /// `PDFAccessPermissions` is declared `NS_ENUM`, not `NS_OPTIONS` — it does not import
    /// as an `OptionSet`, so the bits are combined by hand from each case's own
    /// `rawValue` rather than through Swift's option-set array syntax.
    private static func bitmask(for permissions: Set<PDFPermission>) -> UInt {
        var mask: UInt = 0
        if permissions.contains(.printingLow) { mask |= PDFAccessPermissions.allowsLowQualityPrinting.rawValue }
        if permissions.contains(.printingHigh) {
            mask |= PDFAccessPermissions.allowsHighQualityPrinting.rawValue
        }
        if permissions.contains(.documentChanges) {
            mask |= PDFAccessPermissions.allowsDocumentChanges.rawValue
        }
        if permissions.contains(.documentAssembly) {
            mask |= PDFAccessPermissions.allowsDocumentAssembly.rawValue
        }
        if permissions.contains(.contentCopying) {
            mask |= PDFAccessPermissions.allowsContentCopying.rawValue
        }
        if permissions.contains(.contentAccessibility) {
            mask |= PDFAccessPermissions.allowsContentAccessibility.rawValue
        }
        if permissions.contains(.commenting) { mask |= PDFAccessPermissions.allowsCommenting.rawValue }
        if permissions.contains(.formFieldEntry) {
            mask |= PDFAccessPermissions.allowsFormFieldEntry.rawValue
        }
        return mask
    }

    private static func subtype(for kind: PDFAnnotationKind) -> PDFAnnotationSubtype {
        switch kind {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikeOut: return .strikeOut
        case .note: return .text
        case .freeText: return .freeText
        case .square: return .square
        case .circle: return .circle
        }
    }

    private static func defaultColor(for kind: PDFAnnotationKind) -> NSColor {
        switch kind {
        case .highlight, .note: return .yellow
        case .underline, .strikeOut: return .red
        case .freeText, .square, .circle: return .black
        }
    }

    /// "#RRGGBB" only — this server never needs alpha, and accepting it would just be
    /// another way for a malformed value to fail silently instead of loudly.
    private static func color(fromHex hex: String) -> NSColor? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return NSColor(
            srgbRed: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255, alpha: 1)
    }

    /// `quadrilateralPoints` is documented as relative to the annotation's own
    /// `bounds.origin`, in a 'Z' order: upper-left, upper-right, lower-left, lower-right.
    /// Pass a rect already translated into that local space — `CGRect(origin: .zero, ...)`
    /// for a single-quad annotation, or a rect offset from a shared union origin for one
    /// quad among several.
    private static func quad(for localRect: CGRect) -> [NSValue] {
        [
            CGPoint(x: localRect.minX, y: localRect.maxY),
            CGPoint(x: localRect.maxX, y: localRect.maxY),
            CGPoint(x: localRect.minX, y: localRect.minY),
            CGPoint(x: localRect.maxX, y: localRect.minY),
        ].map { NSValue(point: $0) }
    }

    private func write(_ document: PDFDocument, to output: WriteScopedPath) throws {
        guard document.write(to: URL(fileURLWithPath: output.path)) else {
            throw ToolError.storeFailure("PDFKit could not write to \(output.path)")
        }
    }

    /// Opens a document, trying `password` if it is locked. Leaves it locked if the
    /// password was absent or wrong — the caller decides what that means.
    private func open(_ path: ScopedPath, password: String?) throws -> PDFDocument {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path.path)) else {
            guard fileManager.fileExists(atPath: path.path) else {
                throw ToolError.notFound(path: path.path)
            }
            throw ToolError.notAPDF(path: path.path)
        }
        if document.isLocked, let password { _ = document.unlock(withPassword: password) }
        return document
    }

    /// The convenience `readPDF` deliberately does not use: search and the two listing
    /// methods have no partial-content shape worth returning for a document that stayed
    /// locked, so they refuse outright instead of handing back an empty list that reads
    /// as "nothing found" rather than "could not look".
    private func openOrThrowIfLocked(_ path: ScopedPath, password: String?) throws -> PDFDocument
    {
        let document = try open(path, password: password)
        guard !document.isLocked else { throw ToolError.pdfEncrypted(path: path.path) }
        return document
    }

    private static func kind(of widgetFieldType: PDFAnnotationWidgetSubtype) -> String {
        switch widgetFieldType {
        case .button: return "button"
        case .choice: return "choice"
        case .signature: return "signature"
        case .text: return "text"
        default: return "unknown"
        }
    }

    private static func outline(of document: PDFDocument) -> [PDFContent.OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }
        var entries: [PDFContent.OutlineEntry] = []
        func walk(_ node: PDFOutline, level: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let page = child.destination?.page.map { document.index(for: $0) + 1 }
                entries.append(
                    PDFContent.OutlineEntry(
                        level: level, title: child.label ?? "(untitled)", page: page))
                walk(child, level: level + 1)
            }
        }
        walk(root, level: 0)
        return entries
    }

    private static func metadata(of document: PDFDocument) -> [(String, String)] {
        let attributes = document.documentAttributes ?? [:]
        // Fixed order so two reads of the same document render identically; a
        // dictionary's own order is not stable between runs.
        let wanted: [(PDFDocumentAttribute, String)] = [
            (.titleAttribute, "title"), (.authorAttribute, "author"),
            (.subjectAttribute, "subject"), (.keywordsAttribute, "keywords"),
            (.creatorAttribute, "creator"), (.producerAttribute, "producer"),
            (.creationDateAttribute, "created"), (.modificationDateAttribute, "modified"),
        ]
        return wanted.compactMap { key, label in
            guard let value = attributes[key.rawValue] else { return nil }
            if let date = value as? Date {
                return (label, ISO8601DateFormatter().string(from: date))
            }
            if let list = value as? [String] {
                return list.isEmpty ? nil : (label, list.joined(separator: ", "))
            }
            let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (label, text)
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileReadNoPermissionError
                || nsError.code == NSFileWriteNoPermissionError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        }
        return false
    }
}
