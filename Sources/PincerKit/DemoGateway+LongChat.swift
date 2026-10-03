import Foundation

/// Demo showcase: a long single-topic chat (a home-lab migration) that is taller than a laptop window
/// and a phone screen, so scroll-to-bottom and Find while scrolled up can be tried by hand.
extension DemoGateway {
    static let longChatKey = "agent:main:dashboard:lab-migration"
    static let longChatTitle = "Home-lab migration"
    static let longChatPreview = "Cutover plan is ready for Saturday."
    static let longChatToolCall = "call_demo_long_zpool"

    static let longChatZpoolCommand = "zpool status vault"
    static let longChatZpoolOutput = """
      pool: vault
     state: ONLINE
      scan: none requested
    config:

    	NAME        STATE     READ WRITE CKSUM
    	vault       ONLINE       0     0     0
    	  mirror-0  ONLINE       0     0     0
    	    sda     ONLINE       0     0     0
    	    sdb     ONLINE       0     0     0

    errors: No known data errors
    """

    private static let longChatScript = """
    #!/usr/bin/env bash
    set -euo pipefail

    # Replicate every dataset to the NAS, then verify the snapshot lists match.
    SNAP="migrate-$(date +%F)"
    zfs snapshot -r tank@"$SNAP"
    zfs send -R tank@"$SNAP" | ssh nas zfs receive -F vault/tank
    diff <(zfs list -H -t snapshot -o name tank | sed 's/^tank//') \\
         <(ssh nas zfs list -H -t snapshot -o name vault/tank | sed 's/^vault\\/tank//')
    """

    /// The early turns; the last one ends in the tool call.
    private static let longChatTurns: [(user: String, assistant: String)] = [
        ("I want to retire the old Dell server and move everything to a pair of mini PCs. Where do I start?",
         """
         Start with an inventory, because the migration order depends on what actually runs there.

         From what you've told me before, the Dell runs Home Assistant, Pi-hole, Grafana and a few Docker stacks, and it also serves the photo and media shares from its own disks. The NAS is a separate box. I'd group them by how painful downtime is: DNS and Home Assistant are the ones the household notices, everything else can go dark for an evening.
         """),
        ("OK. List what's on it.", "Seven Docker stacks, two VMs (Home Assistant OS and a Debian utility box) and three NFS/SMB shares. Want sizes?"),
        ("Yes please.", "The photo library is 1.4 TB, archives are 900 GB, media is 3.2 TB, and the VMs together take about 120 GB."),
        ("That's a lot of data to move. How long will it take over gigabit?",
         """
         Roughly 5.5 TB at about 110 MB/s is 14 hours of pure transfer, so plan for a full weekend with headroom for retries.

         One way to shorten the cutover itself: replicate most of the data ahead of time while the old server keeps running, then do a small final incremental sync on the day. That turns a 14-hour outage into under an hour.
         """),
        ("Do that then.", "Agreed. I'll plan it as seed now, delta on cutover day."),
        ("Which hypervisor should the mini PCs run?",
         """
         I'd pick Proxmox VE. It's free, handles both VMs and LXC containers, has built-in ZFS and makes a two-node cluster straightforward.

         The one caveat is that two nodes can't keep quorum alone. You'd add a tiny third vote, such as a Raspberry Pi running `corosync-qnetd`, so a single node failure doesn't freeze the cluster.
         """),
        ("I have two Pis already.", "Then one of them can be the quorum device. It needs almost no resources."),
        ("What about storage? The mini PCs only have one NVMe slot each.",
         """
         Keep bulk data on the NAS rather than the mini PCs, and use each NVMe only for VM disks and container volumes. That's about 120 GB now, so a 1 TB drive each leaves plenty of room.

         For the data's new home, a mirror is worth it. You mentioned two spare 8 TB disks: put them in the NAS as a ZFS mirror pool called `vault`. That gives you 8 TB usable, enough for the 5.5 TB with room to grow, and survives one disk failing.
         """),
        ("Yes, I have two 8 TB drives. Can you check their health before I trust them?", "Sure, let me look at the new `vault` pool on the NAS first."),
    ]

