'use strict';

// 搜索和过滤框的内容保存在本机, 重启 LayerLens 或重新打开窗口后恢复. 恢复时触发输入事件, 由原有的处理逻辑应用;
// 独立日志窗口与主窗口共用同一份, 以最后一次输入为准
const INPUT_MEMORY_KEY = 'layerlens_inputs';
const INPUT_MEMORY_IDS = ['search', 'logFilter', 'netFilter'];

function loadInputMemory() {
  try {
    return JSON.parse(localStorage.getItem(INPUT_MEMORY_KEY)) || {};
  } catch (e) {
    return {};
  }
}

function saveInputMemory(id, value) {
  const saved = loadInputMemory();
  if (value) saved[id] = value;
  else delete saved[id];
  try {
    localStorage.setItem(INPUT_MEMORY_KEY, JSON.stringify(saved));
  } catch (e) {
    // 不可用时只在本次有效
  }
}

function setupInputMemory() {
  const saved = loadInputMemory();
  INPUT_MEMORY_IDS.forEach((id) => {
    const input = $(id);
    if (!input) return;
    const event = input.tagName === 'SELECT' ? 'change' : 'input';
    input.addEventListener(event, () => saveInputMemory(id, input.value));
    const value = saved[id];
    if (typeof value !== 'string' || !value || value === input.value) return;
    // 下拉框只恢复仍存在的选项
    if (input.tagName === 'SELECT' && ![...input.options].some((option) => option.value === value)) return;
    input.value = value;
    input.dispatchEvent(new Event(event));
  });
}
