'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Web/app.js','utf8');
const slice = (a,b) => source.slice(source.indexOf(a),source.indexOf(b,source.indexOf(a)));
function create() {
  const requests = [], messages = [];
  let dialog, resync = 0;
  const c = {
    logs: {source:'live',instanceId:'launch-1',lines:['keep'],key:'phone|app'},
    net: {instanceId:'launch-1',epoch:'epoch-1',token:1}, launchState: {selected:''},
    targets: {deviceId:'phone',bundleId:'app'}, URLSearchParams,
    logTargetKey: () => c.targets.deviceId+'|'+c.targets.bundleId,
    targetBase: () => '/target/'+c.targets.deviceId+'/'+c.targets.bundleId,
    $: id => ({id}), t: s => s, showConfirm: (_button,d) => {dialog=d;},
    toast: (...args) => messages.push(args), scheduleLogRender(){}, loadLaunches(){}, resyncNet(){resync++;},
    fetch: (url,options) => new Promise(resolve => requests.push({url,options,resolve})),
  };
  vm.createContext(c);
  vm.runInContext(slice('async function logAction(', '// 菜单向下展开') + slice('async function clearNet(', 'function setNetDetailWidth('),c);
  const reply = (n,ok=true) => requests[n].resolve({ok,status:ok?200:500,json:async()=>({})});
  return {c,requests,messages,dialog:()=>dialog,reply,resync:()=>resync};
}
(async()=>{
  for(const kind of ['log','net']) {
    const f=create(); f.c.confirmRecordClear(kind);
    assert(f.dialog()); assert.equal(f.requests.length,0,'Confirmation precedes deletion');
    f.c.targets.bundleId='other'; f.dialog().onConfirm();
    assert.equal(f.requests.length,0,'Target changed while dialog open');
    assert.equal(f.messages.length,1);
    const launch=create(); launch.c.confirmRecordClear(kind);
    (kind==='log'?launch.c.logs:launch.c.net).instanceId='launch-2';
    launch.dialog().onConfirm(); assert.equal(launch.requests.length,0,'Stale launch cannot clear');
  }
  const history=create(); history.c.logs.source='file'; history.c.confirmRecordClear('log');
  history.c.net.archive='saved'; history.c.confirmRecordClear('net'); assert(!history.dialog());
  const log=create(); const job=log.c.recordClearContext('log');
  const pending=log.c.clearLogs(job); assert.equal(log.requests.length,1);
  log.c.confirmRecordClear('log'); assert(!log.dialog(),'Do not duplicate an in-flight clear');
  assert.deepEqual(JSON.parse(log.requests[0].options.body),{device:'phone',app:'app',instanceId:'launch-1'});
  log.c.logs.lines=['new-after-reset']; log.reply(0); await pending;
  assert.deepEqual(log.c.logs.lines,['new-after-reset'],'Late HTTP success cannot erase new logs');
  const failed=log.c.clearLogs(job); log.reply(1,false); await failed;
  assert.deepEqual(log.c.logs.lines,['new-after-reset'],'Failed clear preserves display');
  const net=create(); const njob=net.c.recordClearContext('net');
  const clearing=net.c.clearNet(njob); assert(net.requests[0].url.endsWith('?instanceId=launch-1&epoch=epoch-1'));
  net.c.net.token++; net.reply(0); await clearing;
  assert.equal(net.resync(),0,'Old response cannot reset a switched target');
  const epoch=create(); epoch.c.confirmRecordClear('net'); epoch.c.net.epoch='epoch-2';
  epoch.dialog().onConfirm(); assert.equal(epoch.requests.length,0);
  console.log('PASS shared clear confirmation, history guard, target/launch/epoch isolation and late response safety');
})().catch(e=>{console.error(e);process.exitCode=1;});
