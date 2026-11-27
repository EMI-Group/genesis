// Run with: node --test apps/evo_dash/assets/js/hooks/desktop_titlebar.test.cjs
//
// Exercises the two PURE decisions of the Genesis desktop title bar —
// `chromeState` ("does this strip show window controls, and is the middle one
// maximize or restore?") and `isDragTarget` ("does a press here start a window
// drag?") — plus the ONE regression that must never come back: a missing Tauri
// handle leaves the strip VISIBLE (and `data-desktop` intact) instead of hiding
// it and leaving a chrome-less desktop window.
//
// Matching the list_enter.test.cjs / workbench_panel.test.cjs convention, the
// block between the source's markers is sliced out and run through node:vm, so
// the real shipped code is what is measured. The pure block runs in an EMPTY
// context (no DOM, no browser globals); the hook-regression test adds only the
// three fake globals the shipped hook actually reads (`window`, `document`,
// `console`).
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const src = readFileSync(`${__dirname}/desktop_titlebar.js`, 'utf8');
const start = src.indexOf('// --- DesktopTitlebar: pure chrome decision');
const end = src.indexOf('// DesktopTitlebar hook:');
const exportAt = src.indexOf('export {DesktopTitlebar');
assert.ok(start !== -1 && end > start, 'pure chrome decision block not found in desktop_titlebar.js');
assert.ok(exportAt > end, 'export block not found in desktop_titlebar.js');

const pureSource = src.slice(start, end);

const {chromeState, isDragTarget} = vm.runInContext(
  `${pureSource}\n({chromeState, isDragTarget});`,
  vm.createContext({}),
);

// --- chromeState -----------------------------------------------------------

test('no Tauri shell: the strip is STILL visible, but not interactive', () => {
  const state = chromeState({isTauri: false, os: 'windows', isMaximized: false});
  assert.equal(state.visible, true, 'the client is never the visibility authority');
  assert.equal(state.interactive, false);
});

test('only an explicit true is interactive', () => {
  for (const isTauri of [undefined, null, 'true', 1, {}, false, 0]) {
    const state = chromeState({isTauri, os: 'windows', isMaximized: false});
    assert.equal(state.interactive, false, `${JSON.stringify(isTauri)} must not count as Tauri`);
    assert.equal(state.visible, true);
  }
  assert.equal(chromeState({isTauri: true, os: 'windows'}).interactive, true);
});

test('windows, linux and an unknown OS all get minimize / maximize / close', () => {
  for (const os of ['windows', 'linux', 'unknown']) {
    const state = chromeState({isTauri: true, os, isMaximized: false});
    assert.deepEqual([...state.controls], ['minimize', 'maximize', 'close'], `os=${os}`);
    assert.equal(state.maxLabel, 'maximize');
    assert.equal(state.visible, true);
  }
});

test('macOS keeps its native traffic lights: no controls', () => {
  const state = chromeState({isTauri: true, os: 'macos', isMaximized: false});
  assert.equal(state.visible, true);
  assert.deepEqual([...state.controls], []);
  assert.equal(state.maxLabel, 'maximize');
});

test('a maximized window turns the middle control into restore', () => {
  for (const os of ['windows', 'linux', 'unknown']) {
    const state = chromeState({isTauri: true, os, isMaximized: true});
    assert.deepEqual([...state.controls], ['minimize', 'restore', 'close'], `os=${os}`);
    assert.equal(state.maxLabel, 'restore');
  }
});

test('macOS reflects restore in the label but still offers no controls', () => {
  const state = chromeState({isTauri: true, os: 'macos', isMaximized: true});
  assert.equal(state.visible, true);
  assert.deepEqual([...state.controls], []);
  assert.equal(state.maxLabel, 'restore');
});

test('only an explicit true is maximized', () => {
  for (const isMaximized of [undefined, null, 'true', 1, {}]) {
    const state = chromeState({isTauri: true, os: 'windows', isMaximized});
    assert.deepEqual([...state.controls], ['minimize', 'maximize', 'close'], `${JSON.stringify(isMaximized)} must not count as maximized`);
    assert.equal(state.maxLabel, 'maximize');
  }
});

test('a missing, empty or null OS is still a windowed OS', () => {
  for (const missingOs of [{isTauri: true}, {isTauri: true, os: null}, {isTauri: true, os: ''}]) {
    const state = chromeState(missingOs);
    assert.equal(state.visible, true);
    assert.deepEqual([...state.controls], ['minimize', 'maximize', 'close'], `${JSON.stringify(missingOs)} must keep its controls`);
  }
});

test('a malformed or missing input is safe and still visible', () => {
  for (const bad of [undefined, null, {}, 'nope', 42]) {
    const state = chromeState(bad);
    assert.equal(state.visible, true, `${JSON.stringify(bad)} must not be hidden`);
    assert.equal(state.interactive, false);
    assert.equal(state.maxLabel, 'maximize');
  }
});

test('each call returns its own controls array', () => {
  const first = chromeState({isTauri: true, os: 'windows', isMaximized: false});
  const second = chromeState({isTauri: true, os: 'windows', isMaximized: false});
  assert.notEqual(first.controls, second.controls, 'callers may not share one mutable controls list');
  first.controls.push('injected');
  assert.deepEqual([...second.controls], ['minimize', 'maximize', 'close']);
});

