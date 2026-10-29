'use strict';

// 网络面板的过滤条: 工具栏下方一行, 左边是固定的类型和状态, 右边是自定义过滤项.
// 同组内单击单选, ⌘ 单击多选, 再次单击取消; 不同组之间同时满足, 与搜索框也同时满足.
// 自定义过滤项所有 App 共用(可限定只在某个 App 显示), 条件语法与搜索框相同:
// | 分隔关键词, 以 \ 开头为正则, 另支持 host: path: method: status: header: body: 前缀, 如 host:a.com status:5xx
const NET_CHIPS_KEY = 'layerlens_net_chips';
const NET_CUSTOM_FILTERS_KEY = 'layerlens_net_filters';
const NET_QUERY_FIELDS = ['host', 'path', 'method', 'status', 'header', 'body'];
const NET_QUERY_PREFIX = /(^|\s)(host|path|method|status|header|body):(\S*)/gi;
// 前缀的说明和示例, 搜索框的说明卡片和编辑气泡共用
const NET_QUERY_HELP = {
  host: ['域名', 'host:api.example.com'],
  path: ['路径和参数', 'path:/api|/v2'],
  method: ['方法, 完全匹配', 'method:post'],
  status: ['状态码, 如 404 或 4xx', 'status:4xx'],
  header: ['请求头和响应头', 'header:token'],
  body: ['请求和响应内容', 'body:userId'],
};

// 第三项为 true 的不常用, 收在「更多」下拉中
const NET_TYPE_CHIPS = [
  ['json', 'JSON'],
  ['image', '图片'],
  ['html', 'HTML'],
  ['form', '表单', true],
  ['xml', 'XML', true],
  ['js', 'JS', true],
  ['css', 'CSS', true],
  ['graphql', 'GraphQL', true],
  ['other', '其他', true],
];
const NET_STATUS_CHIPS = [
  ['2xx', '2xx'],
  ['3xx', '3xx'],
  ['4xx', '4xx'],
  ['5xx', '5xx'],
  ['failed', '失败'],
];

// selected: 各组选中的项; search: 搜索框的条件; custom: 自定义过滤项; compiled: 自定义过滤项编译后的条件, 按 id 缓存
const netFilters = {
  bar: true,
  selected: { type: new Set(), status: new Set(), custom: new Set() },
  search: null,
  custom: [],
  compiled: new Map(),
  editor: null,
  // 打开的下拉
  chipMenu: null,
};

// MARK: Query

// 单个值的匹配: \ 开头为正则, 否则 | 分隔的关键词, 不区分大小写; exact 时关键词需完全相等
function netValueTest(value, exact) {
  if (value.startsWith('\\')) {
    try {
      const regex = new RegExp(value.slice(1), 'i');
      return { test: (text) => regex.test(text) };
    } catch (e) {
      return { invalid: true, test: () => false };
    }
  }
  const terms = [...new Set(value.split('|').map((s) => s.trim().toLowerCase()).filter(Boolean))];
  return { test: (text) => terms.some((term) => (exact ? text.toLowerCase() === term : text.toLowerCase().includes(term))) };
}

// 状态码: 4xx 按区间, 其他按前缀, 如 40 匹配 400-409
function netStatusTest(value) {
  if (value.startsWith('\\')) return netValueTest(value);
  const terms = value.split('|').map((s) => s.trim().toLowerCase()).filter(Boolean);
  return {
    test: (status) => {
      const code = String(status || '');
      return !!code && terms.some((term) => (/^\dxx$/.test(term) ? code[0] === term[0] && code.length === 3 : code.startsWith(term)));
    },
  };
}

function netUrlParts(record) {
  if (!record.urlParts) {
    try {
      const url = new URL(record.url);
      record.urlParts = { host: url.host, path: url.pathname + url.search };
    } catch (e) {
      record.urlParts = { host: '', path: record.url || '' };
    }
  }
  return record.urlParts;
}

// slot 区分条件来源(搜索框或某个自定义过滤项), 内容查找按 slot 复用, 设备据此取消同一来源的旧查找
function compileNetQuery(raw, slot) {
  raw = (raw || '').trim();
  const query = { raw, slot, conds: [], text: null, remote: [], invalid: false };
  if (!raw) return query;
  let rest = raw;
  if (!raw.startsWith('\\')) {
    rest = raw.replace(NET_QUERY_PREFIX, (match, space, field, value) => {
      if (value) query.conds.push(netQueryCond(query, field.toLowerCase(), value));
      return space;
    }).replace(/\s+/g, ' ').trim();
  }
  if (rest) {
    query.text = parseLogFilter(rest);
    if (query.text.invalid) query.invalid = true;
    else if (query.text.regex || query.text.terms.length) query.textRemote = netQueryRemote(query, 'body', rest);
    else query.text = null;
  }
  if (query.conds.some((cond) => cond.invalid)) query.invalid = true;
  return query;
}

