import Foundation
import Testing
@testable import PincerKit

/// #107: the per-channel `reactionLevel` control (account → channel → default).
@Suite("Reaction level")
struct ReactionLevelTests {
    static func config(_ text: String) -> JSONValue { Fixtures.json(text) }

    @Test func levelsAndCopy() {
        #expect(ReactionLevel.allCases == [.off, .ack, .minimal, .extensive])
        #expect(ReactionLevel.allCases.map(\.rawValue) == ["off", "ack", "minimal", "extensive"])
        #expect(ReactionLevel.allCases.map(\.title) == ["Off", "Acknowledge only", "Minimal", "Extensive"])
        #expect(Set(ReactionLevel.allCases.map(\.detail)).count == 4 && ReactionLevel.allCases.allSatisfy { !$0.detail.isEmpty })
    }

    @Test func supportedChannels() {
        for channel in ["telegram", "whatsapp", "signal"] {
            #expect(ReactionLevels.supportedChannels.contains(channel), "\(channel)")
        }
        #expect(!ReactionLevels.supportedChannels.contains("discord"))
    }

    @Test func emptyConfigUsesTheChannelDefault() throws {
        for channel in ReactionLevels.supportedChannels {
            let result = ReactionLevels.effective(config: Self.config("{}"), channel: channel, account: nil)
            #expect(result.source == .default && result.level == ReactionLevels.defaultLevel(channel: channel), "\(channel)")
        }
    }

