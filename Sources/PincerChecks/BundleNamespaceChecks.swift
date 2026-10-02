import PincerPush

/// Runtime consumers of the suffix embedded by the SwiftPM Mac bundler.
@MainActor
func runBundleNamespaceChecks() {
    let namespace = DevNamespace.resolve(environment: nil, infoValue: ".dev-desk-work")
    check(namespace == "desk-work", "bundle namespace: embedded suffix survives a launch without the build environment")
    check(DevNamespace.identifier("chat.pincer.mac", namespace: namespace) == "chat.pincer.mac.dev-desk-work"
          && DevNamespace.identifier("chat.pincer.gateway", namespace: namespace) == "chat.pincer.gateway.dev-desk-work"
          && DevNamespace.folderName("Pincer", namespace: namespace) == "Pincer-desk-work",
          "bundle namespace: bundle identity, Keychain service, and folders share the embedded namespace")
    check(DevNamespace.resolve(environment: "Other_Work!", infoValue: ".dev-desk-work") == "other-work",
          "bundle namespace: an explicit launch environment still takes precedence")
    check(DevNamespace.resolve(environment: nil, infoValue: nil) == nil
          && DevNamespace.identifier("chat.pincer.mac", namespace: nil) == "chat.pincer.mac"
          && DevNamespace.identifier("chat.pincer.gateway", namespace: nil) == "chat.pincer.gateway"
          && DevNamespace.folderName("Pincer", namespace: nil) == "Pincer",
          "bundle namespace: production identity and standard storage stay unchanged")
}
