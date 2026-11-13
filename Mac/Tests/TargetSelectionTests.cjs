// Run: node Mac/Tests/TargetSelectionTests.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../Web/app.js'), 'utf8');
const offlineSource = fs.readFileSync(path.join(__dirname, '../../Web/offline-view.js'), 'utf8');
function section(start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a);
  assert(a >= 0 && b > a);
  return source.slice(a, b);
}
class Classes {
  values = new Set();
  add(...values) { values.forEach(value => this.values.add(value)); }
  remove(...values) { values.forEach(value => this.values.delete(value)); }
  contains(value) { return this.values.has(value); }
}
class Element {
  classList = new Classes(); children = []; events = {}; dataset = {}; hidden = false; textContent = '';
  append(...nodes) { this.children.push(...nodes); }
  replaceChildren(...nodes) { this.children = nodes; }
  addEventListener(event, action) { this.events[event] = action; }
  get childElementCount() { return this.children.length; }
}
const phone = {id: 'phone', kind: 'device', name: 'Phone', apps: [{bundleId: 'com.example.app', foreground: true}]};
const targets = {devices: [phone], simulators: [], deviceId: 'phone', bundleId: '', deviceOnly: true, hadDevice: true, idle: false};
const targetHistory = {phone: {name: 'Phone', kind: 'device', apps: {'com.example.app': {appName: 'Example'}}}};
const nodes = {}, state = {mode: 'live'}, appState = {value: 'offline', blank: true};
let saved = {}, requestedMode = '', notice = '', pane = '';
const context = vm.createContext({
  targets, targetHistory, state, appState, pendingSwitch: null,
  targetStateHub: {ready: false, foregroundTargets: new Map(), foregroundAmbiguous: new Set()},
  live: {real: true, error: 'stale capture error'}, net: {tab: 'log'},
  savedTarget: () => saved, currentDevice: () => targets.devices.find(d => d.id === targets.deviceId),
  currentDeviceGone: () => !!targets.deviceId && !targets.devices.some(d => d.id === targets.deviceId),
  targetAppName: (device, app) => targetHistory[device]?.apps?.[app]?.appName || app,
  defaultDevice: () => targets.devices[0],
  liveAvailable: () => targets.devices.some(d => d.id === targets.deviceId), liveSupported: () => true,
  simPending: new Map(), LANG: 'zh', t: (text, ...args) => text.replace(/\{(\d+)\}/g, (_, n) => args[n]),
  $: id => nodes[id] ||= new Element(), document: {body: {classList: new Classes()}},
  el: (tag, cls, text = '') => Object.assign(new Element(), {textContent: text}),
  setMode: mode => {requestedMode = mode;}, toast: text => {notice = text;},
  logVisible: () => false, showPaneTab: tab => {pane = tab;},
});
vm.runInContext(offlineSource + '\n' +
                section('function appInBackground(app)', '// 选择在后台的 App') +
                section('function nextTarget()', '// 定时刷新设备列表') +
                section('function pickTarget()', '// 优先有运行中 App 的设备') +
                section('function showLiveGuide(title)', '// Both sources:') +
                section('function showEmptyState(title, body)', '// 没有任何设备时的默认页') +
                section('function requestMode(mode)', '// 画布视图快捷键'), context);
