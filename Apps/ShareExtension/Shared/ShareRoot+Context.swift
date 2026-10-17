import Foundation

extension ShareRoot {
    /// The share sheet for an extension's own context; both platforms' view controllers host this.
    init(extensionContext: NSExtensionContext?) {
        self.init(
            items: extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? [],
            onCancel: { [weak extensionContext] in
                extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            },
            onDone: { [weak extensionContext] in
                extensionContext?.completeRequest(returningItems: nil)
            })
    }
}