    /// Later turns, after the tool call.
    private static let longChatMoreTurns: [(user: String, assistant: String)] = [
        ("Good. So the data disks are fine. What's the migration order?",
         """
         Here's the order I'd follow:

         1. Build the Proxmox cluster and the quorum device.
         2. Replicate the NAS datasets to the new pool (the seed).
         3. Move the stateless containers first: Pi-hole, Grafana.
         4. Migrate Home Assistant last, because it's the one everyone notices.
         5. Final delta sync, flip DNS and shares, keep the Dell powered off but not wiped for two weeks.
         """),
        ("Why Home Assistant last?", "Because automations touch physical things. If the Zigbee stick or the VM's USB passthrough misbehaves, you want everything else already settled."),
        ("Makes sense. Write me the replication script.",
         "Here's a first version. It snapshots recursively, sends the whole tree and then compares snapshot lists on both sides:"),
        ("Will that resume if the connection drops?",
         """
         Not as written. For a resumable transfer, receive with `-s` and restart with the resume token:

         `zfs send -t "$(ssh nas zfs get -H -o value receive_resume_token vault/tank)" | ssh nas zfs receive -s vault/tank`

         I'd wrap that in a loop so a flaky Wi-Fi link can't stall the seed.
         """),
        ("The transfer goes over the wired network, so should be fine.", "Then keep it simple, but I'd still add `-s` so you can recover from a reboot."),
        ("How do I avoid DNS downtime when Pi-hole moves?",
         """
         Run two Pi-hole instances for a day. Advertise both resolvers through DHCP so clients can use either, watch the new one's query log for a few hours, then drop the old resolver from the DHCP options.

         Keep the old one answering until the last lease expires. Since lease time is 24 hours, nobody is ever left without a resolver.
         """),
        ("Nice. What about the Grafana dashboards?", "Export them as JSON, or simply copy the Grafana data volume. The volume copy is easier and keeps the datasource settings."),
        ("Is there anything that could go wrong with Home Assistant's VM?",
         """
         Three things usually bite:

         - **USB passthrough:** the Zigbee coordinator's device path changes on a new host. Pass it through by vendor and product ID, not bus address.
         - **MAC address:** if the VM keeps its MAC, DHCP reservations keep working. Copy it in the VM config.
         - **Clock drift:** a restored VM can wake up with a stale clock and confuse time-based automations. Sync it before starting Home Assistant.
         """),
        ("Good list. I'll pass the stick by ID.", "That's the right call."),
        ("How should I protect the new cluster's VMs?", "Use Proxmox Backup Server (PBS) on the NAS, with nightly incremental snapshots and weekly verification. Deduplication keeps the repository small."),
        ("How much space will that need?", "With 120 GB of VM disks and a 30-day retention, expect roughly 200 to 300 GB thanks to dedup."),
        ("Can I keep offsite copies too?", "Yes. PBS can sync a namespace to a remote repository. A cheap storage box works well, and everything is encrypted client-side."),
        ("OK, add that to the list for later.", "Noted as a follow-up, after the cutover."),
        ("What's the power difference going to be?",
         """
         The Dell idles at about 95 W. Two mini PCs idle at roughly 10 to 15 W each, plus the NAS disks at 12 W.

         That's around 40 W total, so you'd save about 55 W, or roughly 480 kWh a year. At your electricity price the hardware pays for itself in roughly four years.
         """),
        ("That's a solid argument for my partner.", "I can put the numbers in a one-page summary if that helps."),
        ("Yes, do it.", "Drafted: 55 W saved, about 480 kWh per year, payback in roughly four years. I added a note about the quieter fans."),
        ("Let's talk about the network. Should the cluster get its own VLAN?",
         """
         A separate management VLAN is worth it: Proxmox's web UI and the cluster traffic shouldn't sit on the same network as guests' phones.

         Keep it simple: one management VLAN for the nodes and the PBS, your existing LAN for services. The switch you have supports VLANs, so this costs nothing.
         """),
        ("Do the nodes need a second NIC?", "Not for two nodes at this scale. A single gigabit link carries the cluster traffic fine; add a second NIC only if you start live-migrating large VMs often."),
        ("Good. What should I test before cutover day?",
         """
         I'd rehearse three things:

         - **Restore:** restore a PBS snapshot of a VM onto the other node and boot it.
         - **Failover:** pull the power on one node and confirm Pi-hole comes back via Proxmox HA within a minute or two.
         - **Shares:** mount the new SMB shares from a laptop and a phone, and check the photo app's upload job.
         """),
        ("Can Proxmox HA restart Home Assistant automatically?", "Yes, if the VM disk is on replicated storage. With local NVMe you'd use ZFS replication every few minutes, so a failover loses at most that much state."),
        ("Is that too much for a home setup?", "It's a modest amount of extra work, and it means a dead node doesn't turn off your lights. I'd enable it after the main cutover, not during."),
        ("Fair. What's the plan for the Dell afterwards?", "Keep it off but intact for two weeks, then wipe the disks and either sell it or use it as a cold spare."),
        ("What if something breaks after two weeks?", "By then the PBS snapshots and the offsite copy cover you. The Dell is only for the scary first fortnight."),
        ("Write the cutover checklist so I can follow it on the day.",
         """
         **Saturday cutover checklist**

         1. Final snapshot and incremental `zfs send` (expected under 30 minutes).
         2. Stop the Docker stacks on the Dell, take a last snapshot and sync again.
         3. Start the new containers, then the Home Assistant VM.
         4. Switch DHCP's DNS option to the new Pi-hole.
         5. Re-point SMB/NFS mounts and check the nightly jobs.
         6. Shut down the Dell. Don't wipe it.
         """),
        ("That looks right. Anything I'm forgetting?", "Two things: tell the household the lights might blink around noon, and export a copy of the Home Assistant config to your laptop before you start."),
        ("Ha, will do. Remind me on Friday.", "I'll remind you on Friday evening with the checklist attached."),
        ("Thanks. I think we're ready.", "You are. The cutover plan is ready for Saturday."),
    ]

