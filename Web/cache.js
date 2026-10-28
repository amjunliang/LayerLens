'use strict';

// 缓存管理: 按 App 列出 LayerLens 在本机保存的每次启动(日志和抓包合并), 可展开预览, 可按启动、按 App 或全部删除.
// 缓存都不设上限, 由用户在这里清理; 当前 App 排在最前并默认展开
// 当前打开的缓存面板, 面板关闭或重新打开后旧的请求结果不再渲染
let cacheView = null;

// 每个 App 默认显示的启动数, 其余点击后显示
const CACHE_LAUNCH_LIMIT = 10;

function cachePanel() {
  const root = el('div', 'cache');
  cacheView = { root, data: null, expanded: new Set([targets.bundleId]), all: new Set(), open: '', previews: new Map() };
  root.appendChild(el('p', 'log-files-empty', t('正在加载…')));
  cacheRequest(fetch('/api/hub/cache'));
  return [root];
}

async function cacheRequest(promise) {
  const view = cacheView;
  try {
    const res = await promise;
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    if (view !== cacheView) return;
    view.data = data;
    cacheRender();
  } catch (e) {
    if (view === cacheView) view.root.replaceChildren(el('p', 'log-files-empty', t('无法读取缓存: {0}', e.message)));
  }
}

function cacheDelete(body) {
  // 删除后同步刷新面板的启动选择
  cacheRequest(fetch('/api/hub/cache/delete', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  }).finally(() => loadLaunches()));
}

// 删除前在气泡中确认, 说明删除的范围
function cacheConfirmButton(text, confirm, action) {
  const button = el('button', 'cache-btn', text);
  button.addEventListener('click', (e) => {
    e.stopPropagation();
    showConfirm(button, { ...confirm, action: t('删除'), onConfirm: () => {
      button.disabled = true;
      action();
    } });
  });
  return button;
}

function cacheAppName(bundleId) {
  for (const device of Object.values(targetHistory)) {
    const name = device?.apps?.[bundleId]?.appName;
    if (name) return name;
  }
  return '';
}

function cacheRender() {
  const view = cacheView;
  const data = view.data || {};
  const apps = (data.apps || []).slice().sort((a, b) => (b.bundleId === targets.bundleId) - (a.bundleId === targets.bundleId));
  const count = apps.reduce((sum, app) => sum + app.launches.length, 0);
  const head = el('div', 'cache-head');
  head.appendChild(el('span', 'cache-total', count ? t('{0} 个 App, {1} 次启动, 共 {2}', apps.length, count, logSize(data.size || 0)) : t('没有缓存')));
  if (count) head.appendChild(cacheConfirmButton(t('全部删除'), { title: t('删除全部缓存?'), detail: t('{0} 次启动, 共 {1}, 无法恢复', count, logSize(data.size || 0)), items: apps.map((app) => cacheAppName(app.bundleId) || app.bundleId) }, () => cacheDelete({ all: true })));
  view.root.replaceChildren(head, ...apps.map(cacheAppCard));
}

function cacheAppCard(app) {
  const view = cacheView;
  const expanded = view.expanded.has(app.bundleId);
  const card = el('div', 'cache-card' + (expanded ? ' expanded' : ''));
  const head = el('div', 'cache-card-head');
  head.setAttribute('role', 'button');
  head.tabIndex = 0;
  head.setAttribute('aria-expanded', String(expanded));
  const name = el('span', 'cache-app', cacheAppName(app.bundleId) || app.bundleId);
  if (app.bundleId === targets.bundleId) name.appendChild(el('span', 'cache-current', t('当前 App')));
  const title = el('span', 'cache-app-title');
  title.appendChild(name);
  if (cacheAppName(app.bundleId)) title.appendChild(el('span', 'cache-bundle', app.bundleId));
  head.append(el('span', 'cache-chevron', '›'), title, el('span', 'cache-meta', t('{0} 次启动 · {1}', app.launches.length, logSize(app.size || 0))), cacheConfirmButton(t('删除'), { title: t('删除 {0} 的全部缓存?', cacheAppName(app.bundleId) || app.bundleId), detail: t('{0} 次启动, 共 {1}, 无法恢复', app.launches.length, logSize(app.size || 0)) }, () => cacheDelete({ app: app.bundleId })));
  const toggle = () => {
    if (view.expanded.has(app.bundleId)) view.expanded.delete(app.bundleId);
    else view.expanded.add(app.bundleId);
    cacheRender();
  };
  head.addEventListener('click', toggle);
  head.addEventListener('keydown', (e) => {
    if (e.target !== head || (e.key !== 'Enter' && e.key !== ' ')) return;
    e.preventDefault();
    toggle();
  });
  card.appendChild(head);
  if (!expanded) return card;
  const body = el('div', 'cache-card-body');
  const all = view.all.has(app.bundleId);
  const shown = all ? app.launches : app.launches.slice(0, CACHE_LAUNCH_LIMIT);
  let day = '';
  for (const launch of shown) {
    const date = logFullTime(launch.start || launch.time).slice(0, 10);
    if (date !== day) {
      day = date;
      body.appendChild(el('div', 'cache-day', date));
    }
    body.appendChild(cacheLaunchRow(app.bundleId, launch));
    if (view.open === app.bundleId + '|' + launch.id) body.appendChild(cachePreview(app.bundleId, launch));
  }
  if (!all && app.launches.length > shown.length) {
    const more = el('button', 'cache-more', t('显示更早的 {0} 次', app.launches.length - shown.length));
    more.addEventListener('click', () => {
      view.all.add(app.bundleId);
      cacheRender();
    });
    body.appendChild(more);
  }
  card.appendChild(body);
  return card;
}

