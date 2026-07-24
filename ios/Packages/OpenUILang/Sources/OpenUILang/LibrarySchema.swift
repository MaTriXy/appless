import Foundation

/// The GenOS component contract, loaded from `spec/contract/genos.schema.json`
/// (spec/openui-lang.md §8.3 required/optional props of the GenOS contract).
///
/// Provides everything the parser needs from the contract:
/// - `root`: the library's root component type name (e.g. `"Card"`).
/// - `components`: every known component type name.
/// - `paramOrder`: for each component, the positional-argument order and
///   requiredness (the schema body's `properties` are alphabetized for diff
///   stability, so positional order is carried separately by the contract).
/// - `schema`: the raw JSON Schema body (`$defs` etc.) for validation rules.
public struct LibrarySchema: Sendable, Equatable {
    public struct Param: Sendable, Equatable {
        public let name: String
        public let required: Bool
        /// The JSON Schema `default` for this property, if any
        /// (`$defs.<Component>.properties.<name>.default`). lang-core's
        /// `compileSchema` carries it as `defaultValue` and `materializeValue`
        /// applies it to a missing/null REQUIRED prop before reporting
        /// missing-required/null-required (parser.js `getSchemaDefaultValue`).
        public let defaultValue: JSONValue?

        public init(name: String, required: Bool, defaultValue: JSONValue? = nil) {
            self.name = name
            self.required = required
            self.defaultValue = defaultValue
        }
    }

    public let root: String
    public let components: [String]
    public let paramOrder: [String: [Param]]
    /// The raw `schema` body from the contract file (JSON Schema with `$defs`).
    public let schema: JSONValue

    public init(
        root: String,
        components: [String],
        paramOrder: [String: [Param]],
        schema: JSONValue
    ) {
        self.root = root
        self.components = components
        self.paramOrder = paramOrder
        self.schema = schema
    }

    public enum LoadError: Error, CustomStringConvertible {
        case malformedContract(String)

        public var description: String {
            switch self {
            case .malformedContract(let detail):
                return "malformed contract schema: \(detail)"
            }
        }
    }

    /// Loads the contract from a `genos.schema.json` file.
    public static func load(from url: URL) throws -> LibrarySchema {
        let data = try Data(contentsOf: url)
        let doc = try JSONDecoder().decode(JSONValue.self, from: data)

        guard let root = doc["root"]?.stringValue else {
            throw LoadError.malformedContract("missing string \"root\"")
        }
        guard let componentValues = doc["components"]?.arrayValue else {
            throw LoadError.malformedContract("missing array \"components\"")
        }
        let components: [String] = try componentValues.map {
            guard let name = $0.stringValue else {
                throw LoadError.malformedContract("non-string entry in \"components\"")
            }
            return name
        }
        guard let paramOrderObject = doc["paramOrder"]?.objectValue else {
            throw LoadError.malformedContract("missing object \"paramOrder\"")
        }
        guard let schema = doc["schema"], schema.objectValue != nil else {
            throw LoadError.malformedContract("missing object \"schema\"")
        }
        var paramOrder: [String: [Param]] = [:]
        for (component, value) in paramOrderObject {
            guard let entries = value.arrayValue else {
                throw LoadError.malformedContract("paramOrder[\(component)] is not an array")
            }
            let properties = schema["$defs"]?[component]?["properties"]
            paramOrder[component] = try entries.map { entry in
                guard let name = entry["name"]?.stringValue,
                    let required = entry["required"]?.boolValue
                else {
                    throw LoadError.malformedContract(
                        "paramOrder[\(component)] entry missing name/required"
                    )
                }
                // parser.js `getSchemaDefaultValue`: the property's `default`,
                // when the property is a (non-array) object.
                let property = properties?[name]
                let defaultValue = property?.objectValue != nil ? property?["default"] : nil
                return Param(name: name, required: required, defaultValue: defaultValue)
            }
        }

        return LibrarySchema(
            root: root,
            components: components,
            paramOrder: paramOrder,
            schema: schema
        )
    }
}
