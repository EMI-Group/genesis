// The surface + elevation contract, as a source-level test.
//
// Contract (detail: assets/css/CONTEXT.md, "Surfaces & elevation"):
//   * `surfaces.css` is the ONE owner of the layering vocabulary and it is
//     imported right after `density.css`, before every component sheet.
//   * three layers — chrome (`--surface-shell` / `--surface-rail`), the content
//     canvas (`--surface-canvas`) and the overlays (`--surface-raised` plus
//     `--elev-1/2/3`). Overlays are the ONLY shadowed surfaces.
//   * every token is declared exactly once, on `:root` (plus a
//     `[data-theme="dark"]` counterpart whose values differ) and never in
//     another stylesheet.
//   * `surfaces.css` declares no size, padding or gap: `density.css` stays the
//     only owner of the scale.
//   * the workbench tab strip has ONE declaration per selector group — one
//     `.workbench-tab`, one `.workbench-tab-link`, one `.workbench-top` flex
//     rule — with a NATIVE active tab (canvas fill, top-only radius, a negative
//     bottom margin joining it to the canvas) and no `inset 0 -2px` underline.
//   * the published behaviour hooks (`[data-preview="true"]`, the rail-end
//     overflow menu) are styled here.
//   * content surfaces carry NO elevation (only `var(--elev-*)` where a surface
//     legitimately lifts); overlays consume `var(--elev-2)` / `var(--elev-3)`.
//
// Pure source text, no browser and no npm dependencies: the shipped CSS is read
// with `fs.readFileSync`, exactly like density.test.cjs / motion.test.cjs.
const test = require("node:test");
const assert = require("node:assert/strict");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");

