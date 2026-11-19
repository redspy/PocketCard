// 엔진 공용 처리: 카드 이동, 슬롯, 에너지 비용, HP·후퇴 보정, 데미지 계산, 요청·프레임 도우미
// engine.ts(흐름) 와 effects.ts(카드 효과) 가 같이 쓴다. 모든 함수는 ctx.s(상태 복사본)를 직접 바꾼다.
import type { CardData, EType } from './cardData.ts';
import { coin, shuffleInPlace } from './rng.ts';
import type {
  CardInfo, CardInst, Frame, GameEvent, GameState, PendingRequest, PokemonSlot, RequestKind, Seat, Zone,
} from './types.ts';
import { GameError } from './types.ts';

export type Ctx = { s: GameState; ev: GameEvent[]; info: CardInfo };
export const other = (p: Seat): Seat => (p === 0 ? 1 : 0);
export const BENCH_MAX = 5;

type EventBody = GameEvent extends infer E ? (E extends GameEvent ? Omit<E, 'seq'> : never) : never;
export function emit(ctx: Ctx, e: EventBody) {
  ctx.s.eventSeq += 1;
  ctx.ev.push({ ...e, seq: ctx.s.eventSeq } as GameEvent);
}
export const newId = (s: GameState, prefix: string) => `${prefix}${s.nextId++}`;
export const note = (ctx: Ctx, text: string) => emit(ctx, { type: 'note', text });

// ───────────────────────── 카드 조회 ─────────────────────────

export const inst = (ctx: Ctx, iid: string): CardInst => ctx.s.cards[iid];
export const dataOf = (ctx: Ctx, iid: string): CardData => {
  const d = ctx.info.db[ctx.s.cards[iid]?.ruleId];
  if (!d) throw new GameError('no_card_data', `카드 데이터 없음: ${ctx.s.cards[iid]?.ruleId}`);
  return d;
};
export const nameOf = (ctx: Ctx, iid: string) => dataOf(ctx, iid).name;
export const topOf = (slot: PokemonSlot) => slot.stack[slot.stack.length - 1];
export const slotData = (ctx: Ctx, slot: PokemonSlot) => dataOf(ctx, topOf(slot));
export const slotName = (ctx: Ctx, slot: PokemonSlot) => slotData(ctx, slot).name;

/** 필드의 포켓몬 (배틀 먼저) */
export function slotsOf(s: GameState, seat: Seat): PokemonSlot[] {
  const p = s.players[seat];
  return p.active ? [p.active, ...p.bench] : [...p.bench];
}
export function findSlot(s: GameState, sid: string): { slot: PokemonSlot; owner: Seat; active: boolean } | null {
  for (const seat of [0, 1] as Seat[]) {
    const p = s.players[seat];
    if (p.active?.sid === sid) return { slot: p.active, owner: seat, active: true };
    const b = p.bench.find((x) => x.sid === sid);
    if (b) return { slot: b, owner: seat, active: false };
  }
  return null;
}
export const isActive = (s: GameState, slot: PokemonSlot) => s.players[0].active === slot || s.players[1].active === slot;
export const ownerOfSlot = (s: GameState, slot: PokemonSlot): Seat => (s.players[0].active === slot || s.players[0].bench.includes(slot) ? 0 : 1);

// ───────────────────────── 카드 이동 ─────────────────────────

export function locate(s: GameState, iid: string): { player: Seat; zone: Zone } | null {
  for (const seat of [0, 1] as Seat[]) {
    const p = s.players[seat];
    if (p.deck.includes(iid)) return { player: seat, zone: 'deck' };
    if (p.hand.includes(iid)) return { player: seat, zone: 'hand' };
    if (p.prizes.includes(iid)) return { player: seat, zone: 'prizes' };
    if (p.discard.includes(iid)) return { player: seat, zone: 'discard' };
    if (p.lost.includes(iid)) return { player: seat, zone: 'lost' };
    if (p.active && (p.active.stack.includes(iid) || p.active.attached.includes(iid))) return { player: seat, zone: 'active' };
    if (p.bench.some((b) => b.stack.includes(iid) || b.attached.includes(iid))) return { player: seat, zone: 'bench' };
  }
  if (s.stadium === iid) return { player: s.cards[iid].owner, zone: 'stadium' };
  if (s.using.includes(iid)) return { player: s.cards[iid].owner, zone: 'reveal' };
  return null;
}

