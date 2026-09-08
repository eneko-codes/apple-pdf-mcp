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
            let scope = readRoots.isEmpty ? "(none configured)" : readRoots.joined(separator: ", ")
            let resolution =
                resolved == requested
                ? "" : "\n\nIt resolves to:\n  \(resolved)\n(symlinks and .. are followed before the check, always)."
            return """
                Path '\(requested)' is outside the scope this extension was configured with.\
                \(resolution)

                Readable folders: \(scope)

                This is not something to work around: the person installing the extension
                chose those folders in its settings, deliberately keeping everything else
                out of reach. Change them in Claude Desktop → Settings → Extensions.
                """

        case .pathOutOfWriteScope(let requested, let resolved, let writeRoots):
            let scope =
                writeRoots.isEmpty ? "(none configured)" : writeRoots.joined(separator: ", ")
            let resolution =
                resolved == requested
                ? "" : "\n\nIt resolves to:\n  \(resolved)\n(symlinks and .. are followed before the check, always)."
            return """
                Output path '\(requested)' is outside the folders this extension may write \
                into.\(resolution)

                Writable folders: \(scope)

                Every tool that changes a PDF writes to a new path you choose — it never \
                overwrites the file it read. Pick an output_path inside one of the folders \
                above, or change them in Claude Desktop → Settings → Extensions.
                """

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .notFound(let path):
            return "Nothing exists at '\(path)'."

        case .notAPDF(let path):
            return """
                '\(path)' could not be opened as a PDF.

                PDFKit refused it, which usually means it is not really a PDF whatever the
                extension says, or the file is truncated.
                """

        case .pdfEncrypted(let path):
            return """
                '\(path)' is password-protected and this server has no password to give it.

                PDFKit will not read a locked document. Unlock it in Preview and save an
                unlocked copy if the contents are needed.
                """

        case .noTextLayer(let path, let pageCount):
            return """
                '\(path)' has \(pageCount) page\(pageCount == 1 ? "" : "s") and no text layer at all.

                That is what a scan looks like: the pages are images of text, so there is
                nothing for PDFKit to extract. Reading it means text recognition over the
                page images, which this server does not do.
                """

        case .permissionDenied(let path, let detail):
            return """
                macOS refused access to '\(path)': \(detail)

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
            return "PDFKit returned an error: \(detail)"
        }
    }
}
