import Foundation

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

    // Bounds. Every limit a schema, a description or the instructions states is one of these
    // constants, and the code enforces the same one. Each row maximum is a number of
    // ordinary rows that fits `ToolStandard.longestResult` with room to spare, and each
    // default makes a call with no optional argument about `ToolStandard.usualPage` or
    // less; `BoundsTests` renders a full page of the widest ordinary rows to hold both.

    /// How many rows or characters a call may skip.
    public static let offsetRange = 0...10_000_000

    /// A page number, as printed. An identifier: outside this range it is refused, never
    /// moved, because the nearest page would be another page.
    public static let pageNumberRange = 1...100_000
    /// The position of an annotation within its page. Also an identifier.
    public static let annotationIndexRange = 0...100_000

    public static let outlineLimitRange = 1...100
    public static let defaultOutlineLimit = 25
    public static let searchLimitRange = 1...200
    public static let defaultSearchLimit = 50
    public static let annotationLimitRange = 1...100
    public static let defaultAnnotationLimit = 25
    public static let formFieldLimitRange = 1...100
    public static let defaultFormFieldLimit = 25

    /// The window on the text of `pdf_read`. The maximum leaves room in the same result
    /// for the metadata and a full page of outline entries; `Format.pdf` halves a window
    /// whose characters still take more UTF-16 units than a result may hold.
    public static let maxCharactersRange = 1...16_000
    public static let defaultMaxCharacters = ToolStandard.usualPage

    /// Widths a long field is clipped to inside a row or a metadata block.
    public static let metadataValueWidth = 400
    public static let outlineTitleWidth = 120
    public static let searchLineWidth = 160
    public static let annotationContentsWidth = 150
    public static let annotationAuthorWidth = 40
    public static let fieldNameWidth = 80
    public static let fieldValueWidth = 120

    /// A render or redaction scale. A scale is a decimal, which `Notice.adjusted` cannot
    /// word, so a value outside the range is refused with the range, not moved.
    public static let scaleRange = 0.1...8.0
    public static let defaultScale = 2.0

    /// The rotations PDFKit accepts and the schema offers, clockwise.
    public static let rotationDegrees = [90, 180, 270, -90, -180, -270]

    public static let annotationTypeWidth = 40

    /// The longest a call may run before it is abandoned. Well inside
    /// `ToolStandard.timeLimit`, so the answer is this server's and not the client's
    /// generic "no result".
    public static let callTimeout = Duration.seconds(60)

    /// Every property name `name` accepts, read from its own schema so the schema is the
    /// one list and a call cannot use an argument it does not advertise.
    static func argumentNames(of name: String) -> [String] {
        guard let tool = all().first(where: { $0.name == name }),
            case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return [] }
        return properties.keys.sorted()
    }

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

    private static func scaleProperty(_ description: String) -> Value {
        .object([
            "type": .string("number"),
            "description": .string(
                "\(description) From \(scaleRange.lowerBound) to \(scaleRange.upperBound); a "
                    + "value outside that is refused."),
            "minimum": .double(scaleRange.lowerBound), "maximum": .double(scaleRange.upperBound),
            "default": .double(defaultScale),
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

    private static func limitProperty(
        _ things: String, range: ClosedRange<Int>, default fallback: Int, order: String
    ) -> Value {
        integer(
            "How many \(things) to return, \(range.lowerBound)–\(range.upperBound). Ordered \(order).",
            minimum: range.lowerBound, maximum: range.upperBound, default: fallback)
    }

    private static func offsetProperty(_ things: String) -> Value {
        integer(
            "How many \(things) to skip, to reach the next page of them.",
            minimum: offsetRange.lowerBound, maximum: offsetRange.upperBound, default: 0)
    }

    static let read = Tool(
        name: readName,
        title: "Read a PDF",
        description: """
            Returns: the document metadata, up to \(defaultOutlineLimit) outline (bookmark) \
            entries, and a window of \(defaultMaxCharacters) characters from the start of \
            the text of the pages chosen (all pages unless first_page and last_page say \
            otherwise), each page headed by its number. What the result does not hold is announced in its \
            first lines, with the arguments that return it.

            Text: first_page and last_page (1-based, both included) choose the pages; \
            character_offset and max_characters (at most \(maxCharactersRange.upperBound)) \
            read through them in windows. Pass character_offset=<last> as announced for the \
            next window.

            Outline: it is independent of the page range. limit (at most \
            \(outlineLimitRange.upperBound)) and offset page its entries in document order, \
            and outline_query keeps only the entries whose title contains a text, which is \
            how to find one entry's page number in a document with thousands of bookmarks. \
            With outline_query and no page range, only page 1's text comes back. \
            include_outline=false leaves the outline out.

            Metadata values are cut at \(metadataValueWidth) characters and outline titles \
            at \(outlineTitleWidth); the rest of a cut value cannot be read through this \
            server. A PDF with no text layer at all is a scan: this tool says so instead of \
            returning empty pages. A password-protected PDF is refused unless the correct \
            password is given.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to read. \(pathHelp)"),
                "include_outline": boolean(
                    "Include the document's bookmark outline.", default: true),
                "outline_query": string(
                    """
                    Keep only the outline entries whose title contains this text \
                    (case-insensitive). Use it on any document whose outline might be large. \
                    Implies wanting the outline even if 'include_outline' is false. If \
                    'first_page'/'last_page' are omitted, only page 1's text comes back \
                    alongside the matches; pass them to read other pages in the same call.
                    """),
                "limit": limitProperty(
                    "outline entries", range: outlineLimitRange, default: defaultOutlineLimit,
                    order: "as in the document"),
                "offset": offsetProperty("outline entries"),
                "first_page": integer(
                    "First page to extract, 1-based and inclusive. Omit for page 1.",
                    minimum: pageNumberRange.lowerBound, maximum: pageNumberRange.upperBound),
                "last_page": integer(
                    """
                    Last page to extract, 1-based and inclusive. Omit for the last page of \
                    the document. A value past the last page is moved to it and reported.
                    """, minimum: pageNumberRange.lowerBound, maximum: pageNumberRange.upperBound
                ),
                "character_offset": integer(
                    "How many characters of the chosen pages' text to skip.",
                    minimum: offsetRange.lowerBound, maximum: offsetRange.upperBound, default: 0),
                "max_characters": integer(
                    "The most characters of text to return.",
                    minimum: maxCharactersRange.lowerBound,
                    maximum: maxCharactersRange.upperBound, default: defaultMaxCharacters),
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
            Returns the first \(defaultSearchLimit) occurrences of a string in a PDF, in \
            document order, each as its page number and the line it appears on, cut at \
            \(searchLineWidth) characters. The result says how many exist in all. limit (at \
            most \(searchLimitRange.upperBound)) and offset reach the rest.

            A multi-word phrase is matched even where the document wraps it across a line \
            break: each space is retried as a break when the phrase is not found as typed. A \
            phrase wrapping at two points at once is still missed; search one distinctive \
            word if a long phrase finds nothing.

            Case- and accent-insensitive by default, so "resume" and "résumé" are found \
            together; an accent-exact search finds one set or the other while reporting a \
            count that looks complete. Set accent_sensitive to tell them apart.

            A password-protected PDF is refused unless the correct password is given.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to search. \(pathHelp)"),
                "query": string("Text to find."),
                "case_sensitive": boolean("Match case exactly.", default: false),
                "accent_sensitive": boolean(
                    "Treat accented and unaccented letters as different.", default: false),
                "limit": limitProperty(
                    "occurrences", range: searchLimitRange, default: defaultSearchLimit,
                    order: "as they appear in the document"),
                "offset": offsetProperty("occurrences"),
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
            Returns the first \(defaultAnnotationLimit) annotations already on a PDF — \
            highlights, sticky notes, free text, shapes, links, form widgets — ordered by \
            page and then by index on the page, each with its type, author, contents and \
            position. The result says how many exist in all. limit (at most \
            \(annotationLimitRange.upperBound)) and offset reach the rest. Contents are cut \
            at \(annotationContentsWidth) characters and authors at \
            \(annotationAuthorWidth); the rest of a cut value cannot be read through this \
            server. Reads only.

            Each entry's page and index are what pdf_remove_annotation needs. A sticky note \
            appears as TWO entries: the "Text" annotation and a paired "Popup" carrying the \
            same contents; pdf_remove_annotation removes both when given the Text one. A \
            password-protected PDF is refused unless the correct password is given.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to inspect. \(pathHelp)"),
                "limit": limitProperty(
                    "annotations", range: annotationLimitRange, default: defaultAnnotationLimit,
                    order: "by page, then by index on the page"),
                "offset": offsetProperty("annotations"),
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
            Returns the first \(defaultFormFieldLimit) AcroForm fields of a PDF — text box, \
            checkbox, radio button, choice list or signature field — ordered by page and \
            then by index on the page, each with its name, kind, current value and whether \
            it is read-only. The result says how many exist in all. limit (at most \
            \(formFieldLimitRange.upperBound)) and offset reach the rest. Names are cut at \
            \(fieldNameWidth) characters and values at \(fieldValueWidth); the rest of a cut \
            value cannot be read through this server. Reads only.

            A PDF with no form has an empty result, not an error. A password-protected PDF \
            is refused unless the correct password is given.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to inspect. \(pathHelp)"),
                "limit": limitProperty(
                    "form fields", range: formFieldLimitRange, default: defaultFormFieldLimit,
                    order: "by page, then by index on the page"),
                "offset": offsetProperty("form fields"),
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
                                    "Page number, 1-based.", minimum: pageNumberRange.lowerBound, maximum: pageNumberRange.upperBound)),
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
                                "1-based page number.", minimum: pageNumberRange.lowerBound, maximum: pageNumberRange.upperBound),
                            "degrees": integerEnum(
                                "Rotation in degrees, clockwise.",
                                values: rotationDegrees),
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
                "page": integer("1-based page number.", minimum: pageNumberRange.lowerBound, maximum: pageNumberRange.upperBound),
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
                "page": integer("1-based page number.", minimum: pageNumberRange.lowerBound, maximum: pageNumberRange.upperBound),
                "index": integer(
                    "Index within that page's annotations, from pdf_list_annotations.",
                    minimum: annotationIndexRange.lowerBound, maximum: annotationIndexRange.upperBound),
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
            page's own point size, from \(scaleRange.lowerBound) to \(scaleRange.upperBound); \
            \(defaultScale) (the default) is roughly 144 DPI, comfortable for \
            reading on screen. The source PDF is never modified — this only ever produces \
            a new image file.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to render a page from. \(pathHelp)"),
                "page": integer("1-based page number.", minimum: pageNumberRange.lowerBound, maximum: pageNumberRange.upperBound),
                "scale": scaleProperty("Multiplier on the page's point size. 2.0 ≈ 144 DPI."),
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
            redacted pages' image resolution, from \(scaleRange.lowerBound) to \
            \(scaleRange.upperBound); \(defaultScale) (the default) is roughly 144 DPI.
            """,
        inputSchema: object(
            properties: [
                "path": string("PDF to redact. \(pathHelp)"),
                "regions": array(
                    "Pages to redact and the rectangles to black out on each. Every page listed becomes image-only, not just the listed rectangles.",
                    items: object(
                        properties: [
                            "page": integer(
                                "1-based page number.", minimum: pageNumberRange.lowerBound, maximum: pageNumberRange.upperBound),
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
                "scale": scaleProperty("Multiplier on each redacted page's point size. 2.0 ≈ 144 DPI."),
                "output_path": string(outputPathHelp),
            ],
            required: ["path", "regions", "output_path"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
    )
}
