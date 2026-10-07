import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("HTML attachment preview")
struct HTMLAttachmentPreviewTests {
    @Test func selectsHTMLAttachmentsForRenderedPreview() {
        #expect(HTMLPreview.isPreviewable(file: FileRef(name: "preview-test.html", artifactId: "a1", mimeType: "text/html")))
        #expect(HTMLPreview.isPreviewable(file: FileRef(name: "fragment", artifactId: "a2", mimeType: "application/xhtml+xml")))
        #expect(HTMLPreview.isPreviewable(file: FileRef(name: "diagram.svg", artifactId: "a2b", mimeType: "image/svg+xml")))
        #expect(!HTMLPreview.isPreviewable(file: FileRef(name: "notes.md", artifactId: "a3", mimeType: "text/markdown")))
        #expect(!HTMLPreview.isPreviewable(file: FileRef(name: "preview-test.html", mimeType: "text/html")))
    }

    @Test func htmlAttachmentsDontUseSourceExpander() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:html:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "html", name: "HTML"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in })
        let builder = TranscriptLayoutBuilder(context: context, settings: .current(for: context))

        var htmlTurn = AssistantTurn(id: "html-turn", timestamp: Date(timeIntervalSince1970: 1))
        htmlTurn.files = [FileRef(name: "preview-test.html", artifactId: "artifact-1", mimeType: "text/html")]
        let htmlLayout = builder.layout(.entry(.assistant(htmlTurn)), width: 700)
        let htmlPart = try #require(htmlLayout.parts.compactMap { placed -> TranscriptPart.File? in
            if case let .file(file) = placed.part { return file }
            return nil
        }.first)
        #expect(!htmlPart.canExpand)

        var markdownTurn = AssistantTurn(id: "md-turn", timestamp: Date(timeIntervalSince1970: 1))
        markdownTurn.files = [FileRef(name: "notes.md", artifactId: "artifact-2", mimeType: "text/markdown")]
        let markdownLayout = builder.layout(.entry(.assistant(markdownTurn)), width: 700)
        let markdownPart = try #require(markdownLayout.parts.compactMap { placed -> TranscriptPart.File? in
            if case let .file(file) = placed.part { return file }
            return nil
        }.first)
        #expect(markdownPart.canExpand)

        var svgTurn = AssistantTurn(id: "svg-turn", timestamp: Date(timeIntervalSince1970: 1))
        svgTurn.files = [FileRef(name: "diagram.svg", artifactId: "artifact-3", mimeType: "image/svg+xml")]
        let svgLayout = builder.layout(.entry(.assistant(svgTurn)), width: 700)
        let svgPart = try #require(svgLayout.parts.compactMap { placed -> TranscriptPart.File? in
            if case let .file(file) = placed.part { return file }
            return nil
        }.first)
        #expect(!svgPart.canExpand)
    }
}

@MainActor
@Suite("HTML preview lockdown")
struct HTMLPreviewLockdownTests {
    @Test func webViewIsScriptlessAndEphemeral() {
        let configuration = HTMLPreview.configuration()
        #expect(!configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(!configuration.websiteDataStore.isPersistent)
    }

    @Test func policyPrecedesUntrustedMarkup() {
        let page = HTMLPreview.document(#"<!DOCTYPE html><img src="https://example.com/x.png">"#)
        #expect(page.hasPrefix(#"<meta http-equiv="Content-Security-Policy""#))
        #expect(HTMLPreview.contentSecurityPolicy.hasPrefix("default-src 'none'"))
        #expect(HTMLPreview.blockRules.contains("^(https?|wss?|ftp|file|blob)://"))
    }

    @Test func attachmentSourceIsBounded() {
        #expect(HTMLAttachmentSource.decode(Data("<p>hi</p>\r\n".utf8)) == "<p>hi</p>\n")
        #expect(HTMLAttachmentSource.decode(Data(" \n\t".utf8)) == nil)
        #expect(HTMLAttachmentSource.decode(Data([0x3C, 0x00, 0x3E])) == nil)
        #expect(HTMLAttachmentSource.decode(Data([0xFF, 0xFE, 0x3C])) == nil)
        #expect(HTMLAttachmentSource.decode(Data(repeating: 0x20, count: HTMLAttachmentSource.maxBytes) + Data("x".utf8)) == nil)
    }
}
