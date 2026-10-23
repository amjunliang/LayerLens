'use strict';

// 实时画面按显示尺寸编码: 把画布在屏幕上的实际像素尺寸告诉 LayerLens, 由它缩小后再编码,
// 编码、传输、解码的数据量随之减少; 放大查看时尺寸变大, 清晰度随之提高(最高为原始分辨率).
// 缩放停下后才上报, 变化不到 5% 时不上报, 避免频繁重建编码器
const LIVE_SIZE_DELAY_MS = 150;
const LIVE_SIZE_THRESHOLD = 0.05;
const liveSize = { timer: 0, sent: null };

// 连接建立时立即上报, 其他情况等缩放停下
function liveReportSize(immediate) {
  clearTimeout(liveSize.timer);
  if (immediate) liveSize.sent = null;
  liveSize.timer = setTimeout(() => {
    const canvas = $('liveCanvas');
    const ratio = window.devicePixelRatio || 1;
    const width = Math.round(canvas.offsetWidth * ratio);
    const height = Math.round(canvas.offsetHeight * ratio);
    if (!width || !height) return;
    const sent = liveSize.sent;
    if (sent && Math.abs(width - sent.width) / sent.width < LIVE_SIZE_THRESHOLD) return;
    liveSize.sent = { width, height };
    liveSend({ type: 'size', width, height });
  }, immediate ? 0 : LIVE_SIZE_DELAY_MS);
}
