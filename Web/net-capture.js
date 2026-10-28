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
  // 只读查看保存的记录时不能清空, 在缓存管理中删除
  $('netClear').disabled = !!(net.session || net.archive);
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
  // 查看以前的启动时不受开关影响
  if (net.session) {
    syncNetCapture();
    return;
  }
  resyncNet();
}

// 开关切换后重新连接: 保留已显示的请求, 新连接从头取一遍按 id 合并, 避免清空后重新加载造成闪烁
function resyncNet() {
  net.resync = true;
  if (net.active) netConnect();
}

// 目标列表轮询带回的开关与面板不一致(其他窗口切换过)时重新连接
function netCaptureHistoryChanged() {
  if (!net.active || net.capture === null || net.session || !logTargetKey()) return;
  if (netCaptureSetting() === net.capture) return;
  resyncNet();
}

// 关闭时的空状态: 提示和开启按钮
function netCaptureOffEmpty() {
  const button = el('button', 'net-capture-on', t('开启抓包'));
  button.addEventListener('click', () => setNetCapture(true));
  const hint = pastLaunchesOf('net').length ? t('也可以在右上角选择以前保存的启动查看') : '';
  return [el('div', 'net-capture-title', t('未开启抓包')), el('div', 'net-capture-hint', t('开启后请求记录保存在本机, App 息屏或退出后仍可查看') + (hint ? '. ' + hint : '')), button];
}

// MARK: - Sessions

// 选中以前的启动时只读查看该启动保存的抓包, 启动选择见 launches.js
function netSessionParams(params = {}) {
  const session = net.session || net.archive;
  return session ? { ...params, session } : params;
}

function setupNetCapture() {
  $('netCapture').addEventListener('click', () => setNetCapture(net.capture !== true));
}
