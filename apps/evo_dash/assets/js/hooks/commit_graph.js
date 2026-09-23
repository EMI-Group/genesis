// CommitGraph hook: ENTER ANIMATIONS ONLY for the commit-history view (temporal
// dimension) of the Agents page — client side of the frozen DOM contract below.
//
// The view is a VERTICAL, GitLen/GitKraken-style commit graph: one row per
// commit, scrolled natively by the page. There is NO pan/zoom, NO viewBox
// mutation, NO toolbar and NO pointer-drag handling — the renderer geometry
// (the gutter `<svg class="cg-gutter">` overlay + fixed-height rows) is static.
//
// Markup contract (frozen — mirror of the agents_components renderer docs):
//   #commit-graph                        root (this hook's element) — rendered
//                                        ONCE and PERSISTS across a node switch
//                                        and every LiveView patch
//   #commit-graph-body-<node_key>        node-scoped wrapper, replaced wholesale
//                                        on a node switch (its id changes)
//   [data-commit-graph-anim]             animated elements, value = one of
//                                        "row" | "node" | "edge":
//     div.cg-row  (row)                  one commit ROW
//     g.cg-node   (node)                 one gutter commit dot
//     path.cg-edge (edge)                one child → parent connector
//   State blocks #commit-graph-error / #commit-graph-stale-warning are ignored
//   (no graph → nothing to do → never throw).
//
// ENTER ANIMATIONS (keyframes live in css/app.css): a MutationObserver on the
// root (childList + subtree) animates only genuinely-new marked elements
// (WeakSet instance guard — the elements present at mount and an `updated()`
// re-scan never re-animate). The keyframes differ per element type:
//   row  → fade + slide-up (an HTML element with a CSS box)
//   node → fade + scale-up around the element's own center (an SVG <g>: SVG has
//          no CSS box, so the keyframe pins `transform-box: fill-box` +
//          `transform-origin`)
//   edge → plain opacity fade-in — robust for both <path> and <polyline>:
//          nothing measured, nothing that can fail
// Per-element animation state (class) is removed when the animation settles
// (animationend OR animationcancel), on observer-removed nodes, and in
// `destroyed()` — no element can render stuck at its hidden start state.
// prefers-reduced-motion is honoured in JS (nothing is added) and in
// css/app.css (the matching guard). Every step is guarded: any DOM shape (a
// missing root, detached nodes, unknown `data-commit-graph-anim` values) is a
// silent no-op and the hook never throws.

// Animation class per `data-commit-graph-anim` value (unknown kinds ignored).
const ENTER_CLASS = {
  row: "commit-row-enter",
  node: "commit-node-enter",
  edge: "commit-edge-enter"
};

const CommitGraph = {
  mounted() {
    if (!this.el) return;

    // Idempotent-safe: drop any previous bindings before setting up.
    this.teardown();

    // Everything rendered by the initial page load is NOT new — remember those
    // element instances so neither the observer nor an `updated()` re-scan can
    // ever animate them. A WeakSet keeps this leak-free (removed nodes are
    // collected); a re-inserted instance stays "seen" and does not re-animate.
    this.seen = new WeakSet();
    this.eachMarked(this.el, (el) => this.seen.add(el));

    this.observer = new MutationObserver((mutations) => {
      mutations.forEach((mutation) => {
        // Removed elements may be mid-animation (a node switch replaces the
        // whole subtree): clear their animation state so a later re-insert of
        // the same instance can never render as a stuck/invisible element.
        mutation.removedNodes.forEach((removed) => {
          if (removed.nodeType === Node.ELEMENT_NODE) this.clearAnimations(removed);
        });
        // Added nodes arrive one-by-one via `addedNodes`; marked nodes inside
        // an appended subtree are covered by the descendant walk in
        // applyAnimations.
        mutation.addedNodes.forEach((added) => {
          if (added.nodeType === Node.ELEMENT_NODE) this.applyAnimations(added);
        });
      });
    });
    this.observer.observe(this.el, {childList: true, subtree: true});
  },

  // morphdom may replace the subtree wholesale without the observed root
  // itself changing (node switch / new commits), so re-scan on every update.
  // Cheap + idempotent for the animations (the WeakSet makes it a no-op for
  // already-seen elements).
  updated() {
    this.applyAnimations(this.el);
  },

  destroyed() {
    this.teardown();
  },

  // Drops the observer and leaves no animation state behind. Used both by
  // `destroyed()` and (defensively) at the top of `mounted()`.
  teardown() {
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }
    if (this.el && this.el.querySelectorAll) {
      this.clearAnimations(this.el);
    }
  },

  // --- enter animations ------------------------------------------------------

  // Runs the matching enter-animation on every NOT-YET-SEEN marked element in
  // `root` (root included, marked descendants included).
  applyAnimations(root) {
    if (!root || !root.querySelectorAll || !this.seen) return;

    // Belt and braces: css/app.css also carries a `prefers-reduced-motion`
    // guard, but respect the user setting before touching the DOM at all.
    const reduce = this.reducedMotion();

    this.eachMarked(root, (el) => {
      if (this.seen.has(el)) return; // only genuinely new elements animate
      this.seen.add(el); // recorded even under reduced motion (see above)
      if (reduce) return;
      if (!el.isConnected) return; // detached again before the observer ran

      const cls = ENTER_CLASS[el.dataset.commitGraphAnim];
      if (!cls) return; // unknown kinds ignored

      this.onAnimationSettled(el, () => this.clearAnimations(el));
      el.classList.add(cls);
    });
  },

  // Clears any animation state from `root` and every marked descendant — used
  // for detached elements and hook teardown.
  clearAnimations(root) {
    if (!root) return;
    this.eachMarked(root, (el) => {
      el.classList.remove(ENTER_CLASS.row, ENTER_CLASS.node, ENTER_CLASS.edge);
    });
  },

  // Runs `fn` once the element's own animation settles — normally
  // (animationend) or abnormally (animationcancel, e.g. the reduced-motion
  // media query yanking `animation` mid-flight). Animation events bubble, so
  // the target check keeps cleanup tied to THIS element's animation only.
  onAnimationSettled(el, fn) {
    const onSettled = (event) => {
      if (event.target !== el) return;
      el.removeEventListener("animationend", onSettled);
      el.removeEventListener("animationcancel", onSettled);
      fn();
    };
    el.addEventListener("animationend", onSettled);
    el.addEventListener("animationcancel", onSettled);
  },

  // Walks `root` and every `[data-commit-graph-anim]` descendant, calling `fn`.
  eachMarked(root, fn) {
    if (!root || !root.querySelectorAll) return;
    if (root.matches && root.matches("[data-commit-graph-anim]")) fn(root);
    root.querySelectorAll("[data-commit-graph-anim]").forEach(fn);
  },

  reducedMotion() {
    return (
      typeof window.matchMedia === "function" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    );
  }
};

export default CommitGraph;
