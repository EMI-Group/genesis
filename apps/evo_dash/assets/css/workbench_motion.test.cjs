const test = require("node:test");
const assert = require("node:assert/strict");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");

// Source contracts, not a browser/cascade simulator. No npm dependencies.
const workbenchCss = readFileSync(join(__dirname, "workbench.css"), "utf8")
  .replace(/\/\*[\s\S]*?\*\//g, "");
const motionCss = readFileSync(join(__dirname, "motion.css"), "utf8")
  .replace(/\/\*[\s\S]*?\*\//g, "");

function blocks(header, source = workbenchCss) {
  const result = [];
  for (let start = source.indexOf(header); start !== -1; start = source.indexOf(header, start + 1)) {
    const open = source.indexOf("{", start + header.length);
    if (source.slice(start + header.length, open).trim()) continue;
    let depth = 1;
    let end = open + 1;
    for (; end < source.length && depth; end++) {
      if (source[end] === "{") depth++;
      if (source[end] === "}") depth--;
    }
    assert.equal(depth, 0, `unclosed block: ${header}`);
    result.push(source.slice(open + 1, end - 1));
  }
  assert.ok(result.length, `missing block: ${header}`);
  return result;
}

function declarations(body) {
  return body.split(";").map(part => part.trim()).filter(Boolean)
    .map(part => part.split(":").map(value => value.trim()));
}

function values(body) {
  return Object.fromEntries(declarations(body));
}

// Every LEAF rule of a source string with its full selector list. Nested
// @media wrappers are skipped implicitly: their bodies contain further braces,
// so the pattern only ever matches the innermost rules.
function leafRules(source = workbenchCss) {
  return [...source.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(match => ({
    selectors: match[1].trim().split(/,\s*/),
    body: match[2]
  }));
}

function selectorsOf(rule) {
  return rule.selectors.map(selector => selector.replace(/\s+/g, ""));
}

// The shared exit geometry selector pair every direction interpolates from/into.
const PANEL_STATES = ['[data-panel-state="closed"]', '[data-panel-state="closing"]'];

function panelFamily(rule) {
  return PANEL_STATES.every(state => rule.selectors.some(selector => selector.includes(state)));
}

test("the right panel transitions with the shared motion tokens only", () => {
  // `workbench.css` carries several `.workbench-history` leaf rules (base,
  // drawer, a later background-only rule, the reduced-motion guard), so the
  // transition-bearing one is located explicitly instead of assuming one match.
  const transitionBodies = blocks(".workbench-history")
    .filter(body => "transition" in values(body))
    .filter(body => body.includes("var(--motion-slow)"));
  assert.equal(transitionBodies.length, 1, "expected exactly one token-driven .workbench-history transition");

  const transition = values(transitionBodies[0]).transition;
  const parts = transition.split(",").map(part => part.trim());
  assert.deepEqual(parts.map(part => part.split(/\s+/)[0]), [
    "transform",
    "opacity",
    "flex-basis",
    "padding",
    "border-inline-start-width"
  ]);
  for (const part of parts) {
    assert.equal(part, `${part.split(/\s+/)[0]} var(--motion-slow) var(--motion-ease-out)`);
  }

  // No literal may sneak back in beside the tokens.
  const literals = transition.replace(/var\(--[a-z-]+\)/g, "");
  assert.doesNotMatch(literals, /\d+(\.\d+)?ms|\d+(\.\d+)?s\b/, "bare duration in the panel transition");
  assert.doesNotMatch(literals, /\b(ease-out|ease-in|ease|linear)\b/, "literal easing in the panel transition");

  // The tokens resolve to the timing this rule used to hard-code.
  const motionTokens = values(blocks(":root", motionCss)[0]);
  assert.equal(motionTokens["--motion-slow"], "220ms");
  assert.equal(motionTokens["--motion-ease-out"], "cubic-bezier(.16, 1, .3, 1)");
});

test("closed and closing share ONE exit geometry", () => {
  const shared = leafRules().filter(panelFamily).filter(rule => {
    const declared = values(rule.body);
    return ["opacity", "transform", "pointer-events"].every(property => property in declared);
  });
  assert.equal(shared.length, 1, "expected one shared closed+closing geometry rule");

  const geometry = values(shared[0].body);
  assert.equal(geometry.opacity, "0");
  assert.equal(geometry["pointer-events"], "none");
  assert.match(geometry.transform, /^translateX\(/, "the closed panel slides instead of snapping");
});

test("hidden keeps owning display for both right panels", () => {
  const hiddenRules = leafRules().filter(rule => {
    const selectors = selectorsOf(rule);
    return selectors.includes("#workbench-history[hidden]") && selectors.includes("#workbench-git[hidden]");
  });
  assert.equal(hiddenRules.length, 1);
  assert.equal(values(hiddenRules[0].body).display, "none");

  // No state rule may ever re-show the panel: that stays the [hidden] rule's job.
  for (const body of blocks(".workbench-history")) {
    assert.equal("display" in values(body), false, "a .workbench-history rule must never declare display");
  }
});

test("docked media query collapses basis, padding and border for the same family", () => {
  const docked = blocks("@media (min-width: 1280px)")
    .flatMap(body => leafRules(body))
    .filter(panelFamily);
  assert.equal(docked.length, 1);
  assert.deepEqual(values(docked[0].body), {
    "flex-basis": "0",
    "padding-inline": "0",
    "padding-block": "0",
    "border-inline-start-width": "0"
  });
});

test("drawer media query slides the same family fully off the edge", () => {
  const drawer = blocks("@media (max-width: 1279.98px)")
    .flatMap(body => leafRules(body))
    .filter(rule => panelFamily(rule) && "transform" in values(rule.body));
  assert.equal(drawer.length, 1);
  assert.deepEqual(values(drawer[0].body), {transform: "translateX(100%)"});
});

test("the per-component reduced-motion guard stays alongside the global backstop", () => {
  const guards = blocks("@media (prefers-reduced-motion: reduce)")
    .flatMap(body => leafRules(body))
    .filter(rule => selectorsOf(rule).includes(".workbench-history") && "transition" in values(rule.body));
  assert.equal(guards.length, 1);
  assert.equal(values(guards[0].body).transition, "none");
});

test("a project entry's child window rows start below its title pill", () => {
  // The project title row and its FIRST child window row are both
  // `is-current` accent pills: with no block gap their two tints fuse into one
  // continuous coloured shape.
  const containers = leafRules().filter(rule => {
    const selectors = selectorsOf(rule);
    return selectors.includes(".workbench-project-open-windows:not(:empty)") &&
      selectors.includes(".workbench-project-activity");
  });
  assert.equal(containers.length, 1, "expected one shared child-row container rule");

  // The container is JS-filled and HEEx renders it with a whitespace-only body
  // even when it has no rows, so `:not(:empty)` is always true: a block margin
  // on the container would reserve dead space under window-less entries.
  const declared = values(containers[0].body);
  assert.equal(
    declared["margin-block-start"],
    undefined,
    "the empty-container case must not reserve a block gap on the container"
  );
  assert.equal(declared["margin-inline-start"], "1.1rem", "the inline indent is the hierarchy, never the gap");
  assert.equal(declared.gap, ".15rem", "the intra-list gap stays on the container, unchanged");

  // The separation rides the FIRST child row instead, so it exists only when a
  // row is actually rendered.
  const firstChild = leafRules().filter(rule => {
    const selectors = selectorsOf(rule);
    return selectors.includes(".workbench-project-open-windows>:first-child") &&
      selectors.includes(".workbench-project-activity>:first-child");
  });
  assert.equal(firstChild.length, 1, "expected one shared first-child gap rule");

  const gap = values(firstChild[0].body)["margin-block-start"];
  assert.ok(gap, "the first child row must declare margin-block-start");
  assert.match(gap, /^\d*\.?\d+rem$/, `the gap stays on the rem rhythm, got: ${gap}`);
  assert.ok(parseFloat(gap) > 0, `the gap must be non-zero, got: ${gap}`);

  // The separation is not bought by dropping the accent pill: the `is-current`
  // tint contract and its token stay untouched.
  assert.match(workbenchCss, /\.workbench-row\.is-current\s*\{[^}]*background:\s*var\(--workbench-selected\)/);
});
