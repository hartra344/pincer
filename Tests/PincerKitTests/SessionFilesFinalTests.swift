import Foundation
import Synchronization
import Testing
@testable import PincerKit

@MainActor
@Suite("Session files final review")
struct SessionFilesFinalTests {
    @Test func reconnectKeepsTheSnapshotAndRefreshesWhenViewed() async {
        let gateway = FilesGateway()
        gateway.listReply.withLock { $0 = Fixtures.json(FilesFixtures.listJSON) }
        let model = gateway.model()
        model.setVisible(true, viewer: "w")
        _ = await eventually { model.snapshot.counts.changed > 0 }
        let before = gateway.count("sessions.files.list")
        model.handleReconnect()
        #expect(model.loaded)
        #expect(model.snapshot.counts.changed > 0)
        _ = await eventually { gateway.count("sessions.files.list") > before }
        #expect(gateway.count("sessions.files.list") > before)
    }

    @Test func reconnectWhileHiddenRefreshesOnNextShow() async {
        let gateway = FilesGateway()
        gateway.listReply.withLock { $0 = Fixtures.json(FilesFixtures.listJSON) }
        let model = gateway.model()
        await model.refresh()
        let before = gateway.count("sessions.files.list")
        model.handleReconnect()
        #expect(gateway.count("sessions.files.list") == before)
        #expect(model.snapshot.counts.changed > 0 || model.loaded)
        model.setVisible(true, viewer: "w")
        _ = await eventually { gateway.count("sessions.files.list") > before }
        #expect(gateway.count("sessions.files.list") > before)
    }

    @Test func crlfFileStaysCRLFAfterAnEditAndSave() async {
        let gateway = FilesGateway()
        gateway.getReplies.withLock { $0 = [FilesFixtures.text("a\r\nb\r\n")] }
        let model = gateway.model()
        FilesFixtures.retained.withLock { $0.append(model) }
        let document = model.open(path: "a.md")
        _ = await eventually { document.phase != .loading }
        #expect(document.content == "a\nb\n")
        #expect(document.lines == ["a", "b", ""])
        #expect(document.lineSeparator == "\r\n")
        #expect(document.isEditable)
        #expect(await document.save("a\nb\nc\n") == .saved)
        #expect(gateway.last("sessions.files.set")?["content"]?.string == "a\r\nb\r\nc\r\n")
        #expect(document.content == "a\nb\nc\n")
    }

    @Test func separatorDetectionMirrorsUpstream() {
        #expect(SessionFileDocument.detectLineSeparator("a\nb") == "\n")
        #expect(SessionFileDocument.detectLineSeparator("a\r\nb") == "\r\n")
        #expect(SessionFileDocument.detectLineSeparator("a\rb") == "\r")
        #expect(SessionFileDocument.detectLineSeparator("none") == "\n")
    }

    @Test func midFlightTriggerReloadsOnceMore() async {
        let gateway = FilesGateway()
        gateway.listReply.withLock { $0 = Fixtures.json(FilesFixtures.listJSON) }
        // Holds the first list in flight. A trigger that lands before the load has even asked is
        // answered by that load, so a bare `Task.yield()` let a busy runner see a single list.
        let held = Gate()
        let firstList = Mutex(true)
        let model = SessionFilesModel(
            sessionKey: "agent:main:main", agentId: nil,
            request: { method, params in
                let reply = try await gateway.request(method, params)
                if method == "sessions.files.list", firstList.withLock({ first in defer { first = false }; return first }) {
                    await held.wait()
                }
                return reply
            },
            debounce: .milliseconds(20))
        async let first: Void = model.refresh()
        #expect(await eventually { gateway.count("sessions.files.list") == 1 })
        async let second: Void = model.refresh()
        await held.open()
        _ = await (first, second)
        #expect(gateway.count("sessions.files.list") >= 2)
    }

    @Test func thumbnailCadenceIsTenSeconds() {
        #expect(BrowserPanelModel.thumbnailInterval == 10)
    }
}
