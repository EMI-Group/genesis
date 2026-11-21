// Run with: node --test apps/evo_dash/assets/js/hooks/capsule_panel.test.cjs
//
// Pins the CapsulePanel close decisions against the REAL shared motion
// primitive: the root panel's animated close and the NEW Layer-2 submenu
// close. Both are driven through the shipped `closeAnimated` (sliced out of
// disclosure_motion.js, exactly like disclosure_motion.test.cjs does), so the
// test proves the attribute the CSS keys off, the target-verified
// animationend, the release of `open` and the bounded fallback timer — never a
// stub of them.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const motionSrc = readFileSync(`${__dirname}/disclosure_motion.js`, 'utf8');
const pureStart = motionSrc.indexOf('// --- DisclosureMotion: pure close decisions (unit-tested)');
const domStart = motionSrc.indexOf('// DisclosureMotion: DOM orchestration + hook');
const domEnd = motionSrc.indexOf('const DisclosureMotion = {');
assert.ok(pureStart !== -1 && domStart > pureStart && domEnd > domStart,
  'disclosure_motion.js markers moved');

const capsuleSrc = readFileSync(`${__dirname}/capsule_panel.js`, 'utf8');
const capsuleStart = capsuleSrc.indexOf('const CAPSULE_STATE_ATTR');
assert.ok(capsuleStart !== -1, 'capsule_panel.js attribute block not found');
const capsuleCode = capsuleSrc.slice(capsuleStart, capsuleSrc.indexOf('export default CapsulePanel;'));

// --- fake DOM -------------------------------------------------------------
function fakeNode({open = false} = {}) {
  const attributes = new Map();
  if (open) attributes.set('open', '');
  const listeners = new Map();
  const node = {
    open,
    dataset: {},
    listeners,
    getAttribute: (name) => (attributes.has(name) ? attributes.get(name) : null),
    setAttribute(name, value) {
      attributes.set(name, value);
      if (name === 'open') node.open = true;
    },
    removeAttribute(name) {
      attributes.delete(name);
      if (name === 'open') node.open = false;
    },
    addEventListener(name, fn) {
      if (!listeners.has(name)) listeners.set(name, []);
      listeners.get(name).push(fn);
    },
    removeEventListener(name, fn) {
      listeners.set(name, (listeners.get(name) || []).filter((entry) => entry !== fn));
    },
    fire(name, event) {
      for (const fn of listeners.get(name) || []) fn(event);
      return event;
    },
    querySelector: () => null,
    querySelectorAll: () => [],
    contains: (child) => child === node,
    focus() {}
  };
  return node;
}

function makePage({rootOpen = true, subOpen = true, contained = true} = {}) {
  const timers = [];
  const sandbox = {
    window: {matchMedia: () => ({matches: false})},
    document: {addEventListener() {}, removeEventListener() {}},
    setTimeout: (fn, ms) => { const timer = {fn, ms, cleared: false}; timers.push(timer); return timer; },
    clearTimeout: (timer) => { if (timer) timer.cleared = true; },
    Element: class Element {}
  };
  const context = vm.createContext(sandbox);
  // Define the shared primitive first, then alias the import name the hook uses.
  vm.runInContext(`${motionSrc.slice(pureStart, domStart)}\n${motionSrc.slice(domStart, domEnd)}`, context);
  context.closeAnimatedShared = context.closeAnimated;
  const CapsulePanel = vm.runInContext(`${capsuleCode}\nCapsulePanel;`, context);

  const panel = fakeNode();
  const rootSummary = fakeNode();
  const list = fakeNode();
  const subSummary = fakeNode();
  const sub = fakeNode({open: subOpen});

  const root = fakeNode({open: rootOpen});
  root.querySelector = (selector) => {
    if (selector === '.capsule-panel') return panel;
    if (selector === ':scope > summary') return rootSummary;
    return null; // no .capsule-view children (mode+speed capsule shape)
  };
  root.querySelectorAll = (selector) => (selector === 'details.capsule-sub' ? [sub] : []);
  root.contains = (child) => (contained ? child === root || child === sub : false);

  sub.querySelector = (selector) => (selector === ':scope > .capsule-list' ? list : null);
  subSummary.closest = (selector) => (selector === 'details.capsule-sub' ? sub : null);

  const hook = Object.assign(Object.create(CapsulePanel), {el: root});
  hook.mounted();

  const target = (summary) => Object.assign(Object.create(sandbox.Element.prototype), {
    closest: (selector) => (selector === 'summary' ? summary : null)
  });

  return {
    hook, root, panel, sub, list, rootSummary, subSummary, timers, target,
    click(summary) {
      const event = {target: target(summary), prevented: false, preventDefault() { this.prevented = true; }};
      return root.fire('click', event);
    },
    panelEnd(endTarget = panel) { panel.fire('animationend', {target: endTarget}); },
    listEnd(endTarget = list) { list.fire('animationend', {target: endTarget}); },
    // The submenu's own listeners live on the list node.
    subListeners() { return list.listeners.get('animationend') || []; }
  };
}

