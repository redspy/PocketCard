// 규칙 시나리오 테스트: 필드를 직접 꾸며 핵심 규칙을 확인 (공식 규칙서 기준)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applyInput, createGame, legalMoves } from '../../src/game/engine.ts';
import { findSlot, newSlot } from '../../src/game/core.ts';
import type { GameState, PokemonSlot, Seat } from '../../src/game/types.ts';
import { checkInvariants, config, info } from './helpers.ts';

type SideSpec = { active: string; bench?: string[]; energy?: string[]; benchEnergy?: string[][]; hand?: string[]; tool?: string; damage?: number };

/** 덱 카드 ID(ruleId)로 필드를 꾸민다. 카드는 각자 덱에서 가져오므로 60장은 유지된다. */
function scenario(decks: [string, string], a: SideSpec, b: SideSpec, opts: { turnPlayer?: Seat; turns?: [number, number]; stadium?: [Seat, string] } = {}): GameState {
  const s = createGame(config('ab'.repeat(16), decks[0], decks[1]), info).state;
  s.requests = []; s.reveals = []; s.setup = null; s.phase = 'playing';
  s.firstPlayer = 0; s.turnPlayer = opts.turnPlayer ?? 0; s.turnNumber = 5;
  const take = (seat: Seat, ruleId: string): string => {
    const p = s.players[seat];
    const i = p.deck.findIndex((iid) => s.cards[iid].ruleId === ruleId);
    if (i < 0) throw new Error(`덱에 ${ruleId} 없음 (${seat})`);
    return p.deck.splice(i, 1)[0];
  };
  for (const [seat, spec] of [[0, a], [1, b]] as [Seat, SideSpec][]) {
    const p = s.players[seat];
    p.turns = opts.turns?.[seat] ?? 3;
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
    // 사이드: 시나리오에 쓰지 않는 트레이너스 6장 (포켓몬·에너지가 사이드로 빠지지 않게)
    const tr = p.deck.filter((iid) => info.db[s.cards[iid].ruleId].kind === 'trainer').slice(-6);
    p.deck = p.deck.filter((iid) => !tr.includes(iid));
    p.prizes = tr;
  }
  if (opts.stadium) { const [seat, id] = opts.stadium; s.stadium = take(seat, id); }
  return s;
}
const act = (s: GameState, seat: Seat, input: Record<string, unknown>) => applyInput(s, { ...input, player: seat } as never, info);
/** 남은 선택 요청을 첫 선택지로 처리 */
function settle(s: GameState): GameState {
  for (let i = 0; i < 50 && s.requests.length; i++) {
    const r = s.requests[0];
    s = applyInput(s, { type: 'choice', player: r.player, requestId: r.id, picks: r.options.slice(0, Math.max(r.min, Math.min(1, r.max))) }, info).state;
  }
  return s;
}
const attackIndex = (s: GameState, seat: Seat, ja: string) => {
  const d = info.db[s.cards[s.players[seat].active!.stack.at(-1)!].ruleId];
  return d.pokemon!.attacks.findIndex((x) => x.nameJa === ja);
};

test('약점 ×2: 악 타입 리자몽 ex 의 버닝다크 → 가디안 ex (약점 악)', () => {
  const s = scenario(['charizard', 'gardevoir'], { active: 'SV4a_349', energy: ['SV3_141', 'SV3_141'] }, { active: 'SV1S_028' });
  const r = act(s, 0, { type: 'attack', index: attackIndex(s, 0, 'バーニングダーク') });
  const dmg = r.events.find((e) => e.type === 'damage');
  assert.equal(dmg && 'amount' in dmg ? dmg.amount : 0, 360, '180 ×2 (상대가 가져간 사이드 0장) → 310HP 가디안 ex 기절');
  assert.ok(r.events.some((e) => e.type === 'ko'));
  checkInvariants(r.state, [60, 60]);
});