function netQueryRemote(query, scope, q) {
  const key = `${query.slot}#${query.remote.length}`;
  query.remote.push({ key, scope, q });
  return key;
}

function netQueryCond(query, field, value) {
  if (field === 'header' || field === 'body') {
    // 内容和请求头由 Hub 查找, 正则在 Hub 端编译, 这里只检查语法
    const invalid = value.startsWith('\\') && !!netValueTest(value).invalid;
    const key = invalid ? '' : netQueryRemote(query, field, value);
    return { invalid, test: (record) => !!key && netRemoteHas(key, record.id) };
  }
  if (field === 'status') {
    const status = netStatusTest(value);
    return { invalid: status.invalid, test: (record) => status.test(record.status) };
  }
  const value_ = netValueTest(value, field === 'method');
  const pick = {
    host: (record) => netUrlParts(record).host,
    path: (record) => netUrlParts(record).path,
    method: (record) => record.method || '',
  }[field];
  return { invalid: value_.invalid, test: (record) => value_.test(pick(record)) };
}

function netQueryActive(query) {
  return !!query && !query.invalid && !!(query.conds.length || query.text);
}

function netQueryMatches(record, query) {
  for (const cond of query.conds) {
    if (!cond.test(record)) return false;
  }
  if (!query.text) return true;
  if (query.textRemote && netRemoteHas(query.textRemote, record.id)) return true;
  // 缓存过滤用的文本, 记录多时每次刷新不必重新拼接; 记录更新时清空
  record.filterText ??= `${record.method} ${record.url} ${record.status || ''}`;
  const { terms, regex } = query.text;
  if (regex) {
    regex.lastIndex = 0;
    return regex.test(record.filterText);
  }
  record.filterLower ??= record.filterText.toLowerCase();
  return terms.some((term) => record.filterLower.includes(term));
}

// MARK: Category

// 类型按响应的 Content-Type, 表单按请求的 Content-Type, 一个请求可同时属于多个类型(如表单请求返回 JSON)
function netTypeMatches(record, type) {
  const reqMime = (record.reqMime || '').toLowerCase();
  if (type === 'form') return /x-www-form-urlencoded|multipart\//.test(reqMime);
  if (type === 'graphql') return /\/graphql/i.test(netUrlParts(record).path) || reqMime.includes('graphql');
  if (record.state === 'pending') return false;
  const mime = (record.mime || '').toLowerCase();
  if (type === 'json') return mime.includes('json');
  if (type === 'xml') return mime.includes('xml') && !mime.includes('json');
  if (type === 'js') return /javascript|ecmascript/.test(mime);
  if (type === 'css') return mime.includes('text/css');
  if (type === 'image') return mime.startsWith('image/');
  if (type === 'html') return mime.includes('text/html');
  return !NET_TYPE_CHIPS.some(([key]) => key !== 'other' && netTypeMatches(record, key));
}

// 失败只指没有状态码的网络错误, 4xx 和 5xx 按状态码选择
function netStatusMatches(record, key) {
  if (key === 'failed') return record.state === 'failed' && !record.status;
  const status = Number(record.status) || 0;
  return !!status && String(status)[0] === key[0];
}

// MARK: Custom filters

function netCustomVisible() {
  return netFilters.custom.filter((item) => !item.app || item.app === targets.bundleId);
}

function netCustomQuery(item) {
  let compiled = netFilters.compiled.get(item.id);
  if (!compiled || compiled.raw !== (item.query || '').trim()) {
    compiled = compileNetQuery(item.query, 'c' + item.id);
    netFilters.compiled.set(item.id, compiled);
  }
  return compiled;
}

function saveNetCustomFilters() {
  try {
    localStorage.setItem(NET_CUSTOM_FILTERS_KEY, JSON.stringify(netFilters.custom.map(({ id, name, query, app }) => ({ id, name, query, app }))));
  } catch (e) {
    // 不可用时只在本次有效
  }
}

function saveNetChips() {
  const { selected } = netFilters;
  try {
    localStorage.setItem(NET_CHIPS_KEY, JSON.stringify({ bar: netFilters.bar, type: [...selected.type], status: [...selected.status], custom: [...selected.custom] }));
  } catch (e) {
    // 不可用时只在本次有效
  }
}

