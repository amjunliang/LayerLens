'use strict';

// LookinAttrType 枚举值
const T = {
  Char: 2, Int: 3, Short: 4, Long: 5, LongLong: 6, UChar: 7, UInt: 8, UShort: 9, ULong: 10, ULongLong: 11,
  Float: 12, Double: 13, BOOL: 14, Sel: 15, Class: 16, CGPoint: 17, CGVector: 18, CGSize: 19, CGRect: 20,
  Transform: 21, Insets: 22, Offset: 23, NSString: 24, EnumInt: 25, EnumLong: 26, UIColor: 27,
};
const INT_TYPES = new Set([T.Char, T.Int, T.Short, T.Long, T.LongLong, T.UChar, T.UInt, T.UShort, T.ULong, T.ULongLong, T.EnumInt, T.EnumLong]);
const FLOAT_TYPES = new Set([T.Float, T.Double]);
const VECTOR_LABELS = {
  [T.CGPoint]: ['x', 'y'],
  [T.CGVector]: ['dx', 'dy'],
  [T.CGSize]: ['w', 'h'],
  [T.CGRect]: ['x', 'y', 'w', 'h'],
  [T.Transform]: ['a', 'b', 'c', 'd', 'tx', 'ty'],
  [T.Insets]: ['top', 'left', 'bottom', 'right'],
  [T.Offset]: ['h', 'v'],
};
const ENUMS = {
  NSTextAlignment: ['Left', 'Center', 'Right', 'Justified', 'Natural'],
  NSLineBreakMode: ['WordWrapping', 'CharWrapping', 'Clipping', 'TruncatingHead', 'TruncatingTail', 'TruncatingMiddle'],
  UIViewContentMode: ['ScaleToFill', 'ScaleAspectFit', 'ScaleAspectFill', 'Redraw', 'Center', 'Top', 'Bottom', 'Left', 'Right', 'TopLeft', 'TopRight', 'BottomLeft', 'BottomRight'],
  UIViewTintAdjustmentMode: ['Automatic', 'Normal', 'Dimmed'],
  UIControlContentHorizontalAlignment: ['Center', 'Left', 'Right', 'Fill', 'Leading', 'Trailing'],
  UIControlContentVerticalAlignment: ['Center', 'Top', 'Bottom', 'Fill'],
  UILayoutConstraintAxis: ['Horizontal', 'Vertical'],
  UIStackViewAlignment: ['Fill', 'Leading/Top', 'FirstBaseline', 'Center', 'Trailing/Bottom', 'LastBaseline'],
  UIStackViewDistribution: ['Fill', 'FillEqually', 'FillProportionally', 'EqualSpacing', 'EqualCentering'],
  UIScrollViewContentInsetAdjustmentBehavior: ['Automatic', 'ScrollableAxes', 'Never', 'Always'],
  UITableViewStyle: ['Plain', 'Grouped', 'InsetGrouped'],
  UITableViewCellSeparatorStyle: ['None', 'SingleLine', 'SingleLineEtched'],
  UITextFieldViewMode: ['Never', 'WhileEditing', 'UnlessEditing', 'Always'],
  UIBlurEffectStyle: ['ExtraLight', 'Light', 'Dark', 'ExtraDark', 'Regular', 'Prominent'],
};
const SKIP_GROUPS = new Set(['Class', 'Relation']);

const DEFAULT_ROT_X = -12;
const DEFAULT_ROT_Y = 28;

const state = {
  roots: [],
  nodes: new Map(),
  selected: null,
  hover: null,
  // 展开的节点(oid): 选中节点的祖先 + 手动展开的, 不做持久化
  expanded: new Set(),
  mode: '3d',
  showLayers: false,
  showHidden: true,
  showImages: true,
  subtreeOnly: false,
  groupOpen: {},
  spacing: 16,
  rotX: DEFAULT_ROT_X,
  rotY: DEFAULT_ROT_Y,
  zoom: 1,
  panX: 0,
  panY: 0,
  panZ: 0,
  pivot: { x: 0, y: 0, z: 0 },
  // 平面(2D/实时)与 3D 各自保存的视角
  views: { plan: null, depth: null },
  // 进入只看子树前整个 window 的视角, 退出时恢复
  fullView: null,
  stamp: Date.now(),
  tab: 'attr',
  detail: null,
  classTarget: null,
  query: '',
};

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
};

// 把 iOS 侧信息写到 DOM 属性上, 便于浏览器元素选择工具直接读取
function annotate(element, node, withTitle = true) {
  element.dataset.iosClass = node.classChain.slice(0, 3).join(' > ');
  element.dataset.iosAddress = node.address;
  if (node.viewOid) element.dataset.viewOid = node.viewOid;
  if (node.ivarTraces.length) element.dataset.ivar = node.ivarTraces.join(', ');
  if (node.vcClass) element.dataset.vc = node.vcClass;
  if (withTitle) element.title = [node.cls, node.ivarTraces[0], node.vcClass].filter(Boolean).join('\n');
}

function icon(name) {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('class', 'icon');
  const use = document.createElementNS(ns, 'use');
  use.setAttribute('href', '#i-' + name);
  svg.appendChild(use);
  return svg;
}

// MARK: - Copy

function nodePath(node) {
  const parts = [];
  for (let n = node; n; n = n.parent) {
    const ivar = n.ivarTraces[0] ? n.ivarTraces[0].split('.').pop() : '';
    parts.unshift(ivar ? `${n.cls}(${ivar})` : n.cls);
  }
  return parts.join(' > ');
}

function lldbCommand(node) {
  return `expr -l objc -O -- (id)${node.address}`;
}

// 系统类在源码中搜不到, 生成元素定位信息时过滤
const SYSTEM_CLASS = /^(_|UI|NS|CA|WK|AV|MK|PK|SK|SwiftUI\.)/;
const isCodeClass = (cls) => !!cls && !SYSTEM_CLASS.test(cls);
const CONTAINER_CONTROLLER = /(?:Navigation|TabBar|SplitView|PageView|ListContainer)(?:View)?Controller$/;
const TREE_INDENT = 10;
const LONG_PRESS_MS = 500;
const DOUBLE_CLICK_MS = 300;
// F 聚焦时选中元素占画布的比例
const FOCUS_FILL = 0.7;
// 层间距范围与 [ ] 每次调整的步长, 与工具栏滑块一致
const SPACING_MIN = 0;
const SPACING_MAX = 60;
const SPACING_STEP = 4;

// "Host : Declaring._ivar" 表示 ivar 声明在父类中; 只保留声明在非系统类中的 ivar
function codeIvars(node) {
  const result = [];
  node.ivarTraces.forEach((trace) => {
    const dot = trace.lastIndexOf('.');
    const [host, declaring = host] = trace.slice(0, dot).split(' : ');
    const ivar = trace.slice(dot + 1);
    const text = `${declaring}.${ivar}`;
    if (isCodeClass(declaring) && !result.some((r) => r.text === text)) result.push({ host, declaring, ivar, text });
  });
  return result;
}

function nearestView(node) {
  let p = node.parent;
  while (p && p.isLayer) p = p.parent;
  return p;
}

// 从元素向上定位, 省略成员变量持有者和系统容器; 控制器跳过导航和列表等容器
function elementSummary(node) {
  const ivars = codeIvars(node);
  const ownerClasses = new Set(ivars.flatMap((r) => [r.host, r.declaring]));
  const parts = [ivars.length ? ivars.map((r) => r.text).join(' and ') : node.cls];
  let controller = '';
  for (let p = node; p; p = p.parent) {
    if (isCodeClass(p.vcClass) && !CONTAINER_CONTROLLER.test(p.vcClass)) {
      controller = p.vcClass;
      break;
    }
  }

  for (let p = nearestView(node); p && p.parent; p = nearestView(p)) {
    if (controller && p.vcClass === controller) break;
    if (isCodeClass(p.cls) && !ownerClasses.has(p.cls) && p.cls !== node.cls) {
      parts.push(p.cls);
      break;
    }
  }
  if (controller && !parts.includes(controller)) parts.push(controller);
  return parts.join(' < ');
}

// more 为 true 的收进右键菜单的"更多复制"子菜单
const COPY_ACTIONS = [
  { title: '复制类名', value: (n) => n.cls },
  { title: '复制层级路径', value: nodePath },
  { title: '复制元素信息', value: elementSummary },
  { title: '复制成员变量名', value: (n) => [...new Set(n.ivarTraces.map((trace) => trace.split('.').pop()).filter(Boolean))].join('\n'), more: true },
  { title: '复制对象地址', value: (n) => n.address, more: true },
  { title: '复制 LLDB 命令', value: lldbCommand, more: true },
];

async function copyText(text, label) {
  try {
    // 局域网 http 访问时不是安全上下文, clipboard API 不可用
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
    } else {
      const area = el('textarea');
      area.value = text;
      area.style.cssText = 'position:fixed;left:-9999px;top:0';
      document.body.appendChild(area);
      area.select();
      const ok = document.execCommand('copy');
      area.remove();
      if (!ok) throw new Error('copy failed');
    }
    toast(t('已' + label));
  } catch (e) {
    toast(t('复制失败: {0}', e.message), true);
  }
}

// 复制图片需在点击事件中同步调用: Safari 要求同步创建 ClipboardItem, 图片数据以 Promise 传入
async function copyImage(blob, label) {
  try {
    if (!navigator.clipboard?.write || typeof ClipboardItem === 'undefined') throw new Error(t('当前环境不支持复制图片'));
    await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]);
    toast(t('已' + label));
  } catch (e) {
    toast(t('复制失败: {0}', e.message), true);
  }
}

function fetchPNG(url) {
  return fetch(url).then((res) => {
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.blob();
  }).then((blob) => new Blob([blob], { type: 'image/png' }));
}

function liveCanvasPNG() {
  return new Promise((resolve, reject) => {
    $('liveCanvas').toBlob((blob) => (blob ? resolve(blob) : reject(new Error(t('暂无画面')))), 'image/png');
  });
}

// 屏幕截图(画布右键菜单): 实时模式取当前画面, 2D/3D 取当前窗口的 App 截图
function screenShotPNG() {
  if (state.mode === 'live') return liveCanvasPNG();
  const win = currentWindow();
  return win ? fetchPNG(shotURL(win.oid, 'group')) : Promise.reject(new Error(t('暂无画面')));
}

// canvas 为 true 时(画布上呼出)未选中元素也显示菜单, 元素各项不可用, 末尾附带屏幕截图;
// screenOnly 用于实时画面, 只有屏幕截图一项, 不显示标题
function showMenu(x, y, node, canvas, screenOnly) {
  hideMenu();
  if (!node && !canvas) return;
  const menu = el('div', screenOnly ? 'context-menu fit' : 'context-menu');
  menu.id = 'contextMenu';
  if (!screenOnly) menu.appendChild(el('div', 'menu-title', node ? node.cls : t('未选中元素')));
  const makeItem = (title, run, disabled) => {
    const item = el('button', 'menu-item', title);
    item.disabled = disabled;
    item.addEventListener('click', () => {
      hideMenu();
      run();
    });
    // 移到主菜单的其他项上时收起子菜单; 子菜单自己的项不处理, 否则会关掉再打开, 不停闪烁
    item.addEventListener('pointerenter', () => {
      if (item.parentNode === menu) hideSubmenu(menu);
    });
    return item;
  };
  if (!screenOnly) {
    const copyItem = (action) => {
      const value = node && action.value(node);
      return makeItem(t(action.title), () => copyText(value, action.title), !value);
    };
    COPY_ACTIONS.filter((action) => !action.more).forEach((action) => menu.appendChild(copyItem(action)));
    const more = COPY_ACTIONS.filter((action) => action.more).map(copyItem);
    const moreItem = el('button', 'menu-item has-submenu', t('更多复制'));
    moreItem.disabled = more.every((item) => item.disabled);
    const open = () => showSubmenu(menu, moreItem, more);
    moreItem.addEventListener('pointerenter', open);
    moreItem.addEventListener('click', open);
    menu.appendChild(moreItem);
    menu.appendChild(el('div', 'menu-separator'));
    menu.appendChild(makeItem(t('复制元素截图'), () => copyImage(fetchPNG(shotURL(node.oid, 'group')), '复制元素截图'), !node));
  }
  if (canvas) menu.appendChild(makeItem(t('复制屏幕截图'), () => copyImage(screenShotPNG(), '复制屏幕截图')));
  document.body.appendChild(menu);
  placeMenu(menu, x, y);
}

function placeMenu(menu, x, y) {
  const rect = menu.getBoundingClientRect();
  menu.style.left = Math.max(8, Math.min(x, window.innerWidth - rect.width - 8)) + 'px';
  menu.style.top = Math.max(8, Math.min(y, window.innerHeight - rect.height - 8)) + 'px';
}

// 子菜单单独挂在 body 上, 避免被主菜单的滚动区域裁剪; 右侧放不下时放到左侧,
// 两侧都放不下(窗口很窄)时直接在主菜单内展开
function showSubmenu(menu, anchor, items) {
  if (anchor.disabled || menu.submenu?.anchor === anchor) return;
  hideSubmenu(menu);
  anchor.classList.add('open');
  const sub = el('div', 'context-menu submenu');
  sub.append(...items);
  sub.anchor = anchor;
  menu.submenu = sub;
  document.body.appendChild(sub);
  const a = anchor.getBoundingClientRect();
  const width = sub.getBoundingClientRect().width;
  if (a.right + 2 + width <= window.innerWidth - 8) {
    placeMenu(sub, a.right + 2, a.top - 4);
  } else if (a.left - width - 2 >= 8) {
    placeMenu(sub, a.left - width - 2, a.top - 4);
  } else {
    sub.remove();
    sub.className = 'submenu-inline';
    anchor.after(sub);
    placeMenu(menu, parseFloat(menu.style.left), parseFloat(menu.style.top));
  }
}

function hideSubmenu(menu) {
  const sub = menu.submenu;
  if (!sub) return;
  // 内嵌展开的子菜单保持打开, 直到菜单关闭
  if (sub.className === 'submenu-inline' && menu.isConnected && sub.isConnected && !menu.closing) return;
  sub.anchor.classList.remove('open');
  sub.remove();
  menu.submenu = null;
}

// 适应窗口: 缩放与平移归位, 3D 下同时恢复默认旋转角度
function fitView() {
  if (state.mode === 'live') {
    state.zoom = 1;
    state.panX = 0;
    state.panY = 0;
    layoutLive();
    return;
  }
  if (state.mode === '3d') {
    state.rotX = DEFAULT_ROT_X;
    state.rotY = DEFAULT_ROT_Y;
  }
  state.zoom = 1;
  state.panX = 0;
  state.panY = 0;
  state.panZ = 0;
  // 舞台中心(0,0,0)映射到视口中心
  const center = projectToScreen({ x: 0, y: 0, z: 0 });
  state.panX = -center.x;
  state.panY = -center.y;
  state.panZ = -center.z;
  applyStageTransform();
}

function hideMenu() {
  const menu = $('contextMenu');
  if (!menu) return;
  // 退出动画期间可能已打开新的菜单, 先去掉 id 避免冲突
  menu.removeAttribute('id');
  menu.closing = true;
  hideSubmenu(menu);
  hideLayer(menu, 120, () => menu.remove());
}

// MARK: - Network

async function api(path, options) {
  const res = await fetch(targetBase() + path, options);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

// 不显示 CALayer 时这些层不单独绘制, solo 截图保留它们(如视频播放层), 否则视频区域为空
function shotURL(oid, type) {
  const layers = type === 'solo' ? `&layers=${state.showLayers ? 1 : 0}` : '';
  return `${targetBase()}/api/screenshot?oid=${oid}&type=${type}${layers}&t=${state.stamp}`;
}

// 截图并发控制与缓存: App 端截图在主线程串行执行, 并发过高只会排队超时
// gen: 刷新层级时递增, 作废旧请求并重置并发计数; 请求挂起(如 App 挂起期间)时超时释放, 避免占满并发后不再加载
const images = { running: 0, pending: [], max: 4, loaded: new Map(), gen: 0, active: new Set() };
const IMAGE_TIMEOUT_MS = 15000;
function loadImage(url, apply) {
  const cached = images.loaded.get(url);
  if (cached === true) {
    apply(url);
    return;
  }
  if (cached === false) return;
  images.pending.push({ url, apply, attempts: 0 });
  pumpImages();
}
function resetImages() {
  // 取消进行中的请求, 释放浏览器连接
  images.active.forEach((img) => (img.src = ''));
  images.active.clear();
  images.gen++;
  images.running = 0;
  images.pending = [];
  images.loaded.clear();
}
function pumpImages() {
  while (images.running < images.max && images.pending.length) {
    const job = images.pending.shift();
    const gen = images.gen;
    images.running++;
    const img = new Image();
    images.active.add(img);
    let timer = 0;
    const finish = (ok) => {
      if (!timer) return;
      clearTimeout(timer);
      timer = 0;
      img.onload = img.onerror = null;
      images.active.delete(img);
      // 已被刷新作废: 计数已重置, 不再处理
      if (gen !== images.gen) return;
      images.running--;
      if (ok) {
        images.loaded.set(job.url, true);
        job.apply(job.url);
      } else if (job.attempts < 1) {
        // 失败重试一次, 仍失败则视为该节点没有截图
        job.attempts++;
        images.pending.push(job);
      } else {
        images.loaded.set(job.url, false);
      }
      pumpImages();
    };
    timer = setTimeout(() => {
      img.src = '';
      finish(false);
    }, IMAGE_TIMEOUT_MS);
    img.onload = () => finish(true);
    img.onerror = () => finish(false);
    img.src = job.url;
  }
}

function toast(message, isError) {
  // App 不在线时请求失败是预期的, 由提示条说明
  if (isError && appState.value !== 'online') return;
  const node = $('toast');
  node.textContent = message;
  node.className = 'toast show' + (isError ? ' error' : '');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (node.className = 'toast'), 2600);
}

// MARK: - View state
// 浏览器刷新也保留操作状态, 与页面内「刷新」效果一致

const VIEW_STATE_KEY = 'layerlens_view_state';
const PERSIST_FIELDS = ['mode', 'rotX', 'rotY', 'zoom', 'panX', 'panY', 'panZ', 'pivot', 'views', 'fullView', 'spacing', 'showLayers', 'showHidden', 'showImages', 'subtreeOnly', 'tab', 'query', 'groupOpen'];
let pendingRestore = null;

function saveViewState() {
  const node = state.nodes.get(state.selected);
  const win = keyWindow();
  const data = {
    windowAddress: win ? win.address : null,
    selected: state.selected,
    selectedAddress: node ? node.address : null,
  };
  PERSIST_FIELDS.forEach((field) => (data[field] = state[field]));
  try {
    sessionStorage.setItem(VIEW_STATE_KEY, JSON.stringify(data));
  } catch (e) {
    // 无痕模式等场景下不可用, 忽略
  }
}

