# Documentation screenshots

These are real app captures, not mockups. All chat content, model names, paths, usage figures, jobs and configuration are fixtures. Alex is a fictional display name. Screenshots illustrate the interface; they do not establish real-gateway compatibility.

## Feature refresh — September 28, 2026

The images under `src/assets/screenshots/features/` were captured from fresh normal macOS and iOS builds based on `fefab92`, with this change's fixture privacy corrections. Both builds use isolated bundle identifiers (`chat.pincer.documentation.refresh` and `chat.pincer.documentation.refresh.ios`), no shared App Group or Keychain group, memory-only credentials, and disabled transcript, draft and outbox persistence. The installed Pincer app and its real connections were not used.

- **macOS:** SwiftPM debug build, ad-hoc signed, captured with CleanShot. Each capture contains only the foreground app window or sheet. No dedicated capture application was built.
- **iOS:** normal Xcode iOS target, copied to the isolated identifier, on iPhone 17 Pro / iOS 26.5 Simulator. Native XCTest attachments capture the real app. Status bar: 9:41, full battery. Temporary navigation tests and generated projects are not shipped.
- **Fixtures:** built-in Demo for sessions, diffs, run tree/timeline, outbox, skills, tool policy, devices, channels, avatars, search and logs. The iPhone tool-policy example, agent management, workspace files and forwarded messages use the repository's loopback mock at `ws://127.0.0.1:19879`. Names and workspace text that previously used a developer's first name now use the fictional Alex persona in both fixture implementations.
- **Mock connection:** `HOST=127.0.0.1 PORT=19879 MOCK_AUTH=none MOCK_PAIRING=off MOCK_BACKGROUND=0 node mock-gateway/server.mjs`, with Full Management in the isolated profile. This unauthenticated mode is restricted to loopback and is used only for synthetic capture data.

### Documentation audit and capture map

Each row names the new files under `features/`; paired iPhone files use the same name under `features/ios/`. Existing first-run and setup-wizard guides already have their own recent `first-run/` image sets, so this refresh keeps those examples.

| Guide / files | What to capture |
| --- | --- |
| Homepage and README: `homepage` (macOS) | Built-in Demo → Claw → Main, light appearance with Pixel companion avatars. Expand Thinking; keep tool cards collapsed and frame the disk summary, code block and complete inline chart. Empty the composer. |
| Sessions: `sessions`, `session-branches` | Gateway Settings → Sessions. Show run states, then Garden planner → Details → Branches and Rewind. Leave destructive actions unconfirmed. |
| File diffs: `file-diffs` | Forge → Fix retry backoff. Expand Thinking; show the edited retry.ts card and its added/removed lines. |
| Subagents: `run-tree`, `run-timeline` | Research: launch plan → Runs. Show nested helpers and the same activity in Timeline. The trademark failure is simulated. |
| Offline outbox: `offline-outbox` | Dinner party → seeded failed shopping-list request. Dismiss the reasoning hint. Leave Retry and Delete visible without sending. |
| Skills: `skills`, `effective-tools` | Gateway Settings → Skills; Garden planner → Session → Tools & Policy. The two platforms may show different portions of the list. |
| Devices: `devices` | Gateway Settings → Devices. Show pending requests, fingerprints and scopes; do not approve or revoke anything. |
| Channels: `channel-status` | Gateway Settings → Channel Status. Show connected Discord, degraded Telegram and logged-out WhatsApp; no real account linking. |
| Avatars: `agent-avatars` | Settings → Appearance on Mac, Settings on iPhone. Scroll to Pixel/Plush and the four agents' Auto character choices. |
| Agents: `agents`, `agent-editor`, `workspace-file` | Local mock → Gateway Settings → Agents & Models → Claw → AGENTS.md. No edits or saves needed. |
| Transcript: `forwarded-messages` | Local mock → Claw → Main, scroll to the start. Include the automation label and Kiko's source-chat badge. |
| Search: `search` | macOS message search, query Kyoto. Highlighted results from Japan trip. |
| Logs: `gateway-logs` | macOS Gateway Settings → Gateway Logs. Populated severity-tagged fixture records. |

### Remaining capture gaps

