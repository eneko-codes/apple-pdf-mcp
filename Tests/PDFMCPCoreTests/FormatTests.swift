import Foundation
import Testing

@testable import PDFMCPCore

/// `Format.pdf` is a pure function of `PDFContent`, so the outline-filtering and
/// truncation behaviour it renders can be checked without a store, a scope, or any real
/// file — exactly the kind of surface `CLAUDE.md` asks to be proven this way.
@Suite("Outline rendering")
struct FormatTests {

    private static func content(outlineCount: Int) -> PDFContent {
        let outline = (0..<outlineCount).map { index in
            PDFContent.OutlineEntry(level: 0, title: "Section \(index)", page: index + 1)
        }
        return PDFContent(
            pageCount: max(outlineCount, 1),
            pages: [PDFContent.Page(number: 1, text: "some text")],
            outline: outline, metadata: [], isEncrypted: false)
    }

    private func render(
        _ content: PDFContent, request: Format.ReadRequest = .init()
    ) -> String {
        Format().pdf(content, path: "/x.pdf", request: request)
    }

    @Test("A small outline is rendered in full with no notice")
    func smallOutlineInFull() {
        let text = render(Self.content(outlineCount: 3))
        #expect(text.contains("Outline (in document order)"))
        #expect(text.contains("Section 0"))
        #expect(text.contains("Section 2"))
        #expect(!text.contains("Showing"))
    }

    @Test("An outline past the page is cut with the page notice, and the next page follows on")
    func largeOutlineIsPaged() {
        let total = ToolCatalog.defaultOutlineLimit + 50
        let first = render(Self.content(outlineCount: total))
        let last = ToolCatalog.defaultOutlineLimit
        #expect(
            first.hasPrefix(
                "Showing 1–\(last) of \(total) outline entries. Pass offset=\(last) for the next page."
            ))
        #expect(first.contains("Section 0 ·"))
        #expect(!first.contains("Section \(last) ·"))

        var request = Format.ReadRequest()
        request.outlineOffset = last
        let second = render(Self.content(outlineCount: total), request: request)
        #expect(second.contains("Showing \(last + 1)–\(2 * last) of \(total)"))
        #expect(second.contains("Section \(last) ·"))
        #expect(!second.contains("Section \(last - 1) ·"))
    }

    @Test("outline_query narrows a large outline to only the matches")
    func queryFiltersToMatches() {
        var request = Format.ReadRequest()
        request.outlineQuery = "Section 7"
        let text = render(Self.content(outlineCount: 200), request: request)
        #expect(text.contains("entries whose title contains \"Section 7\""))
        #expect(text.contains("Section 7 ·"))
        #expect(!text.contains("Section 0 ·"))
    }

    @Test("outline_query matching nothing says so plainly, without dumping the outline")
    func queryWithNoMatches() {
        var request = Format.ReadRequest()
        request.outlineQuery = "nothing like this"
        let text = render(Self.content(outlineCount: 10), request: request)
        #expect(text.contains("no entry title contains"))
        #expect(!text.contains("Section 0"))
    }

    @Test("outline_query on a PDF with no outline at all says so, not silence")
    func queryWithNoOutlineAtAll() {
        let empty = PDFContent(
            pageCount: 1, pages: [PDFContent.Page(number: 1, text: "text")], outline: [],
            metadata: [], isEncrypted: false)
        var request = Format.ReadRequest()
        request.outlineQuery = "anything"
        #expect(render(empty, request: request).contains("no bookmark outline at all"))
    }
}
