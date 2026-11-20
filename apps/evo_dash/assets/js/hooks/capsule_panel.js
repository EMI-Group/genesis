// CapsulePanel hook: mounted on every fused-capsule <details> root — the task
// form's mode+speed capsule (#mode-speed-capsule) and the shared
// model+reasoning capsule rendered by EvoDashWeb.LLMSelectionComponents
// (#task-llm-selection on Projects, #chat-llm-selection on the Assistant page;
// several capsules may live on one page, each with its own instance).
//
// Responsibilities: OPEN/CLOSE CHOREOGRAPHY + the model capsule's two-view
// drill-down, all client-side. The server owns the markup and the persistence
// events; this hook owns the closing animation, outside-click / Escape
// dismissal, the model ↔ provider view switch, and keeping an open panel open
// across LiveView re-renders.
//
// Two data attributes are written by THIS hook (the server only seeds the
// initial view):
//   data-capsule-state="closing" — present only while a panel plays its exit
//     animation (css/app.css keys the close keyframes off it); removed the
//     instant the panel is actually closed. Attribute-gated on purpose: the
//     exit animation must survive the many re-renders a closing panel can
//     still receive, and a class would be stripped/wobbled by morphdom class
//     merging.
//   data-capsule-view="model"|"provider" — which .capsule-view is displayed.
//     Only the model+reasoning capsule owns views (the mode+speed capsule has
//     none); this hook never adds the attribute to a root without them.
//
// There is NO phx-click on the hook element and no stopPropagation anywhere:
// the LiveView-bound clicks inside the panel (model item, provider item) must
// reach the server untouched.
//
// The CLOSE itself is not this hook's private machinery: it delegates to the
// shared motion foundation (./disclosure_motion.js), the one place that owns
// "wait for the panel's own exit before releasing it" — idempotent one-close-
// per-root, target-verified animationend, the bounded fallback, same-task
// completion under reduced motion and the attribute + `open` release.
import {closeAnimated as closeAnimatedShared} from "./disclosure_motion.js";

// The exit keyframes in css/app.css are gated on this attribute
// (details.capsule[data-capsule-state="closing"]), so the shared helper is
// told to own exactly it.
const CAPSULE_STATE_ATTR = "data-capsule-state";

