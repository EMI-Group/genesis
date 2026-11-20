// Run with: node --test apps/evo_dash/assets/js/hooks/sidebar_collapse.test.cjs
//
// Exercises the PURE collapse-sync probe behind SidebarCollapse.updated() —
// "does the O(sidebar subtree) collapse sweep have to run again after this
// LiveView patch?" — without a browser bundle. The sweep itself (the four
// querySelectorAll walks + per-element class writes) and the mobile state
// writes have no decision of their own; they only execute the plan this probe
// returns.
//
// Matching the workbench_panel.test.cjs convention: the block between the
// source's markers is sliced out and run through node:vm, so the real shipped
// code is what is measured. The DOM seam below is a tiny stand-in for
// querySelector over a class/attribute-only selector vocabulary — and it
// THROWS on a selector it does not understand, so a probe change can never
// silently stop being measured.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const src = readFileSync(`${__dirname}/sidebar_collapse.js`, 'utf8');
const start = src.indexOf('// --- SidebarCollapse: pure collapse-sync probe');
// The file's FIRST line also starts with "// SidebarCollapse hook:", so search
// for the end marker AFTER the block's own start.
const end = src.indexOf('// SidebarCollapse hook:', start);
assert.ok(start !== -1 && end > start, 'pure collapse-sync probe block not found in sidebar_collapse.js');
const source = src.slice(start, end);
const {collapseSyncNeeded} = vm.runInContext(`${source}\n({collapseSyncNeeded});`, vm.createContext({}));

// --- minimal DOM seam -------------------------------------------------------
// Supports exactly the selector vocabulary the probes use: `.class`,
// `[data-attr]` presence and `:not(.class)`.
const TOKEN = /^(:not\(\.([\w-]+)\)|\.([\w-]+)|\[([\w-]+)\])/;

function makeNode(classes = [], attrs = {}, children = []) {
  const classSet = new Set(classes);
  const el = {
    classes: classSet,
    attrs: Object.assign({}, attrs),
    children,
    dataset: {},
    classList: {
      contains: (c) => classSet.has(c),
      add: (...cs) => cs.forEach((c) => classSet.add(c)),
      remove: (...cs) => cs.forEach((c) => classSet.delete(c)),
    },
    querySelector(selector) {
      return findFirst(el, selector);
    },
  };
  return el;
}

function matches(el, selector) {
  let rest = selector.trim();
  const checks = [];
  while (rest.length > 0) {
    const m = TOKEN.exec(rest);
    if (!m) throw new Error(`unsupported selector: ${selector}`);
    if (m[2]) checks.push(['not', m[2]]);
    else if (m[3]) checks.push(['class', m[3]]);
    else checks.push(['attr', m[4]]);
    rest = rest.slice(m[0].length);
  }
  return checks.every(([kind, name]) => {
    if (kind === 'class') return el.classes.has(name);
    if (kind === 'attr') return Object.prototype.hasOwnProperty.call(el.attrs, name);
    return !el.classes.has(name);
  });
}

function findFirst(root, selector) {
  for (const child of root.children) {
    if (matches(child, selector)) return child;
    const nested = findFirst(child, selector);
    if (nested) return nested;
  }
  return null;
}

// A coherent sidebar: `collapsed` derives EVERY probe element's expected
// state, so a test can flip exactly one of them to simulate a morphdom reset.
function makeState({
  collapsed = false,
  applied = 'auto',
  datasetAttr,
  widthClass,
  labels = [],
  compact = [],
  links = [],
  icon = null,
  withToggle = true,
} = {}) {
  const children = [
    ...labels.map((hidden) => makeNode(hidden ? ['sidebar-label', 'hidden'] : ['sidebar-label'])),
    ...compact.map((hidden) =>
      makeNode(hidden ? ['sidebar-collapsed-only', 'hidden'] : ['sidebar-collapsed-only'])
    ),
    ...links.map((centered) =>
      makeNode(centered ? ['justify-center'] : ['px-3'], {'data-sidebar-task-link': ''})
    ),
  ];

  const el = makeNode(widthClass === undefined ? [collapsed ? 'w-16' : 'w-60'] : widthClass, {}, children);
  el.dataset = {
    sidebarCollapsed: datasetAttr === undefined ? String(collapsed) : datasetAttr,
  };

  const collapseToggle = withToggle
    ? makeNode([], {}, icon ? [makeNode([`hero-chevron-double-${icon}`])] : [])
    : null;

  return {
    el,
    // 'auto' → matches `collapsed`; 'unset' → the pre-mount value (undefined).
    appliedCollapsed: applied === 'auto' ? collapsed : applied === 'unset' ? undefined : applied,
    collapseToggle,
  };
}