    static func seedLongChatTranscript() -> [JSONValue] {
        var messages: [JSONValue] = []
        // The chat is one planning session about 3 days ago, a message every 20 minutes, oldest first.
        let total = Double(self.longChatTurns.count + self.longChatMoreTurns.count) * 2 + 2
        let day = 86400.0
        var index = 0.0
        func ago() -> Double {
            defer { index += 1 }
            return 3 * day + 60 + (total - index) * 1200
        }
        func pair(_ turn: (user: String, assistant: String), code: String? = nil) {
            messages.append(Self.message("user", [Self.text(turn.user)], ago: ago()))
            var body = turn.assistant
            if let code { body += "\n\n```bash\n\(code)\n```" }
            messages.append(Self.message("assistant", [Self.text(body)], ago: ago()))
        }
        for turn in Self.longChatTurns.dropLast() { pair(turn) }
        // Last of the early turns hands over to the tool call that checks the disks.
        let handoff = Self.longChatTurns[Self.longChatTurns.count - 1]
        messages.append(Self.message("user", [Self.text(handoff.user)], ago: ago()))
        messages.append(Self.message("assistant", [
            Self.text(handoff.assistant),
            Self.toolCall(Self.longChatToolCall, "exec", ["command": .string(Self.longChatZpoolCommand)]),
        ], ago: ago()))
        messages.append(Self.message("toolResult", [Self.text(Self.longChatZpoolOutput)], ago: ago(),
                                     extra: ["toolCallId": .string(Self.longChatToolCall), "toolName": "exec",
                                             "isError": false]))
        for turn in Self.longChatMoreTurns {
            pair(turn, code: turn.user.hasSuffix("Write me the replication script.") ? Self.longChatScript : nil)
        }
        return messages
    }

    /// Usage logs are derived from the same transcript shown in the chat, so search and drill-down
    /// text cannot drift into a second copy of the conversation.
    static var longChatUsageLog: [(role: String, content: String)] {
        self.seedLongChatTranscript().flatMap { message -> [(role: String, content: String)] in
            let role = message["role"]?.string
            let blocks = message["content"]?.array ?? []
            let text = blocks.compactMap { $0["text"]?.string }.joined(separator: "\n")
            var lines: [(role: String, content: String)] = []

            if let role, !text.isEmpty { lines.append((role, text)) }
            for block in blocks where block["type"]?.string == "toolCall" {
                let name = block["name"]?.string ?? "tool"
                let command = block["arguments"]?["command"]?.string
                lines.append(("tool", command.map { "\(name): \($0)" } ?? name))
            }
            return lines
        }
    }
}
