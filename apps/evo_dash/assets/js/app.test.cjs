const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');

const source = readFileSync(`${__dirname}/app.js`, 'utf8');
const loadingStart = source.indexOf('// Show progress bar on live navigation and form submits');
assert.notEqual(loadingStart, -1, 'page-loading wiring not found in app.js');

for (const kind of ['initial', 'patch', 'redirect', 'element']) {
  test(`LiveView ${kind} loading keeps topbar without a document view transition`, () => {
    const calls = [];
    const window = new EventTarget();
    const liveSocket = {connect: () => calls.push(['connect'])};

    vm.runInNewContext(source.slice(loadingStart), {
      window,
      liveSocket,
      process: {env: {NODE_ENV: 'production'}},
      document: {startViewTransition: () => calls.push(['transition'])},
      prefersReducedMotion: () => false,
      setTimeout: () => calls.push(['timeout']),
      clearTimeout: () => {},
      topbar: {
        config: () => {},
        show: delay => calls.push(['show', delay]),
        hide: () => calls.push(['hide']),
      },
    });
    assert.equal(window.liveSocket, liveSocket);

    const detail = {kind};
    window.dispatchEvent(Object.assign(new Event('phx:page-loading-start'), {detail}));
    assert.deepEqual(calls, [['connect'], ['show', 300]]);
    window.dispatchEvent(Object.assign(new Event('phx:page-loading-stop'), {detail}));
    assert.deepEqual(calls, [['connect'], ['show', 300], ['hide']]);
  });
}
