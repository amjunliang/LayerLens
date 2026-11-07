'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Web/app.js', 'utf8');
const css = fs.readFileSync('Web/app.css', 'utf8');
const section = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));

class Classes {
  values = new Set();
  add(value) { this.values.add(value); }
  remove(value) { this.values.delete(value); }
  contains(value) { return this.values.has(value); }
  toggle(value, on) { on ? this.add(value) : this.remove(value); }
}
const body = { classList: new Classes() };
const panel = { hidden: true, removeAttribute() {} };
const splitter = { hidden: true };
const net = { selected: 0, detail: null, detailToken: 0 };
let loaded = 0, closed = 0;
const context = vm.createContext({
  net,
  $: (id) => ({ netBody: body, netDetail: panel, netSplitter: splitter })[id],
  scheduleNetRender() {},
  loadNetDetail: id => { loaded = id; },
  closeNetDetail: () => { closed++; },
  t: value => value,
  el: (tag, className) => ({ tag, className }),
  netDetailHead: record => ({ record }),
  setNetDetail() {},
});
vm.runInContext(section('function selectNet(id)', 'function moveNetSelection('), context);
context.selectNet(7);
assert.equal(body.classList.contains('has-detail'), true, 'Selecting a request opens detail state');
assert.equal(loaded, 7);
context.selectNet(0);
assert.equal(body.classList.contains('has-detail'), false, 'Clearing selection removes detail state');
assert.equal(closed, 1);

body.classList.add('has-detail');
vm.runInContext(section('function closeNetDetail()', 'function netApi('), context);
context.closeNetDetail();
assert.equal(body.classList.contains('has-detail'), false, 'Back action returns to the request list');
assert.equal(panel.hidden, false, 'Desktop detail placeholder remains available');

assert.match(source, /el\('button', 'icon-btn net-detail-back'\)/);
assert.match(source, /back\.addEventListener\('click', closeNetDetail\)/);
assert.match(css, /\.net-body:not\(\.has-detail\) \.net-detail \{ display: none; \}/);
assert.match(css, /\.net-body\.has-detail \.net-detail/);
console.log('PASS network small screen: list-first state, detail open, back action and floating layout');
