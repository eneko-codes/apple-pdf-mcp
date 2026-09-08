import Foundation
import MCP
import Testing

@testable import PDFMCPCore

/// Records what it was called with and hands back synthetic content, so a test can assert
/// what `PDFTools.handle` actually asked the store for — the argument parsing and routing
/// in `Dispatch.swift` — without touching a real file. `@unchecked Sendable` because the
/// tests that use it are strictly sequential; nothing here is ever called concurrently.
final class RecordingStore: PDFStore, @unchecked Sendable {
    var lastReadPassword: String?
    var lastPageRange: PageRange?
    var lastSearchQuery: String?
    var lastCaseSensitive: Bool?
    var lastAccentSensitive: Bool?
    var lastPassword: String?

    func canonicalise(_ path: String) throws -> CanonicalPath {
        CanonicalPath(path: path, exists: true)
    }

    func probe(_ path: String) -> RootState { .reachable }

    func readPDF(_ path: ScopedPath, pages: PageRange?, password: String?) throws -> PDFContent {
        lastPageRange = pages
        lastReadPassword = password
        return PDFContent(
            pageCount: 2, pages: [PDFContent.Page(number: 1, text: "hello")], outline: [],
            metadata: [], isEncrypted: false)
    }

    func searchPDF(
        _ path: ScopedPath, query: String, caseSensitive: Bool, accentSensitive: Bool,
        password: String?
    ) throws -> [PDFSearchMatch] {
        lastSearchQuery = query
        lastCaseSensitive = caseSensitive
        lastAccentSensitive = accentSensitive
        lastPassword = password
        return [PDFSearchMatch(page: 3, text: "a line containing \(query)")]
    }

    func listAnnotations(_ path: ScopedPath, password: String?) throws -> [PDFAnnotationEntry] {
        lastPassword = password
        return [
            PDFAnnotationEntry(
                page: 1, index: 0, type: "Highlight", contents: "worth remembering",
                author: "user", x: 10, y: 20, width: 100, height: 12)
        ]
    }

    func listFormFields(_ path: ScopedPath, password: String?) throws -> [PDFFormField] {
        lastPassword = password
        return [
            PDFFormField(
                page: 1, index: 0, name: "full_name", kind: "text", value: nil, isReadOnly: false)
        ]
    }

    var lastMergeSources: [PDFMergeSource]?
    var lastMergeOutput: WriteScopedPath?
    var lastRotations: [PDFPageRotation]?
    var lastRotateOutput: WriteScopedPath?

    func mergePages(_ sources: [PDFMergeSource], to output: WriteScopedPath) throws -> Int {
        lastMergeSources = sources
        lastMergeOutput = output
        return sources.reduce(0) { $0 + ($1.pages?.count ?? 1) }
    }

    func rotatePages(
        _ path: ScopedPath, rotations: [PDFPageRotation], to output: WriteScopedPath
    ) throws -> Int {
        lastRotations = rotations
        lastRotateOutput = output
        return 5
    }

    var lastNewAnnotation: PDFNewAnnotation?
    var lastRemovedPage: Int?
    var lastRemovedIndex: Int?
    var lastHighlightQuery: String?
    var lastHighlightColor: String?

    func addAnnotation(
        _ annotation: PDFNewAnnotation, to path: ScopedPath, output: WriteScopedPath
    ) throws -> Int {
        lastNewAnnotation = annotation
        return 2
    }

    func removeAnnotation(
        _ path: ScopedPath, page: Int, index: Int, to output: WriteScopedPath
    ) throws {
        lastRemovedPage = page
        lastRemovedIndex = index
    }

    func highlightText(
        _ path: ScopedPath, query: String, caseSensitive: Bool, accentSensitive: Bool,
        color: String?, to output: WriteScopedPath
    ) throws -> Int {
        lastHighlightQuery = query
        lastHighlightColor = color
        return 3
    }

    var lastFormValues: [String: String]?
    var lastFlatten: Bool?

    func fillForm(
        _ path: ScopedPath, values: [String: String], flatten: Bool, to output: WriteScopedPath
    ) throws -> Int {
        lastFormValues = values
        lastFlatten = flatten
        return values.count
    }

    var lastUserPassword: String?
    var lastOwnerPassword: String?
    var lastPermissions: Set<PDFPermission>?
    var lastRemovePasswordArg: String?
    var lastMetadataUpdate: PDFMetadataUpdate?

