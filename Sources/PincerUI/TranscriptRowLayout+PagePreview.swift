import CoreGraphics
import Foundation
import PincerKit

extension TranscriptPart {
    /// A web page card for a successful `browser` tool call. Built from cached data only; the image
    /// and favicon fill in when `gateway.pagePreviews` and `gateway.images` have them.
    struct PagePreview {
        enum ImageKind { case none, screenshot, og }
        let page: BrowserPagePreview
        let title: String
        let subtitle: String
        let kind: ImageKind
        /// Decoded pixels for the image box; the box is there before they are.
        let image: CGImage?
        let imageRef: ImageRef?
        let imageHeight: CGFloat
        let favicon: CGImage?
        let faviconRef: ImageRef?
        let footerHeight: CGFloat
        /// Fetching waits until the turn has finished.
        let loadsPreview: Bool
    }
}

enum PagePreviewMetrics {
    static let maxWidth: CGFloat = 320
    static let ogAspect: CGFloat = 1.91
    static let maxScreenshotHeight: CGFloat = 240
    static let faviconSize: CGFloat = 16
    static let footerInset: CGFloat = 10
    static let textGap: CGFloat = 8
    static let maxCards = 3
}

extension TranscriptLayoutBuilder {
    /// The cards of one turn: latest per tab, at most three.
    static func pageCards(_ tools: [ToolActivity]) -> [BrowserPagePreview] {
        guard tools.contains(where: { $0.browserPage != nil }) else { return [] }
        return BrowserPagePreview.latestPerTab(tools, limit: PagePreviewMetrics.maxCards)
    }

    func pageCard(_ page: BrowserPagePreview, turn: AssistantTurn, into stack: inout Stack, layout: inout TranscriptRowLayout) {
        let width = min(stack.width, PagePreviewMetrics.maxWidth)
        let previews = self.context.gateway.pagePreviews
        let loader = self.context.gateway.images
        let linkPreview = previews.preview(for: page.url)

        // The screenshot hook only applies to the latest turn; older cards keep their og:image.
        let latest = self.pageTurns[page.tabKey]
        let eligible = latest.map { $0 == turn.id } ?? turn.isStreaming
        let screenshot = eligible ? previews.screenshot(forTab: page.tabKey) : nil
        layout.pages.append(.init(url: page.url, tabKey: page.tabKey, imageKey: linkPreview?.image?.cacheKey,
                                  faviconKey: linkPreview?.favicon?.cacheKey, screenshotKey: screenshot?.cacheKey,
                                  screenshotEligible: eligible, turnId: turn.id))

        // Box height comes from which image exists, never from decoded pixels, so a decode can't move the row.
        var kind = TranscriptPart.PagePreview.ImageKind.none
        var imageRef: ImageRef?
        if let screenshot, !loader.hasFailed(screenshot) {
            kind = .screenshot
            imageRef = screenshot
        } else if let ref = linkPreview?.image, !loader.hasFailed(ref) {
            kind = .og
            imageRef = ref
        }
        var image: CGImage?
        var imageHeight: CGFloat = 0
        if let imageRef {
            layout.images.append(imageRef)
            image = loader.cached(imageRef)
            switch kind {
            case .screenshot:
                if let w = imageRef.width, let h = imageRef.height, w > 0, h > 0 {
                    imageHeight = min(PagePreviewMetrics.maxScreenshotHeight, (width * CGFloat(h) / CGFloat(w)).rounded())
                } else {
                    imageHeight = PagePreviewMetrics.maxScreenshotHeight
                }
            default:
                imageHeight = (width / PagePreviewMetrics.ogAspect).rounded()
            }
        }

        var favicon: CGImage?
        var faviconRef: ImageRef?
        if let ref = linkPreview?.favicon, !loader.hasFailed(ref) {
            layout.images.append(ref)
            faviconRef = ref
            favicon = loader.cached(ref)
        }

        let footer = page.footer(linkTitle: linkPreview?.title)
        let footerHeight = PagePreviewMetrics.footerInset * 2 + TranscriptStyle.lineHeight(self.style.captionSemibold)
            + 2 + TranscriptStyle.lineHeight(self.style.caption)
        let part = TranscriptPart.PagePreview(
            page: page, title: footer.title, subtitle: footer.subtitle, kind: kind, image: image, imageRef: imageRef,
            imageHeight: imageHeight, favicon: favicon, faviconRef: faviconRef, footerHeight: footerHeight,
            loadsPreview: !turn.isStreaming)
        stack.add(.pagePreview(part), height: imageHeight + footerHeight, width: width)
    }
}
