// CommitGraph hook — client side of the frozen DOM contract below, owning four
// behaviours for the commit-history view (temporal dimension) of the Agents
// page:
//
//   1. ENTER ANIMATIONS (keyframes in css/app.css) — unchanged.
//   2. ROW ↔ DOT HOVER SYNC — hovering a commit row highlights its gutter dot
//      and vice versa (event delegation keyed by `data-cg-sha`).
//   3. KEYBOARD ACTIVATION — an owned row is `role="button" tabindex="0"`;
//      Enter / Space push the SAME `select_agent` event a click would.
//   4. SCROLL-TO-SELECTION — when the selected agent id CHANGES, the agent's
//      topmost row is scrolled into view inside `.cg-scroll` (and its lane is
//      revealed horizontally when the gutter is clipped).
//
// The view is a VERTICAL, GitLen/GitKraken-style commit graph: one row per
// commit, ONE scroll container (`.cg-scroll`, both axes — the list scrolls
// vertically inside the panel and the lane header pins above the rows). There
// is NO pan/zoom, NO viewBox mutation and NO toolbar — the renderer geometry
// (the gutter `<svg class="cg-gutter">` overlay + fixed-height rows) is
// static.
//
// Markup contract (frozen — mirror of the agents_components renderer docs):
//   #commit-graph                        root (this hook's element) — rendered
//                                        ONCE per commit-view mount, persists
//                                        across LiveView patches; carries
//                                        data-cg-selected-id (the raw selected
//                                        agent id, stringified exactly like the
//                                        rows' data-cg-agent-id)
//   #commit-graph-body-<node_key>        node-scoped wrapper, replaced wholesale
//                                        on a node switch (its id changes)
//   [data-commit-graph-anim]             animated elements, value = one of
//                                        "row" | "node" | "edge":
//     div.cg-row  (row)                  one commit ROW (owned rows also carry
//                                        role="button" tabindex="0" +
//                                        data-cg-agent-id — the keyboard target)
//     g.cg-node   (node)                 one gutter commit dot (its inner
//                                        circle.cg-node-dot is the only
//                                        pointer-active part of the gutter)
//     path.cg-edge (edge)                one child → parent connector
//   .cg-row[data-cg-sha] ↔ g.cg-node[data-cg-sha]            hover-sync mates
//   .cg-scroll                           the BOTH-axis scroll container the
//                                        selection reveal targets
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

