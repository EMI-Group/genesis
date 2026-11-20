// Guide hook: receives "guide_highlight" pushEvents from the server-side
// Guide on-mount hook (EvoDashWeb.LiveHooks.Guide) — scrolls the target into
// view and applies a temporary highlight. The last payload is kept in a
// module-level variable so mounted() re-applies it after a navigation (the
// @guide assign is restored server-side from a per-tab store keyed by
// guide_client_id — received via the connect params and stable across
// push_navigate since the WebSocket connection persists; the DOM may need
// the retry loop on the new page). Works in plain browsers too — no Tauri
// gating.
let lastGuideHighlight = null;
// A malformed selector from the server is warned about once per page, never
// thrown out of the hook.
let guideSelectorWarned = false;

const Guide = {
  mounted() {
    // Every scheduled timer (retry + highlight) lives on the instance so
    // destroyed() can release it.
    this._timers = new Set();

    this.handleEvent("guide_highlight", (payload) => {
      if (payload && payload.selector) {
        lastGuideHighlight = payload.selector;
        this.applyHighlight(payload.selector);
      }
    });
    // The server pushes "guide_cleared" when the guide is dismissed; drop the
    // stored selector so a later remount/navigation doesn't re-apply it.
    this.handleEvent("guide_cleared", () => {
      lastGuideHighlight = null;
    });
    if (lastGuideHighlight) {
      this.applyHighlight(lastGuideHighlight);
    }
  },

  destroyed() {
    for (const timer of this._timers || []) {
      clearTimeout(timer);
    }
    if (this._timers) this._timers.clear();
  },

  // Schedules `fn` and remembers the handle so destroyed() can release it.
  _schedule(fn, delay) {
    const timer = setTimeout(() => {
      this._timers.delete(timer);
      fn();
    }, delay);
    this._timers.add(timer);
    return timer;
  },

  // Bounded retry: the guided element may render after the event arrives
  // (~10 x 250ms), then give up silently.
  applyHighlight(selector) {
    let attempts = 0;
    const tryHighlight = () => {
      let target;
      try {
        target = document.querySelector(selector);
      } catch (err) {
        // A malformed server-supplied selector can never throw out of the hook
        // — warn once and give up.
        if (!guideSelectorWarned) {
          guideSelectorWarned = true;
          console.warn("[Guide] Ignoring invalid guide selector:", selector, err);
        }
        return;
      }
      if (!target) {
        if (attempts < 10) {
          attempts += 1;
          this._schedule(tryHighlight, 250);
        }
        return;
      }
      // Scroll: prefer the #main-scroll container (center the target within
      // it), falling back to the element's own scrollIntoView.
      const scroller = document.querySelector("#main-scroll");
      if (scroller && scroller.contains(target)) {
        const targetRect = target.getBoundingClientRect();
        const scrollerRect = scroller.getBoundingClientRect();
        scroller.scrollTo({
          top: scroller.scrollTop + targetRect.top - scrollerRect.top - scroller.clientHeight / 2 + targetRect.height / 2,
          behavior: "smooth"
        });
      } else {
        target.scrollIntoView({behavior: "smooth", block: "center"});
      }
      target.classList.add("guide-highlight");
      this._schedule(() => target.classList.remove("guide-highlight"), 3000);
    };
    tryHighlight();
  }
};

// Guide retention: a stable per-tab id (sessionStorage-backed so it also
// survives full reloads within the tab). The server-side Guide hook keys
// its guide store by this id, received via the connect params.
let guideClientId = null;
if (typeof sessionStorage !== "undefined") {
  guideClientId = sessionStorage.getItem("guide_client_id");
}
if (!guideClientId) {
  guideClientId = (typeof crypto !== "undefined" && crypto.randomUUID)
    ? crypto.randomUUID()
    : "g-" + Math.random().toString(36).slice(2);
  if (typeof sessionStorage !== "undefined") {
    try { sessionStorage.setItem("guide_client_id", guideClientId); } catch (e) {}
  }
}

export {guideClientId};
export default Guide;
