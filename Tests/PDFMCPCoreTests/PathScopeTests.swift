import Foundation
import Testing

@testable import PDFMCPCore

/// A `PDFStore` that only knows how to canonicalise.
///
/// `PathScope` is the one thing in this module worth proving exhaustively, and it needs
/// exactly one store method: everything else exists so the type conforms. `readPDF`
/// throws rather than returning something plausible — a scope test that accidentally
/// reached a real file should fail loudly, not quietly pass.
///
/// Canonicalisation is modelled rather than performed: the map below says what each raw
/// path resolves to, which is how a symlink pointing out of the allow-list can be
/// expressed without creating one on the real filesystem.
struct StubStore: PDFStore {

    /// raw path → where it really lands. Anything absent resolves to itself.
    var resolutions: [String: String] = [:]
    var existing: Set<String> = []

    func canonicalise(_ path: String) throws -> CanonicalPath {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = resolutions[expanded] ?? (expanded as NSString).standardizingPath
        return CanonicalPath(path: resolved, exists: existing.contains(resolved))
    }

    func probe(_ path: String) -> RootState { .reachable }

    func readPDF(_ path: ScopedPath, pages: PageRange?, password: String?) throws -> PDFContent {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }

    func searchPDF(
        _ path: ScopedPath, query: String, caseSensitive: Bool, accentSensitive: Bool,
        password: String?
    ) throws -> [PDFSearchMatch] {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }

    func listAnnotations(_ path: ScopedPath, password: String?) throws -> [PDFAnnotationEntry] {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }

    func listFormFields(_ path: ScopedPath, password: String?) throws -> [PDFFormField] {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }

    func mergePages(_ sources: [PDFMergeSource], to output: WriteScopedPath) throws -> Int {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }

    func rotatePages(
        _ path: ScopedPath, rotations: [PDFPageRotation], to output: WriteScopedPath
    ) throws -> Int {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }

    func addAnnotation(
        _ annotation: PDFNewAnnotation, to path: ScopedPath, output: WriteScopedPath
    ) throws -> Int {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }

    func removeAnnotation(
        _ path: ScopedPath, page: Int, index: Int, to output: WriteScopedPath
    ) throws {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }

    func highlightText(
        _ path: ScopedPath, query: String, caseSensitive: Bool, accentSensitive: Bool,
        color: String?, to output: WriteScopedPath
    ) throws -> Int {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }

    func fillForm(
        _ path: ScopedPath, values: [String: String], flatten: Bool, to output: WriteScopedPath
    ) throws -> Int {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }

    func setPassword(
        _ path: ScopedPath, userPassword: String?, ownerPassword: String,
        permissions: Set<PDFPermission>, to output: WriteScopedPath
    ) throws {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }

    func removePassword(_ path: ScopedPath, password: String, to output: WriteScopedPath) throws {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }

    func setMetadata(
        _ path: ScopedPath, update: PDFMetadataUpdate, to output: WriteScopedPath
    ) throws {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }

    func renderPage(
        _ path: ScopedPath, page: Int, scale: Double, to output: WriteScopedPath
    ) throws {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }

    func redactPages(
        _ path: ScopedPath, regions: [PDFRedactionRegion], scale: Double, to output: WriteScopedPath
    ) throws -> Int {
        throw ToolError.storeFailure("a scope test reached a file, which it must never do")
    }
}

/// The safety property this whole server exists for: a path outside the configured roots
/// must never resolve, however it is spelled.
@Suite("Path scope")
struct PathScopeTests {

    private func scope(
        read: [String] = ["/Users/invented/Documents", "/Users/invented/Code"],
        write: [String] = [],
        resolutions: [String: String] = [:]
    ) -> PathScope {
        var configuration = Configuration()
        configuration.readRoots = read
        configuration.writeRoots = write
        return PathScope(configuration: configuration, store: StubStore(resolutions: resolutions))
    }

    @Test("A path inside a read root resolves")
    func insideReadRootResolves() throws {
        let resolved = try scope().resolve("/Users/invented/Documents/report.pdf")
        #expect(resolved.path == "/Users/invented/Documents/report.pdf")
    }

    @Test("A read root itself resolves")
    func rootItselfResolves() throws {
        let resolved = try scope().resolve("/Users/invented/Documents")
        #expect(resolved.path == "/Users/invented/Documents")
    }