    func setPassword(
        _ path: ScopedPath, userPassword: String?, ownerPassword: String,
        permissions: Set<PDFPermission>, to output: WriteScopedPath
    ) throws {
        lastUserPassword = userPassword
        lastOwnerPassword = ownerPassword
        lastPermissions = permissions
    }

    func removePassword(_ path: ScopedPath, password: String, to output: WriteScopedPath) throws {
        lastRemovePasswordArg = password
    }

    func setMetadata(
        _ path: ScopedPath, update: PDFMetadataUpdate, to output: WriteScopedPath
    ) throws {
        lastMetadataUpdate = update
    }

    var lastRenderPage: Int?
    var lastRenderScale: Double?
    var lastRedactionRegions: [PDFRedactionRegion]?
    var lastRedactionScale: Double?

    func renderPage(
        _ path: ScopedPath, page: Int, scale: Double, to output: WriteScopedPath
    ) throws {
        lastRenderPage = page
        lastRenderScale = scale
    }

    func redactPages(
        _ path: ScopedPath, regions: [PDFRedactionRegion], scale: Double, to output: WriteScopedPath
    ) throws -> Int {
        lastRedactionRegions = regions
        lastRedactionScale = scale
        return regions.count
    }
}

/// End-to-end through `PDFTools.handle`, proving `Dispatch` routes each tool name to the
/// right handler and passes arguments through unmangled — the part `PathScopeTests` and
/// `CatalogueTests` don't reach, since neither drives a full `tools/call`.
@Suite("Dispatch")
struct DispatchTests {

    private func tools(_ store: RecordingStore) -> PDFTools {
        var configuration = Configuration()
        configuration.readRoots = ["/"]
        configuration.writeRoots = ["/"]
        return PDFTools(store: store, configuration: configuration)
    }

    private func call(_ name: String, _ arguments: [String: Value]) -> CallTool.Parameters {
        .init(name: name, arguments: arguments)
    }

    // MARK: Status

