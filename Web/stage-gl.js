'use strict';

// 3D 视图的 WebGL 渲染: 每个节点是一块贴了截图的平面, 边线在片元着色器里按屏幕像素宽度绘制,
// 任意缩放和角度下都是清晰的 1px, 被前面的层遮挡; 截图用 mipmap + 各向异性过滤, 缩小和倾斜时不闪烁.
// 相机与原来的 CSS 3D 完全一致: 画布中心为透视原点(perspective: PERSPECTIVE),
// 舞台变换为 translate(pan) scale(s, s, 1) translate(p) rotateX rotateY translate(-p), 与 projectToScreen 等计算共用.
// 平面互相平行, 按到视点的距离从远到近绘制(同层按层级顺序), 半透明截图也能正确叠加, 不需要深度缓冲

const stage3D = {
  canvas: null,
  gl: null,
  program: null,
  loc: null,
  buffer: null,
  maxTexture: 4096,
  anisotropy: null,
  // 当前绘制的节点: { node, key, level, url, x, y, w, h }
  items: [],
  byKey: new Map(),
  // 截图地址 -> { texture, image }; 不再使用的在下次设置节点时释放
  textures: new Map(),
  // 已解码待上传的截图
  uploads: [],
  colors: null,
  frame: 0,
  dirty: false,
  // 画布位置, 尺寸变化时失效
  origins: null,
  lost: false,
};

const GL_VERTEX = `#version 300 es
in vec2 a_pos;
in vec2 a_uv;
uniform mat4 u_mvp;
uniform float u_z;
out vec2 v_uv;
void main() {
  v_uv = a_uv;
  gl_Position = u_mvp * vec4(a_pos, u_z, 1.0);
}`;

// 颜色均为预乘 alpha; 边线宽度以设备像素计, 用 uv 的屏幕导数换算出到四条边的像素距离.
// 不开多重采样, 平面外轮廓在最外 1 像素内按距离淡出来做抗锯齿(轮廓向内收半个像素, 看不出)
const GL_FRAGMENT = `#version 300 es
precision highp float;
in vec2 v_uv;
uniform sampler2D u_tex;
uniform float u_hasTex;
uniform vec4 u_tint;
uniform vec4 u_line;
uniform float u_width;
out vec4 o_color;
void main() {
  vec4 color = u_hasTex > 0.5 ? texture(u_tex, clamp(v_uv, 0.0, 1.0)) : vec4(0.0);
  color = u_tint + color * (1.0 - u_tint.a);
  float gx = max(length(vec2(dFdx(v_uv.x), dFdy(v_uv.x))), 1e-6);
  float gy = max(length(vec2(dFdx(v_uv.y), dFdy(v_uv.y))), 1e-6);
  float dx = min(v_uv.x, 1.0 - v_uv.x) / gx;
  float dy = min(v_uv.y, 1.0 - v_uv.y) / gy;
  float coverage = clamp(u_width + 1.0 - min(dx, dy), 0.0, 1.0);
  vec4 line = u_line * coverage;
  float edge = clamp(min(dx, dy), 0.0, 1.0);
  o_color = (line + color * (1.0 - line.a)) * edge;
}`;

// 首次进入 3D 时创建画布; WebGL2 不可用时返回 false
function stage3DReady() {
  if (stage3D.gl) return true;
  if (stage3D.canvas && !stage3D.lost) return false;
  if (!stage3D.canvas) {
    const canvas = document.createElement('canvas');
    canvas.className = 'stage-gl';
    $('stageWrap').prepend(canvas);
    stage3D.canvas = canvas;
    canvas.addEventListener('webglcontextlost', (e) => {
      e.preventDefault();
      stage3D.gl = null;
      stage3D.lost = true;
      stage3D.textures.clear();
      stage3D.uploads = [];
    });
    canvas.addEventListener('webglcontextrestored', () => {
      if (!stage3DInit()) return;
      // 重新上传截图
      const items = stage3D.items;
      stage3D.items = [];
      stage3DSetItems(items);
    });
    const refreshColors = () => {
      stage3D.colors = null;
      stage3DInvalidate();
    };
    // 画布位置和尺寸只在布局变化时重新读取, 绘制时不强制同步布局
    const resetOrigins = () => {
      stage3D.origins = null;
      stage3DInvalidate();
    };
    new ResizeObserver(resetOrigins).observe($('stageWrap'));
    window.addEventListener('resize', resetOrigins);
    new MutationObserver(refreshColors).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'class'] });
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', refreshColors);
  }
  return stage3DInit();
}

