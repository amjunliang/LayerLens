'use strict';

// 缓存管理: 按 App 列出 LayerLens 在本机保存的日志文件和抓包记录, 可单独删除, 也可按 App 或全部删除.
// 缓存都不设上限, 由用户在这里清理; 当前 App 排在最前
// 当前打开的缓存面板, 面板关闭或重新打开后旧的请求结果不再渲染
let cacheView = null;

function cachePanel() {
  const root = el('div', 'cache');
  cacheView = { root };
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
    if (view === cacheView) cacheRender(data);
  } catch (e) {
    if (view === cacheView) view.root.replaceChildren(el('p', 'log-files-empty', t('无法读取缓存: {0}', e.message)));
  }
}

function cacheDelete(body) {
  cacheRequest(fetch('/api/hub/cache/delete', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  }));
}

// 删除前在气泡中确认, 说明删除的范围
function cacheConfirmButton(text, confirm, action) {
  const button = el('button', 'cache-btn', text);
  button.addEventListener('click', () => showConfirm(button, { ...confirm, action: t('删除'), onConfirm: () => {
    button.disabled = true;
    action();
  } }));
  return button;
}

function cacheRender(data) {
  const view = cacheView;
  const apps = (data.apps || []).slice().sort((a, b) => (b.bundleId === targets.bundleId) - (a.bundleId === targets.bundleId));
  const count = apps.reduce((sum, app) => sum + app.items.length, 0);
  const head = el('div', 'cache-head');
  head.appendChild(el('span', 'cache-total', count ? t('共 {0} 项, {1}', count, logSize(data.size || 0)) : t('没有缓存')));
  if (count) head.appendChild(cacheConfirmButton(t('全部删除'), { title: t('删除全部缓存?'), detail: t('共 {0} 项, {1}', count, logSize(data.size || 0)), items: apps.map((app) => app.bundleId) }, () => cacheDelete({ all: true })));
  const nodes = [head];
  for (const app of apps) {
    const group = el('div', 'cache-group');
    const groupHead = el('div', 'cache-group-head');
    const name = el('span', 'cache-app', app.bundleId);
    if (app.bundleId === targets.bundleId) name.appendChild(el('span', 'cache-current', t('当前 App')));
    groupHead.append(name, el('span', 'cache-meta', logSize(app.size || 0)), cacheConfirmButton(t('删除'), { title: t('删除 {0} 的全部缓存?', app.bundleId), detail: t('共 {0} 项, {1}', app.items.length, logSize(app.size || 0)) }, () => cacheDelete({ app: app.bundleId })));
    group.appendChild(groupHead);
    for (const item of app.items) {
      const row = el('div', 'cache-row');
      const network = item.kind === 'network';
      const title = network ? [item.device, logFullTime(item.start || item.time).slice(0, 19)].filter(Boolean).join(' · ') : item.name.replace(/\.log$/, '');
      const meta = network ? t('{0} 个请求 · {1}', item.count || 0, logSize(item.size || 0)) : logSize(item.size || 0);
      const remove = el('button', 'icon-btn cache-remove');
      remove.title = t('删除');
      remove.setAttribute('aria-label', t('删除'));
      remove.innerHTML = '<svg class="icon"><use href="#i-trash"/></svg>';
      remove.addEventListener('click', () => {
        remove.disabled = true;
        cacheDelete({ ids: [item.id] });
      });
      row.append(el('span', 'cache-kind' + (network ? ' network' : ''), network ? t('抓包') : t('日志')), el('span', 'cache-name', title), el('span', 'cache-meta', meta), remove);
      row.title = t('最后修改 {0}', logFullTime(item.time).slice(0, 19));
      // 当前设备上当前 App 的抓包可直接在网络面板中查看
      if (network && item.deviceId === targets.deviceId && app.bundleId === targets.bundleId) {
        row.classList.add('openable');
        row.title += '\n' + t('点击在网络面板中查看');
        row.addEventListener('click', (e) => {
          if (!e.target.closest('button')) openNetSession(item.name);
        });
      }
      group.appendChild(row);
    }
    nodes.push(group);
  }
  view.root.replaceChildren(...nodes);
}
