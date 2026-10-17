import PincerKit
import SwiftUI

/// The Browser page header, in the Control UI's order: Back, Forward, Reload, the address field, Open in
/// Browser, ⋯. Every action is a Kit call; this view only applies state and never blocks on the network.
struct BrowserControlsRow: View {
    let model: BrowserPanelModel
    @Binding var newTab: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.chatPaneIsActive) private var paneIsActive
    @State private var draft = ""
    @State private var invalidAddress = false
    @State private var closingTab = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloaded: URL?
    @State private var noteDismissed = false
    /// Set from Return until the gateway answers, so the typed address survives a refusal.
    @State private var keepDraft = false
    @FocusState private var focused: Bool

    private var isCompact: Bool { self.sizeClass == .compact }

    private var canAct: Bool {
        guard self.model.selectedTargetId != nil, !self.model.selectedPageMissing else { return false }
        switch self.model.status {
        case .live, .idle, .loading, .reconnecting: return true
        case .needsFullManagement, .notRunning, .navigationBlocked, .unstreamable, .failed: return false
        }
    }

    /// Typing an address works from a blocked or failed page too: that's how you leave it.
    private var canNavigate: Bool {
        guard self.model.selectedTargetId != nil, !self.model.selectedPageMissing else { return false }
        return self.model.status != .needsFullManagement && self.model.status != .notRunning
    }

    /// An empty or error message already says what's wrong, so the pill would only repeat it.
    private var showsStatusPill: Bool {
        switch self.model.status {
        case .needsFullManagement, .notRunning, .failed, .navigationBlocked, .unstreamable: return false
        case .live, .idle, .loading, .reconnecting:
            return !(self.model.selectedPageMissing
                || (self.model.tabs.isEmpty && self.model.selectedTargetId == nil))
        }
    }

    private var navigationHelp: String? {
        self.model.historyUnavailable ? L("Back and Forward are turned off on this gateway") : nil
    }

    /// One line under the row, never stacked: the action error, else the one-time "turned off" note.
    private var caption: String? {
        if let error = self.model.actionError { return error }
        if self.model.historyUnavailable, !self.noteDismissed { return Self.historyNote }
        return nil
    }

    private static var historyNote: String { L("Back and Forward are turned off on this gateway.") }

    private var openableURL: URL? {
        guard let url = self.model.pageURL, url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    var body: some View {
        if self.model.hasAdmin, self.model.status != .needsFullManagement {
            self.row
        }
    }

    private var row: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                self.history
                if !self.isCompact { self.reloadButton }
                self.addressField
                if !self.isCompact, let url = self.openableURL {
                    Button(L("Open in Browser"), systemImage: "arrow.up.forward.square") { Self.open(url) }
                        .help(L("Open in Browser"))
                }
                if self.model.isDownloading { self.downloadProgress }
                self.moreMenu
                if !self.isCompact, self.showsStatusPill { self.statusPill }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            #if os(iOS)
            .controlSize(.large)
            #endif
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            if self.invalidAddress {
                Text("Enter a web address", bundle: .module)
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.lg).padding(.bottom, Theme.Spacing.sm)
                    .accessibilityAddTraits(.isStaticText)
            }
            if self.model.isNavigating {
                ProgressView().progressViewStyle(.linear).controlSize(.mini)
                    .accessibilityLabel(L("Loading"))
            }
            if let error = self.caption {
                Text(error)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.lg).padding(.bottom, Theme.Spacing.sm)
                    .accessibilityAddTraits(.isStaticText)
                    .task(id: error == Self.historyNote) {
                        guard error == Self.historyNote else { return }
                        try? await Task.sleep(for: .seconds(6))
                        self.noteDismissed = true
                    }
            }
        }
        .onAppear { self.revert() }
        .onChange(of: self.model.pageURL) { if !self.focused || self.keepDraft { self.keepDraft = false; self.revert() } }
        .onChange(of: self.focused) { _, isFocused in if isFocused { Self.selectAll() } else if !self.keepDraft { self.revert() } }
        .onChange(of: self.draft) { self.invalidAddress = false }
        .confirmationDialog(L("Close this tab in the agent's browser?"), isPresented: self.$closingTab, titleVisibility: .visible) {
            Button(L("Close Tab"), role: .destructive) {
                guard let id = self.model.selectedTargetId else { return }
                Task { await self.model.closeTab(id) }
            }
        } message: {
            Text("The agent may be using it.", bundle: .module)
        }
        .background {
            // Only the focused chat pane's panel takes ⌘L.
            if self.paneIsActive {
                Button(ShortcutCommand.focusAddress.title) { self.focused = true }
                    .shortcut(.focusAddress)
                    .opacity(0).accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .modifier(PageSaver(file: self.$downloaded))
        .onDisappear { self.downloadTask?.cancel(); self.model.cancelDownload() }
    }

    private var history: some View {
        Group {
            Button(L("Back"), systemImage: "chevron.left") { Task { await self.model.goBack() } }
            Button(L("Forward"), systemImage: "chevron.right") { Task { await self.model.goForward() } }
        }
        .disabled(!self.canAct || self.model.historyUnavailable || self.model.isNavigating)
        .help(self.navigationHelp ?? "")
    }

    private var reloadButton: some View {
        Group {
            if self.model.isNavigating {
                ProgressView().controlSize(.small).accessibilityLabel(L("Loading"))
            } else {
                Button(L("Reload Page"), systemImage: "arrow.clockwise") { Task { await self.model.reload() } }
                    .help(L("Reload Page"))
                    .disabled(!self.canAct || self.model.pageURL == nil)
            }
        }
    }

    private var addressField: some View {
        TextField(L("Go to an address in the agent's browser"), text: self.$draft)
            .textFieldStyle(.plain)
            .font(.caption)
            .lineLimit(1)
            .focused(self.$focused)
            .disabled(!self.canNavigate)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .submitLabel(.go)
            #endif
            .onSubmit(self.submit)
            #if os(macOS)
            .onExitCommand { self.keepDraft = false; self.revert(); self.focused = false }
            #endif
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(L("Page address"))
            .accessibilityValue(self.model.isNavigating ? L("Loading") : self.model.pageURL?.absoluteString ?? L("None"))
    }

    private var downloadProgress: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.small)
            Text("Downloading…", bundle: .module).font(.caption).foregroundStyle(.secondary)
            Button(L("Cancel Download"), systemImage: "xmark.circle.fill") { self.downloadTask?.cancel(); self.model.cancelDownload() }
                .help(L("Cancel Download"))
        }
        .accessibilityElement(children: .contain)
    }

    private var moreMenu: some View {
        Menu {
            if self.isCompact {
                Button(L("Reload Page"), systemImage: "arrow.clockwise") { Task { await self.model.reload() } }
                    .disabled(!self.canAct || self.model.pageURL == nil)
                if let url = self.openableURL {
                    Button(L("Open in Browser"), systemImage: "arrow.up.forward.square") { Self.open(url) }
                }
                Divider()
            }
            Button(L("Copy URL"), systemImage: "doc.on.doc") { self.copyURL() }
                .disabled(self.model.pageURL == nil)
            Button(L("Download Page"), systemImage: "arrow.down.circle", action: self.download)
                .disabled(!self.canAct || self.model.isDownloading)
            Divider()
            Button(L("New Tab…"), systemImage: "plus") { self.newTab = true }
                .disabled(self.model.status == .needsFullManagement)
            Button(L("Close Tab"), systemImage: "xmark.circle", role: .destructive) { self.closingTab = true }
                .disabled(!self.canAct)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("More"))
        .accessibilityLabel(L("More page actions"))
    }

    private var statusPill: some View {
        BrowserStatusPill(status: self.model.status, attempt: self.model.retryAttempt)
    }

    private func submit() {
        let text = self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BrowserURLDraft.normalize(text) != nil else {
            self.invalidAddress = true
            return
        }
        self.keepDraft = true
        self.focused = false
        Task {
            await self.model.navigate(to: text)
            if self.model.actionError == nil {
                self.keepDraft = false
                self.revert()
            } else {
                self.focused = true
            }
        }
    }

    private func revert() {
        self.draft = self.model.pageURL?.absoluteString ?? ""
        self.invalidAddress = false
    }

    private func copyURL() {
        guard let url = self.model.pageURL?.absoluteString else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        #else
        UIPasteboard.general.string = url
        #endif
    }

    private func download() {
        self.downloadTask?.cancel()
        self.downloadTask = Task {
            if let file = try? await self.model.downloadCurrentPage(), !Task.isCancelled {
                self.downloaded = file
            }
        }
    }

    private static func selectAll() {
        DispatchQueue.main.async {
            #if os(macOS)
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            #else
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
            #endif
        }
    }

    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

