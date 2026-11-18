// 규칙 엔진 (결정적): (상태, 입력) → (새 상태, 이벤트)
// - 난수는 state.rng 만 사용 → 같은 시드 + 같은 입력이면 같은 결과
// - 입력은 legalMoves() 목록에 있는 것만 받는다 (검증·폰 버튼·봇이 같은 목록을 씀)
// - 효과·절차는 프레임 스택(state.stack)에서 실행. 선택이 필요하면 멈추고 요청을 보낸 뒤 답이 오면 이어서 실행
import { prizeValue } from './cardData.ts';
import {
  BENCH_MAX, abilityActive, attackCost, canPay, clearSlot, dataOf, drawOne, emit, energiesOf, findSlot, flip, hasAbility, inst, maxHp, moveCard,
  nameOf, newId, note, other, playerHasEffect, prizesLeft, provided, putCounters, remainingHp, request, retreatCost, shuffleDeck,
  slotData, slotHasEffect, slotName, slotsOf, stadiumName, switchActive, toolName, toolOf, topOf,
} from './core.ts';
import type { Ctx } from './core.ts';
import { coin, seedRng } from './rng.ts';
import {
  ABILITIES, ATTACKS, FRAMES, TM_ATTACK, TRAINERS, candyCards, done, evolveFrom, onBenched, seq, updateBench,
} from './effects.ts';
import type {
  ApplyResult, CardInfo, Frame, GameConfig, GameInput, GameState, PendingRequest, PlayerState, PokemonSlot, Seat,
} from './types.ts';
import { GameError } from './types.ts';

export type { CardInfo } from './types.ts';
export const HAND_START = 7;
export const PRIZE_COUNT = 6;
export { BENCH_MAX };

// ───────────────────────── 생성 ─────────────────────────

export function createGame(config: GameConfig, info?: CardInfo): ApplyResult {
  const s: GameState = {
    version: 0, phase: 'setup', rng: seedRng(config.seed), nextId: 1, cards: {},
    players: [emptyPlayer(config.players[0].deckId), emptyPlayer(config.players[1].deckId)],
    stadium: null, firstPlayer: null, turnPlayer: null, turnNumber: 0,
    requests: [], reveals: [], setup: null, result: null, eventSeq: 0, stack: [], inCheckup: false, using: [], attackCtx: null,
  };
  for (const seat of [0, 1] as Seat[]) {
    for (const def of config.players[seat].cards) {
      for (let i = 0; i < def.count; i++) {
        const iid = newId(s, 'c');
        s.cards[iid] = { iid, owner: seat, ruleId: def.ruleId, code: def.code };
        s.players[seat].deck.push(iid);
      }
    }
  }
  const ctx: Ctx = { s, ev: [], info: info ?? { basics: new Set(), db: {} } };
  const heads = coin(s.rng);
  const winner: Seat = heads ? 0 : 1;
  emit(ctx, { type: 'coin', player: 0, heads, reason: '선공 결정 (앞면이면 플레이어 1이 선택)' });
  s.setup = { step: 'coin', coinWinner: winner, activeChosen: [false, false], benchChosen: [false, false], bonusDone: [false, false] };
  request(ctx, winner, 'chooseFirst', ['first', 'second'], 1, 1, '코인 토스에서 이겼습니다. 선공/후공을 고르세요.');
  return { state: s, events: ctx.ev };
}

function emptyPlayer(deckId: string): PlayerState {
  return {
    deckId, deck: [], hand: [], prizes: [], discard: [], active: null, bench: [], benchMax: BENCH_MAX, mulligans: 0, conceded: false,
    turns: 0, flags: { energy: false, supporter: false, retreat: false, stadium: false, stadiumUsed: false, names: [] }, koTurn: -1, effects: [],
  };
}

export { locate } from './core.ts';

/** 진행을 막는 요청 (공개 확인은 막지 않음) */
export const blockingRequests = (s: GameState, seat?: Seat) =>
  s.requests.filter((r) => r.kind !== 'ackReveal' && (seat === undefined || r.player === seat));

const isBasicCard = (ctx: Ctx, iid: string) => ctx.info.basics.has(ctx.s.cards[iid].ruleId) || dataOf(ctx, iid).pokemon?.stage === 0;

// ───────────────────────── 셋업 ─────────────────────────