// --- isDragTarget ----------------------------------------------------------

// Duck-typed stand-in for a DOM node (the pure block runs without a DOM).
const node = (tagName, attrs = {}, parentElement = null) => ({
  tagName,
  parentElement,
  getAttribute: (name) => (Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null),
});

test('a plain element is a drag target', () => {
  assert.equal(isDragTarget(node('DIV')), true);
  assert.equal(isDragTarget(node('SPAN', {}, node('DIV', {}, node('DIV')))), true);
});

test('the strip spacer itself is a drag target', () => {
  assert.equal(isDragTarget(node('DIV', {class: 'desktop-titlebar-drag'})), true);
});

test('interactive tags are never drag targets', () => {
  for (const tagName of ['A', 'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'LABEL', 'SUMMARY']) {
    assert.equal(isDragTarget(node(tagName)), false, tagName);
  }
});

test('an interactive ancestor kills the drag target', () => {
  assert.equal(isDragTarget(node('SPAN', {}, node('BUTTON'))), false);
  assert.equal(isDragTarget(node('SVG', {}, node('PATH', {}, node('SPAN', {}, node('BUTTON', {}, node('DIV')))))), false);
});

test('tag names are matched case-insensitively', () => {
  assert.equal(isDragTarget(node('button')), false);
  assert.equal(isDragTarget(node('div')), true);
  assert.equal(isDragTarget(node('Input')), false);
});

test('interactive roles are not drag targets, presentational roles are', () => {
  for (const role of ['button', 'link', 'menuitem', 'tab', 'checkbox', 'radio', 'switch', 'option', 'BUTTON']) {
    assert.equal(isDragTarget(node('DIV', {role})), false, `role=${role}`);
  }
  assert.equal(isDragTarget(node('DIV', {role: 'presentation'})), true);
  assert.equal(isDragTarget(node('DIV', {role: 'group'})), true);
});

test('a non-negative tabindex is not a drag target, a negative one is', () => {
  assert.equal(isDragTarget(node('DIV', {tabindex: '0'})), false);
  assert.equal(isDragTarget(node('DIV', {tabindex: ''})), false, 'an empty tabindex counts as 0');
  assert.equal(isDragTarget(node('DIV', {tabindex: '3'})), false);
  assert.equal(isDragTarget(node('DIV', {tabindex: '-1'})), true);
});

test('contenteditable is not a drag target', () => {
  for (const value of ['', 'true', 'plaintext-only']) {
    assert.equal(isDragTarget(node('DIV', {contenteditable: value})), false, `contenteditable=${JSON.stringify(value)}`);
  }
  assert.equal(isDragTarget(node('DIV', {contenteditable: 'false'})), true);
  assert.equal(isDragTarget({tagName: 'DIV', isContentEditable: true, parentElement: null, getAttribute: () => null}), false);
});

test('null, undefined and non-element input is never a drag target', () => {
  for (const bad of [null, undefined, 'div', 42, {}, {parentElement: null}]) {
    assert.equal(isDragTarget(bad), false, `${JSON.stringify(bad)}`);
  }
});

test('nodes without getAttribute are read defensively', () => {
  assert.equal(isDragTarget({tagName: 'DIV', parentElement: null}), true);
  assert.equal(isDragTarget({tagName: 'BUTTON', parentElement: null}), false);
});

// --- the hook itself: the never-hide regression ---------------------------

test('a missing Tauri handle keeps the strip visible and leaves data-desktop alone', () => {
  const removed = [];
  const layout = {
    removeAttribute: (...args) => removed.push(args),
    setAttribute: (...args) => removed.push(args),
  };
  const messages = [];
  const context = vm.createContext({
    window: {},
    document: {getElementById: (id) => (id === 'app-layout' ? layout : null)},
    console: {
      error: (...args) => messages.push(args.join(' ')),
      warn: (...args) => messages.push(args.join(' ')),
      log: () => {},
    },
  });

  const {DesktopTitlebar} = vm.runInContext(
    `${src.slice(start, exportAt)}\n;({DesktopTitlebar});`,
    context,
  );
  assert.equal(typeof DesktopTitlebar.mounted, 'function');

  const listeners = [];
  const el = {
    dataset: {os: 'windows'},
    style: {},
    querySelector: () => null,
    addEventListener: (...args) => listeners.push(args),
    removeEventListener: () => {},
  };

  const hook = Object.create(DesktopTitlebar);
  hook.el = el;
  hook.mounted();

  assert.notEqual(el.style.display, 'none', 'the strip must never be hidden');
  assert.equal(el.style.display, undefined, 'the hook writes no display at all');
  assert.equal(removed.length, 0, 'data-desktop (and the reserved strip height) must stay');
  assert.ok(
    messages.some((message) => /\[desktop-titlebar\]/.test(message) && /stays visible/i.test(message)),
    `expected a loud console.error about the missing handle, got ${JSON.stringify(messages)}`,
  );
  assert.equal(hook._win, null);
  assert.equal(hook._chromeRequested, false, 'no chrome request without a handle');
  assert.equal(el.dataset.titlebarBound, undefined, 'nothing is bound without a handle');
  assert.equal(listeners.length, 0);
});