function loadNetFilterState() {
  try {
    const custom = JSON.parse(localStorage.getItem(NET_CUSTOM_FILTERS_KEY));
    if (Array.isArray(custom)) netFilters.custom = custom.filter((item) => item && item.id && typeof item.query === 'string');
  } catch (e) {
    // ignore
  }
  let saved = null;
  try {
    saved = JSON.parse(localStorage.getItem(NET_CHIPS_KEY));
  } catch (e) {
    // ignore
  }
  if (saved) {
    netFilters.bar = saved.bar !== false;
    const known = (list, chips) => (Array.isArray(list) ? list.filter((key) => chips.some(([chip]) => chip === key)) : []);
    // 以前的「文档」改为 HTML
    netFilters.selected.type = new Set(known((saved.type || []).map((key) => (key === 'doc' ? 'html' : key)), NET_TYPE_CHIPS));
    netFilters.selected.status = new Set(known(saved.status, NET_STATUS_CHIPS));
    netFilters.selected.custom = new Set((saved.custom || []).filter((id) => netFilters.custom.some((item) => item.id === id)));
    return;
  }
  // 以前的类型下拉框换成过滤条上对应的项
  const old = loadInputMemory().netType;
  if (old === 'failed') netFilters.selected.status = new Set(['4xx', '5xx', 'failed']);
  else if (old === 'doc') netFilters.selected.type = new Set(['html']);
  else if (NET_TYPE_CHIPS.some(([key]) => key === old)) netFilters.selected.type = new Set([old]);
  if (old) {
    saveInputMemory('netType', '');
    saveNetChips();
  }
}

// MARK: Matching

function netSelectedCustom() {
  return netCustomVisible().filter((item) => netFilters.selected.custom.has(item.id) && netQueryActive(netCustomQuery(item)));
}

function netFiltersActive() {
  const { type, status } = netFilters.selected;
  return !!(type.size || status.size || netSelectedCustom().length || netQueryActive(netFilters.search));
}

// only 只按这一项判断(悬停时统计数量), 否则按全部选中的条件
function netFiltersMatch(record, only) {
  if (only) return only(record);
  const { type, status } = netFilters.selected;
  if (type.size && ![...type].some((key) => netTypeMatches(record, key))) return false;
  if (status.size && ![...status].some((key) => netStatusMatches(record, key))) return false;
  const custom = netSelectedCustom();
  if (custom.length && !custom.some((item) => netQueryMatches(record, netCustomQuery(item)))) return false;
  if (netQueryActive(netFilters.search) && !netQueryMatches(record, netFilters.search)) return false;
  return true;
}

function setNetSearchQuery(raw) {
  netFilters.search = compileNetQuery(raw, 'q');
  $('netSearch').classList.toggle('invalid', netFilters.search.invalid);
  syncNetRemote();
  rebuildNetView();
}

// MARK: Remote search

// 内容和请求头的查找由 Hub 完成, 每个条件一份命中集合; 条件变化时全量查找, 之后只查找新结束的请求.
// key -> { scope, q, hits: Set | null(未取回), pending, timer, inflight, token }
const netRemote = new Map();

function netRemoteHas(key, id) {
  return !!netRemote.get(key)?.hits?.has(id);
}

// 需要查找的条件: 搜索框、显示的自定义过滤项(悬停统计也用)和正在编辑的条件
function netRemoteNeeded() {
  const needed = new Map();
  const add = (query) => {
    if (query && !query.invalid) query.remote.forEach((item) => needed.set(item.key, item));
  };
  add(netFilters.search);
  netCustomVisible().forEach((item) => add(netCustomQuery(item)));
  add(netFilters.editor?.query);
  return needed;
}

function syncNetRemote() {
  const needed = net.searchSupported && net.key ? netRemoteNeeded() : new Map();
  for (const [key, entry] of netRemote) {
    const item = needed.get(key);
    if (item && item.scope === entry.scope && item.q === entry.q) continue;
    clearTimeout(entry.timer);
    entry.token++;
    netRemote.delete(key);
  }
  for (const [key, item] of needed) {
    if (netRemote.has(key)) continue;
    const entry = { scope: item.scope, q: item.q, hits: null, pending: new Set(), timer: 0, inflight: false, token: 0 };
    netRemote.set(key, entry);
    scheduleNetRemote(key, entry, 0);
  }
}

// 记录换了会话或被清空后重新全量查找
function resetNetRemote() {
  for (const entry of netRemote.values()) {
    clearTimeout(entry.timer);
    entry.timer = 0;
    entry.token++;
    entry.hits = null;
    entry.pending.clear();
  }
}

function noteNetRemoteRecord(record, old) {
  if (!netRemote.size || !record.state || record.state === 'pending' || (old && old.state !== 'pending')) return;
  for (const entry of netRemote.values()) entry.pending.add(record.id);
}

// 有请求结束时查找它们, 请求频繁时每秒最多一次; 未取回的条件稍后全量查找
function flushNetRemote() {
  for (const [key, entry] of netRemote) {
    if (entry.timer || entry.inflight) continue;
    if (!entry.hits) scheduleNetRemote(key, entry, 300);
    else if (entry.pending.size) scheduleNetRemote(key, entry, 1000);
  }
}