function removeFrom(s: GameState, iid: string): { player: Seat; zone: Zone } {
  const loc = locate(s, iid);
  if (!loc) throw new GameError('card_missing', `카드 ${iid} 를 찾을 수 없습니다.`);
  const p = s.players[loc.player];
  const drop = (arr: (string | null)[]) => { const i = arr.indexOf(iid); if (i >= 0) arr.splice(i, 1); };
  switch (loc.zone) {
    case 'deck': drop(p.deck); break;
    case 'hand': drop(p.hand); break;
    case 'prizes': { const i = p.prizes.indexOf(iid); p.prizes[i] = null; break; }
    case 'discard': drop(p.discard); break;
    case 'lost': drop(p.lost); break;
    case 'stadium': s.stadium = null; break;
    case 'reveal': drop(s.using); break;
    case 'active':
    case 'bench': {
      const slot = loc.zone === 'active' ? p.active! : p.bench.find((b) => b.stack.includes(iid) || b.attached.includes(iid))!;
      drop(slot.stack); drop(slot.attached);
      if (slot.stack.length === 0) {
        if (slot.attached.length) throw new GameError('slot_not_empty', '붙은 카드가 남은 채로 포켓몬을 옮길 수 없습니다.');
        if (loc.zone === 'active') p.active = null; else p.bench.splice(p.bench.indexOf(slot), 1);
      }
      break;
    }
    default: throw new GameError('bad_zone', String(loc.zone));
  }
  return loc;
}

export function newSlot(s: GameState, iid: string, faceDown = false): PokemonSlot {
  return { sid: newId(s, 's'), stack: [iid], attached: [], damage: 0, faceDown, enteredTurn: s.turnNumber, abilityTurn: -1,
    cond: { poison: 0, burn: false, rot: '', paraUntil: 0 }, effects: [] };
}

export type Dest =
  | { zone: 'deck'; player: Seat; position: 'top' | 'bottom' }
  | { zone: 'hand' | 'discard' | 'lost'; player: Seat }
  | { zone: 'prizes'; player: Seat; index: number }
  | { zone: 'active' | 'bench'; player: Seat; faceDown?: boolean }
  | { zone: 'attach'; sid: string }               // 포켓몬에 붙이기 (에너지·도구)
  | { zone: 'evolve'; sid: string }               // 포켓몬 위에 올리기 (진화)
  | { zone: 'stadium' }
  | { zone: 'reveal' };                           // 사용 중 (트레이너스)

