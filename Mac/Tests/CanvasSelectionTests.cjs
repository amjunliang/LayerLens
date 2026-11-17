'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Web/app.js', 'utf8');
const section = (a,b) => source.slice(source.indexOf(a),source.indexOf(b,source.indexOf(a)));
class Element { constructor(editing=false) {this.editing=editing;} closest() {return this.editing;} }
for (const mode of ['2d','3d']) {
  const win={key:'second'};let updates=0,detail=0,render=0;
  const state={mode,selected:'label',hover:'label',vcFocus:true,classTarget:{},detail:{},tabBeforeVC:'attr'};
  const ctx={state,Element,picker:{on:false},currentWindow:()=>win,select(){},clearTimeout(){},hideHoverTip(){},setTabButtons(){},renderTree(){},recenterStage(){},renderCanvas(){render++;},updateHighlights(){updates++;},updatePivot(){},loadDetail(){detail++;},document:{body:{classList:{contains:()=>false}},querySelector:()=>null}};
  vm.createContext(ctx);vm.runInContext(section('function clearSelection()', 'function select(key, fromTree)'),ctx);
  assert.equal(ctx.canEscapeClearSelection({target:new Element()}),true);
  ctx.document.querySelector=()=>({});assert.equal(ctx.canEscapeClearSelection({target:new Element()}),false,'Close a menu/dialog first');ctx.document.querySelector=()=>null;
  assert.equal(ctx.canEscapeClearSelection({target:new Element(true)}),false,'Do not steal input/panel Escape');
  ctx.picker.on=true;assert.equal(ctx.canEscapeClearSelection({target:new Element()}),false);ctx.picker.on=false;
  ctx.clearSelection();assert.equal(state.selected,null);assert.equal(state.hover,null);assert.equal(state.classTarget,null);assert.equal(state.vcFocus,false);assert.equal(state.detail,null);assert.equal(state.selectionWindow,win);assert.equal(detail,1);assert.equal(updates,1);
  state.selected='label';state.subtreeOnly=true;ctx.clearSelection();assert.equal(render,mode==='3d'?1:0);
  state.mode='live';state.selected='label';ctx.clearSelection();assert.equal(state.selected,'label','Do not affect device interaction');
}
assert(source.includes('if (node) select(node.key);\n    else clearSelection();'),'Blank click clears selection after the existing drag/cancel guards');

// Safe-area Fit with floating desktop panels.
const fitClasses = new Set();
const wrap = { clientWidth: 1600, clientHeight: 900 };
const fitState = { mode: '2d', zoom: 1, panX: 0, panY: 0, rotX: 0, rotY: 0 };
const fitCtx = {
  state: fitState,
  live: { screen: [390, 844], orientation: 0 },
  LIVE_ROTATION: { 0: 0, 1: 90, 2: 180, 3: -90 },
  DEFAULT_ROT_X: -0.22, DEFAULT_ROT_Y: 0.42,
  isNarrow: () => false,
  document: { body: { classList: { contains: (c) => fitClasses.has(c) } } },
  $: () => wrap,
  getComputedStyle: () => ({
    paddingLeft: '12px', paddingRight: '12px', paddingTop: '8px', paddingBottom: '40px',
    getPropertyValue: (k) => ({ '--tree-w': '300px', '--detail-w': '340px', '--log-h': '240px' }[k] || ''),
  }),
  currentWindow: () => ({ rect: [0, 0, 390, 844] }),
  canvasFrame: (w) => w.rect,
  planFitRatio: () => 1,
  projectedBounds: () => null,
  centerStage() { fitState.panX = 0; fitState.panY = 0; },
  applyStageTransform() {},
  layoutLive() {},
};
vm.createContext(fitCtx);
vm.runInContext(section('function safeCanvasInsets()', 'function centerStage()'), fitCtx);
fitCtx.fitView();
assert.equal(fitState.panX, (313 - 353) / 2, '2D fit must center between floating tree and detail panels');
assert.equal(fitState.panY, 0);
const zoomWithBothPanels = fitState.zoom;
assert(zoomWithBothPanels > 0 && zoomWithBothPanels <= 1);
fitClasses.add('tree-hidden');
fitClasses.add('detail-hidden');
fitCtx.fitView();
assert.equal(fitState.panX, 0, 'Fit with no panels open must center on full canvas');
assert.equal(fitState.panY, 0);
assert.equal(fitState.zoom, 1, 'Full canvas fit restores zoom = 1');
fitClasses.add('log-open');
fitState.mode = 'live';
fitCtx.fitView();
assert.equal(fitState.panX, 0);
assert(fitState.panY < 0, 'Live fit with open bottom log panel must shift center upward into safe area');
assert(fitState.zoom < 1, 'Live fit with open bottom log panel must scale within unobstructed height');

