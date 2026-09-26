# Documentation screenshots

These are real macOS app captures, not mockups. Captured September 26, 2026 from commit `4488f7947df1b7cc9852234f5501dc518063b1a3`. The capture branch changes documentation and tooling, not the application UI. All chat content, model names, paths, usage figures, jobs and configuration are fixtures. Alex is a fictional display name. These captures do not establish real-gateway compatibility or iOS behavior.

## Isolated capture app

From the repository root, run:

```sh
scripts/prepare-docs-capture.sh
open 'build/Pincer Documentation.app'
```

The script builds an ad-hoc signed SwiftPM app and copies it to a separate bundle with identifier `chat.pincer.documentation`. It has no App Group or shared Keychain group. Only this bundle's preferences get the display name Alex, Light appearance and All thinking steps. Its launch environment sets `PINCER_KEYCHAIN=memory`, `PINCER_CACHE_DIR=off`, and `PINCER_DRAFTS_DIR=off`.

Never add a real gateway to this bundle. Its profiles persist in its own defaults, but credentials do not survive quitting. For a fresh run, remove its synthetic gateway through **Organize → Edit Connection… → Remove Gateway…**, then choose **Try the Demo** on the welcome screen. Do not reset the installed Pincer app's preferences.

## Shot list

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

To run the mock in a separate terminal:

```sh
cd mock-gateway
npm ci
HOST=127.0.0.1 PORT=19879 MOCK_PAIRING=off npm start
```

Connect the documentation app to `ws://127.0.0.1:19879` with the mock's public fixture token `dev-token` and Full Management. This pairing mode is only for this loopback mock. Stop the mock after capturing. The built-in demo does not implement configuration or automation management, so captions distinguish those mock screenshots.

## Publishing and checking

Use `DocScreenshot.astro` on documentation pages. It supplies responsive optimized images, descriptive alt text, a caption, and a link to the original PNG for readable details. Use `narrow` for portrait settings and connection sheets. The optional `focus` rectangle is measured in source-image pixels and crops only the inline CSS presentation, so small controls remain legible. The full-size link always preserves the complete, unmodified screenshot. Keep route names stable when converting Markdown to MDX.

The README, introduction and landing page share the demo overview. The previous screenshot has been removed so it cannot accidentally be reused.

```sh
cd website
npm ci                       # Node 22.12 or newer
npm run build
npm run preview
```

Inspect the landing page and representative guides at desktop and narrow widths. Follow a screenshot link to verify the full-resolution original loads. Do not ship screenshots with loading placeholders, cropped question choices, or pending live-account actions.