function deal(ctx: Ctx) {
  const { s } = ctx;
  for (const seat of [0, 1] as Seat[]) { shuffleDeck(ctx, seat); for (let i = 0; i < HAND_START; i++) drawOne(ctx, seat); }
  for (let guard = 0; guard < 200; guard++) {
    const lacks = ([0, 1] as Seat[]).filter((seat) => !s.players[seat].hand.some((iid) => isBasicCard(ctx, iid)));
    if (lacks.length === 0) return;
    for (const seat of lacks) {
      const p = s.players[seat];
      const rev = { id: newId(s, 'v'), owner: seat, reason: lacks.length === 2
        ? '멀리건 (양쪽 모두): 처음 패 7장에 기본 포켓몬이 없어 패를 보여주고 덱에 되돌린 뒤 다시 뽑습니다. 둘 다 멀리건이면 추가 드로우는 없습니다.'
        : '멀리건: 처음 패 7장에 기본 포켓몬이 없어서, 정말 없는지 패를 보여주고 덱에 되돌려 섞은 뒤 7장을 다시 뽑습니다. 상대는 멀리건 횟수만큼 카드를 더 뽑을 수 있습니다.',
        cards: p.hand.map((iid) => ({ iid, code: s.cards[iid].code })) };
      s.reveals.push(rev);
      emit(ctx, { type: 'reveal', reveal: rev });
      request(ctx, other(seat), 'ackReveal', ['ok'], 1, 1, '상대가 공개한 패를 확인하세요.', { revealId: rev.id });
      for (const iid of [...p.hand]) moveCard(ctx, iid, { zone: 'deck', player: seat, position: 'top' });
      if (lacks.length === 1) { p.mulligans += 1; emit(ctx, { type: 'mulligan', player: seat, count: p.mulligans }); }
      shuffleDeck(ctx, seat);
      for (let i = 0; i < HAND_START; i++) drawOne(ctx, seat);
    }
  }
  throw new GameError('mulligan_loop', '멀리건이 끝나지 않습니다 (덱에 기본 포켓몬이 없음).');
}

function askActive(ctx: Ctx, seat: Seat) {
  const opts = ctx.s.players[seat].hand.filter((iid) => isBasicCard(ctx, iid));
  request(ctx, seat, 'chooseActive', opts, 1, 1, '배틀 포켓몬으로 낼 기본 포켓몬 1장을 고르세요.');
}
function askBench(ctx: Ctx, seat: Seat, prompt: string): boolean {
  const p = ctx.s.players[seat];
  const opts = p.hand.filter((iid) => isBasicCard(ctx, iid));
  const room = p.benchMax - p.bench.length;
  if (opts.length === 0 || room <= 0) return false;
  request(ctx, seat, 'chooseBench', opts, 0, Math.min(room, opts.length), prompt);
  return true;
}

function advanceSetup(ctx: Ctx) {
  const { s } = ctx;
  const st = s.setup!;
  if (st.step === 'bench' && st.benchChosen[0] && st.benchChosen[1]) {
    for (const seat of [0, 1] as Seat[]) {
      const p = s.players[seat];
      p.prizes = new Array(PRIZE_COUNT).fill(null);
      for (let i = 0; i < PRIZE_COUNT && p.deck.length; i++) moveCard(ctx, p.deck[0], { zone: 'prizes', player: seat, index: i });
    }
    st.step = 'bonus';
    for (const seat of [0, 1] as Seat[]) {
      const n = Math.min(s.players[other(seat)].mulligans, s.players[seat].deck.length);
      if (n > 0) request(ctx, seat, 'mulliganDraw', Array.from({ length: n + 1 }, (_, i) => String(i)), 1, 1,
        `상대가 ${s.players[other(seat)].mulligans}번 멀리건했습니다. 추가로 뽑을 장수를 고르세요.`);
      else st.bonusDone[seat] = true;
    }
  }
  if (st.step === 'bonus' && st.bonusDone[0] && st.bonusDone[1] && blockingRequests(s).length === 0) {
    for (const seat of [0, 1] as Seat[]) {
      const p = s.players[seat];
      if (p.active) p.active.faceDown = false;
      for (const b of p.bench) b.faceDown = false;
    }
    emit(ctx, { type: 'flipUp' });
    st.step = 'done';
    s.phase = 'playing';
    startTurn(ctx, s.firstPlayer!);
  }
}

function resolveSetupChoice(ctx: Ctx, seat: Seat, r: PendingRequest, picks: string[]) {
  const { s } = ctx;
  const st = s.setup!;
  switch (r.kind) {
    case 'chooseFirst':
      s.firstPlayer = picks[0] === 'first' ? seat : other(seat);
      emit(ctx, { type: 'firstPlayer', player: s.firstPlayer });
      deal(ctx);
      st.step = 'active';
      for (const p of [0, 1] as Seat[]) askActive(ctx, p);
      return;
    case 'chooseActive':
      moveCard(ctx, picks[0], { zone: 'active', player: seat, faceDown: true });
      st.activeChosen[seat] = true;
      if (st.activeChosen[0] && st.activeChosen[1]) st.step = 'bench';
      if (!askBench(ctx, seat, '벤치에 낼 기본 포켓몬을 고르세요 (0~5장, 나중에 내도 됩니다).')) st.benchChosen[seat] = true;
      advanceSetup(ctx);
      return;
    case 'chooseBench':
      for (const iid of picks) moveCard(ctx, iid, { zone: 'bench', player: seat, faceDown: s.phase === 'setup' });
      if (st.step === 'bonus') st.bonusDone[seat] = true; else st.benchChosen[seat] = true;
      advanceSetup(ctx);
      return;
    case 'mulliganDraw': {
      const n = Number(picks[0]);
      for (let i = 0; i < n; i++) drawOne(ctx, seat);
      if (n === 0 || !askBench(ctx, seat, '추가로 뽑은 카드 중 기본 포켓몬을 벤치에 낼 수 있습니다.')) st.bonusDone[seat] = true;
      advanceSetup(ctx);
      return;
    }
  }
}