test('저항력 −30, 약점·저항력 무시 기술', () => {
  // 루나톤(격투) 파워젬 50 → 가디안 ex(격투 저항력 −30) = 20
  const s = scenario(['gholdengo', 'gardevoir'], { active: 'M1L_026', energy: ['SV1S_108', 'SV1S_108'], bench: ['M1L_027'] }, { active: 'SV1S_028' });
  const r = act(s, 0, { type: 'attack', index: attackIndex(s, 0, 'パワージェム') });
  assert.equal(r.state.players[1].active!.damage, 20);
  // 솔록 코스모빔: 벤치에 루나톤이 있으면 70, 약점·저항력 계산 안 함
  const s2 = scenario(['gholdengo', 'gardevoir'], { active: 'M1L_027', energy: ['SV1S_108'], bench: ['M1L_026'] }, { active: 'SV1S_028' });
  const r2 = act(s2, 0, { type: 'attack', index: attackIndex(s2, 0, 'コスモビーム') });
  assert.equal(r2.state.players[1].active!.damage, 70);
});

test('테라스탈: 벤치에서는 기술 데미지를 받지 않지만 데미지 카운터는 올라간다', () => {
  // 드래펄트 ex 팬텀다이브: 배틀 200 + 상대 벤치에 카운터 6개 (벤치의 테라스탈 오거폰도 카운터는 받음)
  const s = scenario(['dragapult', 'flareon'], { active: 'SV6_120', energy: ['SV3_141', 'SV2a_210'] }, { active: 'SV7_076', bench: ['SV6_127'] });
  let st = act(s, 0, { type: 'attack', index: attackIndex(s, 0, 'ファントムダイブ') }).state;
  st = settle(st);
  // (배틀 포켓몬이 기절해 오거폰이 새 배틀 포켓몬이 되었을 수도 있음)
  const ogerpon = [st.players[1].active, ...st.players[1].bench].find((b) => b && info.db[st.cards[b.stack[0]].ruleId].name.startsWith('오거폰'));
  assert.ok(ogerpon, '오거폰이 필드에 있음');
  assert.equal(ogerpon!.damage, 60, '카운터 6개는 테라스탈 벤치에도 올라감');
  // 기로치 ex 크루얼애로우로 벤치 테라스탈 오거폰 → 0
  const s2 = scenario(['dragapult', 'flareon'], { active: 'SV6a_089', energy: ['SV3_141', 'SV2a_210', 'SV4a_188'] }, { active: 'SV7_076', bench: ['SV6_127'] });
  let st2 = act(s2, 0, { type: 'attack', index: 0 }).state;
  const benchSid = st2.players[1].bench[0].sid;
  const req = st2.requests[0];
  st2 = applyInput(st2, { type: 'choice', player: 0, requestId: req.id, picks: [benchSid] }, info).state;
  assert.equal(findSlot(st2, benchSid)?.slot.damage ?? 0, 0, '벤치 테라스탈은 기술 데미지 0');
});

test('기절 → 사이드: ex 2장, 메가진화 ex 3장, 마지막 사이드면 승리', () => {
  // 가디안 ex 뮤 ex(ex) 를 기절시키면 2장
  const s = scenario(['charizard', 'gardevoir'], { active: 'SV4a_349', energy: ['SV3_141', 'SV3_141'] }, { active: 'SV2a_151', bench: ['M1S_040'] });
  let st = act(s, 0, { type: 'attack', index: attackIndex(s, 0, 'バーニングダーク') }).state;
  const takeReq = st.requests.find((r) => r.kind === 'takePrize');
  assert.equal(takeReq?.min, 2, 'ex 는 2장');
  // 메가디안시 ex 는 3장
  const s3 = scenario(['charizard', 'gardevoir'], { active: 'SV4a_349', energy: ['SV3_141', 'SV3_141'] }, { active: 'M2a_227', bench: ['M1S_040'], damage: 200 });
  const st3 = act(s3, 0, { type: 'attack', index: attackIndex(s3, 0, 'バーニングダーク') }).state;
  assert.equal(st3.requests.find((r) => r.kind === 'takePrize')?.min, 3, '메가진화 ex 는 3장');
  // 사이드가 1장 남았을 때 기절시키면 승리
  const s4 = scenario(['charizard', 'gardevoir'], { active: 'SV4a_349', energy: ['SV3_141', 'SV3_141'] }, { active: 'SV2a_151', bench: ['M1S_040'] });
  for (let i = 0; i < 5; i++) { s4.players[0].discard.push(s4.players[0].prizes[i]!); s4.players[0].prizes[i] = null; }
  st = settle(act(s4, 0, { type: 'attack', index: attackIndex(s4, 0, 'バーニングダーク') }).state);
  assert.equal(st.phase, 'ended');
  assert.equal(st.result?.winner, 0);
});