test('a root summary click runs the animated close on the shared state attribute', () => {
  const page = makePage();
  const event = page.click(page.rootSummary);
  assert.equal(event.prevented, true);
  assert.equal(page.root.getAttribute('data-capsule-state'), 'closing');
  assert.equal(page.root.open, true, 'the panel stays mounted while it animates out');
  assert.equal(page.timers.length, 1, 'the bounded fallback is the safety net');

  // A child animation must not finish the exit.
  page.panelEnd(fakeNode());
  assert.equal(page.root.getAttribute('data-capsule-state'), 'closing');
  page.panelEnd();
  assert.equal(page.root.getAttribute('data-capsule-state'), null);
  assert.equal(page.root.open, false);
  assert.equal(page.timers[0].cleared, true);
});

test('an OPEN Layer-2 submenu summary click animates the list out instead of snapping', () => {
  const page = makePage();
  const event = page.click(page.subSummary);
  assert.equal(event.prevented, true, 'the native snap is intercepted');
  assert.equal(page.sub.getAttribute('data-capsule-sub-state'), 'closing');
  assert.equal(page.sub.open, true, 'open is released only after the exit');
  assert.equal(page.root.getAttribute('data-capsule-state'), null, 'the root panel is untouched');
  assert.equal(page.root.open, true);
  assert.equal(page.subListeners().length, 1);

  page.listEnd(fakeNode());
  assert.equal(page.sub.open, true, 'a child element animation must not finish it');
  page.listEnd();
  assert.equal(page.sub.open, false);
  assert.equal(page.sub.getAttribute('data-capsule-sub-state'), null);
  assert.equal(page.subListeners().length, 0, 'the listener is released');
});

test('a CLOSED submenu summary keeps its native open (no interception, no state)', () => {
  const page = makePage({subOpen: false});
  const event = page.click(page.subSummary);
  assert.equal(event.prevented, false);
  assert.equal(page.sub.getAttribute('data-capsule-sub-state'), null);
  assert.equal(page.timers.length, 0);
});

test('a submenu outside this hook element is left to its own instance', () => {
  const page = makePage({contained: false});
  const event = page.click(page.subSummary);
  assert.equal(event.prevented, false);
  assert.equal(page.sub.getAttribute('data-capsule-sub-state'), null);
});

test('destroyed releases a submenu close still in flight', () => {
  const page = makePage();
  page.click(page.subSummary);
  assert.equal(page.sub.open, true);
  page.hook.destroyed();
  assert.equal(page.sub.open, false, 'the close completes with the removed element');
  assert.equal(page.sub.getAttribute('data-capsule-sub-state'), null);
  assert.equal(page.subListeners().length, 0);
  assert.equal(page.timers[0].cleared, true);
});
