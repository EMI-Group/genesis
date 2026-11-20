// --- AgentHistoryAutoScroll: pure pinning decision (unit-tested) ------------
//
// "Pinned" = the user is reading the latest content, i.e. the scroller is
// within `thresholdPx` of the bottom. The slack absorbs sub-pixel/zoom
// rounding and a last line that is only partly visible, so a reader sitting at
// the bottom is never wrongly unpinned. Guidance: 48-64 px — generous enough
// that a one-line accidental scroll does not fight the hook, small enough that
// a deliberate scroll into history stays put.
const STICK_TO_BOTTOM_THRESHOLD_PX = 56;

function shouldFollowLatest(scrollTop, scrollHeight, clientHeight, thresholdPx) {
  const threshold = typeof thresholdPx === "number"
    ? thresholdPx
    : STICK_TO_BOTTOM_THRESHOLD_PX;

  // Unmeasurable geometry (detached or display:none element) keeps following:
  // a no-op scroll assignment is harmless, a lost pin is not.
  if (!Number.isFinite(scrollTop) || !Number.isFinite(scrollHeight) ||
      !Number.isFinite(clientHeight)) {
    return true;
  }

  // Content that fits needs no scrolling; a negative distance (overscroll /
  // rubber-banding) is at the bottom too.
  return scrollHeight - clientHeight - scrollTop <= threshold;
}

// AgentHistoryAutoScroll hook: deterministic stick-to-bottom for a transcript
// scroller (`#chat-messages` on /assistant, `#agent-history-<id>` on /agents).
//
// NO ANIMATION. The earlier implementation animated `scrollTop` with a custom
// 200 ms ease-out curve and restarted that animation on every LiveView update.
// Streaming deltas land roughly every 75 ms and the stream→finalized Markdown
// swap changes the content height abruptly at the end of a turn, so the
// scroller was perpetually cancelled and restarted mid-flight: it chased a
// moving target, never settled, and visibly shook. This implementation owns a
// single coalesced requestAnimationFrame that assigns `scrollTop =
// scrollHeight` (instant) — the position is always the truth of the last
// frame, never a trajectory.
//
// Pinning model:
//   * `pinned` (initially true) is `shouldFollowLatest/4` of live geometry;
//   * only USER input re-evaluates it (scroll, wheel, touch, keydown). A
//     programmatic assignment also fires `scroll`, but by the time that event
//     is dispatched the write has already landed at the bottom, so the
//     recomputed distance is ~0 and the pin survives — no suppression flag,
//     no timestamp window;
//   * while pinned, content growth schedules ONE coalesced rAF stick; while
//     unpinned the hook early-returns and both observers are disconnected, so
//     reading history costs no observer work.
//
// Late layout changes (Markdown render, images, a `<details>` opening inside a
// message) arrive after the patch, so a ResizeObserver on the scroller and its
// direct children re-pins and follows. Child-list mutations (LiveView morphs
// replacing children) re-sync the observed set through a MutationObserver.
// Every listener and observer is released in destroyed().
const AgentHistoryAutoScroll = {
  mounted() {
    this.pinned = true;
    this._frame = null;
    this._intentFrame = null;
    this._resizeObserver = null;
    this._mutationObserver = null;
    this._observed = new Set();

    this._onScroll = () => this._recomputePinned();
    this._onUserIntent = () => this._schedulePinnedRecompute();

    this.el.addEventListener("scroll", this._onScroll, {passive: true});
    this.el.addEventListener("wheel", this._onUserIntent, {passive: true});
    this.el.addEventListener("touchmove", this._onUserIntent, {passive: true});
    this.el.addEventListener("keydown", this._onUserIntent);

    this._connectObservers();
    this._scheduleStick();
  },

  updated() {
    this._scheduleStick();
  },

  reconnected() {
    // A reconnect may have replaced DOM children mid-flight; re-derive the pin
    // from the live position and re-attach the observations.
    this._recomputePinned();
    this._scheduleStick();
  },

  destroyed() {
    if (this._frame !== null) cancelAnimationFrame(this._frame);
    if (this._intentFrame !== null) cancelAnimationFrame(this._intentFrame);
    this._frame = null;
    this._intentFrame = null;

    this.el.removeEventListener("scroll", this._onScroll);
    this.el.removeEventListener("wheel", this._onUserIntent);
    this.el.removeEventListener("touchmove", this._onUserIntent);
    this.el.removeEventListener("keydown", this._onUserIntent);

    this._disconnectObservers();
    this._resizeObserver = null;
    this._mutationObserver = null;
  },

  _recomputePinned() {
    this._setPinned(shouldFollowLatest(
      this.el.scrollTop,
      this.el.scrollHeight,
      this.el.clientHeight,
      STICK_TO_BOTTOM_THRESHOLD_PX
    ));
  },

  // User intent events land BEFORE the scroll they cause; evaluate on the next
  // frame (coalesced) so the geometry already reflects the movement.
  _schedulePinnedRecompute() {
    if (this._intentFrame !== null) return;
    this._intentFrame = requestAnimationFrame(() => {
      this._intentFrame = null;
      this._recomputePinned();
    });
  },

  _setPinned(next) {
    if (next === this.pinned) return;
    this.pinned = next;

    if (next) {
      this._connectObservers();
      this._scheduleStick();
    } else {
      this._disconnectObservers();
      if (this._frame !== null) {
        cancelAnimationFrame(this._frame);
        this._frame = null;
      }
    }
  },

  _scheduleStick() {
    if (!this.pinned) return;
    if (this._frame !== null) return;  // coalesce: at most one stick per frame
    this._frame = requestAnimationFrame(() => {
      this._frame = null;
      if (!this.pinned) return;
      // Assigning scrollHeight clamps to the real maximum, so a fractional
      // device-pixel height cannot leave the scroller a hair short.
      this.el.scrollTop = this.el.scrollHeight;
    });
  },

  _connectObservers() {
    if (typeof ResizeObserver === "undefined") return;  // no late-layout following
    if (this._resizeObserver === null) {
      this._resizeObserver = new ResizeObserver(() => this._scheduleStick());
    }
    if (this._mutationObserver === null && typeof MutationObserver !== "undefined") {
      this._mutationObserver = new MutationObserver(() => {
        this._syncObserved();
        this._scheduleStick();
      });
    }
    this._syncObserved();
    // Re-observing the same node with the same options is idempotent.
    if (this._mutationObserver !== null) {
      this._mutationObserver.observe(this.el, {childList: true});
    }
  },

  _syncObserved() {
    if (this._resizeObserver === null) return;
    const targets = new Set([this.el, ...this.el.children]);
    for (const target of this._observed) {
      if (!targets.has(target)) this._resizeObserver.unobserve(target);
    }
    for (const target of targets) {
      if (!this._observed.has(target)) this._resizeObserver.observe(target);
    }
    this._observed = targets;
  },

  _disconnectObservers() {
    if (this._resizeObserver !== null) {
      this._resizeObserver.disconnect();
      this._observed = new Set();
    }
    if (this._mutationObserver !== null) {
      this._mutationObserver.disconnect();
    }
  }
};

export default AgentHistoryAutoScroll;
export {shouldFollowLatest, STICK_TO_BOTTOM_THRESHOLD_PX};
