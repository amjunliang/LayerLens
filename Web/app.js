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
// 3D 透视距离, WebGL 绘制与投影计算共用
const PERSPECTIVE = 2400;

const state = {
  roots: [],
  nodes: new Map(),
  selected: null,
  hover: null,
  // 展开的节点(oid): 选中节点的祖先 + 手动展开的, 不做持久化
  expanded: new Set(),
  // 控制器行: 收起的控制器(其根视图 key), 默认展开; vcFocus 为 true 时选中的是 selected 所属控制器的行
  vcCollapsed: new Set(),
  vcFocus: false,
  // 选中控制器行时自动切到类信息, 记下原来的页签, 选中其他行时切回
  tabBeforeVC: null,
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

// 自上而下的 Markdown 嵌套列表, 与复制元素信息格式一致
function nodePath(node) {
  const parts = [];
  for (let n = node; n; n = n.parent) {
    const ivar = n.ivarTraces[0] ? n.ivarTraces[0].split('.').pop() : '';
    parts.unshift(ivar ? `${n.cls} (${ivar})` : n.cls);
  }
  return markdownTree(parts);
}

function markdownTree(parts) {
  return parts.map((part, depth) => `${'  '.repeat(depth)}- ${part}`).join('\n');
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

const ELEMENT_TEXT_MAX = 40;

// 元素自身一行: 成员变量名加类型, 有文字时附上(换行替换为空格, 过长截断), 便于搜索源码定位;
// 没有声明在业务类中的成员变量时退回系统类的, 如 _UISystemBackgroundView._colorView
function elementLine(node, ivars) {
  const names = ivars.length ? ivars.map((r) => r.text) : [...new Set(node.ivarTraces.map((trace) => {
    const dot = trace.lastIndexOf('.');
    const [host, declaring = host] = trace.slice(0, dot).split(' : ');
    return `${declaring}.${trace.slice(dot + 1)}`;
  }))];
  let line = names.length ? `${names.join(' and ')} (${node.cls})` : node.cls;
  const text = String(node.text ?? '').replace(/\s+/g, ' ').trim();
  if (text) line += ` "${text.length > ELEMENT_TEXT_MAX ? text.slice(0, ELEMENT_TEXT_MAX) + '…' : text}"`;
  return line;
}

// 从元素向上定位, 省略成员变量持有者和系统容器; 控制器跳过导航和列表等容器.
// 输出为自上而下的 Markdown 嵌套列表, 人和 AI 都能直接看出层级
function elementSummary(node) {
  const ivars = codeIvars(node);
  const ownerClasses = new Set(ivars.flatMap((r) => [r.host, r.declaring]));
  const parts = [elementLine(node, ivars)];
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
  return markdownTree(parts.reverse());
}

// more 为 true 的收进右键菜单的"更多复制"子菜单
const COPY_ACTIONS = [
  { title: '复制元素信息', value: elementSummary },
  { title: '复制类名', value: (n) => n.cls },
  { title: '复制层级路径', value: nodePath },
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

// 屏幕截图(画布右键菜单): 实时模式取模拟器原始分辨率截图(画面按显示尺寸缩小编码), 取不到时用当前画面; 2D/3D 取当前窗口的 App 截图
function screenShotPNG() {
  if (state.mode === 'live') return fetchPNG(`/sim/${encodeURIComponent(live.udid)}/screenshot`).catch(liveCanvasPNG);
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
  centerStage();
  // 3D 按层叠旋转、透视后的实际范围缩放并居中, 与 2D 一样占满画布, 不随层数和间距忽大忽小
  const bounds = state.mode === '3d' ? projectedBounds() : null;
  if (bounds) {
    const [width, height] = contentSize($('stageWrap'));
    const fit = Math.min(width / (bounds.maxX - bounds.minX), height / (bounds.maxY - bounds.minY)) * planFitRatio();
    state.zoom = Math.max(0.2, Math.min(6, fit));
    centerStage();
    const next = projectedBounds();
    state.panX -= (next.minX + next.maxX) / 2;
    state.panY -= (next.minY + next.maxY) / 2;
  }
  applyStageTransform();
}

// 舞台中心(0,0,0)映射到视口中心
function centerStage() {
  state.panX = 0;
  state.panY = 0;
  state.panZ = 0;
  const center = projectToScreen({ x: 0, y: 0, z: 0 });
  state.panX = -center.x;
  state.panY = -center.y;
  state.panZ = -center.z;
}

// 3D 画布区域(window 或只看的子树)从底层到顶层的立体框, 经旋转和透视后在屏幕上的范围(相对视口中心).
// 超出 window 的内容(如滚动视图未显示的部分)不参与计算, 避免把主体缩得很小; 没有可绘制的层时返回 null
function projectedBounds() {
  const win = currentWindow();
  if (!win) return null;
  const nodes = drawableNodes(win);
  if (!nodes.length) return null;
  const [, , fw, fh] = canvasFrame(win);
  const depth = Math.max(...nodes.map((node) => node.level)) * state.spacing;
  const bounds = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
  [0, depth].forEach((z) => {
    [[-fw / 2, -fh / 2], [fw / 2, -fh / 2], [-fw / 2, fh / 2], [fw / 2, fh / 2]].forEach(([x, y]) => {
      const p = projectToScreen({ x, y, z });
      const k = PERSPECTIVE / Math.max(1, PERSPECTIVE - p.z);
      bounds.minX = Math.min(bounds.minX, p.x * k);
      bounds.maxX = Math.max(bounds.maxX, p.x * k);
      bounds.minY = Math.min(bounds.minY, p.y * k);
      bounds.maxY = Math.max(bounds.maxY, p.y * k);
    });
  });
  return bounds.maxX > bounds.minX && bounds.maxY > bounds.minY ? bounds : null;
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

// 严格焦点模式: 只暂停页面的视图采集和播放, Hub 的日志/抓包/终端继续运行。
const pageActivity = { active: false, ready: false, pending: false, controller: null, generation: 0 };

function pageHasFocus() {
  return document.visibilityState !== 'hidden' &&
    (typeof window.LAYERLENS_WINDOW_FOCUSED === 'boolean' ? window.LAYERLENS_WINDOW_FOCUSED : document.hasFocus());
}

function setupPageActivity() {
  pageActivity.active = pageHasFocus();
  const update = () => {
    const active = pageHasFocus();
    if (active === pageActivity.active) return;
    pageActivity.active = active;
    ++pageActivity.generation;
    if (!active) {
      pageActivity.pending = true;
      ++refreshSeq;
      pageActivity.controller?.abort();
      resetImages();
      liveStop();
      if (stage3D.frame) cancelAnimationFrame(stage3D.frame);
      stage3D.frame = 0;
      return;
    }
    if (pageActivity.ready) resumePageActivity();
  };
  window.addEventListener('focus', update);
  window.addEventListener('blur', update);
  window.addEventListener('layerlens-window-focus', update);
  document.addEventListener('visibilitychange', update);
}

async function resumePageActivity() {
  const generation = pageActivity.generation;
  try { await loadTargets(); } catch (_) { /* 下一次轮询再试 */ }
  if (!pageActivity.active || generation !== pageActivity.generation) return;
  renderTargetMenu();
  syncLive();
  if (state.mode !== 'live' && targets.bundleId && pageActivity.pending) {
    pageActivity.pending = false;
    refresh();
  }
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
  if (!pageActivity.active) return;
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
        job.apply(job.url, img);
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

// force: 与当前 App 无关的错误(如启动其他 App 失败), App 不在线时也显示
// sticky: 一直显示到下一条提示或 hideToast, 用于耗时不定的操作
function toast(message, isError, force, sticky) {
  // App 不在线时请求失败是预期的, 由提示条说明
  if (isError && !force && appState.value !== 'online') return;
  const node = $('toast');
  node.textContent = message;
  node.className = 'toast show' + (isError ? ' error' : '');
  clearTimeout(toast.timer);
  if (sticky) return;
  // 需要用户处理的错误多停留一会儿, 留出读完的时间
  toast.timer = setTimeout(hideToast, force ? 5000 : 2600);
}

function hideToast() {
  clearTimeout(toast.timer);
  $('toast').className = 'toast';
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
  for (let p = state.vcFocus ? node?.parent : node; p; p = p.parent) state.vcCollapsed.delete(p.key);
}

// MARK: - Hierarchy

// 连续刷新时只采用最后一次请求的结果, 避免较早的响应晚到覆盖新层级
let refreshSeq = 0;
async function refresh() {
  if (!pageActivity.active) { pageActivity.pending = true; return; }
  pageActivity.pending = false;
  pageActivity.controller?.abort();
  const controller = new AbortController();
  pageActivity.controller = controller;
  const seq = ++refreshSeq;
  try {
    const roots = await api('/api/hierarchy', { signal: controller.signal });
    if (seq !== refreshSeq || !pageActivity.active) return;
    applyHierarchy(roots);
  } catch (e) {
    if (seq === refreshSeq && e.name !== 'AbortError') showRefreshError(e);
  } finally {
    if (pageActivity.controller === controller) pageActivity.controller = null;
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
  if (node.vcClass && node.vcClass.toLowerCase().includes(q)) return true;
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
      // 控制器作为树中单独的一层, 它的根视图是唯一的子节点
      const depth = node.vcClass ? level + 1 : level;
      if (node.vcClass) {
        const open = !!q || !state.vcCollapsed.has(node.key);
        frag.appendChild(makeControllerRow(node, level, open, q));
        if (!open) return;
      }
      frag.appendChild(makeRow(node, depth, children.length > 0, expanded, q));
      if (expanded) addRows(children, depth + 1);
    });
  };
  addRows(state.roots.filter((r) => state.showHidden || !r.effHidden), 0);
  // 行宽统一为最宽行, 支持横向滚动且悬停背景铺满
  const inner = el('div', 'tree-inner');
  inner.appendChild(frag);
  tree.replaceChildren(inner);
  if (state.hover) tree.querySelector(`.row:not(.vc-row)[data-key="${CSS.escape(state.hover)}"]`)?.classList.add('hover');
  scrollToSelected();
  renderCrumbs();
}

function makeRow(node, level, hasChildren, expanded, q) {
  const row = el('div', 'row');
  row.dataset.key = node.key;
  annotate(row, node);
  row.style.setProperty('--indent', level * TREE_INDENT + 'px');
  if (node.key === state.selected && !state.vcFocus) row.classList.add('selected');
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
  const cls = el('span', 'cls' + (node.isLayer ? ' layer' : ''));
  appendHighlighted(cls, node.cls, q);
  row.appendChild(cls);
  if (node.title) row.appendChild(el('span', 'meta', node.title));
  // 与 Lookin 一致: 有特殊标记(Cell 位置 / KeyWindow)时显示它, 否则显示引用它的所有成员变量名; 控制器已单独成行
  if (node.specialTrace && !node.vcClass) {
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

// 控制器行的 key 为 VC_KEY + 根视图 key; 选中、悬停、右键时画布和详情对应它的根视图
const VC_KEY = 'vc:';

function viewKeyOf(key) {
  return key?.startsWith(VC_KEY) ? key.slice(VC_KEY.length) : key;
}

function makeControllerRow(node, level, expanded, q) {
  const row = el('div', 'row vc-row');
  row.dataset.key = VC_KEY + node.key;
  row.style.setProperty('--indent', level * TREE_INDENT + 'px');
  if (node.key === state.selected && state.vcFocus) row.classList.add('selected');
  row.title = node.vcClass;
  const arrow = el('span', 'arrow' + (expanded ? ' expanded' : ''));
  arrow.dataset.toggle = '1';
  arrow.appendChild(icon('chevron'));
  row.append(arrow, el('span', 'vc-icon'));
  const name = el('span', 'vc');
  appendHighlighted(name, node.vcClass, q);
  row.appendChild(name);
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

// 记住的子节点; 中间层在树中不可见(如被隐藏的 CALayer)时继续向下找; 子节点是控制器的根视图时返回控制器行
function rememberedChild(node, rows) {
  let key = childTrail.get(node.key);
  while (key && !rows.includes(key) && !rows.includes(VC_KEY + key)) key = childTrail.get(key);
  if (!key) return null;
  return rows.includes(VC_KEY + key) ? VC_KEY + key : key;
}

// 当前树中可见行的顺序, 用于键盘导航
function visibleRowKeys() {
  return [...$('tree').querySelectorAll('.row')].map((row) => row.dataset.key);
}

// 树中可见的父行: 控制器根视图的父行是控制器行, 控制器行的父行是上一层可见的视图
function treeParentKey(key, rows) {
  const isVC = key.startsWith(VC_KEY);
  const node = state.nodes.get(viewKeyOf(key));
  if (!isVC && node.vcClass && rows.includes(VC_KEY + node.key)) return VC_KEY + node.key;
  let p = node.parent;
  while (p && !rows.includes(p.key)) p = p.parent;
  return p ? p.key : null;
}

// ← 直接选中父节点, 不收起(在画布上按时收起树看不到变化, 像是按了没反应); ⌥ + ← 收起
function handleTreeKey(key, alt = false) {
  const node = state.nodes.get(state.selected);
  if (!node) return false;
  const current = state.vcFocus ? VC_KEY + node.key : node.key;
  const rows = visibleRowKeys();
  const index = rows.indexOf(current);
  const searching = !!state.query.trim();
  const hasChildren = state.vcFocus || shownChildren(node).length > 0;
  const expanded = searching || (state.vcFocus ? !state.vcCollapsed.has(node.key) : state.expanded.has(node.key));
  const setExpanded = (rowKey, open) => {
    const target = viewKeyOf(rowKey);
    if (rowKey.startsWith(VC_KEY)) open ? state.vcCollapsed.delete(target) : state.vcCollapsed.add(target);
    else open ? state.expanded.add(target) : state.expanded.delete(target);
  };
  if (key === 'ArrowDown' || key === 'ArrowUp') {
    const next = rows[index + (key === 'ArrowDown' ? 1 : -1)];
    if (next) select(next, true);
  } else if (key === 'ArrowRight') {
    if (hasChildren && !expanded) {
      setExpanded(current, true);
      renderTree();
    } else if (hasChildren) {
      select(state.vcFocus ? node.key : rememberedChild(node, rows) || rows[index + 1], true);
    }
  } else if (key === 'ArrowLeft') {
    // 选中树中可见的父行(跳过被隐藏的 CALayer 等)
    const parent = treeParentKey(current, rows);
    if (alt && !searching) {
      // 收起当前行; 没有可收起的则收起父行并选中它
      const target = hasChildren && expanded ? current : parent;
      if (!target) return true;
      setExpanded(target, false);
      if (target === current) renderTree();
      else select(target, true);
    } else if (parent) {
      select(parent, true);
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
  const focusVC = !!key?.startsWith(VC_KEY);
  key = viewKeyOf(key);
  if (!state.nodes.has(key)) return;
  const previousWindow = currentWindow();
  state.selected = key;
  state.vcFocus = focusVC && !!state.nodes.get(key).vcClass;
  state.classTarget = null;
  if (state.vcFocus) {
    const node = state.nodes.get(key);
    state.classTarget = { oid: node.vcOid, name: node.vcClass };
    if (state.tab !== 'class') {
      state.tabBeforeVC = state.tab;
      setTabButtons('class');
    }
  } else if (state.tabBeforeVC) {
    setTabButtons(state.tabBeforeVC);
    state.tabBeforeVC = null;
  }
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

// 小屏用单栏 + 工具栏两端开关切换面板: 触屏窄屏, 或桌面窗口窄到工具栏放不下; 其余按宽度自动收起侧栏
const NARROW_QUERY = '(max-width: 760px) and (pointer: coarse), (max-width: 600px)';

function isNarrow() {
  return window.matchMedia(NARROW_QUERY).matches;
}

// 画布可用尺寸: 去掉内边距(窄屏底部为浮动工具条预留的位置)
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

// 小屏一次只显示一个面板: 层级 / 详情盖住画布, 再点一次收起回到画布
function setView(view) {
  document.body.dataset.view = view;
  syncPanels();
}

function toggleView(view) {
  setView(document.body.dataset.view === view ? 'canvas' : view);
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
    stage3DClear();
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
    stage3DSetNodes(drawableNodes(win), [wx, wy, w, h], (node) => {
      if (!state.showImages || !node.oid) return null;
      // 不显示 CALayer 且只有 CALayer 子节点时, 子层不单独绘制, 取整体截图; 旧版 Pod 也能显示视频播放层等内容
      const onlyLayers = !state.showLayers && node.children.length > 0 && node.children.every((child) => child.isLayer);
      return shotURL(node.oid, onlyLayers ? 'group' : 'solo');
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
  // 3D 由 WebGL 绘制: 平移后先移到旋转中心再旋转, 选中节点在旋转时保持不动(见 stage-gl.js)
  if (state.mode === '3d') {
    $('stage').style.transform = '';
    stage3DInvalidate();
    return;
  }
  // 平移在屏幕坐标系中进行, 放在最前面
  $('stage').style.transform = `translate3d(${state.panX}px, ${state.panY}px, 0px) scale(${stageScale(win)})`;
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
  if (state.mode !== '3d' || !win || !node || !stage3DHas(node.key)) {
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
    stage3DInvalidate();
  }
  const tree = $('tree');
  tree.querySelectorAll('.row.hover').forEach((row) => row.classList.remove('hover'));
  if (state.hover) tree.querySelector(`.row:not(.vc-row)[data-key="${CSS.escape(state.hover)}"]`)?.classList.add('hover');
}

// MARK: - Hover tip
// 画布悬停标签(类似 Chrome 检查元素): 只显示类名, 带箭头贴在悬停元素顶部, 元素不变则位置不变

// selection: 键盘切换选中时标签贴在选中元素上, 鼠标移动后恢复跟随悬停
// switchedAt: 上次切换内容的时间
const hoverTip = { pendingKey: null, contentTimer: 0, selection: false, switchedAt: 0 };

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
  // 内容防抖: 停顿后第一次换目标立即切换; 连续快速划过重叠层时, 在新目标上停留片刻再切换, 不闪烁
  if (tip.hidden || !tip.dataset.key || (tip.dataset.key !== node.key && performance.now() - hoverTip.switchedAt > 150)) {
    clearTimeout(hoverTip.contentTimer);
    hoverTip.pendingKey = null;
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
  hoverTip.switchedAt = performance.now();
  positionHoverTip();
}

// 以悬停元素在屏幕上的外框定位: 优先上方, 放不下放下方; 水平限制在画布内, 箭头指向元素
function positionHoverTip() {
  const tip = $('hoverTip');
  const key = tip.dataset.key;
  if (tip.hidden || !key) return;
  const target = state.mode === '2d' && $('stage').querySelector(hoverTip.selection ? '.box.selected' : '.box.hover');
  const rect = state.mode === '2d' ? target && target.getBoundingClientRect() : stage3DClientRect(key);
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
    return stage3DNodeAt(point.clientX, point.clientY);
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
      key = stage3DNodeAt(e.clientX, e.clientY)?.key || null;
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
  if (!pageActivity.active) return;
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
  if (!pageActivity.active || live.ws || !liveAvailable()) return;
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
    liveReportSize(true);
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
  const onFrame = (frame) => paintLive(frame);
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

// 解码出一帧立即绘制, 不等动画帧回调(否则平均多等半帧); 绘制只需零点几毫秒, 同一刷新周期内多画几次也无妨
function paintLive(frame) {
  if (!live.ws) {
    if (frame.close) frame.close();
    return;
  }
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
  if (live.connected) liveReportSize();
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
// idle: 正在显示没有设备的默认页
const targets = { hub: null, devices: [], deviceId: '', bundleId: '', hadDevice: false, idle: false };

// 连接过的设备和 App: 断开后仍显示在菜单中, 选中项不随设备断开跳动, 连回来后自动恢复.
// 由 Mac App 记录和保存(扫描到的设备和 App 自动记录), 随设备列表返回; 网页和 App 窗口共用一份, 重启后保留, 用户可从菜单中移除
// { 设备 ID: { id, name, model, os, kind, apps: { Bundle ID: { bundleId, appName, version } } } }
const targetHistory = {};
// 旧版存在网页本地的记录, 首次加载时交给 Mac App
const LEGACY_HISTORY_KEY = 'layerlens_target_history';

function replaceTargetHistory(history) {
  for (const key of Object.keys(targetHistory)) delete targetHistory[key];
  Object.assign(targetHistory, history || {});
}

function postTargetHistory(body) {
  return fetch('/api/hub/history', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
    .then((res) => res.json())
    .catch(() => ({}));
}

function migrateTargetHistory() {
  let legacy = null;
  try {
    legacy = JSON.parse(localStorage.getItem(LEGACY_HISTORY_KEY));
    localStorage.removeItem(LEGACY_HISTORY_KEY);
  } catch (e) {
    // 不可用时没有旧记录
  }
  // Mac App 只补充缺少的设备和 App, 已自动记录的设备也要合并其下的旧 App
  Object.values(legacy || {}).forEach((entry) => {
    if (!entry?.id) return;
    const existing = targetHistory[entry.id];
    if (existing) existing.apps = { ...(entry.apps || {}), ...(existing.apps || {}) };
    else targetHistory[entry.id] = entry;
    postTargetHistory({ op: 'add', entry });
  });
}

// 扫描到的设备和 App 由 Mac App 自动记录; 当前目标尚未扫描到时(如带地址参数打开、设备未连接)补一条占位记录
function recordTargetHistory() {
  if (!targets.deviceId) return;
  const existing = targetHistory[targets.deviceId];
  if (existing && (!targets.bundleId || existing.apps?.[targets.bundleId])) return;
  // 未启动的模拟器从模拟器列表取名称
  const device = currentDevice() || (targets.simulators || []).find((sim) => sim.id === targets.deviceId);
  const entry = existing || { id: targets.deviceId, name: device?.name || t('已断开的设备'), model: device?.model || '', os: device?.os || '', kind: device?.kind || (currentDevice() ? '' : device ? 'simulator' : '') };
  entry.apps = entry.apps || {};
  const app = currentApp();
  if (targets.bundleId) entry.apps[targets.bundleId] = { bundleId: targets.bundleId, appName: app?.appName || appInfo.name || '', version: app?.version || '' };
  targetHistory[targets.deviceId] = entry;
  postTargetHistory({ op: 'add', entry });
}

async function removeTargetHistory(deviceId, bundleId) {
  const entry = targetHistory[deviceId];
  if (!entry) return;
  // 先在本页移除, 再以 Mac App 返回的记录为准
  if (bundleId) delete entry.apps[bundleId];
  if (!bundleId || (!Object.keys(entry.apps || {}).length && !targets.devices.some((d) => d.id === deviceId))) delete targetHistory[deviceId];
  renderTargetMenu();
  const result = await postTargetHistory({ op: 'remove', device: deviceId, app: bundleId });
  if (result.history) {
    replaceTargetHistory(result.history);
    renderTargetMenu();
  }
}

// 设备上已断开的历史 App(不在当前扫描结果中)
function historyApps(deviceId, liveApps = []) {
  return Object.values(targetHistory[deviceId]?.apps || {})
    .filter((app) => !liveApps.some((a) => a.bundleId === app.bundleId))
    .map((app) => ({ ...app, away: true }));
}

// 选中的设备不在列表中(拔掉或关闭)
function currentDeviceGone() {
  return !!targets.deviceId && !currentDevice();
}

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
  targets.simulators = data.simulators || [];
  // 旧版 Mac App 不返回历史, 保留本页的记录
  if (data.history) {
    replaceTargetHistory(data.history);
    netCaptureHistoryChanged();
  }
  settleSimPending();
}

// 模拟器启动 / 关闭: 等列表反映出结果(出现在或离开已启动设备中)再清除进行中状态, 超时也清除
const SIM_PENDING_TIMEOUT_MS = 90000;
const SIM_CONFIRM_MS = 3000;
const simPending = new Map();
let simConfirm = null;

function settleSimPending() {
  simPending.forEach((pending, id) => {
    const booted = targets.devices.some((d) => d.id === id);
    if ((pending.action === 'boot') === booted || Date.now() - pending.since > SIM_PENDING_TIMEOUT_MS) {
      simPending.delete(id);
      if (pending.action === 'boot' && booted && pending.select) switchTarget(id, '');
    }
  });
}

async function simulatorAction(id, action, select) {
  simPending.set(id, { action, since: Date.now(), select });
  renderTargetMenu();
  try {
    const res = await fetch('/api/hub/simulator', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device: id, action }),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    await loadTargets();
  } catch (e) {
    simPending.delete(id);
    toast(t(action === 'boot' ? '启动失败: {0}' : '关机失败: {0}', e.message), true);
  }
  renderTargetMenu();
  syncLive();
}

// 关闭会结束模拟器上的 App, 第一次点击变为「确认关机」, 几秒内再点才执行
function simPowerButton(id, booted) {
  const pending = simPending.get(id);
  const confirming = booted && simConfirm?.id === id && Date.now() < simConfirm.until;
  // 平时只显示图标, 确认和进行中显示文字
  const label = pending ? (pending.action === 'boot' ? t('启动中…') : t('关机中…')) : confirming ? t('确认关机') : '';
  const button = el('button', 'target-power' + (confirming ? ' danger' : '') + (label ? ' text' : ''), label);
  if (!label) button.append(icon(booted ? 'power' : 'play'));
  button.title = booted ? t('关机') : t('启动');
  button.disabled = !!pending;
  button.addEventListener('click', (e) => {
    e.stopPropagation();
    if (!booted) {
      simulatorAction(id, 'boot', false);
    } else if (confirming) {
      simConfirm = null;
      simulatorAction(id, 'shutdown', false);
    } else {
      simConfirm = { id, until: Date.now() + SIM_CONFIRM_MS };
      setTimeout(renderTargetMenu, SIM_CONFIRM_MS);
      renderTargetMenu();
    }
  });
  return button;
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

// 地址参数指定的和本次窗口中连接过的目标始终保留(设备或 App 稍后可能回来); 记住的目标不存在时自动选第一个运行中的 App
function pickTarget() {
  const saved = savedTarget();
  const device = targets.devices.find((d) => d.id === saved.deviceId);
  const known = !!targetHistory[saved.deviceId] && (!saved.bundleId || !!targetHistory[saved.deviceId].apps[saved.bundleId]);
  if (saved.explicit || known || device?.apps.some((a) => a.bundleId === saved.bundleId)) {
    targets.deviceId = saved.deviceId || '';
    targets.bundleId = saved.bundleId || '';
    return;
  }
  const first = defaultDevice();
  targets.deviceId = first ? first.id : '';
  targets.bundleId = firstAppId(first);
}

// 优先有运行中 App 的设备; 都没有时选第一台已启动的模拟器, 以便直接显示实时画面
function defaultDevice() {
  return targets.devices.find((d) => d.apps.length) || targets.devices.find((d) => d.kind === 'simulator') || targets.devices[0];
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
const LAUNCH_FAILURES = {
  locked: '设备已锁屏, 请解锁后重试',
  developerMode: '设备未开启开发者模式',
  notInstalled: '该设备上没有安装这个 App',
  untrustedDeveloper: '开发者证书未被信任, 请在设备的「设置 - 通用 - VPN 与设备管理」中信任',
  unpaired: '设备未信任这台 Mac, 请重新连接并在设备上点「信任」',
  // 菜单里能点到的真机 USB 是连着的, 开发者通道不可用基本是锁屏或休眠后被系统断开
  unavailable: '设备已锁屏或休眠, 请解锁后重试',
  timeout: '设备没有响应, 请解锁设备或重新插拔后重试',
};

// Mac 端启动命令最多等 20s, 再等 App 响应最多 5s; 超过时多半是连接已断开
const ACTIVATE_TIMEOUT_MS = 30000;
// 快速来回切换时不启动经过的 App, 停下来后只激活最后选择的一个
const ACTIVATE_DEBOUNCE_MS = 150;

// failure: 启动失败的原因, 不再切换; hint: 已启动但没有在前台响应, 照常切换并提示可能的原因
// signal: 用户切到别处时取消, 返回 { cancelled: true }
async function activateApp(deviceId, bundleId, signal) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ACTIVATE_TIMEOUT_MS);
  const cancel = () => controller.abort();
  signal?.addEventListener('abort', cancel);
  try {
    const response = await fetch('/api/hub/activate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device: deviceId, app: bundleId }),
      signal: controller.signal,
    });
    const result = await response.json().catch(() => ({}));
    if (response.ok) {
      if (result.ready !== false) return { ready: true };
      return { ready: false, hint: t(result.kind === 'device' ? 'App 没有响应, 设备可能已锁屏, 解锁后自动连接' : 'App 没有响应, 可能还在启动') };
    }
    const known = LAUNCH_FAILURES[result.reason];
    return { failure: known ? t(known) : t('启动失败: {0}', result.error || response.status) };
  } catch (e) {
    if (signal?.aborted) return { cancelled: true };
    if (controller.signal.aborted) return { failure: t(LAUNCH_FAILURES.timeout) };
    // 请求本身失败(如 LayerLens 正在重启)时仍切换, 由页面提示连接状态
    return {};
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', cancel);
  }
}

// 进行中的切换 { deviceId, bundleId, controller, timer, action }: 以最后一次点击为准
let pendingSwitch = null;

function cancelSwitch() {
  const job = pendingSwitch;
  if (!job) return null;
  pendingSwitch = null;
  clearTimeout(job.timer);
  job.controller.abort();
  hideToast();
  renderTargetMenu();
  return job;
}

// 页面已先切到目标 App, 激活在短暂去抖后异步完成. 旧任务的结果不会再修改当前页面.
function activateSelectedAppLater(deviceId, bundleId, appName) {
  const job = { deviceId, bundleId, controller: new AbortController(), timer: 0, action: 'switch' };
  pendingSwitch = job;
  renderTargetMenu();
  job.timer = setTimeout(async () => {
    job.timer = 0;
    const result = await activateApp(deviceId, bundleId, job.controller.signal);
    if (pendingSwitch !== job) return;
    const selected = () => targets.deviceId === deviceId && targets.bundleId === bundleId;
    if (result.failure) {
      if (selected()) {
        try {
          sessionStorage.setItem(STAY_OFFLINE_KEY, deviceId + '|' + bundleId);
        } catch (e) {
          // 不可用时照常跟随前台 App
        }
        setAppState('offline');
      }
      toast(t('{0}. 显示的是保存在本机的日志和抓包', result.failure.replace(/[.。]$/, '')), true, true);
    } else if (result.hint) {
      if (selected()) setAppState('background');
      toast(result.hint, true, true);
    } else if (selected()) {
      // waitForApp 已确认新端口可用; 更新一次列表后再取层级, 避免连到挂起前的旧端口
      try {
        await loadTargets();
      } catch (e) {
        // 事件流仍会自动重连
      }
      if (pendingSwitch !== job || !selected()) return;
      appState.instanceId = currentApp()?.instanceId || '';
      appState.warning = compatibilityWarning(currentApp());
      setAppState('online');
      loadAppInfo();
      if (state.mode !== 'live') refresh();
    }
    if (pendingSwitch !== job) return;
    pendingSwitch = null;
    renderTargetMenu();
    syncOfflineView();
  }, ACTIVATE_DEBOUNCE_MS);
}

// 切换设备会重新加载页面, 提示存到加载后再显示
const PENDING_TOAST_KEY = 'layerlens_pending_toast';

function showPendingToast() {
  try {
    const message = sessionStorage.getItem(PENDING_TOAST_KEY);
    sessionStorage.removeItem(PENDING_TOAST_KEY);
    if (message) toast(message, true, true);
  } catch (e) {
    // 不可用时没有提示
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

const targetMenuUi = { offlineOpen: false };

// 设备扫描和历史字典都不保证顺序; 使用稳定字段排序, 避免每次刷新菜单来回跳
function compareTargetText(a, b) {
  return String(a || '').localeCompare(String(b || ''), undefined, { numeric: true, sensitivity: 'base' });
}

function compareTargetDevices(a, b) {
  return compareTargetText(a.name, b.name) || compareTargetText(a.model, b.model) || compareTargetText(a.id, b.id);
}

function compareTargetApps(a, b) {
  return compareTargetText(a.appName || a.bundleId, b.appName || b.bundleId) || compareTargetText(a.bundleId, b.bundleId);
}

// 顶栏按钮中应用名后显示所在设备, 同一 App 同时运行在模拟器和真机上时能区分; 只选了设备时名称已是设备名, 不重复
function renderTargetLabel() {
  // 未启动的模拟器在模拟器列表中, 历史里可能只有占位记录
  const device = currentDevice() || (targets.simulators || []).find((sim) => sim.id === targets.deviceId);
  const entry = targetHistory[targets.deviceId];
  const name = device?.name || entry?.name || '';
  const kind = device?.kind || entry?.kind || (device ? 'simulator' : '');
  $('targetLabel').hidden = !targets.bundleId || !name;
  $('targetLabelName').textContent = name;
  // 「模拟器」的英文译文是分组标题用的复数, 这里单独处理
  $('targetLabelKind').textContent = kind === 'simulator' ? (LANG === 'en' ? 'Simulator' : '模拟器') : kind ? t('真机') : '';
  $('targetLabelKind').hidden = !kind;
  const model = device?.model || entry?.model || '';
  $('targetLabel').title = [name, model !== name ? model : '', device?.os || entry?.os || ''].filter(Boolean).join(' · ');
}

function renderTargetMenu() {
  const menu = $('targetMenu');
  const children = [];
  const background = appState.value === 'background';
  recordTargetHistory();
  renderTargetLabel();
  // 按类型分组: 模拟器(已启动在前, 未启动的灰色显示在后), 真机; 已断开的历史设备排在各组最后
  const simulators = targets.devices.filter((d) => d.kind === 'simulator').sort(compareTargetDevices);
  const offline = targets.simulators || [];
  const devices = targets.devices.filter((d) => d.kind !== 'simulator');
  // 关闭的模拟器在「未启动」中显示, 其历史 App 合并到那里
  const goneDevices = Object.values(targetHistory).filter((entry) => !targets.devices.some((d) => d.id === entry.id) && !offline.some((sim) => sim.id === entry.id));
  const goneSimulators = goneDevices.filter((entry) => entry.kind === 'simulator').sort(compareTargetDevices);
  const goneOthers = goneDevices.filter((entry) => entry.kind !== 'simulator');
  if (simulators.length || offline.length || goneSimulators.length) {
    children.push(el('div', 'target-section', t('模拟器')));
    simulators.forEach((device) => children.push(...targetDeviceRows(device, background)));
    goneSimulators.forEach((entry) => children.push(...goneDeviceRows(entry)));
    if (offline.length) {
      // 未启动的模拟器默认折叠, 有正在启动的或选中的模拟器已关闭时保持展开
      const open = targetMenuUi.offlineOpen || offline.some((sim) => simPending.has(sim.id) || sim.id === targets.deviceId);
      const toggle = el('button', 'target-fold' + (open ? ' open' : ''));
      toggle.append(icon('chevron'), el('span', null, t('未启动 ({0})', offline.length)));
      toggle.addEventListener('click', () => {
        targetMenuUi.offlineOpen = !open;
        renderTargetMenu();
      });
      children.push(toggle);
      if (open) offline.forEach((sim) => children.push(...[offlineSimulatorRow(sim)].flat()));
    }
  }
  if (devices.length || goneOthers.length) {
    children.push(el('div', 'target-section', t('真机 (USB)')));
    // 在线和历史真机一起排序, 设备短暂断开或恢复时也保持原位置
    const rows = [
      ...devices.map((device) => ({ device, live: true })),
      ...goneOthers.map((device) => ({ device, live: false })),
    ].sort((a, b) => compareTargetDevices(a.device, b.device));
    rows.forEach((item) => children.push(...(item.live ? targetDeviceRows(item.device, background) : goneDeviceRows(item.device))));
  }
  if (children.length === 0) children.push(el('div', 'target-empty', t('没有发现设备')));
  const footer = el('button', 'menu-row menu-action target-footer', t('App 集成…'));
  footer.dataset.panel = 'integration';
  children.push(el('div', 'menu-sep'), footer);
  // 设置使用频率低, 工具栏不放按钮, 从这里打开
  const options = el('button', 'menu-row menu-action target-footer', t('设置…'));
  options.addEventListener('click', () => openPanel('options'));
  children.push(options);
  menu.replaceChildren(...children);
  settleBootLaunch();
  syncOfflineView();
}

// 已启动的设备及其上运行的 App
function targetDeviceRows(device, background) {
  const rows = [];
  // 模拟器可以只选设备, 不连接 App 时也能使用实时画面
  const selectable = device.kind === 'simulator';
  const head = el(selectable ? 'button' : 'div', 'target-device');
  // 真机名称是用户自定义的, 附上机型; 与名称相同(如模拟器)时不重复
  const model = device.model && device.model !== device.name ? device.model : '';
  head.append(el('span', 'status-dot ok'), el('span', 'target-device-name', device.name), el('span', 'target-device-os', [model, device.os].filter(Boolean).join(' · ')));
  if (selectable) {
    head.classList.toggle('current', device.id === targets.deviceId && !targets.bundleId);
    head.title = t('只使用实时画面');
    head.addEventListener('click', () => {
      hidePopovers();
      cancelSwitch();
      if (device.id !== targets.deviceId || targets.bundleId) switchTarget(device.id, '');
    });
    const row = el('div', 'target-device-row');
    row.append(head, simPowerButton(device.id, true));
    rows.push(row);
  } else {
    rows.push(head);
  }
  const apps = [...device.apps, ...historyApps(device.id, device.apps)].sort(compareTargetApps);
  // App 缩进在设备下方, 左侧竖线表示归属
  const group = el('div', 'target-apps');
  rows.push(group);
  if (!apps.length) group.append(el('div', 'target-empty', t('没有运行中的已集成 App')));
  apps.forEach((app) => group.append(targetAppRow(device.id, app, background)));
  return rows;
}

// 已断开的历史设备: 灰色显示, 可从列表移除; 选中的设备不能移除
function goneDeviceRows(entry) {
  const head = el('div', 'target-device offline');
  const model = entry.model && entry.model !== entry.name ? entry.model : '';
  head.append(el('span', 'status-dot'), el('span', 'target-device-name', entry.name), el('span', 'target-device-os', [model, entry.os].filter(Boolean).join(' · ') || t('已断开')));
  if (entry.id !== targets.deviceId) head.appendChild(historyRemoveButton(entry.id, ''));
  const group = el('div', 'target-apps');
  historyApps(entry.id).sort(compareTargetApps).forEach((app) => group.append(targetAppRow(entry.id, app, false)));
  if (!group.childElementCount) {
    const empty = el('div', 'target-empty', t('暂无 App 记录'));
    empty.title = t('连接后运行已集成的 App, 之后断开也能在这里查看');
    group.append(empty);
  }
  return [head, group];
}

function historyRemoveButton(deviceId, bundleId) {
  const button = el('span', 'target-remove');
  button.setAttribute('role', 'button');
  button.title = t('从列表中移除');
  button.appendChild(icon('close'));
  button.addEventListener('click', (e) => {
    e.stopPropagation();
    removeTargetHistory(deviceId, bundleId);
  });
  return button;
}

// 设备下的一个 App. away: 已断开的历史 App; 当前 App 以页面自己的连接状态为准, 挂起后扫描结果可能还保留着记录, 但连接已断开
function targetAppRow(deviceId, app, background) {
  const row = el('button', 'target-app');
  const current = deviceId === targets.deviceId && app.bundleId === targets.bundleId;
  const away = !!app.away || (current && appState.value === 'offline');
  // 当前 App 的事件流连着时以它为准: 进入后台时 App 会主动推送; 列表中的挂起标记可能是前台主线程繁忙导致的超时
  const inBackground = !away && (current && appState.connected ? background : (current && background) || appInBackground(app));
  const live = targets.devices.some((d) => d.id === deviceId);
  const switching = pendingSwitch?.deviceId === deviceId && pendingSwitch.bundleId === app.bundleId;
  row.classList.toggle('current', current);
  row.classList.toggle('background', inBackground);
  row.classList.toggle('away', away);
  row.classList.toggle('switching', switching);
  row.append(el('span', 'status-dot'), el('span', 'target-app-name', app.appName || app.bundleId));
  if (!away && !appCompatible(app)) row.append(el('span', 'target-badge', t('版本不兼容')));
  row.append(el('span', 'target-app-meta', switching ? t(pendingSwitch.action === 'launch' ? '启动中…' : '切换中…') : inBackground ? t('在后台') : away ? t('未连接') : app.version || ''));
  if (away && !current) row.appendChild(historyRemoveButton(deviceId, app.bundleId));
  row.title = !away ? `${app.bundleId} · ${t('端口 {0}', app.port)}` : live ? `${app.bundleId} · ${t('已挂起或退出, 点击启动或切到前台')}` : `${app.bundleId} · ${t('设备未连接, 连上后自动恢复')}`;
  row.addEventListener('click', async () => {
    hidePopovers();
    // 新的点击取代进行中的切换
    const cancelled = cancelSwitch();
    // 未连接的 App 直接切过去显示保存的日志和抓包, 同时尝试启动, 启动后自动连接; 启动失败只提示
    if (away && !current) {
      try {
        sessionStorage.setItem(STAY_OFFLINE_KEY, deviceId + '|' + app.bundleId);
      } catch (e) {
        // 不可用时照常跟随前台 App
      }
      if (deviceId === targets.deviceId && targets.bundleId) {
        switchTargetInPlace(app.bundleId);
        if (live) launchAwayApp(deviceId, app.bundleId, app.appName);
        return;
      }
      // 切换设备会重新加载页面, 加载后再启动
      if (live) {
        try {
          sessionStorage.setItem(PENDING_LAUNCH_KEY, deviceId + '|' + app.bundleId);
        } catch (e) {
          // 不可用时不启动
        }
      }
      switchTarget(deviceId, app.bundleId);
      return;
    }
    // 同一设备切 App 时先更新页面, 再在后台激活; 快速切换只会激活最后停留的 App
    if (live && (inBackground || away || !current)) {
      if (deviceId === targets.deviceId && targets.bundleId) {
        if (!current) switchTargetInPlace(app.bundleId, true, app.appName || app.bundleId);
        else setAppState('background', t('正在切换到 {0}…', app.appName || app.bundleId));
        activateSelectedAppLater(deviceId, app.bundleId, app.appName || app.bundleId);
        return;
      }
      // 跨设备需要重新加载页面, 仍先确认 App 可用, 避免新页面连到旧端口
      // 激活要等 App 响应, 挂起的真机 App 要十几秒; 提示一直显示到结束, 期间可以切到别处
      const job = { deviceId, bundleId: app.bundleId, controller: new AbortController(), action: 'switch' };
      pendingSwitch = job;
      toast(t('正在切换到 {0}…', app.appName || app.bundleId), false, false, true);
      renderTargetMenu();
      const result = await activateApp(deviceId, app.bundleId, job.controller.signal);
      // 已被取消或被新的切换取代
      if (pendingSwitch !== job) return;
      pendingSwitch = null;
      renderTargetMenu();
      const { failure } = result;
      // 启动失败(如设备锁屏)时仍然切过去, 查看 LayerLens 保存的日志和抓包
      const hint = failure ? t('{0}. 显示的是保存在本机的日志和抓包', failure.replace(/[.。]$/, '')) : result.hint;
      if (failure && !current) {
        try {
          sessionStorage.setItem(STAY_OFFLINE_KEY, deviceId + '|' + app.bundleId);
        } catch (e) {
          // 不可用时照常跟随前台 App
        }
      }
      if (hint) toast(hint, true, true);
      else hideToast();
      if (hint && !current && !(deviceId === targets.deviceId && targets.bundleId)) {
        try {
          sessionStorage.setItem(PENDING_TOAST_KEY, hint);
        } catch (e) {
          // 不可用时没有提示
        }
      }
    }
    // 当前 App 回到前台后由事件流恢复, 不必重新加载; 事件流断开时立即重连, 不等浏览器的重试间隔. 同一设备上换 App 原地切换, 实时画面不中断
    if (current) {
      // 切回已连接的当前 App: 取消的切换在同一设备上时, 启动请求已发出, 那个 App 可能已被拉到前台, 把当前 App 切回前台
      if (cancelled && cancelled.deviceId === deviceId && live && !(inBackground || away)) {
        activateApp(deviceId, app.bundleId);
      }
      if (cancelled) toast(t('已取消切换'));
      if (!appState.connected) watchApp();
      return;
    }
    if (deviceId === targets.deviceId && targets.bundleId) switchTargetInPlace(app.bundleId);
    else switchTarget(deviceId, app.bundleId);
  });
  return row;
}

// 未启动的模拟器: 点名称启动并在启动后选中, 点按钮只启动
function offlineSimulatorRow(sim) {
  const head = el('button', 'target-device offline');
  head.append(el('span', 'status-dot'), el('span', 'target-device-name', sim.name), el('span', 'target-device-os', sim.os));
  head.title = t('启动并选中');
  head.addEventListener('click', () => {
    if (!simPending.has(sim.id)) simulatorAction(sim.id, 'boot', true);
  });
  const row = el('div', 'target-device-row');
  row.append(head, simPowerButton(sim.id, false));
  const apps = historyApps(sim.id).sort(compareTargetApps);
  if (!apps.length) return row;
  const group = el('div', 'target-apps');
  apps.forEach((app) => group.append(targetAppRow(sim.id, app, false)));
  return [row, group];
}

// 跟随模拟器前台 App: 当前 App 进入后台(或已退出)时, 切到同一设备上在前台的另一个已集成 App;
// 前台是未集成的 App(如设置)时保持不动. 旧版 Pod 不上报 foreground, 不参与跟随.
// 事件流连着时以 App 实时推送的状态为准; Mac App 的列表每 2s 扫描一次, 刚切换后可能还是旧状态
const STAY_OFFLINE_KEY = 'layerlens_stay_offline';

// 启动失败后切过去查看保存的记录: 不跟随前台 App 切走, 直到这个 App 运行起来
function stayingOffline() {
  try {
    if (sessionStorage.getItem(STAY_OFFLINE_KEY) !== logTargetKey()) return false;
    if (currentApp() && !currentApp().suspended) {
      sessionStorage.removeItem(STAY_OFFLINE_KEY);
      return false;
    }
    return true;
  } catch (e) {
    return false;
  }
}

// 已切到未连接的 App 后在后台启动它, 期间页面显示保存的记录, 启动后由事件流自动连接
const PENDING_LAUNCH_KEY = 'layerlens_pending_launch';

function launchAwayApp(deviceId, bundleId, appName) {
  const job = { deviceId, bundleId, controller: new AbortController(), timer: 0, action: 'launch' };
  pendingSwitch = job;
  renderTargetMenu();
  syncOfflineView();
  job.timer = setTimeout(async () => {
    job.timer = 0;
    const { failure, hint } = await activateApp(deviceId, bundleId, job.controller.signal);
    if (pendingSwitch !== job) return;
    pendingSwitch = null;
    renderTargetMenu();
    syncOfflineView();
    if (failure) toast(t('{0}. 显示的是保存在本机的日志和抓包', failure.replace(/[.。]$/, '')), true, true);
    else if (hint) toast(hint, true, true);
  }, ACTIVATE_DEBOUNCE_MS);
}

function resumePendingLaunch() {
  let key = null;
  try {
    key = sessionStorage.getItem(PENDING_LAUNCH_KEY);
    sessionStorage.removeItem(PENDING_LAUNCH_KEY);
  } catch (e) {
    return;
  }
  const params = new URLSearchParams(location.search);
  const deviceId = params.get('device');
  const bundleId = params.get('app');
  if (!key || !deviceId || !bundleId || key !== deviceId + '|' + bundleId) return;
  launchAwayApp(deviceId, bundleId, targetHistory[deviceId]?.apps?.[bundleId]?.appName);
}

function currentAppAway() {
  if (!currentDevice() || !targets.bundleId || stayingOffline()) return false;
  // 正在把当前选择拉到前台时不要自动跟随仍在前台的旧 App
  if (pendingSwitch?.deviceId === targets.deviceId && pendingSwitch.bundleId === targets.bundleId) return false;
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
function rememberTarget(deviceId, bundleId) {
  try {
    localStorage.setItem(TARGET_KEY, JSON.stringify({ deviceId, bundleId }));
  } catch (e) {
    // 不可用时只依赖地址参数
  }
  history.replaceState(null, '', '?' + new URLSearchParams({ device: deviceId, app: bundleId }).toString());
}

function switchTargetInPlace(bundleId, activating = false, appName = '') {
  rememberTarget(targets.deviceId, bundleId);
  targets.bundleId = bundleId;
  ++appInfoSeq;
  renderTargetLabel();
  clearTimeout(appState.offlineTimer);
  appState.offlineTimer = 0;
  appState.dropped = false;
  appState.connected = false;
  const app = currentApp();
  appState.instanceId = app?.instanceId || '';
  appState.warning = compatibilityWarning(app);
  // 切到未运行的 App(如启动失败后查看保存的记录)时直接显示离线, 不提示加载失败
  appState.blank = !app;
  setAppState(app ? (activating ? 'background' : 'online') : 'offline', activating ? t('正在切换到 {0}…', appName || app?.appName || bundleId) : '');
  watchApp();
  if (activating) {
    $('appName').textContent = appName || app?.appName || bundleId;
    appInfo.name = appName || app?.appName || bundleId;
    appInfo.base = '';
    updateAppMeta();
  } else {
    loadAppInfo();
  }
  clearHierarchy();
  if (!activating && state.mode !== 'live') refresh();
}

function connectAppInPlace(bundleId) {
  $('emptyState').hidden = true;
  document.body.classList.remove('has-empty');
  document.body.classList.add('has-app');
  switchTargetInPlace(bundleId);
}

// 设备启动或 App 启动时原地连接, 不整页重新加载(页面会闪一下), 实时画面不中断;
// 切换设备只发生在默认页(没有设备)上, 此时没有连接中的 App
async function connectInPlace(deviceId, bundleId) {
  targets.idle = false;
  targets.hadDevice = true;
  if (deviceId !== targets.deviceId) {
    targets.deviceId = deviceId;
    targets.bundleId = '';
    renderTargetMenu();
    await syncLive();
  }
  if (bundleId && bundleId !== targets.bundleId) {
    connectAppInPlace(bundleId);
    return;
  }
  // 已选的 App 未运行时等事件流连上, 由 reconnected 原地更新
  if (targets.bundleId) return;
  rememberTarget(deviceId, '');
  $('appName').textContent = currentDevice()?.name || t('未连接');
  if (currentDevice()?.kind === 'simulator' && liveAvailable()) setMode('live');
  const body = liveAvailable() ? t('运行集成了 LayerLens 的 App 后会自动连接, 也可以切换到实时查看模拟器画面') : t('运行集成了 LayerLens 的 App 后会自动连接');
  showEmptyState(t('没有运行中的已集成 App'), body);
  setAppState('offline', t('没有运行中的已集成 App'), { text: t('查看集成说明'), panel: 'integration' });
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
// 接口在 App 主线程执行, 前台时主线程繁忙(取层级、截图、加载视频)也会超时; 连续多次超时才视为挂起
const PROBE_MISS_LIMIT = 3;

async function probeCurrentBackground() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 800);
  try {
    const res = await fetch(targetBase() + '/api/app', { cache: 'no-store', signal: controller.signal });
    appState.probeMisses = 0;
    return appInBackground(await res.json());
  } catch (e) {
    appState.probeMisses = (appState.probeMisses || 0) + 1;
    return appState.probeMisses >= PROBE_MISS_LIMIT && !!currentApp()?.suspended;
  } finally {
    clearTimeout(timer);
  }
}

// 当前 App 不在前台时查找前台 App: 先看 Mac App 的列表, 没有再直接询问各 App; 每 400ms 一次, 约 6s 后交给定时刷新
const foregroundCheck = { running: false };

async function checkForeground() {
  if (!pageActivity.active || foregroundCheck.running) return;
  foregroundCheck.running = true;
  try {
    for (let attempt = 0; attempt < 15 && pageActivity.active && currentAppAway(); attempt++) {
      try {
        await loadTargets();
        // 只认直接询问得到的实时状态, 列表中的前台标记可能过期, 会在两个 App 间来回切换
        const next = await probeForeground();
        if (next && pageActivity.active && currentAppAway()) {
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
    const first = defaultDevice();
    return [first.id, firstAppId(first)];
  }
  const device = currentDevice();
  if (device) {
    if (!targets.hadDevice) return [device.id, targets.bundleId || firstAppId(device)];
    if (!targets.bundleId && device.apps.length) return [device.id, firstAppId(device)];
    return null;
  }
  if (targets.deviceId || !targets.devices.length) return null;
  const first = defaultDevice();
  return [first.id, firstAppId(first)];
}

// 定时刷新设备列表, 设备或 App 出现时自动连接
function pollTargets() {
  setTimeout(async () => {
    if (!pageActivity.active) { pollTargets(); return; }
    try {
      await loadTargets();
      if (!pageActivity.active) { pollTargets(); return; }
      renderTargetMenu();
      syncLive();
      // 选中的设备断开或连回时更新提示
      if (appState.value === 'offline' && appState.deviceGone !== currentDeviceGone()) setAppState('offline');
      // 回到前台的通知可能早于事件流连上而错过, 列表里显示已在前台时恢复
      if (appState.value === 'background' && currentApp() && appInForeground(currentApp())) {
        setAppState('online');
        if (state.mode !== 'live') refresh();
      }
      const next = nextTarget();
      if (next) await connectInPlace(...next);
      // 事件流里的后台通知可能丢失(如重连时被覆盖), 列表显示在后台时直接询问当前 App 确认
      if (appState.value === 'online' && currentApp() && appInBackground(currentApp())) {
        if (await probeCurrentBackground()) setAppState('background');
      } else {
        appState.probeMisses = 0;
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
const appState = { value: 'online', connected: false, dropped: false, blank: false, warning: '', instanceId: '', offlineTimer: 0 };
const OFFLINE_GRACE_MS = 4000;

function watchApp() {
  appState.source?.close();
  const key = logTargetKey();
  const source = new LayerLensEventSource(targetBase() + '/api/events');
  appState.source = source;
  const active = () => appState.source === source && logTargetKey() === key;
  source.onopen = () => {
    if (!active()) return;
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
    if (!active()) return;
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
    if (!active()) return;
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
  // 连上过就有层级可看, 之后再离线不再遮住画布
  if (value === 'online') appState.blank = false;
  appState.deviceGone = currentDeviceGone();
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
    offline: currentDeviceGone() ? t('设备已断开, 重新连接后自动恢复') : canRun ? t('App 未运行或在后台') : t('App 未运行或在后台, 启动后会自动连接'),
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
  syncOfflineView();
  renderLaunchSelects();
  renderTargetMenu();
}

// 画布中央的引导, 实时模式下不显示
function showEmptyState(title, body) {
  $('emptyTitle').textContent = title;
  $('emptyBody').textContent = body;
  offlineViewShown = false;
  $('emptyGuide').hidden = true;
  $('emptyIntegration').hidden = false;
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
  $('sandboxBtn').addEventListener('click', openSandbox);
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
    // 小屏的开关表示该面板是否正盖在画布上
    const on = isNarrow() ? document.body.dataset.view === name : !hidden;
    $(name + 'Toggle').classList.toggle('on', on);
    $(name + 'Toggle').setAttribute('aria-pressed', String(on));
  });
  syncLogPanel();
}

function togglePanel(name) {
  if (isNarrow()) {
    toggleView(name);
    return;
  }
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
        } else if (name === 's4') {
          prop = '--log-h';
          value = clamp(box.bottom - ev.clientY, 100, box.height - 160) + 'px';
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
      ['--tree-w', '--detail-w', '--side-w', '--tree-h', '--log-h'].forEach((p) => layout.style.removeProperty(p));
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
  document.body.dataset.view = 'canvas';
  updateAutoPanels();
  new ResizeObserver(updateAutoPanels).observe(layout);
}

// MARK: - Detail

async function loadDetail() {
  if (!pageActivity.active) { pageActivity.pending = true; return; }
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
    if (!pageActivity.active || state.selected !== node.key) return;
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
      // 结果直接显示在开关旁边: 禁用时常驻"已禁用", 手势名划掉
      const status = el('span', 'ev-state');
      const toggle = el('span', 'ev-toggle');
      toggle.append(status, box);
      const sync = (message, isError) => {
        item.classList.toggle('disabled', !event.enabled);
        status.textContent = message || (event.enabled ? '' : t('已禁用'));
        status.classList.toggle('error', !!isError);
        status.classList.toggle('on', !isError && event.enabled);
        status.classList.remove('flash');
        void status.offsetWidth;
        clearTimeout(status.timer);
        if (message === undefined) return;
        status.classList.add('flash');
        // 结果显示一会儿后回到常驻状态
        status.timer = setTimeout(() => sync(), isError ? 3000 : 1500);
      };
      sync();
      // 旧版 Pod 不返回手势的 oid, 只读展示; 不用 disabled 以免变灰看不清
      if (event.oid) box.addEventListener('change', () => setGestureEnabled(event, box, sync));
      else box.classList.add('readonly');
      add('Enabled', toggle);
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

async function setGestureEnabled(event, box, sync) {
  try {
    const result = await api('/api/gesture', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ oid: event.oid, enabled: box.checked }),
    });
    event.enabled = !!result.enabled;
    // 部分系统手势(如 _UISystemGestureGateGestureRecognizer)忽略修改
    if (event.enabled !== box.checked) sync(t('系统不允许修改该手势'), true);
    else sync(t(event.enabled ? '已启用' : '已禁用'));
  } catch (e) {
    sync(e.message, true);
  }
  box.checked = !!event.enabled;
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
  if (!pageActivity.active) { pageActivity.pending = true; return; }
  const target = state.classTarget || { oid: node.viewOid || node.oid, name: node.cls };
  const container = $('detail');
  if (!target.oid) {
    container.replaceChildren(el('div', 'empty', t('该节点没有对应的 OC 对象')));
    return;
  }
  container.replaceChildren(el('div', 'empty', t('加载中...')));
  try {
    const info = await api(`/api/class?oid=${target.oid}`);
    if (!pageActivity.active || state.selected !== node.key || state.tab !== 'class') return;
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
  // 选中的是控制器行时类信息就是控制器本身, 不提供返回视图
  if (state.classTarget && !state.vcFocus) {
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
  setTabButtons(tab);
  loadDetail();
}

function setTabButtons(tab) {
  state.tab = tab;
  $('detailTabs').querySelectorAll('button').forEach((b) => b.classList.toggle('active', b.dataset.tab === tab));
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
    case 'l':
      showPaneTab('log');
      return true;
    case 'n':
      showPaneTab('net');
      return true;
    case 'g':
      showPaneTab('git');
      return true;
    case '`':
      showPaneTab('term');
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
    el('h5', null, t('2. 安装并运行')),
    codeBlock('pod install'),
    paragraph(t('以 Debug 配置运行 App 即可, 无需编写代码; Release 包不包含 LayerLens.')),
    el('h5', null, t('3. 确认连接')),
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
    [['L'], '显示 / 隐藏日志面板'],
    [['N'], '显示 / 隐藏网络面板'],
    [['G'], '显示 / 隐藏改动面板'],
    [['`'], '显示 / 隐藏终端'],
    [['⌘', '1–4'], '切换到日志 / 网络 / 改动 / 终端'],
    [['⌘', 'F'], '在当前区域查找: 层级树, 日志, 网络列表或请求详情'],
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
  ['改动', false, [
    [['⌘', '点击'], '多选文件或提交'],
    [['⇧', '点击'], '范围选择'],
    [['空格'], '暂存 / 取消暂存选中文件'],
    [['双击'], '打开文件'],
    [['⌘', '↩'], '提交'],
  ]],
  ['终端', false, [
    [['⌘', 'K'], '清屏'],
    [['中键点击'], '关闭标签'],
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
  const panels = { options: [t('设置'), () => [$('optionsMenu')]], about: [t('关于 LayerLens'), aboutPanel], integration: [t('App 集成'), integrationPanel], shortcuts: [t('快捷键'), shortcutsPanel], heal: [t('修复模拟器触摸'), healPanel], deviceLogs: [t('设备日志文件'), deviceLogsPanel], sandbox: [t('沙盒文件'), sandboxPanel], cache: [t('缓存管理'), cachePanel] };
  const panel = panels[name];
  if (!panel) return;
  state.panel = name;
  hidePopovers();
  hideMenu();
  // 设置的控件一直留在文档中, 换成其他弹窗前先放回隐藏的容器
  $('optionsHolder').appendChild($('optionsMenu'));
  $('modal').classList.toggle('modal-wide', name === 'sandbox');
  $('modal').classList.toggle('modal-narrow', name === 'options');
  if (name !== 'sandbox') sandbox = null;
  if (name !== 'cache') cacheView = null;
  $('modalTitle').textContent = panel[0];
  $('modalBody').replaceChildren(...panel[1]());
  $('modalBody').scrollTop = 0;
  showLayer($('modal'));
}

function closePanel() {
  sandbox = null;
  cacheView = null;
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
  // 设置中的操作执行后关闭弹窗; 打开其他弹窗的由 data-panel 处理
  $('optionsMenu').addEventListener('click', (e) => {
    const action = e.target.closest('.menu-action');
    if (action && !action.dataset.panel && action.id !== 'menuHeal') closePanel();
  });
}

// MARK: - Sandbox
// 沙盒文件: 模拟器的沙盒在本机, 直接在访达打开; 真机通过 App 内的接口浏览, 预览, 下载, 上传和删除

const SANDBOX_PREVIEW_LIMIT = 512 * 1024;
const SANDBOX_UPLOAD_LIMIT = 256 * 1024 * 1024;
const SANDBOX_IMAGE_EXT = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'bmp', 'ico', 'svg', 'tif', 'tiff'];
// 当前打开的沙盒面板, 面板关闭后旧的请求结果不再渲染
let sandbox = null;

async function openSandbox() {
  hidePopovers();
  if (!targets.bundleId) {
    toast(t('请先选择 App'));
    return;
  }
  if (currentDevice()?.kind !== 'simulator') {
    openPanel('sandbox');
    return;
  }
  try {
    const res = await fetch('/api/hub/sandbox/reveal', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device: targets.deviceId, app: targets.bundleId }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    toast(t('已在访达中打开沙盒'));
  } catch (e) {
    toast(t('打开失败: {0}', e.message));
  }
}

function sandboxUrl(api, params) {
  return `${sandbox.base}/api/sandbox/${api}?${new URLSearchParams(params)}`;
}

async function sandboxFetch(api, params, options) {
  const res = await fetch(sandboxUrl(api, params), options);
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    // 旧版 Pod 没有沙盒接口, 路由返回 Not Found; 文件不存在时为 File not found
    const outdated = res.status === 404 && (!data.error || data.error === 'Not Found');
    const message = res.status === 503 ? t('App 未运行, 启动后点刷新重试') : data.error || `HTTP ${res.status}`;
    throw Object.assign(new Error(message), { outdated });
  }
  return res;
}

function sandboxJoin(dir, name) {
  return dir ? `${dir}/${name}` : name;
}

function sandboxPanel() {
  const root = el('div', 'sb');
  const side = el('div', 'sb-side');
  const bar = el('div', 'sb-bar');
  const crumbs = el('div', 'sb-crumbs');
  const actions = el('div', 'sb-actions');
  const button = (name, title, onClick) => {
    const node = el('button', 'icon-btn');
    node.title = t(title);
    node.setAttribute('aria-label', t(title));
    node.appendChild(icon(name));
    node.addEventListener('click', onClick);
    return node;
  };
  const input = el('input');
  input.type = 'file';
  input.multiple = true;
  input.hidden = true;
  input.addEventListener('change', () => {
    sandboxUpload([...input.files]);
    input.value = '';
  });
  actions.append(
    button('upload', '上传到此文件夹', () => input.click()),
    button('download', '下载此文件夹 (zip)', () => sandboxDownload('zip', sandbox.path)),
    button('refresh', '刷新', () => sandboxList(sandbox.path)),
    input,
  );
  bar.append(crumbs, actions);
  const notice = el('div', 'sb-notice');
  notice.hidden = true;
  const list = el('div', 'sb-list');
  list.addEventListener('dragover', (e) => {
    if (!e.dataTransfer.types.includes('Files')) return;
    e.preventDefault();
    list.classList.add('drop');
  });
  list.addEventListener('dragleave', (e) => {
    if (!list.contains(e.relatedTarget)) list.classList.remove('drop');
  });
  list.addEventListener('drop', (e) => {
    e.preventDefault();
    list.classList.remove('drop');
    sandboxUpload([...e.dataTransfer.files]);
  });
  side.append(bar, notice, list);
  const preview = el('div', 'sb-preview');
  root.append(side, preview);

  sandbox = { node: root, base: targetBase(), root: '', path: '', entries: [], selected: '', crumbs, list, notice, preview, token: 0 };
  sandboxShowEmpty(t('选择文件以预览'));
  sandboxList('');
  return [root];
}

// App 集成的 Pod 版本过低时整个面板只显示升级说明
function sandboxShowOutdated(panel) {
  const box = el('div', 'sb-outdated');
  const badge = el('div', 'sb-outdated-icon');
  badge.appendChild(icon('folder'));
  const version = currentApp()?.podVersion;
  const help = el('button', null, t('查看集成说明'));
  help.dataset.panel = 'integration';
  box.append(
    badge,
    el('h4', null, t('App 集成的 LayerLens 版本过低')),
    el('p', null, version ? t('当前为 {0}, 沙盒浏览需要 0.5.0 或更高版本.', version) : t('沙盒浏览需要 LayerLens 0.5.0 或更高版本.')),
    el('p', null, t('更新 Pod 后重新运行 App 即可使用.')),
    help,
  );
  panel.node.replaceChildren(box);
}

async function sandboxList(path) {
  const panel = sandbox;
  panel.list.replaceChildren(el('p', 'sb-empty', t('正在加载…')));
  try {
    const data = await (await sandboxFetch('list', { path })).json();
    if (sandbox !== panel) return;
    panel.root = data.root || '';
    panel.path = data.path || '';
    panel.entries = data.entries || [];
    sandboxRenderCrumbs();
    sandboxRenderList();
  } catch (e) {
    if (sandbox !== panel) return;
    if (e.outdated) sandboxShowOutdated(panel);
    else panel.list.replaceChildren(el('p', 'sb-empty', t('无法读取沙盒: {0}', e.message)));
  }
}

function sandboxRenderCrumbs() {
  const parts = sandbox.path ? sandbox.path.split('/') : [];
  const nodes = [['', t('沙盒')], ...parts.map((name, i) => [parts.slice(0, i + 1).join('/'), name])];
  sandbox.crumbs.replaceChildren(...nodes.flatMap(([path, name], i) => {
    const node = el('button', 'sb-crumb', name);
    node.title = name;
    node.disabled = i === nodes.length - 1;
    node.addEventListener('click', () => sandboxList(path));
    return i ? [el('span', 'sb-crumb-sep', '/'), node] : [node];
  }));
  sandbox.crumbs.scrollLeft = sandbox.crumbs.scrollWidth;
}

function sandboxRenderList() {
  const { entries, path } = sandbox;
  const rows = [];
  if (path) {
    const up = el('button', 'sb-row');
    up.append(icon('folder'), el('span', 'sb-name', '..'));
    up.addEventListener('click', () => sandboxList(path.split('/').slice(0, -1).join('/')));
    rows.push(up);
  }
  entries.forEach((entry) => {
    const itemPath = sandboxJoin(path, entry.name);
    const row = el('div', 'sb-row' + (entry.dir ? ' dir' : '') + (sandbox.selected === itemPath ? ' selected' : ''));
    row.tabIndex = 0;
    row.dataset.path = itemPath;
    const meta = entry.dir ? '' : logSize(entry.size);
    row.append(icon(entry.dir ? 'folder' : 'file'), el('span', 'sb-name', entry.name + (entry.link ? ' →' : '')), el('span', 'sb-meta', meta));
    row.title = `${entry.name}\n${logFullTime(entry.modified).slice(0, 19)}`;
    const tools = el('span', 'sb-tools');
    const download = el('button', 'icon-btn');
    download.title = entry.dir ? t('下载 (zip)') : t('下载');
    download.appendChild(icon('download'));
    download.addEventListener('click', (e) => {
      e.stopPropagation();
      sandboxDownload(entry.dir ? 'zip' : 'file', itemPath);
    });
    tools.append(download, sandboxDeleteButton(itemPath));
    row.appendChild(tools);
    row.addEventListener('click', () => (entry.dir ? sandboxList(itemPath) : sandboxPreview(entry, itemPath)));
    row.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') row.click();
    });
    rows.push(row);
  });
  if (!entries.length) rows.push(el('p', 'sb-empty', t('空文件夹, 可拖入文件上传')));
  sandbox.list.replaceChildren(...rows);
}

// 删除不可撤销, 先在气泡中确认
function sandboxDeleteButton(path, withText) {
  const node = el('button', withText ? 'sb-delete' : 'icon-btn sb-delete');
  node.replaceChildren(icon('trash'));
  if (withText) node.append(t('删除'));
  node.title = t('删除');
  node.addEventListener('click', (e) => {
    e.stopPropagation();
    showConfirm(node, { title: t('删除这个文件?'), detail: t('会从 App 沙盒中删除, 此操作不可撤销'), items: [path], action: t('删除'), onConfirm: () => sandboxDelete(path) });
  });
  return node;
}

async function sandboxDelete(path) {
  const panel = sandbox;
  try {
    await sandboxFetch('delete', {}, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ path }) });
    if (sandbox !== panel) return;
    toast(t('已删除 {0}', path.split('/').pop()));
    if (panel.selected === path || panel.selected.startsWith(path + '/')) {
      panel.selected = '';
      sandboxShowEmpty(t('选择文件以预览'));
    }
    sandboxList(panel.path);
  } catch (e) {
    toast(t('删除失败: {0}', e.message), true);
  }
}

function sandboxDownload(api, path) {
  const link = el('a');
  link.href = sandboxUrl(api, api === 'file' ? { path, download: '1' } : { path });
  link.download = '';
  document.body.appendChild(link);
  link.click();
  link.remove();
  toast(t('正在下载…'));
}

// 同名文件先确认覆盖
function sandboxUpload(files) {
  if (!files.length || !sandbox) return;
  const large = files.find((file) => file.size > SANDBOX_UPLOAD_LIMIT);
  if (large) {
    toast(t('{0} 超过 256 MB, 无法上传', large.name), true);
    return;
  }
  const names = new Set(sandbox.entries.map((entry) => entry.name));
  const existing = files.filter((file) => names.has(file.name));
  if (!existing.length) {
    sandboxSend(files);
    return;
  }
  const { notice } = sandbox;
  const ok = el('button', 'primary', t('覆盖'));
  const cancel = el('button', null, t('取消'));
  ok.addEventListener('click', () => {
    notice.hidden = true;
    sandboxSend(files);
  });
  cancel.addEventListener('click', () => (notice.hidden = true));
  const message = existing.length === 1 ? t('{0} 已存在, 是否覆盖?', existing[0].name) : t('{0} 个文件已存在, 是否覆盖?', existing.length);
  notice.replaceChildren(el('span', null, message), cancel, ok);
  notice.hidden = false;
}

async function sandboxSend(files) {
  const panel = sandbox;
  const path = panel.path;
  let done = 0;
  for (const file of files) {
    toast(t('正在上传 {0} ({1}/{2})…', file.name, done + 1, files.length));
    try {
      await sandboxFetch('upload', { path, name: file.name }, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: file });
      done += 1;
    } catch (e) {
      toast(t('上传 {0} 失败: {1}', file.name, e.message), true);
      break;
    }
  }
  if (done === files.length) toast(t('已上传 {0} 个文件', done));
  if (sandbox === panel && panel.path === path) sandboxList(path);
}

function sandboxShowEmpty(message) {
  sandbox.preview.replaceChildren(el('p', 'sb-empty', message));
}

async function sandboxPreview(entry, path) {
  const panel = sandbox;
  const token = ++panel.token;
  panel.selected = path;
  panel.list.querySelectorAll('.sb-row').forEach((row) => row.classList.toggle('selected', row.dataset.path === path));

  const head = el('div', 'sb-preview-head');
  const title = el('div', 'sb-preview-title');
  title.append(el('span', 'sb-preview-name', entry.name), el('span', 'sb-meta', `${logSize(entry.size)} · ${logFullTime(entry.modified).slice(0, 19)}`));
  const tools = el('div', 'sb-preview-tools');
  const copy = el('button', 'sb-text-btn');
  copy.append(icon('copy'), t('复制路径'));
  copy.addEventListener('click', () => copyText(sandboxJoin(panel.root, path), '复制路径'));
  const download = el('button', 'sb-text-btn');
  download.append(icon('download'), t('下载'));
  download.addEventListener('click', () => sandboxDownload('file', path));
  tools.append(copy, download, sandboxDeleteButton(path, true));
  head.append(title, tools);
  const body = el('div', 'sb-preview-body');
  body.appendChild(el('p', 'sb-empty', t('正在加载…')));
  panel.preview.replaceChildren(head, body);

  const current = () => sandbox === panel && panel.token === token;
  const ext = entry.name.split('.').pop().toLowerCase();
  try {
    if (SANDBOX_IMAGE_EXT.includes(ext)) {
      const img = el('img', 'sb-image');
      img.src = sandboxUrl('file', { path });
      img.onerror = () => current() && body.replaceChildren(el('p', 'sb-empty', t('无法预览此图片')));
      body.replaceChildren(img);
      return;
    }
    const res = await sandboxFetch('file', { path, limit: SANDBOX_PREVIEW_LIMIT });
    const bytes = new Uint8Array(await res.arrayBuffer());
    if (!current()) return;
    const total = Number(res.headers.get('X-Total-Size')) || bytes.length;
    const magic = new TextDecoder().decode(bytes.slice(0, 16));
    if (magic.startsWith('SQLite format 3')) {
      sandboxDatabase(body, path, current);
      return;
    }
    if (magic.startsWith('bplist')) {
      const data = await (await sandboxFetch('plist', { path })).json();
      if (current()) body.replaceChildren(sandboxCode(JSON.stringify(data.value, null, 2)));
      return;
    }
    const text = sandboxText(bytes);
    if (text === null) {
      body.replaceChildren(el('p', 'sb-note', t('二进制文件, 显示开头 {0} 字节', Math.min(bytes.length, 1024))), sandboxCode(sandboxHex(bytes.slice(0, 1024))));
      return;
    }
    let content = text;
    if (ext === 'json' && total === bytes.length) {
      try {
        content = JSON.stringify(JSON.parse(text), null, 2);
      } catch (e) {
        // 格式不对时按原文显示
      }
    }
    const nodes = [sandboxCode(content)];
    if (total > bytes.length) nodes.unshift(el('p', 'sb-note', t('文件较大, 只显示前 {0}, 完整内容请下载', logSize(bytes.length))));
    body.replaceChildren(...nodes);
  } catch (e) {
    if (current()) body.replaceChildren(el('p', 'sb-empty', t('无法预览: {0}', e.message)));
  }
}

// 含 NUL 或不是 UTF-8 时视为二进制; 截断处可能切开多字节字符, 允许末尾不完整
function sandboxText(bytes) {
  if (bytes.slice(0, 8192).includes(0)) return null;
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes, { stream: true });
  } catch (e) {
    return null;
  }
}

function sandboxHex(bytes) {
  const lines = [];
  for (let i = 0; i < bytes.length; i += 16) {
    const chunk = [...bytes.slice(i, i + 16)];
    const hex = chunk.map((b) => b.toString(16).padStart(2, '0')).join(' ').padEnd(47);
    const ascii = chunk.map((b) => (b >= 32 && b < 127 ? String.fromCharCode(b) : '.')).join('');
    lines.push(`${i.toString(16).padStart(8, '0')}  ${hex}  ${ascii}`);
  }
  return lines.join('\n');
}

function sandboxCode(text) {
  return el('pre', 'sb-code', text);
}

async function sandboxDatabase(body, path, current) {
  const data = await (await sandboxFetch('sqlite', { path })).json();
  if (!current()) return;
  const tables = data.tables || [];
  if (!tables.length) {
    body.replaceChildren(el('p', 'sb-empty', t('数据库中没有表')));
    return;
  }
  const bar = el('div', 'sb-db-bar');
  const select = el('select', 'sb-db-select');
  tables.forEach((table) => {
    const option = el('option', null, `${table.name} (${table.count})`);
    option.value = table.name;
    select.appendChild(option);
  });
  const pager = el('span', 'sb-db-pager');
  const grid = el('div', 'sb-db-grid');
  bar.append(select, pager);
  body.replaceChildren(bar, grid);

  const pageSize = 100;
  const load = async (offset) => {
    const table = select.value;
    grid.replaceChildren(el('p', 'sb-empty', t('正在加载…')));
    try {
      const result = await (await sandboxFetch('sqlite', { path, table, offset, limit: pageSize })).json();
      if (!current() || select.value !== table) return;
      const tableNode = el('table', 'sb-table');
      const headRow = el('tr');
      result.columns.forEach((name) => headRow.appendChild(el('th', null, name)));
      tableNode.appendChild(el('thead')).appendChild(headRow);
      const tbody = tableNode.appendChild(el('tbody'));
      result.rows.forEach((row) => {
        const tr = tbody.appendChild(el('tr'));
        row.forEach((value) => {
          const td = tr.appendChild(el('td', value === null ? 'null' : null, value === null ? 'NULL' : String(value)));
          td.title = td.textContent;
        });
      });
      grid.replaceChildren(result.rows.length ? tableNode : el('p', 'sb-empty', t('表中没有数据')));
      const prev = el('button', 'sb-text-btn', '‹');
      const next = el('button', 'sb-text-btn', '›');
      prev.disabled = offset <= 0;
      next.disabled = offset + pageSize >= result.total;
      prev.addEventListener('click', () => load(Math.max(0, offset - pageSize)));
      next.addEventListener('click', () => load(offset + pageSize));
      const end = Math.min(offset + result.rows.length, result.total);
      pager.replaceChildren(prev, el('span', null, result.total ? `${offset + 1}-${end} / ${result.total}` : '0'), next);
    } catch (e) {
      if (current()) grid.replaceChildren(el('p', 'sb-empty', t('查询失败: {0}', e.message)));
    }
  };
  select.addEventListener('change', () => load(0));
  load(0);
}

// MARK: - Logs
// 日志面板: 只在打开时连接 Hub 的日志流, 关闭即断开并释放; 列表只渲染可见区域

const LOG_MAX_LINES = 100000;
const LOG_OVERSCAN = 10;
// 单条日志渲染的字符上限, 完整内容在详情区和复制中
const LOG_ROW_CHARS = 2000;
const LOG_WRAP_CHARS = 20000;
const LOG_FILE_CHUNK = 1024 * 1024;
const LOG_OPEN_KEY = 'layerlens_log_open';
const LOG_WRAP_KEY = 'layerlens_log_wrap';
const LOG_FONT_KEY = 'layerlens_log_font';
const LOG_FONT_SIZE = { min: 10, max: 20, value: 13 };
// 候选字体, 只列出本机已安装的
const LOG_FONTS = ['SF Mono', 'Menlo', 'Monaco', 'JetBrains Mono', 'Fira Code', 'Source Code Pro', 'Cascadia Code', 'IBM Plex Mono', 'Hack', 'Inconsolata', 'Roboto Mono', 'Courier New', 'PingFang SC', 'Helvetica Neue'];
const LOG_LINE_RE = /^\[(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d{3})\] ?/;

// lines: 全部日志, 按 id 递增; view: 过滤后的日志, 无过滤时与 lines 为同一数组
// anchor / focus: 选中范围两端的 id; heights / offsets: 换行模式下每行的高度与累计偏移
const logs = {
  open: false,
  active: false,
  es: null,
  key: '',
  timer: null,
  source: 'live',
  file: null,
  unsupported: false,
  loading: false,
  nextId: 1,
  lines: [],
  view: [],
  filter: { raw: '', terms: [], regex: null },
  follow: true,
  unseen: false,
  wrap: false,
  anchor: 0,
  focus: 0,
  heights: [],
  offsets: [0],
  charW: 7.2,
  rendered: new Map(),
  renderKey: '',
  rowH: 17,
  font: { family: '', size: LOG_FONT_SIZE.value },
  raf: 0,
};

function logVisible() {
  if (logs.window) return true;
  return isNarrow() ? document.body.dataset.view === 'log' : logs.open;
}

function syncLogPanel() {
  const visible = logVisible();
  document.body.classList.toggle('log-open', !logs.window && !isNarrow() && logs.open);
  if (!logs.open || isNarrow()) setLogMax(false);
  $('logToggle').classList.toggle('on', visible);
  $('logToggle').setAttribute('aria-pressed', String(visible));
  if (visible && !logs.active) {
    logs.active = true;
    if (logs.source === 'live') logResume();
    logs.timer = setInterval(() => {
      if (logTargetKey() !== launchState.key) loadLaunches();
      if (logs.source === 'live' && logTargetKey() !== logs.key) logConnect();
    }, 1000);
    scheduleLogRender();
  } else if (!visible && logs.active) {
    logs.active = false;
    clearInterval(logs.timer);
    logDisconnect();
    // 关闭后释放内存, 下次打开由 Hub 重新补齐
    logs.source = 'live';
    logs.file = null;
    resetLogLines();
  }
  syncNetPanel();
}

function toggleLogPanel() {
  if (isNarrow()) {
    toggleView('log');
    return;
  }
  logs.open = !logs.open;
  try {
    localStorage.setItem(LOG_OPEN_KEY, logs.open ? '1' : '0');
  } catch (e) {
    // 无痕模式等场景下不可用, 忽略
  }
  syncPanels();
}

function logTargetKey() {
  return targets.deviceId && targets.bundleId ? targets.deviceId + '|' + targets.bundleId : '';
}

function logConnect() {
  logDisconnect();
  logs.key = logTargetKey();
  logs.unsupported = false;
  resetLogLines();
  if (!logs.key) return;
  logs.loading = true;
  const query = `device=${encodeURIComponent(targets.deviceId)}&app=${encodeURIComponent(targets.bundleId)}`;
  const es = new LayerLensEventSource(`/api/hub/app-logs/stream?${query}`);
  const parse = (e) => {
    try {
      return JSON.parse(e.data) || {};
    } catch (err) {
      return {};
    }
  };
  // 连接或重连时 Hub 先发 reset 再补发内存中的日志
  es.addEventListener('reset', (e) => {
    logs.unsupported = !!parse(e).unsupported;
    logs.loading = false;
    resetLogLines();
    // App 重新启动后以前的启动多了一次
    loadLaunches();
  });
  es.addEventListener('status', (e) => {
    logs.unsupported = !!parse(e).unsupported;
    scheduleLogRender();
  });
  es.addEventListener('logs', (e) => {
    const entries = parse(e).entries || [];
    appendLogLines(entries.map((entry) => ({ id: logs.nextId++, t: entry.t, m: entry.k ? '' : String(entry.m ?? ''), k: entry.k })));
  });
  logs.es = es;
}

function logDisconnect() {
  logs.es?.close();
  logs.es = null;
  logs.key = '';
  logs.loading = false;
}

function resetLogLines() {
  logs.lines = [];
  // 重连或清空后保留过滤条件
  logs.view = logFilterActive() ? [] : logs.lines;
  logs.anchor = logs.focus = 0;
  logs.follow = logs.source === 'live';
  logs.unseen = false;
  rebuildLogHeights();
  $('logList').scrollTop = 0;
  scheduleLogRender();
}

function appendLogLines(lines) {
  if (!lines.length) return;
  logs.lines.push(...lines);
  if (logs.view !== logs.lines) {
    lines.forEach((line) => {
      if (logMatches(line)) logs.view.push(line);
    });
  }
  if (logs.wrap) {
    for (let i = logs.heights.length; i < logs.view.length; i++) pushLogHeight(logs.view[i]);
  }
  if (logs.lines.length > LOG_MAX_LINES) trimLogLines();
  if (!logs.follow) logs.unseen = true;
  scheduleLogRender();
}

// 超出上限时一次删掉最早的 10%, 避免每条都整体移动数组
function trimLogLines() {
  const remove = logs.lines.length - Math.floor(LOG_MAX_LINES * 0.9);
  const firstId = logs.lines[remove].id;
  logs.lines.splice(0, remove);
  const removed = logs.view === logs.lines ? remove : logIndexOf(logs.view, firstId);
  if (logs.view !== logs.lines) logs.view.splice(0, removed);
  const removedH = logs.wrap ? logs.offsets[removed] : removed * logs.rowH;
  if (logs.wrap) {
    logs.heights.splice(0, removed);
    rebuildLogOffsets();
  }
  if (!logs.follow) $('logList').scrollTop -= removedH;
}

// 有序数组中第一个 id >= 给定值的下标
function logIndexOf(list, id) {
  let lo = 0;
  let hi = list.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (list[mid].id < id) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

function logLineById(id) {
  const line = logs.lines[logIndexOf(logs.lines, id)];
  return line?.id === id ? line : null;
}

// MARK: Filter

// 多个关键词用 | 分隔, 匹配任意一个即显示; 以 \ 开头时整体按正则匹配
function parseLogFilter(raw) {
  const filter = { raw, terms: [], regex: null, invalid: false };
  if (raw.startsWith('\\')) {
    try {
      if (raw.length > 1) filter.regex = new RegExp(raw.slice(1), 'gi');
    } catch (e) {
      filter.invalid = true;
    }
    return filter;
  }
  filter.terms = [...new Set(raw.split('|').map((s) => s.trim().toLowerCase()).filter(Boolean))];
  return filter;
}

function logFilterActive() {
  return !!(logs.filter.regex || logs.filter.terms.length);
}

function logMatches(line) {
  const { terms, regex } = logs.filter;
  // 重启标记始终显示, 便于看出日志属于哪次运行
  if (line.k) return true;
  if (regex) {
    regex.lastIndex = 0;
    return regex.test(line.m);
  }
  if (!terms.length) return true;
  const text = line.m.toLowerCase();
  return terms.some((term) => text.includes(term));
}

function applyLogFilter(raw) {
  logs.filter = parseLogFilter(raw);
  $('logSearch').classList.toggle('invalid', logs.filter.invalid);
  logs.view = logFilterActive() ? logs.lines.filter(logMatches) : logs.lines;
  rebuildLogHeights();
  // 切换过滤后保持选中行可见, 便于在上下文中查看
  if (logs.focus && !logs.follow) scrollLogTo(logs.focus, true);
  else if (logs.follow) logs.pendingBottom = true;
  scheduleLogRender();
}

function logHighlight(text) {
  const { terms, regex } = logs.filter;
  const ranges = [];
  if (regex) {
    regex.lastIndex = 0;
    for (let match = regex.exec(text); match && ranges.length < 500; match = regex.exec(text)) {
      if (!match[0].length) {
        regex.lastIndex++;
        continue;
      }
      ranges.push([match.index, match.index + match[0].length, 0]);
    }
  } else if (terms.length) {
    const lower = text.toLowerCase();
    terms.forEach((term, i) => {
      for (let at = lower.indexOf(term); at >= 0 && ranges.length < 500; at = lower.indexOf(term, at + term.length)) {
        ranges.push([at, at + term.length, i % 5]);
      }
    });
    ranges.sort((a, b) => a[0] - b[0]);
  }
  let html = '';
  let pos = 0;
  ranges.forEach(([start, end, color]) => {
    if (start < pos) return;
    html += escapeLog(text.slice(pos, start)) + `<mark class="hl${color + 1}">${escapeLog(text.slice(start, end))}</mark>`;
    pos = end;
  });
  return html + escapeLog(text.slice(pos));
}

function escapeLog(text) {
  return text.replace(/[&<>]/g, (c) => (c === '&' ? '&amp;' : c === '<' ? '&lt;' : '&gt;'));
}

// MARK: Render

const logPad = (v, n = 2) => String(v).padStart(n, '0');

function logTime(t) {
  if (!t) return '';
  const d = new Date(t);
  return `${logPad(d.getHours())}:${logPad(d.getMinutes())}:${logPad(d.getSeconds())}.${logPad(d.getMilliseconds(), 3)}`;
}

function logFullTime(t) {
  if (!t) return '';
  const d = new Date(t);
  return `${d.getFullYear()}-${logPad(d.getMonth() + 1)}-${logPad(d.getDate())} ${logTime(t)}`;
}

function logLineText(line) {
  return line.t ? `[${logFullTime(line.t)}] ${line.m}` : line.m;
}

// 按等宽字符估算换行后的行数, 中日韩字符按两个字符宽; 渲染后再按实际高度校正
function pushLogHeight(line) {
  const cols = logs.cols || 80;
  let rows = 0;
  const text = line.k ? '' : line.m.slice(0, LOG_WRAP_CHARS);
  text.split('\n').forEach((part) => {
    const wide = part.length > 2000 ? 0 : (part.match(/[^\x00-\xff]/g) || []).length;
    rows += Math.max(1, Math.ceil((part.length + wide) / cols));
  });
  const h = rows * logs.rowH;
  logs.heights.push(h);
  logs.offsets.push(logs.offsets[logs.offsets.length - 1] + h);
}

function rebuildLogHeights() {
  logs.heights = [];
  logs.offsets = [0];
  if (!logs.wrap) return;
  const list = $('logList');
  logs.cols = Math.max(10, Math.floor((list.clientWidth - 16 - 10) / logs.charW) - 12);
  logs.view.forEach(pushLogHeight);
}

function rebuildLogOffsets(from = 0) {
  logs.offsets.length = from + 1;
  for (let i = from; i < logs.heights.length; i++) logs.offsets.push(logs.offsets[i] + logs.heights[i]);
}

function logOffset(index) {
  return logs.wrap ? logs.offsets[Math.min(index, logs.offsets.length - 1)] : index * logs.rowH;
}

function logIndexAt(y) {
  if (!logs.wrap) return Math.floor(y / logs.rowH);
  let lo = 0;
  let hi = logs.heights.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (logs.offsets[mid + 1] <= y) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

function scheduleLogRender() {
  if (!logs.raf) logs.raf = requestAnimationFrame(renderLogs);
}

function renderLogs() {
  logs.raf = 0;
  if (!logs.active) return;
  const list = $('logList');
  const view = logs.view;
  $('logSpacer').style.height = logOffset(view.length) + 'px';
  if (logs.follow || logs.pendingBottom) {
    list.scrollTop = list.scrollHeight;
    logs.pendingBottom = false;
  }
  const top = list.scrollTop;
  // 上下各多渲染一屏, 快速滚动时不露出空白
  const overscan = Math.max(LOG_OVERSCAN, Math.ceil(list.clientHeight / logs.rowH));
  const start = Math.max(0, logIndexAt(top) - overscan);
  const end = Math.min(view.length, logIndexAt(top + list.clientHeight) + overscan + 1);
  const [selA, selB] = [Math.min(logs.anchor, logs.focus), Math.max(logs.anchor, logs.focus)];
  // 影响行内容的状态变化时整体重建; 否则只增删进出渲染区域的行, 已有的行不重绘, 滚动时不闪烁
  const key = [logs.filter.raw, logs.wrap, logs.focus ? selA : 0, logs.focus ? selB : 0].join('|');
  const rows = $('logRows');
  if (key !== logs.renderKey) {
    rows.replaceChildren();
    logs.rendered.clear();
    logs.renderKey = key;
  }
  const keep = new Set();
  const fragment = document.createDocumentFragment();
  for (let i = start; i < end; i++) {
    const line = view[i];
    keep.add(line.id);
    let row = logs.rendered.get(line.id);
    if (!row) {
      row = logRow(line, logs.focus && line.id >= selA && line.id <= selB);
      logs.rendered.set(line.id, row);
      fragment.appendChild(row);
    }
    const y = logOffset(i) + 'px';
    if (row.style.top !== y) row.style.top = y;
    // 斑马纹按在过滤结果中的位置交替, 增删行后随位置更新
    row.classList.toggle('odd', i % 2 === 1);
  }
  logs.rendered.forEach((row, id) => {
    if (keep.has(id)) return;
    row.remove();
    logs.rendered.delete(id);
  });
  rows.appendChild(fragment);
  if (logs.wrap) measureLogRows(start, end, top);
  renderLogStatus();
}

function logRow(line, selected) {
  let msg;
  if (line.k) {
    msg = escapeLog('—— ' + t('App 已重新启动') + ' ——');
  } else if (logs.wrap) {
    msg = logHighlight(line.m.length > LOG_WRAP_CHARS ? line.m.slice(0, LOG_WRAP_CHARS) + '…' : line.m);
  } else {
    // 单行模式下换行符显示为 ⏎, 行高保持固定
    msg = logHighlight((line.m.length > LOG_ROW_CHARS ? line.m.slice(0, LOG_ROW_CHARS) + '…' : line.m).replace(/\r?\n/g, '⏎'));
  }
  const row = el('div', 'log-row' + (line.k ? ' mark' : '') + (selected ? ' sel' : ''));
  row.dataset.id = line.id;
  row.innerHTML = `<span class="log-time">${logTime(line.t)}</span><span class="log-msg">${msg}</span>`;
  return row;
}

// 换行模式: 用实际高度校正估算值; 视口上方的行变化时同步调整滚动位置, 内容不跳动
function measureLogRows(start, end, top) {
  const view = logs.view;
  let from = -1;
  let above = 0;
  for (let i = start; i < end; i++) {
    const h = logs.rendered.get(view[i].id).offsetHeight;
    if (h && h !== logs.heights[i]) {
      if (logs.offsets[i + 1] <= top) above += h - logs.heights[i];
      logs.heights[i] = h;
      if (from < 0) from = i;
    }
  }
  if (from < 0) return;
  rebuildLogOffsets(from);
  $('logSpacer').style.height = logOffset(view.length) + 'px';
  for (let i = from; i < end; i++) logs.rendered.get(view[i].id).style.top = logOffset(i) + 'px';
  const list = $('logList');
  if (logs.follow) list.scrollTop = list.scrollHeight;
  else if (above) list.scrollTop += above;
}

function renderLogStatus() {
  const total = logs.lines.length;
  const count = $('logCount');
  if (logs.view !== logs.lines) {
    count.replaceChildren(el('span', 'hit', String(logs.view.length)), document.createTextNode(' / ' + total));
  } else {
    count.textContent = total ? String(total) : '';
  }
  const file = logs.file;
  $('logSource').hidden = logs.source === 'live';
  $('logBackLive').textContent = file?.launch ? t('返回当前') : t('返回实时日志');
  // 以前的启动在启动下拉框中已显示时间, 不再重复
  $('logSourceName').hidden = !!file?.launch;
  if (file) $('logSourceName').textContent = file.name + (file.done ? '' : ` · ${Math.round((file.offset / (file.total || 1)) * 100)}%`);
  $('logNew').hidden = logs.follow || !logs.unseen;
  let empty = '';
  if (logs.source === 'live' && !logs.key) empty = t('未连接 App');
  else if (logs.source === 'live' && logs.unsupported) empty = t('App 集成的 LayerLens 版本过低, 升级到 0.4.0 后可查看日志');
  else if (!total) empty = logs.loading || file?.loading ? t('正在加载…') : logs.source === 'live' ? t('暂无日志, App 调用 [LayerLens log:] 后显示在这里') : t('文件中没有日志');
  else if (!logs.view.length) empty = t('没有匹配的日志');
  $('logEmpty').textContent = empty;
  $('logEmpty').hidden = !empty;
  const focus = logs.focus && !logs.wrap ? logLineById(logs.focus) : null;
  const detail = $('logDetail');
  detail.hidden = !focus || !!focus.k;
  if (focus && !focus.k && detail.dataset.id !== String(focus.id)) {
    detail.dataset.id = focus.id;
    detail.replaceChildren(el('span', 'log-time', logFullTime(focus.t)), document.createTextNode(focus.m));
    detail.scrollTop = 0;
  }
}

function scrollLogTo(id, center) {
  const index = logIndexOf(logs.view, id);
  if (index >= logs.view.length) return;
  const list = $('logList');
  const top = logOffset(index);
  const bottom = logOffset(index + 1);
  if (center) list.scrollTop = top - (list.clientHeight - (bottom - top)) / 2;
  else if (top < list.scrollTop) list.scrollTop = top;
  else if (bottom > list.scrollTop + list.clientHeight) list.scrollTop = bottom - list.clientHeight;
}

function scrollLogEdge(bottom) {
  const list = $('logList');
  logs.follow = bottom && logs.source === 'live';
  logs.unseen = false;
  list.scrollTop = bottom ? list.scrollHeight : 0;
  if (bottom) loadLogChunk();
  scheduleLogRender();
}

function setLogWrap(wrap) {
  const list = $('logList');
  const first = logs.view[logIndexAt(list.scrollTop)]?.id;
  logs.wrap = wrap;
  $('logPane').classList.toggle('wrap', wrap);
  $('logWrap').classList.toggle('on', wrap);
  $('logWrap').setAttribute('aria-pressed', String(wrap));
  measureLogChar();
  rebuildLogHeights();
  $('logSpacer').style.height = logOffset(logs.view.length) + 'px';
  if (!logs.follow && first) list.scrollTop = logOffset(logIndexOf(logs.view, first));
  scheduleLogRender();
}

function measureLogChar() {
  const probe = el('span', null, 'M'.repeat(100));
  probe.style.cssText = 'position:absolute;visibility:hidden;white-space:pre';
  $('logList').appendChild(probe);
  logs.charW = probe.getBoundingClientRect().width / 100 || 7.2;
  probe.remove();
}

// MARK: Font

// 用画布比较与后备字体的宽度, 判断字体是否已安装
function installedLogFonts() {
  const context = document.createElement('canvas').getContext('2d');
  const sample = 'mmmmmmmmmmlli1WQ@中文';
  const width = (font) => {
    context.font = `40px ${font}`;
    return context.measureText(sample).width;
  };
  const fallbacks = ['monospace', 'serif', 'sans-serif'].map((name) => [name, width(name)]);
  return LOG_FONTS.filter((family) => fallbacks.some(([name, w]) => width(`"${family}", ${name}`) !== w));
}

function fillLogFontMenu() {
  const select = $('logFont');
  if (select.options.length) return;
  const families = installedLogFonts();
  if (logs.font.family && !families.includes(logs.font.family)) families.push(logs.font.family);
  select.append(el('option', null, t('默认')), ...families.map((family) => {
    const option = el('option', null, family);
    option.value = family;
    option.style.fontFamily = `"${family}"`;
    return option;
  }));
  select.options[0].value = '';
}

// 字号决定行高; 切换后保持当前第一行可见
function applyLogFont(save) {
  const { family, size } = logs.font;
  const list = $('logList');
  const first = logs.view[logIndexAt(list.scrollTop)]?.id;
  const pane = $('logPane');
  logs.rowH = Math.round(size * 1.5);
  // 网络列表与日志共用字体设置, 行距更宽便于逐行对照
  net.rowH = Math.round(size * 2);
  pane.style.setProperty('--log-font', family ? `"${family}", var(--mono)` : 'var(--mono)');
  pane.style.setProperty('--log-size', size + 'px');
  pane.style.setProperty('--log-row-h', logs.rowH + 'px');
  pane.style.setProperty('--net-row-h', net.rowH + 'px');
  $('logSizeLabel').textContent = size;
  $('logSizeDown').disabled = size <= LOG_FONT_SIZE.min;
  $('logSizeUp').disabled = size >= LOG_FONT_SIZE.max;
  measureLogChar();
  rebuildLogHeights();
  $('logSpacer').style.height = logOffset(logs.view.length) + 'px';
  if (!logs.follow && first) list.scrollTop = logOffset(logIndexOf(logs.view, first));
  scheduleLogRender();
  scheduleNetRender();
  if (!save) return;
  try {
    localStorage.setItem(LOG_FONT_KEY, JSON.stringify(logs.font));
  } catch (e) {
    // ignore
  }
}

function setLogFontSize(step) {
  logs.font.size = Math.max(LOG_FONT_SIZE.min, Math.min(LOG_FONT_SIZE.max, logs.font.size + step));
  applyLogFont(true);
}

// MARK: Selection

function selectedLogLines() {
  if (!logs.focus) return [];
  const [a, b] = [Math.min(logs.anchor, logs.focus), Math.max(logs.anchor, logs.focus)];
  return logs.view.slice(logIndexOf(logs.view, a), logIndexOf(logs.view, b + 1)).filter((line) => !line.k);
}

function copyLogSelection() {
  const lines = selectedLogLines();
  if (!lines.length) {
    toast(t('没有选中的日志'));
    return;
  }
  copyText(lines.map(logLineText).join('\n'), '复制');
}

function selectLog(id, extend) {
  logs.focus = id;
  if (!extend || !logs.anchor) logs.anchor = id;
  scheduleLogRender();
}

function moveLogSelection(step, extend) {
  const view = logs.view;
  if (!view.length) return;
  let index = logs.focus ? logIndexOf(view, logs.focus) + step : step > 0 ? 0 : view.length - 1;
  index = Math.max(0, Math.min(view.length - 1, index));
  logs.follow = false;
  selectLog(view[index].id, extend);
  scrollLogTo(view[index].id, false);
}

// MARK: Files

function logSize(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / 1024 / 1024).toFixed(1) + ' MB';
}

// 设备上的日志文件: 先列出文件, 点击后分段加载
function deviceLogsPanel() {
  const list = el('div', 'log-files');
  list.appendChild(el('p', 'log-files-empty', t('正在加载…')));
  fetch(`${targetBase()}/api/logs/files`).then(async (res) => {
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(res.status === 404 ? t('App 集成的 LayerLens 版本过低, 升级到 0.4.0 后可查看日志') : data.error || `HTTP ${res.status}`);
    const files = data.files || [];
    if (!files.length) {
      list.replaceChildren(el('p', 'log-files-empty', t('设备上还没有日志文件')));
      return;
    }
    list.replaceChildren(...files.map((file) => {
      const row = el('button', 'log-file');
      row.append(el('span', 'log-file-name', file.name), el('span', 'log-file-meta', `${logSize(file.size)} · ${logFullTime(file.modified).slice(0, 16)}`));
      row.addEventListener('click', () => {
        closePanel();
        openLogFile(file.name, file.size, (offset, length) => fetch(`${targetBase()}/api/logs/file?name=${encodeURIComponent(file.name)}&offset=${offset}&length=${length}`).then(async (r) => {
          if (!r.ok) throw new Error(`HTTP ${r.status}`);
          return { data: await r.arrayBuffer(), total: Number(r.headers.get('X-Total-Size')) || 0 };
        }));
      });
      return row;
    }));
  }).catch((e) => list.replaceChildren(el('p', 'log-files-empty', t('无法读取设备日志: {0}', e.message))));
  return [list];
}

function openLocalLog(file) {
  if (!file) return;
  openLogFile(file.name, file.size, (offset, length) => file.slice(offset, offset + length).arrayBuffer().then((data) => ({ data, total: file.size })));
}

// read(offset, length) 返回 { data, total }; 滚动接近底部时加载下一段
function openLogFile(name, total, read) {
  if (isNarrow()) setView('log');
  else if (!logs.open) toggleLogPanel();
  logDisconnect();
  logs.source = 'file';
  logs.file = { name, total, read, offset: 0, decoder: new TextDecoder(), rest: '', loading: false, done: false, plain: null };
  resetLogLines();
  loadLogChunk();
}

async function loadLogChunk() {
  const file = logs.file;
  if (!file || file.loading || file.done) return;
  file.loading = true;
  scheduleLogRender();
  try {
    const { data, total } = await file.read(file.offset, LOG_FILE_CHUNK);
    if (logs.file !== file) return;
    file.total = total || file.total;
    file.offset += data.byteLength;
    file.done = !data.byteLength || file.offset >= file.total;
    const parts = (file.rest + file.decoder.decode(data, { stream: !file.done })).split('\n');
    file.rest = file.done ? '' : parts.pop();
    // 文件末尾的换行不算续行
    if (file.done && parts[parts.length - 1] === '') parts.pop();
    appendLogLines(parseLogText(parts, file));
  } catch (e) {
    if (logs.file !== file) return;
    file.done = true;
    toast(t('无法读取日志文件: {0}', e.message), true);
  } finally {
    file.loading = false;
    scheduleLogRender();
  }
  // 内容不足两屏时继续加载; 按计算的内容高度判断, 不依赖还未渲染的 DOM
  const list = $('logList');
  if (logs.file === file && logOffset(logs.view.length) - list.scrollTop <= list.clientHeight * 3) loadLogChunk();
}

// [yyyy-MM-dd HH:mm:ss.SSS] 开头为新的一条, 其余行属于上一条; 没有时间前缀的文件按行显示
function parseLogText(parts, file) {
  const result = [];
  let last = logs.lines[logs.lines.length - 1] || null;
  let changed = false;
  parts.forEach((raw) => {
    const text = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
    const match = LOG_LINE_RE.exec(text);
    if (file.plain === null && text) file.plain = !match;
    if (match && !file.plain) {
      const [, y, mo, d, h, mi, s, ms] = match.map(Number);
      last = { id: logs.nextId++, t: new Date(y, mo - 1, d, h, mi, s, ms).getTime(), m: text.slice(match[0].length) };
      result.push(last);
    } else if (!file.plain && last) {
      last.m += '\n' + text;
      if (!result.includes(last)) changed = true;
    } else if (text || file.plain) {
      last = { id: logs.nextId++, t: 0, m: text };
      result.push(last);
    }
  });
  // 上一段的最后一条有续行时重新渲染并计算高度
  if (changed) {
    logs.renderKey = '';
    if (logs.wrap) rebuildLogHeights();
  }
  return result;
}

// MARK: Actions

async function logAction(action, body) {
  const res = await fetch('/api/hub/app-logs/' + action, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ device: targets.deviceId || '', app: targets.bundleId || '', ...body }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

function exportLogs(lines) {
  hidePopovers();
  const body = lines ? { text: lines.filter((line) => !line.k).map((line) => logLineText(line) + '\n').join('') } : {};
  logAction('export', body).then((data) => toast(t('已导出到 {0}', data.path))).catch((e) => toast(t('导出失败: {0}', e.message), true));
}

function clearLogs() {
  if (logs.source === 'live') {
    // Hub 清空后通过 reset 事件通知所有打开的面板
    logAction('clear').catch((e) => toast(e.message, true));
  } else {
    logs.file = null;
    resetLogLines();
  }
}

// 菜单向下展开, 超出窗口底部时整体上移; 用 offset 尺寸计算, 不受进入动画的缩放影响
function fitLogMenu() {
  const menu = $('logMenu');
  menu.style.top = '';
  if (menu.hidden) return;
  const margin = 8;
  const top = $('logMore').getBoundingClientRect().bottom + 6;
  const overflow = Math.min(top + menu.offsetHeight - (window.innerHeight - margin), top - margin);
  if (overflow > 0) menu.style.top = `calc(100% + 6px - ${overflow}px)`;
}

function setLogMax(max) {
  document.body.classList.toggle('log-max', max);
  const button = $('logMax');
  button.title = max ? t('还原') : t('最大化');
  button.setAttribute('aria-label', button.title);
  button.querySelector('use').setAttribute('href', max ? '#i-minimize' : '#i-maximize');
  scheduleLogRender();
}

// 独立窗口只显示当前 App 的日志, 当前页面的面板随之收起
function openLogWindow() {
  const params = new URLSearchParams({ view: 'logs', device: targets.deviceId || '', app: targets.bundleId || '', tab: net.tab });
  const win = window.open('/?' + params, `layerlens-${net.tab}-${targets.bundleId || ''}`, 'popup,width=1100,height=720');
  if (!win) {
    toast(t('无法打开新窗口, 请允许弹出窗口'), true);
    return;
  }
  if (isNarrow()) setView('canvas');
  else if (logs.open) toggleLogPanel();
}

// 独立窗口停靠回主窗口: 通知打开它的主窗口显示面板并切到同一页, 然后关闭自己.
// 主窗口已刷新时 opener 失效, 再经 BroadcastChannel 通知查看同一 App 的主窗口
const LOG_DOCK_MESSAGE = 'layerlens-dock';

function dockLogWindow() {
  const message = { type: LOG_DOCK_MESSAGE, tab: net.tab, device: targets.deviceId, app: targets.bundleId };
  try {
    window.opener?.postMessage(message, location.origin);
  } catch (e) {
    // 主窗口已关闭
  }
  try {
    const channel = new BroadcastChannel(LOG_DOCK_MESSAGE);
    channel.postMessage(message);
    channel.close();
  } catch (e) {
    // 不支持时只依赖 opener
  }
  window.close();
}

function listenLogDock() {
  if (logs.window) return;
  const receive = (data, fromOpener) => {
    if (data?.type !== LOG_DOCK_MESSAGE) return;
    if (!fromOpener && (data.device !== targets.deviceId || data.app !== targets.bundleId)) return;
    setPaneTab(data.tab);
    if (isNarrow()) setView('log');
    else if (!logs.open) toggleLogPanel();
    window.focus();
  };
  window.addEventListener('message', (e) => {
    if (e.origin === location.origin) receive(e.data, true);
  });
  try {
    new BroadcastChannel(LOG_DOCK_MESSAGE).onmessage = (e) => receive(e.data, false);
  } catch (e) {
    // ignore
  }
}

// 独立的日志窗口: 地址中带着设备与 App, 不加载层级和实时画面
function setupLogsWindow() {
  const params = new URLSearchParams(location.search);
  targets.deviceId = params.get('device') || '';
  targets.bundleId = params.get('app') || '';
  logs.window = true;
  document.body.classList.add('logs-window');
  applyI18n();
  applyTheme(loadTheme(), false);
  setupLogs();
  setupNetwork();
  setupGit();
  setupTerminal();
  setPaneTab(params.get('tab'));
  setupPanels();
  setupInputMemory();
  document.addEventListener('pointerdown', (e) => {
    if (!e.target.closest('.popover-anchor')) hidePopovers();
  });
  document.addEventListener('keydown', (e) => {
    if (handlePaneNumberShortcut(e)) {
      e.preventDefault();
      return;
    }
    if (e.key !== 'Escape' || (e.target instanceof Element && e.target.closest('.xterm'))) return;
    hidePopovers();
    closePanel();
  });
  syncLogPanel();
}

function setupLogs() {
  try {
    logs.open = localStorage.getItem(LOG_OPEN_KEY) === '1';
    logs.wrap = localStorage.getItem(LOG_WRAP_KEY) === '1';
    const font = JSON.parse(localStorage.getItem(LOG_FONT_KEY)) || {};
    logs.font.family = typeof font.family === 'string' ? font.family : '';
    logs.font.size = Math.max(LOG_FONT_SIZE.min, Math.min(LOG_FONT_SIZE.max, Number(font.size) || LOG_FONT_SIZE.value));
  } catch (e) {
    // ignore
  }
  applyLogFont(false);
  setLogWrap(logs.wrap);
  const list = $('logList');
  $('logToggle').addEventListener('click', toggleLogPanel);
  $('logClose').addEventListener('click', toggleLogPanel);
  $('logMax').addEventListener('click', () => setLogMax(!document.body.classList.contains('log-max')));
  $('logPopout').addEventListener('click', openLogWindow);
  $('logDock').addEventListener('click', dockLogWindow);
  listenLogDock();
  let filterTimer = null;
  $('logFilter').addEventListener('input', (e) => {
    clearTimeout(filterTimer);
    filterTimer = setTimeout(() => applyLogFilter(e.target.value), 150);
  });
  $('logWrap').addEventListener('click', () => {
    setLogWrap(!logs.wrap);
    try {
      localStorage.setItem(LOG_WRAP_KEY, logs.wrap ? '1' : '0');
    } catch (e) {
      // ignore
    }
  });
  $('logTop').addEventListener('click', () => scrollLogEdge(false));
  $('logBottom').addEventListener('click', () => scrollLogEdge(true));
  $('logNew').addEventListener('click', () => scrollLogEdge(true));
  $('logClear').addEventListener('click', clearLogs);
  $('logMore').addEventListener('click', () => {
    fillLogFontMenu();
    $('logFont').value = logs.font.family;
    togglePopover('logMenu');
    fitLogMenu();
  });
  $('logFont').addEventListener('change', (e) => {
    logs.font.family = e.target.value;
    applyLogFont(true);
  });
  $('logSizeDown').addEventListener('click', () => setLogFontSize(-1));
  $('logSizeUp').addEventListener('click', () => setLogFontSize(1));
  $('logCopy').addEventListener('click', () => {
    hidePopovers();
    copyLogSelection();
  });
  $('logExportAll').addEventListener('click', () => exportLogs(logs.source === 'live' ? null : logs.lines));
  $('logExportView').addEventListener('click', () => exportLogs(logs.view));
  $('logDeviceFiles').addEventListener('click', () => openPanel('deviceLogs'));
  $('logOpenFile').addEventListener('click', () => {
    hidePopovers();
    $('logFileInput').click();
  });
  $('logFileInput').addEventListener('change', (e) => {
    openLocalLog(e.target.files[0]);
    e.target.value = '';
  });
  $('logReveal').addEventListener('click', () => {
    hidePopovers();
    logAction('reveal').catch((e) => toast(e.message, true));
  });
  $('logBackLive').addEventListener('click', () => {
    if (logs.file?.launch) {
      selectLaunch('');
      return;
    }
    logs.source = 'live';
    logs.file = null;
    logConnect();
  });
  // 用户向上滚动后停止跟随, 回到底部恢复
  list.addEventListener('scroll', () => {
    const atBottom = list.scrollTop + list.clientHeight >= list.scrollHeight - 4;
    if (logs.source === 'live' && atBottom !== logs.follow) {
      logs.follow = atBottom;
      if (atBottom) logs.unseen = false;
    }
    if (logs.file && list.scrollTop + list.clientHeight * 3 >= logOffset(logs.view.length)) loadLogChunk();
    // 滚动事件已与帧对齐, 直接渲染, 不再等下一帧
    cancelAnimationFrame(logs.raf);
    renderLogs();
  });
  list.addEventListener('click', (e) => {
    const row = e.target.closest('.log-row');
    if (!row || window.getSelection().toString()) return;
    const line = logLineById(Number(row.dataset.id));
    if (line) selectLog(line.id, e.shiftKey);
  });
  list.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
      e.preventDefault();
      e.stopPropagation();
      moveLogSelection(e.key === 'ArrowUp' ? -1 : 1, e.shiftKey);
    } else if (e.key === 'c' && (e.metaKey || e.ctrlKey) && !window.getSelection().toString()) {
      e.preventDefault();
      e.stopPropagation();
      copyLogSelection();
    }
  });
  const pane = $('logPane');
  pane.addEventListener('dragover', (e) => {
    if (![...e.dataTransfer.types].includes('Files')) return;
    e.preventDefault();
    pane.classList.add('dragover');
  });
  pane.addEventListener('dragleave', (e) => {
    if (!pane.contains(e.relatedTarget)) pane.classList.remove('dragover');
  });
  pane.addEventListener('drop', (e) => {
    e.preventDefault();
    pane.classList.remove('dragover');
    openLocalLog(e.dataTransfer.files[0]);
  });
  // 宽度变化后换行模式重新估算高度
  let lastWidth = 0;
  new ResizeObserver(() => {
    if (logs.wrap && list.clientWidth !== lastWidth) {
      lastWidth = list.clientWidth;
      rebuildLogHeights();
    }
    scheduleLogRender();
  }).observe(list);
}

// MARK: - Network

const NET_MAX_RECORDS = 5000;
const NET_PREVIEW_LIMIT = 512 * 1024;
const NET_TAB_KEY = 'layerlens_pane_tab';
const NET_DETAIL_W_KEY = 'layerlens_net_detail_w';
// 详情查找框是否打开和查找内容, 重启后恢复
const NET_FIND_KEY = 'layerlens_net_find';
const NET_DETAIL_MIN_W = 280;
const NET_SUPPORT_VERSION = '0.6.0';
// Pod 返回的原因, 显示前翻译
const NET_BODY_MESSAGES = {
  'No content': '没有内容',
  'Content over 5 MB is not saved': '内容超过 5 MB, 未保存',
  'Sent as a stream, content is not available': '以流的方式发送, 无法获取内容',
  'File content is not saved': '文件内容未保存',
  'Removed by cache cleanup': '已被缓存清理删除',
  'Request not found': '请求已不在设备的记录中',
};

// records: id -> 请求的列表字段; list: 全部请求, 按 id 递增; view: 过滤后的请求
// seq: 收到的最大序号, 重连时只补齐之后的变化; pending: 暂停期间收到的变化
const net = {
  tab: 'log',
  rowH: 26,
  active: false,
  es: null,
  key: '',
  timer: null,
  token: 0,
  unsupported: false,
  connecting: false,
  // 抓包开关(Mac 端返回, 旧版 Mac App 为 null); 记录都由 Mac 端保存, offline 表示 App 当前不可访问
  capture: null,
  cached: false,
  offline: false,
  // App 缓冲已满时丢弃的请求数
  dropped: 0,
  // 查看的以前的启动(抓包文件夹名), 空为当前, 由 launches.js 的启动选择设置
  session: '',
  // 未开启抓包时只读查看的当前启动的抓包文件夹名
  archive: '',
  // 为 true 时下次连接从头取请求并合并到当前列表, 不先清空
  resync: false,
  instanceId: '',
  seq: 0,
  records: new Map(),
  list: [],
  view: [],
  paused: false,
  pending: [],
  selected: 0,
  detail: null,
  detailTab: 'response',
  detailToken: 0,
  urlHeadCleanup: null,
  // 内容搜索由 Hub 完成, 见 net-filters.js
  searchSupported: false,
  // 设备据此取消本页面未完成的旧查找
  searchClient: Math.random().toString(36).slice(2),
  // 详情中的 ⌘F 查找
  // row: 查找栏, 只建一次, 切换请求和加载时保留
  find: { open: false, query: '', marks: [], index: -1, row: null },
  follow: true,
  rendered: new Map(),
  renderKey: '',
  raf: 0,
};

function netVisible() {
  return logVisible() && net.tab === 'net';
}

function syncNetPanel() {
  $('logPane').classList.toggle('net', net.tab === 'net');
  $('logPane').dataset.tab = net.tab;
  syncGitPanel();
  syncTermPanel();
  $('paneTabs').querySelectorAll('button').forEach((button) => button.classList.toggle('active', button.dataset.pane === net.tab));
  const visible = netVisible();
  if (visible && !net.active) {
    net.active = true;
    netConnect();
    net.timer = setInterval(() => {
      if (logTargetKey() !== net.key) netConnect();
    }, 1000);
    scheduleNetRender();
  } else if (!visible && net.active) {
    // 记录保留在页面中, 再次打开时只补齐之后的变化
    net.active = false;
    clearInterval(net.timer);
    netDisconnect();
  }
}

function setPaneTab(tab) {
  net.tab = tab === 'net' || tab === 'git' || tab === 'term' ? tab : 'log';
  try {
    localStorage.setItem(NET_TAB_KEY, net.tab);
  } catch (e) {
    // ignore
  }
  if (logs.window) document.title = `${targets.bundleId || 'LayerLens'} · ${t({ net: '网络', git: '改动', term: '终端' }[net.tab] || '日志')}`;
  syncNetPanel();
  if (net.tab === 'log') scheduleLogRender();
}

// 快捷键 L / N: 面板已显示该页时关闭, 否则打开并切到该页
function showPaneTab(tab) {
  const open = logVisible();
  if (open && net.tab === tab) {
    toggleLogPanel();
    return;
  }
  setPaneTab(tab);
  if (!open) toggleLogPanel();
}

// ⌘1–⌘4 与面板页签一一对应; 重复按只保持当前页, 不像 L / N / G / ` 那样关闭面板
function handlePaneNumberShortcut(e) {
  if (!e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return false;
  const tab = { 1: 'log', 2: 'net', 3: 'git', 4: 'term' }[e.key];
  if (!tab) return false;
  setPaneTab(tab);
  if (!logs.window && !logVisible()) toggleLogPanel();
  return true;
}

const NET_RETRY_MS = 2000;

async function netConnect() {
  netDisconnect();
  const key = logTargetKey();
  if (key !== net.key) {
    net.key = key;
    // 面板首次连接时沿用日志面板选中的启动
    syncLaunchTarget();
    net.session = launchNetSession();
    resetNet();
    // 限定 App 的自定义过滤项随 App 切换显示
    renderNetFilterBar();
    syncNetRemote();
  }
  if (!key) {
    net.cached = false;
    net.capture = null;
    syncNetCapture();
    scheduleNetRender();
    return;
  }
  const token = ++net.token;
  net.connecting = true;
  net.unsupported = false;
  net.archive = '';
  scheduleNetRender();
  if (await netOutdated()) {
    if (token !== net.token) return;
    net.unsupported = true;
    net.connecting = false;
    scheduleNetRender();
    return;
  }
  if (token !== net.token) return;
  const launchesLoaded = loadLaunches();
  // 未开启抓包时只读显示这次启动已保存的记录(如中途关闭了抓包); 没有记录时只显示开启按钮
  if (net.capture === false && !net.session) {
    await launchesLoaded;
    if (token !== net.token) return;
    net.archive = currentLaunchNetSession();
    if (!net.archive) {
      if (net.resync) resetNet();
      net.resync = false;
      net.connecting = false;
      syncNetCapture();
      scheduleNetRender();
      return;
    }
  }
  syncNetCapture();
  const es = new LayerLensEventSource(`${targetBase()}/api/network?${new URLSearchParams(netSessionParams({ since: net.resync ? 0 : net.seq }))}`);
  net.resync = false;
  const parse = (e) => {
    try {
      return JSON.parse(e.data) || {};
    } catch (err) {
      return {};
    }
  };
  es.addEventListener('network', (e) => {
    const data = parse(e);
    // 连上时可能还没有请求, 也要重新渲染以去掉"正在连接"
    if (net.connecting) {
      net.connecting = false;
      scheduleNetRender();
    }
    // App 重启后序号从头开始, 上一次的请求内容已不在设备上
    if (data.instanceId && net.instanceId && data.instanceId !== net.instanceId) {
      resetNet();
      loadLaunches();
    }
    if (data.instanceId) net.instanceId = data.instanceId;
    receiveNetRecords(data.records || []);
  });
  es.addEventListener('clear', () => resetNet());
  es.addEventListener('source', (e) => {
    const data = parse(e);
    net.offline = !data.online;
    net.dropped = data.dropped || 0;
    scheduleNetRender();
  });
  // 其他窗口切换了抓包开关
  es.addEventListener('capture', () => resyncNet());
  // 断开后由浏览器自动重连; 期间 App 可能换成了旧版 Pod, 重新检查一次.
  // 收到错误状态码(如 App 未运行时旧版 Mac App 返回 503)时浏览器不再重连, 稍后自己重新连接
  es.onerror = async () => {
    if (token !== net.token) return;
    if (await netOutdated()) {
      if (token !== net.token) return;
      netDisconnect();
      net.unsupported = true;
      scheduleNetRender();
      return;
    }
    if (token === net.token && es.readyState === LayerLensEventSource.CLOSED) {
      setTimeout(() => {
        if (token === net.token && net.active) netConnect();
      }, NET_RETRY_MS);
    }
  };
  net.es = es;
}

// 旧版 Pod 没有抓包接口, 路由返回 Not Found; App 未运行时 Hub 返回 503, 不算过低
async function netOutdated() {
  try {
    const res = await fetch(`${targetBase()}/api/network/status?${new URLSearchParams(netSessionParams())}`);
    const data = await res.json().catch(() => ({}));
    // 0.6.1 起支持搜索内容
    if (res.ok) net.searchSupported = !!data.search;
    syncNetRemote();
    net.cached = res.ok && !!data.cached;
    net.capture = res.ok && 'capture' in data ? !!data.capture : null;
    net.offline = !!data.archived || (res.ok && data.online === false);
    net.dropped = data.dropped || 0;
    syncNetCapture();
    if (res.status !== 404) return false;
    return !data.error || data.error === 'Not Found';
  } catch (e) {
    return false;
  }
}

function netDisconnect() {
  net.token++;
  net.es?.close();
  net.es = null;
  net.connecting = false;
}

function resetNet() {
  net.records.clear();
  net.list = [];
  net.view = [];
  net.pending = [];
  net.seq = 0;
  net.instanceId = '';
  net.follow = true;
  resetNetRemote();
  closeNetDetail();
  scheduleNetRender();
}

function receiveNetRecords(records) {
  if (!records.length) return;
  if (net.paused) {
    net.pending.push(...records);
    renderNetStatus();
    return;
  }
  applyNetRecords(records);
}

function applyNetRecords(records) {
  let reorder = false;
  let detailChanged = false;
  for (const record of records) {
    net.seq = Math.max(net.seq, record.s || 0);
    const old = net.records.get(record.id);
    noteNetRemoteRecord(record, old);
    if (old) {
      if (record.id === net.selected && old.state !== record.state) detailChanged = true;
      Object.assign(old, record);
      old.filterText = old.filterLower = old.urlParts = null;
      continue;
    }
    if (net.list.length && net.list[net.list.length - 1].id > record.id) reorder = true;
    net.records.set(record.id, record);
    net.list.push(record);
  }
  if (reorder) net.list.sort((a, b) => a.id - b.id);
  flushNetRemote();
  if (net.list.length > NET_MAX_RECORDS) {
    net.list.splice(0, net.list.length - NET_MAX_RECORDS).forEach((record) => net.records.delete(record.id));
  }
  rebuildNetView();
  if (detailChanged) loadNetDetail(net.selected);
}

function setNetPaused(paused) {
  net.paused = paused;
  const button = $('netPause');
  button.classList.toggle('on', paused);
  button.setAttribute('aria-pressed', String(paused));
  button.title = paused ? t('继续') : t('暂停');
  button.querySelector('use').setAttribute('href', paused ? '#i-play' : '#i-pause');
  if (!paused && net.pending.length) {
    const pending = net.pending;
    net.pending = [];
    applyNetRecords(pending);
  }
  renderNetStatus();
}

// MARK: Filter

// 类型、状态、自定义过滤项和搜索框条件见 net-filters.js
function netFailed(record) {
  return record.state === 'failed' || record.status >= 400;
}

function rebuildNetView() {
  net.view = netFiltersActive() ? net.list.filter((record) => netFiltersMatch(record)) : net.list;
  scheduleNetRender();
}

// MARK: List

function scheduleNetRender() {
  if (!net.raf) net.raf = requestAnimationFrame(renderNet);
}

const NET_HEAD_H = 28;

function renderNet() {
  net.raf = 0;
  if (!net.active) return;
  const list = $('netList');
  if (!net.charMeasured) measureNetChar(list);
  const view = net.view;
  $('netSpacer').style.height = view.length * net.rowH + 'px';
  if (net.follow) list.scrollTop = list.scrollHeight;
  const top = Math.max(0, list.scrollTop - NET_HEAD_H);
  const overscan = Math.ceil(list.clientHeight / net.rowH);
  const start = Math.max(0, Math.floor(top / net.rowH) - overscan);
  const end = Math.min(view.length, Math.ceil((top + list.clientHeight) / net.rowH) + overscan);
  const rows = $('netRows');
  const key = `${net.selected}|${view === net.list}`;
  if (key !== net.renderKey) {
    rows.replaceChildren();
    net.rendered.clear();
    net.renderKey = key;
  }
  // 已渲染的行内容没变时不重绘, 请求结束等变化后重建该行
  const keep = new Set();
  const fragment = document.createDocumentFragment();
  for (let i = start; i < end; i++) {
    const record = view[i];
    keep.add(record.id);
    let entry = net.rendered.get(record.id);
    if (entry && entry.s !== record.s) {
      entry.row.remove();
      entry = null;
    }
    if (!entry) {
      entry = { s: record.s, row: netRow(record) };
      net.rendered.set(record.id, entry);
      fragment.appendChild(entry.row);
    }
    const y = i * net.rowH + 'px';
    if (entry.row.style.top !== y) entry.row.style.top = y;
    entry.row.classList.toggle('odd', i % 2 === 1);
  }
  net.rendered.forEach((entry, id) => {
    if (keep.has(id)) return;
    entry.row.remove();
    net.rendered.delete(id);
  });
  rows.appendChild(fragment);
  renderNetStatus();
}

function netDuration(ms) {
  if (ms === undefined || ms === null) return '';
  return ms < 1000 ? ms + ' ms' : (ms / 1000).toFixed(ms < 10000 ? 2 : 1) + ' s';
}

function netMimeLabel(record) {
  if (record.state === 'pending') return '';
  const mime = (record.mime || '').split(';')[0].trim();
  const sub = mime.split('/').pop() || '';
  return sub.replace(/^x-/, '').replace(/^.*\+/, '');
}

function netStatusCell(record) {
  const cell = el('span', 'net-status');
  if (record.state === 'pending') {
    cell.textContent = '…';
    cell.classList.add('pending');
  } else if (record.state === 'failed') {
    cell.textContent = record.status || '×';
    cell.classList.add('bad');
    cell.title = record.error || '';
  } else {
    cell.textContent = record.status || '—';
    if (record.status >= 500) cell.classList.add('bad');
    else if (record.status >= 400) cell.classList.add('client');
    else if (record.status >= 300) cell.classList.add('redirect');
  }
  return cell;
}

function netSplitURL(url) {
  const match = /^([a-z][a-z0-9+.-]*:\/\/[^/?#]*)(.*)$/i.exec(url || '');
  return match ? [match[1], match[2] || '/'] : ['', url || ''];
}

function netRow(record) {
  const row = el('div', 'log-row net-row' + (record.id === net.selected ? ' sel' : '') + (netFailed(record) ? ' failed' : ''));
  row.dataset.id = record.id;
  const [origin, path] = netSplitURL(record.url);
  const host = el('span', 'net-host', origin.replace(/^[a-z][a-z0-9+.-]*:\/\//i, ''));
  host.title = origin;
  // 参数在详情中查看, 列表只显示路径; 过滤仍匹配完整地址
  const pathCell = el('span', 'net-path', path.replace(/[?#].*$/, '') || '/');
  pathCell.title = record.url;
  row.append(
    el('span', 'net-start', logTime(record.start)),
    el('span', 'net-method', record.method),
    netStatusCell(record),
    el('span', 'net-size', record.state === 'pending' && !record.resSize ? '' : logSize(record.resSize || 0)),
    el('span', 'net-time', record.state === 'pending' ? t('进行中') : netDuration(record.duration)),
    host,
    pathCell,
    el('span', 'net-kind', netMimeLabel(record)),
  );
  return row;
}

function renderNetStatus() {
  const total = net.list.length;
  $('netSource').hidden = !net.session;
  const count = $('netCount');
  const parts = [];
  if (net.view !== net.list) parts.push(el('span', 'hit', String(net.view.length)), document.createTextNode(' / ' + total));
  else if (total) parts.push(document.createTextNode(String(total)));
  // 暂停期间同一请求会收到开始与结束两次变化, 只数新请求
  const paused = new Set(net.pending.filter((record) => !net.records.has(record.id)).map((record) => record.id)).size;
  if (paused) parts.push(document.createTextNode(' ' + t('+{0} 暂停中', paused)));
  if (net.dropped && !net.session) {
    const badge = el('span', 'net-dropped', t('丢弃 {0}', net.dropped));
    badge.title = t('Mac 未连接期间 App 的缓冲已满, 丢弃了 {0} 个最早的请求', net.dropped);
    parts.push(badge);
  }
  count.replaceChildren(...parts);
  // 切换开关后重新连接期间不显示, 以免在请求列表上闪一下
  const captureOff = !!net.key && !net.unsupported && net.capture === false && !net.session && !net.archive && !net.connecting;
  let empty = '';
  if (!net.key) empty = t('未连接 App');
  else if (net.unsupported) {
    const version = currentApp()?.podVersion;
    empty = version ? t('App 集成的 LayerLens 为 {0}, 抓包需要 {1} 或更高版本, 更新 Pod 后重新运行 App', version, NET_SUPPORT_VERSION) : t('抓包需要 LayerLens {0} 或更高版本, 更新 Pod 后重新运行 App', NET_SUPPORT_VERSION);
  } else if (captureOff) empty = ' ';
  else if (!total) empty = net.connecting ? '' : net.session ? t('这次启动没有保存的请求') : net.cached && net.offline ? t('App 未运行, 本机没有保存的请求') : t('暂无请求. 通过 NSURLSession 发出的请求会显示在这里, WKWebView 中的请求不会');
  else if (!net.view.length) empty = t('没有匹配的请求');
  if (captureOff) $('netEmpty').replaceChildren(...netCaptureOffEmpty());
  else $('netEmpty').textContent = empty;
  $('netEmpty').classList.toggle('capture-off', captureOff);
  $('netEmpty').hidden = !empty;
  $('netHar').disabled = !net.view.length;
}

function netRecordIndex(id) {
  return net.view.findIndex((record) => record.id === id);
}

function selectNet(id) {
  net.selected = id;
  scheduleNetRender();
  if (id) loadNetDetail(id);
  else closeNetDetail();
}

function moveNetSelection(step) {
  if (!net.view.length) return;
  const index = netRecordIndex(net.selected);
  const next = net.view[Math.max(0, Math.min(net.view.length - 1, index < 0 ? (step > 0 ? 0 : net.view.length - 1) : index + step))];
  selectNet(next.id);
  const list = $('netList');
  // 列头固定在顶部, 行在内容中的位置要加上列头高度
  const y = netRecordIndex(next.id) * net.rowH;
  if (y < list.scrollTop) list.scrollTop = y;
  else if (y + NET_HEAD_H + net.rowH > list.scrollTop + list.clientHeight) list.scrollTop = y + NET_HEAD_H + net.rowH - list.clientHeight;
  net.follow = false;
}

// MARK: Menu

// items: [标题, 操作, 是否禁用], null 为分隔线
function showNetMenu(x, y, items) {
  hideMenu();
  const menu = el('div', 'context-menu');
  menu.id = 'contextMenu';
  items.forEach((entry) => {
    if (!entry) {
      menu.appendChild(el('div', 'menu-separator'));
      return;
    }
    const [title, run, disabled] = entry;
    const button = el('button', 'menu-item', t(title));
    button.disabled = !!disabled;
    button.addEventListener('click', () => {
      hideMenu();
      run();
    });
    menu.appendChild(button);
  });
  document.body.appendChild(menu);
  placeMenu(menu, x, y);
}

function showNetRowMenu(x, y, record, cell) {
  // 单元格只是视觉上截断, 文本是完整的
  const value = cell?.textContent || '';
  showNetMenu(x, y, [
    ['复制单元格', () => copyText(value, '复制单元格'), !value],
    ['复制 URL', () => copyText(record.url, '复制 URL')],
    null,
    ['复制 cURL', () => copyNetCurl(record.id)],
    ['复制响应内容', () => copyNetResponse(record.id), record.state === 'pending'],
  ]);
}

async function copyNetResponse(id) {
  try {
    const { bytes } = await fetchNetBody(id, 'res');
    const text = sandboxText(bytes);
    if (text === null) {
      toast(t('响应内容为二进制, 无法复制'), true);
      return;
    }
    await copyText(text, '复制响应内容');
  } catch (e) {
    toast(e.message, true);
  }
}

// MARK: Detail

// 详情面板固定显示, 未选中请求时显示提示
function closeNetDetail() {
  net.selected = 0;
  net.detail = null;
  net.detailToken++;
  $('netDetail').removeAttribute('aria-busy');
  $('netDetail').hidden = false;
  $('netSplitter').hidden = false;
  // 空状态也显示头部, 查找栏位置与选中请求时一致
  setNetDetail(netDetailHead(null), el('div', 'net-detail-empty', t('选择一个请求查看详情')));
  scheduleNetRender();
}

function netApi(path, params) {
  return `${targetBase()}/api/network/${path}?${new URLSearchParams(netSessionParams(params))}`;
}

async function fetchNetDetail(id) {
  const res = await fetch(netApi('detail', { id }));
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(t(NET_BODY_MESSAGES[data.error] || data.error || `HTTP ${res.status}`));
  return data;
}

async function loadNetDetail(id) {
  const token = ++net.detailToken;
  const panel = $('netDetail');
  panel.hidden = false;
  $('netSplitter').hidden = false;
  // 已有详情时保留当前画面, 新数据准备好后一次替换, 避免先清空成加载占位再显示内容
  panel.setAttribute('aria-busy', 'true');
  if (!net.detail) setNetDetail(netDetailHead(net.records.get(id)), el('p', 'net-note', t('正在加载…')));
  else panel.querySelectorAll('[data-detail-tab], [data-detail-curl], [data-detail-url]').forEach((button) => { button.disabled = true; });
  try {
    const data = await fetchNetDetail(id);
    if (token !== net.detailToken) return;
    net.detail = data;
    renderNetDetail();
  } catch (e) {
    if (token !== net.detailToken) return;
    net.detail = null;
    setNetDetail(netDetailHead(net.records.get(id)), el('p', 'net-note', t('无法读取请求详情: {0}', e.message)));
  } finally {
    if (token === net.detailToken) panel.removeAttribute('aria-busy');
  }
}

// 头部显示 URL 摘要, 截断时原地展开完整内容
function netDetailHead(record) {
  const ready = !!record && net.detail?.id === record.id;
  const key = JSON.stringify(record ? [record.id, record.url, record.method, record.status, record.state, record.error] : null);
  const existing = $('netDetail').querySelector('.net-detail-top');
  const syncControls = (top) => {
    top.querySelectorAll('[data-detail-tab]').forEach((button) => {
      button.disabled = !ready;
      button.classList.toggle('active', button.dataset.detailTab === net.detailTab);
    });
    top.querySelector('[data-detail-curl]').disabled = !ready;
    const urlButton = top.querySelector('[data-detail-url]');
    if (urlButton) urlButton.disabled = !ready;
  };
  // 加载结束和页签切换时复用头部和工具栏
  if (existing?.dataset.recordKey === key) {
    syncControls(existing);
    return existing;
  }
  net.urlHeadCleanup?.();
  net.urlHeadCleanup = null;
  const top = el('div', 'net-detail-top');
  top.dataset.recordKey = key;
  const tabs = el('div', 'segmented small net-detail-tabs');
  [['response', '响应'], ['request', '请求'], ['headers', '标头']].forEach(([name, label]) => {
    const button = el('button', '', t(label));
    button.dataset.detailTab = name;
    button.addEventListener('click', () => {
      if (!record || net.detail?.id !== record.id) return;
      net.detailTab = name;
      renderNetDetail();
    });
    tabs.appendChild(button);
  });
  const head = el('div', 'net-detail-head');
  const title = el('div', 'net-detail-title');
  if (record) {
    const url = el('span', 'net-detail-url');
    const text = el('span', 'net-detail-url-text', record.url);
    const show = el('button', 'icon-btn net-detail-url-button');
    show.dataset.detailUrl = '';
    show.title = t('点击查看完整 URL');
    show.setAttribute('aria-label', t('点击查看完整 URL'));
    show.appendChild(icon('chevron-down'));
    show.hidden = true;
    show.setAttribute('aria-expanded', 'false');
    const copy = el('button', 'icon-btn net-detail-url-copy');
    copy.title = t('复制 URL');
    copy.setAttribute('aria-label', t('复制 URL'));
    copy.appendChild(icon('copy'));
    copy.hidden = true;
    copy.addEventListener('click', () => copyText(record.url, '复制 URL'));
    let expanded = false;
    show.addEventListener('click', () => {
      expanded = !expanded;
      head.classList.toggle('url-expanded', expanded);
      show.setAttribute('aria-expanded', String(expanded));
      const label = t(expanded ? '点击收起完整 URL' : '点击查看完整 URL');
      show.title = label;
      show.setAttribute('aria-label', label);
      show.replaceChildren(icon(expanded ? 'chevron-up' : 'chevron-down'));
      copy.hidden = !expanded;
      syncURL();
    });
    url.append(text, show, copy);
    title.append(el('span', 'net-method', record.method), netStatusCell(record), url);
    // 展开时保留收起入口; 收起时按完整可用宽度判断是否需要展开按钮.
    const syncURL = () => { show.hidden = !expanded && text.scrollWidth <= url.clientWidth + 1; };
    const observer = new ResizeObserver(syncURL);
    observer.observe(url);
    top.syncURL = syncURL;
    net.urlHeadCleanup = () => observer.disconnect();
  }
  const tools = el('div', 'net-detail-tools');
  const curl = el('button', 'sb-text-btn', 'cURL');
  curl.dataset.detailCurl = '';
  curl.addEventListener('click', () => copyNetCurl(net.detail?.id));
  curl.disabled = !net.detail;
  tools.appendChild(curl);
  head.append(...[title, tabs, tools].filter(Boolean));
  top.appendChild(head);
  syncControls(top);
  return top;
}

function renderNetDetail() {
  const detail = net.detail;
  const body = el('div', 'net-detail-body');
  if (net.detailTab === 'request') {
    const fullURL = el('div', 'net-detail-full-url', detail.url);
    fullURL.tabIndex = -1;
    const urlSection = netSection(t('完整 URL'), fullURL);
    const copyUrl = el('button', 'icon-btn');
    copyUrl.title = t('复制 URL');
    copyUrl.appendChild(icon('copy'));
    copyUrl.addEventListener('click', () => copyText(detail.url, '复制 URL'));
    urlSection.querySelector('h5').appendChild(copyUrl);
    body.appendChild(urlSection);
    const query = [...new URL(detail.url, location.href).searchParams];
    if (query.length) body.appendChild(netSection(t('查询参数'), netKeyValueRows(query)));
    if (detail.reqSize || (detail.reqBody && detail.reqBody !== 'none')) {
      const requestBody = netBodySection(detail, 'req');
      requestBody.prepend(el('h5', null, t('请求体')));
      body.appendChild(requestBody);
    }
  } else if (net.detailTab === 'headers') {
    body.append(
      netHeadersSection(t('请求头'), detail.requestHeaders),
      netHeadersSection(t('响应头'), detail.responseHeaders),
    );
  } else {
    body.appendChild(netBodySection(detail, 'res'));
  }
  const content = el('div', 'net-detail-content');
  content.appendChild(body);
  setNetDetail(netDetailHead(net.records.get(detail.id) || detail), content);
  runNetFind();
}

// 查找栏悬浮在头部下方, 不占用详情布局; 复用输入框并保留焦点
function setNetDetail(head, ...rest) {
  const input = net.find.row?.querySelector('input');
  const focused = !!input && document.activeElement === input;
  const start = input?.selectionStart;
  const end = input?.selectionEnd;
  const row = netFindRow();
  const hasHead = head?.classList.contains('net-detail-top');
  if (hasHead && row && row.parentNode !== head) head.appendChild(row);
  const nodes = hasHead ? [head, ...rest] : [row, head, ...rest];
  // 保留仍在使用的头部和查找栏节点, 仅替换变化的内容区
  const panel = $('netDetail');
  let cursor = panel.firstChild;
  for (const node of nodes.filter(Boolean)) {
    if (node === cursor) cursor = cursor.nextSibling;
    else panel.insertBefore(node, cursor);
  }
  while (cursor) {
    const next = cursor.nextSibling;
    cursor.remove();
    cursor = next;
  }
  head?.syncURL?.();
  if (focused && input.isConnected) {
    input.focus({ preventScroll: true });
    input.setSelectionRange(start, end);
  }
}

function netFindRow() {
  if (!net.find.open) return null;
  if (!net.find.row) {
    net.find.row = el('div', 'net-find-row');
    net.find.row.appendChild(netFindBar());
  }
  return net.find.row;
}

function netSection(title, content) {
  const section = el('section', 'net-section');
  section.appendChild(el('h5', null, title));
  section.append(...[].concat(content));
  return section;
}

function netKeyValueRows(pairs) {
  if (!pairs.length) return el('p', 'net-note', t('无'));
  const table = el('div', 'net-kv');
  pairs.forEach(([name, value]) => {
    table.append(el('span', 'net-k', name), el('span', 'net-v', value));
  });
  table.addEventListener('contextmenu', (e) => {
    const cell = e.target.closest('.net-k, .net-v');
    // 有选中文本时保留系统的复制行为
    if (!cell || window.getSelection().toString()) return;
    e.preventDefault();
    const [name, value] = pairs[Math.floor([...table.children].indexOf(cell) / 2)];
    showNetMenu(e.clientX, e.clientY, [
      ['复制值', () => copyText(value, '复制值')],
      ['复制名称', () => copyText(name, '复制名称')],
      ['复制整行', () => copyText(`${name}: ${value}`, '复制整行')],
    ]);
  });
  return table;
}

function netHeaderRows(headers) {
  return netKeyValueRows(Object.entries(headers || {}).sort(([a], [b]) => a.toLowerCase().localeCompare(b.toLowerCase())));
}

// 原生折叠区域保持键盘可操作, 内容仍可被详情查找定位.
function netHeadersSection(title, headers) {
  const section = el('details', 'net-section net-headers-section');
  section.open = true;
  section.append(el('summary', null, `${title} (${Object.keys(headers || {}).length})`), netHeaderRows(headers));
  return section;
}

function netBodySection(detail, side) {
  const size = side === 'req' ? detail.reqSize : detail.resSize;
  const state = side === 'req' ? detail.reqBody : detail.resBody;
  const section = el('section', 'net-section net-body-section');
  const notes = { none: '没有内容', tooLarge: '内容超过 5 MB, 未保存', stream: '以流的方式发送, 无法获取内容', file: '文件内容未保存', evicted: '已被缓存清理删除' };
  if (detail.state === 'pending' && side === 'res') {
    section.appendChild(el('p', 'net-note', t('请求进行中, 结束后显示')));
  } else if (state !== 'stored') {
    section.appendChild(el('p', 'net-note', t(notes[state] || '没有内容') + (size && state !== 'none' ? ` (${logSize(size)})` : '')));
  } else {
    const box = el('div', 'net-body-box');
    box.appendChild(el('p', 'net-note', t('正在加载…')));
    section.appendChild(box);
    loadNetBody(detail.id, side, box);
  }
  return section;
}

async function fetchNetBody(id, side) {
  const res = await fetch(netApi('body', { id, side }));
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new Error(t(NET_BODY_MESSAGES[data.error] || data.error || `HTTP ${res.status}`));
  }
  return { type: res.headers.get('Content-Type') || '', bytes: new Uint8Array(await res.arrayBuffer()) };
}

async function loadNetBody(id, side, box) {
  const token = net.detailToken;
  try {
    const { type, bytes } = await fetchNetBody(id, side);
    if (token !== net.detailToken) return;
    const tools = el('div', 'net-body-tools');
    const duration = side === 'res' ? netDuration(net.records.get(id)?.duration) : '';
    tools.appendChild(el('span', 'sb-meta', [type.split(';')[0] || 'application/octet-stream', logSize(bytes.length), duration].filter(Boolean).join(' · ')));
    if (/^image\//i.test(type)) {
      // 默认按比例缩放填满内容区(同 scaleAspectFit), 点击切换原始大小; 加载后在信息中补上尺寸
      const body = box.closest('.net-detail-body');
      const img = el('img', 'sb-image net-image');
      img.title = t('点击查看原始大小');
      img.src = URL.createObjectURL(new Blob([bytes], { type }));
      img.onload = () => tools.firstChild.append(` · ${img.naturalWidth}×${img.naturalHeight}`);
      img.onerror = () => {
        body?.classList.remove('image-fit');
        box.replaceChildren(tools, el('p', 'net-note', t('无法预览此图片')));
      };
      img.addEventListener('click', () => {
        const zoomed = img.classList.toggle('zoomed');
        body?.classList.toggle('image-fit', !zoomed);
        img.title = zoomed ? t('点击缩小') : t('点击查看原始大小');
      });
      body?.classList.add('image-fit');
      box.replaceChildren(tools, img);
      return;
    }
    const text = sandboxText(bytes.slice(0, NET_PREVIEW_LIMIT));
    if (text === null) {
      box.replaceChildren(tools, el('p', 'net-note', t('二进制内容, 显示开头 {0} 字节', Math.min(bytes.length, 1024))), sandboxCode(sandboxHex(bytes.slice(0, 1024))));
      return;
    }
    const full = bytes.length <= NET_PREVIEW_LIMIT ? new TextDecoder().decode(bytes) : text;
    let content = full;
    let tree = null;
    if (bytes.length <= NET_PREVIEW_LIMIT && (/json/i.test(type) || /^\s*[{[]/.test(full))) {
      try {
        tree = parseJSONTree(full);
        content = jsonPretty(tree, '');
      } catch (e) {
        // 不是合法 JSON 时按原文显示
      }
    }
    const nodes = [];
    if (/x-www-form-urlencoded/i.test(type)) nodes.push(netKeyValueRows([...new URLSearchParams(full)]));
    if (bytes.length > NET_PREVIEW_LIMIT) nodes.push(el('p', 'net-note', t('内容较大, 只显示前 {0}', logSize(NET_PREVIEW_LIMIT))));
    const folds = [];
    if (tree && (tree.t === 'o' || tree.t === 'a')) {
      const expand = el('button', 'sb-text-btn', t('展开全部'));
      expand.addEventListener('click', () => box.querySelectorAll('.json-node').forEach((node) => node.classList.remove('collapsed')));
      const collapse = el('button', 'sb-text-btn', t('折叠全部'));
      // 保留第一层, 只折叠更深的层级
      collapse.addEventListener('click', () => box.querySelectorAll('.json-node .json-node').forEach((node) => node.classList.add('collapsed')));
      folds.push(expand, collapse);
    }
    const copy = el('button', 'sb-text-btn');
    copy.append(icon('copy'), t('复制'));
    copy.addEventListener('click', () => copyText(content, '复制内容'));
    tools.append(...folds, copy);
    box.replaceChildren(tools, ...nodes, tree ? jsonView(tree) : sandboxCode(content));
    runNetFind();
  } catch (e) {
    if (token === net.detailToken) box.replaceChildren(el('p', 'net-note', e.message));
  }
}

// MARK: JSON

// 自行解析以保留数字原文, 避免超过 2^53 的 id 等在 JSON.parse 后丢失精度.
// 节点: o 对象 (v 为 [key, 节点] 数组), a 数组, s 字符串, n 数字 (原文), l true / false / null
function parseJSONTree(text) {
  let i = 0;
  const fail = () => {
    throw new SyntaxError('Invalid JSON');
  };
  const space = () => {
    for (let c = text.charCodeAt(i); c === 32 || c === 9 || c === 10 || c === 13; c = text.charCodeAt(++i));
  };
  const stringRe = /"(?:[^"\\\u0000-\u001f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"/y;
  const literalRe = /-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null/y;
  const string = () => {
    stringRe.lastIndex = i;
    const match = stringRe.exec(text);
    if (!match) fail();
    i = stringRe.lastIndex;
    return JSON.parse(match[0]);
  };
  const value = () => {
    space();
    const c = text[i];
    if (c === '{' || c === '[') {
      const object = c === '{';
      const items = [];
      i++;
      space();
      if (text[i] === (object ? '}' : ']')) {
        i++;
        return { t: object ? 'o' : 'a', v: items };
      }
      for (;;) {
        if (object) {
          space();
          if (text[i] !== '"') fail();
          const key = string();
          space();
          if (text[i++] !== ':') fail();
          items.push([key, value()]);
        } else {
          items.push([null, value()]);
        }
        space();
        const next = text[i++];
        if (next === (object ? '}' : ']')) break;
        if (next !== ',') fail();
      }
      return { t: object ? 'o' : 'a', v: items };
    }
    if (c === '"') return { t: 's', v: string() };
    literalRe.lastIndex = i;
    const match = literalRe.exec(text);
    if (!match) fail();
    i = literalRe.lastIndex;
    return { t: /^[tfn]/.test(match[0]) ? 'l' : 'n', v: match[0] };
  };
  const root = value();
  space();
  if (i < text.length) fail();
  return root;
}

function jsonScalarText(node) {
  return node.t === 's' ? JSON.stringify(node.v) : node.v;
}

function jsonPretty(node, indent) {
  if (node.t !== 'o' && node.t !== 'a') return jsonScalarText(node);
  const [open, close] = node.t === 'o' ? ['{', '}'] : ['[', ']'];
  if (!node.v.length) return open + close;
  const inner = indent + '  ';
  const items = node.v.map(([key, child]) => inner + (key === null ? '' : JSON.stringify(key) + ': ') + jsonPretty(child, inner));
  return `${open}\n${items.join(',\n')}\n${indent}${close}`;
}

// 点击 ▸ 或折叠后的摘要切换展开, 按住 ⌥ 时同时切换所有下级
function jsonView(tree) {
  const root = el('pre', 'sb-code json-view');
  root.appendChild(jsonNode(tree, null, false));
  // 行号按展开后的行编号, 折叠时保持不变
  const lines = root.querySelectorAll('.json-line, .json-close');
  lines.forEach((line, index) => (line.dataset.line = index + 1));
  root.style.setProperty('--gutter', String(lines.length).length + 'ch');
  root.addEventListener('click', (e) => {
    const target = e.target.closest('.json-toggle, .json-summary');
    if (!target) return;
    const node = target.closest('.json-node');
    const collapse = !node.classList.contains('collapsed');
    if (e.altKey) node.querySelectorAll('.json-node').forEach((child) => child.classList.toggle('collapsed', collapse));
    node.classList.toggle('collapsed', collapse);
  });
  return root;
}

function jsonNode(node, key, comma) {
  const line = el('div', 'json-line');
  if (key !== null) line.append(el('span', 'json-key', JSON.stringify(key)), el('span', 'json-punct', ': '));
  const container = node.t === 'o' || node.t === 'a';
  if (!container || !node.v.length) {
    line.appendChild(container ? el('span', 'json-punct', node.t === 'o' ? '{}' : '[]') : el('span', node.t === 's' ? 'json-str' : node.t === 'n' ? 'json-num' : 'json-lit', node.v === undefined ? '' : jsonScalarText(node)));
    if (comma) line.appendChild(el('span', 'json-punct', ','));
    return line;
  }
  const [open, close] = node.t === 'o' ? ['{', '}'] : ['[', ']'];
  const wrap = el('div', 'json-node');
  line.prepend(el('span', 'json-toggle'));
  line.append(el('span', 'json-punct', open), el('span', 'json-summary', ` … ${close}${comma ? ',' : ''}  ${t('{0} 项', node.v.length)}`));
  const children = el('div', 'json-children');
  node.v.forEach(([childKey, child], index) => children.appendChild(jsonNode(child, childKey, index < node.v.length - 1)));
  const end = el('div', 'json-close');
  end.appendChild(el('span', 'json-punct', close + (comma ? ',' : '')));
  wrap.append(line, children, end);
  return wrap;
}

// MARK: Find

function netFindBar() {
  const bar = el('div', 'net-find');
  const input = el('input');
  input.type = 'text';
  input.placeholder = t('在内容中查找');
  input.spellcheck = false;
  input.value = net.find.query;
  input.addEventListener('input', () => {
    net.find.query = input.value;
    net.find.index = -1;
    saveNetFind();
    runNetFind();
  });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      stepNetFind(e.shiftKey ? -1 : 1);
    } else if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      closeNetFind();
    }
  });
  const count = el('span', 'net-find-count');
  const button = (name, title, run) => {
    const b = el('button', 'icon-btn');
    b.title = t(title);
    b.appendChild(icon(name));
    b.addEventListener('click', run);
    return b;
  };
  bar.append(input, count, el('span', 'net-find-sep'), button('chevron-up', '上一个', () => stepNetFind(-1)), button('chevron-down', '下一个', () => stepNetFind(1)), button('close', '关闭', closeNetFind));
  return bar;
}

function openNetFind() {
  const panel = $('netDetail');
  net.find.open = true;
  const row = netFindRow();
  if (!row.isConnected) {
    const head = panel.querySelector(':scope > .net-detail-top');
    if (head) head.appendChild(row);
    else panel.prepend(row);
  }
  const input = row.querySelector('input');
  // 选中文本时以选中内容查找
  const selection = window.getSelection().toString().trim();
  if (selection && !selection.includes('\n') && panel.contains(window.getSelection().anchorNode)) {
    input.value = net.find.query = selection;
    net.find.index = -1;
  }
  saveNetFind();
  input.focus({ preventScroll: true });
  input.select();
  runNetFind();
}

// 关闭时保留查找内容, 再次打开时沿用
function closeNetFind() {
  net.find.open = false;
  saveNetFind();
  net.find.row?.remove();
  runNetFind();
  $('netList').focus({ preventScroll: true });
  // 关闭后焦点回到列表, 再按 ⌘F 仍在详情中查找
  findArea = 'netDetail';
}

function saveNetFind() {
  try {
    localStorage.setItem(NET_FIND_KEY, JSON.stringify({ open: net.find.open, query: net.find.query }));
  } catch (e) {
    // 不可用时只在本次有效
  }
}

// 在详情内容的文本中标记所有匹配, 不区分大小写; 折叠的 JSON 中的匹配在跳转到时展开
function runNetFind() {
  const panel = $('netDetail');
  const body = panel.querySelector('.net-detail-body');
  const find = net.find;
  panel.querySelectorAll('mark.find').forEach((mark) => {
    const parent = mark.parentNode;
    mark.replaceWith(document.createTextNode(mark.textContent));
    parent.normalize();
  });
  find.marks = [];
  const query = find.open ? find.query.toLowerCase() : '';
  if (body && query) {
    const nodes = [];
    const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT, {
      acceptNode: (node) => (node.parentElement.closest('.json-summary, .json-toggle, .net-body-tools, button') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    for (let node = walker.nextNode(); node; node = walker.nextNode()) nodes.push(node);
    for (const node of nodes) {
      const lower = node.nodeValue.toLowerCase();
      const starts = [];
      for (let at = lower.indexOf(query); at >= 0 && find.marks.length + starts.length < 5000; at = lower.indexOf(query, at + query.length)) starts.push(at);
      const marks = [];
      // 从后往前拆分, 前面的位置不受影响
      for (let k = starts.length - 1; k >= 0; k--) {
        const match = node.splitText(starts[k]);
        match.splitText(query.length);
        const mark = el('mark', 'find');
        match.replaceWith(mark);
        mark.appendChild(match);
        marks.unshift(mark);
      }
      find.marks.push(...marks);
    }
  }
  if (find.index >= find.marks.length) find.index = find.marks.length - 1;
  if (find.index < 0 && find.marks.length) find.index = 0;
  focusNetFind(false);
}

function stepNetFind(step) {
  const find = net.find;
  if (!find.marks.length) return;
  find.index = (find.index + step + find.marks.length) % find.marks.length;
  focusNetFind(true);
}

function focusNetFind(scroll) {
  const find = net.find;
  const count = $('netDetail').querySelector('.net-find-count');
  if (count) count.textContent = !find.query ? '' : find.marks.length ? `${find.index + 1}/${find.marks.length}` : t('无结果');
  const mark = find.marks[find.index];
  if (!mark) return;
  find.marks.forEach((item) => item.classList.toggle('current', item === mark));
  for (let node = mark.closest('.json-node.collapsed'); node; node = node.parentElement.closest('.json-node.collapsed')) node.classList.remove('collapsed');
  for (let node = mark.parentElement; node; node = node.parentElement) {
    if (node.tagName === 'DETAILS') node.open = true;
  }
  if (scroll || find.index === 0) mark.scrollIntoView({ block: 'center', inline: 'nearest' });
}

function shellQuote(text) {
  return `'${String(text).replace(/'/g, `'\\''`)}'`;
}

async function copyNetCurl(id) {
  let detail = net.detail?.id === id ? net.detail : null;
  try {
    detail = detail || (await fetchNetDetail(id));
  } catch (e) {
    toast(t('无法读取请求详情: {0}', e.message), true);
    return;
  }
  const parts = ['curl'];
  if (detail.method !== 'GET') parts.push('-X', detail.method);
  parts.push(shellQuote(detail.url));
  const headers = detail.requestHeaders || {};
  Object.entries(headers).forEach(([name, value]) => {
    if (name.toLowerCase() !== 'content-length') parts.push('-H', shellQuote(`${name}: ${value}`));
  });
  if (Object.keys(headers).some((name) => name.toLowerCase() === 'accept-encoding')) parts.push('--compressed');
  let note = '';
  if (detail.reqBody === 'stored') {
    try {
      const { bytes } = await fetchNetBody(detail.id, 'req');
      const text = sandboxText(bytes);
      if (text === null) note = t('请求内容为二进制, 未包含在 cURL 中');
      else parts.push('--data-raw', shellQuote(text));
    } catch (e) {
      note = t('无法读取请求内容: {0}', e.message);
    }
  } else if (detail.reqSize) {
    note = t('请求内容未保存, 未包含在 cURL 中');
  }
  await copyText(parts.join(' '), '复制 cURL');
  if (note) toast(note);
}

function exportNetHar() {
  if (!net.view.length) return;
  const d = new Date();
  const stamp = `${d.getFullYear()}${logPad(d.getMonth() + 1)}${logPad(d.getDate())}-${logPad(d.getHours())}${logPad(d.getMinutes())}${logPad(d.getSeconds())}`;
  const params = { name: `${targets.bundleId || 'LayerLens'}-${stamp}.har` };
  if (net.view !== net.list) params.ids = net.view.map((record) => record.id).join(',');
  const link = el('a');
  link.href = netApi('har', params);
  link.download = '';
  document.body.appendChild(link);
  link.click();
  link.remove();
  toast(t('正在下载…'));
}

async function clearNet() {
  try {
    const res = await fetch(targetBase() + '/api/network/clear', { method: 'POST' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
  } catch (e) {
    toast(t('清空失败: {0}', e.message), true);
    return;
  }
  // 设备推送 clear 后各窗口同步清空, 这里先清空当前页面
  resetNet();
}

function setNetDetailWidth(width, save) {
  const body = $('netBody');
  const max = Math.max(NET_DETAIL_MIN_W, body.clientWidth - 200);
  const value = Math.round(Math.max(NET_DETAIL_MIN_W, Math.min(max, width)));
  body.style.setProperty('--net-detail-w', value + 'px');
  if (!save) return;
  try {
    localStorage.setItem(NET_DETAIL_W_KEY, String(value));
  } catch (e) {
    // ignore
  }
}

function setupNetwork() {
  try {
    const tab = localStorage.getItem(NET_TAB_KEY);
    net.tab = tab === 'net' || tab === 'git' || tab === 'term' ? tab : 'log';
    const width = Number(localStorage.getItem(NET_DETAIL_W_KEY));
    if (width) $('netBody').style.setProperty('--net-detail-w', width + 'px');
    const find = JSON.parse(localStorage.getItem(NET_FIND_KEY));
    if (find) {
      net.find.open = !!find.open;
      net.find.query = typeof find.query === 'string' ? find.query : '';
    }
  } catch (e) {
    // ignore
  }
  setupNetColumns();
  $('paneTabs').addEventListener('click', (e) => {
    const button = e.target.closest('button[data-pane]');
    if (button) setPaneTab(button.dataset.pane);
  });
  let filterTimer = null;
  $('netFilter').addEventListener('input', (e) => {
    clearTimeout(filterTimer);
    filterTimer = setTimeout(() => setNetSearchQuery(e.target.value), 150);
  });
  setupNetFilters();
  $('netPause').addEventListener('click', () => setNetPaused(!net.paused));
  setupNetCapture();
  setupLaunches();
  // 清空会删除本机保存的文件, 有记录时先确认
  $('netClear').addEventListener('click', () => {
    if (!net.list.length) {
      clearNet();
      return;
    }
    showConfirm($('netClear'), { title: t('清空本次启动的抓包记录?'), detail: t('将删除 {0} 个请求, 本机保存的文件一并删除, 无法恢复. 以前的启动不受影响', net.list.length), action: t('清空'), onConfirm: clearNet });
  });
  $('netHar').addEventListener('click', exportNetHar);
  const list = $('netList');
  list.addEventListener('scroll', () => {
    hideMenu();
    net.follow = list.scrollTop + list.clientHeight >= list.scrollHeight - 4;
    cancelAnimationFrame(net.raf);
    net.raf = 0;
    renderNet();
  });
  list.addEventListener('click', (e) => {
    const row = e.target.closest('.net-row');
    if (!row || window.getSelection().toString()) return;
    const id = Number(row.dataset.id);
    if (id !== net.selected) selectNet(id);
  });
  list.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
      e.preventDefault();
      e.stopPropagation();
      moveNetSelection(e.key === 'ArrowUp' ? -1 : 1);
    } else if (e.key === 'Escape' && net.selected) {
      e.stopPropagation();
      closeNetDetail();
    }
  });
  list.addEventListener('contextmenu', (e) => {
    const row = e.target.closest('.net-row');
    if (!row) return;
    e.preventDefault();
    showNetRowMenu(e.clientX, e.clientY, net.records.get(Number(row.dataset.id)), e.target.closest('.net-row > span'));
  });
  document.addEventListener('pointerdown', (e) => {
    if (!e.target.closest('.context-menu')) hideMenu();
  });
  // 没有自定义菜单的区域不弹 WebView 自带的菜单(重新加载、播放动画); 输入框和选中文字时保留, 便于复制粘贴
  document.addEventListener('contextmenu', (e) => {
    if (e.defaultPrevented) return;
    if (e.target instanceof Element && e.target.closest('input, textarea, [contenteditable]')) return;
    if (window.getSelection().toString()) return;
    e.preventDefault();
  });
  setupFindKey();
  const splitter = $('netSplitter');
  splitter.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    splitter.setPointerCapture(e.pointerId);
    splitter.classList.add('dragging');
    const right = $('netBody').getBoundingClientRect().right;
    const move = (ev) => setNetDetailWidth(right - ev.clientX, false);
    const up = (ev) => {
      splitter.classList.remove('dragging');
      splitter.removeEventListener('pointermove', move);
      splitter.removeEventListener('pointerup', up);
      splitter.removeEventListener('pointercancel', up);
      setNetDetailWidth(right - ev.clientX, true);
    };
    splitter.addEventListener('pointermove', move);
    splitter.addEventListener('pointerup', up);
    splitter.addEventListener('pointercancel', up);
  });
  new ResizeObserver(() => scheduleNetRender()).observe(list);
  syncNetPanel();
}

// MARK: - Find

// ⌘F 按鼠标所在, 或最近点击, 聚焦的区域查找: 层级树, 日志, 网络列表, 网络请求详情;
// 不必先点击, 鼠标移到哪个区域就查找哪里; 该区域不可见时依次退到层级树, 底部面板当前页
let findArea = '';

function findAreaOf(target) {
  if (!(target instanceof Element)) return findArea;
  if (target.closest('.net-detail')) return 'netDetail';
  if (target.closest('.log-pane')) return 'pane';
  if (target.closest('.tree-pane')) return 'tree';
  return findArea;
}

function paneFilterInput() {
  return net.tab === 'net' ? $('netFilter') : $('logFilter');
}

function runFind() {
  const shown = (node) => !!node && node.offsetParent !== null;
  // 没有选中请求时也可打开查找栏, 选中后在内容中查找
  const detailOpen = netVisible() && shown($('netDetail'));
  const targets = {
    netDetail: detailOpen ? () => openNetFind() : null,
    pane: shown(paneFilterInput()) ? paneFilterInput() : null,
    tree: shown($('search')) ? $('search') : null,
  };
  const target = targets[findArea] || targets.tree || targets.pane;
  if (!target) return false;
  if (typeof target === 'function') {
    target();
  } else {
    target.focus();
    target.select();
  }
  return true;
}

function setupFindKey() {
  ['pointerdown', 'pointerover'].forEach((type) => document.addEventListener(type, (e) => {
    findArea = findAreaOf(e.target);
  }, true));
  document.addEventListener('focusin', (e) => {
    findArea = findAreaOf(e.target);
  });
  document.addEventListener('keydown', (e) => {
    if (!(e.metaKey || e.ctrlKey) || e.altKey || e.shiftKey || e.key.toLowerCase() !== 'f') return;
    if (!$('modal').hidden && !$('modal').classList.contains('closing')) return;
    if (runFind()) {
      e.preventDefault();
      e.stopPropagation();
    }
  }, true);
}

// MARK: - Setup

function setup() {
  setupPageActivity();
  if (new URLSearchParams(location.search).get('view') === 'logs') {
    setupLogsWindow();
    return;
  }
  applyI18n();
  loadViewState();
  showPendingToast();
  resumePendingLaunch();
  window.addEventListener('pagehide', saveViewState);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') saveViewState();
  });
  $('tree').addEventListener('click', (e) => {
    const row = e.target.closest('.row');
    if (!row) return;
    const key = row.dataset.key;
    if (key.startsWith(VC_KEY) && e.target.closest('.arrow')) {
      const view = viewKeyOf(key);
      state.vcCollapsed.has(view) ? state.vcCollapsed.delete(view) : state.vcCollapsed.add(view);
      renderTree();
      return;
    }
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
        showMenu(start.x, start.y, state.nodes.get(viewKeyOf(row.dataset.key)));
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
    showMenu(e.clientX, e.clientY, state.nodes.get(viewKeyOf(row.dataset.key)));
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
    const key = row ? viewKeyOf(row.dataset.key) : null;
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
      state.tabBeforeVC = null;
      switchTab(tab);
    }
  });
  document.addEventListener('keydown', (e) => {
    // 面板快捷键要先于终端处理, 保证焦点在 shell 中时仍可切换页签
    if (handlePaneNumberShortcut(e)) {
      e.preventDefault();
      return;
    }
    // 终端中的按键全部交给 shell, 如 vim 的 Esc
    if (e.target instanceof Element && e.target.closest('.xterm')) return;
    if (e.key === 'Escape') {
      if (document.body.classList.contains('log-max') && $('modal').hidden) setLogMax(false);
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
    if (gitHandleKey(e)) {
      e.preventDefault();
      return;
    }
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
  setupLogs();
  setupNetwork();
  setupGit();
  setupTerminal();
  setupLayout();

  applyTheme(loadTheme(), false);
  $('targetBtn').addEventListener('click', () => togglePopover('targetMenu'));
  setupPanels();
  setupInputMemory();
  start();
}

async function start() {
  try {
    await loadTargets();
  } catch (e) {
    toast(t('无法连接 LayerLens: {0}', e.message), true);
  }
  pageActivity.ready = true;
  migrateTargetHistory();
  pickTarget();
  const device = currentDevice();
  targets.hadDevice = !!device;
  renderTargetMenu();
  await syncLive();
  pollTargets();
  // 一台设备都没有时显示默认页, 保留选中的目标, 该设备回来时优先连接
  if (!targets.devices.length && !targets.bundleId) {
    targets.idle = true;
    $('appName').textContent = t('未连接');
    showGuide();
    setAppState('offline', t('没有发现设备'));
    return;
  }
  if (!targets.bundleId) {
    $('appName').textContent = device?.name || targetHistory[targets.deviceId]?.name || t('未连接');
    // 只选了模拟器(没有运行中的 App)时直接显示实时画面
    if (device?.kind === 'simulator' && liveAvailable()) setMode('live');
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
    $('appName').textContent = targetHistory[targets.deviceId]?.apps[targets.bundleId]?.appName || targets.bundleId;
    appState.blank = true;
    setAppState('offline');
    return;
  }
  loadAppInfo();
  refresh();
}

let appInfoSeq = 0;

function loadAppInfo() {
  const seq = ++appInfoSeq;
  const key = logTargetKey();
  return api('/api/app').then((info) => {
    if (seq !== appInfoSeq || key !== logTargetKey()) return;
    $('appName').textContent = info.appName;
    appInfo.name = info.appName;
    appInfo.base = `${info.version} · ${info.os}`;
    $('appMeta').title = `${info.bundleId} · ${info.device}`;
    updateAppMeta();
    document.title = `${info.appName} - LayerLens`;
  }).catch((e) => {
    if (seq !== appInfoSeq || key !== logTargetKey()) return;
    // App 刚换端口等情况下取不到, 仍显示名称, 事件流重连后会重新加载
    $('appName').textContent = currentApp()?.appName || targets.bundleId;
    toast(e.message, true);
  });
}

setup();