/// Hands a downloaded temp file to the system: a save panel on macOS, a Files picker on iOS. The file is
/// moved, never read into memory.
private struct PageSaver: ViewModifier {
    @Binding var file: URL?

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onChange(of: self.file) { _, new in
            guard let new else { return }
            self.file = nil
            Self.save(new)
        }
        #else
        content.sheet(item: Binding(get: { self.file.map(DownloadedPage.init) }, set: { if $0 == nil { self.file = nil } })) { shared in
            ShareSheet(file: shared.url) {
                try? FileManager.default.removeItem(at: shared.url)
                self.file = nil
            }
            .presentationDetents([.medium, .large])
        }
        #endif
    }

    #if os(macOS)
    private static func save(_ temp: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = temp.lastPathComponent
        panel.begin { response in
            let destination = response == .OK ? panel.url : nil
            Task.detached(priority: .utility) {
                defer { try? FileManager.default.removeItem(at: temp) }
                guard let destination else { return }
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.moveItem(at: temp, to: destination)
            }
        }
    }
    #endif
}

/// "New Tab": a one-line address prompt. Owned by `WorkspacePanel` so the page picker's "+" opens it too.
struct NewTabPrompt: ViewModifier {
    @Binding var isPresented: Bool
    let model: BrowserPanelModel
    @State private var address = ""

    func body(content: Content) -> some View {
        content.alert(L("New Tab"), isPresented: self.$isPresented) {
            TextField(L("Address"), text: self.$address)
            Button(L("Open")) {
                let text = self.address.trimmingCharacters(in: .whitespacesAndNewlines)
                self.address = ""
                Task { await self.model.openTab(url: text) }
            }
            .disabled(BrowserURLDraft.normalize(self.address.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
            Button(L("Cancel"), role: .cancel) { self.address = "" }
        } message: {
            Text("Opens in the agent's browser.", bundle: .module)
        }
    }
}

#if os(iOS)
private struct DownloadedPage: Identifiable {
    let url: URL
    var id: URL { self.url }
}

/// The system share sheet, which includes Save to Files, AirDrop and Mail.
private struct ShareSheet: UIViewControllerRepresentable {
    let file: URL
    let done: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [self.file], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in self.done() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
