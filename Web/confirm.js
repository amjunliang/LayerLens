'use strict';

// 确认气泡: 锚定在触发位置旁, 说明影响并列出涉及的文件, 不自动消失.
// 回车确认, Esc 或点击外部取消; Mac App 的 WebView 不支持 confirm()
const CONFIRM_MAX_ITEMS = 5;
let confirmBubble = null;

// anchor 为元素或 DOMRect; danger 时确认按钮标红, 否则用强调色(可撤回的操作)
function showConfirm(anchor, { title, detail = '', items = [], action = t('确认'), danger = true, onConfirm }) {
  hideConfirm();
  const rect = anchor instanceof Element ? anchor.getBoundingClientRect() : anchor;
  const bubble = el('div', 'confirm-bubble');
  bubble.setAttribute('role', 'alertdialog');
  bubble.append(el('div', 'confirm-title', title));
  if (detail) bubble.append(el('div', 'confirm-detail', detail));
  if (items.length) {
    const list = el('div', 'confirm-items');
    items.slice(0, CONFIRM_MAX_ITEMS).forEach((item) => {
      const row = el('div', 'confirm-item', item);
      row.title = item;
      list.append(row);
    });
    if (items.length > CONFIRM_MAX_ITEMS) list.append(el('div', 'confirm-more', t('等 {0} 个', items.length)));
    bubble.append(list);
  }
  const cancel = el('button', 'confirm-cancel', t('取消'));
  const ok = el('button', 'confirm-ok' + (danger ? ' danger' : ''), action);
  const buttons = el('div', 'confirm-buttons');
  buttons.append(cancel, ok);
  bubble.append(buttons);
  cancel.addEventListener('click', hideConfirm);
  ok.addEventListener('click', () => {
    hideConfirm();
    onConfirm();
  });
  // 捕获阶段处理按键, 不触发全局快捷键和 Esc 关闭面板
  const onKey = (e) => {
    if (e.key !== 'Enter' && e.key !== 'Escape') return;
    e.preventDefault();
    e.stopImmediatePropagation();
    if (e.key === 'Enter') ok.click();
    else hideConfirm();
  };
  const onDown = (e) => {
    if (!bubble.contains(e.target)) hideConfirm();
  };
  window.addEventListener('keydown', onKey, true);
  window.addEventListener('mousedown', onDown, true);
  confirmBubble = { bubble, dispose: () => {
    window.removeEventListener('keydown', onKey, true);
    window.removeEventListener('mousedown', onDown, true);
  } };
  document.body.append(bubble);
  // 优先放在触发位置下方, 放不下时放到上方
  const size = bubble.getBoundingClientRect();
  const below = rect.bottom + 6;
  const top = below + size.height <= window.innerHeight - 8 ? below : rect.top - 6 - size.height;
  bubble.style.left = Math.max(8, Math.min(rect.right - size.width, window.innerWidth - size.width - 8)) + 'px';
  bubble.style.top = Math.max(8, top) + 'px';
  ok.focus();
}

function hideConfirm() {
  if (!confirmBubble) return;
  confirmBubble.dispose();
  confirmBubble.bubble.remove();
  confirmBubble = null;
}
