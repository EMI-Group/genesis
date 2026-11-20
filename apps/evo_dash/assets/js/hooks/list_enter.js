// ListEnter owns the SHARED entry animation for server-rendered lists (task
// cards, conversation rows, process rows) — never scrolling, never ordering.
//
// DOM contract (the Elixir side owns the attributes; this hook only reads them):
//   * the hook mounts on a LIST WRAPPER carrying a nonempty
//     data-list-enter-scope (e.g. "<node>|<project>"). An empty/absent scope is
//     deliberately INERT: nothing animates, keys are still remembered.
//   * each row carries data-list-enter-key="<stable unique key>" — stable
//     across text/token patches and DOM replacements.
//   * rows that are NEW in the CURRENT scope get the class motion-list-enter;
//     its keyframes and timings come from the shared motion foundation
//     (assets/css/motion.css), the rule itself lives in app.css.
// A scope change (project / node / session switch) seeds a fresh baseline
// instead of animating the whole list, so the first paint of a new scope stays
// silent and only later insertions move.
import {prefersReducedMotion} from "./disclosure_motion.js"

// --- ListEnter: pure insertion planning
// Decides which keys are genuinely new in the CURRENT scope. Total and
// side-effect free so `list_enter.test.cjs` can run this block through node:vm.
// `seen` is never mutated: the returned Set is a NEW one, and a scope change
// re-seeds it from the current keys alone (nothing carries over from the old
// scope). Empty and non-string keys are ignored; the first occurrence of a key
// wins. `animate` keeps the input order.
function planListEnter(plan = {}) {
  const {scope, previousScope, keys, seen, reducedMotion} = plan || {}
  // The FIRST snapshot (previousScope undefined) and any scope change are
  // baseline-only: nothing animates and the old scope's keys are dropped.
  const changedScope = scope !== previousScope
  // Duck-typed on purpose: the node:vm test slices this block into another
  // realm, where `seen instanceof Set` would be false.
  const current = seen && typeof seen.has === "function" && typeof seen[Symbol.iterator] === "function"
    ? seen
    : new Set()
  const nextSeen = changedScope ? new Set() : new Set(current)
  // Only a genuinely new key in an unchanged, nonempty scope may enter.
  const animates = !changedScope && !reducedMotion && Boolean(scope)
  const animate = []
  if (!Array.isArray(keys)) return {changedScope, seen: nextSeen, animate}

  const queued = new Set()
  for (const key of keys) {
    if (typeof key !== "string" || key === "") continue
    // A scope change ignores the old baseline entirely: the current rows are
    // re-seeded from scratch, so nothing carries over.
    if (!changedScope && current.has(key)) continue
    if (queued.has(key)) continue
    queued.add(key)
    nextSeen.add(key)
    if (animates) animate.push(key)
  }
  return {changedScope, seen: nextSeen, animate}
}
// ListEnter hook:

const LIST_ENTER_CLASS = "motion-list-enter"
const SCOPE_ATTR = "data-list-enter-scope"
const KEY_ATTR = "data-list-enter-key"
const ROW_SELECTOR = "[data-list-enter-key]"

const ListEnter = {
  mounted() {
    this.teardown();
    if (!this.el) return;

    this.active = new Map();
    this.seen = new Set();
    this.scope = undefined;
    this.reconcile(); // First snapshot is a baseline, not an insertion.

    this.observer = new MutationObserver(() => this._schedule());
    this.observer.observe(this.el, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: [SCOPE_ATTR, KEY_ATTR]
    });
  },
  updated() {
    this._schedule();
  },
  destroyed() {
    this.teardown();
  },

  // ONE coalesced frame per burst of mutations: a patch that appends ten rows
  // plans once, so the first reconcile already sees the final list.
  _schedule() {
    if (this._frame) return;
    if (typeof requestAnimationFrame !== "function") {
      this.reconcile();
      return;
    }
    this._frame = requestAnimationFrame(() => {
      this._frame = null;
      this.reconcile();
    });
  },

  reconcile() {
    if (!this.el || !this.seen || typeof this.el.querySelectorAll !== "function") return;
    const scope = this.el.dataset.listEnterScope || "";

    // First element per key wins: a key is one row, never two.
    const rows = new Map();
    this.el.querySelectorAll(ROW_SELECTOR).forEach((el) => {
      const key = el.dataset.listEnterKey;
      if (!key || rows.has(key)) return;
      rows.set(key, el);
    });

    const plan = planListEnter({
      scope,
      previousScope: this.scope,
      keys: Array.from(rows.keys()),
      seen: this.seen,
      reducedMotion: prefersReducedMotion()
    });

    // Release listeners on detached / re-keyed rows before their animation ends.
    this.active.forEach(({key}, el) => {
      if (!this.el.contains(el) || el.dataset.listEnterKey !== key) {
        this.clearAnimation(el);
      }
    });
    if (plan.changedScope) this.clearAnimations();

    // Scope bookkeeping happens even for an inert (unscoped) wrapper.
    this.seen = plan.seen;
    this.scope = scope;
    if (!scope) return; // An unscoped wrapper is deliberately inert.

    plan.animate.forEach((key) => {
      const el = rows.get(key);
      if (el) this.animate(el, key);
    });
  },
  animate(el, key) {
    const settled = (event) => {
      if (event.target === el) this.clearAnimation(el);
    };
    this.active.set(el, {key, settled});
    el.addEventListener("animationend", settled);
    el.addEventListener("animationcancel", settled);
    el.classList.add(LIST_ENTER_CLASS);
  },
  clearAnimation(el) {
    const entry = this.active.get(el);
    if (!entry) return;
    el.removeEventListener("animationend", entry.settled);
    el.removeEventListener("animationcancel", entry.settled);
    el.classList.remove(LIST_ENTER_CLASS);
    this.active.delete(el);
  },
  clearAnimations() {
    if (this.active) this.active.forEach((_entry, el) => this.clearAnimation(el));
  },

  teardown() {
    if (this._frame && typeof cancelAnimationFrame === "function") {
      cancelAnimationFrame(this._frame);
    }
    this._frame = null;
    if (this.observer) this.observer.disconnect();
    this.observer = null;
    this.clearAnimations();
    if (this.seen) this.seen.clear();
    this.seen = null;
    this.scope = undefined;
  }
};

export {LIST_ENTER_CLASS, planListEnter}
export default ListEnter;