function stage3DInit() {
  const gl = stage3D.canvas.getContext('webgl2', { antialias: false, alpha: true, premultipliedAlpha: true });
  if (!gl) {
    console.error('LayerLens: WebGL2 unavailable, 3D view disabled');
    return false;
  }
  const compile = (type, source) => {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) console.error('LayerLens: shader error', gl.getShaderInfoLog(shader));
    return shader;
  };
  const program = gl.createProgram();
  gl.attachShader(program, compile(gl.VERTEX_SHADER, GL_VERTEX));
  gl.attachShader(program, compile(gl.FRAGMENT_SHADER, GL_FRAGMENT));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    console.error('LayerLens: program error', gl.getProgramInfoLog(program));
    return false;
  }
  stage3D.gl = gl;
  stage3D.lost = false;
  stage3D.program = program;
  stage3D.loc = {
    pos: gl.getAttribLocation(program, 'a_pos'),
    uv: gl.getAttribLocation(program, 'a_uv'),
  };
  ['u_mvp', 'u_z', 'u_tex', 'u_hasTex', 'u_tint', 'u_line', 'u_width'].forEach((name) => {
    stage3D.loc[name] = gl.getUniformLocation(program, name);
  });
  stage3D.buffer = gl.createBuffer();
  stage3D.maxTexture = gl.getParameter(gl.MAX_TEXTURE_SIZE);
  stage3D.anisotropy = gl.getExtension('EXT_texture_filter_anisotropic');
  gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
  return true;
}

// 设置要绘制的节点. frame 为画布区域 [x, y, w, h], 节点坐标换算为相对区域中心;
// urlFor(node) 返回截图地址, 没有截图时返回 null
function stage3DSetNodes(nodes, frame, urlFor) {
  const [fx, fy, fw, fh] = frame;
  stage3DSetItems(nodes.map((node) => ({
    node,
    key: node.key,
    level: node.level || 0,
    url: urlFor(node),
    x: node.rect[0] - fx - fw / 2,
    y: node.rect[1] - fy - fh / 2,
    w: node.rect[2],
    h: node.rect[3],
  })));
}

function stage3DSetItems(items) {
  stage3D.items = items;
  stage3D.byKey = new Map(items.map((item) => [item.key, item]));
  if (!stage3DReady()) return;
  const gl = stage3D.gl;
  // 每个节点 4 个顶点(三角带), 每个顶点 x, y, u, v
  const data = new Float32Array(items.length * 16);
  items.forEach((item, i) => {
    const { x, y, w, h } = item;
    data.set([x, y, 0, 0, x + w, y, 1, 0, x, y + h, 0, 1, x + w, y + h, 1, 1], i * 16);
  });
  gl.bindBuffer(gl.ARRAY_BUFFER, stage3D.buffer);
  gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
  // 释放过期的截图(刷新层级后地址中的时间戳变化); 暂时不用的保留, 进出只看子树、开关截图时不必重新加载
  const used = new Set(items.map((item) => item.url).filter(Boolean));
  const current = `&t=${state.stamp}`;
  stage3D.textures.forEach((entry, url) => {
    if (used.has(url) || url.endsWith(current)) return;
    if (entry.texture) gl.deleteTexture(entry.texture);
    entry.source = null;
    stage3D.textures.delete(url);
  });
  // 重新渲染画布时会丢弃排队中的截图请求, 尚未加载完的重新排队
  used.forEach((url) => {
    let entry = stage3D.textures.get(url);
    if (!entry) {
      entry = { url, texture: null, loading: false, source: null };
      stage3D.textures.set(url, entry);
    }
    if (entry.texture || entry.loading || images.pending.some((job) => job.url === url)) return;
    loadImage(url, (_, image) => stage3DLoadTexture(url, entry, image));
  });
  stage3DInvalidate();
}

