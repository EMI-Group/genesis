// The surface + elevation contract, as a source-level test.
//
// Contract (detail: assets/css/CONTEXT.md, "Surfaces & elevation"):
//   * `surfaces.css` is the ONE owner of the layering vocabulary and it is
//     imported right after `density.css`, before every component sheet.
//   * three layers — chrome (`--surface-shell` / `--surface-rail`), the content
//     canvas (`--surface-canvas`) and the overlays (`--surface-raised` plus
//     `--elev-1/2/3`). Overlays are the ONLY shadowed surfaces.
//   * the rail is ONE restrained step BENEATH the content canvas in both
//     themes, so the sidebar and the canvas read as one continuous surface;
//     only the shell (top bar) wears the chrome step.
//   * every token is declared exactly once, on `:root` (plus a
//     `[data-theme="dark"]` counterpart whose values differ) and never in
//     another stylesheet.
//   * `surfaces.css` declares no size, padding or gap: `density.css` stays the
//     only owner of the scale.
//   * the compact rail joins the committed tab to the canvas without letting
//     pending feedback change the committed destination's silhouette.
//   * the published behaviour hooks (preview, optional kind icons, and the
//     rail-end overflow menu) have CSS treatments without requiring new markup.
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
  "--surface-text-muted",
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
      /var\(--color-(?:base-[\w-]+|primary(?:-standalone)?|secondary)\)/,
      `${token} must resolve from an existing palette role, got: ${declared}`
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
    "./motion.css"
  ]);
});

// --- the native tab strip --------------------------------------------------

const workbench = source["workbench.css"];
const canvasFill = "var(--workbench-canvas, var(--surface-canvas))";

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

test("current and pending tabs have distinct treatments within a stable silhouette", () => {
  const [tab] = rulesWith(".workbench-tab", workbench, {exactSelectorText: true});
  const resting = values(tab.body);
  assert.equal(resting["border-radius"], "var(--radius-tab) var(--radius-tab) 0 0");
  assert.equal(resting.border, "1px solid transparent", "reserve the border even before selection");
  assert.equal(resting["font-size"], "var(--text-xs)");

  const [current] = rulesWith(".workbench-tab.is-current", workbench);
  const [pending] = rulesWith('.workbench-tab[data-tab-pending="true"]:not(.is-current)', workbench);
  const committed = values(current.body);
  assert.equal(committed.background, canvasFill);
  assert.equal(committed["border-color"], "var(--border-hairline)");
  assert.equal(committed["border-block-end-color"], "transparent");
  assert.equal(committed["z-index"], "1", "the tab paints over the canvas's top hairline");
  assert.deepEqual(values(pending.body), {
    background: "var(--workbench-selected)",
    "border-color": "var(--color-primary-standalone)",
    color: "var(--color-base-content)"
  });
  for (const state of [current, pending]) {
    assert.doesNotMatch(state.body, /(?:size|width|padding|margin|font-weight)\s*:/,
      "confirmation or pending must not resize or move the tab");
  }

  const [dot] = rulesWith('.workbench-tab[data-tab-pending="true"] .workbench-tab-link::after', workbench);
  const indicator = values(dot.body);
  assert.equal(indicator.content, '""', "pending adds a static decorative marker");
  assert.equal(indicator.position, "absolute", "the marker must not shift the title");
  assert.ok(parseFloat(indicator["inline-size"]) > 0, "an empty pseudo-element needs a visible size");
  assert.equal(indicator["inline-size"], indicator["block-size"]);
  assert.equal(indicator["border-radius"], "50%");
  assert.equal(indicator.background, "var(--color-primary-standalone)");
  assert.doesNotMatch(dot.body, /\banimation(?:-[\w-]+)?\s*:/);
});

