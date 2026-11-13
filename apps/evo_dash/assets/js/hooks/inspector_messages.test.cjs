// No browser bundle or npm packages: run the real hook against a small DOM seam.
// node --test apps/evo_dash/assets/js/hooks/inspector_messages.test.cjs
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const source = readFileSync(`${__dirname}/inspector_messages.js`, 'utf8')
  .replace('export default InspectorMessages;', 'InspectorMessages;');
const ENTER = 'inspector-message-enter';

class Element {
  constructor(dataset = {}) {
    this.dataset = dataset;
    this.children = [];
    this.listeners = new Map();
    this.classes = new Set();
    this.classList = {
      add: (name) => this.classes.add(name),
      remove: (name) => this.classes.delete(name)
    };
  }
  append(...children) { this.children.push(...children); }
  remove(child) { this.children = this.children.filter((el) => el !== child); }
  contains(el) { return el === this || this.children.some((child) => child.contains(el)); }
  querySelectorAll(selector) {
    assert.equal(selector, '[data-inspector-message]');
    return this.children.flatMap((el) => [
      ...('inspectorMessage' in el.dataset ? [el] : []), ...el.querySelectorAll(selector)
    ]);
  }
  addEventListener(name, fn) {
    if (!this.listeners.has(name)) this.listeners.set(name, new Set());
    this.listeners.get(name).add(fn);
  }
  removeEventListener(name, fn) { this.listeners.get(name)?.delete(fn); }
  fire(name, target = this) { this.listeners.get(name)?.forEach((fn) => fn({target})); }
  listenerCount() { return [...this.listeners.values()].reduce((n, set) => n + set.size, 0); }
  set scrollTop(_value) { assert.fail('entry animation must not scroll'); }
  scrollTo() { assert.fail('entry animation must not scroll'); }
  scrollIntoView() { assert.fail('entry animation must not scroll'); }
}
const message = (key) => new Element({inspectorMessage: key});
const entered = (el) => el.classes.has(ENTER);

function mount({scope = 'local:agent-1', initial = [], reduce = false, matchMedia = true} = {}) {
  const root = new Element({inspectorScope: scope});
  root.append(...initial);
  const media = new Element();
  media.matches = reduce;
  let observer;
  class Observer {
    constructor(callback) { this.callback = callback; observer = this; }
    observe(el, options) { this.el = el; this.options = options; this.connected = true; }
    disconnect() { this.connected = false; }
  }
  const hook = vm.runInNewContext(source, {
    window: matchMedia ? {matchMedia(query) {
      assert.equal(query, '(prefers-reduced-motion: reduce)');
      return media;
    }} : {},
    MutationObserver: Observer
    // Deliberately no timers, rAF, scrolling helpers or polling APIs.
  });
  hook.el = root;
  hook.mounted();
  return {
    hook, root, media,
    get observer() { return observer; },
    flush() { if (observer.connected) observer.callback([]); },
    motion(reduced) { media.matches = reduced; media.fire('change'); }
  };
}

test('mount snapshot and repeated updates never animate existing entries', () => {
  const first = message('first');
  const nested = new Element();
  nested.append(message('nested'));
  const page = mount({initial: [first, nested]});
  page.hook.updated();
  page.flush();
  assert.equal(entered(first), false);
  assert.equal(entered(nested.children[0]), false);
  assert.equal(first.listenerCount(), 0);
  assert.equal(page.observer.el, page.root);
  assert.equal(page.observer.options.childList, true);
  assert.equal(page.observer.options.subtree, true);
  assert.deepEqual(Array.from(page.observer.options.attributeFilter),
    ['data-inspector-scope', 'data-inspector-message']);
});

test('new keys animate, including entries nested inside an appended subtree', () => {
  const page = mount();
  const group = new Element();
  const a = message('a');
  const b = message('b');
  group.append(a, b);
  page.root.append(group);
  page.flush();
  assert.equal(entered(a), true);
  assert.equal(entered(b), true);
  a.fire('animationend', new Element()); // A bubbled child animation is irrelevant.
  assert.equal(entered(a), true);
  a.fire('animationend');
  b.fire('animationcancel');
  assert.equal(entered(a), false);
  assert.equal(entered(b), false);
  assert.equal(a.listenerCount() + b.listenerCount(), 0);
  page.hook.updated();
  assert.equal(entered(a), false);
});

test('text/token patches, DOM replacement and reinsertion never replay a stable key', () => {
  const first = message('stable');
  const page = mount({initial: [first]});
  first.append(new Element()); // Represents a streamed text/Markdown subtree patch.
  page.flush();
  assert.equal(entered(first), false);
  page.root.remove(first);
  const replacement = message('stable');
  page.root.append(replacement);
  page.flush();
  assert.equal(entered(replacement), false);
  page.root.append(first);
  page.hook.updated();
  assert.equal(entered(first), false);
  assert.equal(first.listenerCount() + replacement.listenerCount(), 0);
});