// 截图在后台解码, 解码完成后排队, 绘制时按时间预算逐帧上传, 加载期间转动不卡顿.
// loadImage 命中缓存时不带图片对象, 再取一次(命中浏览器内存缓存)
function stage3DLoadTexture(url, entry, image) {
  if (stage3D.textures.get(url) !== entry || entry.texture || entry.loading) return;
  entry.loading = true;
  if (!image) {
    image = new Image();
    image.src = url;
  }
  image.decode().then(() => {
    if (stage3D.textures.get(url) !== entry || !image.naturalWidth) {
      entry.loading = false;
      return;
    }
    entry.source = image;
    stage3D.uploads.push(entry);
    stage3DInvalidate();
  }).catch(() => {
    entry.loading = false;
  });
}

// 上传排队的截图, 每帧至少一张, 超出时间预算的留到下一帧(绘制中再次请求重绘, 排到下一帧)
function stage3DUpload() {
  const gl = stage3D.gl;
  const start = performance.now();
  let count = 0;
  while (stage3D.uploads.length && (!count || performance.now() - start < 4)) {
    const entry = stage3D.uploads.shift();
    const image = entry.source;
    entry.source = null;
    entry.loading = false;
    if (!image || entry.texture || stage3D.textures.get(entry.url) !== entry) continue;
    count++;
    let source = image;
    // 超出纹理尺寸上限时等比缩小
    const limit = stage3D.maxTexture;
    if (image.naturalWidth > limit || image.naturalHeight > limit) {
      const k = limit / Math.max(image.naturalWidth, image.naturalHeight);
      source = document.createElement('canvas');
      source.width = Math.max(1, Math.floor(image.naturalWidth * k));
      source.height = Math.max(1, Math.floor(image.naturalHeight * k));
      source.getContext('2d').drawImage(image, 0, 0, source.width, source.height);
    }
    const texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source);
    gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    const ext = stage3D.anisotropy;
    if (ext) gl.texParameterf(gl.TEXTURE_2D, ext.TEXTURE_MAX_ANISOTROPY_EXT, Math.min(8, gl.getParameter(ext.MAX_TEXTURE_MAX_ANISOTROPY_EXT)));
    entry.texture = texture;
  }
  if (stage3D.uploads.length) stage3DInvalidate();
}

function stage3DHas(key) {
  return stage3D.byKey.has(key);
}

function stage3DClear() {
  stage3DSetItems([]);
}

// 重绘: 本帧还没绘制过时立即绘制并提交给 GPU, 拖动、缩放不必等动画帧回调(WebKit 中常晚一帧);
// 同一帧内的后续变化合并, 在下一次动画帧回调中绘制
function stage3DInvalidate() {
  if (stage3D.frame) {
    stage3D.dirty = true;
    return;
  }
  stage3D.frame = requestAnimationFrame(stage3DFrame);
  stage3DDraw();
  stage3D.gl?.flush();
}

function stage3DFrame() {
  stage3D.frame = 0;
  if (!stage3D.dirty) return;
  stage3D.dirty = false;
  stage3DInvalidate();
}

// 舞台中心(未变换时位于画布内容区中心)与透视原点(画布中心), 客户端坐标
function stage3DOrigins() {
  if (stage3D.origins) return stage3D.origins;
  const wrap = $('stageWrap');
  const rect = wrap.getBoundingClientRect();
  const style = getComputedStyle(wrap);
  const left = parseFloat(style.paddingLeft);
  const right = parseFloat(style.paddingRight);
  const top = parseFloat(style.paddingTop);
  const bottom = parseFloat(style.paddingBottom);
  stage3D.origins = {
    rect,
    center: { x: rect.left + left + (rect.width - left - right) / 2, y: rect.top + top + (rect.height - top - bottom) / 2 },
    origin: { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 },
  };
  return stage3D.origins;
}

