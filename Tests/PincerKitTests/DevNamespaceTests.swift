import Foundation
import PincerPush
import Testing
@testable import PincerKit

@Suite("Dev namespace")
struct DevNamespaceTests {
    @Test func parsesAndSanitizes() {
        #expect(DevNamespace.sanitize("Foo_Bar!") == "foo-bar")
        #expect(DevNamespace.sanitize("  --x--  ") == "x")
        #expect(DevNamespace.sanitize("") == nil)
        #expect(DevNamespace.sanitize("!!!") == nil)
        #expect(DevNamespace.sanitize(nil) == nil)
        #expect(DevNamespace.sanitize(String(repeating: "a", count: 100))?.count == DevNamespace.maxLength)
    }

    @Test func resolvesEnvironmentThenInfoSuffix() {
        #expect(DevNamespace.resolve(environment: "wt1", infoValue: ".dev-other") == "wt1")
        #expect(DevNamespace.resolve(environment: nil, infoValue: ".dev-wt2") == "wt2")
        #expect(DevNamespace.resolve(environment: "", infoValue: "") == nil)
        #expect(DevNamespace.resolve(environment: nil, infoValue: "$(PINCER_DEV_SUFFIX)") == nil)
        #expect(DevNamespace.resolve(environment: nil, infoValue: nil) == nil)
    }

    @Test func productionValuesAreUnchanged() {
        #expect(DevNamespace.identifier("chat.pincer.gateway", namespace: nil) == "chat.pincer.gateway")
        #expect(DevNamespace.identifier("chat.pincer.push", namespace: nil) == "chat.pincer.push")
        #expect(DevNamespace.folderName("Pincer", namespace: nil) == "Pincer")
        #expect(SharedContainer.devSuiteName(namespace: nil) == nil)
    }

    @Test func namespacedValuesAreDistinct() {
        #expect(DevNamespace.identifier("chat.pincer.gateway", namespace: "foo") == "chat.pincer.gateway.dev-foo")
        #expect(DevNamespace.folderName("Pincer", namespace: "foo") == "Pincer-foo")
        #expect(SharedContainer.devSuiteName(namespace: "foo") == "chat.pincer.dev-foo")
        #expect(SharedContainer.devSuiteName(namespace: "foo") != SharedContainer.devSuiteName(namespace: "bar"))
    }

    @Test func testRunnerIsNotNamespacedByDefault() {
        // Keeps production names when the suite runs without PINCER_DEV_NAMESPACE.
        if ProcessInfo.processInfo.environment[DevNamespace.environmentKey] == nil {
            #expect(Keychain.service == "chat.pincer.gateway")
        }
    }
}
