import Foundation

/// Value types crossing the store seam. Nothing here imports a filesystem or PDFKit API,
/// which is what lets the tests build a scope in memory.

// MARK: - Paths

/// The result of canonicalising a raw path string, before any scope check.
public struct CanonicalPath: Sendable, Equatable {
    public let path: String
    public let exists: Bool

    public init(path: String, exists: Bool) {
        self.path = path
        self.exists = exists
    }
}

// `ScopedPath` deliberately lives in PathScope.swift instead: its initialiser is
// fileprivate, so that file is the only place in the module able to mint one.

/// An inclusive, 1-based page range. PDF page numbers are what a person reads off the
/// page, not an array index, and the off-by-one is worth spending a type on.
public struct PageRange: Sendable, Equatable {
    public let first: Int
    public let last: Int

    public init(first: Int, last: Int) {
        self.first = first
        self.last = last
    }

    public func clamped(to pageCount: Int) -> PageRange {
        PageRange(
            first: Swift.max(1, Swift.min(first, pageCount)),
            last: Swift.max(1, Swift.min(last, pageCount)))
    }
}

// MARK: - Content

public struct PDFContent: Sendable, Equatable {
    public struct Page: Sendable, Equatable {
        public let number: Int
        public let text: String

        public init(number: Int, text: String) {
            self.number = number
            self.text = text
        }
    }

    public struct OutlineEntry: Sendable, Equatable {
        public let level: Int
        public let title: String
        public let page: Int?

        public init(level: Int, title: String, page: Int?) {
            self.level = level
            self.title = title
            self.page = page
        }
    }

    public let pageCount: Int
    public let pages: [Page]
    public let outline: [OutlineEntry]
    /// Title, author, subject, keywords, producer, creation and modification dates —
    /// whatever the document actually carries, in the order PDFKit reports it.
    public let metadata: [(String, String)]
    public let isEncrypted: Bool

    public init(
        pageCount: Int, pages: [Page], outline: [OutlineEntry], metadata: [(String, String)],
        isEncrypted: Bool
    ) {
        self.pageCount = pageCount
        self.pages = pages
        self.outline = outline
        self.metadata = metadata
        self.isEncrypted = isEncrypted
    }

    /// A scanned PDF has pages and no text at all. Reported rather than guessed at, so
    /// the caller is told to try vision_ocr instead of concluding the file is empty.
    public var hasTextLayer: Bool { pages.contains { !$0.text.isEmpty } }

    public static func == (lhs: PDFContent, rhs: PDFContent) -> Bool {
        lhs.pageCount == rhs.pageCount && lhs.pages == rhs.pages && lhs.outline == rhs.outline
            && lhs.isEncrypted == rhs.isEncrypted
            && lhs.metadata.map(\.0) == rhs.metadata.map(\.0)
            && lhs.metadata.map(\.1) == rhs.metadata.map(\.1)
    }
}

// MARK: - Search

/// One hit from `PDFDocument.findString`, extended to its line boundaries so it reads as
/// a snippet rather than a bare word.
public struct PDFSearchMatch: Sendable, Equatable {
    public let page: Int
    public let text: String

    public init(page: Int, text: String) {
        self.page = page
        self.text = text
    }
}

// MARK: - Annotations

