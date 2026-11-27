// The in-shell height contract, as a source-level test.
//
// Contract (detail: assets/css/CONTEXT.md):
//   * the app SHELL — `body` + `#app-layout` (Tailwind `h-dvh`) + `#sidebar`, plus
//     the `@media (max-width: 640px)` `--app-vh` override on `#app-layout` — is
//     the ONLY owner of the viewport height; `main#main-content` is a
//     definite-height flex child of that chain.
//   * an in-shell page that must FILL main uses `.shell-fill`
//     (`height: 100%; min-height: 0`) instead of re-deriving the viewport, so no
//     page content may compute `height`/`min-height` from `vh`/`dvh` and no page
//     markup may use `h-screen`/`min-h-screen`.
//   * `--shell-topbar-h` (on `#app-layout`) is the ONE value a `max-height` cap
//     may use to account for the shell chrome.
//
// Two things are NOT violations, and this file encodes WHY:
//   * `max-height` caps — a cap can only shrink a box, never make it taller than
//     its parent, so it cannot reintroduce page overflow. Only `height` /
//     `min-height` can.
//   * TOP-LAYER / viewport-anchored surfaces — native `<dialog>` (and its
//     `.modal` / `.modal-box` content, the `.workbench-window*` panels and the
//     settings iframe inside one), `position: fixed` popovers/toasts
//     (`.agents-legend-tip`) — are detached from the shell's flow by the browser
//     itself, so measuring their own height against the viewport is legitimate.
//     (`#workbench-settings-frame` is the iframe INSIDE the native
//     `<dialog class="workbench-window">`, hence top-layer too.)
//
// Pure source text, no browser and no npm dependencies: the shipped CSS/markup is
// read with `fs.readFileSync`, exactly like motion.test.cjs and
// workbench_motion.test.cjs. The RENDERED half of the contract is
// test/evo_dash_web/live/layout_height_contract_test.exs.
const test = require("node:test");
const assert = require("node:assert/strict");
const {readFileSync, readdirSync, existsSync} = require("node:fs");
const {join, relative} = require("node:path");

