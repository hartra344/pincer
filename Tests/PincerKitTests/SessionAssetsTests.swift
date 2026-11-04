import Foundation
import Synchronization
import Testing
@testable import PincerKit

private func assetItem(_ id: String, _ role: ChatRole = .assistant, at seconds: TimeInterval = 0,
                  _ blocks: [ContentBlock]) -> ChatItem {
    var item = ChatItem(id: id, role: role, blocks: blocks)
    item.transcriptId = id
    item.timestamp = Date(timeIntervalSince1970: seconds)
    return item
}

private func artifact(_ id: String, _ type: String, _ title: String, size: Int? = nil,
                      mime: String? = nil) -> SessionArtifactItem {
    SessionArtifactItem(id: id, type: type, title: title, mimeType: mime, sizeBytes: size)
}

@Suite struct SessionAssetScannerTests {
    @Test func findsMediaDirectivesAndBlocksOnAssistantMessages() {
        let image = ImageRef(artifactId: "img-1", base64: nil, url: nil, mimeType: "image/png", alt: "chart.png",
                             width: nil, height: nil)
        let assets = SessionAssetScanner.scan([
            assetItem("m1", at: 1, [.text("Here's the report\nMEDIA:/tmp/out/report.pdf")]),
            assetItem("m2", at: 2, [.image(image), .file(FileRef(name: "data.csv", artifactId: "csv-1", mimeType: "text/csv"))]),
        ])
        #expect(assets.map(\.name) == ["data.csv", "chart.png", "report.pdf"])
        #expect(assets.first { $0.name == "report.pdf" }?.messageId == "m1")
        #expect(assets.first { $0.name == "chart.png" }?.isImage == true)
        #expect(assets.first { $0.name == "data.csv" }?.artifactId == "csv-1")
    }

    @Test func ignoresUploadsToolOutputAndPendingMessages() {
        var pending = assetItem("p", at: 3, [.file(FileRef(name: "draft.pdf", artifactId: "d"))])
        pending.isPending = true
        let assets = SessionAssetScanner.scan([
            assetItem("u", .user, at: 1, [.file(FileRef(name: "hosts.csv", artifactId: "u1"))]),
            assetItem("t", .toolResult, at: 2, [.text("MEDIA:/tmp/screenshot.png")]),
            pending,
        ])
        #expect(assets.isEmpty)
    }

    @Test func aFileSentTwiceIsListedOnceAtItsLatestMessage() {
        let assets = SessionAssetScanner.scan([
            assetItem("old", at: 1, [.text("MEDIA:/tmp/report.pdf")]),
            assetItem("mid", at: 2, [.text("MEDIA:/tmp/notes.md")]),
            assetItem("new", at: 3, [.text("Again:\nMEDIA:/tmp/report.pdf")]),
        ])
        #expect(assets.map(\.name) == ["report.pdf", "notes.md"])
        #expect(assets.first?.messageId == "new")
    }

    @Test func mergeFillsSizeByArtifactIdOrNameAndAppendsGatewayOnlyEntries() {
        let local = SessionAssetScanner.scan([
            assetItem("a", at: 1, [.file(FileRef(name: "report.pdf", artifactId: "art-1"))]),
            assetItem("b", at: 2, [.text("MEDIA:/tmp/Summary.md")]),
        ])
        let merged = SessionAssetScanner.merge(local, server: [
            artifact("art-1", "file", "something-else.pdf", size: 900, mime: "application/pdf"),
            artifact("artifact_abc", "file", "summary.md", size: 42),
            artifact("artifact_old", "image", "summary.md", size: 7),
        ])
        #expect(merged.count == 3)
        #expect(merged.first { $0.name == "report.pdf" }?.sizeBytes == 900)
        #expect(merged.first { $0.name == "report.pdf" }?.mimeType == "application/pdf")
        #expect(merged.first { $0.name == "Summary.md" }?.sizeBytes == 42)
        // A same-named image isn't the markdown file: it is its own, older, Gateway-only entry.
        let extra = merged.last
        #expect(extra?.id == "artifact:artifact_old" && extra?.isImage == true && extra?.messageId == nil)
        #expect(extra?.artifactId == "artifact_old" && extra?.isDownloadable == true)
    }