/** 카드를 옮기고 새 iid 를 돌려준다 */
export function moveCard(ctx: Ctx, iid: string, dest: Dest): string {
  const { s } = ctx;
  const from = removeFrom(s, iid);
  const old = s.cards[iid];
  delete s.cards[iid];
  const nid = newId(s, 'c');
  s.cards[nid] = { ...old, iid: nid };
  let to: { player: Seat; zone: Zone };
  let faceDown = false;
  switch (dest.zone) {
    case 'deck': { const p = s.players[dest.player]; if (dest.position === 'top') p.deck.unshift(nid); else p.deck.push(nid); to = { player: dest.player, zone: 'deck' }; break; }
    case 'hand': s.players[dest.player].hand.push(nid); to = { player: dest.player, zone: 'hand' }; break;
    case 'discard': s.players[dest.player].discard.push(nid); to = { player: dest.player, zone: 'discard' }; break;
    case 'lost': s.players[dest.player].lost.push(nid); to = { player: dest.player, zone: 'lost' }; break;
    case 'prizes': s.players[dest.player].prizes[dest.index] = nid; to = { player: dest.player, zone: 'prizes' }; break;
    case 'active':
    case 'bench': {
      const p = s.players[dest.player];
      const slot = newSlot(s, nid, !!dest.faceDown);
      faceDown = !!dest.faceDown;
      if (dest.zone === 'active') {
        if (p.active) throw new GameError('active_taken', '이미 배틀 포켓몬이 있습니다.');
        p.active = slot;
      } else {
        if (p.bench.length >= p.benchMax) throw new GameError('bench_full', '벤치가 가득 찼습니다.');
        p.bench.push(slot);
      }
      to = { player: dest.player, zone: dest.zone };
      break;
    }
    case 'attach':
    case 'evolve': {
      const f = findSlot(s, dest.sid);
      if (!f) throw new GameError('no_slot', '대상 포켓몬이 없습니다.');
      if (dest.zone === 'attach') f.slot.attached.push(nid);
      else {
        f.slot.stack.push(nid);
        f.slot.enteredTurn = s.turnNumber;
        f.slot.abilityTurn = -1;
        f.slot.cond = { poison: 0, burn: false, rot: '', paraUntil: 0 };
        f.slot.effects = [];
      }
      to = { player: f.owner, zone: f.active ? 'active' : 'bench' };
      break;
    }
    case 'stadium': s.stadium = nid; to = { player: old.owner, zone: 'stadium' }; break;
    case 'reveal': s.using.push(nid); to = { player: old.owner, zone: 'reveal' }; break;
  }
  emit(ctx, { type: 'move', card: { iid: nid, code: old.code }, from, to, ...(faceDown ? { faceDown } : {}) });
  return nid;
}

/** 포켓몬과 붙은 카드 전부를 트래쉬 (기절) 또는 패로 */
export function clearSlot(ctx: Ctx, slot: PokemonSlot, owner: Seat, to: 'discard' | 'hand') {
  for (const a of [...slot.attached]) moveCard(ctx, a, { zone: 'discard', player: owner });
  for (const c of [...slot.stack]) {
    const isPokemon = dataOf(ctx, c).kind === 'pokemon';
    moveCard(ctx, c, { zone: to === 'hand' && isPokemon ? 'hand' : 'discard', player: owner });
  }
}

export function shuffleDeck(ctx: Ctx, seat: Seat) {
  const p = ctx.s.players[seat];
  shuffleInPlace(ctx.s.rng, p.deck);
  // 셔플 후에는 덱 안 카드의 iid 도 새로 발급 (셔플 전 위치 추적 방지)
  p.deck = p.deck.map((iid) => {
    const c = ctx.s.cards[iid];
    delete ctx.s.cards[iid];
    const nid = newId(ctx.s, 'c');
    ctx.s.cards[nid] = { ...c, iid: nid };
    return nid;
  });
  emit(ctx, { type: 'shuffle', player: seat });
}

export function drawOne(ctx: Ctx, seat: Seat): boolean {
  const top = ctx.s.players[seat].deck[0];
  if (!top) return false;
  moveCard(ctx, top, { zone: 'hand', player: seat });
  return true;
}
export const drawN = (ctx: Ctx, seat: Seat, n: number) => { for (let i = 0; i < n; i++) if (!drawOne(ctx, seat)) break; };

export function flip(ctx: Ctx, seat: Seat, reason: string): boolean {
  const heads = coin(ctx.s.rng);
  emit(ctx, { type: 'coin', player: seat, heads, reason });
  return heads;
}

