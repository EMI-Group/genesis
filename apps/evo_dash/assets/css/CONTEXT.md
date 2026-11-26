# Dashboard CSS

## Intent
`app.css` is the single Tailwind CSS 4 entry point for shared dashboard styling and page-specific adjustments.
`density.css` is the ONE density + typography token layer every other stylesheet and the markup consume; it is imported FIRST (right after `@import "tailwindcss" source(none);`) so its type ladder replaces Tailwind's stock steps for the whole bundle.
`surfaces.css` is the ONE surface/elevation token layer: three layers (chrome → canvas → overlays), and overlays are the only shadowed surfaces.

## API Surface
The file contains DaisyUI light/dark themes, accent fill/standalone role tokens, shared component styles, Markdown, responsive input layout, and a final Genesis Assistant chat section.
The Assistant section scopes reading rhythm, quiet headings/quotes, code sizing and narrow-screen spacing to `#chat-messages .md-content`, and styles the column `.help-composer` (textarea row above a `.help-composer-controls` bar holding the picker left and Send/Stop right) plus `.help-caret` without changing layout or hook contracts.
`.workbench-composer[data-composer-kind]` scopes a common editor: the descendant `.workbench-composer-surface` is the visible card, `.workbench-composer-editor` wraps the textarea, and `.workbench-composer-toolbar` is the action row.
Only the card gets the hairline and variant-specific fill, with no elevation, a zero-blur focus ring and a forced-colors outline; toolbar controls use the shared touch-target floor.
New Task retains its native `.input-card` and AdaptiveInput geometry; its card is distinct from the surrounding page, and the labelled `section#task-options` uses flat toggle labels and aligned fields with shared disclosure styling for Advanced options and Project Settings.
Mode/model capsule summaries are borderless toolbar actions with visible keyboard focus and open-state fill; their popup positioning, item styles and motion remain capsule-owned.
Inside `#chat-messages`, `.assistant-execution-indicator` is an inline-flex status row with a static base-content label and `.assistant-execution-dot` is a fixed 0.375rem standalone-accent decorative dot.
The dot alone breathes between opacity 1 and 0.45 over 2s; `.help-caret` remains visible at opacity 0.4 at its quietest over 1.4s.
Both animations change opacity only, and reduced motion disables them with explicit opacity 1, preserving the label, dot and caret without layout or height animation.
Markup integration must opt into these classes only for pending/running execution, supply the real readable status label and an `aria-hidden="true"` dot, and retain the existing reserved-height status/footer slot rather than infer execution from empty response text.
CSS supplies no status text or lifecycle detection, and changes require no new JS hook.
The legacy history entrance selector excludes both `#chat-messages` itself and nested Assistant scrollers with `:where(:not(#chat-messages, #chat-messages *))`, preserving its original specificity and non-Assistant animation while disabling it under reduced motion.
Shared Markdown guards wrap long prose and constrain code/table width while preserving horizontal scrolling.
The fused capsule rules (`.capsule-stop` / `.capsule-item` / `.capsule-stop-active`) add only resting alpha plus hover/active states; capsule LAYOUT stays on the markup's Tailwind utilities.
The capsule animation rules add `@keyframes capsule-panel-in` (140ms entrance) / `capsule-panel-out` (130ms, `forwards`) driving only `opacity` + `transform`, plus `transform-origin: bottom` on `.capsule-panel` so the panel grows out of its trigger edge.
The open rule keys on `details.capsule[open]`, the close rule on `details.capsule[data-capsule-state="closing"]` (the CapsulePanel hook owns that attribute and removes `open` only after the animation ends).
The view rules hide every `.capsule-view` and display only the one selected by the root's `data-capsule-view` attribute (with a `:not([data-capsule-view])` first-paint guard that keeps the model view visible before the hook seeds it), plus a 120ms directional `capsule-view-in` / `capsule-view-in-back` fade-slide so drilling in and going back read as opposite directions.
A `capsule-sub-in` entrance animates `details.capsule-sub[open] > .capsule-list`, and the counterpart `details.capsule-sub[data-capsule-sub-state="closing"] > .capsule-list` fades the same list out with `motion-fade-out` + the shared tokens — the CapsulePanel hook defers the native `open` removal for it (a closed submenu still opens natively).
The auto-scrolled transcript rule targets exactly the two scrollers the AgentHistoryAutoScroll hook drives: the `/assistant` `#chat-messages` transcript and the /agents "Chat History / Session Memory" panel (`.agent-history-scroll`).
`min-height: 0` keeps each one a shrinkable flex child, so a tall transcript scrolls INSIDE the panel instead of pushing the composer or the sidebar rail down.
`overflow-anchor: none` disables browser scroll anchoring, which would otherwise re-adjust `scrollTop` after every content mutation and fight the hook's instant stick-to-bottom as visible shaking.
`overscroll-behavior: contain` stops scroll chaining at either end.
`scroll-behavior: auto` is load-bearing: the document sets `html { scroll-behavior: smooth }`, and a smooth behavior on these panels would animate every `scrollTop = scrollHeight` assignment.
The `/agents` inspector animation API is opt-in via exactly three classes and requires no new wrapper or child elements.
`.inspector-thinking` belongs on the active LLM thinking indicator only, preserves its existing readable label, and paints a faint standalone-accent background shimmer on a 2.4s cycle without generated content.
`.inspector-stream-cursor` belongs on the streaming cursor marker whose glyph is supplied by markup (no CSS-generated cursor), uses the standalone accent, and blinks subtly between opacity 1 and 0.4 on a 1.2s cycle.
`.inspector-message-enter` is added by the `InspectorMessages` JS hook only to genuinely new message rows, never initial history or streamed updates, and runs `inspector-message-in` once for 180ms with opacity 0.55→1 and a 3px vertical translate→none.
The hook owns message-row class removal after completion or cancellation, and the animation deliberately has no fill mode so finished rows retain no transform or stacking context.
These classes do not animate layout, heights or scrolling, and the instant `AgentHistoryAutoScroll` invariants above remain unchanged.
Their reduced-motion override disables all three animations while leaving the thinking label, static accent wash, cursor glyph and message rows visible.
The `<dialog class="modal">` rules only fill the gaps DaisyUI's `.modal` / `.modal-box` leave for a modal opened with `showModal()` by the DialogModal hook, and every selector is scoped to `dialog`, so older `<div class="modal modal-open">` dialogs stay untouched and no second modal system may be grown.
`dialog.modal .modal-box` carries `max-height: min(90dvh, 48rem)` (behind a `100vh` fallback), `overflow-y: auto` and `overscroll-behavior: contain`, so the action row stays reachable on short viewports.
`dialog.modal .modal-box pre` scrolls horizontally (`overflow-x: auto`, `overscroll-behavior-x: contain`) while `:not(pre) > code` wraps with `overflow-wrap: anywhere`, keeping approval code readable verbatim.
A `@media (prefers-reduced-motion: reduce)` block disables the `dialog.modal` and `dialog.modal .modal-box` transitions.

