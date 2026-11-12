const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('Web/app.js', 'utf8');
const code = source.slice(source.indexOf('const commandRuns ='), source.indexOf('function syncLiveCursor()'));
const requests = [], modes = [], timers = [], activations = [];
let timerID = 0;
function firePoll() {
  const index = timers.findLastIndex(item => item.delay === 1000);
  assert(index >= 0, 'Expected a run status poll');
  return timers.splice(index, 1)[0].callback();
}
const session = new Map();
let followGuard = null;
const node = { classList: { toggle() {} }, setAttribute() {}, title: '', hidden: true, textContent: '' };
const ctx = { Map, crypto: { randomUUID: () => 'window-1' }, localStorage: { getItem: () => null },
  sessionStorage: { getItem: key => session.get(key) || null, setItem: (key, value) => session.set(key, value) },
  targets: { deviceId: 'phone', bundleId: 'A' }, pageActivity: {active: true}, xcode: { running: false }, $: () => node,
  commandFollowGuard: () => followGuard, saveCommandFollowGuard() {}, finishCommandFollowGuard() {},
  currentDevice: () => ({id: 'phone'}), currentApp: () => ({appName: 'B'}),
  activateSelectedAppLater: (...args) => activations.push(args),
  t: text => text, toast() {}, AbortController,
  setTimeout: (callback, delay) => { const id = ++timerID; timers.push({id, callback, delay}); return id; },
  clearTimeout: id => { const index = timers.findIndex(item => item.id === id); if (index >= 0) timers.splice(index, 1); },
  xcodeRun() {}, setMode: mode => modes.push(mode),
  fetch: (url, options) => new Promise((resolve, reject) => {
    requests.push({url, options, resolve, reject});
    options?.signal?.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), {name: 'AbortError'})), {once: true});
  }) };