function loadViewState() {
  try {
    pendingRestore = JSON.parse(sessionStorage.getItem(VIEW_STATE_KEY));
  } catch (e) {
    pendingRestore = null;
  }
  if (!pendingRestore) return;
  PERSIST_FIELDS.forEach((field) => {
    if (pendingRestore[field] !== undefined) state[field] = pendingRestore[field];
  });
  $('showLayers').checked = state.showLayers;
  $('showHidden').checked = state.showHidden;
  syncTreeFilter();
  syncToggles();
  $('spacing').value = state.spacing;
  $('spacingLabel').textContent = state.spacing;
  $('search').value = state.query;
  syncModeUI();
  $('detailTabs').querySelectorAll('button').forEach((b) => b.classList.toggle('active', b.dataset.tab === state.tab));
}

// App 重启后 oid 会重新分配, 用内存地址校验后才恢复选中
function restoreNodeState() {
  const data = pendingRestore;
  pendingRestore = null;
  const win = keyWindow();
  if (!data || !win || data.windowAddress !== win.address) return;
  const node = state.nodes.get(data.selected);
  if (node && node.address === data.selectedAddress) state.selected = node.key;
}

// 展开选中节点的所有祖先, 保证选中行可见
function expandToSelected() {
  const node = state.nodes.get(state.selected);
  for (let p = node?.parent; p; p = p.parent) state.expanded.add(p.key);
}

// MARK: - Hierarchy

// 连续刷新时只采用最后一次请求的结果, 避免较早的响应晚到覆盖新层级
let refreshSeq = 0;
async function refresh() {
  const seq = ++refreshSeq;
  try {
    const roots = await api('/api/hierarchy');
    if (seq !== refreshSeq) return;
    applyHierarchy(roots);
  } catch (e) {
    showRefreshError(e);
  }
}

function showRefreshError(e) {
  if (appState.value === 'online') setStatus(false, t('连接失败: {0}', e.message));
  toast(t('获取层级失败: {0}', e.message), true);
}

function applyHierarchy(roots) {
  state.stamp = Date.now();
  resetImages();
  prepare(roots);
  if (state.selected && !state.nodes.has(state.selected)) state.selected = null;
  if (!state.selected) {
    const win = keyWindow();
    if (win) state.selected = win.key;
  }
  expandToSelected();
  renderTree();
  renderCanvas();
  loadDetail();
  setStatus(true);
}

// MARK: - Status

const appInfo = { base: '', lastRefresh: 0 };

function setStatus(ok, message, refreshed = ok) {
  if (refreshed) appInfo.lastRefresh = Date.now();
  // 刷新时间只放在提示中, 工具栏不显示会变化的文字
  const time = appInfo.lastRefresh ? new Date(appInfo.lastRefresh).toLocaleTimeString(LANG === 'en' ? 'en-US' : 'zh-CN', { hour12: false }) : '';
  const dot = $('statusDot');
  dot.className = 'status-dot ' + (ok ? 'ok' : 'error');
  dot.title = ok ? t('已连接 · 上次刷新 {0}', time) : message || t('连接失败');
  $('refreshBtn').title = time ? t('刷新 (R) · 上次 {0}', time) : t('刷新 (R)');
  updateAppMeta();
}

function updateAppMeta() {
  const count = state.nodes.size;
  $('appMeta').textContent = [appInfo.base, count ? t('{0} 节点', count) : ''].filter(Boolean).join(' · ');
}

function prepare(roots) {
  const isFirst = state.roots.length === 0;
  state.roots = roots;
  state.nodes = new Map();
  let custom = 0;
  const walk = (node, parent, depth, win) => {
    node.key = node.oid ? String(node.oid) : 'c' + custom++;
    node.parent = parent;
    node.depth = depth;
    node.win = win || node;
    node.cls = node.classChain[0] || '?';
    node.effHidden = node.hidden || node.alpha < 0.01 || (parent ? parent.effHidden : false);
    state.nodes.set(node.key, node);
    node.children.forEach((child) => walk(child, node, depth + 1, node.win));
  };
  roots.forEach((root) => walk(root, null, 0, null));
  if (isFirst) restoreNodeState();
}

function keyWindow() {
  return state.roots.find((r) => r.keyWindow && !r.hidden) || state.roots[0];
}

function currentWindow() {
  const node = state.nodes.get(state.selected);
  return node ? node.win : keyWindow();
}

function isShown(node) {
  if (!state.showHidden && node.effHidden) return false;
  return state.showLayers || !node.isLayer;
}

// 隐藏 CALayer 节点时, 将其子节点提升到上一层
function shownChildren(node) {
  const result = [];
  node.children.forEach((child) => {
    if (isShown(child)) result.push(child);
    else if (child.isLayer && (state.showHidden || !child.effHidden)) result.push(...shownChildren(child));
  });
  return result;
}

function matches(node, q) {
  if (node.cls.toLowerCase().includes(q)) return true;
  if (node.address.toLowerCase().includes(q)) return true;
  if (node.title && node.title.toLowerCase().includes(q)) return true;
  if (node.specialTrace && node.specialTrace.toLowerCase().includes(q)) return true;
  return node.ivarTraces.some((t) => t.toLowerCase().includes(q));
}

// MARK: - Tree

function renderTree() {
  const tree = $('tree');
  const frag = document.createDocumentFragment();
  const q = state.query.trim().toLowerCase();
  let visible = null;
  if (q) {
    visible = new Set();
    state.nodes.forEach((node) => {
      if (!matches(node, q)) return;
      for (let p = node; p; p = p.parent) visible.add(p.key);
    });
  }
  const addRows = (nodes, level) => {
    nodes.forEach((node) => {
      if (visible && !visible.has(node.key)) return;
      const children = shownChildren(node);
      const expanded = q ? true : state.expanded.has(node.key);
      frag.appendChild(makeRow(node, level, children.length > 0, expanded, q));
      if (expanded) addRows(children, level + 1);
    });
  };
  addRows(state.roots.filter((r) => state.showHidden || !r.effHidden), 0);
  // 行宽统一为最宽行, 支持横向滚动且悬停背景铺满
  const inner = el('div', 'tree-inner');
  inner.appendChild(frag);
  tree.replaceChildren(inner);
  if (state.hover) tree.querySelector(`.row[data-key="${CSS.escape(state.hover)}"]`)?.classList.add('hover');
  scrollToSelected();
  renderCrumbs();
}

function makeRow(node, level, hasChildren, expanded, q) {
  const row = el('div', 'row');
  row.dataset.key = node.key;
  annotate(row, node);
  row.style.setProperty('--indent', level * TREE_INDENT + 'px');
  if (node.key === state.selected) row.classList.add('selected');
  if (node.effHidden) row.classList.add('dim');
  if (node.cls.startsWith('_')) row.classList.add('private');
  const arrow = el('span', 'arrow' + (hasChildren && expanded ? ' expanded' : ''));
  if (hasChildren) {
    arrow.dataset.toggle = '1';
    arrow.appendChild(icon('chevron'));
  }
  row.appendChild(arrow);
  // 与 Lookin 一致: 有手势 / 控件事件时左侧显示蓝条, 点击查看事件
  if (node.events?.length) {
    const bar = el('button', 'ev-bar');
    bar.title = t('事件') + ' (' + node.events.length + ')';
    row.appendChild(bar);
  }
  if (node.vcClass) row.appendChild(el('span', 'vc-dot'));
  const cls = el('span', 'cls' + (node.isLayer ? ' layer' : ''));
  appendHighlighted(cls, node.cls, q);
  row.appendChild(cls);
  if (node.title) row.appendChild(el('span', 'meta', node.title));
  // 与 Lookin 一致: 有特殊标记(控制器的 view / Cell 位置 / KeyWindow)时显示它, 否则显示引用它的所有成员变量名
  if (node.vcClass) {
    row.appendChild(el('span', 'vc', node.specialTrace || node.vcClass + '.view'));
  } else if (node.specialTrace) {
    row.appendChild(el('span', 'meta', node.specialTrace));
  } else {
    [...new Set(node.ivarTraces.map((trace) => trace.split('.').pop()))].forEach((name) => row.appendChild(el('span', 'meta', name)));
  }
  const copy = el('button', 'copy');
  copy.appendChild(icon('copy'));
  copy.title = t('复制路径');
  row.appendChild(copy);
  return row;
}

function appendHighlighted(parent, text, q) {
  const index = q ? text.toLowerCase().indexOf(q) : -1;
  if (index < 0) {
    parent.textContent = text;
    return;
  }
  parent.append(text.slice(0, index), el('mark', null, text.slice(index, index + q.length)), text.slice(index + q.length));
}

function scrollToSelected() {
  const tree = $('tree');
  const row = tree.querySelector('.row.selected');
  if (!row) return;
  // 只在纵向滚到可见, 不改横向位置; 缩进较深显示不下时由用户自己横向滚动
  const top = row.getBoundingClientRect().top - tree.getBoundingClientRect().top + tree.scrollTop;
  if (top < tree.scrollTop) tree.scrollTop = top;
  else if (top + row.offsetHeight > tree.scrollTop + tree.clientHeight) tree.scrollTop = top + row.offsetHeight - tree.clientHeight;
}

// 选中路径记忆: 父节点 key -> 上次经过的子节点 key, → 时原路返回
const childTrail = new Map();

function rememberTrail(node) {
  for (let n = node; n && n.parent; n = n.parent) childTrail.set(n.parent.key, n.key);
}

// 记住的子节点; 中间层在树中不可见(如被隐藏的 CALayer)时继续向下找
function rememberedChild(node, rows) {
  let key = childTrail.get(node.key);
  while (key && !rows.includes(key)) key = childTrail.get(key);
  return key || null;
}

// 当前树中可见行的顺序, 用于键盘导航
function visibleRowKeys() {
  return [...$('tree').querySelectorAll('.row')].map((row) => row.dataset.key);
}

// ← 直接选中父节点, 不收起(在画布上按时收起树看不到变化, 像是按了没反应); ⌥ + ← 收起
function handleTreeKey(key, alt = false) {
  const node = state.nodes.get(state.selected);
  if (!node) return false;
  const rows = visibleRowKeys();
  const index = rows.indexOf(node.key);
  const hasChildren = shownChildren(node).length > 0;
  const expanded = state.expanded.has(node.key) || !!state.query.trim();
  if (key === 'ArrowDown' || key === 'ArrowUp') {
    const next = rows[index + (key === 'ArrowDown' ? 1 : -1)];
    if (next) select(next, true);
  } else if (key === 'ArrowRight') {
    if (hasChildren && !expanded) {
      state.expanded.add(node.key);
      renderTree();
    } else if (hasChildren) {
      select(rememberedChild(node, rows) || rows[index + 1], true);
    }
  } else if (key === 'ArrowLeft') {
    // 选中树中可见的父节点(跳过被隐藏的 CALayer 等)
    let p = node.parent;
    while (p && !rows.includes(p.key)) p = p.parent;
    if (alt && !state.query.trim()) {
      // 收起当前节点; 没有可收起的则收起父节点并选中它
      const target = hasChildren && expanded ? node : p;
      if (!target) return true;
      state.expanded.delete(target.key);
      if (target === node) renderTree();
      else select(target.key, true);
    } else if (p) {
      select(p.key, true);
    }
  } else {
    return false;
  }
  showSelectionTip();
  return true;
}

// MARK: - Breadcrumb

// 只显示选中节点的父视图与自己, 悬停不改变
function renderCrumbs() {
  const crumbs = $('crumbs');
  const node = state.nodes.get(state.selected);
  if (!node) {
    crumbs.replaceChildren();
    return;
  }
  const frag = document.createDocumentFragment();
  const parent = nearestView(node);
  if (parent) {
    frag.appendChild(crumbItem(parent, false));
    const sep = el('span', 'crumb-sep');
    sep.appendChild(icon('chevron'));
    frag.appendChild(sep);
  }
  frag.appendChild(crumbItem(node, true));
  crumbs.replaceChildren(frag);
}

function crumbItem(node, current) {
  const item = el('button', 'crumb' + (current ? ' current' : ''));
  item.dataset.key = node.key;
  item.title = node.classChain.slice(0, 3).join(' > ');
  item.appendChild(el('span', 'crumb-cls', node.cls));
  const ivar = codeIvars(node)[0];
  if (ivar) item.appendChild(el('span', 'crumb-ivar', ivar.ivar));
  return item;
}

function select(key, fromTree) {
  if (!state.nodes.has(key)) return;
  const previousWindow = currentWindow();
  state.selected = key;
  state.classTarget = null;
  rememberTrail(state.nodes.get(key));
  if (!fromTree) {
    expandToSelected();
  }
  renderTree();
  if (previousWindow !== currentWindow() || (state.mode === '3d' && state.subtreeOnly)) {
    if (state.mode === '3d' && state.subtreeOnly) recenterStage();
    renderCanvas();
  } else {
    updateHighlights();
    if (state.mode === '3d') updatePivot();
  }
  clearTimeout(select.detailTimer);
  select.detailTimer = setTimeout(loadDetail, 120);
  // 窄屏在层级页选中时, 提示画布内容已变化
  if (isNarrow() && document.body.dataset.view === 'tree') $('mobileNav').querySelector('[data-view="canvas"]').classList.add('dot');
}

// 离开实时模式时刷新一次层级, 画面期间不同步
let modeSeq = 0;

async function setMode(mode) {
  // 每次调用都作废还在取层级的切换, 如取层级期间又点回实时
  const seq = ++modeSeq;
  if (mode === state.mode) return;
  const fromLive = state.mode === 'live';
  // 从实时画面切出时层级已过期: 先取到新层级再切换, 只绘制一次, 避免先画旧层级再刷新
  let roots = null;
  if (fromLive) {
    ++refreshSeq;
    try {
      roots = await api('/api/hierarchy');
    } catch (e) {
      showRefreshError(e);
    }
    if (seq !== modeSeq || state.mode !== 'live') return;
  }
  // 2D 与实时画面共用一套视角, 3D 单独一套; 切换时各自保留上次的缩放和平移
  const kind = (m) => (m === '3d' ? 'depth' : 'plan');
  const fromKind = kind(state.mode);
  const toKind = kind(mode);
  if (fromKind !== toKind) {
    state.views[fromKind] = { zoom: state.zoom, panX: state.panX, panY: state.panY, panZ: state.panZ, pivot: { ...state.pivot } };
  }
  const saved = fromKind !== toKind ? state.views[toKind] : null;
  state.mode = mode;
  hideHoverTip();
  state.hover = null;
  if (saved) {
    Object.assign(state, { zoom: saved.zoom, panX: saved.panX, panY: saved.panY, panZ: saved.panZ, pivot: { ...saved.pivot } });
  } else if (fromKind !== toKind) {
    state.pivot = { x: 0, y: 0, z: 0 };
    state.panZ = 0;
  }
  const keepView = fromKind === toKind || !!saved;
  if (mode === 'live') {
    syncModeUI();
    liveStart();
    if (keepView) layoutLive();
    else fitView();
    return;
  }
  liveStop();
  if (roots) applyHierarchy(roots);
  else renderCanvas();
  if (keepView) applyStageTransform();
  else fitView();
}

// 小屏用单栏 + 底部切换: 触屏窄屏, 或桌面窗口窄到工具栏放不下; 其余按宽度自动收起侧栏
const NARROW_QUERY = '(max-width: 760px) and (pointer: coarse), (max-width: 600px)';

function isNarrow() {
  return window.matchMedia(NARROW_QUERY).matches;
}

// 画布可用尺寸: 去掉内边距(窄屏右侧为浮动工具列预留的位置)
function contentSize(wrap) {
  const style = getComputedStyle(wrap);
  return [
    wrap.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
    wrap.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom),
  ];
}

// 2D/实时适应窗口时内容占画布的比例; 窄屏的留白由画布内边距给出(上下 8px), 这里不再缩小
function planFitRatio() {
  return isNarrow() ? 1 : 0.92;
}

function setView(view) {
  document.body.dataset.view = view;
  $('mobileNav').querySelectorAll('button').forEach((b) => {
    b.classList.toggle('active', b.dataset.view === view);
    if (b.dataset.view === view) b.classList.remove('dot');
  });
}

// MARK: - Canvas

// 画布对应的区域: 3D 只看子树时为选中节点, 否则为整个 window
function canvasFrame(win) {
  if (state.mode === '3d' && state.subtreeOnly) {
    const node = state.nodes.get(state.selected);
    if (node && node.win === win && node.rect[2] > 0 && node.rect[3] > 0) return node.rect;
  }
  return win.rect;
}

function stageScale(win) {
  const wrap = $('stageWrap');
  const [, , w, h] = canvasFrame(win);
  if (!w || !h) return 1;
  const [width, height] = contentSize(wrap);
  const fit = Math.min(width / w, height / h) * (state.mode === '3d' ? 0.62 : planFitRatio());
  return fit * state.zoom;
}

function drawableNodes(win) {
  const base = state.mode === '3d' && state.subtreeOnly && state.nodes.get(state.selected) ? state.nodes.get(state.selected) : win;
  const result = [];
  const walk = (node, level) => {
    let next = level;
    if (!node.effHidden && node.rect[2] > 0 && node.rect[3] > 0 && (state.showLayers || !node.isLayer)) {
      node.level = level;
      result.push(node);
      next = level + 1;
    }
    if (!node.effHidden) node.children.forEach((child) => walk(child, next));
  };
  walk(base, 0);
  return result;
}

function syncModeUI() {
  document.body.classList.toggle('mode-3d', state.mode === '3d');
  document.body.classList.toggle('mode-live', state.mode === 'live');
  $('liveWrap').hidden = state.mode !== 'live';
  if (picker.on && !pickerAvailable()) setColorPicker(false);
  $('modeSeg').querySelectorAll('button').forEach((b) => b.classList.toggle('active', b.dataset.mode === state.mode));
}

function renderCanvas() {
  const stage = $('stage');
  const win = currentWindow();
  syncModeUI();
  if (state.mode === 'live') return;
  if (!win) {
    stage.replaceChildren();
    return;
  }
  const [wx, wy, w, h] = canvasFrame(win);
  stage.style.width = w + 'px';
  stage.style.height = h + 'px';
  stage.replaceChildren();
  // 旧节点已移除, 丢弃尚未发出的截图请求
  images.pending = [];
  if (state.mode === '2d') {
    const img = el('img', 'shot');
    img.draggable = false;
    // 缓存命中时直接设置地址会重新请求, App 重启中会失败, 隐藏避免显示裂图
    img.onerror = () => (img.style.visibility = 'hidden');
    img.onload = () => (img.style.visibility = '');
    loadImage(shotURL(win.oid, 'group'), (url) => (img.src = url));
    stage.append(img, el('div', 'box hover'), el('div', 'box selected'));
  } else {
    drawableNodes(win).forEach((node) => {
      const slab = el('div', 'slab');
      slab.dataset.key = node.key;
      annotate(slab, node, false);
      slab.style.left = node.rect[0] - wx + 'px';
      slab.style.top = node.rect[1] - wy + 'px';
      slab.style.width = node.rect[2] + 'px';
      slab.style.height = node.rect[3] + 'px';
      slab.style.transform = `translateZ(${node.level * state.spacing}px)`;
      // 先挂载再加载: 命中缓存时回调是同步的
      stage.appendChild(slab);
      if (state.showImages && node.oid) {
        // 不显示 CALayer 且只有 CALayer 子节点时, 子层不单独绘制, 取整体截图; 旧版 Pod 也能显示视频播放层等内容
        const onlyLayers = !state.showLayers && node.children.length > 0 && node.children.every((child) => child.isLayer);
        loadImage(shotURL(node.oid, onlyLayers ? 'group' : 'solo'), (url) => {
          if (slab.isConnected) slab.style.backgroundImage = `url("${url}")`;
        });
      }
    });
  }
  updatePivot();
  updateHighlights();
}

