'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Web/app.js', 'utf8');
const section = (a,b) => source.slice(source.indexOf(a),source.indexOf(b,source.indexOf(a)));
class Element { constructor(editing=false) {this.editing=editing;} closest() {return this.editing;} }
for (const mode of ['2d','3d']) {
  const win={key:'second'};let updates=0,detail=0,render=0;
  const state={mode,selected:'label',hover:'label',vcFocus:true,classTarget:{},detail:{},tabBeforeVC:'attr'};
  const ctx={state,Element,picker:{on:false},currentWindow:()=>win,select(){},clearTimeout(){},hideHoverTip(){},setTabButtons(){},renderTree(){},recenterStage(){},renderCanvas(){render++;},updateHighlights(){updates++;},updatePivot(){},loadDetail(){detail++;},document:{body:{classList:{contains:()=>false}},querySelector:()=>null}};
  vm.createContext(ctx);vm.runInContext(section('function clearSelection()', 'function select(key, fromTree)'),ctx);
  assert.equal(ctx.canEscapeClearSelection({target:new Element()}),true);
  ctx.document.querySelector=()=>({});assert.equal(ctx.canEscapeClearSelection({target:new Element()}),false,'Close a menu/dialog first');ctx.document.querySelector=()=>null;
  assert.equal(ctx.canEscapeClearSelection({target:new Element(true)}),false,'Do not steal input/panel Escape');
  ctx.picker.on=true;assert.equal(ctx.canEscapeClearSelection({target:new Element()}),false);ctx.picker.on=false;
  ctx.clearSelection();assert.equal(state.selected,null);assert.equal(state.hover,null);assert.equal(state.classTarget,null);assert.equal(state.vcFocus,false);assert.equal(state.detail,null);assert.equal(state.selectionWindow,win);assert.equal(detail,1);assert.equal(updates,1);
  state.selected='label';state.subtreeOnly=true;ctx.clearSelection();assert.equal(render,mode==='3d'?1:0);
  state.mode='live';state.selected='label';ctx.clearSelection();assert.equal(state.selected,'label','Do not affect device interaction');
}
assert(source.includes('if (node) select(node.key);\n    else clearSelection();'),'Blank click clears selection after the existing drag/cancel guards');
console.log('PASS canvas deselection: 2D/3D state, secondary window, subtree, Escape precedence and live isolation');
