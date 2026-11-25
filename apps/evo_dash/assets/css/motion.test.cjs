const test = require("node:test");
const assert = require("node:assert/strict");
const {readFileSync, readdirSync} = require("node:fs");
const {join} = require("node:path");

// Source contracts for the hook-driven surfaces whose exit used to be missing
// or one-directional. No browser/cascade simulator and no npm dependencies:
// the shipped CSS is read as text, exactly like assistant_motion.test.cjs.
const strip = source => source.replace(/\/\*[\s\S]*?\*\//g, "");
const motionCss = strip(readFileSync(join(__dirname, "motion.css"), "utf8"));
const appCss = strip(readFileSync(join(__dirname, "app.css"), "utf8"));

function blocks(header, source) {
  const found = [];
  for (let start = source.indexOf(header); start !== -1; start = source.indexOf(header, start + 1)) {
    const tail = start + header.length;
    if (source[tail] === "-" || source[tail] === "_") continue; // a longer class name
    const open = source.indexOf("{", tail);
    if (open === -1 || source.slice(tail, open).trim()) continue;
    let depth = 1;
    let end = open + 1;
    for (; end < source.length && depth; end++) {
      if (source[end] === "{") depth++;
      if (source[end] === "}") depth--;
    }
    assert.equal(depth, 0, `unclosed block: ${header}`);
    found.push(source.slice(open + 1, end - 1));
  }
  assert.ok(found.length, `missing block: ${header}`);
  return found;
}

function declarations(body) {
  return body.split(";").map(part => part.trim()).filter(Boolean)
    .map(part => part.split(":").map(value => value.trim()));
}

function values(body) {
  return Object.fromEntries(declarations(body));
}

// Shared-token motion only: every duration/easing is a var() from motion.css.
function assertTokenOnly(animation, label) {
  const literals = animation.replace(/var\(--[a-z-]+\)/g, "");
  assert.doesNotMatch(literals, /\d+(\.\d+)?m?s\b/, `bare duration in ${label}: ${animation}`);
  assert.doesNotMatch(literals, /\b(ease-out|ease-in|ease|linear)\b/, `literal easing in ${label}: ${animation}`);
  assert.match(animation, /^motion-(fade|slide)-[a-z]+ var\(--motion-[a-z]+\) var\(--motion-ease-[a-z]+\)/);
}

test("dashboard styles do not animate page navigation or the document scroll", () => {
  for (const name of readdirSync(__dirname).filter(name => name.endsWith(".css"))) {
    const css = strip(readFileSync(join(__dirname, name), "utf8"));
    assert.doesNotMatch(css, /@view-transition\b|::view-transition\b|\bview-transition-(?:name|class)\s*:/, name);
    assert.doesNotMatch(css, /\bnode-switch-fade\b/, name);
    assert.doesNotMatch(css, /(?:^|[}\n])\s*(?:html|:root)\s*\{[^{}]*scroll-behavior:\s*smooth\b/, name);
  }
});

test("the native modal animates the .modal-box in BOTH directions and only fades ::backdrop", () => {
  // dialog_modal.js settles each phase on a target-verified animationend whose
  // target IS the `.modal-box`, so an entry/exit rule anywhere else can never
  // be observed by the hook (it would always fall back to the 200 ms bound).
  const expected = {
    'dialog.modal[data-dialog-state="opening"] .modal-box':
      "motion-slide-in var(--motion-base) var(--motion-ease-out) both",
    'dialog.modal[data-dialog-state="opening"]::backdrop':
      "motion-fade-in var(--motion-base) var(--motion-ease-out) both",
    'dialog.modal[data-dialog-state="closing"] .modal-box':
      "motion-fade-out var(--motion-fast) var(--motion-ease-in) both",
    'dialog.modal[data-dialog-state="closing"]::backdrop':
      "motion-fade-out var(--motion-fast) var(--motion-ease-in) both"
  };
  for (const [selector, animation] of Object.entries(expected)) {
    const [body, ...duplicates] = blocks(selector, motionCss);
    assert.equal(duplicates.length, 0, `duplicate rule: ${selector}`);
    assert.equal(values(body).animation, animation, selector);
    assertTokenOnly(animation, selector);
  }

  // Exactly one rule per direction on the panel: a second (dialog-level) fade
  // would double-animate the same pixels.
  const boxRules = (motionCss.match(/dialog\.modal\[data-dialog-state="(?:opening|closing)"\] \.modal-box/g) || []);
  assert.equal(boxRules.length, 2, "exactly one opening and one closing .modal-box rule");
});

test("the Layer-2 submenu has an exit rule beside its entrance", () => {
  const [entry] = blocks("details.capsule-sub[open] > .capsule-list", appCss);
  // Both directions use the shared tokens: no bare duration/easing literal.
  assert.equal(values(entry).animation,
    "capsule-sub-in var(--motion-fast) var(--motion-ease-out)");
  assert.doesNotMatch(values(entry).animation.replace(/var\(--[a-z-]+\)/g, ""),
    /\d+(\.\d+)?m?s\b|ease-(?:out|in)\b/);

  // The reduced-motion guard later repeats the same selector (with
  // `animation: none`), so the exit rule is the token-bearing block.
  const exit = blocks('details.capsule-sub[data-capsule-sub-state="closing"] > .capsule-list', appCss)
    .map(values)
    .filter(declared => String(declared.animation || "").startsWith("motion-"));
  assert.equal(exit.length, 1, "exactly one token-driven submenu exit rule");
  assert.equal(exit[0].animation,
    "motion-fade-out var(--motion-fast) var(--motion-ease-in) both");
  assertTokenOnly(exit[0].animation, "capsule-sub closing");

  // The per-component reduced-motion guard covers BOTH directions, so the
  // native snap is disabled alongside the entry under reduced motion.
  const guard = blocks("@media (prefers-reduced-motion: reduce)", appCss)
    .find(body => body.includes('details.capsule-sub[data-capsule-sub-state="closing"]'));
  assert.ok(guard, "the exit selector is missing from the reduced-motion guard");
  assert.ok(guard.includes("animation: none !important"));
});

test("the file-picker manual panel animates opacity/transform only, in both directions", () => {
  const [wrap] = blocks(".file-manual-input-wrap", appCss);
  const wrapValues = values(wrap);
  assert.equal(wrapValues["max-width"], "16.5rem", "the wrap's width is static, never tweened");
  assert.equal(wrapValues.animation, "file-manual-expand 0.2s ease-out");

  const [exit] = blocks('.file-manual[data-file-manual-state="closing"] .file-manual-input-wrap', appCss);
  assert.equal(values(exit).animation,
    "motion-fade-out var(--motion-fast) var(--motion-ease-in) both");
  assertTokenOnly(values(exit).animation, "file-manual closing");

  // HARD INVARIANT (motion.css): no height/width tween. The entry keyframe may
  // only move opacity and transform.
  const [keyframes] = blocks("@keyframes file-manual-expand", appCss);
  for (const forbidden of ["max-width", "min-width", "width", "height"]) {
    assert.doesNotMatch(keyframes, new RegExp(`(^|[^-\\w])${forbidden}\\s*:`),
      `the entry keyframe must not animate ${forbidden}`);
  }
  const properties = new Set([...keyframes.matchAll(/([a-z-]+)\s*:/g)].map(match => match[1]));
  assert.deepEqual([...properties].sort(), ["opacity", "transform"]);
});
test("the legend tooltip fade uses the shared tokens, never a literal", () => {
  const [tip] = blocks(".agents-legend-tip", appCss);
  assert.equal(values(tip).transition, "opacity var(--motion-fast) var(--motion-ease-in)");
});

// The declarations of the rule whose SELECTOR LIST starts at `selector` — the
// section-4 rules group a state selector with its class-only escape hatch.
function declared(selector, source) {
  const at = source.indexOf(selector);
  assert.ok(at !== -1, `missing selector: ${selector}`);
  const open = source.indexOf("{", at);
  assert.ok(open !== -1, `missing block: ${selector}`);
  const body = source.slice(open + 1, source.indexOf("}", open));
  return {selectors: source.slice(at, open), declared: values(body), body};
}

test("the state-driven panel keeps its token-only entry and exit", () => {
  // motion-panel / data-motion-state is the ONE two-direction panel vocabulary:
  // both directions animate opacity (or a small slide) with the shared tokens,
  // and the MotionPanel hook only writes the state attribute.
  const entry = declared('.motion-panel[data-motion-state="opening"]', motionCss);
  assert.equal(entry.declared.animation,
    "motion-fade-in var(--motion-base) var(--motion-ease-out) both");
  assertTokenOnly(entry.declared.animation, "motion-panel opening");
  // The class-only escape hatch an entry-only consumer may use instead.
  assert.match(entry.selectors, /\.motion-panel-open\b/);

  const exit = declared('.motion-panel[data-motion-state="closing"]', motionCss);
  assert.equal(exit.declared.animation,
    "motion-fade-out var(--motion-fast) var(--motion-ease-in) both");
  assertTokenOnly(exit.declared.animation, "motion-panel closing");
  assert.match(exit.selectors, /\.motion-panel-close\b/);

  // The slide variant only swaps the keyframe NAME, so it inherits the entry's
  // duration/easing from the rule above instead of repeating a literal.
  const slide = declared('.motion-panel.motion-panel-slide[data-motion-state="opening"]', motionCss);
  assert.deepEqual(slide.declared, {"animation-name": "motion-slide-in"});

  // No duration may leak into section 4 as a literal.
  for (const {declared: body} of [entry, exit]) {
    assert.doesNotMatch(JSON.stringify(body), /\d+(\.\d+)?m?s\b/);
  }
});

test("a settled or unhooked closed panel is display: none without !important", () => {
  // The hook writes data-motion-state="closed" before it writes `hidden`, and
  // the server renders `hidden` for an intent that starts closed: BOTH frames
  // must hide the panel, or a "closed" panel would paint.
  const closed = declared('.motion-panel[data-motion-state="closed"]', motionCss);
  assert.equal(closed.declared.display, "none");
  assert.match(closed.selectors, /\.motion-panel\[hidden\]/);
  assert.doesNotMatch(closed.body, /!important/,
    "the two selectors' specificity must carry it, never !important");
  // Exactly one closed-frame rule, so no later rule can re-show the panel.
  assert.equal((motionCss.match(/\.motion-panel\[data-motion-state="closed"\]/g) || []).length, 1);
});

test("the reduced-motion backstop is still the LAST rule in motion.css", () => {
  const trimmed = motionCss.trimEnd();
  const at = trimmed.lastIndexOf("@media (prefers-reduced-motion: reduce)");
  assert.ok(at > 0, "the global reduced-motion backstop is missing");
  const tail = trimmed.slice(at);
  // The media block must run to the very end of the file: nothing may be added
  // after it, or the backstop stops being the last word.
  let depth = 0;
  let end = -1;
  for (let index = tail.indexOf("{"); index < tail.length; index++) {
    if (tail[index] === "{") depth++;
    if (tail[index] === "}") depth--;
    if (depth === 0 && tail[index] === "}") {
      end = index + 1;
      break;
    }
  }
  assert.equal(end, tail.length, "a rule follows the reduced-motion backstop");
  assert.match(tail, /animation-duration:\s*\.01ms\s*!important/);
  assert.match(tail, /transition-duration:\s*\.01ms\s*!important/);
});