- **iOS Search:** the fresh simulator build still renders some result text missing. Rejected; the guide now has the usable macOS example.
- **iOS Gateway Logs:** the list rendered blank and a scroll/navigation capture timed out. Rejected; the guide now has the usable macOS example. These are observed capture limitations, not claims that the feature is unavailable on iOS.
- **Nodes:** the attempted Mac view showed node names without useful detail. Keep the Devices illustration; capture the node detail view after its rendering is verified.
- **ClawHub results:** the attempted capture had an empty query and was rejected. The Skills and effective-tools examples illustrate this guide; a search/install walkthrough still needs its own capture.
- **OS integrations:** Share, Siri/Shortcuts, push notifications and the menu bar still need their own synthetic-data capture sessions. Do not substitute unrelated screens.

All published images are visually reviewed, unmodified native captures. Inline `focus` rectangles enlarge useful areas with CSS; the original links retain the entire capture. No screenshots with missing result text, blank logs, tips overlays or unrelated windows are published.

## Capture provenance — September 26, 2026

- The original fourteen macOS images were captured from commit `4488f7947df1b7cc9852234f5501dc518063b1a3`.
- The six additional macOS images (`approval-history`, `command-policy`, `gateway-health`, `pairing-requests`, `quick-capture`, `usage`) use installed Pincer **0.1.0 (13.1)**, copied into an isolated bundle. CleanShot captured the actual foreground demo window. The copy has its own bundle identifier, no App Group or shared Keychain group, and memory-only credentials. No dedicated capture app was built for these images.
- Images under `ios/` use the normal iOS app built from `c0be0c0`, copied to an isolated bundle identifier without shared groups, running on **iPhone 17 Pro / iOS 26.5 Simulator**. Native XCTest screenshots capture the real interface. The status bar is standardized to 9:41. Temporary navigation tests and generated projects are not shipped.
- At this earlier capture date, Search and Gateway Logs had no usable examples. The September 28 refresh above adds their macOS views and records the remaining iOS limitations.

The platform examples can show different scroll positions and themes. Platform-specific alt text and captions describe the actual view. Do not imply that a Mac-only capture verifies iOS behavior.

## Isolated capture app

From the repository root, run:

```sh
scripts/prepare-docs-capture.sh
# Open the absolute "Capture app prepared" path printed by the script.
```

The script builds an ad-hoc signed SwiftPM app in a fresh `build/docs-capture.*` directory and prints the resulting app path. Each run gets separate bundle, entitlement, icon and resource staging, so another app build or capture can run without replacing its files. The copy uses bundle identifier `chat.pincer.documentation` and has no App Group or shared Keychain group. Only this bundle's preferences get the display name Alex, Light appearance and All thinking steps. Its launch environment sets `PINCER_KEYCHAIN=memory`, `PINCER_CACHE_DIR=off`, `PINCER_DRAFTS_DIR=off`, and `PINCER_OUTBOX_DIR=off`.

Never add a real gateway to this bundle. Its profiles persist in its own defaults, but credentials do not survive quitting. For a fresh run, remove its synthetic gateway through **Organize → Edit Connection… → Remove Gateway…**, then choose **Try the Demo** on the welcome screen. Do not reset the installed Pincer app's preferences.

## Original macOS shot list

Files live in `src/assets/screenshots/`. Capture just the app window or sheet, not the desktop. Keep the default 1180 × 780-point main window; these PNGs are Retina captures. Preserve actual UI and use captions to explain the state. Check every screenshot for names, URLs, credentials, private sidebar previews, notification overlays and unrelated windows before adding it.

