// Run viewer-epoch-tests first; exercise actual app.js handlers with its real SSE fixtures.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const code = fs.readFileSync(path.join(__dirname, '../../Web/app.js'), 'utf8');
const fixtures = JSON.parse(fs.readFileSync('/private/tmp/LayerLens-release-build/network-viewer-events.json', 'utf8'));
function slice(start, end, from = 0) {
  const a = code.indexOf(start, from), b = code.indexOf(end, a);
  assert(a >= 0 && b > a); return code.slice(a, b);
}
function create() {
  const handlers = new Map();
  const es = { url: 'http://localhost/api/network?since=0&epoch=', addEventListener: (name, fn) => handlers.set(name, fn) };
  const net = { es, token: 1, sourceRevision: 0, epoch: '', instanceId: '', seq: 0, records: new Map(), list: [], pending: new Map(), selected: 0, paused: false, connecting: false };
  const counts = { resync: 0, errors: 0 };
  const button = { classList: { toggle() {} }, setAttribute() {}, querySelector() { return { setAttribute() {} }; } };
  const context = {
    net, es, token: 1, URL, location: { href: 'http://localhost/' }, NET_MAX_RECORDS: 5000,
    parse: e => JSON.parse(e.data), scheduleNetRender() {}, loadLaunches() {}, recorderStorageError() {},
    renderNetStatus() {}, resetNetRemote() {}, closeNetDetail() {}, noteNetRemoteRecord() {}, flushNetRemote() {},
    rebuildNetView() {}, loadNetDetail() {}, $: () => button, t: value => value,
    targetBase: () => '/t/phone/test', toast: () => counts.errors++, resyncNet: () => counts.resync++,
  };
  vm.createContext(context);
  vm.runInContext(slice('function updateNetResume(', 'function receiveNetRecords(') +
    slice('function receiveNetRecords(', '// MARK: Filter') +
    slice("  es.addEventListener('network', (e) => {", '  // 断开后由浏览器自动重连', code.indexOf('async function netConnect()')) +
    slice('async function clearNet()', 'function setNetDetailWidth('), context);
  const emit = frames => frames.forEach(frame => handlers.get(frame.name)?.({ data: JSON.stringify(frame.data) }));
  return { context, net, es, counts, emit, ids: () => Array.from(net.records.keys()).sort((a, b) => a - b) };
}

(async () => {
  const view = create(); view.emit(fixtures.initial); assert.equal(view.net.records.size, 3);
  view.emit(fixtures.afterClear); assert.equal(view.net.records.size, 0, 'Reconnect must reset missed clear');
  view.emit(fixtures.page); assert.equal(view.net.records.size, 128);
  const partial = new URL(view.es.url);
  assert.equal(partial.searchParams.get('since'), String(view.net.seq));
  assert.equal(partial.searchParams.get('epoch'), view.net.epoch);
  view.emit(fixtures.tail); assert.equal(view.net.records.size, 129, 'Remaining page must merge without reset');
  view.emit(fixtures.clearDuringReplay); assert.equal(view.net.records.size, 0);
  view.emit(fixtures.newRecords); assert.deepEqual(view.ids(), [133, 134]);
  view.emit(fixtures.unchanged); assert.deepEqual(view.ids(), [133, 134], 'Same generation empty delta must preserve data');
  view.emit(fixtures.afterRestart); assert.deepEqual(view.ids(), [133, 134]);
  view.emit(fixtures.cacheReload); assert.deepEqual(view.ids(), [133, 134]);
  view.emit(fixtures.processChanged); assert.deepEqual(view.ids(), [1, 2]);

  const paused = create(); paused.emit(fixtures.initial); paused.emit(fixtures.afterClear);
  paused.net.paused = true; paused.emit(fixtures.page); assert.equal(paused.net.pending.size, 128);
  assert.equal(new URL(paused.es.url).searchParams.get('since'), '0', 'Do not acknowledge unapplied paused pages');
  paused.emit(fixtures.clearDuringReplay); assert.equal(paused.net.pending.size, 0);
  paused.emit(fixtures.newRecords); vm.runInContext('setNetPaused(false)', paused.context);
  assert.deepEqual(paused.ids(), [133, 134]); assert.equal(paused.net.pending.size, 0);
  assert.equal(new URL(paused.es.url).searchParams.get('since'), String(paused.net.seq));

  // Clear event and newer data can arrive before the POST response; the response must not erase them.
  const race = create(); race.emit(fixtures.initial);
  race.context.fetch = async () => { race.emit(fixtures.clearDuringReplay); race.emit(fixtures.newRecords); return { ok: true }; };
  await vm.runInContext('clearNet()', race.context);
  assert.deepEqual(race.ids(), [133, 134]); assert.equal(race.counts.resync, 1);
  const failed = create(); failed.emit(fixtures.initial);
  failed.context.fetch = async () => ({ ok: false, status: 500 });
  await vm.runInContext('clearNet()', failed.context);
  assert.equal(failed.net.records.size, 3); assert.equal(failed.counts.errors, 1); assert.equal(failed.counts.resync, 0);

  // Old stream callbacks and a late HTTP response cannot reset the newly selected target.
  const stale = create(); stale.emit(fixtures.initial); stale.net.token = 2;
  stale.emit(fixtures.afterClear); assert.equal(stale.net.records.size, 3);
  const switched = create(); switched.emit(fixtures.initial);
  switched.context.fetch = async () => { switched.net.token = 2; return { ok: true }; };
  await vm.runInContext('clearNet()', switched.context);
  assert.equal(switched.net.records.size, 3); assert.equal(switched.counts.resync, 0);

  // First App data can arrive after an initially empty source; a new epoch must replace it.
  const firstApp = create(); firstApp.net.epoch = 'empty-source'; firstApp.emit([fixtures.initial.at(-1)]);
  assert.equal(firstApp.net.records.size, 3);
  console.log('PASS actual web handlers with real SSE: missed clear, paged resume, pause, Mac/cache/App restart, clear-response race and stale target callbacks');
})().catch(error => { console.error(error); process.exitCode = 1; });
