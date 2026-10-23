'use strict';

// 改动面板: 当前 App 源码所在 git 仓库的未提交改动, 可暂存、放弃、提交、切分支、拉取和推送.
// 仓库由 Mac App 根据 App 上报的源文件路径推断. 只在页签可见时连接事件流, Mac App 此时才监听仓库文件变化并执行 git
const GIT_RETRY_MS = 2000;
const GIT_DIFF_MAX_LINES = 20000;
// 分组顺序与标题; 冲突最需要处理, 排在最前
const GIT_GROUPS = [
  ['conflicted', '冲突'],
  ['staged', '已暂存'],
  ['unstaged', '更改'],
  ['untracked', '未跟踪'],
];
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
  // { group, path, origin }
  selected: null,
  diffText: null,
  diffSeq: 0,
  commits: [],
  logOid: null,
  busy: new Set(),
};

function gitVisible() {
  return logVisible() && net.tab === 'git';
}

// 面板显示状态或页签变化时调用
function syncGitPanel() {
  const visible = gitVisible();
  if (visible && !git.active) {
    git.active = true;
    gitConnect();
    // 同一窗口切换 App 时重新连接
    git.timer = setInterval(() => {
      if ((targets.bundleId || '') !== git.key) gitConnect();
    }, 1000);
  } else if (!visible && git.active) {
    git.active = false;
    clearInterval(git.timer);
    gitDisconnect();
  }
}

function gitDisconnect() {
  if (git.es) git.es.close();
  git.es = null;
}

async function gitConnect() {
  gitDisconnect();
  const key = (git.key = targets.bundleId || '');
  git.repo = null;
  git.status = null;
  git.statusText = '';
  git.selected = null;
  git.diffText = null;
  git.commits = [];
  git.logOid = null;
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
    // 选中的文件已不在原分组时(如已暂存), 到其他分组中找同一文件
    if (git.selected && !gitFindFile(git.selected.group, git.selected.path)) {
      const next = GIT_GROUPS.map(([group]) => gitFindFile(group, git.selected.path) && group).find(Boolean);
      git.selected = next ? { group: next, path: git.selected.path, origin: gitFindFile(next, git.selected.path).origin } : null;
      if (!git.selected) git.diffText = null;
    }
    gitRender();
    const oid = git.status.branch?.oid || '';
    if (oid !== git.logOid) gitLoadLog(oid);
  }
  // 文件内容变化但状态不变时状态推送内容相同, 也要刷新选中文件的 diff
  if (git.selected) gitLoadDiff(false);
}

function gitFindFile(group, path) {
  return (git.status?.[group] || []).find((file) => file.path === path);
}

async function gitLoadLog(oid) {
  git.logOid = oid;
  const result = await gitRequest('log');
  if (git.logOid !== oid) return;
  git.commits = result.commits || [];
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
  const result = await gitRequest('diff', { path: selected.path, origin: selected.origin || '', group: selected.group });
  if (seq !== git.diffSeq || git.selected !== selected) return;
  const text = result.error ? null : result.text || '';
  if (!reset && text === git.diffText) return;
  git.diffText = text;
  git.diffError = result.error || '';
  git.diffTruncated = !!result.truncated;
  gitRenderDiff();
}

function gitSelect(group, file) {
  git.selected = { group, path: file.path, origin: file.origin };
  gitRenderFiles();
  gitLoadDiff(true);
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
  $('gitBranch').textContent = git.status ? head || t('游离 HEAD') : '';
  $('gitBranch').title = head;
  const sync = [];
  if (branch.ahead) sync.push('↑' + branch.ahead);
  if (branch.behind) sync.push('↓' + branch.behind);
  const local = !!git.status && !git.status.hasRemote;
  if (git.status && !local && !branch.upstream) sync.push(t('无上游'));
  $('gitBranch').classList.toggle('git-local', local);
  for (const id of ['gitSync', 'gitPull', 'gitPush']) $(id).style.display = local ? 'none' : '';
  $('gitSync').textContent = sync.join(' ');
  $('gitSync').title = branch.upstream || '';
  $('gitPull').disabled = !git.status || !branch.upstream || git.busy.has('pull');
  $('gitPush').disabled = !git.status || git.busy.has('push');
  $('gitPull').classList.toggle('loading', git.busy.has('pull'));
  $('gitPush').classList.toggle('loading', git.busy.has('push'));
  const staged = git.status?.staged?.length || 0;
  const amend = $('gitAmend').checked;
  $('gitCommit').disabled = git.busy.has('commit') || !git.status || (!staged && !amend);
  $('gitCommit').textContent = git.busy.has('commit') ? t('正在提交…') : staged ? t('提交 ({0})', staged) : t('提交');
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
  let total = 0;
  GIT_GROUPS.forEach(([group, title]) => {
    const files = git.status[group] || [];
    if (!files.length) return;
    total += files.length;
    fragment.append(gitGroupHead(group, title, files));
    files.forEach((file) => fragment.append(gitFileRow(group, file)));
  });
  if (!total) fragment.append(el('div', 'git-clean', t('没有未提交的改动')));
  if (git.status.truncated) fragment.append(el('div', 'git-note', t('文件过多, 每组只显示前 2000 个')));
  if (git.commits.length) {
    fragment.append(el('div', 'git-group', t('最近提交')));
    git.commits.forEach((commit) => {
      const row = el('div', 'git-commit-item');
      row.append(el('span', 'git-hash', commit.hash), el('span', 'git-subject', commit.subject), el('span', 'git-date', commit.date));
      row.title = `${commit.hash} · ${commit.author} · ${commit.date}\n${commit.subject}`;
      fragment.append(row);
    });
  }
  const scroll = box.scrollTop;
  box.replaceChildren(fragment);
  box.scrollTop = scroll;
}