assert.equal(context.nextTarget()[1], 'com.example.app', 'Device selection associates the known foreground app');
targets.deviceId = 'phone'; targets.bundleId = '';
context.targetStateHub.ready = true;
context.targetStateHub.foregroundTargets.set('phone', 'com.example.app');
assert.equal(context.nextTarget()[1], 'com.example.app', 'Mac foreground summary selects without scanning App records');
context.targetStateHub.foregroundTargets.clear();
context.targetStateHub.foregroundAmbiguous.add('phone');
assert.equal(context.nextTarget(), null, 'Ambiguous foreground summaries do not choose arbitrarily');
context.targetStateHub.ready = false;
context.targetStateHub.foregroundAmbiguous.clear();
targets.devices = []; targets.hadDevice = false;
assert.equal(context.nextTarget(), null, 'Disconnected device choice must remain');
context.showLiveGuide(); context.requestMode('live');
assert.equal(requestedMode, 'live'); assert.equal(notice, '');
assert.equal(nodes.emptyTitle.textContent, 'Phone 已断开');
assert.equal(nodes.emptyGuide.hidden, true, 'Device-only has no app log/network actions');
assert.equal(nodes.liveGuide.hidden, true, 'Do not overlay a second live-specific offline guide');
assert.equal(nodes.liveLoading.hidden, true);
assert(nodes.emptyBody.textContent.includes('Phone'));
assert(!nodes.emptyBody.textContent.includes('正在等待连接'));
// All modes retain the same app identity, explanation and useful actions,
// including when a cached hierarchy had previously been available.
targets.bundleId = 'com.example.app'; appState.blank = false;
for (const mode of ['2d', '3d', 'live']) {
  state.mode = mode; context.syncOfflineView();
  assert.equal(nodes.emptyTitle.textContent, 'Example 未连接');
  assert(nodes.emptyBody.textContent.includes('Phone 已断开'));
  assert(nodes.emptyBody.textContent.includes('可以先查看本机保存的日志和抓包'));
  const buttons = nodes.emptyGuide.children[0].children;
  assert.deepEqual(buttons.map(button => button.textContent), ['查看日志', '查看网络']);
  buttons[1].events.click(); assert.equal(pane, 'net');
  assert(nodes.emptyState.classList.contains('offline-state'));
}
targets.devices = [phone]; state.mode = 'live'; appState.blank = true;
assert.equal(context.syncOfflineView(), false, 'App offline must not cover an online device live stream');
assert.equal(nodes.emptyState.hidden, true);
targets.bundleId = '';
assert.equal(context.nextTarget()[1], 'com.example.app', 'Reconnect follows the same device foreground app');
context.showLiveGuide();
assert.equal(nodes.liveLoading.hidden, true, 'Capture error retains retry state');
context.live.error = ''; context.showLiveGuide();
assert.equal(nodes.liveLoading.hidden, false);
saved = {deviceId: 'phone', bundleId: '', explicit: true}; context.pickTarget();
assert.equal(targets.deviceOnly, true);
saved = {deviceId: 'phone', bundleId: 'com.example.app', explicit: true}; context.pickTarget();
assert.equal(targets.deviceOnly, false);
targets.bundleId = ''; targets.hadDevice = true;
assert.equal(context.nextTarget()[1], 'com.example.app');
targets.deviceId = 'sim'; targets.devices = []; targets.simulators = [{id: 'sim', name: 'Simulator'}];
context.showLiveGuide();
assert.equal(nodes.emptyTitle.textContent, 'Simulator 未启动');
assert.equal(nodes.liveLoading.hidden, true);
context.simPending.set('sim', {}); context.showLiveGuide();
assert.equal(nodes.emptyTitle.textContent, 'Simulator · 启动中…');
assert.equal(nodes.emptyGuide.children[0].children[0].disabled, true);
targets.deviceId = ''; context.showLiveGuide();
requestedMode = ''; context.requestMode('live');
assert.equal(requestedMode, ''); assert.equal(notice, '请先选择设备');
assert.equal(nodes.liveGuideTitle.textContent, '请先选择设备');
assert.equal(nodes.liveWaiting.hidden, true);
console.log('PASS device selection and shared offline states/actions across 2D, 3D and Live');

// Foreground probes: a timeout is not evidence of background, and stale replies
// must not overwrite a newer target or state event.
(async () => {
  let key = 'phone|app', reply;
  const status = {source: {}, stateRevision: 0};
  const probe = vm.createContext({
    appState: status, targetStateHub: {ready: false}, targets: {}, targetStateKey: () => '', logTargetKey: () => key, targetBase: () => '/t/phone/app',
    AbortController, setTimeout, clearTimeout,
    fetch: () => new Promise(resolve => { reply = resolve; }),
  });
  vm.runInContext(section('async function probeCurrentBackground()', '// 当前 App 不在前台时查找前台 App:'), probe);
  const respond = foreground => reply({ok: true, json: async () => ({foreground})});
  let pending = probe.probeCurrentBackground(); respond(1);
  assert.equal(await pending, false);
  pending = probe.probeCurrentBackground(); respond(0);
  assert.equal(await pending, true);
  pending = probe.probeCurrentBackground(); key = 'phone|other'; respond(0);
  assert.equal(await pending, null, 'Old target reply must be ignored');
  pending = probe.probeCurrentBackground(); status.stateRevision++; respond(0);
  assert.equal(await pending, null, 'New foreground event wins over old HTTP reply');
  pending = probe.probeCurrentBackground(); status.source = {}; respond(0);
  assert.equal(await pending, null, 'Reconnected event stream invalidates old probe');
  pending = probe.probeCurrentBackground(); respond(undefined);
  assert.equal(await pending, null, 'Missing field is unknown');
  pending = probe.probeCurrentBackground(); reply({ok: false});
  assert.equal(await pending, null, 'HTTP failure is unknown');
  probe.fetch = async () => { throw new Error('timeout'); };
  for (let i = 0; i < 5; i++) assert.equal(await probe.probeCurrentBackground(), null);
  console.log('Foreground probe regression tests passed');
})().catch(error => { console.error(error); process.exitCode = 1; });

