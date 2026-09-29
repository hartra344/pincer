import PincerKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Quick-react bar (recent emoji first) over a fixed grid of common emoji. Picking one closes it.
struct ReactionPicker: View {
    let onPick: (String) -> Void

    private let quick = Reactions.quickBar(recent: Reactions.recent)
    private let columns = Array(repeating: GridItem(.fixed(32), spacing: 4), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(self.quick, id: \.self) { emoji in
                    self.button(emoji, size: 24)
                }
            }
            Divider()
            LazyVGrid(columns: self.columns, spacing: 4) {
                ForEach(Reactions.catalog, id: \.self) { emoji in
                    self.button(emoji, size: 20)
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .fixedSize()
    }

    private func button(_ emoji: String, size: CGFloat) -> some View {
        Button {
            self.onPick(emoji)
        } label: {
            Text(emoji)
                .font(.system(size: size))
                .frame(width: size + 12, height: size + 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(emoji)
        .help(emoji)
    }

    /// Shows the picker anchored to `rect` in `view`, as a popover (on a phone, a small sheet).
    @MainActor
    static func present(from view: PView, rect: CGRect, onPick: @escaping (String) -> Void) {
        #if os(macOS)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: ReactionPicker { [weak popover] emoji in
            popover?.performClose(nil)
            onPick(emoji)
        })
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        #else
        guard var presenter = view.window?.rootViewController else { return }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed { presenter = presented }
        weak var host: UIHostingController<ReactionPicker>?
        let controller = UIHostingController(rootView: ReactionPicker { emoji in
            host?.dismiss(animated: true)
            onPick(emoji)
        })
        host = controller
        controller.modalPresentationStyle = .popover
        controller.preferredContentSize = controller.sizeThatFits(in: CGSize(width: 400, height: 600))
        if let popover = controller.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = rect
            let sheet = popover.adaptiveSheetPresentationController
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(controller, animated: true)
        #endif
    }
}

#if os(macOS)
/// The one-click reactions row inside a message's context menu.
final class QuickReactionsMenuView: NSView {
    init(onPick: @escaping (String) -> Void) {
        super.init(frame: .zero)
        let row = QuickReactionsRow { [weak self] emoji in
            self?.enclosingMenuItem?.menu?.cancelTracking()
            onPick(emoji)
        }
        let host = NSHostingView(rootView: row)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        self.frame = host.frame
        self.addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private struct QuickReactionsRow: View {
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            ForEach(Reactions.quickBar(recent: Reactions.recent), id: \.self) { emoji in
                Button {
                    self.onPick(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 18))
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("React \(emoji)"))
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.xxs)
    }
}
#endif