/** 배틀 포켓몬과 벤치 포켓몬을 맞바꾼다 (교체: 특수상태·포켓몬 효과는 사라짐) */
export function switchActive(ctx: Ctx, seat: Seat, benchSid: string) {
  const p = ctx.s.players[seat];
  const i = p.bench.findIndex((b) => b.sid === benchSid);
  if (i < 0 || !p.active) throw new GameError('bad_switch', '교체할 포켓몬이 없습니다.');
  const old = p.active;
  old.cond = { poison: 0, burn: false, rot: '', paraUntil: 0 };
  old.effects = [];
  p.active = p.bench[i];
  p.bench[i] = old;
  emit(ctx, { type: 'switch', player: seat, from: old.sid, to: p.active.sid });
}

// ───────────────────────── 요청 / 프레임 ─────────────────────────

export function request(ctx: Ctx, player: Seat, kind: RequestKind, options: string[], min: number, max: number, prompt: string, extra: Partial<PendingRequest> = {}): PendingRequest {
  const r: PendingRequest = { id: newId(ctx.s, 'r'), player, kind, options, min, max, prompt, ...extra };
  ctx.s.requests.push(r);
  return r;
}

export function pushFrame(ctx: Ctx, kind: string, player: Seat, data: Record<string, unknown> = {}): Frame {
  const f: Frame = { id: newId(ctx.s, 'f'), kind, step: 0, player, data };
  ctx.s.stack.push(f);
  return f;
}

/** 프레임에서 선택을 요청하고 멈춘다 (답이 오면 frame.picks 에 담겨 같은 프레임이 다시 실행됨) */
export function ask(ctx: Ctx, f: Frame, nextStep: number, player: Seat, kind: RequestKind, options: string[], min: number, max: number, prompt: string, extra: Partial<PendingRequest> = {}) {
  f.step = nextStep;
  f.picks = undefined;
  request(ctx, player, kind, options, Math.min(min, options.length), Math.min(max, options.length), prompt, { ...extra, frame: f.id });
}

// ───────────────────────── 상태 판정 ─────────────────────────

export const stadiumName = (ctx: Ctx) => (ctx.s.stadium ? nameOf(ctx, ctx.s.stadium) : null);
export const toolsActive = (ctx: Ctx) => stadiumName(ctx) !== '재밍타워';
/** 신오신전: 포켓몬에게 붙은 특수 에너지의 효과가 모두 없어지고 무색 1개분 */
export const specialEnergyOff = (ctx: Ctx) => stadiumName(ctx) === '신오신전';
export const toolOf = (ctx: Ctx, slot: PokemonSlot) => slot.attached.find((a) => dataOf(ctx, a).kind === 'trainer') ?? null;
export const toolName = (ctx: Ctx, slot: PokemonSlot) => { const t = toolOf(ctx, slot); return t && toolsActive(ctx) ? nameOf(ctx, t) : null; };
export const energiesOf = (ctx: Ctx, slot: PokemonSlot) => slot.attached.filter((a) => dataOf(ctx, a).kind === 'energy');

/** 클레피 "장난 잠금": 양쪽 배틀 필드 어디든 클레피가 있으면 기본 포켓몬의 특성(장난 잠금 제외)이 없어진다 */
export function abilityActive(ctx: Ctx, slot: PokemonSlot): boolean {
  const d = slotData(ctx, slot);
  if (!d.pokemon?.abilities.length || slot.faceDown) return false;
  // 정상으로 가는 눈길: 서로의 룰을 가진 포켓몬의 특성은 모두 없어진다
  if (d.pokemon.rule !== null && stadiumName(ctx) === '정상으로 가는 눈길') return false;
  if (d.pokemon.stage !== 0 || d.pokemon.abilities[0].nameJa === 'いたずらロック') return true;
  for (const seat of [0, 1] as Seat[]) {
    const a = ctx.s.players[seat].active;
    if (a && !a.faceDown && slotData(ctx, a).pokemon?.abilities[0]?.nameJa === 'いたずらロック') return false;
  }
  return true;
}
export const hasAbility = (ctx: Ctx, slot: PokemonSlot, nameJa: string) => slotData(ctx, slot).pokemon?.abilities[0]?.nameJa === nameJa && abilityActive(ctx, slot);
/** 이 플레이어 필드에 특성이 켜진 포켓몬이 있는가 */
export const fieldHasAbility = (ctx: Ctx, seat: Seat, nameJa: string) => slotsOf(ctx.s, seat).some((sl) => hasAbility(ctx, sl, nameJa));
export const hasTera = (ctx: Ctx, seat: Seat) => slotsOf(ctx.s, seat).some((sl) => slotData(ctx, sl).pokemon?.tera);

