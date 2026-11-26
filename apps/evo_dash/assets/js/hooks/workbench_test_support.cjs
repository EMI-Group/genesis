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

const store = load('workbench_tabs', '{TAB_BASE_URL, safeHref, sameScope, tabKey, tabGroup, restore, openTab, tabsForProject, alwaysPinned, pinTab, closeTab, cycleTab}');
const helpers = load('workbench_navigation', '{routeTab, exactHref, historyKey, defaultDraftHref, navigationState, sameTabClick}', store);
const url = path => new URL(path, 'https://example.test');
const taskKey = (id, node = '') => store.tabKey(node, '', 'task', id);
const DRAFT = '/assistant?wb_project=%2Frepo&wb_draft=1234567890abcdef12345678';
const OVERVIEW = '/projects?project=%2Frepo';

function timers() {
  let next = 0;
  const jobs = new Map();
  return {
    setTimeout(fn) { jobs.set(++next, fn); return next; },
    clearTimeout(key) { jobs.delete(key); },
    expire() { for (const fn of [...jobs.values()]) fn(); },
  };
}

module.exports = {load, store, helpers, url, taskKey, DRAFT, OVERVIEW, timers};
