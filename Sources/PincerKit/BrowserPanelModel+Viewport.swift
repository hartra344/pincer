import CoreGraphics
import Foundation

/// The agent's page renders at whatever size the agent's browser window last had, so a tall panel got a
/// short landscape frame with dead bands above and below. Like upstream's Control UI
/// (`browser-panel-viewport-owner.ts`), the panel asks the Gateway to resize the page's viewport to the
/// panel (`POST /act {kind: "resize"}`), when `/tabs` says `canAutoResizeViewport`. Sizes are CSS pixels.
extension BrowserPanelModel {
    static let viewportSyncDelay = Duration.milliseconds(300)
    static let viewportRange = 100...8192

    /// The viewport to ask for: the panel's size in points, clamped to what `/act resize` accepts.
    static func resizeTarget(for viewport: CGSize) -> (width: Int, height: Int) {
        func clamp(_ value: CGFloat) -> Int { min(viewportRange.upperBound, max(viewportRange.lowerBound, Int(value.rounded()))) }
        return (clamp(viewport.width), clamp(viewport.height))
    }

    func scheduleViewportSync() {
        guard self.canAutoResizeViewport, !self.resizeUnavailable, self.viewport != nil else { return }
        self.resizeTask?.cancel()
        self.resizeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.viewportSyncDelay)
            guard !Task.isCancelled else { return }
            await self?.syncViewport()
        }
    }

    private func syncViewport() async {
        guard self.canAutoResizeViewport, !self.resizeUnavailable, self.hasAdmin, self.visible,
              let viewport = self.viewport, let tab = self.selectedTab ?? self.tabs.first, !self.selectedPageMissing
        else { return }
        let (width, height) = Self.resizeTarget(for: viewport)
        let wanted = CGSize(width: width, height: height)
        // Never repeat a request for the same size, whether it worked or was refused.
        guard self.resizeRequested[tab.targetId] != wanted else { return }
        if let css = self.frame?.cssSize, abs(css.width - wanted.width) <= 1, abs(css.height - wanted.height) <= 1 {
            self.resizeRequested[tab.targetId] = wanted
            return
        }
        self.resizeRequested[tab.targetId] = wanted
        do {
            _ = try await self.request("browser.request", Self.envelope(
                "POST", "/act", route: tab.route,
                body: ["kind": "resize", "targetId": .string(tab.targetId),
                       "width": .number(Double(width)), "height": .number(Double(height))]))
        } catch {
            if error is CancellationError { return }
            // Refused (policy, a profile that can't resize): show the frame as it is and stop asking.
            self.resizeUnavailable = true
        }
    }
}
