import PincerKit
import SwiftUI

/// Connects the transcript list to the scroll-to-bottom button without `ChatView` observing
/// the scroll position: the list reports where it is and registers how to scroll to the end,
/// and only the button reads `isVisible` and `hasNewMessages`.
@MainActor
@Observable
final class ScrollToBottomModel {
    private(set) var isVisible = false
    private(set) var hasNewMessages = false
    @ObservationIgnored private var state = ScrollToBottomState()
    @ObservationIgnored private var publishScheduled = false
    /// Set by the transcript list: scrolls to the latest message and follows it again.
    @ObservationIgnored var perform: (() -> Void)?

    /// Called by the transcript list on every scroll and update; cheap when nothing changes.
    func report(distance: CGFloat, viewport: CGFloat, lastRowId: String?) {
        var next = self.state
        next.update(distance: distance, viewport: viewport, lastRowId: lastRowId,
                    stickDistance: TranscriptLayout.stickToBottomDistance)
        guard next != self.state else { return }
        self.state = next
        guard next.isVisible != self.isVisible || next.hasNewMessages != self.hasNewMessages,
              !self.publishScheduled else { return }
        // Reports arrive from inside SwiftUI's view updates; publish on the next turn instead.
        self.publishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishScheduled = false
            if self.isVisible != self.state.isVisible { self.isVisible = self.state.isVisible }
            if self.hasNewMessages != self.state.hasNewMessages { self.hasNewMessages = self.state.hasNewMessages }
        }
    }

    func scrollToBottom() {
        self.perform?()
    }

    /// Hides the button while there's no transcript to scroll (loading, or an empty chat).
    func reset() {
        self.report(distance: 0, viewport: 0, lastRowId: nil)
    }
}

/// The round down-arrow shown above the composer while the reader is scrolled up. A dot marks
/// messages that arrived below since. Hidden while the slash-command menu, which grows upward
/// over the same corner, may be open.
struct ScrollToBottomButton: View {
    let model: ScrollToBottomModel
    let chat: ChatStore
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 15

    static let diameter: CGFloat = 36
    /// Centres the button over the composer's Send button: the composer's outer padding, its
    /// trailing inset, and half of the Send control's box, less half of this button.
    static let trailingPadding: CGFloat = Theme.Spacing.row + 7 + 16 - diameter / 2

    var body: some View {
        ZStack {
            if self.model.isVisible, !self.chat.draft.text.hasPrefix("/") {
                Button {
                    self.model.scrollToBottom()
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: min(self.iconSize, 22), weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: Self.diameter, height: Self.diameter)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassSurface(in: Circle(), interactive: true)
                .overlay(alignment: .topTrailing) {
                    if self.model.hasNewMessages {
                        Circle()
                            .fill(self.theme.accent)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.background, lineWidth: 1.5))
                            .offset(x: 1, y: -1)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                }
                .help(Text("Scroll to latest message", bundle: .module))
                .accessibilityLabel(Text("Scroll to latest message", bundle: .module))
                .accessibilityValue(self.model.hasNewMessages ? Text("New messages", bundle: .module) : Text(verbatim: ""))
                .transition(self.reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: self.model.isVisible)
        .animation(.snappy, value: self.model.hasNewMessages)
    }
}
