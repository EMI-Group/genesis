const {test} = require('node:test');
const assert = require('node:assert/strict');
const {load, store, helpers, url, taskKey, DRAFT, OVERVIEW, timers} = require('./workbench_test_support.cjs');

function fixture({initial = OVERVIEW, defaultDraft, tabs = [], widths, historyOpen = false} = {}) {
  let actual = url(initial);
  const widthKey = 'genesis-workbench.sidebar-widths';
  const local = new Map(widths && [[widthKey, JSON.stringify(widths)]]);
  const historyKey = 'genesis-workbench.history', gitKey = 'genesis-workbench.git';
  const session = new Map([[historyKey, JSON.stringify(historyOpen)]]);
  const storage = map => ({getItem: key => map.get(key), setItem: (key, value) => map.set(key, value)});
  const mediaListeners = new Set();
  const media = {matches: true, addEventListener(_, fn) { mediaListeners.add(fn); },
    removeEventListener(_, fn) { mediaListeners.delete(fn); }};
  const trace = [];
  const getWidths = layout => ['left', 'right'].map(side => layout.style.getPropertyValue(`--workbench-${side}-width`));
  let activeLayout;
  const geometry = part => trace.push(['geometry', part, ...getWidths(activeLayout)]);
  const observed = new Set();
  let measure;
  class ResizeObserver {
    constructor(callback) { measure = callback; }
    observe(el) { observed.add(el); }
    unobserve(el) { observed.delete(el); }
    disconnect() { observed.clear(); measure = undefined; }
  }
  const location = new Proxy({}, {get(_, key) { return actual[key]; }});
  const clock = timers(), microtasks = [], frames = [], navigated = [], listeners = new Map();
  const window = {innerWidth: 1600, addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: name => listeners.delete(name)};
  const document = {createElement: tag => element(tag), addEventListener() {}, removeEventListener() {}};
  document.body = document.activeElement = element('body');
  function element(tag) {
    const el = {
      tag, dataset: {}, children: [], attrs: {}, isConnected: true,
      classList: {toggle(name, value) { el[name] = value; }},
      setAttribute(name, value) { this.attrs[name] = value; },
      removeAttribute(name) { delete this.attrs[name]; },
      getAttribute(name) { return this.attrs[name] ?? this[name]; },
      hasAttribute(name) { return Object.hasOwn(this.attrs, name); },
      toggleAttribute(name, show) { if (show) this.attrs[name] = ''; else delete this.attrs[name]; },
      addEventListener() {}, removeEventListener() {}, dispatchEvent() {},
      scrollIntoView() { if (activeLayout) geometry('current tab scroll'); },
      contains(node) { return this.children.some(child => child === node || child.contains(node)); },
      append(...children) { this.children.push(...children); },
      replaceChildren(...children) { this.children = children; },
      querySelector(selector) {
        if (selector === 'a.workbench-tab-link') return this.children.find(child => child.tag === 'a');
        if (selector === '.is-current') return this.children.find(child => child['is-current']);
        return null;
      },
      focus() { document.activeElement = this; },
      matches(selector) { return `${tag}.${this.className}` === selector; },
      click() { navigated.push(this.href); emit('phx:page-loading-start', {kind: 'redirect', to: this.href}); },
      remove() {},
    };
    return el;
  }
  const globals = {location, document, queueMicrotask: fn => microtasks.push(fn)};
  const rail = load('workbench_rail', '{railMethods, link, TAB_KEY}', {...store, ...helpers, ...globals});
  const historyMethods = load('workbench_history', 'historyMethods', {...globals, Event});
  const api = load('workbench', '{Workbench, navigation, attach: hook => { mountedWorkbench = hook; bindNavigation() }}', {
    ...rail, ...helpers, ...globals, historyMethods, safeHrefBase: store.safeHref, sameScope: store.sameScope,
    projectPreview: {forget() {}, remember() {}, show() {}, release() {},
      sync() { if (activeLayout) geometry('preview'); },
      reposition() { geometry('preview reposition'); }},
    createPanelHost: () => ({apply(panel, open, animate) {
      geometry(animate ? 'panel sync' : 'panel seed');
      panel.hidden = !open;
      panel.dataset.panelState = open ? 'open' : 'closed';
    }, destroy() {}}),
    matchMedia: query => query.includes('1280px') ? media : {matches: false},
    initialPanelState: open => open, PANEL_OPEN: true,
    localStorage: storage(local), sessionStorage: storage(session), ResizeObserver, Event,
    getComputedStyle: () => ({direction: 'ltr'}),
    closeTabIn: store.closeTab, restoreTabs: store.restore,
    navigationState: () => helpers.navigationState({setTimer: clock.setTimeout, clearTimer: clock.clearTimeout}),
    requestAnimationFrame: fn => frames.push(fn),
    performance: {getEntriesByType: () => []},
    window,
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
      addEventListener() {},
      append() {},
    },
    node: '', project: '/repo', tabs: store.restore(tabs), navigation: api.navigation,
    rows: historyRows,
    syncSidebarWidths() {}, // The route-only fixture does not mount width state.
    syncState() {},
    focusTab(key) { this.focused = key; },
    onNavigation() {
      this.captureTab(); this.renderTabs(); this.renderHistory(); this.settleActivation(); this.maybeOpenDefaultDraft();
    },
  });
  hook.mountHistory();
  api.attach(hook);

  function mount(page, options = {}) {
    const layout = element('div'), panel = element('aside'), center = element('div');
    Object.assign(layout.dataset, {workbenchProject: '/repo', workbenchPage: page, workbenchTask: 'task-1',
      workbenchAccentDefault: 'blue', ...options.dataset});
    panel.hidden = true;
    const inline = new Map();
    layout.style = {
      getPropertyValue: name => inline.get(name) ?? '',
      setProperty(name, value) { trace.push(['style', name, value]); inline.set(name, value); },
    };
    Object.defineProperty(layout, 'clientWidth', {get() {
      assert.fail('width restoration must not force layout on the shell');
    }});
    const nodes = new Map([['#workbench-history', panel], ['.workbench-center', center],
      ['#workbench-history-overlay', element('button')]]);
    const addHandle = side => {
      const handle = element('div');
      handle.dataset.workbenchResize = side;
      handle.closest = () => handle;
      handle.setPointerCapture = () => {};
      handle.setAttribute = (name, value) => { trace.push(['attr', side, name, value]); handle.attrs[name] = value; };
      nodes.set(`#workbench-${side}-resize`, handle);
      return handle;
    };
    const addOverflow = () => {
      const control = Object.assign(element('details'), {hidden: true, open: false});
      nodes.set('#workbench-tabs-overflow', control);
      return control;
    };
    const addRail = () => {
      const rail = Object.assign(element('div'), {extent: 800});
      Object.defineProperties(rail, {
        scrollWidth: {get() { geometry('overflow'); return rail.extent; }},
        clientWidth: {get() {
          const [left, right] = getWidths(layout).map(parseFloat);
          return window.innerWidth - left - (media.matches && !panel.hidden ? right : 0);
        }},
      });
      nodes.set('#workbench-tabs', rail);
      return rail;
    };
    layout.querySelector = selector => nodes.get(selector);
    layout.querySelectorAll = () => [];
    // History events delegate in the capture phase, including non-bubbling scroll.
    const captured = new Map();
    layout.addEventListener = (type, fn, capture) => { if (capture) captured.set(type, fn); };
    layout.removeEventListener = (type, fn, capture) => { if (capture && captured.get(type) === fn) captured.delete(type); };
    const historyContent = Object.assign(element('section'), {style: {visibility: ''}});
    panel.append(historyContent);
    nodes.set('#workbench-history-content', historyContent);
    const fallback = element('button');
    nodes.set('#workbench-create-toggle', fallback);
    const panelButton = (name, data = {}) => Object.assign(element('button'), {
      id: name, dataset: data, closest(selector) { return selector === 'button, a' ? this : null; },
    });
    const toggle = panelButton('workbench-history-toggle');
    const historyClose = panelButton('', {workbenchCloseHistory: ''});
    panel.append(historyClose);
    nodes.set('#workbench-history-toggle', toggle);
    nodes.set('[data-workbench-close-history]', historyClose);
    const gitUI = {};
    if (options.git) {
      const git = Object.assign(element('aside'), {hidden: true});
      const gitToggle = panelButton('workbench-git-toggle');
      const gitClose = panelButton('', {workbenchCloseGit: ''});
      git.append(gitClose);
      nodes.set('#workbench-git', git);
      nodes.set('#workbench-git-toggle', gitToggle);
      nodes.set('[data-workbench-close-git]', gitClose);
      Object.assign(gitUI, {git, gitToggle, gitClose});
    }
    function putRows({top = 0, max = 1000, loading = false, more = false,
      filter = '/repo', status = '', query = '', kind = 'tasks'} = {}) {
      const form = Object.assign(element('form'), {elements: {
        project: {value: filter}, status: {value: status}, query: {value: query},
      }});
      const kindPicker = element('div');
      kindPicker.dataset.historyKind = kind;
      form.querySelector = () => kindPicker;
      const rows = Object.assign(element('div'), {clientHeight: 400, scrollHeight: 400 + max, scrollTop: top});
      rows.dataset.loading = String(loading);
      const moreButton = element('button');
      rows.closest = selector => selector === '#workbench-history-rows' ? rows : null;
      moreButton.closest = selector => ({'#workbench-history-rows': rows, '[data-workbench-more]': moreButton}[selector]);
      rows.querySelector = selector => selector === '[data-workbench-more]' && moreButton.present ? moreButton : null;
      moreButton.present = more;
      historyContent.replaceChildren(form, rows);
      historyContent.querySelector = selector => nodes.get(selector);
      nodes.set('#workbench-history-filters', form);
      nodes.set('#workbench-history-rows', rows);
      return {rows, form, moreButton};
    }
    function clearRows() {
      historyContent.replaceChildren();
      nodes.delete('#workbench-history-filters');
      nodes.delete('#workbench-history-rows');
    }
    const entries = options.rows ? putRows(options.rows) : {};
    const rail = addRail(), control = addOverflow(), left = addHandle('left'), right = addHandle('right');
    activeLayout = layout;
    const live = Object.assign(Object.create(api.Workbench), {el: layout});
    live.mounted();
    return {live, layout, rail, control, left, right, panel, center, inline, addOverflow, addHandle, addRail,
      historyContent, toggle, historyClose, fallback, overlay: nodes.get('#workbench-history-overlay'),
      putRows, clearRows, ...entries, ...gitUI, captured,
      event(type, target, fields) { captured.get(type)?.({type, target, ...fields}); }};
  }

  return {hook, document, tabRail, list, history, addHistory, navigated, frames, emit, expire: clock.expire,
    at(path) { actual = url(path); },
    flush() { while (microtasks.length) microtasks.shift()(); },
    mount, trace, observed, measure: () => measure?.(), getWidths,
    viewport(width, wide = media.matches) { window.innerWidth = width; media.matches = wide; },
    changeBreakpoint(width, wide) {
      this.viewport(width, wide);
      emit('resize');
      for (const fn of mediaListeners) fn({matches: wide});
    },
    storedDocks: () => [session.get(historyKey), session.get(gitKey)],
    storedWidths: () => JSON.parse(local.get(widthKey)),
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

test('focused Agents replaces the exact destination through review and Back, retaining pinned task metadata', () => {
  const tasks = '/tasks?task=task-1&status=running';
  const agents = '/agents?task=task-1&agent=agent-2#graph';
  const review = '/review/task-1/commit/abcd#diff';
  const savedTask = {...saved('task', 'task-1', tasks), title: 'Task objective', project: 'Named project', location: 'Local'};
  const {hook, at, emit, frames, history, list, tabRail} = fixture({initial: tasks, tabs: [savedTask]});
  Object.assign(hook.el.dataset, {workbenchPage: 'tasks', workbenchTask: 'task-1'});
  hook.projectName = 'repo'; // The project shortcut label is not yet available after remount.
  hook.onNavigation();
  const key = taskKey('task-1');
  hook.indicateActivation(agents, key, true);
  assert.equal(tabRail.children[0].dataset.tabPending, 'true');
  assert.equal(tabRail.children[0].children[0].href, tasks);
  hook.el.dataset.workbenchPage = 'agents';
  hook.project = '';
  hook.projectName = undefined;
  hook.onNavigation();
  assert.equal(hook.tabs[0].href, tasks, 'the early layout cannot overwrite a confirmed destination');
  at(agents);
  emit('phx:navigate', {href: 'https://other.test' + agents});
  assert.equal(hook.navigation.pending.href, agents, 'a matching path on another origin cannot confirm');
  emit('phx:navigate', {href: agents});
  assert.equal(hook.tabs.length, 1);
  assert.equal(hook.tabs[0].key, key);
  assert.equal(hook.tabs[0].projectPath, '/repo');
  assert.equal(hook.tabs[0].project, 'Named project');
  assert.equal(hook.tabs[0].location, 'Local');
  assert.equal(hook.tabs[0].title, 'Task objective');
  assert.equal(hook.tabs[0].preview, false);
  hook.renderOverflowTabs();
  assert.equal(list.children[0].href, agents);
  assert.equal(list.children[0].attrs['aria-current'], 'page');
  assert.equal(list.children[0].attrs['aria-busy'], undefined);
  assert.equal(history.attrs['aria-current'], 'page');

  hook.el.dataset.workbenchPage = 'review';
  at(review);
  emit('phx:navigate', {href: review});
  assert.equal(hook.tabs[0].href, review);
  assert.equal(hook.currentTab, key);
  hook.el.dataset.workbenchPage = 'agents';
  at(agents);
  emit('popstate');
  emit('phx:navigate', {href: agents, pop: true});
  assert.equal(hook.tabs[0].href, agents);
  assert.equal(hook.currentTab, key);
  assert.equal(frames.length, 1);
  frames.shift()();
  assert.equal(hook.focused, undefined, 'the first activation no longer owns focus after Back');

  at('/agents?agent=agent-2');
  hook.el.dataset.workbenchTask = '';
  emit('phx:navigate', {href: '/agents?agent=agent-2'});
  assert.equal(hook.currentTab, null);
  assert.equal(history.attrs['aria-current'], undefined);
  assert.equal(hook.tabs[0].href, agents, 'global inspector never replaces a focused task route');
});

test('a project shortcut restores its focused Agents route and does not navigate away from a local diff on a modifier click', () => {
  const agents = '/agents?node=local&task=task-1&agent=agent-2#graph';
  const {hook, document, at, emit, navigated} = fixture({tabs: [saved('task', 'task-1', agents)]});
  const anchor = document.createElement('a');
  anchor.className = 'workbench-project-link';
  anchor.href = OVERVIEW;
  anchor.dataset = {workbenchNode: '', workbenchProject: '/repo'};
  anchor.closest = selector => selector === 'button, a' ? anchor : null;
  const click = (overrides = {}) => {
    const event = {button: 0, target: anchor, preventDefault() { this.defaultPrevented = true; }, stopPropagation() {}, ...overrides};
    hook.click(event);
    return Boolean(event.defaultPrevented);
  };
  let closed = 0;
  hook.closeGitDiff = () => closed++;
  assert.equal(click({metaKey: true}), false);
  assert.equal(click({button: 1}), false);
  assert.deepEqual(navigated, []);
  assert.equal(click(), true);
  assert.deepEqual(navigated, [agents]);
  at(agents);
  Object.assign(hook.el.dataset, {workbenchPage: 'agents', workbenchTask: 'task-1'});
  emit('phx:navigate', {href: agents});
  hook.gitDiff = 'lib/changed.ex';
  assert.equal(click({ctrlKey: true}), false);
  assert.equal(closed, 0);
  assert.equal(click(), true);
  assert.equal(closed, 1, 'selecting the exact confirmed task route dismisses the local Git diff');
  assert.deepEqual(navigated, [agents]);
  anchor.dataset.workbenchProject = '/another';
  anchor.href = '/projects?project=%2Fanother';
  assert.equal(click(), false, 'an explicit project with no remembered tab follows its own link');
  assert.deepEqual(navigated, [agents]);
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

const widthPreference = {left: 410, right: 520};
const widthPixels = ['410px', '520px'];
const resizerAria = (min, max, now) => ({'aria-valuemin': min, 'aria-valuemax': max, 'aria-valuenow': now});

test('mount and replace-root navigation restore widths before preview, dock, tab scroll and overflow', () => {
  const tasks = '/tasks?task=task-1';
  const review = '/review/task-1/commit/abcd';
  const f = fixture({initial: tasks, widths: widthPreference, historyOpen: true});
  for (const [path, page, back] of [[tasks, 'tasks'], [review, 'review'], [tasks, 'tasks', true]]) {
    f.trace.length = 0;
    f.at(path);
    if (back) f.emit('popstate');
    const {live, rail, panel, control, left, right} = f.mount(page);
    assert.deepEqual(left.attrs, resizerAria('192', '480', '410'));
    assert.deepEqual(right.attrs, resizerAria('264', '640', '520'));
    assert.equal(live.tabs[0].href, path);
    assert.equal(panel.hidden, false, 'the persisted dock still opens without an entrance');
    assert.equal(control.hidden, false, 'the rail is measured with both saved widths and the dock open');
    assert.deepEqual(f.trace.filter(([kind]) => kind === 'geometry'),
      ['preview', 'panel seed', 'current tab scroll', 'overflow'].map(part => ['geometry', part, ...widthPixels]));
    assert.ok(f.observed.has(rail));
    live.destroyed();
    assert.equal(f.observed.size, 0);
  }
});

test('a same-route morph repairs missing and reset widths and ARIA without sweeping an unchanged shell', () => {
  const f = fixture({initial: '/tasks?task=task-1', widths: widthPreference, historyOpen: true});
  const {live, layout, inline, left, addHandle} = f.mount('tasks');
  f.trace.length = 0;
  inline.delete('--workbench-left-width');
  inline.set('--workbench-right-width', '336px');
  delete left.attrs['aria-valuemin'];
  left.attrs['aria-valuenow'] = '256';
  const right = addHandle('right');
  const syncState = live.syncState;
  live.syncState = function () {
    assert.deepEqual(f.getWidths(layout), widthPixels, 'repair before the sweep decision');
    assert.deepEqual(left.attrs, resizerAria('192', '480', '410'));
    assert.deepEqual(right.attrs, resizerAria('264', '640', '520'));
    return syncState.call(this);
  };
  live.updated();
  assert.deepEqual(f.trace, [
    ['style', '--workbench-left-width', '410px'], ['attr', 'left', 'aria-valuemin', '192'],
    ['attr', 'left', 'aria-valuenow', '410'], ['style', '--workbench-right-width', '520px'],
    ...Object.entries(right.attrs).map(([name, value]) => ['attr', 'right', name, value]),
    ['geometry', 'overflow', ...widthPixels],
  ]);
  f.trace.length = 0;
  live.updated();
  assert.deepEqual(f.trace, [], 'a stable patch neither writes widths/ARIA nor measures layout');
  delete right.attrs['aria-valuenow'];
  live.updated();
  assert.deepEqual(f.trace, [['attr', 'right', 'aria-valuenow', '520']], 'ARIA-only repair needs no layout');

  f.trace.length = 0;
  inline.delete('--workbench-right-width');
  layout.dataset.workbenchTitle = 'Updated task';
  live.updated();
  assert.ok(f.trace.some(([, part]) => part === 'panel sync'), 'a dirty patch still sweeps');
  assert.ok(f.trace.filter(([kind]) => kind === 'geometry').every((entry) =>
    entry[2] === widthPixels[0] && entry[3] === widthPixels[1]), 'sweep geometry sees the repaired widths');
});

test('the overflow check follows a replaced rail or control and subsequent geometry changes', () => {
  const f = fixture({initial: '/tasks?task=task-1', widths: widthPreference, historyOpen: true});
  const {live, rail, control, addRail, addOverflow} = f.mount('tasks');
  const replacement = addRail();
  replacement.dataset.signature = rail.dataset.signature;
  replacement.children = [...rail.children];
  replacement.extent = 600;
  f.trace.length = 0;
  live.updated();
  assert.deepEqual(f.trace, [['geometry', 'overflow', ...widthPixels]]);
  assert.equal(control.hidden, true);
  assert.deepEqual([...f.observed], [replacement]);
  replacement.extent = 800;
  f.measure(); // A size observation (e.g. a dock or collapse transition) needs no LiveView patch.
  assert.equal(control.hidden, false);
  const newControl = addOverflow();
  live.updated();
  assert.equal(newControl.hidden, false);
});

test('drag and viewport changes keep width geometry current without persisting a clamp', () => {
  const f = fixture({initial: '/tasks?task=task-1', widths: widthPreference, historyOpen: true});
  const {live, layout, left, right, panel, center, inline} = f.mount('tasks');
  live.onPointerDown({target: left, button: 0, pointerId: 1, clientX: 410, preventDefault() {}});
  live.onPointerMove({pointerId: 1, clientX: 455});
  assert.deepEqual(f.getWidths(layout), ['455px', '520px']);
  assert.deepEqual(f.storedWidths(), widthPreference);
  delete layout.dataset.workbenchResizing;
  inline.clear();
  live.updated();
  assert.equal(layout.dataset.workbenchResizing, 'left');
  assert.deepEqual(f.getWidths(layout), ['455px', '520px'], 'a mid-drag morph must not restore the old preference');
  live.onPointerEnd({pointerId: 1});
  assert.equal(layout.dataset.workbenchResizing, undefined);
  assert.deepEqual(f.storedWidths(), {left: 455, right: 520});
  f.viewport(1280);
  f.trace.length = 0;
  f.emit('resize');
  assert.deepEqual(f.trace.filter(([kind]) => kind === 'geometry'),
    [['geometry', 'preview reposition', '455px', '345px'], ['geometry', 'overflow', '455px', '345px']]);
  assert.deepEqual(right.attrs, resizerAria('264', '345', '345'));
  assert.deepEqual(f.storedWidths(), {left: 455, right: 520});
  f.viewport(1200, false);
  live.onResize();
  assert.equal(panel.hidden, true, 'crossing into overlay mode still dismisses the dock');
  assert.deepEqual(f.getWidths(layout), ['455px', '520px']);
  live.setHistory(true);
  assert.equal(center.inert, true);
  assert.equal(right.hidden, true, 'resize handle remains hidden in drawer mode');
});

function assertNoDrawer(shell) {
  assert.equal(shell.git.hidden, true);
  assert.equal(shell.git.inert, true);
  assert.equal(shell.panel.hidden, true);
  assert.equal(shell.overlay.hidden, true);
  assert.equal(shell.right.hidden, true);
  assert.equal(shell.center.inert, false);
  assert.equal(shell.layout.hasAttribute('data-workbench-history-drawer-open'), false);
  for (const trigger of [shell.gitToggle, shell.toggle]) assert.equal(trigger.getAttribute('aria-expanded'), 'false');
}

function dismissWithEscape(live, target) {
  let handled = false;
  live.onKey({key: 'Escape', target, preventDefault() { handled = true; }});
  assert.equal(handled, true);
}

test('crossing from 1840px to 1279px dismisses Git and restores only lost dock focus', () => {
  for (const focus of ['gitClose', 'right', 'center']) {
    const f = fixture({historyOpen: true});
    f.viewport(1840);
    const shell = f.mount('dashboard', {git: true});
    shell.live.click({target: shell.gitToggle});
    assert.equal(shell.git.hidden, false);
    assert.equal(shell.panel.hidden, true, 'Git is in front of the remembered History dock');
    assert.equal(shell.right.hidden, false);
    shell[focus].focus();
    f.changeBreakpoint(1279, false);
    assertNoDrawer(shell);
    assert.equal(f.document.activeElement, focus === 'center' ? shell.center : shell.gitToggle, focus);
    assert.deepEqual(f.storedDocks(), ['true', 'true'], 'automatic dismissal does not change desktop choices');
  }
});

test('same-project Review remount at 1279px ignores both desktop flags but allows explicit drawers', () => {
  const review = '/review/task-1';
  const f = fixture({initial: '/tasks?task=task-1', historyOpen: true});
  f.viewport(1840);
  const from = f.mount('tasks', {git: true});
  from.live.click({target: from.gitToggle});
  f.changeBreakpoint(1279, false);
  f.emit('phx:page-loading-start', {kind: 'redirect', to: review});
  from.live.destroyed();
  f.at(review);
  const to = f.mount('review', {git: true});
  f.emit('phx:navigate', {href: review});
  assert.equal(to.live.tabs[0].href, review);
  assertNoDrawer(to);

  for (const [toggle, close, panel] of [[to.gitToggle, to.gitClose, to.git], [to.toggle, to.historyClose, to.panel]]) {
    to.live.click({target: toggle});
    assert.equal(panel.hidden, false);
    assert.equal(toggle.getAttribute('aria-expanded'), 'true');
    assert.equal(to.center.inert, true);
    assert.equal(f.document.activeElement, close);
    dismissWithEscape(to.live, close);
    assertNoDrawer(to);
    assert.equal(f.document.activeElement, toggle);
    assert.deepEqual(f.storedDocks(), ['true', 'true'], 'narrow gestures do not change desktop choices');
  }

  to.live.click({target: to.gitToggle});
  Object.assign(to.layout.dataset, pendingHistory);
  to.live.updated();
  assertNoDrawer(to);
  assert.equal(f.document.activeElement, to.fallback, 'unverified scope uses the shell fallback');
  settleHistory(to);
  assertNoDrawer(to);

  to.live.destroyed();
  f.viewport(1840, true);
  const desktop = f.mount('review', {git: true});
  assert.equal(desktop.git.hidden, false, 'a desktop mount still restores the explicit dock choice');
  desktop.live.click({target: desktop.gitClose});
  assert.equal(desktop.panel.hidden, false, 'closing desktop Git reveals the remembered History dock');
  assert.deepEqual(f.storedDocks(), ['true', 'false']);
});

const pendingHistory = {workbenchProject: '', workbenchHistoryScopePending: 'true'};

function settleHistory(shell, project = '/repo') {
  delete shell.layout.dataset.workbenchHistoryScopePending;
  shell.layout.dataset.workbenchProject = project;
  shell.live.updated();
}

function scrollHistory(shell, top) {
  shell.rows.scrollTop = top;
  shell.event('scroll', shell.rows);
}

test('an open desktop dock reserves its saved width through a pending remount without exposing content', () => {
  const f = fixture({historyOpen: true, widths: {left: 300, right: 425}});
  const from = f.mount('dashboard', {rows: {}});
  scrollHistory(from, 200);
  from.live.destroyed();
  assert.equal(from.captured.has('scroll'), false);
  assert.equal(from.captured.has('input'), false);

  const to = f.mount('review', {dataset: pendingHistory, rows: {top: 33}});
  assert.deepEqual(f.getWidths(to.layout), ['300px', '425px']);
  assert.equal(to.panel.hidden, false);
  assert.equal(to.panel.inert, true);
  assert.equal(to.historyContent.style.visibility, 'hidden');
  assert.equal(to.toggle.getAttribute('aria-expanded'), 'false');
  assert.equal(to.toggle.inert, true);
  assert.equal(to.right.hidden, false);
  assert.equal(to.right.inert, true);
  assert.equal(to.center.inert, false, 'reserving a dock is not opening a drawer');
  to.historyContent.style.visibility = '';
  to.panel.hidden = true;
  to.live.updated();
  assert.equal(to.historyContent.style.visibility, 'hidden', 'a same-marker morph repairs the stale frame');
  assert.equal(to.panel.hidden, false);
  const newRows = to.putRows({loading: true});
  settleHistory(to);
  assert.equal(to.panel.hidden, false, 'resolving scope does not close and reopen the panel');
  assert.equal(to.panel.inert, false);
  assert.equal(to.historyContent.style.visibility, '');
  assert.equal(to.right.inert, false);
  assert.equal(to.toggle.getAttribute('aria-expanded'), 'true');
  assert.equal(newRows.rows.scrollTop, 0);
  newRows.rows.dataset.loading = 'false';
  to.live.updated();
  assert.equal(newRows.rows.scrollTop, 200, 'loading settlement works even on a no-sweep patch');
});

test('same-shell pending scope releases focus and ends at unavailable/unscoped History', () => {
  const f = fixture({historyOpen: true});
  const shell = f.mount('tasks', {rows: {}});
  scrollHistory(shell, 150);
  f.document.activeElement = shell.rows;
  Object.assign(shell.layout.dataset, pendingHistory);
  shell.live.updated();
  assert.equal(shell.panel.hidden, false);
  assert.equal(f.document.activeElement, shell.fallback);
  assert.equal(shell.historyContent.style.visibility, 'hidden');
  shell.clearRows();
  settleHistory(shell, '');
  assert.equal(shell.panel.hidden, true);
  shell.live.destroyed();
  const back = f.mount('tasks', {rows: {}});
  assert.equal(back.rows.scrollTop, 0, 'unscoped settlement discards the old offset');
});

test('pending History reserves no space without an outgoing dock, on another node, or in overlay mode', () => {
  const fresh = fixture({historyOpen: true}).mount('agents', {dataset: pendingHistory});
  assert.equal(fresh.panel.hidden, true, 'a preference alone is not an open dock');
  for (const boundary of ['node', 'narrow']) {
    const f = fixture({historyOpen: true});
    const from = f.mount('tasks', {rows: {}});
    scrollHistory(from, 220);
    from.live.destroyed();
    if (boundary === 'narrow') f.viewport(1000, false);
    const to = f.mount('agents', {dataset: {...pendingHistory,
      workbenchNode: boundary === 'node' ? 'remote' : ''}, rows: {}});
    assert.equal(to.panel.hidden, true, boundary);
    assert.equal(to.center.inert, false, boundary);
    assert.equal(to.layout.hasAttribute('data-workbench-history-drawer-open'), false, boundary);
    settleHistory(to);
    assert.equal(to.panel.hidden, boundary === 'narrow');
    assert.equal(to.rows.scrollTop, 0);
  }
});

test('History can transfer before late outgoing hook teardown without reviving its old position', () => {
  const f = fixture({historyOpen: true});
  const from = f.mount('dashboard', {rows: {}});
  from.rows.scrollTop = 180; // no scroll event delivered yet
  const to = f.mount('review', {rows: {}});
  assert.equal(to.rows.scrollTop, 180);
  scrollHistory(to, 330);
  to.live.destroyed();
  from.live.destroyed();
  const next = f.mount('agents', {rows: {}});
  assert.equal(next.rows.scrollTop, 330);
});

test('Back/Forward remounts share the offset only when node, project and view filters still match', () => {
  const f = fixture({historyOpen: true});
  let shell = f.mount('dashboard', {rows: {}});
  scrollHistory(shell, 180);
  for (const path of ['/review/task-1', OVERVIEW, '/review/task-1']) {
    shell.live.destroyed();
    f.at(path);
    f.emit('popstate');
    shell = f.mount(path === OVERVIEW ? 'dashboard' : 'review', {rows: {}});
    assert.equal(shell.rows.scrollTop, 180, path);
  }
  for (const options of [{dataset: {workbenchProject: '/other'}}, {rows: {filter: ''}},
    {rows: {status: 'running'}}, {rows: {query: 'query'}}, {rows: {kind: 'conversations'}}]) {
    const f = fixture({historyOpen: true});
    const from = f.mount('dashboard', {rows: {}});
    scrollHistory(from, 180);
    from.live.destroyed();
    const to = f.mount('review', {rows: {}, ...options});
    assert.equal(to.rows.scrollTop, 0, JSON.stringify(options));
  }
});

test('History scroll restoration waits for explicit pagination, clamps at the end, and yields to user input', () => {
  for (const action of ['page', 'clamp', 'wheel', 'keydown', 'scroll', 'filter']) {
    const f = fixture({historyOpen: true});
    const from = f.mount('dashboard', {rows: {}});
    scrollHistory(from, 800);
    from.live.destroyed();
    const to = f.mount('review', {rows: {more: true, max: 120}});
    assert.equal(to.rows.scrollTop, 0, 'the first page cannot restore the old offset');
    if (action === 'page') {
      to.event('pointerdown', to.moreButton);
      to.event('keydown', to.moreButton, {key: 'Enter'});
    }
    if (action === 'keydown') to.event('keydown', to.rows, {key: 'PageDown'});
    if (action === 'wheel') to.event('wheel', to.rows);
    if (action === 'scroll') scrollHistory(to, 70);
    if (action === 'filter') {
      const input = to.form.elements.query;
      input.closest = () => to.form;
      input.value = 'different';
      to.event('input', input);
      input.value = ''; // even if the server later renders the old filter again
    }
    to.moreButton.present = false;
    to.rows.scrollHeight = to.rows.clientHeight + (action === 'clamp' ? 300 : 1000);
    to.live.updated();
    assert.equal(to.rows.scrollTop, {page: 800, clamp: 300, wheel: 0, keydown: 0, scroll: 70, filter: 0}[action], action);
  }
});
