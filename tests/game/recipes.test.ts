// 공식 덱 레시피 2종(블래키 VMAX · 기라티나 VSTAR)의 새 규칙: V/VMAX/VSTAR/GX 사이드, GX·VSTAR 1번, 로스트존,
// 일격 에너지, 벤치배리어, 정상으로 가는 눈길, 효과 무시 데미지, 옛 저항력(−20), 히스이의 헤비볼 등
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { buildCatalog, buildDeck, cardInfo } from '../../src/game/catalog.ts';
import type { RawDecks } from '../../src/game/catalog.ts';
import { prizeValue } from '../../src/game/cardData.ts';
import { applyInput, countCards, createGame, legalMoves } from '../../src/game/engine.ts';
import { newSlot } from '../../src/game/core.ts';
import type { CardInfo, GameState, PokemonSlot, Seat } from '../../src/game/types.ts';

// 덱 뷰어 전용 덱도 포함한 카탈로그 (playable 무시)
const raw = JSON.parse(readFileSync(fileURLToPath(new URL('../../godot/data/decks.json', import.meta.url)), 'utf8')) as RawDecks & { decks: { playable?: boolean }[] };
for (const d of raw.decks) delete d.playable;
const cat = buildCatalog(raw);
const info: CardInfo = cardInfo(cat, JSON.parse(readFileSync(fileURLToPath(new URL('../../src/data/rules/cards.json', import.meta.url)), 'utf8')));

type Side = { active: string; bench?: string[]; energy?: string[]; benchEnergy?: string[][]; hand?: string[]; tool?: string; damage?: number; lost?: number };
function scenario(decks: [string, string], a: Side, b: Side, opts: { stadium?: [Seat, string] } = {}): GameState {
  const s = createGame({ seed: 'ab'.repeat(16), players: [{ deckId: decks[0], cards: buildDeck(cat, decks[0]) }, { deckId: decks[1], cards: buildDeck(cat, decks[1]) }] }, info).state;
  s.requests = []; s.reveals = []; s.setup = null; s.phase = 'playing';
  s.firstPlayer = 0; s.turnPlayer = 0; s.turnNumber = 5;
  const take = (seat: Seat, id: string): string => {
    const p = s.players[seat];
    for (const zone of [p.deck, p.hand]) {
      const i = zone.findIndex((iid) => s.cards[iid].ruleId === id);
      if (i >= 0) return zone.splice(i, 1)[0];
    }
    throw new Error(`덱에 ${id} 없음 (${seat})`);
  };
  let stadium: string | null = null;
  for (const [seat, spec] of [[0, a], [1, b]] as [Seat, Side][]) {
    const p = s.players[seat];
    p.turns = 3;
    p.deck.push(...p.hand); p.hand = [];
    if (opts.stadium && opts.stadium[0] === seat) stadium = take(seat, opts.stadium[1]);
    // 패를 덱으로 (시나리오가 정한 패만 쓰게)
    p.deck.push(...p.hand); p.hand = [];
    if (p.active) { p.deck.push(...p.active.stack, ...p.active.attached); p.active = null; }
    for (const b2 of p.bench) p.deck.push(...b2.stack, ...b2.attached);
    p.bench = [];
    const mk = (id: string, ens: string[] = []): PokemonSlot => {
      const sl = newSlot(s, take(seat, id));
      sl.enteredTurn = 1;
      for (const e of ens) sl.attached.push(take(seat, e));
      return sl;
    };
    p.active = mk(spec.active, spec.energy);
    if (spec.damage) p.active.damage = spec.damage;
    if (spec.tool) p.active.attached.push(take(seat, spec.tool));
    p.bench = (spec.bench ?? []).map((id, i) => mk(id, spec.benchEnergy?.[i]));
    for (const h of spec.hand ?? []) p.hand.push(take(seat, h));
    // 사이드: 트레이너스 6장 / 로스트존: 덱 아래 카드 n장
    const tr = p.deck.filter((iid) => info.db[s.cards[iid].ruleId].kind === 'trainer').slice(-6);
    p.deck = p.deck.filter((iid) => !tr.includes(iid));
    p.prizes = tr;
    if (spec.lost) p.lost = p.deck.splice(p.deck.length - spec.lost, spec.lost);
  }
  if (stadium) s.stadium = stadium;
  return s;
}
const act = (s: GameState, seat: Seat, input: Record<string, unknown>) => applyInput(s, { ...input, player: seat } as never, info);
const atk = (s: GameState, seat: Seat, name: string) => {
  const d = info.db[s.cards[s.players[seat].active!.stack.at(-1)!].ruleId];
  const i = d.pokemon!.attacks.findIndex((x) => x.nameJa === name);
  assert.ok(i >= 0, `기술 ${name} 없음`);
  return i;
};
/** 남은 선택 요청을 앞쪽 선택지로 처리 */
function settle(s: GameState): GameState {
  for (let i = 0; i < 60 && s.requests.length; i++) {
    const r = s.requests[0];
    s = applyInput(s, { type: 'choice', player: r.player, requestId: r.id, picks: r.options.slice(0, Math.max(r.min, Math.min(1, r.max))) }, info).state;
  }
  return s;
}
const total = (s: GameState) => [countCards(s, 0), countCards(s, 1)];