The provider-setup wizard step transitions (Settings + Welcome) are three flat classes with no hook: `.wizard-step-enter` on a step body wrapper whose DOM id changes per step (`id={"wizard-step-" <> step}`), so a fresh element replays `wizard-step-in` (200ms `cubic-bezier(0.16, 1, 0.3, 1)`, opacity 0→1, `translateY(-7px) scale(0.98)` → none).
`.wizard-step-enter[data-direction="back"]` swaps only `animation-name` to `wizard-step-in-back`, the same motion from `translateY(7px)` so Back reads opposite to Next; an explicit `data-direction="forward"` (or no attribute) keeps the forward motion.
`.wizard-progress` carries a 200ms ease-out `transition` on `width`, `transform` and `background-color` so the rail/fill animates between steps; it sets no width, shape or color — those stay in the markup's Tailwind utilities and theme tokens.
A dedicated `@media (prefers-reduced-motion: reduce)` block disables both the wizard animations and the progress transition, so reduced motion shows each step instantly.
Component authors opt in with the class only: no JS, no layout/height animation, and the step wrapper must be the re-keyed element or the entrance never replays.

## In-shell height contract
The SHELL owns the viewport height and no page may measure itself against the viewport: `body` + `#app-layout` are `h-dvh overflow-hidden`, `#sidebar` is a child of that flex row, and `@media (max-width: 640px) #app-layout { height: var(--app-vh, 100dvh) }` is the only other shell rule that may take a viewport height.
`#main-content` is the one page content box and its height is already definite (viewport − workbench top bar − its own `py-4` padding), so `100%` of it is the correct "fill the page" height.
A page that must fill it takes the `.shell-fill` utility (`height: 100%; min-height: 0` in `app.css`) and its children bound themselves with `flex: 1 1 0; min-height: 0`.
A `height`/`min-height` derived from `100vh`/`100dvh` is forbidden inside the shell, because it ignores the chrome it skipped and overflows or clips at the bottom by exactly that much.
`max-height` caps stay allowed (a cap can only under-fill); a cap that must account for shell chrome uses `--shell-topbar-h` rather than a fresh magic number.
`--shell-topbar-h` (one default derived from control and padding tokens, with a coarse/narrow override through `--workbench-topbar-size`) is defined on `#app-layout` by `./workbench.css` and drives `.workbench-top { flex: 0 0 var(--shell-topbar-h) }`; a `simple_nav` page renders no bar and gets the extra content height.
Viewport-anchored top-layer surfaces keep viewport units: the `dialog.modal .modal-box` caps, `.project-palette-overlay` (`position: fixed`), `.workbench-window`, `#workbench-settings-frame` and `.workbench-window-page` (the settings window's own iframe document) size themselves against the viewport, never against the content box.
The Settings window header's "Settings server" picker (`.workbench-settings-server-picker` in `./workbench.css`) is a shrinkable flex row — `min-width: 0` plus a content-sized shrinking select, never a percentage-width (`w-full`) select in a shrink-to-fit line, which overflowed the popup document — and `./settings_window_overflow.test.cjs` pins it.
`.agents-page-layout` fills `#main-content` at xl+ (`height: 100%`, `.shell-fill` in the markup) instead of subtracting the chrome from a viewport unit.
The expanded `.input-card` is a size container (`container-type: size`, expanded layout only — the compact card's height is content-derived and would collapse); its direct `.workbench-composer-editor` passes the leftover flex height around the toolbar and optional sidecars down to the scrolling textarea.
The textarea floor is the smallest of 10 lines (6 on mobile), `100cqh - var(--input-toolbar-budget, 4.5rem)` and `100%` of the allocated editor height.
`100cqh` measures the card's content box and tracks the shell and the `--app-vh` keyboard override automatically, while the editor height caps the floor when sidecars take up space.

## Motion foundation (`motion.css`)
`./motion.css` is the ONE shared motion vocabulary every dashboard package consumes with a single attribute or class; `app.css` imports it from its `@import` block immediately after `./workbench.css` (an `@import` must precede every other rule, so "last import" is "loaded last"), and its `!important` reduced-motion backstop makes cascade position moot.
Timing and easing come only from `--motion-fast` (120ms), `--motion-base` (170ms), `--motion-slow` (220ms), `--motion-ease-out` and `--motion-ease-in` on `:root`.
Motion is opacity/transform only (`motion-fade-in`, `motion-fade-out`, `motion-slide-in` — a 6px lift; `motion-collapse` is deliberately opacity-only), the one bounded layout exception being `grid-template-rows: 0fr → 1fr` on a single wrapper.
Never animate `height`/`width` on the transcript scrollers, the composer or the sidebar, and never add `scroll-behavior: smooth` to `#chat-messages`, `.agent-history-scroll`, `.cg-scroll` or `#workbench-history`.
`<details>` disclosure — add `class="motion-disclosure"`: `[open] > :not(summary)` slides in with no JS, and the `DisclosureMotion` hook sets `data-disclosure-state="closing"` then removes `open` for the exit.
State-driven panel — `class="motion-panel"` plus `data-motion-state="opening" | "closing"` (or the class-only `motion-panel-open` / `motion-panel-close`, and `motion-panel-slide` to slide instead of fade); the `both` fill holds the closing frame until the hook writes `hidden`.
That recipe has TWO writers, and the split is load-bearing: the `MotionPanel` hook for a panel the server KEEPS MOUNTED (server owns `data-motion-want`, hook owns `data-motion-state` + `hidden`, focused by an opt-in `data-motion-focus` target), and §6 `phx-remove` for a node the server REMOVES.
A mounted panel is required whenever the exit must fade real content: `:if` unmounting tears the content out of the layout in the same frame, so only LiveView's deferred removal (which keeps the children alive) can show an exit.
`.motion-panel[data-motion-state="closed"], .motion-panel[hidden]` is the hooked closed frame (`display: none`, specificity ahead of a utility display class, no `!important`).
Mounted-section collapse — `class="motion-collapse-grid"` + `data-motion-open="true"` on one wrapper, for a panel that stays mounted and cannot use `:if`.
LiveView `:if` removal — `phx-remove={JS.hide(transition: {"motion-exit-lift", "motion-exit-visible", "motion-exit-hidden"})}`: one attribute, no JS of our own.
The tuple is `{transition-class, start-class, end-class}`, applied in that order by LiveView, so the start class is mandatory and the end class must set every property the transition class lists.
`motion-exit-fade` + `motion-exit-visible|hidden` is fade PLUS the shared -4px lift (never a pure fade); a caller that must not transform passes its own end class (e.g. `opacity-0`) in that slot.
Project palette exit — `phx-remove` on `#project-omnibox`, the node `projects_live.ex`'s `:if` actually removes, with `{"motion-exit-fade", "motion-exit-visible", "opacity-0"}`, so backdrop and overlay leave as ONE unit.
`opacity-0` (never `motion-exit-hidden`) is load-bearing there: a transform on that zero-height wrapper re-bases its two `position: fixed` children (see "Overlay paint" in `../../lib/evo_dash_web/components/CONTEXT.md`).
The palette has no exit keyframe and no `data-palette-state` vocabulary — the entry keyframes (`palette-fade-in`, `palette-slide-down`) are the whole local palette motion.
Workbench windows — `dialog.workbench-window[open]` animates in on `showModal()`, while the `workbench.js` close path sets `data-window-state="closing"` and defers `close()` for the exit (plus the `::backdrop` fade).
Native modals — `dialog_modal.js` sets `data-dialog-state="opening|open|closing"` and defers `close()`, so `dialog.modal[data-dialog-state="opening"] .modal-box` slides in and `[data-dialog-state="closing"] .modal-box` fades out: the animated node is ALWAYS `.modal-box`, because both phases settle on a target-verified `animationend` whose target is that panel (a `::backdrop` animation is dispatched at the `<dialog>` and a child animation bubbles from the child). The `<dialog>` element itself carries no animation; only its `::backdrop` fades.
Navigation — project, node, route and theme changes do not animate the whole canvas; local component transitions keep their motion and reduced-motion contracts.
Shared list entry — `class="motion-list-enter"` on new rows, toggled by the `ListEnter` hook from `data-list-enter-scope` + per-row `data-list-enter-key`; see § `.motion-list-enter` below.
The LAST rule in `motion.css` is the global `prefers-reduced-motion` backstop (`animation-duration`, `animation-iteration-count`, `transition-duration`, `transition-delay` and `scroll-behavior: auto`, all `!important`, on `*, *::before, *::after`); nothing may follow it, and per-component guards elsewhere stay as harmless redundancy.

### `.motion-list-enter` (the one motion class that lives in `app.css`)
`.motion-list-enter` is the LAST rule in `app.css` and its only consumer is the `ListEnter` hook (`../js/hooks/list_enter.js`), which toggles that single class on newly inserted rows.
Its animation is `motion-slide-in` with `--motion-base` / `--motion-ease-out` from `motion.css`, so it defines no keyframes of its own and `motion.css`'s global backstop already disables it under reduced motion.
The class must stay in `app.css`: a `hooks/*.js` class toggle cannot import the motion vocabulary itself, so deleting it as "unused CSS" breaks the hook.

## Navigation motion
Route, project, node and theme changes render directly; dashboard styles contain no browser View Transition opt-in, view-transition names or snapshot animations.
The project-switch preview is a static cover while data arrives, and the document does not request smooth scrolling.
Keep motion scoped to controls, disclosures, docks, local status indicators and list entries.

## Surface & elevation system (`surfaces.css`)
`./surfaces.css` is imported from `app.css`'s `@import` block immediately after `./density.css` and before `./assistant.css`, so the order is `tailwindcss` → `density.css` → `surfaces.css` → `assistant.css` → `workbench.css` → `motion.css`: sizes stay in `density.css`, tones and depth live here.
It declares TOKENS plus the `.task-card*` consumers and nothing else — no `height`, `min-height`, `padding`, `gap` or `font-size` declaration exists in the file, so `density.css` stays the only size source.
THREE layers, every value derived with `color-mix()` from the existing base/neutral palette plus `base-content` at low alpha (no new brand colors): layer 0 is recessed chrome, layer 1 is the continuous content canvas, layer 2 is overlays and is the ONLY shadowed surface.

| Token | Layer | Role |
|---|---|---|
| `--surface-shell` | 0 | workbench top bar + frame gutter (the ONE chrome tone that lifts in the dark theme) |
| `--surface-rail` | 0 | the recessed tone: left sidebar, Settings navigation, BOTH docked right panels (History + Source Control) and a nested task-card panel |
| `--surface-canvas` | 1 | center content canvas (`#main-content`/`#main-scroll`), flat, never shadowed |
| `--surface-text-muted` | — | opaque neutral foreground for the composer placeholders and History controls |
| `--surface-raised` | 2 | palettes, menus, dialogs, notifications |
| `--surface-hover` | 1 | hover fill for a surface row/card |
| `--surface-selected` | 1 | selected fill, mixed from the accent |
| `--elev-1` | 2 | resting overlay depth (a raised card) |
| `--elev-2` | 2 | menus, popovers, tooltips |
| `--elev-3` | 2 | modal-scale overlays (`<dialog>`, palette overlay, settings window, assistant menu) |
| `--border-hairline` | — | the ONE 1px separation (`base-300`) |
| `--border-strong` | — | hover/emphasis border (content at low alpha) |
| `--radius-tab` | — | bottom-anchored tab rounding (geometry) |

Light values are near-invisible (a light UI separates by border and tone, not shadow); the `[data-theme="dark"]` block re-declares every TONE with a stronger alpha and achromatic black elevations, because a dark surface separates by depth — `--radius-tab` is geometry and is NOT re-declared for dark.
The rail is ONE restrained step BENEATH the content canvas in both themes, so the sidebar and the canvas read as one continuous surface; only the shell (top bar) wears the chrome step.
In the dark theme the rail anchors on `var(--color-base-100)` because `base-200` is LIGHTER than `base-100` there, and that anchoring was what lifted the sidebar above the canvas; the dark token block therefore never lifts the rail.
`:root` + `[data-theme="dark"]` is the only pair, because the Settings popup's iframe document has no `#app-layout` and still needs the tokens from its own `<html data-theme=…>`.
RULE: content surfaces never carry a real shadow — only overlays consume `var(--elev-2)`/`var(--elev-3)`; a `box-shadow` on a content rule is either `none` or a `0 0 0 …` focus/glow ring (rings are not elevation).
`workbench.css`/`assistant.css` therefore consume these tokens instead of defining a second tone pair: `--workbench-surface`/`--workbench-rail` are gone, and `--workbench-hover`/`--workbench-selected` are thin aliases of `--surface-hover`/`--surface-selected`, declared on BOTH `#app-layout` and `#workbench-window-content`.
The canvas, frame and committed tab share `--workbench-canvas` with a `--surface-canvas` fallback; only `.workbench-center` showing New Task without a Git diff portal overrides it.
The resting composer has its own `--composer-surface` so it remains distinct from the page.

### Workbench chrome and tab strip
`.workbench-top + .workbench-content-stack` is the inset canvas frame shared by the page and Git-diff portal: density-derived gutters, a hairline and `--radius-box`, no elevation shadow and no new scroll or containing block for fixed overlays.
The sidebar uses the recessed `--surface-rail` fill, merging with the canvas as one surface while space and subtle hover/selected fills separate destinations rather than repeated dividers.
`.workbench-top` keeps the only `flex: 0 0 var(--shell-topbar-h)` and holds a bottom-aligned tab strip beside the create, history and Git controls.
`.workbench-context-title` precedes the strip, with a capped, shrinkable inline box that ellipsizes long scope names so the rail controls retain their targets.
`.workbench-tabs` uses intrinsic width up to the available rail space; it scrolls horizontally without squeezing the controls or inserting a scrollbar between the tabs and canvas.
The client owns `div.workbench-tab[data-tab-key]` > `a.workbench-tab-link` + `button.workbench-tab-close`; `.is-current` and `aria-current="page"` belong to the committed navigation.
The committed tab fills with the same color as the canvas and covers its top hairline, with two decorative inverse corners inside the rail's clipping box and mirrored for RTL.
The strip reserves corner room at both scroll extremes and between tabs, and the tab scroll margin lets `scrollIntoView` reveal the flares where space allows.
At 480px and below the title cap, rail gaps and flares tighten while coarse-pointer links and close controls retain their separate touch targets.
`[data-tab-pending="true"]` adds a static indicator, and only an uncommitted pending tab gets an accent edge, without changing geometry or accessibility state.
Optional `[data-kind]` colors the draft, assistant and diff glyphs without supplying the tab's label.
The close control reserves its box and appears on hover/focus and for a current non-preview tab; `[data-preview="true"]` dims and italicizes the label, with the close affordance available on coarse/touch pointers too.
`.workbench-tab-overflow` / `#workbench-tabs-overflow` is the rail-end details menu on the shared raised-menu surface.

### Right dock (`#workbench-history`, `#workbench-git`)
History and Source Control BOTH use the `var(--surface-rail)` fill in both themes, without an inline-start divider on History.
Only Source Control keeps the one inline-start hairline, which collapses with its docked width.
The two panels share scroll containment and motion without elevation.
The Git summary card and the selected segmented segment use `var(--surface-raised)` (lifted content off the chrome panel), the segmented track and the sticky branch-search backdrop use the panel's own `var(--surface-rail)` tone.
The composer placeholders, History search placeholder and unselected History kind use the shared opaque `--surface-text-muted` so contrast does not depend on browser placeholder alpha or the current accent; selection retains the full content foreground.
The `closed | open | closing` machine uses `data-panel-state` + `[hidden]` through `../js/hooks/workbench_panel*.js`.
History follows the DOM order (project and status before search), with only `#workbench-history-rows` scrolling and two-line rows separated by spacing rather than rules.
The `.workbench-history-switch[data-history-kind]` pill switch follows `[data-workbench-kind][aria-pressed]` for selection, wraps translated labels inside stable hit areas and animates only the pill under normal motion.
Source Control keeps `.workbench-git-body` as a non-scrolling column with intrinsic-height controls and gives scrolling to the selected `#workbench-git-changes`, `#workbench-git-branches` or `#workbench-git-history` view.
Branch search stays at the top of its view while results scroll.

### Task card chrome (`.task-card*`, consumed by `../lib/evo_dash_web/components/task_card_components.ex`)
The markup renders `div.task-card[data-variant="flat"|"raised"][data-selected]`, an inner `div.task-card-accent` (the accent-bar wrapper), `span.task-card-status` on the status badge and `div.task-card-panel` on every nested detail/options panel; this section is the only place those classes are styled.
`.task-card` is `position: relative` with a `1px solid var(--border-hairline)` border and a `.75rem` radius.
`[data-variant="flat"]` — the default list row — is `var(--surface-canvas)`, `box-shadow: none`, small radius, accent bar `display: none`, no tint.
`[data-variant="raised"]` is `var(--surface-raised)` + `var(--elev-1)` with the accent bar visible.
`.task-card-panel` is RECESSED: `var(--surface-shell)`, hairline border, `.5rem` radius, no shadow.
`.task-card-status` is a compact pill (`border-radius: 9999px`, inline padding only) and declares no size, because `surfaces.css` stays size-free — a size belongs to the markup ladder.
HOVER / SELECTED / FOCUS are three visibly different treatments, and the accent marks ONLY the current object: hover = `var(--surface-hover)` + `var(--border-strong)`; selected (`[data-selected="true"]`, also honouring `[aria-current]`) = `var(--surface-selected)` + an accent hairline border + a 2px accent `::before` inline-start bar (never a full accent flood); `:focus-visible` = a 2px `--color-primary-standalone` outline with offset and no fill change.

## Typography & Density (`density.css`)
`./density.css` is imported from `app.css`'s `@import` block in the FIRST slot — immediately after `@import "tailwindcss" source(none);` (with `./surfaces.css` in the very next slot and `./assistant.css` after it) — and its two declarations are the only density/type source in the bundle: a `@theme` type ladder and a `:root` token set.
That `@theme` is the umbrella's SECOND `@theme` block — the other is `app.css`'s `--color-primary-standalone` — and the only one that sizes type.
The ladder (size / line-height) is `--text-2xs` 0.75rem/1rem (12/16), `--text-xs` 0.8125rem/1.125rem (13/18), `--text-sm` 0.875rem/1.25rem (14/20, the UI default), `--text-base` 0.9375rem/1.5rem (15/24, reading text), `--text-lg` 1.0625rem/1.5rem (17/24), `--text-xl` 1.25rem/1.625rem (20/26), `--text-2xl` 1.5rem/1.875rem (24/30) and `--text-3xl` 1.875rem/2.25rem (30/36), plus `--leading-body: 1.6` for prose blocks.
Because the `@theme` block redefines `--text-*`, Tailwind regenerates `text-2xs`…`text-3xl` (size AND line-height together) and every stock step is gone: `text-2xs` is the new micro size and 12px is the floor for dashboard chrome.
The `:root` height/spacing tokens are `--control-h` 2.5rem / `--control-h-sm` 2rem / `--control-h-xs` 1.5rem, `--row-h-sm` 2.25rem / `--row-h` 2.5rem / `--row-h-tall` 3rem, `--touch-target` 2.75rem, `--card-pad` 1rem / `--card-pad-lg` 1.25rem and `--page-gutter` 1rem / `--page-gutter-sm` 1.25rem / `--page-gutter-lg` 1.5rem.
They are plain custom properties on `:root` rather than `@theme` entries on purpose: components consume them with `var(--…)` (they generate no utilities), and a future runtime density switch retargets them with one attribute selector instead of a second `@theme`.
DaisyUI's control dial is restored to `--size-field: 0.25rem` / `--size-selector: 0.25rem` in BOTH `@plugin "../vendor/daisyui-theme"` blocks (dark and light), so default controls are 40px, `-sm` 32px and `-xs` 24px — exactly `--control-h` / `--control-h-sm` / `--control-h-xs`; `--radius-selector`/`--radius-field`/`--radius-box` stay `0.375rem`/`0.5rem`/`0.75rem`.
Rules for every consumer: no arbitrary font size (`text-[11px]`), only a ladder step or `var(--text-*)`; numeric font weights only 400/500/600 (700 for numbers, badges and `<strong>`); control/row/card/page-gutter dimensions only from the tokens; nothing below 12px.
`workbench.css` and `assistant.css` consume the ladder through `var(--text-*)` (the Assistant composer textarea stays a literal 16px because iOS zooms a focused input below that), `.md-content` keeps its em-based prose ramp (h1 1.5em → h4 1em, base 1.7 line-height), and `app.css` keeps `font-size: inherit !important` for injected diff spans and its `.md-content` em ramp.
Page padding still lives in the markup (`main#main-content` is `px-4 sm:px-5 lg:px-6 pt-4 pb-4`), which is exactly `--page-gutter` / `-sm` / `-lg`; `.workbench-window-page` pads its own document with `.9rem`.
`@media (pointer: coarse)` in `density.css` raises the DaisyUI dial to `--size-field: 0.275rem` / `--size-selector: 0.275rem` (44 / 35.2 / 26.4 px) as UN-LAYERED author CSS, which beats the plugin's `@layer base` tokens regardless of source order.
That media query also sets `font-size: 1rem` on every `input`/`select`/`textarea` (a focused input below 16px makes iOS zoom the page) and a `min-height: var(--touch-target)` floor on the interactive row classes (`.workbench-row`, `.workbench-history-row > a`/`> button`, `.workbench-tab`, `.workbench-icon-button`, `.workbench-project-link`/`-window-link`/`-activity-link`, `.workbench-git-file`/`-branch`, `.workbench-settings-nav-toggle`, `.project-picker-list .workbench-row`, the Assistant quick-action/menu-item/context-button, and the sidebar conversation links `#chat-session-list > a`).
The same block floors every real control at `var(--touch-target)` — `.btn`, `.btn-sm`, `.btn-square`, `.input`, `.input-sm`, `.select`, `.select-sm` — so a compact control no longer stays at the dial's 35px on touch, while `.btn-xs`/`.input-xs`/`.select-xs` are excluded by `:not(…)` because they are inline adornments inside an already-large row and never the sole action.
The `min-height` (not `height`) form is what beats DaisyUI's own `height`, so neither floor needs `!important`.
Those coarse-pointer selector groups are scoped by `:is(#app-layout, #workbench-window-content)` and use `:is(…)` (never `:where(…)`, which would zero the specificity and lose to every `.input`/`.workbench-row` class rule); `#workbench-window-content` covers the Settings popup's own document, which has no `#app-layout`.
The diff/code mono ramp is `var(--text-xs)` (13px) on a fixed 20px line — `.diff-file-header`, `.diff-line`, `.diff-line-content`, `.diff-split-table` and `.diff-split-hunk` — so the review page reads at the metadata step instead of a sub-ladder 12px.
The only deliberate literal pockets are prose/`.md-content` em sizing and the 16px composer textarea (the latter is in `./density.test.cjs`'s allowed-literal set for `assistant.css`).
`./density.test.cjs` pins the import slot, exact ladder and the single density-token declarations, the DaisyUI dial, the coarse-pointer recipe, bounded History and Source Control scrollers, and the shared composer's keyboard and touch contracts.
The markup side of the ladder is NOT converted yet: `lib/evo_dash_web` still carries 56 arbitrary sizes — `text-[11px]` ×32, `text-[10px]` ×20, `text-[15px]` ×4 (Assistant message bodies, system charts, badges) — which the next wave replaces with ladder steps; CSS cannot convert a utility written in a template.
## Constraints
Use existing theme tokens and the standalone accent for focus outlines; keep fill/content roles unchanged.
Font sizes, control/row heights, card padding and page gutters come from `density.css` (`var(--text-*)`, `var(--control-h*)`, `var(--row-h*)`, `var(--card-pad*)`, `var(--page-gutter*)`) — a new literal is a review finding unless it is prose em sizing (`.md-content`), the 16px composer textarea or a renderer-inline dimension.
Numeric font weights are only 400/500/600 (700 for numbers, badges and `<strong>`), and nothing under 12px may be authored.
The workbench right panel (`./workbench.css`, `.workbench-history` = `#workbench-history` + `#workbench-git`) transitions `transform`, `opacity`, `flex-basis`, `padding` and `border-inline-start-width`, ALL with the shared `var(--motion-slow)` / `var(--motion-ease-out)` tokens and never a duration or easing literal (fastest route to a regression is pasting `220ms ease-out` back in).
While docked (`min-width: 1280px`) it also collapses `flex-basis`/padding/the inline border, so the center column glides instead of snapping; the drawer range (`max-width: 1279.98px`) slides `translateX(100%)` instead.
Open and close both animate from the SAME `closed` + `closing` geometry, so the panel's motion is symmetric in both directions.
The open start frame is forced by the JS half (`../js/hooks/workbench_panel_dom.js`), never by CSS: a panel arriving at `display: none` has no before-change style, so the DOM layer un-hides it, flushes one style/layout read and only then flips `data-panel-state` to `open` in the same task.
`[data-panel-state="closed"|"closing"]` is the shared collapsed geometry (`opacity: 0`, `pointer-events: none`, `overflow: hidden`); `closed` is the resolved start value an entrance is laid out at while displayed (the JS half forces that style + layout pass in the same task, so the collapsed frame is never painted) before it becomes `open`.
Those state rules must NEVER declare `display`: `hidden` stays owned by `#workbench-history[hidden], #workbench-git[hidden] { display: none }`, which is what makes the server-rendered closed state flash-free.
`@media (prefers-reduced-motion: reduce)` still drops the panel transition per component (`.workbench-history { transition: none }`) alongside `motion.css`'s global backstop (the hook then closes in the same task).
The right-panel box never scrolls: `#workbench-history`/`#workbench-git` are flex columns with `overflow: hidden`.
History gives `#workbench-history-rows` the sole `flex: 1 1 auto; min-height: 0; overflow-y: auto; overscroll-behavior: contain` scroller; Source Control gives those properties to the selected view inside `.workbench-git-body`.
The heading, history project/filters, Git summary/segmented controls and outer hint/error lines do not flex-grow or shrink; `.workbench-git-body`, `#workbench-history-content` and `#workbench-git-content` pass the remaining height down through shrinkable flex columns.
The dock uses ID selectors for `display: flex`, so the `[hidden]` rule is the only owner of `display: none` and no `.workbench-history` state rule sets `display`.
No smooth scroll on these scrollers; the panel hook owns `data-panel-state` only and does not manage scrolling.
The git diff already models the pattern further down (`.workbench-git-diff-lines { flex: 1; min-height: 0; overflow: auto }` inside the `#workbench-git-diff-host` portal).
Keep Assistant adjustments scoped, normal-flow message actions untouched, and reduced-motion overrides after the caret animation rule.
Never use `transition: all` in `app.css`: the `.input-*` rules enumerate their properties (`min-height`, `padding`, `gap`, `box-shadow`, `border-color`) so `AdaptiveInput`'s inline height writes are not animated.
Do not edit generated static assets or translations.
Inside the shell never add a `height`/`min-height` from a viewport unit: use `.shell-fill` or a `max-height` cap (full contract: § In-shell height contract).
Never add an unlayered `.capsule-stops { flex-wrap: … }` rule (or any other layout override on that class): unlayered CSS beats Tailwind's layered utilities and would override both capsules at once.
The one-line quality-stops contract lives ONLY in the task form's markup (`#mode-speed-capsule .capsule-stops` carries `flex-nowrap`).
The shared model+reasoning capsule's `#<id>-reasoning` group carries `flex-wrap`, so 4-5 advertised efforts wrap inside its fixed `w-72` panel instead of overflowing.
`.capsule-stop` keeps `flex-shrink: 0` + `white-space: nowrap` so a label never breaks mid-word; overflow wrapping is the group's job, never the label's.
The capsule animation rules are unlayered author CSS so they beat DaisyUI's layered `.dropdown-content` animation (`dropdown 0.2s`), and they animate `opacity` + `transform` — never daisyUI's `scale` property — so the plugin's own transition still composes.
The file-picker manual panel (`.file-manual`) is opacity/transform only in BOTH directions: `file-manual-expand` never tweens `max-width` (the wrap's width is static, per motion.css's hard invariant), and `closeManual()` runs the shared `closeAnimated` exit gated on `.file-manual[data-file-manual-state="closing"] .file-manual-input-wrap` before `hidden` is added.
Source ORDER is load-bearing in the capsule panel pair: the `[open]` and `[data-capsule-state="closing"]` rules have equal specificity and the closing rule must stay second.
`@media (prefers-reduced-motion: reduce)` disables the panel open AND close, the view switching and the submenu open AND close with `animation: none !important` (the hook itself also short-circuits its animated close).

## Known Issues — Motion Coverage
The non-Assistant legacy history rule still animates every matching row with a 300ms 8px slide and has higher specificity than `.inspector-message-enter` if a row matches both selectors.
The reduced-motion backstop in `motion.css` bounds every animation/transition duration to `.01ms`, so it neutralizes rather than removes motion definitions and leaves each component's authored timing in place.
Paused-family card styling lives in the markup / `task_card_components` utilities, not in a card CSS class.
`app.css` is the shared Tailwind entry, while `workbench.css` keeps tab/frame geometry, dock/resizer geometry and the Settings-window rules together so their responsive overrides and portal stacking can be validated as one layout contract.

## Responsive breakpoints, touch targets & density
- Breakpoints are Tailwind's, written as `.98` upper bounds so they mesh with the utility classes: `<640px`, `<768px` (`767.98px`), `<1024px` (`1023.98px`), `<1280px` (`1279.98px`), plus one-off `480px`/`420px` (workbench), `max-height: 620px` + `@container assistant (inline-size < 540px)` (assistant), and the capability queries `prefers-reduced-motion`, `pointer: coarse`, `hover: none`/`hover: hover`.
- `workbench.css` owns almost every layout breakpoint (`1023.98px` sidebar drawer/top-bar padding/project touch height, `1279.98px` right-panel drawer + icon/git-row touch heights, `767.98px` settings-nav toggle, `480px`/`420px` narrow pickers); `app.css` has `640px` (shell `--app-vh`, expanded textarea floor), `639px` (chat markdown padding) and `min-width: 1280px` (agents page + commit-graph fill chain).
- Touch sizing has ONE global floor plus per-breakpoint bumps: the `@media (pointer: coarse)` block in `density.css` (the `--touch-target` row list, the `.btn`/`.input`/`.select` control floor, 16px inputs, the `0.275rem` DaisyUI dial), then `var(--touch-target)` rules in `workbench.css` for `#sidebar-mobile-close` and `.workbench-project-link` (`1023.98px`, as `max(var(--touch-target), var(--row-h-tall))` so the taller shortcut row is never collapsed), the right panel's git rows/toggles (`1279.98px`) and `.workbench-settings-nav-toggle` (`767.98px`).
- `.workbench-tab-close`, `.workbench-project-actions` and `.workbench-segmented button` get no extra bump beyond the coarse-pointer floor; `.cg-row` keeps its renderer-inline 44px and `.process-row*` its markup `min-h-10` (markup dimensions, not CSS).
- Density tokens are consumed as `min-height`/`size` values, never re-declared: the BASE `.workbench-row` is the standard clickable row — `var(--row-h)` (40 px) with a `var(--text-sm)` (14 px) label — while the deliberate dense inspector lists override it back to `var(--row-h-sm)` / `var(--text-xs)` (36 px / 13 px): `.workbench-settings-group .workbench-row` (settings category list), `.project-picker-list .workbench-row`, `.workbench-create-menu > .workbench-row` and the Git pane's `.workbench-git-file` / `.workbench-git-branch`; `.workbench-project-link` `var(--row-h-tall)` (a recent project is a title row, name at `var(--text-sm)` weight 500/600), `.workbench-settings-heading` `var(--row-h-tall)`, the query/select/icon/search controls `var(--control-h-sm)` (the inner `.workbench-query input` `var(--control-h-xs)`) and the mobile bumps `var(--touch-target)`.
- Row rhythm keeps accent pills apart: `.workbench-project-list` uses a `.45rem` entry gap between recent-project entries.
- The remaining shared sizing vars are `--shell-topbar-h` (density-derived through `--workbench-topbar-size`), the `--motion-*` vocabulary, `--input-toolbar-budget` (never declared — consumed only as the `4.5rem` fallback), `--app-vh` (JS-set), `--workbench-left-width`/`--workbench-right-width` (16rem/21rem fallbacks), the density tokens above and DaisyUI's `--radius-*`/`--size-*`.
- Padding and gaps stay per-rule (only font size, row/control height, card padding and page gutter were tokenized); `--card-pad`/`--card-pad-lg` exist for the markup and are not yet consumed by any CSS rule.
- `#main-content` padding is Tailwind in `components/layouts.ex` (`px-4 sm:px-5 lg:px-6 pt-4 pb-4`); no CSS file declares it, and the only `.card-body` rules are the xl agents flex/overflow chain (`app.css:847,868,984`) — neither conflicts with per-page utility padding.

## Validation
Run `node --test apps/evo_dash/assets/css/assistant_motion.test.cjs` from the repository root for focused source contracts covering opacity-only motion, visible reduced-motion fallbacks, native-dialog transition guards, history exclusions, instant-scroll invariants, the `motion.css` tokens/keyframes/state rules, the absence of the dead `data-palette-state` / `palette-fade-out` palette-exit vocabulary (the exit is the opacity-only `phx-remove` on `#project-omnibox`), the last-block reduced-motion backstop and the absence of `transition: all` in `app.css`.
Run `node --test apps/evo_dash/assets/css/motion.test.cjs` for the hook-driven surface contracts: the native modal animates `.modal-box` in BOTH directions (opening slide + closing fade, backdrop fade only, never the `<dialog>` itself, exactly one rule per direction) with shared tokens and no literals, the Layer-2 submenu entry AND exit rules use the shared tokens and sit inside the per-component reduced-motion guard, the file-picker entry keyframe declares opacity/transform only (no width/height tween) beside its exit rule, and the legend tooltip fade uses the shared tokens.
Run `node --test apps/evo_dash/assets/css/density.test.cjs` for density, the single-scroller paths in both docks, and shared composer focus/touch contracts.
Run `node --test apps/evo_dash/assets/css/surfaces.test.cjs` for surface tokens and layer boundaries, the inset canvas frame, compact tab geometry and separate committed/pending states, the dock hairline, and the task-card hover/selected/focus treatments.
Run `node --test apps/evo_dash/assets/css/workbench_motion.test.cjs` for the workbench right-panel contracts: the transition-bearing `.workbench-history` rule declares exactly `transform`/`opacity`/`flex-basis`/`padding`/`border-inline-start-width`, each with `var(--motion-slow)` + `var(--motion-ease-out)` and no bare duration or literal easing keyword, the `closed` + `closing` pair is ONE shared geometry rule carrying `opacity`/`transform`/`pointer-events`, `hidden` still owns `display`, the docked and drawer media queries collapse/slide that same family, the per-component reduced-motion guard stays, and the `.workbench-row.is-current` accent-pill tint keeps its `--workbench-selected` background.
This dependency-free Node suite is not part of `mix test` or the existing JS-only globs; include `apps/evo_dash/assets/css/*.test.cjs` in any aggregate asset-test command alongside `apps/evo_dash/assets/js/*.test.cjs apps/evo_dash/assets/js/hooks/*.test.cjs`.
Run `mix tailwind evo_dash` from the repository root to compile the CSS and `git diff --check` for whitespace checks.
In Chromium, switch projects and routes and toggle the theme at normal and reduced motion; the canvas should update without a snapshot fade or morph, while local controls still move only under their own motion rules.
For browser review, check `/assistant` in light/dark themes at narrow and desktop widths, pending/running/restored/ended turns, long URLs, code/tables, nested lists, RTL quotes, multiline composer, keyboard focus and reduced motion.
Verify the indicator appears only while execution is pending/running, labels remain legible, restored history never enters, and streamed updates do not move the composer or animate scrolling.
Build and source assertions do not substitute for browser visual validation.

## Routing Table
There are no child directories.
`./density.css` is the ONE density + typography token layer, imported by `./app.css` FIRST (directly after `@import "tailwindcss" source(none);`, with `./surfaces.css` immediately after it): the `@theme` type ladder (`text-2xs`…`text-3xl` + `--leading-body`), the `:root` height/spacing tokens and the `@media (pointer: coarse)` recipe; its consumer rules + the DaisyUI dial live in § Typography & Density, and `./density.test.cjs` pins it.
`./surfaces.css` is the ONE surface/elevation token layer, imported between `./density.css` and `./assistant.css`: the three-layer `--surface-*` set, the overlay-only `--elev-*` shadows, the `--border-*` pair, `--radius-tab` and the `.task-card*` consumers; § Surface & elevation system documents it and `./surfaces.test.cjs` pins it.
`./motion.css` is imported by `./app.css` and owns the shared motion foundation (tokens, keyframes, disclosure/panel/window/dialog state rules, the `JS.hide` exit helpers and the global reduced-motion backstop).
`./assistant.css` owns the Assistant layout and the common Assistant/New Task composer and inline options contracts.
`./workbench.css` is imported by `./app.css` and owns the workbench shell (the single-definition tab strip, sidebars, the docked right panel's state/animation + scroll-containment rules, Git pane, dialogs); its state machine lives in `../js/hooks/workbench_panel.js`.
`./*.test.cjs` are dependency-free `node --test` source contracts over these files (`assistant_motion`, `motion`, `workbench_motion`, `layout_contract`, `settings_window_overflow`, `density`, `surfaces`), never part of `mix test`.
