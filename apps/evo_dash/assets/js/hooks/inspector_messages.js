// InspectorMessages owns entry animation only — never scrolling.
// Mount on a wrapper with a nonempty data-inspector-scope (node + agent/session
// identity). Descendants carry data-inspector-message="<stable unique key>".
// Keys must stay unchanged across text/token patches and DOM replacements.
const MESSAGE_SELECTOR = "[data-inspector-message]";
const ENTER_CLASS = "inspector-message-enter";

const InspectorMessages = {
  mounted() {
    this.teardown();
    if (!this.el) return;

    this.active = new Map();
    this.seen = new Set();
    this.scope = undefined;
    this.reconcile(); // First snapshot is a baseline, not an insertion.

    this.motion = typeof window.matchMedia === "function"
      ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;
    this.onMotionChange = () => {
      if (this.motion.matches) this.clearAnimations();
    };
    if (this.motion && this.motion.addEventListener) {
      this.motion.addEventListener("change", this.onMotionChange);
    }

    this.observer = new MutationObserver(() => this.reconcile());
    this.observer.observe(this.el, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["data-inspector-scope", "data-inspector-message"]
    });
  },

  updated() {
    this.reconcile();
  },

  destroyed() {
    this.teardown();
  },

  reconcile() {
    if (!this.el || !this.seen) return;
    const scope = this.el.dataset.inspectorScope || "";
    const changedScope = scope !== this.scope;
    if (changedScope) {
      this.clearAnimations();
      this.seen.clear();
      this.scope = scope;
    }

    // Also release listeners on detached entries before their animation ends.
    this.active.forEach(({key}, el) => {
      if (!this.el.contains(el) || el.dataset.inspectorMessage !== key) {
        this.clearAnimation(el);
      }
    });
    if (!scope) return; // An unscoped wrapper is deliberately inert.

    this.el.querySelectorAll(MESSAGE_SELECTOR).forEach((el) => {
      const key = el.dataset.inspectorMessage;
      if (!key || this.seen.has(key)) return;
      // Remember keys even under reduced motion, and across removal/reinsertion
      // or morphdom replacing a node. Only a NEW key in this scope can enter.
      this.seen.add(key);
      if (changedScope || (this.motion && this.motion.matches)) return;
      this.animate(el, key);
    });
  },

  animate(el, key) {
    const settled = (event) => {
      if (event.target === el) this.clearAnimation(el);
    };
    this.active.set(el, {key, settled});
    el.addEventListener("animationend", settled);
    el.addEventListener("animationcancel", settled);
    el.classList.add(ENTER_CLASS);
  },

  clearAnimation(el) {
    const entry = this.active.get(el);
    if (!entry) return;
    el.removeEventListener("animationend", entry.settled);
    el.removeEventListener("animationcancel", entry.settled);
    el.classList.remove(ENTER_CLASS);
    this.active.delete(el);
  },

  clearAnimations() {
    if (this.active) this.active.forEach((_entry, el) => this.clearAnimation(el));
  },

  teardown() {
    if (this.observer) this.observer.disconnect();
    this.observer = null;
    if (this.motion && this.motion.removeEventListener && this.onMotionChange) {
      this.motion.removeEventListener("change", this.onMotionChange);
    }
    this.motion = null;
    this.onMotionChange = null;
    this.clearAnimations();
    if (this.seen) this.seen.clear();
    this.seen = null;
  }
};

export default InspectorMessages;
