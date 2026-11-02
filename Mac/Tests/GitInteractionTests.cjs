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
