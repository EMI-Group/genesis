const test = require("node:test");
const assert = require("node:assert/strict");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");

// Source contracts, not a browser/cascade simulator. No npm dependencies.
const css = readFileSync(join(__dirname, "app.css"), "utf8")
  .replace(/\/\*[\s\S]*?\*\//g, "");

function blocks(header) {
  const result = [];
  for (let start = css.indexOf(header); start !== -1; start = css.indexOf(header, start + 1)) {
    const open = css.indexOf("{", start + header.length);
    if (css.slice(start + header.length, open).trim()) continue;
    let depth = 1;
    let end = open + 1;
    for (; end < css.length && depth; end++) {
      if (css[end] === "{") depth++;
      if (css[end] === "}") depth--;
    }
    assert.equal(depth, 0, `unclosed block: ${header}`);
    result.push(css.slice(open + 1, end - 1));
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
