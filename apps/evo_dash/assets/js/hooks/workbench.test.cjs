// Run with: node --test apps/evo_dash/assets/js/hooks/workbench.test.cjs
//
// Exercises the PURE patch-sync probe behind `Workbench.updated()` — "does the
// O(the whole shell) sweep have to re-run after this LiveView patch?" — without
// a browser bundle. The sweep itself (the tab rail, every history row's current
// marker, the panel states, the sidebar widths, the Git label, the create menu)
// carries no decision of its own; it only executes the plan this probe returns,
// which is why the DOM half needs no seam here.
//
// Matching the sidebar_collapse.test.cjs convention, the block between the
// source's markers is sliced out and run through node:vm, so the real shipped
// code is what is measured — and the slice runs in a context with NO globals,
// so a probe that started reaching for `document` would throw instead of
// silently passing.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const src = readFileSync(`${__dirname}/workbench.js`, 'utf8');
const start = src.indexOf('// --- Workbench: pure sync probe');
// The block's own end marker: the comment line right after it, above the hook.
const end = src.indexOf('// Workbench hook:', start);
assert.ok(start !== -1 && end > start, 'pure sync probe block not found in workbench.js');
const source = src.slice(start, end);
const {workbenchSyncNeeded, syncStateSignature} = vm.runInContext(
  `${source}\n({workbenchSyncNeeded, syncStateSignature});`,
  vm.createContext({})
);

// One coherent probe state: exactly what the DOM half builds after a sweep
// (the layout dataset, the Git pane's own inputs, the sidebar flags the empty
// state reads, the JS-written re-render marker and the list shapes).
function cleanState(overrides = {}) {
  return {
    dataset: {
      workbenchNode: 'local',
      workbenchProject: '/tmp/project',
      workbenchTask: '',
      workbenchSession: '',
      workbenchDraft: '',
      workbenchDraftProject: '',
      workbenchPage: 'dashboard',
      workbenchTitle: 'Draft subject',
      workbenchDefaultDraft: '/assistant?wb_project=/tmp/project&wb_draft=1234567890abcdef12345678',
      workbenchGitBranch: 'main',
      workbenchStartingCommit: 'abc123',
    },
    git: {diff: undefined, head: 'main', scope: '/?project=%2Ftmp%2Fproject', target: 'ssh'},
    projectsLoading: undefined,
    historyEmpty: undefined,
    accent: 'blue',
    tabsMarked: '["task-1",[]]',
    lists: [
      {name: 'items', count: 3, head: 'task-1', tail: 'task-3'},
      {name: 'projects', count: 2, head: '/tmp/a', tail: '/tmp/project'},
    ],
    ...overrides,
  };
}

// A fresh object graph with the same content (JSON drops `undefined` values,
// which the signature normalises away — that is part of the contract).
function copy(state) {
  return JSON.parse(JSON.stringify(state));
}

test('the very first run always sweeps — nothing has been applied yet', () => {
  assert.equal(workbenchSyncNeeded(cleanState(), undefined), true);
  assert.equal(workbenchSyncNeeded({}, undefined), true);
  // An omitted remembered state is the same case.
  assert.equal(workbenchSyncNeeded(cleanState()), true);
});

test('identical inputs decide identically — repeated patches cost no sweep', () => {
  const state = cleanState();
  assert.equal(workbenchSyncNeeded(state, state), false);
  assert.equal(workbenchSyncNeeded(state, copy(state)), false);
  assert.equal(workbenchSyncNeeded(copy(state), state), false);
  // Key order is not part of the signature.
  const reordered = cleanState();
  reordered.dataset = {
    workbenchStartingCommit: 'abc123',
    workbenchGitBranch: 'main',
    workbenchPage: 'dashboard',
    workbenchDraftProject: '',
    workbenchDraft: '',
    workbenchSession: '',
    workbenchTask: '',
    workbenchProject: '/tmp/project',
    workbenchTitle: state.dataset.workbenchTitle,
    workbenchDefaultDraft: state.dataset.workbenchDefaultDraft,
    workbenchNode: 'local',
  };
  assert.equal(workbenchSyncNeeded(reordered, state), false);
  // A missing field and an empty one are the same input.
  delete reordered.dataset.workbenchTask;
  assert.equal(workbenchSyncNeeded(reordered, state), false);
});

test('every captured dataset field is a signal (navigation must still sweep)', () => {
  const base = cleanState();
  for (const key of Object.keys(base.dataset)) {
    const changed = cleanState();
    changed.dataset = {...base.dataset, [key]: `${base.dataset[key]}-changed`};
    assert.equal(workbenchSyncNeeded(changed, base), true, `${key} change must sweep`);
    const cleared = cleanState();
    cleared.dataset = {...base.dataset};
    delete cleared.dataset[key];
    if (base.dataset[key] !== '') {
      assert.equal(workbenchSyncNeeded(cleared, base), true, `${key} removal must sweep`);
    }
  }
});