const APP_DIR = join(__dirname, "..", "..");
const CSS_FILES = ["app.css", "workbench.css"].map(name => ({
  name,
  path: join(__dirname, name),
  // Comments are blanked, not deleted, so reported line numbers stay true.
  source: readFileSync(join(__dirname, name), "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, comment => comment.replace(/[^\n]/g, " "))
}));
const css = Object.fromEntries(CSS_FILES.map(file => [file.name, file.source]));

// `100vh` / `90dvh` / `100svh` / `100lvh` — a viewport unit attached to a
// number. Deliberately NOT a bare `vh` match: `var(--app-vh)` and `--shell-topbar-h`
// are sanctioned tokens, only the unit suffix is forbidden.
const VIEWPORT_UNIT = /\b\d+(?:\.\d+)?(?:d|s|l)?vh\b/;

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

function values(body) {
  return Object.fromEntries(declarations(body));
}

// The innermost rules of a source string: `@media` wrappers are skipped
// implicitly because their prelude is followed by a NESTED `{`, so only real
// leaf rules ever match.
function leafRules(file) {
  return [...css[file].matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(match => {
    const selectorText = match[1].trim().replace(/\s+/g, " ");
    const bodyStart = match.index + match[1].length;
    return {
      file,
      line: css[file].slice(0, bodyStart).split("\n").length,
      selectorText,
      selectors: selectorText.split(",").map(selector => selector.trim()),
      body: match[2],
      declarations: declarations(match[2])
    };
  });
}

// A whole block by its header (used for the `@media` preludes).
function blocks(header, source) {
  const found = [];
  for (let start = source.indexOf(header); start !== -1; start = source.indexOf(header, start + 1)) {
    const tail = start + header.length;
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
  return found;
}

// --- the allowlist: the shell roots and the top-layer surfaces -------------
const SHELL_ROOT = [/^body$/, /^#app-layout(?![\w-])/, /^#sidebar$/, /^html$/];
const TOP_LAYER = [
  /^dialog(?![\w-])/, // a native <dialog> is in the top layer
  /^\.modal(?![\w-])/, // ...and so is its DaisyUI content
  /\.modal-box\b/,
  /^\.workbench-window/, // .workbench-window, .workbench-window-page, ::backdrop
  /^#workbench-settings-frame$/, // the iframe INSIDE <dialog class="workbench-window">
  /^\.agents-legend-tip$/ // a position: fixed element appended to <body>
];

function allowlisted(rule) {
  const fixed = rule.declarations.some(([property, value]) => property === "position" && value === "fixed");
  if (fixed) return true;
  return rule.selectors.some(
    selector => SHELL_ROOT.some(pattern => pattern.test(selector)) ||
      TOP_LAYER.some(pattern => pattern.test(selector))
  );
}

test("the shell owns the viewport height: h-dvh on body + #app-layout, --app-vh on mobile", () => {
  const layouts = readFileSync(join(APP_DIR, "lib/evo_dash_web/components/layouts.ex"), "utf8");
  const rootLayout = readFileSync(
    join(APP_DIR, "lib/evo_dash_web/components/layouts/root.html.heex"),
    "utf8"
  );

  // #app-layout: class h-dvh + overflow-hidden, then id="app-layout".
  assert.match(
    layouts,
    /class="[^"]*\bh-dvh\b[^"]*\boverflow-hidden\b[^"]*"\s+id="app-layout"/,
    "components/layouts.ex: #app-layout must carry the h-dvh overflow-hidden shell root classes"
  );

  const body = rootLayout.match(/<body\b[^>]*>/);
  assert.ok(body, "components/layouts/root.html.heex: <body> is missing");
  assert.match(body[0], /class="[^"]*\bh-dvh\b/, "root.html.heex: <body> must carry h-dvh");
  assert.match(body[0], /\boverflow-hidden\b/, "root.html.heex: <body> must carry overflow-hidden");

  // The mobile keyboard override: the shell (not a page) shrinks to --app-vh.
  const mobile = blocks("@media (max-width: 640px)", css["app.css"])
    .flatMap(body => [...body.matchAll(/([^{}]+)\{([^{}]*)\}/g)])
    .map(match => ({selector: match[1].trim(), body: match[2]}))
    .filter(rule => rule.selector === "#app-layout");

  assert.equal(mobile.length, 1, "app.css: expected ONE @media (max-width: 640px) #app-layout override");
  assert.equal(
    values(mobile[0].body).height,
    "var(--app-vh, 100dvh)",
    "app.css: the mobile shell root must shrink to var(--app-vh, 100dvh)"
  );
});

test(".shell-fill is the ONE in-shell fill utility (height 100% + min-height 0)", () => {
  const rules = leafRules("app.css").filter(rule => rule.selectors.includes(".shell-fill"));
  assert.equal(rules.length, 1, "app.css: .shell-fill must be defined exactly once");
  assert.deepEqual(
    values(rules[0].body),
    {height: "100%", "min-height": "0"},
    "app.css: .shell-fill must be `height: 100%; min-height: 0` — a definite height that may shrink"
  );
});

test("--shell-topbar-h is defined once on #app-layout and consumed by .workbench-top", () => {
  const definitions = CSS_FILES.flatMap(file =>
    [...file.source.matchAll(/(^|[\s{;])--shell-topbar-h\s*:\s*([^;]+);/g)].map(match => ({
      file: file.name,
      line: file.source.slice(0, match.index).split("\n").length,
      value: match[2].trim()
    }))
  );

  assert.equal(
    definitions.length,
    1,
    `--shell-topbar-h must be DEFINED exactly once (found ${definitions
      .map(definition => `${definition.file}:${definition.line}`)
      .join(", ")})`
  );
  assert.equal(definitions[0].file, "workbench.css");
  assert.equal(definitions[0].value, "var(--workbench-topbar-size, calc(var(--control-h) + var(--card-pad) / 4))");

  // ...and it must live on the shell root, never on a page.
  const host = leafRules("workbench.css").filter(
    rule =>
      rule.selectors.includes("#app-layout") &&
      rule.declarations.some(([property]) => property === "--shell-topbar-h")
  );
  assert.equal(host.length, 1, "workbench.css: define --shell-topbar-h ON #app-layout");

  const topbar = leafRules("workbench.css").filter(rule => rule.selectors.includes(".workbench-top"));
  assert.ok(topbar.length, "workbench.css: .workbench-top is missing");
  const bones = topbar.filter(rule => "flex" in values(rule.body));
  assert.equal(bones.length, 1, "workbench.css: expected ONE .workbench-top flex-basis rule");
  assert.equal(
    values(bones[0].body).flex,
    "0 0 var(--shell-topbar-h)",
    "workbench.css: .workbench-top must consume var(--shell-topbar-h), not a duplicated literal"
  );
  assert.doesNotMatch(
    bones[0].body,
    /3\.5rem/,
    "workbench.css: .workbench-top must not repeat the 3.5rem literal beside the token"
  );
});

test("--shell-titlebar-h is 0px in a browser and one row under [data-desktop]", () => {
  const definitions = CSS_FILES.flatMap(file =>
    [...file.source.matchAll(/(^|[\s{;])--shell-titlebar-h\s*:\s*([^;]+);/g)].map(match => ({
      file: file.name,
      line: file.source.slice(0, match.index).split("\n").length,
      value: match[2].trim()
    }))
  );

  assert.equal(
    definitions.length,
    2,
    `--shell-titlebar-h must be DEFINED exactly twice — 0px on #app-layout and var(--row-h) ` +
      `under [data-desktop="true"] (found ${definitions
        .map(definition => `${definition.file}:${definition.line} = ${definition.value}`)
        .join(", ")})`
  );

  const browser = leafRules("workbench.css").filter(
    rule =>
      rule.selectors.includes("#app-layout") &&
      rule.declarations.some(([property]) => property === "--shell-titlebar-h")
  );
  assert.equal(browser.length, 1, "workbench.css: define --shell-titlebar-h ON #app-layout");
  assert.equal(
    values(browser[0].body)["--shell-titlebar-h"],
    "0px",
    "workbench.css: a browser render must keep the strip token at 0px, so no offset moves"
  );

  const desktop = leafRules("workbench.css").filter(
    rule =>
      rule.selectors.includes('#app-layout[data-desktop="true"]') &&
      rule.declarations.some(([property]) => property === "--shell-titlebar-h")
  );
  assert.equal(
    desktop.length,
    1,
    'workbench.css: a desktop window sets --shell-titlebar-h on #app-layout[data-desktop="true"]'
  );
  assert.equal(
    values(desktop[0].body)["--shell-titlebar-h"],
    "var(--row-h)",
    "workbench.css: the desktop strip takes one density row, not a literal height"
  );

  // ...and the strip consumes that ONE token for both its basis and its height.
  const strip = leafRules("workbench.css").filter(rule => rule.selectors.includes("#desktop-titlebar"));
  assert.equal(strip.length, 1, "workbench.css: #desktop-titlebar must have ONE base rule");
  const bones = values(strip[0].body);
  assert.equal(bones.flex, "0 0 var(--shell-titlebar-h)", "workbench.css: the strip is an in-flow fixed-basis row");
  assert.equal(bones.height, "var(--shell-titlebar-h)", "workbench.css: the strip height IS the token");
  assert.doesNotMatch(
    strip[0].body,
    /2\.5rem/,
    "workbench.css: the strip must not repeat the row-height literal beside the token"
  );
});

test("no page content computes height/min-height from the viewport", () => {
  const offences = [];

  for (const file of CSS_FILES) {
    for (const rule of leafRules(file.name)) {
      if (allowlisted(rule)) continue;
      for (const [property, value] of rule.declarations) {
        if (property !== "height" && property !== "min-height") continue; // a max-height cap cannot overflow
        if (!VIEWPORT_UNIT.test(value)) continue;
        offences.push(
          `${file.name}:${rule.line}  ${rule.selectorText} { ${property}: ${value} }`
        );
      }
    }
  }

  assert.deepEqual(
    offences,
    [],
    "in-shell page content must not derive its height from the viewport — use .shell-fill " +
      "(height: 100%; min-height: 0) and let #app-layout own the viewport:\n  " +
      offences.join("\n  ")
  );
});

test("the desktop title bar is layer-0 chrome and the fixed surfaces clear it", () => {
  const [strip] = leafRules("workbench.css").filter(rule => rule.selectors.includes("#desktop-titlebar"));
  const declared = values(strip.body);

  assert.equal(
    declared.background,
    "var(--surface-shell)",
    "workbench.css: the strip shares the ONE shell chrome tone"
  );
  assert.equal(
    declared["border-bottom"],
    "1px solid var(--border-hairline)",
    "workbench.css: the strip separates from the canvas with the ONE hairline"
  );
  assert.equal(declared["box-shadow"], undefined, "an in-flow strip never elevates (layer 0)");
  assert.equal(declared["z-index"], undefined, "an in-flow strip needs no stacking order");
  assert.equal(declared.position, undefined, "the strip stays in flow — never fixed or absolute");
  // The window-control inset is a token so the two OS branches can retarget it.
  assert.equal(
    declared["--titlebar-lead"],
    "var(--page-gutter)",
    "workbench.css: windows/linux lead with the frame gutter"
  );
  assert.equal(declared["padding-inline-start"], "var(--titlebar-lead)");

  // Every chrome-anchored fixed surface clears the strip with an EXPLICIT 0px
  // fallback: `#flash-group` also renders in the `workbench_window` clause,
  // outside #app-layout, where the token is undefined.
  const expectations = [
    ["#sidebar-mobile-toggle-wrap", "calc(var(--shell-titlebar-h, 0px) + .375rem)"],
    ["#flash-group", "calc(var(--shell-titlebar-h, 0px) + 1rem)"],
    ["#guide-panel", "calc(var(--shell-titlebar-h, 0px) + 1rem)"]
  ];
  for (const [selector, top] of expectations) {
    const rules = leafRules("workbench.css").filter(rule => rule.selectors.includes(selector));
    assert.equal(rules.length, 1, `workbench.css: expected ONE ${selector} strip offset rule`);
    assert.equal(
      values(rules[0].body).top,
      top,
      `workbench.css: ${selector} must offset with the always-present 0px fallback`
    );
  }
});

test("the macOS inset and the window controls keep their chrome contract", () => {
  const mac = leafRules("workbench.css").filter(
    rule => rule.selectors.includes('#desktop-titlebar[data-os="macos"]')
  );
  assert.equal(mac.length, 1, "workbench.css: the macOS strip inset rule must exist");
  assert.equal(
    values(mac[0].body)["--titlebar-lead"],
    "5.25rem",
    "workbench.css: macOS reserves the lead for the overlaid native traffic lights"
  );

  const controls = leafRules("workbench.css").filter(
    rule => rule.selectors.includes(".desktop-titlebar-controls")
  );
  assert.equal(controls.length, 1, "workbench.css: .desktop-titlebar-controls needs ONE base rule");
  assert.equal(values(controls[0].body).display, "flex");
  assert.equal(values(controls[0].body).flex, "0 0 auto");

  const control = leafRules("workbench.css").filter(
    rule => rule.selectors.includes(".desktop-titlebar-control") && "width" in values(rule.body)
  );
  assert.equal(control.length, 1, "workbench.css: .desktop-titlebar-control needs ONE base rule");
  const shape = values(control[0].body);
  assert.equal(shape.display, "grid");
  assert.equal(shape.width, "2.875rem", "workbench.css: a window control keeps a native hit width");
  assert.equal(shape.height, "100%", "workbench.css: a control fills the strip");
  assert.equal(shape.cursor, "default");
  assert.equal(shape.background, "transparent");
  assert.equal(
    shape.transition,
    "background-color .12s ease, color .12s ease",
    "workbench.css: only the control's fill and ink animate"
  );

  const close = leafRules("workbench.css").filter(
    rule => rule.selectors.includes(".desktop-titlebar-control-close:hover")
  );
  assert.equal(close.length, 1, "workbench.css: the close button needs its Windows-style hover");
  assert.equal(values(close[0].body).background, "var(--color-error)");
  assert.equal(values(close[0].body).color, "var(--color-error-content)");

  const reduced = blocks("@media (prefers-reduced-motion: reduce)", css["workbench.css"]);
  assert.ok(
    reduced.some(body => /\.desktop-titlebar-control\s*\{[^}]*transition:\s*none/.test(body)),
    "workbench.css: reduced motion must drop the control transition"
  );
});

// A tag by one of its attributes (attributes may span lines).
function tagAround(source, marker) {
  const at = source.indexOf(marker);
  if (at === -1) return null;
  const start = source.lastIndexOf("<", at);
  const end = source.indexOf(">", at);
  return start === -1 || end === -1 ? null : source.slice(start, end + 1);
}

function classTokens(tag) {
  const match = tag && tag.match(/class="([^"]*)"/);
  return match ? match[1].split(/\s+/).filter(Boolean) : [];
}

// The markup half of the desktop chain lands with the title-bar component in a
// parallel change; while it is absent this reports SKIP rather than a failure.
test("#app-layout is a column of the desktop title bar over one shell row", t => {
  const layouts = readFileSync(join(APP_DIR, "lib/evo_dash_web/components/layouts.ex"), "utf8");
  const titlebar = join(APP_DIR, "lib/evo_dash_web/components/desktop_titlebar.ex");
  const shellRow = tagAround(layouts, 'id="shell-row"');

  if (!existsSync(titlebar) || !shellRow) {
    t.skip(
      "the desktop title-bar markup (components/desktop_titlebar.ex + #shell-row in layouts.ex) " +
        "is not in this checkout yet"
    );
    return;
  }

  const shell = tagAround(layouts, 'id="app-layout"');
  assert.ok(shell, "components/layouts.ex: #app-layout is missing");
  const shellClasses = classTokens(shell);
  assert.ok(
    shellClasses.includes("flex") && shellClasses.includes("flex-col"),
    `components/layouts.ex: #app-layout must stack the strip over the shell row (found "${shellClasses.join(" ")}")`
  );
  assert.ok(shell.includes("data-desktop"), "components/layouts.ex: #app-layout must carry data-desktop");
  assert.ok(
    shell.includes("@desktop?"),
    "components/layouts.ex: data-desktop is set only in a Tauri shell, from the desktop assign"
  );

  const rowClasses = classTokens(shellRow);
  for (const token of ["flex", "flex-1", "min-h-0", "min-w-0"]) {
    assert.ok(
      rowClasses.includes(token),
      `components/layouts.ex: #shell-row must carry ${token} (found "${rowClasses.join(" ")}")`
    );
  }

  const stripAt = layouts.indexOf("DesktopTitlebar.titlebar");
  assert.ok(stripAt !== -1, "components/layouts.ex: DesktopTitlebar.titlebar is not rendered");
  assert.match(
    layouts.slice(Math.max(0, stripAt - 40), stripAt + 400),
    /@desktop\?/,
    "components/layouts.ex: the strip is desktop-gated — a browser render must not include it"
  );
});

test("the agents fill chain keeps ONE xl height and ONE both-axis scroller", () => {
  const rules = leafRules("app.css");

  const pageRules = rules.filter(rule => rule.selectors.includes(".agents-page-layout"));
  assert.ok(pageRules.length, "app.css: .agents-page-layout is missing");
  for (const rule of pageRules) {
    assert.doesNotMatch(
      rule.body,
      /calc\(\s*\d+(?:\.\d+)?(?:d|s|l)?vh/,
      `app.css:${rule.line}: .agents-page-layout must not derive its height from the viewport`
    );
  }

  // The xl rule is the ONE that wires the page into main's height.
  const xl = blocks("@media (min-width: 1280px)", css["app.css"])
    .flatMap(body => [...body.matchAll(/([^{}]+)\{([^{}]*)\}/g)])
    .filter(match => match[1].trim() === ".agents-page-layout");
  assert.equal(xl.length, 1, "app.css: expected ONE xl .agents-page-layout rule");
  assert.equal(
    values(xl[0][2]).height,
    "100%",
    "app.css: the xl .agents-page-layout must take height: 100% of main#main-content"
  );
  assert.equal(values(xl[0][2]).overflow, "hidden", "app.css: the xl page must not scroll itself");

  // .cg-scroll stays the ONE both-axis scroller.
  const scroller = rules.filter(rule => rule.selectors.includes(".cg-scroll"));
  assert.ok(scroller.length, "app.css: .cg-scroll is missing");
  const base = scroller.filter(rule => "overflow" in values(rule.body));
  assert.ok(base.length, "app.css: .cg-scroll must declare `overflow: auto`");
  for (const rule of base) {
    assert.equal(
      values(rule.body).overflow,
      "auto",
      `app.css:${rule.line}: .cg-scroll must stay a both-axis scroller (overflow: auto)`
    );
  }
  for (const rule of scroller) {
    const declared = values(rule.body);
    assert.ok(
      !("overflow-x" in declared) || "overflow" in declared,
      `app.css:${rule.line}: never split .cg-scroll into an overflow-x-only scroller`
    );
  }

  // Commits mode hands it the panel height with NO cap.
  const commits = rules.find(rule =>
    rule.selectorText.includes(".agents-tree-body-commits .cg-scroll")
  );
  assert.ok(commits, "app.css: the commits-mode .cg-scroll fill rule is missing");
  assert.deepEqual(
    values(commits.body),
    {"flex": "1 1 auto", "min-height": "0", "max-height": "none", "overflow": "auto"},
    `app.css:${commits.line}: commits mode must drop the max-height cap and fill the panel`
  );
});

// --- the rendered page markup ---------------------------------------------

// Elixir `#` comments and HEEX `<%!-- --%>` comments are prose, not markup:
// blank them (newlines preserved) so a comment that QUOTES an old rule cannot
// fail the scan.
function stripComments(source) {
  const withoutHeex = source
    .replace(/<%!--[\s\S]*?--%>/g, comment => comment.replace(/[^\n]/g, " "))
    .replace(/<!--[\s\S]*?-->/g, comment => comment.replace(/[^\n]/g, " "));
  let out = "";
  let inString = false;
  for (let index = 0; index < withoutHeex.length; index++) {
    const char = withoutHeex[index];
    if (inString) {
      out += char;
      if (char === "\\") {
        out += withoutHeex[++index] ?? "";
      } else if (char === '"') {
        inString = false;
      }
      continue;
    }
    if (char === '"') {
      inString = true;
      out += char;
      continue;
    }
    if (char === "#") {
      while (index < withoutHeex.length && withoutHeex[index] !== "\n") index++;
      out += "\n";
      continue;
    }
    out += char;
  }
  return out;
}

function markupFiles(root) {
  const excluded = [/\/live\/home_live\//, /\/components\/settings_components\//];
  return readdirSync(root, {recursive: true})
    .map(entry => String(entry).replace(/\\/g, "/"))
    .filter(entry => /\.(ex|heex)$/.test(entry))
    .filter(entry => !excluded.some(pattern => pattern.test(`/${entry}`)))
    .map(entry => ({name: entry, source: stripComments(readFileSync(join(root, entry), "utf8"))}));
}

test("no in-shell page markup uses viewport-sized page content", () => {
  const root = join(APP_DIR, "lib/evo_dash_web");
  const offences = [];

  for (const file of markupFiles(root)) {
    file.source.split("\n").forEach((line, index) => {
      const at = `${file.name}:${index + 1}`;
      // h-screen / min-h-screen on page content. A top-layer or fixed surface
      // is detached from the shell's flow, so it is not page content.
      const overlayLine = /<dialog\b|\bdialog\b|\bmodal\b|\bfixed\b/.test(line);
      if (/\bmin-h-screen\b/.test(line)) {
        offences.push(`${at}  min-h-screen  ${line.trim()}`);
      }
      // `(?<![\w-])` keeps `min-h-screen` from also reporting as `h-screen`.
      if (/(?<![\w-])h-screen\b/.test(line) && !overlayLine) {
        offences.push(`${at}  h-screen  ${line.trim()}`);
      }
      // An inline viewport-derived height is the same violation, spelled by hand.
      if (/style="[^"]*\bmin-height\s*:\s*calc\(\s*\d+(?:\.\d+)?(?:d|s|l)?vh/.test(line)) {
        offences.push(`${at}  inline min-height: calc(<viewport unit> …)  ${line.trim()}`);
      }
    });
  }

  assert.deepEqual(
    offences,
    [],
    "in-shell pages must fill main#main-content instead of sizing against the viewport:\n  " +
      offences.join("\n  ")
  );
});

test("the agents page root and the LiveDashboard iframe carry shell-fill", () => {
  const agents = readFileSync(join(APP_DIR, "lib/evo_dash_web/live/agents_live.html.heex"), "utf8");
  const pageRoot = [...agents.matchAll(/class="([^"]*\bagents-page-layout\b[^"]*)"/g)]
    .map(match => match[1].split(/\s+/))
    .find(classes => classes.includes("agents-page-layout"));

  assert.ok(pageRoot, "agents_live.html.heex: the .agents-page-layout root is missing");
  assert.ok(
    pageRoot.includes("shell-fill"),
    `agents_live.html.heex: the agents page root must carry shell-fill (found "${pageRoot.join(" ")}")`
  );

  const projects = readFileSync(join(APP_DIR, "lib/evo_dash_web/live/projects_live.ex"), "utf8");
  const iframe = projects.match(/<iframe\b[\s\S]*?>/);
  assert.ok(iframe, "projects_live.ex: the LiveDashboard iframe is missing");
  assert.match(
    iframe[0],
    /class="[^"]*\bshell-fill\b/,
    "projects_live.ex: the LiveDashboard iframe must carry shell-fill"
  );
  assert.doesNotMatch(
    iframe[0],
    /calc\(\s*\d+(?:\.\d+)?(?:d|s|l)?vh/,
    "projects_live.ex: the LiveDashboard iframe must not size itself from the viewport"
  );
});
