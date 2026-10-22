'use strict';

// 从按下的元素向上找第一个明确设置了 user-select 的值, 都没有时返回 auto
function explicitUserSelect(target) {
  for (let node = target; node && node !== document.body; node = node.parentElement) {
    const style = getComputedStyle(node);
    const value = style.webkitUserSelect || style.userSelect;
    if (value && value !== 'auto') return value;
  }
  return 'auto';
}

// 在不可选中的元素(按钮, 折叠箭头, 3D 画布, 分隔条等)上按下时:
// 双击或三击时浏览器会从点击处向周围扩展选区, 选中旁边的文字, 阻止多击的默认行为;
// 按住拖动时选区会扩展到经过的文字(如拖动旋转画布时选中下方网络列表), 松开前禁止开始选区.
// 不可选中区域里重新允许选中的内容(user-select: text)和输入框不处理, 可以从这里开始拖选
document.addEventListener('mousedown', (e) => {
  if (e.button !== 0 || !(e.target instanceof Element)) return;
  if (e.target.closest('input, textarea, [contenteditable]')) return;
  if (explicitUserSelect(e.target) !== 'none') return;
  if (e.detail >= 2) e.preventDefault();
  const block = (ev) => ev.preventDefault();
  const release = () => {
    document.removeEventListener('selectstart', block, true);
    window.removeEventListener('mouseup', release, true);
    window.removeEventListener('blur', release);
  };
  document.addEventListener('selectstart', block, true);
  window.addEventListener('mouseup', release, true);
  window.addEventListener('blur', release);
}, true);
