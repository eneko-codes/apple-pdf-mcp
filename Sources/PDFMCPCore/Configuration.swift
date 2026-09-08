import Foundation

/// Settings the person installing the extension can change.
///
/// These arrive as command-line arguments because that is how a Claude extension passes
/// `user_config`: the manifest substitutes `${user_config.key}` into `mcp_config.args`.
/// Parsing is hand-rolled rather than pulling in an argument-parsing package — the whole
/// surface is one setting, and every dependency in this repo has to earn its place.
public struct Configuration: Sendable, Equatable {

    /// Folders Claude may read PDFs from. Not a default a caller can widen — a boundary.
    ///
    /// **Empty means nothing is reachable, not everything.** A server that does nothing
    /// until it is configured is a nuisance for one minute; one that starts with the home
    /// directory in scope is a different kind of program entirely.
    public var readRoots: [String] = []

    /// Folders Claude may write PDFs and images into — a second, independent boundary,
    /// a broader read scope and a narrower write scope. Deliberately
    /// not defaulted to `readRoots`: being allowed to see a folder's PDFs says nothing
    /// about being allowed to leave new files in it, and "unconfigured" must still mean
    /// "unreachable", exactly as `readRoots` has always meant.
    public var writeRoots: [String] = []

    public init() {}

    /// True when an argument is an unsubstituted manifest placeholder.
    ///
    /// Claude Desktop leaves `${user_config.key}` untouched when the person left that
    /// setting empty, so the literal text arrives as an argument. Observed live in the
    /// calendar server: an empty `multiple: true` list produced a bare
    /// `${user_config.calendars}`.
    ///
    /// Taking those at face value is worse than ignoring them: a read-root list would
    /// come to contain one folder nobody has, and every real path would fall out of
    /// scope with an error blaming the caller.
    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("${") && trimmed.hasSuffix("}")
    }

    /// `--read-roots`/`--write-roots`, then every bare argument until the next flag.
    ///
    /// A `multiple: true` user_config expands to one bare argument per value, so a
    /// repeated `--read-root` flag is not available: the values arrive loose, in place,
    /// ending at the next token starting with `--`. Unknown flags are ignored rather
    /// than fatal — a server that will not launch is much harder to diagnose than one
    /// running on a default.
    public static func parse(_ arguments: [String]) -> Configuration {
        var configuration = Configuration()
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--read-roots":
                let (values, next) = consumeValues(arguments, after: index)
                configuration.readRoots = values
                index = next
            case "--write-roots":
                let (values, next) = consumeValues(arguments, after: index)
                configuration.writeRoots = values
                index = next
            default:
                index += 1
            }
        }
        return configuration
    }

    private static func consumeValues(_ arguments: [String], after index: Int) -> ([String], Int)
    {
        var values: [String] = []
        var cursor = index + 1
        while cursor < arguments.count, !arguments[cursor].hasPrefix("--") {
            let value = arguments[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !isPlaceholder(value) { values.append(value) }
            cursor += 1
        }
        return (values, cursor)
    }
}
