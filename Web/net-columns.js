'use strict';

// 网络列表的列: 拖动列头调整顺序, 拖动列头右边缘调整宽度, 右键列头恢复默认.
// 顺序用 flex 的 order 实现, 宽度存为 --net-w-<列> 变量, 列头和行共用, 行的 DOM 顺序不变
const NET_COLS_KEY = 'layerlens_net_cols';
const NET_ORDER_KEY = 'layerlens_net_order';
const NET_COLUMNS = ['start', 'method', 'status', 'host', 'path', 'kind', 'size', 'time'];

const netColumns = { widths: {}, order: NET_COLUMNS.slice() };

function loadNetColumns() {
  try {
    netColumns.widths = JSON.parse(localStorage.getItem(NET_COLS_KEY)) || {};
    const order = JSON.parse(localStorage.getItem(NET_ORDER_KEY));
    // 列有增减时补齐缺少的列, 去掉已不存在的列
    if (Array.isArray(order)) {
      netColumns.order = order.filter((name) => NET_COLUMNS.includes(name));
      NET_COLUMNS.forEach((name) => netColumns.order.includes(name) || netColumns.order.push(name));
    }
  } catch (e) {
    // ignore
  }
}

function saveNetColumns() {
  try {
    localStorage.setItem(NET_COLS_KEY, JSON.stringify(netColumns.widths));
    localStorage.setItem(NET_ORDER_KEY, JSON.stringify(netColumns.order));
  } catch (e) {
    // ignore
  }
}

function applyNetColumns() {
  const list = $('netList');
  NET_COLUMNS.forEach((name) => {
    const width = netColumns.widths[name];
    if (width) list.style.setProperty(`--net-w-${name}`, width + 'px');
    else list.style.removeProperty(`--net-w-${name}`);
    list.style.setProperty(`--net-o-${name}`, netColumns.order.indexOf(name));
  });
  // 最后一列占满剩余宽度
  list.dataset.last = netColumns.order[netColumns.order.length - 1];
}

// WebKit 中 ui-monospace 的 ch 比实际字宽略小, 按 ch 设的列宽会截断; 量出实际字宽作为 --ch
function measureNetChar(list) {
  const probe = el('span', 'net-row', 'octet-stream:0123456789.');
  probe.style.cssText = 'position: absolute; visibility: hidden; display: inline; min-width: 0; padding: 0; height: auto;';
  list.appendChild(probe);
  const width = probe.getBoundingClientRect().width / probe.textContent.length;
  probe.remove();
  if (width) {
    list.style.setProperty('--ch', width + 'px');
    net.charMeasured = true;
  }
}

function setupNetColumns() {
  loadNetColumns();
  applyNetColumns();
  const head = $('netList').querySelector('.net-cols');
  head.querySelectorAll(':scope > span').forEach((cell) => {
    const name = cell.className.replace('net-', '');
    cell.dataset.col = name;
    const handle = el('span', 'net-col-resize');
    handle.addEventListener('pointerdown', (e) => startNetColumnResize(e, cell, handle, name));
    // 双击恢复默认宽度
    handle.addEventListener('dblclick', () => {
      delete netColumns.widths[name];
      applyNetColumns();
      saveNetColumns();
    });
    cell.appendChild(handle);
    cell.addEventListener('pointerdown', (e) => startNetColumnMove(e, head, cell, name));
  });
  head.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    const reset = (patch) => {
      Object.assign(netColumns, patch);
      applyNetColumns();
      saveNetColumns();
    };
    showNetMenu(e.clientX, e.clientY, [
      ['恢复默认顺序', () => reset({ order: NET_COLUMNS.slice() })],
      ['恢复默认宽度', () => reset({ widths: {} })],
    ]);
  });
}

function startNetColumnResize(e, cell, handle, name) {
  if (e.button !== 0) return;
  e.preventDefault();
  e.stopPropagation();
  window.getSelection().removeAllRanges();
  window.addEventListener('selectstart', blockNetSelect, true);
  handle.setPointerCapture(e.pointerId);
  const startX = e.clientX;
  const start = cell.getBoundingClientRect().width;
  document.body.classList.add('col-resizing');
  const move = (ev) => {
    netColumns.widths[name] = Math.round(Math.max(32, start + ev.clientX - startX));
    $('netList').style.setProperty(`--net-w-${name}`, netColumns.widths[name] + 'px');
  };
  const up = () => {
    handle.removeEventListener('pointermove', move);
    window.removeEventListener('selectstart', blockNetSelect, true);
    document.body.classList.remove('col-resizing');
    saveNetColumns();
  };
  handle.addEventListener('pointermove', move);
  handle.addEventListener('pointerup', up, { once: true });
  handle.addEventListener('pointercancel', up, { once: true });
}

function blockNetSelect(e) {
  e.preventDefault();
}

// 按下后移动超过 4px 才开始拖动; 竖线标出放下的位置, Esc 取消
function startNetColumnMove(e, head, cell, name) {
  if (e.button !== 0) return;
  // 拖动过程中不选中文字
  e.preventDefault();
  window.getSelection().removeAllRanges();
  window.addEventListener('selectstart', blockNetSelect, true);
  const startX = e.clientX;
  let dragging = false;
  let target = -1;
  let marker = null;
  // 按显示顺序排列的列头
  const cells = () => [...head.querySelectorAll(':scope > span')].sort((a, b) => a.getBoundingClientRect().left - b.getBoundingClientRect().left);
  const move = (ev) => {
    if (!dragging) {
      if (Math.abs(ev.clientX - startX) < 4) return;
      dragging = true;
      cell.classList.add('moving');
      document.body.classList.add('col-moving');
      marker = el('div', 'net-col-drop');
      head.appendChild(marker);
    }
    const list = cells();
    target = list.findIndex((item) => {
      const rect = item.getBoundingClientRect();
      return ev.clientX < rect.left + rect.width / 2;
    });
    if (target < 0) target = list.length;
    const headRect = head.getBoundingClientRect();
    const edge = target < list.length ? list[target].getBoundingClientRect().left : list[list.length - 1].getBoundingClientRect().right;
    marker.style.left = edge - headRect.left - 1 + 'px';
  };
  const finish = (apply) => {
    window.removeEventListener('pointermove', move);
    window.removeEventListener('pointerup', up);
    window.removeEventListener('pointercancel', cancel);
    window.removeEventListener('keydown', key, true);
    window.removeEventListener('selectstart', blockNetSelect, true);
    if (!dragging) return;
    cell.classList.remove('moving');
    document.body.classList.remove('col-moving');
    marker.remove();
    if (!apply || target < 0) return;
    const order = netColumns.order.filter((item) => item !== name);
    // target 是含被拖动列在内的位置, 去掉它之后位置要前移
    const from = netColumns.order.indexOf(name);
    order.splice(target > from ? target - 1 : target, 0, name);
    netColumns.order = order;
    applyNetColumns();
    saveNetColumns();
  };
  const up = () => finish(true);
  const cancel = () => finish(false);
  const key = (ev) => {
    if (ev.key !== 'Escape') return;
    ev.preventDefault();
    ev.stopPropagation();
    finish(false);
  };
  window.addEventListener('pointermove', move);
  window.addEventListener('pointerup', up);
  window.addEventListener('pointercancel', cancel);
  window.addEventListener('keydown', key, true);
}