function cacheLaunchRow(bundleId, launch) {
  const view = cacheView;
  const key = bundleId + '|' + launch.id;
  const open = view.open === key;
  const row = el('div', 'cache-launch' + (open ? ' open' : ''));
  row.setAttribute('role', 'button');
  row.tabIndex = 0;
  row.setAttribute('aria-expanded', String(open));
  const info = el('span', 'cache-launch-info');
  info.append(el('span', 'cache-time', logFullTime(launch.start || launch.time).slice(11, 16)), el('span', 'cache-device', launch.device || t('未知设备')));
  if (bundleId === targets.bundleId && launch.id === launchState.current) info.appendChild(el('span', 'cache-current', t('当前启动')));
  const tags = el('span', 'cache-tags');
  if (launch.log) tags.appendChild(el('span', 'cache-kind', t('日志 {0}', logSize(launch.log.size || 0))));
  if (launch.network) tags.appendChild(el('span', 'cache-kind network', t('抓包 {0} 个', launch.network.count || 0)));
  const remove = el('button', 'icon-btn cache-remove');
  remove.title = t('删除这次启动');
  remove.setAttribute('aria-label', t('删除这次启动'));
  remove.innerHTML = '<svg class="icon"><use href="#i-trash"/></svg>';
  remove.addEventListener('click', (e) => {
    e.stopPropagation();
    remove.disabled = true;
    if (view.open === key) view.open = '';
    cacheDelete({ ids: [launch.log?.id, launch.network?.id].filter(Boolean) });
  });
  row.append(el('span', 'cache-chevron', '›'), info, tags, remove);
  row.title = t('最后修改 {0}', logFullTime(launch.time).slice(0, 19));
  const toggle = () => {
    view.open = view.open === key ? '' : key;
    cacheRender();
  };
  row.addEventListener('click', toggle);
  row.addEventListener('keydown', (e) => {
    if (e.target !== row || (e.key !== 'Enter' && e.key !== ' ')) return;
    e.preventDefault();
    toggle();
  });
  return row;
}

function cacheReadLog(id) {
  return (offset, length) => fetch('/api/hub/cache/log?' + new URLSearchParams({ id, offset, length })).then(async (r) => {
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return { data: await r.arrayBuffer(), total: Number(r.headers.get('X-Log-Total')) || 0 };
  });
}

// 展开的预览: 日志最后 20 行和前 10 个请求, 可在面板中打开完整内容
function cachePreview(bundleId, launch) {
  const view = cacheView;
  const key = bundleId + '|' + launch.id;
  const box = el('div', 'cache-preview');
  const preview = view.previews.get(key);
  if (!preview) {
    box.appendChild(el('p', 'cache-preview-empty', t('正在加载…')));
    fetch('/api/hub/cache/preview?' + new URLSearchParams({ app: bundleId, launch: launch.id }))
      .then((res) => (res.ok ? res.json() : Promise.reject(new Error(`HTTP ${res.status}`))))
      .catch((e) => ({ error: e.message }))
      .then((data) => {
        if (view !== cacheView) return;
        view.previews.set(key, data || {});
        if (view.open === key) cacheRender();
      });
    return box;
  }
  if (preview.error) {
    box.appendChild(el('p', 'cache-preview-empty', t('无法读取: {0}', preview.error)));
    return box;
  }
  // 旧版本保存的日志没有设备标记, 按设备名判断
  const deviceName = currentDevice()?.name || targetHistory[targets.deviceId]?.name || '';
  const linked = bundleId === targets.bundleId && (launch.deviceId ? launch.deviceId === targets.deviceId : !!launch.device && launch.device === deviceName);
  if (launch.log) {
    box.appendChild(el('div', 'cache-preview-title', t('日志 · 最后 {0} 行', (preview.log || []).length)));
    box.appendChild(el('pre', 'cache-preview-log', (preview.log || []).join('\n') || t('没有日志')));
  }
  if (launch.network) {
    const requests = preview.requests || [];
    box.appendChild(el('div', 'cache-preview-title', t('请求 · 前 {0} 个, 共 {1} 个', requests.length, launch.network.count || 0)));
    const list = el('div', 'cache-preview-requests');
    for (const request of requests) {
      const status = Number(request.status) || 0;
      const row = el('div', 'cache-request');
      row.append(el('span', 'cache-request-method', request.method || ''), el('span', 'cache-request-status' + (status >= 400 || !status ? ' failed' : ''), status ? String(status) : t('失败')), el('span', 'cache-request-url', request.url || ''));
      row.title = request.url || '';
      list.appendChild(row);
    }
    if (!requests.length) list.appendChild(el('p', 'cache-preview-empty', t('没有请求')));
    box.appendChild(list);
  }
  const actions = el('div', 'cache-preview-actions');
  if (launch.log) {
    const button = el('button', 'cache-btn', t('在日志面板打开'));
    button.addEventListener('click', () => {
      if (linked) {
        openLaunch(launch.id, 'log');
        return;
      }
      // 其他 App 或设备的日志按文件只读打开, 不影响当前 App 的启动选择
      closePanel();
      setPaneTab('log');
      openLogFile(t('{0} · {1} 的启动', cacheAppName(bundleId) || bundleId, launchTime(launch)), launch.log.size || 0, cacheReadLog(launch.log.id));
    });
    actions.appendChild(button);
  }
  if (launch.network && linked) {
    const button = el('button', 'cache-btn', t('在网络面板打开'));
    button.addEventListener('click', () => openLaunch(launch.id, 'net'));
    actions.appendChild(button);
  }
  if (launch.network && !linked) actions.appendChild(el('span', 'cache-preview-hint', t('切换到这个 App 后可在网络面板查看')));
  box.appendChild(actions);
  return box;
}