function scheduleNetRemote(key, entry, delay) {
  clearTimeout(entry.timer);
  entry.timer = setTimeout(() => {
    entry.timer = 0;
    runNetRemote(key, entry);
  }, delay);
}

async function runNetRemote(key, entry) {
  if (netRemote.get(key) !== entry || entry.inflight) return;
  let ids = entry.hits ? [...entry.pending] : null;
  if (ids && !ids.length) return;
  // 积压过多时改为全量查找
  if (ids && ids.length > 500) ids = null;
  entry.pending.clear();
  const token = entry.token;
  const params = { q: entry.q, scope: entry.scope, client: `${net.searchClient}-${key}` };
  if (ids) params.ids = ids.join(',');
  entry.inflight = true;
  try {
    const res = await fetch(netApi('search', params));
    const data = await res.json().catch(() => ({}));
    if (token === entry.token && res.ok) {
      if (ids && entry.hits) (data.ids || []).forEach((id) => entry.hits.add(id));
      else entry.hits = new Set(data.ids || []);
      rebuildNetView();
      renderNetFilterEditorCount();
    }
  } catch (e) {
    // 设备断开时保留地址等字段的过滤结果
  } finally {
    entry.inflight = false;
  }
  if (token === entry.token && netRemote.get(key) === entry && entry.pending.size && !entry.timer) scheduleNetRemote(key, entry, 1000);
}

// MARK: Bar

function netChipCount(only) {
  let count = 0;
  for (const record of net.list) {
    if (only(record)) count++;
  }
  return count;
}

function netChip(text, group, key, test) {
  const selected = group ? netFilters.selected[group].has(key) : !netFilterChipsActive();
  const chip = el('button', 'net-chip' + (selected ? ' on' : ''), text);
  chip.dataset.group = group || '';
  chip.dataset.key = key || '';
  chip.setAttribute('aria-pressed', String(selected));
  if (test) chip.addEventListener('mouseenter', () => {
    chip.title = t('匹配 {0} 条', netChipCount(test)) + (group ? ' · ' + t('⌘ 单击可多选') : '');
  });
  chip.addEventListener('click', (e) => toggleNetChip(group, key, e.metaKey || e.ctrlKey));
  return chip;
}

function netFilterChipsActive() {
  const { type, status, custom } = netFilters.selected;
  return !!(type.size || status.size || custom.size);
}

function toggleNetChip(group, key, multi) {
  const { selected } = netFilters;
  if (!group) {
    selected.type.clear();
    selected.status.clear();
    selected.custom.clear();
  } else {
    const set = selected[group];
    if (multi) {
      if (set.has(key)) set.delete(key);
      else set.add(key);
    } else if (set.has(key) && set.size === 1) {
      set.clear();
    } else {
      set.clear();
      set.add(key);
    }
  }
  saveNetChips();
  renderNetFilterBar();
  rebuildNetView();
}

// folded: 状态组收成下拉, 先完整显示, 放不下再收起
function renderNetFilterBar(folded = false) {
  const bar = $('netChips');
  if (!bar) return;
  bar.hidden = !netFilters.bar;
  $('netFilterRow').hidden = !netFilters.bar;
  const toggle = $('netFilterBar');
  toggle.classList.toggle('on', netFilters.bar);
  toggle.setAttribute('aria-pressed', String(netFilters.bar));
  // 收起时有过滤条件, 按钮高亮提示
  toggle.classList.toggle('active', !netFilters.bar && netFilterChipsActive());
  toggle.title = netFilters.bar ? t('隐藏过滤条') : netFilterChipsActive() ? t('显示过滤条 (有过滤条件)') : t('显示过滤条');
  const track = $('netChipsTrack');
  const scroll = track.scrollLeft;
  const chips = [netChip(t('全部'), '', '', null), el('span', 'net-chip-sep')];
  for (const [key, label, more] of NET_TYPE_CHIPS) {
    if (!more) chips.push(netChip(t(label), 'type', key, (record) => netTypeMatches(record, key)));
  }
  chips.push(netDropChip(t('更多'), 'type', NET_TYPE_CHIPS.filter((chip) => chip[2])));
  chips.push(el('span', 'net-chip-sep'));
  // 放不下时状态也收成下拉
  if (folded) chips.push(netDropChip(t('状态'), 'status', NET_STATUS_CHIPS));
  else for (const [key, label] of NET_STATUS_CHIPS) chips.push(netChip(t(label), 'status', key, (record) => netStatusMatches(record, key)));
  chips.push(el('span', 'net-chip-sep'));
  for (const item of netCustomVisible()) chips.push(netCustomChip(item));
  const add = el('button', 'net-chip net-chip-add');
  add.innerHTML = '<svg class="icon"><use href="#i-plus"/></svg>';
  add.title = t('添加过滤项');
  add.setAttribute('aria-label', t('添加过滤项'));
  add.addEventListener('click', () => showNetFilterEditor(add, null));
  chips.push(add);
  track.replaceChildren(...chips);
  // 面板未显示时宽度为 0, 等显示后再判断
  if (!folded && track.clientWidth && track.scrollWidth > track.clientWidth) {
    renderNetFilterBar(true);
    return;
  }
  track.scrollLeft = scroll;
  syncNetChipsOverflow();
  if (netFilters.chipMenu) renderNetChipMenu();
}

