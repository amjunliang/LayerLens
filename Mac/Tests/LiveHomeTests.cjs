const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname, '../../Web/app.js'), 'utf8');
const start = source.indexOf('function liveHome()');
const end = source.indexOf('// MARK: - Targets', start);
const sent = [];
const context = { liveSend: message => sent.push(JSON.parse(JSON.stringify(message))) };
vm.createContext(context);
vm.runInContext(source.slice(start, end), context);
context.liveHome();
context.liveHome();
assert.deepEqual(sent, [
  { type: 'button', button: 'swipe-to-home' },
  { type: 'button', button: 'swipe-to-home' },
]);
assert(!source.includes('/api/hub/home'));
context.liveSleepWake();
assert.deepEqual(sent.at(-1), { type: 'button', button: 'sleep-wake' });
console.log('PASS Home and Sleep/Wake forward immediately without display queries');

const rotateStart=source.indexOf('function liveRotate()');
const button={disabled:false}, notices=[], timers=[];
let layouts=0;
const rotation={live:{real:true,orientation:1,udid:'phone',ws:{readyState:1}},LIVE_ROTATION:{1:0,2:180,3:-90,4:90},
  WebSocket:{OPEN:1}, Date, Math, $:()=>button, t:s=>s, toast:s=>notices.push(s),layoutLive(){layouts++;},
  setTimeout:fn=>{timers.push(fn);return timers.length;},clearTimeout(){},liveSend:m=>sent.push(JSON.parse(JSON.stringify(m)))};
vm.createContext(rotation);
vm.runInContext(source.match(/const LIVE_ROTATE_RIGHT = .*;/)[0] + '\n' + source.slice(rotateStart,source.indexOf('// 画面黑屏',rotateStart)),rotation);
const before=sent.length;
rotation.liveRotate();const request=sent.at(-1);
assert.equal(request.type,'rotate');assert.equal(request.direction,'right');assert(request.requestId);
assert(button.disabled);assert.equal(rotation.live.orientation,1,'Wait for actual device orientation');
rotation.liveRotate();assert.equal(sent.length,before+1,'Do not accumulate rotations while one is pending');
rotation.liveRotationResult({requestId:'other-window',ok:false});assert(button.disabled);
rotation.liveRotationResult({requestId:request.requestId,ok:true,orientation:3});
assert.equal(rotation.live.orientation,3);assert.equal(layouts,1);assert(!button.disabled);assert.equal(notices.length,0);
rotation.liveRotate();rotation.liveRotationResult({requestId:sent.at(-1).requestId,ok:false,detail:'unsupported'});
assert(!button.disabled);assert.equal(notices.length,1,'Unsupported control reports an input error, not a video failure');
rotation.liveRotate();const timedOut=sent.at(-1).requestId;timers.at(-1)();
assert(!button.disabled);assert.equal(rotation.live.rotatePending,null);assert.equal(notices.length,2);
rotation.liveRotationResult({requestId:timedOut,ok:false});assert.equal(notices.length,2,'Ignore late failure');
rotation.live.real=false;rotation.live.orientation=1;rotation.liveRotate();
assert.equal(sent.at(-1).type,'orientation');assert.equal(sent.at(-1).value,4);
rotation.live.orientation=1;
for(const expected of [4,2,3,1]){rotation.liveRotate();assert.equal(sent.at(-1).value,expected);rotation.live.orientation=expected;}
rotation.live.real=true;rotation.live.ws=null;const count=sent.length;rotation.liveRotate();assert.equal(sent.length,count);
console.log('PASS real-device rotation requests, actual orientation, duplicate guard, window isolation, failure/timeout and Simulator compatibility');
