'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Web/git.js', 'utf8');
const storage = new Map();
function create(root) {
  const frames = [];
  let renders = 0;
  const context = { git: { repo: { root }, collapsed: new Set(), active:true }, GIT_COLLAPSED_KEY: 'test:',
    GIT_SECTIONS: [['staged', '', ['staged']], ['changes', '', ['unstaged','untracked']]],
    localStorage: {
      getItem: k => storage.get(k) ?? null, setItem: (k,v) => storage.set(k,v), removeItem: k => storage.delete(k),
      key: i => [...storage.keys()][i] ?? null, get length() { return storage.size; },
    }, requestAnimationFrame: fn => { frames.push(fn); return frames.length; },
    gitRenderFiles() { renders++; }, gitRenderDiff() { renders++; } };
  vm.createContext(context);
  vm.runInContext(source.slice(source.indexOf('function gitCollapsePrefix('), source.indexOf('function gitLoadTreeMode(')) +
    source.slice(source.indexOf('function gitFileTree('), source.indexOf('function gitTreeFiles(')) +
    source.slice(source.indexOf('function gitToggle('), source.indexOf('// 分区标题:')), context);
  context.git.collapsed = context.gitLoadCollapsed(root);
  return Object.assign(context, { flush: () => { while(frames.length) frames.shift()(); }, renders: () => renders });
}
const files = paths => paths.map(path => ({group:'staged', file:{path}}));
const tree = (c,paths) => c.gitFileTree(files(paths));
const a = create('/a');
a.gitToggle('group:log', () => {});
a.gitToggle('dir:staged:Mac', () => {});
assert(create('/a').git.collapsed.has('dir:staged:Mac'), 'Cold start retains folders');
assert(create('/a').git.collapsed.has('group:log'), 'Cold start retains groups');
assert.equal(create('/b').git.collapsed.size, 0, 'Repositories are isolated');
const items = files(['Mac/A.swift', 'Mac/Nested/B.swift', 'Web/app.js']);
a.git.collapsed.add('dir:changes:Other');
a.git.collapsed.add('file:Mac/A.swift');
a.gitSetSectionExpanded('staged', items, false);
assert(a.git.collapsed.has('dir:staged:Mac/Nested'));
assert(a.git.collapsed.has('dir:staged:Web'));
assert(!a.git.collapsed.has('group:staged'));
a.gitSetSectionExpanded('staged', items, true);
assert(!create('/a').git.collapsed.has('dir:staged:Mac'));
assert(a.git.collapsed.has('dir:changes:Other'), 'Other section stays untouched');
assert(a.git.collapsed.has('file:Mac/A.swift'), 'Tree action cannot change diff state');
assert(storage.has(a.gitCollapseStorageKey('/a','file:Mac/A.swift')));
assert(storage.has(a.gitCollapseStorageKey('/a','dir:changes:Other')));

// A stale window writes only its changed item, never the entire older snapshot.
const stale = create('/a');
a.gitToggle('dir:staged:Fresh', () => {});
stale.gitToggle('file:other', () => {});
assert(create('/a').git.collapsed.has('dir:staged:Fresh'));
assert(stale.git.collapsed.has('dir:staged:Fresh'), 'Save incorporates remote changes');
stale.gitSyncCollapsed({key:'test:v2:%2Fb:tree:any'}); stale.flush();
assert.equal(stale.renders(),0, 'Ignore other repositories');
a.gitToggle('dir:staged:Fresh', () => {});
for(let n=0;n<20;n++) stale.gitSyncCollapsed({key:a.gitCollapseStorageKey('/a','dir:staged:Fresh')});
stale.flush(); assert.equal(stale.renders(),2, 'Batch tree/diff redraws for a storage event burst');
assert(!stale.git.collapsed.has('dir:staged:Fresh'), 'Remote expansion propagates');

// Compact display changes must keep raw directory identities.
const compact = tree(a,['Mac/LayerLens/A.swift']).dirs.get('Mac');
assert.equal(compact.name,'Mac/LayerLens');
a.gitToggleDir('staged',compact);
assert(a.gitDirCollapsed('staged',tree(a,['Mac/LayerLens/A.swift','Mac/Other/B.swift']).dirs.get('Mac')));
const split = tree(a,['Mac/LayerLens/A.swift','Mac/Other/B.swift']).dirs.get('Mac');
a.gitToggleDir('staged',split);
const child = split.dirs.get('LayerLens');
assert(a.gitDirCollapsed('staged',child), 'Opening parent retains child collapse');
a.gitToggleDir('staged',child);
assert(!a.gitDirCollapsed('staged',tree(a,['Mac/LayerLens/A.swift']).dirs.get('Mac')), 'Recompact stays expanded');