test('진화 제한: 첫 차례 불가, 이번 차례에 나온 포켓몬 불가', () => {
  const s = scenario(['dragapult', 'gardevoir'], { active: 'SV8a_118', hand: ['SV8a_119', 'SV8a_118'] }, { active: 'M1S_040' }, { turns: [1, 1] });
  const evo = (st: GameState) => legalMoves(st, 0, info).filter((m) => m.kind === 'evolve');
  assert.equal(evo(s).length, 0, '자신의 첫 차례에는 진화 불가');
  s.players[0].turns = 2;
  assert.equal(evo(s).length, 1, '두 번째 차례에는 진화 가능');
  // 이번 차례에 낸 드라꼰은 진화 불가
  const bench = legalMoves(s, 0, info).find((m) => m.kind === 'play')!;
  const st = applyInput(s, bench.input, info).state;
  assert.equal(evo(st).filter((m) => m.target === st.players[0].bench[0].sid).length, 0);
});

test('선공 첫 차례: 기술·서포트 불가', () => {
  const s = scenario(['gardevoir', 'dragapult'], { active: 'M1S_040', energy: ['SV2a_210'], hand: ['MC_706'] }, { active: 'SV8a_118' }, { turns: [1, 0] });
  const m = legalMoves(s, 0, info);
  assert.equal(m.filter((x) => x.kind === 'attack').length, 0);
  assert.ok(!m.some((x) => x.label.includes('릴리에의 결심')));
  s.players[0].turns = 2;
  const m2 = legalMoves(s, 0, info);
  assert.ok(m2.some((x) => x.kind === 'attack'));
  assert.ok(m2.some((x) => x.label.includes('릴리에의 결심')));
});

test('에너지 비용: 네오 어퍼 에너지는 2진화에 붙으면 모든 타입 2개', () => {
  // 드래펄트 ex 팬텀다이브 [불꽃·초]: 네오 어퍼 1장으로 충분
  const s = scenario(['dragapult', 'gardevoir'], { active: 'SV6_120', energy: ['SV5K_071'] }, { active: 'M1S_040' });
  assert.ok(legalMoves(s, 0, info).some((m) => m.kind === 'attack' && m.label.includes('스펙터다이브')));
  // 드래런치(1진화)에 붙으면 무색 1개 → [불꽃·초] 기술 불가
  const s2 = scenario(['dragapult', 'gardevoir'], { active: 'SV8a_119', energy: ['SV5K_071'] }, { active: 'M1S_040' });
  assert.ok(!legalMoves(s2, 0, info).some((m) => m.kind === 'attack'));
});

test('후퇴: 라티아스 ex 가 있으면 기본 포켓몬 후퇴 비용 0, 잠듦·마비면 후퇴 불가', () => {
  const s = scenario(['dragapult', 'gardevoir'], { active: 'SV8a_084', bench: ['SV7a_019'] }, { active: 'M1S_040' });
  const rt = legalMoves(s, 0, info).find((m) => m.kind === 'retreat');
  assert.ok(rt && rt.label.includes('비용 0'));
  s.players[0].active!.cond.rot = 'paralyzed';
  assert.ok(!legalMoves(s, 0, info).some((m) => m.kind === 'retreat'));
});

