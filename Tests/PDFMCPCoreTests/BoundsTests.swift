import Foundation
import Testing

@testable import PDFMCPCore

/// A store that answers every read with as many synthetic rows as the test asks for, so the
/// bounds of every tool can be driven end to end with no file at all.
final class ListingStore: PDFStore, @unchecked Sendable {
    var rowCount = 0
    /// How wide each long field is made. Wider than any clip, so every clip is exercised.
    var fieldWidth = 5_000
    var pageCount = 3
    var pageText = "text"
    var outlineCount = 0
    var metadataValueWidth = 10
    var delay: TimeInterval = 0

    func canonicalise(_ path: String) throws -> CanonicalPath {
        CanonicalPath(path: path, exists: true)
    }

    func probe(_ path: String) -> RootState { .reachable }

    private var wide: String { String(repeating: "w", count: fieldWidth) }

    func readPDF(_ path: ScopedPath, pages: PageRange?, password: String?) throws -> PDFContent {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let range = pages ?? PageRange(first: 1, last: pageCount)
        let last = Swift.min(range.last, pageCount)
        let numbers = range.first <= last ? Array(range.first...last) : []
        return PDFContent(
            pageCount: pageCount,
            pages: numbers.map { PDFContent.Page(number: $0, text: pageText) },
            outline: (0..<outlineCount).map {
                PDFContent.OutlineEntry(level: 3, title: "Section \($0) " + wide, page: $0 + 1)
            },
            metadata: ["title", "author", "subject", "keywords", "creator", "producer"].map {
                ($0, String(repeating: "m", count: metadataValueWidth))
            },
            isEncrypted: false)
    }

    func searchPDF(
        _ path: ScopedPath, query: String, caseSensitive: Bool, accentSensitive: Bool,
        password: String?
    ) throws -> [PDFSearchMatch] {
        (0..<rowCount).map { PDFSearchMatch(page: 100_000 - $0 % 7, text: "row \($0) " + wide) }
    }

    func listAnnotations(_ path: ScopedPath, password: String?) throws -> [PDFAnnotationEntry] {
        (0..<rowCount).map {
            PDFAnnotationEntry(
                page: 100_000, index: $0, type: "Highlight", contents: "row \($0) " + wide,
                author: wide, x: 123_456_789, y: 123_456_789, width: 123_456_789,
                height: 123_456_789)
        }
    }

    func listFormFields(_ path: ScopedPath, password: String?) throws -> [PDFFormField] {
        (0..<rowCount).map {
            PDFFormField(
                page: 100_000, index: $0, name: "row \($0) " + wide, kind: "choice",
                value: wide, isReadOnly: true)
        }
    }

    func mergePages(_ sources: [PDFMergeSource], to output: WriteScopedPath) throws -> Int { 1 }
    func rotatePages(_ path: ScopedPath, rotations: [PDFPageRotation], to output: WriteScopedPath)
        throws -> Int { 1 }
    func addAnnotation(_ annotation: PDFNewAnnotation, to path: ScopedPath, output: WriteScopedPath)
        throws -> Int { 0 }
    func removeAnnotation(_ path: ScopedPath, page: Int, index: Int, to output: WriteScopedPath)
        throws {}
    func highlightText(
        _ path: ScopedPath, query: String, caseSensitive: Bool, accentSensitive: Bool,
        color: String?, to output: WriteScopedPath
    ) throws -> Int { 1 }
    func fillForm(_ path: ScopedPath, values: [String: String], flatten: Bool, to output: WriteScopedPath)
        throws -> Int { 1 }
    func setPassword(
        _ path: ScopedPath, userPassword: String?, ownerPassword: String,
        permissions: Set<PDFPermission>, to output: WriteScopedPath
    ) throws {}
    func removePassword(_ path: ScopedPath, password: String, to output: WriteScopedPath) throws {}
    func setMetadata(_ path: ScopedPath, update: PDFMetadataUpdate, to output: WriteScopedPath)
        throws {}
    func renderPage(_ path: ScopedPath, page: Int, scale: Double, to output: WriteScopedPath)
        throws {}
    func redactPages(
        _ path: ScopedPath, regions: [PDFRedactionRegion], scale: Double, to output: WriteScopedPath
    ) throws -> Int { 1 }
}

/// One listing tool: what it is called, the rows it pages and the constants that bound it.
private struct Listing {
    let tool: String
    let things: String
    let limits: ClosedRange<Int>
    let defaultLimit: Int
}

