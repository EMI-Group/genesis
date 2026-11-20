// Opens and dismisses dialogs. Actions inside each dialog remain with its LiveView.
// Markup/fallback contract: see CONTEXT.md, "DialogModal Integration Contract".
const DialogModal = {
  mounted() {
    this._destroyed = false;
    this._closed = false;
    this._presented = false;
    this._fallback = typeof this.el.showModal !== "function";
    this._opener = document.activeElement;
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
    const restore = this._ownsFocus();
    this._hide();
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
    }
  },

  _ownsFocus() {
    return this.el.contains(document.activeElement) || document.activeElement === document.body;
  },

  _hide() {
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