// 舞台坐标 -> 相对透视原点的屏幕坐标(透视前), 与 CSS 舞台变换一致
function stage3DModelMatrix(view) {
  const win = currentWindow();
  const scale = win ? stageScale(win) : 1;
  const p = state.pivot;
  return new DOMMatrix()
    .translate(view.center.x - view.origin.x, view.center.y - view.origin.y, 0)
    .translate(state.panX, state.panY, state.panZ)
    .scale(scale, scale, 1)
    .translate(p.x, p.y, p.z)
    .rotateAxisAngle(1, 0, 0, state.rotX)
    .rotateAxisAngle(0, 1, 0, state.rotY)
    .translate(-p.x, -p.y, -p.z);
}

// 当前视角: 投影矩阵与绘制顺序
function stage3DView() {
  const view = stage3DOrigins();
  const model = stage3DModelMatrix(view);
  const { width, height } = view.rect;
  // 透视: w = 1 - z / d; x, y 换算到裁剪坐标, z 不使用
  const projection = new DOMMatrix([2 / Math.max(width, 1), 0, 0, 0, 0, -2 / Math.max(height, 1), 0, 0, 0, 0, 0, -1 / PERSPECTIVE, 0, 0, 0, 1]);
  view.mvp = projection.multiply(model).toFloat32Array();
  view.order = stage3DOrder(model);
  return view;
}

// 平行平面按到视点(0, 0, d)的距离从远到近排序, 同层保持层级顺序
function stage3DOrder(model) {
  const a = model.transformPoint(new DOMPoint(1, 0, 0, 0));
  const b = model.transformPoint(new DOMPoint(0, 1, 0, 0));
  const n = { x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x };
  const levels = new Map();
  stage3D.items.forEach((item, i) => {
    if (!levels.has(item.level)) levels.set(item.level, []);
    levels.get(item.level).push(i);
  });
  const distance = (level) => {
    const p = model.transformPoint(new DOMPoint(0, 0, level * state.spacing, 1));
    return Math.abs(n.x * -p.x + n.y * -p.y + n.z * (PERSPECTIVE - p.z));
  };
  const sorted = [...levels.keys()].map((level) => ({ level, d: distance(level) }));
  // 距离相同(层间距为 0)时低层在下
  sorted.sort((x, y) => y.d - x.d || x.level - y.level);
  return sorted.flatMap(({ level }) => levels.get(level));
}

function stage3DDraw() {
  if (state.mode !== '3d' || !stage3DReady()) return;
  const gl = stage3D.gl;
  const canvas = stage3D.canvas;
  const dpr = window.devicePixelRatio || 1;
  const { rect } = stage3DOrigins();
  const width = Math.max(1, Math.round(rect.width * dpr));
  const height = Math.max(1, Math.round(rect.height * dpr));
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
  }
  gl.viewport(0, 0, width, height);
  gl.clearColor(0, 0, 0, 0);
  gl.clear(gl.COLOR_BUFFER_BIT);
  if (!stage3D.items.length || !currentWindow()) return;
  stage3DUpload();
  const view = stage3DView();
  const colors = stage3DColors();
  const loc = stage3D.loc;
  gl.useProgram(stage3D.program);
  gl.bindBuffer(gl.ARRAY_BUFFER, stage3D.buffer);
  gl.enableVertexAttribArray(loc.pos);
  gl.vertexAttribPointer(loc.pos, 2, gl.FLOAT, false, 16, 0);
  gl.enableVertexAttribArray(loc.uv);
  gl.vertexAttribPointer(loc.uv, 2, gl.FLOAT, false, 16, 8);
  gl.uniformMatrix4fv(loc.u_mvp, false, view.mvp);
  gl.uniform1i(loc.u_tex, 0);
  gl.activeTexture(gl.TEXTURE0);
  view.order.forEach((index) => {
    const item = stage3D.items[index];
    const selected = item.key === state.selected;
    const hover = !selected && item.key === state.hover;
    const texture = item.url && stage3D.textures.get(item.url)?.texture;
    if (texture) gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.uniform1f(loc.u_hasTex, texture ? 1 : 0);
    gl.uniform1f(loc.u_z, item.level * state.spacing);
    gl.uniform4fv(loc.u_tint, selected ? colors.selectedTint : hover ? colors.hoverTint : colors.none);
    gl.uniform4fv(loc.u_line, selected || hover ? colors.accent : colors.line);
    gl.uniform1f(loc.u_width, (selected ? 2 : 1) * dpr);
    gl.drawArrays(gl.TRIANGLE_STRIP, index * 4, 4);
  });
}