// One shared socket per window, selection changes create no App subscriptions.
{
  const sockets = [], transitions = [];
  let renders = 0, follows = 0, reconnects = 0;
  class Socket {
    constructor(url) { this.url = url; sockets.push(this); }
  }
  const a = {deviceId: 'phone', bundleId: 'a', instanceId: 'a1', port: 9527, foreground: true, stateConnected: true};
  const b = {deviceId: 'phone', bundleId: 'b', instanceId: 'b1', port: 9528, foreground: true, stateConnected: true};
  const selection = {devices: [{id: 'phone', apps: [{...a}, {...b}]}, {id: 'other', apps: [{...a, deviceId: 'other'}]}], deviceId: 'phone', bundleId: ''};
  const status = {value: 'online', connected: false};
  const timers = new Map(); let timerID = 0;
  const ctx = vm.createContext({
    targets: selection, appState: status, state: {mode: 'live'}, WebSocket: Socket, URL, pageActivity: {ready: false},
    replaceTargetHistory: () => {}, netCaptureHistoryChanged: () => {}, settleSimPending: () => {},
    location: {href: 'http://127.0.0.1:9523/'},
    logTargetKey: () => selection.deviceId + '|' + selection.bundleId,
    renderTargetMenu: () => renders++, setAppState: value => { status.value = value; transitions.push(value); },
    checkForeground: () => follows++, refresh: () => { throw Error('No hierarchy refresh in Live'); },
    setTimeout: fn => { timers.set(++timerID, fn); return timerID; }, clearTimeout: id => timers.delete(id),
    OFFLINE_GRACE_MS: 4000, reconnected: async () => { reconnects++; status.dropped = false; },
  });
  vm.runInContext(section('const targetStateHub = ', 'async function loadTargets()') +
                  section('function watchApp()', '// link 为提示条'), ctx);
  ctx.ensureTargetStateSocket(); ctx.ensureTargetStateSocket();
  assert.equal(sockets.length, 1);
  const push = (revision, apps, extra = {}) => sockets.at(-1).onmessage({data: JSON.stringify({type: 'states', epoch: 'one', revision, apps, ...extra})});
  push(1, [a,b], {replace: true});
  push(2, [{...b, foreground: false}]);
  assert.equal(selection.devices[0].apps[1].foreground, false);
  assert.deepEqual(transitions, [], 'Device-only selection remains untouched');
  selection.bundleId = 'a'; status.instanceId = 'a1'; ctx.watchApp();
  assert.equal(sockets.length, 1, 'Selecting an App creates no additional socket');
  push(3, [{...a, deviceId: 'other', foreground: false}]);
  assert(!transitions.includes('background'), 'Other device cannot change selected App state');
  push(4, [{...a, foreground: false}]);
  assert.equal(transitions.at(-1), 'background'); assert.equal(follows, 1);
  push(3, [a]);
  assert.equal(selection.devices[0].apps[0].foreground, false, 'Old revision ignored');
  // A late HTTP response is merged with the newer shared state.
  selection.devices[0].apps = [{...a}, {...b}]; ctx.mergeTargetStates();
  assert.equal(selection.devices[0].apps[0].foreground, false);
  push(5, [a]); assert.equal(transitions.at(-1), 'online');
  push(6, [], {removed: [{deviceId: 'phone', bundleId: 'b'}]});
  assert(!selection.devices[0].apps.some(app => app.bundleId === 'b'));
  const original = sockets[0]; original.onclose();
  assert.equal(status.connected, false);
  ctx.ensureTargetStateSocket(); assert.equal(sockets.length, 2);
  push(6, [a], {replace: true});
  assert.equal(status.connected, true); assert.equal(reconnects, 1, 'Reconnect restores same-revision snapshot');
  original.onmessage({data: JSON.stringify({type: 'states', epoch: 'one', revision: 999, apps: [{...a, foreground: false}]})});
  assert.equal(selection.devices[0].apps[0].foreground, true, 'Closed socket messages ignored');
  push(1, [{...a, instanceId: 'a2'}], {epoch: 'new-process', replace: true});
  assert.equal(selection.devices[0].apps[0].instanceId, 'a2', 'New Mac session accepts revision reset');
  selection.bundleId = 'b'; ctx.watchApp();
  assert.equal(sockets.length, 2, 'Target switch reuses shared connection');
  // Device topology can change without changing the App-state revision.
  push(1, [], {epoch: 'new-process', replace: true, inventoryRevision: 1,
    inventory: {devices: [{id: 'new-device', apps: []}], simulators: []}});
  assert.equal(selection.devices[0].id, 'new-device');
  push(1, [], {epoch: 'new-process', replace: true, inventoryRevision: 0,
    inventory: {devices: [{id: 'old-device', apps: []}], simulators: []}});
  assert.equal(selection.devices[0].id, 'new-device', 'Old inventory revision ignored');
  console.log('PASS shared state socket, realtime push, device isolation, late scans, removal and reconnect snapshots');
}