// ───────────────────────── 턴 흐름 ─────────────────────────

function startTurn(ctx: Ctx, seat: Seat) {
  const { s } = ctx;
  s.turnPlayer = seat;
  s.turnNumber += 1;
  const p = s.players[seat];
  p.turns += 1;
  p.flags = { energy: false, supporter: false, retreat: false, stadium: false, stadiumUsed: false, names: [] };
  emit(ctx, { type: 'turnStart', player: seat, turnNumber: s.turnNumber });
  if (!drawOne(ctx, seat)) endGame(ctx, other(seat), `플레이어 ${seat + 1}이(가) 턴 시작에 덱에서 카드를 뽑지 못했습니다.`);
}

function endGame(ctx: Ctx, winner: Seat | null, reason: string) {
  const { s } = ctx;
  if (s.phase === 'ended') return;
  s.phase = 'ended';
  s.result = { winner, reason };
  s.requests = s.requests.filter((r) => r.kind === 'ackReveal');
  s.stack = [];
  emit(ctx, { type: 'gameEnd', result: s.result });
}

/** 턴 종료 → 포켓몬 체크 → 기절 확인 → 상대 턴 */
FRAMES.endTurn = (ctx, f) => {
  const { s } = ctx;
  if (f.step === 0) {
    // 차례가 끝날 때: 기술머신 에볼루션 트래쉬
    for (const slot of slotsOf(s, f.player)) {
      const t = toolOf(ctx, slot);
      if (t && nameOf(ctx, t) === '기술머신 에볼루션') moveCard(ctx, t, { zone: 'discard', player: f.player });
    }
    s.inCheckup = true;
    return seq(ctx, f, 1, [['checkup', {}], ['koCheck', {}]]);
  }
  s.inCheckup = false;
  // 이 턴으로 만료되는 효과 정리
  for (const seat of [0, 1] as Seat[]) {
    const p = s.players[seat];
    p.effects = p.effects.filter((e) => e.until > s.turnNumber);
    for (const slot of slotsOf(s, seat)) slot.effects = slot.effects.filter((e) => e.until > s.turnNumber);
  }
  done(ctx, f);
  if (s.phase === 'playing') startTurn(ctx, other(f.player));
};

/** 포켓몬 체크: 양쪽 배틀 포켓몬 — 독 → 화상 → 잠듦 → 마비 */
FRAMES.checkup = (ctx, f) => {
  const { s } = ctx;
  for (const seat of [s.turnPlayer!, other(s.turnPlayer!)] as Seat[]) {
    const a = s.players[seat].active;
    if (!a) continue;
    if (a.cond.poison) putCounters(ctx, a, a.cond.poison);
    if (a.cond.burn) { putCounters(ctx, a, 2); if (flip(ctx, seat, '화상 회복')) { a.cond.burn = false; emit(ctx, { type: 'condition', player: seat, sid: a.sid, cond: 'burned', on: false }); } }
    if (a.cond.rot === 'asleep' && flip(ctx, seat, '잠듦 회복')) { a.cond.rot = ''; emit(ctx, { type: 'condition', player: seat, sid: a.sid, cond: 'asleep', on: false }); }
    if (a.cond.rot === 'paralyzed' && a.cond.paraUntil <= s.turnNumber) { a.cond.rot = ''; emit(ctx, { type: 'condition', player: seat, sid: a.sid, cond: 'paralyzed', on: false }); }
  }
  done(ctx, f);
};

