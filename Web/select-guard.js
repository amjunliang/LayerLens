'use strict';

// 双击或三击按钮, 折叠箭头等不可选中的元素时, 浏览器会从点击处向周围扩展选区, 选中旁边的文字.
// 从按下的元素向上找第一个明确设置了 user-select 的元素, 为 none 时阻止多击的默认行为;
// 为 text 等(如不可选中区域里重新允许选中的内容)时不处理. 单击不受影响, 可以从这里开始拖选
document.addEventListener('mousedown', (e) => {
  if (e.detail < 2 || !(e.target instanceof Element)) return;
  for (let node = e.target; node && node !== document.body; node = node.parentElement) {
    const style = getComputedStyle(node);
    const value = style.webkitUserSelect || style.userSelect;
    if (value === 'none') e.preventDefault();
    if (value && value !== 'auto') return;
  }
}, true);
