'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Web/git.js', 'utf8');
const storage = new Map();
function create(root) {
  const context = { git: { repo: { root }, collapsed: new Set() }, GIT_COLLAPSED_KEY: 'test:',
    localStorage: { getItem: k => storage.get(k), setItem: (k,v) => storage.set(k,v) }, gitRenderFiles() {} };
  vm.createContext(context);
  vm.runInContext(source.slice(source.indexOf('function gitLoadCollapsed('), source.indexOf('function gitLoadTreeMode(')) +
    source.slice(source.indexOf('function gitFileTree('), source.indexOf('function gitTreeFiles(')) +
    source.slice(source.indexOf('function gitToggle('), source.indexOf('// 分区标题:')), context);
  context.git.collapsed = context.gitLoadCollapsed(root);
  return context;
}
const a = create('/a');
a.gitToggle('group:log', () => {});
a.gitToggle('dir:staged:Mac', () => {});
assert(create('/a').git.collapsed.has('dir:staged:Mac'), 'Cold start retains folders');
assert(create('/a').git.collapsed.has('group:log'), 'Cold start retains groups');
assert.equal(create('/b').git.collapsed.size, 0, 'Repositories are isolated');
const files = ['Mac/A.swift', 'Mac/Nested/B.swift', 'Web/app.js'].map(path => ({group: 'staged', file: {path}}));
a.git.collapsed.add('dir:changes:Other');
a.gitSetSectionExpanded('staged', files, false);
assert(a.git.collapsed.has('dir:staged:Mac/Nested'));
assert(a.git.collapsed.has('dir:staged:Web'));
assert(!a.git.collapsed.has('group:staged'), 'Keep group header and root files visible');
a.gitSetSectionExpanded('staged', files, true);
assert(!create('/a').git.collapsed.has('dir:staged:Mac'));
assert(a.git.collapsed.has('dir:changes:Other'), 'Other section stays untouched');
storage.set('test:/bad', '{'); assert.equal(create('/bad').git.collapsed.size, 0);
storage.set('test:/bad', '{}'); assert.equal(create('/bad').git.collapsed.size, 0);
a.localStorage.setItem = () => { throw new Error('quota'); };
a.gitToggle('group:staged', () => {});
assert(a.git.collapsed.has('group:staged'), 'Storage failure does not break interaction');
console.log('PASS Git cold-start persistence, repository/section isolation, expand/collapse and storage failure');