// 收起的一组: 选中一项时显示该项名称, 多项时显示数量
function netDropChip(text, group, items) {
  const picked = items.filter(([key]) => netFilters.selected[group].has(key));
  const label = picked.length === 1 ? t(picked[0][1]) : picked.length ? `${text} (${picked.length})` : text;
  const chip = el('button', 'net-chip net-chip-drop' + (picked.length ? ' on' : ''));
  chip.append(document.createTextNode(label), el('span', 'net-chip-caret', '▾'));
  chip.dataset.group = group;
  chip.dataset.drop = items.map(([key]) => key).join(',');
  chip.setAttribute('aria-haspopup', 'menu');
  chip.addEventListener('click', () => {
    if (netFilters.chipMenu?.group === group) hideNetChipMenu();
    else showNetChipMenu(group, items);
  });
  return chip;
}

// MARK: Chip menu

// 下拉中单击单选并关闭, ⌘ 单击多选并保持打开, 与过滤条上的项一致
function showNetChipMenu(group, items) {
  hideNetChipMenu();
  const menu = el('div', 'context-menu net-chip-menu');
  menu.setAttribute('role', 'menu');
  const onDown = (e) => {
    if (!menu.contains(e.target) && !e.target.closest?.('.net-chip-drop')) hideNetChipMenu();
  };
  const onKey = (e) => {
    if (e.key !== 'Escape') return;
    e.preventDefault();
    e.stopImmediatePropagation();
    hideNetChipMenu();
  };
  window.addEventListener('mousedown', onDown, true);
  window.addEventListener('keydown', onKey, true);
  netFilters.chipMenu = { menu, group, items, dispose: () => {
    window.removeEventListener('mousedown', onDown, true);
    window.removeEventListener('keydown', onKey, true);
  } };
  document.body.append(menu);
  renderNetChipMenu();
}

function renderNetChipMenu() {
  const { menu, group, items } = netFilters.chipMenu;
  const test = group === 'type' ? netTypeMatches : netStatusMatches;
  menu.replaceChildren(...items.map(([key, label]) => {
    const selected = netFilters.selected[group].has(key);
    const button = el('button', 'menu-item net-chip-menu-item' + (selected ? ' on' : ''));
    button.append(el('span', 'net-chip-check', selected ? '✓' : ''), el('span', 'net-chip-menu-label', t(label)), el('span', 'net-chip-menu-count', String(netChipCount((record) => test(record, key)))));
    button.setAttribute('role', 'menuitemcheckbox');
    button.setAttribute('aria-checked', String(selected));
    button.addEventListener('click', (e) => {
      const multi = e.metaKey || e.ctrlKey;
      if (!multi) hideNetChipMenu();
      toggleNetChip(group, key, multi);
    });
    return button;
  }));
  menu.append(el('div', 'net-chip-menu-hint', t('⌘ 单击可多选')));
  const anchor = [...document.querySelectorAll('#netChipsTrack .net-chip-drop')].find((chip) => chip.dataset.group === group);
  if (!anchor) {
    hideNetChipMenu();
    return;
  }
  const rect = anchor.getBoundingClientRect();
  const size = menu.getBoundingClientRect();
  menu.style.left = Math.max(8, Math.min(rect.left, window.innerWidth - size.width - 8)) + 'px';
  menu.style.top = (rect.bottom + 4 + size.height <= window.innerHeight - 8 ? rect.bottom + 4 : Math.max(8, rect.top - 4 - size.height)) + 'px';
}

function hideNetChipMenu() {
  const menu = netFilters.chipMenu;
  if (!menu) return;
  menu.dispose();
  menu.menu.remove();
  netFilters.chipMenu = null;
}

