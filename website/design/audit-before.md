# Impeccable audit: before (issue #289)

Target: `website/src/pages/index.astro` (landing) and the Starlight docs chrome via `/guides/transcript/` (`website/src/styles/docs.css`, `website/src/components/DocScreenshot.astro`). Built from `82296cd` (pre-redesign HEAD) and served statically; inspected in Chromium headless at 1440×900 and 390×844, `prefers-color-scheme` dark and light.

Detector evidence:
- CLI `impeccable detect --json website/src/pages/index.astro`: exit 2, **2 findings**: `gradient-text` (L465, `.grad`) and `dark-glow` (L452, `.dot` box-shadow).
- CLI on `website/src/components` + `guides/transcript.mdx`: exit 0, clean.
- In-page `detect.js` (live-server, injected): landing **23** findings: `icon-tile-stack` ×10 (every feature card), `dark-glow` ×6 (buttons, icon tiles, final logo), `kicker-above-heading` ×4, `radial-spotlight-glow` ×2 (`.glow`, `.final`), `gradient-text` ×1, `low-contrast` ×3 (white on `#ff8a5b`, the primary CTA gradient's top stop). Transcript page **17** dark / **20** light: `line-length` ×16 (~89–106 chars per line), `first-viewport-column-overflow` ×1 (the 954%-tall sidebar), and in light mode `low-contrast` ×3 (`#c9412b` on `#ffe1d9`, 4.0:1).
- False positives: the 1.00:1 "contrast" on `.grad` (transparent fill under `background-clip:text`; real problem is the effect itself) and Starlight's `sr-only` heading anchors.

## Audit Health Score

| # | Dimension | Score | Key Finding |
|---|-----------|-------|-------------|
| 1 | Accessibility | 2 | Primary CTA text fails AA (white on `#ff8a5b`→`#d9283b`, 2.3:1 at the top stop); light-mode selected platform tab 4.0:1; no `prefers-reduced-motion` anywhere |
| 2 | Performance | 3 | Lean (one hero webp ≤88 KB, lazy docs images, near-zero JS); a 900px blurred gradient layer and a backdrop-filter nav are the only costs |
| 3 | Responsive Design | 3 | No overflow at 390px, but mobile nav drops Features/Security with no menu, and the hero is a desktop screenshot shrunk to ~360px (illegible) |
| 4 | Theming | 2 | Landing is dark-only with its own hard-coded palette; ignores the docs' light/dark/auto choice; tokens duplicated between `index.astro` and `docs.css` |
| 5 | Implementation Integrity | 1 | Landing is the generic SaaS template (glow hero, gradient text, icon-tile grids, kickers); detector finds 23 instances |
| **Total** | | **11/20** | **Acceptable (significant work needed)** |

## Implementation Integrity Verdict

**Fail for the landing, pass for the docs.** The landing could ship for any dev tool with the name swapped: centered radial glow hero, gradient-text headline, pill eyebrow with glowing dot, two same-weight card grids with gradient icon tiles (10 of them), uppercase kickers above every H2, numbered step cards, a glowing logo "final CTA". Its palette is a second, hard-coded copy of the Lobster tokens (`#f0654e`, `#ff8a5b`, `#d9283b` appear in both `index.astro` and `docs.css`) with no shared source. The docs are stock Starlight with a competent palette override: coherent but anonymous, and visually a different site from the landing.

## Executive Summary

- Score **11/20** (Acceptable). Issues: **P0 0 · P1 5 · P2 6 · P3 3**.
- Top issues: primary CTA contrast; landing is dark-only and disconnected from the docs theme; template anti-patterns; no reduced-motion handling; docs pages miss the independence disclaimer.
- Next: rebuild the landing on shared tokens with light and dark, fix contrast on the coral fills, add reduced-motion, carry the disclaimer and brand into the Starlight footer.

## Detailed Findings

### P1

- **[P1] Primary CTA text contrast fails AA.** `index.astro` `.btn.primary` (L~500): white 16px/600 on `linear-gradient(#ff8a5b, #d9283b)`; 2.3:1 at the top, ~3.3:1 mid. Same fill on the 44px icon tiles. *A11y · WCAG 1.4.3.* Fix: solid coral no lighter than `#c9412b` under white text (≥4.5:1), or dark text on light coral. → `/impeccable colorize`
- **[P1] Light-mode selected state fails AA in docs.** `DocScreenshot.astro` L85: `input:checked + span` uses `--sl-color-text-accent` (`#c9412b`) on `--sl-color-accent-low` (`#ffe1d9`) = 4.0:1; appears on every screenshot toggle. *A11y · 1.4.3.* Fix: darken text to `--sl-color-accent-high` or lighten the fill. → `/impeccable polish`
- **[P1] Landing ignores light mode and the docs theme choice.** `:root { color-scheme: dark }` with fixed hexes; a visitor who picked Light in the docs lands on a dark page and back. *Theming.* Fix: one token file (the new `src/styles/tokens.css`) consumed by both the landing and `docs.css`, with `[data-theme]` + `prefers-color-scheme` support and the same `starlight-theme` storage key. → `/impeccable colorize`, `/impeccable document`
- **[P1] Independence disclaimer missing on every docs page.** Starlight footer shows only Edit page and pagination. PRODUCT.md: "Always state the independence disclaimer in the footer." *Integrity/brand.* Fix: override Starlight `Footer` to add the disclaimer (and MIT + GitHub). → `/impeccable harden`
- **[P1] Template anti-patterns across the landing** (detector: 23). `.glow`, `.grad`, `.dot`, `.icon` tiles, `.kicker`, `.final`. *Integrity.* Fix is the redesign itself, not polish. → `/impeccable shape` then build

### P2

- **[P2] No reduced-motion handling.** `html { scroll-behavior: smooth }`, `.btn:hover`/`.card.link:hover` translate; no `prefers-reduced-motion` in `website/src`. *A11y · 2.3.3.* Fix: gate smooth scroll and movement; keep color/state change. → `/impeccable animate`
- **[P2] Focus indicators are browser defaults on the landing.** 1px `auto` ring (`#99c8ff` on `#140e0c`), unstyled; no `:focus-visible` rules outside `DocScreenshot`. *A11y · 2.4.7/2.4.11.* Fix: a 2–3px accent ring with offset, tokenized for both themes. → `/impeccable polish`
- **[P2] Mobile nav hides Features and Security with no menu.** `@media (max-width:640px)` L~800. *Responsive.* Fix: keep an Install button plus a compact menu or anchor list. → `/impeccable adapt`
- **[P2] Hero screenshot illegible on phones and no iPhone evidence at all.** One 2360px Mac shot scaled to ~360px, masked to fade out its bottom 25%; 15+ iOS captures in `assets/screenshots/ios` and `features/ios` go unused. *Responsive.* Fix: art-direct: show the iPhone capture on narrow viewports. → `/impeccable adapt`
- **[P2] Docs measure is too long.** 89–106 chars per line on `/guides/transcript/` at 1440px (detector ×16). *Read.* Fix: cap `.sl-markdown-content` prose at ~68–72ch while letting screenshots/tables go wider. → `/impeccable typeset`
- **[P2] Disclaimer text at 4.48:1.** `.disclaimer` 12.8px with `opacity:.7` on the muted color. *A11y · 1.4.3* (just under). Fix: drop the opacity. → `/impeccable polish`

### P3

- **[P3] Small hit areas.** Landing nav links 24px tall, GitHub icon 20×20, footer links 22px; pass 2.5.8 only via spacing. → `/impeccable adapt`
- **[P3] Theme swatches misrepresent the themes.** Lobster's third chip `#1E1614` equals the card background `--bg-2` and disappears; Graphite/Midnight darks nearly do. → part of the redesign
- **[P3] Content bug visible in docs captions** (not theme scope, flag to lead): literal `Kiko\u2019s` and a doubled "Local mock:" in `guides/transcript.mdx` L164; `agent\u2019s` in `guides/agents.mdx` L96. → `/impeccable clarify`

## Patterns & Systemic Issues

- Coral gradient under white text is the house fill (buttons, icon tiles) and fails contrast everywhere it's used.
- Two parallel style systems (landing inline `<style>`, Starlight `docs.css`) with duplicated hexes and no shared tokens, typography or focus style.
- Decoration via glow: 6 glow shadows and 2 radial spotlights; color is used as atmosphere, not state.

## Positive Findings

- Real, honest content: real pairing commands, real demo screenshot, a plain security section, correct independence disclaimer on the landing footer. Keep all of it.
- Semantics are clean: one H1, logical H2/H3, landmarks, descriptive alt text, `aria-label` on the icon-only GitHub link; Starlight gives skip link, ⌘K search, TOC with active state, and prev/next.
- Performance is good: `astro:assets` responsive webp, lazy docs images, almost no JS.
- `DocScreenshot` is a well-built progressive enhancement (radio group, persisted macOS/iOS choice, full-size links with labels).
- Docs palette in dark mode passes AA (`#a8938c` on `#1b1311` ≈ 6.3:1; body gray-2 higher).

## Recommended Actions

1. **[P1] `/impeccable shape`**: replace the template landing (glow hero, icon-tile grids, kickers) with a product-specific composition; surface brief already commits to the switchboard direction.
2. **[P1] `/impeccable colorize`**: shared tokens for landing + Starlight, light and dark, coral fills that pass 4.5:1 under text; color only for state/primary action.
3. **[P1] `/impeccable harden`**: Starlight `Footer` override carrying the disclaimer; theme choice shared between landing and docs.
4. **[P2] `/impeccable adapt`**: mobile nav, iPhone art direction for the hero, 24px+ hit areas.
5. **[P2] `/impeccable typeset`**: docs measure ~70ch, display/body scale shared across both surfaces.
6. **[P2] `/impeccable animate`**: reduced-motion alternatives for any lamp/rise motion.
7. **[P3] `/impeccable polish`**: focus rings, disclaimer opacity, DocScreenshot selected-state contrast, final pass.

You can ask me to run these one at a time, all at once, or in any order you prefer.

Re-run `/impeccable audit` after fixes to see your score improve.
