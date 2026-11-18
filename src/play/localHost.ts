// 브라우저 안 데모 호스트: 서버 없이 Match(공용 코어)를 돌리고, 서버와 같은 프로토콜 메시지를 연결마다 보낸다.
//  - 메시지는 JSON 왕복 + 비동기 전달 (실제 네트워크와 같은 조건 → 로컬에서만 통과하는 버그 방지)
//  - 자리별 조작: 사람 / 봇 (봇은 자기 시점 view 만 보고 행동)
//  - 자동 진행(재생·일시정지·한 단계·속도), 되돌리기, 처음부터, 로그 내보내기/불러오기
//  Node·DOM 의존 없음 (테스트에서 그대로 사용)
import { botHasWork, makeAiBot, randomBot } from '../game/bot.ts';
import type { Bot } from '../game/bot.ts';
import { buildDeck } from '../game/catalog.ts';
import type { Catalog } from '../game/catalog.ts';
import type { CardDB } from '../game/cardData.ts';
import type { CardInfo } from '../game/types.ts';
import { ENGINE_VERSION, Match, ReplayError } from '../game/match.ts';
import type { MatchLog } from '../game/match.ts';
import { PROTOCOL_VERSION } from '../game/protocol.ts';
import type { ClientMsg, LobbyInfo, ServerMsg } from '../game/protocol.ts';
import { seedRng } from '../game/rng.ts';
import type { RngState } from '../game/rng.ts';
import type { GameConfig, Seat, Viewer } from '../game/types.ts';
import { Emitter } from './transport.ts';
import type { ConnStatus, GameConnection } from './transport.ts';

export type Controller = 'human' | 'ai' | 'bot';   // bot = 무작위 (퍼징용), ai = 1인용 AI
export const DEMO_CODE = 'DEMO';
export const MAX_AUTO_INPUTS = 5000;

export type HostInfo = {
  seed: string;
  decks: [string, string];
  controllers: [Controller, Controller];
  playing: boolean;
  speedMs: number;
  inputCount: number;
  timelineCount: number;     // 다시 하기로 갈 수 있는 끝
  error: string | null;
};

type LocalConn = { viewer: Viewer; msgs: Emitter<ServerMsg>; status: Emitter<ConnStatus>; open: boolean };