test('the Git pane inputs are signals — the diff tab, its label and its refresh scope', () => {
  const base = cleanState();
  for (const [key, value] of [['diff', 'Fix login'], ['head', 'feature-x'], ['scope', '/?project=%2Fother'], ['target', 'local']]) {
    assert.equal(
      workbenchSyncNeeded(cleanState({git: {...base.git, [key]: value}}), base),
      true,
      `git.${key} change must sweep`
    );
  }
  // A diff OPENING (undefined → title) is the case that creates the diff tab.
  assert.equal(workbenchSyncNeeded(cleanState({git: {...base.git, diff: 'Fix login'}}), base), true);
  assert.equal(workbenchSyncNeeded(base, cleanState({git: {...base.git, diff: 'Fix login'}})), true);
});

test('the accent marker is a signal — a re-render that drops or reverts it is dirty', () => {
  const base = cleanState();
  assert.equal(workbenchSyncNeeded(cleanState({accent: 'emerald'}), base), true);
  // morphdom reset / re-rendered layout: the JS-applied value is gone.
  assert.equal(workbenchSyncNeeded(cleanState({accent: undefined}), base), true);
  assert.equal(workbenchSyncNeeded(base, cleanState({accent: undefined})), true);
  // Both stripped is stable again (nothing to re-apply in either patch).
  assert.equal(
    workbenchSyncNeeded(cleanState({accent: undefined}), cleanState({accent: undefined})),
    false
  );
});

test('a re-created tab rail (its JS marker gone) is dirty', () => {
  const base = cleanState();
  assert.equal(workbenchSyncNeeded(cleanState({tabsMarked: undefined}), base), true);
  assert.equal(workbenchSyncNeeded(cleanState({tabsMarked: '["task-2",[]]'}), base), true);
});

test('the list shapes are signals — count, head, tail and which list', () => {
  const base = cleanState();
  const items = base.lists[0];
  // Replace ONE list in an otherwise identical pair.
  const withItems = (next) => cleanState({lists: [next, base.lists[1]]});
  assert.equal(workbenchSyncNeeded(withItems({...items, count: 4}), base), true);
  assert.equal(workbenchSyncNeeded(withItems({...items, head: 'task-0'}), base), true);
  assert.equal(workbenchSyncNeeded(withItems({...items, tail: 'task-9'}), base), true);
  assert.equal(workbenchSyncNeeded(withItems({...items, name: 'projects'}), base), true);
  // A list that appeared, disappeared, or became empty.
  assert.equal(workbenchSyncNeeded(cleanState({lists: [base.lists[1]]}), base), true);
  assert.equal(workbenchSyncNeeded(cleanState({lists: []}), base), true);
  assert.equal(
    workbenchSyncNeeded(withItems({name: 'items', count: 0}), base),
    true
  );
  // A "Load more" button at the tail (no item id) still moves the tail/count.
  assert.equal(workbenchSyncNeeded(withItems({...items, count: 4, tail: undefined}), base), true);
  // The recency-ordered project list: a project mounted at the head.
  const projects = base.lists[1];
  assert.equal(
    workbenchSyncNeeded(cleanState({lists: [items, {...projects, count: 3, head: '/tmp/new'}]}), base),
    true
  );
});

test('the sidebar flags the empty state reads are signals', () => {
  const base = cleanState();
  assert.equal(workbenchSyncNeeded(cleanState({projectsLoading: 'true'}), base), true);
  assert.equal(workbenchSyncNeeded(cleanState({historyEmpty: 'true'}), base), true);
  // Both set on both sides is stable — a re-assert, not a change.
  assert.equal(
    workbenchSyncNeeded(
      cleanState({projectsLoading: 'false', historyEmpty: 'false'}),
      cleanState({projectsLoading: 'false', historyEmpty: 'false'})
    ),
    false
  );
});

test('the probe is total — absent or partial inputs never throw', () => {
  assert.equal(workbenchSyncNeeded(null, cleanState()), false);
  assert.equal(workbenchSyncNeeded(undefined, undefined), false);
  assert.equal(workbenchSyncNeeded({}, {}), false);
  assert.equal(workbenchSyncNeeded({dataset: null, git: null, lists: null}, cleanState()), true);
  assert.equal(workbenchSyncNeeded({dataset: null, git: null, lists: null}, {dataset: null}), false);
  assert.equal(workbenchSyncNeeded(cleanState({lists: 'nope'}), cleanState({lists: 'nope'})), false);
  assert.equal(workbenchSyncNeeded(cleanState({lists: [null]}), cleanState({lists: [null]})), false);
  assert.equal(syncStateSignature(undefined), '');
  assert.equal(typeof syncStateSignature(cleanState()), 'string');
  // Numbers/booleans where strings are expected are normalised, not thrown on.
  assert.equal(workbenchSyncNeeded({dataset: {workbenchTask: 7}}, {dataset: {workbenchTask: '7'}}), false);
});

test('the slice is DOM-free by construction — it ran with no globals at all', () => {
  // `vm.createContext({})` above has no `document`, `window` or `matchMedia`;
  // reaching for one from any exercised path would have thrown a ReferenceError
  // before this point.
  assert.equal(typeof workbenchSyncNeeded, 'function');
  assert.equal(typeof syncStateSignature, 'function');
});
