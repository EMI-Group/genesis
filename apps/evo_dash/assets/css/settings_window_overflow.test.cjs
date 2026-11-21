// The Settings window's horizontal-overflow contract, as a source-level test.
//
// Contract (detail: assets/css/CONTEXT.md, "In-shell height contract"):
//   * the in-place Settings popup is `#workbench-settings-frame`, an iframe
//     inside `dialog.workbench-window`, so it scrolls its OWN document.
//   * its header picker (`#workbench-settings-server-form`,
//     `.workbench-settings-server-picker`) is a SHRINKABLE flex row: the
//     "Settings server" label keeps its nowrap wording while the `<select>`
//     takes what is left and may shrink (`min-width: 0`, content-sized width).
//   * a percentage-width select (`w-full`) inside that shrink-to-fit flex line
//     is the bug: the line cannot shrink below its nowrap label, so the select
//     sticks out past the iframe's right edge and the whole popup document
//     gained a horizontal scrollbar (measured 73px at a 1072px viewport).
//   * the content pane of the two-column row keeps `min-w-0`, and the popup's
//     own scroll container (`.workbench-window-page`, `overflow: auto`) stays —
//     the fix must not MASK the overflow with `overflow: hidden`.
//
// Pure source text, no browser and no npm dependencies: the shipped CSS/markup
// is read with `fs.readFileSync`, exactly like layout_contract.test.cjs. The
// helpers below are local on purpose — layout_contract.test.cjs does not export
// its own.
const test = require("node:test");
const assert = require("node:assert/strict");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");

const APP_DIR = join(__dirname, "..", "..");

// Comments are blanked, not deleted, so reported line numbers stay true.
const css = readFileSync(join(__dirname, "workbench.css"), "utf8")
  .replace(/\/\*[\s\S]*?\*\//g, comment => comment.replace(/[^\n]/g, " "));
const settingsLive = readFileSync(
  join(APP_DIR, "lib", "evo_dash_web", "live", "settings_live.ex"),
  "utf8"
);

const PICKER = ".workbench-settings-server-picker";

function declarations(body) {
  return body
    .split(";")
    .map(part => part.trim())
    .filter(Boolean)
    .map(part => {
      const colon = part.indexOf(":");
      return colon === -1
        ? null
        : [part.slice(0, colon).trim(), part.slice(colon + 1).trim()];
    })
    .filter(Boolean);
}

// The innermost rules of the CSS source: `@media` wrappers are skipped
// implicitly because their prelude is followed by a NESTED `{`, so only real
// leaf rules ever match.
const RULES = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(match => {
  const selectorText = match[1].trim().replace(/\s+/g, " ");
  const bodyStart = match.index + match[1].length;
  return {
    line: css.slice(0, bodyStart).split("\n").length,
    selectorText,
    selectors: selectorText.split(",").map(selector => selector.trim()),
    declarations: declarations(match[2])
  };
});

function rules(selector) {
  return RULES.filter(rule => rule.selectors.includes(selector));
}

// Merged declarations of every leaf rule with EXACTLY this selector (a base rule
// plus a `@media` override of the same selector collapse into one map; the later
// declaration wins, as in the cascade at that width).
function declarationsOf(selector) {
  return Object.fromEntries(rules(selector).flatMap(rule => rule.declarations));
}

function elsewhere(rule) {
  return ` (workbench.css:${rule.line} ${rule.selectorText})`;
}

// Markup helpers: the `<header>` / `<.input>` slices of the Settings window.
function windowHeader() {
  const start = settingsLive.indexOf('<header :if={@live_action == :window} class="workbench-window-header">');
  assert.notEqual(start, -1, "settings_live.ex: the window header is missing");
  const end = settingsLive.indexOf("</header>", start);
  assert.notEqual(end, -1, "settings_live.ex: the window header is unclosed");
  return settingsLive.slice(start, end);
}

function pickerInput(header) {
  const start = header.indexOf("<.input");
  assert.notEqual(start, -1, "settings_live.ex: the window header renders no <.input> picker");
  const end = header.indexOf("/>", start);
  assert.notEqual(end, -1, "settings_live.ex: the window header picker input is unclosed");
  return header.slice(start, end);
}

test("the Settings-server picker is a shrinkable flex row", () => {
  const picker = declarationsOf(PICKER);
  assert.equal(picker.display, "flex", "the picker must be a flex container");
  assert.ok(picker.flex, "the picker must declare its own flex shorthand");
  assert.notEqual(picker.flex, "none", "a `flex: none` picker cannot shrink");
  assert.match(picker.flex, /^(0|1) 1 (auto|0)$/, `the picker must shrink: ${picker.flex}`);
  assert.equal(picker["min-width"], "0", "the picker needs min-width: 0 to shrink below its content");
});

test("the picker's label and select shrink instead of demanding their full width", () => {
  const label = declarationsOf(`${PICKER} label`);
  assert.equal(label.display, "flex", "the label wraps its span + select in a flex row");
  assert.equal(label["min-width"], "0", "the label needs min-width: 0 to shrink");
  assert.equal(label["white-space"], "nowrap", "the label wording stays on one line");

  const select = declarationsOf(`${PICKER} select`);
  assert.equal(select["min-width"], "0", "the select needs min-width: 0 to shrink");
  assert.equal(select.width, "auto", "the select must be content-sized, never percentage-wide");
  assert.ok(select.flex, "the select takes the remaining space through flex");
  assert.ok(select["max-width"], "the select keeps a max-width cap");

  // The bug shape: a percentage-width select in that shrink-to-fit line.
  for (const rule of RULES) {
    if (!rule.selectors.some(selector => selector.startsWith(PICKER))) continue;
    for (const [property, value] of rule.declarations) {
      if (property !== "width" || !rule.selectors.some(selector => /\bselect\b/.test(selector))) continue;
      assert.notEqual(value, "100%", `no percentage-width select under the picker${elsewhere(rule)}`);
    }
  }
});

test("the window header renders the server picker with a shrinking heading", () => {
  const header = windowHeader();
  assert.match(header, /<h1 class="[^"]*\bmin-w-0\b[^"]*\bflex-1\b[^"]*"/, "the heading must shrink (min-w-0 flex-1)");
  assert.match(header, /id="workbench-settings-server-form"/, "the picker form is missing from the window header");
  assert.match(header, /class="workbench-settings-server-picker"/, "the picker form lost its CSS class");
  // The form lives INSIDE the header (it is the header's second flex item).
  const input = pickerInput(header);
  assert.match(input, /type="select"/, "the window header picker must be a select");
  const classAttr = input.match(/class="([^"]*)"/);
  assert.ok(classAttr, "settings_live.ex: the picker input declares no class");
  assert.ok(!/\bw-full\b/.test(classAttr[1]), `the picker select must not be w-full: ${classAttr[1]}`);
});

