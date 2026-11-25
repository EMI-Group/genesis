// Run with: node --test apps/evo_dash/assets/js/hooks/workbench_tabs.test.cjs
//
// Exercises the PURE tab store behind the workbench tab rail — "which tabs are
// open, which one does a preview replace, where does a close leave the user?" —
// without a browser bundle. The DOM half (the rail's markup, sessionStorage,
// middle-click, the overflow menu, Alt+Arrow) lives in workbench.js and only
// executes the decisions pinned here.
//
// Matching the workbench_panel.test.cjs / state_persistence.test.cjs
// convention: the block between the source's markers is sliced out and run
// through node:vm, so the real shipped code is what is measured — and the vm
// context supplies `URL` and nothing else, so a store function that started
// reaching for `document`, `window` or `sessionStorage` would throw instead of
// silently passing.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const src = readFileSync(`${__dirname}/workbench_tabs.js`, 'utf8');
const start = src.indexOf('// --- WorkbenchTabs: pure tab store');
const end = src.indexOf('// WorkbenchTabs hook:');
assert.ok(start !== -1 && end > start, 'pure tab store block not found in workbench_tabs.js');
const source = src.slice(start, end);
const {
  MAX_TABS_PER_PROJECT, alwaysPinned, tabKey, tabGroup, tabsForProject, safeHref, restore,
  openTab, pinTab, closeTab, cycleTab, activate,
} = vm.runInContext(`${source}
  ({MAX_TABS_PER_PROJECT, alwaysPinned, tabKey, tabGroup, tabsForProject, safeHref, restore,
    openTab, pinTab, closeTab, cycleTab, activate});`, vm.createContext({URL}));

const NODE = 'local';
const PROJECT = '/tmp/project';
const OTHER = '/tmp/other';

// A tab as `Workbench.captureTab()` builds it (before the store normalises it).
function tab(kind, id, spec = {}) {
  const projectPath = spec.projectPath ?? PROJECT;
  return {
    kind,
    id,
    node: NODE,
    projectPath,
    project: spec.project || 'project',
    title: spec.title || `${kind}:${id}`,
    location: 'Local',
    href: spec.href || `/tasks?node=local&task=${id}`,
    key: tabKey(NODE, projectPath, kind, id),
  };
}

const task = (id, spec) => tab('task', id, spec);
const chat = (id, spec) => tab('chat', id, {
  href: `/assistant?node=local&session=${id}`, ...spec,
});
const draft = (id, spec) => tab('draft', id, {
  href: `/assistant?node=local&wb_draft=${id}&wb_project=${encodeURIComponent(PROJECT)}`, ...spec,
});
const projectTab = (spec = {}) => tab('project', '', {
  projectPath: PROJECT, project: PROJECT,
  href: `/projects?node=local&project=${encodeURIComponent(PROJECT)}&wb_task=1`, ...spec,
});
const assistantTab = (spec) => tab('assistant', '', {href: `/assistant?node=local`, ...spec});

// Host-realm views of a vm-realm list, so assertions compare strings, never
// objects across realms.
const ids = tabs => Array.from(tabs, entry => entry.id).join(',');
const kinds = tabs => Array.from(tabs, entry => entry.kind).join(',');
const count = tabs => Array.from(tabs).length;
const keys = tabs => Array.from(tabs, entry => entry.key);
const first = tabs => Array.from(tabs).find(entry => entry.preview === true);

// `n` pinned task tabs t0…t(n-1), each opened last → active.
function fill(n) {
  let tabs = [];
  for (let i = 0; i < n; i += 1) tabs = openTab(tabs, task(`t${i}`), {preview: false});
  return tabs;
}

test('a project reuses ONE preview tab, replaced in place', () => {
  let tabs = openTab([], task('a'), {preview: true});
  assert.equal(count(tabs), 1);
  assert.equal(tabs[0].preview, true);
  tabs = openTab(tabs, task('b'), {preview: true});
  assert.equal(ids(tabs), 'b', 'the preview slot is reused, not appended to');
  assert.equal(count(tabs), 1, 'only one preview tab per project exists');

  // The replacement keeps the slot's POSITION between pinned tabs.
  let mixed = openTab([], task('p1'), {preview: false});
  mixed = openTab(mixed, task('a'), {preview: true});
  mixed = openTab(mixed, task('p2'), {preview: false});
  assert.equal(ids(mixed), 'p1,a,p2');
  mixed = openTab(mixed, task('b'), {preview: true});
  assert.equal(ids(mixed), 'p1,b,p2', 'replacement is in place, not at the end');
  assert.equal(count(mixed), 3);
  // A preview never replaces the active PINNED tab either: opening p1 again
  // selects it and leaves b alone.
  mixed = openTab(mixed, task('p1'), {preview: true});
  assert.equal(ids(mixed), 'p1,b,p2');
  assert.equal(first(mixed).id, 'b');
});

