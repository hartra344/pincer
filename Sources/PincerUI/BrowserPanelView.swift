import PincerKit
import SwiftUI

/// The agent's browser, view-only: a toolbar row (navigation arrives in a later PR), the page URL, and the
/// latest frame. Frames are decoded off-main by Kit; this view only draws `model.frame.image`.
struct BrowserPanelView: View {
    let model: BrowserPanelModel
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.openGatewaySettings) private var openGatewaySettings
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var size = CGSize.zero
    @State private var appeared = false
    @State private var viewerID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            BrowserToolbarRow(model: self.model)
            Divider()
            self.content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { self.size = $0; self.updateVisibility() }
        }
        .onAppear {
            self.appeared = true
            self.updateVisibility()
            Task { await self.model.refreshTabs() }
        }
        .onDisappear {
            self.appeared = false
            self.model.setVisible(false, pixelSize: .zero, viewer: self.viewerID)
        }
        .onChange(of: self.scenePhase) { self.updateVisibility() }
    }

    /// The stream runs only while the panel is on screen and the app is active.
    private func updateVisibility() {
        let visible = self.appeared && self.scenePhase == .active && self.size.width > 0
        let pixels = CGSize(width: self.size.width * self.displayScale, height: self.size.height * self.displayScale)
        self.model.setVisible(visible, pixelSize: visible ? pixels : .zero, viewer: self.viewerID)
    }

    /// Reads `status` and `tabs` only; the per-frame `model.frame` is read by `BrowserFrameView` alone.
    @ViewBuilder private var content: some View {
        switch self.model.status {
        case .needsFullManagement:
            ContentUnavailableView {
                Label(L("Viewing the agent's browser needs Full Management"), systemImage: "lock.shield")
            } description: {
                Text("Turn on Full Management under Connection, then approve this device on the Gateway host.", bundle: .module)
            } actions: {
                Button(L("Open Connection")) { self.openGatewaySettings(self.gateway, at: .connection) }
            }
        case .notRunning:
            ContentUnavailableView(L("The agent's browser isn't running"), systemImage: "globe",
                                   description: Text("It starts when the agent uses the browser tool.", bundle: .module))
        case let .failed(message):
            ContentUnavailableView {
                Label(L("Can't show the browser"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(L("Try Again")) { Task { await self.model.refreshTabs() } }
            }
        case .navigationBlocked:
            ContentUnavailableView {
                Label(L("This page is blocked"), systemImage: "hand.raised")
            } description: {
                Text("The Gateway's browser policy blocked this navigation.", bundle: .module)
            } actions: {
                if let other = self.model.tabs.first(where: { $0.id != self.model.selectedTargetId }) {
                    Button(L("Show Other Pages")) { self.model.select(targetId: other.id) }
                }
            }
        case .idle, .loading, .live, .reconnecting:
            if self.model.selectedPageMissing {
                ContentUnavailableView {
                    Label(L("This page is no longer open"), systemImage: "macwindow.badge.plus")
                } description: {
                    Text("The agent closed it, or the browser restarted.", bundle: .module)
                } actions: {
                    if let other = self.model.tabs.first(where: { $0.id != self.model.selectedTargetId }) {
                        Button(L("Show Other Pages")) { self.model.select(targetId: other.id) }
                    }
                }
            } else if self.model.tabs.isEmpty, self.model.selectedTargetId == nil, self.model.status == .live || self.model.status == .idle {
                ContentUnavailableView(L("No pages open"), systemImage: "macwindow",
                                       description: Text("Pages the agent opens show up here.", bundle: .module))
            } else {
                BrowserFrameView(model: self.model)
            }
        }
    }
}

/// The only view that reads `model.frame` (5–30 changes a second), so a new frame invalidates just this
/// body and never the chat chrome, toolbar or tab strip.
private struct BrowserFrameView: View {
    let model: BrowserPanelModel

    var body: some View {
        if let frame = self.model.frame {
            Image(decorative: frame.image, scale: 1)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.04))
                // Shown dimmed, not blanked, while paused or reconnecting.
                .opacity(self.model.status == .live ? 1 : 0.5)
                .transaction { $0.animation = nil }
                .accessibilityElement()
                .accessibilityLabel(self.label)
                .accessibilityAddTraits([.isImage, .updatesFrequently])
        } else {
            BrowserWaiting(status: self.model.status)
        }
    }

    private var label: String {
        let title = self.model.pageTitle.flatMap { $0.isEmpty ? nil : $0 } ?? self.model.pageURL?.host(percentEncoded: false)
        return title.map { L("Agent's browser: \($0)") } ?? L("Agent's browser")
    }
}

/// No frame yet: a spinner, then "Waiting for page…" if the first frame takes more than about 10 s.
private struct BrowserWaiting: View {
    let status: BrowserPanelModel.Status
    @State private var slow = false

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ProgressView().controlSize(.small)
            if self.slow {
                Text("Waiting for page…", bundle: .module).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { try? await Task.sleep(for: .seconds(10)); self.slow = true }
    }
}

/// Back, forward and reload (inert until the panel can drive the page), the page URL, Open in Browser
/// and the status pill.
private struct BrowserToolbarRow: View {
    let model: BrowserPanelModel

    /// The empty or stale-page message carries the state, so the pill would only repeat it.
    private var showsEmptyMessage: Bool {
        self.model.selectedPageMissing
            || (self.model.tabs.isEmpty && self.model.selectedTargetId == nil && (self.model.status == .live || self.model.status == .idle))
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button(L("Back"), systemImage: "chevron.left") {}.disabled(true).help(L("Coming soon"))
            Button(L("Forward"), systemImage: "chevron.right") {}.disabled(true).help(L("Coming soon"))
            Button(L("Reload"), systemImage: "arrow.clockwise") {}.disabled(true).help(L("Coming soon"))
            Text(self.model.pageURL?.absoluteString ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(L("Page address"))
                .accessibilityValue(self.model.pageURL?.absoluteString ?? L("None"))
            if let url = self.model.pageURL, url.scheme == "http" || url.scheme == "https" {
                Button(L("Open in Browser"), systemImage: "arrow.up.forward.square") { Self.open(url) }
            }
            if !self.showsEmptyMessage { BrowserStatusPill(status: self.model.status) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

/// Dot and word; the word carries the meaning, so colour is never the only signal. Hidden when an
/// empty state already says what's wrong.
private struct BrowserStatusPill: View {
    let status: BrowserPanelModel.Status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        switch self.status {
        case .live:
            self.pill(L("Live"), spoken: L("Live view")) {
                Circle().fill(.green).frame(width: 6, height: 6)
                    .opacity(self.pulsing && !self.reduceMotion ? 0.4 : 1)
                    .animation(self.reduceMotion ? nil : .easeInOut(duration: 1).repeatForever(), value: self.pulsing)
                    .onAppear { self.pulsing = true }
            }
        case .loading:
            self.pill(L("Connecting…"), spoken: L("Connecting")) { ProgressView().controlSize(.mini) }
        case .reconnecting:
            self.pill(L("Reconnecting…"), spoken: L("Reconnecting")) { ProgressView().controlSize(.mini) }
        case .idle:
            self.pill(L("Paused"), spoken: L("Paused")) { Circle().fill(.gray).frame(width: 6, height: 6) }
        case .needsFullManagement, .notRunning, .navigationBlocked, .failed:
            EmptyView()
        }
    }

    private func pill(_ text: String, spoken: String, @ViewBuilder dot: () -> some View) -> some View {
        HStack(spacing: 4) {
            dot().accessibilityHidden(true)
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}
