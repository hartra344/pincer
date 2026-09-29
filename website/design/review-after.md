# Round 2 verdict: SIGN-OFF

Reviewed HEAD 4af2675 on the dev server (:47321) and the production after-* shots, light and dark, at 1440 and 390.

- **B1 resolved.** Light `--pc-lamp-text` is now #a02e1c. The rendered colour on "Read the security model" is rgb(160,46,28): 5.32:1 on panel, 6.04:1 on bg. The `tokens.css` comment now covers both bg and panel.
- **New type reads well.** The system stack (SF Pro Display/Text on Apple, Segoe/system elsewhere) is sentence case, with no caps and no wide tracking, and no web font at all, so the font request is gone.
- **Hierarchy holds.** Computed sizes:

  | Page | h1 | h2 | h3 | Body |
  |---|---|---|---|---|
  | Landing 1440 | 72/700 | 52/700 | 18/700 | 17–19 |
  | Landing 390 | 40 | 32 | | |
  | Docs 1440 | 44/700 | 25.6/650 | 20/650 | 16/1.7 |
  | Docs 390 | 32 | | | |

  - Step numerals (brass, about 120px) still carry the "three steps" band.
  - The security switches read as clear labelled rows.
- **Other round-2 changes check out:**
  - Docs measure is now about 70ch, down from 90.
  - `theme-color` is set per scheme.
  - The line-index fade works, and the theme chips are ringed.
- **No horizontal overflow** at either width, in either theme.
- **Detector, landing URL:** 16 findings, identical to round 1 and all false positives or sanctioned.
  - low-contrast ×10: "analytic-gradient+alpha" in the security band, where the detector measures the dot pattern. Rendered text is legible and above 5:1.
  - dark-glow ×4: the lamps.
  - radial-spotlight-glow ×2: the dot field.
- **Stale contract:** `.impeccable/surfaces/website-src-pages-index-astro.md` L22 still specifies "condensed engraved grotesque (Big Shoulders) in caps". Update it to the system stack in sentence case, so future Impeccable runs don't reintroduce the old type. This is a doc-only change. Do it before merge or as a follow-up.
- **New nit (follow-up):** at 72px, SF Display plus -0.02em still looks tight in Chromium. The word gap in "agents, in a" is narrow. Try -0.01em, or 0 at ≥64px, since SF already tightens itself optically at display sizes.

**Scores**

| | Before | Round 1 | Round 2 |
|---|---|---|---|
| Audit | 11/20 | 17/20 | **18/20** (A11y 4, Perf 4, Responsive 4, Theming 3, Integrity 3) |
| Critique, landing | 19/28 | 25/28 | **26/28** |
| Critique, docs | 30/40 | 33/40 | **34/40** |

Theming stays at 3 until the landing toggle gets an Auto option; integrity stays at 3 until the sidebar is regrouped. Both are tracked in #311–#314.

---

## Round 1 finish review (history): #289 redesign

Reviewed committed HEAD (2d9110e landing, 5fb8bf7 docs theme, 139110a merge) against `.impeccable/surfaces/website-src-pages-index-astro.md`. Sources: the dev server at :47321, a production build of HEAD from a scratch copy, coder screenshots in `/tmp/pincer-289-coderA|B`, and the formal `after-*` shots.

An uncommitted `landing.css` change was in the worktree when this was written. It softens the display type: no uppercase, weight 700, smaller clamps. That change was not reviewed here, and it doesn't touch the blocker below.

## Scores

| | Before | After |
|---|---|---|
| Audit, total | 11/20 | **17/20** (18 once B1 is fixed) |
| — Accessibility | 2 | 3 (one link at 4.35:1) |
| — Performance | 3 | 4 |
| — Responsive | 3 | 4 |
| — Theming | 2 | 3 |
| — Anti-pattern integrity | 1 | 3 |
| Critique, landing | 19/28 | **25/28** |
| Critique, docs | 30/40 | **33/40** |

## Blockers

**B1. Light-mode "Read the security model" link fails AA (4.35:1).**
- **Where:** `.security-head .textlink` uses `--pc-lamp-text` #b33a25 on `--pc-panel` #d6dfda. The same token on `--pc-bg` gives 4.94:1 and passes.
- **Scope:** the `tokens.css` comment "lamp-text/bg ≥4.9" only covers bg, and the security band sits on panel.
- **Fix, in `website/src/styles/tokens.css` (light block):** darken `--pc-lamp-text` to `#a02e1c`. That gives 5.32:1 on panel and 6.04:1 on bg, and still reads as the lamp.
  - Alternative: add a `--pc-lamp-text-on-panel: #a02e1c` token and use it in `landing.css` for `.security .textlink`.
  - Either way, update the contrast comment. Check any other lamp-text-on-panel uses, such as the docs aside links on panel-tinted asides.

