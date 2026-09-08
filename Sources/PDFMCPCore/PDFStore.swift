import Foundation

/// The seam between the tool layer and the real disk.
///
/// Everything above this protocol is exercised by the tests against an in-memory scope;
/// everything below it can only be verified against a real PDF. Keeping the boundary
/// this thin is what makes the untested surface small enough to check by hand.
///
/// Every path-taking method takes a `ScopedPath`, which cannot be constructed without
/// passing the allow-list check. `canonicalise` is the one exception: it is the step
/// that *feeds* the check, and it reads nothing but the shape of the path.
public protocol PDFStore: Sendable {

    // MARK: Resolution

    /// Expands `~`, removes `.`/`..`, and resolves every symlink in the path.
    func canonicalise(_ path: String) throws -> CanonicalPath

    // MARK: Status

    /// Whether the root is there and this process may actually look inside it.
    func probe(_ path: String) -> RootState

    // MARK: Reads

    /// `password` is tried with `unlock(withPassword:)` when the document is locked; nil
    /// or wrong leaves it locked, which `PDFContent.isEncrypted` reports rather than
    /// throws — the caller above decides whether that is an error.
    func readPDF(_ path: ScopedPath, pages: PageRange?, password: String?) throws -> PDFContent

    /// Every hit from `PDFDocument.findString`, extended to its line so it reads as a
    /// snippet. Throws `ToolError.pdfEncrypted` directly (unlike `readPDF`) rather than
    /// returning an encrypted-and-empty result: there is no partial "found nothing yet"
    /// state worth distinguishing from "could not even look".
    func searchPDF(
        _ path: ScopedPath, query: String, caseSensitive: Bool, accentSensitive: Bool,
        password: String?
    ) throws -> [PDFSearchMatch]

    /// Every annotation on every page, in page then on-page order.
    func listAnnotations(_ path: ScopedPath, password: String?) throws -> [PDFAnnotationEntry]

    /// Every Widget-subtype annotation on every page — the AcroForm fields.
    func listFormFields(_ path: ScopedPath, password: String?) throws -> [PDFFormField]

    // MARK: Writes

    /// Builds a new document by copying pages from `sources`, in order, and writes it to
    /// `output`. Returns the page count written. No source is ever modified — the sources
    /// are only ever read from.
    func mergePages(_ sources: [PDFMergeSource], to output: WriteScopedPath) throws -> Int

    /// Rotates the given pages of the document at `path` and writes the result to
    /// `output`. `path` itself is never modified.
    func rotatePages(
        _ path: ScopedPath, rotations: [PDFPageRotation], to output: WriteScopedPath
    ) throws -> Int

    /// Adds one annotation and writes the result to `output`. Returns its index on its
    /// page — the same addressing `listAnnotations`/`removeAnnotation` use.
    func addAnnotation(
        _ annotation: PDFNewAnnotation, to path: ScopedPath, output: WriteScopedPath
    ) throws -> Int

    /// Removes one annotation, addressed exactly as `listAnnotations` reports it —
    /// `(page, index)`, both within that page's own `annotations` array.
    func removeAnnotation(
        _ path: ScopedPath, page: Int, index: Int, to output: WriteScopedPath
    ) throws

    /// Highlights every occurrence of `query`, each hit becoming its own Highlight
    /// annotation covering exactly the lines it sits on. Returns the number highlighted.
    func highlightText(
        _ path: ScopedPath, query: String, caseSensitive: Bool, accentSensitive: Bool,
        color: String?, to output: WriteScopedPath
    ) throws -> Int

    /// Sets `widgetStringValue` on every widget whose `fieldName` is a key of `values`,
    /// across every page — the same string-value path PDFKit documents for text, button
    /// and choice widgets alike, so no per-kind guessing about "on"/"off" encodings is
    /// needed. A signature field is never a key that can be filled this way; skip it, not
    /// fake it. Returns the number of widgets actually set. `flatten` burns the filled
    /// appearance permanently into the page (`PDFDocumentBurnInAnnotationsOption`), after
    /// which the form is no longer editable.
    func fillForm(
        _ path: ScopedPath, values: [String: String], flatten: Bool, to output: WriteScopedPath
    ) throws -> Int

    // MARK: Security & metadata

    /// Encrypts the document. `ownerPassword` is always set (PDFKit requires it to
    /// encrypt at all); `userPassword`, if given, is required to open the file at all —
    /// omitted, the file opens freely but `permissions` still restricts what may be done
    /// with it. `permissions` is applied exactly as given, with no implicit "allow
    /// everything else" — the caller (via `Dispatch`) decides the default.
    func setPassword(
        _ path: ScopedPath, userPassword: String?, ownerPassword: String,
        permissions: Set<PDFPermission>, to output: WriteScopedPath
    ) throws

    /// Unlocks with `password` and writes a plain, unencrypted copy. Throws
    /// `ToolError.pdfEncrypted` if the password is wrong.
    func removePassword(_ path: ScopedPath, password: String, to output: WriteScopedPath) throws

    /// Merges `update` into the document's existing `documentAttributes` — only the
    /// fields `update` actually sets change; everything else (including `creator`,
    /// `producer` and the two dates, none of which are exposed for editing) is carried
    /// over untouched.
    func setMetadata(
        _ path: ScopedPath, update: PDFMetadataUpdate, to output: WriteScopedPath
    ) throws

    // MARK: Rendering & redaction

    /// Renders one page to a PNG at `output`, `scale` times its point size (2.0 ≈ 144 DPI).
    func renderPage(
        _ path: ScopedPath, page: Int, scale: Double, to output: WriteScopedPath
    ) throws

    /// For each region, paints an opaque box over every rect and then **replaces the
    /// whole page with a rasterized image of the result** — not a burned-in annotation,
    /// which would leave the original text operators intact underneath. This is the only
    /// genuinely safe redaction public PDFKit supports: the affected pages lose their
    /// text layer entirely, which is the point, not a side effect. Returns the number of
    /// pages redacted.
    func redactPages(
        _ path: ScopedPath, regions: [PDFRedactionRegion], scale: Double, to output: WriteScopedPath
    ) throws -> Int
}
