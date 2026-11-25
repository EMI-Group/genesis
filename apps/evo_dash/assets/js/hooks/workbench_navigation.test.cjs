const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

// Run the shipped modules with the small DOM/history seams used by this hook;
// neither a fake store nor a reimplementation of the activation logic.
function load(file, exports, globals = {}) {
  const text = readFileSync(`${__dirname}/${file}.js`, 'utf8')
    .replace(/^import [\s\S]*? from "[^"\n]+"\n/gm, '')
    .replace(/^export \{[^}]+\}\n/gm, '')
    .replace(/^export default \w+\n/gm, '')
    .replace(/^export (?=const |function )/gm, '');
  return vm.runInNewContext(`${text}\n;(${exports});`, {URL, URLSearchParams, ...globals});
}

const store = load('workbench_tabs', '{TAB_BASE_URL, safeHref, tabKey, tabGroup, restore, openTab, tabsForProject, alwaysPinned, pinTab, closeTab, cycleTab}');
const helpers = load('workbench_navigation', '{routeTab, exactHref, historyKey, defaultDraftHref, navigationState, sameTabClick}', store);
const url = path => new URL(path, 'https://example.test');
const taskKey = (id, node = '') => store.tabKey(node, '', 'task', id);
const DRAFT = '/assistant?wb_project=%2Frepo&wb_draft=1234567890abcdef12345678';
const OVERVIEW = '/projects?project=%2Frepo';
const TASKS = '/tasks?node=remote&status=running&task=task-1';
const COMMIT = '/review/task-1/commit/abcd?node=remote#file-2';

function timers() {
  let next = 0;
  const jobs = new Map();
  return {
    setTimeout(fn) { jobs.set(++next, fn); return next; },
    clearTimeout(key) { jobs.delete(key); },
    expire() { for (const fn of [...jobs.values()]) fn(); },
  };
}

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

function fixture({initial = OVERVIEW, defaultDraft, tabs = []} = {}) {
  let actual = url(initial);
  const location = new Proxy({}, {get(_, key) { return actual[key]; }});
  const clock = timers();
  const microtasks = [], frames = [], navigated = [], listeners = new Map();
  const document = {createElement: tag => element(tag)};
  document.body = document.activeElement = element('body');
  function element(tag) {
    const el = {
      tag, dataset: {}, children: [], attrs: {}, isConnected: true,
      classList: {toggle(name, value) { el[name] = value; }},
      setAttribute(name, value) { this.attrs[name] = value; },
      removeAttribute(name) { delete this.attrs[name]; },
      getAttribute(name) { return this.attrs[name] ?? this[name]; },
      hasAttribute(name) { return Object.hasOwn(this.attrs, name); },
      contains(node) { return this.children.some(child => child === node || child.contains(node)); },
      append(...children) { this.children.push(...children); },
      replaceChildren(...children) { this.children = children; },
      querySelector(selector) { return selector === 'a.workbench-tab-link' ? this.children.find(child => child.tag === 'a') : null; },
      focus() { document.activeElement = this; },
      matches(selector) { return `${tag}.${this.className}` === selector; },
      click() { navigated.push(this.href); emit('phx:page-loading-start', {kind: 'redirect', to: this.href}); },
      remove() {},
    };
    return el;
  }
  const globals = {location, document, queueMicrotask: fn => microtasks.push(fn)};
  const rail = load('workbench_rail', '{railMethods, link, TAB_KEY}', {...store, ...helpers, ...globals});
  const api = load('workbench', '{Workbench, navigation, attach: hook => { mountedWorkbench = hook; bindNavigation() }}', {
    ...rail, ...helpers, ...globals, safeHrefBase: store.safeHref,
    projectPreview: {forget() {}}, closeTabIn: store.closeTab, sessionStorage: {setItem() {}},
    navigationState: () => helpers.navigationState({setTimer: clock.setTimeout, clearTimer: clock.clearTimeout}),
    requestAnimationFrame: fn => frames.push(fn),
    performance: {getEntriesByType: () => []},
    window: {addEventListener(name, fn) { listeners.set(name, fn); }},
  });
  function emit(name, detail) { listeners.get(name)?.({detail}); }
  const tabRail = element('div');
  const overflow = element('details');
  const list = element('div');
  const historyRows = [];
  function addHistory(kind, id, href) {
    const row = element('div');
    const anchor = element('a');
    Object.assign(row.dataset, {workbenchItem: kind, itemId: id});
    row.append(anchor);
    row.querySelector = () => anchor;
    anchor.href = href;
    anchor.matches = selector => selector === 'a[data-workbench-open]';
    anchor.closest = selector => ({'button, a': anchor, '[data-workbench-item]': row}[selector]);
    historyRows.push(row);
    return {row, anchor, click(overrides = {}) { hook.click({button: 0, target: anchor, detail: 1, ...overrides}); }};
  }
  const {anchor: history} = addHistory('task', 'task-1', '/tasks?task=task-1');
  const hook = Object.assign(Object.create(api.Workbench), {
    el: {
      isConnected: true,
      dataset: {workbenchPage: 'dashboard', workbenchProject: '/repo', workbenchDefaultDraft: defaultDraft},
      querySelector(selector) {
        return {'#workbench-tabs': tabRail, '#workbench-tabs-overflow': overflow, '#workbench-tabs-overflow-list': list}[selector];
      },
      querySelectorAll() { return [...tabRail.children, ...list.children]; },
      contains(row) { return historyRows.includes(row); },
      append() {},
    },
    node: '', project: '/repo', tabs: store.restore(tabs), navigation: api.navigation,
    rows: historyRows,
    syncState() {},
    focusTab(key) { this.focused = key; },
    onNavigation() {
      this.captureTab(); this.renderTabs(); this.renderHistory(); this.settleActivation(); this.maybeOpenDefaultDraft();
    },
  });
  api.attach(hook);
  return {hook, document, tabRail, list, history, addHistory, navigated, frames, emit, expire: clock.expire,
    at(path) { actual = url(path); },
    flush() { while (microtasks.length) microtasks.shift()(); },
  };
}