test('an animated key cannot replay after settling, streaming or replacement', () => {
  const page = mount();
  const entry = message('new');
  page.root.append(entry);
  page.flush();
  assert.equal(entered(entry), true);
  entry.fire('animationend');
  entry.append(new Element());
  page.flush();
  page.hook.updated();
  assert.equal(entered(entry), false);
  page.root.remove(entry);
  const replacement = message('new');
  page.root.append(replacement);
  page.flush();
  assert.equal(entered(replacement), false);
  assert.equal(replacement.listenerCount(), 0);
});

test('scope changes baseline the complete snapshot before processing insertions', () => {
  const page = mount();
  const old = message('old');
  page.root.append(old);
  page.flush();
  assert.equal(entered(old), true);
  page.root.dataset.inspectorScope = 'remote:agent-2';
  const snapshot = message('snapshot');
  page.root.append(snapshot);
  page.hook.updated(); // LiveView updated may precede MutationObserver delivery.
  page.flush();
  assert.equal(entered(old), false);
  assert.equal(old.listenerCount(), 0);
  assert.equal(entered(snapshot), false);
  const next = message('next');
  page.root.append(next);
  page.flush();
  assert.equal(entered(next), true);
  page.root.dataset.inspectorScope = 'local:agent-1';
  page.flush(); // Observer alone also detects scope changes.
  assert.equal(entered(next), false);
});

test('empty scope is inert and becoming scoped seeds a baseline', () => {
  const page = mount({scope: ''});
  const entry = message('entry');
  page.root.append(entry);
  page.flush();
  assert.equal(entered(entry), false);
  page.root.dataset.inspectorScope = 'agent-1';
  page.flush();
  assert.equal(entered(entry), false);
  const fresh = message('fresh');
  page.root.append(fresh);
  page.flush();
  assert.equal(entered(fresh), true);
});

test('missing/empty markers are ignored; duplicate keys animate at most once', () => {
  const page = mount();
  const unmarked = new Element();
  const empty = message('');
  const a = message('arbitrary:"[] key');
  const duplicate = message('arbitrary:"[] key');
  page.root.append(unmarked, empty, a, duplicate);
  page.flush();
  assert.equal(entered(unmarked), false);
  assert.equal(entered(empty), false);
  assert.equal(entered(a), true);
  assert.equal(entered(duplicate), false);
});

test('reduced motion suppresses entries permanently and clears active animations on change', () => {
  const page = mount({reduce: true});
  const skipped = message('skipped');
  page.root.append(skipped);
  page.flush();
  assert.equal(entered(skipped), false);
  page.motion(false);
  page.hook.updated();
  assert.equal(entered(skipped), false);
  const next = message('next');
  page.root.append(next);
  page.flush();
  assert.equal(entered(next), true);
  page.motion(true);
  assert.equal(entered(next), false);
  assert.equal(next.listenerCount(), 0);
  page.motion(false);
  page.flush();
  assert.equal(entered(next), false);
});

test('removed and re-keyed active entries release animation listeners', () => {
  const page = mount();
  const removed = message('removed');
  const changed = message('before');
  page.root.append(removed, changed);
  page.flush();
  page.root.remove(removed);
  changed.dataset.inspectorMessage = 'after';
  page.flush();
  assert.equal(entered(removed), false);
  assert.equal(removed.listenerCount(), 0);
  assert.equal(entered(changed), true); // Changing identity explicitly means a new entry.
  assert.equal(changed.listenerCount(), 2);
  changed.fire('animationend');
  assert.equal(changed.listenerCount(), 0);
});

test('destroy disconnects observer and removes all listeners/classes, even from detached entries', () => {
  const page = mount();
  const a = message('a');
  const b = message('b');
  page.root.append(a, b);
  page.flush();
  page.root.remove(a); // Destroy before pending mutation delivery.
  page.hook.destroyed();
  assert.equal(page.observer.connected, false);
  assert.equal(a.listenerCount() + b.listenerCount() + page.media.listenerCount(), 0);
  assert.equal(entered(a), false);
  assert.equal(entered(b), false);
  assert.equal(page.hook.active.size, 0);
  assert.equal(page.hook.seen, null);
  page.hook.updated();
  page.hook.destroyed(); // Teardown remains safe when repeated.
});

test('missing matchMedia and empty wrappers are supported', () => {
  const page = mount({matchMedia: false});
  const entry = message('entry');
  page.root.append(entry);
  page.hook.updated();
  assert.equal(entered(entry), true);
  page.hook.destroyed();
});
