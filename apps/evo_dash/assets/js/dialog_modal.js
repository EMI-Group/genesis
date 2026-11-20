// Opens and dismisses dialogs. Actions inside each dialog remain with its LiveView.
// Markup/fallback contract: see CONTEXT.md, "DialogModal Integration Contract".
//
// The close is TWO-PHASE: `data-dialog-state="closing"` lets assets/css/motion.css
// animate the top-layer exit (dialog + ::backdrop) while the element is still
// open, and only then does the immediate teardown call the native close().
// Server teardown (`destroyed()`) deliberately skips the animation and tears
// down synchronously — the node is being removed, so a pending exit would leak
// its timer and leave focus inside a detached tree.
const DIALOG_STATE_ATTR = "data-dialog-state";
const DIALOG_OPENING = "opening";
const DIALOG_OPEN = "open";
const DIALOG_CLOSING = "closing";
// Bounded fallback for both phases: a dialog without an animatable box (or one
// whose animation never fires) must still open/close within a frame or two.
const DIALOG_STATE_FALLBACK_MS = 200;

const DialogModal = {
  mounted() {
    this._destroyed = false;
    this._closed = false;
    this._presented = false;
    this._fallback = typeof this.el.showModal !== "function";
    this._opener = document.activeElement;
    this._closeTimer = null;
    this._closePanel = null;
    this._closeEnd = null;
    this._enterTimer = null;
    this._enterPanel = null;
    this._enterEnd = null;
    // Native close events are queued: an old close can arrive after a reopen.
    this._onClose = () => { if (!this.el.open) this._dismiss(); };
    this._onCancel = event => {
      event.preventDefault();
      this._dismiss();
    };
    this._onKeydown = event => {
      if (this._fallback && event.key === "Escape" && !event.isComposing) {
        event.preventDefault();
        event.stopPropagation();
        this._dismiss();
      }
    };
    this._onClick = event => {
      const control = event.target.closest?.('[data-dialog-dismiss], [phx-click="dialog_closed"], .modal-backdrop button');
      if (!control || !this.el.contains(control)) return;
      // Own dismissal, including the legacy LV close button, so it reports once.
      event.preventDefault();
      event.stopPropagation();
      this._dismiss();
    };
    this._onSubmit = event => {
      if (!event.target.matches?.('form.modal-backdrop[method="dialog"]')) return;
      event.preventDefault();
      event.stopPropagation();
      this._dismiss();
    };
    for (const [name, listener] of this._listeners()) this.el.addEventListener(name, listener);
    this._openRef = this.handleEvent("dialog_open", () => {
      if (this._destroyed) return;
      if (this._closed) this._opener = document.activeElement;
      this._closed = false;
      this._openModal();
    });
    this._openModal();
  },

  updated() {
    if (!this._destroyed && !this._closed) this._openModal();
  },

  destroyed() {
    this._destroyed = true;
    for (const [name, listener] of this._listeners()) this.el.removeEventListener(name, listener);
    if (this._openRef !== undefined) this.removeHandleEvent(this._openRef);
    // Remove listeners BEFORE closing: server teardown must not report dismissal.
    // Synchronous on purpose — never leave a closing dialog or focus inside a node
    // the server is about to replace.
    const restore = this._ownsFocus();
    this._teardown();
    this._restoreFocus(restore);
  },

  _listeners() {
    return [["close", this._onClose], ["cancel", this._onCancel],
      ["keydown", this._onKeydown], ["click", this._onClick], ["submit", this._onSubmit]];
  },

  _usable(element) {
    return element && element.isConnected && !element.disabled && !element.closest('[hidden], [inert], [aria-hidden="true"]') && element.getClientRects().length > 0;
  },

  _focus(element) {
    if (!this._usable(element)) return false;
    element.focus({preventScroll: true});
    return document.activeElement === element;
  },

  _reviewTarget() {
    // Only static, non-action content is eligible for initial focus. In particular
    // an incorrectly marked Allow/Deny button must NEVER become the default.
    const candidates = this.el.querySelectorAll('[data-dialog-initial-focus], [data-dialog-title], .modal-box h2');
    for (const element of candidates) {
      if (element.matches('h1, h2, h3, h4, h5, h6, p, div') &&
          !element.closest('button, a, input, select, textarea, [contenteditable], [role="button"], [phx-click], [data-dialog-dismiss]') &&
          !element.querySelector('button, a, input, select, textarea, [contenteditable], [role="button"], [phx-click]')) {
        element.setAttribute("tabindex", "-1");
        return element;
      }
    }
    // No safe heading supplied: focus the dialog container, never a decision.
    this.el.setAttribute("tabindex", "-1");
    return this.el;
  },

  _openModal() {
    const first = !this._presented;
    const previous = document.activeElement;
    const wasOpen = this.el.open;
    // A genuine (re)open supersedes a pending exit, whose timer must never fire
    // on the freshly reopened dialog.
    if (!wasOpen) this._clearClose();
    const target = this._reviewTarget();
    const generatedTitleId = `${this.el.id}-review-title`;
    if (target !== this.el && this.el.getAttribute("aria-labelledby") === generatedTitleId && !target.id) target.id = generatedTitleId;
    if (!this.el.hasAttribute("aria-label") && !this.el.hasAttribute("aria-labelledby") && target !== this.el) {
      if (!target.id) target.id = generatedTitleId;
      this.el.setAttribute("aria-labelledby", target.id);
    }
    if (!this._fallback && !wasOpen) {
      if (typeof this.el.showModal === "function") {
        try {
          this.el.showModal();
        } catch (_error) {
          // Recover to a visible NON-modal review surface, not a closed/inert UI.
          this._fallback = true;
        }
      } else {
        this._fallback = true;
      }
    }
    this.el.setAttribute("role", "dialog");
    this.el.setAttribute("aria-modal", this._fallback ? "false" : "true");
    this.el.setAttribute("data-dialog-mode", this._fallback ? "fallback" : "native");
    if (this._fallback) {
      this.el.setAttribute("open", "");
      this.el.classList.add("modal-open"); // DaisyUI visibility + pointer access.
    }
    this._presented = true;
    const safeTarget = this._usable(target) ? target : this.el;
    if (safeTarget === this.el) this.el.setAttribute("tabindex", "-1");
    if (first || !wasOpen) {
      const desired = !first && this.el.contains(previous) && this._usable(previous) ? previous : safeTarget;
      if (!this._focus(desired)) {
        // CSS-hidden headings can have layout boxes yet reject focus.
        this.el.setAttribute("tabindex", "-1");
        this._focus(this.el);
      }
      this._enter();
    }
  },

  // Reduced motion is decided in ONE place (hooks/disclosure_motion.js). This
  // module cannot statically import it: dialog_modal.test.cjs runs this source
  // through node:vm as a CLASSIC script, where an `import` is a syntax error.
  // The hook module therefore publishes the helper on globalThis (documented
  // there); an absent bridge — that test, or a host without matchMedia — skips
  // the animation and completes in the same task.
  _motion() {
    const motion = globalThis.genesisMotion;
    return motion && typeof motion.prefersReducedMotion === "function" ? motion : null;
  },

  _skipAnimation() {
    const motion = this._motion();
    return !motion || motion.prefersReducedMotion() === true;
  },

  _panel() {
    return this.el.querySelector?.(".modal-box") || null;
  },

  _state(value) {
    if (value === null) this.el.removeAttribute(DIALOG_STATE_ATTR);
    else this.el.setAttribute(DIALOG_STATE_ATTR, value);
  },

  _clearEnter() {
    if (this._enterTimer !== null) {
      clearTimeout(this._enterTimer);
      this._enterTimer = null;
    }
    if (this._enterPanel && this._enterEnd) this._enterPanel.removeEventListener("animationend", this._enterEnd);
    this._enterPanel = null;
    this._enterEnd = null;
  },

  _clearClose() {
    if (this._closeTimer !== null) {
      clearTimeout(this._closeTimer);
      this._closeTimer = null;
    }
    if (this._closePanel && this._closeEnd) this._closePanel.removeEventListener("animationend", this._closeEnd);
    this._closePanel = null;
    this._closeEnd = null;
    if (this.el.getAttribute(DIALOG_STATE_ATTR) === DIALOG_CLOSING) this._state(null);
  },

  // Entry phase: "opening" while the CSS entry keyframes run, "open" once they
  // settle. Nothing here may block the dialog's usability — focus is already
  // placed by the caller.
  _enter() {
    this._clearEnter();
    const panel = this._panel();
    if (!panel || this._skipAnimation()) {
      this._state(DIALOG_OPEN);
      return;
    }
    this._state(DIALOG_OPENING);
    this._enterPanel = panel;
    this._enterEnd = event => {
      if (!event || event.target !== panel) return; // A child animation must not settle it.
      this._clearEnter();
      this._state(DIALOG_OPEN);
    };
    panel.addEventListener("animationend", this._enterEnd);
    this._enterTimer = setTimeout(() => {
      this._clearEnter();
      this._state(DIALOG_OPEN);
    }, DIALOG_STATE_FALLBACK_MS);
  },

  _ownsFocus() {
    return this.el.contains(document.activeElement) || document.activeElement === document.body;
  },

  // Exit phase: keep the dialog open (and in the top layer) for one animated
  // exit, then tear it down. Without an animatable panel, under reduced motion,
  // or while a close is already running, this completes in the same task.
  _hide() {
    if (this._closeTimer !== null || this._closePanel !== null) {
      this._teardown();
      return;
    }
    const panel = this._panel();
    if (!panel || this._skipAnimation()) {
      this._teardown();
      return;
    }
    this._clearEnter(); // A still-running entry must not outlive the exit.
    this._state(DIALOG_CLOSING);
    this._closePanel = panel;
    this._closeEnd = event => {
      if (!event || event.target !== panel) return; // ::backdrop / child animations.
      this._teardown();
    };
    panel.addEventListener("animationend", this._closeEnd);
    this._closeTimer = setTimeout(() => this._teardown(), DIALOG_STATE_FALLBACK_MS);
  },

  // The immediate teardown, shared by the animated close, the no-animation path
  // and server teardown. Idempotent and always synchronous.
  _teardown() {
    this._clearClose();
    this._clearEnter();
    this._state(null);
    if (this.el.open && typeof this.el.close === "function") {
      try {
        this.el.close();
      } catch (_error) {
        // Broken/partial WebView dialog API: removing open still releases fallback.
      }
    }
    this.el.removeAttribute("open");
    this.el.classList.remove("modal-open");
    this._presented = false;
  },

  _restoreFocus(restore) {
    if (!restore) return; // Never steal focus already moved outside by the user.
    const id = this.el.getAttribute("data-dialog-return-focus");
    const explicit = id ? document.getElementById(id) : null;
    const legacy = this.el.id === "approval-dialog" ? document.querySelector('[phx-click="open_approval_dialog"]') : null;
    const target = [explicit, this._opener, legacy].find(element => !this.el.contains(element) && this._usable(element));
    this._focus(target);
  },

  _dismiss() {
    if (this._closed || this._destroyed) return;
    this._closed = true; // close() can synchronously emit another close event.
    const restore = this._ownsFocus();
    this._hide();
    this._restoreFocus(restore);
    this.pushEvent("dialog_closed", {});
  }
};

export default DialogModal;