const saved = (kind, id, href) => ({kind, id, href, title: id || kind, projectPath: '/repo'});

test('rail and overflow publish grouped markers; pending row is busy, not current', () => {
  const task = '/tasks?task=task-1&status=running';
  const {hook, tabRail, list, emit} = fixture({tabs: [saved('draft', 'draft', DRAFT), saved('task', 'task-1', task),
    saved('project', '', OVERVIEW + '&wb_task=1')]});
  hook.renderTabs();
  hook.renderOverflowTabs();
  for (const parent of [tabRail, list]) {
    assert.deepEqual(parent.children.map(el => el.dataset.tabGroup), ['project', 'task', 'chat']);
    assert.deepEqual(parent.children.map(el => el.dataset.tabGroupStart), [undefined, 'true', 'true']);
  }
  const row = tabRail.children[1], anchor = row.children[0];
  anchor.closest = selector => selector === 'button, a' ? anchor : selector === '[data-tab-key]' ? row : null;
  const event = {button: 0, target: anchor, detail: 0};
  hook.click({...event, ctrlKey: true});
  assert.equal(row.dataset.tabPending, undefined);
  hook.click(event);
  assert.equal(row.dataset.tabPending, 'true');
  assert.equal(anchor.attrs['aria-busy'], 'true');
  assert.equal(anchor.attrs['aria-current'], undefined);
  assert.equal(list.children[1].dataset.tabPending, 'true');
  emit('phx:page-loading-stop', {kind: 'redirect', to: task});
  assert.equal(anchor.attrs['aria-busy'], 'true');
});

test('round-tripping a review commit and Back updates one rail tab and history item, not its key', () => {
  const initial = '/tasks?task=task-1&status=running';
  const commit = '/review/task-1/commit/abcd#context';
  const {hook, at, emit, frames, history, tabRail} = fixture({initial});
  Object.assign(hook.el.dataset, {workbenchPage: 'tasks', workbenchTask: 'task-1'});
  hook.onNavigation();
  const key = taskKey('task-1');
  hook.indicateActivation(commit, key, true);
  emit('phx:page-loading-start', {kind: 'redirect', to: commit});
  emit('phx:page-loading-stop', {kind: 'redirect', to: commit});
  assert.equal(hook.tabs[0].href, initial);
  assert.equal(frames.length, 0);
  hook.el.dataset.workbenchPage = 'review';
  hook.onNavigation(); // DOM arrived before the browser reached the new URL
  assert.equal(hook.tabs[0].href, initial);
  at(commit);
  emit('phx:navigate', {href: commit});
  assert.equal(hook.tabs.length, 1);
  assert.equal(hook.tabs[0].href, commit);
  assert.equal(tabRail.children[0].children[0].href, commit);
  assert.equal(hook.currentTab, key);
  assert.equal(history.attrs['aria-current'], 'page');
  assert.equal(frames.length, 1);
  at(initial);
  emit('popstate');
  emit('phx:navigate', {href: initial, pop: true});
  hook.el.dataset.workbenchPage = 'tasks';
  hook.onNavigation();
  frames.shift()();
  assert.equal(hook.focused, undefined, 'a stale frame must not steal focus after Back');
  assert.equal(hook.tabs[0].href, initial);
  assert.equal(hook.currentTab, key);
});