    /// The one tool untouched by the Phase 1 rewrite of `Format.status` in name only —
    /// its rendering changed from a single read-only list to two independent scopes, and
    /// nothing had exercised that wiring through `Dispatch` until this test: `CatalogueTests`
    /// only checks schema shape, never calls a tool, and there is no `FormatTests` suite.
    @Test("pdf_status reports both the read and write scopes")
    func statusReportsBothScopes() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(call(ToolCatalog.statusName, [:]))
        #expect(result.isError == false)
        guard case .text(let text, _, _) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("1 read root(s), 1 write root(s)"))
        #expect(text.contains("Readable folders:"))
        #expect(text.contains("Writable folders:"))
    }

    @Test("pdf_status reports nothing configured when both scopes are empty")
    func statusReportsNothingConfigured() async throws {
        let store = RecordingStore()
        let empty = PDFTools(store: store, configuration: Configuration())
        let result = await empty.handle(call(ToolCatalog.statusName, [:]))
        #expect(result.isError == false)
        guard case .text(let text, _, _) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("NOTHING configured"))
    }

    @Test("pdf_read passes its password through to the store")
    func readPassesPassword() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(ToolCatalog.readName, ["path": .string("/x.pdf"), "password": .string("hunter2")]))
        #expect(result.isError == false)
        #expect(store.lastReadPassword == "hunter2")
    }

    @Test("pdf_read omits the password when none was given")
    func readOmitsPassword() async throws {
        let store = RecordingStore()
        _ = await tools(store).handle(call(ToolCatalog.readName, ["path": .string("/x.pdf")]))
        #expect(store.lastReadPassword == nil)
    }

    @Test("pdf_search passes query, case sensitivity and password through")
    func searchPassesArguments() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.searchName,
                [
                    "path": .string("/x.pdf"), "query": .string("confidential information"),
                    "case_sensitive": .bool(true), "password": .string("s3cret"),
                ]))
        #expect(result.isError == false)
        #expect(store.lastSearchQuery == "confidential information")
        #expect(store.lastCaseSensitive == true)
        #expect(store.lastPassword == "s3cret")
    }

    @Test("pdf_search defaults to case-insensitive")
    func searchDefaultsCaseInsensitive() async throws {
        let store = RecordingStore()
        _ = await tools(store).handle(
            call(ToolCatalog.searchName, ["path": .string("/x.pdf"), "query": .string("agreement")]))
        #expect(store.lastCaseSensitive == false)
    }

    /// Accent-insensitivity is the default because one document often spells a term two
    /// ways — "resume" in one section, "résumé" in another — and an accent-exact search
    /// then finds one set or the other, never both. A caller who wants the distinction has
    /// to ask for it.
    @Test("pdf_search is accent-insensitive by default and exact on request")
    func searchAccentSensitivity() async throws {
        let store = RecordingStore()
        _ = await tools(store).handle(
            call(ToolCatalog.searchName, ["path": .string("/x.pdf"), "query": .string("resume")]))
        #expect(store.lastAccentSensitive == false)

        _ = await tools(store).handle(
            call(
                ToolCatalog.searchName,
                [
                    "path": .string("/x.pdf"), "query": .string("resume"),
                    "accent_sensitive": .bool(true),
                ]))
        #expect(store.lastAccentSensitive == true)
    }

    @Test("pdf_search requires a query")
    func searchRequiresQuery() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(ToolCatalog.searchName, ["path": .string("/x.pdf")]))
        #expect(result.isError == true)
    }

    @Test("pdf_list_annotations renders what the store returns")
    func listAnnotationsRenders() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(ToolCatalog.listAnnotationsName, ["path": .string("/x.pdf")]))
        #expect(result.isError == false)
        guard case .text(let text, _, _) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("Highlight"))
        #expect(text.contains("worth remembering"))
    }

    @Test("pdf_list_form_fields renders what the store returns")
    func listFormFieldsRenders() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(ToolCatalog.listFormFieldsName, ["path": .string("/x.pdf")]))
        #expect(result.isError == false)
        guard case .text(let text, _, _) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("full_name"))
    }

    @Test("An unknown tool name is refused")
    func unknownToolIsRefused() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(call("pdf_frobnicate", [:]))
        #expect(result.isError == true)
    }

    // MARK: Page assembly

    @Test("pdf_merge_pages parses multiple sources, each with its own page list")
    func mergePagesParsesSources() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.mergePagesName,
                [
                    "sources": .array([
                        .object([
                            "path": .string("/a.pdf"),
                            "pages": .array([.int(2), .int(1)]),
                        ]),
                        .object(["path": .string("/b.pdf")]),
                    ]),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == false)
        #expect(store.lastMergeSources?.count == 2)
        #expect(store.lastMergeSources?[0].path.path == "/a.pdf")
        #expect(store.lastMergeSources?[0].pages == [2, 1])
        #expect(store.lastMergeSources?[1].pages == nil)
        #expect(store.lastMergeOutput?.path == "/out.pdf")
    }

    @Test("pdf_merge_pages requires at least one source")
    func mergePagesRequiresSources() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.mergePagesName,
                ["sources": .array([]), "output_path": .string("/out.pdf")]))
        #expect(result.isError == true)
    }

    @Test("pdf_merge_pages's output_path is refused outside the write scope")
    func mergePagesOutputOutsideWriteScopeIsRefused() async throws {
        let store = RecordingStore()
        var configuration = Configuration()
        configuration.readRoots = ["/"]
        configuration.writeRoots = ["/Users/user/Output"]
        let narrow = PDFTools(store: store, configuration: configuration)

        let result = await narrow.handle(
            call(
                ToolCatalog.mergePagesName,
                [
                    "sources": .array([.object(["path": .string("/a.pdf")])]),
                    "output_path": .string("/Users/user/Elsewhere/out.pdf"),
                ]))
        #expect(result.isError == true)
        #expect(store.lastMergeSources == nil)
    }

    @Test("pdf_rotate_pages parses page/degrees pairs")
    func rotatePagesParsesRotations() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.rotatePagesName,
                [
                    "path": .string("/a.pdf"),
                    "rotations": .array([
                        .object(["page": .int(1), "degrees": .int(90)]),
                        .object(["page": .int(3), "degrees": .int(-90)]),
                    ]),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == false)
        #expect(store.lastRotations == [PDFPageRotation(page: 1, degrees: 90), PDFPageRotation(page: 3, degrees: -90)])
        #expect(store.lastRotateOutput?.path == "/out.pdf")
    }

    @Test("pdf_rotate_pages requires at least one rotation")
    func rotatePagesRequiresRotations() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.rotatePagesName,
                [
                    "path": .string("/a.pdf"), "rotations": .array([]),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == true)
    }

    // MARK: Annotations

    @Test("pdf_add_annotation parses a whole-number rect sent as JSON integers")
    func addAnnotationParsesIntegerCoordinates() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.addAnnotationName,
                [
                    "path": .string("/a.pdf"), "page": .int(1), "kind": .string("highlight"),
                    "x": .int(10), "y": .int(20), "width": .int(100), "height": .int(12),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == false)
        #expect(store.lastNewAnnotation?.kind == .highlight)
        #expect(store.lastNewAnnotation?.x == 10)
        #expect(store.lastNewAnnotation?.y == 20)
        #expect(store.lastNewAnnotation?.width == 100)
        #expect(store.lastNewAnnotation?.height == 12)
    }

    @Test("pdf_add_annotation parses a fractional rect")
    func addAnnotationParsesFractionalCoordinates() async throws {
        let store = RecordingStore()
        _ = await tools(store).handle(
            call(
                ToolCatalog.addAnnotationName,
                [
                    "path": .string("/a.pdf"), "page": .int(1), "kind": .string("note"),
                    "x": .double(10.5), "y": .double(20.25), "width": .double(50.0),
                    "height": .double(20.0), "contents": .string("worth remembering"),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(store.lastNewAnnotation?.x == 10.5)
        #expect(store.lastNewAnnotation?.contents == "worth remembering")
    }

    @Test("pdf_add_annotation refuses an unrecognised kind")
    func addAnnotationRefusesUnknownKind() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.addAnnotationName,
                [
                    "path": .string("/a.pdf"), "page": .int(1), "kind": .string("sparkle"),
                    "x": .int(0), "y": .int(0), "width": .int(1), "height": .int(1),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == true)
        #expect(store.lastNewAnnotation == nil)
    }

    @Test("pdf_remove_annotation passes page and index through")
    func removeAnnotationPassesArguments() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.removeAnnotationName,
                [
                    "path": .string("/a.pdf"), "page": .int(2), "index": .int(1),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == false)
        #expect(store.lastRemovedPage == 2)
        #expect(store.lastRemovedIndex == 1)
    }

    @Test("pdf_highlight_text passes query and color through")
    func highlightTextPassesArguments() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.highlightTextName,
                [
                    "path": .string("/a.pdf"), "query": .string("confidential information"),
                    "color": .string("#FFCC00"), "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == false)
        #expect(store.lastHighlightQuery == "confidential information")
        #expect(store.lastHighlightColor == "#FFCC00")
    }

    // MARK: Forms

    @Test("pdf_fill_form passes the field map and flatten flag through")
    func fillFormPassesArguments() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.fillFormName,
                [
                    "path": .string("/a.pdf"),
                    "fields": .object(["full_name": .string("Eneko"), "agree": .string("Yes")]),
                    "flatten": .bool(true), "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == false)
        #expect(store.lastFormValues == ["full_name": "Eneko", "agree": "Yes"])
        #expect(store.lastFlatten == true)
    }

    @Test("pdf_fill_form defaults flatten to false")
    func fillFormDefaultsFlattenFalse() async throws {
        let store = RecordingStore()
        _ = await tools(store).handle(
            call(
                ToolCatalog.fillFormName,
                [
                    "path": .string("/a.pdf"), "fields": .object(["full_name": .string("Eneko")]),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(store.lastFlatten == false)
    }

    @Test("pdf_fill_form requires a non-empty fields object")
    func fillFormRequiresFields() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.fillFormName,
                ["path": .string("/a.pdf"), "fields": .object([:]), "output_path": .string("/out.pdf")]
            ))
        #expect(result.isError == true)
    }

    @Test("pdf_fill_form refuses a non-string field value")
    func fillFormRefusesNonStringValue() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.fillFormName,
                [
                    "path": .string("/a.pdf"), "fields": .object(["age": .int(30)]),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == true)
    }

    // MARK: Security & metadata

    @Test("pdf_set_password defaults owner_password to user_password when omitted")
    func setPasswordDefaultsOwnerToUser() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.setPasswordName,
                [
                    "path": .string("/a.pdf"), "user_password": .string("open-me"),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == false)
        #expect(store.lastUserPassword == "open-me")
        #expect(store.lastOwnerPassword == "open-me")
        #expect(store.lastPermissions == Set(PDFPermission.allCases))
    }

    @Test("pdf_set_password keeps distinct user and owner passwords")
    func setPasswordKeepsDistinctPasswords() async throws {
        let store = RecordingStore()
        _ = await tools(store).handle(
            call(
                ToolCatalog.setPasswordName,
                [
                    "path": .string("/a.pdf"), "user_password": .string("open-me"),
                    "owner_password": .string("admin-only"), "output_path": .string("/out.pdf"),
                ]))
        #expect(store.lastUserPassword == "open-me")
        #expect(store.lastOwnerPassword == "admin-only")
    }

    @Test("pdf_set_password requires at least one password")
    func setPasswordRequiresAPassword() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(ToolCatalog.setPasswordName, ["path": .string("/a.pdf"), "output_path": .string("/out.pdf")])
        )
        #expect(result.isError == true)
        #expect(store.lastOwnerPassword == nil)
    }

    @Test("pdf_set_password's empty permissions list means deny everything, not the default")
    func setPasswordEmptyPermissionsMeansDenyAll() async throws {
        let store = RecordingStore()
        _ = await tools(store).handle(
            call(
                ToolCatalog.setPasswordName,
                [
                    "path": .string("/a.pdf"), "user_password": .string("open-me"),
                    "permissions": .array([]), "output_path": .string("/out.pdf"),
                ]))
        #expect(store.lastPermissions == [])
    }

    @Test("pdf_set_password refuses an unrecognised permission")
    func setPasswordRefusesUnknownPermission() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.setPasswordName,
                [
                    "path": .string("/a.pdf"), "user_password": .string("open-me"),
                    "permissions": .array([.string("nonsense")]),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == true)
    }

    @Test("pdf_remove_password passes the password through")
    func removePasswordPassesArgument() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.removePasswordName,
                [
                    "path": .string("/a.pdf"), "password": .string("open-me"),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == false)
        #expect(store.lastRemovePasswordArg == "open-me")
    }

    @Test("pdf_set_metadata only sets the fields given")
    func setMetadataOnlySetsGivenFields() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.setMetadataName,
                [
                    "path": .string("/a.pdf"), "title": .string("New Title"),
                    "keywords": .array([.string("a"), .string("b")]),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == false)
        #expect(store.lastMetadataUpdate?.title == "New Title")
        #expect(store.lastMetadataUpdate?.author == nil)
        #expect(store.lastMetadataUpdate?.subject == nil)
        #expect(store.lastMetadataUpdate?.keywords == ["a", "b"])
    }

    // MARK: Rendering & redaction

    @Test("pdf_render_page defaults scale to 2.0")
    func renderPageDefaultsScale() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.renderPageName,
                ["path": .string("/a.pdf"), "page": .int(3), "output_path": .string("/out.png")]))
        #expect(result.isError == false)
        #expect(store.lastRenderPage == 3)
        #expect(store.lastRenderScale == 2.0)
    }

    @Test("pdf_render_page passes an explicit scale through")
    func renderPagePassesScale() async throws {
        let store = RecordingStore()
        _ = await tools(store).handle(
            call(
                ToolCatalog.renderPageName,
                [
                    "path": .string("/a.pdf"), "page": .int(1), "scale": .double(4.0),
                    "output_path": .string("/out.png"),
                ]))
        #expect(store.lastRenderScale == 4.0)
    }

    @Test("pdf_render_page refuses a non-positive scale")
    func renderPageRefusesNonPositiveScale() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.renderPageName,
                [
                    "path": .string("/a.pdf"), "page": .int(1), "scale": .double(0),
                    "output_path": .string("/out.png"),
                ]))
        #expect(result.isError == true)
    }

    @Test("pdf_redact_pages parses regions with multiple rects")
    func redactPagesParsesRegions() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.redactPagesName,
                [
                    "path": .string("/a.pdf"),
                    "regions": .array([
                        .object([
                            "page": .int(1),
                            "rects": .array([
                                .object([
                                    "x": .int(10), "y": .int(20), "width": .int(100),
                                    "height": .int(30),
                                ])
                            ]),
                        ])
                    ]),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == false)
        #expect(store.lastRedactionRegions?.count == 1)
        #expect(store.lastRedactionRegions?[0].page == 1)
        #expect(store.lastRedactionRegions?[0].rects == [
            PDFPageRect(x: 10, y: 20, width: 100, height: 30)
        ])
    }

    @Test("pdf_redact_pages requires at least one region")
    func redactPagesRequiresRegions() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.redactPagesName,
                ["path": .string("/a.pdf"), "regions": .array([]), "output_path": .string("/out.pdf")])
        )
        #expect(result.isError == true)
    }

    @Test("pdf_redact_pages requires at least one rect per region")
    func redactPagesRequiresRectsPerRegion() async throws {
        let store = RecordingStore()
        let result = await tools(store).handle(
            call(
                ToolCatalog.redactPagesName,
                [
                    "path": .string("/a.pdf"),
                    "regions": .array([.object(["page": .int(1), "rects": .array([])])]),
                    "output_path": .string("/out.pdf"),
                ]))
        #expect(result.isError == true)
    }
}
