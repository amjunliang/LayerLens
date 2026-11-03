const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const code = fs.readFileSync(path.join(__dirname, '../../Web/app.js'), 'utf8');
function slice(start, end) {
  const a = code.indexOf(start), b = code.indexOf(end, a);
  assert(a >= 0 && b > a); return code.slice(a, b);
}
function create() {
  let syncCalls = 0;
  const button = { classList: { toggle() {} }, setAttribute() {}, querySelector: () => ({ setAttribute() {} }) };
  const context = {
    URL, URLSearchParams, location: { href: 'http://localhost/' }, NET_MAX_RECORDS: 5000,
    targetBase: () => '/old-target', netSessionParams: params => params || {},
    syncNetRemote() { syncCalls++; }, syncNetCapture() { syncCalls++; },
    resetNetRemote() {}, closeNetDetail() {}, scheduleNetRender() {}, renderNetStatus() {},
    noteNetRemoteRecord() {}, flushNetRemote() {}, rebuildNetView() {}, loadNetDetail() {}, $: () => button, t: value => value,
  };
  vm.createContext(context);
  vm.runInContext(slice('const net = {', '\nfunction netVisible()') +
    slice('async function netOutdated()', '\nfunction netDisconnect()') +
    slice('function updateNetResume(', '// MARK: Filter'), context);
  const net = vm.runInContext('net', context);
  net.token = 1;
  net.es = { url: 'http://localhost/api/network?since=0&epoch=test' }; net.epoch = 'test';
  return { context, net, calls: () => syncCalls };
}

(async () => {
  for (const status of [200, 404]) {
    const test = create(); let resolve;
    test.context.fetch = () => new Promise(done => { resolve = done; });
    const pending = vm.runInContext('netOutdated()', test.context);
    test.net.token = 2; test.net.capture = true; test.net.cached = true; test.net.offline = false; test.net.dropped = 7;
    resolve({ ok: status === 200, status, json: async () => ({ capture: false, cached: false, online: false, dropped: 99, error: 'Not Found' }) });
    assert.equal(await pending, false);
    assert.equal(test.net.capture, true); assert.equal(test.net.cached, true); assert.equal(test.net.offline, false);
    assert.equal(test.net.dropped, 7); assert.equal(test.calls(), 0, 'Stale status must not update the new target');
  }
  // Switching while the response body is still being read must be guarded as well.
  const body = create(); let resolveBody, started;
  const reading = new Promise(done => { started = done; });
  body.context.fetch = async () => ({ ok: true, status: 200, json: () => { started(); return new Promise(done => { resolveBody = done; }); } });
  const old = vm.runInContext('netOutdated()', body.context); await reading;
  body.net.token = 2; body.net.capture = true;
  resolveBody({ capture: false }); await old;
  assert.equal(body.net.capture, true); assert.equal(body.calls(), 0);
  // A newer state pushed by the same target also supersedes an older HTTP query.
  const push = create(); let finish;
  push.context.fetch = () => new Promise(done => { finish = done; });
  const older = vm.runInContext('netOutdated()', push.context);
  push.net.sourceRevision++; push.net.offline = false; push.net.dropped = 7;
  finish({ ok: true, status: 200, json: async () => ({ online: false, dropped: 99 }) });
  await older;
  assert.equal(push.net.offline, false); assert.equal(push.net.dropped, 7); assert.equal(push.calls(), 0);
  const current = create();
  current.context.fetch = async () => ({ ok: true, status: 200, json: async () => ({ capture: false, cached: true, online: false, dropped: 2, search: true }) });
  assert.equal(await vm.runInContext('netOutdated()', current.context), false);
  assert.equal(current.net.capture, false); assert.equal(current.net.cached, true); assert.equal(current.net.offline, true);
  assert.equal(current.net.searchSupported, true); assert.equal(current.calls(), 2);

  // Two status queries for the same target can finish in reverse order without any SSE event.
  const overlap = create(), responses = [];
  overlap.context.fetch = () => new Promise(done => responses.push(done));
  const firstStatus = vm.runInContext('netOutdated()', overlap.context);
  const secondStatus = vm.runInContext('netOutdated()', overlap.context);
  responses[1]({ ok: true, status: 200, json: async () => ({ online: true, capture: true, dropped: 3, cached: true }) });
  await secondStatus;
  responses[0]({ ok: true, status: 200, json: async () => ({ online: false, capture: false, dropped: 99 }) });
  await firstStatus;
  assert.equal(overlap.net.offline, false, 'Older same-target response must not overwrite newer status');
  assert.equal(overlap.net.capture, true); assert.equal(overlap.net.dropped, 3); assert.equal(overlap.calls(), 2);

  const paused = create(); paused.net.paused = true;
  for (let batch = 0; batch < 500; batch++) {
    paused.context.batch = Array.from({ length: 50 }, (_, i) => ({ id: i + 1, s: batch * 50 + i + 1, status: batch }));
    vm.runInContext('receiveNetRecords(batch)', paused.context);
  }
  assert.equal(paused.net.pending.size, 50, '25,000 updates must coalesce to 50 requests');
  paused.context.batch = [{ id: 1, s: 1, status: -1 }];
  vm.runInContext('receiveNetRecords(batch)', paused.context);
  assert.equal(paused.net.pending.get(1).status, 499, 'Older replay must not replace a newer pending update');
  for (let start = 51; start <= 6050; start += 128) {
    paused.context.batch = Array.from({ length: Math.min(128, 6051 - start) }, (_, i) => ({ id: start + i, s: 100000 + start + i }));
    vm.runInContext('receiveNetRecords(batch)', paused.context);
    assert(paused.net.pending.size <= 5000);
  }
  const ids = Array.from(paused.net.pending.keys()).sort((a, b) => a - b);
  assert.equal(ids[0], 1051); assert.equal(ids.at(-1), 6050);
  assert.equal(paused.net.seq, 0, 'Paused data must not advance the reconnect cursor');
  vm.runInContext('setNetPaused(false)', paused.context);
  assert.equal(paused.net.pending.size, 0); assert.equal(paused.net.records.size, 5000);
  assert.equal(paused.net.seq, 106050);
  assert.equal(new URL(paused.net.es.url).searchParams.get('since'), '106050');
  paused.net.paused = true; paused.context.batch = [{ id: 7000, s: 106051 }];
  vm.runInContext('receiveNetRecords(batch); resetNet()', paused.context);
  assert.equal(paused.net.pending.size, 0); assert.equal(paused.net.records.size, 0);
  console.log('PASS actual status-query races, paused update coalescing, 5,000-record bound, old replay rejection, resume cursor and clear');
})().catch(error => { console.error(error); process.exitCode = 1; });
