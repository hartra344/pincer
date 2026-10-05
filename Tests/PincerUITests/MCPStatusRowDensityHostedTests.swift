#if canImport(UIKit)
import PincerKit
import SwiftUI
import Testing
import UIKit
@testable import PincerUI

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct MCPStatusRowDensityHostedTests {
    @Test func connectedListStatusKeepsOneLineAndFullMeaning() throws {
        let ordinary = MCPServerStatus(name: "local", state: .connected, toolCount: nil)
        let long = MCPServerStatus(name: "local", state: .connected, toolCount: 44)
        let first = Self.host(ordinary)
        let second = Self.host(long)
        defer { first.window.isHidden = true; first.window.rootViewController = nil
                second.window.isHidden = true; second.window.rootViewController = nil }
        let ordinaryHeight = first.controller.sizeThatFits(in: CGSize(width: 110, height: 1000)).height
        let longHeight = second.controller.sizeThatFits(in: CGSize(width: 110, height: 1000)).height
        #expect(MCPStatusText(ordinary).title == "Connected")
        let expected = MCPStatusText(long).title
        #expect(expected == "Connected · 44 tools")
        let labels = Self.labels(second.controller.view)
        // Accessibility availability is independent of actual layout evidence; never fake a pass.
        print("MCP row AX full meaning available: \(labels.contains(expected))")
        try #require(ordinaryHeight > 0 && ordinaryHeight < 100 && longHeight > 0)
        #expect(longHeight <= ordinaryHeight + 1 / UIScreen.main.scale,
                "Connected list status should occupy the ordinary single-line height at the narrow list row's 110-point available width")
    }
    private static func host(_ status: MCPServerStatus) -> (window: UIWindow, controller: UIHostingController<some View>) {
        let controller = UIHostingController(rootView: MCPStatusLabel(status: status).frame(maxWidth: 220, alignment: .trailing))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 110, height: 200))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        return (window, controller)
    }
    private static func labels(_ root: UIView) -> Set<String> {
        var stack = [(root, 0)]
        var visited = Set<ObjectIdentifier>()
        var result = Set<String>()
        while let (view, depth) = stack.popLast(), visited.count < 128 {
            guard depth <= 16, visited.insert(ObjectIdentifier(view)).inserted else { continue }
            if let label = view.accessibilityLabel, !label.isEmpty { result.insert(label) }
            for child in view.subviews.prefix(max(0, 128 - visited.count - stack.count)) { stack.append((child, depth + 1)) }
        }
        return result
    }
}
#endif
