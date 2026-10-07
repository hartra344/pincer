import Foundation
import PincerKit
import SwiftUI
import WebKit

/// An ```html fence the agent wrote, shown as a page in a locked-down web view (#40): JavaScript
/// off, a throwaway data store, no navigation, and a content security policy plus a WebKit rule
/// list that block every network load. Only inline styles and `data:` images render.
struct HTMLPreviewItem: Identifiable {
    let id = UUID()
    let html: String
}

enum HTMLPreview {
    /// Fences that get a **Preview** button: HTML documents and fragments, but not the SVG ones
    /// the transcript already draws as images.
    static func isPreviewable(language: String, code: String) -> Bool {
        let lang = language.trimmingCharacters(in: .whitespaces).lowercased()
        guard lang == "html" || lang == "htm" || lang == "xhtml" else { return false }
        return SVGSource.inlineSource(language: language, code: code) == nil
            && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Downloadable HTML attachments that should open as rendered pages instead of source text.
    static func isPreviewable(file: FileRef) -> Bool {
        guard file.isDownloadable else { return false }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if ["html", "htm", "xhtml", "svg"].contains(ext) { return true }
        let mime = file.mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        return mime == "text/html" || mime == "application/xhtml+xml" || mime == "image/svg+xml"
    }

    static let contentSecurityPolicy =
        "default-src 'none'; img-src data:; style-src 'unsafe-inline' data:; font-src data:; media-src data:; form-action 'none'"

    /// The page as loaded: the policy goes first, so the parser puts it in `<head>` before
    /// anything the agent wrote can load.
    static func document(_ html: String) -> String {
        #"<meta http-equiv="Content-Security-Policy" content="\#(self.contentSecurityPolicy)">"#
            + #"<meta name="viewport" content="width=device-width, initial-scale=1">"#
            + html
    }

    /// Blocks any request that leaves the page, as a second wall behind the policy.
    static let blockRules = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp|file|blob)://"},"action":{"type":"block"}}]"#

    @MainActor static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(iOS)
        configuration.dataDetectorTypes = []
        configuration.allowsInlineMediaPlayback = false
        #endif
        return configuration
    }
}

struct HTMLPreviewSheet: View {
    let item: HTMLPreviewItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HTMLPreviewWebView(html: self.item.html)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Label {
                        Text("Scripts and network access are off in this preview.", bundle: .module)
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.bar)
                }
                .navigationTitle(Text("HTML Preview", bundle: .module))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { self.dismiss() } label: { Text("Done", bundle: .module) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 820, minHeight: 480, idealHeight: 640)
        #endif
    }
}

@MainActor
final class HTMLPreviewCoordinator: NSObject, WKNavigationDelegate {
    private var loaded = false

    func load(_ html: String, in view: WKWebView) {
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "pincer.html-preview.block-network", encodedContentRuleList: HTMLPreview.blockRules
        ) { [weak view] list, _ in
            MainActor.assumeIsolated {
                guard let view else { return }
                // Without the rule list the page still has the content security policy.
                if let list { view.configuration.userContentController.add(list) }
                view.loadHTMLString(HTMLPreview.document(html), baseURL: nil)
            }
        }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void)
    {
        // Only the page itself loads; links and form posts go nowhere.
        let initial = !self.loaded && action.navigationType == .other && action.request.url?.scheme == "about"
        let frame = action.targetFrame?.isMainFrame == false && action.request.url?.scheme == "about"
        decisionHandler(initial || frame ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.loaded = true
    }
}

#if os(macOS)
struct HTMLPreviewWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> HTMLPreviewCoordinator { HTMLPreviewCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: HTMLPreview.configuration())
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = true
        view.allowsLinkPreview = false
        view.setAccessibilityLabel(L("HTML Preview"))
        context.coordinator.load(self.html, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
struct HTMLPreviewWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> HTMLPreviewCoordinator { HTMLPreviewCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: HTMLPreview.configuration())
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsLinkPreview = false
        view.accessibilityLabel = L("HTML Preview")
        context.coordinator.load(self.html, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
