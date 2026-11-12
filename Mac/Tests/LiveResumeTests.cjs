'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'Web/app.js'), 'utf8');
const sent = [], guide = { hidden: false };
const c = { live: { real: true, suspended: false, ws: { readyState: 1 }, hasFrame: true },
  pageActivity: { active: true }, state: { mode: 'live' }, WebSocket: { OPEN: 1 },
  layoutLive() {}, paintLive() {}, showLiveGuide() {}, clearTimeout() {}, $: () => guide,
  pageHasFocus: () => false,
  liveSend: message => sent.push(message.type) };
vm.createContext(c);
vm.runInContext(source.slice(source.indexOf('function liveSuspend('), source.indexOf('function liveStop()')), c);
c.liveResume(); c.liveResume(); assert.deepEqual(sent, [], 'Normal layout updates never wake');
c.liveSuspend(); c.liveResume(); assert.deepEqual(sent, ['release'], 'App-follow input release must not undo manual lock'); sent.length = 0;
c.liveSuspend(true); assert(c.live.suspended);
c.pageActivity.active = false; c.liveResume();
assert.deepEqual(sent, ['release', 'resume'], 'Video resume does not depend on page focus');
c.state.mode = '2d'; c.liveSuspend(true); c.liveResume(); assert(c.live.suspended);
c.state.mode = 'live'; c.liveResume(); c.liveResume();
assert.deepEqual(sent, ['release', 'resume', 'release', 'resume'], 'Live mode transition resumes once');
c.live.real = false; c.liveSuspend(true); c.liveResume();
assert.deepEqual(sent, ['release', 'resume', 'release', 'resume', 'release'], 'Simulator does not receive device wake commands');
c.live.real = true; c.live.ws.readyState = 0; c.liveSuspend(true); c.liveResume();
assert(c.live.suspended, 'A connecting socket does not consume a resume transition');
c.live.ws.readyState = 1; c.liveResume(); assert.equal(sent.at(-1), 'resume');
console.log('PASS live resume transitions: focus independence, mode guards, coalescing, connecting sockets and simulator isolation');

