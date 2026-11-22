# Dashboard CSS

## Intent
`app.css` is the single Tailwind CSS 4 entry point for shared dashboard styling and page-specific adjustments.

## API Surface
The file contains DaisyUI light/dark themes, accent fill/standalone role tokens, shared component styles, Markdown, responsive input layout, and a final Genesis Assistant chat section.
The Assistant section scopes reading rhythm, quiet headings/quotes, code sizing and narrow-screen spacing to `#chat-messages .md-content`, and styles the column `.help-composer` (textarea row above a `.help-composer-controls` bar holding the picker left and Send/Stop right) plus `.help-caret` without changing layout or hook contracts.
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
`--shell-topbar-h` (3.5rem, declared once on `#app-layout` in `./workbench.css`) is the top bar's only definition and drives `.workbench-top { flex: 0 0 var(--shell-topbar-h) }`; a `simple_nav` page renders no bar and simply gets the extra content height.
Viewport-anchored top-layer surfaces keep viewport units: the `dialog.modal .modal-box` caps, `.project-palette-overlay` (`position: fixed`), `.workbench-window`, `#workbench-settings-frame` and `.workbench-window-page` (the settings window's own iframe document) size themselves against the viewport, never against the content box.
The Settings window header's "Settings server" picker (`.workbench-settings-server-picker` in `./workbench.css`) is a shrinkable flex row — `min-width: 0` plus a content-sized shrinking select, never a percentage-width (`w-full`) select in a shrink-to-fit line, which overflowed the popup document — and `./settings_window_overflow.test.cjs` pins it.
`.agents-page-layout` fills `#main-content` at xl+ (`height: 100%`, `.shell-fill` in the markup) instead of subtracting the chrome from a viewport unit.
The expanded `.input-card` is a size container (`container-type: size`, expanded layout only — the compact card's height is content-derived and would collapse), so the textarea floor is `min(10 lines, 100cqh - var(--input-toolbar-budget, 4.5rem))` and 6 lines on mobile.
`100cqh` measures the card's content box, so that floor tracks the top bar, the sidebar, the page padding and the `--app-vh` keyboard override automatically, and `--input-toolbar-budget` (4.5rem ≈ the 3rem toolbar row plus slack, so the floor can only under-fill) is its single tuning point.

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
View transitions — `./view_transitions.css` (the LAST `@import`) owns the `page` / `project-swap` pseudo-element fades; see § View transitions below.
Shared list entry — `class="motion-list-enter"` on new rows, toggled by the `ListEnter` hook from `data-list-enter-scope` + per-row `data-list-enter-key`; see § `.motion-list-enter` below.
The LAST rule in `motion.css` is the global `prefers-reduced-motion` backstop (`animation-duration`, `animation-iteration-count`, `transition-duration`, `transition-delay` and `scroll-behavior: auto`, all `!important`, on `*, *::before, *::after`); nothing may follow it, and per-component guards elsewhere stay as harmless redundancy.

### `.motion-list-enter` (the one motion class that lives in `app.css`)
`.motion-list-enter` is the LAST rule in `app.css` and its only consumer is the `ListEnter` hook (`../js/hooks/list_enter.js`), which toggles that single class on newly inserted rows.
Its animation is `motion-slide-in` with `--motion-base` / `--motion-ease-out` from `motion.css`, so it defines no keyframes of its own and `motion.css`'s global backstop already disables it under reduced motion.
The class must stay in `app.css`: a `hooks/*.js` class toggle cannot import the motion vocabulary itself, so deleting it as "unused CSS" breaks the hook.

## View transitions (`view_transitions.css`)
`./view_transitions.css` is imported LAST from `app.css`'s `@import` block — immediately after `./motion.css` and still before the `@source` lines — and owns the browser View Transitions API motion.
It styles `::view-transition-old` / `::view-transition-new` / `::view-transition-group` for the three named transitions `root`, `page` and `project-swap`.
Every fade REUSES `motion.css`'s `motion-fade-out` (old) and `motion-fade-in` (new) keyframes with `--motion-base`, `--motion-ease-in` and `--motion-ease-out`; the file defines no keyframes and no literal durations.
The `::view-transition-group(...)` rules only borrow `animation-duration: var(--motion-base)`, keeping the UA's own size/position morph keyframes so the morph matches the fade instead of outliving it.
Three sources opt in: a cross-document page load (`<meta name="view-transition" content="same-origin">` in `../lib/evo_dash_web/components/layouts/root.html.heex`), the theme switch in that same file's inline script (which needs only the root pair), and the per-PATCH cross-fade in `../js/app.js`.
The element names are declared from CSS ONLY, so no markup had to change: `#main-content { view-transition-name: page }` covers BOTH render branches in `../lib/evo_dash_web/components/layouts.ex` (the app shell and the workbench window page), and `#dashboard-root { view-transition-name: project-swap }` covers `../lib/evo_dash_web/live/projects_live.ex`.
`#dashboard-root` is nested inside `#main-content`, and a named element is excluded from its ancestor's snapshot, so the shell fade and the project-body fade stay independent instead of double-exposing the same pixels.
A duplicate name (the workbench's cloned `#main-content` in `../js/hooks/workbench_project_preview.js`, or both render branches live at once) makes the browser SKIP that name for that transition — it never errors, and the root fade still runs.
Never put `view-transition-name` on a fast-changing element: naming an element snapshots its whole subtree twice per transition.
A `@media (prefers-reduced-motion: reduce)` block sets `animation: none` on all six old/new pseudo-elements and the three groups, because `::view-transition-*` lives in the view-transition pseudo tree and is untouched by `motion.css`'s `*, *::before, *::after` backstop.
The per-patch cross-fade is gated on NAVIGATION, never on diffs: `app.js` starts `document.startViewTransition` on `phx:page-loading-start` with `detail.kind === "patch"` and resolves its update callback on `phx:page-loading-stop` (LiveView dispatches that stop only AFTER the patch reply has been morphed into the DOM), single-flighted through `transition.finished` and bounded by a 600ms fallback timer for a patch that falls back to a full navigation.
Stream ticks, form submits and `phx-click` never dispatch that page-loading event pair, so they are never snapshotted.
The `dom: {onDocumentPatch}` route was verified and rejected (reasoning lives in `app.js`): the patch diff reaches it while the pending link is still set, so `update()` only QUEUES it and the DOM change lands outside the callback — and that callback also sees every event-driven diff.
A server-initiated `push_patch` dispatches no page-loading events, so it still snaps.

## Constraints
Use existing theme tokens and the standalone accent for focus outlines; keep fill/content roles unchanged.
The workbench right panel (`./workbench.css`, `.workbench-history` = `#workbench-history` + `#workbench-git`) transitions `transform`, `opacity`, `flex-basis`, `padding` and `border-inline-start-width`, ALL with the shared `var(--motion-slow)` / `var(--motion-ease-out)` tokens and never a duration or easing literal (fastest route to a regression is pasting `220ms ease-out` back in).
While docked (`min-width: 1280px`) it also collapses `flex-basis`/padding/the inline border, so the center column glides instead of snapping; the drawer range (`max-width: 1279.98px`) slides `translateX(100%)` instead.
Open and close both animate from the SAME `closed` + `closing` geometry, so the panel's motion is symmetric in both directions.
The open start frame is forced by the JS half (`../js/hooks/workbench_panel_dom.js`), never by CSS: a panel arriving at `display: none` has no before-change style, so the DOM layer un-hides it, flushes one style/layout read and only then flips `data-panel-state` to `open` in the same task.
`[data-panel-state="closed"|"closing"]` is the shared collapsed geometry (`opacity: 0`, `pointer-events: none`, `overflow: hidden`); `closed` is the resolved start value an entrance is laid out at while displayed (the JS half forces that style + layout pass in the same task, so the collapsed frame is never painted) before it becomes `open`.
Those state rules must NEVER declare `display`: `hidden` stays owned by `#workbench-history[hidden], #workbench-git[hidden] { display: none }`, which is what makes the server-rendered closed state flash-free.
`@media (prefers-reduced-motion: reduce)` still drops the panel transition per component (`.workbench-history { transition: none }`) alongside `motion.css`'s global backstop (the hook then closes in the same task).
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
`./workbench.css` still styles `.workbench-dialog`, but nothing selects it any more (no `.ex`/`.heex`, no JS hook, no test) — the workbench windows are `dialog.workbench-window`; that block is dead weight kept only because `workbench.css` has a different owner.

## Validation
Run `node --test apps/evo_dash/assets/css/assistant_motion.test.cjs` from the repository root for focused source contracts covering opacity-only motion, visible reduced-motion fallbacks, native-dialog transition guards, history exclusions, instant-scroll invariants, the `motion.css` tokens/keyframes/state rules, the absence of the dead `data-palette-state` / `palette-fade-out` palette-exit vocabulary (the exit is the opacity-only `phx-remove` on `#project-omnibox`), the last-block reduced-motion backstop and the absence of `transition: all` in `app.css`.
Run `node --test apps/evo_dash/assets/css/motion.test.cjs` for the hook-driven surface contracts: the native modal animates `.modal-box` in BOTH directions (opening slide + closing fade, backdrop fade only, never the `<dialog>` itself, exactly one rule per direction) with shared tokens and no literals, the Layer-2 submenu entry AND exit rules use the shared tokens and sit inside the per-component reduced-motion guard, the file-picker entry keyframe declares opacity/transform only (no width/height tween) beside its exit rule, and the legend tooltip fade uses the shared tokens.
Run `node --test apps/evo_dash/assets/css/workbench_motion.test.cjs` for the workbench right-panel contracts: the transition-bearing `.workbench-history` rule declares exactly `transform`/`opacity`/`flex-basis`/`padding`/`border-inline-start-width`, each with `var(--motion-slow)` + `var(--motion-ease-out)` and no bare duration or literal easing keyword, the `closed` + `closing` pair is ONE shared geometry rule carrying `opacity`/`transform`/`pointer-events`, `hidden` still owns `display`, the docked and drawer media queries collapse/slide that same family, and the per-component reduced-motion guard stays.
This dependency-free Node suite is not part of `mix test` or the existing JS-only globs; include `apps/evo_dash/assets/css/*.test.cjs` in any aggregate asset-test command alongside `apps/evo_dash/assets/js/*.test.cjs apps/evo_dash/assets/js/hooks/*.test.cjs`.
Run `mix tailwind evo_dash` from the repository root to compile the CSS and `git diff --check` for whitespace checks.
View transitions need browser review, not source assertions: open `/projects`, switch projects and patch-navigate (e.g. `/projects` → `/tasks` on a patched link) in a Chromium-based browser, then repeat under `prefers-reduced-motion: reduce` to confirm the fades disappear and the patch still lands.
For browser review, check `/assistant` in light/dark themes at narrow and desktop widths, pending/running/restored/ended turns, long URLs, code/tables, nested lists, RTL quotes, multiline composer, keyboard focus and reduced motion.
Verify the indicator appears only while execution is pending/running, labels remain legible, restored history never enters, and streamed updates do not move the composer or animate scrolling.
Build and source assertions do not substitute for browser visual validation.

## Routing Table
There are no child directories.
`./motion.css` is imported by `./app.css` and owns the shared motion foundation (tokens, keyframes, disclosure/panel/window/dialog state rules, the `JS.hide` exit helpers and the global reduced-motion backstop).
`./view_transitions.css` is imported by `./app.css` (last, after `./motion.css`) and owns the View Transitions pseudo-element fades plus the `page` / `project-swap` element names; its navigation gate lives in `../js/app.js`.
`./workbench.css` is imported by `./app.css` and owns the workbench shell (tabs, sidebars, the right panel's state/animation rules, Git pane, dialogs); its state machine lives in `../js/hooks/workbench_panel.js`.
