'use strict';

// Per-page annotations are screen-space marks, not inferred control selections.
const mcpCanvas = {
  tool: '', marks: [], draft: null, revision: 0, identity: '', socket: null, retry: 0,
  wrap() { return $(state.mode === 'live' ? 'liveWrap' : 'stageWrap'); },
  target() {
    return [targets.deviceId || '', targets.bundleId || '', appState.instanceId || currentApp()?.instanceId || '', state.mode].join('|');
  },
  syncTarget() {
    const target = this.target();
    if (this.identity && this.identity !== target) { this.clear(false); this.setTool(''); }
    this.identity = target;
    this.render();
  },
  clear(publish = true) {
    if (!this.marks.length && !this.draft) return;
    this.marks = []; this.draft = null; this.revision++;
    this.render();
    if (publish) scheduleMCPContext();
  },
  selectElement() {
    // The latest explicit element selection supersedes any previous marks.
    this.clear(false);
    this.setTool('');
  },
  exitAndClear() {
    this.clear();
    this.setTool('');
  },
  setTool(tool) {
    this.tool = this.tool === tool ? '' : tool;
    if (this.tool) {
      if (picker.on) setColorPicker(false);
      if (live.inspect) setLiveInspect(false);
      document.activeElement?.blur?.();
      setPanKey(false);
      hideHoverTip();
      if (state.hover) { state.hover = null; updateHighlights(); }
      hidePopovers();
    }
    this.syncInteractionLock();
    for (const [id, name] of [['annotationRect', 'rectangle'], ['annotationPen', 'freehand']]) {
      const button = $(id);
      button.classList.toggle('on', this.tool === name);
      button.setAttribute('aria-pressed', String(this.tool === name));
    }
    for (const layer of document.querySelectorAll('.mcp-annotation-layer')) layer.classList.toggle('active', !!this.tool && layer.parentElement === this.wrap());
  },
  syncInteractionLock() {
    const marking = !!this.tool;
    const picking = typeof picker !== 'undefined' && picker.on;
    const pending = typeof screenColorPending !== 'undefined' && screenColorPending;
    const locked = marking || picking || pending;
    document.body.classList.toggle('annotation-mode', marking);
    for (const area of document.querySelectorAll('.toolbar, .tree-pane, .detail-pane, .log-pane, .splitter, .live-home-dock, .live-guide, .canvas-pane > :not(.canvas-float):not(.stage-wrap):not(.live-wrap):not(.loupe)')) area.inert = locked;
    $('modeSeg').inert = locked;
    $('tree').inert = locked;
    $('crumbs').inert = locked;
    for (const control of document.querySelectorAll('.canvas-float button, .canvas-float input')) {
      const permitted = marking ? !!control.closest('.annotation-tools') : picking && control.id === 'systemColorPick';
      control.inert = locked && !permitted;
    }
  },
  focus() {
    if (!this.marks.length) return null;
    const mark = this.marks.at(-1);
    const focus = { shape: mark.shape, count: this.marks.length };
    // The cached 2D hierarchy and stage share one projection. Do not infer
    // node identity from live frames or overlapping 3D depth planes.
    const win = state.mode === '2d' && mark.shape === 'rectangle' ? currentWindow() : null;
    if (!win) return focus;
    const wrap = this.wrap().getBoundingClientRect(), stage = $('stage').getBoundingClientRect();
    if (!wrap.width || !wrap.height || !stage.width || !stage.height) return focus;
    const a = mark.points[0], b = mark.points[1];
    const box = { left: wrap.left + Math.min(a.x,b.x)*wrap.width, top: wrap.top + Math.min(a.y,b.y)*wrap.height,
      right: wrap.left + Math.max(a.x,b.x)*wrap.width, bottom: wrap.top + Math.max(a.y,b.y)*wrap.height };
    const hints = [];
    for (const node of state.nodes.values()) {
      if (node.win !== win || node.effHidden || node.isLayer || !node.rect || node.rect.length !== 4) continue;
      const value = String(node.text || (node.title !== node.cls ? node.title : '') || '').replace(/\s+/g, ' ').trim();
      if (!value) continue;
      const [x,y,w,h] = node.rect;
      const left = stage.left + (x-win.rect[0])/win.rect[2]*stage.width, top = stage.top + (y-win.rect[1])/win.rect[3]*stage.height;
      const width = w/win.rect[2]*stage.width, height = h/win.rect[3]*stage.height;
      if (!(width > 0 && height > 0) || width > (box.right-box.left)*1.5 || height > (box.bottom-box.top)*1.5) continue;
      const overlap = Math.max(0, Math.min(left+width,box.right)-Math.max(left,box.left))*Math.max(0, Math.min(top+height,box.bottom)-Math.max(top,box.top));
      const text = value.length > 40 ? value.slice(0,40)+'…' : value;
      if (overlap >= width*height*.6 && !hints.includes(text)) hints.push(text);
      if (hints.length === 3) break;
    }
    if (hints.length) focus.hints = hints;
    return focus;
  },
  render() {
    for (const layer of document.querySelectorAll('.mcp-annotation-layer')) {
      layer.replaceChildren();
      layer.classList.toggle('active', !!this.tool && layer.parentElement === this.wrap());
      if (layer.parentElement !== this.wrap()) continue;
      for (const mark of [...this.marks, ...(this.draft ? [this.draft] : [])]) {
        const svg = document.createElementNS('http://www.w3.org/2000/svg', mark.shape === 'rectangle' ? 'rect' : 'polyline');
        if (mark.shape === 'rectangle') {
          const [a, b] = mark.points;
          for (const [name, value] of Object.entries({x: Math.min(a.x,b.x)*1000, y: Math.min(a.y,b.y)*1000, width: Math.abs(a.x-b.x)*1000, height: Math.abs(a.y-b.y)*1000})) svg.setAttribute(name, String(value));
        } else svg.setAttribute('points', mark.points.map(p => `${p.x*1000},${p.y*1000}`).join(' '));
        layer.append(svg);
      }
    }
    $('annotationUndo').disabled = !this.marks.length;
    $('annotationClear').disabled = !this.marks.length;
  },
  setupLayer(wrap) {
    const layer = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    layer.setAttribute('viewBox', '0 0 1000 1000');
    layer.setAttribute('preserveAspectRatio', 'none');
    layer.classList.add('mcp-annotation-layer');
    wrap.appendChild(layer);
    const point = e => {
      const r = layer.getBoundingClientRect();
      return {x: Math.min(1, Math.max(0, (e.clientX-r.left)/r.width)), y: Math.min(1, Math.max(0, (e.clientY-r.top)/r.height))};
    };
    layer.addEventListener('pointerdown', e => {
      if (!this.tool) return;
      e.preventDefault(); e.stopPropagation();
      if (e.pointerType === 'mouse' && e.button !== 0) return;
      this.syncTarget();
      const p = point(e);
      this.draft = {shape: this.tool, points: this.tool === 'rectangle' ? [p, p] : [p]};
      try { layer.setPointerCapture(e.pointerId); } catch (_) {}
      this.render();
    });
    layer.addEventListener('pointermove', e => {
      if (this.tool) e.stopPropagation();
      if (!this.draft) return;
      e.preventDefault(); e.stopPropagation();
      const p = point(e);
      if (this.draft.shape === 'rectangle') this.draft.points[1] = p;
      else if (this.draft.points.length < 1000) this.draft.points.push(p);
      this.render();
    });
    const finish = e => {
      if (!this.draft) return;
      e.preventDefault(); e.stopPropagation();
      if (e.type === 'pointerup' && this.draft.points.length > 1) {
        this.marks.push(this.draft);
        if (this.marks.length > 20) this.marks.shift();
        this.revision++;
        scheduleMCPContext(true);
      }
      this.draft = null; this.render();
    };
    layer.addEventListener('pointerup', finish);
    layer.addEventListener('pointercancel', finish);
    for (const type of ['wheel', 'gesturestart', 'gesturechange', 'gestureend', 'contextmenu', 'dblclick']) {
      layer.addEventListener(type, e => { if (this.tool) { e.preventDefault(); e.stopPropagation(); } }, { passive: false });
    }
  },
  setup() {
    this.setupLayer($('stageWrap')); this.setupLayer($('liveWrap'));
    $('annotationRect').addEventListener('click', () => this.setTool('rectangle'));
    $('annotationPen').addEventListener('click', () => this.setTool('freehand'));
    $('annotationUndo').addEventListener('click', () => this.undo());
    $('annotationClear').addEventListener('click', () => this.clear());
    this.syncTarget();
    this.connect();
  },
  undo() {
    if (!this.marks.length) return;
    this.marks.pop(); this.revision++; this.render(); scheduleMCPContext();
  },
  connect() {
    clearTimeout(this.retry);
    if (mcpContext.closed) return;
    const params = new URLSearchParams({ window: mcpContext.windowId, generation: mcpContext.pageGeneration });
    const socket = new WebSocket(`ws://${location.host}/api/hub/mcp/page?${params}`);
    this.socket = socket;
    socket.onmessage = e => {
      let request;
      try { request = JSON.parse(e.data); } catch (_) { return; }
      if (request.type !== 'capture' || typeof request.id !== 'string') return;
      try {
        if (this.socket !== socket || request.window !== mcpContext.windowId || request.device !== (targets.deviceId || '') ||
            request.app !== (targets.bundleId || '') || request.instance !== (appState.instanceId || currentApp()?.instanceId || '') ||
            request.mode !== state.mode || request.annotationRevision !== this.revision ||
            (!this.marks.length && request.selectedElement !== (mcpSelectedInfo()?.element || ''))) throw new Error('canvas_changed');
        const encoded = this.screenshot().split(',')[1];
        if (!encoded || encoded.length > 11 * 1024 * 1024) throw new Error('canvas_unavailable');
        for (let offset = 0; offset < encoded.length; offset += 60000) socket.send(JSON.stringify({id: request.id, chunk: encoded.slice(offset, offset+60000)}));
        socket.send(JSON.stringify({id: request.id, done: true}));
      } catch (_) { socket.send(JSON.stringify({id: request.id, error: 'canvas_unavailable'})); }
    };
    socket.onclose = () => { if (this.socket === socket && !mcpContext.closed) this.retry = setTimeout(() => this.connect(), 1500); };
  },
  screenshot() {
    const wrap = this.wrap(), bounds = wrap.getBoundingClientRect();
    if (!bounds.width || !bounds.height) throw new Error('canvas_unavailable');
    const scale = Math.min(window.devicePixelRatio || 1, 2, 1920 / Math.max(bounds.width, bounds.height));
    const output = document.createElement('canvas');
    output.width = Math.max(1, Math.round(bounds.width * scale)); output.height = Math.max(1, Math.round(bounds.height * scale));
    const ctx = output.getContext('2d'); ctx.scale(scale, scale);
    ctx.fillStyle = getComputedStyle(document.documentElement).getPropertyValue('--stage-bg').trim() || '#17181b';
    ctx.fillRect(0, 0, bounds.width, bounds.height);
    if (state.mode === 'live') {
      const canvas = $('liveCanvas');
      if (!live.hasFrame || !canvas.width || !canvas.height) throw new Error('canvas_unavailable');
      const r = canvas.getBoundingClientRect();
      const width = parseFloat(canvas.style.width), height = parseFloat(canvas.style.height);
      if (!(width > 0 && height > 0)) throw new Error('canvas_unavailable');
      ctx.save(); ctx.translate(r.left - bounds.left + r.width/2, r.top - bounds.top + r.height/2);
      ctx.rotate((LIVE_ROTATION[live.orientation] || 0) * Math.PI/180);
      ctx.drawImage(canvas, -width/2, -height/2, width, height); ctx.restore();
    } else if (state.mode === '3d') {
      if (!stage3DReady() || !stage3D.items.length) throw new Error('canvas_unavailable');
      stage3DDraw(); stage3D.gl.flush();
      ctx.drawImage(stage3D.canvas, 0, 0, bounds.width, bounds.height);
    } else {
      const image = $('stage').querySelector('.shot');
      if (!image || !image.complete || !image.naturalWidth || image.style.visibility === 'hidden') throw new Error('canvas_unavailable');
      const r = image.getBoundingClientRect();
      ctx.drawImage(image, r.left-bounds.left, r.top-bounds.top, r.width, r.height);
      for (const box of $('stage').querySelectorAll('.box.selected')) {
        const b = box.getBoundingClientRect();
        if (!b.width || !b.height) continue;
        ctx.fillStyle = 'rgba(47,107,255,.18)'; ctx.strokeStyle = '#5b8cff'; ctx.lineWidth = 2;
        ctx.fillRect(b.left-bounds.left,b.top-bounds.top,b.width,b.height); ctx.strokeRect(b.left-bounds.left,b.top-bounds.top,b.width,b.height);
      }
    }
    ctx.strokeStyle = '#ff4d4f'; ctx.lineWidth = 3; ctx.lineJoin = 'round'; ctx.lineCap = 'round';
    for (const mark of this.marks) {
      const points = mark.points.map(p => [p.x*bounds.width,p.y*bounds.height]);
      ctx.beginPath();
      if (mark.shape === 'rectangle') ctx.rect(points[0][0],points[0][1],points[1][0]-points[0][0],points[1][1]-points[0][1]);
      else { ctx.moveTo(...points[0]); points.slice(1).forEach(p => ctx.lineTo(...p)); }
      ctx.stroke();
    }
    return output.toDataURL('image/png');
  },
};