/** 기절 확인 → 트래쉬 → 사이드 → 승패 → 새 배틀 포켓몬 */
FRAMES.koCheck = (ctx, f) => {
  const { s } = ctx;
  if (f.step === 0) {
    const takes: [number, number] = [0, 0];
    let any = false;
    for (const seat of [0, 1] as Seat[]) {
      for (const slot of slotsOf(s, seat)) {
        if (slot.faceDown || remainingHp(ctx, slot) > 0) continue;
        any = true;
        const d = slotData(ctx, slot);
        let n = prizeValue(d);
        const wasActive = s.players[seat].active === slot;
        // 이 기술로 상대 배틀 포켓몬을 기절시켰을 때의 추가 사이드 (무쇠손 ex, 브라이어)
        if (s.attackCtx && s.attackCtx.seat !== seat && wasActive) n += s.attackCtx.extraPrizes;
        takes[other(seat)] += n;
        if (!s.inCheckup && s.turnPlayer !== seat) s.players[seat].koTurn = s.turnNumber;
        emit(ctx, { type: 'ko', player: seat, code: inst(ctx, topOf(slot)).code, prizes: n });
        // 학습장치: 상대 기술로 내 배틀 포켓몬이 기절하면 기본 에너지 1장을 장치를 단 포켓몬으로 옮김
        if (wasActive && s.attackCtx && s.attackCtx.seat !== seat) {
          const holder = s.players[seat].bench.find((b) => toolName(ctx, b) === '학습장치');
          const e = energiesOf(ctx, slot).find((x) => dataOf(ctx, x).energy?.basic);
          if (holder && e) { moveCard(ctx, e, { zone: 'attach', sid: holder.sid }); note(ctx, '학습장치: 기본 에너지를 옮김'); }
        }
        clearSlot(ctx, slot, seat, 'discard');
      }
    }
    if (s.attackCtx) s.attackCtx.extraPrizes = 0;
    if (!any) return done(ctx, f);
    updateBench(ctx);
    f.data.takes = takes;
    f.data.order = [s.turnPlayer ?? 0, other(s.turnPlayer ?? 0)];
    f.data.i = 0;
    f.step = 1;
  }
  if (f.step === 1 || f.step === 2) {
    const takes = f.data.takes as [number, number];
    const order = f.data.order as Seat[];
    if (f.step === 2) {
      const taker = order[Number(f.data.i)];
      for (const idx of f.picks ?? []) { const iid = s.players[taker].prizes[Number(idx)]; if (iid) moveCard(ctx, iid, { zone: 'hand', player: taker }); }
      f.data.i = Number(f.data.i) + 1;
    }
    while (Number(f.data.i) < 2) {
      const taker = order[Number(f.data.i)];
      const n = Math.min(takes[taker], prizesLeft(s, taker));
      if (n > 0) {
        const opts = s.players[taker].prizes.map((x, i) => (x ? String(i) : '')).filter(Boolean);
        f.step = 2;
        f.picks = undefined;
        request(ctx, taker, 'takePrize', opts, n, n, `사이드를 ${n}장 가져가세요.`, { frame: f.id });
        return;
      }
      f.data.i = Number(f.data.i) + 1;
    }
    // 승패 확인 (공식 표: 조건을 더 많이 만족한 쪽 승리, 같으면 무승부)
    const tookAll = (p: Seat) => prizesLeft(s, p) === 0;
    const noMon = (p: Seat) => !s.players[p].active && s.players[p].bench.length === 0;
    const score = (p: Seat) => Number(tookAll(p)) + Number(noMon(other(p)));
    const a = score(0), b = score(1);
    if (a || b) {
      if (a === b) endGame(ctx, null, '양쪽이 동시에 승리 조건을 만족 — 무승부');
      else {
        const w: Seat = a > b ? 0 : 1;
        endGame(ctx, w, tookAll(w) ? '사이드를 모두 가져갔습니다.' : '상대 필드에 포켓몬이 없습니다.');
      }
      return;
    }
    // 새 배틀 포켓몬: 다음 차례 플레이어 먼저
    const next = s.inCheckup ? other(s.turnPlayer!) : s.turnPlayer!;
    then2(ctx, f, [next, other(next)].filter((p) => !s.players[p].active).map((p) => ['promote', p] as [string, Seat]));
  }
};
function then2(ctx: Ctx, f: Frame, children: [string, Seat][]) {
  done(ctx, f);
  for (let i = children.length - 1; i >= 0; i--) ctx.s.stack.push({ id: newId(ctx.s, 'f'), kind: children[i][0], step: 0, player: children[i][1], data: {} });
}

/** 트레이너스 사용 끝: 사용 중인 카드를 트래쉬 */
FRAMES.trainerDone = (ctx, f) => {
  const iid = String(f.data.card);
  if (ctx.s.using.includes(iid)) moveCard(ctx, iid, { zone: 'discard', player: f.player });
  done(ctx, f);
};

/** 기술 선언 → 혼란 확인 → 효과 실행 */
FRAMES.attack = (ctx, f) => {
  const { s } = ctx;
  const a = findSlot(s, String(f.data.sid))?.slot;
  if (!a) return done(ctx, f);
  if (a.cond.rot === 'confused' && !flip(ctx, f.player, '혼란: 앞면이면 기술 사용')) {
    putCounters(ctx, a, 3);
    note(ctx, '혼란으로 기술 실패 — 자신에게 데미지 카운터 3개');
    return done(ctx, f);
  }
  s.attackCtx = { seat: f.player, sid: a.sid, extraPrizes: 0 };
  if (playerHasEffect(s, f.player, 'brier') && slotData(ctx, a).pokemon?.tera) s.attackCtx.extraPrizes += 1;
  done(ctx, f);
  s.stack.push({ id: newId(s, 'f'), kind: 'attackEffect', step: 0, player: f.player, data: { sid: a.sid, base: f.data.base, attackJa: f.data.attackJa } });
};

// ───────────────────────── 실행 루프 ─────────────────────────

