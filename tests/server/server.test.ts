// 서버 통합 테스트: 실제 WebSocket 으로 로비 → 게임 → 끊김/재접속 → 서버 재시작 복원
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer } from '../../server/main.ts';
import { PROTOCOL_VERSION } from '../../src/game/protocol.ts';
import type { ClientMsg, ServerMsg } from '../../src/game/protocol.ts';
import type { GameView } from '../../src/game/view.ts';

class Client {
  ws: WebSocket;
  msgs: ServerMsg[] = [];
  private waiters: { pred: (m: ServerMsg) => boolean; resolve: (m: ServerMsg) => void }[] = [];
  closed = false;
  constructor(port: number) {
    this.ws = new WebSocket(`ws://127.0.0.1:${port}`);
    this.ws.addEventListener('message', (ev) => {
      const m = JSON.parse(String(ev.data)) as ServerMsg;
      this.msgs.push(m);
      this.waiters = this.waiters.filter((w) => { if (w.pred(m)) { w.resolve(m); return false; } return true; });
    });
    this.ws.addEventListener('close', () => { this.closed = true; });
  }
  open() { return new Promise<void>((res, rej) => { this.ws.addEventListener('open', () => res()); this.ws.addEventListener('error', () => rej(new Error('연결 실패'))); }); }
  send(m: ClientMsg) { this.ws.send(JSON.stringify(m)); }
  private used = new Set<ServerMsg>();
  /** 조건에 맞는 메시지 중 아직 꺼내지 않은 첫 번째 (이미 받은 것 포함), 없으면 기다림 */
  wait<T extends ServerMsg['t']>(t: T, pred: (m: Extract<ServerMsg, { t: T }>) => boolean = () => true, timeout = 8000): Promise<Extract<ServerMsg, { t: T }>> {
    const ok = (m: ServerMsg) => !this.used.has(m) && m.t === t && pred(m as Extract<ServerMsg, { t: T }>);
    const have = this.msgs.find(ok);
    if (have) { this.used.add(have); return Promise.resolve(have as Extract<ServerMsg, { t: T }>); }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`시간 초과: ${t} (받은 메시지 ${this.msgs.map((m) => m.t).join(',')})`)), timeout);
      this.waiters.push({ pred: ok, resolve: (m) => { this.used.add(m); clearTimeout(timer); resolve(m as Extract<ServerMsg, { t: T }>); } });
    });
  }
  /** 조건에 맞는 첫 메시지 하나만 꺼낸다 (종류가 여러 개일 때) */
  waitFirst(pred: (m: ServerMsg) => boolean, timeout = 8000): Promise<ServerMsg> {
    const ok = (m: ServerMsg) => !this.used.has(m) && pred(m);
    const have = this.msgs.find(ok);
    if (have) { this.used.add(have); return Promise.resolve(have); }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('시간 초과')), timeout);
      this.waiters.push({ pred: ok, resolve: (m) => { this.used.add(m); clearTimeout(timer); resolve(m); } });
    });
  }
  last<T extends ServerMsg['t']>(t: T) { return [...this.msgs].reverse().find((m) => m.t === t) as Extract<ServerMsg, { t: T }> | undefined; }
  close() { this.ws.close(); }
}

async function connect(port: number, hello: Omit<Extract<ClientMsg, { t: 'hello' }>, 't' | 'protocol'>) {
  const c = new Client(port);
  await c.open();
  c.send({ t: 'hello', protocol: PROTOCOL_VERSION, ...hello });
  const first = await c.waitFirst((m) => m.t === 'welcome' || m.t === 'error');
  return { c, first };
}

/** 내 선택 요청이 있으면 첫 선택지(들)로 답한다 */
function answer(c: Client, view: GameView) {
  const mine = view.requests.find((r) => r.options && r.player === view.viewer);
  if (!mine) return false;
  c.send({ t: 'input', input: { type: 'choice', requestId: mine.id, picks: mine.options!.slice(0, mine.min) } });
  return true;
}

