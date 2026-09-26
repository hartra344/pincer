import AppIntents
import Foundation
import PincerKit

// Gateways, agents and chats as Shortcuts parameters. The logic lives in PincerKit's `IntentService`.

enum PincerIntentService {
    /// A fresh service per run: saved gateways can change between runs. Reuses the running app's
    /// connection when it has one; never starts the app's gateways.
    @MainActor
    static func make() -> IntentService {
        IntentService.live { id in
            let app = AppModel.shared
            let store = app.gateways.first { $0.id == id }
            #if os(iOS)
            // A suspended app's socket can look connected while it's dead; connect afresh instead.
            // The demo runs in-process, so it's always safe to reuse.
            guard app.appIsActive || store?.profile.isDemo == true else { return nil }
            #endif
            return store
        }
    }
}

extension IntentError: @retroactive CustomLocalizedStringResourceConvertible {
    public var localizedStringResource: LocalizedStringResource { "\(self.errorDescription ?? "Something went wrong.")" }
}

// MARK: Gateway

struct GatewayEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Gateway"
    static let defaultQuery = GatewayQuery()

    let id: String
    let name: String
    let host: String?

    init(_ gateway: IntentGateway) {
        self.id = gateway.entityID
        self.name = gateway.name
        self.host = gateway.host
    }

    var gatewayId: UUID? { UUID(uuidString: self.id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(self.name)", subtitle: self.host.map { "\($0)" })
    }
}

struct GatewayQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [GatewayEntity] {
        PincerIntentService.make().gateways(for: identifiers).map(GatewayEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [GatewayEntity] {
        PincerIntentService.make().gateways.map(GatewayEntity.init)
    }
}

// MARK: Agent

struct AgentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let defaultQuery = AgentQuery()

    let id: String
    let gatewayId: UUID
    let gatewayName: String
    let agentId: String
    let name: String
    let title: String
    let subtitle: String?

    init(_ agent: IntentAgent) {
        self.id = agent.entityID
        self.gatewayId = agent.gatewayId
        self.gatewayName = agent.gatewayName
        self.agentId = agent.agentId
        self.name = agent.name
        self.title = agent.title
        self.subtitle = agent.subtitle
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(self.title)", subtitle: self.subtitle.map { "\($0)" })
    }
}

struct AgentQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [AgentEntity] {
        PincerIntentService.make().agents(for: identifiers).map(AgentEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [AgentEntity] {
        await PincerIntentService.make().agents(matching: string).map(AgentEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [AgentEntity] {
        await PincerIntentService.make().suggestedAgents().map(AgentEntity.init)
    }
}

// MARK: Chat

struct ChatEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Chat"
    static let defaultQuery = ChatQuery()

    let id: String
    let chat: IntentChat

    init(_ chat: IntentChat) {
        self.id = chat.entityID
        self.chat = chat
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(self.chat.title)", subtitle: "\(self.chat.subtitle)")
    }
}

struct ChatQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ChatEntity] {
        PincerIntentService.make().chats(for: identifiers).map(ChatEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ChatEntity] {
        await PincerIntentService.make().chats(matching: string).map(ChatEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ChatEntity] {
        await PincerIntentService.make().suggestedChats().map(ChatEntity.init)
    }
}
