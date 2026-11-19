// 데모 호스트(LocalHost)와 공용 코어(Match), 봇 테스트
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Match } from '../../src/game/match.ts';
import type { ServerMsg } from '../../src/game/protocol.ts';
import { LocalHost } from '../../src/play/localHost.ts';
import { catalog, checkInvariants, info } from './helpers.ts';

const flush = () => new Promise((r) => setTimeout(r, 0));
const seedOf = (n: number) => n.toString(16).padStart(32, 'b');

/** 봇 둘이서 끝날 때까지 (자동 진행 타이머 없이 step 반복) */
function botGame(seed: string, d1: string, d2: string) {
  const h = new LocalHost(catalog, info.db, { seed, decks: [d1, d2], controllers: ['bot', 'bot'] });
  let guard = 0;
  while (h.match.state.phase !== 'ended' && guard++ < 3000) {
    if (!h.step()) break;
    checkInvariants(h.match.state, [60, 60]);
  }
  return h;
}

test('봇 대 봇: 모든 덱 조합이 셋업부터 끝까지 진행 (봇은 자기 시점만 봄)', () => {
  const ids = catalog.decks.map((d) => d.id);
  const n = ids.length;
  for (let k = 0; k < n * 3; k++) {
    const h = botGame(seedOf(k + 1), ids[k % n], ids[(k + 1 + Math.floor(k / n)) % n]);
    assert.equal(h.match.state.phase, 'ended', `시드 ${k + 1}: 끝나지 않음 (입력 ${h.match.inputs.length})`);
    assert.equal(h.error, null);
  }
});

test('되돌리기: goto(n) 상태 = n번째 입력 직후 상태', () => {
  const h = botGame(seedOf(50), 'charizard', 'pachirisu');
  const log = h.exportLog();
  const states: string[] = [];
  const m = new Match(log.config, info);
  states.push(JSON.stringify(m.state));
  for (const i of log.inputs) { m.apply(i); states.push(JSON.stringify(m.state)); }
  for (const n of [0, 1, 5, Math.floor(log.inputs.length / 2), log.inputs.length]) {
    h.goto(n);
    assert.equal(JSON.stringify(h.match.state), states[n], `goto(${n})`);
  }
  h.goto(log.inputs.length);
  h.undo(3);
  assert.equal(JSON.stringify(h.match.state), states[log.inputs.length - 3]);
  h.redo(2);
  assert.equal(JSON.stringify(h.match.state), states[log.inputs.length - 1], '다시 하기');
  assert.equal(h.hostInfo.timelineCount, log.inputs.length);
});

test('로그 내보내기 → 불러오기: 같은 상태, JSON 왕복 가능', () => {
  const h = botGame(seedOf(60), 'flareon', 'gholdengo');
  const log = JSON.parse(JSON.stringify(h.exportLog()));
  const h2 = new LocalHost(catalog, info.db);
  h2.importLog(log);
  assert.equal(JSON.stringify(h2.match.state), JSON.stringify(h.match.state));
  // 망가진 로그: 실패한 입력 직전까지 불러오고 오류를 남김
  const broken = structuredClone(log);
  broken.inputs.splice(3, 0, { type: 'endTurn', player: 0 });
  const h3 = new LocalHost(catalog, info.db);
  h3.importLog(broken);
  assert.ok(h3.error && /입력 4번째/.test(h3.error), h3.error ?? '');
  assert.equal(h3.match.inputs.length, 3);
});

test('로컬 연결: hello → welcome·catalog·lobby·state, 남의 자리 입력 불가, 게임판 입력 불가', async () => {
  const h = new LocalHost(catalog, info.db, { seed: seedOf(70), controllers: ['human', 'human'] });
  const got: Record<string, ServerMsg[]> = { 0: [], 1: [], board: [] };
  const conns = (['board', 0, 1] as const).map((v) => {
    const c = h.connect(v);
    c.subscribe((m) => got[String(v)].push(m));
    c.onStatus((s) => { if (s === 'open') c.send({ t: 'hello', protocol: 1, role: v === 'board' ? 'board' : 'player' }); });
    return c;
  });
  await flush();
  assert.deepEqual(got.board.map((m) => m.t), ['welcome', 'catalog', 'lobby', 'state']);
  const req = h.match.state.requests[0];
  const other = req.player === 0 ? 2 : 1;            // conns[1]=P1, conns[2]=P2
  conns[other].send({ t: 'input', input: { type: 'choice', requestId: req.id, picks: ['first'] } });
  conns[0].send({ t: 'input', input: { type: 'endTurn' } });
  await flush();
  assert.equal(h.match.inputs.length, 0, '거절된 입력은 기록되지 않음');
  const errs = [...got['0'], ...got['1'], ...got.board].filter((m) => m.t === 'error');
  assert.equal(errs.length, 2);
});

test('브라우저 공용 코드에 Node 전용 의존 없음', () => {
  const root = fileURLToPath(new URL('../../src/', import.meta.url));
  const files: string[] = [];
  const walk = (d: string) => { for (const f of readdirSync(d)) { const p = join(d, f); if (statSync(p).isDirectory()) walk(p); else if (/\.(ts|tsx)$/.test(f)) files.push(p); } };
  walk(join(root, 'game'));
  walk(join(root, 'play'));
  const bad = /from ['"]node:|require\(|\bprocess\.|\bBuffer\b|from ['"](fs|path|os|crypto|ws)['"]/;
  const hits = files.filter((f) => bad.test(readFileSync(f, 'utf8')));
  assert.deepEqual(hits, []);
});
