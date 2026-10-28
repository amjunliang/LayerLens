'use strict';

// 改动面板: 当前 App 源码所在 git 仓库的未提交改动, 可暂存、放弃、提交、拉取和推送, 可查看提交记录的改动.
// 仓库由 Mac App 根据 App 上报的源文件路径推断. 只在页签可见时连接事件流, Mac App 此时才监听仓库文件变化并执行 git
const GIT_RETRY_MS = 2000;
// 页签隐藏后保持连接的时间, 期间切回来无需重新读取
const GIT_IDLE_MS = 60000;
const GIT_DIFF_MAX_LINES = 20000;
// 多选文件时最多显示的 diff 数, 每次状态变化都要重新读取
const GIT_DIFF_MAX_FILES = 30;
const GIT_LOG_PAGE = 50;
const GIT_DIFF_SIZE_KEY = 'layerlens_git_diff_size';
const GIT_DIFF_SIZE = { min: 10, max: 20, value: 13 };
const GIT_SIDE_WIDTH_KEY = 'layerlens_git_side_width';
const GIT_TREE_KEY = 'layerlens_git_tree';
const GIT_TREE_INDENT = 14;
// 分组顺序与标题; 冲突最需要处理, 排在最前
const GIT_GROUPS = [
  ['conflicted', '冲突'],
  ['staged', '已暂存'],
  ['unstaged', '更改'],
  ['untracked', '未跟踪'],
];
// 列表分区: 未跟踪文件和未暂存的修改放在一起, 与 Sourcetree 一致
const GIT_SECTIONS = [
  ['conflicted', '冲突', ['conflicted']],
  ['staged', '已暂存文件', ['staged']],
  ['changes', '未暂存文件', ['unstaged', 'untracked']],
];
const GIT_STATUS_ICONS = { M: 'pencil', T: 'pencil', A: 'plus', '?': 'plus', D: 'minus', R: 'arrow-right', C: 'plus' };
const GIT_STATUS_NAMES = { M: '已修改', A: '新增', D: '已删除', R: '重命名', C: '复制', T: '类型变更', U: '未合并', '?': '未跟踪' };

const git = {
  active: false,
  timer: 0,
  key: '',
  es: null,
  repo: null,
  status: null,
  statusText: '',
  error: '',
  // 选中的文件 { kind: 'files', items: [{ group, path, origin }] } 或提交 { kind: 'commits', items: [{ hash, subject }] }
  selected: null,
  // 按住 ⇧ 范围选择的起点
  anchor: '',
  diffText: null,
  diffSeq: 0,
  // 折叠的分组与 diff 区块
  collapsed: new Set(),
  commits: [],
  logKey: null,
  logMore: false,
  logLoading: false,
  logScrollX: 0,
  busy: new Set(),
  // 进行中的暂存或取消暂存 { key, paths }: key 为点击的复选框, 菜单或空格触发时为空, 按路径标记
  staging: null,
  // 提交并推送进行中, 推送结束前提交按钮不可用
  committing: false,
  diffSize: gitLoadDiffSize(),
  // 文件按目录树显示, 关闭时为平铺列表
  tree: gitLoadTreeMode(),
};

function gitLoadTreeMode() {
  try {
    return localStorage.getItem(GIT_TREE_KEY) !== '0';
  } catch (e) {
    return true;
  }
}

function gitSetTreeMode(tree) {
  git.tree = tree;
  try {
    localStorage.setItem(GIT_TREE_KEY, tree ? '1' : '0');
  } catch (e) {
    // ignore
  }
  gitRenderHead();
  gitRenderFiles();
}

function gitLoadDiffSize() {
  let size = 0;
  try {
    size = Number(localStorage.getItem(GIT_DIFF_SIZE_KEY)) || 0;
  } catch (e) {
    // ignore
  }
  return Math.max(GIT_DIFF_SIZE.min, Math.min(GIT_DIFF_SIZE.max, size || GIT_DIFF_SIZE.value));
}

// 只改 CSS 变量, 不重建 diff, 保持滚动位置
function gitSetDiffSize(step) {
  git.diffSize = Math.max(GIT_DIFF_SIZE.min, Math.min(GIT_DIFF_SIZE.max, git.diffSize + step));
  const box = $('gitDiff');
  box.style.setProperty('--git-diff-size', git.diffSize + 'px');
  const control = box.querySelector('.git-diff-size');
  if (control) gitSyncDiffSize(control);
  try {
    localStorage.setItem(GIT_DIFF_SIZE_KEY, String(git.diffSize));
  } catch (e) {
    // ignore
  }
}

function gitSyncDiffSize(control) {
  const [down, label, up] = control.children;
  label.textContent = git.diffSize;
  down.disabled = git.diffSize <= GIT_DIFF_SIZE.min;
  up.disabled = git.diffSize >= GIT_DIFF_SIZE.max;
}

function gitDiffSizeControl() {
  const control = el('span', 'log-size git-diff-size');
  const down = el('button', null, '−');
  down.title = t('减小字号');
  down.addEventListener('click', () => gitSetDiffSize(-1));
  const up = el('button', null, '+');
  up.title = t('增大字号');
  up.addEventListener('click', () => gitSetDiffSize(1));
  control.append(down, el('span', null, ''), up);
  gitSyncDiffSize(control);
  return control;
}

function gitVisible() {
  return logVisible() && net.tab === 'git';
}

// 面板显示状态或页签变化时调用. 隐藏后保留页面状态并延迟断开: 短时间内切回来直接显示,
// 事件流仍在时状态已是最新; 已断开时先显示上次的内容, 重新连接后由状态推送更新
function syncGitPanel() {
  const visible = gitVisible();
  if (visible && !git.active) {
    git.active = true;
    clearTimeout(git.idleTimer);
    if (!git.es || git.es.readyState === EventSource.CLOSED || (targets.bundleId || '') !== git.key) gitConnect();
    // 同一窗口切换 App 时重新连接
    git.timer = setInterval(() => {
      if ((targets.bundleId || '') !== git.key) gitConnect();
    }, 1000);
  } else if (!visible && git.active) {
    git.active = false;
    clearInterval(git.timer);
    clearTimeout(git.idleTimer);
    git.idleTimer = setTimeout(gitDisconnect, GIT_IDLE_MS);
  }
}

