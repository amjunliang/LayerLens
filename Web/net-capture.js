'use strict';

// 抓包开关与保存的启动. 开关按设备 + Bundle ID 记在目标历史中(默认关闭), 由 Mac 端同步给 App, 记录都保存在本机;
// 关闭时面板只显示开启按钮. 也可选择该设备上以前的某次启动只读查看, 可搜索和导出 HAR

// 目标历史中当前 App 的开关
function netCaptureSetting() {
  return !!targetHistory[targets.deviceId]?.apps?.[targets.bundleId]?.capture;
}

function syncNetCapture() {
  const button = $('netCapture');
  const on = net.capture === true;
  button.classList.toggle('on', on);
  button.setAttribute('aria-pressed', String(on));
  button.disabled = !logTargetKey() || net.capture === null;
  button.title = on ? t('正在抓包, 记录保存在本机. 点击关闭') : t('开启抓包: 请求记录保存在本机, App 息屏或退出后仍可查看');
  $('netClear').disabled = !!net.session;
}

async function setNetCapture(enabled) {
  const key = logTargetKey();
  if (!key) return;
  try {
    const res = await fetch('/api/hub/network/capture', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device: targets.deviceId, app: targets.bundleId, enabled }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    if (data.history) replaceTargetHistory(data.history);
  } catch (e) {
    toast(t('设置失败: {0}', e.message), true);
    return;
  }
  if (key !== logTargetKey()) return;
  toast(enabled ? t('已开启抓包, App 下次冷启动也会自动记录') : t('已关闭抓包, 保存的记录可在缓存管理中删除'));
  net.capture = enabled;
  net.session = '';
  resetNet();
  if (net.active) netConnect();
}

// 目标列表轮询带回的开关与面板不一致(其他窗口切换过)时重新连接
function netCaptureHistoryChanged() {
  if (!net.active || net.capture === null || net.session || !logTargetKey()) return;
  if (netCaptureSetting() === net.capture) return;
  resetNet();
  netConnect();
}

// 关闭时的空状态: 提示和开启按钮
function netCaptureOffEmpty() {
  const button = el('button', 'net-capture-on', t('开启抓包'));
  button.addEventListener('click', () => setNetCapture(true));
  const hint = net.sessions.some((session) => !session.current || !net.capture) ? t('也可以在右上角选择以前保存的启动查看') : '';
  return [el('div', 'net-capture-title', t('未开启抓包')), el('div', 'net-capture-hint', t('开启后请求记录保存在本机, App 息屏或退出后仍可查看') + (hint ? '. ' + hint : '')), button];
}

// MARK: - Sessions

function netSessionParams(params = {}) {
  return net.session ? { ...params, session: net.session } : params;
}

async function loadNetSessions() {
  const key = logTargetKey();
  if (!key) {
    net.sessions = [];
    renderNetSessions();
    return;
  }
  try {
    const res = await fetch('/api/hub/network/sessions?' + new URLSearchParams({ device: targets.deviceId, app: targets.bundleId }));
    const data = await res.json().catch(() => ({}));
    if (key !== logTargetKey()) return;
    net.sessions = res.ok ? data.sessions || [] : [];
  } catch (e) {
    net.sessions = [];
  }
  renderNetSessions();
}

// 开启时当前启动由「当前」显示, 不重复列出
function renderNetSessions() {
  const select = $('netSession');
  const items = net.sessions.filter((session) => !(session.current && net.capture));
  const options = [el('option', '', net.capture ? t('当前启动') : t('选择保存的启动'))];
  options[0].value = '';
  for (const session of items) {
    const option = el('option', '', `${logFullTime(session.start).slice(5, 19)} · ${t('{0} 个请求', session.count || 0)}`);
    option.value = session.id;
    options.push(option);
  }
  select.replaceChildren(...options);
  if (net.session && !items.some((session) => session.id === net.session)) net.session = '';
  select.value = net.session;
  select.hidden = !items.length;
  select.title = net.session ? t('正在查看以前的启动, 只读') : t('查看以前保存的启动');
}

function selectNetSession(id) {
  if (id === net.session) return;
  net.session = id;
  resetNet();
  if (net.active) netConnect();
}

// 缓存管理中打开某次启动的抓包
function openNetSession(id) {
  net.session = id;
  resetNet();
  closePanel();
  if (!logVisible() || net.tab !== 'net') showPaneTab('net');
  else netConnect();
}

function setupNetCapture() {
  $('netCapture').addEventListener('click', () => setNetCapture(net.capture !== true));
  const select = $('netSession');
  select.addEventListener('change', () => selectNetSession(select.value));
}
