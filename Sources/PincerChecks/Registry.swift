import Foundation

// The suite registry: which check sections run in each mode, in order.
// Adding a feature's checks = adding a `Section` line to the right suite below (a demo or
// live section goes to the half that keeps the CI lanes balanced). main.swift never changes.

/// One offline or demo section: the header it prints (nil when the body prints its own) and its body.
struct Section {
    let title: String?
    let run: @MainActor () async -> Void

    init(_ title: String?, _ run: @escaping @MainActor () async -> Void) {
        self.title = title
        self.run = run
    }
}

/// A section that runs against a (mock) Gateway; the title may mention the URL.
struct LiveSection {
    let title: @Sendable (_ url: String) -> String?
    let run: @MainActor (_ url: String, _ token: String) async -> Void

    init(_ title: String?, _ run: @escaping @MainActor (_ url: String, _ token: String) async -> Void) {
        self.title = { _ in title }
        self.run = run
    }

    init(title: @escaping @Sendable (_ url: String) -> String?, _ run: @escaping @MainActor (_ url: String, _ token: String) async -> Void) {
        self.title = title
        self.run = run
    }
}

@MainActor
func runSections(_ sections: [Section]) async {
    for section in sections {
        if let title = section.title { print(title) }
        await section.run()
    }
}

@MainActor
func runSections(_ sections: [LiveSection], url: String, token: String) async {
    for section in sections {
        if let title = section.title(url) { print(title) }
        await section.run(url, token)
    }
}

