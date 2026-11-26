# UI Density & Typography — Design Record

## Intent

ONE comfortable density and ONE type scale for the whole dashboard (`:evo_dash`), so a surface written in 2024 (Settings, System) and one written today (the workbench sidebars) read as the same product.

"Comfortable" means: readable 14 px UI text, 13 px metadata, a 12 px absolute floor, 40 px primary controls, 40–48 px clickable rows, 16 px card padding, and touch-safe targets on coarse pointers.

Non-goals: a user-facing density switcher, a second "compact" theme, per-page type ramps, or changing the visual identity (colors, radii family, motion).

This record is the contract; `apps/evo_dash/assets/css/CONTEXT.md` holds the implementation rules and `assets/css/density.css` holds the tokens.

## Baseline that made this necessary

- There was no typography or density token layer: `app.css` had one `@theme` block declaring only a color, and 45 `font-size` literals with 18 distinct values lived in `workbench.css`.
- DaisyUI's sizing dial was overridden to `--size-field: 0.21875rem` (7/8 scale), so `btn-sm`/`input-sm` rendered **28 px** with 12 px text, `btn-xs` **21 px**, and the unsuffixed `btn` **35 px** — all below comfortable, and none matching the 16 px body around them.
- The same concepts carried different sizes everywhere: 539 `text-xs` + 436 `text-sm` + 55 arbitrary `text-[10px]`/`text-[11px]`/`text-[15px]` sites; one clickable row was 31 px in the sidebar, 34 px in the project list, 36 px in history, 40 px in processes, 44 px in the commit graph and 48 px in the commit list; controls spanned 21/24/28/32/34/35/36/40 px.
- Settings was the outlier in the other direction: 32 px page gutters and a 24 px sticky header wrapped around 11 px metadata, while every other page ran 16–24 px gutters.
- Mobile had almost no density handling: no `pointer: coarse` rule, no touch-target floor, and 24–32 px controls everywhere.
- The workbench right panel scrolled **the whole component** (`#workbench-history { overflow: auto }` was the only scroll box), so the heading, project label, search field and filters scrolled away with the task list.

## The type scale (authoritative)

Sizes are a ladder, not a menu. Keep the utility names; the values live in `assets/css/density.css`'s `@theme`.

| Role | Utility | Size / line-height | Typical use |
|------|---------|--------------------|-------------|
| Micro | `text-2xs` | 12 px / 16 px | uppercase badges, lane chips, `kbd`, counts, icon-adjacent labels |
| Metadata | `text-xs` | 13 px / 18 px | timestamps, task/agent ids, helper lines, secondary meta, table secondary cells |
| UI default | `text-sm` | 14 px / 20 px | labels, buttons, list rows, table cells, form values on fine pointers, card body copy |
| Reading | `text-base` | 15 px / 24 px | markdown prose, objectives, task titles, descriptions, the task composer |
| Card / section title | `text-lg` | 17 px / 24 px | card headers, section headers |
| Page title | `text-xl` | 20 px / 26 px | a page-scoped headline that is NOT the page name (onboarding, a review header) |
| Hero (rare) | `text-2xl` | 24 px / 30 px | welcome / empty-state heading only |

Rules:

- **12 px is the floor.** No dashboard chrome text may render smaller (`text-[10px]` and `text-[11px]` are banned; use `text-2xs` / `text-xs`).
- Micro text is for all-caps labels, badges and chips — never for a sentence, a helper explanation or an id a user may need to read.
- Weights are **400 / 500 / 600 only**; `700` is reserved for numbers, badges and `<strong>` in prose. Never use numeric weights (`450`, `550`, `650`).
- Metadata is not an excuse for density: a 13 px line still gets 18 px line-height.
- In-shell pages carry **no page `h1`**: the workbench tab rail names the page (`.workbench-context-title`, `text-sm font-semibold`, aligned with the rounded canvas' content line), so a page renders only content and state headings. A `text-xl font-semibold` `h1` is reserved for a page-scoped headline that is not the page name (onboarding, a review header). Section headers `text-lg font-semibold`. Card titles `text-base font-semibold`.
- Long-form/reading surfaces use the `1.6` leading (`--leading-body`), UI text uses the token line-height.

## Density tokens

`apps/evo_dash/assets/css/density.css` owns these and is the only place they are declared:

| Token | Value | Meaning |
|-------|-------|---------|
| `--text-2xs` … `--text-2xl` | per the ladder above | type scale (also emits `text-*` utilities) |
| `--leading-body` | `1.6` | long-form reading leading |
| `--control-h` | `2.5rem` (40 px) | default button/input/select height |
| `--control-h-sm` | `2rem` (32 px) | compact toolbar/table control |
| `--control-h-xs` | `1.5rem` (24 px) | inline adornment only, never the sole action |
| `--row-h-sm` | `2.25rem` (36 px) | dense inspector row (settings list, sidebar panel row, file tree) |
| `--row-h` | `2.5rem` (40 px) | standard clickable list row |
| `--row-h-tall` | `3rem` (48 px) | two-line row / primary nav entry |
| `--touch-target` | `2.75rem` (44 px) | coarse-pointer minimum for anything a finger hits |
| `--card-pad` | `1rem` (16 px) | card body padding |
| `--card-pad-lg` | `1.25rem` (20 px) | hero / single-card padding |
| `--page-gutter` | `1rem` / `1.25rem` / `1.5rem` (sm/lg) | page horizontal padding |

DaisyUI's `--size-field` / `--size-selector` are restored to `0.25rem` in **both** theme blocks, which is what produces the 40/32/24 px control family above. Do not reintroduce a scaled-down field size.

## Control heights

- Default control (button, input, select, textarea trigger): **40 px** — DaisyUI `btn` / `input` / `select` with no size modifier.
- Compact control: **32 px** — `btn-sm` / `input-sm` / `select-sm`, only inside a toolbar, table row, inspector or filter bar.
- Icon-only action: **32 px** desktop (`btn-sm btn-square`), **44 px** on coarse pointers.
- `btn-xs` (24 px) is for decorative/inline affordances inside an already-large clickable row and must never be the only way to perform an action.
- Form values are `text-sm` (14 px) on fine pointers and **16 px on coarse pointers** (iOS focus zoom); the task composer textarea and the Assistant composer stay `text-base`/16 px everywhere.
- The same action weight uses the same size across pages: a "Reset to default" or "Merge" is `btn-sm`, a primary page action is default `btn`.

## List rows

| Row kind | Height | Type |
|----------|--------|------|
| Dense inspector (settings list, sidebar panel row, file/dir tree) | 36 px min | 14 px label, 13 px meta |
| Standard clickable list row (tasks list, processes, history row) | 40 px min | 14 px, one line clamp |
| Two-line row (title + meta) | 48–56 px | 14 px / 20 + 13 px / 18 |
| Primary nav / active task | 44–56 px | 14 px |
| Code / diff / commit-graph line | 18–20 px line, 12.5–13 px mono | fixed 44 px commit row stays |

- Vertical padding on a row is derived from the height tokens, never `py-0.5`/`py-1` on a row that is the primary target.
- A row that can be clicked is a row a finger must hit: below `(pointer: coarse)` every list row and nav entry is **≥ 44 px**.
- A scrolling list carries its own bounded scroller (see below), never the panel.

## Layout rhythm

- Base rhythm **4 px**; allowed steps 4 / 8 / 12 / 16 / 20 / 24 / 32.
- Page gutters: `px-4 sm:px-5 lg:px-6` (16/20/24). **No page uses 32 px gutters.**
- Page vertical padding: `py-4` / `py-5`; Settings panes `px-4 sm:px-6 py-4 sm:py-6`.
- Card padding: `p-4` standard, `p-5` for a single hero card; modals `p-5 sm:p-6` max.
- Gaps: `gap-3` inside a card/group of cells, `space-y-4` between cards, `space-y-6` between major sections (never `mb-3` + `mb-4` + `mb-6` mixed on one page).
- Radius: panels/cards/modals `rounded-xl` (12 px), controls/chips `rounded-lg` (8 px), task composer `rounded-2xl` (16 px), pills/avatars full. No `rounded-3xl` outside chat bubbles.
- Single-column forms and reading surfaces cap at `max-w-3xl` (48 rem); the Assistant transcript keeps `58rem`.

## Scroll containment (the one rule)

A panel with a fixed header/filter bar and a long list is a **flex column**:

```css
panel   { display: flex; flex-direction: column; overflow: hidden; min-height: 0; }
header  { flex: none; }
list    { flex: 1 1 auto; min-height: 0; overflow-y: auto; }
```

Only the active content view scrolls — never the panel, never the page, when the shell already owns the viewport height.
History (`#workbench-history`) keeps Project and Status, Search, and the kind switch outside the scroller; only `#workbench-history-rows` scrolls.
Source Control (`#workbench-git`) keeps its summary and switcher at intrinsic height; `.workbench-git-body` passes the remaining height to the active Changes, Branches or Commits view without scrolling itself. Branch search stays at the top of its view.
The reference implementation for a bounded in-page scroller is the commit graph's `.cg-scroll` chain (`.shell-fill` → `flex: 1 1 0; min-height: 0` → `overflow: auto`).
A scroller never gets `scroll-behavior: smooth`, and it keeps `overscroll-behavior: contain`.

## Touch & mobile

- Every interactive target is **≥ 44 px** under `@media (pointer: coarse)` — buttons, nav entries, list rows, tabs, icon buttons, pickers.
- Text inputs and selects are **≥ 16 px font-size** on coarse pointers (prevents iOS focus zoom); desktop keeps 14 px.
- Dense inspector surfaces (commit graph, diff viewer) may keep 32–36 px rows on fine pointers; on coarse pointers they get the 44 px floor and horizontal scroll instead of squeezed columns.
- The shell drawer patterns (left sidebar, right panels below 1280 px) keep their width caps; density changes never add viewport-height math inside the shell.

## Per-surface targets

| Surface | Target |
|---------|--------|
| `/settings` | Gutters reduced from `px-8 py-8` to `px-4 sm:px-6 py-4 sm:py-6`; sticky section header `p-4`; list rows 40 px (`px-4 py-3`) with 14 px labels, 13 px help (no 11 px); inputs 14 px / 16 px coarse; provider roster rows `px-4 py-3`. |
| `/system` | Cards `p-4`, `space-y-4`, section headers `text-lg`; Self-Check cells `p-4 gap-3`; body `text-sm`, secondary `text-xs`; no page `h1` (the rail names the page). |
| `/tasks` | No page `h1` (the rail names the page); filter bar `p-3 sm:p-4`; card `p-4 gap-4`; title `text-base`; meta `text-xs` (never smaller); actions `btn-sm`, coarse 44 px. |
| `/agents` | No page `h1` (the rail names the page); tree rows 32–36 px, lane chips `text-2xs`, commit rows keep 44 px; inspector body 14 px, mono 13 px; panels `p-4`; coarse-pointer rows 44 px. |
| `/processes` | No page `h1` (the rail names the page); row min-height 40 px desktop / 44 px coarse; command `text-sm`, meta `text-xs`; expand control and square actions ≥ 36 px (44 px coarse). |
| Workbench rail | `--shell-topbar-h` derives from the control and padding tokens, with a touch-target override for narrow screens or coarse pointers; tabs scroll horizontally without squeezing the rail controls. |
| `/projects` workbench | Shared composer surface (`text-base`, 16 px radius) with flat toolbar triggers; preserve the coarse-pointer floor and the 36 px file-tree/picker row target (`--row-h-sm`). |
| `/assistant` | Reading body stays 15 px / 1.6; sidebar rows 40 px (`--row-h`), 44 px coarse; composer 16 px; actions 32 px desktop / 44 px coarse; no `btn-xs` for interrupt/approve. |
| `/review/:task_id` | Header card `p-4 sm:p-5`; tabs 40 px; file-tree rows 32 px (44 coarse); diff mono 13 px / 20 px line; commit rows keep 48 px. |
| Left sidebar | Nav links 40 px (`px-3 py-2 text-sm`); `.workbench-row` 40 px / 14 px label (36 px only for the settings-group, project-picker and Create-menu lists); active-task rows 44–56 px; all nav rows 44 px coarse. |
| `/welcome` | Column `max-w-3xl`; `space-y-5`; controls 40 px default (`btn`/`input`), `btn-sm` only for secondary; step bodies `space-y-4`. |

## Rules for agents

1. Never write an arbitrary font size (`text-[10px]`, `text-[13px]`, `text-[15px]`); use the ladder, adding `text-2xs` for micro.
2. Never hardcode a `font-size`, `padding` or row height in CSS: use the density tokens or a Tailwind utility on the ladder.
3. Prefer changing a token value over editing hundreds of call sites; when you must change a class name, update the test that asserts it in the same commit.
4. Do not introduce a new radius, card padding or section gap value — pick the nearest step above.
5. A list panel with a header gets the scroll-containment shape, not `overflow: auto` on the panel.
6. Mobile is part of the definition of done: add the coarse-pointer/touch floor for anything you touch.
7. Visual review is required for anything wider than a token change: check light/dark, 390 px and 1440 px widths, and `prefers-reduced-motion`.

## Validation

- `mix tailwind evo_dash` (from the repository root) compiles the CSS.
- `node --test apps/evo_dash/assets/css/*.test.cjs apps/evo_dash/assets/js/*.test.cjs apps/evo_dash/assets/js/hooks/*.test.cjs` — source contracts, incl. `density.test.cjs`, the layout height contract, the workbench motion contract and the settings-window overflow contract.
- `mix test apps/evo_dash/test` — UI assertions (some locate elements by `.text-sm` / `text-base` class names, so a rename must update them).
- `mix format --check-formatted` for touched Elixir/HEEx files.