// 画布区域变化时(切换只看子树)旧的缩放、旋转中心和平移已失效, 重新适应窗口, 保留旋转角度
function recenterStage() {
  state.zoom = 1;
  state.pivot = { x: 0, y: 0, z: 0 };
  state.panX = 0;
  state.panY = 0;
  state.panZ = 0;
}

// 进入子树时保存整体视角, 退出时恢复; 没有保存过(如刷新页面后)则重新居中
function toggleSubtreeView() {
  if (state.subtreeOnly) {
    state.fullView = { zoom: state.zoom, panX: state.panX, panY: state.panY, panZ: state.panZ, pivot: { ...state.pivot } };
    recenterStage();
    return;
  }
  const saved = state.fullView;
  state.fullView = null;
  if (saved) {
    Object.assign(state, { zoom: saved.zoom, panX: saved.panX, panY: saved.panY, panZ: saved.panZ, pivot: { ...saved.pivot } });
  } else {
    recenterStage();
  }
}

function applyStageTransform() {
  if (state.mode === 'live') {
    layoutLive();
    return;
  }
  const win = currentWindow();
  if (!win) return;
  const scale = stageScale(win);
  // 平移在屏幕坐标系中进行, 放在最前面; 3D 下先移到旋转中心再旋转, 选中节点在旋转时保持不动
  const pan = `translate3d(${state.panX}px, ${state.panY}px, ${state.panZ}px) `;
  const p = state.pivot;
  $('stage').style.transform = pan + (state.mode === '3d'
    ? `scale(${scale}) translate3d(${p.x}px, ${p.y}px, ${p.z}px) rotateX(${state.rotX}deg) rotateY(${state.rotY}deg) translate3d(${-p.x}px, ${-p.y}px, ${-p.z}px)`
    : `scale(${scale})`);
}

// MARK: - Pivot
// 坐标约定: 舞台坐标以舞台中心为原点; 屏幕偏移以舞台未变换时的中心为原点(透视前)

function rotationMatrix() {
  return new DOMMatrix().rotateAxisAngleSelf(1, 0, 0, state.rotX).rotateAxisAngleSelf(0, 1, 0, state.rotY);
}

// 舞台坐标 -> 屏幕偏移
function projectToScreen(q) {
  const win = currentWindow();
  const scale = win ? stageScale(win) : 1;
  if (state.mode !== '3d') return { x: state.panX + scale * q.x, y: state.panY + scale * q.y, z: 0 };
  const p = state.pivot;
  const r = rotationMatrix().transformPoint(new DOMPoint(q.x - p.x, q.y - p.y, q.z - p.z));
  // CSS scale() 只缩放 x/y, 不缩放 z
  return { x: state.panX + scale * (p.x + r.x), y: state.panY + scale * (p.y + r.y), z: state.panZ + p.z + r.z };
}

// 3D 下的旋转中心: 选中节点的中心与所在层; 未选中或不在画布中时为舞台中心
function computePivot() {
  const win = currentWindow();
  const node = state.nodes.get(state.selected);
  if (state.mode !== '3d' || !win || !node || !$('stage').querySelector(`.slab[data-key="${CSS.escape(node.key)}"]`)) {
    return { x: 0, y: 0, z: 0 };
  }
  const [fx, fy, fw, fh] = canvasFrame(win);
  return {
    x: node.rect[0] + node.rect[2] / 2 - fx - fw / 2,
    y: node.rect[1] + node.rect[3] / 2 - fy - fh / 2,
    z: (node.level || 0) * state.spacing,
  };
}

// 更换旋转中心时补偿平移, 画面保持不动
function updatePivot() {
  const next = computePivot();
  if (state.mode === '3d') {
    const screen = projectToScreen(next);
    const win = currentWindow();
    const scale = win ? stageScale(win) : 1;
    // 三个方向都补偿, 否则深度变化会在透视下表现为位移
    state.pivot = next;
    state.panX = screen.x - scale * next.x;
    state.panY = screen.y - scale * next.y;
    state.panZ = screen.z - next.z;
  } else {
    state.pivot = next;
  }
  applyStageTransform();
}

// 把选中元素放大到画布中央; 未选中或实时模式时等同适应窗口
function focusSelected() {
  const win = currentWindow();
  const node = state.nodes.get(state.selected);
  if (state.mode === 'live' || !win || !node || node.win !== win || !node.rect[2] || !node.rect[3]) {
    fitView();
    return;
  }
  const [width, height] = contentSize($('stageWrap'));
  const base = stageScale(win) / state.zoom;
  // 元素已经足够大时只居中, 不比适应窗口更小
  state.zoom = Math.max(1, Math.min(6, Math.min(width / node.rect[2], height / node.rect[3]) * FOCUS_FILL / base));
  if (state.mode === '3d') updatePivot();
  const [fx, fy, fw, fh] = canvasFrame(win);
  const center = {
    x: node.rect[0] + node.rect[2] / 2 - fx - fw / 2,
    y: node.rect[1] + node.rect[3] / 2 - fy - fh / 2,
    z: state.mode === '3d' ? (node.level || 0) * state.spacing : 0,
  };
  const screen = projectToScreen(center);
  state.panX -= screen.x;
  state.panY -= screen.y;
  if (state.mode === '3d') state.panZ -= screen.z;
  applyStageTransform();
}

// 按住空格时拖动画布为平移
const panKey = { held: false };
function setPanKey(held) {
  panKey.held = held;
  document.body.classList.toggle('pan-key', held);
}

// 屏幕偏移 anchor 处的内容在缩放前后保持不动
function zoomAt(zoom, anchor) {
  const before = state.zoom;
  state.zoom = Math.max(0.2, Math.min(6, zoom));
  const k = state.zoom / before;
  // 缩放只影响 x/y, z 方向不变
  state.panX = anchor.x - k * (anchor.x - state.panX);
  state.panY = anchor.y - k * (anchor.y - state.panY);
  applyStageTransform();
}

// 客户端坐标 -> 屏幕偏移(相对舞台未变换时的中心)
function clientToAnchor(clientX, clientY) {
  const rect = $(state.mode === 'live' ? 'liveWrap' : 'stageWrap').getBoundingClientRect();
  return { x: clientX - (rect.left + rect.width / 2), y: clientY - (rect.top + rect.height / 2), z: 0 };
}

function updateHighlights() {
  const win = currentWindow();
  if (!win) return;
  if (state.mode === '2d') {
    placeBox($('stage').querySelector('.box.hover'), state.nodes.get(state.hover), win);
    placeBox($('stage').querySelector('.box.selected'), state.nodes.get(state.selected), win);
  } else {
    $('stage').querySelectorAll('.slab').forEach((slab) => {
      slab.classList.toggle('selected', slab.dataset.key === state.selected);
      slab.classList.toggle('hover', slab.dataset.key === state.hover);
    });
  }
  const tree = $('tree');
  tree.querySelectorAll('.row.hover').forEach((row) => row.classList.remove('hover'));
  if (state.hover) tree.querySelector(`.row[data-key="${CSS.escape(state.hover)}"]`)?.classList.add('hover');
}

// MARK: - Hover tip
// 画布悬停标签(类似 Chrome 检查元素): 只显示类名, 带箭头贴在悬停元素顶部, 元素不变则位置不变

// selection: 键盘切换选中时标签贴在选中元素上, 鼠标移动后恢复跟随悬停
const hoverTip = { pendingKey: null, contentTimer: 0, selection: false };

function showHoverTip(event, node) {
  if (!node) {
    hideHoverTip();
    return;
  }
  const tip = $('hoverTip');
  if (hoverTip.selection) {
    hoverTip.selection = false;
    delete tip.dataset.key;
  }
  // 内容防抖: 鼠标在新目标上停留片刻再切换, 快速划过重叠层时不闪烁
  if (tip.hidden || !tip.dataset.key) {
    tip.hidden = false;
    setHoverTipContent(node);
  } else if (tip.dataset.key !== node.key && hoverTip.pendingKey !== node.key) {
    hoverTip.pendingKey = node.key;
    clearTimeout(hoverTip.contentTimer);
    hoverTip.contentTimer = setTimeout(() => {
      const pending = state.nodes.get(hoverTip.pendingKey);
      hoverTip.pendingKey = null;
      if (pending && !$('hoverTip').hidden) setHoverTipContent(pending);
    }, 60);
  } else if (tip.dataset.key === node.key) {
    clearTimeout(hoverTip.contentTimer);
    hoverTip.pendingKey = null;
  }
}

// 键盘切换选中后, 等画布更新完再定位到选中元素
function showSelectionTip() {
  const node = state.nodes.get(state.selected);
  if (!node) return;
  requestAnimationFrame(() => {
    if (state.selected !== node.key) return;
    clearTimeout(hoverTip.contentTimer);
    hoverTip.pendingKey = null;
    hoverTip.selection = true;
    $('hoverTip').hidden = false;
    setHoverTipContent(node);
  });
}

function setHoverTipContent(node) {
  const tip = $('hoverTip');
  tip.dataset.key = node.key;
  tip.textContent = node.cls;
  positionHoverTip();
}

// 以悬停元素在屏幕上的外框定位: 优先上方, 放不下放下方; 水平限制在画布内, 箭头指向元素
function positionHoverTip() {
  const tip = $('hoverTip');
  const key = tip.dataset.key;
  if (tip.hidden || !key) return;
  const target = state.mode === '2d'
    ? $('stage').querySelector(hoverTip.selection ? '.box.selected' : '.box.hover')
    : $('stage').querySelector(`.slab[data-key="${CSS.escape(key)}"]`);
  const rect = target && target.getBoundingClientRect();
  // 选中元素在画布上不可见(不在当前 window / 实时模式等)时不显示
  if (!rect || (!rect.width && !rect.height)) {
    if (hoverTip.selection) hideHoverTip();
    return;
  }
  const pane = $('canvasPane').getBoundingClientRect();
  const top = $('crumbs').getBoundingClientRect().bottom - pane.top;
  const arrow = 5;
  const w = tip.offsetWidth;
  const h = tip.offsetHeight;
  // 标签居中在元素上方, 超出画布时在边缘内收
  const centerX = rect.left - pane.left + rect.width / 2;
  const x = Math.min(Math.max(centerX - w / 2, 4), pane.width - w - 4);
  let y = rect.top - pane.top - h - arrow;
  let below = false;
  if (y < top + 4) {
    y = rect.bottom - pane.top + arrow;
    below = true;
  }
  // 箭头指向元素中点, 标签被限制在画布内时仍对准元素
  tip.style.setProperty('--arrow-x', `${Math.round(Math.min(Math.max(centerX - x, 8), w - 8))}px`);
  tip.classList.toggle('below', below);
  tip.style.transform = `translate(${Math.round(x)}px, ${Math.round(y)}px)`;
}

function hideHoverTip() {
  const tip = $('hoverTip');
  tip.hidden = true;
  hoverTip.selection = false;
  delete tip.dataset.key;
  clearTimeout(hoverTip.contentTimer);
  hoverTip.pendingKey = null;
}

function placeBox(box, node, win) {
  if (!box) return;
  if (!node || node.win !== win) {
    box.style.display = 'none';
    return;
  }
  box.style.display = 'block';
  box.style.left = node.rect[0] - win.rect[0] + 'px';
  box.style.top = node.rect[1] - win.rect[1] + 'px';
  box.style.width = node.rect[2] + 'px';
  box.style.height = node.rect[3] + 'px';
}

// 2D 下取包含该点的最上层节点
function hitTest(x, y) {
  const win = currentWindow();
  let hit = null;
  drawableNodes(win).forEach((node) => {
    const [nx, ny, nw, nh] = node.rect;
    if (x >= nx - win.rect[0] && x <= nx - win.rect[0] + nw && y >= ny - win.rect[1] && y <= ny - win.rect[1] + nh) hit = node;
  });
  return hit;
}

function stagePoint(event) {
  const win = currentWindow();
  const rect = $('stage').getBoundingClientRect();
  return [(event.clientX - rect.left) / rect.width * win.rect[2], (event.clientY - rect.top) / rect.height * win.rect[3]];
}

function setupCanvasEvents() {
  const wrap = $('stageWrap');
  const pointers = new Map();
  let drag = null;
  let lastTap = 0;

  const nodeAtPoint = (point) => {
    if (!currentWindow()) return null;
    if (state.mode === '2d') return hitTest(...stagePoint(point));
    const target = document.elementFromPoint(point.clientX, point.clientY);
    const slab = target && target.closest('.slab');
    return slab ? state.nodes.get(slab.dataset.key) : null;
  };
  // 画布菜单始终针对当前选中节点, 不按点击位置重新选中, 空白处也可呼出
  const openCanvasMenu = (point) => {
    showMenu(point.clientX, point.clientY, state.nodes.get(state.selected), true);
  };
  let pinch = null;

  const updateHover = (e) => {
    let key = null;
    if (state.mode === '2d') {
      const node = currentWindow() && hitTest(...stagePoint(e));
      key = node ? node.key : null;
    } else {
      const slab = e.target.closest('.slab');
      key = slab ? slab.dataset.key : null;
    }
    if (key !== state.hover) {
      state.hover = key;
      updateHighlights();
    }
    showHoverTip(e, state.nodes.get(key));
  };

  const cancelDrag = () => {
    if (drag) clearTimeout(drag.longPress);
    drag = null;
    pinch = null;
    pointers.clear();
    wrap.classList.remove('dragging');
  };

  wrap.addEventListener('pointerdown', (e) => {
    // 按住空格或中键拖动: 平移
    if (e.pointerType === 'mouse' && (e.button === 1 || (e.button === 0 && panKey.held))) {
      e.preventDefault();
      try {
        wrap.setPointerCapture(e.pointerId);
      } catch (err) {
        // 忽略
      }
      hideHoverTip();
      drag = { pan: true, x: e.clientX, y: e.clientY, panX: state.panX, panY: state.panY, moved: true };
      wrap.classList.add('dragging');
      return;
    }
    // 仅左键/触摸开始拖拽, 右键交给菜单
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    try {
      wrap.setPointerCapture(e.pointerId);
    } catch (err) {
      // 合成事件等场景下 pointerId 无效, 不影响拖拽
    }
    if (pointers.size === 2) {
      // 双指缩放
      const [a, b] = [...pointers.values()];
      pinch = { distance: Math.hypot(a.x - b.x, a.y - b.y), zoom: state.zoom };
      drag = null;
      return;
    }
    drag = { x: e.clientX, y: e.clientY, rotX: state.rotX, rotY: state.rotY, moved: false };
    if (e.pointerType !== 'mouse') {
      const point = { clientX: e.clientX, clientY: e.clientY };
      drag.longPress = setTimeout(() => {
        if (!drag || drag.moved) return;
        cancelDrag();
        openCanvasMenu(point);
      }, LONG_PRESS_MS);
    }
  });
  wrap.addEventListener('pointermove', (e) => {
    // 松开事件丢失(如弹出菜单)时, 鼠标未按下即结束拖拽
    if (drag && e.pointerType === 'mouse' && e.buttons === 0) cancelDrag();
    if (pointers.has(e.pointerId)) pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pinch && pointers.size === 2) {
      const [a, b] = [...pointers.values()];
      const distance = Math.hypot(a.x - b.x, a.y - b.y);
      zoomAt(pinch.zoom * distance / Math.max(pinch.distance, 1), clientToAnchor((a.x + b.x) / 2, (a.y + b.y) / 2));
      return;
    }
    if (drag?.pan) {
      state.panX = drag.panX + e.clientX - drag.x;
      state.panY = drag.panY + e.clientY - drag.y;
      applyStageTransform();
      return;
    }
    if (drag) {
      const dx = e.clientX - drag.x;
      const dy = e.clientY - drag.y;
      if (Math.abs(dx) + Math.abs(dy) > 4 && !drag.moved) {
        drag.moved = true;
        clearTimeout(drag.longPress);
      }
      if (state.mode === '3d' && drag.moved) {
        hideHoverTip();
        wrap.classList.add('dragging');
        state.rotY = drag.rotY + dx * 0.3;
        state.rotX = Math.max(-90, Math.min(90, drag.rotX - dy * 0.3));
        applyStageTransform();
        return;
      }
    }
    if (e.pointerType === 'mouse') updateHover(e);
  });
  const endPointer = (e) => {
    pointers.delete(e.pointerId);
    if (pinch) {
      if (pointers.size < 2) pinch = null;
      drag = null;
      return;
    }
    const wasDrag = drag && drag.moved;
    const hadDrag = !!drag;
    if (drag) clearTimeout(drag.longPress);
    drag = null;
    wrap.classList.remove('dragging');
    if (!hadDrag || wasDrag || e.type === 'pointercancel') return;
    // setPointerCapture 后 e.target 恒为 wrap, 需按坐标取真实元素
    const target = document.elementFromPoint(e.clientX, e.clientY);
    if (!target || !wrap.contains(target)) return;
    const node = nodeAtPoint(e);
    if (node) select(node.key);
    if (e.pointerType === 'mouse') return;
    // 触屏双击适应窗口
    const now = Date.now();
    if (now - lastTap < DOUBLE_CLICK_MS) {
      fitView();
      lastTap = 0;
    } else {
      lastTap = now;
    }
  };
  wrap.addEventListener('pointerup', endPointer);
  wrap.addEventListener('pointercancel', endPointer);
  wrap.addEventListener('pointerleave', (e) => {
    hideHoverTip();
    if (e.pointerType !== 'mouse' || drag) return;
    state.hover = null;
    updateHighlights();
  });
  wrap.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    cancelDrag();
    hideHoverTip();
    openCanvasMenu(e);
  });
  window.addEventListener('blur', cancelDrag);
  wrap.addEventListener('wheel', (e) => {
    e.preventDefault();
    hideHoverTip();
    const unit = e.deltaMode === 1 ? 16 : 1;
    if (e.ctrlKey || e.metaKey) {
      // 捏合(触控板以 ctrlKey 滚轮上报, delta 很小)或 ⌘/Ctrl + 滚轮: 缩放
      const factor = e.ctrlKey && Math.abs(e.deltaY) < 50 ? 0.01 : 0.0015;
      zoomAt(state.zoom * Math.exp(-e.deltaY * unit * factor), clientToAnchor(e.clientX, e.clientY));
      return;
    }
    // 双指滑动 / 滚轮: 平移
    state.panX -= e.deltaX * unit;
    state.panY -= e.deltaY * unit;
    applyStageTransform();
  }, { passive: false });
  // Safari 的触控板捏合使用 gesture 事件
  let gestureStartZoom = 1;
  wrap.addEventListener('gesturestart', (e) => {
    e.preventDefault();
    gestureStartZoom = state.zoom;
  });
  wrap.addEventListener('gesturechange', (e) => {
    e.preventDefault();
    const anchor = e.clientX !== undefined ? clientToAnchor(e.clientX, e.clientY) : projectToScreen(state.pivot);
    zoomAt(gestureStartZoom * e.scale, anchor);
  });
  // 面板尺寸变化(拖拽分隔条/切换布局)时重新适配
  new ResizeObserver(applyStageTransform).observe(wrap);
  // 路径导航条尺寸变化后保持显示末尾(当前节点)
  new ResizeObserver(() => {
    const crumbs = $('crumbs');
    crumbs.scrollLeft = crumbs.scrollWidth;
  }).observe($('crumbs'));
}

