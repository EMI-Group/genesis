// CommitGraph hook: enter-animations for the horizontal "agent swimlane"
// commit-history view (temporal dimension) on the Agents page.
//
// Markup contract (frozen — see CommitGraphView / agents_components docs):
//   #commit-graph                       root (this hook's element)
//   #commit-graph-body-<node_key>       node-scoped wrapper (replaced wholesale
//                                       on a node switch)
//   data-commit-graph-anim="node"       a commit marker element (plain HTML,
//                                       e.g. a small <div>/<span>)
//   data-commit-graph-anim="lane"       an agent's horizontal progress element
//
// The view grows incrementally: new elements append at the end, and LiveView's
// patcher (morphdom) reuses existing elements by their stable unique DOM ids,
// inserting only genuinely new ones — so ONLY newly inserted elements animate.
// A MutationObserver on the root (childList + subtree) sees exactly those
// insertions; the elements already present at mount never animate, and an
// `updated()` re-scan covers wholesale subtree replacements (view / node
// switches) without re-animating anything already seen (WeakSet instance
// guard).
//
// Animations (keyframes live in css/app.css — HTML-only, no SVG geometry):
//   node → fade + scale-up around the element's own center
//          (`.commit-node-enter`). Plain HTML accepts a CSS transform origin
//          as-is, so no inline origin pinning is needed.
//   lane → horizontal GROW-IN from the LEFT (`.commit-lane-enter`): the CSS
//          animation scales `transform: scaleX(0) → scaleX(1)` with
//          `transform-origin: left center`, so the bar grows out from its
//          leading edge. Purely a class add — nothing to measure, nothing that
//          can fail.
//
// Per-element animation state (class) is removed when the animation settles
// (animationend OR animationcancel) and on hook teardown — so no element can
// ever render stuck at its hidden start state. prefers-reduced-motion is
// checked in JS before touching the DOM (css/app.css carries the matching
// guard too).

const NODE_CLASS = "commit-node-enter";
const LANE_CLASS = "commit-lane-enter";

const CommitGraph = {
  mounted() {
    if (!this.el) return;

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
  // itself changing (view / node switch), so re-scan on every update. Cheap +
  // idempotent: already-seen elements are skipped.
  updated() {
    this.applyAnimations(this.el);
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }
    // Leave no animation state behind on whatever owns the DOM after us.
    if (this.el) this.clearAnimations(this.el);
  },

  // Runs the matching enter-animation on every NOT-YET-SEEN marked element in
  // `root` (root included, marked descendants included).
  applyAnimations(root) {
    if (!root || !root.querySelectorAll) return;

    // Belt and braces: css/app.css also carries a `prefers-reduced-motion`
    // guard, but respect the user setting before touching the DOM at all.
    const reduce = this.reducedMotion();

    this.eachMarked(root, (el) => {
      if (this.seen.has(el)) return; // preserve-motion: only genuinely new nodes
      this.seen.add(el); // recorded even under reduced motion (see above)
      if (reduce) return;
      if (!el.isConnected) return; // detached again before the observer ran

      const kind = el.dataset.commitGraphAnim;
      if (kind === "node") this.animateNode(el);
      else if (kind === "lane") this.animateLane(el); // unknown kinds ignored
    });
  },

  // --- node (commit marker element) ---------------------------------------

  animateNode(el) {
    // Plain HTML: the CSS keyframe scales around the element's own center, so
    // there is no SVG transform origin to pin inline. Just opt the element
    // into the animation and let it settle back to its base state.
    this.onAnimationSettled(el, () => this.clearAnimations(el));
    el.classList.add(NODE_CLASS);
  },

  // --- lane (agent horizontal progress element) ---------------------------

  animateLane(el) {
    // Unconditional class add: the CSS keyframe drives scaleX 0 → 1 from the
    // left edge. Nothing to measure, so nothing can fail.
    this.onAnimationSettled(el, () => this.clearAnimations(el));
    el.classList.add(LANE_CLASS);
  },

  // --- shared helpers --------------------------------------------------------

  // Clears any animation state from `root` and every marked descendant — used
  // for detached elements and hook teardown.
  clearAnimations(root) {
    this.eachMarked(root, (el) => {
      el.classList.remove(NODE_CLASS, LANE_CLASS);
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
    if (root.matches("[data-commit-graph-anim]")) fn(root);
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