    @Test("A path outside every read root is refused")
    func outsideReadRootIsRefused() {
        #expect(throws: ToolError.self) {
            try scope().resolve("/Users/invented/Library/Keychains")
        }
    }

    /// The reason canonicalisation happens before comparison. Compared raw, this string
    /// starts with a read root and would pass a prefix test while landing in the home
    /// directory.
    @Test("Dot-dot cannot climb out of a read root")
    func dotDotCannotEscape() {
        #expect(throws: ToolError.self) {
            try scope().resolve("/Users/invented/Documents/../../../etc/passwd")
        }
    }

    /// The other half of the same rule. A symlink inside an allowed root that points
    /// somewhere else entirely must be judged by where it lands, not by its own path.
    @Test("A symlink pointing out of the scope is judged by where it lands")
    func symlinkOutOfScopeIsRefused() {
        let escaping = scope(resolutions: [
            "/Users/invented/Documents/shortcut": "/Users/invented/Library/Secrets"
        ])
        #expect(throws: ToolError.self) {
            try escaping.resolve("/Users/invented/Documents/shortcut")
        }
    }

    /// `/tmp` is a symlink to `/private/tmp` on macOS, so a root compared in its raw form
    /// would reject every path that resolved through it. The roots are canonicalised too.
    @Test("A root that is itself a symlink still governs its subtree")
    func symlinkedRootStillGoverns() throws {
        var configuration = Configuration()
        configuration.readRoots = ["/tmp/invented"]
        let store = StubStore(resolutions: [
            "/tmp/invented": "/private/tmp/invented",
            "/tmp/invented/file.pdf": "/private/tmp/invented/file.pdf",
        ])
        let pathScope = PathScope(configuration: configuration, store: store)

        let resolved = try pathScope.resolve("/tmp/invented/file.pdf")
        #expect(resolved.path == "/private/tmp/invented/file.pdf")
    }

    /// A sibling whose name merely begins with a root's name is not inside it.
    @Test("A prefix match on the name alone is not containment")
    func siblingWithSharedPrefixIsRefused() {
        #expect(throws: ToolError.self) {
            try scope().resolve("/Users/invented/Documents-private/secret.pdf")
        }
    }

    @Test("With no read roots nothing resolves at all")
    func noReadRootsRefusesEverything() {
        let empty = scope(read: [])
        #expect(throws: ToolError.self) { try empty.resolve("/Users/invented") }
    }

    @Test("An empty path is refused")
    func emptyPathIsRefused() {
        #expect(throws: ToolError.self) { try scope().resolve("   ") }
    }

    // MARK: Write scope

    /// The write scope's own equivalent of the read tests above: same mechanics, same
    /// guarantees, deliberately proven separately rather than assumed from the read tests
    /// passing, since the two lists are independently configured and independently wired.

    @Test("A path inside a write root resolves for writing")
    func insideWriteRootResolvesForWrite() throws {
        let resolved = try scope(write: ["/Users/invented/Output"])
            .resolveForWrite("/Users/invented/Output/report.pdf")
        #expect(resolved.path == "/Users/invented/Output/report.pdf")
    }

    @Test("A path outside every write root is refused for writing")
    func outsideWriteRootIsRefusedForWrite() {
        #expect(throws: ToolError.self) {
            try scope(write: ["/Users/invented/Output"]).resolveForWrite(
                "/Users/invented/Library/Keychains")
        }
    }

    @Test("With no write roots nothing resolves for writing at all")
    func noWriteRootsRefusesEverything() {
        #expect(throws: ToolError.self) {
            try scope().resolveForWrite("/Users/invented/Documents/report.pdf")
        }
    }

    /// The property that makes this a genuine second scope rather than an alias for the
    /// first: a path readable through `read_roots` is not automatically writable just
    /// because it happens to sit under a folder Claude may read.
    @Test("A read root is not implicitly a write root")
    func readRootIsNotImplicitlyWritable() throws {
        let mixed = scope(
            read: ["/Users/invented/Documents"], write: ["/Users/invented/Output"])

        let readable = try mixed.resolve("/Users/invented/Documents/report.pdf")
        #expect(readable.path == "/Users/invented/Documents/report.pdf")

        #expect(throws: ToolError.self) {
            try mixed.resolveForWrite("/Users/invented/Documents/report.pdf")
        }
    }

    @Test("An empty output path is refused")
    func emptyOutputPathIsRefused() {
        #expect(throws: ToolError.self) {
            try scope(write: ["/Users/invented/Output"]).resolveForWrite("   ")
        }
    }
}