// MARK: - Live
// 模拟器实时画面: Mac App 采集模拟器屏幕编码为 H.264 经 /sim/ 推送, 并注入触摸与按键, 页面只负责解码绘制与转发操作

const LIVE_RETRY_MS = 2000;
const LIVE_CORNER = 55;
// 设备方向(UIDeviceOrientation) -> 画布旋转角度; 向左旋转的下一个方向, 与 Simulator.app 的 ⌘← 一致
const LIVE_ROTATION = { 1: 0, 3: -90, 2: 180, 4: 90 };
const LIVE_ROTATE_LEFT = { 1: 3, 3: 2, 2: 4, 4: 1 };
const LIVE_KEY_CODE = /^(Key[A-Z]|Digit\d|Enter|Backspace|Tab|Space|Arrow(Up|Down|Left|Right)|Minus|Equal|Bracket(Left|Right)|Backslash|Semicolon|Quote|Backquote|Comma|Period|Slash)$/;
const live = {
  udid: '',
  screen: [0, 0],
  ws: null,
  decoder: null,
  pending: null,
  raf: 0,
  retryTimer: 0,
  connected: false,
  inspect: false,
  altHeld: false,
  touch: null,
  orientation: 1,
  // 收到的画面帧数, 用于判断拖动后画面是否变化; 连续无效拖动次数
  frames: 0,
  deadDrags: 0,
  healing: false,
};

function liveAvailable() {
  return !!live.udid;
}

// Mac App 加载 Xcode 的模拟器私有框架失败时为 false
function liveSupported() {
  return targets.hub?.live !== false;
}

// 实时画面只取决于当前设备是否为运行中的模拟器(在 Mac App 的设备列表中), 与 App 是否运行、是否响应无关;
// 加载时和每次刷新设备列表后调用, 模拟器关闭时断开, 重新启动后自动连上
async function syncLive() {
  const device = currentDevice();
  const udid = device?.kind === 'simulator' ? device.id : '';
  // 真机也显示按钮, 置灰并说明原因
  const realDevice = !!device && !udid;
  $('liveModeBtn').hidden = !udid && !realDevice;
  $('liveModeBtn').classList.toggle('unavailable', realDevice);
  $('liveModeBtn').title = realDevice ? t('真机不支持实时画面') : t('模拟器实时画面');
  document.body.classList.toggle('has-live', !!udid);
  if (udid !== live.udid) {
    liveStop();
    live.udid = udid;
    if (udid) {
      try {
        const info = await fetch(`/sim/${encodeURIComponent(udid)}/info`).then((r) => r.json());
        live.screen = [info.screen.width, info.screen.height];
      } catch (e) {
        // 查询失败时用常见尺寸, 只影响画面比例, 触摸按比例换算不受影响
        live.screen = [402, 874];
      }
      if (live.udid !== udid) return;
    }
  }
  if (state.mode !== 'live') return;
  if (udid) {
    liveStart();
  } else if (realDevice) {
    // 真机不支持实时画面, 回到 2D
    setMode('2d');
  } else {
    showLiveGuide(t('模拟器未运行'));
  }
}

function liveStart() {
  if (live.ws || !liveAvailable()) return;
  clearTimeout(live.retryTimer);
  layoutLive();
  if (typeof VideoDecoder === 'undefined') {
    showLiveGuide(t('当前浏览器不支持 WebCodecs, 请使用 Chrome 或 Safari'), false);
    return;
  }
  if (!liveSupported()) {
    showLiveGuide();
    return;
  }
  const ws = new WebSocket(`ws://${location.host}/sim/${encodeURIComponent(live.udid)}/stream`);
  ws.binaryType = 'arraybuffer';
  live.ws = ws;
  ws.onopen = () => {
    live.connected = true;
    $('liveGuide').hidden = true;
    if (live.restartOnOpen) {
      live.restartOnOpen = false;
      liveSend({ type: 'restart' });
    }
  };
  ws.onmessage = (e) => {
    if (e.data instanceof ArrayBuffer) {
      const buf = new Uint8Array(e.data);
      feedLiveFrame(buf);
      live.frames++;
      // 0x02 关键帧: 手动修复后收到即画面已恢复
      if (live.restoring && buf[0] === 0x02) liveRestored();
      return;
    }
    // 方向由 Mac App 记录并广播, 多个页面保持一致
    try {
      const message = JSON.parse(e.data);
      if (message.type === 'orientation' && LIVE_ROTATION[message.value] !== undefined) {
        live.orientation = message.value;
        layoutLive();
      }
    } catch (err) {
      // 忽略无法解析的消息
    }
  };
  ws.onclose = () => {
    if (live.ws !== ws) return;
    const wasConnected = live.connected;
    liveStop();
    if (state.mode !== 'live') return;
    showLiveGuide(wasConnected ? t('实时画面连接已断开') : '');
    live.retryTimer = setTimeout(liveStart, LIVE_RETRY_MS);
  };
  if (!live.raf) live.raf = requestAnimationFrame(paintLive);
}

function liveStop() {
  clearTimeout(live.retryTimer);
  if (live.ws) {
    const ws = live.ws;
    live.ws = null;
    try {
      ws.close();
    } catch (e) {
      // 已关闭, 忽略
    }
  }
  if (live.decoder) {
    try {
      live.decoder.close();
    } catch (e) {
      // 已关闭, 忽略
    }
    live.decoder = null;
  }
  if (live.pending && live.pending.close) live.pending.close();
  live.pending = null;
  cancelAnimationFrame(live.raf);
  live.raf = 0;
  live.connected = false;
  live.touch = null;
}

// 私有框架加载失败时说明原因, 否则显示等待连接
function showLiveGuide(title) {
  const supported = liveSupported();
  $('liveGuide').hidden = false;
  $('liveGuideTitle').textContent = title || (supported ? t('正在连接实时画面…') : t('无法加载 Xcode 的模拟器框架'));
  $('liveError').hidden = supported;
  $('liveError').textContent = supported ? '' : `${t('请确认已安装 Xcode, 并用 xcode-select 选中它')}\n${targets.hub?.liveError || ''}`;
  $('liveWaiting').hidden = !supported;
}

// 帧格式: 1 字节类型 + 数据. 0x01 解码配置, 0x02 关键帧, 0x03 增量帧, 0x04 首个关键帧前的 JPEG 占位图
function feedLiveFrame(buf) {
  const type = buf[0];
  const payload = buf.slice(1);
  const onFrame = (frame) => {
    if (live.pending && live.pending.close) live.pending.close();
    live.pending = frame;
  };
  if (type === 0x01) {
    if (live.decoder) live.decoder.close();
    live.decoder = new VideoDecoder({ output: onFrame, error: (e) => console.warn('live decoder:', e.message) });
    const hex = (b) => b.toString(16).padStart(2, '0');
    live.decoder.configure({
      codec: `avc1.${hex(payload[1])}${hex(payload[2])}${hex(payload[3])}`,
      description: payload,
      optimizeForLatency: true,
      hardwareAcceleration: 'prefer-hardware',
    });
    live.timestamp = 0;
  } else if ((type === 0x02 || type === 0x03) && live.decoder && live.decoder.state === 'configured') {
    try {
      live.decoder.decode(new EncodedVideoChunk({ type: type === 0x02 ? 'key' : 'delta', timestamp: live.timestamp, data: payload }));
      live.timestamp += 16667;
    } catch (e) {
      // 丢帧, 等下一个关键帧
    }
  } else if (type === 0x04) {
    createImageBitmap(new Blob([payload], { type: 'image/jpeg' })).then(onFrame).catch(() => {});
  }
}

// 每次刷新只绘制最新一帧, 旧帧直接丢弃, 延迟不会累积
function paintLive() {
  live.raf = requestAnimationFrame(paintLive);
  const frame = live.pending;
  if (!frame) return;
  live.pending = null;
  const canvas = $('liveCanvas');
  const w = frame.displayWidth || frame.width;
  const h = frame.displayHeight || frame.height;
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
  }
  canvas.getContext('2d').drawImage(frame, 0, 0);
  if (frame.close) frame.close();
}

function layoutLive() {
  const wrap = $('liveWrap');
  const canvas = $('liveCanvas');
  const [sw, sh] = live.screen;
  if (!sw || !sh || !wrap.clientWidth) return;
  // 与 2D 舞台相同的适配系数, 切换时比例与位置保持一致; 横屏时按旋转后的尺寸适配
  const [width, height] = contentSize(wrap);
  const deg = LIVE_ROTATION[live.orientation] || 0;
  const [fw, fh] = Math.abs(deg) === 90 ? [sh, sw] : [sw, sh];
  const scale = Math.min(width / fw, height / fh) * planFitRatio() * state.zoom;
  canvas.style.width = sw * scale + 'px';
  canvas.style.height = sh * scale + 'px';
  canvas.style.borderRadius = LIVE_CORNER * scale + 'px';
  canvas.style.transform = `translate(${state.panX}px, ${state.panY}px) rotate(${deg}deg)`;
}

// 触摸失效检测: 明显的拖动后画面一帧都没变化, 连续多次即提示修复.
// 服务端只在画面变化时推帧, 拖动在 App 内几乎总会让画面变化
function checkLiveDrag(touch) {
  if (live.healing || touch.distance < LIVE_HEAL_DRAG) return;
  const frames = touch.frames;
  setTimeout(() => {
    if (live.frames !== frames) {
      live.deadDrags = 0;
      return;
    }
    live.deadDrags++;
    if (live.deadDrags >= LIVE_HEAL_STRIKES) showLiveHeal();
  }, LIVE_HEAL_WAIT_MS);
}

function showLiveHeal() {
  if (live.healing) return;
  $('liveHeal').dataset.state = 'warn';
  $('liveHealText').textContent = t('触摸似乎没有生效, 修复会结束前台 App');
  $('liveHealBtn').hidden = false;
  $('liveHealClose').hidden = false;
  $('liveHeal').hidden = false;
}

function hideLiveHeal() {
  live.deadDrags = 0;
  $('liveHeal').hidden = true;
}

// 重启模拟器的 backboardd(连带 SpringBoard), 约 10 秒后界面恢复
async function healLiveTouch() {
  if (live.healing || !live.udid) return;
  live.healing = true;
  $('liveHeal').dataset.state = 'restarting';
  $('liveHealText').textContent = t('正在修复触摸, 模拟器桌面约 10 秒后恢复');
  $('liveHealBtn').hidden = true;
  $('liveHealClose').hidden = true;
  $('liveHeal').hidden = false;
  try {
    const res = await fetch(`/sim/${encodeURIComponent(live.udid)}/heal`, { method: 'POST' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    await new Promise((resolve) => setTimeout(resolve, LIVE_HEAL_RECOVER_MS));
    toast(t('触摸已修复'));
  } catch (e) {
    toast(t('修复失败: {0}', e.message), true);
  }
  live.healing = false;
  hideLiveHeal();
}

async function revealLogs() {
  hidePopovers();
  try {
    const res = await fetch('/api/hub/logs', { method: 'POST' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
  } catch (e) {
    toast(t('打开失败: {0}', e.message), true);
  }
}

function liveSend(message) {
  if (live.ws && live.ws.readyState === WebSocket.OPEN) live.ws.send(JSON.stringify(message));
}

// 客户端坐标 -> 模拟器屏幕坐标(point)
// 画布按设备方向旋转显示, 先绕中心反向旋转回未旋转的画布, 再换算为竖屏的屏幕坐标
function livePoint(e) {
  const canvas = $('liveCanvas');
  const rect = canvas.getBoundingClientRect();
  const [sw, sh] = live.screen;
  const rad = -(LIVE_ROTATION[live.orientation] || 0) * Math.PI / 180;
  const dx = e.clientX - (rect.left + rect.width / 2);
  const dy = e.clientY - (rect.top + rect.height / 2);
  const rx = (dx * Math.cos(rad) - dy * Math.sin(rad)) / canvas.offsetWidth + 0.5;
  const ry = (dx * Math.sin(rad) + dy * Math.cos(rad)) / canvas.offsetHeight + 0.5;
  const x = Math.max(0, Math.min(sw, rx * sw));
  const y = Math.max(0, Math.min(sh, ry * sh));
  return { x: Math.round(x * 10) / 10, y: Math.round(y * 10) / 10, inside: rx >= 0 && rx <= 1 && ry >= 0 && ry <= 1 };
}

function liveRotate() {
  liveSend({ type: 'orientation', value: LIVE_ROTATE_LEFT[live.orientation] || 1 });
}

// 画面黑屏或卡住(如锁屏、休眠后)时手动恢复: 让 LayerLens 重建采集与编码, 收到关键帧即恢复成功;
// 不在实时模式时先切过去, 连接未建立时等连上再发送
const LIVE_RESTORE_TIMEOUT_MS = 5000;

async function liveRestart() {
  hidePopovers();
  clearTimeout(live.restoreTimer);
  live.restoring = true;
  live.restoreTimer = setTimeout(() => {
    if (!live.restoring) return;
    live.restoring = false;
    toast(t('仍未收到画面, 可尝试重启 LayerLens'));
  }, LIVE_RESTORE_TIMEOUT_MS);
  toast(t('正在重新连接画面…'));
  if (state.mode !== 'live') await setMode('live');
  if (live.ws && live.ws.readyState === WebSocket.OPEN) {
    liveSend({ type: 'restart' });
  } else {
    liveStop();
    live.restartOnOpen = true;
    liveStart();
  }
}

function liveRestored() {
  live.restoring = false;
  clearTimeout(live.restoreTimer);
  toast(t('实时画面已恢复'));
}

// Home: 由 LayerLens 启动 SpringBoard, 直接回桌面; 失败时退回上滑手势.
// Xcode 27 的 Device Hub 接管后, 硬件 home 按钮事件无效
async function liveHome() {
  try {
    const res = await fetch('/api/hub/home', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device: live.udid }),
    });
    if (res.ok) return;
  } catch (e) {
    // LayerLens 不可用, 走手势
  }
  liveSend({ type: 'button', button: 'swipe-to-home' });
}

// MARK: - Targets
// 页面同一时间只连接一个 App, 由 Mac App 转发: /t/<设备 ID>/<Bundle ID>/api/...
// 选择保存在地址参数和 localStorage 中, App 重启换端口后由 Mac App 重新匹配

const TARGET_KEY = 'layerlens_target';
const TARGETS_POLL_MS = 2000;
const API_VERSION = 1;
// hadDevice: 页面加载时选中的设备是否存在
// idle: 正在显示没有设备的默认页; goneSince: 设备全部断开的时间
const targets = { hub: null, devices: [], deviceId: '', bundleId: '', hadDevice: false, idle: false, goneSince: 0 };

function targetBase() {
  return `/t/${encodeURIComponent(targets.deviceId || '-')}/${encodeURIComponent(targets.bundleId || '-')}`;
}

function currentDevice() {
  return targets.devices.find((d) => d.id === targets.deviceId) || null;
}

function currentApp() {
  return currentDevice()?.apps.find((a) => a.bundleId === targets.bundleId) || null;
}

function appCompatible(app) {
  return app.apiVersion === API_VERSION;
}

// 旧版 Pod 没有 apiVersion
function compatibilityWarning(app) {
  if (!app || appCompatible(app)) return '';
  if (!app.apiVersion || app.apiVersion < API_VERSION) return t('App 中的 LayerLens 版本过旧, 部分功能可能不可用, 请更新 Pod');
  return t('LayerLens Mac App 版本过旧, 部分功能可能不可用, 请更新 Mac App');
}

async function loadTargets() {
  const res = await fetch('/api/targets', { cache: 'no-store' });
  const data = await res.json();
  targets.hub = data.hub;
  targets.devices = data.devices || [];
}

function savedTarget() {
  const params = new URLSearchParams(location.search);
  if (params.get('device')) return { deviceId: params.get('device'), bundleId: params.get('app') || '', explicit: true };
  try {
    return JSON.parse(localStorage.getItem(TARGET_KEY)) || {};
  } catch (e) {
    return {};
  }
}

// 地址参数指定的目标始终保留(设备或 App 稍后可能启动); 记住的目标不存在时自动选第一个运行中的 App
function pickTarget() {
  const saved = savedTarget();
  const device = targets.devices.find((d) => d.id === saved.deviceId);
  if (saved.explicit || device?.apps.some((a) => a.bundleId === saved.bundleId)) {
    targets.deviceId = saved.deviceId || '';
    targets.bundleId = saved.bundleId || '';
    return;
  }
  // 没有运行中的 App 时也选中第一台设备, 以便使用实时画面
  const first = targets.devices.find((d) => d.apps.length) || targets.devices[0];
  targets.deviceId = first ? first.id : '';
  targets.bundleId = firstAppId(first);
}

// 挂起的 App 由 Mac App 标记 suspended; 在后台但未挂起(如 Xcode 调试中)的由 App 上报 foreground
// foreground 由 Pod 上报, 可能是布尔值或 0 / 1; 旧版 Pod 不上报
function appInBackground(app) {
  return !!app.suspended || app.foreground === false || app.foreground === 0;
}

function appInForeground(app) {
  return !app.suspended && (app.foreground === true || app.foreground === 1);
}

// 自动选择时优先前台的 App, 挂起的 App 现在也会留在列表里
function firstAppId(device) {
  return (device?.apps.find((a) => !appInBackground(a)) || device?.apps[0])?.bundleId || '';
}

// 选择在后台的 App 时先把它切到前台, 否则层级和实时画面都不是它
async function activateApp(deviceId, bundleId) {
  try {
    await fetch('/api/hub/activate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device: deviceId, app: bundleId }),
    });
  } catch (e) {
    // 失败时仍切换, 由页面提示在后台
  }
}

function switchTarget(deviceId, bundleId) {
  // 重新加载后保持当前模式(如实时画面)和视角
  saveViewState();
  try {
    localStorage.setItem(TARGET_KEY, JSON.stringify({ deviceId, bundleId }));
  } catch (e) {
    // 不可用时只依赖地址参数
  }
  const params = new URLSearchParams({ device: deviceId, app: bundleId });
  location.search = params.toString();
}