test('pinning is one-way and immune to preview replacement', () => {
  let tabs = openTab([], task('a'), {preview: true});
  tabs = pinTab(tabs, tabs[0].key);
  assert.equal(tabs[0].preview, false, 'pinning clears the preview flag');
  // A pinned tab is never a replacement target: the next preview appends.
  tabs = openTab(tabs, task('b'), {preview: true});
  assert.equal(ids(tabs), 'a,b');
  assert.equal(first(tabs).id, 'b');
  // Re-opening the pinned tab with `preview: true` cannot unpin it.
  tabs = openTab(tabs, task('a'), {preview: true});
  assert.equal(tabs[0].preview, false, 'pinning survives every later navigation');
  assert.equal(ids(tabs), 'a,b');
  // Pinning an already pinned / unknown key is inert.
  const before = JSON.stringify(tabs);
  assert.equal(JSON.stringify(pinTab(tabs, tabs[0].key)), before);
  assert.equal(JSON.stringify(pinTab(tabs, 'nope')), before);
});

test('draft, project, assistant and diff tabs are always pinned', () => {
  for (const kind of ['draft', 'project', 'assistant', 'diff']) {
    assert.equal(alwaysPinned(kind), true, kind);
  }
  for (const kind of ['task', 'chat']) assert.equal(alwaysPinned(kind), false, kind);

  let tabs = openTab([], draft('d1'), {preview: true});
  assert.equal(tabs[0].preview, false, 'a draft ignores the preview request');
  tabs = openTab(tabs, projectTab(), {preview: true});
  tabs = openTab(tabs, assistantTab(), {preview: true});
  assert.equal(count(tabs), 3);
  for (const entry of tabs) assert.equal(entry.preview, false, entry.kind);
  // A following preview appends instead of overwriting any of them.
  tabs = openTab(tabs, task('a'), {preview: true});
  assert.equal(kinds(tabs), 'draft,project,assistant,task');
  assert.equal(first(tabs).id, 'a');
});

test('re-opening an open tab updates in place by canonical key or same-kind href', () => {
  let tabs = openTab([], task('a'), {preview: true});
  const before = keys(tabs);
  const stale = task('a', {title: 'other'});
  stale.key = tabKey(NODE, PROJECT, 'task', 'a-twin');
  tabs = openTab(tabs, stale, {preview: true});
  assert.equal(count(tabs), 1);
  assert.deepEqual(keys(tabs), before, 'the route decides the task key');
  assert.equal(tabs[0].title, 'other');
  assert.equal(tabs[0].active, true);

  tabs = openTab(tabs, chat('a'));
  tabs = openTab(tabs, chat('legacy-alias', {href: chat('a').href}));
  assert.equal(count(tabs), 2, 'non-task tabs still dedupe by same-kind href');
  assert.equal(tabs[1].key, chat('a').key);
  tabs = openTab(tabs, assistantTab({href: chat('a').href}));
  assert.equal(count(tabs), 3, 'another kind with the same non-task href remains separate');
});