| File | Fixture and steps |
| --- | --- |
| `transcript.png` | Demo, Claw → Main. Expand Thinking, keep exec collapsed, scroll to top. Default theme. |
| `tool-details.png` | Same, expand exec df -h and scroll to top. |
| `agent-question.png` | Demo, Scout → Main. Dismiss the reasoning hint, send “Please ask me before choosing what to clean up.” Select the third option; capture before Submit. |
| `exec-approval.png` | Demo, Forge → Main. Send “Please approve the demo disk check.” Wait for the canned reply to finish, open the Allow menu. The command shown is simulated and is not executed. Deny after capture. |
| `slash-commands.png` | Demo, Claw → Main at top. Type `/`, without sending. Clear the draft after capture. |
| `command-palette.png` | Demo, ⌘K, type `jptr`; capture Japan trip as the match. |
| `appearance.png` | Settings → Appearance. Select Light and Lobster. |
| `context-meter.png` | Demo, Claw → Main, Lobster theme. Open the 86% ring without compacting. |
| `organize-chats.png` | Demo, Claw → Main, Lobster theme. Open Organize. |
| `connect-gateway.png` | Add Gateway, name Local Mock, loopback URL below, masked fixture token, Full Management. |
| `gateway-settings.png` | Local mock, Organize → Gateway Settings → Agents & Models. |
| `review-changes.png` | Local mock, set timeout to 900 and Save; change back to 600, then open 1 Unsaved. Capture the review; Save to restore the fixture. |
| `plugins.png` | Local mock, Gateway Settings → Plugins. Do not install anything. |
| `automations.png` | Local mock, Organize → Automations → Morning briefing. Capture schedule and task; no need to run the job. |

## Additional platform examples

| Screenshot | Capture state |
| --- | --- |
| `approval-history.png` | Demo, Gateway Settings → Approval History; leave all categories visible. |
| `command-policy.png` | Demo, Gateway Settings → Command Policy; default allowlist and approval rules. |
| `gateway-health.png` | Demo, degraded gateway banner. The iPhone view is scrolled to channels and connected clients. |
| `pairing-requests.png` | Demo, Gateway Settings → Pairing Requests; fictional Telegram and Discord records. Do not approve them. |
| `usage.png` | Demo, Usage & Cost, seven days of synthetic data. The iPhone view is scrolled to the daily cost chart. |
| `quick-capture.png` | macOS Go → Quick Capture; enter a fictional Kyoto trip draft without sending. |
| `ios/transcript.png`, `ios/tool-details.png` | Demo, Claw → Main; disk status response and chart. The iPhone tool example expands Thinking and leaves exec collapsed. |
| `ios/context-meter.png`, `ios/slash-commands.png` | Demo, Claw → Main; open the context ring or type `/` without sending. |
| `ios/gateway-settings.png`, `ios/plugins.png` | Local mock, Gateway Settings → Agents & Models or Plugins. No real gateway configuration is changed. |
| `ios/appearance.png` | Settings, Light mode and Default theme. |
| `ios/organize-chats.png` | Demo sidebar, open Organize. |
| `ios/exec-approval.png` | Demo, Forge → Main; seeded fictional git push approval. No command runs. |

To run the mock in a separate terminal:

```sh
cd mock-gateway
npm ci
HOST=127.0.0.1 PORT=19879 MOCK_PAIRING=off npm start
```

Connect the documentation app to `ws://127.0.0.1:19879` with the mock's public fixture token `dev-token` and Full Management. This pairing mode is only for this loopback mock. Stop the mock after capturing. The built-in demo does not implement configuration or automation management, so captions distinguish those mock screenshots.

## Publishing and checking

Use `DocScreenshot.astro` on documentation pages. It supplies responsive optimized images, descriptive alt text, a caption, and a link to the original PNG for readable details. Pass an `ios` image to add the macOS/iOS radio selector. Use `iosAlt` and `iosCaption` when the views differ. Selection synchronizes across figures and persists across pages; keyboard arrow keys work, and both images remain available without JavaScript. Images without an iOS counterpart remain visibly labeled macOS. Use `platformNote` for availability or capture limitations. Use `narrow` for portrait settings and connection sheets. The optional `focus` rectangle is measured in source-image pixels and crops only the inline CSS presentation, so small controls remain legible. The full-size link always preserves the complete, unmodified screenshot. Keep route names stable when converting Markdown to MDX.

The introduction and demo guide offer both platform views. The README and landing page use the refreshed `features/homepage.png` Mac overview with Pixel companion avatars. Change-review, automations, connection setup, and agent-question examples retain their original Mac capture until usable iOS counterparts are available. OS integrations (Share, Siri/Shortcuts, push notifications and the menu bar) still need dedicated captures; do not substitute unrelated app screens.

```sh
cd website
npm ci                       # Node 22.12 or newer
npm run build
npm run preview
```

Inspect the landing page and representative guides at desktop and narrow widths. Follow a screenshot link to verify the full-resolution original loads. Do not ship screenshots with loading placeholders, cropped question choices, or pending live-account actions.
