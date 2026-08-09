// AdaptiveInput hook: mounted on the <textarea class="input-prompt"> element.
//
// Responsibilities: AUTOGROW + CLIENT-SIDE LAYOUT.
//
// AUTOGROW — measure the textarea's content height (scrollHeight) and set
// its height so the box grows smoothly with its content (up to the CSS
// max-height, beyond which the textarea scrolls internally).
//
// LAYOUT — the compact/expanded layout decision is CLIENT-DRIVEN: this hook
// computes `data-layout` on the closest `.input-layout` ancestor from the
// textarea value, mirroring EvoDashWeb.TaskFormComponents.layout_for/1
// (>600 code points or >16 lines → expanded), on every input and on mount/
// updates. The server only seeds the initial `data-layout` attribute for
// first paint — the old `task_prompt_change` phx-change event (debounced)
// that used to drive it server-side has been removed. The hook re-asserts
// the client-computed layout not only while typing/on updates, but also
// whenever the server re-seeds the `data-layout` attribute from its (possibly
// stale) `@task_prompt` — e.g. after toggling the mode/model selects — via a
// MutationObserver on the `.input-layout` element. Because the textarea sits
// inside phx-update="ignore", morphdom skips it and `updated()` never fires
// on those re-renders; the observer catches the re-seed and flips the layout
// back if needed. applyLayout writes the attribute only when the computed
// value differs from the current DOM value (an equality guard), so the
// observer converges with no loop and no per-keystroke server event. This
// hook does not position any floating controls panel (the
// old --input-layout-center logic is gone — Layout B's controls row is
// in-flow below the textarea).
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
    this.applyLayout();
    this.measureAndApply();
  },

  // Compute the compact/expanded layout from the input value, mirroring the
  // server's layout_for/1 thresholds (>600 code points or >16 lines →
  // expanded). The server only seeds the initial data-layout attribute; from
  // then on the DOM value is the source of truth (no per-keystroke server
  // round-trip). Array.from counts code points — an acceptable stand-in for
  // the server's grapheme count.
  applyLayout() {
    const layoutEl = this.el.closest('.input-layout');
    if (!layoutEl) return;
    const value = this.el.value || '';
    const charCount = Array.from(value).length;
    const lineCount = value.split('\n').length;
    const layout = (charCount > 600 || lineCount > 16) ? 'expanded' : 'compact';
    // Equality guard: writing the attribute even when it already equals the
    // computed value would re-trigger the MutationObserver and loop forever.
    if (layoutEl.dataset.layout !== layout) layoutEl.dataset.layout = layout;
  },

  measureAndApply() {
    const ta = this.el;

    // Temporarily neutralize flex stretching and min/max-height while
    // measuring: in expanded mode the flex layout stretches the textarea, and
    // the CSS min-height would otherwise floor scrollHeight — both would hide
    // the real content height. (Kept from the pre-redesign hook; harmless in
    // compact mode.)
    const prevFlex = ta.style.flex;
    const prevMinHeight = ta.style.minHeight;
    const prevMaxHeight = ta.style.maxHeight;
    const prevHeight = ta.style.height;
    ta.style.flex = "0 0 auto";
    ta.style.minHeight = "0";
    ta.style.maxHeight = "none";
    ta.style.height = "auto";
    const scrollHeight = ta.scrollHeight;
    // Only write when the height actually changed (steady-state repeated
    // calls then write nothing — hygiene, since height is not observed).
    if (scrollHeight + "px" !== prevHeight) ta.style.height = scrollHeight + "px";
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