test('룰을 가진 포켓몬의 사이드: V·VSTAR·GX 2장, VMAX 3장, 찬란한 포켓몬 1장', () => {
  const by = (id: string) => prizeValue(info.db[id]);
  assert.equal(by('S5I_036'), 2, '일격 우라오스 V');
  assert.equal(by('S5I_037'), 3, '일격 우라오스 VMAX');
  assert.equal(by('S12a_111'), 2, '기라티나 VSTAR');
  assert.equal(by('SM12_035'), 2, '춤추새 GX');
  assert.equal(by('S12a_033'), 1, '찬란한 개굴닌자');
  assert.equal(info.db.S12a_033.pokemon!.rule, null, '찬란한 포켓몬은 룰을 가진 포켓몬이 아님');
});

test('일격 에너지: 「일격」 포켓몬에게만 붙고, 격투·악 1개분 + 상대 배틀 포켓몬에게 +20', () => {
  const s = scenario(['umbreon', 'giratina'], { active: 'S6a_047', bench: ['SM12a_055'], hand: ['SGG_019'] }, { active: 'S12a_064' });
  const moves = legalMoves(s, 0, info).filter((m) => m.kind === 'attach');
  assert.ok(moves.some((m) => m.target === s.players[0].active!.sid), '블래키 V(일격)에 붙일 수 있음');
  assert.ok(!moves.some((m) => m.target === s.players[0].bench[0].sid), '뮤(일격 아님)에는 못 붙임');
  // 블래키 V 검은눈빛 [악] 30 → 일격 에너지로 비용 지불 + 20 → 큐아링(약점 강철) 50
  const s2 = scenario(['umbreon', 'giratina'], { active: 'S6a_047', energy: ['SGG_019'] }, { active: 'S12a_064' });
  const r = act(s2, 0, { type: 'attack', index: atk(s2, 0, '검은눈빛') });
  assert.equal(r.state.players[1].active!.damage, 50);
  assert.ok(r.state.players[1].active!.effects.some((e) => e.kind === 'noRetreat'), '다음 차례 후퇴 불가');
});

