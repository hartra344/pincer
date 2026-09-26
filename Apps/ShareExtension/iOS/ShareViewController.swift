import SwiftUI
import UIKit

/// Principal class of the iOS Share extension; hosts `ShareRoot`.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = self.extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let root = ShareRoot(
            items: items,
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            },
            onDone: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            })
        let host = UIHostingController(rootView: root)
        self.addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}
