// Run with: node --test apps/evo_dash/assets/js/hooks/desktop_titlebar.test.cjs
//
// Exercises the PURE chrome decision of the Genesis desktop title bar —
// "does this window get a strip, which controls does it show, and is the middle
// control maximize or restore?" — without a browser bundle. The hook half (the
// click bindings, the isMaximized()/onResized reflection, the Tauri-absence
// fallback) only executes the decision pinned here; it is never touched by
// these tests, so `window.__TAURI__` and the DOM stay out of them.
//
// Matching the list_enter.test.cjs / workbench_panel.test.cjs convention: the
// block between the source's markers is sliced out and run through node:vm, so
// the real shipped code is what is measured.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const src = readFileSync(`${__dirname}/desktop_titlebar.js`, 'utf8');
const start = src.indexOf('// --- DesktopTitlebar: pure chrome decision');
const end = src.indexOf('// DesktopTitlebar hook:');
assert.ok(start !== -1 && end > start, 'pure chrome decision block not found in desktop_titlebar.js');

const {chromeState} = vm.runInContext(
  `${src.slice(start, end)}\n({chromeState});`,
  vm.createContext({}),
);

test('no Tauri shell: the strip is not visible and has no controls', () => {
  const state = chromeState({isTauri: false, os: 'windows', isMaximized: false});
  assert.equal(state.visible, false);
  assert.deepEqual([...state.controls], []);
});

test('macOS keeps its native traffic lights: visible but no controls', () => {
  const state = chromeState({isTauri: true, os: 'macos', isMaximized: false});
  assert.equal(state.visible, true);
  assert.deepEqual([...state.controls], []);
  assert.equal(state.maxLabel, 'maximize');
});

test('windows renders minimize / maximize / close', () => {
  const state = chromeState({isTauri: true, os: 'windows', isMaximized: false});
  assert.equal(state.visible, true);
  assert.deepEqual([...state.controls], ['minimize', 'maximize', 'close']);
  assert.equal(state.maxLabel, 'maximize');
});

test('linux renders minimize / maximize / close', () => {
  const state = chromeState({isTauri: true, os: 'linux', isMaximized: false});
  assert.equal(state.visible, true);
  assert.deepEqual([...state.controls], ['minimize', 'maximize', 'close']);
  assert.equal(state.maxLabel, 'maximize');
});

test('a maximized windows window turns the middle control into restore', () => {
  const state = chromeState({isTauri: true, os: 'windows', isMaximized: true});
  assert.deepEqual([...state.controls], ['minimize', 'restore', 'close']);
  assert.equal(state.maxLabel, 'restore');
});

test('a maximized linux window turns the middle control into restore', () => {
  const state = chromeState({isTauri: true, os: 'linux', isMaximized: true});
  assert.deepEqual([...state.controls], ['minimize', 'restore', 'close']);
  assert.equal(state.maxLabel, 'restore');
});

test('macOS reflects restore in the label but still offers no controls', () => {
  const state = chromeState({isTauri: true, os: 'macos', isMaximized: true});
  assert.equal(state.visible, true);
  assert.deepEqual([...state.controls], []);
  assert.equal(state.maxLabel, 'restore');
});

test('an unknown OS gets a strip but no controls, maximized or not', () => {
  for (const isMaximized of [false, true]) {
    const state = chromeState({isTauri: true, os: 'unknown', isMaximized});
    assert.equal(state.visible, true);
    assert.deepEqual([...state.controls], [], `unknown os must not render controls (isMaximized=${isMaximized})`);
  }
});

test('only an explicit true is Tauri, an explicit true is maximized', () => {
  for (const isTauri of [undefined, null, 'true', 1, {}]) {
    const state = chromeState({isTauri, os: 'windows', isMaximized: false});
    assert.equal(state.visible, false, `${JSON.stringify(isTauri)} must not count as Tauri`);
    assert.deepEqual([...state.controls], []);
  }
  for (const isMaximized of [undefined, null, 'true', 1, {}]) {
    const state = chromeState({isTauri: true, os: 'windows', isMaximized});
    assert.deepEqual([...state.controls], ['minimize', 'maximize', 'close'], `${JSON.stringify(isMaximized)} must not count as maximized`);
    assert.equal(state.maxLabel, 'maximize');
  }
});

test('a missing or malformed input is a safe, hidden decision', () => {
  for (const bad of [undefined, null, {}]) {
    const state = chromeState(bad);
    assert.equal(state.visible, false, `${JSON.stringify(bad)} must not be visible without Tauri`);
    assert.deepEqual([...state.controls], []);
    assert.equal(state.maxLabel, 'maximize');
  }
});

test('a Tauri state without an OS is visible but control-less', () => {
  for (const missingOs of [{isTauri: true}, {isTauri: true, os: null}, {isTauri: true, os: ''}]) {
    const state = chromeState(missingOs);
    assert.equal(state.visible, true, 'the strip still exists, it just has no controls');
    assert.deepEqual([...state.controls], []);
  }
});

test('each call returns its own controls array', () => {
  const first = chromeState({isTauri: true, os: 'windows', isMaximized: false});
  const second = chromeState({isTauri: true, os: 'windows', isMaximized: false});
  assert.notEqual(first.controls, second.controls, 'callers may not share one mutable controls list');
  first.controls.push('injected');
  assert.deepEqual([...second.controls], ['minimize', 'maximize', 'close']);
});
