const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const source = readFileSync(`${__dirname}/browser_notifications.js`, 'utf8')
  .replace('export default BrowserNotifications;', 'BrowserNotifications;');

function target() {
  const listeners = new Map();
  return {
    listeners,
    addEventListener(name, fn) { listeners.set(name, fn); },
    removeEventListener(name, fn) { assert.equal(listeners.get(name), fn); listeners.delete(name); }
  };
}

function mount({permission = 'granted', supported = true, hidden = true, focused = false,
  ids = ['req-1'], scope = 'local:session-1', request, constructorFails = false, canRequest = true} = {}) {
  const notifications = [];
  const pushed = [];
  const events = new Map();
  let requests = 0;
  let focuses = 0;
  const Notification = function(title, options) {
    if (constructorFails) throw new Error('WebView refuses notifications');
    Object.assign(this, {title, options, closed: false});
    this.close = () => { this.closed = true; this.onclose?.(); };
    notifications.push(this);
  };
  Notification.permission = permission;
  if (canRequest) Notification.requestPermission = () => {
    requests++;
    return request ? request(Notification) : Promise.resolve(Notification.permission = 'granted');
  };
  const window = {...target(), focus() { focuses++; }};
  const document = {...target(), hidden, visibilityState: hidden ? 'hidden' : 'visible', hasFocus: () => focused};
  const status = {textContent: ''};
  const button = {disabled: false, hidden: false};
  const el = {
    ...target(), dataset: {approvalScope: scope, approvalRequestIds: JSON.stringify(ids)},
    contains: element => element === button,
    getAttribute(name) { return name.startsWith('data-notification-label-') ? `translated:${name.split('-').at(-1)}` : null; },
    querySelectorAll(selector) { return selector === '[data-notification-status]' ? [status] : [button]; }
  };
  const hook = vm.runInNewContext(source, {window, document, ...(supported ? {Notification} : {})});
  Object.assign(hook, {
    el,
    handleEvent(name, fn) { events.set(name, fn); return name; },
    removeHandleEvent(ref) { events.delete(ref); },
    pushEvent(name, payload) { pushed.push(JSON.parse(JSON.stringify({name, payload}))); }
  });
  hook.mounted();
  return {
    hook, el, window, document, Notification, notifications, pushed, status, button, events,
    requests: () => requests, focuses: () => focuses,
    notify(payload = {title: 'Approval', body: 'Review in Genesis', request_id: 'req-1', scope, tag: 'approval'}) {
      events.get('task_notification')?.(payload);
    },
    enable(inside = true) {
      let prevented = false;
      el.listeners.get('click')({target: {closest: () => inside ? button : {}}, preventDefault() { prevented = true; }});
      return prevented;
    }
  };
}

const settle = () => new Promise(resolve => setImmediate(resolve));

test('permission is never requested on mount/update/focus; explicit delegated click enables once', async () => {
  const page = mount({permission: 'default'});
  page.hook.updated();
  page.window.listeners.get('focus')();
  assert.equal(page.requests(), 0);
  assert.equal(page.status.textContent, 'translated:default');
  assert.equal(page.button.hidden, false);
  assert.equal(page.enable(false), false);
  assert.equal(page.requests(), 0);
  assert.equal(page.enable(), true);
  page.enable();
  assert.equal(page.requests(), 1);
  assert.equal(page.status.textContent, 'translated:requesting');
  await settle();
  assert.equal(page.status.textContent, 'translated:granted');
  assert.equal(page.button.hidden, true);
});

test('unsupported, denied and unrequestable default are honest fallback states', () => {
  for (const [options, expected] of [[{supported: false}, 'unsupported'], [{permission: 'denied'}, 'denied'],
    [{permission: 'default', canRequest: false}, 'unsupported']]) {
    const page = mount(options);
    page.notify();
    page.enable();
    assert.equal(page.status.textContent, `translated:${expected}`);
    assert.equal(page.notifications.length, 0);
    assert.equal(page.requests(), 0);
    assert.equal(page.button.hidden, true);
  }
});