/** 막는 요청이 없는 동안 스택 맨 위 프레임을 실행 */
function run(ctx: Ctx) {
  const { s } = ctx;
  for (let guard = 0; guard < 10000; guard++) {
    if (s.phase === 'ended') { s.stack = []; return; }
    if (blockingRequests(s).length) return;
    const f = s.stack[s.stack.length - 1];
    if (!f) return;
    const h = FRAMES[f.kind];
    if (!h) throw new GameError('no_frame', `처리기 없음: ${f.kind}`);
    const before = `${s.stack.length}|${f.step}|${s.requests.length}`;
    h(ctx, f);
    if (`${s.stack.length}|${f.step}|${s.requests.length}` === before && s.stack[s.stack.length - 1] === f && !f.picks) {
      // 같은 상태로 다시 실행되면 무한 반복 → 오류
      throw new GameError('frame_stuck', `프레임 진행 없음: ${f.kind} step ${f.step}`);
    }
    if (f.picks && s.stack[s.stack.length - 1] === f && !s.requests.some((r) => r.frame === f.id)) f.picks = undefined;
  }
  throw new GameError('loop', '효과 처리가 끝나지 않습니다.');
}

// ───────────────────────── 합법 행동 ─────────────────────────

export type MoveKind = 'play' | 'evolve' | 'attach' | 'tool' | 'trainer' | 'retreat' | 'attack' | 'ability' | 'stadium' | 'endTurn' | 'concede';
export type LegalMove = { input: Exclude<GameInput, { type: 'choice' }>; kind: MoveKind; label: string; card?: string; target?: string };

/** 선택 요청 말고 지금 할 수 있는 행동 목록 (폰 버튼·봇·입력 검증이 모두 이것을 씀) */
export function legalMoves(s: GameState, seat: Seat, info: CardInfo): LegalMove[] {
  const out: LegalMove[] = [];
  if (s.phase !== 'ended') out.push({ input: { type: 'concede', player: seat }, kind: 'concede', label: '항복' });
  if (s.phase !== 'playing' || s.turnPlayer !== seat || blockingRequests(s).length || s.stack.length) return out;
  const ctx: Ctx = { s, ev: [], info };
  const p = s.players[seat];
  const myTurns = p.turns;
  const firstTurnOfGame = seat === s.firstPlayer && myTurns === 1;
  const slots = slotsOf(s, seat);
  const benchRoom = p.benchMax - p.bench.length;
  const oppField = slotsOf(s, other(seat));
  const aceLocked = oppField.some((sl) => hasAbility(ctx, sl, 'エースキャンセラー') && toolOf(ctx, sl));
  const itemLock = playerHasEffect(s, seat, 'itemLock');

  for (const iid of p.hand) {
    const d = dataOf(ctx, iid);
    const nm = d.name;
    if (d.kind === 'pokemon') {
      const pk = d.pokemon!;
      if (pk.stage === 0) {
        if (benchRoom > 0) out.push({ input: { type: 'play', player: seat, card: iid }, kind: 'play', label: `${nm} 벤치에 내기`, card: iid });
        continue;
      }
      for (const sl of slots) {
        if (canEvolve(ctx, seat, sl, iid)) out.push({ input: { type: 'play', player: seat, card: iid, target: sl.sid }, kind: 'evolve', label: `${slotName(ctx, sl)} → ${nm} 진화`, card: iid, target: sl.sid });
      }
    } else if (d.kind === 'energy') {
      if (p.flags.energy || (d.ace && aceLocked)) continue;
      for (const sl of slots) out.push({ input: { type: 'play', player: seat, card: iid, target: sl.sid }, kind: 'attach', label: `${nm} → ${slotName(ctx, sl)}`, card: iid, target: sl.sid });
    } else {
      const sub = d.trainer;
      if (d.ace && aceLocked) continue;
      if (sub === 'tool') {
        // 포켓몬의 도구는 아이템이 아니므로 아이템 잠금의 영향을 받지 않는다
        for (const sl of slots) if (!toolOf(ctx, sl)) out.push({ input: { type: 'play', player: seat, card: iid, target: sl.sid }, kind: 'tool', label: `${nm} → ${slotName(ctx, sl)}`, card: iid, target: sl.sid });
        continue;
      }
      if (sub === 'item' && itemLock) continue;
      if (sub === 'supporter' && (p.flags.supporter || firstTurnOfGame)) continue;
      if (sub === 'stadium') {
        if (p.flags.stadium || stadiumName(ctx) === nm) continue;
        out.push({ input: { type: 'play', player: seat, card: iid }, kind: 'trainer', label: `${nm} 내기`, card: iid });
        continue;
      }
      if (nm === '이상한사탕') {
        if (myTurns <= 1) continue;
        for (const sl of slots) if (sl.enteredTurn < s.turnNumber && candyCards(ctx, seat, sl).length) out.push({ input: { type: 'play', player: seat, card: iid, target: sl.sid }, kind: 'trainer', label: `이상한사탕 → ${slotName(ctx, sl)}`, card: iid, target: sl.sid });
        continue;
      }
      const def = TRAINERS[nm];
      if (!def) continue;
      if (def.can && def.can(ctx, seat, iid)) continue;
      out.push({ input: { type: 'play', player: seat, card: iid }, kind: 'trainer', label: `${nm} 사용`, card: iid });
    }
  }
  // 스타디움 효과 (보물마을)
  if (stadiumName(ctx) === '보물마을' && !p.flags.stadiumUsed && benchRoom > 0 && p.deck.length)
    out.push({ input: { type: 'stadium', player: seat }, kind: 'stadium', label: '보물마을: 덱에서 기본 포켓몬을 벤치로' });
  // 특성
  for (const sl of slots) {
    if (!abilityActive(ctx, sl)) continue;
    const ab = slotData(ctx, sl).pokemon!.abilities[0];
    const def = ABILITIES[ab.nameJa];
    if (!def) continue;
    if (def.once === 'pokemon' && sl.abilityTurn === s.turnNumber) continue;
    if (def.once === 'name' && p.flags.names.includes(ab.nameJa)) continue;
    if (def.can && def.can(ctx, seat, sl)) continue;
    out.push({ input: { type: 'ability', player: seat, sid: sl.sid }, kind: 'ability', label: `특성: ${slotName(ctx, sl)} ${ab.name || ab.nameJa}`, target: sl.sid });
  }
  // 후퇴
  const act = p.active;
  if (act && !p.flags.retreat && p.bench.length && act.cond.rot !== 'asleep' && act.cond.rot !== 'paralyzed' && !slotHasEffect(act, 'noRetreat')) {
    const cost = retreatCost(ctx, act, seat);
    if (provided(ctx, act).length >= cost) for (const b of p.bench) out.push({ input: { type: 'retreat', player: seat, to: b.sid }, kind: 'retreat', label: `후퇴 → ${slotName(ctx, b)} (비용 ${cost})`, target: b.sid });
  }
  // 기술
  if (act && !firstTurnOfGame && act.cond.rot !== 'asleep' && act.cond.rot !== 'paralyzed' && !slotHasEffect(act, 'noAttack')) {
    attacksOf(ctx, act).forEach((a, i) => {
      const cost = attackCost(ctx, act, seat, a.cost, a.nameJa);
      if (!canPay(provided(ctx, act), cost)) return;
      const def = ATTACKS[a.nameJa];
      if (def?.can && def.can(ctx, seat, act)) return;
      out.push({ input: { type: 'attack', player: seat, index: i }, kind: 'attack', label: `기술: ${a.name || a.nameJa}${a.damage ? ` ${a.damage}${a.op}` : ''}` });
    });
  }
  out.push({ input: { type: 'endTurn', player: seat }, kind: 'endTurn', label: '턴 종료' });
  return out;
}