export function maxHp(ctx: Ctx, slot: PokemonSlot): number {
  const p = slotData(ctx, slot).pokemon!;
  let hp = p.hp;
  if (toolName(ctx, slot) === '용기의부적' && p.stage === 0) hp += 50;
  if (stadiumName(ctx) === '그래비티 마운틴' && p.stage === 2) hp -= 30;
  return hp;
}
export const remainingHp = (ctx: Ctx, slot: PokemonSlot) => maxHp(ctx, slot) - slot.damage;

export function retreatCost(ctx: Ctx, slot: PokemonSlot, seat: Seat): number {
  const p = slotData(ctx, slot).pokemon!;
  let c = p.retreat;
  const tool = toolName(ctx, slot);
  if (tool === '풍선') c -= 2;
  if (tool === '부스트에너지 미래' && p.future) c = 0;
  if (p.stage === 0 && fieldHasAbility(ctx, seat, 'スカイライン')) c = 0;
  if (hasAbility(ctx, slot, 'みがる') && energiesOf(ctx, slot).length === 0) c = 0;
  return Math.max(0, c);
}

/** 붙은 에너지가 제공하는 에너지 단위. '*' = 모든 타입 */
export type EUnit = EType | '*' | 'FD';   // 'FD' = 격투 또는 악 1개 (일격 에너지)
export function provided(ctx: Ctx, slot: PokemonSlot): EUnit[] {
  const out: EUnit[] = [];
  const ens = energiesOf(ctx, slot);
  const specials = ens.filter((e) => !dataOf(ctx, e).energy?.basic);
  const stage = slotData(ctx, slot).pokemon?.stage ?? 0;
  for (const e of ens) {
    const d = dataOf(ctx, e);
    if (d.energy?.basic && d.energy.type) { out.push(d.energy.type); continue; }
    if (specialEnergyOff(ctx)) { out.push('C'); continue; }
    switch (d.name) {
      case '제트 에너지': case '캡쳐 에너지': out.push('C'); break;
      case '일격 에너지': out.push('FD'); break;
      case '루미너스 에너지': out.push(specials.length > 1 ? 'C' : '*'); break;
      case '네오 어퍼 에너지': if (stage === 2) out.push('*', '*'); else out.push('C'); break;
      default: out.push('C');
    }
  }
  return out;
}

/** 비용을 낼 수 있는가 (특정 타입부터 맞추고, 무색은 남은 것으로) */
export function canPay(units: EUnit[], cost: EType[]): boolean {
  const pool = [...units];
  const specific = cost.filter((c) => c !== 'C');
  const colorless = cost.length - specific.length;
  for (const t of specific) {
    let i = pool.indexOf(t);
    if (i < 0) i = pool.findIndex((u) => u.length === 2 && u.includes(t));
    if (i < 0) i = pool.indexOf('*');
    if (i < 0) return false;
    pool.splice(i, 1);
  }
  return pool.length >= colorless;
}

