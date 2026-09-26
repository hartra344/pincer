import PincerKit
import SwiftUI
import UniformTypeIdentifiers

/// Gateway Settings → Gateway Logs: a live tail of the Gateway's log file (`logs.tail`), polled
/// every 2 seconds while the page is showing. Lines stay in memory only.
struct GatewayLogsPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("gatewayLogs.levels") private var levelsRaw = GatewayLogLevels.defaults.rawValue
    @State private var showRaw = false
    @State private var query = ""
    @State private var appliedQuery = ""
    @State private var following = true
    /// The newest visible entry when following stopped, for "(N new)".
    @State private var lastSeenId = 0
    @State private var position = ScrollPosition(edge: .bottom)
    /// Buffered entries plus, while scrolled up, ones the buffer has since evicted, so the rows
    /// being read don't move. Recomputed only when the buffer, levels or search change.
    @State private var rows: [GatewayLogEntry] = []
    @State private var visible: [GatewayLogEntry] = []
    @State private var matches = 0
    @State private var totalLines = 0
    @State private var freshCount = 0
    @State private var searchRequest = false
    @State private var selection: Set<Int> = []
    @State private var selectionAnchor: Int?
    @State private var confirmExport = false
    @State private var exportLines: [GatewayLogEntry] = []
    @State private var exportDocument: ExportedFile?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var model: GatewayLogsModel { self.gateway.gatewayLogs }
    private var levels: GatewayLogLevels { GatewayLogLevels(rawValue: self.levelsRaw) }

    private struct FilterKey: Equatable {
        let first: Int?
        let last: Int?
        let count: Int
        let levels: Int
        let query: String
    }

    private struct PollKey: Hashable {
        let active: Bool
        let retry: Int
    }

    private var sceneActive: Bool {
        #if os(macOS)
        // macOS windows stay visible while another app is frontmost.
        self.scenePhase != .background
        #else
        self.scenePhase == .active
        #endif
    }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        let visible = self.visible
        let filterKey = FilterKey(first: model.entries.first?.id, last: model.entries.last?.id, count: model.entries.count,
                                  levels: self.levelsRaw, query: self.appliedQuery)
        Group {
            if !model.supported {
                ContentUnavailableView("Gateway Logs Aren't Available", systemImage: "doc.text.magnifyingglass",
                                       description: Text("This gateway doesn't offer logs.tail. Update OpenClaw to view its logs here."))
            } else {
                self.content(model, visible: visible, connected: connected)
            }
        }
        .navigationTitle("Gateway Logs")
        .onChange(of: filterKey, initial: true) { self.refresh() }
        #if os(macOS)
        .focusedSceneValue(\.gatewayLogsSearch, model.supported ? self.$searchRequest : nil)
        .onChange(of: self.searchRequest) {
            guard self.searchRequest else { return }
            self.searchRequest = false
            self.searchFocused = true
        }
        #endif
        .toolbar { self.toolbar(model, visible: visible, connected: connected) }
        #if os(iOS)
        .searchable(text: self.$query, prompt: "Search Logs")
        #endif
        .task(id: PollKey(active: connected && !model.isPaused && self.sceneActive, retry: model.retryGeneration)) {
            guard connected, !model.isPaused, self.sceneActive else { return }
            await model.run()
        }
        .task(id: self.query) {
            guard self.query != self.appliedQuery else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self.appliedQuery = self.query
        }
        .confirmationDialog("Export \(self.exportLines.count.formatted()) line\(self.exportLines.count == 1 ? "" : "s")?",
                            isPresented: self.$confirmExport, titleVisibility: .visible) {
            Button("Export") {
                let data = Data(GatewayLogs.rawText(self.exportLines).utf8)
                self.exportDocument = ExportedFile(name: GatewayLogs.exportFilename(gatewayName: self.gateway.profile.name),
                                                   data: data)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Gateway logs are redacted by the gateway, but they can still contain hostnames, file paths and message content. Review them before sharing.")
        }
        .fileExporter(
            isPresented: Binding(get: { self.exportDocument != nil }, set: { if !$0 { self.exportDocument = nil } }),
            document: self.exportDocument,
            contentType: self.exportDocument?.contentType ?? .plainText,
            defaultFilename: self.exportDocument?.name) { _ in
                self.exportDocument = nil
                self.exportLines = []
            }
    }

    // MARK: Content

    private func content(_ model: GatewayLogsModel, visible: [GatewayLogEntry], connected: Bool) -> some View {
        VStack(spacing: 0) {
            self.banner(model, connected: connected)
            if model.entries.isEmpty {
                self.emptyState(model, connected: connected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.matches == 0, model.lineCount > 0 {
                ContentUnavailableView {
                    Label("No lines match", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("\(model.lineCount.formatted()) lines are hidden by the level toggles or search.")
                } actions: {
                    Button("Clear Filters") { self.clearFilters() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                self.logList(visible)
            }
        }
        #if os(macOS)
        .safeAreaInset(edge: .top, spacing: 0) { self.filterBar(model) }
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) { self.statusBar(model, connected: connected) }
    }

    private func logList(_ visible: [GatewayLogEntry]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visible) { entry in
                    GatewayLogRow(entry: entry, showRaw: self.showRaw, selected: self.selection.contains(entry.id))
                        .contentShape(Rectangle())
                        #if os(macOS)
                        .onTapGesture { self.select(entry, in: visible) }
                        #endif
                        .contextMenu {
                            if !entry.isMarker {
                                Button("Copy", systemImage: "doc.on.doc") {
                                    Clipboard.copy(GatewayLogs.copyText(self.targets(entry, in: visible)))
                                }
                                Button("Copy Raw", systemImage: "curlybraces") {
                                    Clipboard.copy(GatewayLogs.rawText(self.targets(entry, in: visible)))
                                }
                            }
                        }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollPosition(self.$position)
        // Only the first layout starts at the bottom; following the tail is done below, so
        // content doesn't shift under a reader who scrolled up.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                          atBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 24)
        } action: { old, new in
            if new.atBottom {
                if !self.following {
                    self.following = true
                    self.refresh()
                    self.scrollToLatestIfFollowing()
                }
            } else if new.offset < old.offset - 1, new.contentHeight >= old.contentHeight {
                // Moved up without the content shrinking: the reader scrolled, by any means.
                self.stopFollowing()
            }
        }
        .onChange(of: visible.last?.id) { self.scrollToLatestIfFollowing() }
        .onChange(of: self.showRaw) { self.scrollToLatestIfFollowing() }
        .overlay(alignment: .bottomTrailing) {
            if !self.following {
                let fresh = self.freshCount
                Button {
                    self.following = true
                    self.refresh()
                    self.position.scrollTo(edge: .bottom)
                } label: {
                    Label(fresh > 0 ? "Jump to Latest (\(fresh.formatted()) new)" : "Jump to Latest",
                          systemImage: "arrow.down.to.line")
                        .font(.callout)
                }
                .glassButton()
                .padding(12)
                .transition(.opacity)
            }
        }
        #if os(macOS)
        .focusable()
        .focused(self.$listFocused)
        .focusEffectDisabled()
        .onCopyCommand {
            let text = GatewayLogs.copyText(visible.filter { self.selection.contains($0.id) })
            return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
        }
        #endif
    }

    private struct ScrollMetrics: Equatable {
        let offset: CGFloat
        let contentHeight: CGFloat
        let atBottom: Bool
    }

    private func stopFollowing() {
        guard self.following else { return }
        self.following = false
        self.lastSeenId = self.visible.last?.id ?? 0
        self.freshCount = 0
    }

    private func scrollToLatestIfFollowing() {
        guard self.following else { return }
        self.position.scrollTo(edge: .bottom)
    }

    /// Rebuilds the filtered rows: once per poll, level change or (debounced) search change.
    private func refresh() {
        let entries = self.model.entries
        if self.following || entries.isEmpty {
            self.rows = entries
        } else {
            let floor = entries.first?.id ?? .max
            let retained = self.rows.prefix { $0.id < floor }.suffix(GatewayLogsModel.defaultCapacity)
            self.rows = Array(retained) + entries
        }
        self.visible = GatewayLogs.filter(self.rows, levels: self.levels, query: self.appliedQuery)
        var matches = 0
        var fresh = 0
        for entry in self.visible where !entry.isMarker {
            matches += 1
            if entry.id > self.lastSeenId { fresh += 1 }
        }
        self.matches = matches
        self.totalLines = GatewayLogs.lineCount(self.rows)
        self.freshCount = self.following ? 0 : fresh
    }

    /// The row's lines for Copy: the selection when the row is in it, else the row.
    private func targets(_ entry: GatewayLogEntry, in visible: [GatewayLogEntry]) -> [GatewayLogEntry] {
        guard self.selection.contains(entry.id), self.selection.count > 1 else { return [entry] }
        return visible.filter { self.selection.contains($0.id) }
    }

    #if os(macOS)
    /// Click selects, ⌘-click toggles, ⇧-click extends from the last click.
    private func select(_ entry: GatewayLogEntry, in visible: [GatewayLogEntry]) {
        self.listFocused = true
        guard !entry.isMarker else { return }
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = self.selectionAnchor,
           let from = visible.firstIndex(where: { $0.id == anchor }),
           let to = visible.firstIndex(where: { $0.id == entry.id })
        {
            let range = min(from, to)...max(from, to)
            self.selection = Set(visible[range].filter { !$0.isMarker }.map(\.id))
        } else if flags.contains(.command) {
            if self.selection.contains(entry.id) { self.selection.remove(entry.id) } else { self.selection.insert(entry.id) }
            self.selectionAnchor = entry.id
        } else {
            self.selection = self.selection == [entry.id] ? [] : [entry.id]
            self.selectionAnchor = entry.id
        }
    }
    #endif

    private func clearFilters() {
        self.levelsRaw = GatewayLogLevels.all.rawValue
        self.query = ""
        self.appliedQuery = ""
    }

    private func levelBinding(_ level: GatewayLogLevel) -> Binding<Bool> {
        Binding(get: { self.levels.contains(level) }, set: { on in
            var levels = self.levels
            if on != levels.contains(level) { levels.toggle(level) }
            self.levelsRaw = levels.rawValue
        })
    }

    // MARK: States

    @ViewBuilder private func banner(_ model: GatewayLogsModel, connected: Bool) -> some View {
        if let failure = model.failure, failure.isUnavailable {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
        } else if let failure = model.failure, !model.entries.isEmpty {
            HStack {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Spacer(minLength: 8)
                Button("Try Again") { model.retry() }
                    .disabled(!connected)
            }
            .font(.callout)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.1))
        }
    }

    @ViewBuilder private func emptyState(_ model: GatewayLogsModel, connected: Bool) -> some View {
        if !connected {
            ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                   description: Text("Connect to the gateway to see its logs."))
        } else if let failure = model.failure, !failure.isUnavailable {
            ContentUnavailableView {
                Label("Couldn't Load Logs", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.message)
            } actions: {
                Button("Try Again") { model.retry() }
            }
        } else if !model.hasLoaded {
            ProgressView()
        } else {
            ContentUnavailableView {
                Label("No log output yet", systemImage: "doc.text.magnifyingglass")
            } description: {
                if let file = model.file {
                    Text("New lines written to \(file) appear here.")
                } else {
                    Text("New lines appear here as the gateway writes them.")
                }
            }
        }
    }

    // MARK: Bars

    #if os(macOS)
    private func filterBar(_ model: GatewayLogsModel) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Logs", text: self.$query)
                    .textFieldStyle(.plain)
                    .focused(self.$searchFocused)
                    .onSubmit { self.appliedQuery = self.query }
                if !self.query.isEmpty {
                    Button { self.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear Search")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 160, maxWidth: 260)
            ForEach(GatewayLogLevel.allCases) { level in
                Toggle(isOn: self.levelBinding(level)) {
                    Text("\(level.label) \(model.count(level).formatted())")
                        .font(.caption.monospacedDigit())
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show \(level.rawValue) lines")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
    #endif

    private func statusBar(_ model: GatewayLogsModel, connected: Bool) -> some View {
        let matches = self.matches
        let total = self.totalLines
        return HStack(spacing: 8) {
            Text(matches == total
                ? "\(total.formatted()) line\(total == 1 ? "" : "s")"
                : "\(matches.formatted()) of \(total.formatted()) lines")
                .monospacedDigit()
            if let status = self.status(model, connected: connected) {
                Text(status).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let file = model.file {
                Text(file)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(file)
                Button { Clipboard.copy(file) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy Log File Path")
                    .accessibilityLabel("Copy Log File Path")
            }
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func status(_ model: GatewayLogsModel, connected: Bool) -> String? {
        if !connected { return model.entries.isEmpty ? nil : "Not connected. Showing lines received earlier." }
        if model.isPaused { return "Paused" }
        if model.showsRecentOnly { return "Showing the most recent lines" }
        return model.hasLoaded ? "Live" : nil
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ model: GatewayLogsModel, visible: [GatewayLogEntry], connected: Bool) -> some ToolbarContent {
        if model.supported {
            ToolbarItem {
                Button {
                    model.isPaused.toggle()
                } label: {
                    Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }
                .disabled(!connected)
                .help(model.isPaused ? "Resume" : "Pause")
            }
            #if os(macOS)
            ToolbarItem {
                Toggle(isOn: self.$showRaw) { Label("Show Raw", systemImage: "curlybraces") }
                    .help("Show Raw Lines")
            }
            ToolbarItem {
                Button { self.clear(model) } label: { Label("Clear", systemImage: "trash") }
                    .disabled(model.entries.isEmpty)
                    .help("Clear")
            }
            ToolbarItem {
                Button { self.export(visible) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .disabled(self.matches == 0)
                    .help("Export…")
            }
            #else
            ToolbarItem {
                Menu {
                    ForEach(GatewayLogLevel.allCases) { level in
                        Toggle("\(level.label) (\(model.count(level).formatted()))", isOn: self.levelBinding(level))
                    }
                } label: {
                    Label("Levels", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem {
                Menu {
                    Toggle(isOn: self.$showRaw) { Label("Show Raw", systemImage: "curlybraces") }
                    Button("Copy Visible Lines", systemImage: "doc.on.doc") {
                        Clipboard.copy(GatewayLogs.copyText(visible))
                    }
                    .disabled(self.matches == 0)
                    Button("Export…", systemImage: "square.and.arrow.up") { self.export(visible) }
                        .disabled(self.matches == 0)
                    Button("Clear", systemImage: "trash", role: .destructive) { self.clear(model) }
                        .disabled(model.entries.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
            #endif
        }
    }

    private func clear(_ model: GatewayLogsModel) {
        model.clear()
        self.selection = []
        self.following = true
        self.refresh()
    }

    private func export(_ visible: [GatewayLogEntry]) {
        self.exportLines = visible.filter { !$0.isMarker }
        guard !self.exportLines.isEmpty else { return }
        self.confirmExport = true
    }
}

// MARK: Row

private struct GatewayLogRow: View, Equatable {
    let entry: GatewayLogEntry
    let showRaw: Bool
    let selected: Bool

    private static let badgeWidth: CGFloat = 46
    private static let subsystemLimit = 24

    var body: some View {
        Group {
            switch self.entry.kind {
            case let .marker(text):
                HStack(spacing: 8) {
                    VStack { Divider() }
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack { Divider() }
                }
                .padding(.vertical, 6)
            case .line:
                if self.showRaw {
                    Text(self.entry.displayRaw)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    self.parsed
                }
            }
        }
        .font(Self.font)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(self.background)
    }

    private static var font: Font {
        #if os(macOS)
        .callout.monospaced()
        #else
        .footnote.monospaced()
        #endif
    }

    private var parsed: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let label = GatewayLogTime.label(self.entry) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .help(self.entry.timeText ?? "")
            }
            GatewayLogBadge(level: self.entry.level)
                .frame(width: Self.badgeWidth)
            if let subsystem = self.entry.subsystem {
                Text(subsystem.count > Self.subsystemLimit ? subsystem.prefix(Self.subsystemLimit - 1) + "…" : subsystem)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(subsystem)
            }
            Text(self.entry.displayMessage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var background: some View {
        if self.selected {
            Color.accentColor.opacity(0.22)
        } else {
            switch self.entry.level {
            case .error: Color.red.opacity(0.06)
            case .fatal: Color.red.opacity(0.12)
            default: Color.clear
            }
        }
    }
}

private struct GatewayLogBadge: View {
    let level: GatewayLogLevel?

    var body: some View {
        if let level {
            switch level {
            case .fatal:
                Text(level.label)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .background(Color.red, in: Capsule())
            default:
                Text(level.label)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(self.style(level))
            }
        } else {
            Text(" ").accessibilityHidden(true)
        }
    }

    private func style(_ level: GatewayLogLevel) -> AnyShapeStyle {
        switch level {
        case .trace: AnyShapeStyle(.tertiary)
        case .debug: AnyShapeStyle(.secondary)
        case .info: AnyShapeStyle(Color.blue)
        case .warn: AnyShapeStyle(Color.orange)
        case .error, .fatal: AnyShapeStyle(Color.red)
        }
    }
}

/// Local HH:mm:ss.SSS for today's lines, "MMM d HH:mm:ss" otherwise; the raw text when unparseable.
@MainActor
private enum GatewayLogTime {
    private static let today: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let older: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d HH:mm:ss")
        return formatter
    }()

    static func label(_ entry: GatewayLogEntry) -> String? {
        guard let time = entry.time else { return entry.timeText }
        return Calendar.current.isDateInToday(time) ? Self.today.string(from: time) : Self.older.string(from: time)
    }
}

extension FocusedValues {
    /// Set by a showing Gateway Logs page; Edit ▸ Find sets it to focus the log search.
    @Entry var gatewayLogsSearch: Binding<Bool>?
}
