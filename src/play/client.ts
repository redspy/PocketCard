// 게임 클라이언트 (React 훅): 연결(GameConnection)에서 받은 메시지로 화면 상태를 만든다.
// 연결 종류(실제 서버 / 브라우저 데모)는 connect 함수로 주입한다.
import { useCallback, useEffect, useRef, useState } from 'react';
import { DEFAULT_PORT, PROTOCOL_VERSION } from '../game/protocol.ts';
import type { ClientInput, ClientMsg, LobbyInfo, Role, ServerMsg } from '../game/protocol.ts';
import type { CatalogDeck } from '../game/catalog.ts';
import type { GameEvent, Seat } from '../game/types.ts';
import type { GameView } from '../game/view.ts';
import { wsConnection } from './transport.ts';
import type { ConnStatus, GameConnection } from './transport.ts';

/** 서버 주소: ?server=host:port 가 있으면 그것, 없으면 이 페이지의 호스트 + 기본 포트 */
export function defaultServer(): string {
  const q = new URLSearchParams(location.search).get('server');
  return q || `${location.hostname || 'localhost'}:${DEFAULT_PORT}`;
}

export const store = {
  get(key: string): string | null { try { return localStorage.getItem(key); } catch { return null; } },
  set(key: string, v: string | null) { try { if (v === null) localStorage.removeItem(key); else localStorage.setItem(key, v); } catch { /* 저장 불가 환경 */ } },
};

// 다시 시도해도 소용없는 오류 → 연결 중단
const FATAL = new Set(['protocol', 'data_version', 'bad_code', 'full', 'in_game']);

export type ClientState = {
  status: ConnStatus | 'idle';
  seat: Seat | null;
  code: string | null;
  lobby: LobbyInfo | null;
  decks: CatalogDeck[];
  view: GameView | null;
  log: GameEvent[];
  error: { code: string; message: string; at: number } | null;
  fatal: boolean;
};

const initial: ClientState = { status: 'idle', seat: null, code: null, lobby: null, decks: [], view: null, log: [], error: null, fatal: false };

export type ClientOptions = {
  role: Role;
  /** 연결 만들기 (기본: 실제 서버 WebSocket) */
  connect?: () => GameConnection;
  /** connect 가 바뀌었음을 알리는 키 (바뀌면 다시 연결) */
  connKey?: string;
  server?: string;
  code?: string;
  tokenKey?: string;
  device?: string;
  enabled: boolean;
};

export function useGameClient(opts: ClientOptions) {
  const [st, setSt] = useState<ClientState>(initial);
  const connRef = useRef<GameConnection | null>(null);
  const optsRef = useRef(opts);
  optsRef.current = opts;
  const key = opts.connKey ?? opts.server ?? '';

  useEffect(() => {
    if (!opts.enabled) return;
    const o = optsRef.current;
    const conn = o.connect ? o.connect() : wsConnection(o.server ?? defaultServer());
    connRef.current = conn;
    let usedToken = false;

    const hello = () => {
      const cur = optsRef.current;
      const token = cur.tokenKey ? store.get(cur.tokenKey) : null;
      usedToken = !!token;
      const m: ClientMsg = { t: 'hello', protocol: PROTOCOL_VERSION, role: cur.role, ...(token ? { token } : {}), ...(cur.code ? { code: cur.code } : {}), ...(cur.device ? { device: cur.device } : {}) };
      conn.send(m);
    };
    const offStatus = conn.onStatus((s) => {
      setSt((x) => ({ ...x, status: s }));
      if (s === 'open') hello();
    });
    const offMsg = conn.subscribe((m: ServerMsg) => {
      switch (m.t) {
        case 'welcome':
          if (m.token && optsRef.current.tokenKey) store.set(optsRef.current.tokenKey, m.token);
          setSt((s) => ({ ...s, seat: m.seat, code: m.code, error: null, fatal: false }));
          break;
        case 'catalog': setSt((s) => ({ ...s, decks: m.decks })); break;
        case 'lobby': setSt((s) => ({ ...s, lobby: m.lobby })); break;
        case 'state': setSt((s) => ({ ...s, view: m.view })); break;
        case 'events': setSt((s) => ({ ...s, log: [...s.log, ...m.events].slice(-300) })); break;
        case 'error': {
          // 토큰이 낡았으면(서버가 새 세션) 지우고 코드로 다시 참가
          const cur = optsRef.current;
          if (m.code === 'bad_code' && usedToken && cur.tokenKey && cur.code) { store.set(cur.tokenKey, null); hello(); break; }
          const fatal = FATAL.has(m.code);
          if (fatal) conn.close();
          setSt((s) => ({ ...s, error: { ...m, at: Date.now() }, fatal: fatal || s.fatal }));
          break;
        }
      }
    });
    return () => {
      offStatus();
      offMsg();
      conn.close();
      connRef.current = null;
      setSt(initial);
    };
  }, [opts.enabled, key, opts.role, opts.code, opts.tokenKey]);

  const send = useCallback((m: ClientMsg) => connRef.current?.send(m), []);
  const input = useCallback((i: ClientInput) => send({ t: 'input', input: i }), [send]);

  return { ...st, send, input };
}

export type GameClient = ReturnType<typeof useGameClient>;
