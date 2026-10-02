import Foundation

/// The small, upstream-supported portion of agent/model configuration shown by the demo.
enum DemoAgentModelsConfig {
    static let seed: JSONValue = [
        "agents": ["defaults": ["model": [
            "primary": .string("\(DemoGateway.defaultModel.provider)/\(DemoGateway.defaultModel.model)"),
        ]]],
        "models": ["mode": "merge"],
    ]

    static let schemaProperties: [String: JSONValue] = [
        "agents": ["type": "object", "properties": [
            "defaults": ["type": "object", "properties": [
                "model": ["type": "object", "properties": [
                    "primary": ["type": "string", "title": "Primary model"],
                ]],
            ]],
        ]],
        "models": ["type": "object", "properties": [
            "mode": ["type": "string", "enum": ["merge", "replace"], "title": "Catalog mode"],
        ]],
    ]
}
