import ChirpCore
import Foundation

/// A JSON value, for tool schemas and model-produced arguments (which are never trusted as typed data).
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): NumericFormatting.plain(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    /// Compact JSON with sorted keys (stable bytes for hashing and for the model).
    public var compactJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

enum NumericFormatting {
    static func plain(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e12 ? String(Int64(value)) : String(value)
    }
}

/// One tool in a frozen catalog.
public struct StructureTool: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    /// Spoken trigger phrases (dictation commands only). Never sent to a model.
    public var phrases: [String]?
    /// A JSON Schema object.
    public var parameters: JSONValue

    /// Argument names the schema requires.
    public var required: [String] {
        guard case .array(let values)? = parameters["required"] else { return [] }
        return values.compactMap(\.stringValue)
    }

    /// Allowed values of an enum argument, or nil when the argument is free text.
    public func allowedValues(for argument: String) -> [String]? {
        guard case .array(let values)? = parameters["properties"]?[argument]?["enum"] else { return nil }
        return values.compactMap(\.stringValue)
    }

    public var argumentNames: [String] {
        guard case .object(let properties)? = parameters["properties"] else { return [] }
        return properties.keys.sorted()
    }
}

/// A frozen, versioned tool catalog (`soap-meds.v1`, `dictation-commands.v1`) read from ChirpFeatures' resources.
///
/// Frozen: a catalog file never changes once shipped (a test pins each file's SHA-256); a change is a new version, so
/// every stored result names exactly the tools it was produced against.
public struct StructureCatalog: Codable, Sendable, Equatable {
    public var id: String
    public var version: Int
    public var description: String
    public var tools: [StructureTool]
    /// The model-facing tool array in the file's own key order (set when loaded from a file).
    var orderedToolsJSON: String?

    enum CodingKeys: String, CodingKey {
        case id, version, description, tools
    }

    /// "soap-meds.v1"
    public var versionedID: String { "\(id).v\(version)" }

    public func tool(named name: String) -> StructureTool? {
        tools.first { $0.name == name }
    }

    /// The tool array a model reads: name, description, parameters (no trigger phrases), compact, **in the catalog
    /// file's key order** (Needle is sensitive to key order; see `OrderedJSON`).
    public var toolsJSON: String {
        if let orderedToolsJSON { return orderedToolsJSON }
        return JSONValue.array(
            tools.map { tool in
                .object([
                    "name": .string(tool.name), "description": .string(tool.description), "parameters": tool.parameters,
                ])
            }
        ).compactJSON
    }

    public enum LoadError: Error, Equatable {
        case missing(String)
    }

    /// The bundled `<name>.json`.
    public static func bundledURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "StructureCatalogs")
    }

    /// Loads `<name>.json` from the bundled catalogs.
    public static func bundled(_ name: String) throws -> StructureCatalog {
        guard let url = bundledURL(name) else { throw LoadError.missing(name) }
        let data = try Data(contentsOf: url)
        var catalog = try JSONDecoder().decode(StructureCatalog.self, from: data)
        if case .array(let tools)? = try OrderedJSON.parse(data)["tools"] {
            catalog.orderedToolsJSON = OrderedJSON.array(tools.map { $0.removing(["phrases"]) }).compact
        }
        return catalog
    }

    /// `soap-meds.v1`: vitals, medications, allergies, problems, plan items (clinical, on device only).
    public static let soapMeds: StructureCatalog = {
        do { return try bundled("soap-meds.v1") } catch {
            fatalError("soap-meds.v1.json is missing from ChirpFeatures")
        }
    }()

    /// `dictation-commands.v1`: at most ten spoken commands.
    public static let dictationCommands: StructureCatalog = {
        do { return try bundled("dictation-commands.v1") } catch {
            fatalError("dictation-commands.v1.json is missing from ChirpFeatures")
        }
    }()
}

/// One tool call a structure engine proposed, before validation.
public struct StructuredCall: Sendable, Equatable, Codable {
    public var name: String
    public var arguments: [String: JSONValue]

    public init(name: String, arguments: [String: JSONValue] = [:]) {
        self.name = name
        self.arguments = arguments
    }

    public func string(_ key: String) -> String? {
        arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses an engine's call array (`[{"name", "arguments"}]`; a single object is accepted as one call).
    /// Nil when the JSON is not a call array at all.
    public static func parseArray(_ json: String) -> [StructuredCall]? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else { return nil }
        let items: [JSONValue]
        switch value {
        case .array(let array): items = array
        case .object: items = [value]
        default: return nil
        }
        var calls: [StructuredCall] = []
        for item in items {
            guard let name = item["name"]?.stringValue else { return nil }
            var arguments: [String: JSONValue] = [:]
            if case .object(let object)? = item["arguments"] { arguments = object }
            calls.append(StructuredCall(name: name, arguments: arguments))
        }
        return calls
    }

    /// Schema problems in words (unknown tool, missing required argument, value outside an enum). Empty = valid.
    public func problems(against catalog: StructureCatalog) -> [String] {
        guard let tool = catalog.tool(named: name) else { return ["Unknown tool “\(name)”."] }
        var problems: [String] = []
        for required in tool.required where (string(required) ?? "").isEmpty {
            problems.append("Missing \(required).")
        }
        for (key, value) in arguments {
            guard let allowed = tool.allowedValues(for: key) else { continue }
            if let text = value.stringValue, !allowed.contains(text) {
                problems.append("\(key) “\(text)” is not one of \(allowed.joined(separator: ", ")).")
            }
        }
        return problems
    }
}