{
  const states = vm.createContext({});
  vm.runInContext(section('function appInBackground(app)', '// 自动选择时优先前台的 App'), states);
  assert.equal(states.appInBackground({suspended: true, foreground: true}), false);
  assert.equal(states.appInForeground({suspended: true, foreground: true}), true);
  assert.equal(states.appInBackground({suspended: true}), false);
  assert.equal(states.appInBackground({foreground: false}), true);
  console.log('PASS scan timeouts do not imply background');
}

// Closed menus do no DOM rebuilding; opening renders once, unchanged data is skipped.
{
  const menu = new Element(); menu.hidden = true;
  let builds = 0, labels = 0;
  menu.replaceChildren = () => builds++;
  const status = {value: 'online', connected: true};
  const ctx = vm.createContext({
    $: () => menu, targets: {devices: [], simulators: []}, targetHistory: {}, appState: status,
    targetMenuUi: {offlineOpen: false, signature: ''}, simPending: new Map(), pendingSwitch: null, LANG: 'zh',
    recordTargetHistory: () => {}, renderTargetLabel: () => labels++, settleBootLaunch: () => {}, syncOfflineView: () => {},
    el: () => new Element(), t: text => text,
    compareTargetDevices: () => 0,
  });
  vm.runInContext(section('function renderTargetMenu()', '// 已启动的设备及其上运行的 App'), ctx);
  ctx.renderTargetMenu(); assert.equal(builds, 0); assert.equal(labels, 1);
  menu.hidden = false; ctx.renderTargetMenu(); assert.equal(builds, 1);
  ctx.renderTargetMenu(); assert.equal(builds, 1);
  status.value = 'background'; ctx.renderTargetMenu(); assert.equal(builds, 2);
  menu.hidden = true; ctx.renderTargetMenu(); menu.hidden = false; ctx.renderTargetMenu();
  assert.equal(builds, 3, 'Opening a previously hidden menu refreshes it');
  console.log('PASS closed menu avoids DOM rebuilds, visible unchanged menu stays stable');
}

// A late HTTP response cannot undo a newer device notification; concurrent loads are coalesced.
(async () => {
  let reply, requests = 0, applied = '';
  const hub = {epoch: 'one', inventoryRevision: 1};
  const ctx = vm.createContext({targetStateHub: hub, AbortController, setTimeout, clearTimeout,
    fetch: () => { requests++; return new Promise(resolve => { reply = resolve; }); },
    applyTargetInventory: data => { applied = data.name; }, ensureTargetStateSocket: () => {}, syncSelectedTargetState: () => {},
  });
  vm.runInContext(section('let targetLoad = null;', '// 模拟器启动 / 关闭:'), ctx);
  const first = ctx.loadTargets(), second = ctx.loadTargets(); assert.equal(requests, 1);
  hub.inventoryRevision = 2;
  reply({ok: true, json: async () => ({name: 'stale'})});
  await Promise.all([first, second]); assert.equal(applied, '');
  const next = ctx.loadTargets(); reply({ok: true, json: async () => ({name: 'fresh'})});
  await next; assert.equal(applied, 'fresh');
  console.log('PASS coalesced list requests and stale HTTP inventory rejection');
})().catch(error => { console.error(error); process.exitCode = 1; });

{
  let replaced = '';
  const ctx = vm.createContext({
    TARGET_KEY: 'layerlens_target',
    targets: {deviceId: 'sim-1', bundleId: 'com.example.app', pinned: false},
    localStorage: {setItem() {}},
    history: {replaceState: (_, __, next) => { replaced = next; }},
    location: {origin: 'http://127.0.0.1:9523', pathname: '/', href: 'http://127.0.0.1:9523/'},
    URLSearchParams,
  });
  vm.runInContext(section('function targetQuery(', 'function setTargetPinned('), ctx);
  ctx.rememberTarget('sim-1', 'com.example.app');
  assert.equal(replaced, '?device=sim-1&app=com.example.app');
  assert.equal(ctx.layerlensBrowserURL(), 'http://127.0.0.1:9523/?device=sim-1&app=com.example.app');
  ctx.targets.pinned = true;
  assert.equal(ctx.layerlensBrowserURL(), 'http://127.0.0.1:9523/?device=sim-1&app=com.example.app&pin=1');
  ctx.targets.bundleId = '';
  assert.equal(ctx.layerlensBrowserURL(), 'http://127.0.0.1:9523/?device=sim-1&app=');
  console.log('PASS browser URL carries current device, app and pin state');
}
