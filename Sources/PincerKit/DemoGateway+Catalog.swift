import Foundation

/// Static catalogs and downloads: agents, models, commands, artifacts, logs, usage.
extension DemoGateway {
    func handleCatalog(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        switch method {
        case "agents.list":
            return ["defaultId": "main", "mainKey": "main", "scope": "per-sender", "agents": .array(self.agents)]
        case "models.list":
            return ["models": .array(Self.modelCatalog)]
        case "commands.list":
            return ["commands": .array(Self.commandCatalog)]
        case "artifacts.download":
            guard let id = params["artifactId"]?.string, let artifact = self.artifacts[id] else {
                throw GatewayError.rpc(code: "NOT_FOUND", message: "artifact not found", details: nil)
            }
            return ["artifactId": .string(id), "mimeType": .string(artifact.mimeType), "encoding": "base64",
                    "data": .string(artifact.data.base64EncodedString())]
        case "logs.tail":
            return try self.logs.tail(params)
        case _ where DemoUsage.methods.contains(method):
            return try DemoUsage.handle(method, params, knownKeys: Set(self.sessions.keys))
        default:
            return nil
        }
    }
}