// The hover-sync class toggled on BOTH sha-mates (styled in css/app.css).
const HOVER_CLASS = "cg-hovered";

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

    // The selection the hook was mounted with. Mounting WITH a selection (the
    // view switcher revealing this panel after a select in the tree) also
    // reveals it — deferred one frame so the fresh layout has settled.
    this.lastSelectedId = this.selectedId();
    this.defer(() => this.revealSelection(this.lastSelectedId));

    this.bindHoverSync();
    this.bindKeyboard();

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
  // already-seen elements) — and the ONE place the selection reveal runs: the
  // hook element persists across patches, so a CHANGED data-cg-selected-id is
  // observed here. Only an actual change scrolls (the last-seen id guard keeps
  // user scrolling from ever being fought).
  updated() {
    this.applyAnimations(this.el);

    const selected = this.selectedId();
    if (selected !== this.lastSelectedId) {
      this.lastSelectedId = selected;
      this.revealSelection(selected);
    }
  },

  destroyed() {
    this.teardown();
  },

  // Drops the observer and leaves no animation state behind. Used both by
  // `destroyed()` and (defensively) at the top of `mounted()`. The delegated
  // listeners live on `this.el` itself, so they die with the element — nothing
  // to unbind here.
  teardown() {
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }
    if (this.el && this.el.querySelectorAll) {
      this.clearAnimations(this.el);
    }
  },

  // --- row ↔ dot hover sync --------------------------------------------------
  //
  // `mouseover` / `mouseout` (both bubble; mouseenter/leave do not) with
  // `relatedTarget` containment checks so moving WITHIN a row (or onto a child
  // chip) neither flickers nor double-toggles. Row → dot and dot → row are the
  // same operation: toggle HOVER_CLASS on every sha-mate (the .cg-row div and
  // its g.cg-node).

  bindHoverSync() {
    if (this.hoverBound) return;
    this.hoverBound = true;

    this.el.addEventListener("mouseover", (event) => {
      const from = event.target;
      if (!from || !from.closest) return;

      // The two hover sources live in DISJOINT subtrees (.cg-rows vs the
      // gutter svg), so at most one branch matches.
      const row = from.closest(".cg-row");
      if (row) {
        if (row.dataset.cgSha != null && !row.classList.contains(HOVER_CLASS)) {
          this.setHovered(row.dataset.cgSha, true);
        }
        return; // already hovered / no sha: nothing else can match
      }

      // The gutter dot is the only pointer-active gutter part (see
      // css/app.css) — hovering it highlights the dot AND its row.
      const dot = from.closest(".cg-node-dot");
      const node = dot && dot.closest("g.cg-node");
      if (node && node.dataset.cgSha != null && !node.classList.contains(HOVER_CLASS)) {
        this.setHovered(node.dataset.cgSha, true);
      }
    });

    this.el.addEventListener("mouseout", (event) => {
      const from = event.target;
      if (!from || !from.closest) return;
      const to = event.relatedTarget;

      const row = from.closest(".cg-row");
      if (row) {
        if (row.dataset.cgSha != null) {
          // Leaving the row entirely (not just moving to a descendant of it).
          if (!(to && row.contains(to))) this.setHovered(row.dataset.cgSha, false);
        }
        return;
      }

      const dot = from.closest(".cg-node-dot");
      const node = dot && dot.closest("g.cg-node");
      if (node && node.dataset.cgSha != null) {
        if (!(to && node.contains(to))) this.setHovered(node.dataset.cgSha, false);
      }
    });
  },

  // Toggles the hover class on every element carrying this sha — by ITERATION,
  // not a querySelector string: a sha is arbitrary model data and must never be
  // interpolated into a selector.
  setHovered(sha, on) {
    this.eachShaMate(sha, (el) => el.classList.toggle(HOVER_CLASS, on));
  },

  eachShaMate(sha, fn) {
    if (sha == null || !this.el.querySelectorAll) return;
    this.el.querySelectorAll("[data-cg-sha]").forEach((el) => {
      if (el.dataset.cgSha === sha && el.matches(".cg-row, g.cg-node")) fn(el);
    });
  },

  // --- keyboard activation ---------------------------------------------------
  //
  // Owned rows are `role="button" tabindex="0"` (rendered server-side); Enter
  // and Space push the SAME `select_agent` event a phx-click would, with the
  // row's own `data-cg-agent-id` (stringified identically to `phx-value-id`).
  // Space is prevented so it does not scroll the page. Nested interactive
  // elements (agent tag buttons) are skipped — the event target must BE the row.

  bindKeyboard() {
    if (this.keyBound) return;
    this.keyBound = true;

    this.el.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      if (!event.target || !event.target.closest) return;

      const row = event.target.closest(".cg-row");
      if (!row || event.target !== row) return; // a nested button owns its keys

      const id = row.dataset.cgAgentId;
      if (id == null || id === "") return; // unowned rows have no contract

      event.preventDefault();
      this.pushEvent("select_agent", {id: id});
    });
  },

  // --- scroll-to-selection ---------------------------------------------------
  //
  // Reveals the selected agent's TOPMOST row inside its `.cg-scroll` scroller
  // (vertical, keeping the sticky lane header clear) and — when the gutter is
  // horizontally clipped — scrolls the agent's lane dot into view. Runs ONLY on
  // an actual selection change (see `updated()`), so user scrolling is never
  // fought. Instant (no smooth scroll): nothing to animate, and it is
  // reduced-motion friendly by construction.

  selectedId() {
    return (this.el && this.el.dataset ? this.el.dataset.cgSelectedId : null) || null;
  },

  revealSelection(selected) {
    if (selected == null || selected === "" || !this.el.querySelectorAll) return;

    // One scroller per repo section — reveal in every one that carries a row
    // of the selected agent (an agent's commits live in exactly one repo, but
    // the lookup stays shape-agnostic).
    const rows = Array.from(this.el.querySelectorAll(".cg-row[data-cg-agent-id]")).filter(
      (row) => row.dataset.cgAgentId === selected
    );

    if (rows.length === 0) return;

    const scrolled = new Set();
    rows.forEach((row) => {
      const scroller = row.closest ? row.closest(".cg-scroll") : null;
      if (!scroller || scrolled.has(scroller)) return; // topmost row per scroller
      scrolled.add(scroller);

      this.revealVertically(scroller, row);
      this.revealLane(scroller, selected);
    });
  },

  // Scrolls the minimum needed to bring `row` inside the scroller's visible
  // strip — BELOW the sticky lane header when it is above it, up from below
  // the fold when it is under it. A row already fully visible scrolls nothing.
  revealVertically(scroller, row) {
    const sRect = scroller.getBoundingClientRect();
    const header = scroller.querySelector(".cg-lane-header");
    const headerH = header ? header.getBoundingClientRect().height : 0;
    const rRect = row.getBoundingClientRect();

    // The visible strip starts under the sticky header (it overlays the top).
    const top = sRect.top + headerH;
    const bottom = sRect.bottom;

    if (rRect.top < top) {
      scroller.scrollTop -= top - rRect.top;
    } else if (rRect.bottom > bottom) {
      scroller.scrollTop += rRect.bottom - bottom;
    }
  },

  // When the gutter is wider than the scroller (many agent lanes), reveals the
  // selected agent's lane dot horizontally. The dot's `cx` is a gutter-svg user
  // unit == a CSS pixel from the scroller's content LEFT edge (the absolutely
  // positioned svg starts at the list's left edge), so it maps 1:1 onto
  // scrollLeft coordinates.
  revealLane(scroller, selected) {
    if (scroller.scrollWidth <= scroller.clientWidth) return; // nothing clipped

    const node = Array.from(this.el.querySelectorAll("g.cg-node[data-cg-agent-id]")).find(
      (el) => el.dataset.cgAgentId === selected
    );

    const circle = node && node.querySelector("circle");
    const cx = circle ? parseFloat(circle.getAttribute("cx")) : NaN;
    if (!Number.isFinite(cx)) return;

    const left = scroller.scrollLeft;
    const right = left + scroller.clientWidth;
    if (cx >= left && cx <= right) return; // lane already visible

    scroller.scrollLeft = Math.max(0, cx - 24);
  },

  // Runs `fn` once layout has settled (rAF; the hook root may have just been
  // patched wholesale). Guarded — a hidden document never fires rAF callbacks
  // that matter, and a missing window is a no-op.
  defer(fn) {
    if (typeof window.requestAnimationFrame !== "function") return;
    window.requestAnimationFrame(() => fn());
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
