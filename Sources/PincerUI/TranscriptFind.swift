import PincerKit
import SwiftUI

/// Find in chat (⌘F): the query, its matches in the transcript and which one is selected.
/// Matching runs off the main actor, so typing stays responsive in long transcripts.
@MainActor
@Observable
final class TranscriptFind {
    static let thinkingKey = "pincer.find.includeThinking"
    static let toolsKey = "pincer.find.includeTools"

    private(set) var isPresented = false
    var query = "" {
        didSet {
            guard self.query != oldValue else { return }
            self.preferredMatch = nil
            self.scheduleSearch()
        }
    }
    var includeThinking = UserDefaults.standard.bool(forKey: TranscriptFind.thinkingKey) {
        didSet {
            UserDefaults.standard.set(self.includeThinking, forKey: Self.thinkingKey)
            self.scheduleSearch(delay: 0)
        }
    }
    var includeTools = UserDefaults.standard.bool(forKey: TranscriptFind.toolsKey) {
        didSet {
            UserDefaults.standard.set(self.includeTools, forKey: Self.toolsKey)
            self.scheduleSearch(delay: 0)
        }
    }

    private(set) var matches: [TranscriptSearch.Match] = []
    private var selection = TranscriptFindSelection()
    var current: Int? { self.selection.current }
    /// True while matches for the latest query and transcript are still being computed.
    private(set) var isSearching = false
    /// Bumped to put keyboard focus in the find field (⌘F while it's already open).
    private(set) var focusRequest = 0
    /// Bumped whenever the selected match should be scrolled into view.
    private(set) var revealRequest = 0

    @ObservationIgnored private var entries: [TranscriptEntry] = []
    @ObservationIgnored private var reasoningOff = false
    @ObservationIgnored private var rowIndex: [String: Int] = [:]
    @ObservationIgnored private var search: Task<Void, Never>?
    /// A search that should scroll to its match was replaced before finishing; the next one does it.
    @ObservationIgnored private var pendingReveal = false
    /// The match to select once it's found (a message search result being opened). Kept
    /// through transcript updates, since the first search can run before the transcript loads.
    @ObservationIgnored private var preferredMatch: TranscriptSearch.Match?

    var options: TranscriptSearch.Options {
        TranscriptSearch.Options(includeThinking: self.includeThinking && !self.reasoningOff,
                                 includeTools: self.includeTools,
                                 toolTextLimit: TranscriptMetrics.toolOutputLimit)
    }

    var currentMatch: TranscriptSearch.Match? {
        self.current.flatMap { self.matches.indices.contains($0) ? self.matches[$0] : nil }
    }

    /// "3 of 12", "No results", or nothing before a query is typed.
    var status: String {
        guard !TranscriptSearch.normalized(self.query).isEmpty else { return "" }
        if self.matches.isEmpty { return self.isSearching ? "" : L("No results") }
        return L("\((self.current ?? 0) + 1) of \(self.matches.count)")
    }

    /// The status as VoiceOver speaks it: "Result 3 of 12".
    var accessibilityStatus: String {
        guard !TranscriptSearch.normalized(self.query).isEmpty, !self.isSearching || !self.matches.isEmpty else { return "" }
        return AccessibilityText.findStatus(current: self.matches.isEmpty ? nil : (self.current ?? 0) + 1,
                                            total: self.matches.count)
    }

    /// What the transcript highlights. Only meaningful while the find bar is open.
    var highlight: TranscriptHighlight {
        guard self.isPresented else { return TranscriptHighlight() }
        let query = TranscriptSearch.normalized(self.query)
        guard !query.isEmpty else { return TranscriptHighlight() }
        return TranscriptHighlight(query: query, options: self.options, current: self.currentMatch,
                                   rows: Set(self.matches.map(\.entryId)), reveal: self.revealRequest)
    }

    // MARK: Actions

    func present() {
        self.isPresented = true
        self.focusRequest += 1
        self.scheduleSearch(delay: 0)
    }

