// Run: node Mac/Tests/LiveVideoDecoderTests.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../Web/app.js'), 'utf8');
const start = source.indexOf('// Both sources:');
const end = source.indexOf('// 解码出一帧立即绘制', start);
assert(start >= 0 && end > start);
const sent = [], painted = [], errors = [];
class Decoder {
  constructor(options) { this.options = options; this.state = 'unconfigured'; this.decodeQueueSize = 0; this.chunks = []; }
  configure(config) { this.config = config; this.state = 'configured'; }
  close() { assert.notEqual(this.state, 'closed'); this.state = 'closed'; }
  decode(chunk) { assert.equal(this.state, 'configured'); this.chunks.push(chunk); this.options.output({close() {}}); }
}
const live = {ws: {}, hasFrame: false};
const context = vm.createContext({
  live, VideoDecoder: Decoder, EncodedVideoChunk: class {constructor(value) {Object.assign(this, value);}},
  performance: {now: () => 1000}, clearTimeout() {}, Uint8Array,
  pageActivity: {active: true}, state: {mode: 'live'}, console: {warn() {}},
  liveSend: item => sent.push(item), paintLive: frame => painted.push(frame),
  showLiveGuide: message => errors.push(message), $: () => ({hidden: false}),
});
vm.runInContext(source.slice(start, end), context);
const feed = packet => context.feedLiveFrame(Uint8Array.from(packet));
feed([1,1,100,0,40]);
feed([3,0x41]);
assert.equal(painted.length, 0, 'Must wait for first keyframe');
feed([2,0x65]); feed([3,0x41]);
assert.equal(painted.length, 2);
const staleDecoder = live.decoder;
live.decoder.decodeQueueSize = 2;
feed([3,0x41]);
assert.equal(painted.length, 2, 'Skip deltas when decoder falls behind');
assert.equal(staleDecoder.state, 'configured', 'Do not starve a slow decoder before a fresh keyframe arrives');
assert.equal(sent.at(-1).type, 'keyframe');
feed([3,0x41]);
assert.equal(painted.length, 2, 'Do not decode deltas after dropping a reference');
feed([2,0x65]);
assert.equal(staleDecoder.state, 'closed', 'Fresh keyframe must cancel stale queued work');
assert.equal(live.decoder.decodeQueueSize, 0, 'New decoder must start without backlog');
assert.equal(painted.length, 3, 'Recover on a fresh keyframe');
let staleClosed = false;
staleDecoder.options.output({close() {staleClosed = true;}});
assert.equal(staleClosed, true, 'Release late output from old decoder');
assert.equal(painted.length, 3, 'Never paint stale decoder output');
live.decoder.state = 'closed';
feed([1,1,100,0,41]);
assert.equal(errors.length, 0, 'Reconfiguration must tolerate an already closed decoder');
assert.equal(live.waitingKeyFrame, true);
live.decoder.options.error(new Error('test decoder failure'));
assert.equal(live.decoder, null);
feed([2,0x65]);
assert.equal(painted.length, 4, 'Recreate failed decoder from cached avcC at next keyframe');
assert.equal(errors.length, 0);
console.log('PASS shared web decoder: initial keyframe, backlog, recovery, reconfiguration and decoder failure');
