'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source=fs.readFileSync('Web/git.js','utf8');
class Node {
  constructor(key='',classes='') { this.dataset={gitRowKey:key}; this.className=classes; this.children=[]; this.parent=null; this.removed=0; }
  get classList() { return {contains:key=>this.className.split(' ').includes(key),toggle:(key,on)=>{
    const keys=new Set(this.className.split(' ').filter(Boolean)); if(on)keys.add(key);else keys.delete(key);this.className=[...keys].join(' ');
  }}; }
  append(...nodes){ for(const node of nodes)this.insertBefore(node,null); }
  insertBefore(node,before){
    if(node.parent){const list=node.parent.children;list.splice(list.indexOf(node),1);}
    const index=before?this.children.indexOf(before):this.children.length;
    assert(index>=0);this.children.splice(index,0,node);node.parent=this;
  }
  remove(){this.removed++;if(this.parent){const list=this.parent.children;list.splice(list.indexOf(this),1);this.parent=null;}}
  get firstElementChild(){return this.children[0]||null;}
  get nextElementSibling(){return this.parent?.children[this.parent.children.indexOf(this)+1]||null;}
  querySelectorAll(selector){assert.equal(selector,'.git-row');return this.children.flatMap(node=>[...(node.classList.contains('git-row')?[node]:[]),...node.querySelectorAll(selector)]);}
}
const c={};vm.createContext(c);
vm.runInContext(source.slice(source.indexOf('function gitPatchFileRows('),source.indexOf('// 提交记录接在改动后面')),c);
const box=new Node(), fragment=new Node();
const selected=new Node('dir:changes:A','git-row sel'), child=new Node('file:unstaged:A/x','git-row');
const sibling=new Node('dir:changes:B','git-row'), log=new Node('log','git-log'), commit=new Node('','git-row hover sel');
log.append(commit);box.append(selected,child,sibling,log);
const desiredLog=new Node('log','git-log');desiredLog.append(new Node('','git-row'));
fragment.append(new Node('dir:changes:A','git-row sel collapsed'),new Node('dir:changes:B','git-row'),desiredLog);
c.gitPatchFileRows(box,fragment);
assert.equal(box.children[0],selected);assert.equal(box.children[1],sibling);assert.equal(box.children[2],log);
assert.equal(selected.removed,0,'Selected row stays connected while collapsing');
assert.equal(sibling.removed,0,'Unrelated row stays connected');assert.equal(child.removed,1);
assert(selected.classList.contains('sel'));assert(selected.classList.contains('collapsed'));
assert(commit.classList.contains('hover'),'Commit hover survives');assert(!commit.classList.contains('sel'),'Commit selection updates');
const expanded=new Node(), newChild=new Node('file:unstaged:A/x','git-row');
expanded.append(new Node('dir:changes:A','git-row sel'),newChild,new Node('dir:changes:B','git-row'),desiredLog);
c.gitPatchFileRows(box,expanded);
assert.equal(box.children[0],selected);assert.equal(box.children[1],newChild);assert.equal(box.children[2],sibling);
assert.equal(selected.removed,0);assert.equal(log.removed,0);
console.log('PASS stable selected/hovered DOM nodes, local collapse/expand insertion, sibling retention and commit selection');

// Keyboard navigation uses only visible rows and retains the usual input/shortcut boundaries.
const keyboard = { Element: class {}, git: { focused: true, selected: { kind: 'files' } }, gitVisible: () => true };
let rows, chosen = '', scrolled = '';
function keyboardRow(key, selected = false) {
  return { dataset: { gitRowKey: key }, classList: { contains: name => name === 'sel' && selected },
    click() { chosen = key; rows = rows.map(row => keyboardRow(row.dataset.gitRowKey, row.dataset.gitRowKey === key)); },
    scrollIntoView(options) { assert.equal(options.block, 'nearest'); scrolled = key; } };
}
keyboard.$ = () => ({ querySelectorAll: () => rows });
vm.createContext(keyboard);
vm.runInContext(source.slice(source.indexOf('function gitHandleKey('), source.indexOf('function setupGit(')), keyboard);
const key = (name, extra = {}) => keyboard.gitHandleKey({ key: name, ...extra });
rows = [keyboardRow('dir:changes:A', true), keyboardRow('file:unstaged:A/x'), keyboardRow('file:unstaged:B/y')];
assert(key('ArrowDown')); assert.equal(chosen, 'file:unstaged:A/x'); assert.equal(scrolled, chosen);
assert(key('ArrowDown')); assert.equal(chosen, 'file:unstaged:B/y');
assert(key('ArrowDown')); assert.equal(chosen, 'file:unstaged:B/y', 'Bottom boundary stays selected');
assert(key('ArrowUp')); assert.equal(chosen, 'file:unstaged:A/x');
rows = [keyboardRow('dir:changes:A', true), keyboardRow('file:unstaged:B/y')];
assert(key('ArrowDown')); assert.equal(chosen, 'file:unstaged:B/y', 'Collapsed children are skipped');
assert.equal(key('ArrowDown', { metaKey: true }), false);
keyboard.git.focused = false; assert.equal(key('ArrowDown'), false); keyboard.git.focused = true;
keyboard.git.selected = { kind: 'commits' }; assert.equal(key('ArrowDown'), false);
keyboard.git.selected = null; assert(key('ArrowUp')); assert.equal(chosen, 'dir:changes:A');
const input = new keyboard.Element(); input.closest = () => true;
assert.equal(key('ArrowDown', { target: input }), false, 'Editing text keeps arrow keys');
console.log('PASS Git arrow selection, scrolling, collapsed rows, boundaries and keyboard isolation');

