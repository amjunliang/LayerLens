const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const code = fs.readFileSync(path.join(__dirname, '../../Web/net-capture.js'), 'utf8');
function create() {
  const button = { classList: { toggle() {} }, setAttribute() {}, disabled: false };
  const requests = [], messages = [], historyWrites = [];
  let connects = 0;
  const context = {
    targets: { deviceId: 'phone-a', bundleId: 'app-a' }, targetHistory: { newerDevice: { name: 'keep-me' } },
    net: { capture: false, session: '', archive: '', active: true },
    logTargetKey: () => context.targets.deviceId + '/' + context.targets.bundleId,
    $: id => id === 'netCapture' ? button : {}, t: value => value, toast: (...args) => messages.push(args),
    replaceTargetHistory: history => { historyWrites.push(history); context.targetHistory = history; },
    netConnect: () => connects++,
    scheduleNetRender() {},
    fetch: (_url, options) => new Promise(resolve => requests.push({ body: JSON.parse(options.body), resolve })),
  };
  vm.createContext(context); vm.runInContext(code, context);
  const set = enabled => vm.runInContext(`setNetCapture(${enabled})`, context);
  const reply = (index, ok = true) => requests[index].resolve({ ok, status: ok ? 200 : 500, json: async () => ({ history: { obsolete: true }, error: 'failed' }) });
  return { context, button, requests, messages, historyWrites, set, reply, connects: () => connects };
}

(async () => {
  const switched = create(); const pending = switched.set(true);
  switched.context.targets = { deviceId: 'phone-b', bundleId: 'app-b' };
  switched.reply(0); await pending;
  assert.equal(switched.historyWrites.length, 0, 'Old settings response must not replace the current global history');
  assert.equal(switched.context.targetHistory.newerDevice.name, 'keep-me');
  assert.equal(switched.context.net.capture, false); assert.equal(switched.connects(), 0); assert.equal(switched.messages.length, 0);
  const current = create(); const enabled = current.set(true);
  assert.equal(current.button.disabled, true);
  await current.set(true); assert.equal(current.requests.length, 1, 'Duplicate clicks must not submit another write');
  current.reply(0); await enabled;
  assert.equal(current.context.net.capture, true); assert.equal(current.button.disabled, false);
  assert.equal(current.historyWrites.length, 0); assert.equal(current.connects(), 1);
  // A subsequent opposite setting runs after the prior write, not in parallel with it.
  const disabled = current.set(false); assert.equal(current.requests.length, 2);
  assert.equal(current.requests[1].body.enabled, false); current.reply(1); await disabled;
  assert.equal(current.context.net.capture, false); assert.equal(current.connects(), 2);
  const failed = create(); const bad = failed.set(true); failed.reply(0, false); await bad;
  assert.equal(failed.context.net.capture, false); assert.equal(failed.button.disabled, false);
  assert.equal(failed.messages.length, 1); assert.equal(failed.connects(), 0);
  // The original target's in-flight write must not block another target's write.
  const parallel = create(); const a = parallel.set(true);
  parallel.context.targets = { deviceId: 'phone-b', bundleId: 'app-b' };
  const b = parallel.set(false); assert.equal(parallel.requests.length, 2);
  assert.equal(parallel.requests[0].body.device, 'phone-a'); assert.equal(parallel.requests[1].body.device, 'phone-b');
  parallel.reply(1); await b; parallel.reply(0); await a;
  assert.equal(parallel.messages.length, 1); assert.equal(parallel.historyWrites.length, 0);
  assert.equal(parallel.context.net.capture, false);
  const staleError = create(); const old = staleError.set(true);
  staleError.context.targets = { deviceId: 'phone-b', bundleId: 'app-b' };
  staleError.reply(0, false); await old; assert.equal(staleError.messages.length, 0);
  // Viewing an archive stays selected while the capture state is rechecked.
  const archive = create(); archive.context.net.session = 'saved-launch';
  const archiveWrite = archive.set(true); archive.reply(0); await archiveWrite;
  assert.equal(archive.context.net.session, 'saved-launch'); assert.equal(archive.connects(), 1);
  console.log('PASS capture actions: no history rollback, target isolation, duplicate prevention, failure recovery and archive preservation');
})().catch(error => { console.error(error); process.exitCode = 1; });
