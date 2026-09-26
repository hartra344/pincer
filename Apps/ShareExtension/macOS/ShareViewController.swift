import AppKit
import SwiftUI

/// Principal class of the macOS Share extension; hosts `ShareRoot`.
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let items = self.extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let root = ShareRoot(
            items: items,
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            },
            onDone: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            })
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        self.view = host
        self.preferredContentSize = host.frame.size
    }
}
