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
            PDFContent.OutlineEntry(level: 0, title: "Artículo \(index)", page: index + 1)
        }
        return PDFContent(
            pageCount: max(outlineCount, 1),
            pages: [PDFContent.Page(number: 1, text: "some text")],
            outline: outline, metadata: [], isEncrypted: false)
    }

    @Test("A small outline is rendered in full with no query")
    func smallOutlineInFull() {
        let text = Format().pdf(Self.content(outlineCount: 3), path: "/x.pdf", range: nil)
        #expect(text.contains("Outline\n"))
        #expect(text.contains("Artículo 0"))
        #expect(text.contains("Artículo 2"))
        #expect(!text.contains("outline_query"))
    }

    @Test("An outline past the cap is truncated with a note, not returned whole")
    func largeOutlineIsTruncated() {
        let total = Format.maxOutlineEntriesWithoutQuery + 50
        let text = Format().pdf(Self.content(outlineCount: total), path: "/x.pdf", range: nil)
        #expect(text.contains("showing first \(Format.maxOutlineEntriesWithoutQuery) of \(total)"))
        #expect(text.contains("outline_query"))
        #expect(text.contains("Artículo 0"))
        // The entry just past the cap must not appear — otherwise this is not a real cap.
        #expect(!text.contains("Artículo \(Format.maxOutlineEntriesWithoutQuery)\n"))
    }

    @Test("outline_query narrows a large outline to only the matches")
    func queryFiltersToMatches() {
        let total = Format.maxOutlineEntriesWithoutQuery + 50
        let text = Format().pdf(
            Self.content(outlineCount: total), path: "/x.pdf", range: nil,
            outlineQuery: "Artículo 7")
        // Matches "Artículo 7", "Artículo 70".."Artículo 79", "Artículo 7" inside larger
        // numbers too (e.g. "Artículo 170") — the point is that it is bounded and exact,
        // not that it is a single hit.
        #expect(text.contains("filtered: \"Artículo 7\""))
        #expect(text.contains("Artículo 7 "))
        #expect(!text.contains("Artículo 0 "))
    }

    @Test("outline_query matching nothing says so plainly, without dumping the outline")
    func queryWithNoMatches() {
        let text = Format().pdf(
            Self.content(outlineCount: 10), path: "/x.pdf", range: nil,
            outlineQuery: "no existe esto")
        #expect(text.contains("no entry title contains"))
        #expect(!text.contains("Artículo 0"))
    }

    @Test("outline_query on a PDF with no outline at all says so, not silence")
    func queryWithNoOutlineAtAll() {
        let empty = PDFContent(
            pageCount: 1, pages: [PDFContent.Page(number: 1, text: "text")], outline: [],
            metadata: [], isEncrypted: false)
        let text = Format().pdf(empty, path: "/x.pdf", range: nil, outlineQuery: "algo")
        #expect(text.contains("no bookmark outline at all"))
    }
}
