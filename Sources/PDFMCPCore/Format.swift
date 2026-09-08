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

    /// A metadata field is nominally a short label, and every renderer treats it that way
    /// — but nothing in the PDF spec caps one. A published document was measured carrying
    /// its entire table of contents, more than thirteen thousand characters of it, inside
    /// the Subject field, which `pdf_read` then printed in full ahead of the page text the
    /// caller actually asked for. The outline has had a size cap for exactly this reason;
    /// metadata had none.
    static let maxMetadataValueLength = 400

    static func capped(_ value: String) -> String {
        guard value.count > maxMetadataValueLength else { return value }
        let kept = value.prefix(maxMetadataValueLength)
        return "\(kept)… (truncated, \(value.count) characters in total)"
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

    // MARK: Content

    /// A compendium's outline can run to thousands of entries, and the outline is
    /// returned whole regardless of how the page range is bounded — asking for one page
    /// costs exactly as much as asking for all of them. Past this many entries, an
    /// unfiltered outline is truncated with a note rather than dumped in full: a response
    /// that size is what broke outline-first navigation on a real 705-page code in
    /// practice — the tool succeeded, but the answer was too large to use.
    static let maxOutlineEntriesWithoutQuery = 500

    public func pdf(
        _ content: PDFContent, path: String, range: PageRange?, outlineQuery: String? = nil
    ) -> String {
        var sections: [String] = []
        var facts: [(String, String?)] = [
            ("path", path),
            ("pages", "\(content.pageCount)"),
        ]
        facts += content.metadata.map { ($0.0, Self.capped($0.1)) }
        sections.append(Self.block(facts))

        if !content.outline.isEmpty {
            sections.append(Self.outlineSection(content.outline, query: outlineQuery))
        } else if let outlineQuery, !outlineQuery.isEmpty {
            sections.append(
                "Outline: this PDF has no bookmark outline at all, so \"\(outlineQuery)\" "
                    + "cannot be searched within it.")
        }

        let shown = content.pages
        if let range, shown.count < content.pageCount {
            sections.append("Text of pages \(range.first)–\(range.last) of \(content.pageCount):")
        } else {
            sections.append("Text of all \(content.pageCount) pages:")
        }
        sections += shown.map { page in
            "── page \(page.number) ──\n" + (page.text.isEmpty ? "(no text on this page)" : page.text)
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: Search

    public func search(_ matches: [PDFSearchMatch], path: String, query: String) -> String {
        guard !matches.isEmpty else {
            return "No match for \"\(query)\" in \(path)."
        }
        let header = "\(matches.count) match\(matches.count == 1 ? "" : "es") for \"\(query)\" in \(path):"
        let lines = matches.map { "  p\($0.page) — \(Self.oneLine($0.text))" }
        return ([header] + lines).joined(separator: "\n")
    }

    // MARK: Annotations

    public func annotations(_ entries: [PDFAnnotationEntry], path: String) -> String {
        guard !entries.isEmpty else {
            return "No annotations in \(path)."
        }
        let header = "\(entries.count) annotation\(entries.count == 1 ? "" : "s") in \(path):"
        let lines = entries.map { entry -> String in
            var line = "  p\(entry.page)[\(entry.index)] \(entry.type)"
            if let author = entry.author, !author.isEmpty { line += " by \(author)" }
            if let contents = entry.contents, !contents.isEmpty {
                line += " — \(Self.oneLine(contents))"
            }
            line += String(
                format: "  (x=%.0f y=%.0f w=%.0f h=%.0f)", entry.x, entry.y, entry.width,
                entry.height)
            return line
        }
        return ([header] + lines).joined(separator: "\n")
    }

    // MARK: Form fields

    public func formFields(_ fields: [PDFFormField], path: String) -> String {
        guard !fields.isEmpty else {
            return "No form fields in \(path)."
        }
        let header = "\(fields.count) form field\(fields.count == 1 ? "" : "s") in \(path):"
        let lines = fields.map { field -> String in
            var line = "  p\(field.page)[\(field.index)] \(field.kind)"
            line += " \"\(field.name ?? "(unnamed)")\""
            if let value = field.value, !value.isEmpty { line += " = \(Self.oneLine(value))" }
            if field.isReadOnly { line += " (read-only)" }
            return line
        }
        return ([header] + lines).joined(separator: "\n")
    }

    /// Renders the outline section: every entry when it fits, only the matches when
    /// `query` narrows it, and a truncated slice with an explicit note when neither
    /// applies and the outline is simply too large to return whole.
    private static func outlineSection(_ outline: [PDFContent.OutlineEntry], query: String?)
        -> String
    {
        let entries: [PDFContent.OutlineEntry]
        let header: String

        if let query, !query.isEmpty {
            let needle = query.lowercased()
            entries = outline.filter { $0.title.lowercased().contains(needle) }
            if entries.isEmpty {
                let sizeNote =
                    outline.count > maxOutlineEntriesWithoutQuery
                    ? " (it has \(outline.count) entries — try a different word)" : ""
                return "Outline: no entry title contains \"\(query)\"\(sizeNote)."
            }
            header = "Outline (filtered: \"\(query)\" — \(entries.count) of \(outline.count) entries)"
        } else if outline.count > maxOutlineEntriesWithoutQuery {
            entries = Array(outline.prefix(maxOutlineEntriesWithoutQuery))
            header =
                "Outline (showing first \(maxOutlineEntriesWithoutQuery) of \(outline.count) "
                + "entries — pass outline_query to search the rest instead of reading more of them)"
        } else {
            entries = outline
            header = "Outline"
        }

        let rendered = entries.map { entry -> String in
            let indent = String(repeating: "  ", count: max(entry.level, 0))
            let page = entry.page.map { " · p\($0)" } ?? ""
            return "  \(indent)\(oneLine(entry.title))\(page)"
        }
        return ([header, ""] + rendered).joined(separator: "\n")
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
