---
name: ui-density
description: The dashboard's one comfortable UI density + type scale. Read before adding or changing any dashboard styling, layout, list row, control, card, panel or mobile breakpoint in :evo_dash. Points at docs/ui-density.md and apps/evo_dash/assets/css/density.css.
---

# UI Density & Typography

The dashboard has ONE density and ONE type scale. Full design record: `docs/ui-density.md`. Tokens: `apps/evo_dash/assets/css/density.css` (imported by `assets/css/app.css`).

## Non-negotiables

- Type ladder (utility → size/line-height): `text-2xs` 12/16 (micro badges only) · `text-xs` 13/18 (metadata) · `text-sm` 14/20 (UI default: labels, buttons, rows, cells) · `text-base` 15/24 (reading, task titles, composer) · `text-lg` 17/24 (card/section title) · `text-xl` 20/26 (the one page `h1`) · `text-2xl` 24/30 (hero only).
- Never write an arbitrary font size (`text-[10px]`, `text-[11px]`, `text-[13px]`, `text-[15px]`). 12 px is the floor for dashboard chrome.
- Weights: 400 / 500 / 600 only (700 only for numbers/badges/`<strong>`). No numeric weights like 450/550/650.
- Controls: default 40 px, compact (`-sm`) 32 px, icon-only 32 px (`btn-xs` 24 px only for inline adornments, never the sole action).
- Rows: dense inspector 36 px, standard clickable row 40 px, two-line row 48–56 px, code/diff line 18–20 px.
- Card padding `p-4` (`p-5` hero), page gutters `px-4 sm:px-5 lg:px-6`, section gaps `gap-3` / `space-y-4` / `space-y-6`. No 32 px page gutters.
- Radius: panels/cards/modals `rounded-xl`, controls/chips `rounded-lg`, task composer `rounded-2xl`, pills/avatars full.
- Mobile: anything a finger hits is ≥ 44 px under `@media (pointer: coarse)`; inputs/selects ≥ 16 px font-size there (iOS focus zoom).

## Scroll containment

A panel with a header/filter bar plus a long list is a flex column: panel `overflow: hidden`, header `flex: none`, list `flex: 1 1 auto; min-height: 0; overflow-y: auto`. Only the list scrolls. Never `overflow: auto` on the panel. Never `scroll-behavior: smooth` on a scroller; keep `overscroll-behavior: contain`.

## Before you commit

- Did you add a font-size/padding/row-height literal? Use a token (`var(--text-sm)`, `var(--row-h)`, `var(--control-h)`) or the matching utility instead.
- Did you invent a new radius, card padding, gap or page-title size? Pick the nearest step from the ladder.
- Did you handle coarse pointers for the rows/controls you touched?
- Run `mix tailwind evo_dash` and `node --test apps/evo_dash/assets/css/*.test.cjs`.
- Some tests locate elements by `.text-sm` / `text-base` / `btn-sm` class strings — if you rename a utility, update the test in the same commit.