// Focus canvas (hide & restore all panels) on desktop and narrow screens.
const focusClasses = new Set();
let narrowMode = false;
const storage = new Map();
const focusNodes = new Map();
const focusNode = id => {
  if (!focusNodes.has(id)) focusNodes.set(id, { classList: { toggle() {} }, setAttribute() {}, title: '' });
  return focusNodes.get(id);
};
const focusCtx = {
  PANEL_HIDDEN_KEYS: { tree: 't', detail: 'd' },
  LOG_OPEN_KEY: 'l',
  panels: { tree: { hidden: false, auto: false, forced: false }, detail: { hidden: false, auto: false, forced: false } },
  logs: { open: true },
  isNarrow: () => narrowMode,
  localStorage: { setItem: (k, v) => storage.set(k, v) },
  document: { body: { dataset: { view: 'canvas' }, classList: { toggle: (c, on) => on ? focusClasses.add(c) : focusClasses.delete(c), contains: (c) => focusClasses.has(c) } } },
  $: focusNode,
  t: (s) => s,
  setLogMax(max) { focusCtx.document.body.classList.toggle('log-max', !!max); },
  setView(view) {
    if (view !== 'canvas' && focusCtx.document.body.classList.contains('log-max')) focusCtx.setLogMax(false);
    focusCtx.document.body.dataset.view = view;
    focusCtx.syncPanels();
  },
  syncLogPanel() {
    focusCtx.document.body.classList.toggle('log-open', focusCtx.logs.open);
    if (!focusCtx.logs.open) focusCtx.setLogMax(false);
  },
};
vm.createContext(focusCtx);
vm.runInContext(
  section('function panelHidden(name)', '// 按布局宽度计算自动收起'),
  focusCtx
);
focusCtx.syncPanels();
assert.equal(focusCtx.allPanelsCleared(), false);
focusCtx.setLogMax(true);
focusCtx.toggleFocusCanvas();
assert.equal(focusCtx.allPanelsCleared(), true, 'Desktop focus toggle must clear all open panels');
assert.equal(focusCtx.logs.open, false);
assert.equal(focusClasses.has('log-max'), false);
assert.equal(focusNode('panelsToggle').getAttribute ? undefined : focusNode('panelsToggle').title, '恢复面板 (\\)');
focusCtx.toggleFocusCanvas();
assert.equal(focusCtx.allPanelsCleared(), false, 'Second toggle must restore previous panel layout');
assert.equal(focusCtx.panels.tree.hidden, false);
assert.equal(focusCtx.panels.detail.hidden, false);
assert.equal(focusCtx.logs.open, true);
assert.equal(focusClasses.has('log-max'), true, 'Desktop restore must keep maximized bottom panel');

narrowMode = true;
focusCtx.document.body.dataset.view = 'canvas';
focusCtx.logs.open = true;
focusCtx.setLogMax(true);
focusCtx.toggleFocusCanvas();
assert.equal(focusCtx.document.body.dataset.view, 'canvas');
assert.equal(focusCtx.logs.open, false);
assert.equal(focusClasses.has('log-max'), false);
focusCtx.toggleFocusCanvas();
assert.equal(focusCtx.document.body.dataset.view, 'canvas');
assert.equal(focusCtx.logs.open, true);
assert.equal(focusClasses.has('log-max'), true, 'Narrow restore must keep maximized bottom panel');

focusCtx.setLogMax(false);
focusCtx.document.body.dataset.view = 'detail';
focusCtx.logs.open = true;
focusCtx.toggleFocusCanvas();
assert.equal(focusCtx.document.body.dataset.view, 'canvas');
assert.equal(focusCtx.logs.open, false);
focusCtx.toggleFocusCanvas();
assert.equal(focusCtx.document.body.dataset.view, 'detail');
assert.equal(focusCtx.logs.open, true);

const dblCtx = {};
vm.createContext(dblCtx);
vm.runInContext(
  section('function isStageBackgroundDoubleClick(', 'function setupCanvasEvents('),
  dblCtx
);
const stageChild = {};
const outside = {};
const stageWrap = { contains: (node) => node === stageWrap || node === stageChild };
assert.equal(dblCtx.isStageBackgroundDoubleClick({ button: 0, target: stageChild, wrap: stageWrap, hasHit: false, mode: '2d', pickerOn: false, mcpTool: null, panHeld: false, recentTouchFit: false }), true);
assert.equal(dblCtx.isStageBackgroundDoubleClick({ button: 0, target: stageWrap, wrap: stageWrap, hasHit: false, mode: '3d', pickerOn: false, mcpTool: null, panHeld: false, recentTouchFit: false }), true);
assert.equal(dblCtx.isStageBackgroundDoubleClick({ button: 0, target: stageChild, wrap: stageWrap, hasHit: true, mode: '2d', pickerOn: false, mcpTool: null, panHeld: false, recentTouchFit: false }), false);
assert.equal(dblCtx.isStageBackgroundDoubleClick({ button: 0, target: stageChild, wrap: stageWrap, hasHit: false, mode: 'live', pickerOn: false, mcpTool: null, panHeld: false, recentTouchFit: false }), false);
assert.equal(dblCtx.isStageBackgroundDoubleClick({ button: 2, target: stageChild, wrap: stageWrap, hasHit: false, mode: '2d', pickerOn: false, mcpTool: null, panHeld: false, recentTouchFit: false }), false);
assert.equal(dblCtx.isStageBackgroundDoubleClick({ button: 0, target: stageChild, wrap: stageWrap, hasHit: false, mode: '2d', pickerOn: true, mcpTool: null, panHeld: false, recentTouchFit: false }), false);
assert.equal(dblCtx.isStageBackgroundDoubleClick({ button: 0, target: stageChild, wrap: stageWrap, hasHit: false, mode: '3d', pickerOn: false, mcpTool: 'rect', panHeld: false, recentTouchFit: false }), false);
assert.equal(dblCtx.isStageBackgroundDoubleClick({ button: 0, target: stageChild, wrap: stageWrap, hasHit: false, mode: '2d', pickerOn: false, mcpTool: null, panHeld: true, recentTouchFit: false }), false);
assert.equal(dblCtx.isStageBackgroundDoubleClick({ button: 0, target: stageChild, wrap: stageWrap, hasHit: false, mode: '2d', pickerOn: false, mcpTool: null, panHeld: false, recentTouchFit: true }), false);
assert.equal(dblCtx.isStageBackgroundDoubleClick({ button: 0, target: outside, wrap: stageWrap, hasHit: false, mode: '2d', pickerOn: false, mcpTool: null, panHeld: false, recentTouchFit: false }), false);
assert(source.includes("if (e.pointerType === 'mouse' || node) {"));
assert(source.includes('isStageBackgroundDoubleClick({'));