function netCustomChip(item) {
  const query = netCustomQuery(item);
  const chip = netChip(item.name || item.query, 'custom', item.id, (record) => netQueryMatches(record, query));
  chip.classList.add('custom');
  if (query.invalid) chip.classList.add('invalid');
  chip.addEventListener('mouseenter', () => {
    chip.title = `${item.query}\n${query.invalid ? t('条件无效') : t('匹配 {0} 条', netChipCount((record) => netQueryMatches(record, query)))}${item.app ? '\n' + t('只在 {0} 显示', cacheAppName(item.app) || item.app) : ''}`;
  });
  chip.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    e.stopPropagation();
    showNetMenu(e.clientX, e.clientY, [
      ['编辑', () => showNetFilterEditor(chip, item)],
      ['复制条件', () => copyText(item.query, '复制条件')],
      ['用作搜索条件', () => {
        const input = $('netFilter');
        input.value = item.query;
        input.dispatchEvent(new Event('input'));
      }],
      null,
      ['删除', () => removeNetCustomFilter(item.id)],
    ]);
  });
  // 拖动调整顺序
  chip.draggable = true;
  chip.addEventListener('dragstart', (e) => {
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', item.id);
    chip.classList.add('dragging');
  });
  chip.addEventListener('dragend', () => chip.classList.remove('dragging'));
  chip.addEventListener('dragover', (e) => {
    if (!e.dataTransfer.types.includes('text/plain')) return;
    e.preventDefault();
    const rect = chip.getBoundingClientRect();
    chip.classList.toggle('drop-before', e.clientX < rect.left + rect.width / 2);
    chip.classList.toggle('drop-after', e.clientX >= rect.left + rect.width / 2);
  });
  chip.addEventListener('dragleave', () => chip.classList.remove('drop-before', 'drop-after'));
  chip.addEventListener('drop', (e) => {
    e.preventDefault();
    const after = chip.classList.contains('drop-after');
    chip.classList.remove('drop-before', 'drop-after');
    moveNetCustomFilter(e.dataTransfer.getData('text/plain'), item.id, after);
  });
  return chip;
}

function moveNetCustomFilter(id, target, after) {
  if (id === target) return;
  const list = netFilters.custom;
  const from = list.findIndex((item) => item.id === id);
  if (from < 0) return;
  const [moved] = list.splice(from, 1);
  const to = list.findIndex((item) => item.id === target);
  list.splice(to < 0 ? list.length : to + (after ? 1 : 0), 0, moved);
  saveNetCustomFilters();
  renderNetFilterBar();
}

function removeNetCustomFilter(id) {
  netFilters.custom = netFilters.custom.filter((item) => item.id !== id);
  netFilters.compiled.delete(id);
  netFilters.selected.custom.delete(id);
  saveNetCustomFilters();
  saveNetChips();
  syncNetRemote();
  renderNetFilterBar();
  rebuildNetView();
}

// 过滤项超出宽度时横向滚动, 两端渐隐并显示箭头
function syncNetChipsOverflow() {
  const track = $('netChipsTrack');
  if (!track || $('netChips').hidden) return;
  const max = track.scrollWidth - track.clientWidth;
  const left = track.scrollLeft > 1;
  const right = track.scrollLeft < max - 1;
  $('netChips').classList.toggle('fade-left', left);
  $('netChips').classList.toggle('fade-right', right);
  $('netChipsLeft').hidden = !left;
  $('netChipsRight').hidden = !right;
}

// MARK: Editor

