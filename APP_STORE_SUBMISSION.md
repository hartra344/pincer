# Pincer App Store submission material

Status: description/keywords prepared locally; demo review notes and no-sign-in settings saved for both apps. Free price schedules saved for both apps. Not submitted. Keep review contact details in App Store
Connect, not in this repository.

## Confirmed launch decisions

- Both apps are completely free; no Pincer subscriptions or in-app purchases.
- Version: 1.0, matching the current App Store version records.
- Review sign-in required: **No**. Leave username and password empty.
- Review access: built-in demo. No developer-provided backend or reviewer gateway.
- Privacy URL after deployment: https://www.pincerchat.dev/privacy/
- Support URL after deployment: https://www.pincerchat.dev/support/
- Territories, review contact and release timing: still needed.

## Description

Pincer is a free, native OpenClaw client for Mac, iPhone and iPad. Keep your agents
and conversations organized, follow replies as they stream, inspect tool calls,
and review requests for your approval.

No developer-hosted backend. Your conversations do not pass through the Pincer
developer. Connect directly to an OpenClaw Gateway you control, with the AI models
and services you choose.

Try the built-in demo immediately—no account, credentials or gateway required.
Explore realistic sample conversations, agents, attachments and approval flows
before connecting your own gateway.

Features include organized conversations, search and bookmarks, file attachments,
rendered code and tool results, configurable notifications, dictation, Read Aloud,
and Shortcuts integration. Availability of live gateway features depends on your
gateway version, configuration and permissions.

Pincer is completely free, with no subscriptions or in-app purchases. For live
use, bring your own OpenClaw Gateway. Third-party hosting and AI providers may
charge separately under their own terms. Pincer supports Apple devices only.

## Keywords

OpenClaw,AI,agents,chat,gateway,assistant,tools,automation,native,privacy

## Review notes — both platforms

No sign-in, account or credentials are required for review. Pincer has no
developer-provided backend. Use its built-in on-device demo:

1. Launch the app and choose **Try the Demo** on the first welcome screen.
2. Open **Claw → Main** and send a message to see the simulated streaming reply.
3. Open the seeded conversations to inspect rendered messages, tools and images;
   try search, bookmarks and switching among the sample agents.
4. Open the seeded approval request from Forge and approve or deny it to observe
   the simulated outcome. These actions do not execute real commands.
5. Open Settings to inspect appearance, notifications, dictation, Read Aloud,
   privacy and support. Optional OS permissions can be declined.

The demo is embedded in the binary and processes demo chat locally. It uses
synthetic data and simulated responses. It does not require a network gateway,
Tailscale, an AI subscription or pairing credentials. Some platform integrations,
including remote push delivery, require the user's own live gateway and optional
relay and are not represented as live services in the demo.

For regular live operation, users configure an OpenClaw Gateway that they own or
have access to. Pincer connects as an operator client. It never runs a gateway or
registers as a node and does not expose local camera, screen or shell execution.
Remote management controls operate on that user-selected gateway. No additional
executable app code is downloaded to enable them.

Microphone and speech permissions support optional dictation. Photo/file access
supports chosen attachments. Location sharing is optional. Background audio is
for Read Aloud; background refresh and remote notifications refresh gateway state.
The Mac app is sandboxed with outgoing network and user-selected file access.

## Still needed before copying to App Store Connect

- Verify these steps against the final TestFlight builds on iPhone, iPad and Mac.
- Deploy and verify the privacy/support URLs before entering them in the listings.
- Add final screenshots, copyright, category, age-rating and content-rights answers.
- Free pricing is saved. Choose territories and resolve automatic versus manual release.
- Add private reviewer contact name, email and phone in App Store Connect.
- Attach the matching processed version 1.0 builds; do not submit version 0.1.0.
