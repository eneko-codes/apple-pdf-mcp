import Foundation
import MCP

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
public enum ToolCatalog {

    public static let statusName = "pdf_status"
    public static let readName = "pdf_read"
    public static let searchName = "pdf_search"
    public static let listAnnotationsName = "pdf_list_annotations"
    public static let listFormFieldsName = "pdf_list_form_fields"
    public static let mergePagesName = "pdf_merge_pages"
    public static let rotatePagesName = "pdf_rotate_pages"
    public static let addAnnotationName = "pdf_add_annotation"
    public static let removeAnnotationName = "pdf_remove_annotation"
    public static let highlightTextName = "pdf_highlight_text"
    public static let fillFormName = "pdf_fill_form"
    public static let setPasswordName = "pdf_set_password"
    public static let removePasswordName = "pdf_remove_password"
    public static let setMetadataName = "pdf_set_metadata"
    public static let renderPageName = "pdf_render_page"
    public static let redactPagesName = "pdf_redact_pages"

    public static func all() -> [Tool] {
        [
            status, read, search, listAnnotations, listFormFields, mergePages, rotatePages,
            addAnnotation, removeAnnotation, highlightText, fillForm,
            setPassword, removePassword, setMetadata,
            renderPage, redactPages,
        ]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    /// `type` is the single string `"string"`, never `["string", "null"]`. Claude
    /// Desktop's schema sanitiser drops a property whose `type` is a union and hands the
    /// model a bare `{}` in its place.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func boolean(_ description: String, default def: Bool) -> Value {
        .object([
            "type": .string("boolean"), "description": .string(description), "default": .bool(def),
        ])
    }