// Temporary hide / restore from context menu and refresh reset.
const leaf = { key: 'leaf', parent: null, hidden: false, alpha: 1, children: [] };
const container = { key: 'box', parent: null, hidden: false, alpha: 1, children: [leaf] };
const sibling = { key: 'sib', parent: null, hidden: false, alpha: 1, children: [] };
const nativeHidden = { key: 'off', parent: null, hidden: true, alpha: 1, children: [] };
const root = { key: 'win', parent: null, hidden: false, alpha: 1, children: [container, sibling, nativeHidden] };
leaf.parent = container;
container.parent = root;
sibling.parent = root;
nativeHidden.parent = root;
root.win = container.win = leaf.win = sibling.win = nativeHidden.win = root;
let treeRenders = 0, canvasRenders = 0, detailLoads = 0, hideTipCount = 0;
const tempState = {
  roots: [root],
  nodes: new Map([['win', root], ['box', container], ['leaf', leaf], ['sib', sibling], ['off', nativeHidden]]),
  tempHidden: new Set(),
  selected: 'leaf',
  hover: 'box',
  vcFocus: false,
  tabBeforeVC: null,
  classTarget: null,
  showLayers: false,
  showImages: true,
};
const tempCtx = {
  state: tempState,
  hideHoverTip() { hideTipCount++; },
  loadDetail() { detailLoads++; },
  renderTree() { treeRenders++; },
  renderCanvas() { canvasRenders++; },
  shotURL: (oid, kind) => `/shot/${oid}/${kind}`,
};
vm.createContext(tempCtx);
vm.runInContext(
  section('function syncEffectiveHidden()', 'function keyWindow()') + '\n' +
  section('function shotURLForNode(', 'function renderCanvas()'),
  tempCtx
);
tempCtx.syncEffectiveHidden();
assert.equal(nativeHidden.effHidden, true);
assert.equal(leaf.effHidden, false);
tempCtx.setTempHidden(container, true);
assert.equal(container.tempHidden, true);
assert.equal(container.effHidden, true);
assert.equal(leaf.tempHidden, true);
assert.equal(leaf.effHidden, true);
assert.equal(sibling.effHidden, false);
assert.equal(tempState.selected, null, 'Hiding selected subtree clears stale selection');
assert.equal(tempState.hover, null, 'Hiding hovered subtree clears hover');
assert.equal(hideTipCount, 1);
assert.equal(treeRenders, 1);
assert.equal(canvasRenders, 1);
assert.equal(detailLoads, 1);
assert.equal(tempCtx.hasTempHiddenInWindow(root), true);
tempCtx.setTempHidden(leaf, false);
assert.equal(container.tempHidden, false, 'Unhiding child clears temp-hidden ancestor');
assert.equal(leaf.effHidden, false);
assert.equal(nativeHidden.effHidden, true, 'Native hidden views stay hidden');
tempCtx.setTempHidden(sibling, true);
assert.equal(tempState.tempHidden.size, 1);
tempCtx.clearTempHidden();
assert.equal(tempState.tempHidden.size, 0);
assert.equal(sibling.effHidden, false);
assert.equal(tempCtx.hasTempHiddenInWindow(root), false);
assert(source.includes('function applyHierarchy(roots) {\n  state.tempHidden.clear();'));
assert(source.includes("menu.appendChild(makeItem(t('临时隐藏视图')"));
assert(source.includes("menu.appendChild(makeItem(t('取消临时隐藏')"));
assert(source.includes("menu.appendChild(makeItem(t('恢复全部临时隐藏')"));

console.log('PASS canvas deselection: 2D/3D state, secondary window, subtree, Escape precedence and live isolation');
