// highlight_setup.js — expose highlight.js as a global before language packs load.
//
// The cdnjs highlight.js language packs (e.g. ../vendor/highlight-elixir.min.js)
// are NOT ES modules: each is an IIFE that SELF-REGISTERS on the global `hljs`
// (`window.hljs.registerLanguage("elixir", e)`) and exports nothing. Under
// esbuild's bundling, `var hljs` inside highlight.min.js is module-scoped, so
// without this module the pack would throw `ReferenceError: hljs is not
// defined` at bundle load.
//
// This module's side effect (exposing the imported hljs instance as
// `window.hljs`) MUST run before any language-pack module evaluates. ES module
// evaluation is depth-first in import order, so app.js must import this module
// BEFORE the vendored pack imports. The pack then registers itself on the same
// hljs instance the hook imports, making `hljs.getLanguage("elixir")` work.
import hljs from "../vendor/highlight.min.js"

if (typeof window !== "undefined") {
  window.hljs = hljs
}

export default hljs
