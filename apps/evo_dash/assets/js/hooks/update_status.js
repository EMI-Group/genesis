// UpdateStatus hook: bridges the Tauri updater to the dashboard. Listens for
// the server→client pushes (LiveSocket dispatches them as `phx:update_*`
// CustomEvents on window — the SystemLive card pushes them) and invokes the
// matching Tauri command, then pushes the result back as a client→server
// event which the server-side UpdateStatus on-mount hook consumes on every
// page. Also runs a startup check (30s after the first mount) and a periodic
// check (every 6h). The listeners and timers are module-level: they bind ONCE
// regardless of how many times the hook remounts on navigation, and
// updateCurrentHook always points at the live hook instance so timer-driven
// invokes can reach the current page's LiveView. Complete no-op outside the
// Tauri shell (normal browsers) since window.__TAURI__ is absent.
let updateListenersBound = false;
let updateTimersStarted = false;
let updateCurrentHook = null;

const UpdateStatus = {
  mounted() {
    // Same detection as the TauriDetect hook (app.js).
    const isTauri = !!(window.__TAURI__ || window.__TAURI_OS_INTERNALS__);
    if (!isTauri) {
      return;
    }
    updateCurrentHook = this;

    if (!updateListenersBound) {
      updateListenersBound = true;
      window.addEventListener("phx:update_check_requested", () => invokeUpdateCheck());
      window.addEventListener("phx:update_download_requested", () => invokeUpdateDownload());
      window.addEventListener("phx:update_apply_requested", () => invokeUpdateApply());
    }

    if (!updateTimersStarted) {
      updateTimersStarted = true;
      // Startup check shortly after load; the periodic check re-runs it every
      // 6h. The check itself invokes the Rust command (results flow back via
      // pushEvent), so no payload is needed here.
      setTimeout(() => invokeUpdateCheck(), 30000);
      setInterval(() => invokeUpdateCheck(), 6 * 60 * 60 * 1000);
    }
  },
  destroyed() {
    // Only clear the ref if it still points at this instance (another mount
    // may have already taken over). Timer-driven invokes then no-op until the
    // next mount re-registers a live hook.
    if (updateCurrentHook === this) {
      updateCurrentHook = null;
    }
  }
};

// Pushes a client→server event through the current hook instance. Guards the
// ref (the element may be unmounted mid-timer) and wraps pushEvent in
// try/catch for the same reason.
function pushUpdateEvent(event, payload) {
  const hook = updateCurrentHook;
  if (!hook) {
    return;
  }
  try {
    hook.pushEvent(event, payload || {});
  } catch (_error) {
    // Element unmounted between the guard and the push — ignore.
  }
}

// Runs the Tauri check_update command and reports the result to the server.
async function invokeUpdateCheck() {
  try {
    const result = await window.__TAURI__.core.invoke("check_update");
    pushUpdateEvent("update_check_result", result || {});
  } catch (err) {
    pushUpdateEvent("update_check_result", {status: "error", error: String(err)});
  }
}

// Runs the Tauri download_update command and reports the result to the server.
async function invokeUpdateDownload() {
  try {
    const result = await window.__TAURI__.core.invoke("download_update");
    pushUpdateEvent("update_download_result", result || {});
  } catch (err) {
    pushUpdateEvent("update_download_result", {status: "error", error: String(err)});
  }
}

// Runs the Tauri begin_update command. A `{ok: true}` result means the shell
// has taken over (watchdog → installer → relaunch): report the confirm. Any
// other outcome reports the failure so the hub can revert :applying.
async function invokeUpdateApply() {
  try {
    const result = await window.__TAURI__.core.invoke("begin_update");
    if (result && result.ok) {
      pushUpdateEvent("update_apply_confirmed", {});
    } else {
      const error = result && result.error ? String(result.error) : "begin_update returned no ok result";
      pushUpdateEvent("update_apply_failed", {error: error});
    }
  } catch (err) {
    pushUpdateEvent("update_apply_failed", {error: String(err)});
  }
}

export default UpdateStatus;
