const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const source = readFileSync(`${__dirname}/dialog_modal.js`, 'utf8')
  .replace('export default DialogModal;', 'DialogModal;');

function mount({api = 'native', heading = true, hiddenHeading = false, rejectedHeadingFocus = false, unsafeTarget = false, alreadyOpen = false, animated = false} = {}) {
  const document = {activeElement: null};
  const nodes = new Map();
  function node(tag, {id = '', inside = false, action = false, visible = true} = {}) {
    const attributes = new Map();
    const listeners = new Map();
    const classes = new Set();
    const element = {
      id, inside, action, visible, isConnected: true, disabled: false, listeners, attributes,
      classList: {add: value => classes.add(value), remove: value => classes.delete(value), contains: value => classes.has(value)},
      setAttribute(name, value) { attributes.set(name, value); if (name === 'open') this.open = true; },
      getAttribute: name => attributes.get(name) ?? null,
      hasAttribute: name => attributes.has(name),
      removeAttribute(name) { attributes.delete(name); if (name === 'open') this.open = false; },
      getClientRects() { return this.visible && (!inside || el.open) ? [{}] : []; },
      closest(selector) {
        if (selector.includes('[hidden]')) return this.hidden || this.inert ? this : null;
        return this.action ? this : null;
      },
      matches(selector) { return selector.split(', ').includes(tag); },
      querySelector: () => null,
      focus(options) { assert.equal(options.preventScroll, true); document.activeElement = this; },
      addEventListener(name, fn) { listeners.set(name, fn); },
      removeEventListener(name, fn) { assert.equal(listeners.get(name), fn); listeners.delete(name); }
    };
    if (id) nodes.set(id, element);
    return element;
  }
  const opener = node('button', {id: 'review-button'});
  const body = node('body');
  document.body = body;
  document.activeElement = opener;
  document.getElementById = id => nodes.get(id);
  document.querySelector = () => opener;
  const el = node('dialog', {id: 'approval-dialog'});
  el.contains = element => !!element && (element === el || element.inside);
  el.open = alreadyOpen;
  if (alreadyOpen) el.setAttribute('open', '');
  // `animated` adds the node the hook actually watches: both phases wait for a
  // target-verified animationend on `.modal-box` (motion.css section 9), which
  // only exists alongside the reduced-motion bridge every real page provides.
  const box = node('div', {inside: true});
  if (animated) el.querySelector = selector => (selector === '.modal-box' ? box : null);
  const title = node('h2', {inside: true, visible: !hiddenHeading});
  if (rejectedHeadingFocus) title.focus = () => {}; // visibility:hidden can retain layout boxes.
  const allow = node('button', {inside: true, action: true});
  const deny = node('button', {inside: true, action: true});
  el.querySelectorAll = () => [...(unsafeTarget ? [allow, deny] : []), ...(heading ? [title] : [])];
  let shows = 0;
  let closes = 0;
  if (api !== 'absent') el.showModal = () => {
    shows++;
    if (api === 'throw') throw new Error('WebView unavailable');
    assert.equal(el.open, false);
    el.setAttribute('open', '');
    // Simulate unsafe native autofocus; the hook must replace it before returning.
    document.activeElement = allow;
  };
  el.close = () => {
    closes++;
    if (api === 'broken-close') throw new Error('partial implementation');
    el.removeAttribute('open');
    el.listeners.get('close')?.({});
  };
  const pushes = [];
  const events = new Map();
  // Fake timers: the animated path arms its bounded fallback, so a test must be
  // able to prove the animationend cancelled it instead of waiting 200 ms.
  const timers = [];
  const sandbox = {document};
  if (animated) {
    sandbox.genesisMotion = {prefersReducedMotion: () => false};
    sandbox.setTimeout = (fn, ms) => { const timer = {fn, ms, cleared: false}; timers.push(timer); return timer; };
    sandbox.clearTimeout = timer => { if (timer) timer.cleared = true; };
  }
  const hook = vm.runInNewContext(source, sandbox);
  Object.assign(hook, {
    el,
    handleEvent(name, fn) { events.set(name, fn); return name; },
    removeHandleEvent(ref) { events.delete(ref); },
    pushEvent(name, payload) { pushes.push(JSON.parse(JSON.stringify({name, payload}))); }
  });
  function fire(name, extras = {}) {
    if (name === 'close') el.removeAttribute('open'); // A genuine native close is no longer open.
    const event = {prevented: false, stopped: false, target: el,
      preventDefault() { this.prevented = true; }, stopPropagation() { this.stopped = true; }, ...extras};
    el.listeners.get(name)?.(event);
    return event;
  }
  hook.mounted();
  return {hook, el, title, allow, deny, opener, document, pushes, events, fire, node, box, timers,
    shows: () => shows, closes: () => closes};
}

