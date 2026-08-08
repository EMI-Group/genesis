// PadFly hook (Pad home, HomeLive `/`): mounted on the composer form.
//
// Four responsibilities:
//
// 1. KEYBOARD — Enter in the prompt textarea submits the form
//    (`requestSubmit()`), Shift+Enter inserts a newline, and the
//    `e.isComposing` guard keeps IME candidate confirmation (CJK input) from
//    submitting. Enter in the path input only confirms the path (it moves
//    focus to the prompt) — it never launches a task. Focus lands in the
//    textarea on mount (deferred one frame so PathAutocomplete's own
//    mount-time focus on the path input doesn't win).
//
// 2. OPTIMISTIC FLIGHT — on the form's `submit` event (before the server
//    round-trip answers) the prompt text is cloned into a fixed-position
//    `.pad-fly` blob at the textarea's position and flown to the next free
//    slot at the top of the right-hand rail (`#pad-rail`), shrinking into a
//    44px square that fades out (~550ms, cubic-bezier, styled in
//    `css/pad.css`). Skipped entirely when the prompt is empty (the server
//    would reject it) or when `prefers-reduced-motion` is set. The flight is
//    optimistic: if the submit fails server-side, no rail square ever lands —
//    only the inline error shows.
//
// 3. SERVER-CONFIRMED CLEAR — after a successful submit the server pushes
//    `"pad:clear_prompt"`; the hook clears the (`phx-update="ignore"`)
//    textarea, re-dispatches `input` (so AdaptiveInput shrinks it back), and
//    returns focus — the next requirement can be typed immediately while
//    path/mode/advanced params stay server-side (continuous input).
//
// 4. RAIL TOOLTIP — the rail scrolls (`overflow-y: auto`), which would clip
//    any tooltip absolutely-positioned inside a square (a scroll container
//    clips on BOTH axes). Tooltips are therefore rendered by this hook as one
//    fixed-position `.pad-fly-tip` element driven by mouseover delegation and
//    the square's `data-tip-*` attributes. All text goes through
//    `textContent` — never innerHTML — so prompts/paths can't inject markup.
const PadFly = {
  mounted() {
    this.reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
    const ta = this.el.querySelector("textarea[name='prompt']");
    const pathInput = this.el.querySelector("input[name='path']");

    if (ta) {
      // Defer past all mounted() callbacks: PathAutocomplete focuses the path
      // input on mount, the prompt is the intended landing spot.
      requestAnimationFrame(() => ta.focus());
      ta.addEventListener("keydown", (e) => {
        if (e.key !== "Enter" || e.shiftKey || e.isComposing) return;
        e.preventDefault();
        this.el.requestSubmit();
      });
    }

    if (pathInput && ta) {
      pathInput.addEventListener("keydown", (e) => {
        if (e.key !== "Enter" || e.isComposing) return;
        e.preventDefault();
        ta.focus();
      });
    }

    this.el.addEventListener("submit", () => {
      const text = ta ? ta.value.trim() : "";
      if (text === "" || this.reducedMotion.matches) return;
      this.fly(text);
    });

    this.handleEvent("pad:clear_prompt", () => {
      if (!ta) return;
      ta.value = "";
      // Notify AdaptiveInput (autogrow) so the textarea shrinks back.
      ta.dispatchEvent(new Event("input", {bubbles: true}));
      ta.focus();
    });

    // --- Rail tooltip (fixed position; the rail is a scroll container) ---
    this._tipEl = null;
    this._tipFor = null;
    this._onMouseover = (e) => {
      const sq = e.target && e.target.closest ? e.target.closest(".pad-sq[data-tip-prompt]") : null;
      if (sq) {
        this.showTip(sq);
      } else {
        this.hideTip();
      }
    };
    this._onScrollOrHide = () => this.hideTip();
    document.addEventListener("mouseover", this._onMouseover);
    // Hide on any scroll (rail or page) and when the pointer leaves the window.
    document.addEventListener("scroll", this._onScrollOrHide, true);
    document.addEventListener("mouseleave", this._onScrollOrHide);
  },

  destroyed() {
    document.removeEventListener("mouseover", this._onMouseover);
    document.removeEventListener("scroll", this._onScrollOrHide, true);
    document.removeEventListener("mouseleave", this._onScrollOrHide);
    this.hideTip();
  },

  showTip(sq) {
    if (this._tipFor === sq) return;
    this.hideTip();
    const rect = sq.getBoundingClientRect();
    const tip = document.createElement("div");
    tip.className = "pad-fly-tip";
    const prompt = document.createElement("div");
    prompt.className = "pad-fly-tip-p";
    prompt.textContent = sq.dataset.tipPrompt || "";
    const meta = document.createElement("div");
    meta.className = "pad-fly-tip-m";
    const bits = [sq.dataset.tipPath, sq.dataset.tipTime].filter((b) => b && b !== "");
    meta.textContent = bits.join(" · ");
    tip.appendChild(prompt);
    tip.appendChild(meta);
    document.body.appendChild(tip);
    // Position: left of the rail, vertically centered on the square, clamped
    // into the viewport. Must happen AFTER append so offsetHeight is real.
    const top = rect.top + rect.height / 2 - tip.offsetHeight / 2;
    tip.style.top = Math.max(8, Math.min(top, window.innerHeight - tip.offsetHeight - 8)) + "px";
    tip.style.left = rect.left - tip.offsetWidth - 10 + "px";
    this._tipEl = tip;
    this._tipFor = sq;
  },

  hideTip() {
    if (this._tipEl) {
      this._tipEl.remove();
      this._tipEl = null;
      this._tipFor = null;
    }
  },

  // The optimistic flight: clone the text blob from the textarea position and
  // fly it to the rail's next free slot, shrinking to a 44px square.
  fly(text) {
    const ta = this.el.querySelector("textarea[name='prompt']");
    const rail = document.getElementById("pad-rail");
    if (!ta || !rail) return;

    const from = ta.getBoundingClientRect();
    const flyEl = document.createElement("div");
    flyEl.className = "pad-fly";
    flyEl.textContent = text.length > 40 ? text.slice(0, 40) + "…" : text;
    flyEl.style.left = from.left + "px";
    flyEl.style.top = from.top + "px";
    document.body.appendChild(flyEl);

    // Target: vertically the next free slot (existing squares + gap), centered
    // horizontally inside the rail.
    const railRect = rail.getBoundingClientRect();
    const squares = rail.querySelectorAll(".pad-sq").length;
    const targetX = railRect.left + (railRect.width - 44) / 2;
    const targetY = railRect.top + 14 + squares * 54;

    requestAnimationFrame(() => {
      flyEl.style.left = targetX + "px";
      flyEl.style.top = targetY + "px";
      flyEl.style.width = "44px";
      flyEl.style.height = "44px";
      flyEl.style.maxWidth = "44px";
      flyEl.style.padding = "0";
      flyEl.style.overflow = "hidden";
      flyEl.style.fontSize = "0px";
      flyEl.style.opacity = "0";
    });

    setTimeout(() => flyEl.remove(), 580);
  }
};

export default PadFly;
