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
        guard self.canAutoResizeViewport, self.viewport != nil else { return }
        self.resizeTask?.cancel()
        self.resizeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.viewportSyncDelay)
            guard !Task.isCancelled else { return }
            await self?.syncViewport()
        }
    }

    private func syncViewport() async {
        guard self.canAutoResizeViewport, self.hasAdmin, self.visible,
              let viewport = self.viewport, let tab = self.selectedTab ?? self.tabs.first, !self.selectedPageMissing
        else { return }
        let (width, height) = Self.resizeTarget(for: viewport)
        let wanted = CGSize(width: width, height: height)
        // Never repeat a request for the same size, whether it worked or was refused: a size another client
        // changed since is theirs, and re-asserting it would make two clients fight.
        guard self.resizeRequested[tab.targetId] != wanted, self.resizeRefused[tab.targetId] != wanted else { return }
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
        } catch let error as GatewayError {
            // Only the Gateway saying no (policy, a profile that can't resize) is a refusal, and only that size is
            // not asked again. A timeout or dropped connection says nothing about the Gateway's answer: ask again
            // the next time the panel's size or the page changes.
            if case .rpc = error { self.resizeRefused[tab.targetId] = wanted } else { self.resizeRequested[tab.targetId] = nil }
        } catch {
            self.resizeRequested[tab.targetId] = nil
        }
    }
}