@MainActor
enum Suites {
    /// The offline sections. `skipIntentChecks` leaves out the slow Shortcuts & Siri section
    /// (CI's demo and live runs, since the plain run already covers it).
    static func unit(skipIntentChecks: Bool) -> [Section] {
        var sections: [Section] = [
            Section("Payload & identity") { runIdentityChecks() },
            Section("App-managed device identity") { runSettingsDeviceIdentityChecks() },
            Section("Bundled development namespace") { runBundleNamespaceChecks() },
            Section("Voice key removal explanation") { runVoiceKeyRemovalChecks() },
            Section("Settings content height") { checkSettingsContentHeight() },
            Section("URL policy") { runURLPolicyChecks() },
            Section("Session rows") { runSessionRowChecks() },
            Section("Invalidation perf") { runInvalidationPerfChecks() },
            Section("Memory bounds") { await runMemoryBoundsChecks() },
            Section("Media directives") { await runMediaDirectiveChecks() },
            Section("Transcript") { await runTranscriptChecks() },
            Section("Streaming transcript saves") { runStreamingSaveChecks() },
            Section("Streaming cadence") { runStreamingCadenceChecks() },
            Section("Models") { runModelChecks() },
            Section("Exec approvals") { runExecApprovalChecks() },
            Section("Approval notification actions") { runApprovalNotificationActionChecks() },
            Section("Approval outcomes") { await runApprovalOutcomeChecks() },
            Section("Approval history") { runApprovalHistoryChecks() },
            Section(nil) { await checkApprovalHistoryModel() },
            Section(nil) { await checkGatewayLogsModel() },
            Section(nil) { await checkExecPolicy() },
            Section(nil) { await checkAgentManagement() },
            Section(nil) { checkSubagents() },
            Section(nil) { checkForwardedMessages() },
            Section("Bridged row authors") { checkBridgedHeaderAuthors() },
            Section(nil) { await checkChannelStatus() },
            Section("Channel status staleness") { await runChannelPollingChecks() },
            Section("Settings notice lifetime") { runSettingsNoticeChecks() },
            Section(nil) { await checkDeviceManagement() },
            Section(nil) { await checkSkillsTools() },
            Section(nil) { await checkSessionManager() },
            Section("Pairing requests") { await checkPairingInboxModel() },
            Section(nil) { await checkGatewayHealth() },
            Section("Gateway preference rejections") { runRejectedPrefHealthChecks() },
            Section("Usage & cost") { await checkUsage() },
            Section("Replies & reactions") { checkReactionsReply() },
            Section("Agent avatar signals") { runAvatarSignalChecks() },
            Section("Avatar choices per Gateway") { runGatewayAvatarChoiceChecks() },
            Section("Agent reply targets") { checkReplyTargets() },
            Section("Reaction level") { checkReactionLevel() },
            Section("Gateway reactions") { checkGatewayReactions() },
            Section("Legacy reaction preference cap") { checkLegacyReactionPrefs() },
            Section("Agent questions") { runAgentQuestionChecks() },
            Section("Gateway config schema") { runConfigChecks() },
            Section("MCP editor validation") { runMCPEditorChecks() },
            Section("MCP tool link resolution") { runMCPToolLinkChecks() },
            Section("Sidebar split action visibility") { runSidebarSplitActionChecks() },
            Section("Sidebar split pane marker") { runSidebarSplitPaneChecks() },
            Section("Progress card") { runProgressCardChecks() },
            Section("Slash commands") { runSlashCommandChecks() },
            Section("Dictation") { await runDictationChecks() },
            Section("Device speech catalog") { await runDeviceSpeechCatalogChecks() },
            Section("Dictation target routing") { runDictationTargetChecks() },
            Section("Avatar seed read authorization") { runAvatarSeedReadAuthorization() },
            Section("Demo agent and model schema") { await runDemoAgentModelsSchemaChecks() },
            Section("Location context") { await runLocationContextChecks() },
            Section("Automations") { runAutomationChecks() },
            Section("Web Push") { await runWebPushChecks() },
            Section("Find in chat") { await runFindInChatChecks() },
            Section("Symbol cache budgets") { runSymbolCacheChecks() },
            Section("Transcript premeasure budgets") { runTranscriptPremeasureChecks() },
            Section("Rich rendering") { runRichRenderingChecks() },
            Section("Bookmark cleanup") { await runBookmarkCleanupChecks() },
            Section("Command palette") { runCommandPaletteChecks() },
            Section("Composer drafts") { await checkDrafts() },
            Section("Message search") { checkMessageSearchLogic() },
            Section("Palette search ordering") { checkPaletteSearchOrdering() },
            Section("Message index") {
                await checkMessageIndex()
                await checkTranscriptCacheVersioning()
            },
            Section("Orphan transcript sidecars") {
                await withScratchCache { root in await runOrphanSidecarChecks(root: root) }
            },
            Section("Spotlight descriptions") { runSpotlightChecks() },
            Section("Transcript window") {
                await withScratchCache { root in await withCacheEnvironment(root.path(percentEncoded: false)) { await runTranscriptWindowChecks() } }
                await withCacheEnvironment("off") { await runTranscriptWindowCacheOffChecks() }
            },
            Section("Transcript prefill indexing") { await runTranscriptPrefillIndexChecks() },
            Section("Paged history probe") { runPagingProbeChecks() },
            Section("Message search in the palette") { checkPaletteMessages() },
            Section("Context usage") { runContextUsageChecks() },
            Section("Quick Capture") { await runQuickCaptureChecks() },
            Section("Menu bar inbox") { await runMenuBarInboxChecks() },
            Section("Open at Login") { runOpenAtLoginChecks() },
            Section("Share extension") { await runShareChecks() },
            Section("Share saved upload policy") { await runShareSavedUploadPolicyChecks() },
        ]
        // The slowest offline section (real reply timeouts).
        if !skipIntentChecks {
            sections.append(Section("Shortcuts & Siri") { await runIntentChecks() })
        }
        sections += [
            Section("Sidebar section work") { runSidebarSectionWorkChecks() },
            Section("Shortcuts unread visibility") { await runIntentVisibilityChecks() },
            Section("Deep links & Handoff") { runDeepLinkChecks() },
            Section(nil) { runLocalizationChecks() },
            Section(nil) { checkToolDiffs() },
            Section(nil) { checkOutboxLogic() },
            Section(nil) { checkSidebarWorking() },
            Section("Sidebar activity dates") { runSidebarActivityDateChecks() },
            Section("Composer session title") { runComposerSessionTitleChecks() },
            Section("Current shortcut tips") { runShortcutTipsChecks() },
            Section("First-run wizard") { await runFirstRunChecks() },
            Section("Documentation capture packaging") { runDocsCaptureIsolationChecks() },
        ]
        return sections
    }

    /// The built-in demo, first half.
    static let demoCore: [Section] = [
        Section("Built-in demo") { await runDemo() },
        Section("Demo message search with the cache off") { await checkDemoSearchWithoutCache() },
        Section("Shortcuts on the demo") { await runDemoIntents() },
        Section("Search track (demo)") { await runDemoSearchTrackChecks() },
        Section("Chat navigation") { await runNavigation() },
        Section("Quick Capture (demo)") { await runQuickCaptureDemo() },
        Section("Replies & reactions (demo)") { await runDemoReactionsReply() },
        Section("Bookmark sync (demo)") { await runDemoBookmarkSync() },
        Section("Agent reply targets (demo)") { await runDemoReplyTargets() },
        Section("Reaction level (demo)") { await runDemoReactionLevel() },
        Section("Reactions on users.prefs (demo, Gateway reactions off)") { await runDemoPrefsReactions() },
        Section("Messages from other agents (demo)") { await runDemoForwarded() },
        Section("Menu bar (demo)") { await runMenuBarDemo() },
        Section("Scroll to bottom (demo)") { await runDemoScrollToBottom() },
        Section("Shared chat load (demo)") { await runDemoSharedLoadChecks() },
    ]