// A page reload can finish while focus is on the host window's reload button.
// The live socket must start immediately instead of waiting for a canvas click.
const started = [];
const startLive = {
  udid: 'sim', real: false, ws: null, error: '', frames: 0, retryTimer: 0, startTimer: 0,
};
const startContext = vm.createContext({
  live: startLive,
  pageActivity: { active: false },
  state: { mode: 'live' },
  targets: { hub: { live: true } },
  location: { host: '127.0.0.1:9523' },
  WebSocket: class {
    static OPEN = 1;
    constructor(url) { this.url = url; this.readyState = 0; started.push(url); }
  },
  VideoDecoder: class {},
  clearTimeout() {}, startLiveDeadline() {},
  liveAvailable: () => true,
  liveSupported: () => true,
  layoutLive() {},
  showLiveGuide() {},
  liveSend() {},
});
vm.runInContext(source.slice(source.indexOf('function liveStart()'), source.indexOf('// 原生视频输出状态')), startContext);
startContext.liveStart();
assert.match(started[0], /\/sim\/sim\/stream$/, 'Live starts while the host window button owns focus');
assert.doesNotMatch(source, /async function syncLive\(\) \{\s*if \(!pageActivity\.active\) return;/, 'Target sync must not defer live setup on focus');
console.log('PASS live startup: page reload does not wait for a canvas click');

// Run the actual native wake method against deterministic device/HID boundaries.
const native = fs.readFileSync(path.join(root, 'Mac/DeviceBridge/Sources/native_bridge.m'), 'utf8');
const start = native.indexOf('- (BOOL)wakeDisplayIfNeeded:(NSString **)error {');
const end = native.indexOf('- (void)handle:', start);
assert(start >= 0 && end > start);
const build = '/private/tmp/LayerLens-release-build';
fs.mkdirSync(build, { recursive: true });
const dir = fs.mkdtempSync(path.join(build, 'live-resume-tests.'));
try {
  const harness = `
#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include <stdbool.h>
static NSArray *probes;
static NSUInteger cursor;
static NSMutableArray *pulses;
static uint64_t now;
static int hidError;
static _Atomic bool *cancelOnRead;
static uint64_t ipb_bounded_now_ns(void){ now+=NSEC_PER_SEC;return now; }
static int noSleep(unsigned value){return 0;}
#define usleep noSleep
static NSDictionary *ipbDeviceControl(NSString *device,NSArray *args,NSString **error){
 if(cancelOnRead)atomic_store(cancelOnRead,true);
 id value=probes[MIN(cursor++,probes.count-1)];
 if(value==NSNull.null){*error=@"probe failed";return nil;}return value;
}
static int coredevice_send_hid_button_custom(void *remote,uint64_t page,uint64_t usage,uint8_t state){
 NSCAssert(page==12 && usage==48,@"Only sleep/wake may be synthesized");[pulses addObject:@(state)];return hidError;
}
static int coredevice_send_hid_button_barrier(void *remote){[pulses addObject:@2];return hidError;}
@interface LLNativeSession:NSObject {
@public
 _Atomic bool stopped;
 void *buttons;
 NSArray *_arguments;
}
- (BOOL)wakeDisplayIfNeeded:(NSString**)error;
- (int)send:(int (^)(void))work;
- (void)emit:(uint8_t)kind data:(NSData*)data;
@end
@implementation LLNativeSession
- (instancetype)init{if((self=[super init])){buttons=(void*)1;_arguments=@[@"device"];}return self;}
- (int)send:(int (^)(void))work{return work();}
- (void)emit:(uint8_t)kind data:(NSData*)data{}
${native.slice(start, end)}
@end
static void reset(NSArray *values){probes=values;cursor=0;now=0;hidError=0;cancelOnRead=NULL;pulses=[NSMutableArray array];}
int main(void){@autoreleasepool{
 LLNativeSession *s=[LLNativeSession new];NSString *error=nil;
 reset(@[@{@"backlightState":@"activeOn"}]);NSCAssert([s wakeDisplayIfNeeded:&error] && pulses.count==0,@"Bright lock screen is never toggled");
 reset(@[@{}]);NSCAssert([s wakeDisplayIfNeeded:&error] && pulses.count==0,@"Unknown backlight is never toggled");
 reset(@[@{@"backlightState":@"off"},@{@"backlightState":@"off"},@{@"backlightState":@"activeOn"}]);
 NSCAssert([s wakeDisplayIfNeeded:&error],@"Sleeping device wakes");NSCAssert(([pulses isEqual:@[@0,@1,@2]]),@"Exactly one complete pulse and barrier");
 reset(@[@{@"backlightState":@"off"}]);error=nil;NSCAssert(![s wakeDisplayIfNeeded:&error] && error!=nil,@"Wake polling is bounded");
 NSCAssert(([pulses isEqual:@[@0,@1,@2]]),@"No repeated toggle during polling");
 reset(@[NSNull.null]);error=nil;NSCAssert(![s wakeDisplayIfNeeded:&error] && pulses.count==0,@"Failed query never toggles");
 reset(@[@{@"backlightState":@"off"}]);cancelOnRead=&s->stopped;NSCAssert(![s wakeDisplayIfNeeded:&error] && pulses.count==0,@"Cancellation prevents late input");
 atomic_store(&s->stopped,false);reset(@[@{@"backlightState":@"off"}]);hidError=9;
 NSCAssert(![s wakeDisplayIfNeeded:&error] && pulses.count==1,@"HID failure stops wake sequence");
 puts("PASS native wake: asleep-only toggle, bright/unknown safety, bounded polling, cancellation and HID failure");
}}
`;
  const file = path.join(dir, 'main.m'), binary = path.join(dir, 'live-resume');
  fs.writeFileSync(file, harness);
  execFileSync('/usr/bin/xcrun', ['clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation', file, '-o', binary], { stdio: 'pipe' });
  process.stdout.write(execFileSync(binary));
} finally { fs.rmSync(dir, { recursive: true, force: true }); }