test('the live, review and commit routes share one canonical task key', () => {
  const node = 'remote-target';
  const key = tabKey(node, PROJECT, 'task', 't #1');
  assert.equal(key, tabKey(node, '', 'task', 't #1'));
  assert.equal(key, tabKey(node, OTHER, 'task', 't #1'));
  assert.notEqual(key, tabKey('other-target', PROJECT, 'task', 't #1'));
  assert.equal(tabKey('local', PROJECT, 'task', 'a'), tabKey('', '', 'task', 'a'));

  const live = '/tasks?task=t+%231&node=remote-target';
  const review = '/review/t%20%231?node=remote-target&file=a%20b';
  const commit = '/review/t%20%231/commit/abcdef?file=a%20b&node=remote-target#diff';
  let tabs = openTab([], task('pending-assign', {href: live, projectPath: ''}), {preview: true});
  assert.equal(tabs[0].key, key);
  assert.equal(tabs[0].projectPath, '');
  tabs = pinTab(tabs, key);
  tabs = openTab(tabs, tab('review', 'stale', {href: review}), {preview: true});
  assert.equal(tabs[0].href, review);
  assert.equal(tabs[0].projectPath, PROJECT);
  tabs = openTab(tabs, tab('commit', 'abcdef', {href: commit, projectPath: '', project: 'unscoped'}), {preview: true});
  assert.equal(count(tabs), 1);
  assert.equal(tabs[0].key, key);
  assert.equal(tabs[0].kind, 'task');
  assert.equal(tabs[0].id, 't #1');
  assert.equal(tabs[0].node, node);
  assert.equal(tabs[0].href, commit);
  assert.equal(tabs[0].preview, false);
  assert.equal(tabs[0].project, 'project');
  assert.equal(ids(tabsForProject(tabs, node, PROJECT)), 't #1');
  assert.equal(count(tabsForProject(tabs, node, '')), 0);
  assert.equal(count(tabsForProject(tabs, 'other-target', PROJECT)), 0);

  tabs = openTab(tabs, task('t #1', {href: '/tasks?task=t+%231&node=other-target'}));
  assert.equal(count(tabs), 2, 'another node can have the same task id');
});

test('a preview that learns its scope replaces the destination preview, not pinned tabs', () => {
  let tabs = openTab([], task('unknown', {projectPath: ''}), {preview: true});
  tabs = openTab(tabs, task('pinned'));
  tabs = openTab(tabs, chat('known-preview'), {preview: true});
  tabs = openTab(tabs, task('unknown'), {preview: true});
  assert.equal(ids(tabs), 'unknown,pinned');
  assert.equal(first(tabs).id, 'unknown');
  assert.equal(first(tabs).active, true);
  assert.equal(count(tabsForProject(tabs, NODE, PROJECT)), 2);
});

test('close reports the right neighbour, else the left, else nothing', () => {
  let tabs = openTab([], task('a'), {preview: false});
  tabs = openTab(tabs, task('b'), {preview: false});
  tabs = openTab(tabs, task('c'), {preview: false});

  const middle = closeTab(tabs, tabs[1].key);
  assert.equal(middle.closed.id, 'b');
  assert.equal(middle.focus.id, 'c', 'the right neighbour first');
  assert.equal(ids(middle.tabs), 'a,c');

  const last = closeTab(middle.tabs, middle.tabs[1].key);
  assert.equal(last.focus.id, 'a', 'then the left neighbour');

  const only = closeTab(last.tabs, last.tabs[0].key);
  assert.equal(only.focus, null, 'no neighbour leaves the caller the project home');
  assert.equal(count(only.tabs), 0);

  const unknown = closeTab(tabs, 'missing');
  assert.equal(unknown.closed, null);
  assert.equal(unknown.focus, null);
  assert.equal(count(unknown.tabs), 3);
});

test('tabs never cross projects (or BEAM nodes)', () => {
  let tabs = openTab([], task('a'), {preview: true});
  let other = task('b', {projectPath: OTHER, href: '/tasks?node=local&task=b'});
  tabs = openTab(tabs, other, {preview: true});
  assert.equal(count(tabs), 2, 'a preview slot exists PER project');

  assert.equal(count(tabsForProject(tabs, NODE, PROJECT)), 1);
  assert.equal(count(tabsForProject(tabs, NODE, OTHER)), 1);
  assert.equal(count(tabsForProject(tabs, 'remote@127.0.0.1', PROJECT)), 0);

  // Opening a preview in one project leaves the other's preview intact.
  tabs = openTab(tabs, task('a2'), {preview: true});
  assert.equal(ids(tabsForProject(tabs, NODE, PROJECT)), 'a2');
  assert.equal(ids(tabsForProject(tabs, NODE, OTHER)), 'b');

  // Closing in one project never picks a neighbour from another.
  const closed = closeTab(tabs, task('a2').key);
  assert.equal(closed.focus, null);
  assert.equal(count(tabsForProject(closed.tabs, NODE, OTHER)), 1);

  // `active` is per project: activating one project's tab does not clear the
  // other project's active marker.
  const activated = activate(closed.tabs, task('b', {projectPath: OTHER}).key);
  const byProject = Array.from(activated, entry => `${entry.projectPath}:${entry.active === true}`).sort();
  assert.deepEqual(byProject, [`${OTHER}:true`]);
});

