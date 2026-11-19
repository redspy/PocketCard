import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randInt, seedRng, shuffleInPlace } from '../../src/game/rng.ts';
import type { GameState, Seat } from '../../src/game/types.ts';
import {
  applyInput, checkEventsNoLeak, checkInvariants, checkNoLeak, config, createGame, deckIds, GameError, info, playRandom, viewFor,
} from './helpers.ts';

const seedOf = (n: number) => n.toString(16).padStart(32, 'a');

test('난수: 같은 시드면 같은 결과, 셔플은 순열', () => {
  const a = seedRng(seedOf(1)), b = seedRng(seedOf(1)), c = seedRng(seedOf(2));
  const xs = Array.from({ length: 50 }, () => randInt(a, 1000));
  const ys = Array.from({ length: 50 }, () => randInt(b, 1000));
  const zs = Array.from({ length: 50 }, () => randInt(c, 1000));
  assert.deepEqual(xs, ys);
  assert.notDeepEqual(xs, zs);
  assert.ok(xs.every((x) => x >= 0 && x < 1000));
  const arr = Array.from({ length: 60 }, (_, i) => i);
  shuffleInPlace(a, arr);
  assert.deepEqual([...arr].sort((p, q) => p - q), Array.from({ length: 60 }, (_, i) => i));
});

test('덱 데이터: 9개 덱 모두 60장, 기본 포켓몬 있음', () => {
  assert.equal(deckIds.length, 9);
  for (const id of deckIds) {
    const g = createGame(config(seedOf(3), id, id), info).state;
    assert.equal(g.players[0].deck.length, 60, id);
  }
});

test('셋업: 코인 → 선공 선택 → 7장 → 배틀/벤치 → 사이드 6장 → 선공 첫 턴 드로우', () => {
  for (let k = 0; k < 30; k++) {
    const a = deckIds[k % deckIds.length], b = deckIds[(k * 5 + 1) % deckIds.length];
    const run = playRandom(seedOf(100 + k), a, b, 60);
    const s = run.states.find((x) => x.phase !== 'setup');
    assert.ok(s, `셋업이 끝나지 않음 (${a} vs ${b})`);
    if (s.phase === 'playing') {
      for (const seat of [0, 1] as Seat[]) {
        assert.ok(s.players[seat].active, '배틀 포켓몬 있음');
        assert.equal(s.players[seat].prizes.filter(Boolean).length, 6, '사이드 6장');
        assert.equal(s.players[seat].active!.faceDown, false, '앞면');
      }
      assert.equal(s.turnPlayer, s.firstPlayer);
      assert.equal(s.turnNumber, 1);
    }
  }
});

test('불변식: 무작위 플레이 내내 카드 60장 보존, iid 중복 없음', () => {
  for (let k = 0; k < 40; k++) {
    const run = playRandom(seedOf(500 + k), deckIds[k % deckIds.length], deckIds[(k + 2) % deckIds.length]);
    for (const s of run.states) checkInvariants(s, [60, 60]);
  }
});

test('결정성: 같은 시드 + 같은 입력이면 같은 상태 (리플레이 복원)', () => {
  const run = playRandom(seedOf(777), 'dragapult', 'gardevoir');
  let s: GameState = createGame(run.config, info).state;
  for (const input of run.inputs) s = applyInput(s, input, info).state;
  assert.equal(JSON.stringify(s), JSON.stringify(run.states.at(-1)));
});

test('누출: 숨겨진 카드를 뒤섞어도 각 시점의 보기는 같다 (상태 + 이벤트)', () => {
  const r = seedRng(seedOf(9));
  let checked = 0;
  for (let k = 0; k < 25; k++) {
    const run = playRandom(seedOf(900 + k), deckIds[k % deckIds.length], deckIds[(k + 3) % deckIds.length], 150);
    run.states.forEach((s, i) => {
      for (const v of [0, 1, 'board'] as const) {
        checkNoLeak(s, v, r);
        checkEventsNoLeak(run.events[i], v);
        checked++;
      }
    });
  }
  assert.ok(checked > 1000);
});

test('보기: 게임판은 패 내용을 모르고, 플레이어는 자기 패만 안다', () => {
  const run = playRandom(seedOf(31), 'charizard', 'pachirisu', 80);
  const s = run.states.at(-1)!;
  const board = viewFor(s, 'board', info);
  assert.equal(board.players[0].hand, null);
  assert.equal(board.players[1].hand, null);
  const p1 = viewFor(s, 0, info);
  assert.equal(p1.players[0].hand?.length, s.players[0].hand.length);
  assert.equal(p1.players[1].hand, null);
  for (const r of p1.requests) if (r.player !== 0) assert.equal(r.options, undefined, '남의 선택지는 안 보임');
});

test('잘못된 입력은 거절되고 상태는 그대로', () => {
  const s0 = createGame(config(seedOf(5), 'flareon', 'gholdengo'), info).state;
  const req = s0.requests[0];
  const wrong: Seat = req.player === 0 ? 1 : 0;
  const snapshot = JSON.stringify(s0);
  assert.throws(() => applyInput(s0, { type: 'choice', player: wrong, requestId: req.id, picks: ['first'] }, info), GameError);
  assert.throws(() => applyInput(s0, { type: 'choice', player: req.player, requestId: req.id, picks: ['middle'] }, info), GameError);
  assert.throws(() => applyInput(s0, { type: 'endTurn', player: 0 }, info), GameError);
  assert.equal(JSON.stringify(s0), snapshot);
});

test('덱 아웃: 턴 시작에 드로우하지 못하면 패배', () => {
  const run = playRandom(seedOf(42), 'dragapult', 'gardevoir', 0);
  let s = run.states[0];
  // 셋업을 무작위로 끝낸 뒤, 다음 턴 플레이어의 덱을 비워 둔다
  const done = playRandom(seedOf(42), 'dragapult', 'gardevoir', 40).states.find((x) => x.phase === 'playing' && x.requests.length === 0);
  assert.ok(done);
  s = structuredClone(done);
  const next: Seat = s.turnPlayer === 0 ? 1 : 0;
  // 덱 카드를 트래쉬로 옮겨 카드 수는 유지
  s.players[next].discard.push(...s.players[next].deck);
  s.players[next].deck = [];
  const res = applyInput(s, { type: 'endTurn', player: s.turnPlayer! }, info);
  assert.equal(res.state.phase, 'ended');
  assert.equal(res.state.result?.winner, s.turnPlayer);
});
