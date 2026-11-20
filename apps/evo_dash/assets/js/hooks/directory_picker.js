// DirectoryPicker hook: native directory picker via a server-side wx dialog
//
// The picker buttons ("Browse" on the project, new-project, and foreign-repo
// pickers) carry phx-hook="DirectoryPicker". Clicking a button pushes a
// "directory_pick" event to the server (ProjectsLive), which — when the
// current node is local — runs a native wx directory dialog
// (EvoDash.DirectoryPicker GenServer, wxDirDialog) and pushes the result back
// to the client as a "picker_result:<picker_id>" event. Payloads:
//
//   {path: "/absolute/path"} → a directory was picked (wx returns absolute
//                              paths only)
//   {cancelled: true}        → the user dismissed the dialog — no-op
//   {unavailable: true}      → wx is unavailable (headless server, remote
//                              node, OTP built without wx) — fall back to
//                              manual entry
//
// There is deliberately NO JS-side timeout: the native dialog may legitimately
// stay open for minutes while the user navigates the filesystem, and the
// server owns the dialog lifecycle. On a successful pick the path is filled
// into the adjacent input; the project and new-project pickers additionally
// auto-submit their enclosing form (the server validates via Path.expand +
// File.dir?, so auto-submitting a stale/bad selection is safe), while the
// foreign-repo picker only fills the input (a settings form field). wx picks
// are always absolute; the absolute-path guard below is defense in depth — a
// non-absolute result is never fed into the input (the server would cwd-join
// it) and routes to the manual-entry fallback instead.
const DirectoryPicker = {
  mounted() {
    // The click listener is kept on the hook instance so destroyed() can
    // remove it: a remount of this hook would otherwise stack another
    // anonymous listener on the same element.
    this._onClick = () => {
      // Re-entrancy guard: the native wx dialog is modal, so a second click
      // while a pick is in flight would stack another dialog. The result
      // handler (or a reconnect, see reconnected()) re-arms the button.
      if (this._picking) return;
      this._picking = true;
      this.pushEvent("directory_pick", {picker_id: this.el.dataset.pickerId});
    };
    this.el.addEventListener("click", this._onClick);

    // Register in mounted() (not only on connect) so the listener survives
    // reconnects: handleEvent listeners live until the hook is destroyed, and
    // mounted() re-runs whenever the hook is re-created.
    this.handleEvent("picker_result:" + this.el.dataset.pickerId, ({path, cancelled, unavailable}) => {
      this._picking = false; // the dialog is closed — re-arm the button

      if (unavailable) {
        // Headless server, remote node, or OTP built without wx — never leave
        // the user with a silent dead click.
        this.markManualFallback();
        return;
      }
      if (cancelled) return; // user dismissed the native dialog — not an error

      if (path) {
        // Defense-in-depth: wx picks are always absolute, but never feed a
        // non-absolute result into the input (the server would cwd-join it) —
        // warn and fall through to the manual-entry fallback instead.
        if (!/^[a-zA-Z]:[\\/]|^[\\/]|^\\\\/.test(path)) {
          console.warn(
            "[DirectoryPicker] Picker returned a non-absolute path (\"" + path + "\") — please type the full path."
          );
          this.markManualFallback();
          return;
        }
        this.fillInput(path);
        // wx picks return a full absolute path — auto-confirm the project and
        // new-project pickers by submitting the enclosing form directly. (The
        // browse button lives inside that form; the foreign-repo picker is a
        // settings form field that still needs manual input.)
        if (this.el.dataset.pickerId === "project" ||
            this.el.dataset.pickerId === "new-project") {
          this.el.closest("form")?.requestSubmit();
        }
        return;
      }

      // Defensive: a result with no path and no flags is unusable — fall back
      // to manual entry rather than silently doing nothing.
      this.markManualFallback();
    });
  },

  destroyed() {
    // handleEvent listeners are released by LiveView on destroy; the DOM
    // listener is ours to release.
    if (this._onClick) {
      this.el.removeEventListener("click", this._onClick);
      this._onClick = null;
    }
  },

  // If the connection drops while the native dialog is open, the server-side
  // pick is gone — re-arm the button so the user can try again once the
  // reconnect completes.
  reconnected() {
    this._picking = false;
  },

  // Resolves the container element that wraps the browse button + path input
  // (same lookup order fillInput always used).
  containerEl() {
    return this.el.closest(".picker-container") ||
      this.el.closest(".form-control") ||
      this.el.closest(".relative") ||
      this.el.parentElement;
  },

  pickerInput() {
    const container = this.containerEl();
    if (!container) return null;
    return container.querySelector('input[type="text"]');
  },

  fillInput(value) {
    const input = this.pickerInput();
    if (input) {
      input.value = value;
      input.dispatchEvent(new Event("input", {bubbles: true}));
    }
    this.clearManualFallback();
  },

  // Surfaces a visible "type the path manually" fallback: marks the picker row
  // (styled via [data-picker-error="manual"] in css/app.css) and focuses the
  // path input so manual entry is one keystroke away.
  markManualFallback() {
    const container = this.containerEl();
    if (container) {
      container.dataset.pickerError = "manual";
      this.pickerInput()?.focus();
    } else {
      this.el.dataset.pickerError = "manual";
    }
    console.warn(
      "[DirectoryPicker] Native picker unavailable — the path input remains editable for manual entry"
    );
  },

  clearManualFallback() {
    const container = this.containerEl();
    if (container) container.removeAttribute("data-picker-error");
  }
};

export default DirectoryPicker;