function renderTargetMenu() {
  const menu = $('targetMenu');
  const children = [];
  if (!targets.devices.length) {
    children.push(el('div', 'target-empty', t('没有发现设备')));
  }
  // 挂起的 App 不响应探测, 会从列表消失; 在后台时沿用最后一次的信息显示
  const background = appState.value === 'background';
  if (currentApp()) targets.lastApp = currentApp();
  targets.devices.forEach((device) => {
    // 模拟器可以只选设备, 不连接 App 时也能使用实时画面
    const selectable = device.kind === 'simulator';
    const head = el(selectable ? 'button' : 'div', 'target-device', device.name);
    // 真机名称是用户自定义的, 附上机型; 与名称相同(如模拟器)时不重复
    const model = device.model && device.model !== device.name ? device.model : '';
    head.append(el('span', null, [model, device.os].filter(Boolean).join(' · ')), el('span', 'target-kind ' + (selectable ? 'kind-simulator' : 'kind-device'), selectable ? t('模拟器') : t('设备 (USB)')));
    if (selectable) {
      head.classList.toggle('current', device.id === targets.deviceId && !targets.bundleId);
      head.title = t('只使用实时画面');
      head.addEventListener('click', () => {
        hidePopovers();
        if (device.id !== targets.deviceId || targets.bundleId) switchTarget(device.id, '');
      });
    }
    children.push(head);
    const apps = [...device.apps];
    const last = targets.lastApp;
    if (background && device.id === targets.deviceId && last?.bundleId === targets.bundleId && !apps.some((a) => a.bundleId === last.bundleId)) apps.push(last);
    if (!apps.length) children.push(el('div', 'target-empty', t('没有运行中的已集成 App')));
    apps.forEach((app) => {
      const row = el('button', 'target-app');
      const current = device.id === targets.deviceId && app.bundleId === targets.bundleId;
      const inBackground = (current && background) || appInBackground(app);
      row.classList.toggle('current', current);
      row.classList.toggle('background', inBackground);
      row.append(el('span', 'status-dot'), el('span', 'target-app-name', app.appName || app.bundleId));
      if (!appCompatible(app)) row.append(el('span', 'target-badge', t('版本不兼容')));
      row.append(el('span', 'target-app-meta', inBackground ? t('在后台') : app.version || ''));
      row.title = `${app.bundleId} · ${t('端口 {0}', app.port)}`;
      row.addEventListener('click', async () => {
        hidePopovers();
        // 切换到其他 App 时总是先激活: 旧版 Pod 不上报 foreground, 在后台也看不出来; 已在前台时无影响
        if (inBackground || !current) {
          // 激活要等 App 响应, 最多几秒
          toast(t('正在切换到 {0}…', app.appName || app.bundleId));
          await activateApp(device.id, app.bundleId);
        }
        // 当前 App 回到前台后由事件流恢复, 不必重新加载; 同一设备上换 App 原地切换, 实时画面不中断
        if (current) return;
        if (device.id === targets.deviceId && targets.bundleId) switchTargetInPlace(app.bundleId);
        else switchTarget(device.id, app.bundleId);
      });
      children.push(row);
    });
  });
  const footer = el('button', 'menu-row menu-action target-footer', t('App 集成…'));
  footer.dataset.panel = 'integration';
  children.push(el('div', 'menu-sep'), footer);
  menu.replaceChildren(...children);
}

// 跟随模拟器前台 App: 当前 App 进入后台(或已退出)时, 切到同一设备上在前台的另一个已集成 App;
// 前台是未集成的 App(如设置)时保持不动. 旧版 Pod 不上报 foreground, 不参与跟随.
// 事件流连着时以 App 实时推送的状态为准; Mac App 的列表每 2s 扫描一次, 刚切换后可能还是旧状态
function currentAppAway() {
  if (!currentDevice() || !targets.bundleId) return false;
  if (appState.value === 'background') return true;
  const app = currentApp();
  if (appState.value === 'offline') return !app;
  return !appState.connected && !!app && appInBackground(app);
}

function followForeground(next) {
  const app = targets.devices.find((d) => d.id === next[0])?.apps.find((a) => a.bundleId === next[1]);
  switchTargetInPlace(next[1]);
  toast(t('已切换到前台 App {0}', app?.appName || next[1]));
}

// 同一设备上换 App: 只替换目标、事件流、App 信息和层级, 不重新加载页面, 实时画面不中断
function switchTargetInPlace(bundleId) {
  try {
    localStorage.setItem(TARGET_KEY, JSON.stringify({ deviceId: targets.deviceId, bundleId }));
  } catch (e) {
    // 不可用时只依赖地址参数
  }
  history.replaceState(null, '', '?' + new URLSearchParams({ device: targets.deviceId, app: bundleId }).toString());
  targets.bundleId = bundleId;
  clearTimeout(appState.offlineTimer);
  appState.offlineTimer = 0;
  appState.dropped = false;
  appState.connected = false;
  appState.instanceId = currentApp()?.instanceId || '';
  appState.warning = compatibilityWarning(currentApp());
  setAppState('online');
  watchApp();
  loadAppInfo();
  clearHierarchy();
  if (state.mode !== 'live') refresh();
}

// 实时画面下旧层级作废时只清空, 不重新获取: 取层级和截图都在 App 主线程执行, 刚启动或回到前台时会卡住实时画面;
// 切回 2D / 3D 或选择元素时会重新获取
function clearHierarchy() {
  ++refreshSeq;
  resetImages();
  state.roots = [];
  state.nodes = new Map();
  state.selected = null;
  state.expanded.clear();
  renderTree();
  loadDetail();
  updateAppMeta();
}

// 直接询问同一设备上其他 App 当前是否在前台, 不等 Mac App 每 2s 一次的端口扫描; 挂起的 App 不响应, 超时跳过
async function probeForeground() {
  const device = currentDevice();
  if (!device) return null;
  const others = device.apps.filter((a) => a.bundleId !== targets.bundleId);
  const found = await Promise.all(others.map(async (a) => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 800);
    try {
      const res = await fetch(`/t/${encodeURIComponent(device.id)}/${encodeURIComponent(a.bundleId)}/api/app`, { cache: 'no-store', signal: controller.signal });
      const info = await res.json();
      return appInForeground(info) ? a.bundleId : null;
    } catch (e) {
      return null;
    } finally {
      clearTimeout(timer);
    }
  }));
  const bundleId = found.find(Boolean);
  return bundleId ? [device.id, bundleId] : null;
}

// 当前 App 是否确实在后台: 以 App 实时返回的状态为准; 挂起不响应时沿用列表中的挂起标记
async function probeCurrentBackground() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 800);
  try {
    const res = await fetch(targetBase() + '/api/app', { cache: 'no-store', signal: controller.signal });
    return appInBackground(await res.json());
  } catch (e) {
    return !!currentApp()?.suspended;
  } finally {
    clearTimeout(timer);
  }
}

// 当前 App 不在前台时查找前台 App: 先看 Mac App 的列表, 没有再直接询问各 App; 每 400ms 一次, 约 6s 后交给定时刷新
const foregroundCheck = { running: false };

async function checkForeground() {
  if (foregroundCheck.running) return;
  foregroundCheck.running = true;
  try {
    for (let attempt = 0; attempt < 15 && currentAppAway(); attempt++) {
      try {
        await loadTargets();
        // 只认直接询问得到的实时状态, 列表中的前台标记可能过期, 会在两个 App 间来回切换
        const next = await probeForeground();
        if (next && currentAppAway()) {
          followForeground(next);
          return;
        }
      } catch (e) {
        // 下次再试
      }
      await new Promise((resolve) => setTimeout(resolve, 400));
    }
  } finally {
    foregroundCheck.running = false;
  }
}

// 需要自动切换时返回 [设备 ID, Bundle ID]: 选中的设备启动了, 选中的设备上出现 App, 或未选设备时出现设备
function nextTarget() {
  if (targets.idle) {
    if (!targets.devices.length) return null;
    const back = currentDevice();
    if (back) return [back.id, targets.bundleId || firstAppId(back)];
    const first = targets.devices.find((d) => d.apps.length) || targets.devices[0];
    return [first.id, firstAppId(first)];
  }
  const device = currentDevice();
  if (device) {
    if (!targets.hadDevice) return [device.id, targets.bundleId || firstAppId(device)];
    if (!targets.bundleId && device.apps.length) return [device.id, firstAppId(device)];
    return null;
  }
  if (targets.deviceId || !targets.devices.length) return null;
  const first = targets.devices.find((d) => d.apps.length) || targets.devices[0];
  return [first.id, firstAppId(first)];
}

// 设备全部断开持续一段时间后回到默认页, 短暂中断(重新插拔, 模拟器重启)不切换
const DEVICES_GONE_MS = 3000;

function devicesGone() {
  if (targets.idle || targets.devices.length) {
    targets.goneSince = 0;
    return false;
  }
  targets.goneSince = targets.goneSince || Date.now();
  return Date.now() - targets.goneSince >= DEVICES_GONE_MS;
}

// 定时刷新设备列表, 设备或 App 出现时自动连接
function pollTargets() {
  setTimeout(async () => {
    try {
      await loadTargets();
      renderTargetMenu();
      syncLive();
      if (devicesGone()) {
        location.reload();
        return;
      }
      // 回到前台的通知可能早于事件流连上而错过, 列表里显示已在前台时恢复
      if (appState.value === 'background' && currentApp() && appInForeground(currentApp())) {
        setAppState('online');
        if (state.mode !== 'live') refresh();
      }
      const next = nextTarget();
      if (next) {
        switchTarget(...next);
        return;
      }
      // 事件流里的后台通知可能丢失(如重连时被覆盖), 列表显示在后台时直接询问当前 App 确认
      if (appState.value === 'online' && currentApp() && appInBackground(currentApp()) && await probeCurrentBackground()) {
        setAppState('background');
      }
      if (currentAppAway()) checkForeground();
    } catch (e) {
      // Mac App 已退出, 下次再试
    }
    pollTargets();
  }, TARGETS_POLL_MS);
}

// MARK: - App state
// 通过不关闭的事件流感知 App: 断开即离线, 浏览器自动重连成功即 App 已重新启动

// instanceId: 页面加载时 App 的启动标识, 重连后不变说明 App 没有重启(如 USB 短暂断开)
const appState = { value: 'online', connected: false, dropped: false, warning: '', instanceId: '', offlineTimer: 0 };
const OFFLINE_GRACE_MS = 4000;

function watchApp() {
  appState.source?.close();
  const source = new EventSource(targetBase() + '/api/events');
  appState.source = source;
  source.onopen = () => {
    appState.connected = true;
    clearTimeout(appState.offlineTimer);
    appState.offlineTimer = 0;
    if (!appState.dropped) {
      setAppState('online');
      return;
    }
    reconnected();
  };
  // App 进入后台后被挂起, 事件流不断开, 由 App 推送前后台状态; 旧版 Pod 不推送, 视为前台
  source.addEventListener('state', (e) => {
    const { foreground } = JSON.parse(e.data || '{}');
    const away = foreground === false || foreground === 0;
    if (away && appState.value === 'online') {
      setAppState('background');
      checkForeground();
    } else if (!away && appState.value === 'background') {
      setAppState('online');
      // 在后台期间页面可能已变化, 实时画面之外重新获取层级
      if (state.mode !== 'live') refresh();
    }
  });
  source.onerror = () => {
    appState.connected = false;
    appState.dropped = true;
    if (appState.value === 'restarting' || appState.offlineTimer) return;
    // 回到前台时 App 会重启监听, 事件流短暂断开后约 2s 重连; 宽限一段时间再显示离线, 避免提示条闪现
    appState.offlineTimer = setTimeout(() => {
      appState.offlineTimer = 0;
      if (!appState.connected && appState.value !== 'restarting') setAppState('offline');
    }, OFFLINE_GRACE_MS);
  };
}

// link 为提示条上的次要按钮, 如 { text, panel }
// 重新连上时 App 已重新启动则重新加载, 以使用新的 App 信息;
// 刚连上时首页还未加载完(实测约 2s 后启动遮罩才移除), 过早拉取的层级会过期.
// 重启后通常停在首页, 模拟器上先切到实时画面便于操作到目标页, 切回 2D/3D 时会刷新层级
async function reconnected() {
  try {
    await loadTargets();
  } catch (e) {
    // 取不到时按重启处理
  }
  if (appState.instanceId && currentApp()?.instanceId === appState.instanceId) {
    appState.dropped = false;
    // 等待列表期间事件流可能已推送在后台, 不覆盖
    if (appState.value !== 'background') setAppState('online');
    return;
  }
  const toLive = liveAvailable() && state.mode !== 'live';
  if (toLive) await setMode('live');
  // 实时画面一直连着, 不整页重新加载, 原地更新 App 信息; oid 已重新分配, 旧层级作废
  if (state.mode === 'live') {
    appState.dropped = false;
    appState.instanceId = currentApp()?.instanceId || '';
    appState.warning = compatibilityWarning(currentApp());
    // 原来靠整页重新加载复位, 这里手动结束运行跟踪
    setRunning(false);
    setAppState('online');
    if (toLive) toast(t('App 已重启, 已切换到实时画面'));
    loadAppInfo();
    clearHierarchy();
    return;
  }
  setAppState('back');
  setTimeout(() => location.reload(), 3000);
}

function setAppState(value, message, link) {
  appState.value = value;
  document.body.classList.toggle('app-restarting', value === 'restarting');
  // 在后台时同样不能选择元素; 实时画面下只用状态点提示, 不挡住画面
  document.body.classList.toggle('app-offline', value === 'offline' || value === 'background');
  document.body.classList.toggle('app-background', value === 'background');
  syncLiveCursor();
  // 版本不兼容时仍可使用, 在线状态下常驻提示
  const shown = value === 'online' && appState.warning ? 'warn' : value;
  const canRun = document.body.classList.contains('has-live') && !!targets.bundleId;
  const texts = {
    restarting: t('正在编译并重启 App, 完成后自动刷新'),
    offline: canRun ? t('App 未运行或在后台') : t('App 未运行或在后台, 启动后会自动连接'),
    background: t('App 在后台, 回到前台后自动连接'),
    back: t('已连接, 正在刷新…'),
    warn: appState.warning,
  };
  const text = message || texts[shown] || '';
  $('appBanner').dataset.state = shown;
  $('appBannerText').textContent = text;
  $('appBannerText').title = text;
  $('appBannerRun').hidden = shown !== 'offline' || !canRun;
  $('appBannerLink').hidden = !link;
  $('appBannerLink').textContent = link?.text || '';
  if (link?.panel) $('appBannerLink').dataset.panel = link.panel;
  else delete $('appBannerLink').dataset.panel;
  $('appBanner').hidden = shown === 'online';
  setStatus(value !== 'offline' && value !== 'restarting', text, false);
  if (value === 'background') {
    $('statusDot').className = 'status-dot warn';
    $('statusDot').title = text;
  }
  renderTargetMenu();
}

// 画布中央的引导, 实时模式下不显示
function showEmptyState(title, body) {
  $('emptyTitle').textContent = title;
  $('emptyBody').textContent = body;
  $('emptyGuide').hidden = true;
  $('emptyState').hidden = false;
  document.body.classList.add('has-empty');
}

// 没有任何设备时的默认页: 使用步骤
function showGuide() {
  showEmptyState(t('没有发现设备'), t('按以下步骤开始使用, 设备连接后会自动打开'));
  const box = (cls, children) => {
    const node = el('div', cls);
    node.append(...children);
    return node;
  };
  const step = (index, title, content) => box('guide-step', [el('span', 'guide-index', String(index)), box('guide-content', [el('div', 'guide-title', title), ...content])]);
  const copy = el('button', 'live-copy', t('复制'));
  copy.dataset.copy = POD_LINE;
  $('emptyGuide').replaceChildren(
    step(1, t('集成'), [box('guide-code', [balanceScrollbar(el('code', null, POD_LINE)), copy]), el('div', 'guide-text', t('只在 Debug 下集成, 执行 pod install 即可, 无需代码'))]),
    step(2, t('运行'), [el('div', 'guide-text', t('在模拟器中运行 App, 或通过 USB 连接真机运行'))]),
    step(3, t('查看'), [el('div', 'guide-text', t('2D / 3D 查看视图层级和属性, 模拟器还支持实时画面'))]),
  );
  $('emptyGuide').hidden = false;
}

// MARK: - Xcode run
// 编译期间每秒查询一次 Xcode 状态以显示编译错误; 新 App 启动由事件流重连感知

const RUN_POLL_MS = 1000;
const RUN_TIMEOUT_MS = 10 * 60 * 1000;
const xcode = { running: false, timer: null };

// 由 LayerLens 驱动 Xcode, 它按 App 上报过的源文件路径找到对应的工作区
async function callXcode(command) {
  const app = encodeURIComponent(targets.bundleId);
  const res = command === 'run'
    ? await fetch('/api/hub/run', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ app: targets.bundleId, device: targets.deviceId || '' }) })
    : await fetch(`/api/hub/run-status?app=${app}`, { cache: 'no-store' });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

// 错误码转为可操作的提示, 未识别的错误原样显示
function runErrorText(e) {
  const messages = {
    xcode_not_running: t('Xcode 未打开'),
    project_not_open: t('Xcode 中未打开本项目'),
    permission_denied: t('没有控制 Xcode 的权限, 请在 系统设置 › 隐私与安全性 › 自动化 中允许'),
    permission_required: t('需要允许 LayerLens 控制 Xcode'),
  };
  if (e instanceof TypeError) return t('无法连接 LayerLens');
  return messages[e.message] || t('运行失败: {0}', e.message);
}

function setRunning(on) {
  xcode.running = on;
  clearTimeout(xcode.timer);
  $('xcodeRun').classList.toggle('loading', on);
  $('xcodeRun').title = on ? t('正在运行… 点击取消跟踪') : t('在 Xcode 中运行');
}

// 结束跟踪: 旧 App 仍在则回到在线并提示, 否则显示离线提示条
function endRun(message) {
  setRunning(false);
  if (!appState.connected) {
    setAppState('offline', message);
    return;
  }
  setAppState('online');
  if (message) toast(message, true);
}

async function xcodeRun() {
  if (xcode.running) {
    endRun();
    return;
  }
  setRunning(true);
  try {
    // 首次运行会弹出系统授权窗口, 请求会等待用户选择
    const hint = setTimeout(() => toast(t('请在系统弹窗中允许 LayerLens 控制 Xcode')), 1500);
    try {
      const { switched } = await callXcode('run');
      // Xcode 会先切到正在查看的设备; 没有对应的运行目标时沿用 Xcode 当前选择, App 可能运行在别的设备上
      if (!switched && targets.deviceId) toast(t('Xcode 中没有当前设备的运行目标, 将运行到 Xcode 当前选择的设备'));
    } finally {
      clearTimeout(hint);
    }
  } catch (e) {
    endRun(runErrorText(e));
    return;
  }
  setAppState('restarting');
  const deadline = Date.now() + RUN_TIMEOUT_MS;
  const check = async () => {
    if (!xcode.running) return;
    try {
      const { status, detail } = await callXcode('status');
      if (['failed', 'error occurred', 'cancelled'].includes(status)) {
        endRun(status === 'cancelled' ? t('运行已取消') : detail ? t('编译失败: {0}', detail) : t('编译失败, 请在 Xcode 查看'));
        return;
      }
    } catch (e) {
      // 查询失败不影响跟踪, 下次再试
    }
    if (!xcode.running) return;
    if (Date.now() > deadline) {
      endRun(t('等待超时, 请在 Xcode 查看'));
      return;
    }
    xcode.timer = setTimeout(check, RUN_POLL_MS);
  };
  xcode.timer = setTimeout(check, RUN_POLL_MS);
}

