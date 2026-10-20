import PincerKit
import SwiftUI

/// The agent's browser: you can see it live and navigate it, not click into the page. A controls row and the
/// latest frame. Frames are decoded off-main by Kit; this view only draws `model.frame.image`.
struct BrowserPanelView: View {
    let model: BrowserPanelModel
    @Binding var newTab: Bool
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.openGatewaySettings) private var openGatewaySettings
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var size = CGSize.zero
    @State private var appeared = false
    @State private var viewerID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            BrowserControlsRow(model: self.model, newTab: self.$newTab)
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
        .onChange(of: self.horizontalSizeClass) { self.updateVisibility() }
    }

    /// The stream runs only while the panel is on screen and the app is active.
    private func updateVisibility() {
        let visible = self.appeared && self.scenePhase == .active && self.size.width > 0
        let pixels = CGSize(width: self.size.width * self.displayScale, height: self.size.height * self.displayScale)
        self.model.setVisible(visible, pixelSize: visible ? pixels : .zero, viewer: self.viewerID, viewport: visible ? self.size : nil,
                             compact: self.horizontalSizeClass == .compact)
    }

    /// Reads `status` and `tabs` only; the per-frame `model.frame` is read by `BrowserFrameView` alone.
    @ViewBuilder private var content: some View {
        switch self.model.status {
        case .needsFullManagement:
            FullManagementUnavailable(
                title: L("Viewing the agent's browser needs Full Management"),
                message: Text("Turn on Full Management under Connection, then approve this device on the Gateway host.", bundle: .module),
                action: { self.openGatewaySettings(self.gateway, at: .connection) })
        case .notRunning:
            ContentUnavailableView {
                Label(L("The agent's browser isn't running"), systemImage: "globe")
            } description: {
                Text("It starts when the agent uses the browser tool, or you can start it now.", bundle: .module)
            } actions: {
                if self.model.isNavigating {
                    HStack(spacing: Theme.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Starting…", bundle: .module)
                    }
                } else {
                    Button(L("Start Browser")) { Task { await self.model.startBrowser() } }
                        .buttonStyle(.borderedProminent)
                }
                if let error = self.model.actionError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
        case let .failed(message):
            ContentUnavailableView {
                Label(L("Can't show the browser"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(L("Try Again")) { Task { await self.model.refreshTabs() } }
            }
        case .unstreamable:
            ContentUnavailableView {
                Label(L("Can't show the browser"), systemImage: "exclamationmark.triangle")
            } description: {
                Text("This browser can't be streamed. Extension-relay and existing-session browsers aren't supported; use a managed browser profile.", bundle: .module)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // Dimmed, not blanked, only while the stream is down or paused. A live static page is full strength.
                .opacity(self.model.frameIsStale ? 0.5 : 1)
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

/// No frame yet: a spinner. Once the stream is live a static page can stay quiet, so say so; otherwise
/// "Waiting for page…" if the first frame takes more than about 10 s.
private struct BrowserWaiting: View {
    let status: BrowserPanelModel.Status
    @State private var slow = false

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ProgressView().controlSize(.small)
            if self.status == .live {
                Text("Waiting for the page to draw…", bundle: .module).font(.caption).foregroundStyle(.secondary)
            } else if self.slow {
                Text("Waiting for page…", bundle: .module).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { try? await Task.sleep(for: .seconds(10)); self.slow = true }
    }
}

/// Dot and word; the word carries the meaning, so colour is never the only signal. Hidden when an
/// empty state already says what's wrong.
struct BrowserStatusPill: View {
    let status: BrowserPanelModel.Status
    var attempt = 0
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
            let text = self.attempt > 0 ? L("Reconnecting (\(self.attempt)/\(BrowserPanelModel.maxStreamFailures))…") : L("Reconnecting…")
            self.pill(text, spoken: L("Reconnecting")) { ProgressView().controlSize(.mini) }
        case .idle:
            self.pill(L("Paused"), spoken: L("Paused")) { Circle().fill(.gray).frame(width: 6, height: 6) }
        case .needsFullManagement, .notRunning, .navigationBlocked, .unstreamable, .failed:
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
