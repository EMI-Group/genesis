// AdaptiveInput hook: mounted on the <textarea class="input-prompt"> element.
//
// Responsibilities: AUTOGROW + CLIENT-SIDE LAYOUT.
//
// AUTOGROW — measure the textarea's content height (scrollHeight) and set
// its height so the box grows smoothly with its content. In compact layout
// the CSS caps the box at ~8 lines (max-height: calc(1.6em * 8)); the height
// trigger in applyLayout flips the layout to expanded the INSTANT the natural
// content height would exceed that cap (synchronously, before paint), so the
// compact box NEVER shows an internal scrollbar while growing — overflow-y:
// auto on the compact textarea is a safety net only. In expanded layout the
// box grows freely and the page scrolls instead: the expanded card/textarea
// forbid flex-shrink (flex: 1 0 auto in css/app.css), so the flex chain can
// never compress the box below its content and produce an internal scrollbar.
//
// LAYOUT — the compact/expanded layout decision is CLIENT-DRIVEN: this hook
// computes `data-layout` on the closest `.input-layout` ancestor from the
// textarea value AND its measured content height, on every input and on
// mount/updates. The value thresholds (>600 code points or >16 lines →
// expanded) mirror EvoDashWeb.TaskFormComponents.layout_for/1 so the SSR
// seed and the client converge; the height threshold (natural content height
// exceeds the compact max-height cap → expanded) is client-only — the server
// has no knowledge of the rendered text metrics. The flip back to compact
// uses ~1 line-height of hysteresis (see applyLayout) so the layout does not
// flicker at the boundary while deleting. The server only seeds the initial
// `data-layout` attribute for first paint — the old `task_prompt_change`
// phx-change event (debounced) that used to drive it server-side has been
// removed. The hook re-asserts the client-computed layout not only while
// typing/on updates, but also whenever the server re-seeds the `data-layout`
// attribute from its (possibly stale) `@task_prompt` — e.g. after toggling
// the mode/model selects — via a MutationObserver on the `.input-layout`
// element. Because the textarea sits inside phx-update="ignore", morphdom
// skips it and `updated()` never fires on those re-renders; the observer
// catches the re-seed and flips the layout back if needed. applyLayout writes
// the attribute only when the computed value differs from the current DOM
// value (an equality guard), so the observer converges with no loop and no
// per-keystroke server event. This hook does not position any floating
// controls panel (the old --input-layout-center logic is gone — Layout B's
// controls row is in-flow below the textarea).
const AdaptiveInput = {
  mounted() {
    this._inputHandler = () => this._apply();

    this.el.addEventListener("input", this._inputHandler);

    // Watch the layout container for server re-seeds: any control that
    // triggers a server event (mode/model select, etc.) re-renders the form
    // and re-seeds data-layout from the possibly-stale @task_prompt. The
    // textarea is inside phx-update="ignore", so morphdom skips it and
    // updated() never fires — the observer catches the re-seed and re-applies
    // the client-computed layout immediately. applyLayout writes the
    // attribute only when the computed value differs from the current DOM
    // value (an equality guard), so re-asserting through the observer
    // converges without a loop.
    const layoutEl = this.el.closest('.input-layout');
    if (layoutEl) {
      this._layoutObserver = new MutationObserver(() => this._apply());
      this._layoutObserver.observe(layoutEl, {
        attributes: true,
        attributeFilter: ['data-layout']
      });
    }

    // Defer the initial measurement until after the browser has laid out the
    // element so scrollHeight/lineHeight are accurate. StatePersistence may
    // restore a saved prompt into the textarea on mount, so measure even
    // before any user input.
    requestAnimationFrame(() => this._apply());

    // Server-triggered clear after a successful task launch: the textarea sits
    // inside phx-update="ignore", so morphdom never empties it — the server
    // only resets @task_prompt (which re-seeds data-layout="compact"). This
    // handler empties the visible value, re-asserts autogrow + the layout
    // (converges: applyLayout only writes the attribute when the computed
    // value differs, so the MutationObserver settles in one step), and drops
    // the persisted draft so a reload can't resurrect the submitted prompt.
    this.handleEvent("clear_prompt", () => {
      this.el.value = '';
      this._apply();
      this._clearPersistedDraft();
    });
  },

  updated() {
    // The textarea value may have changed via LiveView morphdom or
    // StatePersistence restore — re-measure and re-derive the layout.
    requestAnimationFrame(() => this._apply());
  },

  destroyed() {
    this.el.removeEventListener("input", this._inputHandler);
    if (this._layoutObserver) this._layoutObserver.disconnect();
  },

  _apply() {
    // Measure first, then decide the layout from the measurement. The height
    // trigger in applyLayout needs the neutralized natural content height
    // (measureAndApply temporarily strips max-height/flex so scrollHeight
    // reflects the content, not the layout), and both steps run synchronously
    // inside the input handler / observer callback — no paint happens between
    // the layout flip and the height write, so the compact box can never
    // render with an internal scrollbar at the flip moment.
    this.measureAndApply();
    this.applyLayout();
  },

  // Compute the compact/expanded layout from the input value AND the measured
  // natural content height. The value thresholds mirror the server's
  // layout_for/1 (>600 code points or >16 lines → expanded) so the SSR-seeded
  // attribute and the client converge; the height threshold is client-only:
  // compact flips to expanded the instant the natural height would exceed the
  // compact max-height cap (the box would otherwise start scrolling
  // internally — the dead zone this trigger eliminates). The reverse flip
  // (expanded → compact) uses ~1 line-height of hysteresis: the height must
  // drop below the cap by at least a full line (AND the char/line thresholds
  // must be under) before leaving expanded, so the layout cannot flicker at
  // the boundary while deleting. The server only seeds the initial
  // data-layout attribute; from then on the DOM value + measurement are the
  // source of truth (no per-keystroke server round-trip). Array.from counts
  // code points — an acceptable stand-in for the server's grapheme count.
  applyLayout() {
    const layoutEl = this.el.closest('.input-layout');
    if (!layoutEl) return;
    const value = this.el.value || '';
    const charCount = Array.from(value).length;
    const lineCount = value.split('\n').length;
    // Cap + line-height come from the measurement. measureAndApply caches the
    // compact cap — the only mode where the CSS max-height resolves to px;
    // lineHeight * 8 is the fallback for a cold cache (e.g. first measurement
    // in an SSR-seeded expanded state). With box-sizing: border-box and a
    // zero border, the computed maxHeight and the neutralized scrollHeight
    // (content + padding) compare 1:1, so naturalHeight > cap fires exactly
    // when the box would need an internal scrollbar.
    const lineHeight = this._lineHeight || 0;
    const cap = this._compactMaxHeight || (lineHeight > 0 ? lineHeight * 8 : 0);
    const naturalHeight = this._measuredScrollHeight || 0;
    const capKnown = cap > 0;
    const exceedsChars = charCount > 600;
    const exceedsLines = lineCount > 16;
    // Flip up at height > cap; the dead band (cap - lineHeight, cap] keeps
    // whichever layout is current, so the flip-down needs a full line of
    // retreat below the cap.
    const exceedsCap = capKnown && naturalHeight > cap;
    const underHysteresisFloor =
      capKnown && lineHeight > 0 && naturalHeight <= cap - lineHeight;
    const currentLayout = layoutEl.dataset.layout;
    let expanded;
    if (currentLayout === 'expanded') {
      // Leave expanded only once the content dropped ~1 line below the compact
      // cap AND the char/line thresholds are under — hysteresis against
      // boundary flicker while deleting.
      expanded = exceedsChars || exceedsLines || !underHysteresisFloor;
    } else {
      // Compact: flip the instant the natural height would exceed the cap —
      // the compact box never renders with an internal scrollbar.
      expanded = exceedsChars || exceedsLines || exceedsCap;
    }
    const layout = expanded ? 'expanded' : 'compact';
    // Equality guard: writing the attribute even when it already equals the
    // computed value would re-trigger the MutationObserver and loop forever.
    if (layoutEl.dataset.layout !== layout) layoutEl.dataset.layout = layout;
  },

  measureAndApply() {
    const ta = this.el;

    // Read the layout metrics BEFORE neutralizing: the compact max-height cap
    // only resolves to px while the layout is compact (in expanded mode the
    // computed max-height is "none"). Cache the last compact value — the
    // layout spends most of its life in compact mode while typing, so the
    // cache is warm; applyLayout's lineHeight * 8 fallback covers a cold
    // cache. Note Tailwind preflight sets box-sizing: border-box, so the
    // computed maxHeight is a border-box cap; the textarea border is 0
    // (border: none), so the neutralized scrollHeight (content + padding)
    // compares 1:1 with it — scrollHeight > cap fires exactly when the box
    // would need an internal scrollbar.
    const cs = getComputedStyle(ta);
    const computedMaxHeight = parseFloat(cs.maxHeight);
    if (!Number.isNaN(computedMaxHeight)) {
      this._compactMaxHeight = computedMaxHeight;
    }
    this._lineHeight = parseFloat(cs.lineHeight) || 0;

    // Temporarily neutralize flex stretching and min/max-height while
    // measuring: in expanded mode the flex layout stretches the textarea, and
    // the CSS min-height would otherwise floor scrollHeight — both would hide
    // the real content height. (Kept from the pre-redesign hook; harmless in
    // compact mode.)
    const prevFlex = ta.style.flex;
    const prevMinHeight = ta.style.minHeight;
    const prevMaxHeight = ta.style.maxHeight;
    ta.style.flex = "0 0 auto";
    ta.style.minHeight = "0";
    ta.style.maxHeight = "none";
    ta.style.height = "auto";
    const scrollHeight = ta.scrollHeight;
    // Stash the natural height for applyLayout's height trigger (the layout
    // decision must use the same measurement that drives the height write).
    this._measuredScrollHeight = scrollHeight;
    // ALWAYS write the explicit height back — never leave the inline style at
    // "auto". A "skip the write when the value is unchanged" guard here (added
    // in ac0104ee alongside the data-layout equality guard) was a regression:
    // whenever the measured scrollHeight equaled the previous inline height
    // (e.g. while typing on the same line), the write was skipped and the
    // inline style stayed "auto", so the CSS min-height collapsed the box to
    // 120px — content overflowed (scrollbar) — and the next keystroke
    // restored the taller height: the box oscillated between the two states
    // on every keystroke. Height is not observed by any MutationObserver
    // (only data-layout is), so an unconditional write cannot loop, and
    // writing a value identical to the current one is a rendering no-op.
    ta.style.height = scrollHeight + "px";
    ta.style.flex = prevFlex;
    ta.style.minHeight = prevMinHeight;
    ta.style.maxHeight = prevMaxHeight;
  },

  // Clears only the draft prompt inside the persisted state blob so a reload
  // cannot resurrect a submitted prompt while the rest of the form state
  // (project, mode, model, advanced fields) survives. Mirrors the
  // StatePersistence hook's restore gate (mounted() only restores a truthy
  // state.task_prompt), so '' is equivalent to removing the field.
  _clearPersistedDraft() {
    try {
      const existing = JSON.parse(sessionStorage.getItem('dashboard_state') || '{}');
      existing.task_prompt = '';
      sessionStorage.setItem('dashboard_state', JSON.stringify(existing));
    } catch (e) {}
  }
};

export default AdaptiveInput;