/** 이 포켓몬이 쓸 수 있는 기술 (기술머신 에볼루션 포함) */
export function attacksOf(ctx: Ctx, slot: PokemonSlot) {
  const list = [...(slotData(ctx, slot).pokemon?.attacks ?? [])];
  if (toolName(ctx, slot) === '기술머신 에볼루션') list.push(TM_ATTACK);
  return list;
}

function canEvolve(ctx: Ctx, seat: Seat, slot: PokemonSlot, iid: string): boolean {
  const { s } = ctx;
  if (slot.faceDown) return false;
  const d = dataOf(ctx, iid).pokemon!;
  const top = slotData(ctx, slot);
  const viaDNA = top.name === '이브이 ex' && hasAbility(ctx, slot, 'にじいろDNA') && d.from === '이브이' && d.rule === 'ex';
  if (d.from !== top.name && !viaDNA) return false;
  const boost = hasAbility(ctx, slot, 'ブーストしんか') && s.players[seat].active === slot;
  if (!boost) {
    if (s.players[seat].turns <= 1) return false;
    if (slot.enteredTurn >= s.turnNumber) return false;
  }
  return true;
}

// ───────────────────────── 입력 처리 ─────────────────────────

/** 입력 비교 (키 순서와 무관) */
const canon = (x: GameInput) => JSON.stringify(Object.fromEntries(Object.entries(x).filter(([, v]) => v !== undefined).sort(([a], [b]) => a.localeCompare(b))));
const sameInput = (a: GameInput, b: GameInput) => canon(a) === canon(b);

export function applyInput(state: GameState, input: GameInput, info: CardInfo): ApplyResult {
  const s = structuredClone(state);
  const ctx: Ctx = { s, ev: [], info };
  if (input.player !== 0 && input.player !== 1) throw new GameError('bad_player', '플레이어가 올바르지 않습니다.');
  if (s.phase === 'ended' && input.type !== 'choice') throw new GameError('ended', '게임이 끝났습니다.');

  if (input.type === 'choice') {
    resolveChoice(ctx, input.player, input.requestId, input.picks);
  } else {
    const moves = legalMoves(s, input.player, info);
    const norm = { ...input } as GameInput;
    if ('target' in norm && norm.target === undefined) delete (norm as { target?: string }).target;
    if (!moves.some((m) => sameInput(m.input, norm))) throw new GameError('illegal', illegalReason(s, input.player));
    doMove(ctx, input.player, norm);
  }
  run(ctx);
  s.version += 1;
  return { state: s, events: ctx.ev };
}

