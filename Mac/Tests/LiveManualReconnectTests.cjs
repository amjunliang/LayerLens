'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Web/app.js', 'utf8');
const code = source.slice(source.indexOf('function liveStart()'), source.indexOf('// 原生视频输出状态'));
const nodes = new Map();
const node = id => { if (!nodes.has(id)) nodes.set(id, { hidden: true, textContent: '' }); return nodes.get(id); };
let retryTimers = 0, stopCount = 0;
const live = { udid: 'sim', real: false, error: '', frames: 0, ws: null, hasFrame: true, connected: true };
class Socket { static OPEN = 1; constructor() { this.readyState = 1; } }
const context = vm.createContext({ live, LANG: 'zh', WebSocket: Socket, VideoDecoder: class {},
  location: {host: '127.0.0.1'}, state: {mode:'live'}, $: node,
  liveAvailable: () => true, liveSupported: () => true, layoutLive() {}, showLiveGuide() {},
  clearTimeout() {}, setTimeout() { retryTimers++; }, startLiveDeadline() {},
  liveStop() { stopCount++; live.ws = null; }, t: value => value,
});
vm.runInContext(source.slice(source.indexOf('function invalidateLiveTouchChecks()'), source.indexOf('function liveStart()')), context);
vm.runInContext(code, context);
context.liveStart();
const ws = live.ws;
ws.onmessage({data: JSON.stringify({type:'capture-stalled'})});
assert.equal(node('liveCaptureWarning').hidden, false, 'A stalled existing frame must show manual reconnect');
assert.equal(stopCount, 0, 'Stalled capture must not interrupt the session');
ws.onmessage({data: JSON.stringify({type:'capture-recovered'})});
assert.equal(node('liveCaptureWarning').hidden, false, 'An encoder keyframe alone must not clear the warning');
context.markLiveCaptureReady();
assert.equal(node('liveCaptureWarning').hidden, true, 'A decoded frame clears the warning');
ws.onclose();
assert.equal(stopCount, 1);
assert.equal(retryTimers, 0, 'Closed simulator socket must wait for a user reconnect');
assert.match(live.error, /手动重新连接/);
console.log('PASS simulator manual reconnect: stall warning, natural recovery and no automatic socket retry');
