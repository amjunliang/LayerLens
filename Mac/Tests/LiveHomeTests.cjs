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
console.log('PASS Home forwards each click immediately without SpringBoard HTTP');