private let listings = [
    Listing(
        tool: ToolCatalog.searchName, things: "matches", limits: ToolCatalog.searchLimitRange,
        defaultLimit: ToolCatalog.defaultSearchLimit),
    Listing(
        tool: ToolCatalog.listAnnotationsName, things: "annotations",
        limits: ToolCatalog.annotationLimitRange, defaultLimit: ToolCatalog.defaultAnnotationLimit),
    Listing(
        tool: ToolCatalog.listFormFieldsName, things: "form fields",
        limits: ToolCatalog.formFieldLimitRange, defaultLimit: ToolCatalog.defaultFormFieldLimit),
]

@Suite("Bounds")
struct BoundsTests {

    private func tools(_ store: ListingStore, timeout: Duration = ToolCatalog.callTimeout)
        -> PDFTools
    {
        var configuration = Configuration()
        configuration.readRoots = ["/"]
        configuration.writeRoots = ["/"]
        return PDFTools(store: store, configuration: configuration, timeout: timeout)
    }

    private func run(
        _ tool: String, _ extra: [String: Value] = [:], store: ListingStore = ListingStore(),
        timeout: Duration = ToolCatalog.callTimeout
    ) async -> (text: String, isError: Bool) {
        var arguments: [String: Value] = ["path": .string("/x.pdf")]
        if tool == ToolCatalog.searchName { arguments["query"] = .string("row") }
        for (key, value) in extra { arguments[key] = value }
        let result = await tools(store, timeout: timeout).handle(
            .init(name: tool, arguments: arguments))
        guard case .text(let text)? = result.content.first else { return ("", result.isError) }
        return (text, result.isError)
    }

    // MARK: Every listing

