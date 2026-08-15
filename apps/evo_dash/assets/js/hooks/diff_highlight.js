// DiffHighlight hook: client-side syntax highlighting for the diff viewer.
// Attached via `phx-hook="ScrollToFile DiffHighlight"` on the #diff-viewer
// container (space-separated multiple hooks are supported by LiveView).
//
// Replaces BEAM-side Lumis highlighting. Both `mounted()` and `updated()`
// must run the highlighting pass: morphdom applies in-place patches (lazy
// file load, expand_context, select_file) WITHOUT re-initializing hooks, so
// `updated()` is what re-highlights new/changed rows; `mounted()` covers full
// remounts (tab switches destroy/recreate #diff-viewer, task reloads collapse
// files).
import hljs from "../../vendor/highlight.min.js"

// Map backend (Lumis) language names to highlight.js names. Anything not
// listed passes through unchanged.
const LANG_MAP = {
  c_sharp: "csharp",
  text: "plaintext"
};

const DiffHighlight = {
  mounted() {
    this.highlight();
  },

  updated() {
    this.highlight();
  },

  highlight() {
    // No-op gracefully if hljs failed to load — cells stay plain text.
    if (!hljs || typeof hljs.highlight !== "function") return;

    this.el.querySelectorAll(".diff-file-section").forEach((section) => {
      // The backend stamps the Lumis language name on the section
      // (data-language); sections without it are skipped.
      const lang = section.dataset.language;
      if (!lang) return;

      const hljsLang = LANG_MAP[lang] || lang;
      // Unknown language: skip the whole section — a wrong grammar is worse
      // than no highlighting. (hljs.highlight would also throw for unknown
      // languages, so this doubles as a guard.)
      if (!hljs.getLanguage(hljsLang)) return;

      section.querySelectorAll(".diff-split-cell").forEach((cell) => {
        // Morphdom replaces leaf cells whose text changed, so new cells
        // arrive without the marker; already-processed cells are skipped.
        if (cell.dataset.hl === "1") return;

        // textContent is already HTML-decoded by the DOM, so any previous
        // Lumis spans are stripped too — the cell holds pure code (the
        // backend's parse_diff_lines/1 already removed +/- markers).
        const code = cell.textContent;
        if (!code.trim()) return; // skip empty/whitespace-only cells

        try {
          cell.innerHTML = hljs.highlight(code, { language: hljsLang }).value;
          cell.dataset.hl = "1";
        } catch (_e) {
          // A throw must leave the cell as plain text — never break the page.
          // (getLanguage already guards the common failure; this covers
          // pathological grammars/inputs.)
        }
      });
    });
  }
};

export default DiffHighlight;
