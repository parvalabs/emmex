import Foundation
import FoundationModels
import MCP

/// Converts an MCP tool's JSON Schema (as the SDK's `Value`) into a FoundationModels
/// `DynamicGenerationSchema`, so the model is grammar-constrained to valid arguments.
/// Supports object/properties/required, string (+enum), integer, number, boolean, array,
/// nested objects, and falls back to string for anything exotic.
enum JSONSchema {
    static func generationSchema(name: String, from value: Value) throws -> GenerationSchema {
        let root = dynamic(name: name, value: value, description: nil)
        return try GenerationSchema(root: root, dependencies: [])
    }

    static func dynamic(name: String, value: Value, description: String?) -> DynamicGenerationSchema {
        let obj = value.objectValue ?? [:]
        let desc = description ?? obj["description"]?.stringValue
        var type = obj["type"]?.stringValue
        if type == nil, let types = obj["type"]?.arrayValue { type = types.compactMap(\.stringValue).first { $0 != "null" } }
        if type == nil, obj["properties"] != nil { type = "object" }
        if type == nil, obj["enum"] != nil { type = "string" }
        if let choices = obj["enum"]?.arrayValue?.compactMap({ $0.stringValue ?? $0.intValue.map(String.init) }), !choices.isEmpty {
            return DynamicGenerationSchema(name: name, description: desc, anyOf: choices)
        }
        switch type {
        case "object":
            let props = obj["properties"]?.objectValue ?? [:]
            let required = Set(obj["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let properties = props.keys.sorted().map { key in
                DynamicGenerationSchema.Property(
                    name: key,
                    description: props[key]?.objectValue?["description"]?.stringValue,
                    schema: dynamic(name: "\(name)_\(key)", value: props[key] ?? .object([:]), description: nil),
                    isOptional: !required.contains(key))
            }
            return DynamicGenerationSchema(name: name, description: desc, properties: properties)
        case "array":
            let item = dynamic(name: "\(name)_item", value: obj["items"] ?? .object(["type": "string"]), description: nil)
            return DynamicGenerationSchema(arrayOf: item)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default: return DynamicGenerationSchema(type: String.self)
        }
    }

    /// GeneratedContent → MCP Value, via JSON.
    static func value(from content: GeneratedContent) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(content.jsonString.utf8))
    }
}
