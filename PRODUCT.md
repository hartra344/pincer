# Product

<!-- impeccable:product-schema 1 -->

> Captured by `/impeccable init` for issue #289. The interview was answered from the maintainer's written brief (issue #289 and the coordinator kickoff) rather than a live Q&A; facts marked *(inferred)* come from the repository and should be confirmed.

## Platform

adaptive

The product is a native SwiftUI app for macOS and iOS. The marketing and docs site in `website/` (Astro + Starlight) is `web`.

## Users

People who already run an [OpenClaw](https://github.com/openclaw/openclaw) Gateway (self-hosted AI agents on their own machine, LAN or tailnet) and want a great native Mac and iPhone client for it. They are technical, comfortable with a terminal and `openclaw` CLI commands, and often live in their agent chats all day. The job: talk to their agents, see what those agents are doing (thinking, tool calls, runs, approvals) and manage the gateway without dropping into a web UI or a Discord bridge.

Secondary: contributors building Pincer from source *(inferred from the Development docs)*.

## Product Purpose

Pincer keeps what works about chatting with agents in a messaging app (organized channels, notifications, replies) and adds what a plain chat window can't show: live thinking, tool-call cards, subagent runs, inline images, exec approvals, and messages clearly attributed to their owner. It also manages the gateway itself (settings, agents, devices, skills, health, logs, usage).

Success on the website: an OpenClaw operator understands in one screen that Pincer is the native client for their gateway, trusts its security model, and goes to Install (TestFlight or build from source), Try the Demo, or the docs.

## Positioning

A pure **operator client**, native on both Mac and iPhone. It never bundles, launches or embeds a Gateway and never registers as a node, so it exposes no camera, screen, shell or `system.run` capability. That makes it usable on machines where the official OpenClaw app isn't allowed. Native table-view transcripts with a background cache, not a web view.

## Operating Context

- Operators connect to a gateway on the same Mac, the LAN, or at home over Tailscale, then approve the device with `openclaw devices approve <requestId>`.
- A built-in demo (**Try the Demo**, ⌘D on macOS) runs entirely on-device with a simulated gateway and a fictional user, Alex.
- Distribution is TestFlight beta (invite link, no public App Store listing) or building from source with Xcode. There is no public TestFlight URL on the site; CTAs go to the Install guide.
- Docs live only on the website (`website/src/content/docs`); the README links to them.

## Capabilities and Constraints

- macOS 15+ and iOS 18+.
- Chats organized by server/#channel, automations and agents; transcript with thinking, tool cards, replies, reactions, images; composer with slash commands; Quick Capture; menu bar; Shortcuts/Siri; approvals and push notifications; Gateway Settings, agents, devices, skills and tools, health, channels, logs, command policy, usage and cost; eight app themes (Default, Lobster, Ocean, Forest, Grape, Sunset, Graphite, Midnight) in light and dark.
- Security: per-device Ed25519 identity in the Keychain, `wss://` required off LAN/tailnet with optional TLS pinning, scoped operator access, sandboxed macOS app with complete file protection.
- Open source under the MIT license. Independent client, not affiliated with the OpenClaw project.
- Website: Astro 7 + Starlight 0.42, hosted on Vercel at the domain root; docs URLs and content are owned by the docs, not the marketing surface.

## Brand Commitments

- Name: **Pincer**. App icon: the white speech-bubble glyph with a claw-shaped notch on a coral-to-red gradient (`website/src/assets/logo.svg`, `#FF8A5B` → `#D9283B`). The "Lobster" palette (`#E8543D` coral) is the house accent *(inferred from the existing site and the app theme)*.
- Voice: plain, direct, second person, short sentences, no hype; concrete about what the app does and doesn't do. Uses "gateway", "agent", "operator", "node", "channel" in OpenClaw's sense.
- Always state the independence disclaimer in the footer.

## Evidence on Hand

- Real app screenshots captured from the demo: `website/src/assets/screenshots/` (macOS), `…/ios/` (iPhone), `…/features/` and `…/features/ios/`, `…/first-run/`. The hero shot is `features/homepage.png`.
- No testimonials, user counts, press, ratings, benchmarks or pricing exist. Do not invent them.
- No App Store listing or public TestFlight link exists.

## Product Principles

1. Show the work, not just the answer: thinking, tools and runs are first-class.
2. Native first: feel like a Mac and iPhone app, never a wrapped web page.
3. A pure client: security and scope are a feature, stated plainly.
4. Honest and concrete: real screenshots and real commands, no invented claims.
5. The demo is the front door for people without a gateway yet.

## Accessibility & Inclusion

WCAG 2.2 AA for the website: text contrast, visible focus states, reduced-motion support, keyboard navigation. The app itself has an accessibility guide (`guides/accessibility`).
