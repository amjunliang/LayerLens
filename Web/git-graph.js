'use strict';

// 提交记录的分支图与引用标签, 参考 Sourcetree: 每条分支一列, 合并与分叉用曲线连接
const GIT_GRAPH_LANE = 14;
const GIT_GRAPH_ROW = 24;
const GIT_GRAPH_COLORS = ['#3d8af7', '#e5532d', '#f5a524', '#30b07a', '#a26bf5', '#e04897', '#2bb5c8', '#8f9a3c'];

function gitGraphColor(lane) {
  return GIT_GRAPH_COLORS[lane % GIT_GRAPH_COLORS.length];
}

// 按提交顺序(子提交在前)逐行分配列: lanes[j] 是该列下一个要出现的提交;
// 每行记录进入节点的列(into)、从节点出发的列(out)和上方经过的列(top), 绘制时只看本行
function gitGraphLayout(commits) {
  const lanes = [];
  const rows = [];
  let width = 1;
  for (const commit of commits) {
    const top = lanes.slice();
    let col = lanes.indexOf(commit.oid);
    if (col < 0) {
      col = lanes.indexOf(null);
      if (col < 0) col = lanes.length;
    }
    const into = [];
    lanes.forEach((oid, index) => {
      if (oid === commit.oid) {
        into.push(index);
        lanes[index] = null;
      }
    });
    const out = [];
    const parents = (commit.parents || '').split(' ').filter(Boolean);
    parents.forEach((parent, index) => {
      let lane = lanes.indexOf(parent);
      if (lane < 0) {
        // 第一个父提交沿用本列, 其余父提交开新列
        lane = index === 0 && lanes[col] == null ? col : lanes.indexOf(null);
        if (lane < 0) lane = lanes.length;
        lanes[lane] = parent;
      }
      out.push(lane);
    });
    while (lanes.length && lanes[lanes.length - 1] == null) lanes.pop();
    rows.push({ col, top, into, out });
    width = Math.max(width, top.length, lanes.length, col + 1);
  }
  return { rows, width };
}

function gitGraphCell(row, width, head) {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  const w = width * GIT_GRAPH_LANE + 4;
  const h = GIT_GRAPH_ROW;
  const mid = h / 2;
  const x = (lane) => lane * GIT_GRAPH_LANE + GIT_GRAPH_LANE / 2 + 2;
  svg.setAttribute('class', 'git-graph');
  svg.setAttribute('width', w);
  svg.setAttribute('height', h);
  svg.setAttribute('viewBox', `0 0 ${w} ${h}`);
  const line = (x1, y1, x2, y2, color) => {
    const path = document.createElementNS(ns, 'path');
    const ym = (y1 + y2) / 2;
    path.setAttribute('d', x1 === x2 ? `M${x1} ${y1}V${y2}` : `M${x1} ${y1}C${x1} ${ym} ${x2} ${ym} ${x2} ${y2}`);
    path.setAttribute('stroke', color);
    svg.append(path);
  };
  row.top.forEach((oid, lane) => {
    if (oid == null) return;
    if (row.into.includes(lane)) line(x(lane), 0, x(row.col), mid, gitGraphColor(lane));
    else line(x(lane), 0, x(lane), h, gitGraphColor(lane));
  });
  row.out.forEach((lane) => line(x(row.col), mid, x(lane), h, gitGraphColor(lane)));
  const dot = document.createElementNS(ns, 'circle');
  dot.setAttribute('cx', x(row.col));
  dot.setAttribute('cy', mid);
  dot.setAttribute('r', head ? 4.5 : 4);
  dot.setAttribute('class', head ? 'git-graph-head' : '');
  dot.setAttribute('fill', head ? 'var(--panel)' : gitGraphColor(row.col));
  dot.setAttribute('stroke', gitGraphColor(row.col));
  svg.append(dot);
  return svg;
}

// %D 的完整引用名: HEAD -> refs/heads/x, refs/remotes/origin/x, tag: refs/tags/v1
function gitParseRefs(text) {
  return (text || '').split(', ').filter(Boolean).map((item) => {
    let name = item;
    let head = false;
    if (name.startsWith('HEAD -> ')) {
      name = name.slice(8);
      head = true;
    }
    if (name.startsWith('tag: ')) return { kind: 'tag', name: name.slice(5).replace(/^refs\/tags\//, '') };
    if (name.startsWith('refs/heads/')) return { kind: 'branch', name: name.slice(11), head };
    if (name.startsWith('refs/remotes/')) return { kind: 'remote', name: name.slice(13) };
    return { kind: 'head', name };
  });
}

function gitRefBadges(refs, lane) {
  return refs.map((ref) => {
    const badge = el('span', 'git-ref git-ref-' + ref.kind + (ref.head ? ' current' : ''), ref.name);
    badge.style.setProperty('--ref-color', gitGraphColor(lane));
    return badge;
  });
}
