// DesktopQuit hook: listens for the Tauri shell's "quit-requested" event
// (tray "Quit Genesis" item) and forwards it to the server as
// desktop_quit_requested, which opens the confirm dialog on whichever page is
// being viewed (the hook is mounted on a wrapper around the app layout's
// <main>, so it is re-established on every page navigation). A complete no-op
// outside the Tauri shell (normal browsers) since window.__TAURI__ is absent.
//
// Delivery is latched + retried because pushEvent is NOT buffered: while the
// window sits hidden in the tray the LiveSocket disconnects (heartbeat stalls
// while the page is hidden and reconnects are suspended until the window is
// shown), and pushHookEvent rejects with "unable to push hook event. LiveView
// not connected" when the socket is down — a single unlatched push would be
// silently lost. The latch is armed on the first quit-requested, dedups any
// re-emit while a quit awaits delivery or the dialog is open, retries the
// push on rejection (1s) and again from reconnected(), and is released only
// when the server pushes desktop_quit_closed (dialog dismissed) so FUTURE
// tray quits stay honored.
const DesktopQuit = {
  mounted() {
    // Same detection as the TauriDetect hook (app.js).
    const isTauri = !!(window.__TAURI__ || window.__TAURI_OS_INTERNALS__);
    if (!isTauri) {
      return;
    }
    // The hook is mounted = the LiveSocket joined = the quit listener below is
    // registered.
    this._quitPending = false;   // a quit awaits delivery / the dialog is open
    this._retryTimer = null;
    this._unlisten = null;
    // Defensive guard: some shells/builds expose __TAURI__ without the event
    // module (capability/ACL restrictions). Without this check the call below
    // would throw a TypeError — log loudly instead of failing silently, since
    // a missing listener means the tray Quit confirm dialog can never appear.
    if (!(window.__TAURI__ && window.__TAURI__.event && typeof window.__TAURI__.event.listen === "function")) {
      console.error("[desktop] quit-requested listener unavailable: window.__TAURI__.event.listen missing");
      this._unlistenPromise = null;
    } else {
      this._unlistenPromise = window.__TAURI__.event.listen("quit-requested", () => {
        if (this._quitPending) return;   // dedup: dialog open or delivery in flight
        this._quitPending = true;
        this._pushQuitRequested();
      });
      this._unlistenPromise.then(
        (unlisten) => {
          // If the hook was destroyed before the promise resolved, unlisten right
          // away; otherwise keep the unlisten for destroyed().
          if (this._unlistenPromise) {
            this._unlisten = unlisten;
          } else {
            unlisten();
          }
        },
        // Registration rejection (ACL/permission, IPC error): historically this
        // was swallowed silently — the tray Quit dialog never appeared and the
        // logs gave no clue why. Log it loudly, including whether __TAURI__ is
        // present at all, so the failure is self-explanatory. No retry/loop:
        // a rejected listen call would just reject again.
        (err) => {
          console.error("[desktop] failed to register quit-requested listener:", err);
          console.error("[desktop] window.__TAURI__ presence at registration failure:", window.__TAURI__);
        }
      );
    }
    // Server→client signal that the dialog was dismissed — re-arms the latch
    // so a FUTURE tray Quit is honored. Same phx: window-event pattern as the
    // DirectoryPicker hook's "picker_result:..." (hooks/directory_picker.js).
    this._unlistenClosed = this.handleEvent("desktop_quit_closed", () => {
      this._quitPending = false;
      if (this._retryTimer) {
        clearTimeout(this._retryTimer);
        this._retryTimer = null;
      }
    });
  },
  // Socket re-established: page is live again; deliver an undelivered quit
  // request now.
  reconnected() {
    if (this._quitPending) this._pushQuitRequested();
  },
  _pushQuitRequested() {
    if (!this._quitPending) return;
    if (this._retryTimer) {
      clearTimeout(this._retryTimer);
      this._retryTimer = null;
    }
    this.pushEvent("desktop_quit_requested", {}).then(
      () => {},   // delivered — latch stays until the user dismisses (desktop_quit_closed)
      () => {     // dropped (disconnected) — retry shortly; latch still set
        if (!this._quitPending) return;
        this._retryTimer = setTimeout(() => this._pushQuitRequested(), 1000);
      }
    );
  },
  destroyed() {
    this._quitPending = false;
    if (this._retryTimer) {
      clearTimeout(this._retryTimer);
      this._retryTimer = null;
    }
    // Safe if the listen promise hasn't resolved yet: nulling _unlistenPromise
    // makes the then-callback unlisten immediately instead of storing.
    this._unlistenPromise = null;
    if (this._unlisten) {
      this._unlisten();
      this._unlisten = null;
    }
    if (this._unlistenClosed) {
      this.removeHandleEvent(this._unlistenClosed);
      this._unlistenClosed = null;
    }
  }
};

// DesktopQuitConfirm hook: the desktop quit dialog's red Quit button. Invokes
// the Tauri `begin_quit` command first — the shell sets its
// intentional-shutdown flag so its watchdog won't restart the backend — and
// then pushes desktop_quit_confirmed to the server. A begin_quit failure must
// still proceed: the confirm event still needs to reach the server. Without
// Tauri (browser testing path) the event is pushed directly.
const DesktopQuitConfirm = {
  mounted() {
    this.el.addEventListener("click", (event) => {
      event.preventDefault();
      this.confirmQuit();
    });
  },
  async confirmQuit() {
    const isTauri = !!(window.__TAURI__ || window.__TAURI_OS_INTERNALS__);
    if (isTauri) {
      try {
        await window.__TAURI__.core.invoke("begin_quit");
      } catch (_error) {
        // Failure must still proceed — the server still needs the confirm.
      }
    }
    this.pushEvent("desktop_quit_confirmed", {});
  }
};

export {DesktopQuit, DesktopQuitConfirm};
export default DesktopQuit;
