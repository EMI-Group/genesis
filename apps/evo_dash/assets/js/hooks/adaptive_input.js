// AdaptiveInput hook: mounted on the <textarea class="input-prompt"> element.
//
// Single responsibility: AUTOGROW — measure the textarea's content height
// (scrollHeight) and set its height so the box grows smoothly with its
// content (up to the CSS max-height, beyond which the textarea scrolls
// internally).
//
// The compact/expanded layout decision is now SERVER-DRIVEN: the server
// computes `data-layout` on the closest `.input-layout` ancestor from the
// prompt length (EvoDashWeb.TaskFormComponents.layout_for/1 — threshold
// @short_objective_threshold chars or 8+ lines) and the user's typing
// updates it via the `task_prompt_change` phx-change event (debounced).
// This hook no longer toggles data-layout and no longer positions any
// floating controls panel (the old --input-layout-center logic is gone —
// Layout B's controls row is in-flow below the textarea).
const AdaptiveInput = {
  mounted() {
    this._inputHandler = () => this.measureAndApply();

    this.el.addEventListener("input", this._inputHandler);

    // Defer the initial measurement until after the browser has laid out the
    // element so scrollHeight/lineHeight are accurate. StatePersistence may
    // restore a saved prompt into the textarea on mount, so measure even
    // before any user input.
    requestAnimationFrame(() => this.measureAndApply());
  },

  updated() {
    // The textarea value may have changed via LiveView morphdom or
    // StatePersistence restore — re-measure.
    requestAnimationFrame(() => this.measureAndApply());
  },

  destroyed() {
    this.el.removeEventListener("input", this._inputHandler);
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
    ta.style.flex = "0 0 auto";
    ta.style.minHeight = "0";
    ta.style.maxHeight = "none";
    ta.style.height = "auto";
    const scrollHeight = ta.scrollHeight;
    ta.style.height = scrollHeight + "px";
    ta.style.flex = prevFlex;
    ta.style.minHeight = prevMinHeight;
    ta.style.maxHeight = prevMaxHeight;
  }
};

export default AdaptiveInput;