    /// The built-in demo, second half.
    static let demoExtras: [Section] = [
        Section("Cold-launch routes (demo)") { await runDemoColdLaunchRouteChecks() },
        Section("Sidebar section work (demo)") { await runDemoSidebarSectionWorkChecks() },
        Section("Sidebar split pane marker (demo)") { await runDemoSidebarSplitPaneChecks() },
        Section("Shortcuts unread visibility (demo)") { await runDemoIntentVisibilityChecks() },
        Section("Device ID Settings cache (demo)") { runSettingsDeviceIdentityChecks() },
        Section("Settings content height (demo)") { checkSettingsContentHeight() },
        Section("Rejected synced preferences (demo)") { await runDemoRejectedPrefWriteChecks() },
        Section("Sidebar automations & slash commands (demo)") { await runDemoSidebarVisibility() },
        Section("Setup wizard (demo)") { await runDemoSetup() },
        Section("Deep links (demo)") { await runDemoDeepLinks() },
        Section("Channel status (demo)") { await runDemoChannels() },
        Section("Channel status staleness (demo)") { await runDemoChannelPollingChecks() },
        Section("Tool diffs (demo)") { await runDemoToolDiffs() },
        Section("Tool cards (demo)") { await runDemoToolCards() },
        Section("Rich rendering (demo)") { await runDemoRichRendering() },
        Section("Agent avatars (demo)") { await runDemoAvatars() },
        Section("Agent avatar seed recovery (demo, #520)") { await runDemoAvatarSeedRecovery() },
        Section("Avatar choices per Gateway (demo, #518)") { await runDemoGatewayAvatarChoices() },
        Section("Current shortcut tips (demo)") { await runDemoShortcutTips() },
        Section("First-run wizard (demo)") { await runDemoFirstRun() },
        Section("Outbox & retry (demo)") { await runDemoOutbox() },
        Section("Outbox head scan (demo, #557)") { await runDemoOutboxHeadScanChecks() },
        Section("Outbox image previews (demo, #557)") { await runDemoOutboxImagePreviewChecks() },
        Section("Streaming transcript saves (demo)") { await runDemoStreamingSaveChecks() },
        Section("Share upload policy lifecycle (demo, #557)") { await runDemoShareUploadPolicyLifecycleChecks() },
        Section("Accessibility labels (demo)") { await runDemoAccessibility() },
        Section("Accessibility pass (demo)") { await runDemoAccessibilityPass() },
        Section("Transcript paging recovery (demo, #337)") { await runDemoTranscriptPagingRecovery() },
        Section("Demo agent and model settings") { await runDemoAgentModelsPageChecks() },
        Section("Transcript headless fill (demo, #299)") { await runDemoTranscriptHeadlessFillChecks() },
        Section("Resize streaming inputs (demo, #353)") { await runDemoResizeStreamingInputs() },
        Section("Sidebar working avatar (demo)") { await runDemoSidebarWorking() },
        Section("Sidebar agent groups (demo)") { await runDemoSidebarAgentGroups() },
        Section("Sidebar group moves (demo, #416)") { await runDemoSidebarGroupMoves() },
        Section("Sidebar hierarchy (demo)") { await runDemoSidebarHierarchy() },
        Section("Sidebar reveal (demo)") { await runDemoSidebarReveal() },
        Section("Sidebar header interactions (demo)") { await runDemoSidebarHeaderInteractions() },
        Section("Sidebar split action visibility (demo)") { await runDemoSidebarSplitActions() },
        Section("MCP servers (demo)") { await runDemoMCP() },
        Section("MCP tool links (demo)") { await runDemoMCPToolLinks() },
        Section("Voice / Read Aloud (demo)") { await runDemoVoice() },
        Section("Device speech settings (demo)") { await runDemoDeviceSpeechCatalogChecks() },
        Section("Chat windows (demo)") { await runDemoChatWindows() },
        Section("Unread in the open chat (demo)") { await runDemoVisibleChatRead() },
        Section("Dictation target routing (demo)") { await runDemoDictationTargetChecks() },
        Section("Location context opt-in (demo)") { await runDemoLocationContextChecks() },
        Section("Composer session title (demo)") { await runDemoComposerSessionTitleChecks() },
        Section("Transcript footer metadata (demo)") { await runDemoFooterMetadataChecks() },
    ]

