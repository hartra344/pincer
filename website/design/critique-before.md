⚠️ DEGRADED: single-context (reviewer runs as a sub-agent that may not spawn nested agents; Assessment A was written before detector output was read)

# Impeccable critique: before (issue #289)

Targets: landing `website/src/pages/index.astro` (**Persuade**) and docs chrome via `/guides/transcript/` (**Read**), dark and light, 1440px and 390px. Snapshot not persisted to `.impeccable/critique/` (the lead limited writes to `website/design/`); first run, no trend.

## Design Health Score

**Landing (Persuade)**

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Sticky nav, but no current-section state |
| 2 | Match System / Real World | 3 | Operator language and real commands; "Get started" is vague for a TestFlight/source install |
| 3 | User Control and Freedom | 3 | Plain links, nothing traps |
| 4 | Consistency and Standards | 2 | Three different primary CTAs (Get started, Connect your gateway, Install Pincer); landing and docs look like two sites |
| 5 | Error Prevention | 3 | "No gateway? Try the demo" heads off the main dead end; system requirements absent |
| 6 | Recognition Rather Than Recall | 3 | Features link to their guides |
| 7 | Flexibility and Efficiency | n/a | Persuade surface |
| 8 | Aesthetic and Minimalist Design | 2 | 10 equal-weight icon cards, glows, gradient text; nothing is ranked |
| 9 | Error Recovery | n/a | No error states on a static landing |
| 10 | Help and Documentation | n/a | Persuade surface |
| **Total** | | **19/28** | **Mid band: works, reads as a template** |

**Docs (Read)**: 1·4 (active sidebar + TOC), 2·3, 3·3, 4·3, 5·3, 6·2 (29 flat siblings under "Using Pincer"), 7·3 (⌘K search, prev/next), 8·3, 9·3 (Troubleshooting exists), 10·3 → **30/40**.

## Design Specificity Verdict

**LLM assessment (written first):** The landing is category-interchangeable. Swap "Pincer" and the screenshot and it is any AI dev tool's page: centered glow hero, gradient-text second line, pill eyebrow, card grid, card grid, three numbered steps, split security block, swatch row, glowing-logo final CTA. Nothing in the composition says *operator console for agents you run yourself*. The one product-specific asset, the real screenshot, is used once and faded out at the bottom. The iPhone half of "macOS & iOS" is never shown. The docs are stock Starlight with a coral tint: calm and readable, but anonymous, and they share neither type, surface nor header with the landing, so "Docs" feels like leaving the site.

**Deterministic scan:** CLI found 2 (`gradient-text`, `dark-glow`) in `index.astro`; the in-page detector found 23 on the landing (`icon-tile-stack` ×10, `dark-glow` ×6, `kicker-above-heading` ×4, `radial-spotlight-glow` ×2, `gradient-text` ×1, `low-contrast` ×3 on the CTA fill) and 17/20 on the transcript page (`line-length` ×16, `first-viewport-column-overflow` from the sidebar, light-mode `low-contrast` ×3 on the platform toggle). The detector agrees with the template verdict and adds two things the design pass underweighted: the CTA fill fails contrast, and docs lines run ~100 characters. False positives: 1.00:1 on `.grad` (transparent fill) and Starlight `sr-only` anchors.

**Visual overlays:** injected into a headless page only; no user-visible [Human] tab.

## Overall Impression

Honest content in a borrowed costume. The copy, commands and security story are right; the visual system is the default AI-landing kit and hides the product's best argument (you can *see* thinking, tools, runs and approvals) behind icon tiles. Biggest opportunity: let real screenshots and the real pairing flow carry the page, in a visual world only Pincer could own, shared with the docs.

## What's Working

- **Voice and truth.** Short, second-person, concrete ("It exposes no camera, screen, shell or `system.run`"). Real `openclaw devices approve` commands. No invented social proof.
- **Security section.** "A pure client. Nothing more." is the sharpest line on the page and the real differentiator for operators on locked-down machines.
- **Demo as the front door.** "No gateway? The built-in demo runs entirely on your device" sits right under the CTAs, exactly where the no-gateway visitor needs it.

## Priority Issues