function gitGroupHead(group, title, files) {
  const head = el('div', 'git-group');
  head.append(el('span', 'git-group-title', t(title)), el('span', 'git-group-count', String(files.length)));
  const paths = files.map((file) => file.path);
  if (group === 'staged') head.append(gitIconButton('minus', t('全部取消暂存'), () => gitAction('unstage', { paths })));
  if (group === 'unstaged' || group === 'untracked' || group === 'conflicted') head.append(gitIconButton('plus', t('全部暂存'), () => gitAction('stage', { paths })));
  return head;
}

function gitFileRow(group, file) {
  const row = el('div', 'git-file');
  const selected = git.selected && git.selected.group === group && git.selected.path === file.path;
  row.classList.toggle('sel', !!selected);
  const slash = file.path.lastIndexOf('/');
  const name = file.path.slice(slash + 1);
  const dir = slash > 0 ? file.path.slice(0, slash) : '';
  const letter = group === 'conflicted' ? 'U' : file.status;
  const badge = el('span', 'git-badge s-' + (letter === '?' ? 'q' : letter), letter === '?' ? 'U' : letter);
  badge.title = t(GIT_STATUS_NAMES[letter] || letter);
  row.append(badge, el('span', 'git-name', name), el('span', 'git-dir', dir));
  row.title = file.origin ? `${file.origin} → ${file.path}` : file.path;
  const actions = el('span', 'git-actions');
  if (group === 'staged') {
    actions.append(gitIconButton('minus', t('取消暂存'), () => gitAction('unstage', { paths: [file.path] })));
  } else {
    if (group !== 'conflicted') actions.append(gitDiscardButton(group, file));
    actions.append(gitIconButton('plus', t('暂存'), () => gitAction('stage', { paths: [file.path] })));
  }
  row.append(actions);
  row.addEventListener('click', () => gitSelect(group, file));
  return row;
}

function gitIconButton(kind, title, onClick) {
  const button = el('button', 'icon-btn git-btn', kind === 'plus' ? '+' : '−');
  button.title = title;
  button.setAttribute('aria-label', title);
  button.addEventListener('click', (e) => {
    e.stopPropagation();
    onClick();
  });
  return button;
}

// 放弃改动不可撤销, 需要再点一次确认; Mac App 的 WebView 不支持 confirm()
function gitDiscardButton(group, file) {
  const button = el('button', 'icon-btn git-btn git-discard');
  const label = group === 'untracked' ? t('删除文件') : t('放弃改动');
  const reset = () => {
    button.classList.remove('confirm');
    button.replaceChildren(icon('trash'));
    button.title = label;
  };
  reset();
  button.addEventListener('click', (e) => {
    e.stopPropagation();
    if (!button.classList.contains('confirm')) {
      button.classList.add('confirm');
      button.replaceChildren(icon('trash'), group === 'untracked' ? t('确认删除') : t('确认放弃'));
      clearTimeout(button.timer);
      button.timer = setTimeout(reset, 3000);
      return;
    }
    clearTimeout(button.timer);
    gitAction('discard', group === 'untracked' ? { untracked: [file.path] } : { paths: [file.path] });
  });
  return button;
}