// 主题颜色, 换算为预乘 alpha
function stage3DColors() {
  if (stage3D.colors) return stage3D.colors;
  const style = getComputedStyle(document.body);
  const ctx = document.createElement('canvas').getContext('2d');
  const parse = (text) => {
    ctx.fillStyle = '#000';
    ctx.fillStyle = text.trim();
    const value = ctx.fillStyle;
    let r = 0;
    let g = 0;
    let b = 0;
    let a = 1;
    if (value[0] === '#') {
      r = parseInt(value.slice(1, 3), 16);
      g = parseInt(value.slice(3, 5), 16);
      b = parseInt(value.slice(5, 7), 16);
    } else {
      [r, g, b, a = 1] = value.replace(/[^\d.,]/g, '').split(',').map(Number);
    }
    return new Float32Array([(r / 255) * a, (g / 255) * a, (b / 255) * a, a]);
  };
  stage3D.colors = {
    line: parse(style.getPropertyValue('--slab-line')),
    accent: parse(style.getPropertyValue('--accent')),
    hoverTint: parse('rgba(47, 107, 255, 0.12)'),
    selectedTint: parse('rgba(47, 107, 255, 0.2)'),
    none: new Float32Array(4),
  };
  return stage3D.colors;
}

// 节点四角在客户端坐标中的位置; 有角落在视点之后时返回 null
function stage3DCorners(item, view) {
  const m = view.mvp;
  const z = item.level * state.spacing;
  const { width, height } = view.rect;
  const corners = [];
  for (const [x, y] of [[item.x, item.y], [item.x + item.w, item.y], [item.x + item.w, item.y + item.h], [item.x, item.y + item.h]]) {
    const cx = m[0] * x + m[4] * y + m[8] * z + m[12];
    const cy = m[1] * x + m[5] * y + m[9] * z + m[13];
    const cw = m[3] * x + m[7] * y + m[11] * z + m[15];
    if (cw <= 1e-6) return null;
    corners.push({ x: view.origin.x + (cx / cw) * width / 2, y: view.origin.y - (cy / cw) * height / 2 });
  }
  return corners;
}

// 客户端坐标处最上面(最后绘制)的节点
function stage3DNodeAt(clientX, clientY) {
  if (!stage3D.items.length || !currentWindow()) return null;
  const view = stage3DView();
  for (let i = view.order.length - 1; i >= 0; i--) {
    const item = stage3D.items[view.order[i]];
    const corners = stage3DCorners(item, view);
    if (corners && pointInQuad(clientX, clientY, corners)) return item.node;
  }
  return null;
}

// 凸四边形(任意绕向)包含点: 各边叉积同号
function pointInQuad(x, y, corners) {
  let sign = 0;
  for (let i = 0; i < 4; i++) {
    const a = corners[i];
    const b = corners[(i + 1) % 4];
    const cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);
    if (cross === 0) continue;
    if (sign === 0) sign = Math.sign(cross);
    else if (Math.sign(cross) !== sign) return false;
  }
  return sign !== 0;
}

// 节点在屏幕上的外框(客户端坐标), 用于定位悬停标签
function stage3DClientRect(key) {
  const item = stage3D.byKey.get(key);
  if (!item || !currentWindow()) return null;
  const corners = stage3DCorners(item, stage3DView());
  if (!corners) return null;
  const xs = corners.map((c) => c.x);
  const ys = corners.map((c) => c.y);
  const left = Math.min(...xs);
  const top = Math.min(...ys);
  const right = Math.max(...xs);
  const bottom = Math.max(...ys);
  return { left, top, right, bottom, width: right - left, height: bottom - top };
}