test('VMAX 기절 → 사이드 3장, GX 기술은 대전 중 1번', () => {
  // 기라티나 VSTAR 로스트임팩트 280 → 데미지 60 받은 일격 우라오스 VMAX(330) 기절
  const s = scenario(['giratina', 'umbreon'], { active: 'S12a_111', energy: ['SVB_029', 'SVB_033', 'SVB_031'] }, { active: 'S5I_037', damage: 60, bench: ['SGG_004'] });
  const r = act(s, 0, { type: 'attack', index: atk(s, 0, '로스트임팩트') });
  const st = settle(r.state);
  assert.equal(st.players[0].prizes.filter(Boolean).length, 3, 'VMAX 기절 = 사이드 3장 가져감');
  assert.equal(st.players[0].lost.length, 2, '에너지 2개 → 로스트존');
  assert.deepEqual(total(st), [60, 60]);
  // 춤추새 GX 뒤집기GX: 쓰고 나면 다시 못 씀
  const g = scenario(['umbreon', 'giratina'], { active: 'SM12_035', energy: ['SV1S_108', 'SV1S_108', 'SV1S_108'], bench: ['SGG_004'] }, { active: 'S12a_110' });
  // 이 덱엔 초 에너지가 없어 시험용으로 1장을 기본 초 에너지 규칙으로 바꿈
  g.cards[g.players[0].active!.attached[0]].ruleId = 'SVB_033';
  const gi = atk(g, 0, '뒤집기GX');
  assert.ok(legalMoves(g, 0, info).some((m) => m.kind === 'attack' && 'index' in m.input && m.input.index === gi));
  const after = settle(act(g, 0, { type: 'attack', index: gi }).state);
  assert.equal(after.players[0].gxUsed, true);
  assert.equal(info.db[after.cards[after.players[0].active!.stack.at(-1)!].ruleId].name, '델빌', '벤치와 교체');
  // 다시 춤추새 GX 가 배틀 포켓몬이 되어도 GX 기술은 목록에 없음
  after.turnPlayer = 0; after.players[0].flags.retreat = false;
  const oricorio = after.players[0].bench[0];
  after.players[0].bench[0] = after.players[0].active!; after.players[0].active = oricorio;
  assert.ok(!legalMoves(after, 0, info).some((m) => m.kind === 'attack' && 'index' in m.input && m.input.index === gi), 'GX 는 대전 중 1번');
});

test('VSTAR 파워: 로스트존 10장 이상일 때 스타레퀴엠으로 기절, 대전 중 1번', () => {
  const base = { active: 'S12a_111', energy: ['SVB_029', 'SVB_033'] };
  const s9 = scenario(['giratina', 'umbreon'], { ...base, lost: 9 }, { active: 'S6a_048', bench: ['SGG_004'] });
  const si = atk(s9, 0, '스타레퀴엠');
  assert.ok(!legalMoves(s9, 0, info).some((m) => m.kind === 'attack' && 'index' in m.input && m.input.index === si), '9장이면 못 씀');
  const s10 = scenario(['giratina', 'umbreon'], { ...base, lost: 10 }, { active: 'S6a_048', bench: ['SGG_004'] });
  const r = act(s10, 0, { type: 'attack', index: si });
  assert.ok(r.events.some((e) => e.type === 'ko' && 'prizes' in e && e.prizes === 3), '블래키 VMAX 기절 → 3장');
  assert.equal(r.state.players[0].vstarUsed, true);
});

test('로스트존: 어비스시크(4장 보고 2장 패, 나머지 로스트), 꽃고르기(배틀필드에서만), 아크로마의 실험', () => {
  const s = scenario(['giratina', 'umbreon'], { active: 'S12a_110', energy: ['SVB_033'], bench: ['S12a_064'] }, { active: 'SGG_004' });
  let st = act(s, 0, { type: 'attack', index: atk(s, 0, '어비스시크') }).state;
  st = settle(st);
  assert.equal(st.players[0].lost.length, 2);
  assert.equal(st.players[0].hand.length, 2);
  assert.deepEqual(total(st), [60, 60]);
  // 큐아링 꽃고르기: 벤치에서는 못 씀
  assert.ok(!legalMoves(s, 0, info).some((m) => m.kind === 'ability'), '벤치 큐아링은 특성 불가');
  const s2 = scenario(['giratina', 'umbreon'], { active: 'S12a_064', hand: ['S12a_155'] }, { active: 'SGG_004' });
  let st2 = act(s2, 0, { type: 'ability', sid: s2.players[0].active!.sid }).state;
  st2 = settle(st2);
  assert.equal(st2.players[0].lost.length, 1, '꽃고르기: 1장 로스트');
  const ach = st2.players[0].hand.find((i) => st2.cards[i].ruleId === 'S12a_155')!;
  st2 = settle(act(st2, 0, { type: 'play', card: ach }).state);
  assert.equal(st2.players[0].lost.length, 3, '아크로마의 실험: 5장 중 3장 패, 2장 로스트');
  assert.deepEqual(total(st2), [60, 60]);
});

