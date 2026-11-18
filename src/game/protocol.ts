// 서버 ↔ 클라이언트(웹 게임판, 폰 앱, 웹 디버그 폰) WebSocket 메시지
// JSON 한 줄 = 메시지 하나. 모든 메시지에 t(종류) 필드.
import type { GameEvent, GameInput, Seat } from './types.ts';
import type { GameView } from './view.ts';
import type { CatalogDeck } from './catalog.ts';

export const PROTOCOL_VERSION = 3;
export const DEFAULT_PORT = 8787;
export const BEACON_PORT = 8788;      // UDP: 같은 Wi-Fi 의 폰이 게임을 찾는 데 사용

export type Role = 'player' | 'board';

/** 게임 입력에서 player 는 서버가 채운다 (클라이언트가 남의 자리로 입력하지 못하게) */
export type ClientInput =
  | { type: 'choice'; requestId: string; picks: string[] }
  | { type: 'play'; card: string; target?: string }
  | { type: 'retreat'; to: string }
  | { type: 'attack'; index: number }
  | { type: 'ability'; sid: string }
  | { type: 'stadium' }
  | { type: 'endTurn' }
  | { type: 'concede' };

export type ClientMsg =
  /** solo: 게임판 없이 서버 AI 와 1:1 연습 (접속마다 따로 세션) */
  | { t: 'hello'; protocol: number; dataVersion?: string; role: Role; token?: string; code?: string; device?: string; solo?: boolean }
  | { t: 'chooseDeck'; deckId: string; prints?: Record<string, string> }
  | { t: 'ready'; ready: boolean }
  | { t: 'aiDeck'; deckId: string | null }          // AI 연습: 상대(AI) 덱 (null = 무작위)
  | { t: 'rematch' }                                // AI 연습: 끝난 게임 → 대전 준비로
  | { t: 'aiSpeed'; ms: number }                    // AI 연습: AI 한 수 사이 간격 (0~5000ms)
  | { t: 'input'; input: ClientInput }
  | { t: 'ping' };

export type SeatInfo = {
  seat: Seat;
  taken: boolean;
  connected: boolean;
  device: string;
  deckId: string | null;
  deckName: string | null;
  ready: boolean;
};

export type LobbyInfo = {
  code: string;
  phase: 'lobby' | 'countdown' | 'game';
  countdownEndsAt: number | null;    // 서버 시각 (ms)
  seats: [SeatInfo, SeatInfo];
  addresses: { address: string; iface: string; preferred: boolean }[];
  port: number;
  paused: boolean;                   // 게임 중 누가 끊김
  solo?: boolean;                    // AI 연습 세션 (플레이어 2 = AI)
  aiDelayMs?: number;                // AI 연습: AI 한 수 사이 간격
};

export type ServerMsg =
  | { t: 'welcome'; role: Role; seat: Seat | null; token: string | null; code: string; protocol: number; dataVersion: string; serverTime: number }
  | { t: 'catalog'; decks: CatalogDeck[] }
  | { t: 'lobby'; lobby: LobbyInfo }
  | { t: 'state'; view: GameView }
  | { t: 'events'; events: GameEvent[] }
  | { t: 'error'; code: string; message: string }
  | { t: 'pong'; serverTime: number };

/** 서버가 클라이언트 입력을 엔진 입력으로 바꿀 때 사용 */
export function toGameInput(input: ClientInput, player: Seat): GameInput {
  switch (input.type) {
    case 'choice': return { type: 'choice', player, requestId: String(input.requestId), picks: Array.isArray(input.picks) ? input.picks.map(String) : [] };
    case 'play': return input.target ? { type: 'play', player, card: String(input.card), target: String(input.target) } : { type: 'play', player, card: String(input.card) };
    case 'retreat': return { type: 'retreat', player, to: String(input.to) };
    case 'attack': return { type: 'attack', player, index: Number(input.index) };
    case 'ability': return { type: 'ability', player, sid: String(input.sid) };
    case 'stadium': return { type: 'stadium', player };
    case 'endTurn': return { type: 'endTurn', player };
    case 'concede': return { type: 'concede', player };
    default: throw new Error('bad_input');
  }
}
