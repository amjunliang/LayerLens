'use strict';

// MCP 设置: 检测 Claude Code 和 Codex, 一键安装或移除 LayerLens 的 MCP 与 Skill, 以及登录时启动.
// 命令由 Mac App 执行(/api/hub/mcp/clients*), 面板只展示状态
let mcpSetupView = null;
const MCP_HINT_KEY = 'layerlens_mcp_hint_shown';

const MCP_STATE_TEXT = {
  installed: '已安装',
  missing: '未安装',
  different: '地址不同',
  outdated: '有更新',
  conflict: '已有同名文件',
  unknown: '无法检测',
};

function mcpSetupPanel() {
  const root = el('div', 'mcp-setup');
  mcpSetupView = { root, data: null, busy: false, errors: [] };
  root.appendChild(el('p', 'log-files-empty', t('正在检测…')));
  mcpSetupRequest(fetch('/api/hub/mcp/clients'));
  return [root];
}

async function mcpSetupRequest(promise) {
  const view = mcpSetupView;
  if (view) { view.busy = true; if (view.data) mcpSetupRender(); }
  try {
    const res = await promise;
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    if (view !== mcpSetupView) return data;
    view.data = data;
    view.errors = data.errors || [];
    view.busy = false;
    mcpSetupRender();
    return data;
  } catch (e) {
    if (view === mcpSetupView) {
      view.busy = false;
      view.root.replaceChildren(el('p', 'log-files-empty', t('无法检测: {0}', e.message)));
    }
    return null;
  }
}

function mcpSetupPost(path, body) {
  return mcpSetupRequest(fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  }));
}

function mcpSetupButton(text, onClick, primary) {
  const button = el('button', primary ? 'cache-btn mcp-primary' : 'cache-btn', text);
  button.disabled = !!mcpSetupView?.busy;
  button.addEventListener('click', (e) => {
    e.stopPropagation();
    onClick();
  });
  return button;
}

function mcpPartRow(client, part, state) {
  const row = el('div', 'mcp-part');
  row.appendChild(el('span', 'mcp-part-name', part === 'mcp' ? 'MCP' : 'Skill'));
  row.appendChild(el('span', `mcp-state mcp-state-${state}`, t(MCP_STATE_TEXT[state] || state)));
  const actions = el('span', 'mcp-part-actions');
  const post = (action) => mcpSetupPost(`/api/hub/mcp/clients/${action}`, { client: client.id, parts: [part] });
  if (state === 'missing') actions.appendChild(mcpSetupButton(t('安装'), () => post('install')));
  if (state === 'different' || state === 'outdated') actions.appendChild(mcpSetupButton(t('更新'), () => post('install')));
  if (state === 'installed' || state === 'different' || state === 'outdated') actions.appendChild(mcpSetupButton(t('移除'), () => post('remove')));
  row.appendChild(actions);
  return row;
}

function mcpClientCard(client) {
  const card = el('div', 'cache-card mcp-client');
  const head = el('div', 'mcp-client-head');
  head.appendChild(el('span', 'cache-app', client.name));
  head.appendChild(el('span', 'cache-bundle', client.found ? client.path : t('未检测到命令行工具')));
  card.appendChild(head);
  if (client.found) {
    card.appendChild(mcpPartRow(client, 'mcp', client.mcp));
    if (client.mcp === 'different' && client.mcpURL) card.appendChild(el('div', 'mcp-detail', t('当前配置: {0}', client.mcpURL)));
  } else {
    card.appendChild(el('div', 'mcp-detail', client.id === 'claude'
      ? t('安装 Claude Code 后重新打开此面板; 桌面版的 Code 标签页与终端共用配置')
      : t('安装 Codex CLI 或 ChatGPT 桌面版后重新打开此面板')));
  }
  card.appendChild(mcpPartRow(client, 'skill', client.skill));
  if (client.error) card.appendChild(el('div', 'mcp-detail mcp-error', client.error));
  return card;
}

function mcpSetupRender() {
  const view = mcpSetupView;
  const data = view.data || {};
  const clients = data.clients || [];
  const pending = clients.some((c) => (c.found && c.mcp !== 'installed') || (c.skill !== 'installed' && c.skill !== 'conflict'));

  const head = el('div', 'mcp-head');
  const address = el('button', 'mcp-url', data.url || '');
  address.dataset.copy = data.url || '';
  address.title = t('复制');
  head.appendChild(address);
  if (pending) head.appendChild(mcpSetupButton(t('一键安装'), () => mcpSetupPost('/api/hub/mcp/clients/install', { client: 'all', parts: ['mcp', 'skill'] }), true));

  const nodes = [head, ...clients.map(mcpClientCard)];
  if (view.errors.length) {
    const errors = el('div', 'mcp-errors');
    view.errors.forEach((message) => errors.appendChild(el('div', 'mcp-error', message)));
    nodes.push(errors);
  }

  const login = el('label', 'mcp-login');
  const box = document.createElement('input');
  box.type = 'checkbox';
  box.checked = data.loginItem === 'enabled' || data.loginItem === 'requiresApproval';
  box.disabled = view.busy;
  box.addEventListener('change', () => mcpSetupPost('/api/hub/login-item', { enabled: box.checked }));
  login.append(box, el('span', null, t('登录时启动 LayerLens')));
  nodes.push(login);
  if (data.loginItem === 'requiresApproval') nodes.push(el('div', 'mcp-detail', t('需要在「系统设置 > 通用 > 登录项」中允许')));

  nodes.push(el('p', 'mcp-note', t('安装后新开一个 Agent 会话生效。LayerLens 需要在会话开始前运行; 会话中 LayerLens 重启后, Codex 会自动恢复, Claude Code 可用 /mcp 重连。')));
  view.root.replaceChildren(...nodes);
}

function mcpSetupClosed() {
  mcpSetupView = null;
}

// 首次使用时提示一次: 检测到客户端但都没有接入时才显示, 关掉或打开设置后不再出现
async function mcpSetupHint() {
  try {
    if (localStorage.getItem(MCP_HINT_KEY)) return;
  } catch (e) {
    return;
  }
  let data = null;
  try {
    const res = await fetch('/api/hub/mcp/clients');
    data = res.ok ? await res.json() : null;
  } catch (e) { /* 不影响页面 */ }
  const clients = (data?.clients || []).filter((c) => c.found);
  if (!clients.length || clients.some((c) => c.mcp === 'installed')) return;
  try { localStorage.setItem(MCP_HINT_KEY, '1'); } catch (e) { /* 只是少显示一次 */ }
  const hint = el('div', 'mcp-hint');
  hint.appendChild(el('span', null, t('可一键接入 {0}, 让 Agent 读取当前选中的元素', clients.map((c) => c.name).join(' / '))));
  const open = el('button', 'cache-btn mcp-primary', t('设置'));
  const close = el('button', 'icon-btn mcp-hint-close', '×');
  close.setAttribute('aria-label', t('关闭'));
  const dismiss = () => hint.remove();
  open.addEventListener('click', () => { dismiss(); openPanel('mcp'); });
  close.addEventListener('click', dismiss);
  hint.append(open, close);
  document.body.appendChild(hint);
}
