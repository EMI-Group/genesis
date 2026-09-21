// CommitGraph hook: enter-animations for the commit-history visualization.
//
// The markup grows incrementally — LiveView patches new commit nodes / lane
// segments into a keyed `phx-update="append"` container as agents commit — so
// only NEWLY INSERTED elements must animate. A MutationObserver on the root
// (#commit-graph, `childList` + `subtree`) sees exactly those insertions; the
// elements already present at mount never animate, and a `updated()` re-scan
// covers wholesale re-renders (e.g. a full view switch that replaces the
// subtree) without re-animating anything already seen.
//
// Markup scope: any element carrying `data-commit-graph-anim` ("node" | "lane"
// | "edge") — either as a directly added child or anywhere inside an added
// subtree.

// data-commit-graph-anim value -> enter-animation class (defined in css/app.css).
const ANIMATION_CLASSES = {
  node: "commit-node-enter",
  lane: "commit-lane-enter",
  edge: "commit-edge-enter"
};

const CommitGraph = {
  mounted() {
    if (!this.el) return;

    // Everything rendered by the initial page load is NOT new — remember those
    // element instances so a later `updated()` re-scan can never animate them.
    // A WeakSet keeps this leak-free (removed nodes are collected).
    this.seen = new WeakSet();
    this.eachMarked(this.el, (el) => this.seen.add(el));

    // Added nodes arrive one-by-one via `addedNodes`; nodes inside an appended
    // subtree are covered by the descendant walk in `applyAnimations`.
    this.observer = new MutationObserver((mutations) => {
      mutations.forEach((mutation) => {
        mutation.addedNodes.forEach((added) => {
          if (added.nodeType === Node.ELEMENT_NODE) this.applyAnimations(added);
        });
      });
    });
    this.observer.observe(this.el, {childList: true, subtree: true});
  },

  // morphdom may replace the subtree wholesale without the observed root itself
  // changing (view switch), so re-scan on every update. Cheap + idempotent:
  // already-seen elements are skipped and `classList.add` never duplicates.
  updated() {
    this.applyAnimations(this.el);
  },

  // The observer must live for the lifetime of the hook (patches keep arriving).
  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }
  },

  // Adds the matching enter-animation class to every NOT-YET-SEEN marked
  // element in `root` (root included, marked descendants included).
  applyAnimations(root) {
    if (!root) return;

    // Belt and braces: css/app.css also carries a `prefers-reduced-motion`
    // guard, but respect the user setting before touching the DOM at all.
    const reduce = this.reducedMotion();

    this.eachMarked(root, (el) => {
      if (this.seen.has(el)) return; // preserve-motion: only genuinely new nodes
      this.seen.add(el); // recorded even under reduced motion (see above)
      if (reduce) return;

      const className = ANIMATION_CLASSES[el.dataset.commitGraphAnim];
      if (className) el.classList.add(className); // unknown kinds are ignored
    });
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
