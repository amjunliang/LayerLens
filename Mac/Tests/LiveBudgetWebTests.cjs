'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Web/app.js', 'utf8');
const section = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));

const sent = [], guides = [];
let pausedFrameClosed = 0;
const live = {
  ws: { readyState: 1, send: value => sent.push(JSON.parse(value)) },
  budgetActive: true,
  budgetPaused: false,
  hasFrame: true,
  pendingFrame: { close() { pausedFrameClosed++; } },
};
const context = vm.createContext({
  live,
  WebSocket: { OPEN: 1 },
  pageHasFocus: () => true,
  showLiveGuide: message => guides.push(message),
  t: value => value,
});
vm.runInContext(section('function liveRequestFocus()', 'function liveStop()'), context);
vm.runInContext(section('function liveSend(message)', '// 客户端坐标'), context);

context.liveRequestFocus();
assert.deepEqual(sent, [{ type: 'viewer-focus' }], 'Focused pages must claim the newest viewer position');

context.applyLiveVideoBudget(false);
assert.equal(live.budgetPaused, true);
assert.equal(pausedFrameClosed, 1, 'Demotion must release the cached decoded frame');
assert.equal(guides.at(-1), '实时画面已在其他窗口暂停, 聚焦后恢复');
context.liveSend({ type: 'paste', text: 'blocked' });
context.liveSend({ type: 'release' });
context.liveSend({ type: 'resume' });
context.liveSend({ type: 'viewer-focus' });
assert.deepEqual(sent.slice(1), [{ type: 'release' }, { type: 'resume' }, { type: 'viewer-focus' }],
  'Paused viewers may release input and reclaim focus, but cannot inject new input');

live.pendingFrame = null;
context.applyLiveVideoBudget(true);
assert.equal(live.budgetPaused, false);
assert.equal(live.hasFrame, false);
assert.equal(guides.at(-1), '正在恢复实时画面…');

console.log('PASS live budget UI: focus claim, paused input and restoration state');
