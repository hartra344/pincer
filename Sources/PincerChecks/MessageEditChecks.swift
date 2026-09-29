import Foundation
import PincerKit

/// #41: Branch from Here, Edit & Resend and Regenerate against a Gateway that keeps its seeded
/// garden chat (two user turns). Everything works on forks of it, so the seed stays as it was.
@MainActor
func runMessageEditChecks(_ gateway: GatewayStore, admin: Bool, _ label: String) async {
    print("Message edit, regenerate, branch (\(label))")
    let garden = "agent:main:dashboard:garden"
    let source = gateway.chat(for: garden)
    await source.load()
    let users = source.items.filter { $0.role == .user && $0.transcriptId != nil }
    let assistants = source.items.filter { $0.role == .assistant && $0.transcriptId != nil }
    check(users.count == 2 && assistants.count == 2, "seeded chat has two turns (\(users.count) user, \(assistants.count) assistant)")
    guard let lastUser = users.last, let firstAssistant = assistants.first, let lastAssistant = assistants.last else { return }
    check(source.canBranchMessages && source.canBranch(from: lastUser.id), "branch is offered")
    check(source.canRewindMessages == admin, "rewind follows admin scope (\(source.canRewindMessages))")
    check(source.canEdit(lastUser.id) == admin && !source.canEdit(lastAssistant.id), "edit is for user messages")
    check(source.canRegenerate(lastAssistant.id) == admin && !source.canRegenerate(firstAssistant.id), "regenerate is for the last reply")

    // A user message forks before itself and hands its text to the new composer.
    let userFork = await source.branch(from: lastUser.id)
    check(userFork != nil && userFork != garden && gateway.selectedKey == userFork, "branch from a user message opens a new chat")
    if let key = userFork {
        let chat = gateway.chat(for: key)
        await chat.load()
        check(chat.items.count == 2 && chat.items.last?.role == .assistant, "forked history stops before the message (\(chat.items.count) items)")
        check(chat.draft.text == lastUser.plainText, "the new composer holds the message text (\(chat.draft.text))")
    }
    // An assistant message forks at the next user message, with an empty composer.
    let assistantFork = await source.branch(from: firstAssistant.id)
    if let key = assistantFork {
        let chat = gateway.chat(for: key)
        await chat.load()
        check(chat.items.count == 2 && chat.draft.text.isEmpty, "branch after an assistant message keeps it and leaves the composer empty")
    } else {
        check(false, "branch from an assistant message (\(source.errorMessage ?? ""))")
    }
    // The last message has nothing after it: the whole chat forks.
    guard let whole = await source.branch(from: lastAssistant.id) else {
        check(false, "branch from the last message (\(source.errorMessage ?? ""))")
        return
    }
    let chat = gateway.chat(for: whole)
    await chat.load()
    check(chat.items.count == 4 && gateway.sessions[whole]?.raw["forkedFromParent"] == true, "branch from the last message forks the whole chat")
    check(source.items.count == 4, "the parent chat is untouched")
    guard admin else {
        check(!chat.beginEdit(chat.items[0].id) && chat.editTarget == nil, "edit is refused without admin")
        return
    }

    // Edit & Resend: non-destructive until Send.
    guard let editId = chat.items.last(where: { $0.role == .user })?.id else { return }
    chat.draft = ComposerDraft(text: "half-written")
    check(chat.beginEdit(editId) && chat.editTarget?.originalText == lastUser.plainText && chat.draft.text == lastUser.plainText,
          "edit puts the message in the composer")
    chat.cancelEdit()
    check(chat.editTarget == nil && chat.draft.text == "half-written" && chat.items.count == 4, "cancel restores the draft and changes nothing")
    _ = chat.beginEdit(editId)
    let outcome = await chat.sendEdit("Make it shade tolerant and add a trellis.", attachments: [])
    var sent = false
    if case .sent = outcome { sent = true }
    check(sent && chat.editTarget == nil, "sending the edit succeeds (\(outcome), \(chat.errorMessage ?? ""))")
    let edited = await waitFor("edited path", timeout: 20) {
        let texts = chat.items.filter { $0.role == .user }.map(\.plainText)
        return !chat.isRunning && texts.count == 2 && texts.last == "Make it shade tolerant and add a trellis."
            && chat.items.last?.role == .assistant
    }
    check(edited, "the transcript shows the cut path plus the edited message (\(chat.items.map(\.plainText)))")
    let cached = await TranscriptCache.load(gatewayId: gateway.id, sessionKey: whole)
    check(cached?.items.contains { $0.plainText.contains("Make it shade tolerant; it only gets four hours") } != true, "the cache dropped the old message")

    await runBranchNavigationChecks(chat, edited: "Make it shade tolerant and add a trellis.")

    // Regenerate: the last reply again, from the same message.
    guard let reply = chat.items.last, chat.canRegenerate(reply.id) else {
        check(false, "regenerate is offered on the last reply")
        return
    }
    let regenerated = await chat.regenerate(reply.id)
    check(regenerated, "regenerate succeeds (\(chat.errorMessage ?? ""))")
    let again = await waitFor("regenerated path", timeout: 20) {
        let texts = chat.items.filter { $0.role == .user }.map(\.plainText)
        return !chat.isRunning && texts == [users[0].plainText, "Make it shade tolerant and add a trellis."]
            && chat.items.last?.role == .assistant
    }
    check(again, "regenerate resends the same message without duplicating it (\(chat.items.map(\.plainText)))")
    gateway.selectedKey = garden
    let forks = [userFork, assistantFork, whole].compactMap { $0 }
    await gateway.sessionManager.load(filter: .all)
    let cleaned = await gateway.sessionManager.delete(forks)
    check(cleaned.succeeded.count == forks.count, "forks deleted again (\(cleaned.failed.map(\.message)))")
}

/// In-chat branch navigation on a chat that was just edited: the old path is a second branch.
@MainActor
private func runBranchNavigationChecks(_ chat: ChatStore, edited: String) async {
    await chat.refreshBranches()
    check(chat.canListBranches && chat.canSwitchBranches, "branches can be listed and switched")
    check(chat.branches.count == 2 && chat.activeBranchNumber == 2 && chat.hasBranches,
          "the edit left two branches, the newest last and active (\(chat.branches.map(\.headline)))")
    guard let old = chat.branches.first(where: { !$0.active }) else { return }
    let switched = await chat.switchBranch(to: old.leafEntryId)
    check(switched, "switch to the earlier branch (\(chat.errorMessage ?? ""))")
    let onOld = await waitFor("old branch transcript", timeout: 10) {
        chat.hasLoaded && chat.items.filter { $0.role == .user }.map(\.plainText).last?.hasPrefix("Make it shade tolerant; it only") == true
    }
    check(onOld && !chat.items.contains { $0.plainText == edited }, "the earlier branch's messages are shown")
    check(chat.branches.first { $0.active }?.leafEntryId == old.leafEntryId, "the switched-to branch is now active")
    let again = await chat.switchBranch(to: old.leafEntryId)
    check(!again, "the active branch is not a switch target")
    if let back = chat.branches.first(where: { !$0.active }) {
        let returned = await chat.switchBranch(to: back.leafEntryId)
        check(returned, "switch back (\(chat.errorMessage ?? ""))")
    }
}
