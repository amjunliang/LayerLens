'use strict';

// App 的每次启动: 本机按启动保存日志和抓包, 日志面板和网络面板共用一个启动选择, 切换时两边联动.
// 各面板的下拉框只列出有该类内容的启动, 选中的启动没有另一类内容时另一个面板保持显示当前启动.
// 「当前启动」在 App 连接时是实时内容, 未连接时是该设备上最近一次启动; 选择以前的启动时只读查看,
// 实时记录在后台继续, 返回当前不丢内容

// list: Mac 端返回的启动, 新的在前; current: 当前启动的 id; selected: 选中的以前的启动, 空为当前
const launchState = { key: '', list: [], current: '', selected: '', token: 0 };

function launchById(id) {
  return launchState.list.find((item) => item.id === id) || null;
}

// 以前的启动, 不含当前启动
function pastLaunches() {
  return launchState.list.filter((item) => item.id !== launchState.current);
}

function launchTime(item) {
  return logFullTime(item?.start || item?.time).slice(5, 16);
}

// 下拉框只显示所在面板的内容: 日志面板显示日志大小, 网络面板显示请求数
function launchLabel(item, kind) {
  return `${launchTime(item)} · ${kind === 'log' ? logSize(item.log.size || 0) : t('{0} 个请求', item.network.count || 0)}`;
}

// 当前启动与以前的启动格式一致: 时间 · 当前; 内容还在增加, 不显示大小和请求数
function currentLaunchLabel(offline) {
  const item = launchById(launchState.current);
  const state = offline ? t('当前 · 离线') : t('当前');
  return item ? `${launchTime(item)} · ${state}` : offline ? t('当前启动 (离线)') : t('当前启动');
}

// 下拉框宽度跟随选中项的文字, 原生 select 默认按最长的选项撑开.
// 用同样字体的隐藏元素测量, 比 canvas 准确; 箭头按系统控件留足空间
let launchMeasure = null;

function fitLaunchSelect(select) {
  if (!launchMeasure) {
    launchMeasure = el('span', 'launch-measure');
    document.body.appendChild(launchMeasure);
  }
  const style = getComputedStyle(select);
  launchMeasure.style.font = style.font;
  launchMeasure.style.letterSpacing = style.letterSpacing;
  launchMeasure.textContent = select.selectedOptions[0]?.text || '';
  const width = launchMeasure.getBoundingClientRect().width;
  select.style.width = Math.ceil(width + parseFloat(style.paddingLeft) + parseFloat(style.paddingRight) + parseFloat(style.borderLeftWidth) + parseFloat(style.borderRightWidth) + 30) + 'px';
}

// 有该类内容的以前的启动
function pastLaunchesOf(kind) {
  return pastLaunches().filter((item) => (kind === 'log' ? item.log : item.network));
}

// 目标切换后清空启动选择, 返回是否切换了目标
function syncLaunchTarget() {
  const key = logTargetKey();
  if (key === launchState.key) return false;
  launchState.key = key;
  launchState.list = [];
  launchState.current = '';
  const selected = launchState.selected;
  launchState.selected = '';
  if (selected && logs.file?.launch) {
    logs.source = 'live';
    logs.file = null;
    if (logs.active) logConnect();
  }
  renderLaunchSelects();
  return true;
}

