---
version: 2
slug: "website-src-pages-index-astro"
primary_target: "website/src/pages/index.astro"
related_targets: ["website/src/styles/docs.css", "website/src/styles/tokens.css", "website/src/components/landing/landing.css"]
---

# Surface brief: Pincer landing page and site theme

Scope: `website/src/pages/index.astro` (Persuade) and the Starlight theme for docs pages (Read). Docs content and URLs are out of scope.

Audience and action: an OpenClaw gateway operator decides Pincer is the native Mac and iPhone client for their gateway, then goes to Install (TestFlight or source), Try the Demo, or the docs. Proof: real demo screenshots on Mac and iPhone, the real pairing commands, the pure-client security model. No invented claims, counts or testimonials.

Constraints: Starlight overrides only; no heavy JS; light and dark; WCAG AA contrast and visible focus; reduced motion and reduced transparency honoured.

Decisions taken unattended (the owner delegated all decisions): redesign of the visual world into native Apple platform grammar; concept seed 66dbd038 index 4 (classic Mac OS Platinum) rejected on factual grounds. Hero headline changed at the owner's request to "OpenClaw, with truly native capabilities and feel."

## Direction contract

THESIS: The site behaves like a Mac app, because the product's claim is "truly native capabilities and feel". It refuses the dark-glow devtool hero and the icon-card grid, and drops the switchboard metaphor that had no native meaning.

OWN-WORLD: Apple system neutrals (light: white + #F5F5F7 grouped ground; dark: #141416 + #1C1C1E/#2C2C2E), SF system type at Apple text-style sizes, Pincer coral as the single system tint (controlAccentColor role), and the app icon's own coral→red gradient (#FF8A5B→#D9283B) as the one drenched brand field. Native components: translucent unified toolbar header, push buttons (filled default button), segmented control (theme, line index), grouped inset lists (security facts), source-list sidebar with a tinted selection pill (docs), keycaps, Terminal-style command block.

STORY: An OpenClaw operator sees Pincer living as a real Mac/iPhone app, understands what it adds over the browser Control UI, trusts the pure-client model, and installs or tries the demo.

FIRST VIEWPORT: Toolbar header (icon + Pincer, Features, Security, Docs, GitHub, theme segmented control, filled Install). Left 5/12: headline at display scale, lede, filled "Install Pincer", bordered "Try the demo", "Why not just use the Control UI?" link, fine print. Right 7/12: a large continuous-corner tile drenched in the app-icon gradient, holding the real macOS homepage screenshot with the iPhone overlapping its corner. A sticky segmented control (System / Approvals / Gateways / Offline / Chat) begins at the fold; its thumb slides to the section in view.

FORM: native macOS/iOS interface language (brief-pinned; concept-seed key 66dbd038 rolled index 4 = classic Mac OS Platinum, rejected on factual grounds: it misstates the era of a macOS 15/iOS 18 client and has no iPhone analogue). Signature: the scroll-tracking segmented control + live keycaps (⌘K, ⌃⇧Space light when pressed). Motion: segmented thumb slide + one hero rise; reduced motion off.

Docs (Read): same tokens, restrained; 17px body, ~70ch, source-list sidebar, Apple semantic colours for asides (note blue, tip green, caution orange, danger red); coral reserved for links, selection and actions.
