'use strict';

// 2D / 3D / 实时共用离线提示。App 目标提供已保存的日志和网络记录；设备目标说明重连状态。
// 设备在线时的实时画面独立于 App 是否已接入，不被 App 离线提示遮挡。
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
  const gone = !!targets.deviceId && currentDeviceGone();
  const hasApp = !!targets.bundleId;
  // 打开页面时 App 已在后台: 还没有任何层级可看, 画布空白时说明原因
  const away = !gone && hasApp && state.mode !== 'live' && appState.value === 'background' && !state.roots?.length;
  const show = gone || away || (state.mode !== 'live' && appState.value === 'offline' && appState.blank && hasApp);
  if (!show) {
    if (!offlineViewShown) return false;
    offlineViewShown = false;
    $('emptyState').hidden = true;
    $('emptyIntegration').hidden = false;
    $('emptyState').classList.remove('offline-state');
    document.body.classList.remove('has-empty', 'has-offline-state');
    if (!hasApp && targets.deviceId && currentDevice()) {
      showEmptyState(t('请选择 App 查看视图层级'), t('也可以切换到实时查看设备画面'));
    }
    return false;
  }
  const name = hasApp ? targetAppName(targets.deviceId, targets.bundleId) : '';
  const simulator = gone ? (targets.simulators || []).find((sim) => sim.id === targets.deviceId) : null;
  const deviceName = currentDevice()?.name || simulator?.name || targetHistory[targets.deviceId]?.name || t('设备');
  const booting = !!simulator && simPending.has(simulator.id);
  // 开机完成后要打开的就是当前 App
  const queued = booting && bootLaunch?.deviceId === targets.deviceId && bootLaunch.bundleId === targets.bundleId;
  const launching = pendingSwitch?.deviceId === targets.deviceId && pendingSwitch.bundleId === targets.bundleId;
  // 菜单每次刷新都会调用, 内容不变时不重建, 避免按钮在鼠标下闪动
  const key = [targets.deviceId, targets.bundleId, name, deviceName, gone, away, !!simulator, booting, queued, launching, !!currentDevice()].join('|');
  if (offlineViewShown && key === offlineViewKey) return true;
  const body = simulator ? t('模拟器 {0} 未启动, 启动后自动连接', deviceName)
    : gone ? t('设备 {0} 已断开, 重新连接后自动恢复', deviceName)
    : t('{0} 上没有运行, 启动后自动连接', deviceName);
  const title = away ? t('{0} 在后台', name) : hasApp ? t('{0} 未连接', name) : simulator
    ? (booting ? `${deviceName} · ${t('启动中…')}` : t('{0} 未启动', deviceName))
    : t('{0} 已断开', deviceName);
  const detail = away ? t('回到前台后自动显示视图层级') : hasApp ? body + (LANG === 'en' ? '. ' : '。') + t('可以先查看本机保存的日志和抓包') : body;
  showEmptyState(title, detail);
  $('emptyState').classList.add('offline-state');
  document.body.classList.add('has-offline-state');
  $('liveGuide').hidden = true;
  $('liveLoading').hidden = true;
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
  if (hasApp) actions.append(paneButton(t('查看日志'), 'log'), paneButton(t('查看网络'), 'net'));
  if (simulator) {
    const boot = el('button', 'offline-action primary', (hasApp ? queued : booting) ? t('启动中…') : hasApp ? t('启动 App') : t('启动'));
    boot.disabled = hasApp ? queued : booting;
    if (hasApp) boot.title = booting ? t('模拟器正在启动, 完成后打开这个 App') : t('先启动模拟器, 再打开这个 App');
    boot.addEventListener('click', () => hasApp ? bootAndLaunch(simulator, targets.bundleId, name) : simulatorAction(simulator.id, 'boot', false));
    actions.append(boot);
  } else if (hasApp && !gone && currentDevice()) {
    const launch = el('button', 'offline-action primary', launching ? t('启动中…') : away ? t('切到前台') : t('启动 App'));
    launch.disabled = launching;
    launch.addEventListener('click', () => launchAwayApp(targets.deviceId, targets.bundleId, name));
    actions.append(launch);
  }
  $('emptyGuide').replaceChildren(actions);
  $('emptyGuide').hidden = !actions.childElementCount;
  return true;
}
