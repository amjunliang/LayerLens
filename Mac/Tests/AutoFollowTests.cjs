const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../Web/app.js'), 'utf8');
function section(from, to) {
  const start = source.indexOf(from), end = source.indexOf(to, start);
  assert(start >= 0 && end > start); return source.slice(start, end);
}
function create(bundleId = '') {
  let now = 0, stored = '', url = '', checks = 0;
  const session = new Map();
  const follows = [], fallback = [], states = new Map();
  const a = {bundleId: 'a', appName: 'A', foreground: true, stateConnected: true};
  const b = {bundleId: 'b', appName: 'B', foreground: false, stateConnected: true};
  const phone = {id: 'phone', apps: [a,b]};
  states.set('phone|a', a); states.set('phone|b', b);
  const targets = {devices: [phone, {id: 'other', apps: [{bundleId: 'c', foreground: true, stateConnected: true}]}], deviceId: 'phone', bundleId, pinned: false, followRevision: 0, hadDevice: true};
  const appState = {value: 'online', connected: !!bundleId};
  const state = {selected: null, nodes: new Map()};
  const ctx = {
    targets, appState, state,
    targetStateHub: {ready: true, epoch: 'one', revision: 1, states, foregroundTargets: new Map(), foregroundAmbiguous: new Set()},
    currentDevice: () => targets.devices.find(d => d.id === targets.deviceId),
    currentApp: () => ctx.currentDevice()?.apps.find(a => a.bundleId === targets.bundleId),
    stayingOffline: () => false, pendingSwitch: null, pageActivity: {active: true},
    targetStateKey: (device, app) => device + '|' + app, logTargetKey: () => targets.deviceId + '|' + targets.bundleId,
    loadTargets: async () => {}, AbortController, URLSearchParams,
    Date: {now: () => now}, setTimeout: callback => { now += 400; Promise.resolve().then(callback); return 1; }, clearTimeout() {},
    fetch: async () => ({json: async () => ({foreground: false})}),
    switchTargetInPlace: bundle => { follows.push(bundle); targets.bundleId = bundle; targets.followRevision++; appState.value = 'online'; appState.connected = true; },
    switchTarget: (device, bundle) => { fallback.push({device, bundle, at: now}); targets.deviceId = device; targets.bundleId = bundle; targets.followRevision++; appState.value = 'online'; appState.connected = false; },
    toast() {}, t: text => text, renderTargetMenu: () => checks++,
    TARGET_KEY: 'target', STAY_OFFLINE_KEY: 'offline', localStorage: {setItem: (_, value) => stored = value, getItem: () => stored},
    sessionStorage: {getItem: key => session.get(key) || null, setItem: (key, value) => session.set(key, value), removeItem: key => session.delete(key)}, history: {replaceState: (_, __, value) => url = value}, location: {search: ''},
  };
  vm.createContext(ctx);
  vm.runInContext(section('function appInBackground(app)', '// 选择在后台的 App') +
    section('function selectedTargetInBackground()', 'function switchTargetInPlace(') +
    section('async function probeForeground()', '// 只有 App 明确返回的前后台状态') +
    section('const foregroundCheck = ', '// 定时刷新设备列表') +
    section('function targetBundleId(', '// 地址参数指定的'), ctx);
  return {ctx, targets, appState, a,b, states, follows, fallback,
    stored: () => JSON.parse(stored), url: () => url,
    settle: () => new Promise(resolve => setImmediate(resolve)),
  };
}
(async () => {
  const device = create();
  await device.ctx.checkForeground();
  assert.deepEqual(device.follows, ['a'], 'Selecting a device follows its foreground SDK app');
  device.a.foreground = false; device.b.foreground = true; device.appState.value = 'background';
  await device.ctx.checkForeground();
  assert.deepEqual(device.follows, ['a','b'], 'Same-device app switches keep following');
  device.ctx.setTargetPinned(true);
  assert.equal(device.stored().pinned, true); assert(device.url().includes('pin=1'));
  device.b.foreground = false; device.a.foreground = true; device.appState.value = 'background';
  await device.ctx.checkForeground(); assert.deepEqual(device.follows, ['a','b']);
  assert.equal(device.ctx.nextTarget(), null, 'Pinned target survives discovery changes');
  device.ctx.location.search = device.url(); assert.equal(device.ctx.savedTarget().pinned, true);
  device.ctx.setTargetPinned(false); await device.settle();
  assert.equal(device.stored().pinned, false); assert(!device.url().includes('pin='));
  assert.equal(device.follows.at(-1), 'a', 'Resume following immediately associates current app');

  const running = create('a');
  running.ctx.commandRuns = new Map([['phone|a', {device: 'phone', app: 'a'}]]);
  running.ctx.commandKey = (device, app) => device + '|' + app;
  running.ctx.protectCommandTargetChoice('phone', 'b');
  running.targets.bundleId = 'b'; running.b.foreground = false; running.a.foreground = true; running.appState.value = 'background';
  await running.ctx.checkForeground();
  assert.deepEqual(running.follows, [], 'A running app must not pull the user away from their new selection');
  running.ctx.finishCommandFollowGuard({device: 'phone', app: 'a'});
  await running.ctx.checkForeground();
  assert.deepEqual(running.follows, [], 'A just-launched app must stay suppressed after its run finishes');
  running.ctx.protectCommandTargetChoice('phone', 'a');
  await running.ctx.checkForeground();
  assert.deepEqual(running.follows, ['a'], 'Explicitly choosing the running app releases the guard');

  const desktop = create('a'); desktop.a.foreground = false; desktop.appState.value = 'background';
  await desktop.ctx.checkForeground(); await desktop.settle();
  assert.equal(desktop.fallback.length, 0, 'Background alone must not change the selected target');
  assert.equal(desktop.targets.bundleId, 'a', 'The last selected app remains selected without another foreground app');

  const followed = create('a'); followed.a.foreground = false; followed.b.foreground = true; followed.appState.value = 'background';
  await followed.ctx.checkForeground();
  assert.deepEqual(followed.follows, ['b'], 'Another foreground app still takes over in follow mode');
  assert.equal(followed.targets.bundleId, 'b');

  const advertised = create('a'); advertised.a.foreground = false; advertised.b.foreground = false; advertised.appState.value = 'background';
  advertised.ctx.targetStateHub.foregroundTargets.set('phone', 'b');
  await advertised.ctx.checkForeground();
  assert.deepEqual(advertised.follows, ['b'], 'Mac foreground summary must be used without extra App queries');

  const exited = create('a'); exited.ctx.state.selected = 'label'; exited.ctx.state.nodes.set('label', {});
  exited.a.foreground = false; exited.appState.value = 'offline'; exited.appState.connected = false;
  await exited.ctx.checkForeground(); await exited.settle();
  assert.equal(exited.fallback.length, 1, 'A cache from an exited app still falls back to device-only');

  const unknown = create('a'); unknown.a.foreground = undefined; unknown.appState.connected = false;
  await unknown.ctx.checkForeground(); assert.equal(unknown.fallback.length, 0, 'Timeout alone is not background evidence');
  const oldSDK = create(); oldSDK.a.foreground = undefined;
  await oldSDK.ctx.checkForeground(); assert.equal(oldSDK.follows.length, 0, 'Unknown foreground is not automatically associated');
  const multiple = create(); multiple.b.foreground = true;
  assert.equal(multiple.ctx.firstAppId(multiple.ctx.currentDevice()), '');
  await multiple.ctx.checkForeground(); assert.equal(multiple.follows.length, 0, 'Ambiguous foreground apps are not picked arbitrarily');

  const stale = create('a'); stale.a.foreground = false; stale.appState.value = 'background'; stale.b.stateConnected = false;
  let reply;
  stale.ctx.fetch = () => new Promise(resolve => { reply = resolve; });
  const pending = stale.ctx.checkForeground();
  stale.ctx.setTargetPinned(true);
  reply({json: async () => ({foreground: true})}); await pending;
  assert.equal(stale.follows.length, 0, 'Pin invalidates an in-flight foreground probe');

  const changed = create(); changed.a.stateConnected = false; let respond;
  changed.ctx.fetch = () => new Promise(resolve => { respond = resolve; });
  const probe = changed.ctx.probeForeground(); changed.ctx.targetStateHub.revision++;
  respond({json: async () => ({foreground: true})});
  assert.equal(await probe, null, 'New native state invalidates late HTTP foreground results');
  const malformed = create();
  for (const value of ['com.bjyueyou.dramapro/', '../app', 'app\\path', ' app', 'com..app', '.', 'app?x=1', 'app\n']) {
    malformed.ctx.location.search = '?device=phone&app=' + encodeURIComponent(value) + '&pin=1';
    const target = malformed.ctx.savedTarget();
    assert.equal(target.bundleId, '', 'Malformed URL must fall back to device-only: ' + value);
  }
  malformed.ctx.location.search = '';
  malformed.ctx.localStorage.getItem = () => JSON.stringify({deviceId:'phone', bundleId:'com.app/', pinned:true});
  assert.equal(malformed.ctx.savedTarget().bundleId, '');
  assert.equal(malformed.ctx.savedTarget().pinned, false);
  malformed.ctx.localStorage.getItem = () => JSON.stringify({deviceId:'phone', bundleId:'com.valid-app_1', pinned:true});
  assert.equal(malformed.ctx.savedTarget().bundleId, 'com.valid-app_1');
  console.log('PASS auto-follow: device association, sticky background target, foreground handoff, pin persistence/resume, device isolation, unknown states and stale probes');
})().catch(error => { console.error(error); process.exitCode = 1; });
