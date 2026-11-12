const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const context = vm.createContext({
  state: { mode: '2d' }, targets: { deviceId: 'device', bundleId: 'app' },
  appState: { instanceId: 'first' }, currentApp: () => null,
});
vm.runInContext(fs.readFileSync('Web/mcp-canvas.js', 'utf8') + '\nglobalThis.canvas = mcpCanvas;', context);
const canvas = context.canvas;
canvas.render = () => {};
canvas.setTool = function (tool) { this.tool = tool; };

canvas.syncTarget();
canvas.tool = 'rectangle';
canvas.marks.push({ shape: 'rectangle', points: [{ x: 0, y: 0 }, { x: 1, y: 1 }] });
context.state.mode = '3d';
canvas.syncTarget();
assert.equal(canvas.marks.length, 0, 'mode changes clear marks from the old projection');
assert.equal(canvas.tool, '', 'mode changes stop annotation input');
assert.equal(canvas.revision, 1);

canvas.marks.push({ shape: 'freehand', points: [{ x: 0, y: 0 }, { x: 1, y: 1 }] });
context.appState.instanceId = 'second';
canvas.syncTarget();
assert.equal(canvas.marks.length, 0, 'app restarts clear stale marks');
assert.equal(canvas.revision, 2);

canvas.marks.push({ shape: 'freehand', points: [{ x: 0, y: 0 }, { x: 1, y: 1 }] });
canvas.tool = 'freehand';
canvas.selectElement();
assert.equal(canvas.marks.length, 0, 'element selection replaces annotation focus');
assert.equal(canvas.tool, '');

// Verify the real overlay consumes hover, wheel and gestures while drawing,
// while the surrounding controls are restored when drawing ends.
const makeElement = () => ({
  classList: { toggle() {}, add() {} }, handlers: {},
  addEventListener(type, fn) { this.handlers[type] = fn; },
  setAttribute() {}, replaceChildren() {}, append() {}, appendChild(child) { child.parentElement = this; },
  getBoundingClientRect() { return { left: 0, top: 0, width: 100, height: 100 }; },
});
const elements = Object.fromEntries(['stageWrap', 'liveWrap', 'modeSeg', 'tree', 'crumbs', 'liveCanvas', 'annotationRect', 'annotationPen', 'annotationUndo', 'annotationClear'].map(id => [id, makeElement()]));
let overlay;
const group = makeElement();
group.id = 'zoomFit'; group.closest = () => null;
const markButton = makeElement(); markButton.id = 'annotationRect'; markButton.closest = () => markButton;
const pickButton = makeElement(); pickButton.id = 'systemColorPick'; pickButton.closest = () => null;
const area = makeElement();
const real = vm.createContext({
  state: { mode: '2d', hover: 'old' }, targets: {}, appState: {}, currentApp: () => null,
  picker: { on: false }, live: { inspect: false }, $: id => elements[id],
  document: { body: makeElement(), activeElement: null,
    querySelectorAll: query => query.startsWith('.canvas-float') ? [group, markButton, pickButton] : query === '.mcp-annotation-layer' ? (overlay ? [overlay] : []) : [area],
    createElementNS: () => (overlay = makeElement()) },
  setPanKey() {}, hideHoverTip() {}, updateHighlights() {}, hidePopovers() {}, scheduleMCPContext() {},
});
vm.runInContext(fs.readFileSync('Web/mcp-canvas.js', 'utf8') + '\nglobalThis.canvas = mcpCanvas;', real);
real.canvas.setTool('rectangle');
assert.equal(group.inert, true);
assert.equal(elements.modeSeg.inert, true);
assert.equal(elements.tree.inert, true);
assert.equal(area.inert, true, 'annotation locks the rest of the app');
assert.equal(markButton.inert, false, 'annotation controls remain available');
assert.equal(real.state.hover, null);
real.canvas.setupLayer(elements.stageWrap);
for (const type of ['wheel', 'gesturestart', 'gesturechange', 'contextmenu', 'dblclick']) {
  let prevented = false, stopped = false;
  overlay.handlers[type]({ preventDefault() { prevented = true; }, stopPropagation() { stopped = true; } });
  assert.ok(prevented && stopped, `${type} must not reach the canvas while drawing`);
}
let hoverStopped = false;
overlay.handlers.pointermove({ stopPropagation() { hoverStopped = true; } });
assert.equal(hoverStopped, true, 'hover must not reach underlying nodes');
real.canvas.marks.push({ shape: 'rectangle', points: [{ x: 0, y: 0 }, { x: 1, y: 1 }] });
real.canvas.exitAndClear();
assert.equal(real.canvas.marks.length, 0, 'Escape removes existing annotations');
assert.equal(real.canvas.tool, '', 'Escape exits annotation mode');
assert.equal(real.canvas.revision, 1, 'clearing changes the canvas revision');
assert.equal(group.inert, false);
assert.equal(elements.modeSeg.inert, false);
assert.equal(elements.tree.inert, false);
assert.equal(area.inert, false);
real.picker.on = true;
real.canvas.syncInteractionLock();
assert.equal(area.inert, true, 'color picking locks the rest of the app');
assert.equal(group.inert, true);
assert.equal(markButton.inert, true);
assert.equal(pickButton.inert, false, 'the picker can still be exited');
real.picker.on = false;
real.canvas.syncInteractionLock();
assert.equal(area.inert, false, 'exiting picker restores interaction');
console.log('MCP canvas state tests passed');
