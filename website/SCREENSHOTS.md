# Documentation screenshots

These are real app captures, not mockups. All chat content, model names, paths, usage figures, jobs and configuration are fixtures. Alex is a fictional display name. Screenshots illustrate the interface; they do not establish real-gateway compatibility.

## Capture provenance — September 26, 2026

- The original fourteen macOS images were captured from commit `4488f7947df1b7cc9852234f5501dc518063b1a3`.
- The six additional macOS images (`approval-history`, `command-policy`, `gateway-health`, `pairing-requests`, `quick-capture`, `usage`) use installed Pincer **0.1.0 (13.1)**, copied into an isolated bundle. CleanShot captured the actual foreground demo window. The copy has its own bundle identifier, no App Group or shared Keychain group, and memory-only credentials. No dedicated capture app was built for these images.
- Images under `ios/` use the normal iOS app built from `c0be0c0`, copied to an isolated bundle identifier without shared groups, running on **iPhone 17 Pro / iOS 26.5 Simulator**. Native XCTest screenshots capture the real interface. The status bar is standardized to 9:41. Temporary navigation tests and generated projects are not shipped.
- The installed version supplied the Mac captures; it does not include the newest Search and Gateway Logs screens. Simulator attempts for those screens rendered missing text and were rejected. Those two guides still need screenshots after that rendering problem is resolved.

The platform examples can show different scroll positions and themes. Platform-specific alt text and captions describe the actual view. Do not imply that a Mac-only capture verifies iOS behavior.

## Isolated capture app

From the repository root, run:

```sh
scripts/prepare-docs-capture.sh
open 'build/Pincer Documentation.app'
```

The script builds an ad-hoc signed SwiftPM app and copies it to a separate bundle with identifier `chat.pincer.documentation`. It has no App Group or shared Keychain group. Only this bundle's preferences get the display name Alex, Light appearance and All thinking steps. Its launch environment sets `PINCER_KEYCHAIN=memory`, `PINCER_CACHE_DIR=off`, and `PINCER_DRAFTS_DIR=off`.

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

The introduction and demo guide offer both platform views. The README and landing page retain the Mac overview. Change-review, automations, connection setup, and agent-question examples retain their original Mac capture until usable iOS counterparts are available. OS integrations (Share, Siri/Shortcuts, push notifications and the menu bar) still need dedicated captures; do not substitute unrelated app screens.

```sh
cd website
npm ci                       # Node 22.12 or newer
npm run build
npm run preview
```

Inspect the landing page and representative guides at desktop and narrow widths. Follow a screenshot link to verify the full-resolution original loads. Do not ship screenshots with loading placeholders, cropped question choices, or pending live-account actions.