/** 기술 비용 (카드 효과로 줄어든 것 반영) */
export function attackCost(ctx: Ctx, slot: PokemonSlot, seat: Seat, cost: EType[], attackJa: string): EType[] {
  let c = [...cost];
  const d = slotData(ctx, slot).pokemon!;
  const dropOne = () => { const i = c.lastIndexOf('C'); if (i >= 0) c.splice(i, 1); else c.pop(); };
  if (toolName(ctx, slot) === '반짝이는 결정' && d.tera) dropOne();
  // 윽우지 "로스트 프로바이드": 로스트존 4장 이상이면 기술 에너지가 모두 없어짐
  if (hasAbility(ctx, slot, '로스트 프로바이드') && ctx.s.players[seat].lost.length >= 4) return [];
  // 드래피온 V "와일드스타일": 상대 필드의 일격·연격·퓨전 포켓몬 수만큼 무색 에너지가 적어짐
  if (hasAbility(ctx, slot, '와일드스타일')) {
    const n = slotsOf(ctx.s, other(seat)).filter((sl) => !sl.faceDown && (slotData(ctx, sl).tags ?? []).some((t) => t === '일격' || t === '연격' || t === '퓨전')).length;
    for (let i = 0; i < n; i++) { const j = c.lastIndexOf('C'); if (j >= 0) c.splice(j, 1); }
  }
  if (attackJa === 'ブラッドムーン' && hasAbility(ctx, slot, 'ろうれんのわざ')) {
    const taken = prizesTaken(ctx.s, other(seat));
    for (let i = 0; i < taken; i++) { const j = c.lastIndexOf('C'); if (j >= 0) c.splice(j, 1); }
  }
  return c;
}

export const lostCount = (s: GameState, seat: Seat) => s.players[seat].lost.length;
export const prizesLeft = (s: GameState, seat: Seat) => s.players[seat].prizes.filter(Boolean).length;
export const prizesTaken = (s: GameState, seat: Seat) => 6 - prizesLeft(s, seat);
export const playerHasEffect = (s: GameState, seat: Seat, kind: string) => s.players[seat].effects.some((e) => e.kind === kind);
export const slotHasEffect = (slot: PokemonSlot, kind: string) => slot.effects.some((e) => e.kind === kind);

// ───────────────────────── 데미지 ─────────────────────────

/**
 * 기술 데미지를 준다 (규칙서 데미지 계산 순서).
 * base: 기술 데미지(+, × 반영 후), wr: 약점·저항력 계산 여부(상대 배틀 포켓몬에게만 true)
 */