// Every probe satisfied for the given state.
function cleanState(collapsed, extra = {}) {
  return makeState({
    collapsed,
    labels: collapsed ? [true] : [false],
    compact: compactFor(collapsed),
    links: [collapsed],
    icon: collapsed ? 'right' : 'left',
    ...extra,
  });
}

function compactFor(collapsed) {
  // Collapsed → the compact marker is SHOWN (no `hidden`).
  return collapsed ? [false] : [true];
}

test('the very first run always sweeps — nothing has been applied yet', () => {
  assert.equal(collapseSyncNeeded(makeState({collapsed: true, applied: 'unset'}), true), true);
  assert.equal(collapseSyncNeeded(makeState({collapsed: false, applied: 'unset'}), false), true);
});

test('a stable sidebar needs no sweep, in either state', () => {
  assert.equal(collapseSyncNeeded(cleanState(true), true), false);
  assert.equal(collapseSyncNeeded(cleanState(false), false), false);
});

test('a state change (breakpoint / stored preference) always sweeps', () => {
  const state = cleanState(true);
  state.appliedCollapsed = true;
  assert.equal(collapseSyncNeeded(state, false), true);
});

test('a reset data-sidebar-collapsed attribute is dirty', () => {
  assert.equal(collapseSyncNeeded(makeState({collapsed: true, datasetAttr: 'false', labels: [true], compact: [false], links: [true], icon: 'right'}), true), true);
  assert.equal(collapseSyncNeeded(makeState({collapsed: false, datasetAttr: 'true', labels: [false], compact: [true], links: [false], icon: 'left'}), false), true);
});

test('a reset width class is dirty', () => {
  assert.equal(collapseSyncNeeded(cleanState(true, {widthClass: ['w-60']}), true), true);
  assert.equal(collapseSyncNeeded(cleanState(false, {widthClass: ['w-16']}), false), true);
});

test('labels: ANY still-visible label is dirty while collapsed (dynamic task rows lead the reset)', () => {
  // The first label (the static brand span) survived; a re-rendered Active
  // Tasks row lost its `hidden` — the first-element-only probe would miss it.
  const state = cleanState(true, {labels: [true, false]});
  assert.equal(collapseSyncNeeded(state, true), true);
});

test('labels: ANY hidden label is dirty while expanded', () => {
  assert.equal(collapseSyncNeeded(cleanState(false, {labels: [false, true]}), false), true);
});

test('collapsed-only markers must be visible while collapsed and hidden while expanded', () => {
  assert.equal(collapseSyncNeeded(cleanState(true, {compact: [true]}), true), true);
  assert.equal(collapseSyncNeeded(cleanState(false, {compact: [false]}), false), true);
  assert.equal(collapseSyncNeeded(cleanState(true, {compact: [false, false]}), true), false);
});

test('task links must be centered while collapsed and left-aligned while expanded', () => {
  assert.equal(collapseSyncNeeded(cleanState(true, {links: [false]}), true), true);
  assert.equal(collapseSyncNeeded(cleanState(false, {links: [true]}), false), true);
  assert.equal(collapseSyncNeeded(cleanState(true, {links: [true, true, true]}), true), false);
});

test('the toggle must carry the matching chevron', () => {
  assert.equal(collapseSyncNeeded(cleanState(true, {icon: 'left'}), true), true);
  assert.equal(collapseSyncNeeded(cleanState(false, {icon: 'right'}), false), true);
  assert.equal(collapseSyncNeeded(cleanState(true, {icon: null}), true), true);
  assert.equal(collapseSyncNeeded(cleanState(false, {icon: null}), false), true);
});

test('MISSING probe elements are fine — no markup means nothing to fix', () => {
  const bare = (collapsed) =>
    makeState({collapsed, labels: [], compact: [], links: [], withToggle: false});
  assert.equal(collapseSyncNeeded(bare(true), true), false);
  assert.equal(collapseSyncNeeded(bare(false), false), false);
});

test('the probe is total — a missing root or state is never dirty and never throws', () => {
  assert.equal(collapseSyncNeeded(null, true), false);
  assert.equal(collapseSyncNeeded(undefined, false), false);
  assert.equal(collapseSyncNeeded({appliedCollapsed: true}, true), false);
  assert.equal(collapseSyncNeeded({el: {}, appliedCollapsed: true}, true), false);
});