function setLiveInspect(on) {
  live.inspect = on;
  if (on && picker.on) setColorPicker(false);
  $('liveInspect').classList.toggle('on', on);
  $('liveInspect').setAttribute('aria-pressed', String(on));
  syncLiveCursor();
}

function syncLiveCursor() {
  $('liveWrap').classList.toggle('inspecting', canInspect() && (live.inspect || live.altHeld));
}

// 选择元素需要连上已集成的 App; 否则实时画面当普通模拟器用, ⌥ + 点击按普通点击处理
function canInspect() {
  const body = document.body.classList;
  return body.contains('has-app') && !body.contains('app-offline');
}

// 刷新层级后选中该点最上层的视图, 并切到 2D 查看
async function inspectAt(point) {
  setLiveInspect(false);
  await setMode('2d');
  const win = keyWindow();
  if (!win) return;
  state.selected = win.key;
  const node = hitTest(point.x - win.rect[0], point.y - win.rect[1]);
  select((node || win).key);
}

// 静止按住多久后发送按下; 移动多少点(设备坐标)才算拖动; 点击时按下到抬起的间隔
const LIVE_PRESS_DELAY_MS = 300;
const LIVE_DRAG_SLOP = 3;
const LIVE_TAP_MS = 40;
// 触摸失效检测: 拖动超过多少点才计入; 松开后等多久看画面是否变化; 连续几次无变化提示修复; 修复后等待界面恢复的时长
const LIVE_HEAL_DRAG = 40;
const LIVE_HEAL_WAIT_MS = 600;
const LIVE_HEAL_STRIKES = 2;
const LIVE_HEAL_RECOVER_MS = 10000;

function setupLiveEvents() {
  const wrap = $('liveWrap');
  const canvas = $('liveCanvas');
  const [w, h] = [() => live.screen[0], () => live.screen[1]];

  canvas.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    e.preventDefault();
    canvas.focus({ preventScroll: true });
    hideMenu();
    try {
      canvas.setPointerCapture(e.pointerId);
    } catch (err) {
      // pointerId 无效时忽略
    }
    const point = livePoint(e);
    if (canInspect() && (live.inspect || e.altKey)) {
      live.touch = { inspect: true, point };
      return;
    }
    // 起点贴近上下边缘时作为系统手势(下拉通知中心 / 上滑回桌面)
    const edge = point.y >= h() - 20 ? 'bottom' : point.y <= 12 ? 'top' : undefined;
    live.touch = { inspect: false, start: point, pending: true, timer: 0, distance: 0, frames: live.frames };
    if (edge) {
      flushDown(live.touch, edge);
      return;
    }
    // 静止按住一段时间后才按下, 以便长按手势照常触发
    live.touch.timer = setTimeout(() => live.touch && flushDown(live.touch), LIVE_PRESS_DELAY_MS);
  });
  // 鼠标通常先按住再拖动, 若按下即发送, 超过 UIScrollView 的延迟(约 150ms)后触摸会交给按钮等 UIControl, 列表无法滚动.
  // 因此推迟到开始移动或松开时才发送按下, 使 App 看到的是按下即移动的手势, 与手指滑动一致
  const flushDown = (touch, edge) => {
    if (!touch.pending) return false;
    touch.pending = false;
    clearTimeout(touch.timer);
    liveSend({ type: 'touch1-down', x: touch.start.x, y: touch.start.y, width: w(), height: h(), edge });
    return true;
  };
  canvas.addEventListener('pointermove', (e) => {
    const touch = live.touch;
    if (!touch || touch.inspect) return;
    const point = livePoint(e);
    const distance = Math.hypot(point.x - touch.start.x, point.y - touch.start.y);
    touch.distance = Math.max(touch.distance, distance);
    if (touch.pending && distance < LIVE_DRAG_SLOP) return;
    flushDown(touch);
    liveSend({ type: 'touch1-move', x: point.x, y: point.y, width: w(), height: h() });
  });
  const endTouch = (e) => {
    const touch = live.touch;
    live.touch = null;
    if (!touch) return;
    const point = livePoint(e);
    if (touch.inspect) {
      if (e.type === 'pointerup' && point.inside) inspectAt(point);
      return;
    }
    if (e.type === 'pointerup') checkLiveDrag(touch);
    const up = () => liveSend({ type: 'touch1-up', x: point.x, y: point.y, width: w(), height: h() });
    // 点击时按下与抬起间隔过短可能不被识别为点击
    if (flushDown(touch)) setTimeout(up, LIVE_TAP_MS);
    else up();
  };
  canvas.addEventListener('pointerup', endTouch);
  canvas.addEventListener('pointercancel', endTouch);
  // 实时画面的右键菜单只有屏幕截图, 元素信息在层级树右键复制
  wrap.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    showMenu(e.clientX, e.clientY, null, true, true);
  });
  // 与 2D 一致: 捏合 / ⌘ + 滚轮缩放, 双指滑动平移; App 内滚动用鼠标拖动.
  // 不注入滚轮事件: 在 iOS 26 模拟器上会导致 backboardd 崩溃
  wrap.addEventListener('wheel', (e) => {
    e.preventDefault();
    const unit = e.deltaMode === 1 ? 16 : 1;
    if (e.ctrlKey || e.metaKey) {
      const factor = e.ctrlKey && Math.abs(e.deltaY) < 50 ? 0.01 : 0.0015;
      zoomAt(state.zoom * Math.exp(-e.deltaY * unit * factor), clientToAnchor(e.clientX, e.clientY));
      return;
    }
    state.panX -= e.deltaX * unit;
    state.panY -= e.deltaY * unit;
    layoutLive();
  }, { passive: false });



  // 画布获得焦点时按键发给模拟器; ⌘ 组合键保留给页面, Esc 退出
  canvas.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      canvas.blur();
      return;
    }
    if (e.metaKey || e.isComposing || !LIVE_KEY_CODE.test(e.code)) return;
    e.preventDefault();
    e.stopPropagation();
    const modifiers = [e.shiftKey && 'shift', e.ctrlKey && 'control', e.altKey && 'option'].filter(Boolean);
    liveSend({ type: 'key', code: e.code, modifiers });
  });
  document.addEventListener('paste', (e) => {
    if (document.activeElement !== canvas) return;
    const text = e.clipboardData && e.clipboardData.getData('text/plain');
    if (!text) return;
    e.preventDefault();
    liveSend({ type: 'paste', text });
  });
  const trackAlt = (e) => {
    if (live.altHeld === e.altKey) return;
    live.altHeld = e.altKey;
    syncLiveCursor();
  };
  window.addEventListener('keydown', trackAlt);
  window.addEventListener('keyup', trackAlt);
  window.addEventListener('blur', () => trackAlt({ altKey: false }));

  $('liveInspect').addEventListener('click', () => setLiveInspect(!live.inspect));
  $('liveHome').addEventListener('click', liveHome);
  // 多任务: 从底部上滑并停顿, 与真机手势一致
  $('liveSwitcher').addEventListener('click', () => liveSend({ type: 'button', button: 'app-switcher' }));
  $('liveRotate').addEventListener('click', liveRotate);
  $('menuLiveRestart').addEventListener('click', liveRestart);
  $('menuLogs').addEventListener('click', revealLogs);
  $('liveHealBtn').addEventListener('click', healLiveTouch);
  $('liveHealClose').addEventListener('click', hideLiveHeal);
  $('menuHeal').addEventListener('click', () => openPanel('heal'));
  $('xcodeRun').addEventListener('click', xcodeRun);
  $('appBannerRun').addEventListener('click', xcodeRun);
  $('emptyGuide').addEventListener('click', (e) => {
    const value = e.target.closest('.live-copy')?.dataset.copy;
    if (value) copyText(value, '复制');
  });
  new ResizeObserver(layoutLive).observe(wrap);
}

// MARK: - Color picker

// 取色: 2D 取窗口截图的像素, 与 App 渲染一致; 实时取画面像素, 视频编码可能有轻微色差. 3D 有透视和叠层, 不提供
const LOUPE_CELLS = 11;
// 放大镜尺寸固定, 与样式中的宽高一致, 每格 15px
const LOUPE_SIZE = 165;
const picker = { on: false, source: null, sourceURL: '', color: null, swallow: false };

function pickerAvailable() {
  return state.mode === '2d' || state.mode === 'live';
}

function setColorPicker(on) {
  picker.on = on && pickerAvailable();
  $('colorPick').classList.toggle('on', picker.on);
  $('colorPick').setAttribute('aria-pressed', String(picker.on));
  document.body.classList.toggle('picking', picker.on);
  if (!picker.on) {
    hideLoupe();
    return;
  }
  if (live.inspect) setLiveInspect(false);
  hideHoverTip();
  if (state.hover) {
    state.hover = null;
    updateHighlights();
  }
}

// 指针处的像素位置(设备像素)和可读取的画面, 不在画面内时为 null
function pickerPixel(e) {
  if (state.mode === 'live') {
    const canvas = $('liveCanvas');
    const [sw] = live.screen;
    if (!canvas.width || !sw) return null;
    const point = livePoint(e);
    if (!point.inside) return null;
    const scale = canvas.width / sw;
    return { ctx: canvas.getContext('2d'), x: Math.floor(point.x * scale), y: Math.floor(point.y * scale) };
  }
  const win = currentWindow();
  const img = $('stage').querySelector('img.shot');
  if (!win || !img || !img.complete || !img.naturalWidth) return null;
  const [x, y] = stagePoint(e);
  if (x < 0 || y < 0 || x >= win.rect[2] || y >= win.rect[3]) return null;
  // 截图变化(刷新层级)时才重新绘制到离屏画布
  if (picker.sourceURL !== img.src) {
    const canvas = document.createElement('canvas');
    canvas.width = img.naturalWidth;
    canvas.height = img.naturalHeight;
    picker.source = canvas.getContext('2d', { willReadFrequently: true });
    picker.source.drawImage(img, 0, 0);
    picker.sourceURL = img.src;
  }
  const scale = img.naturalWidth / win.rect[2];
  return { ctx: picker.source, x: Math.floor(x * scale), y: Math.floor(y * scale) };
}

function colorHex(color) {
  return toHex([color.r / 255, color.g / 255, color.b / 255]).toUpperCase();
}

function updateLoupe(e) {
  const pixel = pickerPixel(e);
  if (!pixel) {
    hideLoupe();
    return;
  }
  const half = LOUPE_CELLS >> 1;
  let data;
  try {
    data = pixel.ctx.getImageData(pixel.x - half, pixel.y - half, LOUPE_CELLS, LOUPE_CELLS);
  } catch (err) {
    hideLoupe();
    return;
  }
  const cells = picker.cells || (picker.cells = document.createElement('canvas'));
  cells.width = LOUPE_CELLS;
  cells.height = LOUPE_CELLS;
  cells.getContext('2d').putImageData(data, 0, 0);
  const canvas = $('loupeCanvas');
  const dpr = window.devicePixelRatio || 1;
  const size = Math.round(LOUPE_SIZE * dpr);
  if (canvas.width !== size) {
    canvas.width = size;
    canvas.height = size;
  }
  const ctx = canvas.getContext('2d');
  ctx.imageSmoothingEnabled = false;
  ctx.clearRect(0, 0, size, size);
  ctx.drawImage(cells, 0, 0, size, size);
  // 中心格黑白双线框, 在任何底色上都可见
  const cell = size / LOUPE_CELLS;
  ctx.lineWidth = Math.max(1, dpr);
  ctx.strokeStyle = '#000';
  ctx.strokeRect(half * cell, half * cell, cell, cell);
  ctx.strokeStyle = '#fff';
  ctx.strokeRect(half * cell + ctx.lineWidth, half * cell + ctx.lineWidth, cell - 2 * ctx.lineWidth, cell - 2 * ctx.lineWidth);

  const i = (half * LOUPE_CELLS + half) * 4;
  const [r, g, b, a] = data.data.slice(i, i + 4);
  picker.color = { r, g, b, a };
  const hex = colorHex(picker.color);
  $('loupeSwatch').style.background = `rgba(${r}, ${g}, ${b}, ${a / 255})`;
  $('loupeHex').textContent = hex;
  // 补齐 3 位, 数值变化时文字宽度不变
  const rgb = [r, g, b].map((v) => String(v).padStart(3)).join(' ');
  $('loupeRgb').textContent = a < 255 ? `${rgb} α${round(a / 255)}` : rgb;

  // 放在指针右下方, 超出画布时翻到另一侧
  const loupe = $('loupe');
  loupe.hidden = false;
  const pane = $('canvasPane').getBoundingClientRect();
  const gap = 18;
  let left = e.clientX - pane.left + gap;
  let top = e.clientY - pane.top + gap;
  if (left + loupe.offsetWidth > pane.width) left = e.clientX - pane.left - gap - loupe.offsetWidth;
  if (top + loupe.offsetHeight > pane.height) top = e.clientY - pane.top - gap - loupe.offsetHeight;
  loupe.style.transform = `translate(${Math.max(0, left)}px, ${Math.max(0, top)}px)`;
}

function hideLoupe() {
  $('loupe').hidden = true;
  picker.color = null;
}

// 在捕获阶段拦截画布上的指针事件, 取色期间不触发选中、悬停和模拟器触摸; 平移(中键 / 空格拖动)和缩放照常
function setupColorPicker() {
  const pane = $('canvasPane');
  const onCanvas = (e) => e.target instanceof Element && !!e.target.closest('#stageWrap, #liveCanvas');
  pane.addEventListener('pointermove', (e) => {
    if (!picker.on || e.buttons) return;
    if (!onCanvas(e)) {
      hideLoupe();
      return;
    }
    e.stopPropagation();
    updateLoupe(e);
  }, true);
  pane.addEventListener('pointerdown', (e) => {
    if (!picker.on || e.button !== 0 || panKey.held || !onCanvas(e)) return;
    e.preventDefault();
    e.stopPropagation();
    picker.swallow = true;
    updateLoupe(e);
    if (!picker.color) return;
    copyText(colorHex(picker.color), '复制颜色');
    setColorPicker(false);
  }, true);
  // 吞掉取色点击后续的抬起和 click, click 与 pointerup 在同一轮事件中派发
  pane.addEventListener('pointerup', (e) => {
    if (!picker.swallow) return;
    e.stopPropagation();
    setTimeout(() => (picker.swallow = false));
  }, true);
  pane.addEventListener('click', (e) => {
    if (picker.swallow) e.stopPropagation();
  }, true);
  pane.addEventListener('pointerleave', hideLoupe);
  $('colorPick').addEventListener('click', () => setColorPicker(!picker.on));
}

// MARK: - Layout

const PANEL_HIDDEN_KEYS = { tree: 'layerlens_tree_hidden', detail: 'layerlens_detail_hidden' };
// 画布至少保留的宽度; 窗口变窄时先收起详情, 再收起层级树, 最后才压缩画布
const CANVAS_MIN_W = 360;
// hidden: 用户手动收起(持久化); auto: 宽度不足自动收起; forced: 自动收起状态下用户手动展开
const panels = {
  tree: { hidden: false, auto: false, forced: false },
  detail: { hidden: false, auto: false, forced: false },
};

function panelHidden(name) {
  const panel = panels[name];
  return panel.hidden || (panel.auto && !panel.forced);
}

function syncPanels() {
  ['tree', 'detail'].forEach((name) => {
    const hidden = panelHidden(name);
    document.body.classList.toggle(name + '-hidden', hidden);
    $(name + 'Toggle').classList.toggle('on', !hidden);
    $(name + 'Toggle').setAttribute('aria-pressed', String(!hidden));
  });
}

function togglePanel(name) {
  const panel = panels[name];
  if (panelHidden(name)) {
    panel.hidden = false;
    panel.forced = panel.auto;
  } else {
    panel.hidden = true;
    panel.forced = false;
  }
  try {
    localStorage.setItem(PANEL_HIDDEN_KEYS[name], panel.hidden ? '1' : '0');
  } catch (e) {
    // 无痕模式等场景下不可用, 忽略
  }
  syncPanels();
}

// 按布局宽度计算自动收起: 三栏放不下先收详情, 两栏放不下再收层级树
function updateAutoPanels() {
  const layout = $('layout');
  const width = layout.clientWidth;
  if (!width) return;
  const style = getComputedStyle(layout);
  const size = (prop, fallback) => parseFloat(style.getPropertyValue(prop)) || fallback;
  const treeW = size('--tree-w', size('--tree-d', 300)) + 1;
  const detailW = size('--detail-w', size('--detail-d', 340)) + 1;
  const autoDetail = width < treeW + detailW + CANVAS_MIN_W;
  const autoTree = width < treeW + CANVAS_MIN_W;
  [['tree', autoTree], ['detail', autoDetail]].forEach(([name, auto]) => {
    const panel = panels[name];
    // 宽度恢复后清掉手动展开标记, 下次变窄仍自动收起
    if (!auto) panel.forced = false;
    panel.auto = auto;
  });
  syncPanels();
}

const LAYOUT_KEY = 'layerlens_layout';

function setupLayout() {
  const layout = $('layout');
  let saved = {};
  try {
    saved = JSON.parse(localStorage.getItem(LAYOUT_KEY)) || {};
  } catch (e) {
    saved = {};
  }
  Object.entries(saved).forEach(([prop, value]) => layout.style.setProperty(prop, value));
  const clamp = (v, min, max) => Math.max(min, Math.min(Math.max(min, max), v));

  layout.querySelectorAll('.splitter').forEach((splitter) => {
    splitter.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      try {
        splitter.setPointerCapture(e.pointerId);
      } catch (err) {
        // pointerId 无效时忽略
      }
      splitter.classList.add('dragging');
      const name = splitter.dataset.split;
      let prop = null;
      let value = null;
      const move = (ev) => {
        const box = layout.getBoundingClientRect();
        if (name === 's1') {
          prop = '--tree-w';
          value = clamp(ev.clientX - box.left, 180, box.width * 0.6) + 'px';
        } else {
          prop = '--detail-w';
          value = clamp(box.right - ev.clientX, 260, box.width * 0.6) + 'px';
        }
        layout.style.setProperty(prop, value);
      };
      const up = () => {
        splitter.classList.remove('dragging');
        splitter.removeEventListener('pointermove', move);
        splitter.removeEventListener('pointerup', up);
        splitter.removeEventListener('pointercancel', up);
        if (!prop) return;
        saved[prop] = value;
        try {
          localStorage.setItem(LAYOUT_KEY, JSON.stringify(saved));
        } catch (err) {
          // 无痕模式等场景下不可用, 忽略
        }
      };
      splitter.addEventListener('pointermove', move);
      splitter.addEventListener('pointerup', up);
      splitter.addEventListener('pointercancel', up);
    });
    // 双击恢复默认尺寸
    splitter.addEventListener('dblclick', () => {
      ['--tree-w', '--detail-w', '--side-w', '--tree-h'].forEach((p) => layout.style.removeProperty(p));
      saved = {};
      try {
        localStorage.removeItem(LAYOUT_KEY);
      } catch (err) {
        // ignore
      }
    });
  });

  Object.keys(panels).forEach((name) => {
    try {
      panels[name].hidden = localStorage.getItem(PANEL_HIDDEN_KEYS[name]) === '1';
    } catch (e) {
      // ignore
    }
    $(name + 'Toggle').addEventListener('click', () => togglePanel(name));
  });
  updateAutoPanels();
  new ResizeObserver(updateAutoPanels).observe(layout);

  setView('canvas');
  $('mobileNav').addEventListener('click', (e) => {
    const button = e.target.closest('button');
    if (button) setView(button.dataset.view);
  });
}