storage.set('test:/legacy',JSON.stringify(['dir:staged:Mac/LayerLens','file:one']));
const legacy=create('/legacy');
assert(legacy.gitDirCollapsed('staged',tree(legacy,['Mac/LayerLens/A.swift']).dirs.get('Mac')));
assert(legacy.git.collapsed.has('file:one'));
assert(!storage.has('test:/legacy'), 'Migrate only after writing new format');
assert(create('/legacy').git.collapsed.has('file:one'));
storage.set('test:/quota',JSON.stringify(['dir:staged:Old']));
const quota=create('/quota');
// Simulate an earlier migration failing to persist its result.
storage.set('test:/quota',JSON.stringify(['dir:staged:Old']));
quota.gitToggle('dir:staged:Old',()=>{});
assert(!create('/quota').git.collapsed.has('dir:staged:Old'), 'Retry migration before applying an expansion');
// Old area wrappers are removed without losing a newer explicit expansion.
storage.set('test:v2:%2Farea:tree:'+encodeURIComponent('dir:staged:A'),'1');
const area=create('/area');
assert(area.git.collapsed.has('dir:staged:A'));
assert(![...storage.keys()].some(k => k.startsWith('test:v2:%2Farea:tree:')));

const status = (staged=[],unstaged=[],untracked=[]) => ({staged:staged.map(path=>({path})),unstaged:unstaged.map(path=>({path})),untracked:untracked.map(path=>({path}))});
const move=create('/move');
move.gitTransferDirState(status([],['A/x','A/y']));
move.gitToggleDir('changes',tree(move,['A/x','A/y']).dirs.get('A'));
move.gitTransferDirState(status(['A/x','A/y']));
assert(move.git.collapsed.has('dir:staged:A'), 'Complete stage inherits collapse');
move.gitToggleDir('staged',tree(move,['A/x','A/y']).dirs.get('A'));
move.gitTransferDirState(status([],['A/x','A/y']));
assert(!move.git.collapsed.has('dir:changes:A'), 'Complete unstage inherits expansion when destination is absent');

const partial=create('/partial');
partial.gitTransferDirState(status([],['A/x','A/y']));
partial.gitToggleDir('changes',tree(partial,['A/x','A/y']).dirs.get('A'));
partial.gitTransferDirState(status(['A/x'],['A/y']));
assert(partial.git.collapsed.has('dir:changes:A'));
assert(!partial.git.collapsed.has('dir:staged:A'), 'Partial stage keeps target independently expanded');
partial.gitTransferDirState(status(['A/x','A/y']));
assert(!partial.git.collapsed.has('dir:staged:A'), 'Appending to an existing target must not collapse it');
const restart=create('/partial');
restart.gitTransferDirState(status([],['A/x','A/y']));
restart.gitTransferDirState(status(['A/x','A/y']));
assert(restart.git.collapsed.has('dir:staged:A'), 'A complete move inherits current source state, replacing an absent destination’s old memory');

const unstage=create('/unstage');
unstage.gitTransferDirState(status(['A/x']));
unstage.gitToggleDir('staged',tree(unstage,['A/x']).dirs.get('A'));
unstage.gitTransferDirState(status([],['A/x']));
assert(unstage.git.collapsed.has('dir:changes:A'), 'Complete unstage inherits collapse');
const previous=unstage.git.dirStatus;
unstage.gitTransferDirState({error:'temporary'});
assert.equal(unstage.git.dirStatus,previous, 'Status failure cannot erase transfer origin');

const remote=create('/remote');
remote.gitTransferDirState(status(['A/old'],['A/x']));
const other=create('/remote');
other.gitTransferDirState(status(['A/x']));
other.gitToggleDir('staged',tree(other,['A/x']).dirs.get('A'));
remote.gitTransferDirState(status(['A/x']));
assert(remote.git.collapsed.has('dir:staged:A'), 'An existing destination in another window wins');
const inverse=create('/inverse');
inverse.gitTransferDirState(status(['A/x'],['A/y']));
inverse.gitToggleDir('staged',tree(inverse,['A/x']).dirs.get('A'));
inverse.gitTransferDirState(status(['A/x','A/y']));
assert(inverse.git.collapsed.has('dir:staged:A'), 'Existing collapsed target wins over expanded source');

