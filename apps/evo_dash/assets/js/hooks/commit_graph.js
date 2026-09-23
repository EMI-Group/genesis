// CommitGraph hook: interactive, COMMIT-CENTRIC SVG DAG viewer (GitKraken-style)
// for the commit-history view (temporal dimension) of the Agents page — client
// side of the frozen DOM contract below. Responsibilities: enter animations +
// pan/zoom/fit. All interaction is CLIENT-SIDE — no server round-trips.
//
// Markup contract (frozen — mirror of the agents_components renderer docs):
//   #commit-graph                        root (this hook's element) — rendered
//                                        ONCE and PERSISTS across a node switch
//                                        and every LiveView patch
//   #commit-graph-body-<node_key>        node-scoped wrapper, replaced wholesale
//                                        on a node switch (its id changes)
//   .cg-graph[data-cg-repo-id]           one block per repo (0..n per page —
//                                        each handled independently)
//     [data-cg-action="zoom-in"]         zoom toolbar buttons (type="button")
//     [data-cg-action="zoom-out"]        — handled in a capture-phase click
//     [data-cg-action="fit"]               on the root (no server event)
//     .cg-zoom-readout                   optional zoom readout (text written by
//                                        this hook, "<n>%")
//     svg.cg-svg                         the pan/zoom surface; the hook mutates
//                                        ITS viewBox (never a group transform)
//       g.cg-viewport                    sole child — holds ALL content
//         path.cg-edge[data-commit-graph-anim="edge"]  (or <polyline>)
//         g.cg-node[data-commit-graph-anim="node"]     (+ <title> tooltip)
//         g.cg-lane[data-commit-graph-anim="lane"]     (+ <title> tooltip)
//   State blocks #commit-graph-error / #commit-graph-stale-warning are ignored
//   (no graph → nothing to do → never throw).
//
// PAN/ZOOM MECHANISM (frozen): the view is the `<svg class="cg-svg">` `viewBox`
// (x, y, w, h) — NEVER a transform on `.cg-viewport`. The renderer sets a
// sensible initial viewBox (content bounds + padding); that width is the 100%
// zoom baseline. Screen→user coordinates always go through
// `svg.getScreenCTM().inverse()` + `svg.createSVGPoint()` (correct under
// `preserveAspectRatio`):
//   * PAN   — pointer drag on the svg updates viewBox x/y. The svg's linear
//             scale is unchanged while panning, so the pointerdown inverse maps
//             the whole drag. Deliberately NO `setPointerCapture` on the svg
//             (it would hijack the `phx-click` on nodes/lanes): temporary
//             window listeners instead, plus a one-shot click suppression so a
//             drag never triggers `select_agent`.
//   * ZOOM  — mouse wheel about the CURSOR and the +/- buttons about the svg
//             center. Uniform scale (aspect preserved) clamped to
//             MIN_SCALE..MAX_SCALE relative to the initial viewBox width.
//   * FIT   — recompute the content bbox from `.cg-viewport.getBBox()` (+ a
//             small margin, aspect-matched to the rendered box).
//   * The user's view is PRESERVED across incremental `updated()` patches (never
//             jumps when new commits arrive) and reset only on `fit` / when the
//             node-scoped wrapper id changes (a new node's graph).
//
// ENTER ANIMATIONS (keyframes live in css/app.css): a MutationObserver on the
// root (childList + subtree) animates only genuinely-new marked elements
// (`data-commit-graph-anim` = "node" | "lane" | "edge"; WeakSet instance guard
// — the elements present at mount and an `updated()` re-scan never re-animate).
// SVG elements have no CSS box, so the keyframes pin `transform-box: fill-box`
// + a concrete `transform-origin` to scale around the element's own box:
//   node → fade + scale-up around the element's own center (.commit-node-enter)
//   lane → horizontal GROW-IN from the LEFT (.commit-lane-enter)
//   edge → plain opacity fade-in (.commit-edge-enter) — robust for both <path>
//          and <polyline>: nothing measured, nothing that can fail
// Per-element animation state (class) is removed when the animation settles
// (animationend OR animationcancel), on observer-removed nodes, and in
// `destroyed()` — no element can render stuck at its hidden start state.
// prefers-reduced-motion is honoured in JS (nothing is added) and in
// css/app.css (the matching guard).

