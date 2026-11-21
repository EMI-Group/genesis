// Run with: node --test apps/evo_dash/assets/js/hooks/file_picker.test.cjs
//
// Pins the FilePicker teardown contract: the manual path panel
// (#objective-file-manual) is a SIBLING of the <details> the hook is mounted
// on, so it outlives a details teardown. Every listener the hook registers —
// on this.el AND on the manual elements — must be removed in destroyed();
// otherwise a remount stacks a second set of closures over the surviving
// nodes and Enter/confirm pushes "file_pick_manual" twice.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const moduleSource = readFileSync(`${__dirname}/file_picker.js`, 'utf8');
// Start at the attribute constants (not the ES import, which a vm script
// cannot parse) so the shipped attribute names are exercised, not copies.
const hookSource = moduleSource.slice(moduleSource.indexOf('const FILE_MANUAL_STATE_ATTR'),
  moduleSource.indexOf('export default FilePicker;'));

// The manual panel's exit is the shared motion primitive; run the SHIPPED
// closeAnimated (sliced exactly like disclosure_motion.test.cjs does) so the
// attribute, the target-verified animationend and the bounded fallback are
// proven, not stubbed.
const motionSrc = readFileSync(`${__dirname}/disclosure_motion.js`, 'utf8');
const pureStart = motionSrc.indexOf('// --- DisclosureMotion: pure close decisions (unit-tested)');
const domStart = motionSrc.indexOf('// DisclosureMotion: DOM orchestration + hook');
const domEnd = motionSrc.indexOf('const DisclosureMotion = {');
const motionSource = `${motionSrc.slice(pureStart, domStart)}\n${motionSrc.slice(domStart, domEnd)}`;

const timers = [];
function createPicker({reduced = false} = {}) {
  const context = vm.createContext({
    console: {warn() {}},
    document: {querySelector: () => null},
    Event: class {constructor(type) { this.type = type; }},
    window: {matchMedia: () => ({matches: reduced})},
    setTimeout: (fn, ms) => { const timer = {fn, ms, cleared: false}; timers.push(timer); return timer; },
    clearTimeout: (timer) => { if (timer) timer.cleared = true; }
  });
  vm.runInContext(motionSource, context);
  return vm.runInContext(`${hookSource}\nFilePicker;`, context);
}
const filePicker = createPicker();

// A listener-recording DOM seam: every element keeps its own listener map, so
// an added-then-removed listener leaves the element empty. Attributes matter
// here: the exit is gated on data-file-manual-state="closing".
function makeEl(querySelector = () => null) {
  const listeners = new Map();
  const attributes = new Map();
  return {
    listeners,
    attributes,
    hidden: true,
    value: '',
    dataset: {},
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(fn);
    },
    removeEventListener(type, fn) {
      const fns = listeners.get(type) || [];
      listeners.set(type, fns.filter((entry) => entry !== fn));
    },
    count(type) { return (listeners.get(type) || []).length; },
    fire(type, event) { for (const fn of listeners.get(type) || []) fn(event); },
    getAttribute(name) { return attributes.has(name) ? attributes.get(name) : null; },
    setAttribute(name, value) { attributes.set(name, value); },
    removeAttribute(name) { attributes.delete(name); },
    querySelector,
    closest: () => null,
    focus() {},
    select() {}
  };
}

// The manual panel is a SIBLING of the dropdown <details>, so the SAME nodes
// are reused across a details teardown + remount in the real DOM.
function makeManualDom() {
  const manualInput = makeEl();
  const confirmBtn = makeEl();
  const cancelBtn = makeEl();
  const wrap = makeEl();   // .file-manual-input-wrap — the animated panel
  const manualEl = makeEl((selector) => {
    if (selector === '.file-manual-input') return manualInput;
    if (selector === '.file-manual-input-wrap') return wrap;
    if (selector === '.file-manual-error') return null;
    if (selector === '.file-manual-confirm') return confirmBtn;
    if (selector === '.file-manual-cancel') return cancelBtn;
    return null;
  });
  manualEl.hidden = true;
  return {manualEl, manualInput, confirmBtn, cancelBtn, wrap,
    els: [manualEl, manualInput, confirmBtn, cancelBtn]};
}