test('permission rejection and synchronous throws report error and allow explicit retry', async () => {
  for (const request of [() => Promise.reject(new Error('blocked')), () => { throw new Error('blocked'); }]) {
    const page = mount({permission: 'default', request});
    page.enable();
    await settle();
    assert.equal(page.status.textContent, 'translated:error');
    assert.equal(page.button.disabled, false);
    assert.equal(page.requests(), 1);
    page.window.listeners.get('focus')();
    assert.equal(page.status.textContent, 'translated:default');
  }
});

test('permission is read fresh on focus, visibilitychange, patch and delivery', () => {
  const page = mount({permission: 'default'});
  page.Notification.permission = 'granted';
  page.window.listeners.get('focus')();
  assert.equal(page.status.textContent, 'translated:granted');
  page.Notification.permission = 'denied';
  page.document.listeners.get('visibilitychange')();
  assert.equal(page.status.textContent, 'translated:denied');
  page.Notification.permission = 'granted';
  page.hook.updated();
  assert.equal(page.status.textContent, 'translated:granted');
  page.Notification.permission = 'denied';
  page.notify();
  assert.equal(page.notifications.length, 0);
  assert.equal(page.status.textContent, 'translated:denied');
});

test('visible focused pages never notify; hidden OR unfocused pages do', () => {
  for (const [hidden, focused, expected] of [[false, true, 0], [false, false, 1], [true, true, 1]]) {
    const page = mount({hidden, focused});
    page.notify();
    assert.equal(page.notifications.length, expected);
  }
  const page = mount({hidden: false, focused: true});
  delete page.document.hidden;
  delete page.document.hasFocus;
  page.notify();
  assert.equal(page.notifications.length, 0);
  page.document.visibilityState = 'hidden';
  page.notify();
  assert.equal(page.notifications.length, 1);
});

test('approval click only focuses and requests review of a currently pending same-scope id', () => {
  const page = mount();
  page.notify();
  const notification = page.notifications[0];
  assert.equal(notification.options.tag, 'approval');
  notification.onclick();
  assert.deepEqual(page.pushed, [{name: 'review_approval_notification', payload: {request_id: 'req-1', scope: 'local:session-1'}}]);
  assert.equal(page.focuses(), 1);
  assert.equal(notification.closed, true);
  assert.equal(notification.onclick, null);
});

test('malformed/missing metadata or request ids fail closed, never become terminal notifications', () => {
  for (const ids of [null, {}, [1], [''], ['req-1', null], []]) {
    const page = mount({ids});
    page.notify();
    assert.equal(page.notifications.length, 0);
  }
  for (const scope of ['', '  ', undefined]) {
    const page = mount({scope});
    if (scope === undefined) delete page.el.dataset.approvalScope;
    page.notify();
    assert.equal(page.notifications.length, 0);
  }
  const page = mount();
  for (const id of [null, 1, '', ' ', 'not-pending', {}]) page.notify({title: 'Approval', request_id: id, scope: 'local:session-1'});
  page.el.dataset.approvalRequestIds = 'not JSON';
  page.notify();
  assert.equal(page.notifications.length, 0);
});

test('delivery rejects missing/malformed payload scopes and stale payloads after same-id reuse', () => {
  const page = mount();
  for (const scope of [undefined, null, '', ' ', 1, {}, ['local:session-1'], 'foreign']) {
    page.notify({title: 'Approval', request_id: 'req-1', scope});
  }
  assert.equal(page.notifications.length, 0);

  const stalePayload = {title: 'Approval', request_id: 'req-1', scope: 'local:session-1'};
  page.notify(stalePayload);
  const staleClick = page.notifications[0].onclick;
  // The same request id in a different chat must not adopt the host's new scope.
  page.el.dataset.approvalScope = 'local:session-2';
  page.notify(stalePayload);
  assert.equal(page.notifications.length, 1);
  assert.equal(page.notifications[0].closed, true);
  staleClick();
  assert.deepEqual(page.pushed, []);

  page.notify({...stalePayload, scope: 'local:session-2'});
  page.notifications[1].onclick();
  assert.deepEqual(page.pushed, [{name: 'review_approval_notification',
    payload: {request_id: 'req-1', scope: 'local:session-2'}}]);
});

