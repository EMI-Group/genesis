// Run with: node --test apps/evo_dash/assets/js/state_persistence.test.cjs
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

// Exercise the actual inline hook without importing the browser-only app bundle.
const app = readFileSync(`${__dirname}/app.js`, 'utf8');
const hookSource = app.slice(app.indexOf('const StatePersistence = {'),
  app.indexOf('// BrowserNotifications hook:'));

function mount({state, node = 'local', legacyModel} = {}) {
  let saved = state === undefined ? null : JSON.stringify(state);
  const events = {};
  const listeners = {};
  const prompt = {value: ''};
  const pushed = [];
  let timer;
  const context = vm.createContext({
    sessionStorage: {
      getItem(key) { assert.equal(key, 'dashboard_state'); return saved; },
      setItem(key, value) { assert.equal(key, 'dashboard_state'); saved = value; }
    },
    clearTimeout() { timer = null; },
    setTimeout(fn) { timer = fn; }
  });
  const hook = vm.runInContext(`${hookSource}\nStatePersistence;`, context);
  Object.assign(hook, {
    el: {
      dataset: {nodeId: node, project: '/repo', taskMode: 'evolve_simple'},
      querySelector(selector) {
        if (selector === '[name="prompt"]') return prompt;
        if (selector === '[name="model_id"]') return legacyModel;
        return null;
      },
      addEventListener(name, fn) { listeners[name] = fn; }
    },
    handleEvent(name, fn) { events[name] = fn; },
    pushEvent(name, payload) { pushed.push({name, payload}); }
  });
  hook.mounted();
  return {
    events, prompt, pushed,
    read() { return saved === null ? null : JSON.parse(saved); },
    change(name, type = 'input') {
      listeners[type]({target: {getAttribute() { return name; }}});
    },
    flush() { const fn = timer; timer = null; fn(); }
  };
}

const spec = {provider_profile_id: 'provider-one', model: 'model-one', reasoning_effort: 'high'};

test('matching-node picker update merges only selection and preserves saved prompt/fields', () => {
  const state = {node: 'remote-a', task_prompt: 'saved draft', foreign_repos: [{id: 'other'}]};
  const page = mount({node: 'remote-a', state});
  page.prompt.value = 'new unsaved typing';
  page.events.persist_model_selection({node: 'remote-a', model_spec: spec});
  assert.deepEqual(page.read(), {...state, model_spec: spec});
  assert.equal(page.prompt.value, 'new unsaved typing');
});

test('explicit empty canonical Auto survives prompt watcher and remount restore', () => {
  const page = mount({state: {node: 'local', selected_model_id: 'stale-legacy', model_spec: spec}});
  page.events.persist_model_selection({node: 'local', model_spec: {}});
  page.prompt.value = 'typed draft';
  page.change('prompt');
  page.flush();
  const saved = page.read();
  assert.deepEqual(saved.model_spec, {});
  assert.equal(saved.selected_model_id, 'stale-legacy');
  assert.equal(saved.task_prompt, 'typed draft');
  const restored = mount({state: saved});
  assert.deepEqual(JSON.parse(JSON.stringify(restored.pushed[0])), {name: 'restore_state', payload: saved});
});

test('stale event for another node is ignored', () => {
  const state = {node: 'remote-b', task_prompt: 'keep', model_spec: spec};
  const page = mount({node: 'remote-b', state});
  page.events.persist_model_selection({node: 'remote-a', model_spec: {}});
  assert.deepEqual(page.read(), state);
});

test('current-node update does not relabel another node pending in storage', () => {
  const state = {node: 'remote-a', task_prompt: 'pending restore', model_spec: spec};
  const page = mount({node: 'local', state});
  page.events.persist_model_selection({node: 'local', model_spec: {}});
  assert.deepEqual(page.read(), state);
});

test('selection can initialize empty storage, including Auto on a remote node', () => {
  const page = mount({node: 'remote-a'});
  page.events.persist_model_selection({node: 'remote-a', model_spec: {}});
  assert.deepEqual(page.read(), {node: 'remote-a', model_spec: {}});
});

test('node-less legacy state belongs to local and is not relabeled as remote', () => {
  const state = {task_prompt: 'legacy draft', selected_model_id: 'legacy'};
  const remote = mount({node: 'remote-a', state});
  remote.events.persist_model_selection({node: 'remote-a', model_spec: spec});
  assert.deepEqual(remote.read(), state);
  const local = mount({state});
  local.events.persist_model_selection({node: 'local', model_spec: spec});
  assert.deepEqual(local.read(), {...state, node: 'local', model_spec: spec});
});

test('absent legacy selector never creates an empty legacy id or drops canonical spec', () => {
  const page = mount({state: {node: 'local', model_spec: spec}});
  page.change('prompt');
  page.events.persist_model_selection({node: 'local', model_spec: {}});
  page.flush();
  assert.equal(Object.hasOwn(page.read(), 'selected_model_id'), false);
  assert.deepEqual(page.read().model_spec, {});
});

test('full-state pushes keep the DOM prompt and canonical Auto', () => {
  const page = mount();
  page.prompt.value = 'unsent typing';
  page.events.persist_state({node: 'local', task_prompt: 'stale server draft', model_spec: {}});
  assert.deepEqual(page.read(), {node: 'local', task_prompt: 'unsent typing', model_spec: {}});
});

test('present legacy selector still persists explicit empty Auto and selected ids', () => {
  const legacyModel = {value: ''};
  const page = mount({legacyModel});
  page.change('model_id', 'change');
  page.flush();
  assert.equal(page.read().selected_model_id, '');
  legacyModel.value = 'legacy-profile';
  page.change('model_id', 'change');
  page.flush();
  assert.equal(page.read().selected_model_id, 'legacy-profile');
});