let collapsed = true, toggles = 0;
keyboard.MouseEvent = class { constructor(type, options) { this.type = type; this.bubbles = options.bubbles; } };
const folder = { dataset: { gitRowKey: 'dir:changes:A' }, classList: { contains: name => name === 'collapsed' && collapsed },
  querySelector: selector => { assert.equal(selector, '.git-chevron'); return { dispatchEvent(event) {
    assert.equal(event.type, 'click'); assert(event.bubbles); collapsed = !collapsed; toggles++;
  } }; } };
rows = [folder]; keyboard.git.selected = { kind: 'files', dir: 'dir:changes:A' };
assert(key('ArrowRight')); assert.equal(collapsed, false); assert.equal(toggles, 1);
assert(key('ArrowRight')); assert.equal(toggles, 1, 'Right does not collapse an expanded directory');
assert(key('ArrowLeft')); assert.equal(collapsed, true); assert.equal(toggles, 2);
assert(key('ArrowLeft')); assert.equal(toggles, 2, 'Left does not expand a collapsed directory');
keyboard.git.selected = { kind: 'files', items: [{ path: 'x' }] };
assert(key('ArrowLeft')); assert.equal(toggles, 2, 'A selected file does not toggle directories or the hierarchy tree');
assert.equal(key('ArrowRight', { target: input }), false);
console.log('PASS Git directory left/right expansion, repeated keys and selection/input isolation');

(async () => {
  const requests = [];
  let reloads = 0;
  const fields = {
    gitMessage: { value: 'Commit in A' },
    gitAmend: { checked: false },
    gitPushAfter: { checked: true },
  };
  const targets = { deviceId: 'phone-a', bundleId: 'app' };
  const git = { device: 'phone-a', key: 'app', repo: { root: '/repo/a' }, status: { hasRemote: true, branch: { head: 'main' } }, busy: new Set() };
  const panel = vm.createContext({
    git, targets, $: key => fields[key], t: text => text, toast() {}, gitFitMessage() {}, gitRenderHead() {},
    gitConnect: () => { reloads++; },
    fetch: (url, options) => new Promise(resolve => requests.push({ url, body: JSON.parse(options.body), resolve })),
  });
  for (const [start, end] of [
    ['function gitIsCurrent()', 'function gitVisible()'],
    ['function gitActionTarget()', 'function gitOnStatus('],
    ['async function gitCommit()', 'function gitFitMessage()'],
  ]) {
    vm.runInContext(source.slice(source.indexOf(start), source.indexOf(end)), panel);
  }

  const commit = panel.gitCommit();
  const refresh = panel.gitAction('refresh');
  targets.deviceId = git.device = 'phone-b';
  git.repo = { root: '/repo/b' };
  git.busy = new Set();
  git.committing = null;
  fields.gitMessage.value = 'New draft in B';

  requests[1].resolve({ status: 409, json: async () => ({ error: 'Repository changed', reason: 'repositoryChanged' }) });
  assert.equal(await refresh, false);
  assert.equal(reloads, 0, 'A stale response must not reconnect the new panel');
  requests[0].resolve({ status: 200, json: async () => ({ ok: true }) });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(requests[2].url, '/api/hub/git/push');
  assert.deepEqual(requests[2].body, { device: 'phone-a', app: 'app', root: '/repo/a', expectedBranch: 'main' });
  requests[2].resolve({ status: 200, json: async () => ({ ok: true }) });
  await commit;
  assert.equal(fields.gitMessage.value, 'New draft in B');
  assert.equal(git.repo.root, '/repo/b');
  console.log('PASS commit and push stay on the original repository after switching targets');
})().catch(error => { console.error(error); process.exitCode = 1; });