// Exercise the real status handler, so incoming Git updates actually trigger inheritance.
const live=create('/status-handler');
live.gitRender=()=>{}; live.gitLoadLog=()=>{}; live.gitLoadDiff=()=>{};
vm.runInContext(source.slice(source.indexOf('function gitOnStatus('),source.indexOf('function gitFindFile(')),live);
live.gitOnStatus(JSON.stringify(status([],['A/Nested/x'])));
live.gitToggleDir('changes',tree(live,['A/Nested/x']).dirs.get('A'));
live.gitOnStatus(JSON.stringify(status(['A/Nested/x'])));
assert(live.git.collapsed.has('dir:staged:A'));
assert(live.git.collapsed.has('dir:staged:A/Nested'));
// Option-click toggles the entire subtree without affecting siblings or the other group.
const option=create('/option');
const optionTree=tree(option,['A/root','A/Child/one','A/Child/Deep/two','B/other']);
const optionDir=optionTree.dirs.get('A');
option.git.collapsed.add('dir:staged:B');
option.git.collapsed.add('dir:changes:A');
option.gitToggleDir('staged',optionDir,true);
for (const path of ['A','A/Child','A/Child/Deep']) assert(option.git.collapsed.has('dir:staged:'+path));
option.gitToggleDir('staged',optionDir,true);
for (const path of ['A','A/Child','A/Child/Deep']) assert(!option.git.collapsed.has('dir:staged:'+path));
assert(option.git.collapsed.has('dir:staged:B'));
assert(option.git.collapsed.has('dir:changes:A'));
assert(!create('/option').git.collapsed.has('dir:staged:A/Child/Deep'));
option.gitToggleDir('staged',optionDir);
assert(option.git.collapsed.has('dir:staged:A'));
assert(!option.git.collapsed.has('dir:staged:A/Child'), 'Ordinary click keeps descendant states');
// Group-arrow Option gesture and context-menu actions use the real section handler.
const header=create('/header'); header.git.tree=true;
class Element {
  constructor(){this.children=[];this.events={};this.dataset={};}
  append(...children){this.children.push(...children);}
  addEventListener(name,fn){this.events[name]=fn;}
}
header.el=()=>new Element();header.icon=()=>new Element();header.t=s=>s;
header.gitCheckbox=()=>new Element();let menu;
header.gitShowMenu=(_x,_y,items)=>menu=items;
vm.runInContext(source.slice(source.indexOf('function gitSectionHead('),source.indexOf('// 勾选状态')),header);
const head=header.gitSectionHead('staged','Staged',files(['A/x','A/Child/y']),false);
assert.equal(head.children.length,4,'No permanent expand/collapse buttons');
let stopped=false;
head.children[0].events.click({altKey:true,stopPropagation(){stopped=true;}});
assert(stopped);assert(header.git.collapsed.has('group:staged'));
assert(header.git.collapsed.has('dir:staged:A/Child'));
head.children[0].events.click({altKey:true,stopPropagation(){}});
assert(!header.git.collapsed.has('group:staged'));
assert(!header.git.collapsed.has('dir:staged:A/Child'));
head.events.contextmenu({clientX:1,clientY:2,preventDefault(){}});
menu[1][1]();assert(header.git.collapsed.has('dir:staged:A/Child'));
menu[0][1]();assert(!header.git.collapsed.has('dir:staged:A/Child'));
storage.set('test:/bad','{'); assert.equal(create('/bad').git.collapsed.size,0);
a.localStorage.setItem=()=>{throw new Error('quota');};
a.gitToggle('group:staged',()=>{});
assert(a.git.collapsed.has('group:staged'), 'Storage failure does not break interaction');
const css = fs.readFileSync('Web/app.css', 'utf8');
assert.match(css, /\.git-sec-file \{[^}]*margin-bottom: 8px;[^}]*border: 1px solid var\(--border\);/);
assert.match(css, /\.git-sec-file > \.git-sec-body > \.git-hunk \{[^}]*margin: 0;[^}]*border: 0;[^}]*border-radius: 0;/);
assert.match(css, /\.git-sec-file:not\(\.collapsed\) > \.git-sec-head \{[^}]*position: sticky;/);
console.log('PASS complete stage/unstage inheritance, partial-stage independence, existing destination priority, recursive Option toggle, migration, cold start, window isolation and unified expandable file blocks');
