#if DEBUG
import Foundation
@testable import PincerKit

@MainActor func runEmbeddedImageBase64PreparationChecks() async {
    let fixture = await Task.detached {
        let data = Data(repeating: 42, count: 1024 * 1024)
        let ref = ImageRef(artifactId: nil, base64: data.base64EncodedString(), url: nil, mimeType: "image/png", alt: nil, width: nil, height: nil)
        return (data, ref)
    }.value
    let loader = ArtifactImageLoader(), probe = EmbeddedImageBase64Probe()
    loader.base64Probe = probe
    let actual = await loader.data(for: fixture.1, sessionKey: "fixture")
    check(actual == fixture.0, "actual capped embedded image byte preparation retains exact lawful base64 data")
    let counts = probe.snapshot()
    check(counts.main == 0 && counts.main + counts.worker == 1, "actual inline image base64 decoding stays off Main and records real work")
}

@MainActor func runDemoEmbeddedImageBase64PreparationChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let ready = await waitFor("embedded image Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(ready, "genuine Demo image session connects")
    guard ready else { return }
    let key = "agent:main:main", chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    let images = chat.entries.flatMap { entry -> [ImageRef] in
        if case let .assistant(turn) = entry { return turn.images }
        return []
    }
    guard let image = images.first, let data = await gateway.images.data(for: image, sessionKey: key) else {
        check(false, "actual Demo history image downloads"); return
    }
    // The seeded Demo uses artifactId. This is an explicitly LOCAL inline representation
    // of its genuinely downloaded bytes, not a modified Gateway response.
    let inline = await Task.detached {
        ImageRef(artifactId: nil, base64: data.base64EncodedString(), url: nil, mimeType: image.mimeType, alt: nil, width: image.width, height: image.height)
    }.value
    let probe = EmbeddedImageBase64Probe(); gateway.images.base64Probe = probe
    defer { gateway.images.base64Probe = nil }
    let actual = await gateway.images.data(for: inline, sessionKey: key)
    check(actual == data, "local inline representation of actual Demo image preserves full downloaded bytes")
    let counts = probe.snapshot()
    check(counts.main == 0 && counts.main + counts.worker == 1, "actual Demo-derived inline decoding does no Main base64 work")
}
#endif