    /// Opens Find showing `query`, with `match` selected and scrolled to once it's found (or,
    /// without one or if it's gone, the newest match).
    func present(query: String, select match: TranscriptSearch.Match?) {
        self.query = query
        self.preferredMatch = match
        self.selection.select(nil)
        self.matches = []
        self.pendingReveal = true
        self.isPresented = true
        self.focusRequest += 1
        self.scheduleSearch(delay: 0)
    }

    func dismiss() {
        self.preferredMatch = nil
        self.isPresented = false
        self.search?.cancel()
        self.pendingReveal = false
        self.isSearching = false
    }

    func next() { self.step(forward: true) }
    func previous() { self.step(forward: false) }

    private func step(forward: Bool) {
        self.preferredMatch = nil
        if !self.isPresented {
            self.present()
            return
        }
        guard let index = TranscriptSearch.step(from: self.current, count: self.matches.count, forward: forward) else { return }
        self.selection.select(index)
        self.revealRequest += 1
    }

    /// The transcript changed (a message arrived, history loaded) or the session's reasoning setting did.
    func update(entries: [TranscriptEntry], reasoningOff: Bool) {
        let optionsChanged = reasoningOff != self.reasoningOff
        self.entries = entries
        self.reasoningOff = reasoningOff
        guard self.isPresented else { return }
        self.scheduleSearch(delay: optionsChanged ? 0 : 0.25, reveal: false)
    }

    // MARK: Searching

    private func scheduleSearch(delay: Double = 0.12, reveal: Bool = true) {
        self.search?.cancel()
        guard self.isPresented else { return }
        let query = TranscriptSearch.normalized(self.query)
        guard !query.isEmpty else {
            self.matches = []
            self.selection.select(nil)
            self.isSearching = false
            self.pendingReveal = false
            return
        }
        self.pendingReveal = self.pendingReveal || reveal
        self.isSearching = true
        let entries = self.entries
        let options = self.options
        let capture = self.selection.capture(matches: self.matches, rowIndex: self.rowIndex, preferred: self.preferredMatch)
        let previous = capture.previous
        let preferred = capture.preferred
        self.search = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            let (matches, rowIndex) = await Task.detached(priority: .userInitiated) {
                (TranscriptSearch.matches(query, in: entries, options: options),
                 Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }))
            }.value
            guard !Task.isCancelled, let self else { return }
            let selected = self.selection.complete(capture, matches: matches, rowIndex: rowIndex)
            let foundPreferred = preferred != nil && selected.map { matches[$0] } == preferred
            if foundPreferred { self.preferredMatch = nil }
            self.matches = matches
            self.rowIndex = rowIndex
            self.isSearching = false
            let moved = selected.map { matches[$0] } != previous
            // Follow the selection as the query is typed; a message arriving doesn't move the reader.
            if selected != nil, self.pendingReveal || moved && (previous == nil || foundPreferred) { self.revealRequest += 1 }
            // Still waiting for the transcript to load: reveal once there are matches.
            self.pendingReveal = selected == nil && self.preferredMatch != nil
        }
    }
}

/// The find state the transcript list draws: which rows have matches and which match is selected.
struct TranscriptHighlight: Equatable {
    var query = ""
    var options = TranscriptSearch.Options()
    var current: TranscriptSearch.Match?
    /// Ids of rows with at least one match.
    var rows: Set<String> = []
    /// Changes whenever `current` should be scrolled into view, even if it's the same match.
    var reveal = 0

    var isActive: Bool { !self.query.isEmpty }

    /// Whether the selected match is in this row's thinking or tool calls.
    func revealsSteps(of rowId: String) -> Bool {
        guard let current, current.entryId == rowId else { return false }
        if case .message = current.section { return false }
        return true
    }
}

/// Highlights Find's matches in a row's text as the row is laid out. Counts occurrences per
/// section in the order they're drawn, so the selected match lands on the same one the search
/// counted.
@MainActor
final class TranscriptFindMarks {
    private var row = ""
    private var highlight = TranscriptHighlight()
    private var counts: [TranscriptSearch.Section: Int] = [:]

    func reset(row: String, highlight: TranscriptHighlight) {
        self.row = row
        self.highlight = highlight
        self.counts.removeAll()
    }

