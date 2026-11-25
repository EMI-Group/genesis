// The density + typography contract, as a source-level test.
//
// Contract (detail: docs/ui-density.md, assets/css/CONTEXT.md):
//   * `density.css` is imported immediately after `@import "tailwindcss"` and
//     before every component stylesheet, so its `@theme` block REPLACES the
//     stock Tailwind `text-*` steps; it must stay out of the pinned
//     workbench→motion import adjacency.
//   * the ladder is one table of exact size/line-height pairs (12 px floor).
//   * control / row / padding / gutter heights are `:root` tokens declared
//     ONCE in density.css and consumed as `var(--…)` everywhere else.
//   * DaisyUI's dial is restored to 0.25rem in BOTH theme blocks (40/32/24 px).
//   * no `font-size` in px or rem may fall below 0.75rem (12 px).
//   * the right panel is a flex column whose LIST alone scrolls.
//   * a coarse pointer gets >= 16 px text inputs, a 44 px row floor and a
//     44 px floor on real controls (the -xs adornments excepted).
//
// Pure source text, no browser and no npm dependencies: the shipped CSS is read
// with `fs.readFileSync`, exactly like motion.test.cjs / workbench_motion.test.cjs.
const test = require("node:test");
const assert = require("node:assert/strict");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");

const strip = source => source.replace(/\/\*[\s\S]*?\*\//g, "");

const FILES = ["density.css", "surfaces.css", "app.css", "workbench.css", "assistant.css", "motion.css"];
const source = Object.fromEntries(
  FILES.map(name => [name, strip(readFileSync(join(__dirname, name), "utf8"))])
);

const density = source["density.css"];
const app = source["app.css"];

function blocks(header, text = density) {
  const found = [];
  for (let start = text.indexOf(header); start !== -1; start = text.indexOf(header, start + 1)) {
    const tail = start + header.length;
    const open = text.indexOf("{", tail);
    if (open === -1 || text.slice(tail, open).trim()) continue;
    let depth = 1;
    let end = open + 1;
    for (; end < text.length && depth; end++) {
      if (text[end] === "{") depth++;
      if (text[end] === "}") depth--;
    }
    assert.equal(depth, 0, `unclosed block: ${header}`);
    found.push(text.slice(open + 1, end - 1));
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

// Every LEAF rule (innermost `{…}`) with its full selector list. Nested
// @media/@theme wrappers are skipped implicitly: their bodies contain further
// braces, so only real rules ever match.
function leafRules(text) {
  return [...text.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(match => ({
    selectorText: match[1].trim().replace(/\s+/g, " "),
    selectors: match[1].trim().split(/,\s*/).map(selector => selector.replace(/\s+/g, " ")),
    body: match[2]
  }));
}

function rulesWith(selector, text = source["workbench.css"]) {
  return leafRules(text).filter(rule => rule.selectors.includes(selector));
}

// --- the import slot -------------------------------------------------------

test("density.css is imported right after Tailwind and before every component sheet", () => {
  const imports = [...app.matchAll(/@import "([^"]+)"[^;]*;/g)].map(match => match[1]);
  assert.deepEqual(imports, [
    "tailwindcss",
    "./density.css",
    "./surfaces.css",
    "./assistant.css",
    "./workbench.css",
    "./motion.css"
  ]);

  // The surface/elevation layer sits between the scale and the component sheets.
  assert.match(app, /@import "\.\/density\.css";\s*@import "\.\/surfaces\.css";/);

  // The pinned adjacency and the last-import rule stay intact.
  assert.match(app, /@import "\.\/workbench\.css";\s*@import "\.\/motion\.css";/);
  assert.equal(imports[imports.length - 1], "./motion.css");
});

// --- the type ladder -------------------------------------------------------

test("the type ladder is one exact table of size/line-height pairs", () => {
  const [theme] = blocks("@theme");
  const ladder = values(theme);

  const expected = {
    "--text-2xs": ["0.75rem", "1rem"],
    "--text-xs": ["0.8125rem", "1.125rem"],
    "--text-sm": ["0.875rem", "1.25rem"],
    "--text-base": ["0.9375rem", "1.5rem"],
    "--text-lg": ["1.0625rem", "1.5rem"],
    "--text-xl": ["1.25rem", "1.625rem"],
    "--text-2xl": ["1.5rem", "1.875rem"],
    "--text-3xl": ["1.875rem", "2.25rem"]
  };

  for (const [token, [size, lineHeight]] of Object.entries(expected)) {
    assert.equal(ladder[token], size, `${token} size`);
    const paired = ladder[`${token}--line-height`];
    assert.equal(paired, lineHeight, `${token} line-height`);
    // 12 px floor: every step must resolve to >= 0.75rem.
    assert.ok(parseFloat(size) >= 0.75, `${token} is below the 12px floor`);
  }

  assert.equal(ladder["--leading-body"], "1.6");
});

// --- the density tokens ----------------------------------------------------

const TOKENS = {
  "--control-h": "2.5rem",
  "--control-h-sm": "2rem",
  "--control-h-xs": "1.5rem",
  "--row-h-sm": "2.25rem",
  "--row-h": "2.5rem",
  "--row-h-tall": "3rem",
  "--touch-target": "2.75rem",
  "--card-pad": "1rem",
  "--card-pad-lg": "1.25rem",
  "--page-gutter": "1rem",
  "--page-gutter-sm": "1.25rem",
  "--page-gutter-lg": "1.5rem"
};

test("each height/spacing token is declared exactly once, in density.css", () => {
  const [root] = blocks(":root");
  const declared = values(root);

  for (const [token, value] of Object.entries(TOKENS)) {
    assert.equal(declared[token], value, `${token} must be ${value} on :root`);
    for (const name of FILES) {
      const occurrences = [...source[name].matchAll(new RegExp(`${token}\\s*:`, "g"))].length;
      assert.equal(occurrences, name === "density.css" ? 1 : 0,
        `${token} must be DECLARED once in density.css only (found ${occurrences} in ${name})`);
    }
  }

  // 44px / 40px / 36px / 32px, spelled out so a silent retune is caught.
  assert.equal(TOKENS["--touch-target"], "2.75rem");
  assert.equal(TOKENS["--row-h"], "2.5rem");
  assert.equal(TOKENS["--row-h-sm"], "2.25rem");
  assert.equal(TOKENS["--control-h-sm"], "2rem");
});

// --- the DaisyUI dial ------------------------------------------------------

test("the DaisyUI control dial is restored to 0.25rem in BOTH themes", () => {
  const themes = blocks('@plugin "../vendor/daisyui-theme"', app);
  assert.equal(themes.length, 2, "expected the dark and light theme blocks");

  for (const theme of themes) {
    const declared = values(theme);
    assert.equal(declared["--size-field"], "0.25rem", "default control = 10 x 0.25rem = 40px");
    assert.equal(declared["--size-selector"], "0.25rem");
    // The radius dial is unrelated and must keep its values.
    assert.equal(declared["--radius-selector"], "0.375rem");
    assert.equal(declared["--radius-field"], "0.5rem");
    assert.equal(declared["--radius-box"], "0.75rem");
  }

  for (const name of FILES) {
    assert.doesNotMatch(source[name], /0\.21875rem/,
      `${name} still carries the old compressed dial (no 0.21875rem may remain)`);
  }
});

// --- the typography floor --------------------------------------------------

test("no font-size literal in app/workbench/assistant falls below 12px", () => {
  const offences = [];
  for (const name of ["app.css", "workbench.css", "assistant.css"]) {
    for (const match of source[name].matchAll(/font-size:\s*([0-9.]+)(px|rem)\s*;/g)) {
      const px = match[2] === "rem" ? parseFloat(match[1]) * 16 : parseFloat(match[1]);
      if (px < 12) offences.push(`${name}: font-size: ${match[1]}${match[2]} (${px}px)`);
    }
    // A `font:` shorthand must not smuggle a raw size literal in either.
    for (const match of source[name].matchAll(/font:\s*([0-9.]+)(px|rem)\b/g)) {
      const px = match[2] === "rem" ? parseFloat(match[1]) * 16 : parseFloat(match[1]);
      if (px < 12) offences.push(`${name}: font: ${match[1]}${match[2]} (${px}px)`);
    }
  }
  assert.deepEqual(offences, [], `text below the 12px chrome floor:\n  ${offences.join("\n  ")}`);
});

test("component stylesheets consume the ladder instead of arbitrary sizes", () => {
  // Every remaining px/rem font-size literal is a ladder step or the 16px
  // composer textarea (iOS focus zoom) — no 0.7/0.8125/13px style islands.
  const allowed = new Set(["12px", "13px", "14px", "15px", "16px", "17px", "20px", "24px", "30px"]);
  for (const name of ["workbench.css", "assistant.css"]) {
    for (const match of source[name].matchAll(/font-size:\s*([0-9.]+(?:px|rem))\s*;/g)) {
      assert.ok(allowed.has(match[1]), `${name} carries a non-ladder font-size: ${match[1]}`);
    }
  }
  // The composer textarea stays 16px.
  assert.match(source["assistant.css"], /\.assistant-textarea \{[^}]*font-size: 16px;/);
});

// --- shared composer chrome and control sizing -----------------------------

const composerStyles = source["assistant.css"];
const composer = "#app-layout .workbench-composer-surface:is(.workbench-composer[data-composer-kind], .workbench-composer[data-composer-kind] *)";
const trigger = ".workbench-composer-toolbar details.capsule > .capsule-trigger";
const advancedSummary = ".workbench-task-options #task-advanced-options > summary";

test("one flat composer surface supports both wrapper placements without decorating the whole form", () => {
  const shared = leafRules(composerStyles).filter(rule => rule.selectorText === composer);
  assert.equal(shared.length, 1);
  const chrome = values(shared[0].body);
  assert.equal(chrome.border, "1px solid var(--border-hairline)");
  assert.equal(chrome["border-radius"], "var(--radius-2xl)");
  assert.equal(chrome.background, "var(--composer-surface)");
  assert.equal(chrome["box-shadow"], "none");
  assert.equal(chrome.transition, "var(--composer-transition, var(--composer-focus-transition))");

  for (const [sheet, selector] of [
    ["assistant.css", ".assistant-input-card"],
    ["app.css", ".input-card"],
    ["app.css", '.input-layout[data-layout="compact"] .input-card'],
    ["app.css", '.input-layout[data-layout="expanded"] .input-card']
  ]) {
    for (const rule of rulesWith(selector, source[sheet])) {
      assert.doesNotMatch(rule.body, /(?:^|[;\s])(?:border(?:-[\w-]+)?|background(?:-[\w-]+)?|box-shadow|transition)\s*:/,
        `${sheet}: ${selector} is layout-only; put chrome in the shared rule`);
    }
  }

  const sizing = leafRules(composerStyles).filter(rule => "--composer-transition" in values(rule.body));
  assert.deepEqual(sizing.map(rule => rule.selectorText), [
    '.workbench-composer[data-composer-kind="task"]'
  ], "only the task composer animates AdaptiveInput's size changes");
  assert.match(values(sizing[0].body)["--composer-transition"], /^min-height\b[\s\S]+var\(--composer-focus-transition\)$/);
});

test("the New Task page and composer have distinct tones in both themes", () => {
  const page = ":is(#main-content, #main-scroll):has(#workbench-task-composer)";
  const task = '.workbench-composer[data-composer-kind="task"]';
  for (const prefix of ["", '[data-theme="dark"] ']) {
    const declarationsFor = selector => values(blocks(prefix + selector, composerStyles)[0]);
    assert.notEqual(declarationsFor(page).background, declarationsFor(task)["--composer-surface"]);
  }
});

test("composer focus is visible on the surface and on the exact keyboard control", () => {
  const [within] = blocks(`${composer}:focus-within`, composerStyles);
  const focus = values(within);
  assert.equal(focus["border-color"], "var(--color-primary-standalone)");
  assert.match(focus["box-shadow"], /^0 0 0 2px .*var\(--color-primary-standalone\)/);

  const keyboard = ".workbench-composer-toolbar :is(button, summary):focus-visible";
  const [focusRule] = leafRules(composerStyles).filter(rule => rule.selectorText.startsWith(`${keyboard},`));
  assert.equal(values(focusRule.body).outline, "2px solid var(--color-primary-standalone)");

  const [forced] = blocks("@media (forced-colors: active)", composerStyles);
  const [forcedFocus] = blocks(".workbench-composer-surface:focus-within", forced);
  assert.equal(values(forcedFocus).outline, "2px solid Highlight");
});

test("composer capsule summaries are flat at rest and distinct while open", () => {
  const [summary] = blocks(trigger, composerStyles);
  const resting = values(summary);
  assert.equal(resting.border, "0");
  assert.equal(resting.background, "transparent");
  assert.equal(resting["min-block-size"], "var(--control-h-sm)");

  const [opened] = blocks(".workbench-composer-toolbar details.capsule[open] > .capsule-trigger", composerStyles);
  assert.equal(values(opened).background, "var(--surface-selected)");
});

test("inline task options flatten the toggles and keep only a division above advanced fields", () => {
  const [toggles] = blocks(".workbench-task-options label:has(> .toggle)", composerStyles);
  assert.equal(values(toggles).border, "0");
  assert.equal(values(toggles).background, "transparent");

  const [advanced] = blocks(".workbench-task-options #task-advanced-options", composerStyles);
  assert.equal(values(advanced).border, "0");
  assert.equal(values(advanced)["border-block-start"], "1px solid var(--border-hairline)");
  const [summary] = blocks(advancedSummary, composerStyles);
  assert.equal(values(summary)["min-block-size"], "var(--row-h)");
});

// --- right-panel scroll containment ----------------------------------------

test("the right panels are flex columns that never scroll themselves", () => {
  const panels = leafRules(source["workbench.css"]).filter(rule =>
    rule.selectors.includes("#workbench-history") && rule.selectors.includes("#workbench-git"));

  assert.equal(panels.length, 1, "expected ONE #workbench-history + #workbench-git rule");
  const declared = values(panels[0].body);
  assert.equal(declared.display, "flex");
  assert.equal(declared["flex-direction"], "column");
  assert.equal(declared.overflow, "hidden", "the panel must clip, never scroll");
  assert.equal(declared["min-height"], "0", "the panel must be allowed to shrink");

  // The base class rule may not bring `overflow: auto` back.
  for (const rule of leafRules(source["workbench.css"])) {
    if (!rule.selectors.some(selector => selector.startsWith(".workbench-history"))) continue;
    assert.notEqual(values(rule.body).overflow, "auto",
      `no .workbench-history rule may scroll the panel: ${rule.selectors.join(", ")}`);
  }
});

test("the history list is the ONE scroller and the header stays put", () => {
  const [rows] = rulesWith("#workbench-history-rows");
  assert.deepEqual(values(rows.body), {
    flex: "1 1 auto",
    "min-height": "0",
    "overflow-y": "auto",
    "overscroll-behavior": "contain"
  });

  const content = leafRules(source["workbench.css"]).filter(rule =>
    rule.selectors.includes("#workbench-history-content") &&
    rule.selectors.includes("#workbench-git-content"));
  assert.equal(content.length, 1);
  const declared = values(content[0].body);
  assert.equal(declared.display, "flex");
  assert.equal(declared["flex-direction"], "column");
  assert.equal(declared.flex, "1 1 auto");
  assert.equal(declared["min-height"], "0");

  // The heading, the project label and the filter form never shrink away.
  const pinned = leafRules(source["workbench.css"]).filter(rule =>
    rule.selectors.includes("#workbench-history .workbench-section-heading") &&
    rule.selectors.includes("#workbench-history-project") &&
    rule.selectors.includes("#workbench-history-filters"));
  assert.equal(pinned.length, 1, "expected ONE flex: none rule for the pinned history header");
  assert.equal(values(pinned[0].body).flex, "none");
});

test("history chrome follows the DOM and keeps controls and two-line rows readable", () => {
  const css = source["workbench.css"];
  for (const rule of leafRules(css).filter(rule => /workbench-history/.test(rule.selectorText))) {
    assert.doesNotMatch(rule.body, /(?:^|;)\s*(?:order|grid-(?:area|row|column)(?:-start|-end)?|grid-template-areas)\s*:/,
      `history's paint and focus order must agree: ${rule.selectorText}`);
  }

  const [filters] = rulesWith(".workbench-history-filters");
  assert.equal(values(filters.body)["grid-template-columns"], "repeat(2, minmax(0, 1fr))");
  for (const selector of [".workbench-history-filter", "#workbench-history-query"]) {
    const [control] = rulesWith(selector);
    assert.equal(values(control.body)["min-height"], "var(--control-h)");
  }

  const [row] = rulesWith(".workbench-history-row > .workbench-row");
  assert.equal(values(row.body)["min-block-size"], "var(--row-h-tall)");
  assert.doesNotMatch(row.body, /(?:^|;)\s*border(?:-block|-bottom|-top)?\s*:/, "rows use space, not dividers");
  const [meta] = rulesWith(".workbench-history-meta");
  assert.equal(values(meta.body)["font-size"], "var(--text-xs)");
  assert.equal(values(meta.body)["flex-wrap"], "wrap");
});

test("the kind switch fits translated labels and takes the touch floor", () => {
  const css = source["workbench.css"];
  const switchRule = leafRules(css).find(rule =>
    rule.selectorText.includes('.workbench-history-switch:is([data-history-kind="tasks"], [data-history-kind="conversations"])'));
  assert.equal(values(switchRule.body)["grid-template-columns"], "repeat(2, minmax(0, 1fr))");
  const button = ".workbench-history-switch [data-workbench-kind]";
  const [choice] = rulesWith(button);
  const declared = values(choice.body);
  assert.equal(declared["min-height"], "var(--control-h)");
  assert.equal(declared["min-width"], "0");
  assert.equal(declared["overflow-wrap"], "anywhere");
  for (const property of ["white-space", "text-overflow", "max-width", "width", "inline-size", "max-inline-size"]) {
    assert.equal(declared[property], undefined, `a translated label must not be clipped by ${property}`);
  }

  const coarse = blocks("@media (pointer: coarse)", css).join("\n");
  const [touch] = rulesWith(button, coarse);
  assert.equal(values(touch.body)["min-height"], "var(--touch-target)");
  const [search] = rulesWith("#workbench-history-search", coarse);
  assert.equal(values(search.body)["font-size"], "16px");
});

test("only the selected Source Control view scrolls", () => {
  const [body] = rulesWith(".workbench-git-body");
  const declared = values(body.body);
  assert.equal(declared.display, "flex");
  assert.equal(declared["flex-direction"], "column");
  assert.equal(declared.flex, "1 1 auto");
  assert.equal(declared["min-height"], "0");
  assert.equal(declared.overflow, "hidden", "the body clips instead of scrolling its controls");

  const view = ".workbench-git-body > :is(#workbench-git-changes, #workbench-git-branches, #workbench-git-history)";
  const scrollOwners = Object.values(source).flatMap(leafRules).filter(rule => {
    // The portaled diff is outside the dock and owns a separate scroller.
    if (!/#workbench-git(?![\w-])|[.#]workbench-git-(?!diff\b)/.test(rule.selectorText)) return false;
    return declarations(rule.body).some(([key, value]) =>
      /^overflow(?:-[xy]|-block|-inline)?$/.test(key) && /\b(auto|scroll|overlay)\b/.test(value));
  });
  assert.deepEqual(scrollOwners.map(rule => rule.selectorText), [view]);
  assert.deepEqual(values(scrollOwners[0].body), {
    flex: "1 1 auto",
    "min-height": "0",
    "overflow-y": "auto",
    "overscroll-behavior": "contain"
  });
});

test("Source Control keeps its heading, summary and view switcher at intrinsic height", () => {
  for (const selector of [
    "#workbench-git-content .workbench-section-heading",
    ".workbench-git-summary",
    ".workbench-git-views"
  ]) {
    const flex = rulesWith(selector).flatMap(rule => declarations(rule.body))
      .filter(([key]) => key === "flex").map(([, value]) => value);
    assert.deepEqual(flex, ["none"], `${selector} must not grow or shrink with the list`);
  }

  const [search] = rulesWith("#workbench-git-search");
  const declared = values(search.body);
  assert.equal(declared.position, "sticky", "branch search stays reachable inside the scrolling view");
  assert.equal(declared["inset-block-start"], "0");
  assert.equal(declared.background, "var(--surface-dock)", "rows must not show through the search field");
  const [branches] = blocks("#workbench-git-branches", source["workbench.css"]);
  assert.match(values(branches)["scroll-padding-block-start"], /var\(--touch-target\)/,
    "keyboard scrolling leaves space for sticky branch search");
});

test("no right-panel scroller asks for smooth scrolling", () => {
  for (const rule of leafRules(source["workbench.css"])) {
    if (!/workbench-history|workbench-git|workbench-row/.test(rule.selectorText)) continue;
    assert.doesNotMatch(rule.body, /scroll-behavior:\s*smooth/,
      `smooth scrolling on ${rule.selectorText}`);
  }
});

// --- the coarse-pointer recipe --------------------------------------------

test("composer controls reach the touch floor for coarse pointers", () => {
  const [coarse] = blocks("@media (pointer: coarse)", composerStyles);
  const [touchTargets] = leafRules(coarse).filter(rule =>
    [".assistant-send-button", "#objective-file-button", "#task-launch-button", trigger]
      .every(selector => rule.selectorText.includes(selector)));
  assert.equal(values(touchTargets.body)["min-inline-size"], "var(--touch-target)");
  assert.equal(values(touchTargets.body)["min-block-size"], "var(--touch-target)");

  const [advanced] = blocks(advancedSummary, coarse);
  assert.equal(values(advanced)["min-block-size"], "var(--touch-target)");
});

test("a coarse pointer gets 16px inputs and a 44px row floor", () => {
  const [coarse] = blocks("@media (pointer: coarse)");
  assert.ok(coarse, "density.css must carry the coarse-pointer recipe");

  // iOS focus zoom: every text input is >= 16px.
  const inputs = leafRules(coarse).filter(rule =>
    rule.selectorText.includes(":is(input, select, textarea)"));
  assert.equal(inputs.length, 1, "expected ONE input/select/textarea rule");
  assert.equal(values(inputs[0].body)["font-size"], "1rem");

  // Finger targets: ONE row/nav floor plus ONE real-control floor, both at
  // var(--touch-target).
  const floors = leafRules(coarse).filter(rule =>
    rule.body.includes("min-height: var(--touch-target)"));
  assert.equal(floors.length, 2, "expected the row floor and the control floor");
  const rows = floors.filter(rule => rule.selectorText.includes(".workbench-row"));
  assert.equal(rows.length, 1, "expected ONE row-floor rule");
  for (const selector of [
    ".workbench-row",
    ".workbench-history-row > a",
    ".workbench-tab",
    ".project-picker-list .workbench-row",
    ".assistant-menu-item",
    "#chat-session-list > a"
  ]) {
    assert.ok(rows[0].selectorText.includes(selector),
      `the coarse row floor is missing ${selector}`);
  }
  // Real controls clear 44px too; `.btn-xs` / `.input-xs` / `.select-xs` are
  // inline adornments and stay out of it.
  const controls = floors.filter(rule => rule.selectorText.includes(".btn"));
  assert.equal(controls.length, 1, "expected ONE real-control floor rule");
  for (const selector of [".btn", ".btn-sm", ".btn-square", ".input", ".input-sm", ".select", ".select-sm"]) {
    assert.ok(controls[0].selectorText.includes(selector),
      `the coarse control floor is missing ${selector}`);
  }
  assert.match(controls[0].selectorText, /:not\(\.btn-xs, \.input-xs, \.select-xs\)/,
    "the control floor must leave the -xs adornments alone");

  // ...and the DaisyUI dial reaches 44px default / 35px compact there.
  const dial = values(leafRules(coarse).find(rule => rule.selectors.includes(":root")).body);
  assert.equal(dial["--size-field"], "0.275rem");
  assert.equal(parseFloat(dial["--size-field"]) * 16 * 10, 44);
  assert.equal(parseFloat(dial["--size-field"]) * 16 * 8, 35.2);
});
