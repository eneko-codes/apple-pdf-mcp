import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool hands `notices` to `Format`, which puts them before the data.
///
/// Absent and `null` mean the same: not given. A value of the wrong type is refused with
/// the form expected, never ignored.
public final class Arguments {
    private let values: [String: Value]

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    /// Refuses an argument the tool's schema does not list, naming the ones it does. Without
    /// this, a call that still uses a renamed or misspelled argument would run without it.
    public func requireOnly(_ allowed: [String]) throws {
        let unknown = values.keys.filter { !allowed.contains($0) }.sorted()
        guard !unknown.isEmpty else { return }
        throw ToolError.unknownArguments(unknown, allowed: allowed)
    }

    /// The same check for the members of an object inside an argument.
    static func requireOnly(_ fields: [String: Value], in context: String, allowed: [String])
        throws
    {
        let unknown = fields.keys.filter { !allowed.contains($0) }.sorted()
        guard !unknown.isEmpty else { return }
        throw ToolError.unknownArguments(unknown, allowed: allowed, in: context)
    }

    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = given(name) else { throw ToolError.missingArgument(name) }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    /// A string the caller may legitimately omit — absence and blank both read as nil,
    /// never as an empty-string value to act on. Used for `password`, among others: never
    /// pass what this returns into a `ToolError` message, since a wrong password
    /// shouldn't come back to the model verbatim in the error it triggered.
    public func optionalString(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) throws -> Bool {
        guard let raw = given(name) else { return fallback }
        guard let flag = raw.boolValue else {
            throw ToolError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    private func wholeNumber(_ name: String) throws -> Int? {
        guard let raw = given(name) else { return nil }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return number
    }

    /// A quantity: a size, a count, a skip. Outside its range it is moved to the nearest
    /// allowed value, and `notices` gains the sentence that says which value was used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let number = try wholeNumber(name) else { return fallback }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// An identifier: a page number or the index of an annotation. Outside its range it is
    /// refused, not moved, because the nearest value would name something else.
    public func optionalIdentifier(_ name: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let number = try wholeNumber(name) else { return nil }
        try Self.check(number, named: name, in: range)
        return number
    }

    public func requiredIdentifier(_ name: String, in range: ClosedRange<Int>) throws -> Int {
        guard let number = try optionalIdentifier(name, in: range) else {
            throw ToolError.missingArgument(name)
        }
        return number
    }

    static func check(_ number: Int, named name: String, in range: ClosedRange<Int>) throws {
        guard range.contains(number) else {
            throw ToolError.badArgument(
                name: name,
                reason: "a whole number from \(range.lowerBound) to \(range.upperBound) was expected"
            )
        }
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (
        limit: Int, offset: Int
    ) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: ToolCatalog.offsetRange)
        )
    }

    /// A page-space coordinate. Deliberately accepts either JSON representation: `Value`
    /// decodes a whole number like `100` as `.int`, not `.double`, and a caller has no way
    /// to force the decimal point that would change that.
    public func optionalDouble(_ name: String) throws -> Double? {
        guard let raw = given(name) else { return nil }
        return try Self.number(raw, named: name)
    }

    public func requiredDouble(_ name: String) throws -> Double {
        guard let raw = given(name) else { throw ToolError.missingArgument(name) }
        return try Self.number(raw, named: name)
    }

    static func number(_ raw: Value, named name: String) throws -> Double {
        guard let value = raw.doubleValue, value.isFinite else {
            throw ToolError.badArgument(name: name, reason: "a number was expected")
        }
        return value
    }

    // MARK: Collections

    /// A flat `{name: value}` object argument, every value required to be a string — the
    /// shape `pdf_fill_form`'s `fields` argument takes.
    public func requiredStringMap(_ name: String) throws -> [String: String] {
        guard let raw = given(name) else { throw ToolError.missingArgument(name) }
        guard case .object(let fields) = raw else {
            throw ToolError.badArgument(name: name, reason: "an object was expected")
        }
        guard !fields.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        var result: [String: String] = [:]
        for (key, value) in fields {
            guard let string = value.stringValue else {
                throw ToolError.badArgument(
                    name: name,
                    reason: "the value for '\(ToolStandard.echo(key))' must be a string")
            }
            result[key] = string
        }
        return result
    }

    /// The elements of an array argument the caller may omit, distinct from an explicit
    /// empty array: omitted means "use the default", `[]` means "deliberately nothing".
    public func optionalArray(_ name: String) throws -> [Value]? {
        guard let raw = given(name) else { return nil }
        guard case .array(let array) = raw else {
            throw ToolError.badArgument(name: name, reason: "a list was expected")
        }
        return array
    }

    /// The raw elements of an array argument, unparsed, refused when absent or empty.
    /// Callers with a structured shape parse each element themselves.
    public func requiredArray(_ name: String) throws -> [Value] {
        guard let array = try optionalArray(name) else { throw ToolError.missingArgument(name) }
        guard !array.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return array
    }

    // MARK: Pages

    /// `first_page`/`last_page`, 1-based and inclusive. Returns nil when neither was
    /// given, which `pdf_read` reads as "no range chosen". A range that ends before it
    /// starts is refused.
    /// `lastGiven` tells whether the caller named an end, so that an end past the document
    /// is reported only when it was asked for.
    public func pageRange() throws -> (range: PageRange, lastGiven: Bool)? {
        let first = try optionalIdentifier("first_page", in: ToolCatalog.pageNumberRange)
        let last = try optionalIdentifier("last_page", in: ToolCatalog.pageNumberRange)
        guard first != nil || last != nil else { return nil }
        let lower = first ?? 1
        let upper = last ?? ToolCatalog.pageNumberRange.upperBound
        guard upper >= lower else {
            throw ToolError.badArgument(
                name: "last_page", reason: "it is before first_page (\(lower))")
        }
        return (PageRange(first: lower, last: upper), last != nil)
    }
}
