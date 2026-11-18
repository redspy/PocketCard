// 게임 연결 추상화 — 같은 프로토콜 메시지(ClientMsg/ServerMsg)를 주고받는 통로.
//  - wsConnection: 실제 게임 서버 (자동 재접속)
//  - LocalHost.connect(): 브라우저 안 데모 (src/play/localHost.ts)
// 화면(useGameClient)은 어떤 연결인지 모른다 → 데모와 실제가 같은 UI 코드를 탄다.
import type { ClientMsg, ServerMsg } from '../game/protocol.ts';

export type ConnStatus = 'connecting' | 'open' | 'closed';

export interface GameConnection {
  send(msg: ClientMsg): void;
  subscribe(fn: (msg: ServerMsg) => void): () => void;
  /** 'open' 이 될 때마다(재접속 포함) 클라이언트가 hello 를 보낸다 */
  onStatus(fn: (s: ConnStatus) => void): () => void;
  close(): void;
}

/** 작은 이벤트 통로 (구독 목록) */
export class Emitter<T> {
  private fns = new Set<(v: T) => void>();
  on(fn: (v: T) => void) { this.fns.add(fn); return () => { this.fns.delete(fn); }; }
  emit(v: T) { for (const f of [...this.fns]) f(v); }
}

export function wsConnection(server: string): GameConnection {
  const msgs = new Emitter<ServerMsg>();
  const status = new Emitter<ConnStatus>();
  let ws: WebSocket | null = null;
  let stopped = false;
  let retry = 0;
  let timer: ReturnType<typeof setTimeout> | null = null;

  const open = () => {
    if (stopped) return;
    status.emit('connecting');
    const sock = new WebSocket(`ws://${server}`);
    ws = sock;
    sock.onopen = () => { retry = 0; status.emit('open'); };
    sock.onmessage = (ev) => { try { msgs.emit(JSON.parse(String(ev.data)) as ServerMsg); } catch { /* 깨진 메시지 무시 */ } };
    sock.onclose = () => {
      if (ws === sock) ws = null;
      status.emit('closed');
      if (stopped) return;
      retry = Math.min(retry + 1, 5);
      timer = setTimeout(open, 600 * retry);
    };
  };
  // 화면으로 돌아오면 기다리지 않고 바로 다시 연결
  const onVis = () => { if (typeof document !== 'undefined' && document.visibilityState === 'visible' && !ws && !stopped) { if (timer) clearTimeout(timer); open(); } };
  if (typeof document !== 'undefined') document.addEventListener('visibilitychange', onVis);
  setTimeout(open, 0);

  return {
    send: (m) => { if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(m)); },
    subscribe: (fn) => msgs.on(fn),
    onStatus: (fn) => status.on(fn),
    close: () => {
      stopped = true;
      if (timer) clearTimeout(timer);
      if (typeof document !== 'undefined') document.removeEventListener('visibilitychange', onVis);
      ws?.close();
      ws = null;
    },
  };
}