test("the two-column row keeps shrinkable panes and the iframe's own scroller", () => {
  assert.match(
    settingsLive,
    /class="wizard-step-enter flex-1 flex flex-col min-w-0 min-h-0"/,
    "settings_live.ex: the content pane must keep flex-1 flex flex-col min-w-0 min-h-0"
  );

  // The desktop nav rail (the narrow-width override stacks it on purpose).
  const nav = rules(".workbench-settings-nav").find(
    rule => rule.declarations.some(([property, value]) => property === "flex" && value === "0 0 13rem")
  );
  assert.ok(nav, "workbench.css: the settings nav keeps its fixed 13rem rail");
  assert.ok(
    nav.declarations.some(([property, value]) => property === "min-height" && value === "0"),
    `workbench.css: the settings nav keeps min-height: 0 so it can scroll${elsewhere(nav)}`
  );

  const page = declarationsOf("#workbench-window-content .workbench-window-page");
  assert.equal(page.padding, "0", "the popup page relies on the panes for padding");
  assert.equal(
    declarationsOf(".workbench-window-page")["overflow"],
    "auto",
    "the popup page is its own scroll container"
  );

  // The fix must not MASK the overflow: neither the header nor the picker clips.
  for (const selector of [".workbench-window-header", PICKER]) {
    for (const rule of rules(selector)) {
      for (const [property, value] of rule.declarations) {
        if (!property.startsWith("overflow")) continue;
        assert.ok(
          value !== "hidden" && !/^hidden\b/.test(value),
          `${selector} must not hide overflow${elsewhere(rule)}`
        );
      }
    }
  }
});
