'use strict';

// EventSource 所需的接口, 事件数据经 WebSocket 传输, 不占用浏览器的
// HTTP/1.1 连接池。Hub 内部继续使用 SSE, 无需升级 iOS Pod。
class LayerLensEventSource extends EventTarget {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSED = 2;

  constructor(url) {
    super();
    this.url = new URL(url, location.href).href;
    this.readyState = LayerLensEventSource.CONNECTING;
    this.retry = 2000;
    this.timer = 0;
    this.connect();
  }

  emit(event) {
    this.dispatchEvent(event);
    this['on' + event.type]?.(event);
  }

  connect() {
    const target = new URL(this.url);
    if (target.origin !== location.origin) throw new Error('Event stream must be same-origin');
    const url = new URL('/api/hub/event-socket', location.href);
    url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    url.searchParams.set('target', target.pathname + target.search);
    const ws = new WebSocket(url);
    this.socket = ws;
    ws.binaryType = 'arraybuffer';
    const decoder = new TextDecoder();
    let buffer = '';
    let eventName = '';
    let data = [];
    let skipLF = false;
    const line = (text) => {
      if (!text) {
        if (data.length) this.emit(new MessageEvent(eventName || 'message', { data: data.join('\n'), origin: target.origin }));
        eventName = '';
        data = [];
        return;
      }
      const colon = text.indexOf(':');
      const field = colon < 0 ? text : text.slice(0, colon);
      let value = colon < 0 ? '' : text.slice(colon + 1);
      if (value.startsWith(' ')) value = value.slice(1);
      if (field === 'event') eventName = value;
      if (field === 'data') data.push(value);
      if (field === 'retry' && /^\d+$/.test(value)) this.retry = Math.min(2147483647, Number(value));
    };
    ws.onmessage = (message) => {
      if (this.socket !== ws || this.readyState === LayerLensEventSource.CLOSED) return;
      if (typeof message.data === 'string') {
        const { status } = JSON.parse(message.data);
        if (status !== 200) {
          this.close();
          this.emit(new Event('error'));
        } else {
          this.readyState = LayerLensEventSource.OPEN;
          this.emit(new Event('open'));
        }
        return;
      }
      const text = decoder.decode(message.data, { stream: true });
      for (const char of text) {
        if (this.socket !== ws) break;
        if (skipLF && char === '\n') { skipLF = false; continue; }
        skipLF = char === '\r';
        if (char === '\r' || char === '\n') { line(buffer); buffer = ''; }
        else buffer += char;
      }
    };
    ws.onclose = () => {
      if (this.socket !== ws || this.readyState === LayerLensEventSource.CLOSED) return;
      this.readyState = LayerLensEventSource.CONNECTING;
      this.timer = setTimeout(() => this.connect(), this.retry);
      this.emit(new Event('error'));
    };
    // WebSocket 在错误后会发 close, 统一在 close 中重连, 不重复计时。
    ws.onerror = () => {};
  }

  close() {
    this.readyState = LayerLensEventSource.CLOSED;
    clearTimeout(this.timer);
    this.socket?.close();
    this.socket = null;
  }
}
