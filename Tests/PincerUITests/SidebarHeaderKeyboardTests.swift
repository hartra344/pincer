import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI
#if os(macOS)
import AppKit

/// Native AppKit keyboard path for sidebar headers; this deliberately does not rely on AX trust.
@MainActor
@Suite("Sidebar header keyboard focus", .serialized)
struct SidebarHeaderKeyboardTests {
    @Test func tabFocusAndHeaderCommandsUseTheRealOutline() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let profile = GatewayProfile(name: "Keyboard", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:mochi:main"
        let row = try #require(SessionRow(.object(["key": .string(key), "agentId": .string("mochi")])))
        let entry = SidebarModel.Entry(id: SidebarModel.entryId(key), row: row, icon: nil, color: nil,
                                       isThread: false, subagentCount: 0, runningSubagents: 0, hiddenUnreadThreads: 0,
                                       threadsExpanded: false, showSubagentRuns: false, preview: nil, working: nil,
                                       avatar: nil, avatarStyle: nil)
        let section = SidebarSection(id: "Mochi", title: "Mochi", emoji: nil, channels: [], kind: .agent("mochi"))
        let header = SidebarModel.Header(id: SidebarModel.headerId("Mochi"), section: section,
                                         isCollapsed: false, newChatAgent: "mochi")
        let model = SidebarModel(groups: [.init(header: header, entries: [entry])])
        let effects = Effects()
        let coordinator = SidebarList.Coordinator(gateway: gateway, actions: Self.actions(effects))
        defer { coordinator.stop() }
        let scroll = coordinator.makeScrollView()
        let outline = try #require(scroll.documentView as? NSOutlineView)
        coordinator.update(model: model, selectedKey: key, actions: Self.actions(effects), theme: AppTheme())

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        let before = NSTextField(string: "")
        let after = NSButton(title: "After", target: nil, action: nil)
        before.frame = NSRect(x: 8, y: 328, width: 120, height: 22)
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 310)
        outline.frame = scroll.bounds
        after.frame = NSRect(x: 140, y: 328, width: 80, height: 22)
        root.addSubview(before)
        root.addSubview(scroll)
        root.addSubview(after)
        before.nextKeyView = outline
        outline.nextKeyView = after
        after.nextKeyView = before
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 520, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = false
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.displayIfNeeded()
        outline.layoutSubtreeIfNeeded()

        let headerRow = outline.row(forItem: outline.item(atRow: 0))
        #expect(headerRow == 0)
        let headerItem = try #require(outline.item(atRow: headerRow))
        #expect(outline.delegate?.outlineView?(outline, shouldSelectItem: headerItem) == false,
                "mouse-driven selection continues to reject section headers")
        #expect(outline.selectedRow == outline.row(forItem: outline.item(atRow: 1)),
                "the current chat remains selected before keyboard focus moves")
        #expect(window.makeFirstResponder(before), "the preceding control accepts keyboard focus")
        window.sendEvent(Self.key("\t", code: 48, in: window))
        #expect(window.firstResponder === outline, "Tab enters the sidebar through the native key-view loop")

        window.sendEvent(Self.key("\u{F700}", code: 126, in: window)) // Up: from chat row to its section header.
        #expect(outline.selectedRow == headerRow, "the header can take keyboard focus without selecting a chat")
        #expect(effects.selected.isEmpty, "focusing a header never changes the selected chat")

        let refreshedSection = SidebarSection(id: "Mochi", title: "Mochi refreshed", emoji: nil,
                                              channels: [], kind: .agent("mochi"))
        let refreshedHeader = SidebarModel.Header(id: header.id, section: refreshedSection,
                                                  isCollapsed: false, newChatAgent: "mochi")
        let refreshed = SidebarModel(groups: [.init(header: refreshedHeader, entries: [entry])])
        coordinator.update(model: refreshed, selectedKey: key, actions: Self.actions(effects), theme: AppTheme())
        #expect(outline.selectedRow == headerRow, "a still-present header keeps keyboard focus through row reconfiguration")
        #expect(effects.selected.isEmpty)

        window.sendEvent(Self.key("\u{F702}", code: 123, in: window)) // Left collapses.
        #expect(effects.collapsed.last?.collapsed == true)
        window.sendEvent(Self.key("\u{F703}", code: 124, in: window)) // Right expands.
        #expect(effects.collapsed.last?.collapsed == false)
        window.sendEvent(Self.key("\u{F701}", code: 125, in: window)) // Down follows native outline navigation to the chat.
        #expect(outline.selectedRow == 1)
        #expect(effects.selected == [key])
        window.sendEvent(Self.key("\u{F700}", code: 126, in: window)) // Up returns to the header.
        #expect(outline.selectedRow == headerRow)
        #expect(effects.selected == [key], "returning to a header does not change chat selection")
        window.sendEvent(Self.key("\r", code: 36, in: window)) // Return toggles.
        #expect(effects.collapsed.last?.collapsed == true)
        window.sendEvent(Self.key("+", code: 24, modifiers: [.shift], in: window))
        #expect(effects.newChats == ["mochi"], "Shift-+ invokes only the focused header's + action")
        #expect(effects.selected == [key], "keyboard header commands preserve the selected chat")
    }

    private final class Effects {
        var selected: [String] = []
        var newChats: [String] = []
        var collapsed: [(id: String, collapsed: Bool)] = []
    }

    private static func actions(_ effects: Effects) -> SidebarActions {
        SidebarActions(select: { effects.selected.append($0) }, newChat: { effects.newChats.append($0) },
                       newChatInGroup: { _, _ in }, rename: { _ in }, changeIcon: { _ in }, changeGroupIcon: { _ in },
                       pickColor: { _ in }, prompt: { _ in }, confirm: { _ in }, toggleThreads: { _ in },
                       setCollapsed: { id, collapsed in effects.collapsed.append((id, collapsed)) },
                       refresh: {}, openAutomations: {})
    }

    private static func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
}
#endif
