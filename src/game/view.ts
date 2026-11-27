// 시점별 보기: 상태와 이벤트에서 보는 사람(플레이어 1·2, 게임판)이 알 수 없는 정보를 지운다.
// 서버는 이 함수를 거친 결과만 클라이언트에 보낸다 (비공개 정보 누출 방지의 유일한 관문).
import { legalMoves, maxHp, retreatCost } from './engine.ts';
import { slotData } from './core.ts';
import type { Ctx } from './core.ts';
import { ABILITIES } from './effects.ts';
import type { LegalMove } from './engine.ts';
import type { CardInfo, Conditions, GameEvent, GameState, PendingRequest, PokemonSlot, Reveal, Seat, SlotEffect, Viewer, ZoneRef } from './types.ts';

export type CardView = { iid: string; code: string };
export type SlotView = {
  sid: string; faceDown: boolean; stack: CardView[] | null; attached: CardView[] | null;
  damage: number; hp: number | null;              // 최대 HP (뒷면이면 null)
  cond: Conditions; effects: SlotEffect[]; retreat: number | null;
  abilityUsed: boolean;                            // 차례에 1번인 특성을 이번 차례에 이미 씀 (화면 표시용)
};
export type PlayerView = {
  seat: Seat;
  deckId: string;
  deckCount: number;
  handCount: number;
  hand: CardView[] | null;         // 본인만
  prizes: boolean[];               // 칸마다 카드가 있는지 (내용은 아무도 모름)
  discard: CardView[];
  lost: CardView[];
  gxUsed: boolean;
  vstarUsed: boolean;
  active: SlotView | null;
  bench: SlotView[];
  benchMax: number;
  mulligans: number;
  conceded: boolean;
  turns: number;
  flags: GameState['players'][0]['flags'];
  effects: GameState['players'][0]['effects'];
};
export type RequestView = Pick<PendingRequest, 'id' | 'player' | 'kind' | 'prompt'> & Partial<Pick<PendingRequest, 'options' | 'min' | 'max' | 'revealId' | 'labels' | 'cards'>>;
export type MoveView = LegalMove;
export type GameView = {
  viewer: Viewer;
  version: number;
  phase: GameState['phase'];
  setupStep: string | null;
  players: [PlayerView, PlayerView];
  stadium: CardView | null;
  using: CardView[];               // 사용 중인 트레이너스 (모두에게 공개)
  firstPlayer: Seat | null;
  turnPlayer: Seat | null;
  turnNumber: number;
  requests: RequestView[];         // 내 요청은 선택지까지, 남의 요청은 "누가 무엇을 고르는 중"만
  reveals: Reveal[];
  result: GameState['result'];
  actions: MoveView[] | null;      // 플레이어 시점: 지금 할 수 있는 행동 (게임판은 null)
};

const cv = (s: GameState, iid: string): CardView => ({ iid, code: s.cards[iid].code });

function slotView(s: GameState, slot: PokemonSlot, owner: Seat, viewer: Viewer, info: CardInfo): SlotView {
  const hide = slot.faceDown && viewer !== owner;
  const ctx = { s, ev: [], info };
  const known = !!info.db[s.cards[slot.stack[slot.stack.length - 1]].ruleId];
  return {
    sid: slot.sid, faceDown: slot.faceDown, damage: hide ? 0 : slot.damage,
    stack: hide ? null : slot.stack.map((i) => cv(s, i)),
    attached: hide ? null : slot.attached.map((i) => cv(s, i)),
    hp: hide || !known ? null : maxHp(ctx, slot),
    cond: slot.cond, effects: slot.effects,
    retreat: hide || !known ? null : retreatCost(ctx, slot, owner),
    abilityUsed: !hide && known && abilityUsedNow(ctx, slot, owner),
  };
}

// 차례에 1번인 특성을 이번 차례에 이미 써서 더 쓸 수 없는가 (legalMoves 의 "1번" 조건과 같은 기준)
function abilityUsedNow(ctx: Ctx, slot: PokemonSlot, owner: Seat): boolean {
  const ab = slotData(ctx, slot).pokemon?.abilities[0];
  const def = ab ? ABILITIES[ab.nameJa] : undefined;
  if (!ab || !def) return false;
  if (def.once === 'pokemon') return slot.abilityTurn === ctx.s.turnNumber;
  if (def.once === 'name') return ctx.s.turnPlayer === owner && ctx.s.players[owner].flags.names.includes(ab.nameJa);
  return false;
}

export function viewFor(s: GameState, viewer: Viewer, info: CardInfo): GameView {
  const players = ([0, 1] as Seat[]).map((seat): PlayerView => {
    const p = s.players[seat];
    return {
      seat, deckId: p.deckId, deckCount: p.deck.length, handCount: p.hand.length,
      hand: viewer === seat ? p.hand.map((i) => cv(s, i)) : null,
      prizes: p.prizes.map((x) => x !== null),
      discard: p.discard.map((i) => cv(s, i)),
      lost: p.lost.map((i) => cv(s, i)), gxUsed: p.gxUsed, vstarUsed: p.vstarUsed,
      active: p.active ? slotView(s, p.active, seat, viewer, info) : null,
      bench: p.bench.map((b) => slotView(s, b, seat, viewer, info)),
      benchMax: p.benchMax, mulligans: p.mulligans, conceded: p.conceded, turns: p.turns, flags: p.flags, effects: p.effects,
    };
  }) as [PlayerView, PlayerView];
  return {
    viewer, version: s.version, phase: s.phase, setupStep: s.setup?.step ?? null, players,
    stadium: s.stadium ? cv(s, s.stadium) : null,
    using: s.using.map((i) => cv(s, i)),
    firstPlayer: s.firstPlayer, turnPlayer: s.turnPlayer, turnNumber: s.turnNumber,
    requests: s.requests.map((r) => (r.player === viewer
      ? { id: r.id, player: r.player, kind: r.kind, prompt: r.prompt, options: r.options, min: r.min, max: r.max, revealId: r.revealId, labels: r.labels, cards: r.cards }
      : { id: r.id, player: r.player, kind: r.kind, prompt: r.prompt })),
    reveals: s.reveals,
    result: s.result,
    actions: viewer === 'board' ? null : legalMoves(s, viewer, info),
  };
}

/** 이 구역의 카드를 viewer 가 볼 수 있는가 */
function zoneVisible(ref: ZoneRef, viewer: Viewer, faceDown = false): boolean {
  switch (ref.zone) {
    case 'deck': case 'prizes': return false;
    case 'hand': return viewer === ref.player;
    case 'active': case 'bench': return !faceDown || viewer === ref.player;
    default: return true;
  }
}

/** 이벤트를 viewer 시점으로 거른다 (보이지 않는 카드 이동은 카드 정보를 지움) */
export function eventsFor(events: GameEvent[], viewer: Viewer): GameEvent[] {
  return events.map((e) => {
    if (e.type !== 'move') return e;
    if (!e.card) return e;
    if (zoneVisible(e.to, viewer, e.faceDown)) return e;
    // 보이던 카드가 안 보이는 곳으로 감: 무슨 카드인지는 알지만, 새 iid 는 알려주지 않음
    if (zoneVisible(e.from, viewer)) return { ...e, card: { iid: '', code: e.card.code } };
    return { ...e, card: null };
  });
}
