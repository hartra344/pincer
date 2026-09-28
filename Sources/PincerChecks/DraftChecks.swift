import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

@MainActor
func checkDrafts() async {
    let profile = GatewayProfile(name: "Drafts", url: "ws://127.0.0.1:1", authMode: .none)
    let gatewayFolder = draftsRoot.appending(path: profile.id.uuidString)
    func folders() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: gatewayFolder.path(percentEncoded: false))) ?? []
    }
    let photo = OutgoingAttachment(fileName: "photo.png", mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
    let notes = OutgoingAttachment(fileName: "notes.txt", mimeType: "text/plain", data: Data("hello".utf8))

    let first = GatewayStore(profile: profile)
    let alpha = first.chat(for: "agent:main:alpha")
    let beta = first.chat(for: "agent:main:beta")
    await alpha.load()
    await beta.load()
    check(alpha.draft.isEmpty && beta.draft.isEmpty, "new chats start with an empty draft")
    alpha.draft.text = "half-written thought"
    alpha.draft.attachments = [photo, notes]
    beta.draft.text = "/model"
    check(first.chat(for: "agent:main:alpha").draft.text == "half-written thought"
          && first.chat(for: "agent:main:alpha").draft.attachments.map(\.id) == [photo.id, notes.id],
          "switching chats keeps each chat's draft")
    check(first.chat(for: "agent:main:beta").draft.text == "/model", "drafts are per chat")

    // Each folder is created before its draft.json, so wait for the manifests, not the folders.
    func manifests() -> Int {
        folders().filter { name in
            FileManager.default.fileExists(atPath: gatewayFolder.appending(path: name).appending(path: "draft.json").path(percentEncoded: false))
        }.count
    }
    let saved = await waitFor("debounced draft save", timeout: 5) { manifests() == 2 }
    check(saved, "drafts are saved without an explicit flush")
    // Let any save still queued behind the first one land before "relaunching".
    await alpha.flushDraft()
    await beta.flushDraft()

    // Relaunch: a fresh store for the same Gateway.
    let second = GatewayStore(profile: profile)
    let alphaAgain = second.chat(for: "agent:main:alpha")
    await alphaAgain.load()
    check(alphaAgain.draft.text == "half-written thought", "draft text survives relaunch")
    check(alphaAgain.draft.attachments == [photo, notes], "pending attachments survive relaunch (bytes, names, ids)")
    let betaAgain = second.chat(for: "agent:main:beta")
    await betaAgain.load()
    check(betaAgain.draft.text == "/model" && betaAgain.draft.attachments.isEmpty, "other chat's draft restored separately")

    alphaAgain.draft.attachments.removeAll { $0.id == photo.id }
    await alphaAgain.flushDraft()
    let alphaFolder = gatewayFolder.appending(path: folders().first { name in
        let files = (try? FileManager.default.contentsOfDirectory(atPath: gatewayFolder.appending(path: name).path(percentEncoded: false))) ?? []
        return files.contains("\(notes.id.uuidString).bin")
    } ?? "missing")
    let alphaFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: alphaFolder.path(percentEncoded: false))) ?? [])
    check(alphaFiles == ["draft.json", "\(notes.id.uuidString).bin"], "removed attachment's file is deleted (\(alphaFiles.sorted()))")

    // Sending clears the composer.
    alphaAgain.draft = ComposerDraft()
    await alphaAgain.flushDraft()
    check(folders().count == 1, "an empty draft removes its folder")
    let third = GatewayStore(profile: profile)
    let alphaThird = third.chat(for: "agent:main:alpha")
    await alphaThird.load()
    check(alphaThird.draft.isEmpty, "a sent draft doesn't come back after relaunch")

    // Typing before the saved draft is read wins over the saved one.
    let fourth = GatewayStore(profile: profile)
    let betaFourth = fourth.chat(for: "agent:main:beta")
    betaFourth.draft.text = "typed first"
    await betaFourth.load()
    check(betaFourth.draft.text == "typed first", "a draft started before restore isn't overwritten")
    await betaFourth.flushDraft()
    let fifth = GatewayStore(profile: profile)
    let betaFifth = fifth.chat(for: "agent:main:beta")
    await betaFifth.load()
    check(betaFifth.draft.text == "typed first", "latest draft is the one on disk")

    // Rapid edits flushed at once still land in order.
    for index in 1...20 { betaFifth.draft.text = "edit \(index)" }
    await betaFifth.flushDraft()
    let sixth = GatewayStore(profile: profile)
    let betaSixth = sixth.chat(for: "agent:main:beta")
    await betaSixth.load()
    check(betaSixth.draft.text == "edit 20", "last of many quick edits is saved (got \(betaSixth.draft.text))")
    betaSixth.draft = ComposerDraft()
    await betaSixth.flushDraft()
    check(folders().isEmpty, "all drafts cleared")
}
