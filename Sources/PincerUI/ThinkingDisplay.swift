import SwiftUI

/// How much of the agent's thinking steps (reasoning and tool calls) the transcript shows.
/// A display preference on this device, separate from the session's `reasoningLevel`, which
/// decides what the Gateway saves and streams.
enum ThinkingDisplay: String, CaseIterable, Identifiable {
    /// Only replies.
    case none
    /// Thinking steps while a reply is running, hidden once it finishes.
    case live
    /// Every turn's thinking steps, each finished turn folded into one "Thinking" item.
    case all

    static let storageKey = "pincer.thinkingDisplay"
    static let defaultValue = ThinkingDisplay.live

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .live: "Live Only"
        case .all: "All"
        }
    }

    var detail: String {
        switch self {
        case .none: "Show only replies."
        case .live: "Show thinking and tool calls while the agent works, then hide them."
        case .all: "Keep every turn's thinking and tool calls, folded into one item."
        }
    }

    static var current: ThinkingDisplay {
        UserDefaults.standard.string(forKey: self.storageKey).flatMap(ThinkingDisplay.init(rawValue:)) ?? self.defaultValue
    }
}

/// Picker for `ThinkingDisplay`, for the chat menu and Settings.
struct ThinkingDisplayPicker: View {
    @AppStorage(ThinkingDisplay.storageKey) private var display = ThinkingDisplay.defaultValue

    var body: some View {
        Picker(selection: self.$display) {
            ForEach(ThinkingDisplay.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        } label: {
            Label("Thinking Steps", systemImage: "brain.head.profile")
        }
        .pickerStyle(.menu)
    }
}
