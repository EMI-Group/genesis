// CommitGraph hook: enter-animations for the SVG git-graph (temporal commit
// history) on the Agents page.
//
// Markup contract (frozen — see CommitGraphView / agents_components docs):
//   #commit-graph                    root (this hook's element)
//   #commit-graph-body-<node_key>    node-scoped wrapper (replaced wholesale
//                                     on a node switch)
//   commit-graph-repo-<slug>-<hash>  per-repo section wrapping one <svg>
//   <g id="commit-dot-…">    data-commit-graph-anim="node"  commit dot group
//   <g id="commit-ring-…">   data-commit-graph-anim="node"  agent ring group
//   <path id="commit-edge-…"> data-commit-graph-anim="edge" straight/Bézier edge
//
// The graph grows incrementally: new commits append at the BOTTOM (oldest at
// top), and LiveView's patcher (morphdom) reuses existing elements by their
// stable unique DOM ids, inserting only genuinely new ones — so ONLY newly
// inserted elements animate. A MutationObserver on the root (childList +
// subtree) sees exactly those insertions; the elements already present at
// mount never animate, and an `updated()` re-scan covers wholesale subtree
// replacements (view / node switches) without re-animating anything already
// seen (WeakSet instance guard).
//
// Animations (keyframes live in css/app.css):
//   node → fade + scale-up (`.commit-node-enter`). SVG groups have no CSS box,
//          so the hook pins the transform origin inline to the dot/ring center
//          (read from the group's first <circle> cx/cy, view-box relative —
//          every circle in these groups shares that center); a missing
//          measurable center falls back to the group's own bounding-box center
//          (transform-box: fill-box).
//   edge → stroke-draw (`.commit-edge-enter`): getTotalLength() measures the
//          path, the hook writes the inline start state (stroke-dasharray /
//          stroke-dashoffset = path length), and the CSS animation drives
//          dashoffset → 0 — drawing the edge from its start point (the new
//          child commit, below) up to its parent. Unmeasurable paths (no
//          getTotalLength / degenerate geometry) fall back to a plain fade.
//
// Per-element animation state (class + inline styles) is removed when the
// animation settles (animationend OR animationcancel), when the element is
// detached mid-flight, and on hook teardown — so no element can ever render
// stuck at its hidden start state. prefers-reduced-motion is checked in JS
// before touching the DOM (css/app.css carries the matching guard too).

const NODE_CLASS = "commit-node-enter";
const EDGE_CLASS = "commit-edge-enter";
const EDGE_FADE_CLASS = "commit-edge-fade";

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
      else if (kind === "edge") this.animateEdge(el); // unknown kinds ignored
    });
  },

  // --- node (commit dot / agent ring <g>) ---------------------------------

  animateNode(group) {
    // SVG groups have no CSS box: pin the scale origin to the dot/ring center.
    // Every circle in these groups (halo, glow band, dot, ring) shares the
    // same cx/cy, so the first one always carries the center; view-box
    // relative coordinates match the untransformed user units the SVG uses.
    const circle = group.querySelector("circle");
    const cx = circle ? parseFloat(circle.getAttribute("cx")) : NaN;
    const cy = circle ? parseFloat(circle.getAttribute("cy")) : NaN;

    this.onAnimationSettled(group, () => this.clearNodeState(group));

    if (Number.isFinite(cx) && Number.isFinite(cy)) {
      group.style.transformBox = "view-box";
      group.style.transformOrigin = cx + "px " + cy + "px";
    } else {
      // No measurable center: scale around the group's own bounding box.
      group.style.transformBox = "fill-box";
      group.style.transformOrigin = "center";
    }

    group.classList.add(NODE_CLASS);
  },

  clearNodeState(group) {
    group.classList.remove(NODE_CLASS);
    group.style.removeProperty("transform-box");
    group.style.removeProperty("transform-origin");
  },

  // --- edge (child→parent <path>) ------------------------------------------

  animateEdge(path) {
    const length = this.edgeLength(path);

    this.onAnimationSettled(path, () => {
      path.classList.remove(length > 0 ? EDGE_CLASS : EDGE_FADE_CLASS);
      path.style.removeProperty("stroke-dasharray");
      path.style.removeProperty("stroke-dashoffset");
    });

    if (length > 0) {
      // Start state: one dash exactly the path length, fully offset (hidden).
      // The CSS animation drives dashoffset → 0, revealing the path from its
      // start point (the new child commit) up to its parent; the animation's
      // implicit 0% keyframe is synthesized from this inline base value.
      path.style.strokeDasharray = String(length);
      path.style.strokeDashoffset = String(length);
      path.classList.add(EDGE_CLASS);
    } else {
      // Unmeasurable geometry (no getTotalLength / non-positive length):
      // fade in instead, so edges never pop in harder than dots do.
      path.classList.add(EDGE_FADE_CLASS);
    }
  },

  // getTotalLength is pure path geometry, but older engines can throw on
  // paths they refuse to measure — never let that break the page.
  edgeLength(path) {
    if (typeof path.getTotalLength !== "function") return 0;
    try {
      const length = path.getTotalLength();
      return isFinite(length) && length > 0 ? length : 0;
    } catch (_error) {
      return 0;
    }
  },

  // --- shared helpers --------------------------------------------------------

  // Clears any animation state from `root` and every marked descendant — used
  // for detached elements and hook teardown.
  clearAnimations(root) {
    this.eachMarked(root, (el) => {
      el.classList.remove(NODE_CLASS, EDGE_CLASS, EDGE_FADE_CLASS);
      el.style.removeProperty("transform-box");
      el.style.removeProperty("transform-origin");
      el.style.removeProperty("stroke-dasharray");
      el.style.removeProperty("stroke-dashoffset");
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