test('Alt+Arrow cycling wraps, is project-scoped and starts at the near end', () => {
  let tabs = openTab([], task('a'), {preview: false});
  tabs = openTab(tabs, task('b'), {preview: false});
  tabs = openTab(tabs, task('c'), {preview: false});
  const [a, b, c] = Array.from(tabs);
  const key = entry => entry.key;

  assert.equal(cycleTab(tabs, NODE, PROJECT, key(a), 1).id, 'b');
  assert.equal(cycleTab(tabs, NODE, PROJECT, key(c), 1).id, 'a', 'next wraps forward');
  assert.equal(cycleTab(tabs, NODE, PROJECT, key(a), -1).id, 'c', 'previous wraps backward');
  assert.equal(cycleTab(tabs, NODE, PROJECT, key(b), -1).id, 'a');
  // The store's `direction` is only ever a sign.
  assert.equal(cycleTab(tabs, NODE, PROJECT, key(a), 0).id, 'b');

  // Unknown current key starts at the near end; an empty project yields null.
  assert.equal(cycleTab(tabs, NODE, PROJECT, 'missing', 1).id, 'a');
  assert.equal(cycleTab(tabs, NODE, PROJECT, 'missing', -1).id, 'c');
  assert.equal(cycleTab(tabs, NODE, '/tmp/none', key(a), 1), null);

  // Another project's tabs are never in the walk.
  const withOther = openTab(tabs, task('x', {projectPath: OTHER}), {preview: false});
  assert.equal(cycleTab(withOther, NODE, PROJECT, key(c), 1).id, 'a');
  assert.equal(cycleTab(withOther, NODE, OTHER, 'missing', 1).id, 'x');
});

test('the rail groups tab types in fixed order, preserving order within each group', () => {
  const groupKinds = ['project', 'task', 'assistant', 'draft', 'chat', 'diff', 'unknown'];
  assert.deepEqual(groupKinds.map(tabGroup), ['project', 'task', 'chat', 'chat', 'chat', 'diff', 'other']);
  assert.equal(tabGroup(undefined), 'other');

  let tabs = openTab([], chat('c1'));
  tabs = openTab(tabs, task('t1'));
  tabs = openTab(tabs, draft('d1'));
  tabs = openTab(tabs, projectTab());
  tabs = openTab(tabs, task('t2'));
  tabs = openTab(tabs, assistantTab());
  tabs = openTab(tabs, task('other', {projectPath: OTHER}));
  const rail = tabsForProject(tabs, NODE, PROJECT);
  assert.equal(kinds(rail), 'project,task,task,chat,draft,assistant');
  assert.equal(ids(rail), ',t1,t2,c1,d1,');
  assert.equal(ids(tabs), 'c1,t1,d1,,t2,,other', 'grouping does not reorder the raw store');
  assert.equal(cycleTab(tabs, NODE, PROJECT, task('t2').key, 1).id, 'c1');
  assert.equal(cycleTab(tabs, NODE, PROJECT, chat('c1').key, -1).id, 't2');
  assert.equal(closeTab(tabs, task('t2').key).focus.id, 'c1', 'close follows visual order');
});

test('restore round-trips a persisted list', () => {
  let tabs = openTab([], task('a'), {preview: true});
  tabs = openTab(tabs, draft('d1'));
  tabs = openTab(tabs, projectTab());
  const persisted = JSON.parse(JSON.stringify(tabs));
  const restored = restore(persisted, safeHref);
  assert.equal(ids(restored), 'a,d1,');
  assert.equal(kinds(restored), 'task,draft,project');
  assert.deepEqual(keys(restored), keys(tabs), 'keys are rebuilt from the fields');
  assert.equal(restored[0].preview, true);
  assert.equal(restored[1].projectPath, PROJECT, 'a draft keeps its project');
  assert.equal(restored[2].projectPath, PROJECT, 'a project tab keys off its href');
  // A JSON string (rather than an already-parsed list) is the same input.
  assert.deepEqual(keys(restore(JSON.stringify(persisted), safeHref)), keys(tabs));
});

test('restore migrates the legacy wb_workspace scope and rebuilds stale keys', () => {
  const href = `/projects?node=local&project=${encodeURIComponent('/tmp/p')}&wb_task=1&wb_workspace=1`;
  const legacyEntry = {
    kind: 'project', id: 'stale', node: '', projectPath: '',
    project: 'p', title: 'p', location: 'Local', href, key: 'stale-key',
  };
  const [restored] = Array.from(restore([legacyEntry], safeHref));
  assert.equal(restored.href.includes('wb_workspace'), false, 'the legacy param is dropped');
  assert.equal(restored.title, 'p', 'a migrated project tab is titled by its project');
  assert.equal(restored.id, '');
  assert.equal(restored.projectPath, '/tmp/p');
  assert.equal(restored.node, 'local');
  assert.equal(restored.key, tabKey('local', '/tmp/p', 'project', ''));
  assert.notEqual(restored.key, 'stale-key');

  // A project tab is only valid with `wb_task=1` and a project param.
  assert.equal(restore([{kind: 'project', href: '/projects?node=local'}], safeHref).length, 0);
  assert.equal(
    restore([{kind: 'project', href: '/projects?wb_task=1&project=%2Ftmp%2Fp'}], safeHref).length, 1
  );
});

