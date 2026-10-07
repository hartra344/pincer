import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Demo showcase transcripts and seed content.
extension DemoGateway {
    // MARK: Content

    static func reply(to text: String, usedTool: Bool, note: String? = nil, paletteShortcut: String? = "⌘K", findShortcut: String? = "⌘F",
                      quickCaptureShortcut: String? = HotKeyShortcut.default.displayString) -> String {
        let quoted = text.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
        return """
        \(quoted.isEmpty ? "" : quoted + "\n\n")\(note.map { $0 + "\n\n" } ?? "")This is **Pincer's demo mode**, \
        so this reply is canned. Connect your own OpenClaw Gateway to chat with real agents.

        \(Self.thingsToTry(usedTool: usedTool, paletteShortcut: paletteShortcut, findShortcut: findShortcut, quickCaptureShortcut: quickCaptureShortcut))

        ```text
        streaming: ok · markdown: ok · tools: \(usedTool ? "ran" : "on request")
        ```
        """
    }

    // MARK: Demo showcase: tips

    /// Trigger words match anywhere in a message, so each tip names only its own.
    static func thingsToTry(usedTool: Bool, paletteShortcut: String? = "⌘K", findShortcut: String? = "⌘F",
                            quickCaptureShortcut: String? = HotKeyShortcut.default.displayString) -> String {
        let findTip = findShortcut.map { "**\($0)** searches the chat — try \"onsen\" in *Japan trip*." }
            ?? "Use **Find in Chat** to search — try \"onsen\" in *Japan trip*."
        let paletteTip = paletteShortcut.map { "**\($0)** opens the command palette" }
            ?? "Open the command palette from the toolbar"
        let captureTip = quickCaptureShortcut.map { "On a Mac, **\($0)** opens Quick Capture." }
            ?? "On a Mac, open **Quick Capture** from the menu."
        return """
        ## Things to try

        - **tool** or **disk** runs a live tool call\(usedTool ? " (like the one above)" : "").
        - **image** adds an inline chart.
        - **approve** raises a command approval; **approve once-only** leaves out Always allow, and \
        **approve later** sends one a few seconds after the reply.
        - **ask** brings up a question card.
        - **secret** asks for an API key that goes straight to the Gateway's secret store.
        - **plan** walks the task progress card.
        - **long** streams a multi-page reply.
        - **fail** ends the run with an error.
        - Send **/compact**, or use **Compact Now** in the context ring.
        - \(findTip)
        - \(paletteTip), and **⌘1–⌘3** jump to pinned chats.
        - \(captureTip)
        - Settings → **Location** can share your device location as context for the agent. It starts off; \
        when enabled, the context stays separate from your message text and uses the device's reported accuracy.
        - Switch models, or pin, rename and group chats in the sidebar.
        """
    }

    // MARK: Demo showcase: long reply