function manualListenerCount(manualDom) {
  return manualDom.els.reduce((sum, el) =>
    sum + el.count('click') + el.count('keydown'), 0);
}

function makeInstance({pickerIds = ['objective_file'], manualDom = makeManualDom(), impl = filePicker} = {}) {
  const textarea = makeEl(() => null);
  textarea.value = 'base prompt';
  textarea.dispatched = [];
  textarea.dispatchEvent = (event) => textarea.dispatched.push(event.type);

  const itemEls = pickerIds.map((id) => {
    const item = makeEl();
    item.dataset.pickerId = id;
    item.dataset.pickerKind = 'text';
    return item;
  });

  const pushed = [];
  const handleEventRefs = [];
  const removedRefs = [];
  const registry = new Map();   // event name -> Set of live handlers

  const hook = Object.assign(Object.create(impl), {
    pushEvent(name, payload) { pushed.push({name, payload}); },
    handleEvent(name, fn) {
      if (!registry.has(name)) registry.set(name, new Set());
      registry.get(name).add(fn);
      const ref = {name, fn};
      handleEventRefs.push(ref);
      return ref;
    },
    removeHandleEvent(ref) {
      registry.get(ref.name)?.delete(ref.fn);
      removedRefs.push(ref);
    }
  });
  hook.el = makeEl((selector) => (selector === 'textarea[name="prompt"]' ? textarea : null));
  hook.el.closest = (selector) => {
    if (selector === '.input-controls') return {querySelector: () => manualDom.manualEl};
    if (selector === 'form') return {querySelector: () => textarea};
    return null;
  };
  hook.el.querySelectorAll = () => itemEls;

  return {hook, textarea, manualDom, itemEls, pushed, handleEventRefs, removedRefs,
    dispatchResult(name, payload) {
      for (const fn of registry.get(name) || []) fn(payload);
    },
    liveHandlers(name) { return (registry.get(name) || new Set()).size; }};
}

test('a single mount registers the DOM listeners and one handler per picker id', () => {
  const manualDom = makeManualDom();
  const page = makeInstance({pickerIds: ['objective_file', 'objective_file_image'], manualDom});
  page.hook.mounted();
  assert.equal(page.hook.el.count('click'), 1);
  assert.equal(manualDom.manualInput.count('keydown'), 1);
  assert.equal(manualDom.confirmBtn.count('click'), 1);
  assert.equal(manualDom.cancelBtn.count('click'), 1);
  assert.equal(manualListenerCount(manualDom), 3);
  assert.deepEqual(page.handleEventRefs.map((ref) => ref.name),
    ['picker_result:objective_file', 'picker_result:objective_file_image']);
});

test('destroyed removes the el listener, every manual-panel listener and every handleEvent ref', () => {
  const manualDom = makeManualDom();
  const page = makeInstance({manualDom});
  page.hook.mounted();
  page.hook.destroyed();
  assert.equal(page.hook.el.count('click'), 0);
  assert.equal(manualListenerCount(manualDom), 0);
  assert.equal(page.removedRefs.length, page.handleEventRefs.length);
  assert.deepEqual(page.removedRefs, page.handleEventRefs);
  assert.equal(page.liveHandlers('picker_result:objective_file'), 0);
});

test('a remount over the surviving manual panel never stacks a second confirm closure', () => {
  const manualDom = makeManualDom();
  const first = makeInstance({manualDom});
  first.hook.mounted();
  // The <details> goes away (hook destroyed); the sibling manual panel survives.
  first.hook.destroyed();
  const second = makeInstance({manualDom});
  second.hook.mounted();

  assert.equal(manualDom.manualInput.count('keydown'), 1, 'one keydown listener, not two');
  assert.equal(manualDom.confirmBtn.count('click'), 1, 'one confirm listener, not two');

  manualDom.confirmBtn.fire('click', {});
  assert.equal(first.pushed.filter((event) => event.name === 'file_pick_manual').length, 0,
    'the destroyed hook never pushes');
  assert.equal(second.pushed.filter((event) => event.name === 'file_pick_manual').length, 1,
    'the live hook pushes exactly once per confirm');
});