test('로스트 프로바이드(4장 이상 → 비용 없음)·와일드스타일(상대 일격 포켓몬 수만큼 무색 감소)', () => {
  const s3 = scenario(['giratina', 'umbreon'], { active: 'S11_033', lost: 3 }, { active: 'SGG_004' });
  assert.ok(!legalMoves(s3, 0, info).some((m) => m.kind === 'attack'), '3장: 에너지 없으면 기술 불가');
  const s4 = scenario(['giratina', 'umbreon'], { active: 'S11_033', lost: 4 }, { active: 'SGG_004' });
  assert.ok(legalMoves(s4, 0, info).some((m) => m.kind === 'attack'), '4장: 에너지 없이 시치미스핏');
  // 드래피온 V 다이내믹테일 [무무무무]: 상대 필드에 일격 포켓몬 3마리 → 무색 1개로
  const d = scenario(['giratina', 'umbreon'], { active: 'S12a_085', energy: ['SVB_029'] }, { active: 'SGG_004', bench: ['SGG_004', 'S6a_047'] });
  assert.ok(legalMoves(d, 0, info).some((m) => m.kind === 'attack' && 'index' in m.input && m.input.index === atk(d, 0, '다이내믹테일')));
});

test('벤치배리어·파도의 베일: 상대 기술의 데미지를 벤치가 받지 않음 (카운터는 올라감)', () => {
  // 찬란한 개굴닌자 월광수리검: 상대 2마리에 90 → 뮤가 있으면 벤치는 0
  const s = scenario(['giratina', 'umbreon'], { active: 'S12a_033', energy: ['SVB_031', 'SVB_031', 'SVB_033'] }, { active: 'S6a_047', bench: ['SM12a_055', 'SGG_004'] });
  let st = act(s, 0, { type: 'attack', index: atk(s, 0, '월광수리검') }).state;
  // 에너지 2개 고르기 → 대상 2마리 (배틀 + 벤치 델빌)
  const r1 = st.requests[0];
  st = applyInput(st, { type: 'choice', player: 0, requestId: r1.id, picks: r1.options.slice(0, 2) }, info).state;
  const r2 = st.requests[0];
  const target = [st.players[1].active!.sid, st.players[1].bench[1].sid];
  st = applyInput(st, { type: 'choice', player: 0, requestId: r2.id, picks: target }, info).state;
  assert.equal(st.players[1].active!.damage, 90);
  assert.equal(st.players[1].bench[1].damage, 0, '뮤 벤치배리어');
  // 깜까미 로스트마인: 카운터는 벤치에도
  const m = scenario(['giratina', 'umbreon'], { active: 'S11_044', energy: ['SVB_033'], lost: 10 }, { active: 'S6a_047', bench: ['SM12a_055', 'SGG_004'] });
  let mt = act(m, 0, { type: 'attack', index: atk(m, 0, '로스트마인') }).state;
  const devil = mt.players[1].bench[1].sid;
  for (let i = 0; i < 12 && mt.requests.length; i++) { const r = mt.requests[0]; mt = applyInput(mt, { type: 'choice', player: 0, requestId: r.id, picks: [i < 2 ? devil : mt.players[1].active!.sid] }, info).state; }
  assert.equal(mt.players[1].bench.find((b) => b.sid === devil)!.damage, 20, '벤치에도 데미지 카운터는 올라감');
  assert.equal(mt.players[1].active!.damage, 100, '나머지 10개는 배틀 포켓몬');
});

test('정상으로 가는 눈길: 룰을 가진 포켓몬의 특성 없음 / 옛 저항력 −20 / 효과를 계산하지 않는 데미지', () => {
  // 블래키 VMAX 다크시그널(룰 있음)은 눈길이 있으면 발동 안 함 → 진화해도 상대 교체 질문 없음
  const s = scenario(['umbreon', 'giratina'], { active: 'S6a_047', hand: ['S6a_048'] }, { active: 'S12a_064', bench: ['S11_033'] }, { stadium: [1, 'SVB_027'] });
  const evo = s.players[0].hand[0];
  const r = act(s, 0, { type: 'play', card: evo, target: s.players[0].active!.sid });
  assert.equal(r.state.requests.length, 0, '특성 없음');
  const s2 = scenario(['umbreon', 'giratina'], { active: 'S6a_047', hand: ['S6a_048'] }, { active: 'S12a_064', bench: ['S11_033'] });
  const r2 = act(s2, 0, { type: 'play', card: s2.players[0].hand[0], target: s2.players[0].active!.sid });
  assert.ok(r2.state.requests.length > 0, '눈길이 없으면 다크시그널 질문');
  // 춤추새 GX 저항력 격투 −20: 일격 우라오스 V 임팩트블로 180 → 160
  const s3 = scenario(['umbreon', 'giratina'], { active: 'S5I_036', energy: ['SV1S_108', 'SV1S_108', 'SV1S_108'] }, { active: 'S12a_110' });
  void s3;
  const s4 = scenario(['umbreon', 'umbreon'], { active: 'S5I_036', energy: ['SV1S_108', 'SV1S_108', 'SV1S_108'] }, { active: 'SM12_035' });
  const r4 = act(s4, 0, { type: 'attack', index: atk(s4, 0, '임팩트블로') });
  assert.equal(r4.state.players[1].active!.damage, 160);
  assert.ok(r4.state.players[0].active!.effects.some((e) => e.kind === 'lockAttack' && e.name === '임팩트블로'));
});