test("the compact bottom-aligned rail contains horizontal overflow", () => {
  const [strip] = rulesWith(".workbench-tabs", workbench, {exactSelectorText: true});
  const declared = values(strip.body);
  assert.equal(declared["overflow-x"], "auto");
  assert.equal(declared["overflow-y"], "hidden");
  assert.equal(declared["overscroll-behavior-inline"], "contain");
  assert.equal(declared["scrollbar-width"], "none", "a native scrollbar gutter must not break the canvas join");
  assert.equal(declared["align-items"], "end");
  assert.equal(declared["align-self"], "stretch");
  assert.equal(declared.flex, "0 1 auto", "the strip shrinks to make room for its sibling controls");
  assert.equal(declared["min-width"], "0");
  assert.doesNotMatch(strip.body, /scroll-behavior:\s*smooth|margin-block-end:\s*-/);

  const [tab] = rulesWith(".workbench-tab", workbench, {exactSelectorText: true});
  assert.equal(values(tab.body).flex, "0 0 auto", "scroll rather than squeeze a tab");
  assert.equal(values(tab.body)["block-size"], "calc(var(--control-h-sm) + 2px)");
  assert.equal(values(tab.body)["max-inline-size"], "min(10rem, 55vw, 100%)", "a long tab can fit within its rail");
  const [separator] = rulesWith('.workbench-tab[data-tab-group-start="true"]:not(.is-current)::before', workbench);
  assert.equal(values(separator.body)["pointer-events"], "none");
  assert.equal(values(separator.body)["border-inline-start"], "1px solid var(--border-hairline)");

  const [rail] = rulesWith(".workbench-tab-rail", workbench);
  assert.equal(values(rail.body)["min-width"], "0", "the rail must shrink with the shell");
  const [empty] = rulesWith(".workbench-tabs:empty", workbench);
  assert.equal(values(empty.body).display, "none", "an empty strip adds no space beside Create");
});