test('Alt+Arrow stays within the rail, makes the destination pending, then focuses it on confirmation', () => {
  const current = '/tasks?task=task-1';
  const next = '/review/task-2/commit/abcd';
  const {hook, document, tabRail, at, emit, frames, navigated} = fixture({initial: current, tabs: [
    saved('task', 'task-1', current), saved('task', 'task-2', next),
  ]});
  Object.assign(hook.el.dataset, {workbenchPage: 'tasks', workbenchTask: 'task-1'});
  hook.onNavigation();
  const anchor = tabRail.children[0].children[0];
  anchor.focus();
  const event = {target: anchor, key: 'ArrowRight', altKey: true,
    preventDefault() { this.defaultPrevented = true; }, stopPropagation() {}};
  anchor.closest = () => null;
  assert.equal(hook.cycleTabWithKey(event), false);
  anchor.closest = selector => selector.startsWith('#workbench-tabs') ? tabRail : null;
  assert.equal(hook.cycleTabWithKey(event), true);
  assert.deepEqual(navigated, [next]);
  assert.equal(tabRail.children[1].dataset.tabPending, 'true');
  assert.equal(tabRail.children[0].children[0].attrs['aria-current'], 'page');
  assert.equal(tabRail.children[1].children[0].attrs['aria-current'], undefined);
  at(next);
  emit('phx:navigate', {href: next}); // layout is still for task-1
  assert.equal(frames.length, 0);
  Object.assign(hook.el.dataset, {workbenchPage: 'review', workbenchTask: 'task-2'});
  hook.onNavigation();
  assert.equal(tabRail.children[1].dataset.tabPending, undefined);
  assert.equal(tabRail.children[1].children[0].attrs['aria-current'], 'page');
  document.activeElement = document.body;
  frames.shift()();
  assert.equal(hook.focused, taskKey('task-2'));
});

test('closing a pending tab survives late start, layout and repeated commits without stealing focus', () => {
  const current = '/tasks?task=task-1&status=running';
  const next = '/review/task-2/commit/abcd#file-1';
  const {hook, at, emit, flush, frames, navigated, addHistory} = fixture({initial: current, tabs: [
    saved('task', 'task-1', current), saved('task', 'task-2', next),
  ]});
  const key = taskKey('task-2');
  Object.assign(hook.el.dataset, {workbenchPage: 'tasks', workbenchTask: 'task-1'});
  hook.onNavigation();
  hook.navigate(next, {key, restoreFocus: true});
  emit('phx:before-navigate', {href: next});
  hook.closeTab(key, true);
  flush(); // The old before-navigate microtask cannot revive the request.
  assert.equal(hook.focused, taskKey('task-1'));
  assert.equal(hook.navigation.pending, null);
  assert.deepEqual(navigated, [next], 'closing a background tab does not change the current route');
  emit('phx:page-loading-start', {kind: 'redirect', to: next});
  assert.equal(hook.navigation.moving, null);
  assert.equal(hook.currentTab, taskKey('task-1'));
  assert.equal(hook.tabs[0].href, current);

  at(next);
  emit('phx:navigate', {href: next}); // URL first, layout later.
  Object.assign(hook.el.dataset, {workbenchPage: 'review', workbenchTask: 'task-2'});
  hook.onNavigation();
  emit('phx:navigate', {href: next});
  assert.equal(hook.currentTab, null);
  assert.equal(hook.tabs.some(tab => tab.key === key), false);
  assert.equal(frames.length, 0);

  addHistory('task', 'task-2', next).click(); // Already on the URL: no navigation events needed.
  assert.equal(hook.currentTab, key);
  assert.equal(hook.tabs.find(tab => tab.key === key).href, next);
});

test('a late closed route cannot settle a newer request for another exact route of the same tab', () => {
  const old = '/review/task-2/commit/abcd#old';
  const next = '/review/task-2/commit/abcd#new';
  const {hook, at, emit, frames, addHistory} = fixture({tabs: [saved('task', 'task-2', old)]});
  const key = taskKey('task-2');
  hook.indicateActivation(old, key, true);
  hook.closeTab(key, false);
  const row = addHistory('task', 'task-2', next);
  row.click();
  Object.assign(hook.el.dataset, {workbenchPage: 'review', workbenchTask: 'task-2'});
  at(old);
  emit('phx:navigate', {href: old});
  assert.equal(hook.navigation.pending.href, next);
  assert.equal(row.row.dataset.tabPending, 'true');
  assert.equal(hook.tabs.length, 0);
  assert.equal(frames.length, 0);
  at(next);
  emit('phx:navigate', {href: next});
  assert.equal(hook.tabs[0].href, next);
  assert.equal(row.row.dataset.tabPending, undefined);
  assert.equal(row.anchor.attrs['aria-current'], 'page');
});