test('로비 → 게임 → 끊김/재접속 → 서버 재시작 후 복원', { timeout: 60000 }, async () => {
  const dataDir = mkdtempSync(join(tmpdir(), 'pocketcard-'));
  let srv = await startServer({ port: 0, dataDir, beacon: false, quiet: true });
  try {
    const port = srv.port;
    const code = srv.session.code;

    // 게임판
    const board = await connect(port, { role: 'board' });
    assert.equal(board.first.t, 'welcome');

    // 잘못된 코드, 데이터 버전 불일치
    const bad = await connect(port, { role: 'player', code: '000000' === code ? '111111' : '000000' });
    assert.equal(bad.first.t, 'error');
    assert.equal((bad.first as Extract<ServerMsg, { t: 'error' }>).code, 'bad_code');
    bad.c.close();
    const oldApp = await connect(port, { role: 'player', code, dataVersion: 'deadbeef' });
    assert.equal((oldApp.first as Extract<ServerMsg, { t: 'error' }>).code, 'data_version');

    // 플레이어 2명 참가, 3번째는 거절
    const p1 = await connect(port, { role: 'player', code, device: 'Fold' });
    const p2 = await connect(port, { role: 'player', code, device: 'Debug' });
    const w1 = p1.first as Extract<ServerMsg, { t: 'welcome' }>;
    const w2 = p2.first as Extract<ServerMsg, { t: 'welcome' }>;
    assert.equal(w1.seat, 0);
    assert.equal(w2.seat, 1);
    assert.ok(w1.token && w2.token);
    const p3 = await connect(port, { role: 'player', code });
    assert.equal((p3.first as Extract<ServerMsg, { t: 'error' }>).code, 'full');
    p3.c.close();

    // 덱 없이 준비 → 오류, 덱 고르고 준비 → 카운트다운 → 게임 시작
    p1.c.send({ t: 'ready', ready: true });
    assert.equal((await p1.c.wait('error')).code, 'no_deck');
    p1.c.send({ t: 'chooseDeck', deckId: 'dragapult', prints: { SV8a_118: 'M2a_211', SV6_120: 'BAD_999' } });
    p2.c.send({ t: 'chooseDeck', deckId: 'gardevoir' });
    await board.c.wait('lobby', (m) => m.lobby.seats[0].deckId === 'dragapult' && m.lobby.seats[1].deckId === 'gardevoir');
    p1.c.send({ t: 'ready', ready: true });
    p2.c.send({ t: 'ready', ready: true });
    await board.c.wait('lobby', (m) => m.lobby.phase === 'countdown');
    await board.c.wait('lobby', (m) => m.lobby.phase === 'game', 6000);
    let bv = (await board.c.wait('state')).view;
    assert.equal(bv.phase, 'setup');

    // 고른 인쇄가 반영되고, 잘못된 인쇄는 기본 인쇄로
    const cfg = srv.session.game!.config;
    assert.ok(cfg.players[0].cards.find((c) => c.ruleId === 'SV8a_118')?.code === 'M2a_211');
    assert.ok(cfg.players[0].cards.find((c) => c.ruleId === 'SV6_120')?.code === 'SV6_120');

    // 셋업을 자동으로 진행 (각자 첫 선택지로)
    const clients = [p1.c, p2.c];
    for (let i = 0; i < 40 && srv.session.game!.state.phase === 'setup'; i++) {
      for (const c of clients) { const v = c.last('state')?.view; if (v) answer(c, v); }
      await new Promise((r) => setTimeout(r, 60));
    }
    assert.equal(srv.session.game!.state.phase, 'playing');
    bv = (await board.c.wait('state', (m) => m.view.phase === 'playing')).view;
    assert.equal(bv.players[0].hand, null, '게임판에는 패 내용 없음');
    assert.equal(bv.players[0].prizes.filter(Boolean).length, 6);

    // 플레이어 1 끊김 → 일시정지 → 플레이어 2 입력 거절
    p1.c.close();
    await board.c.wait('lobby', (m) => m.lobby.paused === true);
    p2.c.send({ t: 'input', input: { type: 'endTurn' } });
    assert.equal((await p2.c.wait('error')).code, 'paused');

    // 토큰으로 재접속 → 같은 자리, 내 패가 보임
    const p1b = await connect(port, { role: 'player', token: w1.token! });
    const w1b = p1b.first as Extract<ServerMsg, { t: 'welcome' }>;
    assert.equal(w1b.seat, 0);
    const v1 = (await p1b.c.wait('state')).view;
    assert.ok(v1.players[0].hand && v1.players[0].hand.length > 0);
    await board.c.wait('lobby', (m) => m.lobby.paused === false);

    // 턴 진행: 차례인 플레이어가 턴 종료
    const tp = srv.session.game!.state.turnPlayer!;
    const actor = tp === 0 ? p1b.c : p2.c;
    const before = srv.session.game!.state.turnNumber;
    actor.send({ t: 'input', input: { type: 'endTurn' } });
    await board.c.wait('state', (m) => m.view.turnNumber === before + 1);
    const savedVersion = srv.session.game!.state.version;
    const savedJson = JSON.stringify(srv.session.game!.state);

    // 서버 재시작 → 같은 세션 코드, 같은 게임 상태 (리플레이 복원)
    for (const c of [board.c, p1b.c, p2.c]) c.close();
    await srv.close();
    srv = await startServer({ port: 0, dataDir, beacon: false, quiet: true });
    assert.equal(srv.session.code, code);
    assert.equal(srv.session.game!.state.version, savedVersion);
    assert.equal(JSON.stringify(srv.session.game!.state), savedJson);
    const again = await connect(srv.port, { role: 'player', token: w2.token! });
    assert.equal((again.first as Extract<ServerMsg, { t: 'welcome' }>).seat, 1);
    again.c.close();
  } finally {
    await srv.close();
    rmSync(dataDir, { recursive: true, force: true });
  }
});