test('restore merges legacy task aliases, keeping scope and pin but the last exact href', () => {
  const live = {...task('a', {project: 'Known project'}), preview: false};
  live.key = JSON.stringify([NODE, PROJECT, 'task', 'a']);
  const review = {...tab('review', 'wrong-id', {projectPath: '', href: '/review/a?file=a%20b'}), preview: true};
  const commit = {
    ...tab('commit', 'abcdef', {projectPath: '', href: '/review/a/commit/abcdef?file=a%20b&node=local#diff'}),
    preview: true,
    active: true,
  };
  const remote = {...task('a', {href: '/tasks?task=a&node=other-target'}), preview: true};
  const tabs = restore([live, review, commit, remote]);
  assert.equal(count(tabs), 2);
  const [local, otherNode] = Array.from(tabs);
  assert.equal(local.key, tabKey('', PROJECT, 'task', 'a'));
  assert.equal(local.id, 'a');
  assert.equal(local.kind, 'task');
  assert.equal(local.node, '');
  assert.equal(local.projectPath, PROJECT);
  assert.equal(local.project, 'Known project');
  assert.equal(local.preview, false);
  assert.equal(local.active, true);
  assert.equal(local.href, commit.href);
  assert.equal(otherNode.key, tabKey('other-target', PROJECT, 'task', 'a'));
  assert.equal(otherNode.preview, true);
  assert.equal(JSON.stringify(restore(JSON.stringify(tabs))), JSON.stringify(tabs), 'migration is idempotent');

  const [knownLast] = Array.from(restore([commit, live]));
  assert.equal(knownLast.href, live.href, 'latest route wins regardless of route type');
  assert.equal(knownLast.projectPath, PROJECT);
  assert.equal(knownLast.preview, false);
});

test('restore dedupes by key (last wins) and rejects untrusted hrefs', () => {
  const first = {...task('a'), title: 'first'};
  const second = {...task('a'), title: 'second'};
  const deduped = Array.from(restore([first, second], safeHref));
  assert.equal(deduped.length, 1);
  assert.equal(deduped[0].title, 'second');

  for (const href of [
    'https://evil.example/tasks?task=a',
    '//evil.example/tasks',
    'javascript:alert(1)',
    '/phoenix/dashboard',
    '/review',
    '/review/a/commit',
    '/review/a/other/b',
    '/review/%FF',
    '/tasks',
    '/tasks?task=',
    '',
    null,
    undefined,
    42,
  ]) {
    assert.equal(restore([{kind: 'task', id: 'a', href}], safeHref).length, 0, String(href));
  }
  // Review deep links are legal tab destinations.
  assert.equal(restore([{kind: 'task', id: 'a', href: '/review/abc'}], safeHref).length, 1);
});