test('히스이의 헤비볼: 사이드의 기본 포켓몬과 바꿔 패로, 사이드 수 유지', () => {
  const s = scenario(['giratina', 'umbreon'], { active: 'S12a_064', hand: ['SVB_016'] }, { active: 'SGG_004' });
  // 사이드 한 칸에 기본 포켓몬(윽우지) 넣기
  const p = s.players[0];
  const i = p.deck.findIndex((iid) => s.cards[iid].ruleId === 'S11_033');
  const mon = p.deck.splice(i, 1)[0];
  p.deck.push(p.prizes[0]!);
  p.prizes[0] = mon;
  const ball = p.hand.find((x) => s.cards[x].ruleId === 'SVB_016')!;
  let st = act(s, 0, { type: 'play', card: ball }).state;
  const req = st.requests.find((r) => r.player === 0)!;
  st = applyInput(st, { type: 'choice', player: 0, requestId: req.id, picks: req.options.slice(0, 1) }, info).state;
  const p2 = st.players[0];
  assert.ok(p2.hand.some((x) => st.cards[x].ruleId === 'S11_033'), '윽우지를 패로');
  assert.equal(p2.prizes.filter(Boolean).length, 6, '사이드 6장 유지');
  assert.ok(p2.prizes.some((x) => x && st.cards[x].ruleId === 'SVB_016'), '헤비볼이 사이드로');
  assert.deepEqual(total(st), [60, 60]);
});

// ── 2023 코리안리그 시즌3 마스터 우승 가디안 ex (gardevoir23) ──
/** seat 의 첫 요청에 picks 로 답한다 (picks 가 함수면 요청을 보고 고름) */
function answer(s: GameState, seat: Seat, picks: string[] | ((r: GameState['requests'][number]) => string[])): GameState {
  const r = s.requests.find((x) => x.player === seat);
  assert.ok(r, `플레이어 ${seat} 의 요청 없음`);
  return applyInput(s, { type: 'choice', player: seat, requestId: r.id, picks: typeof picks === 'function' ? picks(r) : picks }, info).state;
}
const handOf = (s: GameState, seat: Seat, id: string) => s.players[seat].hand.find((x) => s.cards[x].ruleId === id)!;
const first = (r: GameState['requests'][number]) => r.options.slice(0, 1);

test('신오신전: 특수 에너지는 무색 1개분 (일격 에너지의 악 대신·+20 없음)', () => {
  const side = { active: 'S6a_047', energy: ['SGG_019'] };
  const plainS = scenario(['umbreon', 'gardevoir23'], side, { active: 'S9a_032' });
  assert.ok(legalMoves(plainS, 0, info).some((m) => m.kind === 'attack'), '스타디움이 없으면 일격 에너지로 검은눈빛 [악]');
  const temple = scenario(['umbreon', 'gardevoir23'], side, { active: 'S9a_032' }, { stadium: [1, 'S12a_166'] });
  assert.ok(!legalMoves(temple, 0, info).some((m) => m.kind === 'attack'), '신오신전: 일격 에너지가 무색이라 [악] 비용을 못 냄');
});

