'use strict';

// 集成终端: 在当前 App 源码所在仓库的根目录打开 shell, 可同时开多个.
// 会话由 Mac App 持有, 切页签、关面板、切 App 都不结束, 关闭标签或退出 LayerLens 时结束.
// 会话列表常驻连接, 底部面板关闭时顶栏按钮也显示会话数; 每个会话一个 xterm 和 WebSocket, 页面打开期间保持连接
const TERM_RETRY_MS = 2000;
const TERM_CONFIRM_MS = 3000;
const TERM_SIZE_KEY = 'layerlens_term_size';
const TERM_SIZE = { min: 9, max: 24, value: 12 };

const term = {
  es: null,
  sessions: [],
  current: '',
  // 会话 id → { xterm, fit, box, ws, exited }
  views: new Map(),
  creating: false,
  // 关闭运行中会话的确认状态 { id, until }
  confirm: null,
  observer: null,
  fontSize: termLoadSize(),
  // 空状态显示的将要打开的位置 { root, name, branch, home } 或 { error }, 按 App 缓存
  info: null,
  infoKey: '',
  infoAt: 0,
  timer: 0,
};

function termVisible() {
  return logVisible() && net.tab === 'term';
}

// 面板显示状态或页签变化时调用
function syncTermPanel() {
  if (!termVisible()) {
    clearInterval(term.timer);
    term.timer = 0;
    return;
  }
  // 切换 App 时更新空状态的项目信息
  if (!term.timer) term.timer = setInterval(() => termLoadInfo(false), 1000);
  termLoadInfo(true);
  termRender();
  // 刚显示时容器才有尺寸
  requestAnimationFrame(() => termFit(true));
}

function termConnect() {
  if (term.es) term.es.close();
  const es = new LayerLensEventSource('/api/hub/term/events');
  term.es = es;
  es.addEventListener('sessions', (e) => {
    if (term.es !== es) return;
    try {
      termOnSessions(JSON.parse(e.data));
    } catch (error) {
      // ignore
    }
  });
  es.onerror = () => {
    if (es.readyState !== LayerLensEventSource.CLOSED) return;
    setTimeout(() => {
      if (term.es === es) termConnect();
    }, TERM_RETRY_MS);
  };
}

function termOnSessions(sessions) {
  term.sessions = sessions;
  const ids = new Set(sessions.map((session) => session.id));
  for (const [id, view] of term.views) {
    if (!ids.has(id)) termDisposeView(id, view);
  }
  sessions.forEach((session) => {
    const view = term.views.get(session.id);
    if (view && session.exited && !view.exited) {
      view.exited = true;
      view.xterm.write(`\r\n\x1b[2m${t('[进程已退出, 状态 {0}]', session.status)}\x1b[0m\r\n`);
    }
  });
  if (!ids.has(term.current)) term.current = sessions.length ? sessions[sessions.length - 1].id : '';
  termSyncBadges();
  termRender();
}

// 页签和顶栏按钮上的会话数; 有会话在运行命令时带一个跳动的点
function termSyncBadges() {
  const count = term.sessions.length;
  const busy = term.sessions.some((session) => session.busy);
  ['termCount', 'termToggleCount'].forEach((id) => {
    const badge = $(id);
    if (!badge) return;
    badge.hidden = !count;
    badge.textContent = count;
    badge.classList.toggle('busy', busy);
  });
  const toggle = $('logToggle');
  if (toggle) toggle.title = count ? t('日志与网络面板 (L / N), {0} 个终端', count) : t('日志与网络面板 (L / N)');
}

function termRender() {
  const tabs = $('termTabs');
  const fragment = document.createDocumentFragment();
  term.sessions.forEach((session) => fragment.append(termTab(session)));
  tabs.replaceChildren(fragment);
  const empty = !term.sessions.length;
  $('termEmpty').hidden = !empty;
  $('termViews').hidden = empty;
  if (empty) {
    termRenderInfo();
    return;
  }
  if (!termVisible()) return;
  const session = term.sessions.find((item) => item.id === term.current);
  if (session) termShow(session);
}

// App 变化或距上次读取超过 10 秒时重新读取; force 用于刚显示页签
async function termLoadInfo(force) {
  const key = targets.bundleId || '';
  if (term.sessions.length && !force) return;
  if (key === term.infoKey && (!force || Date.now() - term.infoAt < 10000)) return;
  term.infoKey = key;
  term.infoAt = Date.now();
  if (!key) {
    term.info = null;
    termRender();
    return;
  }
  let info;
  try {
    info = await (await fetch(`/api/hub/term/info?app=${encodeURIComponent(key)}`)).json();
  } catch (e) {
    info = { error: e.message };
  }
  if (key !== term.infoKey) return;
  term.info = info;
  termRender();
}

