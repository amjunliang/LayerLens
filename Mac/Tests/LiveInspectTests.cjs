const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../../Web/app.js'), 'utf8');
function section(from, to) {
  const start = source.indexOf(from), end = source.indexOf(to, start);
  assert(start >= 0 && end > start); return source.slice(start, end);
}
function create(real, scale = 3, deferred = false) {
  let finish;
  const pending = deferred ? new Promise(resolve => { finish = resolve; }) : Promise.resolve();
  const hits = [], selected = [];
  let rect, width, height;
  const ctx = {
    live: { real, sourceGeometry: { pointScale: scale }, screen: real ? [1179, 2556] : [393, 852], orientation: 1 },
    LIVE_ROTATION: { 1: 0, 2: 180, 3: -90, 4: 90 },
    appState: { source: {} }, targets: { deviceId: 'phone', bundleId: 'app' }, state: { mode: 'live' },
    setLiveInspect() {},
    $: () => ({ getBoundingClientRect: () => rect, get offsetWidth() { return width; }, get offsetHeight() { return height; } }),
    keyWindow: () => ({ key: 'window', rect: [10, 20, 393, 852] }),
    hitTest: (x, y) => { hits.push([x, y]); return { key: 'label' }; }, select: key => selected.push(key),
  };
  vm.createContext(ctx);
  ctx.setMode = async () => { vm.runInContext('++modeSeq', ctx); await pending; ctx.state.mode = '2d'; };
  vm.runInContext('let modeSeq = 0;\n' + section('function livePoint(e)', 'function liveRotate()') + section('async function inspectAt(point)', '// 静止按住多久'), ctx);
  return {
    ctx, hits, selected, finish: () => finish(),
    click: async (orientation, zoom) => {
      ctx.live.orientation = orientation;
      width = 280 * zoom; height = 607.125 * zoom;
      const rad = ctx.LIVE_ROTATION[orientation] * Math.PI / 180;
      const quarter = Math.abs(ctx.LIVE_ROTATION[orientation]) === 90;
      rect = { left: 137, top: 88, width: quarter ? height : width, height: quarter ? width : height };
      const dx = -0.1 * width, dy = -0.25 * height;
      const point = ctx.livePoint({ clientX: rect.left + rect.width / 2 + dx * Math.cos(rad) - dy * Math.sin(rad), clientY: rect.top + rect.height / 2 + dx * Math.sin(rad) + dy * Math.cos(rad) });
      assert.equal(point.inside, true);
      await ctx.inspectAt(point);
    },
  };
}
(async () => {
  const node = (cls, rect, children = [], chain = [cls]) => ({ cls, classChain: chain, rect, children });
  const title = node('UILabel', [150, 71, 99, 25]);
  const row = node('UILabel', [80, 310, 70, 25]);
  const tab = node('UILabel', [175, 830, 51, 12]);
  const floating = node('_UIFloatingBarContainerView', [0, 0, 402, 874], [
    node('_TtGC5UIKitFloatingBarHostingView', [0, 0, 402, 874], [
      node('UIKit._UITabBarContainerWrapperView', [0, 791, 402, 83], [
        node('UIKit._UITabBarContainerView', [0, 0, 402, 874], [tab], ['UIKit._UITabBarContainerView', '_UITouchPassthroughView', 'UIView']),
      ], ['UIKit._UITabBarContainerWrapperView', '_UITouchPassthroughView', 'UIView']),
    ]),
  ]);
  const glass = node('UIKit._GlassGroupView', [0, 62, 402, 54], [node('UIView', [0, 62, 402, 54])]);
  const navigation = node('UIKit.NavigationBarTransitionContainer', [0, 62, 402, 54], [title, glass, node('UIView', [0, 62, 402, 54])], ['UIKit.NavigationBarTransitionContainer', '_UITouchPassthroughView', 'UIView']);
  const root = node('UIWindow', [0, 0, 402, 874], [row, navigation, floating]);
  function parents(n, parent = null) { n.parent = parent; n.children.forEach(child => parents(child, n)); }
  parents(root);
  const hit = { state: { mode: '2d', showLayers: false }, currentWindow: () => root };
  vm.createContext(hit); vm.runInContext(section('function drawableNodes(win)', 'function syncModeUI()') + section('function systemPassthrough(node)', 'function stagePoint(event)'), hit);
  assert.equal(hit.hitTest(201, 84), title, 'A full-screen floating bar must not block the navigation title');
  assert.equal(hit.hitTest(110, 323), row, 'A full-screen child of a bottom bar must not block the list');
  assert.equal(hit.hitTest(200, 836), tab, 'Visible tab labels must remain selectable');
  const overlay = node('UIView', [0, 0, 402, 874]); root.children.push(overlay); parents(root);
  assert.equal(hit.hitTest(201, 84), overlay, 'Ordinary frontmost views keep existing selection priority');

  // The browser rect includes changed margins, pan and CSS zoom; hierarchy uses points.
  for (const real of [false, true]) for (const orientation of [1, 2, 3, 4]) for (const zoom of [0.5, 1, 2]) {
    const test = create(real); await test.click(orientation, zoom);
    assert.deepEqual(test.selected, ['label']);
    assert(Math.abs(test.hits[0][0] - (393 * 0.4 - 10)) < 0.1);
    assert(Math.abs(test.hits[0][1] - (852 * 0.25 - 20)) < 0.1);
  }
  const switched = create(true, 3, true), stale = switched.ctx.inspectAt({ x: 300, y: 600 });
  switched.ctx.targets.bundleId = 'other'; switched.finish(); await stale;
  assert.deepEqual(switched.selected, []);
  const generation = create(true, 3, true), old = generation.ctx.inspectAt({ x: 300, y: 600 });
  generation.ctx.appState.source = {}; generation.finish(); await old;
  assert.deepEqual(generation.selected, []);
  const geometry = create(true, 3, true), paused = geometry.ctx.inspectAt({ x: 300, y: 600 });
  geometry.ctx.live.sourceGeometry = null; geometry.finish(); await paused;
  assert.deepEqual(geometry.hits, [[90, 180]], 'Capture scale before awaiting hierarchy');

  // Real mode scheduling, cancellation and stale hierarchy responses are covered by TargetTaskTests.cjs.
  console.log('PASS live inspection: pixel/point conversion, layout/pan/zoom/rotation and stale target isolation');
})().catch(error => { console.error(error); process.exitCode = 1; });

