import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
public struct Arguments {
    private let values: [String: Value]

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        values[name]?.boolValue ?? fallback
    }

    /// A string the caller may legitimately omit — absence and blank both read as nil,
    /// never as an empty-string value to act on. Used for `password`, among others: never
    /// pass what this returns into a `ToolError` message, since a wrong password
    /// shouldn't come back to the model verbatim in the error it triggered.
    public func optionalString(_ name: String) -> String? {
        guard let raw = values[name]?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func requiredInt(_ name: String) throws -> Int {
        guard let raw = values[name] else { throw ToolError.missingArgument(name) }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return number
    }

    /// An integer the caller may legitimately omit, where the absence means "no bound"
    /// rather than a default value.
    public func optionalInt(_ name: String) throws -> Int? {
        guard let raw = values[name] else { return nil }
        if case .null = raw { return nil }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return number
    }

    /// A page-space coordinate. Deliberately accepts either JSON representation: `Value`
    /// decodes a whole number like `100` as `.int`, not `.double`, and a caller (model or
    /// otherwise) has no way to force the decimal point that would change that — rejecting
    /// `.int` here would refuse the overwhelmingly common case of a whole-number rect.
    /// The optional sibling of `requiredDouble` — nil means "use the caller's own
    /// default", same convention as `optionalInt`.
    public func optionalDouble(_ name: String) throws -> Double? {
        guard let raw = values[name] else { return nil }
        if case .null = raw { return nil }
        if let value = raw.doubleValue { return value }
        if let value = raw.intValue { return Double(value) }
        throw ToolError.badArgument(name: name, reason: "a number was expected")
    }

    public func requiredDouble(_ name: String) throws -> Double {
        guard let raw = values[name] else { throw ToolError.missingArgument(name) }
        if let value = raw.doubleValue { return value }
        if let value = raw.intValue { return Double(value) }
        throw ToolError.badArgument(name: name, reason: "a number was expected")
    }

    /// A flat `{name: value}` object argument, every value required to be a string — the
    /// shape `pdf_fill_form`'s `fields` argument takes.
    public func requiredStringMap(_ name: String) throws -> [String: String] {
        guard case .object(let fields)? = values[name] else { throw ToolError.missingArgument(name) }
        guard !fields.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        var result: [String: String] = [:]
        for (key, value) in fields {
            guard let string = value.stringValue else {
                throw ToolError.badArgument(
                    name: name, reason: "the value for '\(key)' must be a string")
            }
            result[key] = string
        }
        return result
    }

    /// The raw elements of an array argument the caller may omit, distinct from an
    /// explicit empty array — omitted means "use the default", `[]` means "deliberately
    /// nothing", and a caller (like `pdf_set_password`'s `permissions`) needs to tell
    /// those apart. `requiredArray` below refuses both alike, which is right for a list
    /// that means nothing sensible when empty (`sources`, `rotations`), but wrong here.
    public func optionalArray(_ name: String) -> [Value]? {
        guard case .array(let array)? = values[name] else { return nil }
        return array
    }

    /// The raw elements of an array argument, unparsed. Callers with a structured shape
    /// (a list of `{path, pages}` sources, a list of `{page, degrees}` rotations) parse
    /// each element themselves — there is no single shape general enough to lift into a
    /// shared helper here without it being harder to read than the parsing it replaces.
    public func requiredArray(_ name: String) throws -> [Value] {
        guard case .array(let array)? = values[name] else { throw ToolError.missingArgument(name) }
        guard !array.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return array
    }

    // MARK: Pages

    /// `first_page`/`last_page`, 1-based and inclusive. Returns nil when neither was
    /// given, which the tools read as "the whole document".
    public func pageRange() throws -> PageRange? {
        let first = try optionalInt("first_page")
        let last = try optionalInt("last_page")
        guard first != nil || last != nil else { return nil }
        let lower = Swift.max(first ?? 1, 1)
        let upper = Swift.max(last ?? Int.max, lower)
        guard upper >= lower else {
            throw ToolError.badArgument(
                name: "last_page", reason: "it is before 'first_page'")
        }
        return PageRange(first: lower, last: upper)
    }
}