function gitDisconnect() {
  if (git.es) git.es.close();
  git.es = null;
}

async function gitConnect() {
  gitDisconnect();
  const key = targets.bundleId || '';
  // 同一个 App 重新连接时保留列表、选中和 diff, 只重新订阅状态
  if (key && key === git.key && git.repo && git.status) {
    gitSubscribe(key);
    return;
  }
  git.key = key;
  git.repo = null;
  git.status = null;
  git.statusText = '';
  git.selected = null;
  git.diffText = null;
  git.commits = [];
  git.logKey = null;
  git.logMore = false;
  git.error = key ? '' : t('未选择 App');
  gitRender();
  if (!key) return;
  const repo = await gitRequest('repo');
  if (key !== git.key || !git.active) return;
  if (repo.error) {
    git.error = repo.reason === 'noSource'
      ? t('App 没有上报源码路径: 在模拟器上运行一次, 或更新 LayerLens Pod 后重新运行')
      : repo.reason === 'notRepo' ? t('App 的源码不在 git 仓库中') : t('无法读取仓库: {0}', repo.error);
    gitRender();
    return;
  }
  git.repo = repo;
  gitRender();
  gitSubscribe(key);
}

function gitSubscribe(key) {
  const es = new EventSource(`/api/hub/git/events?app=${encodeURIComponent(key)}`);
  git.es = es;
  es.addEventListener('status', (e) => {
    if (git.es !== es) return;
    gitOnStatus(e.data);
  });
  // LayerLens 重启等原因断开且不再重连时, 稍后重新连接
  es.onerror = () => {
    if (es.readyState !== EventSource.CLOSED) return;
    setTimeout(() => {
      if (git.es === es && git.active) gitConnect();
    }, GIT_RETRY_MS);
  };
}

async function gitRequest(action, params = {}) {
  const query = new URLSearchParams({ app: git.key, ...params });
  try {
    const response = await fetch(`/api/hub/git/${action}?${query}`);
    return await response.json();
  } catch (e) {
    return { error: e.message };
  }
}