function onlyDismissal(page) {
  assert.deepEqual(page.pushes, [{name: 'dialog_closed', payload: {}}]);
}

test('native dialog focuses static review content, labels it, and never focuses Allow/Deny initially', () => {
  const page = mount({unsafeTarget: true});
  assert.equal(page.shows(), 1);
  assert.equal(page.document.activeElement, page.title);
  assert.equal(page.title.getAttribute('tabindex'), '-1');
  assert.equal(page.el.getAttribute('aria-labelledby'), page.title.id);
  assert.equal(page.el.getAttribute('aria-modal'), 'true');
  assert.equal(page.el.getAttribute('role'), 'dialog');
  assert.deepEqual(page.pushes, []);
});

test('missing, hidden or unsafe-only review target focuses container, never decision controls', () => {
  for (const options of [{heading: false}, {hiddenHeading: true}, {rejectedHeadingFocus: true}, {heading: false, unsafeTarget: true}]) {
    const page = mount(options);
    assert.equal(page.document.activeElement, page.el);
    assert.equal(page.el.getAttribute('tabindex'), '-1');
    assert.deepEqual(page.pushes, []);
  }
});

test('patches preserve focused controls and accessible naming; stripped open is reasserted safely', () => {
  const page = mount();
  page.document.activeElement = page.deny;
  page.hook.updated();
  assert.equal(page.shows(), 1);
  assert.equal(page.document.activeElement, page.deny);
  page.el.removeAttribute('open');
  page.title.id = '';
  page.hook.updated();
  assert.equal(page.shows(), 2);
  assert.equal(page.document.activeElement, page.deny);
  assert.equal(page.el.getAttribute('aria-labelledby'), page.title.id);
  page.el.setAttribute('aria-label', 'Translated review name');
  page.hook.updated();
  assert.equal(page.el.getAttribute('aria-label'), 'Translated review name');
});

test('already open dialog is never passed to showModal twice', () => {
  const page = mount({alreadyOpen: true});
  page.hook.updated();
  assert.equal(page.shows(), 0);
  assert.equal(page.document.activeElement, page.title);
});

test('absent/throwing modal API exposes visible non-inert, honestly nonmodal review fallback', () => {
  for (const api of ['absent', 'throw']) {
    const page = mount({api});
    assert.equal(page.el.open, true);
    assert.equal(page.el.classList.contains('modal-open'), true);
    assert.equal(page.el.getAttribute('aria-modal'), 'false');
    assert.equal(page.el.getAttribute('data-dialog-mode'), 'fallback');
    assert.equal(page.el.hasAttribute('inert'), false);
    assert.equal(page.document.activeElement, page.title);
    page.el.removeAttribute('open');
    page.el.classList.remove('modal-open');
    page.hook.updated();
    assert.equal(page.el.open, true);
    assert.equal(page.el.classList.contains('modal-open'), true);
    assert.equal(page.shows(), api === 'throw' ? 1 : 0);
    const event = page.fire('keydown', {key: 'Escape'});
    assert.equal(event.prevented, true);
    assert.equal(page.el.open, false);
    assert.equal(page.el.classList.contains('modal-open'), false);
    onlyDismissal(page);
    assert.equal(page.document.activeElement, page.opener);
  }
});

test('native cancel/close races report dismissal once, updates cannot reopen, explicit reopen can', () => {
  const page = mount();
  assert.equal(page.fire('cancel').prevented, true);
  page.fire('close');
  page.fire('cancel');
  page.hook.updated();
  assert.equal(page.el.open, false);
  assert.equal(page.shows(), 1);
  onlyDismissal(page);
  assert.equal(page.document.activeElement, page.opener);
  page.events.get('dialog_open')();
  assert.equal(page.shows(), 2);
  assert.equal(page.document.activeElement, page.title);
  page.el.listeners.get('close')({}); // Delayed close from the previous presentation.
  assert.equal(page.el.open, true);
  onlyDismissal(page);
  page.fire('close');
  assert.equal(page.pushes.length, 2);
});

