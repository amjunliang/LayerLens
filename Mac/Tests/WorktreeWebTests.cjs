const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const source = fs.readFileSync(path.join(__dirname, '../../Web/app.js'), 'utf8');
const start = source.indexOf('const worktreeState =');
const end = source.indexOf('// 选择元素需要连上已集成的 App');
assert(start >= 0 && end > start);

const nodes = new Map();
function makeNode(id) {
  const node = {
    id,
    hidden: true,
    title: '',
    textContent: '',
    dataset: {},
    attributes: new Map(),
    children: [],
    classList: {
      set: new Set(),
      toggle(name, force) {
        if (force === undefined) this.set.has(name) ? this.set.delete(name) : this.set.add(name);
        else force ? this.set.add(name) : this.set.delete(name);
      },
      contains(name) { return this.set.has(name); },
    },
    setAttribute(k, v) { this.attributes.set(k, String(v)); },
    replaceChildren(...kids) { this.children = kids; },
    append(...kids) { this.children.push(...kids); },
  };
  return node;
}
for (const id of ['worktreeChip', 'worktreeChipText', 'runModeBtn', 'worktreeMenuHeading', 'worktreeItems', 'xcodeRun']) {
  nodes.set(id, makeNode(id));
}
let requests = [];
let runSyncCount = 0;
const ctx = {
  Map,
  URLSearchParams,
  targets: { deviceId: 'sim-1', bundleId: 'com.test.app' },
  runMode: 'command',
  xcode: { running: false },
  t: (text) => text,
  el: (tag, cls, text) => ({ tagName: tag, className: cls || '', textContent: text || '', children: [], append(...kids) { this.children.push(...kids); } }),
  document: { createElement: (tag) => makeNode(tag) },
  $: (id) => nodes.get(id),
  syncCommandRun: () => { runSyncCount++; },
  setRunning: () => { runSyncCount++; },
  fetch: async (url, options) => {
    requests.push({ url, options });
    if (url.startsWith('/api/hub/worktrees')) {
      return {
        ok: true,
        json: async () => ({
          deviceId: 'sim-1',
          bundleId: 'com.test.app',
          activeWorktree: '/tmp/wt/ea74/App',
          liveWorktree: '/tmp/wt/ea74/App',
          overridden: false,
          worktrees: [
            { path: '/tmp/wt/ea74/App', name: 'ea74', branch: 'feat/extremely-long-feature-branch-name-1234', head: '1111111', isMain: false, detached: false },
            { path: '/tmp/wt/ab12/App', name: 'ab12', branch: '', head: '2222222', isMain: false, detached: true },
          ],
        }),
      };
    }
    if (url === '/api/hub/worktree') {
      const body = JSON.parse(options.body);
      return {
        ok: true,
        json: async () => ({
          deviceId: 'sim-1',
          bundleId: 'com.test.app',
          activeWorktree: body.path || '/tmp/wt/ea74/App',
          liveWorktree: '/tmp/wt/ea74/App',
          overridden: !!body.path,
          worktrees: [
            { path: '/tmp/wt/ea74/App', name: 'ea74', branch: 'feat/extremely-long-feature-branch-name-1234', head: '1111111', isMain: false, detached: false },
            { path: '/tmp/wt/ab12/App', name: 'ab12', branch: '', head: '2222222', isMain: false, detached: true },
          ],
        }),
      };
    }
    throw new Error('Unexpected fetch: ' + url);
  },
};
vm.createContext(ctx);
vm.runInContext(source.slice(start, end), ctx);

(async () => {
  await ctx.refreshWorktreeState(true);
  assert(requests[0].url.includes('verify=1'));
  const chipText = nodes.get('worktreeChipText').textContent;
  assert.equal(chipText, 'ea74 · feat/extremely-long-feature-branch-name-1234', `Branch chip must show both worktree name and branch cleanly, got: ${chipText}`);
  assert.equal(nodes.get('worktreeChip').hidden, false);
  assert.equal(nodes.get('worktreeChip').classList.contains('overridden'), false);
  assert.equal(nodes.get('runModeBtn').classList.contains('has-worktree'), true);
  assert.equal(ctx.selectedWorktreeForRun(), '');
  assert.equal(nodes.get('worktreeMenuHeading').hidden, false);
  assert.equal(nodes.get('worktreeItems').hidden, false);
  assert.equal(nodes.get('worktreeItems').children.length, 2);

  await ctx.selectWorktree('/tmp/wt/ab12/App');
  assert.equal(nodes.get('worktreeChipText').textContent, 'ab12');
  assert.equal(nodes.get('worktreeChip').classList.contains('overridden'), true);
  assert.equal(ctx.selectedWorktreeForRun(), '/tmp/wt/ab12/App');

  // Selecting the live worktree again clears the override path.
  await ctx.selectWorktree('/tmp/wt/ea74/App');
  assert.equal(JSON.parse(requests.at(-1).options.body).path, '');
  assert.equal(ctx.selectedWorktreeForRun(), '');
  assert(runSyncCount >= 3);

  // Single worktree keeps the worktree+branch visible beside Run while hiding the switcher section.
  ctx.applyWorktreePayload({
    deviceId: 'sim-1',
    bundleId: 'com.test.app',
    activeWorktree: '/tmp/wt/solo/App',
    liveWorktree: '/tmp/wt/solo/App',
    overridden: false,
    worktrees: [{ path: '/tmp/wt/solo/App', name: 'App', branch: 'main', head: '1111111', isMain: true, detached: false }],
  });
  assert.equal(nodes.get('worktreeChip').hidden, false);
  assert.equal(nodes.get('worktreeChipText').textContent, 'App · main');
  assert.equal(nodes.get('worktreeMenuHeading').hidden, true);
  assert.equal(nodes.get('worktreeItems').hidden, true);
  console.log('PASS worktree UI: unified run-bar branch chip, fixed center layout, menu switching and override tracking');
})().catch((err) => { console.error(err); process.exitCode = 1; });