export type DamageOpts = { ignoreEffects?: boolean; noWeak?: boolean };
export function dealAttackDamage(ctx: Ctx, seat: Seat, atk: PokemonSlot, target: PokemonSlot, base: number, wr: boolean, opts: DamageOpts = {}) {
  const { s } = ctx;
  const tOwner = ownerOfSlot(s, target);
  const tActive = isActive(s, target);
  const ad = slotData(ctx, atk).pokemon!;
  const td = slotData(ctx, target).pokemon!;
  let dmg = base;
  if (dmg <= 0) return 0;
  // 테라스탈 룰: 벤치의 테라스탈 포켓몬은 기술 데미지를 받지 않는다
  if (!tActive && td.tera) { note(ctx, `${slotName(ctx, target)}: 테라스탈 — 벤치에서는 기술 데미지를 받지 않음`); return 0; }
  const onOppActive = tActive && tOwner !== seat;
  // 뮤 "벤치배리어"·마나피 "파도의 베일": 상대 기술로 벤치 포켓몬은 데미지를 받지 않는다
  if (!tActive && tOwner !== seat && (fieldHasAbility(ctx, tOwner, '벤치배리어') || fieldHasAbility(ctx, tOwner, '파도의 베일'))) {
    note(ctx, `${slotName(ctx, target)}: 벤치 포켓몬은 상대 기술의 데미지를 받지 않음`);
    return 0;
  }
  // 2) 공격하는 쪽 효과
  if (onOppActive) {
    const tRule = td.rule !== null;
    if (playerHasEffect(s, seat, 'boostExV30') && tRule) dmg += 30;
    if (playerHasEffect(s, seat, 'boostEx40') && tRule) dmg += 40;
    const tool = toolName(ctx, atk);
    if (tool === '오기머리띠' && prizesLeft(s, seat) > prizesLeft(s, other(seat))) dmg += 30;
    if (tool === '부스트에너지 미래' && ad.future) dmg += 20;
    if (hasAbility(ctx, atk, 'ふくがん') && td.abilities.length > 0) dmg += 50;
    // 일격 에너지: 붙인 포켓몬의 기술이 상대 배틀 포켓몬에게 주는 데미지 +20 (장마다)
    if (!specialEnergyOff(ctx)) dmg += 20 * energiesOf(ctx, atk).filter((e) => nameOf(ctx, e) === '일격 에너지').length;
  }
  if (dmg <= 0) return 0;
  // 3) 약점 4) 저항력 (연출용으로 적용 여부를 사건에 남김)
  let wHit = false, rHit = false;
  if (wr && onOppActive) {
    // 릴리에의 삐삐 ex "페어리존": 상대 필드의 드래곤 타입 포켓몬의 약점은 초 타입
    const weak = td.type === 'N' && fieldHasAbility(ctx, seat, 'フェアリーゾーン') ? 'P' : td.weak;
    if (weak && weak === ad.type && !opts.noWeak) { dmg *= 2; wHit = true; }
    if (td.resist && td.resist === ad.type) { dmg -= td.resistValue ?? 30; rHit = true; }
    if (dmg <= 0) return 0;
  }
  // 5) 받는 쪽 효과 ("상대 배틀 포켓몬에게 걸려 있는 효과를 계산하지 않는" 기술은 건너뜀)
  if (tOwner !== seat && !(opts.ignoreEffects && tActive)) {
    if (slotHasEffect(target, 'reduce30')) dmg -= 30;
    if (hasAbility(ctx, target, 'ダイヤコート')) dmg -= 30;
    if (slotHasEffect(target, 'immuneBasicNonC') && ad.stage === 0 && ad.type !== 'C') { note(ctx, `${slotName(ctx, target)}: 기본 포켓몬의 기술 데미지를 받지 않음`); return 0; }
  }
  if (dmg <= 0) return 0;
  // 피카츄 ex "버티는 하트": HP 만땅에서 기술 데미지로 기절할 때 HP 10 으로 남음
  const hp = maxHp(ctx, target);
  if (target.damage === 0 && target.damage + dmg >= hp && hasAbility(ctx, target, 'がんばりハート')) {
    dmg = hp - 10;
    note(ctx, `${slotName(ctx, target)}: 버티는 하트 — HP 10 으로 남음`);
  }
  target.damage += dmg;
  const ev: { type: 'damage'; player: Seat; sid: string; amount: number; weak?: boolean; resist?: boolean } = { type: 'damage', player: tOwner, sid: target.sid, amount: dmg };
  if (wHit) ev.weak = true;
  if (rHit) ev.resist = true;
  emit(ctx, ev);
  return dmg;
}

/** 데미지 카운터 올리기 (데미지가 아님: 약점·저항력·데미지 증감 무시) */
export function putCounters(ctx: Ctx, target: PokemonSlot, n: number) {
  if (n <= 0) return;
  target.damage += n * 10;
  emit(ctx, { type: 'damage', player: ownerOfSlot(ctx.s, target), sid: target.sid, amount: n * 10, counters: true });
}

export function heal(ctx: Ctx, target: PokemonSlot, amount: number) {
  const h = Math.min(amount, target.damage);
  if (h <= 0) return;
  target.damage -= h;
  emit(ctx, { type: 'heal', player: ownerOfSlot(ctx.s, target), sid: target.sid, amount: h });
}

export function setRot(ctx: Ctx, target: PokemonSlot, rot: 'asleep' | 'paralyzed' | 'confused') {
  target.cond.rot = rot;
  if (rot === 'paralyzed') target.cond.paraUntil = ctx.s.turnNumber + 1;
  emit(ctx, { type: 'condition', player: ownerOfSlot(ctx.s, target), sid: target.sid, cond: rot, on: true });
}
