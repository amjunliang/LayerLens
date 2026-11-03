const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../Web/app.js'), 'utf8');
function section(a,b) { const start=source.indexOf(a), end=source.indexOf(b,start); assert(start>=0&&end>start); return source.slice(start,end); }
const deferred = () => {let resolve,reject; const promise=new Promise((a,b)=>{resolve=a;reject=b;}); return {promise,resolve,reject};};
function create() {
  const timers = new Map(), requests=[], applied=[], cancellations=[], notices=[];
  let id=0;
  const ctx={AbortController, DOMException, crypto:{randomUUID:()=>String(++id)},
    targets:{deviceId:'phone',bundleId:'a'}, state:{mode:'live',views:{},pivot:{}},
    pageActivity:{active:true,controller:null}, appState:{source:{},value:'online'}, appInfoSeq:0, refreshSeq:0,
    ACTIVATE_DEBOUNCE_MS:150, STAY_OFFLINE_KEY:'stay', targetStateHub:{epoch:'one',inventoryRevision:1},
    setTimeout:(fn,ms)=>{const key=++id;timers.set(key,{fn,ms});return key;},clearTimeout:key=>timers.delete(key),
    fetch:(url,options={})=>{if(url.includes('activation/cancel')){cancellations.push(JSON.parse(options.body));return Promise.resolve({});} const d=deferred();requests.push({url,options,...d}); options.signal?.addEventListener('abort',()=>d.reject(new DOMException('Cancelled','AbortError')),{once:true});return d.promise;},
    activateApp:async()=>({ready:true}), loadAppInfo:async()=>{}, currentApp:()=>({instanceId:'one'}), appInBackground:a=>a.foreground===false, compatibilityWarning:()=>'',
    applyTargetInventory(){}, renderTargetMenu(){}, syncOfflineView(){}, resetImages(){}, hideToast(){},
    $:()=>null, t:(s,...args)=>s.replace(/\{(\d+)\}/g,(_,n)=>args[n]), toast:s=>notices.push(s),
    setAppState:value=>ctx.appState.value=value, sessionStorage:{setItem(){}},
    api:(url,options)=>ctx.fetch(url,options).then(r=>r.json()), applyHierarchy:value=>applied.push(value), showRefreshError:e=>notices.push(e.message),
    currentDevice:()=>({}), liveAvailable:()=>false, setRunning(){}, clearHierarchy(){}, hideHoverTip(){}, syncModeUI(){}, liveStart(){}, layoutLive(){}, fitView(){},liveSuspend(){},renderCanvas(){},applyStageTransform(){},
  };
  vm.createContext(ctx);
  vm.runInContext(section('// 每次选择拥有独立任务;', '// 兼容旧页面重载')+
    section('async function refresh()', 'function showRefreshError')+
    'let modeSeq = 0;\n'+section('async function setMode(mode)', '// 小屏用单栏'),ctx);
  const tick=async()=>{for(let i=0;i<12;i++)await Promise.resolve();};
  return {ctx,timers,requests,applied,cancellations,notices,tick,
    task:()=>vm.runInContext('targetTask',ctx),pending:()=>vm.runInContext('pendingSwitch',ctx),
    select:bundle=>{ctx.targets.bundleId=bundle;return ctx.beginTargetTask('phone',bundle,bundle);},
    fire:async ms=>{const item=[...timers].find(([,v])=>v.ms===ms);assert(item,'Missing timer '+ms);timers.delete(item[0]);const p=item[1].fn();await tick();return {promise:p};},
  };
}
(async()=>{
  // B 尚未发出就选择 C: B 的定时器/等待立即结束, 只执行 C。
  const queued=create(); let activations=[];
  queued.ctx.activateApp=async(d,b)=>{activations.push(b);return {ready:true};};
  const b=queued.select('b'); const pb=queued.ctx.activateSelectedAppLater('phone','b','B');
  const c=queued.select('c'); const pc=queued.ctx.activateSelectedAppLater('phone','c','C');
  await pb;assert(b.controller.signal.aborted);assert.equal(queued.pending(),c);
  await queued.fire(150);assert.deepEqual(activations,['c']);
  queued.requests[0].resolve({ok:true,json:async()=>({})}); await pc;
  assert.equal(queued.pending(),null);assert.equal(c.phase,'done');

  // B 激活在途, C 立即取得界面所有权; B 的成功/失败结果都不得覆盖 C。
  for(const failure of [false,true]) {
    const t=create(), reply=deferred();t.ctx.activateApp=()=>reply.promise;
    const old=t.select('b'); const pending=t.ctx.activateSelectedAppLater('phone','b','B'); await t.fire(150);
    const current=t.select('c');reply.resolve(failure?{failure:'old failure'}:{ready:true});await pending;await t.tick();
    assert.equal(t.task(),current);assert.equal(t.ctx.appState.value,'online');assert.deepEqual(t.notices,[]);
    assert(old.controller.signal.aborted);assert.equal(t.pending(),null);
  }

  // 激活未结束时点 2D/3D: 模式立即变化, 不提前请求层级; 激活后只获取最后模式。
  const mode=create(), ready=deferred();mode.ctx.liveAvailable=()=>true;mode.ctx.activateApp=()=>ready.promise;
  const job=mode.select('b'); const switching=mode.ctx.activateSelectedAppLater('phone','b','B');await mode.fire(150);
  const two=mode.ctx.setMode('2d'); const three=mode.ctx.setMode('3d');
  assert.equal(mode.ctx.state.mode,'3d');assert.equal(mode.requests.length,0);
  ready.resolve({ready:true});await mode.tick();
  mode.requests[0].resolve({ok:true,json:async()=>({})});await mode.tick();
  assert.equal(mode.requests[1].url,'/api/hierarchy');
  mode.requests[1].resolve({ok:true,json:async()=>['B']});await Promise.all([two,three,switching]);
  assert.deepEqual(mode.applied,[['B']]);assert.equal(job.phase,'done');assert.equal(mode.pending(),null);

  // 层级永不响应: 五秒后清除切换状态并允许继续操作。
  const hung=create();hung.ctx.state.mode='2d';const h=hung.select('b');
  const hp=hung.ctx.activateSelectedAppLater('phone','b','B');await hung.fire(150);
  hung.requests[0].resolve({ok:true,json:async()=>({})});await hung.tick();
  await hung.fire(5000);await hp;assert.equal(h.phase,'failed');assert.equal(hung.pending(),null);assert.equal(hung.notices.length,1);
  const retry=hung.ctx.refresh();assert.equal(h.phase,'hierarchy');hung.requests.at(-1).resolve({ok:true,json:async()=>['retry']});await retry;assert.equal(h.phase,'done');

  // 新目标立即取消旧层级, 旧结果不会写入新页面。
  const hierarchy=create();hierarchy.ctx.state.mode='2d';const a=hierarchy.select('a');const reading=hierarchy.ctx.refresh();
  const next=hierarchy.select('c');await reading;assert(a.controller.signal.aborted);assert.equal(hierarchy.task(),next);assert.deepEqual(hierarchy.applied,[]);

  // 列表超时不阻塞完成; 异常统一收尾。新任务不会等旧任务。
  const inventory=create();inventory.select('b');const inv=inventory.ctx.activateSelectedAppLater('phone','b','B');await inventory.fire(150);await inventory.fire(3000);await inv;assert.equal(inventory.pending(),null);assert.equal(inventory.task().phase,'done');
  const error=create();error.ctx.loadAppInfo=async()=>{throw Error('broken');};error.select('b');const ep=error.ctx.activateSelectedAppLater('phone','b','B');await error.fire(150);error.requests[0].resolve({ok:true,json:async()=>({})});await ep;assert.equal(error.pending(),null);assert.equal(error.task().phase,'failed');
  // 保留切换先到实时: 激活入口、直接选择和自动跟随共用目标切换入口。
  const live=create();live.ctx.state.mode='3d';live.ctx.liveAvailable=()=>true;live.select('b');
  const lp=live.ctx.activateSelectedAppLater('phone','b','B');
  assert.equal(live.ctx.state.mode,'live');live.ctx.cancelSwitch();await lp;
  const selection=create();Object.assign(selection.ctx, {
    $:()=>({}),document:{body:{classList:{add(){},remove(){}}}},appInfo:{},
    rememberTarget(){},renderTargetLabel(){},renderSelectedAppName(){},watchApp(){},updateAppMeta(){},
  });
  vm.runInContext(section('function switchTargetInPlace(', 'function connectAppInPlace('),selection.ctx);
  selection.ctx.state.mode='3d';selection.ctx.liveAvailable=()=>true;selection.ctx.targets.pinned=true;
  selection.ctx.switchTargetInPlace('b',true,'B');assert.equal(selection.ctx.state.mode,'live');assert.equal(selection.ctx.targets.pinned,false);
  // 离线设备没有实时通道, 仍保留原来的 2D/3D 和本机日志入口。
  selection.ctx.liveAvailable=()=>false;selection.ctx.state.mode='3d';selection.ctx.switchTargetInPlace('c',true,'C');assert.equal(selection.ctx.state.mode,'3d');
  // 激活期间事件流重连不再走旧 reconnected 路径, 任务自己完成重启状态收尾。
  const restarted=create();let stopped=0,cleared=0;restarted.ctx.appState.instanceId='old';restarted.ctx.appState.dropped=true;
  restarted.ctx.setRunning=()=>stopped++;restarted.ctx.clearHierarchy=()=>cleared++;restarted.select('b');
  const rp=restarted.ctx.activateSelectedAppLater('phone','b','B');await restarted.fire(150);
  restarted.requests[0].resolve({ok:true,json:async()=>({})});await rp;
  assert.equal(restarted.ctx.appState.dropped,false);assert.equal(stopped,1);assert.equal(cleared,1);
  const failed=create();failed.ctx.activateApp=async()=>({failure:'Not installed.'});failed.select('b');
  const fp=failed.ctx.activateSelectedAppLater('phone','b','B');await failed.fire(150);await fp;
  assert(failed.notices[0].includes('显示的是保存在本机的日志和抓包'));
  // 固定的目标在后台时切 2D/3D, 只显示缓存, 不请求后台 App。
  for (const status of ['background', 'offline', 'restarting']) {
    const fixed=create();fixed.select('a');fixed.ctx.targets.pinned=true;fixed.ctx.appState.value=status;
    await fixed.ctx.setMode('3d');
    assert.equal(fixed.ctx.state.mode,'3d');assert.equal(fixed.requests.length,0);assert.equal(fixed.task().phase,'ready');
  }
  // 即使后台通知发生在请求发出以后, 迟到层级也不能替换缓存。
  const background=create();background.ctx.state.mode='2d';background.select('a');
  const before=background.ctx.refresh();background.ctx.appState.value='background';
  background.requests[0].resolve({ok:true,json:async()=>['stale']});await before;
  assert.deepEqual(background.applied,[]);assert.equal(background.task().phase,'ready');
  const aborting=create();aborting.ctx.state.mode='3d';aborting.select('a');
  vm.runInContext(section('function setAppState(value, message, link)', '  // 连上过') + '}', aborting.ctx);
  const inFlight=aborting.ctx.refresh();aborting.ctx.setAppState('background');await inFlight;
  assert(aborting.requests[0].options.signal.aborted);assert.equal(aborting.task().phase,'ready');assert.deepEqual(aborting.notices,[]);
  // 激活后库存已明确在后台, 不把它覆盖成 online 并错误读取层级。
  const switchedAway=create();switchedAway.ctx.state.mode='3d';switchedAway.select('b');
  switchedAway.ctx.currentApp=()=>({foreground:false});
  const task=switchedAway.ctx.activateSelectedAppLater('phone','b','B');await switchedAway.fire(150);
  switchedAway.requests[0].resolve({ok:true,json:async()=>({})});await task;
  assert.equal(switchedAway.ctx.appState.value,'background');assert.equal(switchedAway.requests.length,1);assert.equal(switchedAway.pending(),null);
  // 网页激活超时必须同时取消 Mac 排队, 不能仅结束界面 Loading。
  const timed=create();Object.assign(timed.ctx,{ACTIVATE_TIMEOUT_MS:30000,LAUNCH_FAILURES:{timeout:'timeout'}});
  vm.runInContext(section('async function activateApp(', '// 每次选择拥有独立任务;'),timed.ctx);
  const timedJob=timed.select('b'), timedPromise=timed.ctx.activateSelectedAppLater('phone','b','B');
  await timed.fire(150);await timed.fire(30000);await timedPromise;
  assert.equal(timedJob.phase,'failed');assert.equal(timed.pending(),null);assert.equal(timed.cancellations[0].task,timedJob.id);

  // 重连在途时新建同一目标任务, source 未改变也不能让旧回调跳实时/清空新层级。
  const reconnect=create(), reconnectReply=deferred();reconnect.select('a');reconnect.ctx.state.mode='3d';
  reconnect.ctx.loadTargets=()=>reconnectReply.promise;reconnect.ctx.liveAvailable=()=>true;
  vm.runInContext(section('async function reconnected()', 'function setAppState('),reconnect.ctx);
  const reconnecting=reconnect.ctx.reconnected();reconnect.select('a');reconnectReply.resolve();await reconnecting;
  assert.equal(reconnect.ctx.state.mode,'3d');
  // 无实时通道的延迟 reload 只能作用于原来的目标和任务。
  for (const changed of [false,true]) {
    const delayed=create();delayed.select('a');delayed.ctx.state.mode='3d';let reloads=0;
    delayed.ctx.loadTargets=async()=>{};delayed.ctx.location={reload:()=>reloads++};
    vm.runInContext(section('async function reconnected()', 'function setAppState('),delayed.ctx);
    await delayed.ctx.reconnected();if(changed)delayed.select('c');await delayed.fire(3000);
    assert.equal(reloads,changed?0:1);
  }
  // 共享设备快照卡住时释放合并请求, 后续请求可以恢复。
  const list=create();list.ctx.ensureTargetStateSocket=()=>{};list.ctx.syncSelectedTargetState=()=>{};
  vm.runInContext(section('let targetLoad = null;', '// 模拟器启动 / 关闭:'),list.ctx);
  const inventoryTimeout=list.ctx.loadTargets().catch(error=>error);await list.fire(5000);
  assert.equal((await inventoryTimeout).name,'AbortError');
  const recovered=list.ctx.loadTargets();list.requests.at(-1).resolve({ok:true,json:async()=>({})});await recovered;
  // 同一个元素从属性切到类信息, 旧属性/旧类请求也不能覆盖当前详情。
  const detail=create();detail.select('a');const node={key:'one',oid:1,cls:'UIView'};
  Object.assign(detail.ctx.state,{nodes:new Map([['one',node]]),selected:'one',tab:'attr',classTarget:null});
  let detailRenders=0,classRenders=0;
  Object.assign(detail.ctx,{targetBase:()=>'/t/phone/a',el:()=>({}),$:()=>({replaceChildren(){}}),renderDetail:()=>detailRenders++,renderClassInfo:()=>classRenders++});
  vm.runInContext(section('async function loadDetail()', 'function renderDetail(')+section('async function loadClassInfo(', 'function renderClassInfo('),detail.ctx);
  const attributes=detail.ctx.loadDetail();detail.ctx.state.tab='class';const classes=detail.ctx.loadClassInfo(node);
  detail.requests[0].resolve({ok:true,json:async()=>({})});await attributes;assert.equal(detailRenders,1);
  detail.ctx.state.classTarget={oid:2,name:'Other'};detail.requests[1].resolve({ok:true,json:async()=>({})});await classes;assert.equal(classRenders,0);
  // 原生 ready=false 的迟到响应不能把已连接且明确前台的 App 改成后台。
  const foreground=create();foreground.ctx.currentApp=()=>({foreground:true,stateConnected:true});
  foreground.ctx.activateApp=async()=>({hint:'not ready'});foreground.select('b');
  const fg=foreground.ctx.activateSelectedAppLater('phone','b','B');await foreground.fire(150);
  if(foreground.requests.length)foreground.requests[0].resolve({ok:true,json:async()=>({})});await fg;
  assert.equal(foreground.ctx.appState.value,'online');assert.equal(foreground.task().phase,'done');
  // 命令失败与 App 实际状态独立: 已确认前台时仍可查看数据, 但保留命令错误。
  const failedForeground=create();failedForeground.ctx.currentApp=()=>({foreground:true,stateConnected:true});
  failedForeground.ctx.activateApp=async()=>({failure:'command failed'});failedForeground.select('b');
  const ff=failedForeground.ctx.activateSelectedAppLater('phone','b','B');await failedForeground.fire(150);await ff;
  assert.equal(failedForeground.ctx.appState.value,'online');assert.equal(failedForeground.task().phase,'failed');
  // 没有前后台证据时, ready=false 只表示未响应, 不能推断成后台。
  const unknown=create();unknown.ctx.activateApp=async()=>({hint:'not ready'});unknown.select('b');
  const up=unknown.ctx.activateSelectedAppLater('phone','b','B');await unknown.fire(150);await up;
  assert.equal(unknown.ctx.appState.value,'offline');assert.equal(unknown.pending(),null);
  // 激活响应之后 App 又退出, 状态墓碑不能被成功响应覆盖。
  const removed=create();removed.ctx.state.mode='3d';removed.select('b');removed.ctx.appState.dropped=true;
  Object.assign(removed.ctx,{targetStateKey:(d,b)=>d+'|'+b,currentApp:()=>null});
  Object.assign(removed.ctx.targetStateHub,{ready:true,states:new Map([['phone|b',{removed:true}]])});
  const rem=removed.ctx.activateSelectedAppLater('phone','b','B');await removed.fire(150);
  removed.requests[0].resolve({ok:true,json:async()=>({})});await rem;
  assert.equal(removed.ctx.appState.value,'offline');assert.equal(removed.ctx.appState.dropped,true);assert.equal(removed.requests.length,1);
  // 连接仍在时, 新的明确前台通知可以恢复由旧激活错误造成的 offline 状态。
  const recoveredState=create();recoveredState.select('a');recoveredState.ctx.appState.value='offline';
  vm.runInContext(section('function receiveTargetForeground(', 'function mergeTargetStates()'),recoveredState.ctx);
  recoveredState.ctx.receiveTargetForeground('phone','a',true);assert.equal(recoveredState.ctx.appState.value,'online');
  // 再点已选中且在线的 App 只是关闭菜单, 不能取消详情/截图等正常加载。
  const same=create();const sameJob=same.select('a');
  const app={bundleId:'a',foreground:true,stateConnected:true};same.ctx.targets.devices=[{id:'phone',apps:[app]}];same.ctx.appState.connected=true;
  const elements=[];
  Object.assign(same.ctx,{hidePopovers(){},targetAppName:()=> 'A',appCompatible:()=>true,
    el:()=>{const item={events:{},classList:{toggle(){}},append(){},addEventListener:(event,handler)=>item.events[event]=handler};elements.push(item);return item;},
  });
  vm.runInContext(section('function targetAppRow(', '// 未启动的模拟器:'),same.ctx);
  const row=same.ctx.targetAppRow('phone',app,false);
  const detailRequest=same.ctx.taskRequest(sameJob,'/t/phone/a/api/detail').catch(e=>e);
  await row.events.click();assert.equal(same.task(),sameJob);assert.equal(same.requests[0].options.signal.aborted,false);
  same.requests[0].resolve({ok:true,json:async()=>({value:'loaded'})});assert.equal((await detailRequest).value,'loaded');
  // 但当前 App 确实在后台时, 再点它仍应创建新的激活任务。
  const bringForward=same.ctx.targetAppRow('phone',app,true);await bringForward.events.click();
  assert.notEqual(same.task(),sameJob);assert.equal(same.task().phase,'queued');assert.equal(sameJob.controller.signal.aborted,true);
  const pendingRetry=same.task().promise;same.ctx.cancelSwitch();await pendingRetry;
  console.log('PASS target tasks: latest-only activation, queued/in-flight cancellation, immediate modes, serial hierarchy, timeout/retry and unconditional cleanup');
})().catch(e=>{console.error(e);process.exitCode=1;});