async function loadLaunches() {
  syncLaunchTarget();
  const key = logTargetKey();
  const token = ++launchState.token;
  if (!key) return;
  let data = {};
  try {
    // 旧版本保存的日志没有设备标记, 按设备名匹配
    const name = currentDevice()?.name || targetHistory[targets.deviceId]?.name || '';
    const res = await fetch('/api/hub/launches?' + new URLSearchParams({ device: targets.deviceId, app: targets.bundleId, name }));
    data = res.ok ? await res.json().catch(() => ({})) : {};
  } catch (e) {
    data = {};
  }
  if (token !== launchState.token || key !== logTargetKey()) return;
  launchState.list = data.launches || [];
  // App 未连接且 Hub 没有记录过这台设备时, 面板显示的是最近一次启动
  const current = launchState.list.find((item) => item.current) || (appState.value === 'offline' ? launchState.list[0] : null);
  launchState.current = current?.id || '';
  // App 重新启动等导致当前启动变化时, 网络面板换成新的当前启动
  if (net.archive && net.archive !== currentLaunchNetSession() && net.active && !net.session) {
    resetNet();
    netConnect();
  }
  // 选中的启动被删除或成了当前启动时回到当前
  if (launchState.selected && !pastLaunches().some((item) => item.id === launchState.selected)) selectLaunch('');
  else renderLaunchSelects();
}

function renderLaunchSelects() {
  const offline = appState.value === 'offline';
  for (const [select, kind] of [[$('netSession'), 'net'], [$('logLaunch'), 'log']]) {
    if (!select) continue;
    const items = pastLaunchesOf(kind);
    const selected = items.some((item) => item.id === launchState.selected) ? launchState.selected : '';
    const first = el('option', '', currentLaunchLabel(offline));
    first.value = '';
    const options = [first];
    for (const item of items) {
      const option = el('option', '', launchLabel(item, kind));
      option.value = item.id;
      options.push(option);
    }
    select.replaceChildren(...options);
    select.value = selected;
    // 只有当前启动时也显示, 标明正在看的是哪次启动
    select.hidden = !items.length && !launchById(launchState.current);
    fitLaunchSelect(select);
    select.title = selected ? t('正在查看以前的启动, 只读') : offline ? t('App 未连接, 显示的是这台设备上最近一次启动') : t('查看以前保存的启动');
  }
}

// 当前启动保存的抓包会话, 未开启抓包时网络面板只读显示它
function currentLaunchNetSession() {
  return launchById(launchState.current)?.network?.session || '';
}

// 选中的启动对应的抓包会话
function launchNetSession() {
  return launchById(launchState.selected)?.network?.session || '';
}

// 两个面板同时切换到该启动; id 为空时回到当前启动
function selectLaunch(id) {
  const item = id ? launchById(id) : null;
  if (id && !item) return;
  launchState.selected = id;
  renderLaunchSelects();
  applyLaunchLog();
  const session = launchNetSession();
  if (session !== net.session) {
    net.session = session;
    resetNet();
    if (net.active) netConnect();
  }
}

// 日志面板显示选中的启动; 面板未显示时等显示后再加载
function applyLaunchLog() {
  if (!logs.active) return;
  const item = launchById(launchState.selected);
  if (!item?.log) {
    if (logs.file?.launch) {
      logs.source = 'live';
      logs.file = null;
      logConnect();
    }
    return;
  }
  if (logs.file?.launch === item.id) return;
  const name = t('正在查看 {0} 的启动', launchTime(item));
  openLogFile(name, item.log.size || 0, cacheReadLog(item.log.id));
  logs.file.launch = item.id;
}

// 日志面板显示时: 有选中的启动则打开它, 否则连接实时日志
function logResume() {
  if (launchById(launchState.selected)?.log) applyLaunchLog();
  else logConnect();
  loadLaunches();
}

// 缓存管理中打开当前 App 的某次启动, show 为要显示的面板
function openLaunch(id, show) {
  closePanel();
  if (!logVisible() || net.tab !== show) showPaneTab(show);
  if (id === launchState.current) selectLaunch('');
  else if (launchById(id)) selectLaunch(id);
  else {
    // 列表还没加载, 加载后再选择
    loadLaunches().then(() => selectLaunch(id === launchState.current ? '' : id));
  }
}

function setupLaunches() {
  for (const select of [$('netSession'), $('logLaunch')]) {
    select?.addEventListener('change', () => selectLaunch(select.value));
  }
  $('netBackCurrent')?.addEventListener('click', () => selectLaunch(''));
}
