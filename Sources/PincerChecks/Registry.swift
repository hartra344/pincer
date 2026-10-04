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
            Section("Attachment draft ownership") { runAttachmentDraftOwnershipChecks() },
            Section("Device pairing action scopes") { await runDevicePairingActionScopeChecks() },
            Section("Deferred dictation send ownership") { runDeferredDictationSendChecks() },
            Section("Composer edit admission ownership") { runComposerEditAdmissionOwnershipChecks() },
            Section("Compact graduated header policy") { runCompactGraduatedHeaderChecks() },
            Section("Bounded cold rotor labels") { await runColdRotorLabelChecks() },
            Section("Cold transcript geometry sources") { await runColdTranscriptHeightEstimateChecks() },
            Section("Attachment thumbnails") { await runAttachmentThumbnailChecks() },
            Section("Attachment preparation bounds") { await runAttachmentPreparationChecks() },
            Section("App-managed device identity") { runSettingsDeviceIdentityChecks() },
            Section("Bundled development namespace") { runBundleNamespaceChecks() },
            Section("Development suffix validator") { await runDevSuffixValidatorChecks() },
            Section("Mac bundle location purpose") { await runBundleLocationPurposeChecks() },
            Section("Voice settings value bounds") { runVoiceSettingsValueBoundsChecks() },
            Section("Voice playback ownership") { runVoicePlaybackOwnershipChecks() },
            Section("Voice test feedback ownership") { await runVoiceTestFeedbackOwnershipChecks() },
            Section("Voice key removal explanation") { runVoiceKeyRemovalChecks() },
            Section("Voice catalog request ownership") { await runVoiceListRequestOwnershipChecks() },
            Section("Voice settings draft ownership") { runVoiceSettingsDraftChecks() },
            Section("Settings content height") { checkSettingsContentHeight() },
            Section("Display name editing") { await runOwnerNameChecks() },
            Section("URL policy") { runURLPolicyChecks() },
            Section("Rewind history ownership") { await runRewindHistoryOwnershipChecks() },
            Section("Session rows") { runSessionRowChecks() },
            Section("Invalidation perf") { runInvalidationPerfChecks() },
            Section("Latest measurement worker") { await runLatestMeasurementChecks() },
            Section("Memory bounds") { await runMemoryBoundsChecks() },
            Section("Media directives") { await runMediaDirectiveChecks() },
            Section("Transcript") { await runTranscriptChecks() },
            Section("Grouped message keyboard selection") { runGroupedMessageKeyboardChecks() },
            Section("Streaming clock adjustment") { runStreamingClockChecks() },
            Section("Streaming transcript saves") { runStreamingSaveChecks() },
            Section("Streaming cadence") { runStreamingCadenceChecks() },
            Section("Models") { runModelChecks() },
            Section("Exec approvals") { runExecApprovalChecks() },
            Section("Approval notification actions") { runApprovalNotificationActionChecks() },
            Section("Approval outcomes") { await runApprovalOutcomeChecks() },
            Section("Approval history") { runApprovalHistoryChecks() },
            Section(nil) { await checkApprovalHistoryModel() },
            Section(nil) { await checkGatewayLogsModel() },
            Section("Gateway Logs Clear ownership") { await runGatewayLogsClearOwnershipChecks() },
            Section(nil) { await checkExecPolicy() },
            Section("Device load admission") { await runDeviceLoadAdmissionChecks() },
            Section("Command policy load admission") { await runExecPolicyLoadAdmissionChecks() },
            Section(nil) { await checkAgentManagement() },
            Section("Agent file reload ownership") { await runAgentFileReloadOwnershipChecks() },
            Section("Agent file write authority") { await runAgentFileWriteAuthorityChecks() },
            Section(nil) { checkSubagents() },
            Section(nil) { checkForwardedMessages() },
            Section("Bridged row authors") { checkBridgedHeaderAuthors() },
            Section(nil) { await checkChannelStatus() },
            Section("Channel status staleness") { await runChannelPollingChecks() },
            Section("Channel action ownership") { await runChannelActionOwnershipChecks() },
            Section("Settings notice lifetime") { runSettingsNoticeChecks() },
            Section("Settings save reconciliation") { await runSettingsSaveRebaseChecks() },
            Section("Raw config editor ownership") { await runRawConfigEditorChecks() },
            Section("Plugin credential ownership") { await runPluginCredentialOwnershipChecks() },
            Section(nil) { await checkDeviceManagement() },
            Section(nil) { await checkSkillsTools() },
            Section("Skills feedback ownership") { await runSkillsFeedbackOwnershipChecks() },
            Section(nil) { await checkSessionManager() },
            Section("Session detail ownership") { await runSessionDetailOwnershipChecks() },
            Section("Pairing requests") { await checkPairingInboxModel() },
            Section(nil) { await checkGatewayHealth() },
            Section("Ingress health issues") { runIngressHealthChecks() },
            Section("Heartbeat event ordering") { await runHeartbeatEventOrderingChecks() },
            Section("Health canceled admission") { await runHealthCanceledAdmissionChecks() },
            Section("Health event ordering") { await runHealthEventOrderingChecks() },
            Section("Gateway preference rejections") { runRejectedPrefHealthChecks() },
            Section("Shutdown restart delay bounds") { runShutdownRestartDelayBoundsChecks() },
            Section("MCP numeric value display") { runMCPNumericValueDisplayChecks() },
            Section("MCP refresh outcomes") { await runMCPRefreshOutcomeChecks() },
            Section("Usage totals bounds") { await runUsageTotalsBoundsChecks() },
            Section("Usage & cost") { await checkUsage() },
            Section("Usage load admission") { await runUsageLoadAdmissionChecks() },
            Section("Replies & reactions") { checkReactionsReply() },
            Section("Quoted row preview preparation") { await runQuotePreviewChecks() },
            Section("Agent avatar signals") { runAvatarSignalChecks() },
            Section("Centered chat identity") { runCenteredChatHeaderChecks() },
            Section("Avatar choices per Gateway") { runGatewayAvatarChoiceChecks() },
            Section("Agent reply targets") { checkReplyTargets() },
            Section("Reaction level") { checkReactionLevel() },
            Section("Gateway reactions") { checkGatewayReactions() },
            Section("Legacy reaction preference cap") { checkLegacyReactionPrefs() },
            Section("Agent questions") { runAgentQuestionChecks() },
            Section("Gateway config schema") { runConfigChecks() },
            Section("MCP editor validation") { runMCPEditorChecks() },
            Section("Dotted config revert") { await runDottedConfigRevertChecks() },
            Section("MCP tool link resolution") { runMCPToolLinkChecks() },
            Section("Sidebar split action visibility") { runSidebarSplitActionChecks() },
            Section("Sidebar split pane marker") { runSidebarSplitPaneChecks() },
            Section("Selected helper sidebar visibility") { runSidebarSelectedHelperChecks() },
            Section("Progress card") { runProgressCardChecks() },
            Section("Slash commands") { runSlashCommandChecks() },
            Section("Dictation") { await runDictationChecks() },
            Section("Device speech catalog") { await runDeviceSpeechCatalogChecks() },
            Section("Dictation target routing") { runDictationTargetChecks() },
            Section("Avatar seed read authorization") { runAvatarSeedReadAuthorization() },
            Section("Demo agent and model schema") { await runDemoAgentModelsSchemaChecks() },
            Section("Location context") { await runLocationContextChecks() },
            Section("Location transport") { runLocationTransportChecks() },
            Section("Location chat selection") { await runLocationSelectionChecks() },
            Section("Automations") { runAutomationChecks() },
            Section("Automation delete versus held load") { await runAutomationDeleteLoadChecks() },
            Section("Cron run timestamp IDs") { runCronRunTimestampIDChecks() },
            Section("Activity notification timestamps") { runActivityNotificationTimestampChecks() },
            Section("Web Push") { await runWebPushChecks() },
            Section("Find in chat") { await runFindInChatChecks() },
            Section("Symbol cache budgets") { runSymbolCacheChecks() },
            Section("Transcript premeasure budgets") { runTranscriptPremeasureChecks() },
            Section("Premeasure metadata admission") { runPremeasureMetadataChecks() },
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
            Section("Sidebar home chat group placement") { runSidebarHomeGroupMenuChecks() },
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
            Section("Checks pending lane diagnostics") { await runChecksPendingProgressChecks() },
        ]
        #if DEBUG
        sections.append(Section("Avatar phase diagnostics") { runAvatarPhaseDiagnosticsChecks() })
        sections.append(Section("Owned task work probe") { await runTaskScopeWorkProbeChecks() })
        sections.append(Section("Log Copy preparation") { await runGatewayLogCopyPreparationChecks() })
        sections.append(Section("Log Export preparation") { await runGatewayLogExportPreparationChecks() })
        sections.append(Section("Tools Inspector search preparation") { await runToolsInspectorSearchPreparationChecks() })
        sections.append(Section("UI readiness cancellation") { await runUITestReadinessCancellationChecks() })
        sections.append(Section("Cache inventory preparation") { await runCacheInventoryPreparationChecks() })
        if let index = sections.firstIndex(where: { $0.title == "Channel status staleness" }) {
            sections.insert(Section("Log page preparation") { await runGatewayLogPagePreparationChecks() }, at: index + 1)
        }
        if let index = sections.firstIndex(where: { $0.title == "Settings save reconciliation" }) {
            sections.insert(Section("Settings field search work") { await runSettingsFieldSearchChecks() }, at: index + 1)
        }
        if let index = sections.firstIndex(where: { $0.title == "Deferred dictation send ownership" }) {
            sections.insert(Section("Message edit completion ownership") { await runMessageEditCompletionOwnershipChecks() }, at: index + 1)
        }
        if let index = sections.firstIndex(where: { $0.title == "Channel status staleness" }) {
            sections.insert(Section("Channel QR ownership") { await runChannelQRLoginOwnershipChecks() }, at: index + 1)
        }
        #endif
        return sections
    }

    /// The built-in demo, first half.
    static let demoCore: [Section] = [
        Section("Built-in demo") { await runDemo() },
        Section("Location transport (demo)") { await runDemoLocationTransportChecks() },
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
    static var demoExtras: [Section] {
        var sections: [Section] = [
        Section("MCP refresh outcomes (demo)") { await runDemoMCPRefreshOutcomeChecks() },
        Section("Rewind history ownership (demo)") { await runDemoRewindHistoryOwnershipChecks() },
        Section("Session detail ownership (demo)") { await runDemoSessionDetailOwnershipChecks() },
        Section("Usage totals bounds (demo)") { await runDemoUsageTotalsBoundsChecks() },
        Section("Usage load admission (demo)") { await runDemoUsageLoadAdmissionChecks() },
        Section("Cron run timestamp IDs (demo)") { await runDemoCronRunTimestampIDChecks() },
        Section("Activity notification timestamps (demo)") { await runDemoActivityNotificationTimestampChecks() },
        Section("Context usage (demo)") { await runDemoContextUsageChecks() },
        Section("Deferred dictation send ownership (demo)") { await runDemoDeferredDictationSendChecks() },
        Section("Composer edit admission ownership (demo)") { await runDemoComposerEditAdmissionOwnershipChecks() },
        Section("Attachment draft ownership (demo)") { await runDemoAttachmentDraftOwnershipChecks() },
        Section("Device pairing action scopes (demo)") { await runDemoDevicePairingActionScopeChecks() },
        Section("Compact graduated header (demo)") { await runDemoCompactGraduatedHeaderChecks() },
        Section("Bounded cold rotor labels (demo)") { await runDemoColdRotorLabelChecks() },
        Section("Heartbeat event ordering (demo)") { await runDemoHeartbeatEventOrderingChecks() },
        Section("Ingress health issues (demo)") { await runDemoIngressHealthChecks() },
        Section("Gateway Logs Clear ownership (demo)") { await runDemoGatewayLogsClearOwnershipChecks() },
        Section("Health canceled admission (demo)") { await runDemoHealthCanceledAdmissionChecks() },
        Section("Health event ordering (demo)") { await runDemoHealthEventOrderingChecks() },
        Section("Shutdown restart delay bounds (demo)") { await runDemoShutdownRestartDelayBoundsChecks() },
        Section("Cold transcript geometry sources (demo)") { await runDemoColdTranscriptHeightEstimateChecks() },
        Section("Premeasure metadata admission (demo)") { await runDemoPremeasureMetadataChecks() },
        Section("Centered chat identity (demo)") { await runDemoCenteredChatHeaderChecks() },
        Section("Reply Last availability (demo)") { await runDemoReplyLastAvailabilityChecks() },
        Section("Slash suggestion announcements (demo)") { await runDemoSlashSuggestionAnnouncementChecks() },
        Section("Compact chat toolbar branches (demo)") { await runDemoCompactBranchToolbarChecks() },
        Section("Explicit transcript history navigation (demo)") { await runDemoTranscriptManualNavigationChecks() },
        Section("Image attachment preparation (demo)") { await runDemoAttachmentPreparationChecks() },
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
        Section("Channel action ownership (demo)") { await runDemoChannelActionOwnershipChecks() },
        Section("Tool diffs (demo)") { await runDemoToolDiffs() },
        Section("Tool cards (demo)") { await runDemoToolCards() },
        Section("Quoted row preview preparation (demo)") { await runDemoQuotePreviewChecks() },
        Section("Grouped message keyboard selection (demo)") { await runDemoGroupedMessageKeyboardChecks() },
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
        Section("Agent file reload ownership (demo)") { await runDemoAgentFileReloadOwnershipChecks() },
        Section("Agent file write authority (demo)") { await runDemoAgentFileWriteAuthorityChecks() },
        Section("Skills feedback ownership (demo)") { await runDemoSkillsFeedbackOwnershipChecks() },
        Section("Settings save (demo)") { await runSettingsSaveRebaseDemoChecks() },
        Section("Raw config editor ownership (demo)") { await runDemoRawConfigEditorChecks() },
        Section("Transcript headless fill (demo, #299)") { await runDemoTranscriptHeadlessFillChecks() },
        Section("Resize streaming inputs (demo, #353)") { await runDemoResizeStreamingInputs() },
        Section("Streaming clock rollback (demo, #649)") { await runDemoStreamingClockChecks() },
        Section("Capped recovery scan budget (demo)") { await runDemoCappedRecoveryBudget() },
        Section("Sidebar working avatar (demo)") { await runDemoSidebarWorking() },
        Section("Sidebar agent groups (demo)") { await runDemoSidebarAgentGroups() },
        Section("Sidebar group moves (demo, #416)") { await runDemoSidebarGroupMoves() },
        Section("Sidebar hierarchy (demo)") { await runDemoSidebarHierarchy() },
        Section("Sidebar reveal (demo)") { await runDemoSidebarReveal() },
        Section("Sidebar header interactions (demo)") { await runDemoSidebarHeaderInteractions() },
        Section("Sidebar split action visibility (demo)") { await runDemoSidebarSplitActions() },
        Section("MCP numeric value display (demo)") { await runDemoMCPNumericValueDisplayChecks() },
        Section("MCP servers (demo)") { await runDemoMCP() },
        Section("Plugin credential ownership (demo)") { await runDemoPluginCredentialOwnershipChecks() },
        Section("Dotted config revert (demo)") { await runDemoDottedConfigRevertChecks() },
        Section("MCP tool links (demo)") { await runDemoMCPToolLinks() },
        Section("Voice playback ownership (demo)") { await runDemoVoicePlaybackOwnershipChecks() },
        Section("Voice test feedback ownership (demo)") { await runDemoVoiceTestFeedbackOwnershipChecks() },
        Section("Voice / Read Aloud (demo)") { await runDemoVoice() },
        Section("Voice settings value bounds (demo)") { await runDemoVoiceSettingsValueBoundsChecks() },
        Section("Voice catalog request ownership (demo)") { await runDemoVoiceListRequestOwnershipChecks() },
        Section("Voice settings draft ownership (demo)") { await runDemoVoiceSettingsDraftChecks() },
        Section("Device speech settings (demo)") { await runDemoDeviceSpeechCatalogChecks() },
        Section("Chat windows (demo)") { await runDemoChatWindows() },
        Section("Chat window notification visibility (demo)") { await runDemoChatWindowNotificationVisibility() },
        Section("Unread in the open chat (demo)") { await runDemoVisibleChatRead() },
        Section("Dictation target routing (demo)") { await runDemoDictationTargetChecks() },
        Section("Location context opt-in (demo)") { await runDemoLocationContextChecks() },
        Section("Composer session title (demo)") { await runDemoComposerSessionTitleChecks() },
        Section("Transcript footer metadata (demo)") { await runDemoFooterMetadataChecks() },
    ]
        #if DEBUG
        sections.append(Section("Log Copy preparation (demo)") { await runDemoGatewayLogCopyPreparationChecks() })
        sections.append(Section("Log Export preparation (demo)") { await runDemoGatewayLogExportPreparationChecks() })
        sections.append(Section("Tools Inspector search preparation (demo)") { await runDemoToolsInspectorSearchPreparationChecks() })
        sections.append(Section("Cache inventory preparation (demo)") { await runDemoCacheInventoryPreparationChecks() })
        if let index = sections.firstIndex(where: { $0.title == "Channel status staleness (demo)" }) {
            sections.insert(Section("Log page preparation (demo)") { await runDemoGatewayLogPagePreparationChecks() }, at: index + 1)
        }
        if let index = sections.firstIndex(where: { $0.title == "Settings save (demo)" }) {
            sections.insert(Section("Settings field search work (demo)") { await runDemoSettingsFieldSearchChecks() }, at: index + 1)
        }
        if let index = sections.firstIndex(where: { $0.title == "Deferred dictation send ownership (demo)" }) {
            sections.insert(Section("Message edit completion ownership (demo)") { await runDemoMessageEditCompletionOwnershipChecks() }, at: index + 1)
        }
        if let index = sections.firstIndex(where: { $0.title == "Channel status staleness (demo)" }) {
            sections.insert(Section("Channel QR ownership (demo)") { await runDemoChannelQRLoginOwnershipChecks() }, at: index + 1)
        }
        #endif
        return sections
    }

    /// Against a (mock) Gateway, first half.
    static let liveCore: [LiveSection] = [
        LiveSection("Location transport (live)") { url, token in await runLiveLocationTransportChecks(url: url, token: token) },
        LiveSection(title: { "Live against \($0)" }) { url, token in await runLive(url: url, token: token) },
    ]

    /// Against a (mock) Gateway, second half.
    static let liveExtras: [LiveSection] = [
        LiveSection("Device load admission (live)") { url, token in await runLiveDeviceLoadAdmissionChecks(url: url, token: token) },
        LiveSection("Automation delete versus held load (live)") { url, token in await runLiveAutomationDeleteLoadChecks(url: url, token: token) },
        LiveSection("Command policy load admission (live)") { url, token in await runLiveExecPolicyLoadAdmissionChecks(url: url, token: token) },
        LiveSection("Cron run timestamp IDs (live)") { url, token in await runLiveCronRunTimestampIDChecks(url: url, token: token) },
        LiveSection("Ingress health issues (live)") { url, token in await runLiveIngressHealthChecks(url: url, token: token) },
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