    /// Streamed for the **long** trigger word: several blocks (heading, lists, a code fence with a blank line,
    /// a table, a quote) so a multi-page reply exercises chunked streaming.
    static let longReply = """
    ## Building a quiet home lab

    A home lab is easiest to live with when it is small, documented and boring. Start with a single mini PC running a hypervisor, \
    put the router and access point on their own circuit, and resist the urge to buy rack gear before you know what you will host. \
    Most people end up running the same handful of services for years, so pick hardware for idle power draw, not peak benchmarks.

    Networking deserves more thought than compute. Give the lab its own VLAN, keep guest devices and smart-home gadgets on \
    separate segments, and reserve static addresses for anything you will point a bookmark at. A managed switch with eight \
    ports is plenty, and once the cables are labelled you will thank yourself every time something needs moving.

    Backups are the part that turns a hobby into infrastructure. Snapshot the virtual machines nightly, copy them to a second \
    disk, and send an encrypted copy of the important data off site each week. Then actually restore one now and then; a backup \
    you have never restored is only a hope, and the drill takes less than an hour once it is scripted.

    ### What to run first

    - A DNS resolver with ad blocking for the whole house.
    - A reverse proxy that terminates TLS for every internal service.
    - A media server for photos, music and home videos.
    - A password manager the whole family can use.
    - A monitoring stack with a dashboard and phone alerts.
    - A small Git server for scripts and configuration.

    ### Rollout order

    1. Install the hypervisor and set a static address.
    2. Create the VLANs and firewall rules on the router.
    3. Bring up DNS and the reverse proxy.
    4. Add monitoring, then alerts you can live with.
    5. Schedule backups and test a restore.

    A tiny health check script keeps the dashboard honest:

    ```swift
    import Foundation

    struct Service {
        let name: String
        let url: URL
    }

    func check(_ service: Service) async -> Bool {
        do {
            let (_, response) = try await URLSession.shared.data(from: service.url)

            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    for service in [Service(name: "dns", url: URL(string: "http://10.0.10.2/health")!)] {
        print(service.name, await check(service) ? "up" : "down")
    }
    ```

    | Service | Host | Idle power |
    | --- | --- | --- |
    | DNS | mini PC | 1 W |
    | Media | mini PC | 4 W |
    | Backups | NAS | 9 W |

    Power is the hidden cost. A mini PC idles at a few watts, but a rack server can draw a hundred, which adds up to a real \
    line on the electricity bill by the end of the year. Measure with a plug-in meter before you commit, and turn off anything \
    you have not touched in a month; you can always bring it back from a snapshot in a couple of minutes.

    Noise and heat matter as well, especially in a flat. Fanless or low-profile machines can live in a cupboard, while anything \
    with small, fast fans belongs in a garage or basement. Leave a few centimetres of clearance around every box, and check \
    the temperatures on the dashboard after the first warm week.

    > Keep it boring. The best lab is the one your family never notices is there.

    That is the whole plan: one small box, a tidy network, and backups you have tested. Add one service at a time, write down \
    what you changed, and the lab will stay a pleasure to run instead of a second job.
    """