function illegalReason(s: GameState, seat: Seat): string {
  if (s.phase !== 'playing') return '지금은 할 수 없습니다.';
  if (s.turnPlayer !== seat) return '내 차례가 아닙니다.';
  if (blockingRequests(s).length || s.stack.length) return '먼저 선택을 끝내세요.';
  return '지금 할 수 없는 행동입니다.';
}

function doMove(ctx: Ctx, seat: Seat, input: GameInput) {
  const { s } = ctx;
  const p = s.players[seat];
  switch (input.type) {
    case 'concede':
      p.conceded = true;
      endGame(ctx, other(seat), `플레이어 ${seat + 1}이(가) 항복했습니다.`);
      return;
    case 'endTurn':
      s.stack.push({ id: newId(s, 'f'), kind: 'endTurn', step: 0, player: seat, data: {} });
      return;
    case 'retreat': {
      const act = p.active!;
      const cost = retreatCost(ctx, act, seat);
      s.stack.push({ id: newId(s, 'f'), kind: 'retreat', step: 0, player: seat, data: { to: input.to, cost } });
      return;
    }
    case 'attack': {
      const act = p.active!;
      const a = attacksOf(ctx, act)[input.index];
      emit(ctx, { type: 'attack', player: seat, code: inst(ctx, topOf(act)).code, name: a.name || a.nameJa, index: input.index });
      s.stack.push({ id: newId(s, 'f'), kind: 'endTurn', step: 0, player: seat, data: {} });
      s.stack.push({ id: newId(s, 'f'), kind: 'koCheck', step: 0, player: seat, data: {} });
      s.stack.push({ id: newId(s, 'f'), kind: 'attack', step: 0, player: seat, data: { sid: act.sid, base: a.damage, attackJa: a.nameJa } });
      return;
    }
    case 'ability': {
      const slot = findSlot(s, input.sid)!.slot;
      const ab = slotData(ctx, slot).pokemon!.abilities[0];
      slot.abilityTurn = s.turnNumber;
      p.flags.names.push(ab.nameJa);
      emit(ctx, { type: 'ability', player: seat, code: inst(ctx, topOf(slot)).code, name: ab.name || ab.nameJa });
      s.stack.push({ id: newId(s, 'f'), kind: 'koCheck', step: 0, player: seat, data: {} });
      s.stack.push({ id: newId(s, 'f'), kind: 'abilityRun', step: 0, player: seat, data: { sid: slot.sid, ab: ab.nameJa } });
      return;
    }
    case 'stadium': {
      p.flags.stadiumUsed = true;
      emit(ctx, { type: 'play', player: seat, code: inst(ctx, s.stadium!).code, what: '스타디움 효과' });
      s.stack.push({ id: newId(s, 'f'), kind: 'search', step: 0, player: seat, data: { from: 'deck', filter: { kind: 'pokemon', stage: 0, noRule: true }, max: 1, to: 'bench', prompt: '벤치에 낼 룰 없는 기본 포켓몬' } });
      return;
    }
    case 'play': return playCard(ctx, seat, input.card, input.target);
  }
}

FRAMES.abilityRun = (ctx, f) => {
  const def = ABILITIES[String(f.data.ab)];
  if (!def) return done(ctx, f);
  def.run(ctx, f);
};

FRAMES.retreat = (ctx, f) => {
  const { s } = ctx;
  const p = s.players[f.player];
  const act = p.active!;
  const cost = Number(f.data.cost);
  const ens = energiesOf(ctx, act);
  if (f.step === 0 && cost > 0) {
    const units = provided(ctx, act).length;
    if (ens.length <= cost && units >= cost && units === ens.length) { for (const e of ens) moveCard(ctx, e, { zone: 'discard', player: f.player }); f.step = 2; }
    else {
      f.step = 1;
      f.picks = undefined;
      request(ctx, f.player, 'pickCards', ens, 1, ens.length, `후퇴 비용: 트래쉬할 에너지 (${cost}개 분량)`, { frame: f.id, cards: ens.map((iid) => ({ iid, code: inst(ctx, iid).code })) });
      return;
    }
  }
  if (f.step === 1) {
    const picks = f.picks ?? [];
    const got = provided(ctx, { ...act, attached: picks }).length;
    if (got < cost) {
      f.picks = undefined;
      request(ctx, f.player, 'pickCards', ens, 1, ens.length, `에너지가 부족합니다. ${cost}개 분량을 고르세요.`, { frame: f.id, cards: ens.map((iid) => ({ iid, code: inst(ctx, iid).code })) });
      return;
    }
    for (const e of picks) moveCard(ctx, e, { zone: 'discard', player: f.player });
  }
  p.flags.retreat = true;
  switchActive(ctx, f.player, String(f.data.to));
  done(ctx, f);
};

