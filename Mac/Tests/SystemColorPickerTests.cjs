'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Web/app.js', 'utf8');
const start = source.indexOf('function handleViewKey(key)');
const end = source.indexOf('function setSpacing(', start);
assert.ok(start >= 0 && end > start);
let calls = 0;
const context = {
  state: { mode: '3d' }, window: { LAYERLENS_APP: true }, picker: { on: false },
  pickScreenColor() { calls++; },
};
vm.createContext(context);
vm.runInContext(source.slice(start, end), context);
assert.equal(context.handleViewKey('c'), true);
assert.equal(calls, 1, 'native 3D invokes the screen picker');
context.window.LAYERLENS_APP = false;
assert.equal(context.handleViewKey('c'), true, 'browser 3D invokes the screen picker');
context.state.mode = '2d';
assert.equal(context.handleViewKey('c'), true);
assert.equal(calls, 3, 'all modes use the shared picker');

const pixelStart = source.indexOf('function picker3DPixel(e)');
const pixelEnd = source.indexOf('function colorHex(', pixelStart);
assert.ok(pixelStart >= 0 && pixelEnd > pixelStart);
let draws = 0, copies = 0;
const context2d = { save() {}, restore() {}, scale() {}, fillRect() {}, drawImage() { copies++; } };
const glCanvas = { width: 400, height: 200, getBoundingClientRect: () => ({ left: 10, top: 20, right: 210, bottom: 120, width: 200, height: 100 }) };
const pixel = {
  stage3D: { canvas: glCanvas, items: [{}], drawVersion: 1 }, picker: {},
  stage3DReady: () => true, currentWindow: () => ({}),
  stage3DDraw() { draws++; pixel.stage3D.drawVersion++; },
  document: { createElement: () => ({ width: 0, height: 0, getContext: () => context2d }) },
  $: () => ({ getBoundingClientRect: () => ({ left: 10, top: 0 }) }),
  getComputedStyle: () => ({ backgroundColor: '#111111', getPropertyValue: () => '#222222' }),
};
vm.createContext(pixel);
vm.runInContext(source.slice(pixelStart, pixelEnd), pixel);
const first = pixel.picker3DPixel({ clientX: 35, clientY: 45 });
assert.equal(first.x, 50); assert.equal(first.y, 50);
pixel.picker3DPixel({ clientX: 40, clientY: 50 });
assert.equal(draws, 1, 'pointer movement reuses the cached frame');
assert.equal(copies, 1);
pixel.stage3D.drawVersion++;
pixel.picker3DPixel({ clientX: 40, clientY: 50 });
assert.equal(draws, 2, 'a new 3D render refreshes the cached frame');
assert.equal(pixel.picker3DPixel({ clientX: 210, clientY: 50 }), null, 'outside canvas is not sampled');

const setupStart = source.indexOf('function setupColorPicker()');
const setupEnd = source.indexOf('let screenColorPending = false;', setupStart);
assert.ok(setupStart >= 0 && setupEnd > setupStart);
class Element { closest() { return true; } }
const listeners = {}, buttons = {}, pane = { addEventListener: (type, fn) => { listeners[type] = fn; } };
let copied = '';
const events = {
  Element, picker: { on: true, color: null, swallow: false }, panKey: { held: false },
  $: id => id === 'canvasPane' ? pane : (buttons[id] ||= { addEventListener() {} }),
  updateLoupe: () => { events.picker.color = { r: 1, g: 2, b: 3 }; },
  hideLoupe() {}, colorHex: () => '#010203', copyText: color => { copied = color; },
  setColorPicker: on => { events.picker.on = on; }, pickScreenColor() {}, setTimeout: fn => fn(),
};
vm.createContext(events);
vm.runInContext(source.slice(setupStart, setupEnd), events);
events.setupColorPicker();
const event = () => ({ target: new Element(), button: 0, prevented: false, stopped: false,
  preventDefault() { this.prevented = true; }, stopPropagation() { this.stopped = true; } });
for (const type of ['wheel', 'gesturechange', 'contextmenu', 'dblclick']) {
  const e = event(); listeners[type](e);
  assert.ok(e.prevented && e.stopped, `${type} cannot change the canvas while sampling`);
}
const click = event(); listeners.pointerdown(click);
assert.ok(click.prevented && click.stopped, 'sampling click does not select an element');
assert.equal(copied, '#010203');
assert.equal(events.picker.on, false, 'sampling completes on click');
const up = event(); listeners.pointerup(up);
assert.ok(up.stopped, 'sampling pointerup cannot reach the canvas');

const bridgeStart = source.indexOf('let screenColorPending = false;');
const bridgeEnd = source.indexOf('// MARK: - Layout', bridgeStart);
assert.ok(bridgeStart >= 0 && bridgeEnd > bridgeStart);
let requests = [], messages = [], notices = [], allowed = true, available = true, blockColor = false, finishColor;
const bridge = {
  window: { LAYERLENS_APP: false },
  crypto: { randomUUID: () => '31944b08-4783-4b82-958f-628d27419bed' },
  picker: { on: false },
  pickerAvailable: () => available,
  setColorPicker: on => { bridge.picker.on = on; },
  fetch: async (url, options) => {
    requests.push({ url, options });
    if (blockColor && url === '/api/hub/screen-color') await new Promise(resolve => { finishColor = resolve; });
    return { ok: true, json: async () => url.endsWith('/status') ? { screenCaptureAllowed: allowed } : { color: '#123456' } };
  },
  t: (message, value) => message.replace('{0}', value),
  toast: (...args) => notices.push(args),
};
vm.createContext(bridge);
vm.runInContext(source.slice(bridgeStart, bridgeEnd), bridge);
(async () => {
  await bridge.pickScreenColor();
  assert.equal(requests[0].url, '/api/hub/screen-color/status');
  assert.equal(requests[1].url, '/api/hub/screen-color');
  assert.equal(requests[1].options.method, 'POST');
  assert.equal(notices[0][0], '已复制颜色: #123456');
  bridge.window = { LAYERLENS_APP: true, webkit: { messageHandlers: { layerlens: { postMessage: value => messages.push(value) } } } };
  await bridge.pickScreenColor();
  assert.equal(messages[0].action, 'pickScreenColor');
  assert.equal(requests.length, 3, 'native windows use the existing bridge after the permission check');
  allowed = false;
  await bridge.pickScreenColor();
  assert.equal(bridge.picker.on, true, 'without permission use the existing canvas picker');
  assert.equal(messages.length, 1, 'fallback never opens the system permission prompt');
  await bridge.pickScreenColor();
  assert.equal(bridge.picker.on, false, 'the same button exits the canvas picker');
  available = true;
  await bridge.pickScreenColor();
  assert.equal(bridge.picker.on, true, '3D also falls back to canvas color picking');
  bridge.picker.on = false;
  bridge.window = { LAYERLENS_APP: false };
  allowed = true; blockColor = true;
  const pending = bridge.pickScreenColor();
  await new Promise(resolve => setImmediate(resolve));
  bridge.cancelPendingScreenColor();
  assert.equal(requests.at(-1).url, '/api/hub/screen-color/cancel');
  assert.equal(JSON.parse(requests.at(-1).options.body).id, '31944b08-4783-4b82-958f-628d27419bed');
  finishColor(); await pending;
  console.log('PASS screen color picker: native and browser entry points');
})().catch(error => { console.error(error); process.exitCode = 1; });