test("only committed tabs flare out to the same canvas, within the scrolling rail", () => {
  const before = ".workbench-tab.is-current::before";
  const after = ".workbench-tab.is-current::after";
  const corners = leafRules(workbench).find(rule => rule.selectors.includes(before) && rule.selectors.includes(after));
  const paint = values(corners.body);
  assert.deepEqual(corners.selectors, [before, after], "pending-only tabs never get a join");
  assert.equal(paint.position, "absolute", "confirmation never changes the tab footprint");
  assert.equal(paint["inset-block-end"], "-1px", "meet the same frame hairline as the tab");
  assert.equal(paint["pointer-events"], "none");
  assert.equal(paint["inline-size"], "var(--workbench-tab-flare)");
  assert.equal(paint["block-size"], paint["inline-size"]);
  assert.match(paint.background, /^radial-gradient\(/);
  assert.ok(paint.background.includes(canvasFill), "New Task and fallback canvas colors reach the flares too");
  assert.equal(merge(rulesWith(before, workbench))["inset-inline-end"], "100%");
  assert.equal(merge(rulesWith(after, workbench))["inset-inline-start"], "100%");
  assert.equal(merge(rulesWith(".workbench-tab.is-current:dir(rtl)::before", workbench))["--workbench-corner-edge"], "right");
  assert.equal(merge(rulesWith(".workbench-tab.is-current:dir(rtl)::after", workbench))["--workbench-corner-edge"], "left");

  const strip = merge(rulesWith(".workbench-tabs", workbench));
  assert.equal(strip.gap, paint["inline-size"], "the adjacent pending tab's edge stays clear");
  assert.equal(strip["padding-inline"], "calc(var(--workbench-tab-flare) + var(--workbench-tab-start-inset, var(--radius-box))) var(--workbench-tab-flare)");
  assert.equal(merge(rulesWith(".workbench-tab", workbench))["scroll-margin-inline"], paint["inline-size"]);
  const [wide, narrow] = rulesWith(".workbench-tab-rail", workbench);
  assert.equal(values(wide.body)["--workbench-tab-flare"], "var(--radius-tab)");
  assert.equal(values(narrow.body)["--workbench-tab-flare"], "calc(var(--radius-tab) / 2)",
    "reduce decoration, not touch targets, on narrow rails");
});

test("the compact context label yields room to tabs and fixed toolbar controls", () => {
  const [desktop, narrow] = rulesWith(".workbench-context-title", workbench);
  const title = values(desktop.body);
  assert.equal(title.flex, "0 1 auto");
  assert.equal(title["min-inline-size"], "0");
  assert.equal(title["max-inline-size"], "min(12rem, 30%)");
  assert.deepEqual(values(narrow.body), {"max-inline-size": "16%"});
  assert.equal(title.overflow, "hidden");
  assert.equal(title["white-space"], "nowrap");
  assert.equal(title["text-overflow"], "ellipsis");
  assert.equal(title["font-size"], "var(--text-sm)");
});

test("the inset canvas retains its frame and meets the committed tab at the hairline", () => {
  const [bar] = rulesWith(".workbench-top", workbench, {exactSelectorText: true});
  const top = values(bar.body);
  assert.doesNotMatch(bar.body, /\bborder-(?:bottom|block-end)\s*:/);
  assert.equal(top["padding-inline"], "calc(var(--page-gutter) / 2)");

  const [canvas] = rulesWith(".workbench-top + .workbench-content-stack", workbench);
  const frame = values(canvas.body);
  assert.equal(frame["margin-inline"], top["padding-inline"], "align the canvas with the top bar gutter");
  assert.equal(frame.border, "1px solid var(--border-hairline)");
  assert.equal(frame["margin-block-start"], "-1px", "overlap only the single top hairline");
  assert.equal(frame.background, canvasFill);
  assert.equal(frame["box-shadow"], undefined);
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

  // Inset focus rings remain visible at either clipped edge of the scroller.
  const [focus] = rulesWith(".workbench-top :focus-visible", workbench);
  assert.equal(values(focus.body).outline, "2px solid var(--color-primary-standalone)");
  assert.equal(values(focus.body)["outline-offset"], "-2px");

  const coarse = workbench.split("@media (pointer: coarse)")[1];
  const [tabFloor] = rulesWith(".workbench-tabs > .workbench-tab", coarse);
  assert.equal(values(tabFloor.body)["block-size"], "calc(var(--touch-target) + 2px)");
  assert.equal(values(tabFloor.body)["min-inline-size"], "calc(var(--touch-target) * 2 + 2px)");
  const [touchLink] = rulesWith(".workbench-tab .workbench-tab-link", coarse);
  assert.equal(values(touchLink.body)["min-inline-size"], "var(--touch-target)");
  const [touchClose] = rulesWith(".workbench-tab .workbench-tab-close", coarse);
  const touch = values(touchClose.body);
  assert.equal(touch["inline-size"], "var(--touch-target)");
  assert.equal(touch["block-size"], "var(--touch-target)");
  assert.equal(touch.visibility, "visible", "touch has no hover for revealing close");
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

  // The kind seam is optional in the DOM; only the icon gets a kind accent.
  for (const [kind, tone] of [
    ["draft", "var(--color-primary-standalone)"],
    ["assistant", "var(--color-primary-standalone)"],
    ["diff", "var(--color-info)"]
  ]) {
    const [icon] = rulesWith(`.workbench-tab[data-kind="${kind}"] .workbench-tab-icon`, workbench);
    assert.deepEqual(values(icon.body), {color: tone}, `${kind} changes only the icon color`);
  }

  // The rail-end overflow menu: the class AND its id are styled.
  const menu = leafRules(workbench).filter(rule =>
    rule.selectors.includes(".workbench-tab-overflow") &&
    rule.selectors.includes("#workbench-tabs-overflow")
  );
  assert.equal(menu.length, 1, "#workbench-tabs-overflow / .workbench-tab-overflow must be styled");
  assert.equal(values(menu[0].body).position, "relative");
  assert.equal(values(menu[0].body).flex, "none", "the overflow control never shrinks into the strip");
  const [create] = rulesWith(".workbench-create", workbench);
  assert.equal(values(create.body).flex, "none", "the Create control never shrinks into the strip");

  // Its panel reuses the create menu's surface + elevation family.
  const panel = values(rulesWith(".workbench-tab-overflow > .workbench-create-menu", workbench)[0].body);
  assert.equal(panel["inset-inline-end"], "0", "the panel anchors at the rail's end");
  const createMenu = values(rulesWith(".workbench-create-menu", workbench, {exactSelectorText: true})[0].body);
  assert.equal(createMenu.background, "var(--surface-raised)");
  assert.equal(createMenu["box-shadow"], "var(--elev-2)");
});

// --- docked right panel ----------------------------------------------------

test("Source Control shares Project History's fill and keeps only the hairline", () => {
  const declared = merge(rulesWith(".workbench-history", workbench, {exactSelectorText: true}));
  const history = merge(rulesWith("#workbench-history", workbench));
  const sidebar = merge(rulesWith("#app-layout #sidebar", workbench));
  const git = merge(rulesWith(".workbench-history:where(#workbench-git)", workbench));
  const gitFill = merge(rulesWith(".workbench-git", workbench));
  assert.equal(history.background, "var(--surface-rail)");
  assert.equal(history.background, sidebar.background,
    "the docked panels share the left sidebar's fill in either theme");
  assert.equal(git.background, undefined, "no separate dock wash for Source Control");
  assert.equal(gitFill.background, "var(--surface-rail)",
    "Source Control takes the same rail fill as Project History");
  assert.equal(git["border-inline-start"], "1px solid var(--border-hairline)",
    "only Source Control keeps the one separating hairline");
  assert.equal(declared["border-inline-start"], undefined, "the base panel frame declares no divider");
  assert.equal(history["border-inline-start"], undefined, "Project History keeps no divider");
  assert.match(declared["--workbench-selected"], /var\(--color-primary\) 10%/, "accents tint local choices, not the whole dock");
  for (const surface of [declared, history, git]) {
    assert.equal(surface["box-shadow"], undefined, "neither dock floats");
  }
  assert.equal(declared.padding, "calc(var(--card-pad) / 2)", "the panel frame uses the shared density scale");
});

test("the rail sits one step beneath the canvas in both themes", () => {
  const light = values(rulesWith(":root")[0].body);
  const dark = values(rulesWith('[data-theme="dark"]')[0].body);

  // Light: the canvas IS base-100 and the rail is a chrome step just under it.
  assert.equal(light["--surface-canvas"], "var(--color-base-100)");
  assert.match(light["--surface-rail"], /var\(--color-base-200\) 86%/,
    "the light rail derives from the neutral chrome step");
  assert.match(light["--surface-rail"], /var\(--color-base-300\)/);
  assert.doesNotMatch(light["--surface-rail"], /var\(--color-base-100\)/,
    "the light rail is a chrome step, not the canvas itself");

  // Dark: base-200 is LIGHTER than base-100, so the rail anchors on base-100.
  assert.match(dark["--surface-canvas"], /var\(--color-base-100\) 94%/);
  assert.equal(dark["--surface-rail"], "var(--color-base-100)",
    "the dark rail anchors on base-100 so it never lifts above the canvas");
  assert.doesNotMatch(dark["--surface-rail"], /var\(--color-base-20[02]\)|var\(--color-base-300\)/,
    "anchoring the dark rail on base-200/base-300 lifted the sidebar above the canvas");
});

test("the composer and History placeholders use the opaque muted foreground", () => {
  for (const [file, selector] of [
    ["app.css", ".input-prompt::placeholder"],
    ["assistant.css", ".assistant-textarea::placeholder"],
    ["workbench.css", "#workbench-history-search::placeholder"]
  ]) {
    const rules = rulesWith(selector, source[file]);
    assert.deepEqual(merge(rules), {color: "var(--surface-text-muted)", opacity: "1"}, selector);
  }
  // These neutral mixes were checked in Chrome against the composer and History fills.
  for (const [theme, weight] of [[":root", 79], ['[data-theme="dark"]', 65]]) {
    const palette = values(rulesWith(theme)[0].body);
    assert.equal(palette["--surface-text-muted"],
      `color-mix(in srgb, var(--color-base-content) ${weight}%, var(--color-base-100))`,
      "the shared text tone must be opaque and independent of the accent");
  }
});

test("History uses the muted foreground only for the unselected kind", () => {
  const choice = ".workbench-history-switch [data-workbench-kind]";
  assert.equal(merge(rulesWith(choice, workbench)).color, "var(--surface-text-muted)");
  assert.equal(merge(rulesWith(`${choice}[aria-pressed="true"]`, workbench)).color,
    "var(--color-base-content)");
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
  assert.equal(panel.background, "var(--surface-rail)",
    "a nested panel is recessed in both themes: the rail tone lifts in neither");
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

test("the page and scroller consume the same fill as the tab and frame, with no competing paint", () => {
  const canvas = FILES.flatMap(name => leafRules(source[name])).filter(rule =>
    /#main-(?:content|scroll)\b/.test(rule.selectorText) && /\bbackground(?:-color)?\s*:/.test(rule.body)
  );
  assert.equal(canvas.length, 1, "expected ONE #main-content + #main-scroll canvas rule");
  assert.deepEqual(canvas[0].selectors, ["#main-content", "#main-scroll"]);
  assert.deepEqual(values(canvas[0].body), {background: canvasFill},
    "the canvas rule stays background-only");
});

test("only the uncovered New Task page changes the inherited canvas, separately from composer fill", () => {
  const overrides = FILES.flatMap(name => leafRules(source[name])).filter(rule =>
    "--workbench-canvas" in values(rule.body)
  );
  const draft = ".workbench-center:has(> .workbench-content-stack > #main-scroll #workbench-task-composer):not(:has(#workbench-git-diff))";
  const dark = '[data-theme="dark"] ';
  assert.deepEqual(overrides.map(rule => rule.selectorText), [draft, dark + draft]);

  const task = '.workbench-composer[data-composer-kind="task"]';
  for (const [index, [prefix, tone]] of [
    ["", "color-mix(in oklab, var(--surface-canvas) 45%, var(--surface-shell))"],
    [dark, "var(--color-base-100)"]
  ].entries()) {
    assert.deepEqual(values(overrides[index].body), {"--workbench-canvas": tone});
    const [composer] = rulesWith(prefix + task, source["assistant.css"]);
    const fill = values(composer.body)["--composer-surface"];
    assert.ok(fill);
    assert.notEqual(fill, tone, "the resting composer is distinct from the surrounding canvas");
    assert.doesNotMatch(fill, /--workbench-canvas/, "the editor never inherits the page's draft fill");
  }
});
