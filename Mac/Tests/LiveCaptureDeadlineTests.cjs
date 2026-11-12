'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Web/app.js', 'utf8');
const code = source.slice(source.indexOf('function startLiveDeadline('), source.indexOf('function liveStart()'));
let timer, delay, stopped = 0, shown = '';
const ws = {};
const live = { ws, real: false, budgetPaused: false };
const context = vm.createContext({ live, LANG: 'zh',
  clearTimeout() {}, setTimeout(fn, ms) { timer = fn; delay = ms; return 1; },
  liveStop() { stopped++; }, showLiveGuide(message) { shown = message; },
});
vm.runInContext(code, context);
context.startLiveDeadline(ws);
assert.equal(delay, 12000);
live.budgetPaused = true; timer();
assert.equal(stopped, 0, 'A budget-paused viewer must not time out');
live.budgetPaused = false; live.ws = {}; timer();
assert.equal(stopped, 0, 'A stale timer must not stop a replacement socket');
live.ws = ws; timer();
assert.equal(stopped, 0, "Simulator timeout must not close its live connection");
assert.match(shown, /模拟器/);
live.real = true; context.startLiveDeadline(ws);
assert.equal(delay, 5000);
timer(); assert.equal(stopped, 1); assert.match(shown, /解锁/);
console.log('PASS live deadlines: simulator retry, inactive viewers, replaced sockets and real device');
