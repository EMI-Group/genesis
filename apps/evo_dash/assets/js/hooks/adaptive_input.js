// AdaptiveInput hook: mounted on the <textarea class="input-prompt"> element.
// Measures the textarea content and toggles the `data-layout` attribute on the
// closest `.input-layout` ancestor between "compact" (few lines) and "expanded"
// (many lines). The CSS reacts to this attribute to morph the layout smoothly
// between Layout A (inline controls) and Layout B (floating controls panel).
//
// The threshold is ~8 lines of content: if the textarea's scrollHeight exceeds
// lineHeight * 8, we switch to "expanded".
const AdaptiveInput = {
  mounted() {
    this.layoutEl = this.el.closest(".input-layout");
    this._inputHandler = () => this.measureAndApply();

    // Defer the initial measurement until after the browser has laid out the
    // element so scrollHeight/lineHeight are accurate.
    requestAnimationFrame(() => this.measureAndApply());

    this.el.addEventListener("input", this._inputHandler);
  },

  updated() {
    // The textarea value may have changed via LiveView morphdom or
    // StatePersistence restore — re-measure and re-apply the layout.
    requestAnimationFrame(() => this.measureAndApply());
  },

  destroyed() {
    this.el.removeEventListener("input", this._inputHandler);
  },

  measureAndApply() {
    const ta = this.el;
    if (!this.layoutEl) return;

    const computed = window.getComputedStyle(ta);
    const lineHeight = parseFloat(computed.lineHeight) || 1.5 * parseFloat(computed.fontSize) || 24;

    // Threshold: ~8 lines of content.
    const threshold = lineHeight * 8;

    // Reset height to auto momentarily so scrollHeight reflects the true
    // content height (not a previously-clamped value).
    const prevHeight = ta.style.height;
    ta.style.height = "auto";
    const scrollHeight = ta.scrollHeight;
    ta.style.height = prevHeight;

    const layout = scrollHeight > threshold ? "expanded" : "compact";

    if (this.layoutEl.getAttribute("data-layout") !== layout) {
      this.layoutEl.setAttribute("data-layout", layout);
    }
  }
};

export default AdaptiveInput;
