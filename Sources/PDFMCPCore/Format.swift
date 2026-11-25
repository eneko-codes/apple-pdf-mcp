import Foundation

/// Plain-text rendering of every tool result.
public struct Format: Sendable {
    public init() {}

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    /// Collapses a multi-line value onto one line, so an outline title containing a
    /// newline does not break the one-entry-per-line layout — which is legal in a PDF's
    /// bookmark label and does happen.
    static func oneLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Clipping

    /// Shortens long fields to a stated width and remembers what it cut, so the result can
    /// say so. Nothing in the PDF spec caps a metadata value, a title or an annotation's
    /// contents: a published document was measured carrying its whole table of contents,
    /// more than thirteen thousand characters, inside its Subject field.
    ///
    /// No tool of this server reads one such value in full, so there is no
    /// `Notice.clipped` to write: the rest cannot be read again, and the notice says so
    /// in the fixed sentence the standard gives for that case.
    struct Clipper {
        private(set) var notices: [String] = []
        private var longest: [String: Int] = [:]
        private var order: [String] = []
        private var widths: [String: Int] = [:]

        mutating func clip(_ value: String, field: String, width: Int) -> String {
            guard value.count > width else { return value }
            if longest[field] == nil { order.append(field) }
            longest[field] = Swift.max(longest[field] ?? 0, value.count)
            widths[field] = width
            return String(value.prefix(width)) + "…"
        }

        /// One sentence per field that lost text, longest original length first quoted.
        var cutNotices: [String] {
            order.map { field in
                Format.cutNotice(field: field, limit: widths[field] ?? 0, total: longest[field] ?? 0)
            }
        }
    }

    /// The sentence for text whose rest can never be read again, with the field it is
    /// about in front. `total` is the longest original value cut in that field.
    static func cutNotice(field: String, limit: Int, total: Int) -> String {
        "\(field): Cut at \(limit) of \(total) characters; the rest cannot be read again."
    }

    /// One page of `rows`: the notices, the sentence that places the page in the whole,
    /// the sentences about fields `render` had to clip, then the rows. `render` returns
    /// the text of the rows it was given and what it clipped, so a notice is only written
    /// for a row that is on the page. A page whose text is still too long is halved, so
    /// no tool leans on the guard.
    static func page<Row>(
        of rows: [Row], limit: Int, offset: Int, things: String, notices: [String],
        render: ([Row]) -> (text: String, cuts: [String])
    ) -> String {
        ToolStandard.fitting(limit) { size in
            let page = Array(rows.dropFirst(offset).prefix(size))
            let position = Notice.page(offset: offset, count: page.count, total: rows.count, things: things)
            let (text, cuts) = render(page)
            return ToolStandard.withNotices(notices + [position].compactMap { $0 } + cuts, text)
        }
    }

    // MARK: Content

    /// What `pdf_read` was asked for, already within its ranges.
    public struct ReadRequest: Sendable {
        public var range: PageRange?
        public var outlineQuery: String?
        public var showOutline: Bool
        public var outlineLimit: Int
        public var outlineOffset: Int
        public var characterOffset: Int
        public var maxCharacters: Int

        public init(
            range: PageRange? = nil, outlineQuery: String? = nil, showOutline: Bool = true,
            outlineLimit: Int = ToolCatalog.defaultOutlineLimit, outlineOffset: Int = 0,
            characterOffset: Int = 0, maxCharacters: Int = ToolCatalog.defaultMaxCharacters
        ) {
            self.range = range
            self.outlineQuery = outlineQuery
            self.showOutline = showOutline
            self.outlineLimit = outlineLimit
            self.outlineOffset = outlineOffset
            self.characterOffset = characterOffset
            self.maxCharacters = maxCharacters
        }
    }

