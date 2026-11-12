'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Web/app.js', 'utf8');
const nodes = new Map();
const node = id => { if (!nodes.has(id)) nodes.set(id, {hidden:true, dataset:{}, textContent:''}); return nodes.get(id); };
const timers = [];
const live = {connected:true, hasFrame:true, budgetPaused:false, captureStalled:false,
  healing:false, deadDrags:0, decodedFrames:3, touchCheckEpoch:0, frames:10, ws:{}, real:false};
const state = {mode:'live'};
const context = vm.createContext({live, state, $:node, t:value=>value,
  LIVE_HEAL_DRAG:40, LIVE_HEAL_WAIT_MS:600, LIVE_HEAL_STRIKES:2, LIVE_HEAL_PROBE_MS:4500,
  liveSend(message) { assert.equal(message.type, 'keyframe'); },
  setTimeout: fn => { timers.push(fn); }});
vm.runInContext(source.slice(source.indexOf('function invalidateLiveTouchChecks()'), source.indexOf('function liveStart()')), context);
vm.runInContext(source.slice(source.indexOf('function checkLiveDrag('), source.indexOf('// 重启模拟器的 backboardd')), context);
const drag = () => context.checkLiveDrag({distance:80, frames:live.frames, checkEpoch:live.touchCheckEpoch});
drag(); timers.shift()(); assert.equal(live.deadDrags, 1);
drag(); context.markLiveCaptureStalled();
assert.equal(live.deadDrags, 0, 'Stall clears previous touch failures');
timers.shift()(); assert.equal(live.deadDrags, 0, 'Pending checks must not survive a stall');
assert.equal(node('liveHeal').hidden, true, 'A stall hides the touch repair prompt');
drag(); assert.equal(timers.length, 0, 'No touch diagnosis while the picture is stalled');
context.markLiveCaptureReady();
drag(); timers.shift()(); assert.equal(live.deadDrags, 1);
drag(); timers.shift()();
assert.equal(node('liveHeal').hidden, true, 'The touch prompt waits for a fresh decoded frame');
live.decodedFrames++; timers.shift()();
assert.equal(node('liveHeal').hidden, false, 'A fresh frame and two failed drags can show touch repair');
context.markLiveCaptureStalled(); context.markLiveCaptureReady();
assert.equal(node('liveHeal').hidden, true);
assert.equal(live.deadDrags, 0, 'Recovery starts a fresh sequence');
drag(); timers.shift()(); drag(); timers.shift()();
context.markLiveCaptureStalled(); timers.shift()();
assert.equal(node('liveHeal').hidden, true, 'A stall during the keyframe probe suppresses touch repair');
context.markLiveCaptureReady();
drag(); live.budgetPaused = true; timers.shift()();
assert.equal(live.deadDrags, 0, 'Paused viewers must not diagnose touch');
live.budgetPaused = false; drag(); live.ws = {}; timers.shift()();
assert.equal(live.deadDrags, 0, 'Checks from an older socket must not leak into a new session');
console.log('PASS touch diagnosis: capture stall, pending checks, decoded recovery, budget and target isolation');