That is the only blocker.

## Verified

- **Contrast:**
  - Dark: landing and docs are clean. Lamp-text on panel is 6.36:1, muted on panel 7.1:1, lamp-ink on lamp 6.14:1.
  - Light: docs are clean. On the landing, only B1 fails.
  - The DocScreenshot toggle, which was 4.0:1 before, now passes.
- **Focus:**
  - Every tab stop has a visible ring. Landing uses a 2px lamp-text ring, docs a 3px lamp ring.
  - Landing order: skip link → header → OpenClaw → CTAs → the 7 line-index links → guide links.
  - Docs: search, Install, GitHub, theme select, sidebar and TOC all show the ring.
- **Reduced motion:** smooth scroll, the hero rise animation and lamp transitions are all disabled.
- **Overflow:** none at 390 or 1440, landing or transcript, light or dark.
- **Themes:**
  - The landing now has light and dark, sharing `starlight-theme` with the docs, and the choice persists both ways.
  - `theme-color` is set per scheme on the landing.
- **Disclaimer:** present in the landing footer and the docs footer (`starlight/Footer.astro`).
- **Line index:** lights the section in view, and sits sticky under the header (56–116px).
- **Page weight (prod build, landing):**

  | Viewport | HTML | CSS | JS | Font | Images (initial / full scroll) | Requests |
  |---|---|---|---|---|---|---|
  | 1440@2x | 25KB | 12KB | 2.5KB | 36KB | 429KB / 562KB | 21 |
  | 390@3x | | | | | 271KB / 461KB | |

  Docs transcript: JS 99KB (Starlight + pagefind). Lean.

## Detector (URL scans)

**Landing, 16 findings. All are false positives or sanctioned.**
- radial-spotlight-glow ×2 on `.field` and `.security`: this is the 1.5px dot "jack field" pattern, not a glow.
- dark-glow ×4: the lamp glows the contract sanctions.
- low-contrast ×10 in the security band: the detector measured against the dot background-image. Real text there is about 13:1.
- The source scan of `index.astro` and the components returns 0 findings. Before, it caught gradient text, icon tiles and kickers.

**Transcript, 32 at 1280 and 34 at 390.**
- border-accent-on-rounded ×19–21: the kbd keycaps. The 2px bottom border is a deliberate keycap metaphor.
- line-length ×6, down from 16.
- first-viewport-column-overflow: the 29-item sidebar.
- dark-glow ×3: Install button and the DocScreenshot lamp.
- layout-transition ×1.
- text-occlusion ×11 at 390: the collapsed Starlight mobile TOC. It is a false positive; the visuals are fine.

## Nits → follow-up issues

1. **Docs sidebar:** "Using Pincer" is still 29 flat items. Regroup into Chat, Composer, Approvals and notifications, Gateway admin, and Platform (`astro.config.mjs`).
2. **Docs measure:** `--sl-content-width: 46rem` at 17px is about 90 characters. Aim for 40rem (about 70ch) in `docs.css`.
3. **Starlight `theme-color`:** it is still `#E8543D` in `astro.config.mjs`. Use the per-scheme bg values the landing uses.
4. **Landing theme toggle:** it only offers light and dark. The docs offer Auto. Add Auto, or a way to return to system.
5. **Theme chips:** the Lobster third colour #1E1614 is 1.21:1 against the dark panel, so it's invisible. Add a 1px `--pc-line-strong` ring to the swatch dots (`index.astro` chips, `appearance.mdx` plates).
6. **Docs Install button glow** (dark-glow): consider dropping it outside the header, or keep it as a sanctioned lamp.
7. **layout-transition:** a width/height transition on docs. Find it and switch to transform/opacity.
8. **Escaped apostrophes:** literal `\u2019` in captions at `guides/transcript.mdx` L164 and `guides/agents.mdx` L96. Carried over from before.
9. **Mobile:** the 390 hero fold shows no product. The Mac shot starts just below the fold. Consider a peek of the iPhone shot above the fold, or a shorter lede.
10. **Line index:** at 390 it is a horizontal scroller. Add an edge fade or a "more" affordance so users know it scrolls.

## Must preserve

- Real product screenshots, with Mac and iPhone pairs on each line.
- The independence disclaimer on the landing and on every docs page.
- One theme token set shared by the landing and the docs, with persistence.
- Lamps reserved for primary, active and attention states.
- Reduced-motion handling.
- Lean JS on the landing (about 2.5KB).