// 写操作: 期间禁用对应按钮, 失败时提示 git 的输出
async function gitAction(action, body = {}) {
  if (git.busy.has(action)) return false;
  git.busy.add(action);
  gitRenderHead();
  let result;
  try {
    const response = await fetch(`/api/hub/git/${action}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ app: git.key, ...body }),
    });
    result = await response.json().catch(() => ({ error: String(response.status) }));
  } catch (e) {
    result = { error: e.message };
  }
  git.busy.delete(action);
  gitRenderHead();
  if (result.error) {
    // git 的错误常有多行, 提示里只放最有用的前两行
    const lines = String(result.error).split('\n').map((line) => line.trim()).filter(Boolean);
    toast(t('git 失败: {0}', lines.slice(0, 2).join(' ')), true, true);
    return false;
  }
  return true;
}

function gitOnStatus(text) {
  const changed = text !== git.statusText;
  git.statusText = text;
  try {
    git.status = JSON.parse(text);
  } catch (e) {
    return;
  }
  if (changed) {
    // 选中的文件已不在原分组时(如已暂存), 到其他分组中找同一文件; 都找不到的去掉
    if (git.selected?.kind === 'files') {
      // 选中整个目录时可能有上千个文件, 先按分组建索引, 避免逐个线性查找
      const index = new Map(GIT_GROUPS.map(([key]) => [key, new Map((git.status[key] || []).map((file) => [file.path, file]))]));
      const items = git.selected.items.map((item) => {
        if (index.get(item.group)?.has(item.path)) return item;
        const group = GIT_GROUPS.map(([key]) => index.get(key).has(item.path) && key).find(Boolean);
        return group ? { group, path: item.path, origin: index.get(group).get(item.path).origin } : null;
      }).filter(Boolean);
      git.selected = items.length ? { kind: 'files', items } : null;
      if (!git.selected) git.diffText = null;
    }
    gitRender();
    // 推送、拉取只移动远端分支, HEAD 不变; 上游或领先落后数变化时也重新读取, 更新提交记录中的分支标签
    const branch = git.status.branch || {};
    const logKey = [branch.oid, branch.upstream, branch.ahead, branch.behind].join('|');
    if (logKey !== git.logKey) gitLoadLog(logKey, true);
  }
  // 文件内容变化但状态不变时状态推送内容相同, 也要刷新选中文件的 diff
  if (git.selected?.kind === 'files') gitLoadDiff(false);
}

function gitFindFile(group, path) {
  return (git.status?.[group] || []).find((file) => file.path === path);
}

// 暂存或取消暂存: 请求是异步的, 文件多或仓库大时 git 较慢; 执行期间点击的复选框显示加载, 其余复选框暂不可点
async function gitStage(action, paths, key = '') {
  if (!paths.length || git.staging) return false;
  git.staging = { key, paths: new Set(paths) };
  gitRenderHead();
  gitMarkStaging();
  const ok = await gitAction(action, { paths });
  git.staging = null;
  gitRenderHead();
  gitMarkStaging();
  return ok;
}

function gitStagingKey(key, path) {
  const staging = git.staging;
  return !!staging && (staging.key ? staging.key === key : !!path && staging.paths.has(path));
}

// 开始和结束时只更新复选框状态, 不重绘列表; 期间状态推送重绘时由 gitCheckbox 按 git.staging 标记
function gitMarkStaging() {
  document.querySelectorAll('#gitFiles .git-check[data-key]').forEach((check) => {
    check.classList.toggle('pending', gitStagingKey(check.dataset.key, check.dataset.path));
  });
}

// 顶栏刷新: 还没读到仓库时重新连接; 否则立即重新读取状态, 并重新读取提交记录和选中项的 diff
async function gitRefresh() {
  if (!git.repo || !git.status) {
    git.key = '';
    gitConnect();
    return;
  }
  if (!(await gitAction('refresh'))) return;
  gitLoadLog(git.logKey, true);
  gitLoadDiff(false);
}

// key: 读取时的分支状态, 期间状态变化后旧结果作废
async function gitLoadLog(key, reset) {
  if (!reset && (git.logLoading || !git.logMore)) return;
  git.logKey = key;
  git.logLoading = true;
  const result = await gitRequest('log', { skip: reset ? 0 : git.commits.length });
  if (git.logKey !== key) return;
  git.logLoading = false;
  const commits = result.commits || [];
  git.commits = reset ? commits : git.commits.concat(commits);
  git.logMore = commits.length >= GIT_LOG_PAGE;
  gitRenderFiles();
}

async function gitLoadDiff(reset) {
  const selected = git.selected;
  if (!selected) return;
  const seq = ++git.diffSeq;
  if (reset) {
    git.diffText = null;
    gitRenderDiff();
  }
  let result;
  if (selected.kind === 'commits') {
    result = await gitRequest('show', { commits: selected.items.map((item) => item.hash).join(',') });
  } else {
    // 多个文件分别读取后拼接, 每段都以 diff --git 开头, 显示时按文件分段
    const results = await Promise.all(selected.items.slice(0, GIT_DIFF_MAX_FILES).map((item) => gitRequest('diff', { path: item.path, origin: item.origin || '', group: item.group })));
    const failed = results.find((item) => item.error);
    result = selected.items.length === 1 || !failed
      ? { text: results.map((item) => item.text || '').join(''), truncated: results.some((item) => item.truncated), error: failed?.error }
      : failed;
  }
  if (seq !== git.diffSeq || git.selected !== selected) return;
  const text = result.error ? null : result.text || '';
  if (!reset && text === git.diffText) return;
  git.diffText = text;
  git.diffError = result.error || '';
  git.diffTruncated = !!result.truncated;
  gitRenderDiff();
}

// MARK: - Selection

function gitItemKey(kind, item) {
  return kind === 'commits' ? item.hash : item.group + '\0' + item.path;
}

function gitIsSelected(kind, item) {
  return git.selected?.kind === kind && git.selected.items.some((other) => gitItemKey(kind, other) === gitItemKey(kind, item));
}

// 单击选中一个, ⌘ 单击加选 / 取消, ⇧ 单击选中与上次点击之间的范围
function gitSelect(kind, item, e, ordered) {
  const key = gitItemKey(kind, item);
  const current = git.selected?.kind === kind ? git.selected.items : [];
  let items;
  if (e.shiftKey && git.anchor && current.length) {
    const keys = ordered.map((other) => gitItemKey(kind, other));
    const from = keys.indexOf(git.anchor);
    const to = keys.indexOf(key);
    items = from < 0 ? [item] : ordered.slice(Math.min(from, to), Math.max(from, to) + 1);
  } else if (e.metaKey || e.ctrlKey) {
    items = current.some((other) => gitItemKey(kind, other) === key) ? current.filter((other) => gitItemKey(kind, other) !== key) : current.concat(item);
    git.anchor = key;
  } else {
    items = [item];
    git.anchor = key;
  }
  git.selected = items.length ? { kind, items } : null;
  git.diffText = null;
  gitRenderFiles();
  if (git.selected) gitLoadDiff(true);
  else gitRenderDiff();
}

// ⇧ 单击和双击会选中文字, 列表行不需要选中文字
function gitPreventSelection(e) {
  if (e.shiftKey || e.detail > 1) e.preventDefault();
}

function gitSectionFiles(groups) {
  return groups.flatMap((group) => (git.status?.[group] || []).map((file) => ({ group, file })));
}

function gitAllFiles() {
  return GIT_SECTIONS.flatMap(([key, , groups]) => git.collapsed.has('group:' + key) ? [] : gitSectionFiles(groups).map(({ group, file }) => ({ group, path: file.path, origin: file.origin })));
}

// 行上的操作作用于该行; 该行在多选中时作用于同一分区的所有选中文件
function gitTargets(group, file) {
  const section = GIT_SECTIONS.find(([, , groups]) => groups.includes(group));
  const items = gitIsSelected('files', { group, path: file.path }) ? git.selected.items.filter((item) => section[2].includes(item.group)) : [];
  return items.length ? items : [{ group, path: file.path }];
}

function gitDiscard(items) {
  const paths = items.filter((item) => item.group !== 'untracked').map((item) => item.path);
  const untracked = items.filter((item) => item.group === 'untracked').map((item) => item.path);
  gitAction('discard', { paths, untracked });
}

// 放弃改动不可撤销, 确认气泡的内容: 说明影响并列出文件
function gitDiscardConfirm(items) {
  const removing = items.every((item) => item.group === 'untracked');
  const someUntracked = items.some((item) => item.group === 'untracked');
  return {
    title: removing ? t('删除 {0} 个未跟踪文件?', items.length) : t('放弃 {0} 个文件的改动?', items.length),
    detail: someUntracked && !removing ? t('未跟踪的文件会被删除, 此操作不可撤销') : t('此操作不可撤销'),
    items: items.map((item) => item.path),
    action: removing ? t('删除') : t('放弃'),
  };
}

// MARK: - Render

function gitRender() {
  gitRenderHead();
  gitRenderFiles();
  gitRenderDiff();
}

function gitRenderHead() {
  const branch = git.status?.branch || {};
  $('gitRepo').textContent = git.repo?.name || '';
  $('gitRepo').title = git.repo?.root || '';
  const head = branch.head && branch.head !== '(detached)' ? branch.head : '';
  // 分支名过长时省略中间, 保留前缀和末尾的编号
  $('gitBranch').textContent = git.status ? (head.length > 32 ? head.slice(0, 15) + '…' + head.slice(-15) : head) || t('游离 HEAD') : '';
  $('gitBranch').title = head;
  $('gitContext').hidden = !git.repo;
  const sync = [];
  if (branch.ahead) sync.push('↑' + branch.ahead);
  if (branch.behind) sync.push('↓' + branch.behind);
  const local = !!git.status && !git.status.hasRemote;
  if (git.status && !local && !branch.upstream) sync.push(t('无上游'));
  for (const id of ['gitSync', 'gitRemoteGap', 'gitPull', 'gitPush']) $(id).style.display = local ? 'none' : '';
  $('gitSync').textContent = sync.join(' ');
  $('gitSync').title = branch.upstream || '';
  $('gitPullCount').textContent = branch.behind ? '↓' + branch.behind : '';
  $('gitPullCount').hidden = !branch.behind;
  $('gitPushCount').textContent = branch.ahead ? '↑' + branch.ahead : '';
  $('gitPushCount').hidden = !branch.ahead;
  $('gitTreeMode').classList.toggle('active', git.tree);
  $('gitTreeMode').title = git.tree ? t('平铺显示') : t('树形显示');
  $('gitPull').disabled = !git.status || !branch.upstream || git.busy.has('pull');
  $('gitPush').disabled = !git.status || git.busy.has('push');
  $('gitBody').classList.toggle('staging', !!git.staging);
  $('gitRefresh').disabled = git.busy.has('refresh');
  $('gitRefresh').classList.toggle('loading', git.busy.has('refresh'));
  $('gitPull').classList.toggle('loading', git.busy.has('pull'));
  $('gitPush').classList.toggle('loading', git.busy.has('push'));
  const staged = git.status?.staged?.length || 0;
  const amend = $('gitAmend').checked;
  // 有上游且没有领先提交时, 上一次提交已在远端, 修改它会改写已推送的历史
  $('gitAmendWarn').hidden = !(amend && branch.upstream && !branch.ahead);
  // 并推送: 没有远端时不显示, 也不推送
  const pushAfter = !local && $('gitPushAfter').checked;
  $('gitPushAfterLabel').style.display = local ? 'none' : '';
  $('gitCommit').disabled = git.busy.has('commit') || git.committing || !git.status || (!staged && !amend);
  $('gitCommit').textContent = git.busy.has('commit') ? t('正在提交…') : git.committing && git.busy.has('push') ? t('正在推送…')
    : pushAfter ? (staged ? t('提交并推送 ({0})', staged) : t('提交并推送')) : staged ? t('提交 ({0})', staged) : t('提交');
}

function gitRenderFiles() {
  const box = $('gitFiles');
  const empty = $('gitEmpty');
  const ready = !!git.status && !git.status.error;
  $('gitBody').classList.toggle('ready', ready);
  if (!ready) {
    box.replaceChildren();
    empty.hidden = false;
    empty.textContent = git.error || git.status?.error || (git.repo ? t('正在读取改动…') : t('正在查找仓库…'));
    return;
  }
  empty.hidden = true;
  const fragment = document.createDocumentFragment();
  // 按显示顺序收集可见文件, 供 ⇧ 范围选择; 行渲染完后才填满, 点击时已完整
  const ordered = git.tree ? [] : gitAllFiles();
  const sections = GIT_SECTIONS.map(([key, title, groups]) => [key, title, gitSectionFiles(groups)]);
  if (!sections.some(([, , files]) => files.length)) {
    fragment.append(el('div', 'git-clean', t('没有改动, 工作区是干净的')));
  } else {
    sections.forEach(([key, title, files]) => {
      // 分区为空时不显示标题栏, 只显示一行提示; 冲突只在有时显示
      if (!files.length) {
        if (key !== 'conflicted') fragment.append(el('div', 'git-section-empty', key === 'staged' ? t('没有已暂存的文件, 勾选下方文件即可暂存') : t('没有未暂存的改动')));
        return;
      }
      const collapsed = git.collapsed.has('group:' + key);
      fragment.append(gitSectionHead(key, title, files, collapsed));
      if (collapsed) return;
      if (git.tree) gitAppendTree(fragment, key, gitFileTree(files), 0, ordered);
      else files.forEach(({ group, file }) => fragment.append(gitFileRow(group, file, ordered)));
    });
  }
  if (git.status.truncated) fragment.append(el('div', 'git-note', t('文件过多, 每组只显示前 2000 个')));
  if (git.commits.length) gitAppendLog(fragment);
  const scroll = box.scrollTop;
  box.replaceChildren(fragment);
  box.scrollTop = scroll;
  const main = box.querySelector('.git-log-main');
  if (main) main.scrollLeft = git.logScrollX || 0;
}

// 提交记录接在改动后面, 同一个列表滚动
function gitAppendLog(fragment) {
  const collapsed = git.collapsed.has('group:log');
  const head = el('div', 'git-group git-toggle' + (collapsed ? ' collapsed' : ''));
  head.append(icon('chevron'), el('span', 'git-group-title', t('提交记录')));
  head.addEventListener('click', () => gitToggle('group:log', gitRenderFiles));
  fragment.append(head);
  if (!collapsed) {
    // 时间一列不动, 哈希和标题一列可左右滚动; 两列行高相同, 随列表一起上下滚动.
    // 不用 sticky 固定时间列, WebKit 中行内 sticky 单元格左右滚动时绘制错乱
    const dates = el('div', 'git-log-dates');
    const main = el('div', 'git-log-main');
    main.addEventListener('scroll', () => (git.logScrollX = main.scrollLeft));
    const inner = el('div', 'git-log-inner');
    main.append(inner);
    const graph = gitGraphLayout(git.commits);
    git.commits.forEach((commit, index) => {
      const kind = 'git-row' + (index % 2 ? ' odd' : '') + (gitIsSelected('commits', commit) ? ' sel' : '');
      const date = el('div', kind + ' git-date', gitFormatTime(commit.time));
      const row = el('div', kind + ' git-commit-item');
      const refs = gitParseRefs(commit.refs);
      const head = refs.some((ref) => ref.head || ref.kind === 'head');
      const lane = graph.rows[index].col;
      row.append(gitGraphCell(graph.rows[index], graph.width, head), el('span', 'git-hash', commit.hash), ...gitRefBadges(refs, lane), el('span', 'git-subject', commit.subject));
      const title = `${commit.hash} · ${commit.author} · ${commit.date}\n${commit.subject}`;
      [date, row].forEach((cell) => {
        cell.title = title;
        cell.addEventListener('click', (e) => gitSelect('commits', commit, e, git.commits));
        cell.addEventListener('mousedown', gitPreventSelection);
        cell.addEventListener('contextmenu', (e) => gitShowCommitMenu(e, commit));
        cell.addEventListener('mouseenter', () => [date, row].forEach((item) => item.classList.add('hover')));
        cell.addEventListener('mouseleave', () => [date, row].forEach((item) => item.classList.remove('hover')));
      });
      dates.append(date);
      inner.append(row);
    });
    const log = el('div', 'git-log');
    log.append(dates, main);
    fragment.append(log);
    if (git.logLoading) fragment.append(el('div', 'git-note', t('正在读取…')));
    else if (!git.logMore) fragment.append(el('div', 'git-note', t('共 {0} 个提交, 已全部显示', git.commits.length)));
  }
}

// 今天只显示时间, 今年显示月日, 更早显示年月日; 宽度固定便于对齐
function gitFormatTime(seconds) {
  const date = new Date(Number(seconds) * 1000);
  if (!seconds || isNaN(date)) return '';
  const now = new Date();
  const pad = (value) => String(value).padStart(2, '0');
  const time = `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  if (date.toDateString() === now.toDateString()) return time;
  if (date.getFullYear() === now.getFullYear()) return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${time}`;
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function gitToggle(key, render) {
  if (git.collapsed.has(key)) git.collapsed.delete(key);
  else git.collapsed.add(key);
  render();
}

// 分区标题: 复选框暂存或取消暂存整个分区, 点击其余位置折叠
function gitSectionHead(key, title, files, collapsed) {
  const head = el('div', 'git-group git-toggle' + (collapsed ? ' collapsed' : ''));
  const paths = files.map(({ file }) => file.path);
  const check = gitCheckbox(key === 'staged' && files.length > 0, key === 'staged' ? t('全部取消暂存') : t('全部暂存'), () => gitStage(key === 'staged' ? 'unstage' : 'stage', paths, 'group:' + key), 'group:' + key);
  check.disabled = !files.length;
  head.append(icon('chevron'), check, el('span', 'git-group-title', t(title)), el('span', 'git-group-count', String(files.length)));
  head.addEventListener('click', () => gitToggle('group:' + key, gitRenderFiles));
  return head;
}

// 勾选状态由 git 状态推送决定, 点击时只发出操作, 不直接改变勾选
// key 标识这个复选框, 暂存进行中时据此显示加载; path 用于菜单或空格触发时按文件标记
function gitCheckbox(checked, title, onClick, key, path) {
  const check = el('input', 'git-check');
  check.type = 'checkbox';
  check.checked = checked;
  check.title = title;
  check.dataset.key = key;
  if (path) check.dataset.path = path;
  check.classList.toggle('pending', gitStagingKey(key, path));
  check.addEventListener('click', (e) => {
    e.preventDefault();
    e.stopPropagation();
    onClick();
  });
  check.addEventListener('dblclick', (e) => e.stopPropagation());
  return check;
}

function gitFileRow(group, file, ordered, depth) {
  const row = el('div', 'git-row git-file');
  row.classList.toggle('sel', !git.selected?.dir && gitIsSelected('files', { group, path: file.path }));
  const slash = file.path.lastIndexOf('/');
  const name = file.path.slice(slash + 1);
  const dir = slash > 0 ? file.path.slice(0, slash) : '';
  const letter = group === 'conflicted' ? 'U' : file.status;
  const badge = gitStatusBadge(letter);
  const staged = group === 'staged';
  const key = 'file:' + group + ':' + file.path;
  const check = gitCheckbox(staged, staged ? t('取消暂存') : t('暂存'), () => {
    gitStage(staged ? 'unstage' : 'stage', gitTargets(group, file).map((item) => item.path), key);
  }, key, file.path);
  // 复选框固定在最左一列, 树形缩进放在复选框后面; 文件图标与同层目录的文件夹图标对齐
  row.append(check);
  if (depth != null) row.append(gitIndent(depth * GIT_TREE_INDENT + 18));
  row.append(badge, el('span', 'git-name', name), el('span', 'git-dir', depth == null ? dir : ''));
  row.title = (file.origin ? `${file.origin} → ${file.path}` : file.path) + '\n' + t('双击打开');
  if (group === 'unstaged' || group === 'untracked') {
    const actions = el('span', 'git-actions');
    actions.append(gitDiscardButton(group, file));
    row.append(actions);
  }
  row.addEventListener('click', (e) => gitSelect('files', { group, path: file.path, origin: file.origin }, e, ordered));
  row.addEventListener('dblclick', () => gitOpenFile(file.path));
  row.addEventListener('mousedown', gitPreventSelection);
  row.addEventListener('contextmenu', (e) => gitShowFileMenu(e, group, file));
  return row;
}

// 目录树: 只有一个子目录且没有文件的目录与子目录合并显示, 如 Mac/LayerLens
function gitFileTree(files) {
  const root = { name: '', path: '', dirs: new Map(), files: [] };
  for (const item of files) {
    const parts = item.file.path.split('/');
    let node = root;
    parts.slice(0, -1).forEach((part) => {
      if (!node.dirs.has(part)) node.dirs.set(part, { name: part, path: node.path ? node.path + '/' + part : part, dirs: new Map(), files: [] });
      node = node.dirs.get(part);
    });
    node.files.push(item);
  }
  const compact = (node) => {
    for (const child of node.dirs.values()) {
      while (child.dirs.size === 1 && !child.files.length) {
        const only = child.dirs.values().next().value;
        child.name += '/' + only.name;
        child.path = only.path;
        child.dirs = only.dirs;
        child.files = only.files;
      }
      compact(child);
    }
  };
  compact(root);
  return root;
}

function gitTreeFiles(node) {
  return [...node.dirs.values()].flatMap(gitTreeFiles).concat(node.files);
}

function gitAppendTree(fragment, section, node, depth, ordered) {
  const byName = (a, b) => a.name.localeCompare(b.name);
  [...node.dirs.values()].sort(byName).forEach((dir) => {
    const key = 'dir:' + section + ':' + dir.path;
    const collapsed = git.collapsed.has(key);
    fragment.append(gitDirRow(section, dir, depth, collapsed));
    if (!collapsed) gitAppendTree(fragment, section, dir, depth + 1, ordered);
  });
  node.files.slice().sort((a, b) => a.file.path.localeCompare(b.file.path)).forEach(({ group, file }) => {
    ordered.push({ group, path: file.path, origin: file.origin });
    fragment.append(gitFileRow(group, file, ordered, depth));
  });
}

// 目录行: 复选框暂存或取消暂存目录下的全部文件; 点击选中目录(即其下全部文件), 点箭头或双击折叠
function gitDirRow(section, dir, depth, collapsed) {
  const key = 'dir:' + section + ':' + dir.path;
  const row = el('div', 'git-row git-dir-row git-toggle' + (collapsed ? ' collapsed' : '') + (git.selected?.dir === key ? ' sel' : ''));
  const staged = section === 'staged';
  const files = gitTreeFiles(dir);
  const paths = files.map(({ file }) => file.path);
  const check = gitCheckbox(staged, staged ? t('取消暂存') : t('暂存'), () => gitStage(staged ? 'unstage' : 'stage', paths, key), key);
  const chevron = icon('chevron');
  chevron.classList.add('git-chevron');
  chevron.addEventListener('click', (e) => {
    e.stopPropagation();
    gitToggle(key, gitRenderFiles);
  });
  row.append(check, gitIndent(depth * GIT_TREE_INDENT), chevron, gitFolderIcon(), el('span', 'git-name', dir.name));
  row.title = dir.path;
  row.addEventListener('click', () => gitSelectDir(key, dir.path, files));
  row.addEventListener('dblclick', () => gitToggle(key, gitRenderFiles));
  row.addEventListener('mousedown', gitPreventSelection);
  row.addEventListener('contextmenu', (e) => gitShowDirMenu(e, key, section, dir, files));
  return row;
}

function gitSelectDir(key, path, files) {
  const items = files.map(({ group, file }) => ({ group, path: file.path, origin: file.origin }));
  git.selected = items.length ? { kind: 'files', items, dir: key, dirPath: path } : null;
  git.anchor = '';
  git.diffText = null;
  gitRenderFiles();
  if (git.selected) gitLoadDiff(true);
  else gitRenderDiff();
}

// 同 Sourcetree: 彩色方块图标, 修改是笔, 新增是加号, 删除是减号; 其余显示字母
function gitStatusBadge(letter) {
  const badge = el('span');
  gitSetBadge(badge, letter);
  return badge;
}

function gitSetBadge(badge, letter) {
  badge.className = 'git-badge s-' + (letter === '?' ? 'q' : letter);
  const glyph = GIT_STATUS_ICONS[letter];
  badge.replaceChildren(glyph ? icon(glyph) : letter);
  badge.title = t(GIT_STATUS_NAMES[letter] || letter);
}

function gitFolderIcon() {
  const folder = icon('folder');
  folder.classList.add('git-folder');
  return folder;
}

// 缩进占位, 宽度扣掉行内元素间距
function gitIndent(width) {
  const indent = el('span', 'git-indent');
  indent.style.width = Math.max(0, width - 6) + 'px';
  if (width <= 0) indent.style.marginLeft = '-6px';
  return indent;
}

function gitOpenFile(path) {
  gitAction('open', { path });
}

function gitDiscardButton(group, file) {
  const button = el('button', 'icon-btn git-btn git-discard');
  button.title = group === 'untracked' ? t('删除文件') : t('放弃改动');
  button.append(icon('trash'));
  button.addEventListener('dblclick', (e) => e.stopPropagation());
  button.addEventListener('click', (e) => {
    e.stopPropagation();
    const items = gitTargets(group, file);
    showConfirm(button, { ...gitDiscardConfirm(items), onConfirm: () => gitDiscard(items) });
  });
  return button;
}

function gitRenderDiff() {
  const box = $('gitDiff');
  const selected = git.selected;
  $('gitBody').classList.toggle('has-diff', !!selected);
  if (!selected) {
    box.replaceChildren(el('div', 'git-diff-empty', git.status && !git.status.error ? t('选择文件或提交查看改动') : ''));
    return;
  }
  const head = el('div', 'git-diff-head');
  const back = el('button', 'icon-btn git-diff-back');
  back.title = t('返回');
  back.append(icon('chevron'));
  back.addEventListener('click', () => {
    git.selected = null;
    git.diffText = null;
    gitRenderFiles();
    gitRenderDiff();
  });
  const items = selected.items;
  const commits = selected.kind === 'commits';
  let name;
  let label;
  let message = '';
  let badge = null;
  if (selected.dir) {
    name = selected.dirPath;
    label = t('{0} 个文件', items.length);
    badge = gitFolderIcon();
  } else if (items.length > 1) {
    name = commits ? t('{0} 个提交', items.length) : t('{0} 个文件', items.length);
    label = '';
  } else if (commits) {
    name = `${items[0].hash} ${items[0].subject}`;
    message = gitCommitMessage(git.diffText);
    label = t('提交');
  } else {
    name = items[0].origin ? `${items[0].origin} → ${items[0].path}` : items[0].path;
    const group = GIT_GROUPS.find(([key]) => key === items[0].group);
    label = group ? t(group[1]) : '';
    const file = gitFindFile(items[0].group, items[0].path);
    if (file) badge = gitStatusBadge(items[0].group === 'conflicted' ? 'U' : file.status);
  }
  // 单个已暂存或未暂存文件可按块操作
  const hunkGroup = !commits && items.length === 1 && (items[0].group === 'staged' || items[0].group === 'unstaged') ? items[0].group : '';
  head.append(back);
  if (badge) head.append(badge);
  let title = el('span', 'git-diff-title', name);
  if (message) {
    // 单个提交按原始提交信息多行显示
    head.classList.add('message');
    title = el('div', 'git-diff-title git-diff-message');
    title.append(el('span', 'git-hash', items[0].hash), document.createTextNode(message));
  }
  head.append(title, el('span', 'git-diff-group', label), gitDiffSizeControl());
  box.style.setProperty('--git-diff-size', git.diffSize + 'px');
  const body = el('div', 'git-diff-body');
  if (git.diffError) {
    body.append(el('div', 'git-diff-empty', git.diffError));
  } else if (git.diffText === null) {
    body.append(el('div', 'git-diff-empty', t('正在读取…')));
  } else {
    body.append(gitDiffView(git.diffText, commits || items.length > 1, hunkGroup));
    if (!commits && items.length > GIT_DIFF_MAX_FILES) body.append(el('div', 'git-note', t('只显示前 {0} 个文件', GIT_DIFF_MAX_FILES)));
  }
  const scroll = box.querySelector('.git-diff-body')?.scrollTop || 0;
  box.replaceChildren(head, body);
  body.scrollTop = scroll;
}

// 可折叠的区块: 提交或文件
function gitDiffSection(parent, kind, title, key, badge) {
  const section = el('div', 'git-sec git-sec-' + kind + (git.collapsed.has(key) ? ' collapsed' : ''));
  const head = el('div', 'git-sec-head');
  head.append(icon('chevron'));
  if (badge) head.append(badge);
  head.append(el('span', 'git-sec-title', title));
  head.addEventListener('click', () => {
    section.classList.toggle('collapsed');
    if (section.classList.contains('collapsed')) git.collapsed.add(key);
    else git.collapsed.delete(key);
  });
  const body = el('div', 'git-sec-body');
  section.append(head, body);
  parent.append(section);
  return body;
}

// 一个块: 标题 "块 N: 行 a-b" 与按块操作, 内容单独左右滚动(同 Sourcetree)
function gitHunkCard(parent, index, range, hunk, group) {
  const card = el('div', 'git-hunk');
  const head = el('div', 'git-hunk-head');
  // 纯删除的块新文件行数为 0, 用旧文件的行号
  const useOld = range[4] === '0';
  const start = Number(useOld ? range[1] : range[3]);
  const count = Number((useOld ? range[2] : range[4]) ?? 1);
  head.append(el('span', 'git-hunk-title', t('块 {0}: 行 {1}', index, count > 1 ? `${start}-${start + count - 1}` : start)));
  if (group === 'unstaged') head.append(gitHunkDiscardButton(hunk), gitHunkButton(t('暂存区块'), () => gitHunkAction('stage', hunk)));
  if (group === 'staged') head.append(gitHunkButton(t('取消暂存区块'), () => gitHunkAction('unstage', hunk)));
  const body = el('div', 'git-hunk-body');
  const lines = el('div', 'git-hunk-lines');
  body.append(lines);
  card.append(head, body);
  parent.append(card);
  return lines;
}

function gitHunkAction(mode, hunk) {
  gitAction('hunk', { mode, patch: hunk.header.concat(hunk.lines).join('\n') + '\n' });
}

function gitHunkButton(label, onClick) {
  const button = el('button', 'git-hunk-btn', label);
  button.addEventListener('click', onClick);
  return button;
}

// 放弃区块不可撤销, 先在气泡中确认
function gitHunkDiscardButton(hunk) {
  const button = gitHunkButton(t('放弃区块'), () => showConfirm(button, {
    title: t('放弃这个区块的改动?'),
    detail: t('此操作不可撤销'),
    action: t('放弃'),
    onConfirm: () => gitHunkAction('discard', hunk),
  }));
  return button;
}

// 统一 diff: 按块分成卡片, 两栏行号(旧 / 新)与增删符号各占一列, 增删着色; 文件头只保留模式变化等有用信息.
// 多文件或提交时按提交、文件分成可折叠的区块. 记下每块所属文件的头部, 按块操作时拼成补丁
// git show 输出中第一个提交的原始提交信息
function gitCommitMessage(text) {
  const match = /^\0[^\n]*\n([\s\S]*?)\x1d/.exec(text || '');
  return match ? match[1].trimEnd() : '';
}

function gitDiffView(text, multiple, hunkGroup) {
  if (!text.trim()) return el('div', 'git-diff-empty', t('没有内容差异(可能只改了文件权限或换行)'));
  if (!multiple && /^Binary files .* differ$/m.test(text) && !/^@@/m.test(text)) return el('div', 'git-diff-empty', t('二进制文件, 不显示差异'));
  const table = el('div', 'git-diff-lines');
  const lines = text.split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  let oldLine = 0;
  let newLine = 0;
  let header = [];
  let hunk = null;
  let hunkLines = null;
  let index = 0;
  let commitBody = table;
  let commitKey = '';
  let fileBody = table;
  let fileBadge = null;
  let rows = 0;
  let truncated = false;
  let inMessage = false;
  for (const line of lines) {
    if (rows >= GIT_DIFF_MAX_LINES) {
      truncated = true;
      break;
    }
    if (inMessage) {
      // 提交信息在顶栏显示, 这里跳过直到结束标记
      if (line.endsWith('\x1d')) inMessage = false;
      continue;
    }
    if (line.startsWith('\0')) {
      // git show 每个提交前的 "\0短哈希 标题", 随后是以 \x1d 结束的原始提交信息
      inMessage = true;
      hunk = null;
      commitKey = 'commit:' + line.slice(1);
      commitBody = fileBody = gitDiffSection(table, 'commit', line.slice(1), commitKey);
      continue;
    }
    if (line === '') continue;
    if (line.startsWith('diff --git')) {
      header = [line];
      hunk = null;
      index = 0;
      const path = (/ b\/(.*)$/.exec(line) || [])[1] || line;
      // 文件状态先按修改显示, 读到文件头的新增、删除、重命名说明后更新
      fileBadge = multiple ? gitStatusBadge('M') : null;
      fileBody = multiple ? gitDiffSection(commitBody, 'file', path, commitKey + 'file:' + path, fileBadge) : table;
      continue;
    }
    const range = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(line);
    if (range) {
      oldLine = Number(range[1]);
      newLine = Number(range[3]);
      hunk = { header: header.slice(), lines: [line] };
      index++;
      hunkLines = gitHunkCard(fileBody, index, range, hunk, hunkGroup);
      continue;
    }
    if (!hunk) {
      // 文件头: index / --- / +++ 不显示, 其余(新文件、模式变化、重命名、二进制)作为说明
      header.push(line);
      if (fileBadge) {
        if (line.startsWith('new file mode')) gitSetBadge(fileBadge, 'A');
        else if (line.startsWith('deleted file mode')) gitSetBadge(fileBadge, 'D');
        else if (line.startsWith('rename from')) gitSetBadge(fileBadge, 'R');
      }
      if (!/^(index |--- |\+\+\+ )/.test(line)) {
        fileBody.append(el('div', 'git-meta', line));
        rows++;
      }
      continue;
    }
    hunk.lines.push(line);
    let kind = 'ctx';
    let a = '';
    let b = '';
    let sign = '';
    let content = line.slice(1);
    if (line.startsWith('+')) {
      kind = 'add';
      b = newLine++;
      sign = '+';
    } else if (line.startsWith('-')) {
      kind = 'del';
      a = oldLine++;
      sign = '−';
    } else if (line.startsWith('\\')) {
      kind = 'meta';
      content = line;
    } else {
      a = oldLine++;
      b = newLine++;
    }
    const row = el('div', 'git-line ' + kind);
    row.append(el('span', 'git-ln', String(a)), el('span', 'git-ln', String(b)), el('span', 'git-sign', sign), el('span', 'git-code', content || ' '));
    hunkLines.append(row);
    rows++;
  }
  if (truncated || git.diffTruncated) table.append(el('div', 'git-note', t('差异过大, 只显示前面部分')));
  return table;
}

// MARK: - Setup

// 提交后是否推送, 记住上次的选择
const GIT_PUSH_AFTER_KEY = 'layerlens_git_push_after';

async function gitCommit() {
  const message = $('gitMessage').value.trim();
  const amend = $('gitAmend').checked;
  if (!message && !amend) {
    $('gitMessage').focus();
    toast(t('请填写提交说明'), true, true);
    return;
  }
  const pushAfter = !!git.status?.hasRemote && $('gitPushAfter').checked;
  // 提交到推送结束前按钮保持不可用, 显示推送进度
  git.committing = true;
  try {
    if (!(await gitAction('commit', { message, amend }))) return;
    $('gitMessage').value = '';
    gitFitMessage();
    $('gitAmend').checked = false;
    if (!pushAfter) {
      toast(t('已提交'));
      return;
    }
    // 推送失败时 gitAction 已提示原因, 提交已完成
    if (await gitAction('push')) toast(t('已提交并推送'));
  } finally {
    git.committing = false;
    gitRenderHead();
  }
}

// 提交说明默认一行, 随内容增高
function gitFitMessage() {
  const input = $('gitMessage');
  input.style.height = '';
  const height = input.scrollHeight + 2;
  input.style.height = Math.min(height, 120) + 'px';
  input.style.overflowY = height > 120 ? 'auto' : 'hidden';
}

// 文件列表与 diff 之间的分隔线, 拖动调整列表宽度; 上下限由 CSS 的 min-width / max-width 约束
function gitSetupSplitter() {
  const body = $('gitBody');
  const splitter = $('gitSplitter');
  const apply = (width) => body.style.setProperty('--git-side-w', Math.round(width) + 'px');
  try {
    const saved = Number(localStorage.getItem(GIT_SIDE_WIDTH_KEY)) || 0;
    if (saved) apply(saved);
  } catch (e) {
    // ignore
  }
  splitter.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    splitter.setPointerCapture(e.pointerId);
    splitter.classList.add('dragging');
    const left = body.getBoundingClientRect().left;
    const move = (ev) => apply(ev.clientX - left);
    const up = () => {
      splitter.classList.remove('dragging');
      splitter.removeEventListener('pointermove', move);
      splitter.removeEventListener('pointerup', up);
      splitter.removeEventListener('pointercancel', up);
      // 保存实际生效的宽度, 超出上下限的部分不记
      const width = body.querySelector('.git-side').getBoundingClientRect().width;
      apply(width);
      try {
        localStorage.setItem(GIT_SIDE_WIDTH_KEY, String(Math.round(width)));
      } catch (e) {
        // ignore
      }
    };
    splitter.addEventListener('pointermove', move);
    splitter.addEventListener('pointerup', up);
    splitter.addEventListener('pointercancel', up);
  });
}

// 鼠标最后点在改动面板内且选中了文件时, 空格暂存或取消暂存选中的文件: 已暂存的取消暂存, 其余暂存
function gitHandleKey(e) {
  if (e.code !== 'Space' || e.metaKey || e.ctrlKey || e.altKey || e.repeat) return false;
  if (!git.focused || !gitVisible() || git.selected?.kind !== 'files') return false;
  const items = git.selected.items;
  const unstage = items.filter((item) => item.group === 'staged').map((item) => item.path);
  const stage = items.filter((item) => item.group !== 'staged').map((item) => item.path);
  (async () => {
    if (unstage.length) await gitStage('unstage', unstage);
    if (stage.length) await gitStage('stage', stage);
  })();
  return true;
}

function setupGit() {
  document.addEventListener('pointerdown', (e) => {
    git.focused = e.target instanceof Element && !!e.target.closest('#gitBody') && !e.target.closest('textarea, input:not(.git-check)');
  }, true);
  $('gitPull').addEventListener('click', async () => {
    if (await gitAction('pull')) toast(t('已拉取'));
  });
  $('gitPush').addEventListener('click', async () => {
    if (await gitAction('push')) toast(t('已推送'));
  });
  $('gitTreeMode').addEventListener('click', () => gitSetTreeMode(!git.tree));
  $('gitRefresh').addEventListener('click', gitRefresh);
  $('gitCommit').addEventListener('click', gitCommit);
  $('gitAmend').addEventListener('change', gitRenderHead);
  try {
    $('gitPushAfter').checked = localStorage.getItem(GIT_PUSH_AFTER_KEY) === '1';
  } catch (e) {
    // 不可用时默认不推送
  }
  $('gitPushAfter').addEventListener('change', () => {
    try {
      localStorage.setItem(GIT_PUSH_AFTER_KEY, $('gitPushAfter').checked ? '1' : '0');
    } catch (e) {
      // 不可用时只在本次有效
    }
    gitRenderHead();
  });
  $('gitMessage').addEventListener('input', gitFitMessage);
  $('gitMessage').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      gitCommit();
    }
  });
  gitSetupSplitter();
  // 滑到底部附近时加载更多提交
  $('gitFiles').addEventListener('scroll', (e) => {
    const box = e.target;
    if (box.scrollHeight - box.scrollTop - box.clientHeight < 200) gitLoadLog(git.logKey, false);
  });
  gitRender();
}