function showNetFilterEditor(anchor, item) {
  hideNetFilterEditor();
  const bubble = el('div', 'confirm-bubble net-filter-editor');
  bubble.setAttribute('role', 'dialog');
  bubble.append(el('div', 'confirm-title', item ? t('编辑过滤项') : t('添加过滤项')));
  const name = el('input', 'net-filter-name');
  name.placeholder = t('名称 (可选, 默认显示条件)');
  name.spellcheck = false;
  name.value = item?.name || '';
  const query = el('input', 'net-filter-query');
  query.placeholder = t('条件, 如 host:example.com status:5xx');
  query.spellcheck = false;
  // 新建时用搜索框当前的内容
  query.value = item ? item.query : $('netFilter').value.trim();
  const prefixes = el('div', 'net-filter-prefixes');
  for (const field of NET_QUERY_FIELDS) {
    const button = el('button', 'net-filter-prefix', field + ':');
    button.title = `${t(NET_QUERY_HELP[field][0])}\n${t('示例')}: ${NET_QUERY_HELP[field][1]}`;
    button.addEventListener('mousedown', (e) => e.preventDefault());
    button.addEventListener('click', () => {
      const start = query.selectionStart ?? query.value.length;
      const before = query.value.slice(0, start);
      const insert = (before && !/\s$/.test(before) ? ' ' : '') + field + ':';
      query.setRangeText(insert, start, query.selectionEnd ?? start, 'end');
      query.focus();
      query.dispatchEvent(new Event('input'));
    });
    prefixes.append(button);
  }
  const hint = el('div', 'confirm-detail net-filter-hint', t('| 分隔, \\ 开头为正则, 多个条件同时满足'));
  const count = el('div', 'net-filter-count');
  const scope = el('label', 'net-filter-scope');
  const only = el('input');
  only.type = 'checkbox';
  only.checked = !!item?.app;
  scope.append(only, document.createTextNode(' ' + t('只在 {0} 显示', cacheAppName(item?.app || targets.bundleId) || item?.app || targets.bundleId || t('当前 App'))));
  only.disabled = !item?.app && !targets.bundleId;
  const buttons = el('div', 'confirm-buttons');
  const cancel = el('button', 'confirm-cancel', t('取消'));
  const ok = el('button', 'confirm-ok', item ? t('保存') : t('添加'));
  buttons.append(cancel, ok);
  bubble.append(name, query, prefixes, hint, count, scope, buttons);

  const editor = { bubble, item, query: null, count, ok, anchor };
  netFilters.editor = editor;
  const update = () => {
    editor.query = compileNetQuery(query.value, 'e');
    query.classList.toggle('invalid', editor.query.invalid);
    ok.disabled = !netQueryActive(editor.query);
    syncNetRemote();
    renderNetFilterEditorCount();
  };
  query.addEventListener('input', update);
  update();
  const save = () => {
    if (ok.disabled) return;
    const value = { name: name.value.trim(), query: query.value.trim(), app: only.checked ? item?.app || targets.bundleId : '' };
    if (item) {
      Object.assign(item, value);
      netFilters.compiled.delete(item.id);
    } else {
      const id = Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
      netFilters.custom.push({ id, ...value });
      // 新建后直接选中
      netFilters.selected.custom = new Set([id]);
      saveNetChips();
    }
    saveNetCustomFilters();
    hideNetFilterEditor();
    renderNetFilterBar();
    rebuildNetView();
  };
  cancel.addEventListener('click', hideNetFilterEditor);
  ok.addEventListener('click', save);
  // 捕获阶段处理按键, 不触发全局快捷键和 Esc 关闭面板
  const onKey = (e) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopImmediatePropagation();
      hideNetFilterEditor();
    } else if (e.key === 'Enter' && bubble.contains(e.target) && !e.isComposing) {
      e.preventDefault();
      e.stopImmediatePropagation();
      save();
    } else if (bubble.contains(e.target)) {
      e.stopImmediatePropagation();
    }
  };
  const onDown = (e) => {
    if (!bubble.contains(e.target)) hideNetFilterEditor();
  };
  window.addEventListener('keydown', onKey, true);
  window.addEventListener('mousedown', onDown, true);
  editor.dispose = () => {
    window.removeEventListener('keydown', onKey, true);
    window.removeEventListener('mousedown', onDown, true);
  };
  document.body.append(bubble);
  const rect = anchor.getBoundingClientRect();
  const size = bubble.getBoundingClientRect();
  const below = rect.bottom + 6;
  const top = below + size.height <= window.innerHeight - 8 ? below : rect.top - 6 - size.height;
  bubble.style.left = Math.max(8, Math.min(rect.left, window.innerWidth - size.width - 8)) + 'px';
  bubble.style.top = Math.max(8, top) + 'px';
  (item || query.value ? name : query).focus();
}

function renderNetFilterEditorCount() {
  const editor = netFilters.editor;
  if (!editor) return;
  const query = editor.query;
  if (!query?.raw) {
    editor.count.textContent = '';
    return;
  }
  if (query.invalid) {
    editor.count.textContent = t('条件无效');
    editor.count.classList.add('invalid');
    return;
  }
  editor.count.classList.remove('invalid');
  const loading = query.remote.some((item) => !netRemote.get(item.key)?.hits) && net.searchSupported;
  editor.count.textContent = t('匹配 {0} 条', netChipCount((record) => netQueryMatches(record, query))) + (loading ? ' · ' + t('正在查找内容…') : '');
}

function hideNetFilterEditor() {
  const editor = netFilters.editor;
  if (!editor) return;
  editor.dispose?.();
  editor.bubble.remove();
  netFilters.editor = null;
  syncNetRemote();
}

// MARK: Search hint

// 搜索框获得焦点且为空时列出前缀和示例, 输入前缀开头(如 ho)时改为补全, Tab 或回车补全; 输入其他内容后收起
const netQueryHint = { card: null, fields: [], index: 0, complete: false, token: null };

// 光标前正在输入的条件
function netQueryToken(input) {
  const end = input.selectionStart ?? input.value.length;
  const text = /(\S*)$/.exec(input.value.slice(0, end))[1];
  return { start: end - text.length, end, text };
}

function updateNetQueryHint() {
  const input = $('netFilter');
  if (document.activeElement !== input) {
    hideNetQueryHint();
    return;
  }
  const token = netQueryToken(input);
  const word = token.text.toLowerCase();
  let fields = [];
  let complete = false;
  if (!input.value.trim()) {
    fields = NET_QUERY_FIELDS;
  } else if (word && !word.includes(':') && !input.value.trimStart().startsWith('\\')) {
    fields = NET_QUERY_FIELDS.filter((field) => field.startsWith(word));
    complete = true;
  }
  if (!fields.length) {
    hideNetQueryHint();
    return;
  }
  const changed = complete !== netQueryHint.complete || fields.join() !== netQueryHint.fields.join();
  Object.assign(netQueryHint, { fields, complete, token, index: changed ? 0 : netQueryHint.index });
  renderNetQueryHint();
}

