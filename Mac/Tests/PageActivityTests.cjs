'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Web/app.js', 'utf8');
const start = source.indexOf('const FOCUS_REFRESH_MIN_MS');
const end = source.indexOf('// MARK: - Network', start);
assert(start >= 0 && end > start);

let refreshes = 0;
const context = vm.createContext({
  Date,
  document: { visibilityState: 'visible', hasFocus: () => true },
  window: { LAYERLENS_WINDOW_FOCUSED: true },
  state: { mode: '2d' },
  targets: { bundleId: 'app' },
  loadTargets: async () => {},
  renderTargetMenu: () => {},
  reconcileTargets: async () => {},
  refresh: () => refreshes++,
  liveRequestFocus: () => {},
  resetImages: () => {},
  liveSuspend: () => {},
  cancelAnimationFrame: () => {},
  stage3D: { frame: 0 },
  refreshSeq: 0,
});
vm.runInContext(source.slice(start, end), context);
const pageActivity = vm.runInContext('pageActivity', context);

async function returnAfter(elapsed) {
  pageActivity.active = true;
  pageActivity.pending = true;
  pageActivity.inactiveAt = Date.now() - elapsed;
  await context.resumePageActivity();
}

(async () => {
  await returnAfter(9 * 60_000 + 59_000);
  assert.equal(refreshes, 0, 'Focus switches under ten minutes must reuse the cached 2D/3D hierarchy');
  assert.equal(pageActivity.pending, false);

  await returnAfter(10 * 60_000);
  assert.equal(refreshes, 1, 'Returning after ten minutes must refresh the hierarchy once');

  context.state.mode = 'live';
  await returnAfter(20 * 60_000);
  assert.equal(refreshes, 1, 'Live mode never triggers a 2D hierarchy refresh');
  console.log('PASS focus refresh threshold: cache under ten minutes, refresh at ten minutes, live isolation');
})().catch(error => { console.error(error); process.exitCode = 1; });