// Animation class per `data-commit-graph-anim` value (unknown kinds ignored).
const ENTER_CLASS = {
  node: "commit-node-enter",
  lane: "commit-lane-enter",
  edge: "commit-edge-enter"
};

// Zoom clamp, relative to the renderer's INITIAL viewBox width (= 100%).
const MIN_SCALE = 0.2;
const MAX_SCALE = 20;
const WHEEL_STEP = 1.1;
const BUTTON_STEP = 1.2;
// Pointer movement (px) before a press counts as a pan (below = a click).
const DRAG_THRESHOLD_PX = 3;
// Content bbox padding used by FIT (5% of the bbox on each side).
const FIT_MARGIN = 0.05;

const round3 = (n) => Math.round(n * 1000) / 1000;

const CommitGraph = {
  mounted() {
    if (!this.el) return;

    // Idempotent-safe: drop any previous bindings before setting up.
    this.teardown();

    // Per-repo view state: repo id → {view: {x, y, w, h}, baseW}. Cleared
    // whenever the node-scoped wrapper id changes (a different node's graph).
    this.views = new Map();
    this.bodyId = null;
    this.drag = null;
    this.suppressClick = false;
    this.suppressTimer = null;

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

    // ONE delegated set of listeners on the (persistent) root — newly added
    // `.cg-graph` blocks are covered without any per-block rebinding.
    this.bindEvents();

    // Capture each graph's initial (renderer-provided) viewBox.
    this.syncGraphs();
  },

  // morphdom may replace the subtree wholesale without the observed root
  // itself changing (node switch / new commits), so re-scan on every update.
  // Cheap + idempotent for the animations; the pan/zoom state is re-applied so
  // the view never jumps on a patch.
  updated() {
    this.applyAnimations(this.el);
    this.syncGraphs();
  },

  destroyed() {
    this.teardown();
  },

  // --- listener lifecycle ----------------------------------------------------

  bindEvents() {
    this.onPointerDown = (event) => this.handlePointerDown(event);
    this.onWheel = (event) => this.handleWheel(event);
    this.onClickCapture = (event) => this.handleClickCapture(event);

    this.el.addEventListener("pointerdown", this.onPointerDown);
    // Non-passive: zooming must own the gesture (no page scroll).
    this.el.addEventListener("wheel", this.onWheel, {passive: false});
    // Capture phase: handles the zoom toolbar AND suppresses the click that
    // trails a pan (before it can reach the node's phx-click).
    this.el.addEventListener("click", this.onClickCapture, true);
  },

  unbindEvents() {
    if (!this.el) return;
    if (this.onPointerDown) this.el.removeEventListener("pointerdown", this.onPointerDown);
    if (this.onWheel) this.el.removeEventListener("wheel", this.onWheel, {passive: false});
    if (this.onClickCapture) this.el.removeEventListener("click", this.onClickCapture, true);
    this.onPointerDown = null;
    this.onWheel = null;
    this.onClickCapture = null;
  },

  // Drops every listener, observer and transient state. Used both by
  // `destroyed()` and (defensively) at the top of `mounted()`.
  teardown() {
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }
    this.unbindEvents();
    this.endDrag();
    if (this.suppressTimer) {
      clearTimeout(this.suppressTimer);
      this.suppressTimer = null;
    }
    this.suppressClick = false;
    // Leave no animation/drag state behind on whatever owns the DOM after us.
    if (this.el && this.el.querySelectorAll) {
      this.el.querySelectorAll(".cg-svg.cg-dragging").forEach((svg) => {
        svg.classList.remove("cg-dragging");
      });
      this.clearAnimations(this.el);
    }
  },

  // --- pan / zoom ------------------------------------------------------------

  // Re-applies every stored view (and initializes brand-new graphs) after a
  // render. A changed node wrapper invalidates all stored views.
  syncGraphs() {
    if (!this.el || !this.views) return;

    const body = this.el.querySelector('[id^="commit-graph-body-"]');
    const bodyId = body ? body.id : null;
    if (bodyId !== this.bodyId) {
      // Node switch (or first paint): the graphs now belong to a different
      // node — never leak the previous node's pan/zoom onto them.
      this.bodyId = bodyId;
      this.views.clear();
    }

    this.el.querySelectorAll(".cg-graph").forEach((graph) => {
      const svg = graph.querySelector("svg.cg-svg");
      if (!svg) return;
      const state = this.stateFor(svg);
      if (!state) return; // no geometry yet (empty / error state) — nothing to do
      this.applyView(svg, state.view);
      this.updateReadout(svg);
    });
  },

  // Stored view state for the graph owning `svg`, lazily initialized from the
  // renderer's initial viewBox (or the content bbox when none is set). The
  // initial width is remembered as the 100% zoom baseline.
  stateFor(svg) {
    const graph = svg && svg.closest ? svg.closest(".cg-graph") : null;
    if (!graph || !this.views) return null;

    const repoId = this.repoKey(graph);
    let state = this.views.get(repoId);
    if (state) return state;

    const vb = svg.viewBox && svg.viewBox.baseVal;
    let view = null;
    if (vb && isFinite(vb.width) && vb.width > 0 && isFinite(vb.height) && vb.height > 0) {
      view = {x: vb.x, y: vb.y, w: vb.width, h: vb.height};
    } else {
      view = this.contentView(svg);
    }
    if (!view) return null;

    state = {view: view, baseW: view.w};
    this.views.set(repoId, state);
    return state;
  },

  setView(svg, view) {
    const state = this.stateFor(svg);
    if (state) state.view = view;
    this.applyView(svg, view);
  },

  applyView(svg, view) {
    if (!svg || !view) return;
    // The whole pan/zoom mechanism — the renderer sets the initial value, the
    // hook owns it from then on.
    svg.setAttribute(
      "viewBox",
      `${round3(view.x)} ${round3(view.y)} ${round3(view.w)} ${round3(view.h)}`
    );
  },

  // Uniform zoom about the user-space point `p`, clamped to MIN_SCALE..MAX_SCALE
  // *relative to the initial width* (clamping the factor keeps `p` pinned).
  zoomAt(view, p, factor, baseW) {
    const base = baseW > 0 ? baseW : view.w;
    const wMin = base / MAX_SCALE;
    const wMax = base / MIN_SCALE;
    let target = view.w * factor;
    if (target < wMin) target = wMin;
    if (target > wMax) target = wMax;
    const f = view.w > 0 ? target / view.w : 1;
    const w = view.w * f;
    const h = view.h * f;
    // Keep the point under `p` fixed: its fractional position in the view is
    // preserved in the new (smaller/larger) view.
    const fx = view.w > 0 ? (p.x - view.x) / view.w : 0.5;
    const fy = view.h > 0 ? (p.y - view.y) / view.h : 0.5;
    return {x: p.x - fx * w, y: p.y - fy * h, w: w, h: h};
  },

  handleWheel(event) {
    if (!this.el || !event.target || !event.target.closest) return;
    const svg = event.target.closest("svg.cg-svg");
    if (!svg || !this.el.contains(svg)) return;
    const state = this.stateFor(svg);
    if (!state) return;
    const p = this.screenToUser(svg, event.clientX, event.clientY);
    if (!p) return;

    // Own the gesture only when the graph actually consumes it.
    if (event.cancelable) event.preventDefault();

    const factor = event.deltaY > 0 ? WHEEL_STEP : 1 / WHEEL_STEP;
    this.setView(svg, this.zoomAt(state.view, p, factor, state.baseW));
    this.updateReadout(svg);
  },

  // Zoom about the current view center (the +/- toolbar buttons).
  zoomByButton(btn, factor) {
    const svg = this.svgOf(btn);
    if (!svg) return;
    const state = this.stateFor(svg);
    if (!state) return;
    const p = {x: state.view.x + state.view.w / 2, y: state.view.y + state.view.h / 2};
    this.setView(svg, this.zoomAt(state.view, p, factor, state.baseW));
    this.updateReadout(svg);
  },

  fitGraph(btn) {
    const svg = this.svgOf(btn);
    if (!svg) return;
    const view = this.contentView(svg);
    if (!view) return;
    this.setView(svg, view);
    this.updateReadout(svg);
  },

  handlePointerDown(event) {
    // Primary button / touch / pen only.
    if (event.button !== undefined && event.button !== 0) return;
    const target = event.target;
    if (!this.el || !target || !target.closest) return;
    const svg = target.closest("svg.cg-svg");
    if (!svg || !this.el.contains(svg)) return;

    const state = this.stateFor(svg);
    const ctm = svg.getScreenCTM ? svg.getScreenCTM() : null;
    if (!state || !ctm) return;

    this.drag = {
      svg: svg,
      startClient: {x: event.clientX, y: event.clientY},
      startView: state.view,
      inverse: ctm.inverse(),
      moved: false
    };

    // Deliberately NO setPointerCapture here — capturing on the svg hijacks the
    // `click` that `phx-click` on the nodes/lanes depends on. Temporary window
    // listeners track the drag instead (removed on pointerup/cancel).
    this.winPointerMove = (ev) => this.handlePointerMove(ev);
    this.winPointerUp = (ev) => this.handlePointerUp(ev);
    window.addEventListener("pointermove", this.winPointerMove, {passive: false});
    window.addEventListener("pointerup", this.winPointerUp);
    window.addEventListener("pointercancel", this.winPointerUp);
  },

  handlePointerMove(event) {
    const drag = this.drag;
    if (!drag) return;

    const dxScreen = event.clientX - drag.startClient.x;
    const dyScreen = event.clientY - drag.startClient.y;
    if (!drag.moved) {
      if (Math.hypot(dxScreen, dyScreen) < DRAG_THRESHOLD_PX) return;
      drag.moved = true;
      drag.svg.classList.add("cg-dragging");
    }

    // Panning changes only the viewBox translation — the svg's linear scale is
    // unchanged — so the pointerdown screen→user matrix stays valid throughout
    // the drag.
    const from = this.userPoint(drag.svg, drag.inverse, drag.startClient.x, drag.startClient.y);
    const to = this.userPoint(drag.svg, drag.inverse, event.clientX, event.clientY);
    if (!from || !to) return;
    if (event.cancelable) event.preventDefault();

    this.setView(drag.svg, {
      x: drag.startView.x - (to.x - from.x),
      y: drag.startView.y - (to.y - from.y),
      w: drag.startView.w,
      h: drag.startView.h
    });
  },

  handlePointerUp() {
    const drag = this.drag;
    this.endDrag();
    if (!drag) return;

    if (drag.moved) {
      // A pan must not fire the trailing click (it would run `select_agent`).
      // Suppressed once in the capture-phase click handler; a timer clears the
      // flag if no click follows at all (pointer released off the root).
      this.suppressClick = true;
      if (this.suppressTimer) clearTimeout(this.suppressTimer);
      this.suppressTimer = setTimeout(() => {
        this.suppressClick = false;
        this.suppressTimer = null;
      }, 300);
    }
  },

  endDrag() {
    this.removeWindowDragListeners();
    if (this.drag && this.drag.svg) this.drag.svg.classList.remove("cg-dragging");
    this.drag = null;
  },

  removeWindowDragListeners() {
    if (this.winPointerMove) {
      window.removeEventListener("pointermove", this.winPointerMove, {passive: false});
    }
    if (this.winPointerUp) {
      window.removeEventListener("pointerup", this.winPointerUp);
      window.removeEventListener("pointercancel", this.winPointerUp);
    }
    this.winPointerMove = null;
    this.winPointerUp = null;
  },

  handleClickCapture(event) {
    if (this.suppressClick) {
      this.suppressClick = false;
      if (this.suppressTimer) {
        clearTimeout(this.suppressTimer);
        this.suppressTimer = null;
      }
      // Stop the click before it reaches the node's phx-click handler.
      event.stopPropagation();
      if (event.cancelable) event.preventDefault();
      return;
    }

    const target = event.target;
    const btn = target && target.closest ? target.closest("[data-cg-action]") : null;
    if (!btn || !this.el || !this.el.contains(btn)) return;

    const action = btn.getAttribute("data-cg-action");
    if (action === "zoom-in") this.zoomByButton(btn, 1 / BUTTON_STEP);
    else if (action === "zoom-out") this.zoomByButton(btn, BUTTON_STEP);
    else if (action === "fit") this.fitGraph(btn);
    event.preventDefault();
  },

  // --- geometry helpers ------------------------------------------------------

  // The graph block's view key. `data-cg-repo-id` is the contract id; a block
  // without one degrades to a single shared key (still functional).
  repoKey(graph) {
    return graph.getAttribute("data-cg-repo-id") || "";
  },

  svgOf(el) {
    const graph = el && el.closest ? el.closest(".cg-graph") : null;
    return graph ? graph.querySelector("svg.cg-svg") : null;
  },

  // Client (screen) coordinates → user (viewBox) coordinates.
  screenToUser(svg, clientX, clientY) {
    const ctm = svg && svg.getScreenCTM ? svg.getScreenCTM() : null;
    if (!ctm) return null;
    return this.userPoint(svg, ctm.inverse(), clientX, clientY);
  },

  userPoint(svg, inverse, clientX, clientY) {
    if (!svg || !inverse || typeof svg.createSVGPoint !== "function") return null;
    const pt = svg.createSVGPoint();
    pt.x = clientX;
    pt.y = clientY;
    return pt.matrixTransform(inverse);
  },

  // A viewBox that fits `.cg-viewport`'s content (bbox + FIT_MARGIN), aspect-
  // matched to the svg's rendered box so the content fills it undistorted.
  contentView(svg) {
    const bbox = this.contentBBox(svg);
    if (!bbox) return null;

    let w = bbox.w * (1 + 2 * FIT_MARGIN);
    let h = bbox.h * (1 + 2 * FIT_MARGIN);
    const rect = svg.getBoundingClientRect ? svg.getBoundingClientRect() : null;
    if (rect && rect.width > 0 && rect.height > 0) {
      const aspect = rect.width / rect.height;
      if (w / h > aspect) h = w / aspect;
      else w = h * aspect;
    }
    const cx = bbox.x + bbox.w / 2;
    const cy = bbox.y + bbox.h / 2;
    return {x: cx - w / 2, y: cy - h / 2, w: w, h: h};
  },

  contentBBox(svg) {
    const viewport = svg ? svg.querySelector(".cg-viewport") : null;
    if (!viewport || typeof viewport.getBBox !== "function") return null;
    let bb;
    // Firefox throws NS_ERROR_FAILURE for getBBox() on a detached / zero-layout
    // element — the expected, recoverable case here, so guard it.
    try {
      bb = viewport.getBBox();
    } catch (_err) {
      return null;
    }
    if (!bb || !isFinite(bb.width) || !isFinite(bb.height) || bb.width <= 0 || bb.height <= 0) {
      return null;
    }
    return {x: bb.x, y: bb.y, w: bb.width, h: bb.height};
  },

  updateReadout(svg) {
    const graph = svg && svg.closest ? svg.closest(".cg-graph") : null;
    if (!graph || !this.views) return;
    const readout = graph.querySelector(".cg-zoom-readout");
    if (!readout) return;
    const state = this.views.get(this.repoKey(graph));
    if (!state || !state.view.w) return;
    // Baseline = the renderer's initial viewBox width.
    readout.textContent = `${Math.round((state.baseW / state.view.w) * 100)}%`;
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
    this.eachMarked(root, (el) => {
      el.classList.remove(ENTER_CLASS.node, ENTER_CLASS.lane, ENTER_CLASS.edge);
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