function renderNetQueryHint() {
  let card = netQueryHint.card;
  if (!card) {
    card = el('div', 'net-query-hint');
    card.setAttribute('role', 'listbox');
    // 点击卡片不让搜索框失去焦点
    card.addEventListener('mousedown', (e) => e.preventDefault());
    document.body.append(card);
    netQueryHint.card = card;
  }
  const rows = netQueryHint.fields.map((field, index) => {
    const [desc, example] = NET_QUERY_HELP[field];
    const row = el('div', 'net-query-hint-row' + (netQueryHint.complete && index === netQueryHint.index ? ' sel' : ''));
    row.setAttribute('role', 'option');
    row.append(el('code', 'net-query-hint-key', field + ':'), el('span', 'net-query-hint-desc', t(desc)), el('code', 'net-query-hint-example', example));
    row.addEventListener('click', () => applyNetQueryHint(field));
    return row;
  });
  card.replaceChildren(...rows);
  if (!netQueryHint.complete) card.append(el('div', 'net-query-hint-foot', t('| 分隔, \\ 开头为正则, 多个条件同时满足')));
  const rect = $('netSearch').getBoundingClientRect();
  card.style.left = Math.max(8, Math.min(rect.left, window.innerWidth - card.offsetWidth - 8)) + 'px';
  // 下方放不下时放到搜索框上方
  const height = card.offsetHeight;
  card.style.top = (rect.bottom + 4 + height <= window.innerHeight - 8 ? rect.bottom + 4 : Math.max(8, rect.top - 4 - height)) + 'px';
}

function applyNetQueryHint(field) {
  const input = $('netFilter');
  const token = netQueryToken(input);
  input.setRangeText(field + ':', token.start, token.end, 'end');
  input.dispatchEvent(new Event('input'));
  updateNetQueryHint();
}

function hideNetQueryHint() {
  netQueryHint.card?.remove();
  Object.assign(netQueryHint, { card: null, fields: [], complete: false, index: 0 });
}

function setupNetQueryHint() {
  const input = $('netFilter');
  input.addEventListener('focus', updateNetQueryHint);
  input.addEventListener('blur', hideNetQueryHint);
  input.addEventListener('input', updateNetQueryHint);
  input.addEventListener('click', updateNetQueryHint);
  input.addEventListener('keyup', (e) => {
    if (/^(Arrow(Left|Right)|Home|End)$/.test(e.key)) updateNetQueryHint();
  });
  input.addEventListener('keydown', (e) => {
    if (!netQueryHint.card || e.isComposing) return;
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopImmediatePropagation();
      hideNetQueryHint();
      return;
    }
    if (!netQueryHint.complete) return;
    const count = netQueryHint.fields.length;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      netQueryHint.index = (netQueryHint.index + (e.key === 'ArrowDown' ? 1 : count - 1)) % count;
      renderNetQueryHint();
    } else if (e.key === 'Tab' || e.key === 'Enter') {
      applyNetQueryHint(netQueryHint.fields[netQueryHint.index]);
    } else {
      return;
    }
    e.preventDefault();
    e.stopImmediatePropagation();
  });
  window.addEventListener('resize', hideNetQueryHint);
}

function setupNetFilters() {
  setupNetQueryHint();
  loadNetFilterState();
  netFilters.search = compileNetQuery('', 'q');
  $('netFilterBar').addEventListener('click', () => {
    netFilters.bar = !netFilters.bar;
    saveNetChips();
    renderNetFilterBar();
  });
  const track = $('netChipsTrack');
  track.addEventListener('scroll', syncNetChipsOverflow, { passive: true });
  // 竖向滚轮也横向滚动
  track.addEventListener('wheel', (e) => {
    if (Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return;
    e.preventDefault();
    track.scrollLeft += e.deltaY;
  }, { passive: false });
  $('netChipsLeft').addEventListener('click', () => track.scrollBy({ left: -track.clientWidth * 0.7, behavior: 'smooth' }));
  $('netChipsRight').addEventListener('click', () => track.scrollBy({ left: track.clientWidth * 0.7, behavior: 'smooth' }));
  let width = 0;
  new ResizeObserver(() => {
    syncNetChipsOverflow();
    // 宽度变化时重新判断状态是否收起
    if (track.clientWidth !== width) {
      width = track.clientWidth;
      renderNetFilterBar();
    }
  }).observe(track);
  renderNetFilterBar();
}