test('혼란: 뒷면이면 기술 실패 + 자신에게 카운터 3개', () => {
  let tails = 0, heads = 0;
  for (let k = 0; k < 20; k++) {
    const s = scenario(['gardevoir', 'dragapult'], { active: 'M1S_040', energy: ['SV2a_210'] }, { active: 'SV8a_118' });
    s.rng = [k * 7 + 1, k * 13 + 3, k * 17 + 5, k + 11];
    s.players[0].active!.cond.rot = 'confused';
    const st = act(s, 0, { type: 'attack', index: 1 }).state;
    const self = st.players[0].active!;
    if (self.damage === 30) { tails++; assert.equal(st.players[1].active!.damage, 0); } else { heads++; assert.equal(st.players[1].active!.damage, 10); }
  }
  assert.ok(tails > 0 && heads > 0, `앞 ${heads} 뒤 ${tails}`);
});

test('피카츄 ex 버티는 하트: HP 만땅에서 기절할 데미지를 받으면 HP 10', () => {
  const s = scenario(['charizard', 'pachirisu'], { active: 'SV4a_349', energy: ['SV3_141', 'SV3_141'] }, { active: 'SV8_033', bench: ['SV7_032'] });
  s.players[0].prizes.forEach((_, i) => { if (i < 4) { s.players[0].discard.push(s.players[0].prizes[i]!); s.players[0].prizes[i] = null; } });
  // 가져간 사이드 0 기준: 180 + 0 → 피카츄 ex 200HP 는 안 죽음. 상대가 가져간 사이드를 늘려 데미지를 키운다
  for (let i = 0; i < 3; i++) { s.players[1].discard.push(s.players[1].prizes[i]!); s.players[1].prizes[i] = null; }
  const st = act(s, 0, { type: 'attack', index: attackIndex(s, 0, 'バーニングダーク') }).state;
  assert.equal(st.players[1].active!.damage, 190, '180+90=270 이지만 HP 10 으로 남음');
});

test('제로의 대공동: 테라스탈 포켓몬이 있으면 벤치 8칸, 스타디움이 사라지면 5칸까지 트래쉬', () => {
  const s = scenario(['flareon', 'gardevoir'], { active: 'SV6_127', bench: ['SV7_076', 'SV7_076', 'SV7_076', 'SV8a_131', 'SV8a_125'], hand: ['SV8a_183', 'SV7_076'] }, { active: 'M1S_040', hand: ['SV1a_071'] });
  const play = legalMoves(s, 0, info).find((m) => m.label.includes('제로의 대공동'))!;
  let st = applyInput(s, play.input, info).state;
  assert.equal(st.players[0].benchMax, 8);
  st = applyInput(st, legalMoves(st, 0, info).find((m) => m.kind === 'play')!.input, info).state;
  assert.equal(st.players[0].bench.length, 6);
  // 상대가 보물마을로 바꾸면 5칸이 되도록 1마리 트래쉬
  st = applyInput(st, { type: 'endTurn', player: 0 }, info).state;
  st = settle(st);
  const mv = legalMoves(st, 1, info).find((m) => m.label.includes('보물마을'));
  assert.ok(mv, '보물마을을 낼 수 있음');
  st = applyInput(st, mv!.input, info).state;
  assert.ok(st.requests.some((r) => r.player === 0 && r.min === 1), '플레이어 1 이 벤치 1마리를 고름');
  st = settle(st);
  assert.equal(st.players[0].bench.length, 5);
  checkInvariants(st, [60, 60]);
});

/** 요청을 직접 고른 값으로 처리 */
function pick(s: GameState, picks: (r: GameState['requests'][0]) => string[]): GameState {
  const r = s.requests[0];
  return applyInput(s, { type: 'choice', player: r.player, requestId: r.id, picks: picks(r) }, info).state;
}

