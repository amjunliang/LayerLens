'use strict';

// 改动面板的右键菜单: 提交(复制哈希、创建补丁、回滚)和文件 / 目录(打开、在 Finder 中显示、复制路径、暂存、放弃)

// 菜单项 [标题, 执行, 禁用, 确认]; 文字已本地化. 有确认的项点击后关闭菜单, 在原位置弹出确认气泡(参数见 showConfirm),
// danger 为 false 的是可撤回的操作, 不标红
function gitShowMenu(x, y, items) {
  hideMenu();
  const menu = el('div', 'context-menu');
  menu.id = 'contextMenu';
  items.forEach((entry) => {
    if (!entry) {
      menu.append(el('div', 'menu-separator'));
      return;
    }
    const [title, run, disabled, confirm] = entry;
    const button = el('button', 'menu-item' + (confirm ? (confirm.danger === false ? ' notice' : ' danger') : ''), title);
    button.disabled = !!disabled;
    button.addEventListener('click', () => {
      const rect = button.getBoundingClientRect();
      hideMenu();
      if (confirm) showConfirm(rect, { ...confirm, onConfirm: run });
      else run();
    });
    menu.append(button);
  });
  document.body.append(menu);
  placeMenu(menu, x, y);
}

function gitFullPath(path) {
  return (git.repo?.root || '') + '/' + path;
}

// 右键未选中的行时先选中它, 与 Finder 一致; 已在多选中时保留多选
function gitShowCommitMenu(e, commit) {
  e.preventDefault();
  if (!gitIsSelected('commits', commit)) gitSelect('commits', commit, {}, git.commits);
  const oid = commit.oid || commit.hash;
  gitShowMenu(e.clientX, e.clientY, [
    [t('复制 SHA-1'), () => copyText(oid, '复制 SHA-1')],
    [t('复制短哈希'), () => copyText(commit.hash, '复制短哈希')],
    [t('复制哈希和标题'), () => copyText(`${commit.hash} ${commit.subject}`, '复制哈希和标题')],
    null,
    [t('创建补丁'), () => gitCopyPatch(oid)],
    null,
    [t('回滚提交'), () => gitRevert(oid), git.busy.has('revert'), { title: t('回滚提交 {0}?', commit.hash), detail: t('会新建一个提交撤销它的改动'), action: t('回滚'), danger: false }],
    gitResetItem(commit, oid),
  ]);
}

// Safari 要求在点击事件中同步写剪贴板, 补丁内容以 Promise 传入; 不支持时读取后再复制
function gitCopyPatch(oid) {
  const load = gitRequest('patch', { commit: oid }).then((result) => {
    if (result.error) throw new Error(String(result.error).split('\n')[0]);
    return result.text || '';
  });
  if (window.isSecureContext && navigator.clipboard?.write && typeof ClipboardItem !== 'undefined') {
    const blob = load.then((text) => new Blob([text], { type: 'text/plain' }));
    navigator.clipboard.write([new ClipboardItem({ 'text/plain': blob })])
      .then(() => toast(t('已复制补丁')))
      .catch((e) => toast(t('复制失败: {0}', e.message), true));
    return;
  }
  load.then((text) => copyText(text, '复制补丁')).catch((e) => toast(t('复制失败: {0}', e.message), true));
}

// 软重置: 分支指向所选提交, 本地改动都保留; 二次确认并说明影响. 游离 HEAD 或已是当前提交时不可用
function gitResetItem(commit, oid) {
  const branch = git.status?.branch || {};
  const name = branch.head && branch.head !== '(detached)' ? branch.head : '';
  const current = branch.oid || '';
  const title = name ? t('将 {0} 重置到这次提交', name) : t('重置当前分支到这次提交');
  const confirm = {
    title: name ? t('将 {0} 重置到 {1}?', name, commit.hash) : t('重置到 {0}?', commit.hash),
    detail: t('工作区和暂存区不变, 跳过的提交的改动会出现在已暂存中; 可在原提交 {0} 上再次重置撤回', current.slice(0, 7)),
    action: t('重置'),
    danger: false,
  };
  return [title, () => gitReset(oid, name, current), !name || !current || current === oid || git.busy.has('reset'), confirm];
}

async function gitReset(oid, name, previous) {
  if (await gitAction('reset', { commit: oid })) toast(t('已将 {0} 重置到 {1}, 原提交 {2}', name, oid.slice(0, 7), previous.slice(0, 7)));
}

async function gitRevert(oid) {
  if (await gitAction('revert', { commit: oid })) toast(t('已回滚提交'));
}

function gitShowFileMenu(e, group, file) {
  e.preventDefault();
  const item = { group, path: file.path, origin: file.origin };
  if (git.selected?.dir || !gitIsSelected('files', item)) gitSelect('files', item, {}, []);
  const items = gitTargets(group, file);
  const deleted = items.length === 1 && file.status === 'D';
  gitShowMenu(e.clientX, e.clientY, [
    [t('打开'), () => gitOpenFile(file.path), items.length > 1 || deleted],
    [t('在 Finder 中显示'), () => gitAction('reveal', { path: file.path })],
    null,
    ...gitPathItems(items.map((target) => target.path)),
    null,
    ...gitChangeItems(group === 'staged' ? 'staged' : 'changes', items),
  ]);
}

function gitShowDirMenu(e, key, section, dir, files) {
  e.preventDefault();
  if (git.selected?.dir !== key) gitSelectDir(key, dir.path, files);
  const items = files.map(({ group, file }) => ({ group, path: file.path }));
  gitShowMenu(e.clientX, e.clientY, [
    [t('在 Finder 中显示'), () => gitAction('reveal', { path: dir.path })],
    null,
    ...gitPathItems([dir.path]),
    null,
    ...gitChangeItems(section, items),
  ]);
}

// 多个文件时每行一个路径
function gitPathItems(paths) {
  return [
    [t('复制相对路径'), () => copyText(paths.join('\n'), '复制相对路径')],
    [t('复制完整路径'), () => copyText(paths.map(gitFullPath).join('\n'), '复制完整路径')],
  ];
}

// 已暂存的可取消暂存; 未暂存和未跟踪的可暂存、放弃, 冲突只能暂存(标记为已解决)
function gitChangeItems(section, items) {
  const paths = items.map((item) => item.path);
  const count = (text, n) => (n > 1 ? `${text} (${n})` : text);
  if (section === 'staged') return [[count(t('取消暂存'), paths.length), () => gitStage('unstage', paths)]];
  const entries = [[count(t('暂存'), paths.length), () => gitStage('stage', paths)]];
  const discard = items.filter((item) => item.group === 'unstaged' || item.group === 'untracked');
  if (discard.length) {
    const removing = discard.every((item) => item.group === 'untracked');
    const title = removing ? t('删除文件') : t('放弃改动');
    entries.push(null, [count(title, discard.length), () => gitDiscard(discard), false, gitDiscardConfirm(discard)]);
  }
  return entries;
}
