// Run with: node --test apps/evo_dash/assets/js/state_persistence.test.cjs
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

// Exercise the actual inline hook without importing the browser-only app bundle.
const app = readFileSync(`${__dirname}/app.js`, 'utf8');
const hookSource = app.slice(app.indexOf('const StatePersistence = {'),
  app.indexOf('// ClipboardCopy hook:'));

function mount({state, node = 'local', project = '/repo', taskDraftProject, taskDraftScope,
  legacyModel, storage = new Map()} = {}) {
  if (state !== undefined) storage.set('dashboard_state', JSON.stringify(state));
  const events = {};
  const listeners = {};
  const prompt = {value: ''};
  const pushed = [];
  let timer;
  const context = vm.createContext({
    sessionStorage: {
      getItem(key) { return storage.get(key) ?? null; },
      setItem(key, value) { storage.set(key, value); }
    },
    clearTimeout() { timer = null; },
    setTimeout(fn) { timer = fn; }
  });
  const hook = vm.runInContext(`${hookSource}\nStatePersistence;`, context);
  Object.assign(hook, {
    el: {
      dataset: {nodeId: node, project, taskDraftProject, taskDraftScope,
        taskMode: 'evolve_simple'},
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
    read(key = 'dashboard_state') { return JSON.parse(storage.get(key) ?? null); },
    navigate(dataset) { Object.assign(hook.el.dataset, dataset); hook.updated(); },
    destroy() { hook.destroyed(); },
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

test('project drafts restore only for the matching node and project', () => {
  const storage = new Map();
  const projectA = {node: 'remote-a', taskDraftProject: '/a', storage};
  const initial = {node: 'remote-a', project: '/a', task_prompt: 'project A draft'};
  const page = mount({...projectA, state: initial});
  assert.equal(page.prompt.value, 'project A draft');
  page.prompt.value = 'edited draft';
  page.change('prompt');
  page.destroy();

  assert.equal(mount({...projectA, taskDraftProject: '/b'}).prompt.value, '');
  assert.equal(mount({...projectA, node: 'remote-b'}).prompt.value, '');
  assert.equal(mount(projectA).prompt.value, 'edited draft');
});

test('switching and clearing a task draft preserve the other project', () => {
  const storage = new Map();
  const page = mount({storage, taskDraftProject: '/a'});
  page.prompt.value = 'project A draft';
  page.change('prompt');
  page.navigate({taskDraftProject: '/b'});
  assert.equal(page.prompt.value, '');

  page.events.persist_model_selection({node: 'local', project: '/a', model_spec: spec});
  assert.equal(page.read('dashboard_state:["local","/b"]'), null);
  page.prompt.value = 'submitted text';
  page.change('prompt');
  page.events.clear_prompt();

  assert.equal(mount({storage, taskDraftProject: '/a'}).prompt.value, 'project A draft');
  assert.equal(mount({storage, taskDraftProject: '/b'}).prompt.value, '');
});

test('two VCT points over one path keep separate drafts', () => {
  const storage = new Map();
  const first = mount({storage, taskDraftProject: '/repo', taskDraftScope: 'vct:///projects/one'});
  first.prompt.value = 'draft for point one';
  first.change('prompt');
  first.flush();
  assert.equal(first.read('dashboard_state:["local","vct:///projects/one"]').scope_token,
    'vct:///projects/one');

  // Same OS path, different point: a different project as far as drafts are concerned.
  assert.equal(mount({storage, taskDraftProject: '/repo',
    taskDraftScope: 'vct:///projects/two'}).prompt.value, '');
  assert.equal(mount({storage, taskDraftProject: '/repo',
    taskDraftScope: 'vct:///projects/one'}).prompt.value, 'draft for point one');
});

test('one VCT point restores its draft under a different path spelling', () => {
  const storage = new Map();
  const page = mount({storage, taskDraftProject: '/repo', taskDraftScope: 'vct:///projects/foo'});
  page.prompt.value = 'pointed draft';
  page.change('prompt');
  page.flush();

  // A symlink, a second mount or a workspace member: the point wins over the path.
  const reopened = mount({storage, taskDraftProject: '/repo-symlink',
    taskDraftScope: 'vct:///projects/foo'});
  assert.equal(reopened.prompt.value, 'pointed draft');
  assert.deepEqual(JSON.parse(JSON.stringify(reopened.pushed[0])), {
    name: 'restore_state',
    payload: {node: 'local', project: '/repo', task_prompt: 'pointed draft',
      task_mode: 'evolve_simple', task_node_path: '', task_seeds: '',
      task_starting_commit: '', scope_token: 'vct:///projects/foo'}
  });
});

test('a legacy path-keyed draft is adopted once the project gains its VCT point', () => {
  const storage = new Map();
  const legacy = {node: 'local', project: '/repo', task_prompt: 'typed before the point'};
  storage.set('dashboard_state:["local","/repo"]', JSON.stringify(legacy));

  const page = mount({storage, taskDraftProject: '/repo', taskDraftScope: 'vct:///projects/foo'});
  assert.equal(page.prompt.value, 'typed before the point');
  assert.deepEqual(JSON.parse(JSON.stringify(page.pushed[0])),
    {name: 'restore_state', payload: legacy});
});

test('a draft written before the VCT point is known is adopted once the point arrives, keeping every saved field', () => {
  const storage = new Map();
  const pathKey = 'dashboard_state:["local","/repo"]';
  // The first frame of a page load has no async VCT mount yet, so its stamp is
  // the raw path itself — the same value as the state's own project.
  const page = mount({storage, taskDraftProject: '/repo'});
  page.prompt.value = 'typed before the point';
  page.events.persist_state({node: 'local', project: '/repo', task_mode: 'evolve_simple',
    task_archive: true, task_prompt: 'typed before the point'});
  const stored = page.read(pathKey);
  assert.deepEqual(stored, {node: 'local', project: '/repo', task_mode: 'evolve_simple',
    task_archive: true, task_prompt: 'typed before the point', scope_token: '/repo'});

  page.navigate({taskDraftScope: 'vct:///projects/foo'});
  assert.deepEqual(JSON.parse(JSON.stringify(page.pushed)),
    [{name: 'restore_state', payload: stored}]);
  assert.equal(page.prompt.value, 'typed before the point');
  assert.equal(page.read(pathKey).task_mode, 'evolve_simple');
  assert.equal(page.read(pathKey).task_archive, true);
});

test('a real VCT stamp never matches a different point', () => {
  const storage = new Map();
  storage.set('dashboard_state:["local","/repo"]', JSON.stringify({node: 'local',
    project: '/repo', task_prompt: 'point one draft', scope_token: 'vct:///projects/foo'}));

  // Same project path, different point: the stamp decides, not the path.
  const page = mount({storage, taskDraftProject: '/repo', taskDraftScope: 'vct:///projects/bar'});
  assert.equal(page.prompt.value, '');
  assert.deepEqual(page.pushed, []);
});

test('a workspace stamp stays separate from the project path draft', () => {
  const storage = new Map();
  storage.set('dashboard_state:["local","/repo"]', JSON.stringify({node: 'local',
    project: '/repo', task_prompt: 'workspace draft', scope_token: 'vct:///workspaces/dev'}));

  const page = mount({storage, taskDraftProject: '/repo'});
  assert.equal(page.prompt.value, '');
  assert.deepEqual(page.pushed, []);
});

test('typing survives the moment a project gains its VCT point', () => {
  const storage = new Map();
  const page = mount({storage, taskDraftProject: '/repo'});
  page.prompt.value = 'in-flight typing';
  page.change('prompt');
  page.navigate({taskDraftScope: 'vct:///projects/foo'});

  // Flushed under the path scope it was typed in, and never cleared from the DOM.
  assert.equal(page.prompt.value, 'in-flight typing');
  assert.equal(page.read('dashboard_state:["local","/repo"]').task_prompt, 'in-flight typing');
});

test('a VCT-scoped draft never restores or persists on another node', () => {
  const storage = new Map();
  const remoteA = mount({storage, node: 'remote-a', taskDraftProject: '/repo',
    taskDraftScope: 'vct:///projects/foo'});
  remoteA.prompt.value = 'remote A draft';
  remoteA.change('prompt');
  remoteA.destroy();
  const key = 'dashboard_state:["remote-a","vct:///projects/foo"]';
  const saved = storage.get(key);

  const remoteB = mount({storage, node: 'remote-b', taskDraftProject: '/repo',
    taskDraftScope: 'vct:///projects/foo'});
  assert.equal(remoteB.prompt.value, '');
  remoteB.events.persist_model_selection({node: 'remote-a', model_spec: spec});
  assert.equal(storage.get(key), saved);
});