test('급류펌프: 에너지 3개를 덱으로 → 상대 벤치에 120 (약점·저항력 없음)', () => {
  const s = scenario(['flareon', 'gardevoir'], { active: 'SV6_127', energy: ['SV2P_099', 'SV1V_108', 'SV3_141'] }, { active: 'SV1S_028', bench: ['SV2a_151'] });
  const deckBefore = s.players[0].deck.length;
  let st = act(s, 0, { type: 'attack', index: attackIndex(s, 0, 'げきりゅうポンプ') }).state;
  assert.equal(st.players[1].active!.damage, 100, '배틀 100');
  st = pick(st, () => ['yes']);
  st = pick(st, (r) => r.options.slice(0, 3));
  const benchSid = st.players[1].bench[0].sid;
  st = pick(st, () => [benchSid]);
  assert.equal(findSlot(st, benchSid)?.slot.damage, 120);
  assert.equal(st.players[0].active!.attached.length, 0);
  assert.equal(st.players[0].deck.length, deckBefore + 3);
  checkInvariants(st, [60, 60]);
});

test('이상한사탕 + 리자몽 ex 연옥 지배: 파이리 → 리자몽 ex, 덱에서 기본 불꽃 에너지 3장', () => {
  const s = scenario(['charizard', 'gardevoir'], { active: 'SV2a_168', hand: ['MC_656', 'SV4a_349'] }, { active: 'M1S_040' });
  const candy = legalMoves(s, 0, info).find((m) => m.label.startsWith('이상한사탕'));
  assert.ok(candy, '이상한사탕 사용 가능');
  let st = applyInput(s, candy!.input, info).state;
  st = pick(st, (r) => [r.options[0]]);                 // 2진화 고르기
  assert.equal(info.db[st.cards[st.players[0].active!.stack.at(-1)!].ruleId].name, '리자몽 ex');
  st = pick(st, () => ['yes']);                          // 특성 사용
  const before = st.players[0].active!.attached.length;
  st = pick(st, (r) => r.options.slice(0, 3));           // 에너지 3장
  for (let i = 0; i < 3 && st.requests.length; i++) st = pick(st, () => [st.players[0].active!.sid]);
  assert.equal(st.players[0].active!.attached.length, before + 3);
  assert.ok(st.players[0].active!.attached.every((a) => info.db[st.cards[a].ruleId].energy?.type === 'R'), '모두 기본 불꽃 에너지');
  checkInvariants(st, [60, 60]);
});

test('보스의 지령: 상대 벤치 포켓몬을 배틀로 / 모야모: 서로 패를 덱 아래로, 남은 사이드만큼 드로우', () => {
  const s = scenario(['dragapult', 'gardevoir'], { active: 'SV8a_118', hand: ['MC_709', 'SV2D_068'] }, { active: 'M1S_040', bench: ['SV1S_028'], hand: ['SV2a_210'] });
  let st = applyInput(s, legalMoves(s, 0, info).find((m) => m.label.includes('보스의 지령'))!.input, info).state;
  const target = st.players[1].bench[0].sid;
  st = pick(st, () => [target]);
  assert.equal(st.players[1].active!.sid, target);
  // 서포트는 턴당 1장 → 모야모는 다음 턴에
  assert.ok(!legalMoves(st, 0, info).some((m) => m.label.includes('모야모')));
  st.players[0].flags.supporter = false;
  for (let i = 0; i < 2; i++) { st.players[1].discard.push(st.players[1].prizes[i]!); st.players[1].prizes[i] = null; }
  st = applyInput(st, legalMoves(st, 0, info).find((m) => m.label.includes('모야모'))!.input, info).state;
  assert.equal(st.players[0].hand.length, 6, '나: 사이드 6장 → 6장');
  assert.equal(st.players[1].hand.length, 4, '상대: 사이드 4장 → 4장');
  checkInvariants(st, [60, 60]);
});

