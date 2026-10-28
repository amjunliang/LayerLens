'use strict';

// 选中未连接的 App 且还没有层级时, 画布中央说明状态, 并提供查看本机保存的日志和抓包的入口;
// 设备在线时可直接启动. 连上后整页刷新或原地更新, 这里随状态隐藏
let offlineViewShown = false;
let offlineViewKey = '';
// 未启动的模拟器: 点「启动 App」先开机, 开机后打开 App; 开机期间切到同一设备的其他 App 再点, 以最后一次为准
let bootLaunch = null;

function bootAndLaunch(simulator, bundleId, appName) {
  bootLaunch = { deviceId: simulator.id, bundleId, appName };
  if (!simPending.has(simulator.id)) simulatorAction(simulator.id, 'boot', false);
  syncOfflineView();
}

// 列表刷新后调用: 开机完成时, 仍选中着最后点击的 App 才打开; 开机失败或超时放弃
function settleBootLaunch() {
  if (!bootLaunch) return;
  const { deviceId, bundleId, appName } = bootLaunch;
  if (targets.devices.some((d) => d.id === deviceId)) {
    bootLaunch = null;
    if (targets.deviceId === deviceId && targets.bundleId === bundleId && !currentApp()) launchAwayApp(deviceId, bundleId, appName);
    return;
  }
  if (!simPending.has(deviceId)) bootLaunch = null;
}

function syncOfflineView() {
  const show = appState.value === 'offline' && appState.blank && !!targets.bundleId;
  if (!show) {
    if (!offlineViewShown) return;
    offlineViewShown = false;
    $('emptyState').hidden = true;
    $('emptyIntegration').hidden = false;
    document.body.classList.remove('has-empty');
    return;
  }
  const name = targetHistory[targets.deviceId]?.apps?.[targets.bundleId]?.appName || targets.bundleId;
  const gone = currentDeviceGone();
  const simulator = gone ? (targets.simulators || []).find((sim) => sim.id === targets.deviceId) : null;
  const deviceName = currentDevice()?.name || simulator?.name || targetHistory[targets.deviceId]?.name || t('设备');
  const booting = !!simulator && simPending.has(simulator.id);
  // 开机完成后要打开的就是当前 App
  const queued = booting && bootLaunch?.deviceId === targets.deviceId && bootLaunch.bundleId === targets.bundleId;
  const launching = pendingSwitch?.deviceId === targets.deviceId && pendingSwitch.bundleId === targets.bundleId;
  // 菜单每次刷新都会调用, 内容不变时不重建, 避免按钮在鼠标下闪动
  const key = [name, deviceName, gone, !!simulator, booting, queued, launching, !!currentDevice()].join('|');
  if (offlineViewShown && key === offlineViewKey) return;
  const body = simulator ? t('模拟器 {0} 未启动, 启动后自动连接', deviceName)
    : gone ? t('设备 {0} 已断开, 重新连接后自动恢复', deviceName)
    : t('{0} 上没有运行, 启动后自动连接', deviceName);
  showEmptyState(t('{0} 未连接', name), body + '. ' + t('可以先查看本机保存的日志和抓包'));
  offlineViewShown = true;
  offlineViewKey = key;
  $('emptyIntegration').hidden = true;
  const actions = el('div', 'offline-actions');
  const paneButton = (text, tab) => {
    const button = el('button', 'offline-action', text);
    button.addEventListener('click', () => {
      if (!logVisible() || net.tab !== tab) showPaneTab(tab);
    });
    return button;
  };
  actions.append(paneButton(t('查看日志'), 'log'), paneButton(t('查看网络'), 'net'));
  if (simulator) {
    const boot = el('button', 'offline-action primary', queued ? t('启动中…') : t('启动 App'));
    boot.disabled = queued;
    boot.title = booting ? t('模拟器正在启动, 完成后打开这个 App') : t('先启动模拟器, 再打开这个 App');
    boot.addEventListener('click', () => bootAndLaunch(simulator, targets.bundleId, name));
    actions.append(boot);
  } else if (!gone && currentDevice()) {
    const launch = el('button', 'offline-action primary', launching ? t('启动中…') : t('启动 App'));
    launch.disabled = launching;
    launch.addEventListener('click', () => launchAwayApp(targets.deviceId, targets.bundleId, name));
    actions.append(launch);
  }
  $('emptyGuide').replaceChildren(actions);
  $('emptyGuide').hidden = false;
}