    static func words(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character.isWhitespace {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Keeps millisecond timestamps at or before the sampled wall clock.
    static func now(_ date: Date = .now) -> JSONValue {
        .number((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    static func shortId(_ prefix: String = "") -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    static func text(_ text: String) -> JSONValue { ["type": "text", "text": .string(text)] }
    static func thinking(_ text: String) -> JSONValue { ["type": "thinking", "thinking": .string(text)] }
    static func toolCall(_ id: String, _ name: String, _ args: JSONValue) -> JSONValue {
        ["type": "toolCall", "id": .string(id), "name": .string(name), "arguments": args]
    }

    static func image(_ artifactId: String, alt: String) -> JSONValue {
        ["type": "image", "artifactId": .string(artifactId), "mimeType": "image/png", "alt": .string(alt),
         "width": 320, "height": 200]
    }

    static func file(_ artifactId: String, name: String, mimeType: String) -> JSONValue {
        ["type": "file", "artifactId": .string(artifactId), "fileName": .string(name), "mimeType": .string(mimeType)]
    }

    static let diskScript = """
    #!/bin/sh
    # Prints each mounted volume's usage, flagging any above 80%.
    set -eu

    df -h | awk 'NR == 1 { print; next }
    {
      used = $5 + 0
      flag = used > 80 ? "  <- getting full" : ""
      print $0 flag
    }'
    """

    /// `replyToId` + `replyToPreview` for a user message replying to `targetId`, like the Gateway
    /// records them. Unknown ids reply to nothing.
    func replyFacts(_ key: String, _ targetId: String?) -> Row {
        guard let targetId, !targetId.hasPrefix(ChatItem.pendingInputPrefix),
              let target = self.transcripts[key]?.first(where: { $0["__openclaw"]?["id"]?.string == targetId })
        else { return [:] }
        let text = (target["content"]?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
            .joined(separator: "\n\n")
        let sender: String = target["role"]?.string == "assistant"
            ? self.agentName(self.sessions[key]?["agentId"]?.string ?? "main") : GatewayConnection.displayName
        return ["replyToId": .string(targetId),
                "replyToPreview": ["text": .string(String(text.prefix(2000))), "senderLabel": .string(sender)]]
    }

    func agentName(_ id: String) -> String {
        self.agents.first { $0["id"]?.string == id }?["name"]?.string ?? id
    }

    static func message(
        _ role: String, _ content: [JSONValue], runId: String? = nil, idempotencyKey: String? = nil,
        model: (provider: String, model: String)? = nil, id: String? = nil, openclaw facts: Row = [:],
        ago: Double = 0, extra: Row = [:]) -> JSONValue
    {
        var openclaw: Row = ["id": .string(id ?? UUID().uuidString.lowercased())]
        openclaw.merge(facts) { _, new in new }
        if let runId { openclaw["runId"] = .string(runId) }
        if let idempotencyKey { openclaw["idempotencyKey"] = .string(idempotencyKey) }
        let timestamp = ago > 0 ? JSONValue.number(((Date().timeIntervalSince1970 - ago) * 1000).rounded()) : Self.now()
        var message: Row = ["role": .string(role), "content": .array(content), "timestamp": timestamp,
                            "__openclaw": .object(openclaw)]
        if role == "assistant" {
            let model = model ?? Self.defaultModel
            message["provider"] = .string(model.provider)
            message["model"] = .string(model.model)
        }
        message.merge(extra) { _, new in new }
        return .object(message)
    }

    static func row(key: String, agentId: String, title: String, preview: String, ageMs: Double = 0) -> Row {
        let at = JSONValue.number((Self.now().double ?? 0) - ageMs)
        return [
            "key": .string(key), "sessionId": .string(UUID().uuidString.lowercased()), "kind": "direct",
            "label": nil, "derivedTitle": .string(title), "lastMessagePreview": .string(preview),
            "channel": "webchat", "agentId": .string(agentId), "isMain": false, "pinned": false, "unread": false,
            "archived": false, "updatedAt": at, "lastActivityAt": at, "status": "idle", "hasActiveRun": false,
            "activeRunIds": [], "model": .string(Self.defaultModel.model),
            "modelProvider": .string(Self.defaultModel.provider), "modelOverrideSource": nil,
        ]
    }

    static func seed() -> (sessions: [String: Row], transcripts: [String: [JSONValue]]) {
        var sessions: [String: Row] = [:]
        var transcripts: [String: [JSONValue]] = [:]
        func add(_ key: String, agent: String, title: String, preview: String, age: Double, _ extra: Row = [:],
                 messages: [JSONValue])
        {
            var row = Self.row(key: key, agentId: agent, title: title, preview: preview, ageMs: age)
            row.merge(["totalTokens": 24_000, "totalTokensFresh": true, "inputTokens": 24_000, "outputTokens": 900,
                       "contextTokens": JSONValue(Self.contextTokens)]) { _, new in new }
            row.merge(extra) { _, new in new }
            var messages = messages
            // Each chat runs on the model its sample usage is billed to.
            if let model = DemoUsage.model(for: key) {
                row["model"] = .string(model.model)
                row["modelProvider"] = .string(model.provider)
                messages = messages.map { message in
                    // Messages forwarded from another agent keep that agent's own model, not this chat's.
                    guard case var .object(fields) = message, fields["role"]?.string == "assistant",
                          fields["senderSession"] == nil else { return message }
                    fields["provider"] = .string(model.provider)
                    fields["model"] = .string(model.model)
                    return .object(fields)
                }
            }
            sessions[key] = row
            transcripts[key] = messages
        }

        let dfCall = "call_seed_df"
        let ackCall = "call_seed_ack"
        let minute = 60.0, hour = 3600.0, day = 86400.0
        /// A seeded message sent `ago` seconds before launch, so results show realistic dates.
        func said(_ role: String, _ text: String, ago: Double, extra: Row = [:]) -> JSONValue {
            Self.message(role, [Self.text(text)], ago: ago, extra: extra)
        }
        add("agent:main:main", agent: "main", title: "Main", preview: "Disk looks healthy.", age: 10_000,
            ["isMain": true, "totalTokens": 172_000, "inputTokens": 172_000], messages: [
                said("user", "Every weekday at 7:30, send me a morning briefing: weather, calendar and anything urgent in my inbox.",
                     ago: 9 * day),
                said("assistant", """
                Done. The morning briefing runs weekdays at 7:30 and posts here. Tomorrow's includes the forecast, \
                your first three meetings and any flagged mail.
                """, ago: 9 * day - minute),
                said("user", "Remind me to renew my passport before the Japan trip.", ago: 6 * day),
                said("assistant", """
                Reminder set for Monday at 9:00: **renew your passport**. Renewals take about four weeks, which \
                still leaves plenty of time before the flight to Tokyo.
                """, ago: 6 * day - minute),
                said("user", "Did last night's Time Machine backup finish?", ago: 5 * day),
                said("assistant", """
                Yes. The backup finished at 02:14 and copied 3.2 GB. The oldest snapshot still kept is from March.
                """, ago: 5 * day - minute),
                said("user", "Book a table for two at Café Lumière on Friday at 8.", ago: 3 * day),
                said("assistant", """
                Café Lumière has nothing at 8:00 on Friday, but 8:15 is free. I've held 8:15 for two under your \
                name; reply *confirm* to keep it.
                """, ago: 3 * day - minute),
                said("user", "confirm", ago: 3 * day - 5 * minute),
                said("assistant", "Confirmed: Café Lumière, Friday at 8:15 pm, two people. It's in your calendar with the address.",
                     ago: 3 * day - 6 * minute),
            ] + Self.seedKikoIntroInClaw() + [
                Self.message("user", [Self.text("Can you check disk usage and show me a quick status?")], id: "demo-main-ask",
                             ago: 20 * minute),
                Self.message("assistant", [
                    Self.thinking("I should look at disk usage and summarize the main volumes."),
                    Self.toolCall(ackCall, "message", ["action": "react", "emoji": "✅"]),
                    Self.toolCall(dfCall, "exec", ["command": "df -h"]),
                ], id: "demo-main-thinking", ago: 20 * minute - 5),
                Self.message("toolResult", [Self.text(#"{"ok":true,"added":"✅"}"#)], ago: 20 * minute - 7,
                             extra: ["toolCallId": .string(ackCall), "toolName": "message", "isError": false]),
                Self.message("toolResult", [Self.text("""
                Filesystem      Size  Used Avail Use% Mounted on
                /dev/disk3s1   926G  411G  490G  46% /
                /dev/disk3s6   926G  7.0G  490G   2% /System/Volumes/VM
                """)], ago: 20 * minute - 10, extra: ["toolCallId": .string(dfCall), "toolName": "exec", "isError": false]),
                Self.message("assistant", [
                    Self.text("""
                    ## Disk status

                    - The root volume has plenty of room.
                    - The VM volume is barely used.

                    ```text
                    /dev/disk3s1  46% used
                    ```

                    Here's a quick chart.
                    """),
                    Self.image("demo-chart", alt: "Disk usage chart"),
                    Self.file("demo-script", name: "disk-report.sh", mimeType: "text/x-shellscript"),
                ], id: "demo-main-status", ago: 20 * minute - 15),
                Self.message("user", [Self.text("Can you sketch that as a little gauge?")], id: "demo-main-gauge-ask",
                             openclaw: ["replyToId": "demo-main-status",
                                        "replyToPreview": ["text": "Disk status — The root volume has plenty of room…",
                                                           "senderLabel": "Claw"]],
                             ago: 15 * minute),
                Self.message("assistant", [Self.text("""
                Here's the root volume as a gauge:

                ```svg
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 140" width="240" height="140">
                  <path d="M20 120 A100 100 0 0 1 220 120" fill="none" stroke="#d9dde3" stroke-width="18" stroke-linecap="round"/>
                  <path d="M20 120 A100 100 0 0 1 108 21" fill="none" stroke="#34a37a" stroke-width="18" stroke-linecap="round"/>
                  <text x="120" y="112" text-anchor="middle" font-family="-apple-system, sans-serif" font-size="30" font-weight="600" fill="#34a37a">46%</text>
                </svg>
                ```
                """)], id: "demo-main-gauge", ago: 15 * minute - 10),
                Self.message("user", [Self.text("Find a coffee shop nearby.")], id: "demo-location-context-user",
                    openclaw: ["workContext": ["snapshot": ["page": "Pincer location",
                        "selection": "Device location: 42.360100, -71.058900 (reported accuracy ±18m, observed 2026-09-30T12:00:00Z)."]]], ago: 20),
                Self.message("assistant", [Self.text("Using the fictional Boston location shared for this demo, I can look for coffee near Boston Common. Your location reference stays separate from your message.")],
                    id: "demo-location-context-reply", ago: 15),
                Self.message("assistant", [Self.text("""
                👋 **Welcome to the Pincer demo.** Everything here is simulated on your device, so no Gateway \
                is needed. Send a message to see a streamed reply. Try the words *tool*, *image*, *approve*, *ask*, *secret* or *plan*, \
                or send */compact*.

                Settings → **Location** can share available device location with your assistant. It starts off.
                Location travels separately from your message, so your chat bubbles stay clean.
                The Boston example above is fictional; it is not your device's location.
                """)], ago: 10),
            ])
        add(Self.kikoKey, agent: "kiko", title: "Main", preview: "Claw sent the list of home-lab bills.", age: 86_400_000,
            ["isMain": true, "totalTokens": 58_000, "inputTokens": 57_000, "outputTokens": 1_000],
            messages: Self.seedKikoChat())
        add("agent:mochi:main", agent: "mochi", title: "General", preview: "Moving day is Oct 18; I'll keep the checklist.",
            age: 5 * 3_600_000, ["isMain": true, "label": "General"], messages: [
                said("user", "I'm moving from Boston to Brooklyn on October 18.", ago: 6 * day),
                said("assistant", "Got it. Moving day is Oct 18; I'll keep the checklist and split it into prep and the day itself.",
                     ago: 6 * day - minute),
            ])
        add("agent:mochi:dashboard:apartments", agent: "mochi", title: "Apartment Hunt",
            preview: "Three Park Slope listings under $3,200.", age: 4 * 3_600_000,
            ["label": "Apartment Hunt", "category": "Preparations"], messages: [
                said("user", "Find 1-bedrooms in Park Slope under $3,200 that allow cats.", ago: 5 * day),
                said("assistant", "Three listings fit: 5th Ave ($3,050), 7th Ave ($3,150) and Garfield Pl ($3,190). All allow cats.",
                     ago: 5 * day - minute),
            ])
        add("agent:mochi:dashboard:packing", agent: "mochi", title: "Packing list",
            preview: "Kitchen is packed; books are next.", age: 3 * 3_600_000,
            ["label": "Packing list", "category": "Preparations"], messages: [
                said("user", "Make a room-by-room packing list.", ago: 4 * day),
                said("assistant", "Kitchen is packed; books are next. Buy 20 small boxes for them; large ones get too heavy.",
                     ago: 4 * day - minute),
            ])
        add("agent:mochi:dashboard:movers", agent: "mochi", title: "Movers",
            preview: "Arrival window is 8-10am on the 18th.", age: 2 * 3_600_000,
            ["label": "Movers", "category": "Day of move"], messages: [
                said("user", "Book two movers for the morning of the 18th.", ago: 3 * day),
                said("assistant", "Booked with Brooklyn Bound: arrival window is 8-10am on the 18th, 4-hour minimum.",
                     ago: 3 * day - minute),
            ])
        add("agent:mochi:dashboard:utilities", agent: "mochi", title: "Utilities setup",
            preview: "Con Edison transfer scheduled for the 17th.", age: 1 * 3_600_000,
            ["label": "Utilities setup"], messages: [
                said("user", "Set up electricity and internet at the new place.", ago: 2 * day),
                said("assistant", "Con Edison transfer is scheduled for the 17th; internet install is booked for the 19th.",
                     ago: 2 * day - minute),
            ])
        let discord: Row = ["provenance": ["sourceChannel": "discord"]]
        add("agent:main:discord:channel:123", agent: "main", title: "home-lab", preview: "Discord bridge is online.",
            age: 20_000, ["label": "home-lab", "category": "Home", "channel": "discord", "pinned": true, "unread": true],
            messages: [
                said("user", "Nightly backup to the NAS failed again, can you check why?", ago: 12 * day, extra: discord),
                said("assistant", """
                The backup job stopped at 03:02 because the NAS share ran out of space: old photo library \
                snapshots take 1.1 TB. Want me to prune everything older than 90 days?
                """, ago: 12 * day - minute),
                said("user", "Yes, prune them and rerun it.", ago: 12 * day - 10 * minute, extra: discord),
                said("assistant", "Pruned 412 snapshots (780 GB freed) and reran the backup. It finished in 41 minutes with no errors.",
                     ago: 12 * day - 55 * minute),
                said("user", "What's drawing so much power on the rack?", ago: 8 * day, extra: discord),
                said("assistant", """
                The UPS reports 186 W. The old Dell server idles at 95 W of that; the switch, the NAS and the \
                Raspberry Pis share the rest.
                """, ago: 8 * day - minute),
                said("user", "Add the new Zigbee door sensor to Home Assistant.", ago: 4 * day, extra: discord),
                said("assistant", """
                Paired it as `binary_sensor.garage_door`. It reports open, closed and battery level, and it's on \
                the Security dashboard now.
                """, ago: 4 * day - 2 * minute),
                said("user", "Is the Grafana dashboard still showing the Pi-hole stats?", ago: day, extra: discord),
                said("assistant", """
                Yes. Pi-hole blocked 18% of 42,000 queries in the last 24 hours; the panel came back after the \
                container restarted.
                """, ago: day - minute),
                Self.message("user", [Self.text("The lab temperature sensor looks noisy tonight.")], id: "demo-lab-sensor",
                             openclaw: ["transport": ["channel": "discord", "messageId": "1300000000000000001",
                                                      "conversationRef": "channel:123"]],
                             ago: minute, extra: discord),
                Self.message("assistant", [
                    Self.toolCall("call_seed_lab_ack", "message",
                                  ["action": "react", "emoji": "👀", "messageId": "1300000000000000001"]),
                ], ago: 50),
                Self.message("toolResult", [Self.text(#"{"ok":true,"added":"👀"}"#)], ago: 45,
                             extra: ["toolCallId": "call_seed_lab_ack", "toolName": "message", "isError": false]),
                said("assistant", "I'll keep an eye on the home-lab channel and flag anything unusual.", ago: 20),
            ])
        // A bridged Telegram chat (account "home") whose agent replies carry `openclawDelivery` reply targets.
        let telegram: Row = ["provenance": ["sourceChannel": "telegram"]]
        func tgUser(_ id: String, _ messageId: String, _ text: String, ago: Double) -> JSONValue {
            Self.message("user", [Self.text(text)], id: id,
                         openclaw: ["transport": ["channel": "telegram", "messageId": .string(messageId),
                                                  "conversationRef": "5550142"],
                                    "senderId": "5550142", "senderName": "Maya"],
                         ago: ago, extra: telegram.merging(["senderLabel": "Maya"]) { _, new in new })
        }
        func tgReply(_ text: String, delivery: JSONValue, ago: Double) -> JSONValue {
            Self.message("assistant", [Self.text(text)], ago: ago, extra: ["openclawDelivery": delivery])
        }
        add("agent:main:telegram:home:direct:5550142", agent: "main", title: "Maya", preview: "Friday pickup is at 3:15.",
            age: 45_000,
            ["label": "Maya", "category": "Home", "channel": "telegram", "lastChannel": "telegram", "lastAccountId": "home"],
            messages: [
                tgUser("demo-tg-clinic", "9101", "Can you find the pediatrician's opening hours?", ago: 40 * minute),
                tgUser("demo-tg-dentist", "9102", "Also, when is my dentist appointment?", ago: 39 * minute),
                tgReply("Dr. Alvarez's office is open Monday to Friday, 8:00 to 17:00, and Saturday 9:00 to 12:00.",
                        delivery: ["replyToId": "demo-tg-clinic"], ago: 38 * minute),
                tgReply("Your dentist appointment is Thursday at 10:30 with Dr. Kim.",
                        delivery: ["replyToCurrent": true], ago: 37 * minute + 30),
                tgUser("demo-tg-pharmacy", "9104", "Did the pharmacy call back about the refill?", ago: 20 * minute),
                tgUser("demo-tg-bus", "9105", "Is the 7:40 bus running today?", ago: 19 * minute),
                // The agent names the pharmacy message by Telegram's own message id, not a transcript id.
                tgReply("The pharmacy called at 9:05: the refill is ready for pickup until 6 pm.",
                        delivery: ["replyToId": "9104"], ago: 18 * minute),
                tgUser("demo-tg-pickup", "9103", "And what time is school pickup on Friday?", ago: 5 * minute),
                tgReply("[[reply_to_current]] Friday pickup is at 3:15, half an hour earlier than usual.",
                        delivery: ["replyToCurrent": true], ago: 4 * minute),
            ])
        add("agent:main:dashboard:trip", agent: "main", title: "Japan trip", preview: "Kyoto day plan drafted.",
            age: 60_000, ["label": "Japan trip", "category": "Personal", "color": "pink", "pinned": true,
                          "totalTokens": 192_000, "inputTokens": 192_000],
            messages: Self.seedTripTranscript())
        add("agent:research:main", agent: "research", title: "Main", preview: "Research queue is clear.", age: 90_000,
            ["isMain": true], messages: [
                said("assistant", "Scout is ready to dig into papers, repos, and docs.", ago: 14 * day),
                said("user", "Compare SQLite FTS5 and Tantivy for searching chat history on a phone.", ago: 6 * day),
                said("assistant", """
                FTS5 is the better fit on a phone: it ships with the OS, adds nothing to the app's size and \
                searches a few hundred thousand messages in milliseconds. Tantivy is faster at larger scale but \
                adds about 5 MB and a Rust toolchain.
                """, ago: 6 * day - 2 * minute),
                said("user", "Find the best reviewed noise-cancelling headphones for long flights.", ago: 3 * minute),
                said("assistant", """
                Reviewers agree on the Sony WH-1000XM6 for noise cancelling and battery life. The Bose \
                QuietComfort Ultra is more comfortable on a long flight, like the one to Tokyo.
                """, ago: 90),
            ])
        add("agent:research:dashboard:papers", agent: "research", title: "Paper digest",
            preview: "Three papers summarized.", age: 120_000,
            ["label": "Paper digest", "category": "Reading", "unread": true, "pinned": true,
             "totalTokens": 96_000, "inputTokens": 94_000, "outputTokens": 2_000],
            messages: [
                said("user", "What's new in speculative decoding?", ago: 5 * day),
                said("assistant", """
                Two themes this week: draft models that share the target model's KV cache, and tree-based \
                verification that accepts several tokens per step. Both report 2–3× faster generation with \
                identical outputs.
                """, ago: 5 * day - 2 * minute),
                said("user", "Summarize the latest diffusion papers.", ago: 3 * minute),
                said("assistant", "The main themes are consistency models, faster sampling, and video generation.",
                     ago: 2 * minute),
            ])
        add("agent:research:subagent:abc", agent: "research", title: "Summarize arXiv 2401.x",
            preview: "Subagent found the main contribution.", age: 180_000,
            ["label": "Summarize arXiv 2401.x", "parentSessionKey": "agent:research:dashboard:papers",
             "spawnedBy": "agent:research:dashboard:papers", "hasActiveRun": true, "status": "running",
             "activeRunIds": [.string(Self.seededHelperRunId)]],
            messages: [
                said("assistant", "The paper mainly improves how retrieval-augmented summaries are evaluated.", ago: 3 * minute),
            ])
        add(DemoOutbox.sessionKey, agent: "main", title: DemoOutbox.title, preview: DemoOutbox.preview, age: 120_000,
            ["label": .string(DemoOutbox.title), "category": "Personal"], messages: Self.seedOutboxTranscript())
        // Forge is still at work here, so the sidebar shows a working chat at launch.
        add(Self.fileEditsKey, agent: "coder", title: "Fix retry backoff", preview: Self.fileEditsPreview,
            age: 5 * hour * 1000, ["hasActiveRun": true, "status": "running", "activeRunIds": [.string(Self.seededRunId)]],
            messages: Self.seedFileEditsTranscript())
        add(Self.richRenderingKey, agent: "main", title: Self.richRenderingTitle, preview: Self.richRenderingPreview,
            age: 8 * 60_000, messages: Self.seedRichRenderingTranscript())
        add(Self.longChatKey, agent: "main", title: Self.longChatTitle, preview: Self.longChatPreview,
            age: 3 * 86_400_000, messages: Self.seedLongChatTranscript())
        add(Self.toolCardsKey, agent: "main", title: Self.toolCardsTitle, preview: Self.toolCardsPreview, age: 3 * 60_000,
            messages: Self.seedToolCardsTranscript())
        add("agent:coder:main", agent: "coder", title: "Main", preview: "Waiting for approval to push the fix.", age: 45_000,
            ["isMain": true, "unread": true], messages: [
                said("assistant", "Forge can edit code, run builds, and report back briefly.", ago: 14 * day),
                said("user", "The login test is flaky on CI again.", ago: 10 * day),
                said("assistant", """
                It races the token refresh: the test signs in before the mock clock advances. I pinned the clock \
                in `LoginTests.setUp()`, and it has passed 50 runs in a row.
                """, ago: 10 * day - 4 * minute),
                said("user", "Write a script that backs up the Postgres database every night.", ago: 7 * day),
                said("assistant", """
                Added `scripts/backup-db.sh`. It runs `pg_dump`, gzips the output to \
                `/backups/db-$(date +%F).sql.gz` and keeps the last 14 days. A cron entry runs the backup at 02:30.
                """, ago: 7 * day - 3 * minute),
                said("user", "Why is the release build slower than debug?", ago: 2 * day),
                said("assistant", """
                Whole-module optimization was off in the Release configuration, so every file compiled on its \
                own. Turning it on cut the build from 6 min 40 s to 2 min 55 s.
                """, ago: 2 * day - 2 * minute),
                said("user", "Fix the login timeout and push it.", ago: 3 * minute),
                said("assistant", """
                Raised the login timeout to 30 s and the tests pass. I've asked to run \
                `git push origin fix/login-timeout`; approve it and I'll push.
                """, ago: 45),
            ])
        // Chats of the demo's cron jobs (the log's morning-briefing and disk-check), hidden from the
        // sidebar until Organize ▸ Show Automations is on.
        let cron: Row = ["channel": "cron", "totalTokens": 6_400, "inputTokens": 6_400, "outputTokens": 420]
        let briefingPrompt = "Write my morning briefing: weather, calendar and anything urgent in my inbox."
        add("agent:main:cron:morning-briefing", agent: "main", title: "Morning briefing",
            preview: "Sunny, 22°C. Two meetings and one flagged email.", age: 2 * hour * 1000,
            cron.merging(["label": "Automation: Morning briefing", "unread": true]) { _, new in new }, messages: [
                said("user", briefingPrompt, ago: day + 2 * hour),
                said("assistant", """
                **Good morning.** Light rain until 10, then clearing to 19°C. You have a 1:1 with Priya at 10:00 \
                and nothing else before lunch. No urgent mail overnight.
                """, ago: day + 2 * hour - minute),
                said("user", briefingPrompt, ago: 2 * hour),
                said("assistant", """
                **Good morning.** Sunny and 22°C all day.

                - 09:30 Design review
                - 14:00 Dentist (Harbor St.)

                One flagged email: the landlord needs the lease renewal signed **by Friday**.
                """, ago: 2 * hour - minute),
            ])
        add("agent:main:cron:disk-check", agent: "main", title: "Check disk space",
            preview: "The external drive isn't mounted.", age: 3 * hour * 1000,
            cron.merging(["label": "Automation: Check disk space"]) { _, new in new }, messages: [
                said("user", "Check free space on every volume and warn me under 10%.", ago: 3 * hour),
                said("assistant", """
                The root volume is at 46% and fine. The external drive isn't mounted, so I couldn't check it \
                (`df` exited with code 1).
                """, ago: 3 * hour - minute),
            ])
        // Native Discord slash commands run in their own `…:discord:slash:<userId>` session.
        add("agent:main:discord:slash:418235907214753792", agent: "main", title: "Slash commands",
            preview: "Status: online, 3 agents, 1 pending approval.", age: 4 * hour * 1000,
            ["channel": "discord", "totalTokens": 1_200, "inputTokens": 1_200, "outputTokens": 80], messages: [
                said("user", "/status", ago: 4 * hour, extra: discord),
                said("assistant", "Status: online, 3 agents, 1 pending approval.", ago: 4 * hour - 2),
            ])
        return (sessions, transcripts)
    }
}
