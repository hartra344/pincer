---
name: Pincer Website
description: A telephone-exchange switchboard in gray-green enamel; coral lamps mean lit, active or primary, and nothing else.
colors:
  enamel-night: "#17211e"
  panel-night: "#1f2b27"
  raised-night: "#283632"
  ink-night: "#e9f0ec"
  muted-night: "#a9b8b1"
  lamp-night: "#f2674f"
  lamp-ink-night: "#1a0e0b"
  lamp-text-night: "#ff8a70"
  lamp-off-night: "#3a4a44"
  brass-night: "#c9a45c"
  socket-night: "#0e1513"
  enamel-day: "#e6ece8"
  panel-day: "#d6dfda"
  raised-day: "#f4f7f5"
  ink-day: "#14201c"
  muted-day: "#4a5a54"
  lamp-day: "#b33a25"
  lamp-ink-day: "#ffffff"
  lamp-text-day: "#a02e1c"
  lamp-off-day: "#b7c3bd"
  brass-day: "#7a5c22"
  socket-day: "#24302c"
typography:
  display:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', system-ui, sans-serif"
    fontSize: "clamp(2.5rem, 5.2vw, 4.5rem)"
    fontWeight: 700
    lineHeight: 1.05
    letterSpacing: "-0.02em"
  headline:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', system-ui, sans-serif"
    fontSize: "clamp(2rem, 3.6vw, 3.25rem)"
    fontWeight: 700
    lineHeight: 1.05
    letterSpacing: "-0.015em"
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', system-ui, sans-serif"
    fontSize: "1.375rem"
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "-0.015em"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "1.0625rem"
    fontWeight: 400
    lineHeight: 1.6
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', system-ui, sans-serif"
    fontSize: "0.9375rem"
    fontWeight: 600
    lineHeight: 1.3
  numeral:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', system-ui, sans-serif"
    fontSize: "clamp(4.5rem, 9vw, 7.5rem)"
    fontWeight: 700
    lineHeight: 0.9
    letterSpacing: "-0.04em"
  code:
    fontFamily: "'SF Mono', ui-monospace, Menlo, Consolas, monospace"
    fontSize: "0.875rem"
    lineHeight: 1.7
rounded:
  s: "0.375rem"
  m: "0.625rem"
  l: "1rem"
  strip: "3px"
  device: "0.75rem"
spacing:
  "1": "0.25rem"
  "2": "0.5rem"
  "3": "0.75rem"
  "4": "1rem"
  "5": "1.5rem"
  "6": "2rem"
  "7": "3rem"
  "8": "4.5rem"
  "9": "7rem"
components:
  button-lamp:
    backgroundColor: "{colors.lamp-night}"
    textColor: "{colors.lamp-ink-night}"
    rounded: "{rounded.s}"
    height: "2.75rem"
    padding: "0 1.5rem"
  button-secondary:
    backgroundColor: "transparent"
    textColor: "{colors.ink-night}"
    rounded: "{rounded.s}"
    height: "2.75rem"
    padding: "0 1.5rem"
  keyshelf-header:
    backgroundColor: "{colors.panel-night}"
    textColor: "{colors.ink-night}"
    height: "3.5rem"
  line-index:
    backgroundColor: "{colors.enamel-night}"
    textColor: "{colors.muted-night}"
    height: "3.75rem"
  designation-plate:
    backgroundColor: "{colors.panel-night}"
    textColor: "{colors.ink-night}"
    typography: "{typography.label}"
    rounded: "{rounded.strip}"
    padding: "0.1rem 0.5rem"
  panel-band:
    backgroundColor: "{colors.panel-night}"
    textColor: "{colors.ink-night}"
    padding: "7rem 0"
  device-frame:
    backgroundColor: "{colors.raised-night}"
    rounded: "{rounded.device}"
  aside:
    backgroundColor: "{colors.panel-night}"
    textColor: "{colors.ink-night}"
    rounded: "{rounded.m}"
---

# Design System: Pincer Website

## Overview

**Creative North Star: "The Operator's Board"**

The site is a telephone-exchange switchboard in gray-green enamel. Whole bands of the page are panel field; feature lines are rows of ringed sockets; a coral lamp lights only for the primary action, the line in view and things that need attention. Colour means state, never decoration. The tone is plain and instrument-like, matching PRODUCT.md's commitment to honest, concrete, native-first presentation, and it applies equally to the landing page and the Starlight docs.

Density is calm: generous vertical rhythm (7rem band padding), strict two-column modules (5fr copy / 7fr device pair), hairline rules instead of cards. Real app screenshots are the only imagery, shown in device frames on the panel field.

**Key Characteristics:**
- Dark enamel by default; light enamel is equally first-class (`:root[data-theme='light']`, localStorage key `starlight-theme`).
- One accent (coral lamp) used sparingly; brass is the single secondary.
- Apple system type everywhere, sentence case, no web fonts.
- Flat surfaces separated by hairlines and tone; shadow only on device frames.
- Motion is lamp glow and one staggered rise on the hero devices.