function playCard(ctx: Ctx, seat: Seat, iid: string, target?: string) {
  const { s } = ctx;
  const p = s.players[seat];
  const d = dataOf(ctx, iid);
  const code = inst(ctx, iid).code;
  if (d.kind === 'pokemon') {
    if (d.pokemon!.stage === 0) {
      const nid = moveCard(ctx, iid, { zone: 'bench', player: seat });
      emit(ctx, { type: 'play', player: seat, code, what: '벤치에 냄' });
      const slot = p.bench.find((b) => b.stack.includes(nid))!;
      updateBench(ctx);
      onBenched(ctx, seat, slot.sid);
      return;
    }
    evolveFrom(ctx, seat, iid, target!);
    updateBench(ctx);
    return;
  }
  if (d.kind === 'energy') {
    p.flags.energy = true;
    moveCard(ctx, iid, { zone: 'attach', sid: target! });
    emit(ctx, { type: 'play', player: seat, code, what: '에너지 붙이기' });
    if (d.name === '제트 에너지') {
      const t = findSlot(s, target!);
      if (t && !t.active) { switchActive(ctx, seat, t.slot.sid); note(ctx, '제트 에너지: 배틀 포켓몬과 교체'); }
    }
    return;
  }
  // 트레이너스
  const sub = d.trainer;
  if (sub === 'tool') {
    moveCard(ctx, iid, { zone: 'attach', sid: target! });
    emit(ctx, { type: 'play', player: seat, code, what: '도구 붙이기' });
    return;
  }
  if (sub === 'stadium') {
    p.flags.stadium = true;
    if (s.stadium) moveCard(ctx, s.stadium, { zone: 'discard', player: s.cards[s.stadium].owner });
    moveCard(ctx, iid, { zone: 'stadium' });
    emit(ctx, { type: 'play', player: seat, code, what: '스타디움' });
    updateBench(ctx);
    return;
  }
  if (sub === 'supporter') p.flags.supporter = true;
  const nid = moveCard(ctx, iid, { zone: 'reveal' });
  emit(ctx, { type: 'play', player: seat, code, what: sub === 'supporter' ? '서포트' : '아이템' });
  s.stack.push({ id: newId(s, 'f'), kind: 'koCheck', step: 0, player: seat, data: {} });
  s.stack.push({ id: newId(s, 'f'), kind: 'trainerDone', step: 0, player: seat, data: { card: nid } });
  s.stack.push({ id: newId(s, 'f'), kind: 'trainerRun', step: 0, player: seat, data: { card: nid, name: d.name, target } });
}

FRAMES.trainerRun = (ctx, f) => {
  const def = TRAINERS[String(f.data.name)];
  if (!def) { note(ctx, '이 카드의 효과는 아직 자동화되지 않았습니다.'); return done(ctx, f); }
  def.run(ctx, f);
};

function resolveChoice(ctx: Ctx, seat: Seat, requestId: string, picks: string[]) {
  const { s } = ctx;
  const r = s.requests.find((x) => x.id === requestId);
  if (!r) throw new GameError('no_request', '이미 처리되었거나 없는 선택입니다.');
  if (r.player !== seat) throw new GameError('not_yours', '내 선택이 아닙니다.');
  if (!Array.isArray(picks) || new Set(picks).size !== picks.length) throw new GameError('bad_picks', '선택이 올바르지 않습니다.');
  if (picks.length < r.min || picks.length > r.max) throw new GameError('bad_count', `${r.min}~${r.max}개를 골라야 합니다.`);
  if (picks.some((p) => !r.options.includes(p))) throw new GameError('bad_option', '고를 수 없는 것을 골랐습니다.');
  s.requests = s.requests.filter((x) => x.id !== r.id);
  if (r.kind === 'ackReveal') {
    if (!s.requests.some((x) => x.revealId === r.revealId)) s.reveals = s.reveals.filter((v) => v.id !== r.revealId);
    return;
  }
  if (r.frame) {
    const f = s.stack.find((x) => x.id === r.frame);
    if (!f) throw new GameError('no_frame', '처리 중인 효과가 없습니다.');
    f.picks = picks;
    return;
  }
  resolveSetupChoice(ctx, seat, r, picks);
}

// ───────────────────────── 검사 도우미 ─────────────────────────

/** 플레이어가 가진 카드 수 (모든 구역 합) — 불변식 검사용 */
export function countCards(s: GameState, seat: Seat): number {
  const p = s.players[seat];
  const inPlay = (slot: PokemonSlot | null) => (slot ? slot.stack.length + slot.attached.length : 0);
  return p.deck.length + p.hand.length + p.prizes.filter(Boolean).length + p.discard.length
    + inPlay(p.active) + p.bench.reduce((a, b) => a + inPlay(b), 0)
    + (s.stadium && s.cards[s.stadium].owner === seat ? 1 : 0)
    + s.using.filter((i) => s.cards[i].owner === seat).length;
}

export { maxHp, remainingHp, provided, retreatCost, attackCost };
