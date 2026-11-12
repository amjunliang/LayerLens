'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Web/app.js', 'utf8');
const start = source.indexOf('function newMCPWindowId()');
const end = source.indexOf('function setupPageActivity()', start);
assert(start >= 0 && end > start);

const requests = [];
const beacons = [];
const timers = [];
const storage = new Map();
let navigationType = 'navigate';
let now = 1000;
const owner = { cls: 'DetailView', parent: { cls: 'DetailController', vcClass: 'DetailController', parent: null } };
const selected = {
  key: '42',
  cls: 'UIButton',
  classChain: ['UIButton', 'UIControl'],
  ivarTraces: ['DetailController.readButton'],
  vcClass: 'DetailController',
  identifier: 'book_detail_read_now',
  title: '',
  text: '立即阅读',
  frame: [10, 20, 100, 44],
  rect: [10, 20, 100, 44],
  hidden: false,
  alpha: 1,
  parent: owner,
};
const context = vm.createContext({
  state: { nodes: new Map([['42', selected]]), selected: '42' },
  $: id => ({ getBoundingClientRect: () => ({ x: id === 'liveWrap' ? 40 : 20, y: 60, width: 500, height: 700 }) }),
  viewKeyOf: key => key,
  currentDevice: () => ({ name: 'iPhone 17 Pro' }),
  targetHistory: {},
  targets: { deviceId: 'sim', bundleId: 'com.reader.readit' },
  targetAppName: () => 'DreamNovel',
  appState: { instanceId: 'launch-1' },
  currentApp: () => null,
  elementLine: node => `${node.ivarTraces[0]} (${node.cls}) "${node.text}" · id=${node.identifier}`,
  swiftUIAncestors: node => (node.swiftUIContext || []).slice(0, -1),
  codeIvars: () => [{ text: 'DetailController.readButton' }],
  isCodeClass: cls => !cls.startsWith('UI'),
  isSwiftUILayoutContext: node => node.cls === 'SwiftUI',
  fetch: (_url, options) => { requests.push(JSON.parse(options.body)); return Promise.resolve(); },
  navigator: { sendBeacon: (_url, body) => { beacons.push(body); return true; } },
  Blob,
  Date: { now: () => now },
  Math,
  globalThis: {},
  document: { documentElement: { dataset: {} } },
  performance: { getEntriesByType: () => [{ type: navigationType }] },
  sessionStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value) },
  setTimeout: fn => { timers.push(fn); return timers.length; },
  clearTimeout() {},
});
vm.runInContext(source.slice(start, end), context);
vm.runInContext('scheduleMCPContext(true);', context);
timers.shift()();
assert.equal(requests.length, 1);
assert.equal(requests[0].focusRequested, true);
assert.equal(requests[0].focusEpoch, 1000);
assert.equal(requests[0].appName, 'DreamNovel');
const { windowId, pageGeneration } = requests[0];
assert.equal(context.document.documentElement.dataset.layerlensWindowId, windowId);
navigationType = 'reload';
const refreshed = context.mcpPageIdentity();
assert.equal(refreshed.windowId, windowId);
assert.equal(refreshed.pageGeneration, pageGeneration + 1);
navigationType = 'navigate';
assert.notEqual(context.mcpPageIdentity().windowId, windowId, 'A new page must ignore inherited storage');
const canvasTarget = [windowId, 'sim', 'com.reader.readit', 'launch-1', pageGeneration];
assert.equal(context.mcpCanvasRect(...canvasTarget).x, 20);
context.state.mode = 'live';
assert.equal(context.mcpCanvasRect(...canvasTarget).x, 40);
assert.equal(context.mcpCanvasRect('another-window', ...canvasTarget.slice(1)), null);
assert.equal(context.mcpCanvasRect(...canvasTarget.slice(0, 3), 'another-launch', pageGeneration), null);
assert.equal(context.mcpCanvasRect(...canvasTarget.slice(0, 4), refreshed.pageGeneration), null);
assert.match(requests[0].selected.element, /DetailController\.readButton/);
assert.match(requests[0].selected.element, /id=book_detail_read_now/);
assert.equal(requests[0].selected.owner, 'DetailView');
assert.equal(requests[0].selected.vc, 'DetailController');
assert.deepEqual(Object.keys(requests[0].selected).sort(), ['element', 'owner', 'vc'], 'Selected node must stay compact');
selected.swiftUIContext = ['ScrollView', 'Label', 'Text'];
selected.cls = 'SwiftUI';
assert.equal(context.mcpSelectedInfo().swiftUIPath, 'ScrollView / Label', 'Captured SwiftUI context must reach MCP');
delete selected.swiftUIContext;
context.state.mode = '2d';
selected.children = [
  {cls: 'SwiftUI', text: '关闭模型信息', children: []},
  {cls: 'SwiftUI', text: 'GPT-6.1 Sol', children: []},
  {cls: 'SwiftUI', text: '隐藏内容', effHidden: true, children: []},
  {cls: 'SwiftUI', text: '关闭模型信息', children: []},
];
assert.deepEqual(Array.from(context.mcpSelectedInfo().hints), ['关闭模型信息', 'GPT-6.1 Sol'], 'Visible SwiftUI hints must be compact and unique');
context.state.mode = 'live';
assert.equal(context.mcpSelectedInfo().hints, undefined, 'Live frames must not claim cached hierarchy hints');
selected.cls = 'UIButton';
now = 2000;
vm.runInContext('scheduleMCPContext(false);', context);
timers.shift()();
assert.equal(requests.at(-1).focusRequested, false);
assert.equal(requests.at(-1).focusEpoch, 1000);
assert.match(source, /select\.detailTimer = setTimeout\(loadDetail, 120\);[\s\S]{0,180}scheduleMCPContext\(true\)/);
vm.runInContext('scheduleMCPContext(true); removeMCPContext();', context);
const beforeClose = requests.length;
timers.shift()();
assert.equal(requests.length, beforeClose, 'A pending publication must not resurrect a closed window');
assert.equal(beacons.length, 1);
assert.equal(context.mcpCanvasRect(...canvasTarget), null);
console.log('PASS MCP web context: focused target, selected node and removal beacon');