    @Test func filterAndSearch() {
        let assets = SessionAssetScanner.scan([
            assetItem("a", at: 1, [.text("MEDIA:/tmp/report.pdf\nMEDIA:/tmp/chart.png")]),
        ])
        #expect(SessionAssetScanner.filter(assets, filter: .images, search: "").map(\.name) == ["chart.png"])
        #expect(SessionAssetScanner.filter(assets, filter: .files, search: "").map(\.name) == ["report.pdf"])
        #expect(SessionAssetScanner.filter(assets, filter: .all, search: " REPORT ").map(\.name) == ["report.pdf"])
        #expect(SessionAssetScanner.filter(assets, filter: .images, search: "report").isEmpty)
    }
}

@MainActor
@Suite struct SessionAssetsModelTests {
    @Test func mergesCachedLiveAndGatewayAssets() async {
        let calls = Mutex<[JSONValue]>([])
        let live = Mutex<[ChatItem]>([assetItem("live", at: 5, [.text("MEDIA:/tmp/new.pdf")])])
        let model = SessionAssetsModel(
            sessionKey: "agent:main:main", agentId: "main",
            request: { method, params in
                #expect(method == SessionAssetsModel.artifactsMethod)
                calls.withLock { $0.append(params) }
                return Fixtures.json(#"{"artifacts":[{"id":"artifact_x","type":"file","title":"old-export.zip","sizeBytes":10,"sessionKey":"agent:main:main","source":"session-transcript","download":{"mode":"bytes"}}]}"#)
            },
            liveItems: { live.withLock { $0 } },
            cachedItems: { [assetItem("cached", at: 1, [.text("MEDIA:/tmp/cached.pdf")])] })
        await model.refresh()
        #expect(model.loaded)
        #expect(model.assets.map(\.name) == ["new.pdf", "cached.pdf", "old-export.zip"])
        let params = calls.withLock { $0.last }
        #expect(params?["sessionKey"]?.string == "agent:main:main")
        #expect(params?["messageRole"]?.string == "assistant")
        #expect(params?["agentId"]?.string == "main")

        live.withLock { $0.append(assetItem("later", at: 6, [.text("MEDIA:/tmp/later.png")])) }
        await model.refresh()
        #expect(model.assets.first?.name == "later.png")
        model.filter = .images
        #expect(model.shown.map(\.name) == ["later.png"])
    }

    @Test func skipsArtifactsListWhenNotAdvertisedAndSurvivesErrors() async {
        let calls = Mutex(0)
        let model = SessionAssetsModel(
            sessionKey: "k",
            request: { _, _ in calls.withLock { $0 += 1 }; throw GatewayError.rpc(code: "X", message: "nope", details: nil) },
            advertises: { _ in false },
            liveItems: { [assetItem("a", at: 0, [.text("MEDIA:/tmp/a.pdf")])] })
        await model.refresh()
        #expect(calls.withLock { $0 } == 0)
        #expect(model.assets.map(\.name) == ["a.pdf"])

        let failing = SessionAssetsModel(
            sessionKey: "k",
            request: { _, _ in throw GatewayError.rpc(code: "X", message: "nope", details: nil) },
            liveItems: { [assetItem("a", at: 0, [.text("MEDIA:/tmp/a.pdf")])] })
        await failing.refresh()
        #expect(failing.assets.map(\.name) == ["a.pdf"])
    }
}

@Suite struct AssistantTurnMessageIdsTests {
    /// Show in Chat jumps by transcript id. A file-only assistant message has no text id, so the turn
    /// must still list it, or the jump finds no row.
    @Test func fileOnlyAssistantMessageIsInItsTurn() {
        let items = [
            assetItem("u1", .user, at: 1, [.text("Make me a PDF")]),
            assetItem("a1", at: 2, [.text("Working on it")]),
            assetItem("a2", at: 3, [.file(FileRef(name: "report.pdf", artifactId: "pdf"))]),
        ]
        let turns = TranscriptBuilder.build(items).compactMap { if case let .assistant(turn) = $0 { turn } else { nil } }
        #expect(turns.count == 1)
        #expect(turns.first?.messageIds.contains("a2") == true)
        #expect(turns.first?.textIds.contains("a2") == false)
    }
}
