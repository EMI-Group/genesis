const {test} = require('node:test');
const assert = require('node:assert/strict');
const {helpers, url, taskKey, DRAFT, OVERVIEW, timers} = require('./workbench_test_support.cjs');

const TASKS = '/tasks?node=remote&status=running&task=task-1';
const AGENTS = '/agents?node=remote&task=task-1&agent=agent-3#tree';
const COMMIT = '/review/task-1/commit/abcd?node=remote#file-2';

test('task aliases preserve the actual URL and share the same node/task identity', () => {
  const data = {workbenchNode: 'remote', workbenchTask: 'task-1', workbenchPage: 'tasks'};
  assert.equal(helpers.routeTab(url(TASKS), data, false).href, TASKS);
  assert.equal(helpers.routeTab(url(COMMIT), data, false), undefined, 'a stale task patch does not confirm a review');
  data.workbenchPage = 'review';
  assert.equal(helpers.routeTab(url(COMMIT), data, false).href, COMMIT);
  assert.equal(helpers.routeTab(url('/review/task-1'), data, false), undefined, 'node identity is not inferred');
  assert.equal(helpers.historyKey('remote', {workbenchItem: 'task', itemId: 'task-1'}), taskKey('task-1', 'remote'));
  assert.equal(helpers.historyKey('local', {workbenchItem: 'task', itemId: 'task-1'}), taskKey('task-1'));
  assert.equal(helpers.routeTab(url('/review/%E0'), {...data, workbenchNode: ''}, false), undefined);
});

test('focused Agents requires matching page, node and decoded task; global Agents stays outside the task rail', () => {
  const data = {workbenchNode: 'remote', workbenchPage: 'agents', workbenchTask: 'task-1', workbenchTitle: 'My task'};
  const view = helpers.routeTab(url(AGENTS), data, false);
  assert.equal(view.kind, 'task');
  assert.equal(view.id, 'task-1');
  assert.equal(view.href, AGENTS);
  assert.equal(view.title, 'My task');
  for (const overrides of [{workbenchNode: 'other'}, {workbenchPage: 'tasks'}, {workbenchTask: 'task-2'}, {workbenchTask: ''}]) {
    assert.equal(helpers.routeTab(url(AGENTS), {...data, ...overrides}, false), undefined);
  }
  const local = {...data, workbenchNode: '', workbenchTask: 'one+two'};
  assert.equal(helpers.routeTab(url('/agents?node=local&task=one%2Btwo'), local, false).id, 'one+two');
  assert.equal(helpers.routeTab(url('/agents?node=remote&agent=agent-3'), data, false), undefined);
  assert.equal(helpers.routeTab(url('/agents?node=remote&agent=agent-3'), {...data, workbenchTask: ''}, false), null);
});

test('the only default is the exact server-supplied scoped draft on an empty ready overview', () => {
  const data = {workbenchPage: 'dashboard', workbenchProject: '/repo', workbenchDefaultDraft: DRAFT};
  assert.equal(helpers.defaultDraftHref(url(OVERVIEW), data, false), DRAFT);
  assert.equal(helpers.defaultDraftHref(url(OVERVIEW), data, true), null);
  for (const suffix of ['&wb_home=1', '&wb_task=1', '&resume_from=a', '&starting_commit=abc', '&node=remote']) {
    assert.equal(helpers.defaultDraftHref(url(OVERVIEW + suffix), data), null);
  }
  for (const path of ['/tasks?task=task-1', '/review/task-1', '/assistant?session=s1', DRAFT, '/projects?project=/other']) {
    assert.equal(helpers.defaultDraftHref(url(path), data), null, path);
  }
  for (const href of [null, '//evil.test' + DRAFT, '/assistant?session=s1', DRAFT + '&node=remote', DRAFT + '&wb_project=/other']) {
    assert.equal(helpers.defaultDraftHref(url(OVERVIEW), {...data, workbenchDefaultDraft: href}), null);
  }
  const workspace = 'vct:///workspaces/pair';
  const href = DRAFT.replace('%2Frepo', encodeURIComponent(workspace)) + '&node=remote';
  const ready = {...data, workbenchNode: 'remote', workbenchProject: '', workbenchDefaultDraft: href};
  assert.equal(helpers.defaultDraftHref(url(`/projects?project=${encodeURIComponent(workspace)}&node=remote`), ready), href);
});

test('activation survives ignored events, rejects stale route updates and expires without focus', () => {
  const clock = timers();
  const state = helpers.navigationState({setTimer: clock.setTimeout, clearTimer: clock.clearTimeout});
  let paints = 0;
  const repaint = () => paints++;
  state.request(TASKS, 'task', 'focus', repaint);
  assert.equal(state.confirm(TASKS, 'task'), null, 'URL and key alone cannot confirm in-flight navigation');
  state.request(COMMIT, 'task', 'focus', repaint);
  state.start(TASKS, repaint); // queued loading-start from the superseded request
  state.commit(TASKS); // stale patch or redirect
  assert.equal(state.pending.href, COMMIT);
  assert.equal(state.confirm(TASKS, 'task'), null);
  state.commit(COMMIT);
  assert.equal(state.confirm(COMMIT, 'other'), null);
  assert.equal(state.confirm(COMMIT, 'task').focus, 'focus');
  assert.equal(state.confirm(COMMIT, 'task'), null);
  state.request(TASKS, 'task', 'focus', repaint);
  clock.expire();
  assert.equal(state.pending, null);
  assert.equal(paints, 1);
});

test('a later announced navigation or traversal can reopen a closed exact route', () => {
  const clock = timers();
  const state = helpers.navigationState({setTimer: clock.setTimeout, clearTimer: clock.clearTimeout});
  const key = taskKey('task-1', 'remote');
  const repaint = () => {};
  for (const reopen of [() => state.start(COMMIT, repaint, true), () => state.traverse(COMMIT)]) {
    state.request(COMMIT, key, null, repaint);
    state.cancelPending(key);
    state.start(COMMIT, repaint);
    state.commit(COMMIT);
    assert.equal(state.isClosed(COMMIT, key), true);
    assert.equal(state.isClosed(TASKS, key), false);
    reopen();
    assert.equal(state.isClosed(COMMIT, key), false);
  }
});

test('Back cancels activation and suppresses default drafts; failed defaults are one-shot per entry', () => {
  const clock = timers();
  const state = helpers.navigationState({setTimer: clock.setTimeout, clearTimer: clock.clearTimeout});
  assert.equal(state.claimDefault(OVERVIEW, '/repo'), true);
  assert.equal(state.claimDefault(OVERVIEW, '/repo'), false);
  state.request(DRAFT, 'draft', null, () => {});
  state.traverse(OVERVIEW);
  state.start(DRAFT, () => {}); // delayed loading start from before Back
  assert.equal(state.moving, null);
  assert.equal(state.confirm(DRAFT, 'draft'), null);
  assert.equal(state.claimDefault(OVERVIEW, '/repo'), false);
  const canonical = '/projects?node=local&project=/repo';
  state.commit(canonical); // server-only URL normalization is still a Back landing
  assert.equal(state.claimDefault(canonical, '/repo'), false);
  state.commit('/tasks');
  state.commit(OVERVIEW);
  assert.equal(state.claimDefault(OVERVIEW, '/repo'), true);
});
