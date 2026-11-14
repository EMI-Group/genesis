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
A `capsule-sub-in` entrance animates `details.capsule-sub[open] > .capsule-list`, the only animation the nested Layer-2 submenu gets (its toggle stays native).
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

## Constraints
Use existing theme tokens and the standalone accent for focus outlines; keep fill/content roles unchanged.
Keep Assistant adjustments scoped, normal-flow message actions untouched, and reduced-motion overrides after the caret animation rule.
Do not edit generated static assets or translations.
Never add an unlayered `.capsule-stops { flex-wrap: … }` rule (or any other layout override on that class): unlayered CSS beats Tailwind's layered utilities and would override both capsules at once.
The one-line quality-stops contract lives ONLY in the task form's markup (`#mode-speed-capsule .capsule-stops` carries `flex-nowrap`).
The shared model+reasoning capsule's `#<id>-reasoning` group carries `flex-wrap`, so 4-5 advertised efforts wrap inside its fixed `w-72` panel instead of overflowing.
`.capsule-stop` keeps `flex-shrink: 0` + `white-space: nowrap` so a label never breaks mid-word; overflow wrapping is the group's job, never the label's.
The capsule animation rules are unlayered author CSS so they beat DaisyUI's layered `.dropdown-content` animation (`dropdown 0.2s`), and they animate `opacity` + `transform` — never daisyUI's `scale` property — so the plugin's own transition still composes.
Source ORDER is load-bearing in the capsule panel pair: the `[open]` and `[data-capsule-state="closing"]` rules have equal specificity and the closing rule must stay second.
`@media (prefers-reduced-motion: reduce)` disables the panel open AND close, the view switching and the submenu with `animation: none !important` (the hook itself also short-circuits its animated close).

## Known Issues — Motion Coverage
The reduced-motion guards are selector-specific rather than global, and `html` still requests smooth scrolling under reduced motion although both transcript scrollers explicitly stay instant.
The broad reduced-motion block precedes the equal-specificity `.no-project-overlay` and `.dashboard-topbar[data-no-project="true"]` animation declarations, so those later declarations override its `animation: none`.
`.task-card-active`, `.node-switch-fade`, the project-palette entrances and `.file-manual-input-wrap` have no matching reduced-motion animation override.
The non-Assistant legacy history rule still animates every matching row with a 300ms 8px slide and has higher specificity than `.inspector-message-enter` if a row matches both selectors.

## Validation
Run `node --test apps/evo_dash/assets/css/assistant_motion.test.cjs` from the repository root for focused source contracts covering opacity-only motion, visible reduced-motion fallbacks, native-dialog transition guards, history exclusions and instant-scroll invariants.
This dependency-free Node suite is not part of `mix test` or the existing JS-only globs; include `apps/evo_dash/assets/css/*.test.cjs` in any aggregate asset-test command alongside `apps/evo_dash/assets/js/*.test.cjs apps/evo_dash/assets/js/hooks/*.test.cjs`.
Run `mix tailwind evo_dash` from the repository root to compile the CSS and `git diff --check` for whitespace checks.
For browser review, check `/assistant` in light/dark themes at narrow and desktop widths, pending/running/restored/ended turns, long URLs, code/tables, nested lists, RTL quotes, multiline composer, keyboard focus and reduced motion.
Verify the indicator appears only while execution is pending/running, labels remain legible, restored history never enters, and streamed updates do not move the composer or animate scrolling.
Build and source assertions do not substitute for browser visual validation.

## Routing Table
There are no child directories or separate CSS modules.