test('AI 연습: 게임판 없이 폰 한 대 vs 서버 AI → 끝까지 → 재접속 → 다시 하기', { timeout: 120000 }, async () => {
  const srv = await startServer({ port: 0, dataDir: null, beacon: false, quiet: true, aiDelayMs: 0 });
  try {
    const { makeAiBot, botHasWork } = await import('../../src/game/bot.ts');
    const { seedRng } = await import('../../src/game/rng.ts');
    const me = makeAiBot(srv.catalog, srv.info.db);
    const rng = seedRng('5010');
    const { c, first } = await connect(srv.port, { role: 'player', solo: true, device: 'test', dataVersion: srv.catalog.dataVersion });
    assert.equal(first.t, 'welcome');
    const w = first as Extract<ServerMsg, { t: 'welcome' }>;
    assert.equal(w.seat, 0);
    assert.equal(w.code, 'AI');
    assert.equal(srv.solos.size, 1);
    // 게임판 세션에는 아무 자리도 잡히지 않음
    assert.ok(srv.session.seats.every((s) => s.token === null));
    const decks = srv.catalog.decks;
    c.send({ t: 'chooseDeck', deckId: decks[0].id });
    c.send({ t: 'aiDeck', deckId: decks[2].id });
    await c.wait('lobby', (m) => m.lobby.seats[1].deckId === decks[2].id && m.lobby.solo === true);
    c.send({ t: 'aiSpeed', ms: 1 });
    await c.wait('lobby', (m) => m.lobby.aiDelayMs === 1);
    c.send({ t: 'ready', ready: true });
    await c.wait('lobby', (m) => m.lobby.phase === 'game');
    // 내 차례마다 (AI 봇으로) 둔다 — 상대 AI 는 서버가 둔다
    // 내 입력이 처리되기 전의 낡은 화면으로 두 번 보내지 않게: 메시지가 잠시 멈춘 뒤에만 둔다
    let lastVer = -1;
    let view: GameView | undefined;
    let seen = 0, quietSince = Date.now();
    for (let i = 0; i < 40000; i++) {
      if (c.msgs.length !== seen) { seen = c.msgs.length; quietSince = Date.now(); }
      view = c.last('state')?.view;
      if (view?.result) break;
      if (view && Date.now() - quietSince >= 15 && view.version !== lastVer && botHasWork(view)) {
        lastVer = view.version;
        const input = me(JSON.parse(JSON.stringify(view)), rng);
        if (input) c.send({ t: 'input', input: { ...input, player: undefined } as never });
      }
      await new Promise((r) => setTimeout(r, 3));
    }    assert.ok(view?.result, '게임이 끝나야 함');
    assert.ok(!c.msgs.some((m) => m.t === 'error'), `오류 없음: ${JSON.stringify(c.msgs.filter((m) => m.t === 'error'))}`);
    // 재접속: 같은 토큰 → 같은 AI 연습 세션, 같은 자리
    c.close();
    const again = await connect(srv.port, { role: 'player', token: w.token!, dataVersion: srv.catalog.dataVersion });
    assert.equal(again.first.t, 'welcome');
    assert.equal((again.first as Extract<ServerMsg, { t: 'welcome' }>).seat, 0);
    await again.c.wait('state', (m) => !!m.view.result);
    // 다시 하기 → 대전 준비
    again.c.send({ t: 'rematch' });
    await again.c.wait('lobby', (m) => m.lobby.phase === 'lobby' && !m.lobby.seats[0].ready);
    again.c.send({ t: 'ready', ready: true });
    await again.c.wait('lobby', (m) => m.lobby.phase === 'game');
    again.c.close();
  } finally {
    await srv.close();
  }
});