## Colors

Cool gray-green enamel with one warm coral and one brass; text pairs clear WCAG AA in both modes. Ratios below are measured from the frontmatter values (dark / light).

### Primary
- **Lamp Coral** (night #f2674f, day #b33a25): fill for the primary button, lit lamp dots, selection, focus and the docs active-page lamp. Ink on the fill is #1a0e0b / #ffffff (6.1:1 / 5.9:1). Lamp fill against page ground is 5.4:1 / 4.9:1.
- **Lamp Text Coral** (night #ff8a70, day #a02e1c): coral used as text and links. 7.2 / 6.0 on ground, 6.4 / 5.3 on panel, 5.5 / 6.7 on raised.

### Secondary
- **Brass** (night #c9a45c, day #7a5c22): the one secondary; setup-step numerals and the `$` prompt in code. 7.0 / 5.2 on ground; 4.6 on the light panel, so use it only at display size or on ground/raised there.

### Neutral
- **Enamel** (night #17211e, day #e6ece8): page ground.
- **Panel** (night #1f2b27, day #d6dfda): header, hero field, security band, footer, plates, docs sidebar.
- **Raised** (night #283632, day #f4f7f5): hover and current-item backgrounds, inline code.
- **Ink** (night #e9f0ec, day #14201c): body and heading text; 14.3 / 14.0 on ground, 12.7 / 12.3 on panel.
- **Muted** (night #a9b8b1, day #4a5a54): secondary text; 8.0 / 6.1 on ground, 7.1 / 5.4 on panel.
- **Socket** (night #0e1513, day #24302c): sockets, phone bezels, code blocks. Code text stays #e9f0ec in both modes.
- **Lamp Off** (night #3a4a44, day #b7c3bd): unlit lamp dot.
- **Hairlines**: ink at 13% (line) and 24% (line-strong) alpha in night (`rgb(200 230 215)`), day `rgb(20 40 32)` at 12% / 22%.

### Docs aside accents (Starlight)
Note = sage (#8fb5a5 / #2f6b56), tip = coral (#f2674f / #b33a25), caution = amber (#e8a23c / #a5610a), danger = crimson (#f0506e / #b5173f), each on a tinted low variant.

### Named Rules
**The Lamp Rule.** Coral means lit, active or primary. It is never a decoration, heading colour or illustration fill.
**The Two-Enamel Rule.** Every new surface is specified in both dark and light using the same role tokens; never hardcode a hex outside `tokens.css` (app-theme swatches are content).

## Typography

**Display Font:** Apple system stack (`-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', system-ui, sans-serif`)
**Body Font:** same stack with `'SF Pro Text'`
**Mono:** `'SF Mono', ui-monospace, Menlo, Consolas, monospace`, code and commands only

**Character:** native and legible, like the app itself. Hierarchy comes from weight (700 display, 650 titles, 550 links) and tight tracking, not from a second family.

### Hierarchy
- **Display** (700, clamp(2.5rem, 5.2vw, 4.5rem), 1.05, -0.02em): the hero H1 only. Sentence case.
- **Headline** (700, clamp(2rem, 3.6vw, 3.25rem) / security up to 4rem, 1.05): section H2s on the landing page. Docs H2 is 1.6rem/650; docs H1 clamp(2rem, 4.5vw, 2.75rem).
- **Title** (700, 1.125–1.375rem, 1.15–1.2): step and switch titles.
- **Body** (400, 1.0625rem, 1.6; docs 1.7): muted secondary copy holds to ~34rem; docs column is 40rem.
- **Label** (600, 0.875–0.9375rem): designation plates, sidebar group headings, tabs, table heads. No caps, no tracking.
- **Numeral** (700, clamp(4.5rem, 9vw, 7.5rem), 0.9, -0.04em, tabular): oversized setup-step numbers in brass.

### Named Rules
**The Sentence Case Rule.** No all-caps and no letter-spaced labels; headings are sentence case in the system face.
**The Code Only Mono Rule.** Mono appears only for code, commands and paths.

## Layout

A page gutter of `max(1.5rem, (100vw − 80rem)/2)` centres an 80rem measure. Landing rhythm: hero 5fr/7fr with the panel field bleeding to the right edge; feature lines 5fr/7fr (alternating via `flip`); security band with a 6fr/5fr head and a four-up switch row; three-column setup steps. Section padding is 7rem (4.5rem below 1100px, 3rem below 720px). Spacing scale 0.25 / 0.5 / 0.75 / 1 / 1.5 / 2 / 3 / 4.5 / 7rem.

Sticky layers: keyshelf header (3.5rem) then line index (3.75rem); anchors use `scroll-margin-top` for both. Breakpoints: 1099px (tighter padding, two-up switches, single-column steps), 899px (hero and lines stack, line index scrolls horizontally with an end fade), 719px (wide nav links hide, one-column switches and steps). Docs use Starlight's shell with the sidebar and TOC mapped to the same tokens.

## Elevation & Depth

Flat by default; depth comes from tonal layering (ground, panel, raised) and hairlines.

### Shadow Vocabulary
- **Device** (`0 1px 2px rgb(0 0 0 / 0.35), 0 18px 40px -12px rgb(0 0 0 / 0.55)`; light `0 1px 2px rgb(20 40 32 / 0.12), 0 18px 40px -14px rgb(20 40 32 / 0.3)`): Mac window, phone, docs images.
- **Lamp glow** (`0 1px 8px 2px var(--pc-lamp-glow)`; button hover `0 4px 22px -4px`): the only coloured light, on lit lamps and the lamp button hover.

### Named Rules
**The Lit Only Rule.** Glow is a state. A glowing element that is not active, hovered or primary is a bug.

## Shapes

Small instrument radii: 0.375rem controls and code, 0.625rem asides, 3–4px designation plates (near-square, like engraved strips), 0.75rem Mac frames, 1.6rem phone bezels (4px socket-colour border), full circles for sockets and lamps, 22% for the logo. Structure is drawn with hairlines and 2px top rules, not boxed cards. A subtle 30px dot grid (`radial-gradient` at 1.5px, line-strong) marks the panel field and security band as jack fields.

## Components

### Keyshelf header
Sticky 3.5rem panel bar with a hairline bottom edge: logo and name left; Features, Security, Docs, theme toggle, GitHub icon and a coral Install lamp button right. Links 0.9375rem/550, hover to lamp-text. Wide links hide below 720px.

### Lamp button
Coral fill, lamp-ink text, 2.75rem tall, 0.375rem radius, 650 weight. Hover adds glow and brightness 1.05. Secondary button: transparent, 1px line-strong border, raised background on hover. One lamp button per view.

### Line index
Sticky strip under the header: a row of sockets (1.5rem ringed circles) each with an unlit dot and a designation plate. The dot lights coral with glow for the section in view (`data-lit`) and on hover or focus. It is the page's signature interaction.

### Device frames
Mac window (0.75rem radius, 1px inset outline, device shadow) with the iPhone overlapping the lower-right (or lower-left when `flip`) corner in a socket-colour bezel. Hero devices rise in staggered (0.9s, `--ease-out`, 0.05s then 0.3s); nothing else animates in.

### Panel band
A full-width panel-colour band with hairline top and bottom, dot grid, 7rem padding; used for the security section (four switch columns with a 2px top rule and a permanently lit lamp) and the hero field.

### Designation plates
Small panel-fill plates with a 1px line-strong border, 3–4px radius, 600-weight system type: line-index labels and theme-name plates (with overlapping colour chips).

### Docs sidebar lamp
Group headings are 0.875rem/650 muted labels. The current page gets raised background, white text, 600 weight and a 0.5rem coral lamp dot with glow at the left; hover only raises the background. The TOC's active heading turns lamp-text at 600. Focus is a 3px lamp outline.

### Asides
Rounded 0.625rem, 1px border at 45% of the aside accent, tinted low background, no thick side border. Title 600 system face. Note sage, tip coral, caution amber, danger crimson.

### Tabs, steps, tables (docs)
Selected tab gets a lamp underline. Steps use a raised square badge with lamp-text numeral. Table heads sit on panel with hairline rules.

## Do's and Don'ts

### Do:
- **Do** use `--pc-*` tokens for every colour and keep dark and light in step.
- **Do** light a lamp only for the primary action, the active line or a state needing attention.
- **Do** set ink on lamp fills (6.1:1 / 5.9:1) and use lamp-text, not the fill, for coral text.
- **Do** keep 2.75rem tap targets on buttons and honour `prefers-reduced-motion` (animations and transitions off).
- **Do** use real screenshots in device frames; theme scrollbars, selection and focus rings (coral, 2–3px, 3px offset).

### Don't:
- **Don't** use a display web font, caps, or letter-spaced labels; type is the Apple system stack in sentence case.
- **Don't** add eyebrow or kicker labels above headings, gradient text, glass effects, or same-size icon-card grids as page structure.
- **Don't** use mono outside code.
- **Don't** put coral on more than the lamp roles above, or use a thick coloured side border on callouts.
- **Don't** invent counts, testimonials or claims; PRODUCT.md is the source of truth.

## Deviations

- **Type:** the contract specified Big Shoulders in caps for headlines and designation strips. The user rejected it as hard to read, so the built system uses the Apple system stack, sentence case, everywhere. Designation plates are now plain 600-weight labels rather than engraved caps.
- The contract's "oversized numerals" survive as the brass system-face step numerals.