test('a destroyed hook has no live handler left for a late native result', () => {
  const page = makeInstance();
  page.hook.mounted();
  page.hook.destroyed();
  page.dispatchResult('picker_result:objective_file',
    {prompt: 'server prompt', block: 'block', attached: true});
  assert.deepEqual(page.pushed, []);
  assert.equal(page.textarea.value, 'base prompt');
});

test('the text result still uses append-not-clobber semantics', () => {
  const unchanged = makeInstance();
  unchanged.hook.mounted();
  unchanged.hook._basePrompt = 'base prompt';
  unchanged.dispatchResult('picker_result:objective_file',
    {prompt: 'next objective', block: ' block', attached: true});
  assert.equal(unchanged.textarea.value, 'next objective');
  assert.deepEqual(unchanged.textarea.dispatched, ['input', 'change']);

  const typed = makeInstance();
  typed.hook.mounted();
  typed.hook._basePrompt = 'base prompt';
  typed.textarea.value = 'base prompt + typed';
  typed.dispatchResult('picker_result:objective_file',
    {prompt: 'stale server prompt', block: ' block', attached: true});
  assert.equal(typed.textarea.value, 'base prompt + typed block');
});

// --- Manual panel exit (shared motion primitive) --------------------------

test('closeManual fades the wrap out before hiding it, and never snaps', () => {
  const page = makeInstance();
  page.hook.mounted();
  page.hook.openManual();
  assert.equal(page.manualDom.manualEl.hidden, false);

  const before = timers.length;
  page.hook.closeManual();
  assert.equal(page.manualDom.manualEl.hidden, false, 'the exit frame must be visible');
  assert.equal(page.manualDom.manualEl.getAttribute('data-file-manual-state'), 'closing');
  assert.equal(timers.length, before + 1, 'the bounded fallback is armed');

  // A child element's animationend must not cut the exit short.
  page.manualDom.wrap.fire('animationend', {target: page.manualDom.manualInput});
  assert.equal(page.manualDom.manualEl.hidden, false);
  page.manualDom.wrap.fire('animationend', {target: page.manualDom.wrap});
  assert.equal(page.manualDom.manualEl.hidden, true, 'hidden only after the wrap finished');
  assert.equal(page.manualDom.manualEl.getAttribute('data-file-manual-state'), null);
  assert.equal(timers[before].cleared, true, 'the fallback is cancelled by the animationend');
  assert.equal(page.manualDom.wrap.count('animationend'), 0, 'the listener is released');
});

test('closeManual is a no-op on an already hidden panel (no exit, no timer)', () => {
  const page = makeInstance();
  page.hook.mounted();
  const before = timers.length;
  page.hook.closeManual();
  assert.equal(page.manualDom.manualEl.hidden, true);
  assert.equal(page.manualDom.manualEl.getAttribute('data-file-manual-state'), null);
  assert.equal(timers.length, before);
});

test('reduced motion hides the manual panel in the same task', () => {
  const page = makeInstance({impl: createPicker({reduced: true})});
  page.hook.mounted();
  page.hook.openManual();
  page.hook.closeManual();
  assert.equal(page.manualDom.manualEl.hidden, true);
  assert.equal(page.manualDom.manualEl.getAttribute('data-file-manual-state'), null);
  assert.equal(page.manualDom.wrap.count('animationend'), 0, 'nothing to wait for');
});

test('reopening during the exit completes it first, then reveals the panel', () => {
  const page = makeInstance();
  page.hook.mounted();
  page.hook.openManual();
  page.hook.closeManual();
  assert.equal(page.manualDom.manualEl.getAttribute('data-file-manual-state'), 'closing');

  page.hook.openManual();
  assert.equal(page.manualDom.manualEl.hidden, false, 'the new open wins');
  assert.equal(page.manualDom.manualEl.getAttribute('data-file-manual-state'), null);
  assert.equal(page.manualDom.wrap.count('animationend'), 0, 'the superseded exit released its listener');
});

test('destroyed releases a manual close still in flight', () => {
  const page = makeInstance();
  page.hook.mounted();
  page.hook.openManual();
  page.hook.closeManual();
  page.hook.destroyed();
  assert.equal(page.manualDom.manualEl.hidden, true, 'the exit completes with the hook');
  assert.equal(page.manualDom.manualEl.getAttribute('data-file-manual-state'), null);
  assert.equal(page.manualDom.wrap.count('animationend'), 0);
});