test('only the clicked history row is busy and rapid clicks, patches, timeout and disconnect clean up', () => {
  const current = '/tasks?task=task-1&status=running';
  const {hook, at, emit, history, addHistory, tabRail, expire} = fixture({initial: current});
  Object.assign(hook.el.dataset, {workbenchPage: 'tasks', workbenchTask: 'task-1'});
  hook.onNavigation();
  const task = addHistory('task', 'task-2', '/review/task-2');
  const sibling = addHistory('task', 'task-2', '/review/task-2');
  const chat = addHistory('chat', 'chat-1', '/assistant?session=chat-1');
  const busy = ({row, anchor}, value) => {
    assert.equal(row.dataset.tabPending, value ? 'true' : undefined);
    assert.equal(anchor.attrs['aria-busy'], value ? 'true' : undefined);
    assert.equal(Boolean(anchor['cursor-progress']), value);
  };

  task.click();
  busy(task, true);
  busy(sibling, false);
  assert.equal(tabRail.children.length, 1, 'history feedback does not require a tab');
  assert.equal(history.attrs['aria-current'], 'page');
  assert.equal(task.anchor.attrs['aria-current'], undefined);
  assert.equal(hook.tabs[0].href, current);
  for (const modifier of ['ctrlKey', 'metaKey', 'altKey', 'shiftKey']) chat.click({[modifier]: true});
  chat.click({button: 1});
  busy(chat, false);
  busy(task, true);

  delete task.row.dataset.tabPending;
  delete task.anchor.attrs['aria-busy'];
  hook.updated(); // A patch stripped the client attributes without changing the row.
  busy(task, true);
  chat.click();
  busy(task, false);
  busy(chat, true);
  at('/review/task-2');
  emit('phx:navigate', {href: '/review/task-2'}); // Superseded arrival.
  busy(chat, true);
  assert.equal(chat.anchor.attrs['aria-current'], undefined);
  at(chat.anchor.href);
  Object.assign(hook.el.dataset, {workbenchPage: 'assistant', workbenchTask: '', workbenchSession: 'chat-1'});
  emit('phx:navigate', {href: chat.anchor.href});
  busy(chat, false);
  assert.equal(chat.anchor.attrs['aria-current'], 'page');

  task.click();
  task.anchor.href = '/review/task-2/commit/abcd'; // A reused DOM row now links elsewhere.
  hook.updated();
  busy(task, false);
  task.click();
  expire();
  busy(task, false);
  task.click();
  hook.disconnected();
  busy(task, false);
  assert.equal(hook.navigation.pending, null);
  assert.equal(chat.anchor.attrs['aria-current'], 'page');
});

test('closing the last tab takes the explicit home route without starting a new draft', () => {
  const {hook, at, emit, flush, navigated} = fixture({initial: '/tasks?task=task-1', defaultDraft: DRAFT});
  Object.assign(hook.el.dataset, {workbenchPage: 'tasks', workbenchTask: 'task-1'});
  hook.onNavigation();
  hook.closeTab(taskKey('task-1'), false);
  hook.onNavigation();
  assert.equal(hook.tabs.length, 0, 'an outgoing patch cannot resurrect the closed view');
  const home = '/projects?wb_home=1&project=%2Frepo';
  assert.deepEqual(navigated, [home]);
  at(home);
  Object.assign(hook.el.dataset, {workbenchPage: 'dashboard', workbenchTask: ''});
  emit('phx:navigate', {href: home});
  flush();
  assert.deepEqual(navigated, [home]);
});

test('blank default goes through navigation once after restoration, without any event to start a session', () => {
  const empty = fixture({defaultDraft: DRAFT});
  empty.hook.onNavigation();
  empty.hook.onNavigation();
  empty.flush();
  assert.deepEqual(empty.navigated, [DRAFT]);
  empty.at(DRAFT);
  Object.assign(empty.hook.el.dataset, {workbenchPage: 'assistant', workbenchDraft: url(DRAFT).searchParams.get('wb_draft')});
  empty.emit('phx:navigate', {href: DRAFT});
  assert.equal(empty.hook.tabs[0].href, DRAFT);

  const restored = fixture({defaultDraft: DRAFT, tabs: [saved('task', 'task-1', '/tasks?task=task-1')]});
  restored.hook.onNavigation();
  restored.flush();
  assert.deepEqual(restored.navigated, []);

  const back = fixture({defaultDraft: DRAFT});
  back.hook.onNavigation();
  back.emit('popstate');
  back.flush();
  assert.deepEqual(back.navigated, []);
});
