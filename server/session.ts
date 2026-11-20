// 게임 세션: 로비(자리·덱·준비) → 카운트다운 → 게임
// - 게임 상태의 원본은 여기 하나. 클라이언트에는 viewFor/eventsFor 로 거른 것만 보낸다.
// - 시드 + 입력 로그를 디스크에 저장 → 서버가 다시 켜지면 리플레이로 같은 상태 복원.
import { randomBytes, randomInt } from 'node:crypto';
import { existsSync, readFileSync, renameSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import type { CardInfo } from '../src/game/types.ts';
import { botHasWork, makeAiBot } from '../src/game/bot.ts';
import type { Bot } from '../src/game/bot.ts';
import { seedRng } from '../src/game/rng.ts';
import type { RngState } from '../src/game/rng.ts';
import { buildDeck } from '../src/game/catalog.ts';
import type { Catalog } from '../src/game/catalog.ts';
import { Match } from '../src/game/match.ts';
import { PROTOCOL_VERSION } from '../src/game/protocol.ts';
import type { ClientInput, ClientMsg, LobbyInfo, Role, ServerMsg } from '../src/game/protocol.ts';
import type { GameConfig, GameEvent, GameInput, Seat, Viewer } from '../src/game/types.ts';
import { GameError } from '../src/game/types.ts';
import { lanAddresses } from './net.ts';

export const COUNTDOWN_MS = 3000;

/** 연결 하나 (WebSocket 을 감싼 것 — 테스트에서는 가짜로 대체 가능) */
export type Conn = {
  id: number;
  send(msg: ServerMsg): void;
  close(): void;
  role: Role | null;
  seat: Seat | null;
};

type SeatState = {
  token: string | null;
  device: string;
  deckId: string | null;
  prints: Record<string, string>;
  ready: boolean;
};

type Saved = {
  version: 1;
  code: string;
  seats: [SeatState, SeatState];
  game: { config: GameConfig; inputs: GameInput[] } | null;
  /** 게임판 세션: 플레이어 2 = 서버 AI */
  boardAi?: boolean;
  aiDeck?: string | null;
  aiDelayMs?: number;
};

/** solo: 게임판 없이 폰 한 대와 서버 AI(플레이어 2)의 연습 세션. aiDelayMs: AI 입력 사이 간격 */
export type SessionOptions = { catalog: Catalog; info: CardInfo; file: string | null; port: number; log?: (msg: string) => void; solo?: boolean; aiDelayMs?: number };

const AI_SEAT: Seat = 1;
const AI_TOKEN = 'ai';

export class Session {
  code: string;
  seats: [SeatState, SeatState];
  phase: LobbyInfo['phase'] = 'lobby';
  countdownEndsAt: number | null = null;
  game: Match | null = null;
  conns = new Set<Conn>();
  private timer: NodeJS.Timeout | null = null;
  private opts: SessionOptions;
  private info: CardInfo;
  readonly solo: boolean;
  /** AI 연습: 상대 덱 (null = 게임 시작 때 무작위) */
  aiDeck: string | null = null;
  lastActive = Date.now();
  private ai: Bot | null = null;
  private aiRng: RngState | null = null;
  private aiTimer: NodeJS.Timeout | null = null;
  /** AI 한 수 사이 간격 (폰에서 바꿀 수 있음) */
  aiDelayMs: number;
  /** 게임판 세션: 플레이어 2 자리를 서버 AI 가 맡음 (폰 한 대로 게임판 흐름 시험) */
  boardAi = false;
  get aiOn() { return this.solo || this.boardAi; }

  constructor(opts: SessionOptions) {
    this.opts = opts;
    this.info = opts.info;
    this.code = String(randomInt(0, 1_000_000)).padStart(6, '0');
    this.seats = [emptySeat(), emptySeat()];
    this.solo = !!opts.solo;
    this.aiDelayMs = opts.aiDelayMs ?? 700;
    if (this.solo) {
      this.code = 'AI';
      this.seats[AI_SEAT] = { ...emptySeat(), token: AI_TOKEN, device: 'AI' };
      this.ai = makeAiBot(opts.catalog, opts.info.db);
    }
  }

  // ───────────── 저장 / 복원 ─────────────

  /** 저장된 세션을 불러와 입력 로그를 리플레이한다. 실패하면 null */
  static load(opts: SessionOptions): Session | null {
    if (!opts.file || !existsSync(opts.file)) return null;
    const saved = JSON.parse(readFileSync(opts.file, 'utf8')) as Saved;
    const s = new Session(opts);
    s.code = saved.code;
    s.seats = saved.seats.map((x) => ({ ...x, ready: saved.game ? x.ready : false })) as [SeatState, SeatState];
    if (saved.boardAi) {
      s.boardAi = true;
      s.aiDeck = saved.aiDeck ?? null;
      s.aiDelayMs = saved.aiDelayMs ?? s.aiDelayMs;
      s.ai = makeAiBot(opts.catalog, opts.info.db);
      if (!saved.game) s.seats[AI_SEAT] = aiSeat(s.aiDeck);
    }
    if (saved.game) {
      s.game = Match.replay(saved.game, s.info);
      s.phase = 'game';
    }
    return s;
  }

  private save() {
    const f = this.opts.file;
    if (!f) return;
    const saved: Saved = { version: 1, code: this.code, seats: this.seats, game: this.game ? { config: this.game.config, inputs: this.game.inputs } : null,
      ...(this.boardAi ? { boardAi: true, aiDeck: this.aiDeck, aiDelayMs: this.aiDelayMs } : {}) };
    mkdirSync(dirname(f), { recursive: true });
    writeFileSync(`${f}.tmp`, JSON.stringify(saved));
    renameSync(`${f}.tmp`, f);
  }

  // ───────────── 연결 ─────────────

  attach(conn: Conn) { this.conns.add(conn); }

  detach(conn: Conn) {
    this.conns.delete(conn);
    if (conn.seat !== null && !this.seatConnected(conn.seat)) {
      this.log(`플레이어 ${conn.seat + 1} 연결 끊김`);
      if (this.phase === 'countdown') this.cancelCountdown();
    }
    this.broadcastLobby();
  }

  seatConnected(seat: Seat) {
    if (this.aiOn && seat === AI_SEAT) return true;
    for (const c of this.conns) if (c.seat === seat && c.role === 'player') return true;
    return false;
  }

  get paused() { return this.phase === 'game' && !(this.seatConnected(0) && this.seatConnected(1)); }

  handle(conn: Conn, msg: ClientMsg) {
    try {
      if (!msg || typeof msg !== 'object' || typeof (msg as { t?: unknown }).t !== 'string') throw new GameError('bad_msg', '메시지 형식 오류');
      if (msg.t === 'ping') { conn.send({ t: 'pong', serverTime: Date.now() }); return; }
      if (msg.t === 'hello') { this.hello(conn, msg); return; }
      // 게임판: 플레이어 2 = AI 켜고 끄기, AI 대전이 끝난 뒤 다시 하기
      if (conn.role === 'board' && msg.t === 'boardAi') { this.lastActive = Date.now(); this.setBoardAi(msg); return; }
      if (conn.role === 'board' && msg.t === 'kick') { this.lastActive = Date.now(); this.kick(msg.seat); return; }
      if (conn.role === 'board' && msg.t === 'rematch') { this.lastActive = Date.now(); this.rematch(); return; }
      if (conn.role !== 'player' || conn.seat === null) throw new GameError('not_joined', '먼저 게임에 참가하세요.');
      this.lastActive = Date.now();
      switch (msg.t) {
        case 'aiDeck': this.setAiDeck(msg.deckId); break;
        case 'rematch': this.rematch(); break;
        case 'aiSpeed': this.setAiSpeed(msg.ms); break;
        case 'chooseDeck': this.chooseDeck(conn.seat, msg.deckId, msg.prints ?? {}); break;
        case 'ready': this.setReady(conn.seat, !!msg.ready); break;
        case 'input': this.input(conn.seat, msg.input); break;
        default: throw new GameError('bad_msg', '알 수 없는 메시지');
      }
    } catch (e) {
      const err = e instanceof GameError ? e : new GameError('server_error', String((e as Error)?.message ?? e));
      conn.send({ t: 'error', code: err.code, message: err.message });
    }
  }

  private hello(conn: Conn, msg: Extract<ClientMsg, { t: 'hello' }>) {
    if (msg.protocol !== PROTOCOL_VERSION) {
      conn.send({ t: 'error', code: 'protocol', message: `앱과 서버의 버전이 다릅니다 (앱 ${msg.protocol}, 서버 ${PROTOCOL_VERSION}). 앱을 업데이트하세요.` });
      conn.close();
      return;
    }
    if (msg.role === 'player' && msg.dataVersion && msg.dataVersion !== this.opts.catalog.dataVersion) {
      conn.send({ t: 'error', code: 'data_version', message: '앱과 서버의 카드 데이터가 다릅니다. 앱을 다시 설치하세요.' });
      conn.close();
      return;
    }
    if (msg.role === 'board') {
      conn.role = 'board';
      conn.seat = null;
      this.welcome(conn, null);
      return;
    }
    // 플레이어: 토큰이 있으면 같은 자리로 재접속
    let seat: Seat | null = null;
    let token: string | null = null;
    if (msg.token) {
      const i = this.seats.findIndex((s) => s.token === msg.token);
      if (i >= 0 && !(this.aiOn && i === AI_SEAT)) { seat = i as Seat; token = msg.token; }
    }
    if (seat === null) {
      if (!this.solo && String(msg.code ?? '') !== this.code) throw new GameError('bad_code', '세션 코드가 맞지 않습니다.');
      if (this.phase !== 'lobby') throw new GameError('in_game', '이미 게임이 진행 중입니다.');
      const free = this.seats.findIndex((s) => s.token === null);
      if (free < 0) throw new GameError('full', '자리가 모두 찼습니다.');
      seat = free as Seat;
      token = randomBytes(16).toString('hex');
      this.seats[seat] = { ...emptySeat(), token };
    }
    // 같은 자리의 이전 연결은 닫는다 (자리 인계·재접속)
    for (const c of [...this.conns]) if (c !== conn && c.seat === seat && c.role === 'player') { c.seat = null; c.role = null; c.close(); this.conns.delete(c); }
    conn.role = 'player';
    conn.seat = seat;
    if (msg.device) this.seats[seat].device = String(msg.device).slice(0, 40);
    this.save();
    this.log(`플레이어 ${seat + 1} 접속 (${this.seats[seat].device || '기기 이름 없음'})`);
    this.welcome(conn, token);
  }

  private welcome(conn: Conn, token: string | null) {
    conn.send({ t: 'welcome', role: conn.role!, seat: conn.seat, token, code: this.code, protocol: PROTOCOL_VERSION, dataVersion: this.opts.catalog.dataVersion, serverTime: Date.now() });
    conn.send({ t: 'catalog', decks: this.opts.catalog.decks });
    this.broadcastLobby();
    if (this.game) conn.send(this.game.snapshot(this.viewerOf(conn)));
    this.scheduleAi();   // 서버를 다시 켜 복원한 게임이 AI 차례에서 멈춰 있지 않게
  }

  private viewerOf(conn: Conn): Viewer { return conn.role === 'player' && conn.seat !== null ? conn.seat : 'board'; }

  // ───────────── 로비 ─────────────

  private chooseDeck(seat: Seat, deckId: string, prints: Record<string, string>) {
    if (this.phase !== 'lobby') throw new GameError('in_game', '게임 중에는 덱을 바꿀 수 없습니다.');
    if (!this.opts.catalog.decks.some((d) => d.id === deckId)) throw new GameError('no_deck', '없는 덱입니다.');
    const clean: Record<string, string> = {};
    for (const [k, v] of Object.entries(prints ?? {})) if (typeof v === 'string') clean[String(k)] = v;
    this.seats[seat] = { ...this.seats[seat], deckId, prints: clean, ready: false };
    this.save();
    this.broadcastLobby();
  }

  private setReady(seat: Seat, ready: boolean) {
    if (this.phase === 'game') throw new GameError('in_game', '이미 게임 중입니다.');
    if (ready && !this.seats[seat].deckId) throw new GameError('no_deck', '먼저 덱을 고르세요.');
    this.seats[seat].ready = ready;
    // AI 연습: 내가 준비하면 AI 덱을 정하고 바로 시작
    if (this.solo && ready && this.phase === 'lobby') {
      const decks = this.opts.catalog.decks;
      const deckId = this.aiDeck && decks.some((d) => d.id === this.aiDeck) ? this.aiDeck : decks[randomInt(0, decks.length)].id;
      this.seats[AI_SEAT] = { ...this.seats[AI_SEAT], deckId, prints: {}, ready: true };
      this.startGame();
      return;
    }
    if (!ready && this.phase === 'countdown') this.cancelCountdown();
    this.maybeCountdown();
    this.save();
    this.broadcastLobby();
  }

  /** 두 자리 모두 준비 + 연결 → 카운트다운 (게임판 AI 의 덱이 무작위면 이때 정함) */
  private maybeCountdown() {
    if (!(this.seats[0].ready && this.seats[1].ready && this.seatConnected(0) && this.seatConnected(1) && this.phase === 'lobby')) return;
    if (this.boardAi && !this.seats[AI_SEAT].deckId) {
      const decks = this.opts.catalog.decks;
      this.seats[AI_SEAT].deckId = decks[randomInt(0, decks.length)].id;
    }
    this.phase = 'countdown';
    this.countdownEndsAt = Date.now() + COUNTDOWN_MS;
    this.timer = setTimeout(() => this.startGame(), COUNTDOWN_MS);
  }

  /** 게임판: 연결이 끊긴 플레이어를 내보내 자리를 비운다 (대전 준비 중에만, 접속 중인 사람·AI 자리는 안 됨) */
  private kick(seat: unknown) {
    if (seat !== 0 && seat !== 1) throw new GameError('bad_msg', '자리 번호가 잘못됐습니다.');
    if (this.phase === 'game') throw new GameError('in_game', '게임 중에는 내보낼 수 없습니다.');
    const s = this.seats[seat];
    if (s.token === null) throw new GameError('empty_seat', '빈자리입니다.');
    if (this.aiOn && seat === AI_SEAT) throw new GameError('bad_msg', 'AI 자리는 [플레이어 2를 AI로]를 꺼서 비우세요.');
    if (this.seatConnected(seat)) throw new GameError('connected', '접속 중인 플레이어는 내보낼 수 없습니다.');
    if (this.phase === 'countdown') this.cancelCountdown();
    this.seats[seat] = emptySeat();
    this.log(`플레이어 ${seat + 1} 내보냄 (${s.device || '기기 이름 없음'})`);
    this.save();
    this.broadcastLobby();
  }

  /** 게임판: 플레이어 2 자리를 서버 AI 로 (끄면 빈자리). 사람이 접속해 있는 자리는 빼앗지 않는다 */
  private setBoardAi(msg: Extract<ClientMsg, { t: 'boardAi' }>) {
    if (this.solo) throw new GameError('bad_msg', 'AI 연습 세션에서는 쓸 수 없습니다.');
    if (this.phase !== 'lobby') throw new GameError('in_game', '대전 준비 중에만 바꿀 수 있습니다.');
    const decks = this.opts.catalog.decks;
    if (msg.deckId !== undefined && msg.deckId !== null && !decks.some((d) => d.id === msg.deckId)) throw new GameError('no_deck', '없는 덱입니다.');
    if (msg.ms !== undefined) {
      const n = Number(msg.ms);
      if (!Number.isFinite(n)) throw new GameError('bad_msg', '속도 값이 잘못됐습니다.');
      this.aiDelayMs = Math.max(0, Math.min(5000, Math.round(n)));
    }
    if (msg.on) {
      const s = this.seats[AI_SEAT];
      if (!this.boardAi && s.token !== null && this.seatConnected(AI_SEAT)) throw new GameError('seat_taken', '플레이어 2 자리에 이미 사람이 접속해 있습니다.');
      if (msg.deckId !== undefined) this.aiDeck = msg.deckId;
      if (!this.boardAi) this.log('플레이어 2 = AI');
      this.boardAi = true;
      this.ai ??= makeAiBot(this.opts.catalog, this.opts.info.db);
      this.seats[AI_SEAT] = aiSeat(this.aiDeck);
    } else if (this.boardAi) {
      this.boardAi = false;
      this.ai = null;
      this.aiDeck = null;
      this.seats[AI_SEAT] = emptySeat();
      this.log('플레이어 2 = AI 끔');
    }
    this.maybeCountdown();
    this.save();
    this.broadcastLobby();
  }

  private setAiDeck(deckId: string | null) {
    if (!this.solo) throw new GameError('not_solo', 'AI 연습에서만 쓸 수 있습니다.');
    if (this.phase !== 'lobby') throw new GameError('in_game', '게임 중에는 덱을 바꿀 수 없습니다.');
    if (deckId !== null && !this.opts.catalog.decks.some((d) => d.id === deckId)) throw new GameError('no_deck', '없는 덱입니다.');
    this.aiDeck = deckId;
    this.seats[AI_SEAT] = { ...this.seats[AI_SEAT], deckId, ready: false };
    this.broadcastLobby();
  }

  private setAiSpeed(ms: unknown) {
    if (!this.solo) throw new GameError('not_solo', 'AI 연습에서만 쓸 수 있습니다.');
    const n = Number(ms);
    if (!Number.isFinite(n)) throw new GameError('bad_msg', '속도 값이 잘못됐습니다.');
    this.aiDelayMs = Math.max(0, Math.min(5000, Math.round(n)));
    this.broadcastLobby();
  }

  /** AI 연습: 게임을 접고 대전 준비로 (끝난 뒤 다시 하기) */
  private rematch() {
    if (!this.aiOn) throw new GameError('not_solo', 'AI 연습에서만 쓸 수 있습니다.');
    if (this.boardAi && this.game && this.game.state.phase !== 'ended') throw new GameError('in_game', '게임이 끝난 뒤에 다시 할 수 있습니다.');
    this.stopAi();
    this.game = null;
    this.phase = 'lobby';
    this.seats[0].ready = false;
    this.seats[AI_SEAT] = this.boardAi ? aiSeat(this.aiDeck) : { ...this.seats[AI_SEAT], deckId: this.aiDeck, ready: false };
    this.save();
    this.broadcastLobby();
  }

  // ───────────── AI (연습 세션) ─────────────

  /** AI 가 할 일이 있으면 잠깐 뒤에 한 수 (사람이 따라볼 수 있게 간격을 둔다) */
  private scheduleAi() {
    if (!this.ai || !this.game || this.aiTimer || this.game.state.phase === 'ended') return;
    if (!botHasWork(this.game.snapshot(AI_SEAT).view)) return;
    this.aiTimer = setTimeout(() => {
      this.aiTimer = null;
      if (!this.ai || !this.game || this.game.state.phase === 'ended') return;
      this.aiRng ??= seedRng(this.game.config.seed.split('').reverse().join(''));
      const v = JSON.parse(JSON.stringify(this.game.snapshot(AI_SEAT).view));
      const input = this.ai(v, this.aiRng);
      if (!input) return;
      const r = this.game.submit(AI_SEAT, input);
      if (!r.ok) { this.log(`AI 입력 거절 (${r.error.code}): ${r.error.message}`); return; }
      this.broadcastGame(r.events);
    }, this.aiDelayMs);
  }

  private stopAi() { if (this.aiTimer) clearTimeout(this.aiTimer); this.aiTimer = null; }

  private cancelCountdown() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.phase = 'lobby';
    this.countdownEndsAt = null;
  }

  /** 카운트다운이 끝나면 호출 (테스트에서는 시드를 지정해 직접 호출 가능) */
  startGame(seed: string = randomBytes(16).toString('hex')) {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    const [a, b] = this.seats;
    if (!a.deckId || !b.deckId) { this.cancelCountdown(); this.broadcastLobby(); return; }
    const config: GameConfig = {
      seed,
      players: [
        { deckId: a.deckId, cards: buildDeck(this.opts.catalog, a.deckId, a.prints) },
        { deckId: b.deckId, cards: buildDeck(this.opts.catalog, b.deckId, b.prints) },
      ],
    };
    this.game = new Match(config, this.info);
    this.aiRng = null;
    const events = this.game.lastEvents;
    this.phase = 'game';
    this.countdownEndsAt = null;
    this.save();
    this.log(`게임 시작: ${a.deckId} vs ${b.deckId}`);
    this.broadcastLobby();
    this.broadcastGame(events);
  }

  // ───────────── 게임 입력 ─────────────

  private input(seat: Seat, input: unknown) {
    if (!this.game) throw new GameError('no_game', '게임이 시작되지 않았습니다.');
    if (this.paused) throw new GameError('paused', '상대의 재접속을 기다리는 중입니다.');
    const r = this.game.submit(seat, input as ClientInput);
    if (!r.ok) throw new GameError(r.error.code, r.error.message);
    this.save();
    this.broadcastGame(r.events);
  }

  // ───────────── 전송 ─────────────

  lobbyInfo(): LobbyInfo {
    return {
      code: this.code, phase: this.phase, countdownEndsAt: this.countdownEndsAt,
      seats: ([0, 1] as Seat[]).map((seat) => {
        const s = this.seats[seat];
        return {
          seat, taken: s.token !== null, connected: this.seatConnected(seat), device: s.device,
          deckId: s.deckId, deckName: this.opts.catalog.decks.find((d) => d.id === s.deckId)?.name ?? null, ready: s.ready,
        };
      }) as LobbyInfo['seats'],
      addresses: lanAddresses().map(({ address, iface, preferred }) => ({ address, iface, preferred })),
      port: this.opts.port,
      paused: this.paused,
      ...(this.solo ? { solo: true, aiDelayMs: this.aiDelayMs } : {}),
      ...(this.boardAi ? { boardAi: true, aiDeck: this.aiDeck, aiDelayMs: this.aiDelayMs } : {}),
    };
  }

  broadcastLobby() {
    const lobby = this.lobbyInfo();
    for (const c of this.conns) if (c.role) c.send({ t: 'lobby', lobby });
  }

  private broadcastGame(events: GameEvent[]) {
    if (!this.game) return;
    for (const c of this.conns) {
      if (!c.role) continue;
      for (const m of this.game.messagesFor(this.viewerOf(c), events)) c.send(m);
    }
    this.scheduleAi();
  }

  dispose() { if (this.timer) clearTimeout(this.timer); this.stopAi(); }

  private log(msg: string) { this.opts.log?.(msg); }
}

function emptySeat(): SeatState { return { token: null, device: '', deckId: null, prints: {}, ready: false }; }
/** 게임판 AI 자리: 늘 준비 완료 (덱 null = 카운트다운 때 무작위) */
function aiSeat(deckId: string | null): SeatState { return { token: AI_TOKEN, device: 'AI', deckId, prints: {}, ready: true }; }