/// One entry from a page's `annotations` array. `index` is the position within that
/// page's own array — stable for the lifetime of one open document — so a later "remove
/// this annotation" tool can address it as `(page, index)` without inventing an identifier
/// PDFKit itself has no notion of.
public struct PDFAnnotationEntry: Sendable, Equatable {
    public let page: Int
    public let index: Int
    /// The PDF /Subtype name PDFKit reports — "Highlight", "Text", "FreeText", "Widget",
    /// "Link", "Square", "Ink", and so on. Not an enum: the PDF spec's own annotation
    /// subtype list is open-ended, and passing the string through verbatim is more honest
    /// than pretending this server recognises every one of them.
    public let type: String
    public let contents: String?
    public let author: String?
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(
        page: Int, index: Int, type: String, contents: String?, author: String?, x: Double,
        y: Double, width: Double, height: Double
    ) {
        self.page = page
        self.index = index
        self.type = type
        self.contents = contents
        self.author = author
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - Form fields

/// One AcroForm widget annotation, read across every page. `index` mirrors
/// `PDFAnnotationEntry.index`: the widget's position within its own page's `annotations`
/// array, which is what a future "fill this field" tool needs alongside `name` — a form
/// can legally have fields that share a name, or none at all.
public struct PDFFormField: Sendable, Equatable {
    public let page: Int
    public let index: Int
    public let name: String?
    /// "text", "button" (push button, checkbox or radio — PDFKit does not split these
    /// further), "choice" or "signature", straight from `PDFAnnotationWidgetSubtype`.
    public let kind: String
    public let value: String?
    public let isReadOnly: Bool

    public init(
        page: Int, index: Int, name: String?, kind: String, value: String?, isReadOnly: Bool
    ) {
        self.page = page
        self.index = index
        self.name = name
        self.kind = kind
        self.value = value
        self.isReadOnly = isReadOnly
    }
}

// MARK: - Page assembly

/// One source document's pages to copy into a merged result, in the order given.
/// `pages: nil` means every page of this source, in its own natural order. Listing the
/// same source more than once, or the same page number twice within one source, is not a
/// guaranteed way to duplicate a page — PDFKit's own behavior for that is unverified here.
public struct PDFMergeSource: Sendable, Equatable {
    public let path: ScopedPath
    public let pages: [Int]?

    public init(path: ScopedPath, pages: [Int]?) {
        self.path = path
        self.pages = pages
    }
}

/// One page's requested rotation, in degrees clockwise. Must be a multiple of 90 —
/// `PDFPage.rotation`'s setter raises an Objective-C exception for anything else, which
/// Swift's `try`/`catch` cannot intercept, so this is validated before ever reaching
/// PDFKit, not just documented.
public struct PDFPageRotation: Sendable, Equatable {
    public let page: Int
    public let degrees: Int

    public init(page: Int, degrees: Int) {
        self.page = page
        self.degrees = degrees
    }
}

// MARK: - Adding annotations

/// The annotation kinds this server knows how to build. Not the whole PDF spec's list —
/// Ink (freehand paths) and Line have no natural shape for a model to specify, and Stamp
/// needs an image; all three are left out rather than half-supported. `PDFOutline`,
/// `PDFPage.thumbnail`, and other native-but-unrelated concepts stay out on purpose too.
public enum PDFAnnotationKind: String, Sendable, Equatable {
    case highlight
    case underline
    case strikeOut = "strike_out"
    /// A classic sticky note (PDF /Text subtype), not a free-standing text box.
    case note
    /// A text box drawn directly on the page (PDF /FreeText subtype).
    case freeText = "free_text"
    case square
    case circle
}

/// What `pdf_add_annotation` needs to build one. `x`/`y`/`width`/`height` are page-space
/// points (PDF's own unit, origin at the page's bottom-left) — the same space
/// `PDFAnnotationEntry`'s bounds are already reported in, so a caller can round-trip a
/// listed annotation's position back into a new one.
public struct PDFNewAnnotation: Sendable, Equatable {
    public let page: Int
    public let kind: PDFAnnotationKind
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let contents: String?
    /// "#RRGGBB". Nil means this server's own default for the kind, not "no color" —
    /// PDFKit annotations without an appearance stream need a color to draw with at all.
    public let color: String?
    /// Fill color for square/circle; ignored for every other kind.
    public let interiorColor: String?

    public init(
        page: Int, kind: PDFAnnotationKind, x: Double, y: Double, width: Double, height: Double,
        contents: String?, color: String?, interiorColor: String?
    ) {
        self.page = page
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.contents = contents
        self.color = color
        self.interiorColor = interiorColor
    }
}

// MARK: - Security

/// One of PDF's 8 owner-controlled permission bits (Adobe spec, Table 3.20), named to
/// match `PDFAccessPermissions`'s own Swift case names one-to-one — `SystemPDFStore` maps
/// each straight across, no reinterpretation.
public enum PDFPermission: String, Sendable, Equatable, CaseIterable {
    case printingLow = "printing_low"
    case printingHigh = "printing_high"
    case documentChanges = "document_changes"
    case documentAssembly = "document_assembly"
    case contentCopying = "content_copying"
    case contentAccessibility = "content_accessibility"
    case commenting = "commenting"
    case formFieldEntry = "form_field_entry"
}

// MARK: - Metadata

/// What `pdf_set_metadata` may change. Every field is independently optional: nil means
/// "leave this alone". There is deliberately no way to clear a field to empty through
/// this type — `Arguments.optionalString` already treats a blank argument as absent
/// everywhere else in this server, and a second, field-specific meaning for blank here
/// would be a trap for whoever reads this next, not a feature worth the inconsistency.
public struct PDFMetadataUpdate: Sendable, Equatable {
    public let title: String?
    public let author: String?
    public let subject: String?
    public let keywords: [String]?

    public init(title: String?, author: String?, subject: String?, keywords: [String]?) {
        self.title = title
        self.author = author
        self.subject = subject
        self.keywords = keywords
    }
}

// MARK: - Redaction

/// A page-space rectangle: points, origin at the page's bottom-left — the same space
/// `PDFAnnotationEntry` and `PDFNewAnnotation` already use.
public struct PDFPageRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One page's redaction: paint over `rects`, then discard the page's original content
/// entirely by replacing it with a rasterized image of the result. There is no partial
/// redaction of a page — either a page is in this list and becomes image-only, or it
/// isn't touched at all.
public struct PDFRedactionRegion: Sendable, Equatable {
    public let page: Int
    public let rects: [PDFPageRect]

    public init(page: Int, rects: [PDFPageRect]) {
        self.page = page
        self.rects = rects
    }
}

// MARK: - Status

/// What one configured root is actually worth right now. There is no API that asks TCC
/// "may I read this folder?", so the only honest answer comes from trying.
public enum RootState: String, Sendable, Equatable {
    case reachable
    case missing
    /// The path is there and macOS refused. This is the TCC denial, and the one the
    /// status message has to explain how to fix.
    case notPermitted
}

public struct RootProbe: Sendable, Equatable {
    public let path: String
    public let state: RootState
    /// Set when the configured root does not canonicalise to itself — a symlinked root
    /// silently governs a different subtree than the one that was typed.
    public let canonicalPath: String?

    public init(path: String, state: RootState, canonicalPath: String? = nil) {
        self.path = path
        self.state = state
        self.canonicalPath = canonicalPath
    }
}
