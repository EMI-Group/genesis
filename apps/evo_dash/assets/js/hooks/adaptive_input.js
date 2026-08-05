// AdaptiveInput hook: mounted on the <textarea class="input-prompt"> element.
//
// Two responsibilities:
//   1. Autogrow — sets textarea.style.height from scrollHeight so the box
//      grows smoothly with its content (up to the CSS max-height, beyond
//      which the textarea scrolls internally).
//   2. Layout morph — measures the content and toggles the `data-layout`
//      attribute on the closest `.input-layout` ancestor between "compact"
//      (few lines) and "expanded" (many lines). The CSS reacts to this
//      attribute to morph the layout smoothly between Layout A (inline
//      controls) and Layout B (floating controls panel).
//
// The threshold is ~8 lines of content. In expanded mode the hook also
// measures the content column's horizontal center (from the .input-layout
// element, which is mx-auto max-w-3xl) and exposes it as the
// --input-layout-center CSS variable, so the position: fixed floating
// controls panel centers on the content column (offset by the sidebar)
// instead of the viewport.
const AdaptiveInput = {
  mounted() {
    this._inputHandler = () => this.measureAndApply();
    this._resizeHandler = () => this.updateFloatingControlsPosition();

    this.el.addEventListener("input", this._inputHandler);
    window.addEventListener("resize", this._resizeHandler);

    // Defer the initial measurement until after the browser has laid out the
    // element so scrollHeight/lineHeight are accurate. StatePersistence may
    // restore a saved prompt into the textarea on mount, so measure even
    // before any user input.
    requestAnimationFrame(() => this.measureAndApply());
  },

  updated() {
    // The textarea value may have changed via LiveView morphdom or
    // StatePersistence restore — re-measure and re-apply the layout.
    requestAnimationFrame(() => this.measureAndApply());
  },

  destroyed() {
    this.el.removeEventListener("input", this._inputHandler);
    window.removeEventListener("resize", this._resizeHandler);
  },

  measureAndApply() {
    const ta = this.el;
    this.layoutEl = ta.closest(".input-layout");
    if (!this.layoutEl) return;

    const computed = window.getComputedStyle(ta);
    const fontSize = parseFloat(computed.fontSize);
    const lineHeight = parseFloat(computed.lineHeight);
    // Fallback chain: computed line-height -> font-size * 1.5 -> 24px.
    // Number.isFinite guards make sure a NaN (e.g. line-height: normal)
    // can never leak into the threshold comparison below.
    const lineH =
      Number.isFinite(lineHeight) && lineHeight > 0
        ? lineHeight
        : Number.isFinite(fontSize) && fontSize > 0
          ? fontSize * 1.5
          : 24;

    // --- Autogrow ---
    // Reset to auto so scrollHeight reflects the true content height (not a
    // previously-set inline height), then set it explicitly so the box grows
    // with the content up to the CSS max-height (beyond which it scrolls).
    // Temporarily neutralize flex stretching and min/max-height while
    // measuring: in expanded mode the flex layout stretches the textarea, and
    // the CSS min-height would otherwise floor scrollHeight — both would hide
    // the real content height and break the compact<->expanded threshold.
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

    // Content height excludes the textarea's vertical padding (p-4 = 1rem
    // top + 1rem bottom), so the ~8-line threshold is accurate.
    const padTop = parseFloat(computed.paddingTop) || 0;
    const padBottom = parseFloat(computed.paddingBottom) || 0;
    const contentHeight = Math.max(0, scrollHeight - padTop - padBottom);

    // Threshold: ~8 lines of content.
    const layout = contentHeight > lineH * 8 ? "expanded" : "compact";

    if (this.layoutEl.getAttribute("data-layout") !== layout) {
      this.layoutEl.setAttribute("data-layout", layout);
    }

    this.updateFloatingControlsPosition();
  },

  updateFloatingControlsPosition() {
    if (!this.layoutEl) return;
    if (this.layoutEl.querySelector(".input-controls") === null) return;

    if (this.layoutEl.getAttribute("data-layout") !== "expanded") {
      // Compact mode uses position: relative — clear any measured position so
      // a leftover value can't shift the inline controls.
      this.layoutEl.style.removeProperty("--input-layout-center");
      return;
    }

    // The floating panel is position: fixed, so by default it centers on the
    // VIEWPORT. .input-layout is mx-auto max-w-3xl, so its horizontal center
    // equals the content column's center (which is offset from the viewport
    // center by the sidebar). Expose that center as a CSS variable that the
    // expanded-mode rule consumes: left: var(--input-layout-center, 50%).
    // The panel keeps its translateX(-50%) transform; the max-width clamp in
    // the CSS still applies.
    const rect = this.layoutEl.getBoundingClientRect();
    if (!(rect.width > 0) || !(rect.height > 0)) {
      // Not measurable (e.g. hidden) — fall back to the CSS 50% default.
      this.layoutEl.style.removeProperty("--input-layout-center");
      return;
    }

    const center = rect.left + rect.width / 2;
    this.layoutEl.style.setProperty("--input-layout-center", center + "px");
  }
};

export default AdaptiveInput;
