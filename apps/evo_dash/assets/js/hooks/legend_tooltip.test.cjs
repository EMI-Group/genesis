// Run with: node --test apps/evo_dash/assets/js/hooks/legend_tooltip.test.cjs
//
// Pins the LegendTooltip exit contract: the tip is ONE node per chip that
// stays in the DOM across hide/show, so the CSS opacity transition in
// css/app.css can run in BOTH directions (hide() only drops `.is-visible`;
// removing the node synchronously would pop it out). The pending entry frame
// is tracked and cancelled, so a mouseleave landing before the frame can never
// be undone by a stale `requestAnimationFrame` callback.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const moduleSource = readFileSync(`${__dirname}/legend_tooltip.js`, 'utf8');
const hookSource = moduleSource.slice(moduleSource.indexOf('const LegendTooltip = {'),
  moduleSource.indexOf('export default LegendTooltip;'));

function makeTip() {
  const classes = new Set();
  return {
    className: '',
    textContent: '',
    style: {},
    offsetWidth: 100,
    offsetHeight: 24,
    removed: false,
    classList: {
      add: (name) => classes.add(name),
      remove: (name) => classes.delete(name),
      contains: (name) => classes.has(name)
    },
    remove() { this.removed = true; }
  };
}

function makePage() {
  const created = [];
  const appended = [];
  const frames = new Map();
  let nextFrame = 1;
  const context = vm.createContext({
    document: {
      createElement(tag) {
        const el = Object.assign(makeTip(), {tag});
        created.push(el);
        return el;
      },
      body: {appendChild(el) { appended.push(el); }}
    },
    window: {innerHeight: 800, innerWidth: 1200},
    requestAnimationFrame(fn) {
      const id = nextFrame++;
      frames.set(id, fn);
      return id;
    },
    cancelAnimationFrame(id) { frames.delete(id); }
  });

  const hook = vm.runInContext(`${hookSource}\nLegendTooltip;`, context);
  const listeners = new Map();
  const chip = {
    dataset: {tip: 'Spawned a subagent'},
    addEventListener(type, fn) { listeners.set(type, fn); },
    removeEventListener(type, fn) { if (listeners.get(type) === fn) listeners.delete(type); },
    getBoundingClientRect: () => ({top: 400, bottom: 416, left: 500, width: 16, height: 16}),
    fire(type) { const fn = listeners.get(type); if (fn) fn({}); }
  };
  Object.assign(hook, {el: chip});

  return {
    hook, chip, created, appended, frames,
    // Runs every queued frame, like a browser would on the next paint.
    flushFrames() {
      const queued = [...frames.values()];
      frames.clear();
      for (const fn of queued) fn();
    }
  };
}

test('the entry frame adds is-visible only after the node is measured and appended', () => {
  const page = makePage();
  page.hook.mounted();
  page.chip.fire('mouseenter');

  assert.equal(page.created.length, 1, 'exactly one node per chip');
  assert.deepEqual(page.appended, [page.created[0]]);
  const tip = page.hook.tipEl;
  assert.equal(tip.textContent, 'Spawned a subagent');
  assert.equal(tip.style.left, '458px', 'centered on the chip and clamped');
  assert.equal(tip.style.bottom, '408px', 'default: above the chip');
  assert.equal(tip.style.top, 'auto');
  assert.equal(tip.classList.contains('is-visible'), false, 'hidden until the frame runs');

  page.flushFrames();
  assert.equal(tip.classList.contains('is-visible'), true);

  // No room above → flip below the chip on the next show.
  page.chip.getBoundingClientRect = () => ({top: 10, bottom: 26, left: 500, width: 16, height: 16});
  page.chip.fire('mouseenter');
  assert.equal(tip.style.top, '34px');
  assert.equal(tip.style.bottom, 'auto');
});

test('hide only drops is-visible: the same node stays for the CSS exit transition', () => {
  const page = makePage();
  page.hook.mounted();
  page.chip.fire('mouseenter');
  page.flushFrames();
  const tip = page.hook.tipEl;
  page.chip.fire('mouseleave');

  assert.equal(tip.classList.contains('is-visible'), false, 'the exit transition has a frame to run');
  assert.equal(tip.removed, false, 'the node is not synchronously torn out');
  assert.equal(page.hook.tipEl, tip, 'one node per chip, reused');
  assert.equal(page.appended.length, 1);
});

test('re-showing an existing node repositions it and re-arms the entry frame', () => {
  const page = makePage();
  page.hook.mounted();
  page.chip.fire('mouseenter');
  page.flushFrames();
  page.chip.fire('mouseleave');

  page.chip.fire('mouseenter');
  assert.equal(page.created.length, 1, 'the node is reused, never duplicated');
  assert.equal(page.hook.tipEl.classList.contains('is-visible'), false, 're-armed behind a frame');
  page.flushFrames();
  assert.equal(page.hook.tipEl.classList.contains('is-visible'), true);
});

test('a hide landing before the entry frame cancels it (no stale re-show)', () => {
  const page = makePage();
  page.hook.mounted();
  page.chip.fire('mouseenter');
  page.chip.fire('mouseleave'); // Same task: the frame has not run yet.
  assert.equal(page.frames.size, 0, 'the pending frame is cancelled');

  page.flushFrames(); // A browser may still dispatch an already-queued frame.
  assert.equal(page.hook.tipEl.classList.contains('is-visible'), false,
    'a cancelled frame can never resurrect the tooltip');
});

test('a blank data-tip is inert and never creates a node', () => {
  const page = makePage();
  page.hook.mounted();
  page.chip.dataset.tip = '';
  page.chip.fire('mouseenter');
  page.flushFrames();
  assert.deepEqual(page.created, []);
  assert.equal(page.hook.tipEl, null);
});

test('destroyed removes the listeners and the node for good', () => {
  const page = makePage();
  page.hook.mounted();
  page.chip.fire('mouseenter');
  page.flushFrames();
  const tip = page.hook.tipEl;

  page.hook.destroyed();
  assert.equal(tip.removed, true);
  assert.equal(page.hook.tipEl, null);
  assert.equal(page.frames.size, 0, 'no frame outlives the hook');
  assert.equal(page.chip.fire('mouseenter'), undefined);
  assert.equal(page.hook.tipEl, null, 'a late mouseenter on the detached hook is inert');
});