test('사이코 임브레이스: 트래쉬의 기본 초 에너지를 초 포켓몬에 붙이고 카운터 2개 (몇 번이든)', () => {
  const s = scenario(['gardevoir', 'dragapult'], { active: 'SV1S_028', bench: ['M1S_040'] }, { active: 'SV8a_118' });
  // 트래쉬에 기본 초 에너지 3장
  for (let i = 0; i < 3; i++) { const iid = s.players[0].deck.find((x) => s.cards[x].ruleId === 'SV2a_210')!; s.players[0].deck.splice(s.players[0].deck.indexOf(iid), 1); s.players[0].discard.push(iid); }
  let st = s;
  for (let k = 0; k < 2; k++) {
    const ab = legalMoves(st, 0, info).find((m) => m.kind === 'ability');
    assert.ok(ab, `${k + 1}번째 사용 가능`);
    st = applyInput(st, ab!.input, info).state;
    st = pick(st, () => [st.players[0].active!.sid]);
  }
  assert.equal(st.players[0].active!.attached.length, 2);
  assert.equal(st.players[0].active!.damage, 40);
  checkInvariants(st, [60, 60]);
});

test('하솔: 서로 다른 타입 기본 에너지 2장 → 1장은 패, 1장은 포켓몬에', () => {
  const s = scenario(['flareon', 'gardevoir'], { active: 'SV7_130', hand: ['SV8a_179'] }, { active: 'M1S_040' });
  let st = applyInput(s, legalMoves(s, 0, info).find((m) => m.label.includes('하솔'))!.input, info).state;
  const req = st.requests[0];
  const types = new Map<string, string>();
  for (const o of req.options) { const t = info.db[st.cards[o].ruleId].energy!.type!; if (!types.has(t)) types.set(t, o); }
  st = pick(st, () => [...types.values()].slice(0, 2));
  const handBefore = st.players[0].hand.length;
  st = pick(st, (r) => [r.options[0]]);
  st = pick(st, () => [st.players[0].active!.sid]);
  assert.equal(st.players[0].hand.length, handBefore + 1);
  assert.equal(st.players[0].active!.attached.length, 1);
  checkInvariants(st, [60, 60]);
});

test('암호마니아의 해독: 고른 2장이 덱 맨 위에 고른 순서로', () => {
  const s = scenario(['gholdengo', 'gardevoir'], { active: 'SV7a_024', hand: ['SV5M_069'] }, { active: 'M1S_040' });
  let st = applyInput(s, legalMoves(s, 0, info).find((m) => m.label.includes('암호마니아'))!.input, info).state;
  const two = st.requests[0].options.slice(0, 2);
  const codes = two.map((i) => st.cards[i].code);
  st = pick(st, () => two);
  st = pick(st, () => [two[1]]);
  assert.equal(st.cards[st.players[0].deck[0]].code, codes[1], '맨 위');
  assert.equal(st.cards[st.players[0].deck[1]].code, codes[0], '두 번째');
  checkInvariants(st, [60, 60]);
});

test('기술머신 에볼루션: 진화할 카드가 없는 대상은 건너뛰고, 차례가 끝나면 트래쉬', () => {
  const s = scenario(['gardevoir', 'dragapult'], { active: 'SV11W_041', energy: ['SV2a_210'], tool: 'SV4M_061', bench: ['M1S_040', 'SV4K_032'] }, { active: 'SV8a_118' });
  const tm = legalMoves(s, 0, info).find((m) => m.kind === 'attack' && m.label.includes('에볼루션'));
  assert.ok(tm, '기술머신의 기술 사용 가능');
  let st = applyInput(s, tm!.input, info).state;
  st = pick(st, (r) => r.options);                 // 랄토스 + 우렁찬꼬리
  st = pick(st, (r) => [r.options[0]]);            // 랄토스 → 킬리아 (우렁찬꼬리는 진화 카드가 없어 건너뜀)
  st = settle(st);
  const names = st.players[0].bench.map((b) => info.db[st.cards[b.stack.at(-1)!].ruleId].name);
  assert.ok(names.includes('킬리아'), names.join(','));
  assert.ok(st.players[0].discard.some((i) => info.db[st.cards[i].ruleId].name === '기술머신 에볼루션'), '차례가 끝나면 트래쉬');
  checkInvariants(st, [60, 60]);
});
