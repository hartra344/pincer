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
        didSet { if self.query != oldValue { self.scheduleSearch() } }
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
    private(set) var current: Int?
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
        if self.matches.isEmpty { return self.isSearching ? "" : "No results" }
        return "\((self.current ?? 0) + 1) of \(self.matches.count)"
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

    func dismiss() {
        self.isPresented = false
        self.search?.cancel()
        self.pendingReveal = false
        self.isSearching = false
    }

    func next() { self.step(forward: true) }
    func previous() { self.step(forward: false) }

    private func step(forward: Bool) {
        if !self.isPresented {
            self.present()
            return
        }
        guard let index = TranscriptSearch.step(from: self.current, count: self.matches.count, forward: forward) else { return }
        self.current = index
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
            self.current = nil
            self.isSearching = false
            self.pendingReveal = false
            return
        }
        self.pendingReveal = self.pendingReveal || reveal
        self.isSearching = true
        let entries = self.entries
        let options = self.options
        let previous = self.currentMatch
        let previousRow = previous.flatMap { self.rowIndex[$0.entryId] }
        self.search = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            let (matches, rowIndex) = await Task.detached(priority: .userInitiated) {
                (TranscriptSearch.matches(query, in: entries, options: options),
                 Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }))
            }.value
            guard !Task.isCancelled, let self else { return }
            let selected = TranscriptSearch.reselect(previous, in: matches, rowIndex: rowIndex, near: previousRow)
            self.matches = matches
            self.rowIndex = rowIndex
            self.isSearching = false
            let moved = selected.map { matches[$0] } != previous
            self.current = selected
            // Follow the selection as the query is typed; a message arriving doesn't move the reader.
            if selected != nil, self.pendingReveal || moved && previous == nil { self.revealRequest += 1 }
            self.pendingReveal = false
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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in Chat", text: self.$find.query)
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
                .accessibilityIdentifier("find-status")
            Menu {
                Toggle("Include Thinking", systemImage: "brain", isOn: self.$find.includeThinking)
                    .disabled(self.reasoningOff)
                Toggle("Include Tool Output", systemImage: "wrench.and.screwdriver", isOn: self.$find.includeTools)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle" + (self.filtered ? ".fill" : ""))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Search options")
            .accessibilityLabel("Search Options")
            ControlGroup {
                Button("Previous", systemImage: "chevron.up") { self.find.previous() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .help("Previous match (⇧⌘G)")
                Button("Next", systemImage: "chevron.down") { self.find.next() }
                    .keyboardShortcut("g", modifiers: .command)
                    .help("Next match (⌘G)")
            }
            .labelStyle(.iconOnly)
            .disabled(self.find.matches.isEmpty)
            .fixedSize()
            Button("Done") { self.find.dismiss() }
                .glassButton()
                .controlSize(.small)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .glassSurface(in: Capsule())
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .onAppear { self.focused = true }
        .onChange(of: self.find.focusRequest) { self.focused = true }
    }

    private var filtered: Bool {
        (self.find.includeThinking && !self.reasoningOff) || self.find.includeTools
    }
}

#if os(macOS)
/// Edit ▸ Find items for the focused chat: Find in Chat (⌘F), Find Next (⌘G), Find Previous (⇧⌘G).
struct TranscriptFindCommands: Commands {
    @FocusedValue(\.transcriptFind) private var find
    @FocusedValue(\.gatewayLogsSearch) private var logsSearch

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(self.find == nil && self.logsSearch != nil ? "Find in Logs…" : "Find in Chat…") {
                if let find = self.find { find.present() } else { self.logsSearch?.wrappedValue = true }
            }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(self.find == nil && self.logsSearch == nil)
            Button("Find Next") { self.find?.next() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(self.find == nil)
            Button("Find Previous") { self.find?.previous() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(self.find == nil)
        }
    }
}
#endif
