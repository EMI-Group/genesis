// DiffViewer hook: combined client-side behavior for the diff viewer.
//
// LiveView 1.2 `phx-hook` takes exactly ONE hook name per element — the whole
// attribute value is looked up as a single hook name (no whitespace
// splitting), so never use space-separated hook lists (that was pre-1.2
// behavior). A space-separated form silently attaches NOTHING (browser
// console: `unknown hook found for "..."`), which is why BOTH behaviors —
// scroll-to-file AND client-side syntax highlighting — are merged into this
// single hook.
//
// Both `mounted()` and `updated()` must run the highlighting pass: morphdom
// applies in-place patches (lazy file load, expand_context, select_file)
// WITHOUT re-initializing hooks, so `updated()` is what re-highlights
// new/changed rows; `mounted()` covers full remounts (tab switches
// destroy/recreate #diff-viewer, task reloads collapse files).
//
// PERFORMANCE: the pass is proportional to NEW content, never to the whole
// diff. A review page patches on every lazy file load, expand_context,
// select_file and tab switch, and a big diff holds thousands of cells — walking
// all of them (and branching per cell in JS) on each patch made every one of
// those interactions O(all cells).
//
// Three mechanisms, in order of cost:
//   1. `this._clean` — sections already fully processed are SKIPPED with one
//      WeakSet lookup and NO `querySelectorAll` at all.
//   2. `this._done` — a second-level guard (beside the `data-hl="1"` attribute
//      this hook writes) for cells whose HTML the hook already produced.
//   3. A `:not([data-hl="1"])` selector — the browser walks the cells natively
//      and hands back only the new ones; an empty result ends the section.
//
// Correctness note (why the observer exists): `expand_context` appends cells to
// a section that was already clean, so "clean" is INVALIDATED, never guessed —
// see `_observe()`. Coalescing: `mounted()`/`updated()`/the observer all call
// `_schedule()`, which keeps at most ONE pending `requestAnimationFrame`.
import hljs from "../../vendor/highlight.min.js"

// Map backend (server-side) language names to highlight.js names. Anything not
// listed passes through unchanged.
const LANG_MAP = {
  c_sharp: "csharp",
  text: "plaintext"
};

