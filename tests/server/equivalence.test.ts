// 동등성: 같은 시드 + 같은 입력이면 실제 서버(ws)와 브라우저 데모(LocalHost)가 시점별로 똑같은 메시지를 보낸다.
// (데모 경로와 실제 경로가 갈라지는 것을 막는 핵심 테스트)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startServer } from '../../server/main.ts';
import { PROTOCOL_VERSION } from '../../src/game/protocol.ts';
import type { ClientInput, ServerMsg } from '../../src/game/protocol.ts';
import type { GameInput } from '../../src/game/types.ts';
import { LocalHost } from '../../src/play/localHost.ts';
import { catalog, info } from '../game/helpers.ts';

const SEED = 'c0ffee00c0ffee00c0ffee00c0ffee00';
const DECKS: [string, string] = ['dragapult', 'gardevoir'];
const toClient = (i: GameInput): ClientInput => { const { player: _p, ...rest } = i; return rest as ClientInput; };
const gameMsgs = (list: ServerMsg[]) => list.filter((m) => m.t === 'events' || m.t === 'state');

test('실제 서버와 데모 호스트의 시점별 메시지가 같다', { timeout: 60000 }, async () => {
  // 1) 데모: 봇 둘로 한 판 (입력 열 확보) — 메시지는 연결로 받는다
  const ref = new LocalHost(catalog, info.db, { seed: SEED, decks: DECKS, controllers: ['bot', 'bot'] });
  for (let i = 0; i < 400 && ref.match.state.phase !== 'ended' && ref.step(); i++) { /* 진행 */ }
  const inputs = ref.exportLog().inputs.slice(0, 120);

  const local = new LocalHost(catalog, info.db, { seed: SEED, decks: DECKS, controllers: ['human', 'human'] });
  const lgot: Record<string, ServerMsg[]> = { 0: [], 1: [], board: [] };
  const lconn = (['board', 0, 1] as const).map((v) => {
    const c = local.connect(v);
    c.subscribe((m) => lgot[String(v)].push(m));
    c.onStatus((s) => { if (s === 'open') c.send({ t: 'hello', protocol: PROTOCOL_VERSION, role: v === 'board' ? 'board' : 'player' }); });
    return c;
  });
  await new Promise((r) => setTimeout(r, 10));
  for (const k of Object.keys(lgot)) lgot[k] = [];      // 접속 인사는 비교에서 제외
  for (const i of inputs) { lconn[i.player + 1].send({ t: 'input', input: toClient(i) }); await new Promise((r) => setTimeout(r, 0)); }
  await new Promise((r) => setTimeout(r, 10));

  // 2) 실제 서버: 같은 시드·덱으로 시작해 같은 입력을 ws 로 보낸다
  const srv = await startServer({ port: 0, dataDir: null, beacon: false, quiet: true });
  try {
    const sgot: Record<string, ServerMsg[]> = { 0: [], 1: [], board: [] };
    const open = (who: 'board' | 0 | 1) => new Promise<WebSocket>((res) => {
      const ws = new WebSocket(`ws://127.0.0.1:${srv.port}`);
      ws.addEventListener('message', (ev) => sgot[String(who)].push(JSON.parse(String(ev.data))));
      ws.addEventListener('open', () => {
        ws.send(JSON.stringify(who === 'board' ? { t: 'hello', protocol: PROTOCOL_VERSION, role: 'board' } : { t: 'hello', protocol: PROTOCOL_VERSION, role: 'player', code: srv.session.code }));
        res(ws);
      });
    });
    const wb = await open('board');
    const w0 = await open(0);
    await new Promise((r) => setTimeout(r, 50));
    const w1 = await open(1);
    await new Promise((r) => setTimeout(r, 50));
    w0.send(JSON.stringify({ t: 'chooseDeck', deckId: DECKS[0] }));
    w1.send(JSON.stringify({ t: 'chooseDeck', deckId: DECKS[1] }));
    await new Promise((r) => setTimeout(r, 50));
    srv.session.startGame(SEED);
    await new Promise((r) => setTimeout(r, 50));
    for (const k of Object.keys(sgot)) sgot[k] = [];
    const ws = [w0, w1];
    for (const i of inputs) {
      const before = srv.session.game!.inputs.length;
      ws[i.player].send(JSON.stringify({ t: 'input', input: toClient(i) }));
      for (let t = 0; t < 200 && srv.session.game!.inputs.length === before; t++) await new Promise((r) => setTimeout(r, 2));
    }
    await new Promise((r) => setTimeout(r, 100));
    for (const c of [wb, w0, w1]) c.close();

    // 3) 비교 (events·state 만 — 로비·인사는 경로마다 다름)
    for (const v of ['board', '0', '1']) {
      const a = gameMsgs(sgot[v]), b = gameMsgs(lgot[v]);
      assert.equal(a.length, b.length, `${v}: 메시지 수 (서버 ${a.length}, 데모 ${b.length})`);
      assert.deepEqual(a, b, `${v}: 메시지 내용`);
    }
    assert.ok(gameMsgs(lgot.board).length >= inputs.length);
  } finally {
    await srv.close();
  }
});
