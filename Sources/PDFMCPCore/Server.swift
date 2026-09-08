import Foundation
import MCP

public enum PDFMCPServer {

    public static let name = "apple-pdf-mcp"
    public static let version = "1.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: the allow-list(s), which tool answers which kind of question, and the fact
    /// that a scan needs a different tool entirely.
    public static let instructions = """
        Reads PDFs on this Mac through PDFKit. No Finder, no Apple events, no network.

        TWO INDEPENDENT SCOPES: a list of folders that may be READ and a separate, \
        narrower list of folders that may be WRITTEN into, each chosen by the person who \
        installed the extension. Being allowed to read a folder's PDFs does not by itself \
        allow writing into it. Every path is canonicalised — ~ expanded, .. removed, \
        symlinks followed — and then checked against the matching list before anything \
        happens. A path outside its list is refused and the error names the configured \
        scope. Call pdf_status first: it reports both lists and whether macOS is actually \
        letting this process reach them.

        pdf_read extracts a PDF's text, page by page, plus its outline (bookmarks) and \
        document metadata — title, author, subject, keywords, producer and dates. A PDF \
        with no text layer at all is a scan: pdf_read says so explicitly instead of \
        returning empty pages. Reading the pixels is text recognition, which this server \
        does not do.

        The outline is returned in full regardless of the page range asked for, so a long \
        compendium's outline can itself be too large a response to be useful. Pass \
        outline_query to search it by title instead of reading it whole — the way to find \
        one entry's page number without the response becoming enormous.

        pdf_search finds every occurrence of a string and returns the whole line each hit \
        sits on, not just the bare word. It is case- AND accent-insensitive by default, \
        because one document often spells a term two ways — "resume" in one place and \
        "résumé" in another — and an accent-exact search finds one set or the other while \
        reporting a count that looks complete. Pass accent_sensitive to tell them apart. \
        A phrase the document wraps across a line break is still matched. \
        pdf_list_annotations reports every highlight, \
        note, shape and link already on a PDF; pdf_list_form_fields reports every AcroForm \
        field, its current value and whether it is read-only — call this before trying to \
        fill a form.

        A password-protected PDF is refused by every read tool above unless the correct \
        password is given as that tool's own `password` argument.

        pdf_merge_pages and pdf_rotate_pages write: both require `output_path`, checked \
        against the WRITE scope, and never touch the file(s) they read. pdf_merge_pages \
        builds a new PDF from one or more sources' pages, in the order given — the one \
        primitive behind merging several files, reordering one file's pages, \
        extracting/splitting a subset, and deleting pages by omitting them. \
        pdf_rotate_pages rotates specific pages by a multiple of 90 degrees.

        pdf_add_annotation adds a highlight, underline, strike_out, note (sticky note), \
        free_text (text box) or square/circle (optionally filled) to a page — freehand \
        ink, line and stamp annotations are not offered, since none has a natural shape \
        for a tool argument. pdf_remove_annotation removes one, addressed exactly as \
        pdf_list_annotations reports it: (page, index) — note that a sticky note is TWO \
        entries, the Text annotation and a paired Popup holding the same contents, and \
        removing the Text one removes both. pdf_highlight_text is the easier path for the \
        common case — search for text and highlight every occurrence, following the actual \
        line breaks rather than one rectangle per match.

        pdf_fill_form sets values on AcroForm fields by name — the same string-value \
        assignment for text fields, checkboxes/radio buttons and choice fields alike, so \
        call pdf_list_form_fields first to see each field's kind and its on-state value \
        for a checkbox/radio button. Every name in `fields` must exist or the call is \
        refused, naming which one didn't. Signature fields are skipped even if named: no \
        public API fills one meaningfully. `flatten` burns the values in permanently and \
        removes the editable widgets — irreversible.

        None of the seven tools above accepts a password yet, so a protected source is \
        refused by all of them.

        pdf_set_password encrypts a PDF: give user_password (needed to open it), \
        owner_password (needed to change permissions or remove protection — defaults to \
        user_password if not given separately), or both. permissions lists what stays \
        allowed once opened; omit it to allow everything, pass [] to deny everything \
        listed. pdf_remove_password unlocks with a password and writes a plain copy; \
        wrong password is refused. pdf_set_metadata changes title/author/subject/keywords \
        — every field optional and independent, omitted fields keep their existing value, \
        creator/producer/dates stay PDFKit's own.

        pdf_render_page renders one page to a PNG — a snapshot exactly as it displays, \
        annotations included. pdf_redact_pages is the one tool worth reading twice before \
        using: it does NOT merely paint over the given rectangles. Painting an opaque box \
        while leaving the page's underlying content stream intact is not redaction — the \
        original text is still there underneath, extractable by anything that ignores \
        what's drawn on top. Instead, every page listed in `regions` is rasterized whole \
        after the boxes are painted, replacing it with a plain image. The trade-off, \
        stated plainly: a redacted page loses its ENTIRE text layer, not just the boxed \
        rectangles — pdf_search and pdf_read will find nothing on that page afterward. \
        Pages not listed keep their text layer untouched. That trade-off is the price of \
        the redaction actually being real; there is no middle option in public PDFKit.

        That is the full tool set. Two things public PDFKit itself cannot do, so no tool \
        here pretends to: a real cryptographic signature (no public API attaches one — \
        pdf_fill_form skips a signature field rather than faking it), and true redaction \
        without the whole-page rasterization trade-off above.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing in
    /// this function opens a file by itself.
    public static func run(
        store: any PDFStore = SystemPDFStore(),
        configuration: Configuration = Configuration()
    ) async throws {
        let tools = PDFTools(store: store, configuration: configuration)
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.all()) }
        await server.withMethodHandler(CallTool.self) { await tools.handle($0) }

        // The default StdioTransport logger is a no-op handler. Leave it that way: a
        // logger writing to stdout would interleave with the JSON-RPC stream and break
        // every response after the first log line.
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
