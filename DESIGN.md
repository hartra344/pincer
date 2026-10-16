---
name: Pincer Website
description: The site behaves like a native Mac app. Apple system neutrals, SF type, Pincer coral as the system tint, and the app icon's gradient as the one brand field.
colors:
  bg-dark: "#161618"
  grouped-dark: "#1c1c1e"
  panel-dark: "#232325"
  raised-dark: "#2c2c2e"
  text-dark: "#f5f5f7"
  muted-dark: "#a1a1a6"
  tint-text-dark: "#ff8a70"
  bg-light: "#ffffff"
  grouped-light: "#f5f5f7"
  panel-light: "#ffffff"
  raised-light: "#e8e8ed"
  text-light: "#1d1d1f"
  muted-light: "#636366"
  tint-text-light: "#c0311b"
  tint: "#d6391f"
  tint-ink: "#ffffff"
  brand-gradient: "linear-gradient(160deg, #ff8a5b, #d9283b)"
typography:
  family: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', system-ui, sans-serif"
  display: "clamp(2.5rem, 4.6vw, 4.25rem) / 700 / -0.02em"
  headline: "clamp(2rem, 3.6vw, 3rem) / 700"
  body-landing: "1.125rem"
  body-docs: "1.0625rem, ~70ch measure"
radius:
  s: "0.4375rem"
  m: "0.625rem"
  l: "1.375rem"
---

# Design System: Pincer Website

## Overview

Pincer is a native Mac and iPhone client, so the site speaks native Apple interface language instead of a web-app or devtool look. Tokens live in `website/src/styles/tokens.css` and are shared by the landing page (`website/src/components/landing/landing.css`, Persuade) and the Starlight docs theme (`website/src/styles/docs.css`, Read).

Dark is the default (matching Starlight); light is a full peer. Theme is stored in `localStorage['starlight-theme']` and applied as `:root[data-theme]`.

## Colors

- **Neutrals:** Apple system backgrounds. `--pc-bg` is the page, `--pc-grouped` the grouped ground (sidebar, media stages, footer), `--pc-panel` and `--pc-raised` for controls.
- **Tint:** Pincer coral is the one accent, in the `controlAccentColor` role. `--pc-tint` (#d6391f) is a fill with white ink (4.7:1). `--pc-tint-text` is the text-on-ground variant (#c0311b light, #ff8a70 dark). Coral means action, selection or link, and nothing else.
- **Brand gradient:** `--pc-brand`, the app icon's gradient. Used only as the hero tile and icon glyph squircles. Never put text on it (fails contrast).
- **Docs asides:** Apple semantic colours: note blue, tip green, caution orange, danger red.

## Typography

The Apple system stack everywhere, sentence case. No condensed or all-caps display type (the owner rejected it as hard to read). Headlines are bold with slight negative tracking; body copy on the landing page is muted at 1.125rem; docs body is 17px at about 70ch.

## Layout

- Landing: a 12-column feel with 5/12 copy and 7/12 media. Flipped sections mirror to 7/12 media and 5/12 copy, so every feature's media is the same size. Sections are padded 4.5–5rem.
- Breakpoints: 1099, 899 (single column), 719, 479px.
- Docs: Starlight's three-pane layout; the sidebar sits on the grouped ground.

## Elevation & Depth

Hairlines (0.5px `--pc-line`/`--pc-line-strong`) do most of the separating. Shadows are reserved for windows (`--pc-shadow-window`) and lifted controls (`--pc-shadow`). Toolbars and the docs header are translucent with backdrop blur; `prefers-reduced-transparency` makes them opaque.

## Shapes

Continuous-feeling rounded rectangles: `--radius-s` for controls and keycaps, `--radius-m` for cards and code, `--radius-l` for tiles and stages.

## Components

- **Toolbar header:** translucent bar with the icon and name, text links, GitHub, a theme pop-up button (`.popup` wrapping `#theme-select`) and a filled Install button.
- **Push buttons:** `.btn` (bordered fill) and `.btn.filled` (tint fill, white ink).
- **Hero tile:** the brand gradient holding the real macOS screenshot with the iPhone overlapping its corner.
- **Segmented control (signature):** the sticky feature index. Its thumb slides to the section in view (`--thumb-x`/`--thumb-w`, set by an IntersectionObserver) and clears above the first section.
- **Keycaps (signature):** `kbd` with a `[data-pressed]` state; ⌘K and ⌃⇧Space on the landing page light when pressed.
- **Stages:** a grouped-colour tile behind each feature's screenshots; Approvals uses a soft tint ground.
- **Grouped inset list:** the security facts, Settings-style, with gradient glyph squircles.
- **Steps:** tint-filled number circles; a Terminal-style command block.
- **Docs:** source-list sidebar with muted group headers and a filled tint pill for the current page; tabs and the DocScreenshot platform switch as segmented controls; steps as tint circles; rounded hairline tables; search as a filled field.

## Accessibility & Performance

- WCAG AA: all text pairs measured (lowest 4.70:1). Links inside running text are underlined, never colour-only.
- Focus: a 3px tint outline on every interactive element.
- `prefers-reduced-motion` stops the thumb slide and hero rise; `prefers-reduced-transparency` removes blur.
- JS on the landing page is a theme select, one IntersectionObserver and a key listener. Docs add nothing beyond Starlight.
- `<kbd>` content must not end with a raw backslash in Markdown (`<kbd>\</kbd>` escapes the closing tag); write `<kbd>&#92;</kbd>`.

## Do's and Don'ts

Do:
- Use real app screenshots only.
- Keep coral for action, selection and links.
- Keep the independence disclaimer in the footer.

Don't:
- Put text on the brand gradient.
- Add icon-card grids, glow heroes or decorative coral.
- Reintroduce condensed or caps display type.