test('legacy close, marked dismiss and backdrop clicks/submits are review-only and latched', () => {
  for (const api of ['native', 'absent']) {
    for (const controlType of ['legacy', 'marked', 'backdrop', 'submit']) {
      const page = mount({api});
      const control = page.node('button', {inside: true});
      let event;
      if (controlType === 'submit') {
        control.matches = selector => selector === 'form.modal-backdrop[method="dialog"]';
        event = page.fire('submit', {target: control});
      } else {
        event = page.fire('click', {target: {closest(selector) {
          assert.ok(selector.includes(controlType === 'legacy' ? '[phx-click="dialog_closed"]' : controlType === 'marked' ? '[data-dialog-dismiss]' : '.modal-backdrop button'));
          return control;
        }}});
      }
      assert.equal(event.prevented, true);
      assert.equal(event.stopped, true);
      page.fire('close');
      onlyDismissal(page);
    }
  }
});

test('decision clicks, Enter, composing Escape, unrelated forms and outside clicks are not interpreted', () => {
  const page = mount({api: 'absent'});
  for (const target of [page.allow, page.deny, {closest: () => null}, {closest: () => page.opener}]) {
    // Real action buttons do not match any dismissal selector.
    if (target === page.allow || target === page.deny) target.closest = () => null;
    assert.equal(page.fire('click', {target}).prevented, false);
  }
  assert.equal(page.fire('keydown', {key: 'Enter'}).prevented, false);
  assert.equal(page.fire('keydown', {key: 'Escape', isComposing: true}).prevented, false);
  assert.equal(page.fire('submit', {target: {matches: () => false}}).prevented, false);
  assert.deepEqual(page.pushes, []);
});

test('focus restoration uses explicit target, skips disconnected/hidden/disabled targets and never steals outside focus', () => {
  const page = mount();
  const target = page.node('button', {id: 'review-return'});
  page.el.setAttribute('data-dialog-return-focus', target.id);
  page.fire('cancel');
  assert.equal(page.document.activeElement, target);
  for (const mutate of [target => { target.isConnected = false; }, target => { target.hidden = true; }, target => { target.disabled = true; }]) {
    const page = mount();
    const target = page.node('button', {id: 'return'});
    page.el.setAttribute('data-dialog-return-focus', target.id);
    mutate(target);
    page.fire('cancel');
    assert.equal(page.document.activeElement, page.opener);
  }
  const outside = mount();
  const other = outside.node('button');
  outside.document.activeElement = other;
  outside.fire('close');
  assert.equal(outside.document.activeElement, other);
});

test('server teardown closes and restores without a dismissal, removes handlers, late reopen is inert', () => {
  for (const api of ['native', 'absent', 'broken-close']) {
    const page = mount({api});
    const lateOpen = page.events.get('dialog_open');
    page.hook.destroyed();
    assert.equal(page.el.open, false);
    assert.equal(page.el.classList.contains('modal-open'), false);
    assert.equal(page.document.activeElement, page.opener);
    assert.equal(page.el.listeners.size, 0);
    assert.equal(page.events.size, 0);
    lateOpen();
    page.hook.updated();
    assert.equal(page.el.open, false);
    assert.deepEqual(page.pushes, []);
  }
});

test('both phases animate the .modal-box panel the hook watches, never the dialog', () => {
  const page = mount({animated: true});
  const boxEnd = event => page.box.listeners.get('animationend')({target: event});

  // Entry: the phase stays "opening" until the BOX itself finishes; a child
  // animation bubbling through the box (or the ::backdrop, dispatched at the
  // dialog) must never settle it early.
  assert.equal(page.el.getAttribute('data-dialog-state'), 'opening');
  boxEnd(page.allow);
  assert.equal(page.el.getAttribute('data-dialog-state'), 'opening');
  boxEnd(page.box);
  assert.equal(page.el.getAttribute('data-dialog-state'), 'open');

  // Exit: same watched node, and the dialog stays open until it finishes.
  page.fire('cancel');
  assert.equal(page.el.getAttribute('data-dialog-state'), 'closing');
  boxEnd(page.allow);
  assert.equal(page.el.getAttribute('data-dialog-state'), 'closing');
  assert.equal(page.el.open, true);
  boxEnd(page.box);
  assert.equal(page.el.getAttribute('data-dialog-state'), null);
  assert.equal(page.el.open, false);
  assert.equal(page.box.listeners.size, 0, 'the listener is released on completion');
  assert.ok(page.timers.length > 0 && page.timers.every(timer => timer.cleared),
    'every bounded fallback is cancelled by the animationend');
  onlyDismissal(page);
});
