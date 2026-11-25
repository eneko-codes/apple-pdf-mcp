import Foundation

public enum PDFMCPServer {

    public static let name = "apple-pdf-mcp"
    public static let version = "1.1.0"

    /// Returned from `initialize`. It leads with what a call returns and how to reach the
    /// rest, because a client may show only its start; the rules that cannot be put on one
    /// tool follow. Sizes come from `ToolCatalog`, never from literals.
    public static let instructions = """
        Reads and edits PDFs on this Mac through PDFKit. No network, no text recognition.

        HOW RESULTS ARE BOUNDED. Every listing returns one page and says, in its first \
        lines, how many exist and the exact argument that returns the next page: limit and \
        offset. pdf_read returns a window of text: first_page and last_page choose pages, \
        character_offset and max_characters read through them. A number outside its range \
        is moved and reported; a page number or index outside its range is refused. An \
        argument a tool does not list is refused.

        pdf_read: the metadata, up to \(ToolCatalog.defaultOutlineLimit) outline entries \
        and a window of \(ToolCatalog.defaultMaxCharacters) characters from the start of the \
        text of all pages (with outline_query and no page range, page 1 only). A scan \
        (no text layer) is reported, not returned as empty pages. outline_query keeps the \
        outline entries whose title contains a text: the way to find a page number in a \
        long document. Metadata values are cut at \(ToolCatalog.metadataValueWidth) \
        characters and outline titles at \(ToolCatalog.outlineTitleWidth), and the rest of \
        a cut value cannot be read here.

        pdf_search: occurrences in document order, \(ToolCatalog.defaultSearchLimit) by \
        default, each with its page and its line. Case- and accent-insensitive by default \
        ("resume" finds "résumé"); accent_sensitive tells them apart. pdf_list_annotations \
        and pdf_list_form_fields: \(ToolCatalog.defaultAnnotationLimit) rows by default, \
        by page and index; call pdf_list_form_fields before pdf_fill_form.

        SCOPES. Two independent lists of folders, chosen by whoever installed the \
        extension: one may be READ, a narrower one WRITTEN. Paths are canonicalised (~ \
        expanded, .. removed, symlinks followed) and then checked; a path outside its list \
        is refused. Call pdf_status first: it reports both lists and whether macOS lets \
        this process reach them.

        WRITING. Every tool that changes a PDF takes output_path, writes a NEW file there \
        and never touches its source. pdf_merge_pages builds a PDF from pages of one or \
        more sources (merge, reorder, extract, split, delete) and drops the metadata. \
        pdf_rotate_pages turns pages by multiples of 90 degrees. pdf_add_annotation adds a \
        highlight, underline, strike_out, note, free_text, square or circle; \
        pdf_highlight_text highlights every occurrence of a text, following line breaks. \
        pdf_remove_annotation takes (page, index) as pdf_list_annotations shows them; a \
        sticky note is two entries and both go. pdf_fill_form sets fields by name \
        (flatten=true is irreversible; signature fields are skipped). pdf_set_metadata \
        changes title, author, subject, keywords. pdf_render_page writes one page as a PNG.

        PASSWORDS. pdf_read, pdf_search and the two listings take the document's password \
        as `password`, and pdf_remove_password needs it; the other writing tools take none and \
        refuse a protected source. \
        pdf_set_password encrypts (omit permissions to allow everything, [] to deny all); \
        pdf_remove_password writes an unlocked copy.

        REDACTION. pdf_redact_pages paints the rectangles and then rasterizes each page \
        listed, whole: that page loses its entire text layer, so pdf_search and pdf_read \
        find nothing on it afterward. Redact last. Painting a box alone is not redaction.

        No tool signs a PDF: public PDFKit has no API for a cryptographic signature.

        A call that runs longer than \(Int(ToolCatalog.callTimeout.components.seconds)) \
        seconds is abandoned; for a tool that writes, the change may still have been made.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing in
    /// this function opens a file by itself.
    public static func run(
        store: any PDFStore = SystemPDFStore(),
        configuration: Configuration = Configuration()
    ) async {
        Diagnostics.started(version: version)
        await serveStandardStreams(
            handler: handler(tools: PDFTools(store: store, configuration: configuration)))
    }

    public static func handler(tools: PDFTools) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions,
            catalog: ToolCatalog.all(), tools: tools)
    }
}