// Exercise the real hierarchy navigation with collapsed branches and remembered child paths.
{
  const nodes = new Map();
  function node(key, parent = null) {
    const item = { key, parent, children: [] }; nodes.set(key, item); parent?.children.push(item); return item;
  }
  const root = node('root'), a = node('a', root), a1 = node('a1', a), a2 = node('a2', a), b = node('b', root);
  let rows = [];
  const ctx = { VC_KEY: 'vc:', viewKeyOf: key => key.replace(/^vc:/, ''),
    state: { mode: '2d', nodes, selected: 'a', expanded: new Set(['root']), vcCollapsed: new Set(), query: '', vcFocus: false },
    shownChildren: item => item.children, showSelectionTip() {},
    $: () => ({ querySelectorAll: () => rows.map(key => ({ dataset: { key } })) }),
    renderTree() { rows = []; const walk = item => { rows.push(item.key); if (ctx.state.expanded.has(item.key)) item.children.forEach(walk); }; walk(root); },
    select(key) { ctx.state.selected = key; ctx.rememberTrail(nodes.get(key)); ctx.renderTree(); },
  };
  vm.createContext(ctx);
  vm.runInContext(section('const childTrail = new Map();', '// MARK: - Breadcrumb'), ctx);
  ctx.renderTree();
  assert(ctx.handleStageKey('ArrowDown')); assert.equal(ctx.state.selected, 'a', 'First Down only expands');
  ctx.handleStageKey('ArrowDown'); assert.equal(ctx.state.selected, 'a1', 'Second Down enters a child');
  ctx.handleStageKey('ArrowRight'); assert.equal(ctx.state.selected, 'a2');
  ctx.handleStageKey('ArrowUp'); assert.equal(ctx.state.selected, 'a');
  ctx.handleStageKey('ArrowDown'); assert.equal(ctx.state.selected, 'a2', 'Down returns to the remembered child');
  ctx.handleStageKey('ArrowDown'); assert.equal(ctx.state.selected, 'a2', 'Leaf remains selected');
  ctx.handleStageKey('ArrowLeft'); assert.equal(ctx.state.selected, 'a1');
  ctx.handleStageKey('ArrowLeft'); assert.equal(ctx.state.selected, 'a', 'Left follows visible row order, including parents');
  ctx.handleStageKey('ArrowRight'); assert.equal(ctx.state.selected, 'a1', 'Right enters visible descendants in row order');
  ctx.handleStageKey('ArrowUp'); ctx.handleStageKey('ArrowUp'); assert.equal(ctx.state.selected, 'root');
  ctx.state.selected = 'a'; ctx.handleTreeKey('ArrowDown'); assert.equal(ctx.state.selected, 'a1', 'Tree still uses visible row order');
  ctx.handleTreeKey('ArrowLeft'); assert.equal(ctx.state.selected, 'a', 'Tree Left still selects parent');
  ctx.state.mode = '3d'; ctx.handleStageKey('ArrowRight'); assert.equal(ctx.state.selected, 'a1');
  ctx.handleStageKey('ArrowUp', true); assert.equal(ctx.state.selected, 'a'); assert(!ctx.state.expanded.has('a'), 'Option Up collapses parent from a leaf');
  assert.equal(ctx.handleStageKey('ArrowLeft', true), false);
  ctx.state.mode = 'live'; assert.equal(ctx.handleStageKey('ArrowLeft'), false); assert.equal(ctx.state.selected, 'a');
  console.log('PASS stage direction swap, two-step expansion, visible row order, remembered child, Option collapse and tree/live isolation');
}