/** 무작위 32자리 16진수 시드 (브라우저·Node 18+ 공용 Web Crypto) */
export function newSeed(): string {
  const b = new Uint8Array(16);
  globalThis.crypto.getRandomValues(b);
  return [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
}

export class LocalHost {
  catalog: Catalog;
  match: Match;
  controllers: [Controller, Controller] = ['human', 'ai'];
  speedMs = 400;
  playing = false;
  error: string | null = null;
  info: CardInfo;
  private ai: Bot;
  botFor = (seat: Seat): Bot => (this.controllers[seat] === 'ai' ? this.ai : randomBot);
  private botRng: RngState;
  private conns = new Set<LocalConn>();
  private timer: ReturnType<typeof setTimeout> | null = null;
  private autoCount = 0;
  /** 되돌리기·다시 하기용 전체 입력 기록 (되돌린 뒤 새 입력이 들어오면 그 뒤는 잘림) */
  private timeline: MatchLog | null = null;
  readonly changed = new Emitter<HostInfo>();

  constructor(catalog: Catalog, db: CardDB, opts: { seed?: string; decks?: [string, string]; controllers?: [Controller, Controller]; log?: MatchLog } = {}) {
    this.catalog = catalog;
    this.info = { basics: catalog.basics, db };
    this.ai = makeAiBot(catalog, db);
    if (opts.controllers) this.controllers = opts.controllers;
    this.match = opts.log ? this.replayOrThrow(opts.log) : new Match(this.config(opts.seed ?? newSeed(), opts.decks ?? [catalog.decks[0].id, catalog.decks[1].id]), this.info);
    this.botRng = seedRng(this.match.config.seed.split('').reverse().join(''));
  }

  private config(seed: string, decks: [string, string]): GameConfig {
    return { seed, players: [{ deckId: decks[0], cards: buildDeck(this.catalog, decks[0]) }, { deckId: decks[1], cards: buildDeck(this.catalog, decks[1]) }] };
  }

  private replayOrThrow(log: MatchLog, upTo?: number): Match {
    if (log.engine !== ENGINE_VERSION) this.error = `엔진 버전이 다른 로그입니다 (로그 ${log.engine}, 현재 ${ENGINE_VERSION}) — 재생을 시도합니다.`;
    return Match.replay(log, this.info, upTo);
  }

  get hostInfo(): HostInfo {
    const p = this.match.config.players;
    return { seed: this.match.config.seed, decks: [p[0].deckId, p[1].deckId], controllers: [...this.controllers] as [Controller, Controller],
      playing: this.playing, speedMs: this.speedMs, inputCount: this.match.inputs.length, timelineCount: this.timeline?.inputs.length ?? this.match.inputs.length, error: this.error };
  }

  // ───────────── 연결 (서버와 같은 프로토콜) ─────────────

  connect(viewer: Viewer): GameConnection {
    const c: LocalConn = { viewer, msgs: new Emitter(), status: new Emitter(), open: true };
    this.conns.add(c);
    queueMicrotask(() => { if (c.open) c.status.emit('open'); });
    return {
      send: (m) => this.receive(c, JSON.parse(JSON.stringify(m)) as ClientMsg),
      subscribe: (fn) => c.msgs.on(fn),
      onStatus: (fn) => c.status.on(fn),
      close: () => { c.open = false; this.conns.delete(c); },
    };
  }

  private deliver(c: LocalConn, m: ServerMsg) {
    const copy = JSON.parse(JSON.stringify(m)) as ServerMsg;
    queueMicrotask(() => { if (c.open) c.msgs.emit(copy); });
  }

  private lobby(): LobbyInfo {
    const name = (id: string) => this.catalog.decks.find((d) => d.id === id)?.name ?? id;
    const p = this.match.config.players;
    return {
      code: DEMO_CODE, phase: 'game', countdownEndsAt: null, port: 0, paused: false, addresses: [],
      seats: ([0, 1] as Seat[]).map((seat) => ({ seat, taken: true, connected: true, device: this.controllers[seat] === 'human' ? '사람 (데모)' : this.controllers[seat] === 'ai' ? 'AI' : '무작위 봇',
        deckId: p[seat].deckId, deckName: name(p[seat].deckId), ready: true })) as LobbyInfo['seats'],
    };
  }

  private receive(c: LocalConn, m: ClientMsg) {
    switch (m.t) {
      case 'hello':
        this.deliver(c, { t: 'welcome', role: c.viewer === 'board' ? 'board' : 'player', seat: c.viewer === 'board' ? null : c.viewer, token: null, code: DEMO_CODE, protocol: PROTOCOL_VERSION, dataVersion: this.catalog.dataVersion, serverTime: Date.now() });
        this.deliver(c, { t: 'catalog', decks: this.catalog.decks });
        this.deliver(c, { t: 'lobby', lobby: this.lobby() });
        this.deliver(c, this.match.snapshot(c.viewer));
        return;
      case 'ping': this.deliver(c, { t: 'pong', serverTime: Date.now() }); return;
      case 'input': {
        if (c.viewer === 'board') { this.deliver(c, { t: 'error', code: 'not_joined', message: '게임판은 입력할 수 없습니다.' }); return; }
        const r = this.match.submit(c.viewer, m.input);
        if (!r.ok) { this.deliver(c, { t: 'error', ...r.error }); return; }
        this.broadcast(r.events);
        this.kick();
        return;
      }
      default:
        this.deliver(c, { t: 'error', code: 'demo', message: '데모 모드에서는 데모 막대에서 덱·설정을 바꾸세요.' });
    }
  }

  private broadcast(events: Parameters<Match['messagesFor']>[1]) {
    this.timeline = this.match.log;
    for (const c of this.conns) for (const m of this.match.messagesFor(c.viewer, events)) this.deliver(c, m);
    this.notify();
  }

  /** 전체 다시 보내기 (되돌리기·불러오기 뒤) — 이벤트 로그는 클라이언트에서 다시 시작 */
  private resync() {
    for (const c of this.conns) { this.deliver(c, { t: 'lobby', lobby: this.lobby() }); this.deliver(c, this.match.snapshot(c.viewer)); }
    this.notify();
  }

  private notify() { this.changed.emit(this.hostInfo); }

  // ───────────── 봇 / 자동 진행 ─────────────

  setController(seat: Seat, ctl: Controller) { this.controllers[seat] = ctl; this.resync(); this.kick(); }

  /** 봇이 할 일이 있는 자리 (선택 요청이 있는 봇 자리 먼저, 그다음 차례인 봇) */
  private botSeat(): Seat | null {
    for (const seat of [0, 1] as Seat[]) {
      if (this.controllers[seat] === 'human') continue;
      const v = this.match.snapshot(seat).view;
      if (v.requests.some((r) => r.player === seat && r.options)) return seat;
    }
    for (const seat of [0, 1] as Seat[]) {
      if (this.controllers[seat] === 'human') continue;
      if (botHasWork(this.match.snapshot(seat).view)) return seat;
    }
    return null;
  }

  /** 봇 입력 하나. 했으면 true */
  step(): boolean {
    const seat = this.botSeat();
    if (seat === null) return false;
    // 봇은 자기 시점 보기만 (JSON 왕복으로 상태 객체와 끊음)
    const view = JSON.parse(JSON.stringify(this.match.snapshot(seat).view));
    const input = this.botFor(seat)(view, this.botRng);
    if (!input) return false;
    const r = this.match.submit(seat, input);
    if (!r.ok) { this.error = `봇 입력 오류 (${r.error.code}): ${r.error.message}`; this.pause(); return false; }
    this.broadcast(r.events);
    return true;
  }

  play() { this.playing = true; this.autoCount = 0; this.error = null; this.notify(); this.kick(); }
  pause() { this.playing = false; if (this.timer) clearTimeout(this.timer); this.timer = null; this.notify(); }
  setSpeed(ms: number) { this.speedMs = Math.max(0, ms); this.notify(); }

  /** 자동 진행 중이면 다음 봇 입력 예약 */
  private kick() {
    if (!this.playing || this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      if (!this.playing) return;
      if (this.match.state.phase === 'ended') { this.pause(); return; }
      if (++this.autoCount > MAX_AUTO_INPUTS) { this.error = `자동 진행 상한(${MAX_AUTO_INPUTS}) 도달 — 멈춤`; this.pause(); return; }
      try {
        if (this.step()) this.kick();      // 봇이 했으면 계속, 사람 차례면 사람 입력 때 kick
      } catch (e) {
        this.error = `엔진 예외: ${(e as Error).message} (시드 ${this.match.config.seed}, 입력 ${this.match.inputs.length}개)`;
        this.pause();
      }
    }, this.speedMs);
  }

  // ───────────── 되돌리기 / 처음부터 / 로그 ─────────────

  /** 입력 n 개를 되돌린다 (로그 앞부분 재생) */
  undo(n = 1) { this.goto(Math.max(0, this.match.inputs.length - n)); }
  /** 되돌린 입력을 n 개 다시 */
  redo(n = 1) { this.goto(this.match.inputs.length + n); }

  /** 입력 count 개까지 재생한 상태로 이동 (타임라인 안에서 앞뒤로) */
  goto(count: number) {
    this.pause();
    const tl = this.timeline ?? this.match.log;
    this.timeline = tl;
    this.match = Match.replay(tl, this.info, Math.max(0, Math.min(count, tl.inputs.length)));
    this.error = null;
    this.resync();
  }

  restart(opts: { seed?: string; decks?: [string, string] } = {}) {
    this.pause();
    const p = this.match.config.players;
    this.match = new Match(this.config(opts.seed ?? newSeed(), opts.decks ?? [p[0].deckId, p[1].deckId]), this.info);
    this.botRng = seedRng(this.match.config.seed.split('').reverse().join(''));
    this.timeline = null;
    this.error = null;
    this.resync();
  }

  exportLog(): MatchLog { return this.match.log; }

  /** 로그 불러오기. 재생에 실패하면 실패 직전까지 불러오고 오류를 남긴다 */
  importLog(log: MatchLog) {
    this.pause();
    try {
      this.match = this.replayOrThrow(log);
    } catch (e) {
      if (e instanceof ReplayError) {
        this.match = Match.replay(log, this.info, e.index);
        this.error = e.message;
      } else throw e;
    }
    this.botRng = seedRng(this.match.config.seed.split('').reverse().join(''));
    this.timeline = null;
    this.resync();
  }

  dispose() { this.pause(); for (const c of this.conns) c.open = false; this.conns.clear(); }
}
