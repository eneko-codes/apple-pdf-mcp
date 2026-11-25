import Foundation

public enum ToolError: Error, Equatable {
    case noReadRootsConfigured
    case noWriteRootsConfigured
    case pathOutOfScope(requested: String, resolved: String, readRoots: [String])
    case pathOutOfWriteScope(requested: String, resolved: String, writeRoots: [String])
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case notFound(path: String)
    case notAPDF(path: String)
    case pdfEncrypted(path: String)
    case noTextLayer(path: String, pageCount: Int)
    case permissionDenied(path: String, detail: String)
    case storeFailure(String)
    case unknownTool(String)
    case unknownArguments([String], allowed: [String], in: String? = nil)
    case timedOut(seconds: Int, writes: Bool)
    /// A page the document does not have. `pageCount` is what it does have.
    case pageOutOfDocument(argument: String, page: Int, pageCount: Int)

    public var message: String {
        switch self {
        case .noReadRootsConfigured:
            return """
                This server has no read roots configured, so it can see nothing at all.

                That is the safe default, not a fault: an unconfigured server would
                otherwise start with the whole disk in reach. Name the folders Claude
                may look inside in:
                  Claude Desktop → Settings → Extensions → PDF → Folders Claude may read

                Nothing outside that list can be opened.
                """

        case .noWriteRootsConfigured:
            return """
                This server has no write roots configured, so it cannot save anything \
                anywhere.

                That is the safe default, not a fault: an unconfigured server would
                otherwise be free to leave new files across the whole disk. Name the
                folders Claude may write PDFs and images into in:
                  Claude Desktop → Settings → Extensions → PDF → Folders Claude may write

                Being allowed to read a folder's PDFs does not by itself allow writing into
                it — the two lists are independent, on purpose.
                """

        case .pathOutOfScope(let requested, let resolved, let readRoots):
            let scope = Self.rootList(readRoots)
            let resolution =
                resolved == requested
                ? "" : "\n\nIt resolves to:\n  \(ToolStandard.echo(resolved))\n(symlinks and .. are followed before the check, always)."
            return """
                Path '\(ToolStandard.echo(requested))' is outside the scope this extension was configured with.\
                \(resolution)

                Readable folders: \(scope)

                This is not something to work around: the person installing the extension
                chose those folders in its settings, deliberately keeping everything else
                out of reach. Change them in Claude Desktop → Settings → Extensions.
                """

        case .pathOutOfWriteScope(let requested, let resolved, let writeRoots):
            let scope = Self.rootList(writeRoots)
            let resolution =
                resolved == requested
                ? "" : "\n\nIt resolves to:\n  \(ToolStandard.echo(resolved))\n(symlinks and .. are followed before the check, always)."
            return """
                Output path '\(ToolStandard.echo(requested))' is outside the folders this extension may write \
                into.\(resolution)

                Writable folders: \(scope)

                Every tool that changes a PDF writes to a new path you choose — it never \
                overwrites the file it read. Pick an output_path inside one of the folders \
                above, or change them in Claude Desktop → Settings → Extensions.
                """

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(ToolStandard.echo(name))' is not valid: \(reason)"

        case .notFound(let path):
            return "Nothing exists at '\(ToolStandard.echo(path))'."

        case .notAPDF(let path):
            return """
                '\(ToolStandard.echo(path))' could not be opened as a PDF.

                PDFKit refused it, which usually means it is not really a PDF whatever the
                extension says, or the file is truncated.
                """

        case .pdfEncrypted(let path):
            return """
                '\(ToolStandard.echo(path))' is password-protected, and no password was given or the one given is wrong.

                PDFKit will not read a locked document. pdf_read, pdf_search and the two
                listings take the password as `password`; pdf_remove_password writes an
                unlocked copy.
                """

        case .noTextLayer(let path, let pageCount):
            return """
                '\(ToolStandard.echo(path))' has \(pageCount) page\(pageCount == 1 ? "" : "s") and no text layer at all.

                That is what a scan looks like: the pages are images of text, so there is
                nothing for PDFKit to extract. Reading it means text recognition over the
                page images, which this server does not do.
                """

        case .permissionDenied(let path, let detail):
            return """
                macOS refused access to '\(ToolStandard.echo(path))': \(ToolStandard.echo(detail))

                The path is inside the configured scope, so this is a system permission,
                not this server's allow-list. Two different grants can be missing:

                For Desktop, Documents or Downloads:
                  System Settings → Privacy & Security → Files and Folders → enable the folder
                  under "apple-pdf-mcp"

                For anywhere else — iCloud Drive, an external disk, another user's folder:
                  System Settings → Privacy & Security → Full Disk Access → add and enable
                  "apple-pdf-mcp"

                Then restart Claude Desktop: the permission is resolved when the process
                starts. Full Disk Access has no consent dialog — it is never requested,
                only granted by hand.
                """

        case .storeFailure(let detail):
            return "PDFKit returned an error: \(ToolStandard.echo(detail))"

        case .unknownTool(let name):
            return "'\(ToolStandard.echo(name))' is not a tool of this server."

        case .unknownArguments(let unknown, let allowed, let context):
            let names = unknown.prefix(Self.listedCandidates).map { "'\(ToolStandard.echo($0))'" }
                .joined(separator: ", ")
            let more =
                unknown.count > Self.listedCandidates
                ? " and \(unknown.count - Self.listedCandidates) more" : ""
            let place = context.map { " in \($0)" } ?? ""
            let accepted = allowed.isEmpty ? "none" : allowed.joined(separator: ", ")
            return "Not an argument\(place): \(names)\(more). It accepts: \(accepted)."

        case .timedOut(let seconds, let writes):
            let consequence =
                writes
                ? "The change may still have been made: look at output_path before trying again."
                : "This call only reads, so nothing was changed."
            return """
                The call did not finish within \(seconds) seconds and was abandoned. \
                \(consequence)

                Ask for less: pdf_read takes first_page and last_page, and every tool is \
                quicker on a PDF with fewer pages. pdf_status says whether the server still \
                answers at all.
                """

        case .pageOutOfDocument(let argument, let page, let pageCount):
            return """
                \(argument)=\(page) is past the end: this PDF has \(pageCount) \
                page\(pageCount == 1 ? "" : "s"). Pages are numbered from 1.
                """
        }
    }

    /// The most roots or candidate names an error lists; it says how many more there are.
    static let listedCandidates = 5

    private static func rootList(_ roots: [String]) -> String {
        guard !roots.isEmpty else { return "(none configured)" }
        let shown = roots.prefix(listedCandidates).map { ToolStandard.echo($0) }
        let more = roots.count > listedCandidates ? " and \(roots.count - listedCandidates) more" : ""
        return shown.joined(separator: ", ") + more
    }
}