function termRenderInfo() {
  const info = term.info;
  const ready = !!info?.root;
  $('termProject').hidden = !ready;
  const note = !targets.bundleId ? t('未选择 App') : info?.error
    ? (info.reason === 'noSource' ? t('App 没有上报源码路径: 在模拟器上运行一次, 或更新 LayerLens Pod 后重新运行') : t('无法读取项目: {0}', info.error))
    : '';
  $('termProjectNote').hidden = !note;
  $('termProjectNote').textContent = note;
  $('termOpen').disabled = !ready || term.creating;
  if (!ready) return;
  $('termProjectName').textContent = info.name;
  const home = info.home || '';
  $('termProjectPath').textContent = home && info.root.startsWith(home + '/') ? '~' + info.root.slice(home.length) : info.root;
  $('termProjectPath').title = info.root;
  $('termProjectBranch').hidden = !info.branch;
  $('termProjectBranchName').textContent = info.branch === 'HEAD' ? t('游离 HEAD') : info.branch || '';
}

function termTab(session) {
  const tab = el('div', 'term-tab' + (session.id === term.current ? ' active' : '') + (session.exited ? ' exited' : '') + (session.busy ? ' busy' : ''));
  tab.append(el('span', 'term-dot'), el('span', 'term-name', session.name));
  const state = session.exited ? t('已结束') : session.command;
  if (state) tab.append(el('span', 'term-state', state));
  tab.title = session.root + (session.busy ? '\n' + t('正在运行: {0}', session.command) : '');
  // 正在运行命令时再点一次确认; 确认状态记在 term 上, 列表刷新重绘后仍保留
  const confirming = session.busy && term.confirm?.id === session.id && Date.now() < term.confirm.until;
  const close = el('button', 'term-close' + (confirming ? ' confirm' : ''));
  if (confirming) close.append(t('结束'));
  else close.append(icon('close'));
  close.title = confirming ? t('再点一次结束正在运行的 {0}', session.command) : t('关闭终端');
  close.addEventListener('click', (e) => {
    e.stopPropagation();
    if (session.busy && !confirming) {
      term.confirm = { id: session.id, until: Date.now() + TERM_CONFIRM_MS };
      termRender();
      setTimeout(termRender, TERM_CONFIRM_MS + 50);
      return;
    }
    term.confirm = null;
    termClose(session.id);
  });
  tab.append(close);
  tab.addEventListener('click', () => {
    term.current = session.id;
    termRender();
    termFit(true);
  });
  tab.addEventListener('auxclick', (e) => {
    if (e.button === 1 && !session.busy) termClose(session.id);
  });
  return tab;
}

async function termCreate() {
  if (term.creating) return;
  if (!targets.bundleId) {
    toast(t('未选择 App'), true);
    return;
  }
  term.creating = true;
  termRender();
  let result;
  try {
    const response = await fetch('/api/hub/term/create', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ app: targets.bundleId }),
    });
    result = await response.json().catch(() => ({ error: String(response.status) }));
  } catch (e) {
    result = { error: e.message };
  }
  term.creating = false;
  if (result.error) {
    toast(result.reason === 'noSource' ? t('App 没有上报源码路径: 在模拟器上运行一次, 或更新 LayerLens Pod 后重新运行') : t('无法打开终端: {0}', result.error), true);
    termRender();
    return;
  }
  term.current = result.id;
  if (!termVisible()) showPaneTab('term');
  termRender();
}

async function termClose(id) {
  try {
    await fetch('/api/hub/term/close', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id }),
    });
  } catch (e) {
    toast(e.message, true);
  }
}

// MARK: - xterm

function termShow(session) {
  let view = term.views.get(session.id);
  if (!view) view = termCreateView(session);
  term.views.forEach((other, id) => (other.box.hidden = id !== session.id));
}

