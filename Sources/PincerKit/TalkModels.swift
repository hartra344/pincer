import Foundation

/// Names from the Gateway's Talk protocol (`talk.*`), verified against openclaw/openclaw.
public enum TalkProtocol {
    public static let catalogMethod = "talk.catalog"
    public static let sessionCreateMethod = "talk.session.create"
    public static let sessionAppendAudioMethod = "talk.session.appendAudio"
    public static let sessionCancelOutputMethod = "talk.session.cancelOutput"
    public static let sessionAcknowledgeMarkMethod = "talk.session.acknowledgeMark"
    public static let sessionSubmitToolResultMethod = "talk.session.submitToolResult"
    public static let sessionSteerMethod = "talk.session.steer"
    public static let sessionCloseMethod = "talk.session.close"
    public static let clientToolCallMethod = "talk.client.toolCall"
    public static let eventName = "talk.event"
    public static let scope = "operator.talk"
    public static let closeDispositionCapability = "talk-session-close-disposition"
    public static let gatewayRelayTransport = "gateway-relay"
    public static let agentConsultBrain = "agent-consult"
    public static let realtimeMode = "realtime"
}

public struct TalkAudioFormat: Equatable, Sendable {
    public let encoding: String
    public let sampleRateHz: Int
    public let channels: Int

    public init?(_ json: JSONValue) {
        guard let encoding = json["encoding"]?.text, let rate = json["sampleRateHz"]?.int,
              let channels = json["channels"]?.int else { return nil }
        self.encoding = encoding
        self.sampleRateHz = rate
        self.channels = channels
    }
}

public struct TalkRealtimeProvider: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let configured: Bool
    public let aliases: [String]
    public let models: [String]
    public let voices: [String]
    public let defaultModel: String?
    public let transports: [String]?
    public let brains: [String]?
    public let inputAudioFormats: [TalkAudioFormat]
    public let outputAudioFormats: [TalkAudioFormat]
    public let supportsBargeIn: Bool?
    public let supportsToolCalls: Bool?

    public init?(_ json: JSONValue) {
        guard let id = json["id"]?.text else { return nil }
        self.id = id
        self.label = json["label"]?.text ?? id
        self.configured = json["configured"]?.bool ?? false
        self.aliases = Self.strings(json["aliases"]) ?? []
        self.models = Self.strings(json["models"]) ?? []
        self.voices = Self.strings(json["voices"]) ?? []
        self.defaultModel = json["defaultModel"]?.text
        self.transports = Self.strings(json["transports"])
        self.brains = Self.strings(json["brains"])
        self.inputAudioFormats = json["inputAudioFormats"]?.array?.compactMap(TalkAudioFormat.init) ?? []
        self.outputAudioFormats = json["outputAudioFormats"]?.array?.compactMap(TalkAudioFormat.init) ?? []
        self.supportsBargeIn = json["supportsBargeIn"]?.bool
        self.supportsToolCalls = json["supportsToolCalls"]?.bool
    }

    public func matches(_ name: String) -> Bool {
        self.id == name || self.aliases.contains(name)
    }

    static func strings(_ json: JSONValue?) -> [String]? {
        json?.array?.compactMap(\.text)
    }
}

public struct TalkCatalog: Equatable, Sendable {
    public let transports: [String]
    public let brains: [String]
    public let modes: [String]
    public let realtimeReady: Bool?
    public let activeRealtimeProvider: String?
    public let realtimeProviders: [TalkRealtimeProvider]
    public let gatewayRelaySupportedHint: Bool?

    public init?(_ json: JSONValue) {
        guard json.object != nil else { return nil }
        self.transports = TalkRealtimeProvider.strings(json["transports"]) ?? []
        self.brains = TalkRealtimeProvider.strings(json["brains"]) ?? []
        self.modes = TalkRealtimeProvider.strings(json["modes"]) ?? []
        let realtime = json["realtime"]
        self.realtimeReady = realtime?["ready"]?.bool
        self.activeRealtimeProvider = realtime?["activeProvider"]?.text
        self.realtimeProviders = realtime?["providers"]?.array?.compactMap(TalkRealtimeProvider.init) ?? []
        self.gatewayRelaySupportedHint = json["config"]?["clientHints"]?["realtime"]?["gatewayRelaySupported"]?.bool
    }

    /// The provider a relay call would use: the active one (by id or alias), else the first configured one.
    public var relayProvider: TalkRealtimeProvider? {
        if let active = self.activeRealtimeProvider, let match = self.realtimeProviders.first(where: { $0.matches(active) }) {
            return match
        }
        return self.realtimeProviders.first { $0.configured }
    }

    public var supportsRelayCall: Bool {
        guard let provider = self.relayProvider, provider.configured, self.realtimeReady != false else { return false }
        let transports = provider.transports ?? self.transports
        let relay = transports.contains(TalkProtocol.gatewayRelayTransport) || self.gatewayRelaySupportedHint == true
        return relay && (provider.brains ?? self.brains).contains(TalkProtocol.agentConsultBrain)
    }

    /// Barge-in is on unless the matched provider says `supportsBargeIn == false`.
    public func supportsBargeIn(provider name: String) -> Bool {
        guard let provider = self.realtimeProviders.first(where: { $0.matches(name) }) else { return false }
        return provider.supportsBargeIn != false
    }
}

public enum TalkAvailability: Equatable, Sendable {
    case unsupported
    case unknown
    case notConfigured(String?)
    case available(provider: String)
}

extension JSONValue {
    /// Messages the Gateway marks `display: false` (Talk consult prompts, internal records) stay out of chat.
    public var isHiddenFromChat: Bool { self["display"]?.bool == false }
}
