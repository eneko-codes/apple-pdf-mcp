import Foundation

/// A canonical path — `~` expanded, `..` removed, every symlink resolved — that has
/// already been checked against the allow-list.
///
/// The initialiser is `fileprivate`, so the only code in the whole module that can mint
/// one is `PathScope` below. A store method therefore cannot be reached with a path
/// nobody vetted: forgetting the check is a compile error rather than an escape, and the
/// tests cannot skip past the guard either.
public struct ScopedPath: Sendable, Equatable, Hashable {
    public let path: String
    /// Whether the leaf existed at the moment it was resolved.
    public let exists: Bool

    fileprivate init(path: String, exists: Bool) {
        self.path = path
        self.exists = exists
    }
}

/// A canonical, allow-listed **destination** for a write. Structurally identical to
/// `ScopedPath`, but a distinct type on purpose: a write handler's `output_path` parameter
/// takes a `WriteScopedPath`, so a path merely resolved for *reading* cannot be passed
/// where a write destination is required — the compiler enforces the read/write boundary,
/// not just convention.
public struct WriteScopedPath: Sendable, Equatable, Hashable {
    public let path: String
    /// Whether something already exists at this path — worth surfacing to a caller about
    /// to write there, even though no tool here refuses to overwrite: that decision is the
    /// caller's, made explicit by the path it chose to pass.
    public let exists: Bool

    fileprivate init(path: String, exists: Bool) {
        self.path = path
        self.exists = exists
    }
}

/// The allow-list, enforced — one list for reading, a second and independent one for
/// writing: a broader read scope, a narrower write scope.
///
/// This is the whole point of the server, so it is one small file with two exported
/// operations: turn a string the model wrote into a `ScopedPath` or a `WriteScopedPath`,
/// or refuse. Because both initialisers are fileprivate to *this* file, no other code in
/// the module can fabricate either — a store method that takes a path can only ever be
/// handed a path that came through here, and a read-scoped path can never satisfy a
/// write-scoped parameter.
///
/// The order matters and is not negotiable: **canonicalise first, then compare.**
/// Comparing the raw string would let `~/Documents/../../../etc` and a symlink pointing
/// out of the tree both pass a prefix test while landing somewhere else entirely.
public struct PathScope: Sendable {
    private let store: any PDFStore
    /// Roots as configured, kept for error messages: the person recognises what they
    /// typed, not its canonical form.
    private let configuredReadRoots: [String]
    private let configuredWriteRoots: [String]
    /// The same roots canonicalised once, which is what every containment test uses.
    /// `/tmp` is a symlink to `/private/tmp` on macOS, so a root compared raw would
    /// reject every path resolved through it.
    private let readRoots: [String]
    private let writeRoots: [String]

    public init(configuration: Configuration, store: any PDFStore) {
        self.store = store
        self.configuredReadRoots = configuration.readRoots
        self.configuredWriteRoots = configuration.writeRoots
        self.readRoots = configuration.readRoots.compactMap { Self.canonicalRoot($0, store: store) }
        self.writeRoots = configuration.writeRoots.compactMap {
            Self.canonicalRoot($0, store: store)
        }
    }

    /// A root that cannot be canonicalised is dropped rather than kept raw. Keeping it
    /// would mean comparing against a string no real path can ever match, which reads as
    /// a scope that exists and silently governs nothing.
    private static func canonicalRoot(_ path: String, store: any PDFStore) -> String? {
        guard let canonical = try? store.canonicalise(path) else { return nil }
        return normalise(canonical.path)
    }

    /// Drops a trailing slash so `/Users/x/Docs/` and `/Users/x/Docs` are one root. The
    /// filesystem root itself keeps its slash — there is nothing left to drop.
    private static func normalise(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    /// True when `candidate` is the root itself or lies underneath it.
    ///
    /// The separator in the prefix is what stops `/Users/user/Documents-old` from
    /// matching the root `/Users/user/Documents`. A bare `hasPrefix` is the classic way
    /// this check is got wrong.
    static func contains(root: String, candidate: String) -> Bool {
        if candidate == root { return true }
        let boundary = root.hasSuffix("/") ? root : root + "/"
        return candidate.hasPrefix(boundary)
    }

    public var hasReadRoots: Bool { !readRoots.isEmpty }
    public var hasWriteRoots: Bool { !writeRoots.isEmpty }

    /// Canonicalise, then check. The only door to a `ScopedPath`.
    public func resolve(_ raw: String) throws -> ScopedPath {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: "path", reason: "it is empty")
        }
        guard hasReadRoots else { throw ToolError.noReadRootsConfigured }

        let canonical = try store.canonicalise(trimmed)
        let path = Self.normalise(canonical.path)

        guard readRoots.contains(where: { Self.contains(root: $0, candidate: path) }) else {
            throw ToolError.pathOutOfScope(
                requested: trimmed, resolved: path, readRoots: configuredReadRoots)
        }
        return ScopedPath(path: path, exists: canonical.exists)
    }

    /// Canonicalise, then check against the write list. The only door to a
    /// `WriteScopedPath` — every mutating tool's `output_path` goes through this, never
    /// through `resolve`.
    public func resolveForWrite(_ raw: String) throws -> WriteScopedPath {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: "output_path", reason: "it is empty")
        }
        guard hasWriteRoots else { throw ToolError.noWriteRootsConfigured }

        let canonical = try store.canonicalise(trimmed)
        let path = Self.normalise(canonical.path)

        guard writeRoots.contains(where: { Self.contains(root: $0, candidate: path) }) else {
            throw ToolError.pathOutOfWriteScope(
                requested: trimmed, resolved: path, writeRoots: configuredWriteRoots)
        }
        return WriteScopedPath(path: path, exists: canonical.exists)
    }

    /// Probes every configured read root, for `pdf_status`. The canonical form is carried
    /// alongside when it differs, because a symlinked root governs a subtree nobody
    /// typed and that is worth seeing before it surprises someone.
    public func probeRoots() -> [RootProbe] {
        Self.probe(configuredReadRoots, store: store)
    }

    /// The write-scope counterpart to `probeRoots()`, same rendering, same reasoning.
    public func probeWriteRoots() -> [RootProbe] {
        Self.probe(configuredWriteRoots, store: store)
    }

    private static func probe(_ configuredRoots: [String], store: any PDFStore) -> [RootProbe] {
        configuredRoots.map { raw in
            let canonical = (try? store.canonicalise(raw)).map { Self.normalise($0.path) }
            return RootProbe(
                path: raw, state: store.probe(canonical ?? raw),
                canonicalPath: canonical == raw ? nil : canonical)
        }
    }
}
