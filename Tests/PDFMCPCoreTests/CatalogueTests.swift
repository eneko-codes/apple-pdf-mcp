import Foundation
import MCP
import Testing

@testable import PDFMCPCore

/// Checks on the advertised surface itself. None of these open a file.
@Suite("Catalogue")
struct CatalogueTests {

    @Test("Every tool has a unique name, title and description")
    func catalogueIsWellFormed() {
        let tools = ToolCatalog.all()
        let names = tools.map(\.name)
        #expect(names.count == Set(names).count)
        for tool in tools {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    /// Claude Desktop's schema sanitiser drops a property whose `type` is a union such as
    /// `["string", "null"]` and hands the model a bare `{}` in its place. The fault is
    /// invisible until a caller happens to use that field, so the whole catalogue is
    /// walked here rather than trusted to review.
    @Test("No property declares a union type")
    func noUnionTypesInSchemas() {
        for tool in ToolCatalog.all() {
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else { continue }
            for (property, definition) in properties {
                guard case .object(let fields) = definition else { continue }
                if case .array = fields["type"] {
                    Issue.record("\(tool.name).\(property) declares a union type")
                }
            }
        }
    }

    /// Tools that only ever read: no `output_path`, nothing on disk changes. Every other
    /// tool in the catalogue is expected to mutate something and must say so. Listed by
    /// name, not inferred, so adding a new tool forces a deliberate choice here rather
    /// than silently inheriting whatever the default happens to be.
    private static let readOnlyToolNames: Set<String> = [
        ToolCatalog.statusName,
        ToolCatalog.readName,
        ToolCatalog.searchName,
        ToolCatalog.listAnnotationsName,
        ToolCatalog.listFormFieldsName,
    ]

    @Test("Read tools and mutating tools are annotated correctly, not blanket read-only")
    func toolsAreAnnotatedByWhatTheyActuallyDo() {
        for tool in ToolCatalog.all() {
            let expectedReadOnly = Self.readOnlyToolNames.contains(tool.name)
            #expect(
                tool.annotations.readOnlyHint == expectedReadOnly,
                "\(tool.name) should have readOnlyHint == \(expectedReadOnly)")
            if !expectedReadOnly {
                #expect(
                    tool.annotations.destructiveHint == true,
                    "\(tool.name) mutates a file and should declare destructiveHint")
            }
        }
    }

    /// Caught live: `first_page`/`last_page` used to declare a numeric `default`, and a
    /// caller that omits both still had them arrive filled in as `1` and `10_000` —
    /// indistinguishable at the server from someone deliberately asking for the whole
    /// document. That erased the one signal `outline_query`'s "default to page 1 unless a
    /// range was actually given" behaviour depends on. A schema `default` is fine for a
    /// field like `include_outline`, where a filled-in default and a true omission mean
    /// the same thing either way — it is specifically wrong here, so this is pinned rather
    /// than left to be rediscovered the same way.
    @Test("first_page and last_page declare no default")
    func pageRangeHasNoDefault() {
        guard case .object(let schema) = ToolCatalog.read.inputSchema,
            case .object(let properties)? = schema["properties"]
        else {
            Issue.record("pdf_read has no object schema to inspect")
            return
        }
        for name in ["first_page", "last_page"] {
            guard case .object(let fields)? = properties[name] else {
                Issue.record("pdf_read is missing a '\(name)' property")
                continue
            }
            #expect(fields["default"] == nil, "'\(name)' must not declare a default")
        }
    }

    /// The same sixteen tools are written out in four places: the name constants, `all()`,
    /// the switch in `Dispatch.swift`, and `extension/manifest.json`. Nothing makes them
    /// agree, and each way of disagreeing fails silently in its own way. These two tests
    /// are what makes them agree.

    /// A tool listed in the catalogue but missing a `case` in `Dispatch.run` advertises
    /// itself, gets a permission switch, and then refuses every call as an unknown tool.
    /// The switch's `default` swallows it, so nothing else catches this.
    @Test("Every advertised tool is actually reachable through dispatch")
    func everyToolDispatches() async {
        var configuration = Configuration()
        configuration.readRoots = ["/"]
        configuration.writeRoots = ["/"]
        let tools = PDFTools(store: RecordingStore(), configuration: configuration)

        for tool in ToolCatalog.all() {
            // Deliberately called with no arguments: a routed tool rejects those on their
            // merits ("missing required argument 'path'"), while an unrouted one cannot
            // get that far. Only the second failure is the one under test.
            let result = await tools.handle(.init(name: tool.name, arguments: [:]))
            guard case .text(let message, _, _)? = result.content.first else {
                Issue.record("\(tool.name) returned no text at all")
                continue
            }
            #expect(
                !message.contains("is not a tool of this server"),
                "\(tool.name) is in the catalogue but has no case in Dispatch.run")
        }
    }

    /// Claude Desktop builds the per-tool permission switches from `manifest.json` alone,
    /// before this server has ever run. A tool missing from it ships with no switch; a
    /// tool listed there but absent from the catalogue shows a switch that governs
    /// nothing. Neither shows up at build time.
    @Test("manifest.json lists exactly the tools the catalogue advertises")
    func manifestMatchesCatalogue() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PDFMCPCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
        let data = try Data(contentsOf: root.appending(path: "extension/manifest.json"))

        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = manifest["tools"] as? [[String: Any]]
        else {
            Issue.record("manifest.json has no 'tools' array")
            return
        }

        let listed = Set(entries.compactMap { $0["name"] as? String })
        let advertised = Set(ToolCatalog.all().map(\.name))

        #expect(
            advertised.subtracting(listed).isEmpty,
            "in the catalogue but missing from manifest.json — these ship with no permission switch")
        #expect(
            listed.subtracting(advertised).isEmpty,
            "in manifest.json but not in the catalogue — these show a switch that governs nothing")

        for entry in entries {
            let name = entry["name"] as? String ?? "(unnamed)"
            let description = entry["description"] as? String ?? ""
            #expect(!description.isEmpty, "\(name) has no description in manifest.json")
        }
    }
}
