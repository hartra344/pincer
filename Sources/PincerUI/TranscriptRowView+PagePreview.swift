import CoreGraphics
import Foundation
import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The browser page card: an optional image on top, a footer with favicon, title and URL below.
/// Tapping opens the page through `TranscriptRowActions.openBrowserPage`.
final class TranscriptPagePreviewView: TranscriptTapView {
    private var preview: TranscriptPart.PagePreview?
    private weak var actions: TranscriptRowActions?
    private let clip = CALayer()
    private let imageLayer = CALayer()
    private let faviconLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let host = self.hostLayer
        host.cornerRadius = TranscriptMetrics.cardRadius
        host.masksToBounds = true
        host.borderWidth = 1
        self.imageLayer.minificationFilter = .trilinear
        self.imageLayer.contentsGravity = .resize
        self.clip.masksToBounds = true
        self.clip.addSublayer(self.imageLayer)
        self.faviconLayer.cornerRadius = 3
        self.faviconLayer.masksToBounds = true
        self.faviconLayer.contentsGravity = .resizeAspectFill
        host.addSublayer(self.clip)
        host.addSublayer(self.faviconLayer)
        self.appearanceChanged()
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .pagePreview(preview) = part else { return }
        self.preview = preview
        self.actions = actions
        let page = preview.page
        self.accessibilityText = Self.openName(page)
        self.onTap = { [weak actions] in actions?.openBrowserPage(page) }
        #if os(macOS)
        self.toolTip = page.url.absoluteString
        #endif
        withoutLayerAnimations {
            self.imageLayer.contents = preview.image
            self.faviconLayer.contents = preview.favicon
            self.clip.isHidden = preview.kind == .none
            self.faviconLayer.isHidden = preview.favicon == nil
        }
        if preview.loadsPreview {
            actions.loadPagePreview(page.url)
            if preview.image == nil, let ref = preview.imageRef { actions.loadImage(ref) }
            if preview.favicon == nil, let ref = preview.faviconRef { actions.loadImage(ref) }
        }
        self.layoutContent()
        self.redraw()
    }

    static func openName(_ page: BrowserPagePreview) -> String { L("Open \(page.displayTitle)") }

    #if os(macOS)
    override func resetCursorRects() { self.addCursorRect(self.bounds, cursor: .pointingHand) }
    #endif

    override func appearanceChanged() {
        super.appearanceChanged()
        withoutLayerAnimations {
            self.clip.backgroundColor = self.resolved(TranscriptColors.strongFill)
            self.hostLayer.borderColor = self.resolved(TranscriptColors.stroke)
            self.hostLayer.backgroundColor = self.resolved(TranscriptColors.fill)
        }
    }

    override func layoutContent() {
        guard let preview else { return }
        let bounds = self.bounds
        withoutLayerAnimations {
            self.clip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: preview.imageHeight)
            if let image = preview.image {
                let box = CGSize(width: bounds.width, height: preview.imageHeight)
                let natural = CGSize(width: image.width, height: image.height)
                if preview.kind == .screenshot {
                    // Aspect-fill, anchored to the top of the box.
                    let scale = max(box.width / natural.width, box.height / natural.height)
                    let size = CGSize(width: natural.width * scale, height: natural.height * scale)
                    self.imageLayer.frame = CGRect(x: (box.width - size.width) / 2, y: 0, width: size.width, height: size.height)
                } else {
                    // Aspect-fit, centered.
                    let scale = min(box.width / natural.width, box.height / natural.height)
                    let size = CGSize(width: natural.width * scale, height: natural.height * scale)
                    self.imageLayer.frame = CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2,
                                                   width: size.width, height: size.height)
                }
            }
            let side = PagePreviewMetrics.faviconSize
            self.faviconLayer.frame = CGRect(x: PagePreviewMetrics.footerInset,
                                             y: preview.imageHeight + (preview.footerHeight - side) / 2, width: side, height: side)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let preview else { return }
        let style = TranscriptStyle.shared
        let inset = PagePreviewMetrics.footerInset
        let side = PagePreviewMetrics.faviconSize
        let top = preview.imageHeight
        if preview.favicon == nil {
            TranscriptSymbols.draw("globe", in: CGRect(x: inset, y: top + (preview.footerHeight - side) / 2, width: side, height: side),
                                   size: 13, color: TranscriptColors.secondary)
        }
        let x = inset + side + PagePreviewMetrics.textGap
        let width = self.bounds.width - x - inset
        let titleY = top + inset
        singleLine(preview.title, style.captionSemibold, TranscriptColors.label)
            .drawLine(at: CGPoint(x: x, y: titleY), width: width, font: style.captionSemibold)
        singleLine(preview.subtitle, style.caption, TranscriptColors.secondary)
            .drawLine(at: CGPoint(x: x, y: titleY + TranscriptStyle.lineHeight(style.captionSemibold) + 2), width: width, font: style.caption)
    }

    /// Open in Browser and Copy Link, for the context menu.
    private var menuActions: [(title: String, symbol: String, run: () -> Void)] {
        guard let page = self.preview?.page else { return [] }
        return [
            (L("Open in Browser"), "safari", { [weak actions = self.actions] in actions?.open(page.url) }),
            (L("Copy Link"), "link", { Clipboard.copy(page.url.absoluteString) }),
        ]
    }

    #if os(macOS)
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for item in self.menuActions { menu.addItem(TranscriptMenuItem(item.title, symbol: item.symbol, handler: item.run)) }
        return menu
    }
    #else
    var menuElements: [UIMenuElement] {
        self.menuActions.map { item in
            UIAction(title: item.title, image: UIImage(systemName: item.symbol)) { _ in item.run() }
        }
    }
    #endif
}