    /// Against a (mock) Gateway, first half.
    static let liveCore: [LiveSection] = [
        LiveSection(title: { "Live against \($0)" }) { url, token in await runLive(url: url, token: token) },
    ]

    /// Against a (mock) Gateway, second half.
    static let liveExtras: [LiveSection] = [
        LiveSection("Spotlight indexing (live)") { url, token in await runLiveSpotlightChecks(url: url, token: token) },
        LiveSection("Messages from other agents (live)") { url, token in await runLiveForwarded(url: url, token: token) },
        LiveSection("Gateway reactions (live)") { url, token in await runLiveGatewayReactions(url: url, token: token) },
        LiveSection("Quick Capture (live)") { url, token in await runQuickCaptureLive(url: url, token: token) },
        LiveSection("Replies & reactions (live)") { url, token in await runLiveReactionsReply(url: url, token: token) },
        LiveSection("Agent reply targets (live)") { url, token in await runLiveReplyTargets(url: url, token: token) },
        LiveSection("Reaction level (live)") { url, token in await runLiveReactionLevel(url: url, token: token) },
        LiveSection("Transcript cache recovery (live)") { url, token in await runLiveCacheRecovery(url: url, token: token) },
        LiveSection("Transcript window (live)") { url, token in await runLiveTranscriptWindow(url: url, token: token) },
        LiveSection(nil) { url, token in await runLiveCacheRefill(url: url, token: token) },
        LiveSection("Setup wizard (live)") { url, token in await runLiveSetup(url: url, token: token) },
        LiveSection("Deep links (live)") { url, token in await runLiveDeepLinks(url: url, token: token) },
        LiveSection("Cold-launch routes (live)") { url, token in await runLiveColdLaunchRouteChecks(url: url, token: token) },
        LiveSection("Tool diffs (live)") { url, token in await runLiveToolDiffs(url: url, token: token) },
        LiveSection("Tool cards (live)") { url, token in await runLiveToolCards(url: url, token: token) },
        LiveSection("Agent avatars (live)") { url, token in await runLiveAvatars(url: url, token: token) },
        LiveSection("MCP servers (live)") { url, token in await runLiveMCP(url: url, token: token) },
        LiveSection("MCP tool links (live)") { url, token in await runLiveMCPToolLinks(url: url, token: token) },
        LiveSection("Voice / Read Aloud (live)") { url, token in await runLiveVoice(url: url, token: token) },
        LiveSection("Outbox & retry (live)") { url, token in await runLiveOutbox(url: url, token: token) },
        LiveSection("Background refresh (live)") { url, token in await runBackgroundRefreshLive(url: url, token: token) },
        // Last: it pairs a fresh device identity.
        LiveSection("First-run wizard (live)") { url, token in await runLiveFirstRun(url: url, token: token) },
    ]

    /// Reconnect and bootstrap behaviour (#202); needs a fresh mock.
    static let liveReconnect: [LiveSection] = [
        LiveSection(title: { "Reconnect & bootstrap (live, \($0))" }) { url, token in await runLiveReconnect(url: url, token: token) },
    ]

    /// A Gateway without usage (mock with MOCK_NO_USAGE=1).
    static let liveNoUsage: [LiveSection] = [
        LiveSection(title: { "Gateway without usage at \($0)" }) { url, token in await runLiveNoUsage(url: url, token: token) },
    ]

    /// A Gateway without replyToId (mock with MOCK_NO_REPLY_TO=1).
    static let liveNoReplyTo: [LiveSection] = [
        LiveSection(title: { "Gateway without replyToId at \($0)" }) { url, token in await runLiveNoReplyTo(url: url, token: token) },
    ]

    /// A Gateway without session.reactions.* (mock with MOCK_NO_REACTIONS=1).
    static let liveNoSessionReactions: [LiveSection] = [
        LiveSection(title: { "Gateway without session.reactions at \($0)" }) { url, token in await runLiveNoSessionReactions(url: url, token: token) },
    ]

    /// A mock started with MOCK_PAIRING=auto MOCK_LEGACY_PAIRING=1.
    static let liveScopeUpgrade: [LiveSection] = [
        LiveSection(title: { "Scope upgrade fallback against \($0)" }) { url, token in await runScopeUpgrade(url: url, token: token) },
    ]

    /// Message index at 20 chats × 20k messages (run it in a release build).
    static let perf: [Section] = [
        Section("Message index performance (20 × 20k)") { await runMessageIndexPerf() },
    ]

    /// Budgets enforced; run it alone.
    static let perfSmoke: [Section] = [
        Section("Message index perf smoke") { await withScratchCache { root in await checkMessageIndexPerfSmoke(root: root) } },
    ]
}