    /// Metadata, then the outline, then a window of the text. Each part is bounded:
    /// values are clipped, the outline is paged, the text is windowed, and the window is
    /// halved while the whole is still longer than a result may be.
    public func pdf(
        _ content: PDFContent, path: String, request: ReadRequest, notices: [String] = []
    ) -> String {
        var clipper = Clipper()
        var facts: [(String, String?)] = [("path", path), ("pages", "\(content.pageCount)")]
        facts += content.metadata.map {
            ($0.0, clipper.clip($0.1, field: $0.0, width: ToolCatalog.metadataValueWidth))
        }
        let metadata = Self.block(facts)

        var outlineNotices: [String] = []
        var outlineSection: String?
        if request.showOutline {
            (outlineSection, outlineNotices) = Self.outline(
                content.outline, request: request, clipper: &clipper)
        } else if !content.outline.isEmpty {
            outlineNotices.append(
                Notice.notShown(
                    count: content.outline.count, things: "outline entries",
                    pass: "include_outline=true"))
        }

        let pages = content.pages.map { page in
            "── page \(page.number) ──\n" + (page.text.isEmpty ? "(no text on this page)" : page.text)
        }.joined(separator: "\n\n")
        let heading: String
        if let range = request.range, content.pages.count < content.pageCount {
            heading = "Text of pages \(range.first)–\(Swift.min(range.last, content.pageCount)) of \(content.pageCount):"
        } else {
            heading = "Text of all \(content.pageCount) pages:"
        }

        return ToolStandard.fitting(request.maxCharacters) { size in
            let window = ToolStandard.window(
                of: pages, characterOffset: request.characterOffset, maxCharacters: size,
                label: "Text")
            let body = [metadata, outlineSection, heading + "\n\n" + window.text]
                .compactMap { $0 }.joined(separator: "\n\n")
            return ToolStandard.withNotices(
                notices + outlineNotices + clipper.cutNotices + [window.notice].compactMap { $0 },
                body)
        }
    }

    /// The outline section and the sentences that go with it: `nil` for a document with no
    /// outline and no query, otherwise a page of the entries whose title contains the
    /// query (all of them without one).
    private static func outline(
        _ outline: [PDFContent.OutlineEntry], request: ReadRequest, clipper: inout Clipper
    ) -> (String?, [String]) {
        let query = request.outlineQuery
        guard !outline.isEmpty else {
            guard let query else { return (nil, []) }
            return (
                "Outline: this PDF has no bookmark outline at all, so \"\(ToolStandard.echo(query))\" "
                    + "cannot be searched within it.", []
            )
        }
        let entries: [PDFContent.OutlineEntry]
        let heading: String
        if let query {
            let needle = query.lowercased()
            entries = outline.filter { $0.title.lowercased().contains(needle) }
            guard !entries.isEmpty else {
                return (
                    "Outline: no entry title contains \"\(ToolStandard.echo(query))\" "
                        + "(it has \(outline.count) entries).", []
                )
            }
            heading = "Outline (entries whose title contains \"\(ToolStandard.echo(query))\", in document order)"
        } else {
            entries = outline
            heading = "Outline (in document order)"
        }

        let page = Array(entries.dropFirst(request.outlineOffset).prefix(request.outlineLimit))
        let rows = page.map { entry -> String in
            let indent = String(repeating: "  ", count: Swift.min(Swift.max(entry.level, 0), 10))
            let title = clipper.clip(
                oneLine(entry.title), field: "outline title", width: ToolCatalog.outlineTitleWidth)
            let location = entry.page.map { " · p\($0)" } ?? ""
            return "  \(indent)\(title)\(location)"
        }
        let position = Notice.page(
            offset: request.outlineOffset, count: page.count, total: entries.count,
            things: "outline entries")
        return (([heading, ""] + rows).joined(separator: "\n"), [position].compactMap { $0 })
    }

    // MARK: Search

    public func search(
        _ matches: [PDFSearchMatch], path: String, query: String, limit: Int, offset: Int,
        notices: [String] = []
    ) -> String {
        guard !matches.isEmpty else {
            return ToolStandard.withNotices(
                notices, "No match for \"\(ToolStandard.echo(query))\" in \(path).")
        }
        let header =
            "\(matches.count) match\(matches.count == 1 ? "" : "es") for "
            + "\"\(ToolStandard.echo(query))\" in \(path), in document order:"
        return Self.page(
            of: matches, limit: limit, offset: offset, things: "matches", notices: notices
        ) { page in
            var clipper = Clipper()
            let lines = page.map { match in
                let text = clipper.clip(
                    Self.oneLine(match.text), field: "match line", width: ToolCatalog.searchLineWidth)
                return "  p\(match.page) — \(text)"
            }
            return (([header] + lines).joined(separator: "\n"), clipper.cutNotices)
        }
    }

    // MARK: Annotations

