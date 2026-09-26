# Pincer

A native macOS and iOS client for [OpenClaw](https://github.com/openclaw/openclaw). It keeps the parts of the Discord connection that work well, organized chats and notifications, and adds what Discord can't show: thinking, tool calls, inline images, and messages attributed to you as the owner.

<img width="2804" height="2004" alt="CleanShot 2026-09-25 at 3 20 07 PM@2x" src="https://github.com/user-attachments/assets/03bc0ca0-8cee-49bf-8985-a684b6e691b5" />


## What it is (and isn't)

Pincer is a **pure client**. It connects to a Gateway you already run and speaks the Gateway WebSocket protocol (v4) in the `operator` role, with the `operator.read`, `operator.write` and `operator.approvals` scopes. If you set a gateway's **Access** to **Full Management** (Gateway Settings → Connection), it also asks for `operator.admin`, which the gateway has to approve once more.

It **never** bundles, launches or embeds a Gateway, and it never registers as a node, so it exposes no camera, screen, shell or `system.run` capabilities. That makes it suitable for machines where the official OpenClaw app isn't allowed.

- **Identity:** each install creates an Ed25519 device key, stored in the Keychain and marked this-device-only. The gateway must approve the device once.
- **Secrets:** gateway tokens and passwords are stored in the Keychain and never in UserDefaults.
- **Transport:**
  - `wss://` is required for anything other than loopback, private LAN or Tailscale addresses.
  - You can pin a TLS certificate by its SHA-256 fingerprint.
  - Images are fetched only from the gateway itself: inline, through `artifacts.download`, or from the gateway's own host.
- **Local cache:** transcripts are cached in `~/Library/Caches/Pincer/Transcripts/<gateway>/`, one file per chat, up to 20,000 messages each. Files use complete file protection, and removing a gateway deletes its cache. Set `PINCER_CACHE_DIR=off` to turn the cache off, or set it to a path to use another folder.
- **Drafts:** each chat keeps its unsent text and pending attachments when you switch chats or relaunch. They're saved in `~/Library/Application Support/Pincer/Drafts/<gateway>/`, one folder per chat, using complete file protection. A draft is deleted when you send it, when its chat is deleted, or when you remove its gateway. Set `PINCER_DRAFTS_DIR=off` to turn draft saving off, or set it to a path to use another folder.
- **Sandbox:** the Xcode-built macOS app is sandboxed, with outgoing network access and read-only access to files you pick. The quick `scripts/bundle-mac.sh` dev bundle is only ad-hoc signed.

## Features

- **Layout:**
  - by default, a **"Like Discord"** layout: each Discord server gets a section with its `#channels`, automations get their own section, and everything else is grouped under its agent. You can also group by agent, by group, or by recency;
  - server names come from the gateway's Discord config (`channels.discord.guilds.<id>.slug`) when it's set; otherwise the section is just called "Discord". Discord categories aren't sent at all. To name a server yourself, right-click its header and choose **Rename Server…**. Names you set sync to your other devices through the gateway's user preferences (`users.prefs`, key `pincer.serverNames`); if the gateway has no durable identity for your connection, they stay on this device. To recreate categories, choose **New Group…** from the Organize menu (or a group header's menu), or right-click a channel and choose **Move to Group → New Group…**. Groups sync through the gateway;
  - subagent (helper) runs stay out of the sidebar, like Discord: open one from the **Open run** button on the tool call that started it, and a spinner on the parent shows helpers are working. Settings → Sidebar can list them under their parent (behind a ✨ count chip) instead. They never add to unread counts or notifications;
  - custom chat icons: right-click a chat and choose **Change Icon…** to pick an SF Symbol (tinted with the chat's color), or **Reset Icon** to go back to the default. Icons sync to your other devices through `users.prefs` (key `pincer.chatIcons`), since the gateway's session `icon` only takes emoji, named glyphs or SVG. Named glyphs set by other OpenClaw clients are shown too;
  - pinned chats. New chats you start are listed on their own, like in the Control UI; only forks and branches nest under their parent;
  - compaction doesn't start a new chat. It shows up inline as a "Compacting context…" line while it runs, then as a divider in the same thread;
  - search, unread dots and dock badge;
  - "Next Unread Chat" (⌥⇧↓).
- **Command palette and quick switching** (**Go** menu):
  - ⌘K opens a palette to jump to any chat on any gateway (recently visited first), start a new chat with an agent, change the chat's model, pin or unpin it, show or hide thinking steps, switch gateways, or open Settings, Gateway Settings or Automations. Type to filter (fuzzy, so `jptr` finds "Japan trip"), use ↑/↓ to move, Return to run and Esc to go back or close;
  - Back (⌘[) and Forward (⌘]) move through the chats you've visited, like a browser;
  - ⌘1–⌘9 open the selected gateway's pinned chats, in sidebar order.
- **Transcript:**
  - live streaming, with a collapsible **thinking** section and **tool cards** showing arguments and results. Choose whether to show thinking steps never, only live, or for every turn;
  - the full history of every chat loads in the background, so scrolling up never waits for the network. After connecting, Pincer quietly caches every chat (most recently active first) and skips chats that haven't changed. Opening one shows the cached transcript at once, then fetches only what's new;
  - Markdown, including tables and code blocks with a Copy button;
  - every message ends with a **Copy** button and its details: the model that wrote it and the full date and time it was sent. Back-to-back messages from the agent each get their own footer and some space, and replies from a different run start a new row;
  - **inline images** with a Quick Look-style preview and sharing. This covers attachments and the agent's `MEDIA:` lines, the same as the web UI. Local files are fetched through the gateway's `assistant-media` route. Public `https` images are downloaded directly, with no credentials or cookies sent; you can turn this off in Settings with "Load images the agent links from the web".
- **Appearance:** Settings → Appearance picks Light, Dark or System and a theme: Default (your system accent), Lobster, Ocean, Forest, Grape, Sunset, Graphite or Midnight. Themes color the accent, links, both avatars, and the chat, sidebar and code backgrounds, with separate shades for light and dark mode. Any of those colors can be overridden with your own pick, and reset back to the theme's.
- **Owner attribution:** messages from you appear under your own name (set in Settings, default is your macOS full name), even when they came in through Discord. A small "via Discord" tag shows where they came from.
- **Models:** the chat toolbar shows the session's model; pick another (from the Gateway's `models.list`) or go back to the agent's default, and new messages use it. Each reply's footer shows the model the Gateway recorded for it, so earlier replies keep their original model after a switch.
- **Composer:** Return sends and ⇧/⌥-Return adds a new line. You can paste, drag in or pick images and files; they are downscaled to fit the gateway's limits. Stop a run with ⌘.
- **Slash commands:** typing `/` suggests the commands the gateway offers for that chat (`commands.list`: built-ins, skills and plugins), then their arguments: listed choices (`/verbose on`), the agent's models for `/model`, and the session's thinking levels for `/think`. Use ↑/↓ to move, Tab or Return to complete, Esc to hide; Return sends once the command is complete. `/clear` is sent as `/reset`, like the Control UI. Gateways without `commands.list` get a built-in list of common commands.
- **Approvals:** exec approvals appear as a banner and as actionable notifications (Allow once, Always allow, Deny).
- **Notifications:** one notification thread per chat, a reply action, and no notification for the chat you're already looking at.
- **Gateway settings** (**Pincer → Gateway Settings…**, ⇧⌘, on macOS, or the gateway's menu in the sidebar): a window on macOS and a sheet on iOS, with a sidebar of pages:
  - **Connection** (this device's URL, token, access level and TLS pin; **Apply** reconnects) and **Overview** (version, config file and health);
  - curated pages (Gateway, Agents & Models, Channels, Sessions & Messages, Tools & Skills, Automation) built from the gateway's own schema (`config.get` / `config.schema`), with rarely used fields under **Advanced**. Sections the gateway's schema doesn't have are hidden;
  - **Plugins**: list, add (ClawHub, npm or git), remove, enable and disable plugins, and fill in their settings and credentials (`plugins.*`);
  - **All Settings** (every field, grouped by section) and **Raw Config** (JSON5, `config.apply`) for anything else. Search in the sidebar finds any setting and jumps to it;
  - edits from every page go into one draft. The toolbar shows how many are unsaved, and **Save** (⌘S) opens **Review Changes**, which lists each change and sends them together with `config.patch`, so the gateway validates, persists and hot-applies them. Invalid values come back with the field and reason, and changes that need a gateway restart say so. If the config changed on the gateway meanwhile, Pincer rebases the draft and asks about any conflicting setting;
  - secrets are shown only as "saved" and are never sent back to the gateway unless you change them;
  - editing needs **Access → Full Management** on the Connection page (and the gateway's approval); otherwise settings are read-only.
- **Automations** (**Organize → Automations…** in the sidebar, or **Manage Automations…** on the Automations section's header): a window on macOS and a sheet on iOS listing the gateway's cron jobs with their schedule, last and next run, and status (failing jobs show the error). Each job's run history (`cron.runs`) links every run to its chat. **Run Now**, **Pause**/**Resume**, **Edit**, **New** and **Delete** use `cron.run`/`cron.update`/`cron.add`/`cron.remove`, and the list updates live from the gateway's `cron` events. Changing jobs needs **Access → Full Management**; edits made elsewhere in the meantime are refused instead of overwritten. Gateways without `cron.*` show that automations aren't available.
- **Per-session actions:** pin, rename, group, color, reasoning level and archive. **Color → Custom…** picks any color; since `sessions.patch` only takes OpenClaw's named colors, custom colors sync through `users.prefs` (key `pincer.chatColors`) and win over the named one. Drag a chat onto a group (or **Ungrouped**) to move it, or between chats to put it at that spot; in **Like Discord**, dropping a grouped chat on its own server or agent takes it out of the group.
- **Groups:** create empty groups and keep them until you delete them (**Delete Group…** on the header leaves its chats ungrouped). Drag a group header, or use **Move Up**/**Move Down**, to reorder groups. **Change Icon…** on a group's header picks its SF Symbol; group icons sync through `users.prefs` (key `pincer.groupIcons`). Groups, their order and renames live in the gateway's group catalog (`sessions.groups.*`); on gateways without it, they sync through `users.prefs` (key `pincer.groups`). The order of chats within a group syncs through `users.prefs` (key `pincer.chatOrder`) and wins over pinning and activity.

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

OpenClaw only stores reasoning when the session's reasoning level is `on`. To turn it on, use the hint above the composer, the chat's ⋯ menu (**Gateway Reasoning → Save & Stream**), or send `/reasoning on` in the chat. Setting it to **Off** also hides reasoning text in the transcript.

How much of the agent's thinking steps (reasoning and tool calls) the transcript shows is a separate, per-device choice, under **Thinking Steps** in the chat's ⋯ menu or in Settings:

- **None:** only replies.
- **Live Only** (default): thinking and tool calls show while the agent works, then hide once the reply finishes.
- **All:** every turn keeps its thinking and tool calls, folded into one collapsible "Thinking" item once the turn finishes.

"Copy Thinking" stays in a reply's context menu whichever you pick.

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

### TestFlight

`.github/workflows/testflight.yml` archives both apps, signs them for the App Store, and uploads them to TestFlight. To run it, go to **Actions → TestFlight → Run workflow** and pick a platform, or push a `v*` tag. Each build number is `<run number>.<attempt>`.

Signing uses manual App Store profiles through `project.appstore.yml`, which is included only when `PINCER_APP_STORE_SIGNING=YES`. `scripts/testflight.sh ios|macos` does the work and also runs locally (`UPLOAD=0` exports without uploading). The workflow needs these repository secrets:

| Secret | Contents |
| --- | --- |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API key (the `.p8` is base64) |
| `DISTRIBUTION_P12`, `MAC_INSTALLER_P12`, `P12_PASSWORD` | Apple Distribution and Mac Installer Distribution certificates (base64 `.p12`) |
| `IOS_PROFILE`, `MACOS_PROFILE` | Base64 `Pincer_iOS_AppStore_CI` / `Pincer_macOS_AppStore_CI` provisioning profiles |

The certificates and profiles expire on 2027-09-25. Renew them before then and update the secrets.

### Layout

| Path | Contents |
| --- | --- |
| `Sources/PincerKit` | Protocol client (handshake, signing, reconnect, TLS pinning), models, and the observable stores. No UI. |
| `Sources/PincerUI` | Shared UI for macOS and iOS. The app shell is SwiftUI. The chat transcript and sidebar are native for performance: `NSTableView`/`NSOutlineView` on macOS and `UICollectionView` on iOS. Markdown is laid out once with TextKit (`TranscriptSupport`, `TranscriptRowView`), and the same part views are shared by both platforms. |
| `Apps/macOS`, `Apps/iOS` | `@main` app shells used by the Xcode project. |
| `Apps/Shared` | Resources shared by both apps, including the app icon (`AppIcon.icon`). |
| `Design/AppIcon` | Flattened reference artwork for the app icon (`Pincer.svg`). The shipped icon is `Apps/Shared/AppIcon.icon`, a layered Icon Composer file (gradient background + glass speech-bubble layer) with Default, Dark, Clear and Tinted appearances; edit it in Icon Composer (Xcode ▸ Open Developer Tool). Xcode renders flat fallbacks for iOS 18 / macOS 15. |
| `Sources/PincerMacDev` | Dev entry point so SwiftPM alone can produce the macOS app. |
| `Sources/PincerChecks` | Self-checks, with an optional live end-to-end run. |
| `mock-gateway/` | Node mock of the Gateway protocol for offline development. |

## Testing without a real gateway

The app has a built-in demo: choose **Try the Demo** on the welcome screen or in the Add Gateway sheet. It runs a simulated Gateway on the device, with sample agents, chats, streamed replies, a chart and an exec approval, and nothing leaves the device. This is what TestFlight and App Review testers use, so they don't need a Gateway or Tailscale. The message triggers below work in the demo too.

For the full protocol, including Gateway Settings, run the Node mock:

```sh
cd mock-gateway && npm install
npm start                                   # ws://127.0.0.1:18789, token "dev-token"
MOCK_TOKEN= MOCK_BACKGROUND=1 npm start     # no auth, simulated Discord traffic
```

Message triggers:
- a message containing `tool` or `disk` streams a tool call;
- `image` also attaches an image;
- `approve` raises an exec approval.

The mock also serves a small config and plugin catalog for Gateway Settings, and three cron jobs for Automations; see its README.

For the rest of the options, see [`mock-gateway/README.md`](mock-gateway/README.md).

To run the self-checks:

```sh
PINCER_KEYCHAIN=memory swift run PincerChecks
PINCER_KEYCHAIN=memory swift run PincerChecks --live ws://127.0.0.1:18789 dev-token
PINCER_KEYCHAIN=memory swift run PincerChecks --demo   # the built-in demo
```

`PINCER_KEYCHAIN=memory` keeps identities and secrets in memory, so checks and dev runs never touch your real Keychain. It works for the app too: `open --env PINCER_KEYCHAIN=memory build/Pincer.app`.

To see what the gateway says about each request, run the app with `open --env PINCER_REQUEST_LOG=/tmp/pincer.log build/Pincer.app`. Every request is logged with ✓ or the gateway's error, along with the fields of each sidebar update. History and image downloads are left out.

## Known gaps

- iOS runs in the simulator (connect, sidebar, history), but hasn't been tried on a real device yet.
- Automations has been tested against the mock only.
- Gateway Settings has been tested against the mock only. It doesn't browse the ClawHub catalog, show install progress, or edit lists of objects in forms (use the raw editor).

## License

MIT. See [LICENSE](LICENSE).