    /// `text` with every match highlighted, and the range of the selected match if it's in it.
    func mark(_ text: NSAttributedString, _ section: TranscriptSearch.Section) -> (NSAttributedString, NSRange?) {
        guard self.highlight.isActive, self.highlight.rows.contains(self.row) else { return (text, nil) }
        switch section {
        case .thinking where !self.highlight.options.includeThinking: return (text, nil)
        case .tool where !self.highlight.options.includeTools: return (text, nil)
        default: break
        }
        let ranges = TranscriptSearch.ranges(of: self.highlight.query, in: text.string)
        guard !ranges.isEmpty else { return (text, nil) }
        let start = self.counts[section, default: 0]
        self.counts[section] = start + ranges.count
        var selected: Int?
        if let current = self.highlight.current, current.entryId == self.row, current.section == section,
           current.occurrence >= start, current.occurrence < start + ranges.count
        {
            selected = current.occurrence - start
        }
        // Layouts share cached attributed strings, so mark a copy.
        let marked = NSMutableAttributedString(attributedString: text)
        for (index, range) in ranges.enumerated() {
            marked.addAttribute(.backgroundColor, value: index == selected ? TranscriptColors.findCurrent : TranscriptColors.findMatch, range: range)
            if index == selected { marked.addAttribute(.foregroundColor, value: TranscriptColors.findCurrentText, range: range) }
        }
        return (marked, selected.map { ranges[$0] })
    }

    /// Bottom of the line holding `range`, measured from the top of `text` wrapped at `width`.
    func lineBottom(of range: NSRange, in text: NSAttributedString, width: CGFloat) -> CGFloat {
        TranscriptText.size(text.attributedSubstring(from: NSRange(location: 0, length: NSMaxRange(range))), width: width).height
    }

    /// Records where the selected match sits in the row, when `match` is it and it's in the part
    /// just added to `stack`, `offset` below the part's top.
    func place(_ match: NSRange?, in text: NSAttributedString, width: CGFloat,
               stack: TranscriptLayoutBuilder.Stack, offset: CGFloat = 0, into layout: inout TranscriptRowLayout)
    {
        guard let match, let frame = stack.parts.last?.frame else { return }
        layout.matchY = frame.minY + offset + self.lineBottom(of: match, in: text, width: width)
    }
}

extension FocusedValues {
    /// Find in the chat that has focus, for the Find menu commands.
    @Entry var transcriptFind: TranscriptFind?
}