    @Test func channelValueBeatsDefault() {
        let config = Self.config(#"{"channels":{"telegram":{"reactionLevel":"extensive"}}}"#)
        let result = ReactionLevels.effective(config: config, channel: "telegram", account: nil)
        #expect(result.level == .extensive && result.source == .channel)
        let viaAccount = ReactionLevels.effective(config: config, channel: "telegram", account: "work")
        #expect(viaAccount.level == .extensive && viaAccount.source == .channel)
    }

    @Test func accountValueBeatsChannel() {
        let config = Self.config(#"{"channels":{"telegram":{"reactionLevel":"minimal","accounts":{"work":{"reactionLevel":"off"},"home":{}}}}}"#)
        let work = ReactionLevels.effective(config: config, channel: "telegram", account: "work")
        #expect(work.level == .off && work.source == .account)
        let home = ReactionLevels.effective(config: config, channel: "telegram", account: "home")
        #expect(home.level == .minimal && home.source == .channel)
        let unknown = ReactionLevels.effective(config: config, channel: "telegram", account: "nobody")
        #expect(unknown.level == .minimal && unknown.source == .channel)
    }

    @Test func accountValueIgnoredWithoutAccount() {
        let config = Self.config(#"{"channels":{"telegram":{"accounts":{"work":{"reactionLevel":"off"}}}}}"#)
        let result = ReactionLevels.effective(config: config, channel: "telegram", account: nil)
        #expect(result.source == .default)
    }

    @Test func valuesAreTrimmedAndBlankIsMissing() {
        let trimmed = ReactionLevels.effective(config: Self.config(#"{"channels":{"telegram":{"reactionLevel":"  ack "}}}"#), channel: "telegram", account: nil)
        #expect(trimmed.level == .ack && trimmed.source == .channel)
        for blank in [#""""#, #""   ""#, "null"] {
            let result = ReactionLevels.effective(config: Self.config(#"{"channels":{"telegram":{"reactionLevel":\#(blank)}}}"#), channel: "telegram", account: nil)
            #expect(result.source == .default, "\(blank)")
        }
    }

    @Test func invalidValuesFallBackToAckOrMinimal() {
        for bad in [#""loud""#, "5", "true", #"["off"]"#, #""OFF""#] {
            let config = Self.config(#"{"channels":{"telegram":{"reactionLevel":\#(bad)}}}"#)
            let result = ReactionLevels.effective(config: config, channel: "telegram", account: nil)
            #expect(result.level == .ack || result.level == .minimal, "\(bad) → \(result.level)")
        }
    }

    @Test func invalidAccountValueDoesNotFallThroughToChannel() {
        // Upstream resolves the account's own value first; an invalid one takes the channel's invalid fallback.
        let config = Self.config(#"{"channels":{"telegram":{"reactionLevel":"extensive","accounts":{"work":{"reactionLevel":"loud"}}}}}"#)
        let result = ReactionLevels.effective(config: config, channel: "telegram", account: "work")
        #expect(result.level == .ack || result.level == .minimal)
    }

    @Test func malformedConfigShapesDoNotCrash() {
        for text in ["null", "[]", #"{"channels":[]}"#, #"{"channels":{"telegram":"x"}}"#, #"{"channels":{"telegram":{"accounts":[]}}}"#] {
            let result = ReactionLevels.effective(config: Self.config(text), channel: "telegram", account: "work")
            #expect(result.source == .default, "\(text)")
        }
    }

    @Test func patchSetsChannelLevel() {
        let patch = ReactionLevels.patch(channel: "telegram", account: nil, level: .minimal)
        #expect(patch == ["channels": ["telegram": ["reactionLevel": "minimal"]]])
    }

    @Test func patchSetsAccountLevel() {
        let patch = ReactionLevels.patch(channel: "telegram", account: "work", level: .off)
        #expect(patch == ["channels": ["telegram": ["accounts": ["work": ["reactionLevel": "off"]]]]])
    }

    @Test func patchClearingAnOverrideWritesNull() {
        #expect(ReactionLevels.patch(channel: "signal", account: nil, level: nil)
                == ["channels": ["signal": ["reactionLevel": .null]]])
        #expect(ReactionLevels.patch(channel: "signal", account: "a1", level: nil)
                == ["channels": ["signal": ["accounts": ["a1": ["reactionLevel": .null]]]]])
    }

    @Test func patchAppliedToConfigRoundTripsThroughEffective() {
        var config = Self.config(#"{"channels":{"telegram":{"reactionLevel":"minimal"}}}"#)
        config = config.setting("extensive", at: ["channels", "telegram", "accounts", "work", "reactionLevel"])
        #expect(ReactionLevels.effective(config: config, channel: "telegram", account: "work").level == .extensive)
    }

    @Test func invalidFallbackIsAckOrMinimalPerChannel() {
        for channel in ReactionLevels.supportedChannels {
            let fallback = ReactionLevels.invalidFallback(channel: channel)
            #expect(fallback == .ack || fallback == .minimal, "\(channel)")
            let bad = ReactionLevels.effective(config: Self.config(#"{"channels":{"\#(channel)":{"reactionLevel":"loud"}}}"#), channel: channel, account: nil)
            #expect(bad.level == fallback && bad.isInvalid && bad.source == .channel)
        }
    }

    @Test func supportsIsCaseInsensitiveAndRejectsUnsupported() {
        #expect(ReactionLevels.supports(channel: "Telegram") && ReactionLevels.supports(channel: "SIGNAL"))
        #expect(!ReactionLevels.supports(channel: "discord") && !ReactionLevels.supports(channel: nil) && !ReactionLevels.supports(channel: ""))
    }

    @Test func pathsAndControlledSettings() {
        #expect(ReactionLevels.path(channel: "telegram") == ["channels", "telegram", "reactionLevel"])
        #expect(ReactionLevels.path(channel: "telegram", account: "work") == ["channels", "telegram", "accounts", "work", "reactionLevel"])
        #expect(ReactionLevels.isControlled(path: ["channels", "telegram", "reactionLevel"]))
        #expect(ReactionLevels.isControlled(path: ["channels", "signal", "accounts", "a", "reactionLevel"]))
        #expect(!ReactionLevels.isControlled(path: ["channels", "discord", "reactionLevel"]))
        #expect(!ReactionLevels.isControlled(path: ["channels", "telegram", "enabled"]))
    }

    @Test func discordNeverHasAControlTarget() {
        #expect(ReactionLevels.target(for: ["channels", "discord"]) == nil)
        #expect(ReactionLevels.target(for: ["channels", "telegram"])?.channel == "telegram")
        #expect(ReactionLevels.target(for: ["channels", "telegram", "accounts", "home"])?.account == "home")
    }

    @Test func chatEditsTheAccountOnlyWhenTheConfigListsIt() {
        let config = Self.config(#"{"channels":{"telegram":{"accounts":{"home":{}}}}}"#)
        #expect(ReactionLevels.editableAccount(config: config, channel: "telegram", account: "home") == "home")
        #expect(ReactionLevels.editableAccount(config: config, channel: "telegram", account: "ghost") == nil)
        #expect(ReactionLevels.editableAccount(config: config, channel: "telegram", account: nil) == nil)
    }

    @Test func offStopsTheAcknowledgementOnWhatsAppAndSignalOnly() {
        for channel in ["whatsapp", "signal", "WhatsApp"] { #expect(ReactionLevel.off.offAlsoStopsAcknowledgement(channel: channel), "\(channel)") }
        #expect(!ReactionLevel.off.offAlsoStopsAcknowledgement(channel: "telegram"))
        #expect(!ReactionLevel.off.offAlsoStopsAcknowledgement(channel: "discord"))
        for level in ReactionLevel.allCases where level != .off {
            #expect(!level.offAlsoStopsAcknowledgement(channel: "whatsapp"), "\(level)")
        }
    }

    @Test func overridingAccountOnlyWhenItHasItsOwnLevel() {
        let config = Self.config(#"{"channels":{"telegram":{"reactionLevel":"minimal","accounts":{"home":{"reactionLevel":"off"},"work":{"name":"Work"},"nulled":{"reactionLevel":null}}}}}"#)
        #expect(ReactionLevels.overridingAccount(config: config, channel: "telegram", account: "home") == "home")
        #expect(ReactionLevels.overridingAccount(config: config, channel: "telegram", account: "work") == nil)
        #expect(ReactionLevels.overridingAccount(config: config, channel: "telegram", account: "ghost") == nil)
        #expect(ReactionLevels.overridingAccount(config: config, channel: "telegram", account: nil) == nil)
        #expect(ReactionLevels.overridingAccount(config: config, channel: "telegram", account: "") == nil)
        #expect(ReactionLevels.overridingAccount(config: nil, channel: "telegram", account: "home") == nil)
    }

    @Test func displayNames() {
        #expect(ReactionLevels.displayName(channel: "whatsapp") == "WhatsApp" && ReactionLevels.displayName(channel: "TELEGRAM") == "Telegram")
        #expect(ReactionLevels.displayName(channel: "signal") == "Signal" && ReactionLevels.displayName(channel: "matrix") == "Matrix")
    }
}