test('무너진 스타디움: 벤치 4마리 — 낼 때 넘치는 포켓몬은 주인부터 트래쉬', () => {
  const s = scenario(['gardevoir23', 'umbreon'], { active: 'S8a_002', bench: ['S11a_036', 'S9a_032', 'S9a_032', 'S10D_028', 'S12a_067'], hand: ['S12a_165', 'S9a_032'] }, { active: 'SGG_004' });
  let st = act(s, 0, { type: 'play', card: handOf(s, 0, 'S12a_165') }).state;
  assert.equal(st.players[0].benchMax, 4);
  st = answer(st, 0, first);
  assert.equal(st.players[0].bench.length, 4, '1마리 트래쉬');
  assert.ok(!legalMoves(st, 0, info).some((m) => m.kind === 'play'), '벤치가 4마리면 더 낼 수 없음');
  assert.deepEqual(total(st), [60, 60]);
});

test('하늘의 봉인석 스타오더: 기본 포켓몬 V 로 VMAX 를 기절시키면 사이드 +1 (VSTAR 파워 1번)', () => {
  const s = scenario(['gardevoir23', 'umbreon'], { active: 'S12a_067', energy: ['SVB_033', 'SVB_033', 'SVB_033'], tool: 'S12a_147' }, { active: 'S6a_048', damage: 200, bench: ['SGG_004'] });
  const star = legalMoves(s, 0, info).find((m) => m.kind === 'ability' && (m.input as { tool?: boolean }).tool);
  assert.ok(star, '봉인석 VSTAR 파워');
  let st = act(s, 0, star!.input).state;
  assert.ok(st.players[0].vstarUsed);
  assert.ok(!legalMoves(st, 0, info).some((m) => (m.input as { tool?: boolean }).tool), '대전 중 1번');
  st = act(st, 0, { type: 'attack', index: atk(st, 0, '스톰슬래시') }).state;   // 60 + 초 에너지 3개 × 30 = 150 ≥ 남은 110
  const take = st.requests.find((r) => r.kind === 'takePrize')!;
  assert.equal(take.min, 4, 'VMAX 3장 + 스타오더 1장');
});

test('메모리스킵: 고른 기술은 상대의 다음 차례에 못 씀 (다른 기술은 씀)', () => {
  const s = scenario(['gardevoir23', 'umbreon'], { active: 'S11a_036', energy: ['SVB_033'] }, { active: 'S6a_047', energy: ['SGG_019', 'SGG_019', 'SGG_019'] });
  let st = act(s, 0, { type: 'attack', index: atk(s, 0, '메모리스킵') }).state;
  st = answer(st, 0, ['1']);   // 월광의칼날
  assert.equal(st.turnPlayer, 1);
  const labels = legalMoves(st, 1, info).filter((m) => m.kind === 'attack').map((m) => m.label);
  assert.ok(labels.some((l) => l.includes('검은눈빛')), labels.join(','));
  assert.ok(!labels.some((l) => l.includes('월광의칼날')), labels.join(','));
});