    public func annotations(
        _ entries: [PDFAnnotationEntry], path: String, limit: Int, offset: Int,
        notices: [String] = []
    ) -> String {
        guard !entries.isEmpty else {
            return ToolStandard.withNotices(notices, "No annotations in \(path).")
        }
        let header =
            "\(entries.count) annotation\(entries.count == 1 ? "" : "s") in \(path), "
            + "by page and index:"
        return Self.page(
            of: entries, limit: limit, offset: offset, things: "annotations", notices: notices
        ) { page in
            var clipper = Clipper()
            let lines = page.map { entry -> String in
                let type = clipper.clip(
                    Self.oneLine(entry.type), field: "annotation type",
                    width: ToolCatalog.annotationTypeWidth)
                var line = "  p\(entry.page)[\(entry.index)] \(type)"
                if let author = entry.author, !author.isEmpty {
                    let shown = clipper.clip(
                        Self.oneLine(author), field: "annotation author",
                        width: ToolCatalog.annotationAuthorWidth)
                    line += " by \(shown)"
                }
                if let contents = entry.contents, !contents.isEmpty {
                    let shown = clipper.clip(
                        Self.oneLine(contents), field: "annotation contents",
                        width: ToolCatalog.annotationContentsWidth)
                    line += " — \(shown)"
                }
                line += String(
                    format: "  (x=%.0f y=%.0f w=%.0f h=%.0f)", entry.x, entry.y, entry.width,
                    entry.height)
                return line
            }
            return (([header] + lines).joined(separator: "\n"), clipper.cutNotices)
        }
    }

    // MARK: Form fields

    public func formFields(
        _ fields: [PDFFormField], path: String, limit: Int, offset: Int, notices: [String] = []
    ) -> String {
        guard !fields.isEmpty else {
            return ToolStandard.withNotices(notices, "No form fields in \(path).")
        }
        let header =
            "\(fields.count) form field\(fields.count == 1 ? "" : "s") in \(path), "
            + "by page and index:"
        return Self.page(
            of: fields, limit: limit, offset: offset, things: "form fields", notices: notices
        ) { page in
            var clipper = Clipper()
            let lines = page.map { field -> String in
                let name = clipper.clip(
                    Self.oneLine(field.name ?? "(unnamed)"), field: "field name",
                    width: ToolCatalog.fieldNameWidth)
                var line = "  p\(field.page)[\(field.index)] \(field.kind) \"\(name)\""
                if let value = field.value, !value.isEmpty {
                    let shown = clipper.clip(
                        Self.oneLine(value), field: "field value",
                        width: ToolCatalog.fieldValueWidth)
                    line += " = \(shown)"
                }
                if field.isReadOnly { line += " (read-only)" }
                return line
            }
            return (([header] + lines).joined(separator: "\n"), clipper.cutNotices)
        }
    }

    // MARK: Status

    public func status(readProbes: [RootProbe], writeProbes: [RootProbe], binaryPath: String)
        -> String
    {
        let headline =
            readProbes.isEmpty && writeProbes.isEmpty
            ? "PDF scope: NOTHING configured — this server can see and touch no files."
            : "PDF scope: \(readProbes.count) read root(s), \(writeProbes.count) write root(s)."

        var text = headline + "\n\n"
        text += Self.block([
            ("binary", binaryPath),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
        ])

        text += "\n\nReadable folders:\n" + Self.rootList(readProbes)
        text += "\n\nWritable folders:\n" + Self.rootList(writeProbes)
        text += """


            Being allowed to read a folder's PDFs does not by itself allow writing into \
            it: the two lists above are independent, and every tool that changes a PDF \
            writes its result to a new path inside a writable folder — none overwrite the \
            file they read.
            """

        if (readProbes + writeProbes).contains(where: { $0.state == .notPermitted }) {
            text += """


                One or more roots are configured but macOS refuses them. That is a system
                permission, not this server's allow-list:
                  System Settings → Privacy & Security → Files and Folders → enable the folders
                  under "apple-pdf-mcp"
                Anywhere outside Desktop, Documents and Downloads needs Full Disk Access
                instead, which is granted by hand and never prompts.
                """
        }
        return text
    }

    private static func rootList(_ probes: [RootProbe]) -> String {
        guard !probes.isEmpty else { return "  (none configured — nothing is reachable)" }
        return probes.map { probe in
            var line = "  \(probe.path) — \(probe.state.rawValue)"
            if let canonical = probe.canonicalPath { line += "\n      resolves to \(canonical)" }
            return line
        }.joined(separator: "\n")
    }
}