    private static func integer(
        _ description: String, minimum: Int, maximum: Int, default def: Int
    ) -> Value {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum), "default": .int(def),
        ])
    }

    /// The no-default sibling of the helper above, for a bare integer inside an array
    /// `items` schema — a "default" makes no sense for one element of a list the caller
    /// must supply explicitly.
    private static func integer(_ description: String, minimum: Int, maximum: Int) -> Value {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum),
        ])
    }

    /// An integer restricted to an explicit set of values — used for a rotation in
    /// degrees, where anything off that list crashes PDFKit rather than merely being
    /// wrong. The schema restriction is the first line of defence; `SystemPDFStore`
    /// validates again before ever calling PDFKit, since a schema is advisory only.
    private static func integerEnum(_ description: String, values: [Int]) -> Value {
        .object([
            "type": .string("integer"), "description": .string(description),
            "enum": .array(values.map { .int($0) }),
        ])
    }

    private static func array(_ description: String, items: Value) -> Value {
        .object(["type": .string("array"), "description": .string(description), "items": items])
    }

    private static func number(_ description: String) -> Value {
        .object(["type": .string("number"), "description": .string(description)])
    }

    private static func number(_ description: String, default def: Double) -> Value {
        .object([
            "type": .string("number"), "description": .string(description), "default": .double(def),
        ])
    }

    private static func stringEnum(_ description: String, values: [String]) -> Value {
        .object([
            "type": .string("string"), "description": .string(description),
            "enum": .array(values.map { .string($0) }),
        ])
    }

    /// An object whose keys are caller-chosen (field names) and whose values are all
    /// strings — `object(properties:)` above is for a fixed, known set of properties and
    /// does not fit this shape.
    private static func stringMap(_ description: String) -> Value {
        .object([
            "type": .string("object"), "description": .string(description),
            "additionalProperties": .object(["type": .string("string")]),
        ])
    }

    private static let colorHelp =
        "\"#RRGGBB\" hex color. Omit for this server's own default for the annotation kind."

    private static let pathHelp = """
        Absolute path, or one starting with ~. It is canonicalised — ~ expanded, .. \
        removed, symlinks followed — and then checked against the configured folders \
        before anything happens.
        """

    private static let outputPathHelp = """
        Absolute path, or one starting with ~, for the new file this tool writes. Checked \
        against the writable folders, which are configured independently from the \
        readable ones. This never overwrites a file the tool read from — pick a different \
        path, or the same one deliberately if that is what you want.
        """

    // MARK: Tools

    static let status = Tool(
        name: statusName,
        title: "PDF scope and permissions",
        description: """
            Reports which folders this server may read and whether macOS is actually \
            letting it reach them. Reads no file contents.

            Call it first in any session that will touch PDFs, and again whenever \
            pdf_read fails: it separates "outside the configured scope" from "macOS \
            refused", which are two different problems with two different fixes.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    private static let passwordHelp =
        "The document's password, if it has one. Omit for a PDF that isn't protected."

    static let read = Tool(
        name: readName,
        title: "Read a PDF",
        description: """
            Extracts text from a PDF with PDFKit, page by page, plus its outline \
            (bookmarks) and document metadata — title, author, subject, keywords, producer \
            and dates.

            Page numbers are 1-based, as printed. A PDF with no text layer at all is a \
            scan: this tool says so explicitly instead of returning empty pages, rather \
            than guessing. A password-protected PDF is refused unless the correct password \
            is given.

            The outline is independent of the page range — asking for page 1 alone costs \
            exactly as much as asking for the whole document, because the outline is \
            always returned in full. On a long compendium that outline can itself run to \
            thousands of entries, which is too large a response to be useful. Pass \
            'outline_query' to search the outline by title instead of reading it whole: \
            that is the way to find one entry's page number in a document too large to \
            list. An unfiltered outline past \(Format.maxOutlineEntriesWithoutQuery) \
            entries is truncated with a note rather than returned in full — narrow with \
            'outline_query' rather than reading around the limit.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to read. \(pathHelp)"),
                "include_outline": boolean(
                    "Include the document's bookmark outline.", default: true),
                "outline_query": string(
                    """
                    Filter the outline to entries whose title contains this text \
                    (case-insensitive), instead of every entry. Use this on any document \
                    whose outline might be large — it costs nothing extra to try, returns \
                    only the matches, and is what makes it possible to locate one \
                    article's page number in a document with thousands of bookmarks \
                    without the response itself becoming too large. Implies wanting the \
                    outline even if 'include_outline' says otherwise. If 'first_page'/\
                    'last_page' are also omitted, only page 1's text comes back alongside \
                    the filtered outline rather than the whole document's — this is a \
                    lookup for a page number, not a request to also read that many pages; \
                    pass 'first_page'/'last_page' explicitly to get text back in the same call.
                    """),
                "first_page": integer(
                    """
                    First page to extract, 1-based and inclusive. Omit for page 1, or to \
                    leave the choice to 'outline_query' when that's also given.
                    """, minimum: 1, maximum: 10_000),
                "last_page": integer(
                    """
                    Last page to extract, 1-based and inclusive. Omit for the last page, \
                    or to leave the choice to 'outline_query' when that's also given.
                    """, minimum: 1, maximum: 10_000),
                "password": string(passwordHelp),
            ],
            required: ["path"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let search = Tool(
        name: searchName,
        title: "Search a PDF",
        description: """
            Finds every occurrence of a string in a PDF with PDFKit's own search, and \
            returns each hit's page number plus the full line it appears on — not just \
            the bare matched word.

            A multi-word phrase is matched even where the document wraps it across a line \
            break: PDFKit's own search would miss that, since the page's text holds a real \
            newline where you typed a space, so each space is retried as a break when the \
            phrase is not found as typed. A phrase wrapping at two points at once is still \
            missed — search a single distinctive word if a long phrase finds nothing.

            Case- and accent-insensitive by default, which matters more than it sounds: \
            one document often spells the same term two ways — "resume" in one section and \
            "résumé" in another. An accent-exact search then finds one set of occurrences \
            or the other, never both, while reporting a count that looks complete. Set \
            accent_sensitive to tell them apart deliberately.

            A password-protected PDF is refused unless the correct password is given.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to search. \(pathHelp)"),
                "query": string("Text to find."),
                "case_sensitive": boolean("Match case exactly.", default: false),
                "accent_sensitive": boolean(
                    "Treat accented and unaccented letters as different.", default: false),
                "password": string(passwordHelp),
            ],
            required: ["path", "query"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let listAnnotations = Tool(
        name: listAnnotationsName,
        title: "List a PDF's annotations",
        description: """
            Lists every annotation already on a PDF — highlights, sticky notes, free text, \
            shapes, links, form widgets and so on — with its page, type, contents, author \
            and position. Reads only; it does not add, remove or change anything.

            Each entry's page + index is what pdf_remove_annotation needs to address it. \
            Note that a sticky note appears as TWO entries: the "Text" annotation itself \
            and a paired "Popup" carrying the same contents — PDFKit creates the pair, \
            and pdf_remove_annotation removes both together when given the Text one. \
            A password-protected PDF is refused unless the correct password is given.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to inspect. \(pathHelp)"),
                "password": string(passwordHelp),
            ],
            required: ["path"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let listFormFields = Tool(
        name: listFormFieldsName,
        title: "List a PDF's form fields",
        description: """
            Lists every AcroForm field (text box, checkbox, radio button, choice list or \
            signature field) in a PDF, with its name, kind, current value and whether it \
            is read-only. Reads only; it does not fill in or change anything.

            A PDF with no form has an empty result, not an error. A password-protected PDF \
            is refused unless the correct password is given.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to inspect. \(pathHelp)"),
                "password": string(passwordHelp),
            ],
            required: ["path"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let mergePages = Tool(
        name: mergePagesName,
        title: "Merge, reorder, extract or delete PDF pages",
        description: """
            Builds a new PDF by copying pages from one or more source PDFs, in the exact \
            order given. One tool covers several jobs depending on what is passed:

            - Merge: list more than one source.
            - Reorder: list one source's pages out of their natural order.
            - Extract or split: list one source with only the pages wanted.
            - Delete pages: list one source, omitting the pages to drop.

            Always writes a new PDF; no source is ever modified. Listing the same page \
            number twice within a source is not a guaranteed way to duplicate it — that \
            behavior is unverified. A password-protected source is refused; there is \
            nowhere to put a password for a merge source yet.
            """,
        inputSchema: object(
            properties: [
                "sources": array(
                    "Sources to combine, in the order their pages should appear in the result.",
                    items: object(
                        properties: [
                            "path": string("PDF to take pages from. \(pathHelp)"),
                            "pages": array(
                                "1-based page numbers to take from this source, in the order to use them. Omit for every page of this source, in its own order.",
                                items: integer(
                                    "Page number, 1-based.", minimum: 1, maximum: 100_000)),
                        ],
                        required: ["path"])),
                "output_path": string(outputPathHelp),
            ],
            required: ["sources", "output_path"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
    )

    static let rotatePages = Tool(
        name: rotatePagesName,
        title: "Rotate PDF pages",
        description: """
            Rotates specific pages of a PDF and writes the result to a new file; the \
            source is never modified. Rotation is clockwise and must be a multiple of 90 \
            degrees — PDFKit has no notion of any other angle. A password-protected \
            source is refused; there is nowhere to put a password here yet.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to rotate pages of. \(pathHelp)"),
                "rotations": array(
                    "Which pages to rotate and by how much.",
                    items: object(
                        properties: [
                            "page": integer(
                                "1-based page number.", minimum: 1, maximum: 100_000),
                            "degrees": integerEnum(
                                "Rotation in degrees, clockwise.",
                                values: [90, 180, 270, -90, -180, -270]),
                        ],
                        required: ["page", "degrees"])),
                "output_path": string(outputPathHelp),
            ],
            required: ["path", "rotations", "output_path"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
    )

    static let addAnnotation = Tool(
        name: addAnnotationName,
        title: "Add an annotation to a PDF",
        description: """
            Adds one annotation to a page and writes the result to a new file; the source \
            is never modified. Covers highlight, underline, strike_out (text markup drawn \
            over the given rectangle — for highlighting text you already know the wording \
            of, pdf_highlight_text is usually easier), note (a classic sticky note), \
            free_text (a text box drawn on the page), and square/circle (shapes, \
            optionally filled).

            Not covered: freehand ink drawing, line annotations and image stamps — none \
            has a natural shape for a tool argument to specify, so none is offered rather \
            than offered badly.

            Coordinates are in PDF page space: points, origin at the page's bottom-left — \
            the same space pdf_list_annotations reports existing annotations in.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to annotate. \(pathHelp)"),
                "page": integer("1-based page number.", minimum: 1, maximum: 100_000),
                "kind": stringEnum(
                    "Kind of annotation.",
                    values: [
                        "highlight", "underline", "strike_out", "note", "free_text", "square",
                        "circle",
                    ]),
                "x": number("Left edge, in points from the page's left edge."),
                "y": number("Bottom edge, in points from the page's bottom edge."),
                "width": number("Width in points."),
                "height": number("Height in points."),
                "contents": string(
                    "Text content — the note text for \"note\", the text shown for \"free_text\". Ignored for the other kinds."
                ),
                "color": string(colorHelp),
                "interior_color": string(
                    "\"#RRGGBB\" fill color. Only used for \"square\"/\"circle\"; omit for no fill."
                ),
                "output_path": string(outputPathHelp),
            ],
            required: ["path", "page", "kind", "x", "y", "width", "height", "output_path"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )

    static let removeAnnotation = Tool(
        name: removeAnnotationName,
        title: "Remove an annotation from a PDF",
        description: """
            Removes one annotation and writes the result to a new file; the source is \
            never modified. Addressed exactly as pdf_list_annotations reports it: the \
            page number and the index within that page's own list — call \
            pdf_list_annotations first to find both.

            Removing a sticky note ("Text") also removes its paired "Popup" entry, since \
            that popup holds a copy of the same text; you do not need to remove it \
            separately.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to remove an annotation from. \(pathHelp)"),
                "page": integer("1-based page number.", minimum: 1, maximum: 100_000),
                "index": integer(
                    "Index within that page's annotations, from pdf_list_annotations.",
                    minimum: 0, maximum: 100_000),
                "output_path": string(outputPathHelp),
            ],
            required: ["path", "page", "index", "output_path"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )

    static let highlightText = Tool(
        name: highlightTextName,
        title: "Highlight every occurrence of a search term",
        description: """
            Finds every occurrence of a string with the same search pdf_search uses, and \
            adds a Highlight annotation over each one — following the actual text across \
            line breaks rather than covering the whitespace between lines with one \
            rectangle. Writes the result to a new file; the source is never modified.

            A phrase the document wraps mid-way is both found and highlighted correctly, \
            typed the natural way with a space: the highlight becomes one shape per line, \
            hugging the text.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to highlight text in. \(pathHelp)"),
                "query": string("Text to find and highlight."),
                "case_sensitive": boolean("Match case exactly.", default: false),
                "accent_sensitive": boolean(
                    "Treat accented and unaccented letters as different.", default: false),
                "color": string(colorHelp),
                "output_path": string(outputPathHelp),
            ],
            required: ["path", "query", "output_path"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
    )

    static let fillForm = Tool(
        name: fillFormName,
        title: "Fill in a PDF's form fields",
        description: """
            Sets values on a PDF's AcroForm fields by name and writes the result to a new \
            file; the source is never modified. Call pdf_list_form_fields first to see \
            what field names exist and what kind each one is.

            The same string-value assignment works for text fields, checkboxes/radio \
            buttons and choice fields alike — for a checkbox or radio button, pass the \
            field's own on-state value (visible via pdf_list_form_fields) to select it, or \
            "Off" to clear it. Selecting one option of a radio group turns the group's \
            other options off, as it should; note the reported count is per widget, so a \
            radio group of two options reports 2 fields set, not 1. Every name in fields must match an existing field, or the \
            call is refused naming which one didn't. Signature fields cannot be filled \
            this way — there is no public API for a real signature — and are skipped even \
            if named.

            flatten burns the filled-in values permanently into the page and removes the \
            editable widgets — irreversible, and appropriate once the form is finished, \
            not while it might still need changes.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF whose form to fill. \(pathHelp)"),
                "fields": stringMap(
                    "Field name → value to set. Every name must exist in the document's form."
                ),
                "flatten": boolean(
                    "Burn the values in permanently and remove the editable widgets.",
                    default: false),
                "output_path": string(outputPathHelp),
            ],
            required: ["path", "fields", "output_path"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
    )

    static let setPassword = Tool(
        name: setPasswordName,
        title: "Password-protect a PDF",
        description: """
            Encrypts a PDF and writes the result to a new file; the source is never \
            modified. Give at least one of user_password (required to open the file at \
            all) or owner_password (required to change permissions or remove protection; \
            defaults to user_password if not given separately — PDFKit requires an owner \
            password to encrypt at all). Omitting user_password leaves the file openable \
            by anyone, protected only by the permissions below.

            permissions lists what is ALLOWED once opened; omit it to allow everything \
            (the common case — just requiring a password to open). Pass an empty list to \
            deny everything listed. printing_high implies printing_low; document_changes \
            implies commenting and form_field_entry; content_copying implies \
            content_accessibility; commenting implies form_field_entry — granting the \
            broader right grants the narrower one it lists, same as PDFKit itself.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to protect. \(pathHelp)"),
                "user_password": string("Password required to open the file. Optional."),
                "owner_password": string(
                    "Password required to change permissions or remove protection. Defaults to user_password if omitted."
                ),
                "permissions": array(
                    "What to allow once opened. Omit for \"allow everything\"; pass [] to deny everything listed here.",
                    items: stringEnum(
                        "Permission to allow.",
                        values: [
                            "printing_low", "printing_high", "document_changes",
                            "document_assembly", "content_copying", "content_accessibility",
                            "commenting", "form_field_entry",
                        ])),
                "output_path": string(outputPathHelp),
            ],
            required: ["path", "output_path"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
    )

    static let removePassword = Tool(
        name: removePasswordName,
        title: "Remove a PDF's password protection",
        description: """
            Unlocks a PDF with the given password and writes a plain, unencrypted copy; \
            the source is never modified. Refused if the password is wrong.
            """,
        inputSchema: object(
            properties: [
                "path": string("Protected PDF to unlock. \(pathHelp)"),
                "password": string(passwordHelp),
                "output_path": string(outputPathHelp),
            ],
            required: ["path", "password", "output_path"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
    )

    static let setMetadata = Tool(
        name: setMetadataName,
        title: "Edit a PDF's metadata",
        description: """
            Sets title, author, subject and/or keywords on a PDF's document metadata and \
            writes the result to a new file; the source is never modified. Every field is \
            independent and optional — omitted fields keep their existing value, there is \
            no way to clear a field to empty through this tool. creator, producer and the \
            two dates are not editable here; PDFKit manages them itself on write.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF whose metadata to edit. \(pathHelp)"),
                "title": string("New title. Omit to leave unchanged."),
                "author": string("New author. Omit to leave unchanged."),
                "subject": string("New subject. Omit to leave unchanged."),
                "keywords": array(
                    "New keyword list, replacing the existing one entirely. Omit to leave unchanged.",
                    items: string("One keyword.")),
                "output_path": string(outputPathHelp),
            ],
            required: ["path", "output_path"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
    )

    static let renderPage = Tool(
        name: renderPageName,
        title: "Render a PDF page to an image",
        description: """
            Renders one page to a PNG image and writes it to output_path — a snapshot of \
            the page exactly as it displays, annotations included. scale multiplies the \
            page's own point size; 2.0 (the default) is roughly 144 DPI, comfortable for \
            reading on screen. The source PDF is never modified — this only ever produces \
            a new image file.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to render a page from. \(pathHelp)"),
                "page": integer("1-based page number.", minimum: 1, maximum: 100_000),
                "scale": number(
                    "Multiplier on the page's point size. 2.0 ≈ 144 DPI.", default: 2.0),
                "output_path": string("Where to write the PNG. \(outputPathHelp)"),
            ],
            required: ["path", "page", "output_path"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
    )

    static let redactPages = Tool(
        name: redactPagesName,
        title: "Redact regions of a PDF",
        description: """
            Genuinely redacts — not just covers — the given rectangles on the given \
            pages, and writes the result to a new file; the source is never modified. \
            Painting an opaque box over text and leaving the underlying page content \
            stream intact is not redaction: the original text is still there, extractable \
            by any tool that ignores what is drawn on top of it. This tool instead paints \
            the boxes and then rasterizes each affected page whole, replacing it with a \
            plain image. That is the only way public PDFKit can make removal genuinely \
            irreversible.

            The trade-off, stated plainly: every page listed in regions loses its text \
            layer entirely, not just the redacted rectangles — pdf_search and pdf_read \
            will no longer find or extract text on those specific pages afterward. Pages \
            not listed are untouched, text layer included. scale controls the \
            redacted pages' image resolution; 2.0 (the default) is roughly 144 DPI.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to redact. \(pathHelp)"),
                "regions": array(
                    "Pages to redact and the rectangles to black out on each. Every page listed becomes image-only, not just the listed rectangles.",
                    items: object(
                        properties: [
                            "page": integer(
                                "1-based page number.", minimum: 1, maximum: 100_000),
                            "rects": array(
                                "Rectangles to black out on this page, in page-space points.",
                                items: object(
                                    properties: [
                                        "x": number("Left edge, in points from the page's left edge."),
                                        "y": number(
                                            "Bottom edge, in points from the page's bottom edge."),
                                        "width": number("Width in points."),
                                        "height": number("Height in points."),
                                    ],
                                    required: ["x", "y", "width", "height"])),
                        ],
                        required: ["page", "rects"])),
                "scale": number(
                    "Multiplier on each redacted page's point size. 2.0 ≈ 144 DPI.",
                    default: 2.0),
                "output_path": string(outputPathHelp),
            ],
            required: ["path", "regions", "output_path"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
    )
}