// MARK: - Detail

async function loadDetail() {
  const node = state.nodes.get(state.selected);
  if (!node) {
    $('detail').replaceChildren(el('div', 'empty', t('选择一个视图')));
    return;
  }
  if (state.tab === 'class') {
    loadClassInfo(node);
    return;
  }
  state.detail = null;
  renderDetail(node);
  if (!node.oid) return;
  try {
    const detail = await api(`/api/detail?oid=${node.oid}`);
    if (state.selected !== node.key) return;
    state.detail = detail;
    renderDetail(node);
  } catch (e) {
    toast(e.message, true);
  }
}

function renderDetail(node) {
  const container = $('detail');
  const frag = document.createDocumentFragment();
  frag.appendChild(objectCard(node));
  const detail = state.detail;
  if (detail) {
    detail.groups.filter((g) => !SKIP_GROUPS.has(g.title)).forEach((g) => frag.appendChild(groupCard(node, g)));
    detail.customGroups.forEach((g) => frag.appendChild(groupCard(node, g)));
    if (detail.events.length) frag.appendChild(eventsCard(detail.events));
  } else if (node.oid) {
    frag.appendChild(el('div', 'empty', t('加载中...')));
  }
  const scrollTop = container.scrollTop;
  container.replaceChildren(frag);
  container.scrollTop = scrollTop;
}

// 默认展开的属性分组, 其余收起; 用户的展开/收起选择会记住
const DEFAULT_OPEN_GROUPS = new Set(['Layout', 'CALayer / UIView']);

function card(title, count, body, collapsed, persistKey) {
  if (persistKey && state.groupOpen[persistKey] !== undefined) collapsed = !state.groupOpen[persistKey];
  const wrap = el('div', 'card' + (collapsed ? ' collapsed' : ''));
  const h = el('h4');
  h.append(icon('chevron'), el('span', null, title));
  if (count !== undefined) h.appendChild(el('span', 'count', String(count)));
  h.addEventListener('click', () => {
    const nowCollapsed = wrap.classList.toggle('collapsed');
    if (persistKey) state.groupOpen[persistKey] = !nowCollapsed;
  });
  const content = el('div', 'card-body');
  content.appendChild(body);
  wrap.append(h, content);
  return wrap;
}

// 选中对象的标题区: 类名 + 父类链 + 关键信息 + 复制
function objectCard(node) {
  const hero = el('div', 'hero');
  hero.appendChild(el('div', 'hero-title', node.cls));
  if (node.classChain.length > 1) hero.appendChild(el('div', 'hero-chain', node.classChain.slice(1).join(' › ')));
  const kv = el('div', 'kv hero-kv');
  const add = (k, v) => {
    if (v === null || v === undefined || v === '') return;
    kv.appendChild(el('div', null, k));
    const cell = el('div');
    if (v instanceof Node) cell.appendChild(v);
    else cell.textContent = v;
    kv.appendChild(cell);
  };
  add('ivar', codeIvars(node).map((r) => r.text).join('\n'));
  if (node.vcClass) {
    const vc = el('span', 'link', node.vcClass);
    vc.title = t('查看 VC 类信息');
    vc.addEventListener('click', () => {
      state.classTarget = { oid: node.vcOid, name: node.vcClass };
      switchTab('class');
    });
    add('VC', vc);
  }
  add(t('文字'), node.text);
  add(t('标题'), node.title);
  add(t('特殊'), node.specialTrace);
  add(t('地址'), node.address);
  add(t('屏幕坐标'), node.rect.map(round).join(', '));
  if (node.hidden || node.alpha < 1) add(t('可见性'), `hidden ${node.hidden} · alpha ${round(node.alpha)}`);
  hero.appendChild(kv);
  // 复制项与右键菜单一致, 收进一个按钮, 避免抢占属性内容的视线
  const actions = el('div', 'copy-actions');
  const button = el('button', 'copy-menu-btn');
  const chevron = icon('chevron');
  chevron.classList.add('copy-menu-chevron');
  button.append(icon('copy'), document.createTextNode(t('复制')), chevron);
  button.addEventListener('click', (e) => {
    e.stopPropagation();
    const rect = button.getBoundingClientRect();
    showMenu(rect.left, rect.bottom + 4, node);
  });
  actions.appendChild(button);
  hero.appendChild(actions);
  return hero;
}

function groupCard(node, group) {
  const body = el('div');
  let count = 0;
  group.sections.forEach((section) => {
    if (section.title && (section.attrs.length > 1 || section.title !== section.attrs[0]?.title)) {
      body.appendChild(el('div', 'sec-title', section.title));
    }
    section.attrs.forEach((attr) => {
      count++;
      const row = el('div', 'attr');
      row.appendChild(el('div', 'name', attr.title)).title = attr.id;
      const value = el('div', 'value');
      value.appendChild(attr.editable && node.oid ? editor(node, attr) : display(attr));
      row.appendChild(value);
      body.appendChild(row);
    });
  });
  return card(group.title, count, body, !DEFAULT_OPEN_GROUPS.has(group.title), 'g:' + group.title);
}

function display(attr) {
  const v = attr.value;
  if (v === null) return el('span', null, 'nil');
  if (attr.type === T.UIColor && Array.isArray(v)) return colorSwatch(v);
  if (attr.enumList && ENUMS[attr.enumList]) return el('span', null, ENUMS[attr.enumList][v] || String(v));
  if (VECTOR_LABELS[attr.type] && Array.isArray(v)) {
    const wrap = numsGrid(VECTOR_LABELS[attr.type]);
    VECTOR_LABELS[attr.type].forEach((label, i) => {
      const box = el('label', null, label);
      box.appendChild(el('span', 'num-readonly', String(round(v[i]))));
      wrap.appendChild(box);
    });
    return wrap;
  }
  if (Array.isArray(v)) {
    const span = el('span', null, v.map((item) => (Array.isArray(item) ? item.join(' → ') : typeof item === 'object' ? JSON.stringify(item) : round(item))).join('\n'));
    span.style.whiteSpace = 'pre-wrap';
    return span;
  }
  if (typeof v === 'object') return el('span', null, JSON.stringify(v));
  return el('span', null, typeof v === 'number' ? String(round(v)) : String(v));
}

function colorSwatch(rgba) {
  const wrap = el('div', 'color-edit');
  const sw = el('span');
  sw.style.cssText = `display:inline-block;width:18px;height:14px;border-radius:3px;border:1px solid var(--border);background:rgba(${rgba.slice(0, 3).map((c) => Math.round(c * 255)).join(',')},${rgba[3]})`;
  wrap.append(sw, el('span', null, rgbaText(rgba)));
  return wrap;
}

function rgbaText(rgba) {
  return toHex(rgba) + ' α' + round(rgba[3]);
}

function editor(node, attr) {
  const commit = (value) => modify(node, attr, value);
  const v = attr.value;
  const type = attr.type;
  if (type === T.BOOL) {
    const input = el('input');
    input.type = 'checkbox';
    input.checked = !!v;
    input.addEventListener('change', () => commit(input.checked));
    return input;
  }
  if (attr.enumList && ENUMS[attr.enumList] && ENUMS[attr.enumList][v] !== undefined) {
    const select = el('select');
    ENUMS[attr.enumList].forEach((name, i) => {
      const option = el('option', null, `${name} (${i})`);
      option.value = i;
      select.appendChild(option);
    });
    select.value = v;
    select.addEventListener('change', () => commit(Number(select.value)));
    return select;
  }
  if (INT_TYPES.has(type) || FLOAT_TYPES.has(type)) {
    const input = numberInput(v);
    input.addEventListener('change', () => {
      const n = INT_TYPES.has(type) ? parseInt(input.value, 10) : parseFloat(input.value);
      if (!isNaN(n)) commit(n);
    });
    return input;
  }
  if (type === T.NSString) {
    const input = el('input');
    input.type = 'text';
    input.value = v === null ? '' : v;
    input.placeholder = 'nil';
    input.addEventListener('change', () => commit(input.value));
    return input;
  }
  if (type === T.UIColor) return colorEditor(v, commit);
  if (VECTOR_LABELS[type]) {
    const labels = VECTOR_LABELS[type];
    const wrap = numsGrid(labels);
    const inputs = labels.map((label, i) => {
      const box = el('label', null, label);
      const input = numberInput(Array.isArray(v) ? v[i] : 0);
      box.appendChild(input);
      wrap.appendChild(box);
      return input;
    });
    inputs.forEach((input) => input.addEventListener('change', () => {
      const values = inputs.map((x) => parseFloat(x.value));
      if (values.every((n) => !isNaN(n))) commit(values);
    }));
    return wrap;
  }
  return display(attr);
}

// 4 个值(rect/insets)分两行, 6 个值(transform)分三列, 避免窄面板中数字被截断
function numsGrid(labels) {
  const wrap = el('div', 'nums');
  wrap.style.setProperty('--n', labels.length === 4 ? 2 : Math.min(labels.length, 3));
  return wrap;
}

function numberInput(v) {
  const input = el('input');
  input.type = 'number';
  input.step = 'any';
  input.value = typeof v === 'number' ? round(v) : v;
  return input;
}

function colorEditor(v, commit) {
  const wrap = el('div', 'color-edit');
  const picker = el('input');
  picker.type = 'color';
  picker.value = v ? toHex(v) : '#000000';
  const alpha = numberInput(v ? v[3] : 1);
  alpha.min = 0;
  alpha.max = 1;
  alpha.step = 0.05;
  const text = el('span', null, v ? rgbaText(v) : 'nil');
  const clear = el('button', 'clear', t('清除'));
  const send = () => {
    const hex = picker.value;
    const rgb = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
    commit([...rgb, Math.max(0, Math.min(1, parseFloat(alpha.value) || 0))]);
  };
  picker.addEventListener('change', send);
  alpha.addEventListener('change', send);
  clear.addEventListener('click', () => commit(null));
  wrap.append(picker, alpha, text, clear);
  return wrap;
}

// 事件浮窗: 每个手势 / 控件事件一组, 显示类名、来源、开关、代理与 target-action
function showEventPop(node, anchor) {
  const pop = $('eventPop');
  if (!node || !node.events?.length) return;
  if (!pop.hidden && pop.dataset.key === node.key && !pop.classList.contains('closing')) {
    hideLayer(pop, 120);
    return;
  }
  hidePopovers();
  pop.dataset.key = node.key;
  pop.replaceChildren(...node.events.map((event) => {
    const item = el('div', 'ev-item');
    item.appendChild(el('div', 'ev-name', event.name));
    if (event.inherited) item.appendChild(el('div', 'ev-sub', t('继承自') + ' ' + event.inherited));
    event.ivarTraces.forEach((trace) => item.appendChild(el('div', 'ev-sub', trace)));
    const kv = el('div', 'ev-kv');
    const add = (name, value) => kv.append(el('span', null, name), value instanceof Node ? value : el('span', 'ev-value', value));
    if (event.type === 'gesture') {
      const box = el('input');
      box.type = 'checkbox';
      box.checked = !!event.enabled;
      // 只读展示, 不用 disabled 以免变灰看不清
      box.tabIndex = -1;
      add('Enabled', box);
      if (event.delegate) add('Delegate', event.delegate);
    }
    event.targetActions.forEach(([target, action]) => {
      add('Target', target);
      add('Action', action);
    });
    item.appendChild(kv);
    return item;
  }));
  showLayer(pop);
  // 贴在蓝条右侧, 放不下时向上 / 向左收
  const rect = anchor.getBoundingClientRect();
  const w = pop.offsetWidth;
  const h = pop.offsetHeight;
  const x = Math.max(4, Math.min(rect.right + 6, window.innerWidth - w - 4));
  const y = Math.max(4, Math.min(rect.top - 6, window.innerHeight - h - 4));
  pop.style.left = x + 'px';
  pop.style.top = y + 'px';
}

function eventsCard(events) {
  const body = el('div');
  events.forEach((event) => {
    const row = el('div', 'attr');
    row.appendChild(el('div', 'name', event.type === 'gesture' ? (event.inherited || 'Gesture') : 'Control'));
    const lines = [event.name + (event.type === 'gesture' && !event.enabled ? ' (disabled)' : '')];
    event.targetActions.forEach(([target, action]) => lines.push(`${target} → ${action}`));
    if (event.delegate) lines.push('delegate: ' + event.delegate);
    event.ivarTraces.forEach((t) => lines.push('ivar: ' + t));
    const value = el('div', 'value multi', lines.join('\n'));
    row.appendChild(value);
    body.appendChild(row);
  });
  return card('Events', events.length, body, true, 'g:Events');
}

async function modify(node, attr, value) {
  try {
    const result = await api('/api/modify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ oid: node.oid, attrId: attr.id, attrType: attr.type, value }),
    });
    if (result.error) toast(result.error, true);
    else toast(t('已修改 {0}', attr.title));
    // 修改可能触发重新布局, 重新抓取层级与截图
    await refresh();
  } catch (e) {
    toast(e.message, true);
    loadDetail();
  }
}

// MARK: - Class info

async function loadClassInfo(node) {
  const target = state.classTarget || { oid: node.viewOid || node.oid, name: node.cls };
  const container = $('detail');
  if (!target.oid) {
    container.replaceChildren(el('div', 'empty', t('该节点没有对应的 OC 对象')));
    return;
  }
  container.replaceChildren(el('div', 'empty', t('加载中...')));
  try {
    const info = await api(`/api/class?oid=${target.oid}`);
    if (state.selected !== node.key || state.tab !== 'class') return;
    renderClassInfo(info, node);
  } catch (e) {
    container.replaceChildren(el('div', 'empty', e.message));
  }
}

function renderClassInfo(info, node) {
  const container = $('detail');
  const filter = el('input', 'filter');
  filter.type = 'search';
  filter.placeholder = t('过滤 ivar / property / method');
  const list = el('div');
  const header = el('div', 'kv');
  header.append(el('div', null, t('类')), el('div', null, info.className), el('div', null, t('地址')), el('div', null, info.address), el('div', null, t('描述')), el('div', null, info.description));
  if (state.classTarget) {
    const back = el('span', 'link', t('返回视图'));
    back.addEventListener('click', () => {
      state.classTarget = null;
      loadClassInfo(node);
    });
    header.append(el('div'), back);
  }
  const draw = () => {
    const q = filter.value.trim().toLowerCase();
    const frag = document.createDocumentFragment();
    info.classes.forEach((cls, index) => {
      const ivars = cls.ivars.filter((i) => !q || i.name.toLowerCase().includes(q) || i.type.toLowerCase().includes(q));
      const props = cls.properties.filter((p) => !q || p.name.toLowerCase().includes(q));
      const methods = cls.methods.filter((m) => !q || m.toLowerCase().includes(q));
      if (q && !ivars.length && !props.length && !methods.length) return;
      const body = el('div');
      if (ivars.length) {
        body.appendChild(el('div', 'sec-title', `Ivars (${ivars.length})`));
        const table = el('table', 'ivars');
        ivars.forEach((ivar) => {
          const tr = el('tr');
          tr.append(el('td', null, ivar.name), el('td', null, ivar.type));
          const td = el('td');
          const key = ivar.nodeOid ? String(ivar.nodeOid) : null;
          if (key && state.nodes.has(key)) {
            const link = el('span', 'link', ivar.value);
            link.title = t('在层级中选中');
            link.addEventListener('click', () => select(key));
            td.appendChild(link);
          } else {
            td.textContent = ivar.value;
          }
          tr.appendChild(td);
          table.appendChild(tr);
        });
        body.appendChild(table);
      }
      if (props.length) {
        body.appendChild(el('div', 'sec-title', `Properties (${props.length})`));
        const box = el('div', 'list-mono');
        props.forEach((p) => {
          const row = el('div', null, p.name);
          row.title = p.attributes;
          box.appendChild(row);
        });
        body.appendChild(box);
      }
      if (methods.length) {
        body.appendChild(el('div', 'sec-title', `Methods (${methods.length})`));
        const box = el('div', 'list-mono');
        methods.forEach((m) => box.appendChild(el('div', null, m)));
        body.appendChild(box);
      }
      frag.appendChild(card(cls.name, ivars.length + props.length + methods.length, body, !q && index > 0));
    });
    list.replaceChildren(frag);
  };
  filter.addEventListener('input', draw);
  draw();
  const head = el('div', 'class-head');
  head.append(filter, header);
  container.replaceChildren(head, list);
}

function switchTab(tab) {
  state.tab = tab;
  $('detailTabs').querySelectorAll('button').forEach((b) => b.classList.toggle('active', b.dataset.tab === tab));
  loadDetail();
}

// MARK: - Utils

function round(v) {
  return typeof v === 'number' ? Math.round(v * 100) / 100 : v;
}

function toHex(rgba) {
  return '#' + rgba.slice(0, 3).map((c) => Math.round(Math.max(0, Math.min(1, c)) * 255).toString(16).padStart(2, '0')).join('');
}

// MARK: - Controls

function syncToggles() {
  ['showImages', 'subtreeOnly'].forEach((field) => {
    $(field).classList.toggle('on', !!state[field]);
    $(field).setAttribute('aria-pressed', String(!!state[field]));
  });
}

// 筛选不是默认值时按钮高亮, 提示层级树有筛选生效
function syncTreeFilter() {
  $('treeFilterBtn').classList.toggle('active', state.showLayers || !state.showHidden);
}

function requestMode(mode) {
  if (mode === 'live' && !liveAvailable()) {
    toast(t('真机不支持实时画面'));
    return;
  }
  if (mode) setMode(mode);
}

// 画布视图快捷键, 返回是否已处理
function handleViewKey(key) {
  const three = state.mode === '3d';
  switch (key.toLowerCase()) {
    case 'f':
      focusSelected();
      return true;
    case '0':
      fitView();
      return true;
    case '1':
      requestMode('live');
      return true;
    case '2':
      requestMode('2d');
      return true;
    case '3':
      requestMode('3d');
      return true;
    case 'c':
      if (!pickerAvailable()) return false;
      setColorPicker(!picker.on);
      return true;
    case 't':
      togglePanel('tree');
      return true;
    case 'd':
      togglePanel('detail');
      return true;
    case '[':
    case ']':
      if (!three) return false;
      setSpacing(Math.max(SPACING_MIN, Math.min(SPACING_MAX, state.spacing + (key === ']' ? SPACING_STEP : -SPACING_STEP))));
      return true;
    case 'i':
      if (!three) return false;
      $('showImages').click();
      return true;
    case 's':
      if (!three) return false;
      $('subtreeOnly').click();
      return true;
    default:
      return false;
  }
}

function setSpacing(value) {
  state.spacing = value;
  $('spacing').value = value;
  $('spacingLabel').textContent = value;
  $('stage').querySelectorAll('.slab').forEach((slab) => {
    const node = state.nodes.get(slab.dataset.key);
    if (node) slab.style.transform = `translateZ(${node.level * state.spacing}px)`;
  });
  updatePivot();
}