const DiffViewer = {
  mounted() {
    this.handleEvent("scroll_to_file", ({target_id}) => {
      setTimeout(() => {
        const target = document.getElementById(target_id);
        if (!target || !this.el.contains(target)) return;

        target.querySelector(".diff-file-header")?.focus({preventScroll: true});
        const behavior = window.matchMedia("(prefers-reduced-motion: reduce)").matches
          ? "instant"
          : "smooth";

        // The main content area is the scroll container (not window)
        const scrollContainer = document.getElementById('main-scroll');
        if (scrollContainer) {
          const containerRect = scrollContainer.getBoundingClientRect();
          const targetRect = target.getBoundingClientRect();
          const scrollOffset = targetRect.top - containerRect.top + scrollContainer.scrollTop;
          scrollContainer.scrollTo({
            top: scrollOffset - 12,
            behavior
          });
        } else {
          // Fallback
          target.scrollIntoView({ behavior, block: "start" });
        }
      }, 50);
    });

    // Cells whose HTML this hook wrote (second-level guard beside `data-hl`).
    this._done = new WeakSet();
    // Sections with nothing left to process (invalidated by `_observe`).
    this._clean = new WeakSet();
    // The pending rAF id, so at most one highlight pass is queued.
    this._frame = null;

    this._observe();
    this._schedule();
  },

  updated() {
    // Coalesced: several patches in one frame cost ONE pass (and clean
    // sections make that pass nearly free).
    this._schedule();
  },

  destroyed() {
    // Every rAF id is cancelled with `cancelAnimationFrame` on the same window
    // the scheduler holds.
    if (this._frame !== null && typeof window.cancelAnimationFrame === "function") {
      window.cancelAnimationFrame(this._frame);
    }
    this._frame = null;
    this._clean = null;
    this._done = null;

    if (this._observer) {
      this._observer.disconnect();
      this._observer = null;
    }
  },

  // Watch for cells added to an ALREADY-clean section (lazy expand_context, a
  // lazily loaded file) and forget that section's clean marker. Mutations
  // inside a `.diff-split-cell` are this hook's own `innerHTML` writes — they
  // are ignored so the pass can never schedule itself forever.
  _observe() {
    if (typeof MutationObserver !== "function") return;

    this._observer = new MutationObserver((records) => {
      let dirty = false;

      for (const record of records) {
        const target = record.target;
        if (!target || typeof target.closest !== "function") continue;
        // This hook's own highlight write (and any text edit inside a cell).
        if (target.closest(".diff-split-cell")) continue;

        const section = target.closest(".diff-file-section");
        if (section) {
          this._clean?.delete(section);
        } else {
          // A wholesale subtree swap (tab switch, task reload) leaves no
          // section to reason about: forget every clean marker defensively.
          this._clean = new WeakSet();
        }
        dirty = true;
      }

      if (dirty) this._schedule();
    });

    this._observer.observe(this.el, { childList: true, subtree: true });
  },

  // Queues exactly one highlight pass on the next frame (falls back to a
  // synchronous pass where rAF is unavailable).
  _schedule() {
    if (this._frame !== null) return;
    if (typeof window.requestAnimationFrame !== "function") {
      this.highlight();
      return;
    }

    this._frame = window.requestAnimationFrame(() => {
      this._frame = null;
      this.highlight();
    });
  },

  highlight() {
    // No-op gracefully if hljs failed to load — cells stay plain text.
    if (!hljs || typeof hljs.highlight !== "function") return;

    if (!this._clean) this._clean = new WeakSet();
    if (!this._done) this._done = new WeakSet();

    this.el.querySelectorAll(".diff-file-section").forEach((section) => {
      // Already fully processed and nothing has been added since: no cell walk
      // at all (the common case on every patch after the first one).
      if (this._clean.has(section)) return;

      // The backend stamps the language name on the section
      // (data-language); sections without it are skipped.
      const lang = section.dataset.language;
      if (!lang) return;

      const hljsLang = LANG_MAP[lang] || lang;
      // Unknown language: skip the whole section — a wrong grammar is worse
      // than no highlighting. (hljs.highlight would also throw for unknown
      // languages, so this doubles as a guard.)
      if (!hljs.getLanguage(hljsLang)) return;

      // Let the browser filter the already-highlighted cells instead of
      // branching on them in JS.
      const cells = section.querySelectorAll('.diff-split-cell:not([data-hl="1"])');
      if (!cells.length) {
        this._clean.add(section);
        return;
      }

      let leftOver = false;

      cells.forEach((cell) => {
        // Second-level guard: this hook already produced this cell's HTML.
        if (this._done.has(cell)) return;

        // textContent is already HTML-decoded by the DOM, so the cell holds
        // pure code (the backend's parse_diff_lines/1 already removed the
        // +/- markers). Leftover markup spans, if any, are stripped too.
        const code = cell.textContent;
        if (!code.trim()) {
          // Empty/whitespace-only (the empty side of a split-view row, or a
          // blank line): leave it unmarked so a later patch can still fill it
          // in — and keep the section out of `_clean` for the same reason.
          leftOver = true;
          return;
        }

        try {
          cell.innerHTML = hljs.highlight(code, { language: hljsLang }).value;
          cell.dataset.hl = "1";
          this._done.add(cell);
        } catch (_e) {
          // A throw must leave the cell as plain text — never break the page.
          // (getLanguage already guards the common failure; this covers
          // pathological grammars/inputs.) The cell stays unmarked, so the
          // section is not marked clean either.
          leftOver = true;
        }
      });

      if (!leftOver) this._clean.add(section);
    });
  }
};

export default DiffViewer;