test('게임판: 플레이어 2 = 서버 AI → 폰 한 대로 게임 → 항복 → 다시 하기 → 서버 재시작 후에도 유지', { timeout: 60000 }, async () => {
  const dataDir = mkdtempSync(join(tmpdir(), 'pocketcard-'));
  let srv = await startServer({ port: 0, dataDir, beacon: false, quiet: true, aiDelayMs: 0 });
  try {
    const code = srv.session.code;
    const decks = srv.catalog.decks;
    const board = await connect(srv.port, { role: 'board' });

    // 플레이어 2 자리에 사람이 접속해 있으면 AI 로 바꿀 수 없음 (끊긴 뒤에는 가능)
    const human = await connect(srv.port, { role: 'player', code, device: 'p1' });
    const other = await connect(srv.port, { role: 'player', code, device: 'p2' });
    board.c.send({ t: 'boardAi', on: true });
    assert.equal((await board.c.wait('error')).code, 'seat_taken');
    other.c.close();
    await board.c.wait('lobby', (m) => m.lobby.seats[1].taken && !m.lobby.seats[1].connected);
    board.c.send({ t: 'boardAi', on: true, deckId: decks[1].id, ms: 0 });
    let lb = (await board.c.wait('lobby', (m) => !!m.lobby.boardAi)).lobby;
    assert.equal(lb.aiDeck, decks[1].id);
    assert.deepEqual([lb.seats[1].device, lb.seats[1].ready, lb.seats[1].connected], ['AI', true, true]);
    // 플레이어 2 의 옛 토큰으로는 AI 자리를 가져갈 수 없음
    const stale = await connect(srv.port, { role: 'player', code, dataVersion: srv.catalog.dataVersion });
    assert.equal((stale.first as Extract<ServerMsg, { t: 'error' }>).code, 'full');
    stale.c.close();

    // 폰이 준비 → 카운트다운 → 게임, 셋업은 폰만 답하면 AI 가 알아서 진행
    const p = human.c;
    p.send({ t: 'chooseDeck', deckId: decks[0].id });
    p.send({ t: 'ready', ready: true });
    await board.c.wait('lobby', (m) => m.lobby.phase === 'countdown');
    await board.c.wait('lobby', (m) => m.lobby.phase === 'game', 6000);
    for (let i = 0; i < 100 && srv.session.game!.state.phase === 'setup'; i++) {
      const v = p.last('state')?.view;
      if (v) answer(p, v);
      await new Promise((r) => setTimeout(r, 50));
    }
    assert.equal(srv.session.game!.state.phase, 'playing');
    assert.equal(srv.session.game!.config.players[1].deckId, decks[1].id);

    // 끝나기 전에는 다시 하기 불가, 항복 → 끝 → 게임판에서 다시 하기
    board.c.send({ t: 'rematch' });
    assert.equal((await board.c.wait('error')).code, 'in_game');
    p.send({ t: 'input', input: { type: 'concede' } });
    await board.c.wait('state', (m) => !!m.view.result);
    const since = board.c.msgs.length;
    board.c.send({ t: 'rematch' });
    lb = (await board.c.wait('lobby', (m) => m.lobby.phase === 'lobby' && board.c.msgs.indexOf(m) >= since)).lobby;
    assert.equal(lb.boardAi, true);
    assert.deepEqual([lb.seats[0].ready, lb.seats[1].ready, lb.seats[1].deckId], [false, true, decks[1].id]);

    // 서버 재시작 → AI 자리 유지, 끄면 빈자리
    for (const c of [board.c, p]) c.close();
    await srv.close();
    srv = await startServer({ port: 0, dataDir, beacon: false, quiet: true, aiDelayMs: 0 });
    const b2 = await connect(srv.port, { role: 'board' });
    lb = (await b2.c.wait('lobby')).lobby;
    assert.equal(lb.boardAi, true);
    assert.equal(lb.seats[1].ready, true);
    b2.c.send({ t: 'boardAi', on: false });
    lb = (await b2.c.wait('lobby', (m) => !m.lobby.boardAi)).lobby;
    assert.equal(lb.seats[1].taken, false);
    b2.c.close();
  } finally {
    await srv.close();
    rmSync(dataDir, { recursive: true, force: true });
  }
});

test('게임판: 연결이 끊긴 플레이어 내보내기 (접속 중·게임 중에는 불가)', { timeout: 30000 }, async () => {
  const srv = await startServer({ port: 0, dataDir: null, beacon: false, quiet: true });
  try {
    const code = srv.session.code;
    const board = await connect(srv.port, { role: 'board' });
    const p1 = await connect(srv.port, { role: 'player', code, device: 'a' });
    const p2 = await connect(srv.port, { role: 'player', code, device: 'b' });
    const t2 = (p2.first as Extract<ServerMsg, { t: 'welcome' }>).token!;
    board.c.send({ t: 'kick', seat: 1 });
    assert.equal((await board.c.wait('error')).code, 'connected');
    p2.c.close();
    await board.c.wait('lobby', (m) => m.lobby.seats[1].taken && !m.lobby.seats[1].connected);
    board.c.send({ t: 'kick', seat: 1 });
    await board.c.wait('lobby', (m) => !m.lobby.seats[1].taken);
    // 내보낸 기기의 옛 토큰은 무효 → 코드로 새로 참가하면 빈자리에 앉음
    const back = await connect(srv.port, { role: 'player', token: t2, code, device: 'b' });
    const wb = back.first as Extract<ServerMsg, { t: 'welcome' }>;
    assert.equal(wb.seat, 1);
    assert.notEqual(wb.token, t2);
    for (const c of [board.c, p1.c, back.c]) c.close();
  } finally {
    await srv.close();
  }
});
