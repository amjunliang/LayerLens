const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../../Web/app.js'), 'utf8');
const code = source.slice(source.indexOf('const RUN_POLL_MS ='), source.indexOf('function setLiveInspect(on)'));
function create(ignoreAbort = false) {
  const timers = new Map(), requests = [], states = [], notices = [], modes = [];
  let serial = 0;
  const ctx = {
    AbortController, TypeError, targets: { deviceId: 'phone-a', bundleId: 'app-a' }, appState: { connected: true }, currentApp: () => ({foreground: true}), appInBackground: app => app.foreground === false,
    $: () => ({ classList: { toggle() {} } }), t: text => text,
    setMode: mode => modes.push(mode),
    setAppState: state => { states.push(state); ctx.appState.value = state; }, toast: text => notices.push(text),
    setTimeout: (callback, delay) => { timers.set(++serial, { callback, delay }); return serial; },
    clearTimeout: id => timers.delete(id),
    fetch: (url, options) => new Promise((resolve, reject) => {
      requests.push({ url, options, resolve, reject });
      if (!ignoreAbort) options.signal.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), { name: 'AbortError' })), { once: true });
    }),
  };
  vm.createContext(ctx); vm.runInContext(code, ctx);
  return {
    ctx, requests, states, notices, timers, modes,
    run: () => ctx.xcodeRun(), stop: () => ctx.setRunning(false),
    running: () => vm.runInContext('xcode.running', ctx),
    reply: (index, data, ok = true) => requests[index].resolve({ ok, status: ok ? 200 : 400, json: async () => data }),
    fire: async delay => {
      const entry = [...timers].find(([, value]) => value.delay === delay);
      assert(entry, `Missing timer ${delay}`); timers.delete(entry[0]);
      await entry[1].callback();
    },
  };
}
(async () => {
  const stale = create(true), first = stale.run();
  stale.stop(); stale.ctx.targets = { deviceId: 'phone-b', bundleId: 'app-b' };
  const second = stale.run();
  stale.reply(0, { switched: false }); await first;
  assert.equal(stale.running(), true);
  assert.deepEqual(stale.states, []); assert.deepEqual(stale.notices, []);
  assert.deepEqual(JSON.parse(stale.requests[0].options.body), { app: 'app-a', device: 'phone-a' });
  assert.deepEqual(JSON.parse(stale.requests[1].options.body), { app: 'app-b', device: 'phone-b' });
  stale.reply(1, { runId: 'run-a' }); await second;
  assert.deepEqual(stale.states, []); stale.stop();

  const cancelled = create(true), cancelledRun = cancelled.run();
  await cancelled.run(); // Second click stops tracking while the first response is pending.
  cancelled.reply(0, { runId: 'run-a' }); await cancelledRun;
  assert.equal(cancelled.running(), false); assert(!cancelled.states.includes('restarting'));
  assert.equal(cancelled.timers.size, 0);

  const timeout = create(), pending = timeout.run();
  await timeout.fire(30000); await pending;
  assert.equal(timeout.running(), false); assert.equal(timeout.timers.size, 0);
  assert(timeout.notices.includes('等待超时, 请在 Xcode 查看'));

  const body = create(), bodyRun = body.run();
  let reading = false;
  body.requests[0].resolve({ ok: true, json: () => new Promise((resolve, reject) => {
    reading = true;
    body.requests[0].options.signal.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), { name: 'AbortError' })), { once: true });
  }) });
  await new Promise(resolve => setImmediate(resolve)); assert(reading);
  await body.fire(30000); await bodyRun;
  assert.equal(body.running(), false); assert(!body.states.includes('restarting'));

  const busy = create(), busyRun = busy.run();
  busy.reply(0, { error: 'xcode_busy' }, false); await busyRun;
  assert.equal(busy.running(), false); assert(busy.notices.includes('Xcode 正忙, 请稍后再试'));

  const poll = create(true), started = poll.run();
  poll.reply(0, { runId: 'run-a' }); await started;
  const status = poll.fire(1000);
  assert(poll.requests[1].url.includes('run=run-a'));
  poll.stop(); poll.ctx.targets.bundleId = 'app-b';
  const next = poll.run(); poll.reply(2, { runId: 'run-a' }); await next;
  poll.reply(1, { status: 'failed', detail: 'old failure' }); await status;
  assert.equal(poll.running(), true); assert.deepEqual(poll.states, []);
  assert.deepEqual(poll.notices, []); poll.stop();
  const background = create(), backgroundRun = background.run();
  background.ctx.appState.value = 'online';
  background.ctx.state = {mode: 'live'};
  let follows = 0;
  background.ctx.checkForeground = () => follows++;
  vm.runInContext(source.slice(source.indexOf('function receiveTargetForeground('), source.indexOf('function mergeTargetStates()')), background.ctx);
  background.ctx.receiveTargetForeground('phone-a', 'app-a', false);
  assert.equal(follows, 1, 'Foreground following still runs during compile');
  background.ctx.appState.value = 'offline';
  background.ctx.receiveTargetForeground('phone-a', 'app-a', false);
  assert.equal(background.ctx.appState.value, 'background', 'Explicit background must recover offline tracking');
  assert.equal(follows, 2);
  background.ctx.currentApp = () => ({foreground: false});
  background.reply(0, {runId: 'run-a'}); await backgroundRun;
  assert.deepEqual(background.states, ['background', 'background'], 'Run acknowledgement must not hide background changes');
  background.ctx.appState.connected = false; // Background SDK may already be suspended.
  const failure = background.fire(1000);
  background.reply(1, {status: 'failed', detail: 'build failed'}); await failure;
  assert.equal(background.states.at(-1), 'background', 'Failed run must not mark background app online');
  const switchOnBuild = create(), pendingSwitch = switchOnBuild.run();
  assert.deepEqual(switchOnBuild.modes, [], 'Xcode lookup must not switch the view');
  switchOnBuild.reply(0, {runId: 'accepted'}); await pendingSwitch;
  assert.deepEqual(switchOnBuild.modes, ['live'], 'Accepted Xcode run switches to live');
  switchOnBuild.stop();
  const lookupFailure = create(), failedLookup = lookupFailure.run();
  lookupFailure.reply(0, {error: 'project_not_open'}, false); await failedLookup;
  assert.deepEqual(lookupFailure.modes, [], 'Xcode lookup failure must not switch the view');
  const missing = create(), missingRun = missing.run();
  missing.reply(0, {switched: false}); await missingRun;
  assert.equal(missing.running(), false, 'Unverified run must never enter status polling');
  console.log('PASS Xcode run: target isolation, cancellation, request timeout and stale status replies');
})().catch(error => { console.error(error); process.exitCode = 1; });