const strip = source => source.replace(/\/\*[\s\S]*?\*\//g, "");

const FILES = [
  "surfaces.css",
  "app.css",
  "workbench.css",
  "assistant.css",
  "density.css",
  "motion.css"
];
const source = Object.fromEntries(
  FILES.map(name => [name, strip(readFileSync(join(__dirname, name), "utf8"))])
);
const surfaces = source["surfaces.css"];

// Every LEAF rule (innermost `{…}`) with its full selector list. `@media` /
// `@theme` wrappers are skipped implicitly: their bodies contain further braces.
function leafRules(text) {
  return [...text.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(match => ({
    selectorText: match[1].trim().replace(/\s+/g, " "),
    selectors: match[1].trim().split(/,\s*/).map(selector => selector.replace(/\s+/g, " ")),
    body: match[2]
  }));
}

function declarations(body) {
  return body.split(";").map(part => part.trim()).filter(Boolean)
    .map(part => part.split(":").map(value => value.trim()));
}

function values(body) {
  return Object.fromEntries(declarations(body));
}

function rulesWith(selector, text, options = {}) {
  return leafRules(text ?? surfaces).filter(rule => {
    const match = rule.selectors.includes(selector);
    return options.exactSelectorText ? match && rule.selectorText === selector : match;
  });
}

// A rule whose selector TEXT contains `fragment` — for selectors carrying a
// comma inside `:is(…)`, which the selector splitter above cannot see.
function ruleContaining(fragment, text) {
  return leafRules(text ?? surfaces).filter(rule => rule.selectorText.includes(fragment));
}

function merge(rules) {
  return Object.fromEntries(rules.flatMap(rule => declarations(rule.body)));
}

// --- the token layer -------------------------------------------------------

const TONES = [
  "--surface-shell",
  "--surface-rail",
  "--surface-canvas",
  "--surface-hover",
  "--surface-selected",
  "--surface-raised",
  "--elev-1",
  "--elev-2",
  "--elev-3",
  "--border-hairline",
  "--border-strong"
];
// Theme-independent geometry: declared once on `:root`, never per theme.
const GEOMETRY = ["--radius-tab"];
const TOKENS = [...TONES, ...GEOMETRY];

test("every surface/elevation token is declared once per theme, never elsewhere", () => {
  for (const token of TOKENS) {
    const expected = GEOMETRY.includes(token) ? 1 : 2; // light + dark
    for (const name of FILES) {
      const occurrences = [...source[name].matchAll(new RegExp(`${token}\\s*:`, "g"))].length;
      assert.equal(occurrences, name === "surfaces.css" ? expected : 0,
        `${token} must be DECLARED ${expected}x in surfaces.css only (found ${occurrences} in ${name})`);
    }
  }

  // They all live on the theme roots — never on a shell id (the Settings window
  // document has no #app-layout), never on a component rule.
  for (const token of TOKENS) {
    const roots = leafRules(surfaces).filter(rule => rule.selectors.includes(":root"));
    const darks = leafRules(surfaces).filter(rule => rule.selectors.includes('[data-theme="dark"]'));
    assert.ok(roots.some(rule => token in values(rule.body)), `${token} must be declared on :root`);
    assert.equal(
      darks.filter(rule => token in values(rule.body)).length,
      GEOMETRY.includes(token) ? 0 : 1,
      `${token} must ${GEOMETRY.includes(token) ? "not " : ""}be re-declared for the dark theme`
    );
  }
});

test("the light and dark token values are both present and differ", () => {
  const light = merge(leafRules(surfaces).filter(rule => rule.selectors.includes(":root")));
  const dark = merge(leafRules(surfaces).filter(rule => rule.selectors.includes('[data-theme="dark"]')));

  for (const token of TONES) {
    assert.ok(light[token], `${token} is missing from the light :root block`);
    assert.ok(dark[token], `${token} is missing from the [data-theme="dark"] block`);
    assert.notEqual(dark[token], light[token], `${token} must resolve differently in the dark theme`);
  }

  // Geometry is theme-independent by design.
  for (const token of GEOMETRY) {
    assert.equal(dark[token], undefined, `${token} is geometry and must not be re-declared for dark`);
  }

  // Elevation is only ever a shadow list, and the dark theme carries more alpha
  // than the near-invisible light one (a dark surface separates by depth).
  for (const token of ["--elev-1", "--elev-2", "--elev-3"]) {
    assert.match(light[token], /^(0|\d+px) \d+px/, `${token} must be a box-shadow list`);
    assert.match(dark[token], /^(0|\d+px) \d+px/, `${token} must be a box-shadow list`);
    assert.match(light[token], /var\(--color-base-content\)/,
      `${token} derives from the existing palette in the light theme`);
  }

  // Every tone derives from the existing palette — no new colors.
  for (const token of TONES) {
    const declared = token in light ? light[token] : dark[token];
    assert.match(
      declared,
      /var\(--color-(base|primary)-/,
      `${token} must resolve from a base/neutral/primary token, got: ${declared}`
    );
  }
});

test("surfaces.css owns no size, padding or gap (density.css keeps the scale)", () => {
  const banned = /(^|[;{\s])(font-size|height|min-height|max-height|width|min-width|max-width|padding|padding-[a-z-]+|gap|row-gap|column-gap|line-height)\s*:/;
  for (const rule of leafRules(surfaces)) {
    assert.doesNotMatch(rule.body, banned,
      `surfaces.css must stay size-free: ${rule.selectorText} { … }`);
  }
});

// --- the import slot -------------------------------------------------------

test("app.css imports surfaces.css between the scale and the component sheets", () => {
  const imports = [...source["app.css"].matchAll(/@import "([^"]+)"[^;]*;/g)].map(match => match[1]);
  assert.deepEqual(imports, [
    "tailwindcss",
    "./density.css",
    "./surfaces.css",
    "./assistant.css",
    "./workbench.css",
    "./motion.css",
    "./view_transitions.css"
  ]);
});

// --- the native tab strip --------------------------------------------------

const workbench = source["workbench.css"];

test("the tab strip has ONE declaration per selector group", () => {
  for (const selector of [".workbench-tab", ".workbench-tab-link", ".workbench-tabs"]) {
    const rules = rulesWith(selector, workbench, {exactSelectorText: true});
    assert.equal(rules.length, 1,
      `expected exactly ONE ${selector} rule in workbench.css (found ${rules.length})`);
  }

  // `.workbench-top` may carry ONE responsive override; exactly one rule owns
  // the bar's flex basis, and it consumes the shell token.
  const topbar = rulesWith(".workbench-top", workbench);
  const flex = topbar.filter(rule => "flex" in values(rule.body));
  assert.equal(flex.length, 1, "expected ONE .workbench-top flex rule");
  assert.equal(values(flex[0].body).flex, "0 0 var(--shell-topbar-h)");

  // No selected-underline pill survives anywhere.
  for (const name of FILES) {
    assert.doesNotMatch(source[name], /inset\s+0\s+-2px/,
      `${name} still carries the old ` + "`inset 0 -2px`" + ` tab underline`);
  }
});

test("the active tab is continuous with the canvas", () => {
  const [current] = rulesWith(".workbench-tab.is-current", workbench);
  assert.ok(current, "the active tab rule is missing");
  const declared = values(current.body);

  assert.equal(declared.background, "var(--surface-canvas)",
    "the active tab takes the canvas fill");
  assert.equal(declared["margin-block-end"], "-1px",
    "the active tab joins the canvas through a negative bottom margin");
  assert.equal(declared["border-block-end-color"], "var(--surface-canvas)",
    "the tab's bottom border paints over the bar's hairline in the canvas colour");
  assert.equal(declared["border-color"], "var(--border-hairline)",
    "the sides and the top carry the hairline");
  assert.equal(declared["box-shadow"], undefined, "the active tab carries no shadow");
  assert.equal(declared["z-index"], "1", "the active tab paints above the bar's hairline");

  // Top-only rounding, on the shared radius token, for BOTH the base slab and
  // the active tab (the hover silhouette matches the active shape).
  const [tab] = rulesWith(".workbench-tab", workbench, {exactSelectorText: true});
  const radius = values(tab.body)["border-radius"];
  assert.equal(radius, "var(--radius-tab) var(--radius-tab) 0 0");
  assert.equal(values(current.body)["border-radius"], undefined,
    "the active tab inherits the slab's top-only rounding instead of re-declaring it");
});

test("the strip bottom-aligns its tabs and scrolls without smooth scrolling", () => {
  const [strip] = rulesWith(".workbench-tabs", workbench, {exactSelectorText: true});
  const declared = values(strip.body);
  assert.equal(declared["overflow-x"], "auto");
  assert.equal(declared["scrollbar-width"], "thin");
  assert.equal(declared["align-items"], "flex-end");
  assert.equal(declared["align-self"], "stretch");
  // The 1px padding absorbs the active tab's -1px margin inside the scroller.
  assert.equal(declared["padding-block-end"], "1px");
  assert.equal(declared["margin-block-end"], "-1px");
  assert.doesNotMatch(strip.body, /scroll-behavior:\s*smooth/);

  const [tab] = rulesWith(".workbench-tab", workbench, {exactSelectorText: true});
  assert.equal(values(tab.body)["align-self"], "flex-end");
  assert.equal(values(tab.body)["block-size"], "var(--row-h-sm)");
});

test("the close button reveals on hover/focus and is always visible when current", () => {
  const [close] = rulesWith(".workbench-tab-close", workbench, {exactSelectorText: true});
  const declared = values(close.body);
  assert.equal(declared.opacity, "0", "hidden by default");
  assert.equal(declared.visibility, "hidden");

  const reveal = ruleContaining(".workbench-tab:is(:hover, :focus-within) .workbench-tab-close", workbench);
  assert.equal(reveal.length, 1, "the hover/focus reveal rule is missing");
  assert.deepEqual(values(reveal[0].body), {opacity: "1", visibility: "visible"});

  const always = ruleContaining(".workbench-tab.is-current .workbench-tab-close", workbench);
  assert.equal(always.length, 1, "the active tab must always show its close control");
});

// --- the published behaviour hooks -----------------------------------------

test("the published tab hooks are styled", () => {
  assert.ok(rulesWith('.workbench-tab[data-preview="true"] .workbench-tab-link', workbench).length,
    'the preview tab must style its title ([data-preview="true"])');
  const previewTitle = values(rulesWith('.workbench-tab[data-preview="true"] .workbench-tab-link', workbench)[0].body);
  assert.equal(previewTitle["font-style"], "italic");
  assert.equal(previewTitle.opacity, ".72", "the preview title is dimmed");

  const previewClose = ruleContaining(
    '.workbench-tab[data-preview="true"]:is(:hover, :focus-within) .workbench-tab-close',
    workbench
  );
  assert.equal(previewClose.length, 1, "a preview tab reveals its close control on hover");

  // The rail-end overflow menu: the class AND its id are styled.
  const menu = leafRules(workbench).filter(rule =>
    rule.selectors.includes(".workbench-tab-overflow") &&
    rule.selectors.includes("#workbench-tabs-overflow")
  );
  assert.equal(menu.length, 1, "#workbench-tabs-overflow / .workbench-tab-overflow must be styled");
  assert.equal(values(menu[0].body).position, "relative");

  // Its panel reuses the create menu's surface + elevation family.
  const panel = values(rulesWith(".workbench-tab-overflow > .workbench-create-menu", workbench)[0].body);
  assert.equal(panel["inset-inline-end"], "0", "the panel anchors at the rail's end");
  const createMenu = values(rulesWith(".workbench-create-menu", workbench, {exactSelectorText: true})[0].body);
  assert.equal(createMenu.background, "var(--surface-raised)");
  assert.equal(createMenu["box-shadow"], "var(--elev-2)");
});

// --- docked right panel ----------------------------------------------------

test("the right dock is a shell-layer panel with ONE hairline", () => {
  const [history] = rulesWith(".workbench-history", workbench, {exactSelectorText: true});
  const declared = values(history.body);
  assert.equal(declared.background, "var(--surface-rail)");
  assert.equal(declared["border-inline-start"], "1px solid var(--border-hairline)");
  assert.equal(declared["box-shadow"], undefined, "the dock never floats");
  assert.equal(declared.padding, ".55rem .6rem", "one consistent panel frame stays");
});

// --- content surfaces vs overlays -----------------------------------------

// Content surfaces: they may only lift through a shared elevation token, and in
// practice none of them carries one.
const CONTENT_SELECTORS = [
  '.task-card[data-variant="flat"]',
  ".workbench-history",
  ".task-card-panel",
  "#main-content",
  "#main-scroll"
];

test("no content surface carries a real shadow", () => {
  for (const name of FILES) {
    for (const rule of leafRules(source[name])) {
      if (!rule.selectors.some(selector => CONTENT_SELECTORS.includes(selector))) continue;
      const shadow = values(rule.body)["box-shadow"];
      if (shadow === undefined) continue;
      assert.equal(shadow, "none", `${name}: ${rule.selectorText} must not elevate (${shadow})`);
    }
  }
});

test("overlays consume the shared elevation tokens", () => {
  const expectations = [
    ["app.css", ".project-palette-overlay", "var(--elev-3)"],
    ["app.css", "dialog.modal .modal-box", "var(--elev-3)"],
    ["app.css", ".agents-legend-tip", "var(--elev-2)"],
    ["workbench.css", ".workbench-create-menu", "var(--elev-2)"],
    ["workbench.css", ".workbench-window", "var(--elev-3)"],
    ["assistant.css", ".assistant-menu-panel", "var(--elev-3)"]
  ];

  for (const [name, selector, token] of expectations) {
    const rules = leafRules(source[name]).filter(rule => rule.selectors.includes(selector));
    assert.ok(rules.length, `${name}: ${selector} is missing`);
    const shadows = rules.map(rule => values(rule.body)["box-shadow"]).filter(Boolean);
    assert.ok(shadows.length, `${name}: ${selector} must carry an elevation`);
    for (const shadow of shadows) {
      assert.equal(shadow, token, `${name}: ${selector} must use ${token}`);
    }
  }

  // No component stylesheet may hand-roll an elevation-like drop shadow any
  // more: every remaining shadow literal is a ring/glow (`0 0 …`).
  for (const name of FILES) {
    for (const rule of leafRules(source[name])) {
      const shadow = values(rule.body)["box-shadow"];
      if (!shadow) continue;
      if (shadow === "none" || shadow.includes("var(--elev-")) continue;
      if (shadow.startsWith("var(--")) continue;
      assert.match(shadow, /^0 0 |, 0 0 |inset /,
        `${name}: ${rule.selectorText} carries a drop shadow — use an --elev-* token or a glow ring`);
    }
  }
});

// --- the task-card chrome contract ----------------------------------------

test("the task-card chrome is styled as the surface consumers", () => {
  const card = values(rulesWith(".task-card", surfaces, {exactSelectorText: true})[0].body);
  assert.equal(card.position, "relative");
  assert.equal(card.border, "1px solid var(--border-hairline)");
  assert.equal(card["border-radius"], "0.75rem");

  const flat = values(rulesWith('.task-card[data-variant="flat"]', surfaces)[0].body);
  assert.equal(flat.background, "var(--surface-canvas)");
  assert.equal(flat["border-radius"], "var(--radius-tab)");
  assert.equal(flat["box-shadow"], "none", "a list row never elevates");

  const accent = rulesWith('.task-card[data-variant="flat"] > .task-card-accent', surfaces);
  assert.equal(accent.length, 1, "the flat variant hides the accent bar");
  assert.equal(values(accent[0].body).display, "none");

  const raised = values(rulesWith('.task-card[data-variant="raised"]', surfaces)[0].body);
  assert.equal(raised.background, "var(--surface-raised)");
  assert.equal(raised["box-shadow"], "var(--elev-1)");

  const panel = values(rulesWith(".task-card-panel", surfaces, {exactSelectorText: true})[0].body);
  assert.equal(panel.background, "var(--surface-shell)");
  assert.equal(panel.border, "1px solid var(--border-hairline)");
  assert.equal(panel["border-radius"], "0.5rem");
  assert.equal(panel["box-shadow"], "none", "a nested panel is recessed, not raised");

  assert.ok(rulesWith(".task-card-status", surfaces, {exactSelectorText: true}).length,
    "the status chip has a shape rule");
});

test("hover, selected and focus are three different treatments", () => {
  const hover = values(rulesWith(".task-card:hover", surfaces)[0].body);
  assert.equal(hover.background, "var(--surface-hover)");
  assert.equal(hover["border-color"], "var(--border-strong)");

  const selected = rulesWith(".task-card[data-selected=\"true\"]", surfaces)[0];
  const selectedValues = values(selected.body);
  assert.equal(selectedValues.background, "var(--surface-selected)");
  assert.equal(selectedValues["border-color"], "var(--color-primary-standalone)");

  // `[aria-current]` is honored with the same treatment...
  const aria = rulesWith(".task-card[aria-current]", surfaces);
  assert.equal(aria.length, 1, "the aria-current spelling must be honored");
  assert.equal(values(aria[0].body).background, "var(--surface-selected)");

  // ...and the accent marks the current object with a 2px inline-start bar.
  const bar = rulesWith(".task-card[data-selected=\"true\"]::before", surfaces);
  assert.equal(bar.length, 1, "the selected card carries a 2px accent inline-start bar");
  const barValues = values(bar[0].body);
  assert.equal(barValues["inline-size"], "2px");
  assert.equal(barValues.background, "var(--color-primary-standalone)");

  const focus = values(rulesWith(".task-card:focus-visible", surfaces)[0].body);
  assert.equal(focus.outline, "2px solid var(--color-primary-standalone)");
  assert.equal(focus["outline-offset"], "2px");
  assert.equal(focus.background, undefined, "focus never changes the fill");
});

// --- the center canvas ----------------------------------------------------

test("the center canvas takes the canvas token, once", () => {
  const canvas = leafRules(source["app.css"]).filter(rule =>
    rule.selectors.includes("#main-content") && rule.selectors.includes("#main-scroll")
  );
  assert.equal(canvas.length, 1, "expected ONE #main-content + #main-scroll canvas rule");
  assert.deepEqual(values(canvas[0].body), {background: "var(--surface-canvas)"},
    "the canvas rule stays background-only");
});
