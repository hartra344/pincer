import PincerKit
import QuickLook
import SwiftUI

/// Shared actual preview lifetime hook, also exercised by the native presentation test.
struct ChatQuickLookLifecycle: ViewModifier {
    @Binding var url: URL?
    func body(content: Content) -> some View {
        content.quickLookPreview(self.$url)
            .onDisappear {
                if let old = self.url {
                    self.url = nil
                    Task { await FilePreviewFiles.dismiss(old) }
                }
            }
            .onChange(of: self.url) { old, url in
                if let old, old != url { Task { await FilePreviewFiles.dismiss(old) } }
            }
    }
}