test('click revalidates live metadata even before a LiveView updated callback', () => {
  for (const mutate of [page => { page.el.dataset.approvalRequestIds = '[]'; },
    page => { page.el.dataset.approvalScope = 'remote:session-2'; },
    page => { page.el.dataset.approvalRequestIds = '{'; }]) {
    const page = mount();
    page.notify();
    mutate(page);
    page.notifications[0].onclick();
    assert.deepEqual(page.pushed, []);
    assert.equal(page.notifications[0].closed, true);
  }
});

test('resolution closes affected notifications; scope changes close all and invalidate saved callbacks', () => {
  const page = mount({ids: ['req-1', 'req-2']});
  page.notify();
  page.notify({title: 'Other approval', request_id: 'req-2', scope: 'local:session-1'});
  const staleClick = page.notifications[0].onclick;
  page.el.dataset.approvalRequestIds = '["req-2"]';
  page.hook.updated();
  assert.equal(page.notifications[0].closed, true);
  assert.equal(page.notifications[1].closed, false);
  staleClick();
  assert.deepEqual(page.pushed, []);
  page.el.dataset.approvalScope = 'other';
  page.hook.updated();
  assert.equal(page.notifications[1].closed, true);
  assert.equal(page.hook._notifications.size, 0);
});

test('Projects terminal notifications need no approval metadata and clicks never submit review/decisions', () => {
  const page = mount();
  page.el.dataset = {};
  page.el.querySelectorAll = () => [];
  page.el.getAttribute = () => null;
  page.notify({title: 'Task completed', body: 'Done'});
  const notification = page.notifications[0];
  assert.equal(notification.title, 'Task completed');
  assert.equal(notification.options.body, 'Done');
  notification.onclick();
  assert.equal(page.focuses(), 1);
  assert.deepEqual(page.pushed, []);
});

test('tag/request dedupe closes old notifications and native close drops retained records', () => {
  const page = mount();
  page.notify();
  page.notify();
  assert.equal(page.notifications[0].closed, true);
  assert.equal(page.hook._notifications.size, 1);
  page.notifications[1].onclose();
  assert.equal(page.hook._notifications.size, 0);
  page.notify({title: 'Terminal', tag: 'task'});
  page.notify({title: 'Terminal again', tag: 'task'});
  assert.equal(page.notifications[2].closed, true);
});

test('constructor failures expose localized error; invalid titles and body types are safe', () => {
  const page = mount({constructorFails: true});
  page.notify();
  assert.equal(page.status.textContent, 'translated:error');
  assert.deepEqual(page.pushed, []);
  const valid = mount();
  for (const title of ['', ' ', null, {}, 2]) valid.notify({title});
  assert.equal(valid.notifications.length, 0);
  valid.notify({title: 'Plain text', body: {sensitive: 'not serialized'}});
  assert.equal(valid.notifications[0].options.body, '');
});

test('async notification errors release records and show a translated advisory failure', () => {
  const page = mount();
  page.notify();
  const notification = page.notifications[0];
  notification.onerror();
  assert.equal(page.status.textContent, 'translated:error');
  assert.equal(notification.closed, true);
  assert.equal(notification.onerror, null);
  assert.equal(page.hook._notifications.size, 0);
  assert.deepEqual(page.pushed, []);
});

test('disconnect/destroy close notifications and release listeners/events; late permission completion is inert', async () => {
  const page = mount();
  page.notify();
  page.hook.disconnected();
  assert.equal(page.notifications[0].closed, true);
  page.hook.reconnected();
  page.notify();
  const staleClick = page.notifications[1].onclick;
  page.hook.destroyed();
  staleClick();
  assert.deepEqual(page.pushed, []);
  assert.equal(page.notifications[1].closed, true);
  for (const object of [page.el, page.window, page.document]) assert.equal(object.listeners.size, 0);
  assert.equal(page.events.size, 0);
  let resolve;
  const pending = mount({permission: 'default', request: () => new Promise(done => { resolve = done; })});
  pending.enable();
  pending.hook.destroyed();
  pending.status.textContent = 'unmounted';
  resolve('granted');
  await settle();
  assert.equal(pending.status.textContent, 'unmounted');
});