function termCreateView(session) {
  const box = el('div', 'term-view');
  $('termViews').append(box);
  const xterm = new Terminal({
    fontFamily: getComputedStyle(document.documentElement).getPropertyValue('--mono').trim() || 'Menlo, monospace',
    fontSize: term.fontSize,
    lineHeight: 1.15,
    cursorBlink: true,
    scrollback: 5000,
    macOptionIsMeta: true,
    theme: termTheme(),
  });
  const fit = new FitAddon.FitAddon();
  xterm.loadAddon(fit);
  xterm.open(box);
  // ⌘K 清屏, 与 Terminal.app 一致; ⌘C / ⌘V 由 xterm 处理复制粘贴事件
  xterm.attachCustomKeyEventHandler((e) => {
    if (e.type === 'keydown' && e.metaKey && e.key.toLowerCase() === 'k') {
      xterm.clear();
      return false;
    }
    return true;
  });
  const view = { xterm, fit, box, ws: null, exited: session.exited };
  term.views.set(session.id, view);
  // 多个窗口连着同一会话时以正在输入或刚获得焦点的窗口的尺寸为准, 输入时附带尺寸
  xterm.onData((data) => termSend(view, { t: 'i', d: data, c: xterm.cols, r: xterm.rows }));
  xterm.onResize(({ cols, rows }) => termSend(view, { t: 'r', c: cols, r: rows }));
  xterm.textarea?.addEventListener('focus', () => termSend(view, { t: 'r', c: xterm.cols, r: xterm.rows }));
  termOpenSocket(session.id, view);
  return view;
}

function termOpenSocket(id, view) {
  const ws = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/api/hub/term/${encodeURIComponent(id)}/ws`);
  ws.binaryType = 'arraybuffer';
  view.ws = ws;
  ws.onopen = () => {
    termFit(false);
    termSend(view, { t: 'r', c: view.xterm.cols, r: view.xterm.rows });
  };
  ws.onmessage = (e) => view.xterm.write(new Uint8Array(e.data));
  // LayerLens 重启时会话已不存在, 列表更新后视图会被移除; 仍在列表中则稍后重连并重新回放
  ws.onclose = () => {
    if (view.ws !== ws) return;
    view.ws = null;
    setTimeout(() => {
      if (term.views.get(id) !== view || view.ws) return;
      view.xterm.reset();
      termOpenSocket(id, view);
    }, TERM_RETRY_MS);
  };
}

function termSend(view, message) {
  if (view.ws?.readyState === WebSocket.OPEN) view.ws.send(JSON.stringify(message));
}

function termDisposeView(id, view) {
  term.views.delete(id);
  const ws = view.ws;
  view.ws = null;
  ws?.close();
  view.xterm.dispose();
  view.box.remove();
}

function termFit(focus) {
  if (!termVisible()) return;
  const view = term.views.get(term.current);
  if (!view || view.box.hidden || !view.box.clientWidth || !view.box.clientHeight) return;
  try {
    view.fit.fit();
  } catch (e) {
    // ignore
  }
  if (focus) view.xterm.focus();
}

// 颜色取自页面主题变量, 主题切换时更新
function termTheme() {
  const style = getComputedStyle(document.documentElement);
  const value = (name) => style.getPropertyValue(name).trim();
  const background = value('--panel');
  return {
    background,
    foreground: value('--text'),
    cursor: value('--accent'),
    cursorAccent: background,
    selectionBackground: 'rgba(47, 107, 255, 0.3)',
  };
}

function termApplyTheme() {
  const theme = termTheme();
  term.views.forEach((view) => (view.xterm.options.theme = theme));
}

function termLoadSize() {
  let size = 0;
  try {
    size = Number(localStorage.getItem(TERM_SIZE_KEY)) || 0;
  } catch (e) {
    // ignore
  }
  return Math.max(TERM_SIZE.min, Math.min(TERM_SIZE.max, size || TERM_SIZE.value));
}

// 所有会话共用一个字号; 改字号后重新计算行列, 尺寸变化会通知 shell
function termSetSize(step) {
  term.fontSize = Math.max(TERM_SIZE.min, Math.min(TERM_SIZE.max, term.fontSize + step));
  term.views.forEach((view) => (view.xterm.options.fontSize = term.fontSize));
  termSyncSize();
  termFit(false);
  try {
    localStorage.setItem(TERM_SIZE_KEY, String(term.fontSize));
  } catch (e) {
    // ignore
  }
}

function termSyncSize() {
  $('termSizeLabel').textContent = term.fontSize;
  $('termSizeDown').disabled = term.fontSize <= TERM_SIZE.min;
  $('termSizeUp').disabled = term.fontSize >= TERM_SIZE.max;
}

function setupTerminal() {
  $('termSizeDown').addEventListener('click', () => termSetSize(-1));
  $('termSizeUp').addEventListener('click', () => termSetSize(1));
  termSyncSize();
  $('termNew').addEventListener('click', termCreate);
  $('termOpen').addEventListener('click', termCreate);
  term.observer = new ResizeObserver(() => termFit(false));
  term.observer.observe($('termViews'));
  new MutationObserver(termApplyTheme).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', termApplyTheme);
  termConnect();
}
