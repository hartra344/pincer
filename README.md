# Pincer

A native macOS and iOS client for [OpenClaw](https://github.com/openclaw/openclaw). It keeps the parts of the Discord connection that work well, organized chats and notifications, and adds what Discord can't show: thinking, tool calls, inline images, and messages attributed to you as the owner.

```
┌────┬──────────────────┬──────────────────────────────────────┐
│ HM │ 🦞 Claw        + │ Main · Claw                      ⋯   │
│ ●  │   💬 home-lab  • │                                      │
│    │   ⌂  Main        │ AL  Alex       2:01 PM               │
│ +  │   #  Japan trip  │     Can you check disk usage?        │
│    │ 🔭 Scout       + │ 🦞  Claw  2:01 PM                    │
│    │   ⌂  Main        │     🧠 Thinking ›                    │
│    │   #  Paper digest│     ▸ exec  df -h                    │
│    │     ↳ Summarize… │     ## Disk status …   [image]       │
└────┴──────────────────┴──────────────────────────────────────┘
 gateways  agents → sessions → subagent threads
```

## What it is (and isn't)

Pincer is a **pure client**. It connects to a Gateway you already run and speaks the Gateway WebSocket protocol (v4) in the `operator` role, with the `operator.read`, `operator.write` and `operator.approvals` scopes. If you turn on **Manage Gateway settings** for a gateway (Edit Gateway → Advanced), it also asks for `operator.admin`, which the gateway has to approve once more.

It **never** bundles, launches or embeds a Gateway, and it never registers as a node, so it exposes no camera, screen, shell or `system.run` capabilities. That makes it suitable for machines where the official OpenClaw app isn't allowed.

- **Identity:** each install creates an Ed25519 device key, stored in the Keychain and marked this-device-only. The gateway must approve the device once.
- **Secrets:** gateway tokens and passwords are stored in the Keychain and never in UserDefaults.
- **Transport:**
  - `wss://` is required for anything other than loopback, private LAN or Tailscale addresses.
  - You can pin a TLS certificate by its SHA-256 fingerprint.
  - Images are fetched only from the gateway itself: inline, through `artifacts.download`, or from the gateway's own host.
- **Local cache:** transcripts are cached in `~/Library/Caches/Pincer/Transcripts/<gateway>/`, one file per chat, up to 20,000 messages each. Files use complete file protection, and removing a gateway deletes its cache. Set `PINCER_CACHE_DIR=off` to turn the cache off, or set it to a path to use another folder.
- **Sandbox:** the Xcode-built macOS app is sandboxed, with outgoing network access and read-only access to files you pick. The quick `scripts/bundle-mac.sh` dev bundle is only ad-hoc signed.

## Features

- **Layout:**
  - by default, a **"Like Discord"** layout: each Discord server gets a section with its `#channels`, automations get their own section, and everything else is grouped under its agent. You can also group by agent, by group, or by recency;
  - server names come from the gateway's Discord config (`channels.discord.guilds.<id>.slug`) when it's set; otherwise the section is just called "Discord". Discord categories aren't sent at all. To name a server yourself, right-click its header and choose **Rename Server…**. Names you set sync to your other devices through the gateway's user preferences (`users.prefs`, key `pincer.serverNames`); if the gateway has no durable identity for your connection, they stay on this device. To recreate categories, right-click a channel and choose **Move to Group → New Group…**. Groups sync through the gateway;
  - subagent (helper) runs stay out of the sidebar, like Discord: open one from the **Open run** button on the tool call that started it, and a spinner on the parent shows helpers are working. Settings → Sidebar can list them under their parent (behind a ✨ count chip) instead. They never add to unread counts or notifications;
  - pinned chats. New chats you start are listed on their own, like in the Control UI; only forks and branches nest under their parent;
  - compaction doesn't start a new chat. It shows up inline as a "Compacting context…" line while it runs, then as a divider in the same thread;
  - search, unread dots and dock badge;
  - "Next Unread Chat" (⌥⇧↓).
- **Transcript:**
  - live streaming, with a collapsible **thinking** section and **tool cards** showing arguments and results;
  - the full history of every chat loads in the background, so scrolling up never waits for the network. After connecting, Pincer quietly caches every chat (most recently active first) and skips chats that haven't changed. Opening one shows the cached transcript at once, then fetches only what's new;
  - Markdown, including tables and code blocks with a Copy button;
  - **inline images** with a Quick Look-style preview and sharing. This covers attachments and the agent's `MEDIA:` lines, the same as the web UI. Local files are fetched through the gateway's `assistant-media` route. Public `https` images are downloaded directly, with no credentials or cookies sent; you can turn this off in Settings with "Load images the agent links from the web".
- **Owner attribution:** messages from you appear under your own name (set in Settings, default is your macOS full name), even when they came in through Discord. A small "via Discord" tag shows where they came from.
- **Composer:** Return sends and ⇧/⌥-Return adds a new line. You can paste, drag in or pick images and files; they are downscaled to fit the gateway's limits. Stop a run with ⌘.
- **Approvals:** exec approvals appear as a banner and as actionable notifications (Allow once, Always allow, Deny).
- **Notifications:** one notification thread per chat, a reply action, and no notification for the chat you're already looking at.
- **Gateway settings** (sidebar menu → **Gateway Settings…**):
  - view and edit the gateway's OpenClaw config as forms generated from the gateway's own schema (`config.get` / `config.schema`), plus a raw JSON5 editor (`config.apply`) for anything the forms don't cover;
  - list, add (ClawHub, npm or git), remove, enable and disable plugins, and fill in their settings and credentials (`plugins.*`);
  - changes are saved with `config.patch`, so the gateway validates, persists and hot-applies them; invalid values come back with the field and reason, and changes that need a gateway restart say so;
  - secrets are shown only as "saved" and are never sent back to the gateway unless you change them;
  - editing needs **Manage Gateway settings** turned on for the gateway; without it, settings are read-only.
- **Per-session actions:** pin, rename, group, color, reasoning level and archive. Drag a chat onto a group (or **Ungrouped**) to move it; in **Like Discord**, dropping a grouped chat on its own server or agent takes it out of the group.

## Connecting to your home gateway over Tailscale

1. On the gateway host, expose the gateway with Tailscale Serve, following the OpenClaw remote-access docs.
2. In Pincer, click **+** in the rail and enter the address:
   - `wss://<host>.<tailnet>.ts.net`, for example `wss://my-mac.tail1234.ts.net`, since Serve uses HTTPS on port 443;
   - or `ws://100.x.y.z:18789` if you're connecting straight to the tailnet IP and Gateway port.
3. Pick the auth mode your gateway uses (token or password) and enter the secret.
4. The first time you connect, Pincer shows a pairing request. On the gateway host, run:
   ```sh
   openclaw devices list
   openclaw devices approve <requestId>
   ```
   Pincer reconnects automatically after you approve it.

### Seeing thinking

OpenClaw only stores reasoning when the session's reasoning level is `on`. To turn it on, use the hint above the composer, the chat's ⋯ menu (**Reasoning → On**), or send `/reasoning on` in the chat.

## Building

You need a current Xcode (Swift 6, macOS 15 / iOS 18 SDKs or later), with its license accepted (`sudo xcodebuild -license accept`). The SwiftUI macros ship only inside Xcode.app, so the Command Line Tools alone won't build the UI.

```sh
swift build                      # PincerKit, PincerUI, dev app, checks
scripts/bundle-mac.sh release    # -> build/Pincer.app (ad-hoc signed)
open build/Pincer.app
```

To produce signed macOS and iOS apps, generate the Xcode project with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
open Pincer.xcodeproj            # set your team, then run Pincer-macOS or Pincer-iOS
```

### Layout

| Path | Contents |
| --- | --- |
| `Sources/PincerKit` | Protocol client (handshake, signing, reconnect, TLS pinning), models, and the observable stores. No UI. |
| `Sources/PincerUI` | Shared UI for macOS and iOS. The app shell is SwiftUI. The chat transcript and sidebar are native for performance: `NSTableView`/`NSOutlineView` on macOS and `UICollectionView` on iOS. Markdown is laid out once with TextKit (`TranscriptSupport`, `TranscriptRowView`), and the same part views are shared by both platforms. |
| `Apps/macOS`, `Apps/iOS` | `@main` app shells used by the Xcode project. |
| `Apps/Shared` | Asset catalog shared by both apps, including the generated app icon. |
| `Design/AppIcon` | Source artwork for the app icon (`Pincer.svg`). After editing it, run `swift scripts/make-icons.swift` to regenerate the icons. |
| `Sources/PincerMacDev` | Dev entry point so SwiftPM alone can produce the macOS app. |
| `Sources/PincerChecks` | Self-checks, with an optional live end-to-end run. |
| `mock-gateway/` | Node mock of the Gateway protocol for offline development. |

## Testing without a real gateway

```sh
cd mock-gateway && npm install
npm start                                   # ws://127.0.0.1:18789, token "dev-token"
MOCK_TOKEN= MOCK_BACKGROUND=1 npm start     # no auth, simulated Discord traffic
```

Message triggers:
- a message containing `tool` or `disk` streams a tool call;
- `image` also attaches an image;
- `approve` raises an exec approval.

The mock also serves a small config and plugin catalog for Gateway Settings; see its README.

For the rest of the options, see [`mock-gateway/README.md`](mock-gateway/README.md).

To run the self-checks:

```sh
PINCER_KEYCHAIN=memory swift run PincerChecks
PINCER_KEYCHAIN=memory swift run PincerChecks --live ws://127.0.0.1:18789 dev-token
```

`PINCER_KEYCHAIN=memory` keeps identities and secrets in memory, so checks and dev runs never touch your real Keychain. It works for the app too: `open --env PINCER_KEYCHAIN=memory build/Pincer.app`.

To see what the gateway says about each request, run the app with `open --env PINCER_REQUEST_LOG=/tmp/pincer.log build/Pincer.app`. Every request is logged with ✓ or the gateway's error, along with the fields of each sidebar update. History and image downloads are left out.

## Known gaps

- iOS runs in the simulator (connect, sidebar, history), but hasn't been tried on a real device yet.
- Gateway Settings has been tested against the mock only. It doesn't browse the ClawHub catalog, show install progress, or edit lists of objects in forms (use the raw editor).
- Session groups are derived from each session's category; `sessions.groups.list` isn't used yet.

## License

MIT. See [LICENSE](LICENSE).