function gitRenderDiff() {
  const box = $('gitDiff');
  const selected = git.selected;
  $('gitBody').classList.toggle('has-diff', !!selected);
  if (!selected) {
    box.replaceChildren(el('div', 'git-diff-empty', git.status && !git.status.error ? t('选择文件查看改动') : ''));
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
  const title = el('span', 'git-diff-title', selected.origin ? `${selected.origin} → ${selected.path}` : selected.path);
  const group = GIT_GROUPS.find(([key]) => key === selected.group);
  head.append(back, title, el('span', 'git-diff-group', group ? t(group[1]) : ''));
  const body = el('div', 'git-diff-body');
  if (git.diffError) {
    body.append(el('div', 'git-diff-empty', git.diffError));
  } else if (git.diffText === null) {
    body.append(el('div', 'git-diff-empty', t('正在读取…')));
  } else {
    body.append(gitDiffView(git.diffText));
  }
  const scroll = box.querySelector('.git-diff-body')?.scrollTop || 0;
  box.replaceChildren(head, body);
  body.scrollTop = scroll;
}

// 统一 diff: 两栏行号(旧 / 新), 增删着色; 文件头只保留模式变化等有用信息
function gitDiffView(text) {
  if (!text.trim()) return el('div', 'git-diff-empty', t('没有内容差异(可能只改了文件权限或换行)'));
  if (/^Binary files .* differ$/m.test(text) && !/^@@/m.test(text)) return el('div', 'git-diff-empty', t('二进制文件, 不显示差异'));
  const table = el('div', 'git-diff-lines');
  const lines = text.split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  let oldLine = 0;
  let newLine = 0;
  let inHunk = false;
  const fragment = document.createDocumentFragment();
  const count = Math.min(lines.length, GIT_DIFF_MAX_LINES);
  for (let i = 0; i < count; i++) {
    const line = lines[i];
    let kind = 'ctx';
    let a = '';
    let b = '';
    let content = line;
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
    if (hunk) {
      oldLine = Number(hunk[1]);
      newLine = Number(hunk[2]);
      inHunk = true;
      kind = 'hunk';
    } else if (!inHunk) {
      // 文件头: diff --git / index / --- / +++ 不显示, 其余(新文件、模式变化、重命名)作为说明
      if (/^(diff --git|index |--- |\+\+\+ )/.test(line)) continue;
      kind = 'meta';
    } else if (line.startsWith('+')) {
      kind = 'add';
      b = newLine++;
      content = line.slice(1);
    } else if (line.startsWith('-')) {
      kind = 'del';
      a = oldLine++;
      content = line.slice(1);
    } else if (line.startsWith('\\')) {
      kind = 'meta';
    } else if (line.startsWith('diff --git')) {
      inHunk = false;
      continue;
    } else {
      a = oldLine++;
      b = newLine++;
      content = line.slice(1);
    }
    const row = el('div', 'git-line ' + kind);
    row.append(el('span', 'git-ln', String(a)), el('span', 'git-ln', String(b)), el('span', 'git-code', content || ' '));
    fragment.append(row);
  }
  table.append(fragment);
  if (lines.length > count || git.diffTruncated) table.append(el('div', 'git-note', t('差异过大, 只显示前面部分')));
  return table;
}

// MARK: - Setup

async function gitCommit() {
  const message = $('gitMessage').value.trim();
  const amend = $('gitAmend').checked;
  if (!message && !amend) {
    $('gitMessage').focus();
    toast(t('请填写提交说明'), true, true);
    return;
  }
  if (await gitAction('commit', { message, amend })) {
    $('gitMessage').value = '';
    gitFitMessage();
    $('gitAmend').checked = false;
    toast(t('已提交'));
    gitRenderHead();
  }
}

// 提交说明默认一行, 随内容增高
function gitFitMessage() {
  const input = $('gitMessage');
  input.style.height = '';
  input.style.height = Math.min(input.scrollHeight + 2, 120) + 'px';
}

function setupGit() {
  $('gitPull').addEventListener('click', async () => {
    if (await gitAction('pull')) toast(t('已拉取'));
  });
  $('gitPush').addEventListener('click', async () => {
    if (await gitAction('push')) toast(t('已推送'));
  });
  $('gitCommit').addEventListener('click', gitCommit);
  $('gitAmend').addEventListener('change', gitRenderHead);
  // 点勾选项时保持输入框焦点, 避免勾选项先被隐藏
  $('gitAmend').closest('label').addEventListener('mousedown', (e) => e.preventDefault());
  $('gitMessage').addEventListener('input', gitFitMessage);
  $('gitMessage').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      gitCommit();
    }
  });
  gitRender();
}