function togglePopover(id) {
  const target = $(id);
  const willShow = target.hidden || target.classList.contains('closing');
  hidePopovers();
  if (willShow) showLayer(target);
}

function hidePopovers() {
  document.querySelectorAll('.popover').forEach((p) => hideLayer(p, 120));
}

// 浮层显示时由 CSS 播放进入动画; 隐藏时先加 closing 播放退出动画, 结束后再设置 hidden(或执行 done)
function showLayer(node) {
  clearTimeout(node.exitTimer);
  node.classList.remove('closing');
  node.hidden = false;
}

function hideLayer(node, duration, done) {
  if (node.hidden || node.classList.contains('closing')) return;
  const finish = () => {
    node.classList.remove('closing');
    done ? done() : (node.hidden = true);
  };
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
    finish();
    return;
  }
  node.classList.add('closing');
  node.exitTimer = setTimeout(finish, duration);
}

// 主题偏好跨会话保留, 存 localStorage
const THEME_KEY = 'layerlens_theme';

function loadTheme() {
  try {
    return localStorage.getItem(THEME_KEY) || 'auto';
  } catch (e) {
    return 'auto';
  }
}

function applyTheme(theme, save) {
  if (theme === 'auto') document.documentElement.removeAttribute('data-theme');
  else document.documentElement.dataset.theme = theme;
  $('themeSeg').querySelectorAll('button').forEach((b) => b.classList.toggle('active', b.dataset.theme === theme));
  // App 窗口的标题栏和底色跟随页面主题
  window.webkit?.messageHandlers?.layerlens?.postMessage({ action: 'theme', theme });
  if (!save) return;
  try {
    localStorage.setItem(THEME_KEY, theme);
  } catch (e) {
    // 无痕模式等场景下不可用, 忽略
  }
}

// MARK: - Panels
// 关于和 App 集成面板; Mac App 的菜单通过 window.layerlensOpenPanel 打开

const REPO_URL = 'https://github.com/amjunliang/LayerLens';
const POD_LINE = `pod 'LayerLens', :git => '${REPO_URL}.git', :configurations => ['Debug']`;
const POST_INSTALL = `post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      if config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'].to_f < 12.0
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      end
    end
  end
end`;

// 常显滚动条会占用底部高度, 在顶部补同样的高度, 让单行代码和复制按钮对齐
function balanceScrollbar(node) {
  new ResizeObserver(() => {
    node.style.paddingTop = '';
    const bar = node.offsetHeight - node.clientHeight;
    if (bar > 0) node.style.paddingTop = `${parseFloat(getComputedStyle(node).paddingTop) + bar}px`;
  }).observe(node);
  return node;
}

function codeBlock(text) {
  // 单行时复制按钮竖向居中, 多行时贴顶
  const box = el('div', text.includes('\n') ? 'code-block multiline' : 'code-block');
  const button = el('button', null, t('复制'));
  button.dataset.copy = text;
  box.append(balanceScrollbar(el('pre', null, text)), button);
  return box;
}

function linkTo(text, url) {
  const a = el('a', null, text);
  a.href = url;
  a.target = '_blank';
  a.rel = 'noopener';
  return a;
}

function paragraph(...parts) {
  const p = el('p');
  p.append(...parts);
  return p;
}

function integrationPanel() {
  return [
    el('h5', null, t('1. 在 Podfile 中添加, 只在 Debug 集成')),
    codeBlock(POD_LINE),
    el('h5', null, t('2. 设置最低系统版本')),
    paragraph(t('依赖的 LookinServer 声明了 iOS 9, 新版 Xcode 已不支持, 在 Podfile 末尾添加:')),
    codeBlock(POST_INSTALL),
    el('h5', null, t('3. 安装并运行')),
    codeBlock('pod install'),
    paragraph(t('以 Debug 配置运行 App 即可, 无需编写代码; Release 包不包含 LayerLens.')),
    el('h5', null, t('4. 确认连接')),
    paragraph(t('Xcode 控制台输出 [LayerLens] Running on port …, 左上角的设备列表中出现该 App.')),
    el('h5', null, t('真机调试')),
    paragraph(t('通过 USB 连接即可使用, 无需额外配置; 暂不支持 Wi-Fi 连接.')),
  ];
}

function aboutPanel() {
  const hub = targets.hub || {};
  const app = currentApp();
  const liveStatus = hub.live === undefined ? '-' : hub.live ? t('可用') : t('不可用');
  const rows = [
    [t('版本'), hub.version || '-'],
    [t('接口版本'), String(API_VERSION)],
    [t('当前 App'), app ? `${app.appName || app.bundleId} · Pod ${app.podVersion || t('旧版本')}` : '-'],
    [t('模拟器实时画面'), liveStatus],
  ];
  const head = el('div', 'about-head');
  head.append(el('div', 'about-name', 'LayerLens'), el('div', 'about-desc', t('iOS 视图调试工具, 浏览器和 Mac App 使用同一界面')));
  const kv = el('div', 'about-kv');
  rows.forEach(([name, value]) => kv.append(el('span', null, name), el('span', null, value)));
  return [
    head,
    kv,
    paragraph(linkTo('GitHub', REPO_URL), document.createTextNode(' · ' + t('以 MIT 许可证开源'))),
    el('h5', null, t('致谢')),
    paragraph(linkTo('LookinServer', 'https://github.com/QMUI/LookinServer'), document.createTextNode(' by QMUI · ' + t('视图层级数据'))),
    paragraph(linkTo('baguette', 'https://tddworks.github.io/baguette/'), document.createTextNode(' by tddworks · ' + t('模拟器画面采集与输入注入的实现参考'))),
  ];
}

// Mac App 的 WebView 不支持 confirm(), 用面板确认
function healPanel() {
  const actions = el('div', 'modal-actions');
  const cancel = el('button', null, t('取消'));
  const ok = el('button', 'primary', t('修复'));
  cancel.addEventListener('click', closePanel);
  ok.addEventListener('click', () => {
    closePanel();
    healLiveTouch();
  });
  actions.append(cancel, ok);
  return [
    paragraph(document.createTextNode(t('模拟器重启后偶尔不再响应注入的触摸, 重启模拟器的 backboardd 即可恢复.'))),
    paragraph(document.createTextNode(t('会连带重启 SpringBoard, 前台 App 会被结束, 约 10 秒后回到桌面.'))),
    actions,
  ];
}

// 快捷键: [分组标题, 只在有实时画面时显示, [[按键...], 说明]...]
const SHORTCUT_GROUPS = [
  ['通用', false, [
    [['R'], '刷新'],
    [['⌘', 'C'], '复制选中节点路径'],
    [['右键'], '复制菜单'],
    [['T'], '显示 / 隐藏层级面板'],
    [['D'], '显示 / 隐藏详情面板'],
    [['?'], '显示此面板'],
  ]],
  ['层级树', false, [
    [['↑', '↓'], '上一个 / 下一个节点'],
    [['←'], '选中父节点'],
    [['⌥', '←'], '收起'],
    [['→'], '展开, 再按进入子节点'],
  ]],
  ['画布', false, [
    [['双指滑动'], '平移画布'],
    [['空格', '拖动'], '平移画布, 也可中键拖动'],
    [['捏合'], '缩放, 也可 ⌘ + 滚轮'],
    [['F'], '放大选中元素'],
    [['0'], '适应窗口'],
    [['1', '2', '3'], '实时 / 2D / 3D'],
    [['C'], '取色, 点击复制色值'],
  ]],
  ['3D', false, [
    [['拖动'], '旋转'],
    [['S'], '独立显示选中元素'],
    [['[', ']'], '调整层间距'],
    [['I'], '显示 / 隐藏截图'],
  ]],
  ['实时', true, [
    [['拖动'], '在 App 内滑动 / 滚动'],
    [['⌥', '点击'], '选中元素并切到 2D'],
    [['⌘', 'V'], '粘贴到模拟器'],
    [['Esc'], '停止向模拟器输入按键'],
  ]],
];

function shortcutsPanel() {
  const grid = el('div', 'shortcut-groups');
  SHORTCUT_GROUPS.forEach(([title, liveOnly, items]) => {
    const group = el('div', liveOnly ? 'shortcut-group has-live-only' : 'shortcut-group');
    group.appendChild(el('h5', null, t(title)));
    items.forEach(([keys, text]) => {
      const row = el('div', 'shortcut');
      const keysCell = el('div', 'shortcut-keys');
      keys.forEach((key) => keysCell.appendChild(el('kbd', null, t(key))));
      row.append(keysCell, el('span', null, t(text)));
      group.appendChild(row);
    });
    grid.appendChild(group);
  });
  return [grid];
}

function openPanel(name) {
  const panels = { about: [t('关于 LayerLens'), aboutPanel], integration: [t('App 集成'), integrationPanel], shortcuts: [t('快捷键'), shortcutsPanel], heal: [t('修复模拟器触摸'), healPanel] };
  const panel = panels[name];
  if (!panel) return;
  state.panel = name;
  hidePopovers();
  hideMenu();
  $('modalTitle').textContent = panel[0];
  $('modalBody').replaceChildren(...panel[1]());
  $('modalBody').scrollTop = 0;
  showLayer($('modal'));
}

function closePanel() {
  hideLayer($('modal'), 160);
}

function setupPanels() {
  window.layerlensOpenPanel = openPanel;
  document.addEventListener('click', (e) => {
    const trigger = e.target.closest('[data-panel]');
    if (trigger) openPanel(trigger.dataset.panel);
  });
  $('modal').addEventListener('click', (e) => {
    if (e.target === $('modal')) closePanel();
    const value = e.target.closest('[data-copy]')?.dataset.copy;
    if (value) copyText(value, '复制');
  });
  $('modalClose').addEventListener('click', closePanel);
}

// MARK: - Setup

function setup() {
  applyI18n();
  loadViewState();
  window.addEventListener('pagehide', saveViewState);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') saveViewState();
  });
  $('tree').addEventListener('click', (e) => {
    const row = e.target.closest('.row');
    if (!row) return;
    const key = row.dataset.key;
    if (e.target.closest('.copy')) {
      copyText(nodePath(state.nodes.get(key)), '复制路径');
      return;
    }
    const bar = e.target.closest('.ev-bar');
    if (bar) {
      showEventPop(state.nodes.get(key), bar);
      return;
    }
    if (e.target.closest('.arrow')?.dataset.toggle) {
      if (e.altKey) {
        // Alt + 点击: 展开/收起整个子树
        const expand = !state.expanded.has(key);
        const walk = (n) => {
          expand ? state.expanded.add(n.key) : state.expanded.delete(n.key);
          n.children.forEach(walk);
        };
        walk(state.nodes.get(key));
      } else if (state.expanded.has(key)) {
        state.expanded.delete(key);
      } else {
        state.expanded.add(key);
      }
      renderTree();
      return;
    }
    select(key, true);
  });
  let treePress = null;
  $('tree').addEventListener('pointerdown', (e) => {
    if (e.pointerType === 'mouse') return;
    const row = e.target.closest('.row');
    if (!row) return;
    const start = { x: e.clientX, y: e.clientY };
    clearTimeout(treePress?.timer);
    treePress = {
      start,
      timer: setTimeout(() => {
        select(row.dataset.key, true);
        showMenu(start.x, start.y, state.nodes.get(row.dataset.key));
      }, LONG_PRESS_MS),
    };
  });
  $('tree').addEventListener('pointermove', (e) => {
    if (treePress && Math.hypot(e.clientX - treePress.start.x, e.clientY - treePress.start.y) > 8) clearTimeout(treePress.timer);
  });
  ['pointerup', 'pointercancel'].forEach((type) => $('tree').addEventListener(type, () => clearTimeout(treePress?.timer)));
  $('tree').addEventListener('contextmenu', (e) => {
    const row = e.target.closest('.row');
    if (!row) return;
    e.preventDefault();
    select(row.dataset.key, true);
    showMenu(e.clientX, e.clientY, state.nodes.get(row.dataset.key));
  });
  document.addEventListener('pointerdown', (e) => {
    if (!e.target.closest('.context-menu')) hideMenu();
    if (!e.target.closest('.popover-anchor, .ev-bar')) hidePopovers();
  });
  document.addEventListener('scroll', hideMenu, true);
  $('tree').addEventListener('scroll', () => hideLayer($('eventPop'), 120));
  window.addEventListener('blur', hideMenu);
  $('tree').addEventListener('mouseover', (e) => {
    const row = e.target.closest('.row');
    const key = row ? row.dataset.key : null;
    if (key !== state.hover) {
      state.hover = key;
      updateHighlights();
    }
  });
  $('tree').addEventListener('mouseleave', () => {
    state.hover = null;
    updateHighlights();
  });

  $('refreshBtn').addEventListener('click', refresh);
  $('crumbs').addEventListener('click', (e) => {
    const key = e.target.closest('.crumb')?.dataset.key;
    if (!key) return;
    // 窄屏点当前节点进入详情
    if (key === state.selected && isNarrow()) setView('detail');
    else select(key);
  });
  $('modeSeg').addEventListener('click', (e) => requestMode(e.target.dataset.mode));
  $('showLayers').addEventListener('change', (e) => {
    state.showLayers = e.target.checked;
    syncTreeFilter();
    renderTree();
    renderCanvas();
  });
  $('showHidden').addEventListener('change', (e) => {
    state.showHidden = e.target.checked;
    syncTreeFilter();
    renderTree();
  });
  ['showImages', 'subtreeOnly'].forEach((field) => {
    $(field).addEventListener('click', () => {
      state[field] = !state[field];
      syncToggles();
      if (field === 'subtreeOnly') toggleSubtreeView();
      renderCanvas();
    });
  });
  $('optionsBtn').addEventListener('click', () => togglePopover('optionsMenu'));
  $('helpBtn').addEventListener('click', () => openPanel('shortcuts'));
  $('spacingBtn').addEventListener('click', () => togglePopover('spacingPop'));
  $('treeFilterBtn').addEventListener('click', () => togglePopover('treeFilterPop'));
  $('zoomFit').addEventListener('click', fitView);
  $('themeSeg').addEventListener('click', (e) => {
    const theme = e.target.dataset.theme;
    if (theme) applyTheme(theme, true);
  });
  $('langSeg').querySelectorAll('button').forEach((b) => b.classList.toggle('active', b.dataset.lang === loadLangSetting()));
  $('langSeg').addEventListener('click', (e) => {
    const lang = e.target.dataset.lang;
    if (lang && lang !== loadLangSetting()) setLang(lang);
  });
  $('spacing').addEventListener('input', (e) => setSpacing(Number(e.target.value)));
  let searchTimer = null;
  $('search').addEventListener('input', (e) => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
      state.query = e.target.value;
      renderTree();
    }, 150);
  });
  $('detailTabs').addEventListener('click', (e) => {
    const tab = e.target.dataset.tab;
    if (tab && tab !== state.tab) {
      state.classTarget = null;
      switchTab(tab);
    }
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      setColorPicker(false);
      hideMenu();
      hidePopovers();
      closePanel();
    }
    if (e.key === '?' && !(e.target instanceof Element && e.target.matches('input, select, textarea'))) {
      if ($('modal').hidden || $('modal').classList.contains('closing') || state.panel !== 'shortcuts') openPanel('shortcuts');
      else closePanel();
      return;
    }
    if (!$('modal').hidden && !$('modal').classList.contains('closing')) return;
    if (e.target instanceof Element && e.target.matches('input, select, textarea')) return;
    if (e.code === 'Space' && state.mode !== 'live') {
      // 阻止页面滚动和触发聚焦中的按钮
      e.preventDefault();
      setPanKey(true);
      return;
    }
    if (!e.metaKey && !e.ctrlKey && !e.altKey && handleViewKey(e.key)) {
      e.preventDefault();
      return;
    }
    if (e.key === 'r' && !e.metaKey && !e.ctrlKey) refresh();
    if (!e.metaKey && !e.ctrlKey && (!e.altKey || e.key === 'ArrowLeft') && handleTreeKey(e.key, e.altKey)) e.preventDefault();
    // 未选中页面文本时, ⌘C 复制选中节点路径
    if (e.key === 'c' && (e.metaKey || e.ctrlKey) && !window.getSelection().toString()) {
      const node = state.nodes.get(state.selected);
      if (node) {
        e.preventDefault();
        copyText(nodePath(node), '复制路径');
      }
    }
  });
  document.addEventListener('keyup', (e) => {
    if (e.code === 'Space') setPanKey(false);
  });
  window.addEventListener('blur', () => setPanKey(false));
  setupCanvasEvents();
  setupLiveEvents();
  setupColorPicker();
  setupLayout();

  applyTheme(loadTheme(), false);
  $('targetBtn').addEventListener('click', () => togglePopover('targetMenu'));
  setupPanels();
  start();
}

async function start() {
  try {
    await loadTargets();
  } catch (e) {
    toast(t('无法连接 LayerLens: {0}', e.message), true);
  }
  pickTarget();
  const device = currentDevice();
  targets.hadDevice = !!device;
  renderTargetMenu();
  await syncLive();
  pollTargets();
  // 一台设备都没有时显示默认页, 保留选中的目标, 该设备回来时优先连接
  if (!targets.devices.length) {
    targets.idle = true;
    $('appName').textContent = t('未连接');
    showGuide();
    setAppState('offline', t('没有发现设备'));
    return;
  }
  if (!targets.bundleId) {
    $('appName').textContent = device.name;
    const body = liveAvailable() ? t('运行集成了 LayerLens 的 App 后会自动连接, 也可以切换到实时查看模拟器画面') : t('运行集成了 LayerLens 的 App 后会自动连接');
    showEmptyState(t('没有运行中的已集成 App'), body);
    setAppState('offline', t('没有运行中的已集成 App'), { text: t('查看集成说明'), panel: 'integration' });
    return;
  }
  document.body.classList.add('has-app');
  appState.instanceId = currentApp()?.instanceId || '';
  appState.warning = compatibilityWarning(currentApp());
  watchApp();
  // App 未运行时等事件流连上后整页重新加载; 模拟器的实时画面照常可用
  if (!currentApp()) {
    appState.dropped = true;
    $('appName').textContent = targets.bundleId;
    setAppState('offline');
    return;
  }
  loadAppInfo();
  refresh();
}

function loadAppInfo() {
  return api('/api/app').then((info) => {
    $('appName').textContent = info.appName;
    appInfo.base = `${info.version} · ${info.os}`;
    $('appMeta').title = `${info.bundleId} · ${info.device}`;
    const menuInfo = $('menuAppInfo');
    menuInfo.replaceChildren(el('b', null, info.appName), el('div', null, `${info.bundleId} · ${info.version}`), el('div', null, `${info.device} · ${info.os}`));
    updateAppMeta();
    document.title = `${info.appName} - LayerLens`;
  }).catch((e) => {
    // App 刚换端口等情况下取不到, 仍显示名称, 事件流重连后会重新加载
    $('appName').textContent = currentApp()?.appName || targets.bundleId;
    toast(e.message, true);
  });
}

setup();