test('가디안 아르카나 샤인 · 킬리아 리파인 · 네오라이트 V 루미너스사인 · 자시안 V 검의 포효(차례 끝)', () => {
  // 아르카나 샤인: 덱 위 2장 = [에너지, 트레이너스] → 에너지는 붙이고 나머지는 패로
  const s = scenario(['gardevoir23', 'umbreon'], { active: 'S8b_196', bench: ['S11a_037'] }, { active: 'SGG_004' });
  const p = s.players[0];
  const en = p.deck.splice(p.deck.findIndex((x) => s.cards[x].ruleId === 'SVB_033'), 1)[0];
  const tr = p.deck.splice(p.deck.findIndex((x) => info.db[s.cards[x].ruleId].kind === 'trainer'), 1)[0];
  p.deck.unshift(en, tr);
  const hand0 = p.hand.length;
  let st = act(s, 0, legalMoves(s, 0, info).find((m) => m.kind === 'ability' && m.target === s.players[0].active!.sid)!.input).state;
  st = answer(st, 0, first);                              // 에너지 고르기
  st = answer(st, 0, [st.players[0].active!.sid]);        // 붙일 포켓몬
  assert.equal(st.players[0].active!.attached.length, 1, '에너지 붙음');
  assert.equal(st.players[0].hand.length, hand0 + 1, '남은 1장은 패로');
  // 리파인: 패 1장 트래쉬 → 2장 뽑기
  const kir = legalMoves(st, 0, info).find((m) => m.kind === 'ability' && m.target === st.players[0].bench[0].sid)!;
  const h1 = st.players[0].hand.length;
  st = act(st, 0, kir.input).state;
  st = answer(st, 0, first);
  assert.equal(st.players[0].hand.length, h1 + 1);
  // 루미너스사인: 패에서 벤치로 내면 덱의 서포트를 패로
  const s2 = scenario(['gardevoir23', 'umbreon'], { active: 'S8a_002', hand: ['SVB_008'] }, { active: 'SGG_004' });
  let st2 = act(s2, 0, { type: 'play', card: handOf(s2, 0, 'SVB_008') }).state;
  st2 = answer(st2, 0, ['yes']);
  st2 = answer(st2, 0, first);
  assert.ok(st2.players[0].hand.some((x) => info.db[st2.cards[x].ruleId].trainer === 'supporter'), '서포트를 패로');
  // 검의 포효: 덱의 초 에너지를 붙이고 차례가 끝남
  const s3 = scenario(['gardevoir23', 'umbreon'], { active: 'S12a_067' }, { active: 'SGG_004' });
  let st3 = act(s3, 0, legalMoves(s3, 0, info).find((m) => m.kind === 'ability')!.input).state;
  st3 = answer(st3, 0, first);
  st3 = answer(st3, 0, [st3.players[0].active!.sid]);
  assert.equal(st3.players[0].active!.attached.length, 1);
  assert.equal(st3.turnPlayer, 1, '차례가 끝남');
});

test('세레나(포켓몬 V 끌어내기) · 모란(기본 포켓몬과 붙은 카드를 패로) · 아쿠아리턴(덱으로 되돌리고 새 배틀 포켓몬)', () => {
  const s = scenario(['gardevoir23', 'umbreon'], { active: 'S9a_032', hand: ['SVB_021'] }, { active: 'SGG_004', bench: ['S6a_047'] });
  let st = act(s, 0, { type: 'play', card: handOf(s, 0, 'SVB_021') }).state;
  st = answer(st, 0, ['gust']);
  st = answer(st, 0, first);
  assert.equal(info.db[st.cards[st.players[1].active!.stack[0]].ruleId].name, '블래키 V');
  const s2 = scenario(['gardevoir23', 'umbreon'], { active: 'S9a_032', bench: ['S12a_067'], benchEnergy: [['SVB_033']], hand: ['SV1S_074'] }, { active: 'SGG_004' });
  let st2 = act(s2, 0, { type: 'play', card: handOf(s2, 0, 'SV1S_074') }).state;
  st2 = answer(st2, 0, [st2.players[0].bench[0].sid]);
  assert.equal(st2.players[0].bench.length, 0);
  assert.ok(st2.players[0].hand.some((x) => st2.cards[x].ruleId === 'S12a_067') && st2.players[0].hand.some((x) => st2.cards[x].ruleId === 'SVB_033'), '포켓몬과 에너지 모두 패로');
  assert.deepEqual(total(st2), [60, 60]);
  const s3 = scenario(['gardevoir23', 'umbreon'], { active: 'SVB_008', energy: ['SVB_033', 'SVB_033', 'SVB_033'], bench: ['S9a_032'] }, { active: 'SGG_004', bench: ['SGG_004'] });
  // 이 덱에는 물 에너지가 없으므로 붙은 에너지 1장을 기본 물 에너지(기라티나 덱의 인쇄)로 바꿔서 [물] 비용을 맞춘다
  const w = s3.players[0].active!.attached[0];
  s3.cards[w] = { ...s3.cards[w], ruleId: 'SVB_031', code: 'SVB_031' };
  const deck0 = s3.players[0].deck.length;
  let st3 = act(s3, 0, { type: 'attack', index: atk(s3, 0, '아쿠아리턴') }).state;
  st3 = settle(st3);
  assert.equal(st3.players[0].deck.length, deck0 + 4 - 0, '포켓몬 + 에너지 3장이 덱으로');
  assert.equal(info.db[st3.cards[st3.players[0].active!.stack[0]].ruleId].name, '랄토스', '벤치의 포켓몬이 배틀로');
  assert.deepEqual(total(st3), [60, 60]);
});