test('the per-project cap evicts in the documented order', () => {
  assert.equal(MAX_TABS_PER_PROJECT, 40);

  // (1) The OLDEST tab that is not active and not a draft, once over the cap.
  let tabs = fill(MAX_TABS_PER_PROJECT);
  assert.equal(count(tabs), 40);
  tabs = openTab(tabs, task('overflow'), {preview: false});
  assert.equal(count(tabs), 40);
  assert.equal(ids(tabs).startsWith('t1,'), true, 'the oldest tab goes first');
  assert.equal(ids(tabs).endsWith(',overflow'), true);
  assert.equal(tabs[tabs.length - 1].active, true, 'the ACTIVE tab is never evicted');

  // (2) A preview is evicted FIRST, even when a pinned tab is older.
  let previewed = fill(MAX_TABS_PER_PROJECT - 1);
  previewed = openTab(previewed, task('look'), {preview: true});
  assert.equal(count(previewed), 40);
  assert.equal(first(previewed).id, 'look');
  previewed = openTab(previewed, task('keep'), {preview: false});
  assert.equal(count(previewed), 40);
  assert.equal(first(previewed), undefined, 'the preview slot was the victim');
  assert.equal(ids(previewed).includes('look'), false);
  assert.equal(ids(previewed).includes('t0'), true, 'older pinned tabs survived');

  // (3) A draft is the LAST resort — non-draft tabs go first.
  let drafted = openTab([], draft('d1'));
  for (let i = 0; i < MAX_TABS_PER_PROJECT - 1; i += 1) drafted = openTab(drafted, task(`t${i}`));
  assert.equal(count(drafted), 40);
  drafted = openTab(drafted, task('last'));
  assert.equal(count(drafted), 40);
  assert.equal(drafted[0].kind, 'draft', 'the draft survives while a task can go');
  assert.equal(ids(drafted).includes('t0'), false);

  // (4) With nothing but drafts and the active tab, the draft goes too — the
  // cap is hard, and the active tab is still never evicted.
  let drafts = [];
  for (let i = 0; i < MAX_TABS_PER_PROJECT; i += 1) drafts = openTab(drafts, draft(`d${i}`));
  assert.equal(count(drafts), MAX_TABS_PER_PROJECT);
  drafts = openTab(drafts, draft('extra'));
  assert.equal(count(drafts), MAX_TABS_PER_PROJECT);
  assert.equal(ids(drafts).includes('d0'), false, 'the oldest draft is evicted last-resort');
  assert.equal(ids(drafts).endsWith(',extra'), true);

  // Group order is NOT eviction age: the oldest chat goes before a newer project tab.
  let grouped = openTab([], chat('oldest'));
  grouped = openTab(grouped, projectTab());
  for (let i = 0; i < MAX_TABS_PER_PROJECT - 1; i += 1) grouped = openTab(grouped, task(`t${i}`));
  assert.equal(count(grouped), MAX_TABS_PER_PROJECT);
  assert.equal(grouped.some(entry => entry.id === 'oldest'), false);
  assert.equal(tabsForProject(grouped, NODE, PROJECT)[0].kind, 'project');

  // The cap is per project: another project keeps all of its own tabs.
  let twoProjects = fill(MAX_TABS_PER_PROJECT);
  twoProjects = openTab(twoProjects, task('other', {projectPath: OTHER}), {preview: false});
  assert.equal(count(tabsForProject(twoProjects, NODE, OTHER)), 1);
});

test('the store is total and never mutates its input', () => {
  // Garbage in, empty list out — never a throw.
  for (const raw of [null, undefined, 42, 'nope', '{bad json', [null, 1, 'x', {}, {kind: ''}], {a: 1}]) {
    const restored = restore(raw, safeHref);
    assert.equal(Array.isArray(restored), true);
    assert.equal(count(restored), 0, String(raw));
  }
  assert.equal(count(openTab(null, null)), 0);
  assert.equal(count(openTab(undefined, undefined, undefined)), 0);
  assert.equal(count(openTab([], {})), 0, 'a tab with no kind is not a tab');
  assert.equal(count(openTab('nope', task('a'))), 1);
  assert.equal(count(pinTab(null, 'k')), 0);
  assert.equal(closeTab(undefined, 'k').closed, null);
  assert.equal(closeTab(null, 'k').focus, null);
  assert.equal(cycleTab(null, NODE, PROJECT, 'k', 1), null);
  assert.equal(count(activate(null, 'k')), 0);
  // Numbers and booleans where strings belong are normalised, never thrown on.
  assert.equal(count(restore([{kind: 'task', id: 7, href: '/tasks?task=7', projectPath: 3}], safeHref)), 1);
  assert.equal(tabsForProject(null, NODE, PROJECT).length, 0);
  assert.equal(safeHref(7), false);

  // No input list is ever mutated in place.
  const tabs = openTab([], task('a'), {preview: true});
  const snapshot = JSON.stringify(tabs);
  openTab(tabs, task('b'), {preview: true});
  pinTab(tabs, tabs[0].key);
  closeTab(tabs, tabs[0].key);
  assert.equal(JSON.stringify(tabs), snapshot);
});

test('the slice is side-effect free by construction — it ran with only URL', () => {
  // The vm context above supplies `URL` and NOTHING else: no `document`, no
  // `window`, no `location`, no `sessionStorage`, no timers. Reaching for one
  // from any exercised path would have thrown a ReferenceError before this.
  assert.equal(typeof openTab, 'function');
  assert.equal(typeof restore, 'function');
  assert.equal(typeof cycleTab, 'function');
});