/// Floating find bar at the top of a chat.
struct TranscriptFindBar: View {
    @Bindable var find: TranscriptFind
    let reasoningOff: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L("Find in Chat"), text: self.$find.query)
                .textFieldStyle(.plain)
                .focused(self.$focused)
                .onSubmit { self.find.next() }
                .onKeyPress(.escape) {
                    self.find.dismiss()
                    return .handled
                }
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .accessibilityIdentifier("find-field")
            Text(self.find.status)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(self.find.accessibilityStatus)
                .accessibilityIdentifier("find-status")
                .onChange(of: self.find.accessibilityStatus) { _, status in AccessibilityAnnouncer.announce(status) }
            Menu {
                Toggle(L("Include Thinking"), systemImage: "brain", isOn: self.$find.includeThinking)
                    .disabled(self.reasoningOff)
                Toggle(L("Include Tool Output"), systemImage: "wrench.and.screwdriver", isOn: self.$find.includeTools)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle" + (self.filtered ? ".fill" : ""))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Search options"))
            .accessibilityLabel(L("Search Options"))
            #if os(iOS)
            // iOS draws a ControlGroup here as a segmented control whose buttons stay disabled
            // when the bar opens before matches arrive, so taps never reach them.
            HStack(spacing: -8) {
                self.previousButton
                self.nextButton
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .tint(.primary)
            .disabled(self.find.matches.isEmpty)
            // 44pt tap targets that overlap their neighbors, so the bar keeps its size.
            .padding(.horizontal, -4)
            .padding(.vertical, -6)
            #else
            ControlGroup {
                self.previousButton
                self.nextButton
            }
            .labelStyle(.iconOnly)
            .disabled(self.find.matches.isEmpty)
            .fixedSize()
            #endif
            Button(L("Done")) { self.find.dismiss() }
                .glassButton()
                .controlSize(.small)
        }
        .padding(.leading, Theme.Spacing.row)
        .padding(.trailing, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .glassSurface(in: Capsule())
        .padding(.horizontal, Theme.Spacing.row)
        .padding(.top, Theme.Spacing.md)
        .onAppear {
            self.focused = true
            // Again after the views appearing with it (a chat's composer) have claimed focus.
            DispatchQueue.main.async { self.focused = true }
        }
        .onChange(of: self.find.focusRequest) { self.focused = true }
    }

    private var filtered: Bool {
        (self.find.includeThinking && !self.reasoningOff) || self.find.includeTools
    }

    private var previousButton: some View {
        Button { self.find.previous() } label: { self.stepLabel(L("Find previous"), systemImage: "chevron.up") }
            .shortcut(.findPrevious)
            .help(ShortcutCommand.findPrevious.displayShortcut.map { L("Previous match (\($0))") } ?? L("Previous match"))
            .accessibilityIdentifier("find-previous")
    }

    private var nextButton: some View {
        Button { self.find.next() } label: { self.stepLabel(L("Find next"), systemImage: "chevron.down") }
            .shortcut(.findNext)
            .help(ShortcutCommand.findNext.displayShortcut.map { L("Next match (\($0))") } ?? L("Next match"))
            .accessibilityIdentifier("find-next")
    }

    private func stepLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            #if os(iOS)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            #endif
    }
}

#if os(macOS)
/// Edit ▸ Find items for the focused chat: Find in Chat (⌘F), Find Next (⌘G), Find Previous (⇧⌘G).
struct TranscriptFindCommands: Commands {
    @FocusedValue(\.transcriptFind) private var find
    @FocusedValue(\.replyToLast) private var replyToLast
    @FocusedValue(\.gatewayLogsSearch) private var logsSearch

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(self.find == nil && self.logsSearch != nil ? L("Find in Logs…") : L("Find in Chat…")) {
                if let find = self.find { find.present() } else { self.logsSearch?.wrappedValue = true }
            }
                .shortcut(.findInChat)
                .disabled(self.find == nil && self.logsSearch == nil)
            Button(L("Find Next")) { self.find?.next() }
                .shortcut(.findNext)
                .disabled(self.find == nil)
            Button(L("Find Previous")) { self.find?.previous() }
                .shortcut(.findPrevious)
                .disabled(self.find == nil)
            Divider()
            Button(L("Reply to Last Message")) { self.replyToLast?.perform() }
                .shortcut(.replyToLastMessage)
                .disabled(self.replyToLast?.isAvailable != true)
            Button(L("Edit Last Message")) { self.replyToLast?.editLast() }
                .shortcut(.editLastMessage)
                .disabled(self.replyToLast?.canRewrite != true)
            Button(L("Regenerate Last Reply")) { self.replyToLast?.regenerateLast() }
                .shortcut(.regenerateLastReply)
                .disabled(self.replyToLast?.canRewrite != true)
        }
    }
}
#endif

extension ReplyToLast {
    /// Only whether the Gateway allows rewinding, so streaming doesn't rebuild the main menu; the
    /// actions below check the transcript when run and do nothing if no message qualifies.
    var canRewrite: Bool { self.chat.canRewindMessages }

    /// Edit & Resend on the newest message you can edit.
    func editLast() {
        guard let item = self.chat.items.last(where: { self.chat.canEdit($0.id) }) else { return }
        _ = self.chat.beginEdit(item.id)
    }

    /// Regenerate on the last reply, when it can be.
    func regenerateLast() {
        guard let item = self.chat.items.last(where: { $0.role == .assistant && !$0.isPending }),
              self.chat.canRegenerate(item.id) else { return }
        let chat = self.chat
        Task { await chat.regenerate(item.id) }
    }
}