vm.createContext(ctx); vm.runInContext(code, ctx);
const reply = (r, data) => r.resolve({ok: true, json: async () => data});
(async () => {
  const a = ctx.commandRun();
  ctx.targets.bundleId = 'B'; const b = ctx.commandRun();
  ctx.targets.bundleId = 'A'; const c = ctx.commandRun();
  const bodies = requests.map(r => JSON.parse(r.options.body));
  assert.deepEqual(bodies.map(x => x.app), ['A', 'B', 'A']);
  assert.deepEqual(bodies.map(x => x.order), [1, 2, 3]);
  assert(bodies.every(x => x.device === 'phone' && x.owner === 'window-1'));
  for (let i = 0; i < 3; i++) reply(requests[i], {runId: String(i)});
  await Promise.all([a, b, c]);
  ctx.runSelected();
  assert.deepEqual(modes, [], 'Cancelling must not change the view');
  ctx.targets.bundleId = 'C'; ctx.runSelected();
  assert.deepEqual(modes, [], 'A run request must not switch before build starts');
  const start = requests.at(-1); reply(start, {runId: 'C'});
  await new Promise(resolve => setImmediate(resolve));
  let pending = firePoll();
  reply(requests.at(-1), {status: 'resolving', buildStarted: false}); await pending;
  assert.deepEqual(modes, [], 'Project lookup must not switch the view');
  pending = firePoll();
  reply(requests.at(-1), {status: 'building', buildStarted: true}); await pending;
  assert.deepEqual(modes, ['live'], 'Build start must switch to live');
  pending = firePoll();
  reply(requests.at(-1), {status: 'succeeded', buildStarted: true}); await pending;
  assert.deepEqual(modes, ['live'], 'A run must switch at most once');
  ctx.targets.bundleId = 'D'; ctx.runSelected(); reply(requests.at(-1), {runId: 'D'});
  await new Promise(resolve => setImmediate(resolve));
  pending = firePoll();
  reply(requests.at(-1), {status: 'failed', detail: 'No project', buildStarted: false}); await pending;
  assert.deepEqual(modes, ['live'], 'A lookup failure must leave the view unchanged');
  ctx.targets.bundleId = 'A';
  const restoring = ctx.restoreCommandRuns();
  const snapshot = requests.at(-1);
  assert.equal(snapshot.url, '/api/hub/command-runs');
  reply(snapshot, {runs: [{runId: 'restored', device: 'phone', app: 'A', status: 'building', buildStarted: true}]});
  await restoring;
  assert.equal(vm.runInContext("commandRuns.get('phone|A').id", ctx), 'restored', 'Reload must recover the active run by device and app');
  assert.equal(vm.runInContext("commandRuns.get('phone|A').liveSwitched", ctx), true, 'Reload must not unexpectedly change the view');
  const revisionRestore = ctx.restoreCommandRuns();
  const staleSnapshot = requests.at(-1);
  ctx.targets.bundleId = 'E'; ctx.runSelected();
  reply(staleSnapshot, {runs: [{runId: 'old', device: 'phone', app: 'A'}]});
  await revisionRestore;
  assert.equal(vm.runInContext("commandRuns.has('phone|A')", ctx), false, 'Late snapshots must not override a newer run');
  ctx.targets.bundleId = 'F'; ctx.runSelected(); reply(requests.at(-1), {runId: 'F-old'});
  await new Promise(resolve => setImmediate(resolve));
  const oldPoll = firePoll();
  const oldStatus = requests.at(-1);
  ctx.targets.bundleId = 'G'; ctx.runSelected();
  ctx.targets.bundleId = 'F'; ctx.runSelected();
  reply(oldStatus, {status: 'succeeded', buildStarted: true}); await oldPoll;
  assert.equal(vm.runInContext("commandRuns.has('phone|F')", ctx), true, 'A stale status must not clear a newer run for the same app');
  followGuard = {device: 'phone', app: 'A', pending: true};
  ctx.targets.deviceId = 'phone'; ctx.targets.bundleId = 'B';
  ctx.restoreSelectedAfterCommand({device: 'phone', app: 'A'}, 'succeeded');
  assert.deepEqual(activations[0], ['phone', 'B', 'B', 'switch', false], 'After A launches, restore the app the user selected without forcing live mode');
  ctx.restoreSelectedAfterCommand({device: 'phone', app: 'A'}, 'failed');
  assert.equal(activations.length, 1, 'A failed build must not reactivate an app');
  ctx.pageActivity.active = false;
  ctx.restoreSelectedAfterCommand({device: 'phone', app: 'A'}, 'succeeded');
  assert.equal(activations.length, 1, 'A background page must not take over the device');
  ctx.reportCommandSelection('phone', 'B');
  const selection = JSON.parse(requests.at(-1).options.body);
  assert.equal(selection.app, 'B'); assert.equal(selection.owner, 'window-1');
  assert.equal(selection.explicit, false, 'Automatic selection reports must be marked as automatic');
  ctx.reportCommandSelection('phone', 'A', true);
  assert.equal(JSON.parse(requests.at(-1).options.body).explicit, true, 'User selections must be marked explicit');
  const savedOwner = JSON.parse(session.get('layerlens_command_run_owner'));
  assert.equal(savedOwner.order, selection.order + 1, 'Selection order must survive a page reload');
  const refreshed = {...ctx, crypto: {randomUUID: () => 'new-window'}};
  vm.createContext(refreshed); vm.runInContext(code, refreshed);
  assert.equal(vm.runInContext('commandRunOwner', refreshed), 'window-1', 'A reload must preserve the run owner');
  refreshed.reportCommandSelection('phone', 'A');
  const afterReload = JSON.parse(requests.at(-1).options.body);
  assert.equal(afterReload.order, selection.order + 2, 'Selection order must increase after reload');
  ctx.restoreSelectedAfterCommand({device: 'phone', app: 'A'}, 'skipped');
  assert.equal(activations.length, 1, 'Skipping A must not relaunch B');
  ctx.targets.bundleId = 'H'; ctx.runSelected(); reply(requests.at(-1), {runId: 'H'});
  await new Promise(resolve => setImmediate(resolve));
  const timedPoll = firePoll();
  const timeoutIndex = timers.findLastIndex(item => item.delay === 5000);
  assert(timeoutIndex >= 0, 'A status query must have a timeout');
  timers.splice(timeoutIndex, 1)[0].callback();
  await timedPoll;
  assert(node.textContent.includes('正在重新连接运行状态'), 'A stalled status request must show retry feedback');
  assert(timers.some(item => item.delay === 1000), 'A timed-out status request must retry');
  console.log('PASS command run UI: rapid A/B/A, build-time switch and lookup failure');
})().catch(error => { console.error(error); process.exitCode = 1; });