- **[P1] The product never gets to show its work.** One Mac screenshot, masked away at the bottom, then 10 abstract icon cards describing what screenshots already in the repo (`features/run-tree.png`, `ios/exec-approval.png`, `ios/tool-details.png`, `features/file-diffs.png`…) could *show*. *Why:* principle 1 ("show the work") and the only proof we're allowed are screenshots. *Fix:* replace both card grids with a few large, captioned, real captures (thinking + tool cards, run tree, exec approval on iPhone) and short copy; pair Mac with iPhone in the hero. → `/impeccable shape`, `/impeccable layout`
- **[P1] Template visual language, no Pincer world.** Glow, gradient text, pill eyebrow, kickers, gradient icon tiles (detector: 23). *Why:* reads as generic, undermines "native first" craft credibility with a technical audience. *Fix:* commit to one authored direction (the surface brief's switchboard) and drop every glow/gradient-text/kicker/icon-tile. → `/impeccable shape`, `/impeccable quieter`
- **[P1] Landing and docs are two sites.** Landing: dark-only, custom nav, its own hexes. Docs: Starlight header, light/dark/auto, different type scale. *Why:* the main path is landing → docs → install; the jump costs trust and the theme choice is lost. *Fix:* shared tokens, shared header treatment and display type; landing honours light/dark and the docs' stored choice; docs get the same brand strip and footer (with the disclaimer, currently missing). → `/impeccable colorize`, `/impeccable typeset`
- **[P1] The primary action is unclear and fails contrast.** Hero "Get started" goes to Introduction; Install is only at the very bottom; white on the `#ff8a5b` gradient is 2.3–3.3:1. *Why:* success = Install, Try the Demo, or docs; the page never states requirements (macOS 15+, iOS 18+) or that install means TestFlight invite or source. *Fix:* hero primary "Install Pincer" (→ install guide) + secondary "Try the demo", requirements in the fine print, one accessible coral fill. → `/impeccable clarify`, `/impeccable colorize`
- **[P2] Docs navigation is a wall.** "Using Pincer" lists 29 siblings flat (detector flags the 954%-tall sidebar); body lines ~100 chars. *Why:* Read mode is comprehension; operators scanning for "approvals" or "logs" hunt through 29 items. *Fix:* regroup the sidebar config into ~5 labelled groups (Chats & transcript, Composer & capture, Approvals & notifications, Gateway admin, Personalize) without changing slugs/URLs; cap prose at ~70ch. → `/impeccable layout`, `/impeccable typeset`

## Persona Red Flags

- **Alex (power user, OpenClaw operator):** Wants "how do I install it, what does it need" in one glance. Hero primary goes to an Introduction page; Install is 6 sections down; no macOS/iOS version requirements; no TestFlight mention on the page. Scrolls past 10 cards of prose to reach the one code block.
- **Jordan (first-timer, no gateway yet):** "Try the demo" + fine print works. But "OpenClaw" is only a link inside a pill; nothing says in one line what a gateway is, so "Connected in three steps" starts at "Run a Gateway" with no pointer to how.
- **Sam (security-conscious operator on a managed work Mac)** *(project persona)*: The security block delivers, but it's the 4th section, below two feature grids; "open source, MIT" isn't said until the final CTA. Sam needs "pure client, no node, no shell" above the fold.
- **Riley (iPhone visitor)** *(project persona)*: Sees a Mac window shrunk to 360px, unreadable; no iPhone screenshot anywhere; Features/Security nav links are hidden with no menu.

## Cognitive Load

Landing: 2 checklist failures (chunking: grids of 4, 6 and 8 same-weight items; visual hierarchy: nothing ranked) → moderate. Docs: 2 failures (minimal choices / chunking: 29 sibling links) → moderate.

## Emotional Journey

Peak is the hero screenshot, then an emotional valley through two card grids; the security section recovers trust; the end ("Bring your agents home" + glowing logo) is generic. The reassurance moment for the high-stakes step (letting a new app onto your gateway) is buried.

## Minor Observations

- Theme swatches: Lobster's third chip equals the card background and vanishes; the swatches don't look like the app themes. `ios/appearance.png` shows the real thing.
- Hero screenshot `mask-image` fade cuts off the composer, the part that shows slash commands.
- `.fine` and card body text lean on `--muted` everywhere; hierarchy is set by size only.
- Docs captions show a literal `Kiko\u2019s` and a doubled "Local mock:" (`guides/transcript.mdx` L164); `agent\u2019s` in `guides/agents.mdx` L96. Content, not theme, but visible.
- Docs dark-mode active sidebar item uses the pale `accent-high` fill; heavy against the dark chrome.

## Questions to Consider

- What if the hero *was* the product: the Mac window and the iPhone, live-looking, with the pairing command next to them?
- What if "See the work" were three large real screenshots instead of four icons?
- Does the docs sidebar need 29 items at one level, or 5 groups the operator already thinks in?
- What would a confident, quiet version look like, one where coral means "needs you" and nothing else?

## Recommendations for the redesign (for the lead)

**Landing, Persuade:** hero = two-line headline, one-paragraph lede, primary **Install Pincer** (→ `getting-started/install/`), secondary **Try the demo**, fine print with macOS 15+ / iOS 18+ and "TestFlight beta or build from source"; Mac screenshot with the iPhone overlapping. Then show-the-work with real captures (thinking/tool cards, runs, exec approval), the three setup steps with the real commands, the pure-client security block (move it higher), themes shown through the app, closing CTA pair, footer with disclaimer. Light and dark. Coral only for primary action/active/attention.

**Docs, Read:** keep Starlight structure, URLs and content; restyle via tokens (shared with landing), a brand-consistent header, footer override with the disclaimer, ~70ch measure, grouped sidebar (config-only, slugs unchanged), accessible accent states in both themes.

**Must preserve:** all factual copy and the voice; the independence disclaimer (add it to docs too); real screenshots only, no invented stats/testimonials/App Store badges; CTAs to the Install guide (no fake TestFlight link); the demo as a first-class secondary CTA; the real pairing commands; the security claims exactly as worded; all docs slugs/URLs and `BASE_URL`-relative links; `DocScreenshot` macOS/iOS toggle behaviour; Starlight search, TOC, edit link, skip link; the logo/icon and the Lobster coral as the brand accent; lean performance (no heavy JS, `astro:assets` images).

## Questions for the lead

1. **Priority:** tackle (a) show-the-work composition with real screenshots, (b) shared landing+docs theme, or (c) CTA/contrast fixes first? All three are P1; I'd sequence b → a → c-in-passing.
2. **Docs sidebar regrouping:** (a) in scope (config-only, slugs unchanged), (b) follow-up issue, or (c) leave as is?
3. **Scope:** (a) all P1+P2, (b) P1 only with P2/P3 as follow-up issues, (c) everything.
