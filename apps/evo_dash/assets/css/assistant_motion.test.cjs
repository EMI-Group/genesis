const test = require("node:test");
const assert = require("node:assert/strict");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");

// Source contracts, not a browser/cascade simulator. No npm dependencies.
const css = readFileSync(join(__dirname, "app.css"), "utf8")
  .replace(/\/\*[\s\S]*?\*\//g, "");
const motionCss = readFileSync(join(__dirname, "motion.css"), "utf8")
  .replace(/\/\*[\s\S]*?\*\//g, "");

function blocks(header, source = css) {
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

function rule(body, selector) {
  // Only leaf rules are needed for these local contracts.
  const found = [...body.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
    .filter(match => match[1].trim().split(/,\s*/).includes(selector));
  assert.equal(found.length, 1, `expected one rule for ${selector}`);
  return Object.fromEntries(declarations(found[0][2]));
}

const reduced = blocks("@media (prefers-reduced-motion: reduce)").join("\n");

test("Assistant activity and caret keyframes animate only nonzero opacity", () => {
  for (const name of ["assistant-execution-breathe", "help-blink"]) {
    const [frames] = blocks(`@keyframes ${name}`);
    const steps = [...frames.matchAll(/[^{}]+\{([^{}]*)\}/g)];
    assert.ok(steps.length >= 2);
    for (const step of steps) {
      const entries = declarations(step[1]);
      assert.equal(entries.length, 1);
      const [[property, value]] = entries;
      assert.equal(property, "opacity");
      assert.ok(Number(value) >= 0.4 && Number(value) <= 1);
    }
  }
});

test("activity keeps its label static and its decorative dot fixed-size and theme-aware", () => {
  const [indicator] = blocks("#chat-messages .assistant-execution-indicator");
  assert.deepEqual(Object.keys(Object.fromEntries(declarations(indicator))).sort(),
    ["align-items", "color", "display", "gap"]);
  assert.match(indicator, /color: var\(--color-base-content\)/);
  const [dot] = blocks("#chat-messages .assistant-execution-dot");
  const values = Object.fromEntries(declarations(dot));
  assert.equal(values.width, "0.375rem");
  assert.equal(values.height, values.width);
  assert.equal(values.flex, `0 0 ${values.width}`);
  assert.equal(values["background-color"], "var(--color-primary-standalone)");
  assert.equal(values.animation, "assistant-execution-breathe 2s ease-in-out infinite");
  assert.doesNotMatch(indicator + dot, /transform|transition|content:|gradient|shadow/);
});

test("reduced motion keeps activity/caret visible and native dialogs transition-free", () => {
  for (const selector of ["#chat-messages .assistant-execution-dot", ".help-caret"]) {
    const values = rule(reduced, selector);
    assert.equal(values.animation, "none");
    assert.equal(values.opacity, "1");
  }
  for (const selector of ["dialog.modal", "dialog.modal .modal-box"]) {
    assert.equal(rule(reduced, selector).transition, "none");
  }
});

test("legacy history entrances exclude the Assistant scroller and its descendants", () => {
  const selector = ".agent-history-scroll:where(:not(#chat-messages, #chat-messages *)) > .divide-y > div";
  const historyRules = blocks(selector);
  assert.equal(historyRules.length, 2);
  assert.match(historyRules[0], /animation: history-entry-appear 0\.3s ease-out both/);
  assert.match(historyRules[1], /animation: none/);
  assert.ok(reduced.includes(selector));
  assert.doesNotMatch(css, /\.agent-history-scroll\s*>\s*\.divide-y\s*>\s*div\s*\{/);
});

test("transcript scroll anchoring and instant follow invariants remain intact", () => {
  const [scroll] = blocks("#chat-messages,\n.agent-history-scroll");
  assert.deepEqual(Object.fromEntries(declarations(scroll)), {
    "min-height": "0",
    "overflow-anchor": "none",
    "overscroll-behavior": "contain",
    "scroll-behavior": "auto"
  });
});

// --- Shared motion foundation (motion.css) -------------------------------

test("motion.css is loaded from app.css's @import block after workbench.css", () => {
  assert.match(css, /@import "\.\/workbench\.css";\s*@import "\.\/motion\.css";/);
});

test("motion tokens pin the shared timing and easing vocabulary", () => {
  const [root] = blocks(":root", motionCss);
  assert.deepEqual(Object.fromEntries(declarations(root)), {
    "--motion-fast": "120ms",
    "--motion-base": "170ms",
    "--motion-slow": "220ms",
    "--motion-ease-out": "cubic-bezier(.16, 1, .3, 1)",
    "--motion-ease-in": "cubic-bezier(.4, 0, 1, 1)"
  });
});

test("motion keyframes animate opacity and transform only", () => {
  for (const name of ["motion-fade-in", "motion-fade-out", "motion-slide-in", "motion-collapse"]) {
    const [frames] = blocks(`@keyframes ${name}`, motionCss);
    const steps = [...frames.matchAll(/[^{}]+\{([^{}]*)\}/g)];
    assert.ok(steps.length >= 2, `${name} needs at least two steps`);
    for (const step of steps) {
      const entries = declarations(step[1]);
      assert.ok(entries.length >= 1);
      for (const [property] of entries) {
        assert.ok(["opacity", "transform"].includes(property), `${name} animates ${property}`);
      }
    }
  }
});

test("motion.css never animates height/width and never requests smooth scrolling", () => {
  for (const name of ["motion-fade-in", "motion-fade-out", "motion-slide-in", "motion-collapse"]) {
    const [frames] = blocks(`@keyframes ${name}`, motionCss);
    assert.doesNotMatch(frames, /\b(height|width)\s*:/, `${name} animates a box dimension`);
  }
  assert.doesNotMatch(motionCss, /scroll-behavior:\s*smooth/);
  for (const scroller of ["#chat-messages", ".agent-history-scroll", ".cg-scroll", "#workbench-history"]) {
    assert.doesNotMatch(motionCss, new RegExp(`${scroller.replace(/[.#]/g, "\\$&")}[^{]*\\{[^}]*scroll-behavior`));
  }
});

test("details.motion-disclosure smooths the open with zero JS", () => {
  const [open] = blocks("details.motion-disclosure[open] > :not(summary)", motionCss);
  assert.equal(Object.fromEntries(declarations(open)).animation,
    "motion-slide-in var(--motion-fast) var(--motion-ease-out) both");
  const [closing] = blocks('details.motion-disclosure[data-disclosure-state="closing"] > :not(summary)', motionCss);
  assert.equal(Object.fromEntries(declarations(closing)).animation,
    "motion-fade-out var(--motion-fast) var(--motion-ease-in) both");
});

test("motion panels expose attribute-driven and class-only escape hatches", () => {
  const [opening] = blocks('.motion-panel[data-motion-state="opening"],\n.motion-panel-open', motionCss);
  assert.equal(Object.fromEntries(declarations(opening)).animation,
    "motion-fade-in var(--motion-base) var(--motion-ease-out) both");
  const [closing] = blocks('.motion-panel[data-motion-state="closing"],\n.motion-panel-close', motionCss);
  assert.equal(Object.fromEntries(declarations(closing)).animation,
    "motion-fade-out var(--motion-fast) var(--motion-ease-in) both");
  const [slide] = blocks(".motion-panel-slide.motion-panel-open", motionCss);
  assert.match(slide, /animation-name:\s*motion-slide-in;/);
});

test("the grid-collapse helper is the only bounded layout animation", () => {
  const [grid] = blocks(".motion-collapse-grid", motionCss);
  assert.equal(Object.fromEntries(declarations(grid))["transition"],
    "grid-template-rows var(--motion-base) var(--motion-ease-out)");
  const [open] = blocks('.motion-collapse-grid[data-motion-open="true"]', motionCss);
  assert.equal(Object.fromEntries(declarations(open))["grid-template-rows"], "1fr");
});

test("JS.hide exit helpers use opacity/transform transitions", () => {
  const [fade] = blocks(".motion-exit-fade", motionCss);
  assert.equal(Object.fromEntries(declarations(fade)).transition,
    "opacity var(--motion-fast) var(--motion-ease-in)");
  const [lift] = blocks(".motion-exit-lift", motionCss);
  assert.equal(Object.fromEntries(declarations(lift)).transition,
    "opacity var(--motion-fast) var(--motion-ease-in), transform var(--motion-fast) var(--motion-ease-in)");
  const [visible] = blocks(".motion-exit-visible", motionCss);
  assert.deepEqual(Object.fromEntries(declarations(visible)), {opacity: "1", transform: "none"});
  const [hidden] = blocks(".motion-exit-hidden", motionCss);
  assert.deepEqual(Object.fromEntries(declarations(hidden)), {opacity: "0", transform: "translateY(-4px)"});
});

test("window and dialog closing states fade out before the node is dropped", () => {
  for (const header of [
    'dialog.workbench-window[data-window-state="closing"]',
    // The native modal animates the .modal-box the DialogModal hook watches,
    // never the <dialog> itself (motion.css section 9).
    'dialog.modal[data-dialog-state="closing"] .modal-box'
  ]) {
    for (const body of blocks(header, motionCss)) {
      assert.equal(Object.fromEntries(declarations(body)).animation,
        "motion-fade-out var(--motion-fast) var(--motion-ease-in) both");
    }
  }
  // The <dialog> element itself must never carry a closing animation: _hide()
  // only ever listens for an animationend on `.modal-box`.
  assert.doesNotMatch(motionCss, /dialog\.modal\[data-dialog-state="(?:opening|closing)"\]\s*\{/,
    "the dialog element is not the watched node");
  for (const header of [
    "dialog.workbench-window[open]",
    "dialog.modal[data-dialog-state=\"closing\"]::backdrop"
  ]) {
    assert.ok(blocks(header, motionCss).length >= 1);
  }
  // The palette exit is phx-remove-driven on the removed #project-omnibox root
  // (never a hook-written state attribute): motion.css must carry NO
  // [data-palette-state] vocabulary, and the exit reuses the shared fade-only
  // helper so no transform re-bases the two position: fixed layers.
  assert.doesNotMatch(motionCss, /\[data-palette-state/,
    "the dead palette-state vocabulary is back; the exit rides phx-remove");
  assert.doesNotMatch(motionCss, /palette-fade-out/,
    "no palette exit keyframe: the exit is the motion-exit-fade transition");
  const [fade] = blocks(".motion-exit-fade", motionCss);
  assert.equal(Object.fromEntries(declarations(fade)).transition,
    "opacity var(--motion-fast) var(--motion-ease-in)",
    "the palette's end class (opacity-0) only completes an opacity transition");
  // Source contract: the exit sits on the node projects_live.ex's :if removes.
  const omniboxSource = readFileSync(
    join(__dirname, "../../lib/evo_dash_web/components/project_components.ex"), "utf8");
  const omnibox = omniboxSource.slice(omniboxSource.indexOf('id="project-omnibox"'));
  assert.match(omnibox.slice(0, 400),
    /phx-remove=\{JS\.hide\(transition: \{"motion-exit-fade", "motion-exit-visible", "opacity-0"\}\)\}/,
    "#project-omnibox must carry an opacity-only phx-remove exit");
});

test("reduced-motion backstop is global, !important and the last block in motion.css", () => {
  const header = "@media (prefers-reduced-motion: reduce)";
  assert.equal(blocks(header, motionCss).length, 1, "motion.css carries exactly one backstop");
  const start = motionCss.lastIndexOf(header);
  const open = motionCss.indexOf("{", start + header.length);
  assert.equal(motionCss.slice(start + header.length, open).trim(), "");
  let depth = 1;
  let end = open + 1;
  for (; end < motionCss.length && depth; end++) {
    if (motionCss[end] === "{") depth++;
    if (motionCss[end] === "}") depth--;
  }
  assert.equal(depth, 0, "unclosed reduced-motion backstop");
  const body = motionCss.slice(open + 1, end - 1);
  assert.match(body, /\*,\s*\*::before,\s*\*::after\s*\{/);
  for (const declaration of [
    "animation-duration: .01ms !important",
    "animation-iteration-count: 1 !important",
    "transition-duration: .01ms !important",
    "transition-delay: 0s !important",
    "scroll-behavior: auto !important"
  ]) {
    assert.ok(body.includes(declaration), `missing backstop declaration: ${declaration}`);
  }
  assert.equal(motionCss.slice(end).trim(), "", "nothing may follow the reduced-motion backstop");
});

test("app.css has no transition: all and enumerates the input transitions", () => {
  assert.doesNotMatch(css, /(^|[;{\s])transition:\s*all\b/m);
  const [layout] = blocks(".input-layout", css);
  const transition = Object.fromEntries(declarations(layout)).transition;
  assert.match(transition, /min-height 0\.35s cubic-bezier\(0\.4, 0, 0\.2, 1\)/);
  assert.doesNotMatch(transition, /\ball\b/);
  for (const selector of [".input-card", ".input-prompt", ".input-controls"]) {
    assert.doesNotMatch(blocks(selector, css)[0], /transition:\s*all\b/);
  }
});

test("the palette keeps its entry keyframes and defines no exit keyframe", () => {
  const [fadeIn] = blocks("@keyframes palette-fade-in", css);
  assert.deepEqual([...fadeIn.matchAll(/opacity:\s*(\d)/g)].map(match => match[1]), ["0", "1"]);
  const [slideDown] = blocks("@keyframes palette-slide-down", css);
  assert.match(slideDown, /opacity/);
  assert.doesNotMatch(css, /@keyframes palette-fade-out/,
    "the exit is the shared motion-exit-fade transition, not a palette keyframe");
});