const CapsulePanel = {
  mounted() {
    // Native <details> open state is the source of truth at mount; the hook
    // only remembers what the USER asked for, so a morphdom patch that drops
    // the `open` attribute cannot silently close a panel the user has open.
    this.openRequested = this.el.open;
    this.view = this.el.dataset.capsuleView || "model";

    // Seed the view attribute so a view-owning capsule never renders with
    // every .capsule-view hidden (a no-op when the server already wrote it).
    this.setView(this.view);

    // Outside click → animated close. `pointerdown` (capture) rather than
    // `click`: the press that moves focus away is the honest "dismiss" signal,
    // it fires before the following click lands on (or navigates) whatever was
    // clicked, and it cannot be swallowed by a descendant's click handling.
    this._outsideHandler = (event) => {
      if (!this.el.open) return;
      if (this.el.contains(event.target)) return;
      this.closeAnimated();
    };
    document.addEventListener("pointerdown", this._outsideHandler, true);

    // Escape → animated close + focus back on the collapsed trigger. Only a
    // panel that is actually open reacts, so a closed capsule never steals the
    // key from a modal, a command palette or another capsule.
    this._escapeHandler = (event) => {
      if (!this.el.open) return;
      if (event.key !== "Escape") return;
      event.preventDefault();
      this.closeAnimated();
      const summary = this._rootSummary();
      if (summary) summary.focus();
    };
    document.addEventListener("keydown", this._escapeHandler, true);

    // ONE delegated click handler owns the trigger interception and the
    // drill-down navigation; delegation survives every server re-render of the
    // panel's contents (no per-item listeners to re-attach in updated()).
    this._clickHandler = (event) => this._handleClick(event);
    this.el.addEventListener("click", this._clickHandler);

    // Track the user's intent across every open/close — native summary
    // toggles, our own `open = false` write, and the re-assertion in
    // updated() all funnel through here.
    this._toggleHandler = () => {
      const open = this.el.open;
      const wasRequested = this.openRequested;
      this.openRequested = open;
      // Reset to the default view on a GENUINE open (closed → opened by the
      // user). The wasRequested guard is load-bearing: a LiveView patch
      // strips the server-less `open` attribute, updated() immediately
      // restores it, and the queued toggle then reports "open" again — which
      // would yank a panel the user drilled into back to the model list.
      if (open && !wasRequested) this.setView("model");
    };
    this.el.addEventListener("toggle", this._toggleHandler);
  },

  updated() {
    // Never touch the DOM of a closed capsule: LiveView re-renders the form
    // on nearly every selection, and re-opening here would fight the user.
    if (!this.openRequested) return;

    // LiveView patches strip attributes the server does not render — `open`
    // is one of them (it is pure client state), so restore it or the open
    // panel would vanish on the next unrelated re-render.
    if (!this.el.open) this.el.open = true;
    // Same story for the states this hook owns: a patch removes both, so
    // re-assert the selected view. A leftover "closing" is cleared because
    // this panel is meant to be open.
    if (this.el.dataset.capsuleState === "closing") {
      delete this.el.dataset.capsuleState;
    }
    this.setView(this.view);
  },

  destroyed() {
    document.removeEventListener("pointerdown", this._outsideHandler, true);
    document.removeEventListener("keydown", this._escapeHandler, true);
    this.el.removeEventListener("click", this._clickHandler);
    this.el.removeEventListener("toggle", this._toggleHandler);

    // Release a running exit (its listener and its timer) with the element — it
    // is leaving the DOM, so the close simply completes now (fallbackMs 0 makes
    // the shared helper skip the wait; a close already in flight completes
    // synchronously and still runs its completion callbacks). Without this a
    // mid-exit teardown would leave data-capsule-state="closing" behind and the
    // panel would never be released.
    if (this.el.dataset.capsuleState === "closing") {
      closeAnimatedShared(this.el, {
        panel: this.el.querySelector(".capsule-panel"),
        attr: CAPSULE_STATE_ATTR,
        fallbackMs: 0
      });
    }
  },

  // The one close path: native <details> cannot animate its exit, so the exit
  // is played first (attribute-gated) and `open` is removed only once it
  // finished — all of it delegated to the shared motion foundation.
  closeAnimated() {
    if (!this.el.open) return;
    // Re-entrancy guard: a second outside press / Escape during the exit
    // animation must not restart it.
    if (this.el.dataset.capsuleState === "closing") return;

    // Drop the intent FIRST — everything downstream (toggle events,
    // updated()) must agree that this panel is meant to be closed.
    this.openRequested = false;

    // The helper writes CAPSULE_STATE_ATTR="closing", waits for the panel's own
    // animationend (target-verified, so a child view animation cannot finish it
    // early) or its bounded 200 ms fallback, then removes BOTH the attribute and
    // `open` — and completes in the same task under reduced motion or when there
    // is no .capsule-panel to animate.
    closeAnimatedShared(this.el, {
      panel: this.el.querySelector(".capsule-panel"),
      attr: CAPSULE_STATE_ATTR,
      onComplete: () => this._afterClose()
    });
  },

  // The helper owns the attribute and the `open` release; this only re-asserts
  // the hook's own bookkeeping (shared with the `toggle` listener) so a
  // straggling toggle/patch can never resurrect the closed panel.
  _afterClose() {
    this.openRequested = false;
    if (this.el.open) this.el.open = false;
  },

  // Switches the panel's view. Roots without any .capsule-view children (the
  // mode+speed capsule) are simply left alone — they must not grow a
  // data-capsule-view attribute they never use.
  setView(view) {
    const next = view || "model";
    this.view = next;
    if (!this.el.querySelector(".capsule-view")) return;
    if (this.el.dataset.capsuleView !== next) {
      this.el.dataset.capsuleView = next;
    }
  },

  _rootSummary() {
    return this.el.querySelector(":scope > summary");
  },

  _handleClick(event) {
    const target = event.target;
    if (!(target instanceof Element)) return;

    // 1) The collapsed trigger. A native summary click closes <details>
    // INSTANTLY, skipping the exit animation — intercept it and run the
    // animated close. Only the ROOT summary is intercepted: the mode+speed
    // capsule's nested <details class="capsule-sub"> summary is a DIFFERENT
    // element, so Layer 2 keeps its native toggle.
    const summary = target.closest("summary");
    if (summary) {
      if (summary === this._rootSummary() && this.el.open) {
        event.preventDefault();
        this.closeAnimated();
      }
      return;
    }

    // 2) Drill down into another view (e.g. the provider-profile list). The
    // row is a type="button" with no phx-click, so nothing else to do here.
    const drill = target.closest("[data-capsule-drill]");
    if (drill) {
      this.setView(drill.dataset.capsuleDrill);
      return;
    }

    // 3) Back row → the default view.
    if (target.closest("[data-capsule-back]")) {
      this.setView("model");
      return;
    }

    // 4) Picking a provider returns to the model view. Deliberately WITHOUT
    // preventDefault: the item also carries the LiveView phx-click that
    // persists the choice, so the click must reach the server; its re-render
    // then shows the freshly scoped model list. The .capsule-item fallback
    // keeps this working should an item ship without role="option".
    const option = target.closest('[role="option"], .capsule-item');
    if (option && option.closest('[data-view="provider"]')) {
      this.setView("model");
    }
  }
};

export default CapsulePanel;