    @Test("A full page of the widest rows fits a result, and the default fits a usual page")
    func pagesFit() async {
        for listing in listings {
            let store = ListingStore()
            store.rowCount = listing.limits.upperBound * 2
            let widest = await run(listing.tool, ["limit": .int(listing.limits.upperBound)], store: store)
            #expect(widest.text.utf16.count <= ToolStandard.longestResult, "\(listing.tool)")
            // The page was not halved to fit: the last row asked for is there.
            #expect(
                widest.text.contains(
                    "Showing 1–\(listing.limits.upperBound) of \(store.rowCount) \(listing.things)."),
                "\(listing.tool) had to halve its widest page")

            let usual = await run(listing.tool, store: store)
            #expect(usual.text.utf16.count <= ToolStandard.usualPage, "\(listing.tool)")
            #expect(
                usual.text.contains("Showing 1–\(listing.defaultLimit) of \(store.rowCount)"))
        }
    }

    @Test("The second page starts where the first ended, and the last says that is all")
    func pagesFollowOn() async {
        for listing in listings {
            let store = ListingStore()
            store.rowCount = listing.defaultLimit + 3
            store.fieldWidth = 10
            let first = await run(listing.tool, store: store)
            #expect(
                first.text.hasPrefix(
                    "Showing 1–\(listing.defaultLimit) of \(store.rowCount) \(listing.things). "
                        + "Pass offset=\(listing.defaultLimit) for the next page."),
                "\(listing.tool)")
            let second = await run(
                listing.tool, ["offset": .int(listing.defaultLimit)], store: store)
            #expect(
                second.text.hasPrefix(
                    "Showing \(listing.defaultLimit + 1)–\(store.rowCount) of \(store.rowCount) "
                        + "\(listing.things). That is all."),
                "\(listing.tool)")
            // Neither page repeats a row of the other.
            #expect(first.text.contains("row \(listing.defaultLimit - 1) "))
            #expect(!second.text.contains("row \(listing.defaultLimit - 1) "))
            #expect(second.text.contains("row \(listing.defaultLimit) "))
        }
    }

    @Test("A result that holds everything carries no notice")
    func wholeResultHasNoNotice() async {
        for listing in listings {
            let store = ListingStore()
            store.rowCount = 2
            store.fieldWidth = 10
            let result = await run(listing.tool, store: store)
            #expect(!result.text.contains("Showing"), "\(listing.tool)")
            #expect(!result.text.contains("Pass offset"), "\(listing.tool)")
        }
    }

    @Test("A limit outside its range is moved and the result says which was used")
    func limitIsMoved() async {
        for listing in listings {
            let store = ListingStore()
            store.rowCount = listing.limits.upperBound + 5
            store.fieldWidth = 10
            let low = await run(listing.tool, ["limit": .int(0)], store: store)
            #expect(
                low.text.hasPrefix(
                    "limit=0 is outside \(listing.limits.lowerBound)–\(listing.limits.upperBound); "
                        + "\(listing.limits.lowerBound) was used."), "\(listing.tool)")
            let high = await run(
                listing.tool, ["limit": .int(listing.limits.upperBound + 1)], store: store)
            #expect(
                high.text.hasPrefix(
                    "limit=\(listing.limits.upperBound + 1) is outside "
                        + "\(listing.limits.lowerBound)–\(listing.limits.upperBound); "
                        + "\(listing.limits.upperBound) was used."), "\(listing.tool)")
            let skipped = await run(listing.tool, ["offset": .int(-4)], store: store)
            #expect(skipped.text.contains("offset=-4 is outside"), "\(listing.tool)")
        }
    }

    @Test("An offset past the end says so and that it is all")
    func offsetPastTheEnd() async {
        for listing in listings {
            let store = ListingStore()
            store.rowCount = 3
            store.fieldWidth = 10
            let result = await run(listing.tool, ["offset": .int(50)], store: store)
            #expect(
                result.text.contains(
                    "Showing 0 of 3 \(listing.things): offset=50 is past the end. That is all."),
                "\(listing.tool)")
        }
    }

    @Test("A wrong type is refused with the form expected, and so is an unlisted argument")
    func wrongTypesAndUnknownArguments() async {
        for listing in listings {
            let wrong = await run(listing.tool, ["limit": .string("ten")])
            #expect(wrong.isError)
            #expect(wrong.text.contains("a whole number was expected"))

            let unknown = await run(listing.tool, ["max_results": .int(5)])
            #expect(unknown.isError)
            #expect(unknown.text.contains("'max_results'"))
            #expect(unknown.text.contains("limit"))
            #expect(unknown.text.contains("offset"))
            #expect(unknown.text.contains("password"))
        }
    }

    @Test("A clipped field is announced only when a row on the page was clipped")
    func clippingIsAnnounced() async {
        let store = ListingStore()
        store.rowCount = 2
        store.fieldWidth = 5_000
        let clipped = await run(ToolCatalog.searchName, store: store)
        let originalWidth = "row 0 ".count + 5_000
        #expect(
            clipped.text.contains(
                "match line: Cut at \(ToolCatalog.searchLineWidth) of "
                    + "\(originalWidth) characters; the rest cannot be read again."))

        store.fieldWidth = 10
        let short = await run(ToolCatalog.searchName, store: store)
        #expect(!short.text.contains("Cut at"))

        store.fieldWidth = 5_000
        let annotations = await run(ToolCatalog.listAnnotationsName, store: store)
        #expect(annotations.text.contains("annotation contents: Cut at"))
        #expect(annotations.text.contains("annotation author: Cut at"))
        let fields = await run(ToolCatalog.listFormFieldsName, store: store)
        #expect(fields.text.contains("field name: Cut at"))
        #expect(fields.text.contains("field value: Cut at"))
    }

    // MARK: pdf_read

    @Test("pdf_read with no optional argument holds about one usual page and says nothing is left")
    func readDefault() async {
        let store = ListingStore()
        store.pageText = "a short page"
        let result = await run(ToolCatalog.readName, store: store)
        #expect(!result.isError)
        #expect(result.text.contains("Text of all 3 pages:"))
        #expect(!result.text.contains("Characters"))
    }

    @Test("pdf_read windows the text and the second window starts where the first ended")
    func readWindows() async {
        let store = ListingStore()
        store.pageText = String(repeating: "x", count: 30_000)
        store.pageCount = 1
        let first = await run(ToolCatalog.readName, ["max_characters": .int(1_000)], store: store)
        let header = "── page 1 ──\n"
        let total = header.count + 30_000
        #expect(
            first.text.hasPrefix(
                "Text: characters 1–1000 of \(total). Pass character_offset=1000 for the rest."))
        let second = await run(
            ToolCatalog.readName,
            ["max_characters": .int(1_000), "character_offset": .int(total - 10)], store: store)
        #expect(
            second.text.hasPrefix(
                "Text: characters \(total - 9)–\(total) of \(total). That is all."))
    }

    @Test("pdf_read's widest result fits and its default window is a usual page")
    func readFits() async {
        let store = ListingStore()
        store.pageText = String(repeating: "x", count: 100_000)
        store.pageCount = 1
        store.outlineCount = ToolCatalog.outlineLimitRange.upperBound * 2
        store.metadataValueWidth = 9_000
        let widest = await run(
            ToolCatalog.readName,
            [
                "max_characters": .int(ToolCatalog.maxCharactersRange.upperBound),
                "limit": .int(ToolCatalog.outlineLimitRange.upperBound),
            ], store: store)
        #expect(widest.text.utf16.count <= ToolStandard.longestResult)
        #expect(
            widest.text.contains(
                "Text: characters 1–\(ToolCatalog.maxCharactersRange.upperBound) of"),
            "the widest read had to halve its window")
        #expect(
            widest.text.contains(
                "Showing 1–\(ToolCatalog.outlineLimitRange.upperBound) of "
                    + "\(store.outlineCount) outline entries."))

        let usual = await run(ToolCatalog.readName, store: store)
        #expect(usual.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("pdf_read clips metadata and outline titles, saying so")
    func readClips() async {
        let store = ListingStore()
        store.outlineCount = 2
        store.metadataValueWidth = 5_000
        let result = await run(ToolCatalog.readName, store: store)
        #expect(
            result.text.contains(
                "title: Cut at \(ToolCatalog.metadataValueWidth) of 5000 characters; "
                    + "the rest cannot be read again."))
        #expect(result.text.contains("outline title: Cut at \(ToolCatalog.outlineTitleWidth)"))
    }

    @Test("pdf_read outline pages with limit and offset")
    func readOutlinePages() async {
        let store = ListingStore()
        store.fieldWidth = 5
        store.outlineCount = 30
        let first = await run(ToolCatalog.readName, ["limit": .int(10)], store: store)
        #expect(
            first.text.hasPrefix(
                "Showing 1–10 of 30 outline entries. Pass offset=10 for the next page."))
        let last = await run(
            ToolCatalog.readName, ["limit": .int(10), "offset": .int(20)], store: store)
        #expect(last.text.hasPrefix("Showing 21–30 of 30 outline entries. That is all."))
    }

    @Test("pdf_read announces an outline it was told to leave out")
    func readNotShown() async {
        let store = ListingStore()
        store.fieldWidth = 5
        store.outlineCount = 4
        let result = await run(
            ToolCatalog.readName, ["include_outline": .bool(false)], store: store)
        #expect(
            result.text.hasPrefix(
                "4 outline entries are not shown. Pass include_outline=true to include them."))
        #expect(!result.text.contains("Outline ("))
    }

    @Test("pdf_read: a last page past the document is moved, a first page past it is refused")
    func readPageRange() async {
        let store = ListingStore()
        store.pageCount = 3
        let moved = await run(ToolCatalog.readName, ["last_page": .int(50)], store: store)
        #expect(!moved.isError)
        #expect(moved.text.hasPrefix("last_page=50 is outside 1–3; 3 was used."))

        let refused = await run(ToolCatalog.readName, ["first_page": .int(4)], store: store)
        #expect(refused.isError)
        #expect(refused.text.contains("first_page=4 is past the end: this PDF has 3 pages"))

        let backwards = await run(
            ToolCatalog.readName, ["first_page": .int(3), "last_page": .int(2)], store: store)
        #expect(backwards.isError)
        #expect(backwards.text.contains("last_page"))

        let identifier = await run(ToolCatalog.readName, ["first_page": .int(0)], store: store)
        #expect(identifier.isError)
        #expect(
            identifier.text.contains(
                "from \(ToolCatalog.pageNumberRange.lowerBound) to "
                    + "\(ToolCatalog.pageNumberRange.upperBound)"))
    }

    @Test("pdf_read with an outline query and no range reads page 1 only, and says which pages")
    func readQueryReadsOnePage() async {
        let store = ListingStore()
        store.outlineCount = 3
        store.fieldWidth = 5
        let result = await run(
            ToolCatalog.readName, ["outline_query": .string("Section")], store: store)
        #expect(result.text.contains("Text of pages 1–1 of 3:"))
        #expect(!result.text.contains("── page 2 ──"))
    }

    // MARK: Time, errors, the guard

    @Test("A call that outruns its deadline is abandoned with an error that says what to do")
    func deadline() async {
        let store = ListingStore()
        store.delay = 1
        let result = await run(
            ToolCatalog.readName, store: store, timeout: .milliseconds(100))
        #expect(result.isError)
        #expect(result.text.contains("did not finish within 0 seconds"))
        #expect(result.text.contains("nothing was changed"))
        #expect(result.text.contains("first_page and last_page"))
    }

    @Test("The deadline error of a writing tool says the change may still have been made")
    func writeDeadline() {
        let message = ToolError.timedOut(seconds: 60, writes: true).message
        #expect(message.contains("may still have been made"))
        #expect(message.utf16.count <= ToolStandard.longestError)
    }

    @Test("The deadline is inside the time limit")
    func deadlineIsInsideTheTimeLimit() {
        #expect(ToolCatalog.callTimeout < ToolStandard.timeLimit)
    }

    @Test("An error repeats a caller's text only clipped, and lists few candidates")
    func errorsEchoLittle() async {
        let long = String(repeating: "q", count: 5_000)
        let unknownTool = await tools(ListingStore()).handle(.init(name: long, arguments: [:]))
        guard case .text(let text)? = unknownTool.content.first else { return }
        #expect(unknownTool.isError)
        #expect(text.utf16.count < 200)

        let many = (0..<50).map { "extra\($0)" }
        let arguments = Dictionary(uniqueKeysWithValues: many.map { ($0, Value.int(1)) })
        let result = await run(ToolCatalog.statusName, arguments)
        #expect(result.isError)
        #expect(result.text.contains("and 46 more"))
        #expect(result.text.utf16.count < 1_000)
    }

    @Test("Unknown arguments inside a nested object are refused too")
    func nestedUnknownArguments() async {
        let result = await run(
            ToolCatalog.rotatePagesName,
            [
                "rotations": .array([
                    .object(["page": .int(1), "degrees": .int(90), "angle": .int(1)])
                ]),
                "output_path": .string("/out.pdf"),
            ])
        #expect(result.isError)
        #expect(result.text.contains("'angle'"))
        #expect(result.text.contains("rotations[]"))
    }

    @Test("A page number or an index outside its range is refused, not moved")
    func identifiersAreRefused() async {
        let result = await run(
            ToolCatalog.removeAnnotationName,
            [
                "page": .int(ToolCatalog.pageNumberRange.upperBound + 1), "index": .int(0),
                "output_path": .string("/out.pdf"),
            ])
        #expect(result.isError)
        #expect(!result.text.contains("was used"))
        let badDegrees = await run(
            ToolCatalog.rotatePagesName,
            [
                "rotations": .array([.object(["page": .int(1), "degrees": .int(45)])]),
                "output_path": .string("/out.pdf"),
            ])
        #expect(badDegrees.isError)
        #expect(badDegrees.text.contains("one of 90, 180, 270, -90, -180, -270"))
    }

    @Test("A scale outside its range is refused with the range, and the schema states it")
    func scaleIsBounded() async {
        for tool in [ToolCatalog.renderPageName, ToolCatalog.redactPagesName] {
            for scale in [0.0, 0.05, 8.5, 1e30] {
                var arguments: [String: Value] = [
                    "scale": .double(scale), "output_path": .string("/out.png"),
                    "page": .int(1),
                    "regions": .array([
                        .object([
                            "page": .int(1),
                            "rects": .array([
                                .object(["x": .int(0), "y": .int(0), "width": .int(1), "height": .int(1)])
                            ]),
                        ])
                    ]),
                ]
                if tool == ToolCatalog.renderPageName { arguments["regions"] = nil }
                if tool == ToolCatalog.redactPagesName { arguments["page"] = nil }
                let result = await run(tool, arguments)
                #expect(result.isError, "\(tool) scale \(scale)")
                #expect(result.text.contains("from 0.1 to 8.0"), "\(tool) scale \(scale)")
            }
        }
        guard case .object(let schema) = ToolCatalog.renderPage.inputSchema,
            case .object(let properties)? = schema["properties"],
            case .object(let scale)? = properties["scale"]
        else {
            Issue.record("pdf_render_page has no scale property")
            return
        }
        #expect(scale["minimum"] == .double(ToolCatalog.scaleRange.lowerBound))
        #expect(scale["maximum"] == .double(ToolCatalog.scaleRange.upperBound))
    }

    @Test("A rotation outside the set the schema offers is refused")
    func rotationsMatchTheSchema() async {
        for degrees in [0, 45, 360, 450] {
            let result = await run(
                ToolCatalog.rotatePagesName,
                [
                    "rotations": .array([.object(["page": .int(1), "degrees": .int(degrees)])]),
                    "output_path": .string("/out.pdf"),
                ])
            #expect(result.isError, "degrees \(degrees)")
        }
        let allowed = await run(
            ToolCatalog.rotatePagesName,
            [
                "rotations": .array(
                    ToolCatalog.rotationDegrees.map { .object(["page": .int(1), "degrees": .int($0)]) }),
                "output_path": .string("/out.pdf"),
            ])
        #expect(!allowed.isError)
    }

    @Test("A flag of the wrong type is refused, not ignored")
    func wrongFlag() async {
        let result = await run(ToolCatalog.readName, ["include_outline": .string("no")])
        #expect(result.isError)
        #expect(result.text.contains("true or false was expected"))
    }

    // MARK: What the model reads

    @Test("No instructions or description is longer than a client reads")
    func textsFit() {
        #expect(
            ToolStandard.overlongTexts(
                instructions: PDFMCPServer.instructions, catalog: ToolCatalog.all()) == [])
        // Measured as sent: the answers to initialize and tools/list carry these strings.
        #expect(PDFMCPServer.instructions.utf16.count <= ToolStandard.longestDescription)
        for tool in ToolCatalog.all() {
            #expect((tool.description ?? "").utf16.count <= ToolStandard.longestDescription)
        }
    }

    @Test("The instructions lead with how results are bounded")
    func instructionsLeadWithBounds() {
        let start = PDFMCPServer.instructions.prefix(600)
        #expect(start.contains("limit and offset"))
        #expect(start.contains("character_offset"))
    }

    @Test("Schemas state the ranges the code enforces")
    func schemasQuoteTheConstants() {
        func property(_ tool: Tool, _ name: String) -> [String: Value]? {
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"],
                case .object(let fields)? = properties[name]
            else { return nil }
            return fields
        }
        for (tool, limits, fallback) in [
            (ToolCatalog.search, ToolCatalog.searchLimitRange, ToolCatalog.defaultSearchLimit),
            (
                ToolCatalog.listAnnotations, ToolCatalog.annotationLimitRange,
                ToolCatalog.defaultAnnotationLimit
            ),
            (
                ToolCatalog.listFormFields, ToolCatalog.formFieldLimitRange,
                ToolCatalog.defaultFormFieldLimit
            ),
            (ToolCatalog.read, ToolCatalog.outlineLimitRange, ToolCatalog.defaultOutlineLimit),
        ] {
            let limit = property(tool, "limit")
            #expect(limit?["minimum"] == .int(limits.lowerBound), "\(tool.name)")
            #expect(limit?["maximum"] == .int(limits.upperBound), "\(tool.name)")
            #expect(limit?["default"] == .int(fallback), "\(tool.name)")
            #expect(property(tool, "offset")?["maximum"] == .int(ToolCatalog.offsetRange.upperBound))
        }
        let window = property(ToolCatalog.read, "max_characters")
        #expect(window?["maximum"] == .int(ToolCatalog.maxCharactersRange.upperBound))
        #expect(window?["default"] == .int(ToolStandard.usualPage))
        #expect(
            property(ToolCatalog.read, "first_page")?["maximum"]
                == .int(ToolCatalog.pageNumberRange.upperBound))
    }

    @Test("README and manifest state only figures the code enforces")
    func documentsQuoteTheConstants() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        for listing in listings {
            let figures = "\(listing.limits.lowerBound)–\(listing.limits.upperBound), default \(listing.defaultLimit)"
            #expect(readme.contains(figures), "README lacks the page size of \(listing.tool)")
        }
        let outline =
            "\(ToolCatalog.outlineLimitRange.lowerBound)–\(ToolCatalog.outlineLimitRange.upperBound), "
            + "default \(ToolCatalog.defaultOutlineLimit)"
        #expect(readme.contains(outline))
        #expect(
            readme.contains(
                "1–\(ToolCatalog.maxCharactersRange.upperBound), default \(ToolCatalog.defaultMaxCharacters)"
            ))
        #expect(readme.contains("\(ToolCatalog.metadataValueWidth) characters"))
        #expect(readme.contains("\(ToolCatalog.annotationContentsWidth) characters"))

        let manifest = try String(
            contentsOf: root.appendingPathComponent("extension/manifest.json"), encoding: .utf8)
        #expect(!manifest.contains("400 characters"))
    }

    @Test("The version agrees across the manifest, the plist and the server")
    func versionAgrees() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try String(
            contentsOf: root.appendingPathComponent("extension/manifest.json"), encoding: .utf8)
        let plist = try String(
            contentsOf: root.appendingPathComponent("Resources/Info.plist"), encoding: .utf8)
        #expect(manifest.contains("\"version\": \"\(PDFMCPServer.version)\""))
        #expect(plist.contains("<string>\(PDFMCPServer.version)</string>"))
    }
}
