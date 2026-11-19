// 카드 효과 (6개 덱의 트레이너스·특성·기술) — 프레임 처리기로 구현
// 프레임 처리기 규칙: (ctx, f) 를 받아 ① done(ctx,f) 로 끝내거나 ② ask(...) 로 선택을 요청하고 멈추거나
//                    ③ seq(...) 로 하위 프레임을 쌓고 다음 단계로 넘어간다. 상태는 f.step / f.data 에만 둔다(직렬화 가능).
import type { CardData, EType } from './cardData.ts';
import {
  abilityActive, ask, clearSlot, dataOf, dealAttackDamage, drawN, drawOne, emit, energiesOf, findSlot, flip, hasTera, heal,
  inst, isActive, maxHp, moveCard, nameOf, note, other, ownerOfSlot, playerHasEffect, prizesLeft, prizesTaken, provided, putCounters,
  remainingHp, setRot, shuffleDeck, slotData, slotName, slotsOf, stadiumName, switchActive, toolOf, topOf, lostCount,
} from './core.ts';
import { shuffleInPlace } from './rng.ts';
import type { Ctx } from './core.ts';
import type { Frame, PokemonSlot, Seat } from './types.ts';

export type Handler = (ctx: Ctx, f: Frame) => void;

export function done(ctx: Ctx, f: Frame) {
  const i = ctx.s.stack.lastIndexOf(f);
  if (i >= 0) ctx.s.stack.splice(i, 1);
}
/** 하위 프레임들을 순서대로 실행한 뒤 이 프레임을 nextStep 으로 다시 실행 */
export function seq(ctx: Ctx, f: Frame, nextStep: number, children: [string, Record<string, unknown>][]) {
  f.step = nextStep;
  for (let i = children.length - 1; i >= 0; i--) {
    ctx.s.stack.push({ id: `f${ctx.s.nextId++}`, kind: children[i][0], step: 0, player: f.player, data: { ...children[i][1], parent: f.id } });
  }
}
/** 하위 프레임만 쌓고 이 프레임은 끝냄 */
export function then(ctx: Ctx, f: Frame, children: [string, Record<string, unknown>][]) {
  // 부모는 여기서 끝나므로 출처(어떤 카드·특성·기술인지)를 자식에게 물려준다 (공개 이유 표시용)
  const src = frameSource(ctx, f);
  done(ctx, f);
  for (let i = children.length - 1; i >= 0; i--) {
    ctx.s.stack.push({ id: `f${ctx.s.nextId++}`, kind: children[i][0], step: 0, player: f.player, data: { ...children[i][1], ...(src ? { src } : {}) } });
  }
}
const parentOf = (ctx: Ctx, f: Frame) => ctx.s.stack.find((x) => x.id === f.data.parent);

// ───────────────────────── 카드 조건 (필터) ─────────────────────────

export type Filter = {
  kind?: 'pokemon' | 'trainer' | 'energy';
  stage?: 0 | 1 | 2;
  evolution?: boolean;
  basicEnergy?: boolean;
  etype?: EType;
  ptype?: EType;
  maxHp?: number;
  tera?: boolean;
  ex?: boolean;
  noRule?: boolean;
  trainer?: 'item' | 'tool' | 'supporter' | 'stadium';
  name?: string;
  or?: Filter[];
};

export function matches(d: CardData, flt: Filter): boolean {
  if (flt.or) return flt.or.some((x) => matches(d, x));
  if (flt.kind && d.kind !== flt.kind) return false;
  const p = d.pokemon;
  if (flt.stage !== undefined && (!p || p.stage !== flt.stage)) return false;
  if (flt.evolution && (!p || p.stage === 0)) return false;
  if (flt.basicEnergy && !d.energy?.basic) return false;
  if (flt.etype && d.energy?.type !== flt.etype) return false;
  if (flt.ptype && p?.type !== flt.ptype) return false;
  if (flt.maxHp !== undefined && (!p || p.hp > flt.maxHp)) return false;
  if (flt.tera && !p?.tera) return false;
  if (flt.ex && (!p || p.rule === null)) return false;
  if (flt.noRule && (!p || p.rule !== null)) return false;
  if (flt.trainer && d.trainer !== flt.trainer) return false;
  if (flt.name && d.name !== flt.name) return false;
  return true;
}
const cardsMatching = (ctx: Ctx, iids: string[], flt: Filter) => iids.filter((i) => matches(dataOf(ctx, i), flt));
const cardsOf = (ctx: Ctx, iids: string[]) => iids.map((iid) => ({ iid, code: inst(ctx, iid).code }));

// ───────────────────────── 공용 프레임 ─────────────────────────

export const FRAMES: Record<string, Handler> = {};

/**
 * 카드 고르기 (덱·트래쉬): data = { from, filter, min, max, to, reveal, shuffle, prompt, distinct, look, exclude, save }
 *  to: 'hand' | 'bench' | 'deck'(덱으로 되돌림) | 'attach'(고른 뒤 붙일 포켓몬을 한 장씩 고름) | 'top'(덱 위, 순서 고르기) | 'save'(부모 data[save] 에 iid 저장)
 */
/** 이 프레임이 나타내는 카드·특성·기술 이름 (없으면 null) */
export function frameSource(ctx: Ctx, fr: Frame): string | null {
  if (typeof fr.data.src === 'string') return fr.data.src;
  if (fr.kind === 'trainerRun') return `트레이너스 [${String(fr.data.name ?? '')}]`;
  if (fr.kind === 'trigger') {
    // 조건이 되면 발동하는 특성 (진화했을 때 등)
    const found = findSlot(ctx.s, String(fr.data.sid ?? ''));
    const name = { infernalReign: '연옥 지배', jewelSeeker: '보석 찾기', flyingEntry: '플라잉엔트리', rapidVernier: '래피드 버니어', darkSignal: '다크시그널', luminousSign: '루미너스사인' }[String(fr.data.effect)] ?? '';
    return `${found ? slotName(ctx, found.slot) : '포켓몬'}의 특성${name ? ` [${name}]` : ''} (조건이 되어 발동)`;
  }
  if (fr.kind === 'abilityRun' || fr.kind === 'attack' || fr.kind === 'attackEffect') {
    const found = findSlot(ctx.s, String(fr.data.sid ?? ''));
    const who = found ? slotName(ctx, found.slot) : '포켓몬';
    const pk = found ? slotData(ctx, found.slot).pokemon : undefined;
    if (fr.kind === 'abilityRun') {
      const ab = pk?.abilities.find((a) => a.nameJa === fr.data.ab);
      return `${who}의 특성 [${ab?.name || String(fr.data.ab ?? '')}]`;
    }
    const at = pk?.attacks.find((a) => a.nameJa === fr.data.attackJa);
    return `${who}의 기술 [${at?.name || String(fr.data.attackJa ?? '')}]`;
  }
  return null;
}

/** 지금 처리 중인 효과의 출처 (스택을 위에서부터 보고 가장 가까운 카드·특성·기술) */
export function effectSource(ctx: Ctx): string {
  for (let i = ctx.s.stack.length - 1; i >= 0; i--) {
    const label = frameSource(ctx, ctx.s.stack[i]);
    if (label) return label;
  }
  return '카드 효과';
}
const ZONE_KO: Record<string, string> = { deck: '덱', discard: '트래쉬', hand: '패' };
const TO_KO: Record<string, string> = { hand: '패로 가져갑니다', bench: '벤치에 내놓습니다', deck: '덱으로 되돌립니다', attach: '포켓몬에게 붙입니다', top: '덱 위에 놓습니다', save: '사용합니다' };

/** 공개 이유: 무엇이(출처) · 어디서 무엇을 찾아 · 어디로, 그리고 왜 보여주는지 (규칙) */
function revealReason(ctx: Ctx, d: { from: string; to: string; prompt?: string; look?: number }): string {
  const what = (d.prompt ?? '카드').replace(/\s*(을|를)?\s*고르세요\.?$/, '').replace(/\.$/, '');
  const from = d.look ? `덱 위 ${d.look}장` : ZONE_KO[d.from] ?? d.from;
  const why = d.from === 'deck'
    ? '덱에서 정해진 종류의 카드를 찾으면, 조건에 맞는 카드인지 상대에게 보여줘야 합니다.'
    : d.from === 'discard'
      ? '트래쉬에서 가져가는 카드는 무엇인지 상대에게 보여줍니다.'
      : '효과로 고른 카드를 상대에게 보여줍니다.';
  return `${effectSource(ctx)}: ${from}에서 [${what}] → ${TO_KO[d.to] ?? '사용합니다'}\n${why}`;
}

FRAMES.search = (ctx, f) => {
  const d = f.data as { from: 'deck' | 'discard' | 'hand'; filter: Filter; min?: number; max: number; to: string; reveal?: boolean; shuffle?: boolean; prompt?: string; distinct?: 'type'; look?: number; exclude?: string[]; save?: string; attachTo?: string; attachWho?: 'own' };
  const p = ctx.s.players[f.player];
  if (f.step === 0) {
    const zone = d.from === 'deck' ? p.deck : d.from === 'discard' ? p.discard : p.hand;
    const pool = d.look ? zone.slice(0, d.look) : zone;
    const opts = cardsMatching(ctx, pool, d.filter).filter((i) => !(d.exclude ?? []).includes(i));
    let max = d.max;
    if (d.to === 'bench') max = Math.min(max, p.benchMax - p.bench.length);
    if (max <= 0 || opts.length === 0) {
      if (d.from === 'deck' && pool.length && opts.length === 0) note(ctx, '조건에 맞는 카드가 없습니다.');
      f.step = 2;
      if (d.from === 'deck' && d.shuffle !== false) shuffleDeck(ctx, f.player);
      return done(ctx, f);
    }
    // 덱을 보는 효과: 고르는 사람에게만 보이는 카드 목록(보기 범위 전체)을 함께 보낸다
    const shown = d.from === 'deck' ? cardsOf(ctx, pool) : cardsOf(ctx, opts);
    return ask(ctx, f, 1, f.player, 'pickCards', opts, d.min ?? 0, max, d.prompt ?? '카드를 고르세요.', { cards: shown });
  }
  if (f.step === 1) {
    let picks = f.picks ?? [];
    if (d.distinct === 'type') {
      // 서로 다른 타입만 (같은 타입이면 앞의 것만)
      const seen = new Set<string>();
      picks = picks.filter((i) => { const t = dataOf(ctx, i).energy?.type ?? dataOf(ctx, i).pokemon?.type ?? ''; if (seen.has(t)) return false; seen.add(t); return true; });
    }
    const moved: string[] = [];
    if (d.reveal && picks.length) {
      const rev = { id: `v${ctx.s.nextId++}`, owner: f.player, reason: revealReason(ctx, d), cards: cardsOf(ctx, picks) };
      ctx.s.reveals.push(rev);
      emit(ctx, { type: 'reveal', reveal: rev });
      ctx.s.requests.push({ id: `r${ctx.s.nextId++}`, player: other(f.player), kind: 'ackReveal', options: ['ok'], min: 1, max: 1, prompt: '상대가 보여준 카드를 확인하세요.', revealId: rev.id });
    }
    for (const iid of picks) {
      switch (d.to) {
        case 'hand': moved.push(moveCard(ctx, iid, { zone: 'hand', player: f.player })); break;
        case 'bench': moved.push(moveCard(ctx, iid, { zone: 'bench', player: f.player })); break;
        case 'deck': moved.push(moveCard(ctx, iid, { zone: 'deck', player: f.player, position: 'bottom' })); break;
        case 'attachTo': moved.push(moveCard(ctx, iid, { zone: 'attach', sid: d.attachTo! })); break;
        default: moved.push(iid);
      }
    }
    if (d.to === 'attach') { f.data.pending = picks; f.step = 3; return; }
    if (d.to === 'save') { const par = parentOf(ctx, f); if (par) par.data[d.save!] = picks; }
    if (d.save && d.to !== 'save') { const par = parentOf(ctx, f); if (par) par.data[d.save] = moved; }
    if (d.from === 'deck' && d.shuffle !== false) shuffleDeck(ctx, f.player);
    return done(ctx, f);
  }
  if (f.step === 3 || f.step === 4) {
    // 고른 에너지를 한 장씩 붙일 포켓몬 고르기
    if (f.step === 4 && f.picks?.length) {
      const pend = f.data.pending as string[];
      moveCard(ctx, pend[0], { zone: 'attach', sid: f.picks[0] });
      f.data.pending = pend.slice(1);
    }
    const pend = f.data.pending as string[];
    if (!pend.length) {
      if (d.from === 'deck' && d.shuffle !== false) shuffleDeck(ctx, f.player);
      return done(ctx, f);
    }
    const slots = d.attachTo ? [d.attachTo] : slotsOf(ctx.s, f.player).map((s) => s.sid);
    return ask(ctx, f, 4, f.player, 'pickSlot', slots, 1, 1, `${nameOf(ctx, pend[0])}을(를) 붙일 포켓몬을 고르세요.`, { cards: cardsOf(ctx, [pend[0]]) });
  }
};

FRAMES.shuffle = (ctx, f) => { shuffleDeck(ctx, f.player); done(ctx, f); };
FRAMES.draw = (ctx, f) => { drawN(ctx, f.player, Number(f.data.n)); done(ctx, f); };

/** 패에서 n장 버리기 (비용) — data { n, exclude? , save? } */
FRAMES.discardHand = (ctx, f) => {
  const p = ctx.s.players[f.player];
  const n = Number(f.data.n);
  if (f.step === 0) {
    const opts = p.hand.filter((i) => !(f.data.exclude as string[] | undefined)?.includes(i));
    return ask(ctx, f, 1, f.player, 'pickCards', opts, n, n, `패에서 ${n}장을 트래쉬하세요.`, { cards: cardsOf(ctx, opts) });
  }
  const moved = (f.picks ?? []).map((i) => moveCard(ctx, i, { zone: 'discard', player: f.player }));
  if (f.data.save) { const par = parentOf(ctx, f); if (par) par.data[String(f.data.save)] = moved; }
  done(ctx, f);
};

/** 내 배틀 포켓몬을 벤치와 교체 — data { optional? } */
FRAMES.switchOwn = (ctx, f) => {
  const p = ctx.s.players[f.player];
  if (f.step === 0) {
    if (!p.bench.length || !p.active) return done(ctx, f);
    return ask(ctx, f, 1, f.player, 'pickSlot', p.bench.map((b) => b.sid), f.data.optional ? 0 : 1, 1, '배틀 포켓몬과 바꿀 벤치 포켓몬을 고르세요.');
  }
  if (f.picks?.length) switchActive(ctx, f.player, f.picks[0]);
  done(ctx, f);
};

/** 상대 벤치 포켓몬을 배틀 포켓몬과 교체 (상대 플레이어가 아니라 사용자가 고름) */
FRAMES.gust = (ctx, f) => {
  const opp = other(f.player);
  const p = ctx.s.players[opp];
  if (f.step === 0) {
    if (!p.bench.length) return done(ctx, f);
    return ask(ctx, f, 1, f.player, 'pickSlot', p.bench.map((b) => b.sid), 1, 1, '배틀 필드로 끌어낼 상대 벤치 포켓몬을 고르세요.');
  }
  if (f.picks?.length) switchActive(ctx, opp, f.picks[0]);
  done(ctx, f);
};

/** 예/아니오 — 부모 data[save] = 'yes'|'no' */
FRAMES.yesno = (ctx, f) => {
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickOption', ['yes', 'no'], 1, 1, String(f.data.prompt), { labels: { yes: '예', no: '아니오' } });
  const par = parentOf(ctx, f);
  if (par) par.data[String(f.data.save)] = f.picks?.[0] ?? 'no';
  done(ctx, f);
};

// ───────────────────────── 트레이너스 ─────────────────────────

export type TrainerDef = {
  /** 쓸 수 없으면 이유, 쓸 수 있으면 null */
  can?: (ctx: Ctx, seat: Seat, self: string) => string | null;
  run: Handler;   // f.data.card = 사용 중인 카드 iid
};

const deckN = (ctx: Ctx, seat: Seat) => ctx.s.players[seat].deck.length;
const benchRoom = (ctx: Ctx, seat: Seat) => ctx.s.players[seat].benchMax - ctx.s.players[seat].bench.length;
const handOthers = (ctx: Ctx, seat: Seat, self: string) => ctx.s.players[seat].hand.filter((i) => i !== self).length;
const discardHas = (ctx: Ctx, seat: Seat, flt: Filter) => cardsMatching(ctx, ctx.s.players[seat].discard, flt).length > 0;
const needDeck = (ctx: Ctx, seat: Seat) => (deckN(ctx, seat) > 0 ? null : '덱에 카드가 없습니다.');
const POKEMON: Filter = { kind: 'pokemon' };
const BASIC: Filter = { kind: 'pokemon', stage: 0 };
const BASIC_ENERGY: Filter = { kind: 'energy', basicEnergy: true };
const SUPPORTER: Filter = { kind: 'trainer', trainer: 'supporter' };
const search = (from: string, filter: Filter, max: number, to: string, extra: Record<string, unknown> = {}): [string, Record<string, unknown>] =>
  ['search', { from, filter, max, to, ...extra }];

export const TRAINERS: Record<string, TrainerDef> = {
  '네스트볼': { can: (c, s) => needDeck(c, s) ?? (benchRoom(c, s) > 0 ? null : '벤치가 가득 찼습니다.'),
    run: (c, f) => then(c, f, [search('deck', BASIC, 1, 'bench', { prompt: '벤치에 낼 기본 포켓몬을 고르세요.' })]) },
  '하이퍼볼': { can: (c, s, self) => (handOthers(c, s, self) >= 2 ? null : '패를 2장 트래쉬해야 합니다.'),
    run: (c, f) => then(c, f, [['discardHand', { n: 2 }], search('deck', POKEMON, 1, 'hand', { reveal: true, prompt: '패로 가져올 포켓몬을 고르세요.' })]) },
  '절친 포핀': { can: (c, s) => needDeck(c, s) ?? (benchRoom(c, s) > 0 ? null : '벤치가 가득 찼습니다.'),
    run: (c, f) => then(c, f, [search('deck', { kind: 'pokemon', stage: 0, maxHp: 70 }, 2, 'bench', { prompt: 'HP 70 이하 기본 포켓몬을 2장까지 고르세요.' })]) },
  '테라스탈오브': { can: needDeck, run: (c, f) => then(c, f, [search('deck', { kind: 'pokemon', tera: true }, 1, 'hand', { reveal: true, prompt: '테라스탈 포켓몬을 고르세요.' })]) },
  '카운터 캐처': { can: (c, s) => (prizesLeft(c.s, s) > prizesLeft(c.s, other(s)) ? (c.s.players[other(s)].bench.length ? null : '상대 벤치가 없습니다.') : '내 사이드가 상대보다 많을 때만 쓸 수 있습니다.'),
    run: (c, f) => then(c, f, [['gust', {}]]) },
  '밤의 들것': { can: (c, s) => (discardHas(c, s, { or: [POKEMON, BASIC_ENERGY] }) ? null : '트래쉬에 포켓몬·기본 에너지가 없습니다.'),
    run: (c, f) => then(c, f, [search('discard', { or: [POKEMON, BASIC_ENERGY] }, 1, 'hand', { min: 1, reveal: true, prompt: '패로 가져올 포켓몬 또는 기본 에너지를 고르세요.' })]) },
  '포켓몬 교체': { can: (c, s) => (c.s.players[s].bench.length ? null : '벤치 포켓몬이 없습니다.'), run: (c, f) => then(c, f, [['switchOwn', {}]]) },
  '유리나팔': { can: (c, s) => (!hasTera(c, s) ? '테라스탈 포켓몬이 있어야 합니다.' : !c.s.players[s].bench.length ? '벤치 포켓몬이 없습니다.' : discardHas(c, s, BASIC_ENERGY) ? null : '트래쉬에 기본 에너지가 없습니다.'),
    run: (c, f) => then(c, f, [['glassTrumpet', {}]]) },
  '하솔': { can: needDeck, run: (c, f) => then(c, f, [['crispin', {}]]) },
  '보스의 지령': { can: (c, s) => (c.s.players[other(s)].bench.length ? null : '상대 벤치가 없습니다.'), run: (c, f) => then(c, f, [['gust', {}]]) },
  '모야모': { run: (c, f) => {
    for (const seat of [f.player, other(f.player)] as Seat[]) {
      const p = c.s.players[seat];
      for (const iid of [...p.hand]) moveCard(c, iid, { zone: 'deck', player: seat, position: 'bottom' });
    }
    for (const seat of [f.player, other(f.player)] as Seat[]) drawN(c, seat, prizesLeft(c.s, seat));
    done(c, f);
  } },
  '시아노': { can: needDeck, run: (c, f) => then(c, f, [search('deck', { kind: 'pokemon', ex: true }, 3, 'hand', { reveal: true, prompt: '포켓몬 ex 를 3장까지 고르세요.' })]) },
  '투로박사의 시나리오': { can: (c, s) => (slotsOf(c.s, s).length >= 2 ? null : '필드에 포켓몬이 2마리 이상 있어야 합니다.'), run: (c, f) => then(c, f, [['scoopUp', {}]]) },
  '카지': { run: (c, f) => then(c, f, [['carmine', {}]]) },
  '태권왕의 수련': { run: (c, f) => { c.s.players[f.player].effects.push({ kind: 'boostEx40', until: c.s.turnNumber }); done(c, f); } },
  '브라이어': { can: (c, s) => (prizesLeft(c.s, other(s)) === 2 ? null : '상대 사이드가 2장일 때만 쓸 수 있습니다.'),
    run: (c, f) => { c.s.players[f.player].effects.push({ kind: 'brier', until: c.s.turnNumber }); done(c, f); } },
  '이상한사탕': { run: (c, f) => then(c, f, [['rareCandy', { target: f.data.target }]]) },
  '대단한낚싯대': { can: (c, s) => (discardHas(c, s, { or: [POKEMON, BASIC_ENERGY] }) ? null : '트래쉬에 포켓몬·기본 에너지가 없습니다.'),
    run: (c, f) => then(c, f, [search('discard', { or: [POKEMON, BASIC_ENERGY] }, 3, 'deck', { min: 1, reveal: true, prompt: '덱으로 되돌릴 포켓몬·기본 에너지를 3장까지 고르세요.' }), ['shuffle', {}]]) },
  '프라임 캐처': { can: (c, s) => (c.s.players[other(s)].bench.length ? null : '상대 벤치가 없습니다.'), run: (c, f) => then(c, f, [['gust', {}], ['switchOwn', {}]]) },
  '빛나': { can: needDeck, run: (c, f) => then(c, f, [
    search('deck', { kind: 'pokemon', stage: 0 }, 1, 'hand', { reveal: true, shuffle: false, prompt: '기본 포켓몬 1장' }),
    search('deck', { kind: 'pokemon', stage: 1 }, 1, 'hand', { reveal: true, shuffle: false, prompt: '1진화 포켓몬 1장' }),
    search('deck', { kind: 'pokemon', stage: 2 }, 1, 'hand', { reveal: true, prompt: '2진화 포켓몬 1장' })]) },
  '파이팅공': { can: needDeck, run: (c, f) => then(c, f, [search('deck', { or: [{ kind: 'pokemon', stage: 0, ptype: 'F' }, { kind: 'energy', basicEnergy: true, etype: 'F' }] }, 1, 'hand', { reveal: true, prompt: '격투 기본 포켓몬 또는 기본 격투 에너지' })]) },
  '대지의 그릇': { can: (c, s, self) => (handOthers(c, s, self) >= 1 ? needDeck(c, s) : '패를 1장 트래쉬해야 합니다.'),
    run: (c, f) => then(c, f, [['discardHand', { n: 1 }], search('deck', BASIC_ENERGY, 2, 'hand', { reveal: true, prompt: '기본 에너지를 2장까지 고르세요.' })]) },
  '수퍼 에너지 회수': { can: (c, s, self) => (handOthers(c, s, self) >= 2 ? (discardHas(c, s, BASIC_ENERGY) ? null : '트래쉬에 기본 에너지가 없습니다.') : '패를 2장 트래쉬해야 합니다.'),
    run: (c, f) => then(c, f, [['superRetrieval', {}]]) },
  '페퍼': { can: needDeck, run: (c, f) => then(c, f, [search('deck', { kind: 'trainer', trainer: 'item' }, 1, 'hand', { reveal: true, shuffle: false, prompt: '아이템 1장' }), search('deck', { kind: 'trainer', trainer: 'tool' }, 1, 'hand', { reveal: true, prompt: '포켓몬의 도구 1장' })]) },
  '암호마니아의 해독': { can: needDeck, run: (c, f) => then(c, f, [['cipher', {}]]) },
  '수련의 돌봄': { can: (c, s) => (discardHas(c, s, { or: [{ kind: 'pokemon', noRule: true }, BASIC_ENERGY] }) ? null : '트래쉬에 대상이 없습니다.'),
    run: (c, f) => then(c, f, [search('discard', { or: [{ kind: 'pokemon', noRule: true }, BASIC_ENERGY] }, 3, 'hand', { min: 1, reveal: true, prompt: '룰 없는 포켓몬·기본 에너지를 3장까지' })]) },
  '릴리에의 결심': { run: (c, f) => {
    const p = c.s.players[f.player];
    for (const iid of [...p.hand]) moveCard(c, iid, { zone: 'deck', player: f.player, position: 'top' });
    shuffleDeck(c, f.player);
    drawN(c, f.player, prizesLeft(c.s, f.player) === 6 ? 8 : 6);
    done(c, f);
  } },
  '투희': { can: needDeck, run: (c, f) => then(c, f, [search('deck', { kind: 'pokemon', evolution: true }, 1, 'hand', { reveal: true, shuffle: false, prompt: '진화 포켓몬 1장' }), search('deck', { kind: 'energy' }, 1, 'hand', { reveal: true, prompt: '에너지 1장' })]) },
  '시크릿박스': { can: (c, s, self) => (handOthers(c, s, self) >= 3 ? null : '패를 3장 트래쉬해야 합니다.'),
    run: (c, f) => then(c, f, [['discardHand', { n: 3 }],
      search('deck', { kind: 'trainer', trainer: 'item' }, 1, 'hand', { reveal: true, shuffle: false, prompt: '아이템 1장' }),
      search('deck', { kind: 'trainer', trainer: 'tool' }, 1, 'hand', { reveal: true, shuffle: false, prompt: '포켓몬의 도구 1장' }),
      search('deck', { kind: 'trainer', trainer: 'supporter' }, 1, 'hand', { reveal: true, shuffle: false, prompt: '서포트 1장' }),
      search('deck', { kind: 'trainer', trainer: 'stadium' }, 1, 'hand', { reveal: true, prompt: '스타디움 1장' })]) },
  '포켓기어3.0': { can: needDeck, run: (c, f) => then(c, f, [search('deck', { kind: 'trainer', trainer: 'supporter' }, 1, 'hand', { look: 7, reveal: true, prompt: '덱 위 7장 중 서포트를 1장 가져올 수 있습니다.' })]) },
  '에너지 갈아 달기': { can: (c, s) => (slotsOf(c.s, s).length >= 2 && slotsOf(c.s, s).some((sl) => energiesOf(c, sl).some((e) => dataOf(c, e).energy?.basic)) ? null : '옮길 기본 에너지가 없습니다.'),
    run: (c, f) => then(c, f, [['energySwitch', {}]]) },

  // ── 공식 덱 레시피: 블래키 VMAX · 기라티나 VSTAR ──
  '퀵볼': { can: (c, s, self) => (handOthers(c, s, self) >= 1 ? needDeck(c, s) : '패를 1장 트래쉬해야 합니다.'),
    run: (c, f) => then(c, f, [['discardHand', { n: 1 }], search('deck', BASIC, 1, 'hand', { reveal: true, prompt: '패로 가져올 기본 포켓몬을 고르세요.' })]) },
  '포켓몬통신': { can: (c, s, self) => (c.s.players[s].hand.some((i) => i !== self && dataOf(c, i).kind === 'pokemon') ? null : '패에 덱으로 되돌릴 포켓몬이 없습니다.'),
    run: (c, f) => then(c, f, [search('hand', POKEMON, 1, 'deck', { min: 1, reveal: true, shuffle: false, prompt: '덱으로 되돌릴 패의 포켓몬을 고르세요.' }),
      search('deck', POKEMON, 1, 'hand', { reveal: true, prompt: '패로 가져올 포켓몬을 고르세요.' })]) },
  '진화향로': { can: needDeck, run: (c, f) => then(c, f, [search('deck', { kind: 'pokemon', evolution: true }, 1, 'hand', { reveal: true, prompt: '패로 가져올 진화 포켓몬을 고르세요.' })]) },
  '활력의 항아리': { can: (c, s) => (discardHas(c, s, { name: '일격 에너지' }) ? null : '트래쉬에 일격 에너지가 없습니다.'),
    run: (c, f) => then(c, f, [search('discard', { name: '일격 에너지' }, 2, 'deck', { min: 1, reveal: true, prompt: '덱으로 되돌릴 일격 에너지를 2장까지 고르세요.' }), ['shuffle', {}]]) },
  '보통낚싯대': { can: (c, s) => (discardHas(c, s, { or: [POKEMON, BASIC_ENERGY] }) ? null : '트래쉬에 포켓몬·기본 에너지가 없습니다.'),
    run: (c, f) => then(c, f, [search('discard', POKEMON, 2, 'deck', { reveal: true, prompt: '덱으로 되돌릴 포켓몬을 2장까지 고르세요.' }),
      search('discard', BASIC_ENERGY, 2, 'deck', { reveal: true, prompt: '덱으로 되돌릴 기본 에너지를 2장까지 고르세요.' }), ['shuffle', {}]]) },
  '박사의 연구': { run: (c, f) => {
    const p = c.s.players[f.player];
    for (const iid of [...p.hand]) moveCard(c, iid, { zone: 'discard', player: f.player });
    drawN(c, f.player, 7);
    done(c, f);
  } },
  '마리': { run: (c, f) => {
    for (const seat of [f.player, other(f.player)] as Seat[]) {
      const p = c.s.players[seat];
      const hand = [...p.hand];
      shuffleInPlace(c.s.rng, hand);   // 뒷면으로 섞어서 덱 아래로
      for (const iid of hand) moveCard(c, iid, { zone: 'deck', player: seat, position: 'bottom' });
    }
    drawN(c, f.player, 5);
    drawN(c, other(f.player), 4);
    done(c, f);
  } },
  '민화의 대접': { can: (c, s, self) => (handOthers(c, s, self) + 1 >= 6 ? '패가 이 카드를 포함해 6장 이상이면 쓸 수 없습니다.' : needDeck(c, s)),
    run: (c, f) => { drawN(c, f.player, slotsOf(c.s, other(f.player)).length); done(c, f); } },
  '배틀VIP패스': { can: (c, s) => (c.s.players[s].turns !== 1 ? '자신의 첫 번째 차례에만 쓸 수 있습니다.' : needDeck(c, s) ?? (benchRoom(c, s) > 0 ? null : '벤치가 가득 찼습니다.')),
    run: (c, f) => then(c, f, [search('deck', BASIC, 2, 'bench', { prompt: '벤치에 낼 기본 포켓몬을 2장까지 고르세요.' })]) },
  '미라주게이트': { can: (c, s) => (lostCount(c.s, s) < 7 ? '로스트존에 카드가 7장 이상 있어야 합니다.' : needDeck(c, s)),
    run: (c, f) => then(c, f, [search('deck', BASIC_ENERGY, 2, 'attach', { distinct: 'type', prompt: '서로 다른 타입의 기본 에너지를 2장까지 고르세요.' })]) },
  '교체카트': { can: (c, s) => { const p = c.s.players[s]; return !p.bench.length ? '벤치 포켓몬이 없습니다.' : p.active && slotData(c, p.active).pokemon?.stage === 0 ? null : '배틀 포켓몬이 기본 포켓몬일 때만 쓸 수 있습니다.'; },
    run: (c, f) => then(c, f, [['switchCart', {}]]) },
  '동굴탈출로프': { can: (c, s) => (c.s.players[s].bench.length || c.s.players[other(s)].bench.length ? null : '양쪽 모두 벤치 포켓몬이 없습니다.'),
    run: (c, f) => then(c, f, [['escapeRope', {}]]) },
  '로스트스위퍼': { can: (c, s, self) => (handOthers(c, s, self) < 1 ? '패를 1장 로스트존에 두어야 합니다.' : sweeperTargets(c).length ? null : '포켓몬의 도구·스타디움이 없습니다.'),
    run: (c, f) => then(c, f, [['lostSweeper', {}]]) },
  '히스이의 헤비볼': { run: (c, f) => then(c, f, [['heavyBall', { card: f.data.card }]]) },
  '아크로마의 실험': { can: needDeck, run: (c, f) => then(c, f, [['lookTake', { look: 5, take: 3, prompt: '덱 위 5장 중 패로 가져올 카드 3장 (나머지는 로스트존)' }]]) },
  '원규': { can: (c, s) => (prizesLeft(c.s, other(s)) <= 3 ? null : '상대의 남은 사이드가 3장 이하일 때만 쓸 수 있습니다.'),
    run: (c, f) => {
      for (const seat of [f.player, other(f.player)] as Seat[]) {
        const p = c.s.players[seat];
        for (const iid of [...p.hand]) moveCard(c, iid, { zone: 'deck', player: seat, position: 'top' });
        shuffleDeck(c, seat);
      }
      drawN(c, f.player, 6);
      drawN(c, other(f.player), 2);
      done(c, f);
    } },

  // ── 2023 코리안리그 시즌3 마스터 우승 가디안 ex ──
  '레벨볼': { can: needDeck, run: (c, f) => then(c, f, [search('deck', { kind: 'pokemon', maxHp: 90 }, 1, 'hand', { reveal: true, prompt: 'HP 90 이하 포켓몬을 고르세요.' })]) },
  '안개의 수정': { can: needDeck, run: (c, f) => then(c, f, [search('deck', { or: [{ kind: 'pokemon', stage: 0, ptype: 'P' }, { kind: 'energy', basicEnergy: true, etype: 'P' }] }, 1, 'hand', { reveal: true, prompt: '초 타입 기본 포켓몬 또는 기본 초 에너지를 고르세요.' })]) },
  '친구수첩': { can: (c, s) => (discardHas(c, s, SUPPORTER) ? null : '트래쉬에 서포트가 없습니다.'),
    run: (c, f) => then(c, f, [search('discard', SUPPORTER, 2, 'deck', { min: 1, reveal: true, prompt: '덱으로 되돌릴 서포트를 2장까지 고르세요.' }), ['shuffle', {}]]) },
  '저지맨': { run: (c, f) => {
    for (const seat of [f.player, other(f.player)] as Seat[]) {
      const p = c.s.players[seat];
      for (const iid of [...p.hand]) moveCard(c, iid, { zone: 'deck', player: seat, position: 'top' });
      shuffleDeck(c, seat);
    }
    drawN(c, f.player, 4);
    drawN(c, other(f.player), 4);
    done(c, f);
  } },
  '작업원': { run: (c, f) => {
    drawN(c, f.player, 3);
    if (c.s.stadium) { moveCard(c, c.s.stadium, { zone: 'discard', player: c.s.cards[c.s.stadium].owner }); updateBench(c); }
    done(c, f);
  } },
  '미모사': { run: (c, f) => then(c, f, [search('discard', POKEMON, 5, 'deck', { reveal: true, prompt: '덱으로 되돌릴 포켓몬을 5장까지 고르세요.' }), ['shuffle', {}], ['draw', { n: 3 }]]) },
  '세레나': { can: (c, s, self) => (handOthers(c, s, self) >= 1 || vBenchOf(c, other(s)).length ? null : '트래쉬할 패도, 끌어낼 상대 벤치의 포켓몬 V 도 없습니다.'),
    run: (c, f) => then(c, f, [['serena', {}]]) },
  '모란': { can: (c, s) => (peonyTargets(c, s).length ? null : '패로 되돌릴 기본 포켓몬이 없습니다 (필드에 포켓몬이 2마리 이상 있어야 합니다).'),
    run: (c, f) => then(c, f, [['peony', {}]]) },
};

/** 상대 벤치의 「포켓몬 V」 (V·VMAX·VSTAR) */
function vBenchOf(ctx: Ctx, seat: Seat): string[] {
  return ctx.s.players[seat].bench.filter((b) => { const r = slotData(ctx, b).pokemon?.rule; return !b.faceDown && (r === 'V' || r === 'VMAX' || r === 'VSTAR'); }).map((b) => b.sid);
}
/** 모란: 되돌릴 수 있는 내 기본 포켓몬 (필드에 2마리 이상일 때만 — 마지막 1마리를 되돌리면 필드가 빔) */
function peonyTargets(ctx: Ctx, seat: Seat): string[] {
  const sl = slotsOf(ctx.s, seat);
  if (sl.length < 2) return [];
  return sl.filter((x) => !x.faceDown && slotData(ctx, x).pokemon?.stage === 0).map((x) => x.sid);
}

/** 세레나: ① 패 1~3장 트래쉬 → 5장이 되도록 뽑기 ② 상대 벤치의 포켓몬 V 를 배틀로 */
FRAMES.serena = (ctx, f) => {
  const p = ctx.s.players[f.player];
  if (f.step === 0) {
    const opts: string[] = [];
    if (p.hand.length) opts.push('draw');
    if (vBenchOf(ctx, other(f.player)).length) opts.push('gust');
    if (!opts.length) return done(ctx, f);
    return ask(ctx, f, 1, f.player, 'pickOption', opts, 1, 1, '세레나: 효과를 고르세요.', { labels: { draw: '패 1~3장 트래쉬 → 5장이 되도록 뽑기', gust: '상대 벤치의 포켓몬 V 를 배틀 포켓몬과 교체' } });
  }
  if (f.step === 1) {
    if (f.picks?.[0] === 'gust') return ask(ctx, f, 3, f.player, 'pickSlot', vBenchOf(ctx, other(f.player)), 1, 1, '배틀 필드로 끌어낼 상대 벤치의 포켓몬 V 를 고르세요.');
    return ask(ctx, f, 2, f.player, 'pickCards', [...p.hand], 1, 3, '트래쉬할 패를 1~3장 고르세요 (그 뒤 패가 5장이 되도록 뽑음).', { cards: cardsOf(ctx, p.hand) });
  }
  if (f.step === 2) {
    for (const iid of f.picks ?? []) moveCard(ctx, iid, { zone: 'discard', player: f.player });
    while (p.hand.length < 5 && drawOne(ctx, f.player)) { /* 5장까지 */ }
    return done(ctx, f);
  }
  if (f.picks?.length) switchActive(ctx, other(f.player), f.picks[0]);
  done(ctx, f);
};

/** 모란: 내 기본 포켓몬 1마리와 붙은 카드 전부를 패로 */
FRAMES.peony = (ctx, f) => {
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickSlot', peonyTargets(ctx, f.player), 1, 1, '패로 되돌릴 기본 포켓몬을 고르세요 (붙은 카드도 모두 패로).');
  const found = findSlot(ctx.s, f.picks![0]);
  if (found) {
    for (const a of [...found.slot.attached]) moveCard(ctx, a, { zone: 'hand', player: f.player });
    for (const c of [...found.slot.stack]) moveCard(ctx, c, { zone: 'hand', player: f.player });
  }
  done(ctx, f);
  if (!ctx.s.players[f.player].active) ctx.s.stack.push({ id: `f${ctx.s.nextId++}`, kind: 'promote', step: 0, player: f.player, data: {} });
};

// 트레이너스 하위 프레임 ─────────────

// ── 공식 덱 레시피 하위 프레임 ─────────────

/** 덱 위 look 장을 보고 take 장을 패로, 나머지는 로스트존 (어비스시크·아크로마의 실험) */
FRAMES.lookTake = (ctx, f) => {
  const p = ctx.s.players[f.player];
  const look = Number(f.data.look);
  const top = p.deck.slice(0, look);
  if (f.step === 0) {
    if (!top.length) return done(ctx, f);
    const take = Math.min(Number(f.data.take), top.length);
    return ask(ctx, f, 1, f.player, 'pickCards', top, take, take, String(f.data.prompt), { cards: cardsOf(ctx, top) });
  }
  const picks = f.picks ?? [];
  for (const iid of top) moveCard(ctx, iid, picks.includes(iid) ? { zone: 'hand', player: f.player } : { zone: 'lost', player: f.player });
  done(ctx, f);
};

/** 교체카트: 기본 배틀 포켓몬을 벤치와 교체 → 벤치로 간 포켓몬 HP 30 회복 */
FRAMES.switchCart = (ctx, f) => {
  const p = ctx.s.players[f.player];
  if (f.step === 0) {
    if (!p.bench.length || !p.active) return done(ctx, f);
    f.data.old = p.active.sid;
    return ask(ctx, f, 1, f.player, 'pickSlot', p.bench.map((b) => b.sid), 1, 1, '배틀 포켓몬과 바꿀 벤치 포켓몬을 고르세요.');
  }
  if (f.picks?.length) switchActive(ctx, f.player, f.picks[0]);
  const old = findSlot(ctx.s, String(f.data.old));
  if (old) heal(ctx, old.slot, 30);
  done(ctx, f);
};

/** 동굴탈출로프: 상대부터 각자 배틀 포켓몬을 벤치와 교체 (각자 고름) */
FRAMES.escapeRope = (ctx, f) => {
  const opp = other(f.player);
  if (f.step === 0) {
    const ob = ctx.s.players[opp].bench;
    if (ob.length && ctx.s.players[opp].active) return ask(ctx, f, 1, opp, 'pickSlot', ob.map((b) => b.sid), 1, 1, '동굴탈출로프: 배틀 포켓몬과 바꿀 내 벤치 포켓몬을 고르세요.');
    f.step = 1;
  }
  if (f.step === 1) {
    if (f.picks?.length) switchActive(ctx, opp, f.picks[0]);
    f.picks = undefined;
    const mb = ctx.s.players[f.player].bench;
    if (mb.length && ctx.s.players[f.player].active) return ask(ctx, f, 2, f.player, 'pickSlot', mb.map((b) => b.sid), 1, 1, '배틀 포켓몬과 바꿀 벤치 포켓몬을 고르세요.');
    return done(ctx, f);
  }
  if (f.picks?.length) switchActive(ctx, f.player, f.picks[0]);
  done(ctx, f);
};

/** 로스트스위퍼 대상: 양쪽 필드의 포켓몬의 도구 + 스타디움 */
function sweeperTargets(ctx: Ctx): string[] {
  const out: string[] = [];
  for (const seat of [0, 1] as Seat[]) for (const sl of slotsOf(ctx.s, seat)) { const t = toolOf(ctx, sl); if (t) out.push(t); }
  if (ctx.s.stadium) out.push(ctx.s.stadium);
  return out;
}
FRAMES.lostSweeper = (ctx, f) => {
  const p = ctx.s.players[f.player];
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickCards', [...p.hand], 1, 1, '로스트존에 둘 패 1장 (사용 비용)', { cards: cardsOf(ctx, p.hand) });
  if (f.step === 1) {
    if (f.picks?.length) moveCard(ctx, f.picks[0], { zone: 'lost', player: f.player });
    const opts = sweeperTargets(ctx);
    if (!opts.length) return done(ctx, f);
    return ask(ctx, f, 2, f.player, 'pickCards', opts, 1, 1, '로스트존에 둘 포켓몬의 도구 또는 스타디움', { cards: cardsOf(ctx, opts) });
  }
  const t = f.picks?.[0];
  if (t) {
    const wasStadium = ctx.s.stadium === t;
    moveCard(ctx, t, { zone: 'lost', player: ctx.s.cards[t].owner });
    if (wasStadium) updateBench(ctx);
  }
  done(ctx, f);
};

/** 히스이의 헤비볼: 사이드를 모두 보고 기본 포켓몬 1장을 이 카드와 바꿔 패로 → 사이드를 섞음 */
FRAMES.heavyBall = (ctx, f) => {
  const p = ctx.s.players[f.player];
  const prizes = p.prizes.filter((x): x is string => !!x);
  if (f.step === 0) {
    if (!prizes.length) return done(ctx, f);
    const opts = cardsMatching(ctx, prizes, BASIC);
    return ask(ctx, f, 1, f.player, 'pickCards', opts, 0, 1, '사이드(프라이즈) 중 패로 가져올 기본 포켓몬 (없으면 그냥 결정)', { cards: cardsOf(ctx, prizes) });
  }
  const pick = f.picks?.[0];
  const ball = String(f.data.card);
  if (pick) {
    const idx = p.prizes.indexOf(pick);
    const nid = moveCard(ctx, pick, { zone: 'hand', player: f.player });
    const rev = { id: `v${ctx.s.nextId++}`, owner: f.player, reason: `${effectSource(ctx)}: 사이드에서 [기본 포켓몬] → 패로 가져갑니다\n효과로 가져가는 카드를 상대에게 보여줍니다.`, cards: cardsOf(ctx, [nid]) };
    ctx.s.reveals.push(rev);
    emit(ctx, { type: 'reveal', reveal: rev });
    ctx.s.requests.push({ id: `r${ctx.s.nextId++}`, player: other(f.player), kind: 'ackReveal', options: ['ok'], min: 1, max: 1, prompt: '상대가 보여준 카드를 확인하세요.', revealId: rev.id });
    if (ctx.s.using.includes(ball)) moveCard(ctx, ball, { zone: 'prizes', player: f.player, index: idx });
  }
  // 사이드를 뒷면으로 섞는다 (자리 그대로, 카드 순서만 섞고 새 iid)
  const idxs = p.prizes.map((x, i) => (x ? i : -1)).filter((i) => i >= 0);
  const vals = idxs.map((i) => p.prizes[i]!);
  shuffleInPlace(ctx.s.rng, vals);
  idxs.forEach((i, k) => {
    const c = ctx.s.cards[vals[k]];
    delete ctx.s.cards[vals[k]];
    const nid = `c${ctx.s.nextId++}`;
    ctx.s.cards[nid] = { ...c, iid: nid };
    p.prizes[i] = nid;
  });
  done(ctx, f);
};

/** 악의 탑 (스타디움 효과): 패의 「일격」 카드 1장 트래쉬 → 2장 뽑기 */
FRAMES.darkTower = (ctx, f) => {
  const p = ctx.s.players[f.player];
  const opts = p.hand.filter((i) => (dataOf(ctx, i).tags ?? []).includes('일격'));
  if (f.step === 0) {
    if (!opts.length) return done(ctx, f);
    return ask(ctx, f, 1, f.player, 'pickCards', opts, 1, 1, "트래쉬할 '일격' 카드를 고르세요.", { cards: cardsOf(ctx, opts) });
  }
  if (f.picks?.length) { moveCard(ctx, f.picks[0], { zone: 'discard', player: f.player }); drawN(ctx, f.player, 2); }
  done(ctx, f);
};

FRAMES.glassTrumpet = (ctx, f) => {
  const p = ctx.s.players[f.player];
  const chosen = (f.data.chosen as string[] | undefined) ?? [];
  if (f.step === 0 || f.step === 2) {
    if (f.step === 2 && f.picks?.length) {
      const e = cardsMatching(ctx, p.discard, BASIC_ENERGY)[0];
      if (e) { moveCard(ctx, e, { zone: 'attach', sid: f.picks[0] }); chosen.push(f.picks[0]); f.data.chosen = chosen; }
    }
    if (f.step === 2 && !f.picks?.length) return done(ctx, f);
    const opts = p.bench.map((b) => b.sid).filter((sid) => !chosen.includes(sid));
    if (chosen.length >= 2 || !opts.length || !cardsMatching(ctx, p.discard, BASIC_ENERGY).length) return done(ctx, f);
    return ask(ctx, f, 2, f.player, 'pickSlot', opts, 0, 1, `트래쉬의 기본 에너지를 붙일 벤치 포켓몬 (${chosen.length + 1}/2, 그만하려면 고르지 않고 결정)`);
  }
};

FRAMES.crispin = (ctx, f) => {
  if (f.step === 0) return seq(ctx, f, 1, [search('deck', BASIC_ENERGY, 2, 'save', { save: 'picked', distinct: 'type', shuffle: false, prompt: '서로 다른 타입의 기본 에너지를 2장까지 고르세요.' })]);
  const picked = (f.data.picked as string[] | undefined) ?? [];
  if (f.step === 1) {
    if (picked.length === 0) { shuffleDeck(ctx, f.player); return done(ctx, f); }
    if (picked.length === 1) { moveCard(ctx, picked[0], { zone: 'hand', player: f.player }); shuffleDeck(ctx, f.player); return done(ctx, f); }
    return ask(ctx, f, 2, f.player, 'pickCards', picked, 1, 1, '패로 가져올 에너지 1장 (나머지는 포켓몬에 붙임)', { cards: cardsOf(ctx, picked) });
  }
  if (f.step === 2) {
    const toHand = f.picks![0];
    f.data.rest = picked.filter((i) => i !== toHand);
    moveCard(ctx, toHand, { zone: 'hand', player: f.player });
    return ask(ctx, f, 3, f.player, 'pickSlot', slotsOf(ctx.s, f.player).map((s) => s.sid), 1, 1, '나머지 에너지를 붙일 포켓몬을 고르세요.');
  }
  for (const e of f.data.rest as string[]) moveCard(ctx, e, { zone: 'attach', sid: f.picks![0] });
  shuffleDeck(ctx, f.player);
  done(ctx, f);
};

FRAMES.scoopUp = (ctx, f) => {
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickSlot', slotsOf(ctx.s, f.player).map((s) => s.sid), 1, 1, '패로 되돌릴 포켓몬을 고르세요 (포켓몬 외 카드는 트래쉬).');
  const found = findSlot(ctx.s, f.picks![0]);
  if (found) clearSlot(ctx, found.slot, f.player, 'hand');
  done(ctx, f);
  // 배틀 포켓몬을 되돌렸으면 새 배틀 포켓몬
  if (!ctx.s.players[f.player].active) ctx.s.stack.push({ id: `f${ctx.s.nextId++}`, kind: 'promote', step: 0, player: f.player, data: {} });
};

FRAMES.carmine = (ctx, f) => {
  if (f.step === 0) {
    const opts = ['boost'];
    if (ctx.s.players[f.player].bench.length) opts.unshift('switch');
    return ask(ctx, f, 1, f.player, 'pickOption', opts, 1, 1, '카지: 효과를 고르세요.', { labels: { switch: '배틀 포켓몬 교체', boost: '이번 차례 ex·V 에게 +30' } });
  }
  if (f.picks?.[0] === 'switch') return then(ctx, f, [['switchOwn', {}]]);
  ctx.s.players[f.player].effects.push({ kind: 'boostExV30', until: ctx.s.turnNumber });
  done(ctx, f);
};

/** 이상한사탕: 대상 기본 포켓몬(data.target)에 패의 2진화를 바로 올린다 */
FRAMES.rareCandy = (ctx, f) => {
  const target = findSlot(ctx.s, String(f.data.target));
  if (!target) return done(ctx, f);
  const opts = candyCards(ctx, f.player, target.slot);
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickCards', opts, 1, 1, '진화시킬 2진화 포켓몬을 고르세요.', { cards: cardsOf(ctx, opts) });
  if (f.picks?.length) evolveFrom(ctx, f.player, f.picks[0], target.slot.sid);
  done(ctx, f);
};

/** 기본 포켓몬 슬롯에 이상한사탕으로 올릴 수 있는 패의 2진화 */
export function candyCards(ctx: Ctx, seat: Seat, slot: PokemonSlot): string[] {
  const base = slotData(ctx, slot);
  if (base.pokemon?.stage !== 0) return [];
  const stage1Names = new Set(Object.values(ctx.info.db).filter((d) => d.pokemon?.stage === 1 && d.pokemon.from === base.name).map((d) => d.name));
  return ctx.s.players[seat].hand.filter((i) => { const d = dataOf(ctx, i); return d.pokemon?.stage === 2 && !!d.pokemon.from && stage1Names.has(d.pokemon.from); });
}

FRAMES.superRetrieval = (ctx, f) => {
  if (f.step === 0) return seq(ctx, f, 1, [['discardHand', { n: 2, save: 'discarded' }]]);
  if (f.step === 1) return seq(ctx, f, 2, [search('discard', BASIC_ENERGY, 4, 'hand', { min: 1, reveal: true, exclude: (f.data.discarded as string[]) ?? [], prompt: '트래쉬의 기본 에너지를 4장까지 고르세요.' })]);
  done(ctx, f);
};

FRAMES.cipher = (ctx, f) => {
  const p = ctx.s.players[f.player];
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickCards', [...p.deck], Math.min(2, p.deck.length), 2, '덱 위에 놓을 카드를 2장 고르세요.', { cards: cardsOf(ctx, p.deck) });
  if (f.step === 1) {
    f.data.chosen = f.picks ?? [];
    // 고른 카드를 잠시 빼 두고 셔플 → 덱 위에 올림 (순서는 다음 단계)
    const chosen = f.data.chosen as string[];
    if (chosen.length < 2) {
      shuffleDeck(ctx, f.player);
      const moved = chosen.map((i) => moveCardKeep(ctx, i, f.player));
      void moved;
      return done(ctx, f);
    }
    return ask(ctx, f, 2, f.player, 'pickCards', chosen, 1, 1, '맨 위에 둘 카드를 고르세요.', { cards: cardsOf(ctx, chosen) });
  }
  const chosen = f.data.chosen as string[];
  const top = f.picks![0];
  const second = chosen.find((i) => i !== top)!;
  // 두 장을 빼고 나머지 셔플 후, 두 번째 → 맨 위 순서로 올린다
  const p2 = ctx.s.players[f.player];
  p2.deck = p2.deck.filter((i) => i !== top && i !== second);
  shuffleDeck(ctx, f.player);
  p2.deck.unshift(second);
  p2.deck.unshift(top);
  done(ctx, f);
};
/** 덱 안의 카드를 맨 위로 (셔플 뒤 재배치용) */
function moveCardKeep(ctx: Ctx, iid: string, seat: Seat) {
  const p = ctx.s.players[seat];
  const i = p.deck.indexOf(iid);
  if (i >= 0) { p.deck.splice(i, 1); p.deck.unshift(iid); }
  return iid;
}

FRAMES.energySwitch = (ctx, f) => {
  const slots = slotsOf(ctx.s, f.player);
  if (f.step === 0) {
    const opts = slots.filter((sl) => energiesOf(ctx, sl).some((e) => dataOf(ctx, e).energy?.basic)).map((s) => s.sid);
    return ask(ctx, f, 1, f.player, 'pickSlot', opts, 1, 1, '기본 에너지를 뗄 포켓몬을 고르세요.');
  }
  if (f.step === 1) {
    f.data.from = f.picks![0];
    const src = findSlot(ctx.s, f.picks![0])!.slot;
    const ens = energiesOf(ctx, src).filter((e) => dataOf(ctx, e).energy?.basic);
    return ask(ctx, f, 2, f.player, 'pickCards', ens, 1, 1, '옮길 기본 에너지를 고르세요.', { cards: cardsOf(ctx, ens) });
  }
  if (f.step === 2) {
    f.data.energy = f.picks![0];
    return ask(ctx, f, 3, f.player, 'pickSlot', slots.map((s) => s.sid).filter((sid) => sid !== f.data.from), 1, 1, '에너지를 붙일 포켓몬을 고르세요.');
  }
  moveCard(ctx, String(f.data.energy), { zone: 'attach', sid: f.picks![0] });
  done(ctx, f);
};

// ───────────────────────── 진화 ─────────────────────────

/** 진화 (손에서). 진화 시 발동하는 특성(리자몽 ex, 야부엉)은 프레임으로 쌓는다 */
export function evolveFrom(ctx: Ctx, seat: Seat, cardIid: string, sid: string, fromHand = true) {
  const nid = moveCard(ctx, cardIid, { zone: 'evolve', sid });
  emit(ctx, { type: 'play', player: seat, code: inst(ctx, nid).code, what: '진화' });
  const slot = findSlot(ctx.s, sid)!.slot;
  const ab = slotData(ctx, slot).pokemon?.abilities[0]?.nameJa;
  if (!abilityActive(ctx, slot)) return;
  if (ab === 'れんごくしはい' && ctx.s.players[seat].deck.length) pushTrigger(ctx, seat, 'infernalReign', sid, '리자몽 ex 특성: 덱에서 기본 에너지를 3장까지 붙일까요?');
  if (ab === 'ほうせきさがし' && hasTera(ctx, seat) && ctx.s.players[seat].deck.length) pushTrigger(ctx, seat, 'jewelSeeker', sid, '야부엉 특성: 덱에서 트레이너스를 2장까지 가져올까요?');
  if (ab === '다크시그널' && fromHand && ctx.s.players[other(seat)].bench.length) pushTrigger(ctx, seat, 'darkSignal', sid, '블래키 VMAX 특성: 상대 벤치 포켓몬을 배틀 포켓몬과 교체할까요?');
}
function pushTrigger(ctx: Ctx, seat: Seat, kind: string, sid: string, prompt: string) {
  ctx.s.stack.push({ id: `f${ctx.s.nextId++}`, kind: 'trigger', step: 0, player: seat, data: { effect: kind, sid, prompt } });
}
/** 선택형 발동 특성: 쓸지 묻고 쓰면 효과 */
FRAMES.trigger = (ctx, f) => {
  if (f.step === 0) return seq(ctx, f, 1, [['yesno', { prompt: String(f.data.prompt), save: 'answer' }]]);
  if (f.data.answer !== 'yes') return done(ctx, f);
  const slot = findSlot(ctx.s, String(f.data.sid));
  if (slot) emit(ctx, { type: 'ability', player: f.player, code: inst(ctx, topOf(slot.slot)).code, name: slotData(ctx, slot.slot).pokemon?.abilities[0]?.name || slotData(ctx, slot.slot).pokemon?.abilities[0]?.nameJa || '' });
  switch (f.data.effect) {
    case 'infernalReign': return then(ctx, f, [search('deck', { kind: 'energy', basicEnergy: true, etype: 'R' }, 3, 'attach', { prompt: '붙일 기본 불꽃 에너지를 3장까지 고르세요.' })]);
    case 'jewelSeeker': return then(ctx, f, [search('deck', { kind: 'trainer' }, 2, 'hand', { reveal: true, prompt: '트레이너스를 2장까지 고르세요.' })]);
    case 'flyingEntry': return then(ctx, f, [['flyingEntry', {}]]);
    case 'rapidVernier': return then(ctx, f, [['rapidVernier', { sid: f.data.sid }]]);
    case 'darkSignal': return then(ctx, f, [['gust', {}]]);
    case 'luminousSign': return then(ctx, f, [search('deck', SUPPORTER, 1, 'hand', { reveal: true, prompt: '패로 가져올 서포트를 고르세요.' })]);
  }
  done(ctx, f);
};

/** 벤치에 냈을 때 발동하는 특성 */
export function onBenched(ctx: Ctx, seat: Seat, sid: string) {
  const slot = findSlot(ctx.s, sid)!.slot;
  if (!abilityActive(ctx, slot)) return;
  const ab = slotData(ctx, slot).pokemon?.abilities[0]?.nameJa;
  if (ab === 'フライングエントリー' && ctx.s.players[other(seat)].bench.length) pushTrigger(ctx, seat, 'flyingEntry', sid, '루차불 특성: 상대 벤치 포켓몬 2마리에 데미지 카운터를 1개씩 올릴까요?');
  if (ab === '루미너스사인' && ctx.s.players[seat].deck.length) pushTrigger(ctx, seat, 'luminousSign', sid, '네오라이트 V 특성: 덱에서 서포트를 1장 가져올까요?');
  if (ab === 'ラピッドバーニア' && ctx.s.players[seat].active) pushTrigger(ctx, seat, 'rapidVernier', sid, '무쇠잎새 ex 특성: 배틀 포켓몬과 바꾸고 벤치의 에너지를 옮길까요?');
}

FRAMES.flyingEntry = (ctx, f) => {
  const opp = ctx.s.players[other(f.player)];
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickSlot', opp.bench.map((b) => b.sid), Math.min(2, opp.bench.length), 2, '데미지 카운터를 1개씩 올릴 상대 벤치 포켓몬 2마리');
  for (const sid of f.picks ?? []) { const t = findSlot(ctx.s, sid); if (t) putCounters(ctx, t.slot, 1); }
  done(ctx, f);
};

FRAMES.rapidVernier = (ctx, f) => {
  const p = ctx.s.players[f.player];
  if (f.step === 0) {
    switchActive(ctx, f.player, String(f.data.sid));
    f.step = 1;
  }
  // 벤치 포켓몬의 에너지를 원하는 만큼 옮김: 에너지를 하나씩 고름 (그만하려면 고르지 않음)
  if (f.step === 2 && f.picks?.length) moveCard(ctx, f.picks[0], { zone: 'attach', sid: p.active!.sid });
  if (f.step === 2 && !f.picks?.length) return done(ctx, f);
  const opts = p.bench.flatMap((b) => energiesOf(ctx, b));
  if (!opts.length) return done(ctx, f);
  return ask(ctx, f, 2, f.player, 'pickCards', opts, 0, 1, '배틀 포켓몬으로 옮길 에너지 (그만하려면 고르지 않고 결정)', { cards: cardsOf(ctx, opts) });
};

// ───────────────────────── 특성 (선언해서 쓰는 것) ─────────────────────────

export type AbilityDef = {
  once: 'pokemon' | 'name' | 'none';
  endsTurn?: boolean;   // 쓰면 자신의 차례가 끝난다 (자시안 V 검의 포효)
  can?: (ctx: Ctx, seat: Seat, slot: PokemonSlot) => string | null;
  run: Handler;   // f.data.sid
};
const slotOfFrame = (ctx: Ctx, f: Frame) => findSlot(ctx.s, String(f.data.sid))?.slot;

export const ABILITIES: Record<string, AbilityDef> = {
  'ファンコール': { once: 'name', can: (c, s) => (c.s.players[s].turns === 1 ? needDeck(c, s) : '자신의 첫 차례에만 쓸 수 있습니다.'),
    run: (c, f) => then(c, f, [search('deck', { kind: 'pokemon', maxHp: 100, ptype: 'C' }, 3, 'hand', { reveal: true, prompt: 'HP 100 이하 무색 포켓몬을 3장까지' })]) },
  'さかてにとる': { once: 'name', can: (c, s) => (c.s.players[s].koTurn === c.s.turnNumber - 1 && c.s.turnNumber > 1 ? needDeck(c, s) : '앞의 상대 차례에 내 포켓몬이 기절했을 때만 쓸 수 있습니다.'),
    run: (c, f) => { drawN(c, f.player, 3); done(c, f); } },
  'リスタート': { once: 'pokemon', can: (c, s) => (c.s.players[s].hand.length < 3 ? needDeck(c, s) : '패가 3장 이상입니다.'),
    run: (c, f) => { const p = c.s.players[f.player]; while (p.hand.length < 3 && drawOne(c, f.player)) { /* 3장까지 */ } done(c, f); } },
  'マッハサーチ': { once: 'name', can: needDeck, run: (c, f) => then(c, f, [search('deck', {}, 1, 'hand', { min: 1, prompt: '패로 가져올 카드 1장' })]) },
  'カースドボム': { once: 'pokemon', run: (c, f) => then(c, f, [['cursedBomb', { sid: f.data.sid }]]) },
  'ボーナスコイン': { once: 'pokemon', can: needDeck, run: (c, f) => {
    const slot = slotOfFrame(c, f);
    drawN(c, f.player, slot && isActive(c.s, slot) ? 2 : 1);
    done(c, f);
  } },
  'ルナサイクル': { once: 'name',
    can: (c, s) => (!slotsOf(c.s, s).some((sl) => slotData(c, sl).name === '솔록') ? '필드에 솔록이 있어야 합니다.'
      : !c.s.players[s].hand.some((i) => matches(dataOf(c, i), { kind: 'energy', basicEnergy: true, etype: 'F' })) ? '패에 기본 격투 에너지가 있어야 합니다.' : needDeck(c, s)),
    run: (c, f) => then(c, f, [['lunarCycle', {}]]) },
  'メタルシグナル': { once: 'pokemon', can: needDeck, run: (c, f) => then(c, f, [search('deck', { kind: 'pokemon', evolution: true, ptype: 'M' }, 2, 'hand', { reveal: true, prompt: '강철 타입 진화 포켓몬을 2장까지' })]) },
  'アドレナブレイン': { once: 'pokemon',
    can: (c, s, slot) => (!energiesOf(c, slot).some((e) => provided(c, { ...slot, attached: [e] }).some((u) => u === 'D' || u === '*')) ? '악 에너지가 붙어 있어야 합니다.'
      : !slotsOf(c.s, s).some((sl) => sl.damage > 0) ? '데미지 카운터가 올라간 내 포켓몬이 없습니다.' : null),
    run: (c, f) => then(c, f, [['adrenaBrain', {}]]) },
  'ていさつしれい': { once: 'pokemon', can: needDeck, run: (c, f) => then(c, f, [['recon', {}]]) },
  'サイコエンブレイス': { once: 'none',
    can: (c, s) => (!discardHas(c, s, { kind: 'energy', basicEnergy: true, etype: 'P' }) ? '트래쉬에 기본 초 에너지가 없습니다.'
      : !slotsOf(c.s, s).some((sl) => remainingHp(c, sl) > 20 && slotData(c, sl).pokemon?.type === 'P') ? '붙일 수 있는 초 포켓몬이 없습니다.' : null),
    run: (c, f) => then(c, f, [['psychicEmbrace', {}]]) },
  'タンデムユニット': { once: 'pokemon', can: (c, s) => needDeck(c, s) ?? (benchRoom(c, s) > 0 ? null : '벤치가 가득 찼습니다.'),
    run: (c, f) => then(c, f, [search('deck', { kind: 'pokemon', stage: 0, ptype: 'L' }, 2, 'bench', { prompt: '번개 타입 기본 포켓몬을 2장까지' })]) },

  // ── 공식 덱 레시피 ──
  '전별의 춤': { once: 'name', can: (c, s) => (c.s.players[s].koTurn === c.s.turnNumber - 1 && c.s.turnNumber > 1 ? needDeck(c, s) : '앞의 상대 차례에 내 포켓몬이 기절했을 때만 쓸 수 있습니다.'),
    run: (c, f) => { drawN(c, f.player, 3); done(c, f); } },
  '일격의 포효': { once: 'pokemon',
    can: (c, s) => (!c.s.players[s].deck.some((i) => nameOf(c, i) === '일격 에너지') ? '덱에 일격 에너지가 없습니다.'
      : !slotsOf(c.s, s).some((sl) => (slotData(c, sl).tags ?? []).includes('일격')) ? "'일격' 포켓몬이 없습니다." : null),
    run: (c, f) => then(c, f, [['singleStrikeRoar', {}]]) },
  '꽃고르기': { once: 'pokemon', can: (c, s, slot) => (c.s.players[s].active !== slot ? '배틀 포켓몬일 때만 쓸 수 있습니다.' : needDeck(c, s)),
    run: (c, f) => then(c, f, [['flowerSelecting', {}]]) },
  '숨겨진 수단': { once: 'pokemon', can: (c, s) => (!c.s.players[s].hand.some((i) => dataOf(c, i).kind === 'energy') ? '패에 에너지가 없습니다.' : needDeck(c, s)),
    run: (c, f) => then(c, f, [['concealedCards', {}]]) },

  // ── 2023 코리안리그 시즌3 가디안 ex ──
  '이상한 꼬리': { once: 'pokemon', can: (c, s, slot) => (c.s.players[s].active !== slot ? '배틀 포켓몬일 때만 쓸 수 있습니다.' : needDeck(c, s)),
    run: (c, f) => then(c, f, [search('deck', { kind: 'trainer', trainer: 'item' }, 1, 'hand', { look: 6, reveal: true, prompt: '덱 위 6장 중 패로 가져올 아이템 1장' })]) },
  '검의 포효': { once: 'pokemon', endsTurn: true, can: needDeck,
    run: (c, f) => then(c, f, [search('deck', { kind: 'energy', etype: 'P' }, 1, 'attach', { prompt: '내 포켓몬에게 붙일 초 에너지를 고르세요 (쓰면 차례가 끝남).' })]) },
  '리파인': { once: 'pokemon', can: (c, s) => (c.s.players[s].hand.length ? needDeck(c, s) : '트래쉬할 패가 없습니다.'),
    run: (c, f) => then(c, f, [['discardHand', { n: 1 }], ['draw', { n: 2 }]]) },
  '아르카나 샤인': { once: 'pokemon', can: needDeck, run: (c, f) => then(c, f, [['arcanaShine', {}]]) },
};

/** 가디안 "아르카나 샤인": 덱 위 2장 중 기본 에너지를 원하는 만큼 붙이고, 남은 카드는 패로 */
FRAMES.arcanaShine = (ctx, f) => {
  const p = ctx.s.players[f.player];
  if (f.step === 0) {
    f.data.top = p.deck.slice(0, 2);
    return seq(ctx, f, 1, [search('deck', BASIC_ENERGY, 2, 'attach', { look: 2, shuffle: false, prompt: '덱 위 2장 중 붙일 기본 에너지 (원하는 만큼, 남은 카드는 패로)' })]);
  }
  for (const iid of f.data.top as string[]) if (p.deck.includes(iid)) moveCard(ctx, iid, { zone: 'hand', player: f.player });
  done(ctx, f);
};

/** 헬가 "일격의 포효": 덱의 일격 에너지를 일격 포켓몬에게 붙이고 그 포켓몬에 카운터 2개 */
FRAMES.singleStrikeRoar = (ctx, f) => {
  if (f.step === 0) return seq(ctx, f, 1, [search('deck', { name: '일격 에너지' }, 1, 'save', { save: 'picked', shuffle: false, prompt: '붙일 일격 에너지를 고르세요.' })]);
  const picked = (f.data.picked as string[] | undefined) ?? [];
  if (f.step === 1) {
    const targets = slotsOf(ctx.s, f.player).filter((sl) => (slotData(ctx, sl).tags ?? []).includes('일격')).map((sl) => sl.sid);
    if (!picked.length || !targets.length) { shuffleDeck(ctx, f.player); return done(ctx, f); }
    return ask(ctx, f, 2, f.player, 'pickSlot', targets, 1, 1, "일격 에너지를 붙일 '일격' 포켓몬 (데미지 카운터 2개)", { cards: cardsOf(ctx, picked) });
  }
  const t = findSlot(ctx.s, f.picks![0])?.slot;
  if (t) moveCard(ctx, picked[0], { zone: 'attach', sid: t.sid });
  shuffleDeck(ctx, f.player);
  if (t) putCounters(ctx, t, 2);
  done(ctx, f);
};

/** 큐아링 "꽃고르기": 덱 위 2장 중 1장 패로, 나머지 로스트존 */
FRAMES.flowerSelecting = (ctx, f) => then(ctx, f, [['lookTake', { look: 2, take: 1, prompt: '덱 위 2장 중 패로 가져올 1장 (나머지는 로스트존)' }]]);

/** 찬란한 개굴닌자 "숨겨진 수단": 패의 에너지 1장 트래쉬 → 2장 뽑기 */
FRAMES.concealedCards = (ctx, f) => {
  const p = ctx.s.players[f.player];
  const opts = p.hand.filter((i) => dataOf(ctx, i).kind === 'energy');
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickCards', opts, 1, 1, '트래쉬할 에너지를 고르세요.', { cards: cardsOf(ctx, opts) });
  if (f.picks?.length) { moveCard(ctx, f.picks[0], { zone: 'discard', player: f.player }); drawN(ctx, f.player, 2); }
  done(ctx, f);
};


FRAMES.cursedBomb = (ctx, f) => {
  const self = slotOfFrame(ctx, f);
  if (!self) return done(ctx, f);
  const n = slotData(ctx, self).pokemon?.stage === 2 ? 13 : 5;
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickSlot', slotsOf(ctx.s, other(f.player)).map((s) => s.sid), 1, 1, `데미지 카운터 ${n}개를 올릴 상대 포켓몬`);
  const t = findSlot(ctx.s, f.picks![0]);
  if (t) putCounters(ctx, t.slot, n);
  // 이 포켓몬은 기절 (기절 처리는 뒤의 기절 확인에서)
  self.damage = Math.max(self.damage, maxHp(ctx, self));
  note(ctx, `${slotName(ctx, self)}: 커스드밤으로 기절`);
  done(ctx, f);
};

FRAMES.lunarCycle = (ctx, f) => {
  const p = ctx.s.players[f.player];
  const opts = p.hand.filter((i) => matches(dataOf(ctx, i), { kind: 'energy', basicEnergy: true, etype: 'F' }));
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickCards', opts, 1, 1, '트래쉬할 기본 격투 에너지', { cards: cardsOf(ctx, opts) });
  moveCard(ctx, f.picks![0], { zone: 'discard', player: f.player });
  drawN(ctx, f.player, 3);
  done(ctx, f);
};

FRAMES.adrenaBrain = (ctx, f) => {
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickSlot', slotsOf(ctx.s, f.player).filter((s) => s.damage > 0).map((s) => s.sid), 1, 1, '데미지 카운터를 옮길 내 포켓몬');
  if (f.step === 1) {
    f.data.from = f.picks![0];
    const src = findSlot(ctx.s, f.picks![0])!.slot;
    const n = Math.min(3, Math.floor(src.damage / 10));
    const opts = Array.from({ length: n }, (_, i) => String(i + 1));
    return ask(ctx, f, 2, f.player, 'pickOption', opts, 1, 1, '옮길 데미지 카운터 수', { labels: Object.fromEntries(opts.map((o) => [o, `${o}개`])) });
  }
  if (f.step === 2) {
    f.data.n = Number(f.picks![0]);
    return ask(ctx, f, 3, f.player, 'pickSlot', slotsOf(ctx.s, other(f.player)).map((s) => s.sid), 1, 1, '데미지 카운터를 올릴 상대 포켓몬');
  }
  const src = findSlot(ctx.s, String(f.data.from))?.slot;
  const dst = findSlot(ctx.s, f.picks![0])?.slot;
  const n = Number(f.data.n);
  if (src && dst) { src.damage -= n * 10; emit(ctx, { type: 'heal', player: f.player, sid: src.sid, amount: n * 10 }); putCounters(ctx, dst, n); }
  done(ctx, f);
};

FRAMES.recon = (ctx, f) => {
  const p = ctx.s.players[f.player];
  const top2 = p.deck.slice(0, 2);
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickCards', top2, 1, 1, '덱 위 2장 중 패로 가져올 1장 (나머지는 덱 아래)', { cards: cardsOf(ctx, top2) });
  const pick = f.picks![0];
  for (const i of top2) {
    if (i === pick) moveCard(ctx, i, { zone: 'hand', player: f.player });
    else moveCard(ctx, i, { zone: 'deck', player: f.player, position: 'bottom' });
  }
  done(ctx, f);
};

FRAMES.psychicEmbrace = (ctx, f) => {
  const p = ctx.s.players[f.player];
  const ens = cardsMatching(ctx, p.discard, { kind: 'energy', basicEnergy: true, etype: 'P' });
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickSlot', slotsOf(ctx.s, f.player).filter((s) => remainingHp(ctx, s) > 20 && slotData(ctx, s).pokemon?.type === 'P').map((s) => s.sid), 1, 1, '초 에너지를 붙일 초 포켓몬 (데미지 카운터 2개)');
  const t = findSlot(ctx.s, f.picks![0])?.slot;
  if (t && ens.length) { moveCard(ctx, ens[0], { zone: 'attach', sid: t.sid }); putCounters(ctx, t, 2); }
  done(ctx, f);
};

// ───────────────────────── 기술 ─────────────────────────

/** 기술 처리기: f.data = { sid(공격 포켓몬), base(기본 데미지), attackJa } — 기본: 상대 배틀 포켓몬에게 base */
export type AttackDef = { can?: (ctx: Ctx, seat: Seat, slot: PokemonSlot) => string | null; run: Handler };
const atkSlot = (ctx: Ctx, f: Frame) => findSlot(ctx.s, String(f.data.sid))?.slot ?? null;
const oppActive = (ctx: Ctx, f: Frame) => ctx.s.players[other(f.player)].active;
/** 상대 배틀 포켓몬에게 데미지 */
export function hit(ctx: Ctx, f: Frame, amount: number, wr = true) {
  const a = atkSlot(ctx, f);
  const t = oppActive(ctx, f);
  if (a && t) dealAttackDamage(ctx, f.player, a, t, amount, wr);
}
const base = (f: Frame) => Number(f.data.base);
const selfEffect = (ctx: Ctx, f: Frame, kind: 'noAttack' | 'noRetreat' | 'reduce30' | 'immuneBasicNonC', turns: number) => {
  const a = atkSlot(ctx, f);
  if (a) a.effects.push({ kind, until: ctx.s.turnNumber + turns });
};
const defenderEffect = (ctx: Ctx, f: Frame, kind: 'noRetreat') => { const t = oppActive(ctx, f); if (t) t.effects.push({ kind, until: ctx.s.turnNumber + 1 }); };
const plain: AttackDef = { run: (c, f) => { hit(c, f, base(f)); done(c, f); } };
/** 붙어 있는 초 에너지 개수 × 30 추가 (자시안 V 스톰슬래시, 가디안 브레인웨이브) */
const psyBonus: AttackDef = { run: (c, f) => {
  const a = atkSlot(c, f);
  const n = a ? provided(c, a).filter((u) => u === 'P' || u === '*').length : 0;
  hit(c, f, base(f) + 30 * n);
  done(c, f);
} };
const noAttackNext: AttackDef = { run: (c, f) => { hit(c, f, base(f)); selfEffect(c, f, 'noAttack', 2); done(c, f); } };
const allEnergiesOn = (ctx: Ctx, seat: Seat) => slotsOf(ctx.s, seat).reduce((a, s) => a + energiesOf(ctx, s).length, 0);
const pickOppAny = (dmgOf: (c: Ctx, f: Frame) => number): AttackDef => ({ run: (c, f) => {
  if (f.step === 0) return ask(c, f, 1, f.player, 'pickSlot', slotsOf(c.s, other(f.player)).map((s) => s.sid), 1, 1, '데미지를 줄 상대 포켓몬');
  const t = findSlot(c.s, f.picks![0]);
  const a = atkSlot(c, f);
  if (t && a) dealAttackDamage(c, f.player, a, t.slot, dmgOf(c, f), t.active);
  done(c, f);
} });

export const ATTACKS: Record<string, AttackDef> = {
  'さんどづき': { run: (c, f) => { let n = 0; for (let i = 0; i < 3; i++) if (flip(c, f.player, '삼단 찌르기')) n++; hit(c, f, 10 * n); done(c, f); } },
  'とつげきランディング': { run: (c, f) => { if (!c.s.stadium) { note(c, '스타디움이 없어 기술 실패'); return done(c, f); } hit(c, f, base(f)); done(c, f); } },
  'とつげき': { run: (c, f) => { hit(c, f, base(f)); const a = atkSlot(c, f); if (a) { a.damage += 10; emit(c, { type: 'damage', player: f.player, sid: a.sid, amount: 10 }); } done(c, f); } },
  'カラフルフレンズ': { run: (c, f) => then(c, f, [search('deck', POKEMON, 3, 'hand', { reveal: true, distinct: 'type', prompt: '서로 다른 타입의 포켓몬을 3장까지' })]) },
  'バーニングチャージ': { run: (c, f) => {
    if (f.step === 0) { hit(c, f, base(f)); if (!c.s.players[f.player].deck.length) return done(c, f); return ask(c, f, 1, f.player, 'pickSlot', slotsOf(c.s, f.player).map((s) => s.sid), 1, 1, '기본 에너지를 붙일 포켓몬 1마리'); }
    return then(c, f, [search('deck', BASIC_ENERGY, 2, 'attachTo', { attachTo: f.picks![0], prompt: '붙일 기본 에너지를 2장까지' })]);
  } },
  'カーネリアン': noAttackNext,
  'あおばのあらし': { run: (c, f) => { hit(c, f, 60 * allEnergiesOn(c, other(f.player))); done(c, f); } },
  'モスアゲート': { run: (c, f) => { hit(c, f, base(f)); for (const b of c.s.players[f.player].bench) heal(c, b, 100); done(c, f); } },
  'すすりなく': { run: (c, f) => { hit(c, f, base(f)); defenderEffect(c, f, 'noRetreat'); done(c, f); } },
  'げきりゅうポンプ': { run: (c, f) => {
    const a = atkSlot(c, f)!;
    if (f.step === 0) {
      hit(c, f, base(f));
      if (energiesOf(c, a).length < 3 || !c.s.players[other(f.player)].bench.length) return done(c, f);
      return seq(c, f, 1, [['yesno', { prompt: '에너지 3개를 덱으로 되돌리고 상대 벤치에 120 데미지를 줄까요?', save: 'answer' }]]);
    }
    if (f.step === 1) {
      if (f.data.answer !== 'yes') return done(c, f);
      const ens = energiesOf(c, a);
      return ask(c, f, 2, f.player, 'pickCards', ens, 3, 3, '덱으로 되돌릴 에너지 3개', { cards: cardsOf(c, ens) });
    }
    if (f.step === 2) {
      for (const e of f.picks!) moveCard(c, e, { zone: 'deck', player: f.player, position: 'top' });
      shuffleDeck(c, f.player);
      return ask(c, f, 3, f.player, 'pickSlot', c.s.players[other(f.player)].bench.map((b) => b.sid), 1, 1, '120 데미지를 줄 상대 벤치 포켓몬');
    }
    const t = findSlot(c.s, f.picks![0]);
    if (t) dealAttackDamage(c, f.player, a, t.slot, 120, false);
    done(c, f);
  } },
  'ユニオンビート': { can: (c, s) => (s !== c.s.firstPlayer && c.s.players[s].turns === 1 ? '후공 플레이어의 첫 차례에는 쓸 수 없습니다.' : null),
    run: (c, f) => { hit(c, f, 30 * c.s.players[f.player].bench.length); done(c, f); } },
  'クラウンオパール': { run: (c, f) => { hit(c, f, base(f)); selfEffect(c, f, 'immuneBasicNonC', 1); done(c, f); } },
  'クルーエルアロー': pickOppAny(() => 100),
  'ゲノムハック': { run: (c, f) => {
    const t = oppActive(c, f);
    const atks = t && !t.faceDown ? slotData(c, t).pokemon?.attacks ?? [] : [];
    if (f.step === 0) {
      if (!atks.length) return done(c, f);
      const opts = atks.map((_, i) => String(i));
      return ask(c, f, 1, f.player, 'pickOption', opts, 1, 1, '사용할 상대 배틀 포켓몬의 기술', { labels: Object.fromEntries(atks.map((a, i) => [String(i), `${a.name || a.nameJa} ${a.damage || ''}${a.op}`])) });
    }
    const a = atks[Number(f.picks![0])];
    done(c, f);
    if (!a) return;
    // 고른 기술을 이 포켓몬의 기술로 실행 (게놈 해킹으로 다시 게놈 해킹은 하지 않음)
    if (a.nameJa === 'ゲノムハック') return;
    c.s.stack.push({ id: `f${c.s.nextId++}`, kind: 'attackEffect', step: 0, player: f.player, data: { sid: f.data.sid, base: a.damage, attackJa: a.nameJa } });
  } },
  'まるやけ': { run: (c, f) => { if (c.s.stadium) moveCard(c, c.s.stadium, { zone: 'discard', player: c.s.cards[c.s.stadium].owner }); updateBench(c); done(c, f); } },
  'ふきすさぶ': { run: (c, f) => {
    if (f.step === 0) { hit(c, f, base(f)); if (!c.s.stadium) return done(c, f); return seq(c, f, 1, [['yesno', { prompt: '스타디움을 트래쉬할까요?', save: 'answer' }]]); }
    if (f.data.answer === 'yes' && c.s.stadium) { moveCard(c, c.s.stadium, { zone: 'discard', player: c.s.cards[c.s.stadium].owner }); updateBench(c); }
    done(c, f);
  } },
  'むかえにいく': { run: (c, f) => then(c, f, [search('discard', { kind: 'pokemon', name: '해골몽' }, 3, 'bench', { prompt: '벤치에 낼 해골몽을 3장까지' })]) },
  'かげしばり': { run: (c, f) => { hit(c, f, base(f)); defenderEffect(c, f, 'noRetreat'); done(c, f); } },
  'ねらいおとす': { run: (c, f) => {
    const t = oppActive(c, f);
    const tool = t ? toolOf(c, t) : null;
    if (tool) moveCard(c, tool, { zone: 'discard', player: other(f.player) });
    hit(c, f, base(f));
    done(c, f);
  } },
  'ちいさなおつかい': { run: (c, f) => then(c, f, [search('deck', BASIC_ENERGY, 2, 'hand', { reveal: true, prompt: '기본 에너지를 2장까지' })]) },
  'ゴールドラッシュ': { run: (c, f) => {
    const p = c.s.players[f.player];
    const opts = cardsMatching(c, p.hand, BASIC_ENERGY);
    if (f.step === 0) return ask(c, f, 1, f.player, 'pickCards', opts, 0, opts.length, '트래쉬할 기본 에너지 (장당 50 데미지)', { cards: cardsOf(c, opts) });
    for (const e of f.picks ?? []) moveCard(c, e, { zone: 'discard', player: f.player });
    hit(c, f, 50 * (f.picks?.length ?? 0));
    done(c, f);
  } },
  'コスモビーム': { run: (c, f) => {
    if (!c.s.players[f.player].bench.some((b) => slotData(c, b).name === '루나톤')) { note(c, '벤치에 루나톤이 없어 기술 실패'); return done(c, f); }
    hit(c, f, base(f), false);
    done(c, f);
  } },
  'プロテクトチャージ': { run: (c, f) => { hit(c, f, base(f)); selfEffect(c, f, 'reduce30', 1); done(c, f); } },
  'サイコトリップ': { run: (c, f) => { hit(c, f, base(f)); const t = oppActive(c, f); if (t) setRot(c, t, 'confused'); done(c, f); } },
  'ファントムダイブ': { run: (c, f) => {
    if (f.step === 0) { hit(c, f, base(f)); f.data.left = 6; f.step = 1; }
    if (f.step === 2 && f.picks?.length) { const t = findSlot(c.s, f.picks[0]); if (t) putCounters(c, t.slot, 1); f.data.left = Number(f.data.left) - 1; }
    const bench = c.s.players[other(f.player)].bench;
    if (Number(f.data.left) <= 0 || !bench.length) return done(c, f);
    return ask(c, f, 2, f.player, 'pickSlot', bench.map((b) => b.sid), 1, 1, `데미지 카운터를 올릴 상대 벤치 포켓몬 (남은 ${f.data.left}개)`);
  } },
  'むずむずかふん': { run: (c, f) => { hit(c, f, base(f)); c.s.players[other(f.player)].effects.push({ kind: 'itemLock', until: c.s.turnNumber + 1 }); done(c, f); } },
  'うみのかげ': { run: (c, f) => { hit(c, f, base(f)); c.s.players[other(f.player)].effects.push({ kind: 'itemLock', until: c.s.turnNumber + 1 }); done(c, f); } },
  'ブラッドムーン': noAttackNext,
  'むげんのやいば': noAttackNext,
  'フォトンブラスター': noAttackNext,
  'プリズムエッジ': noAttackNext,
  'もってくる': { run: (c, f) => { drawOne(c, f.player); done(c, f); } },
  'コールサイン': { run: (c, f) => then(c, f, [search('deck', POKEMON, 3, 'hand', { reveal: true, prompt: '포켓몬을 3장까지' })]) },
  'ミラクルフォース': { run: (c, f) => { hit(c, f, base(f)); const a = atkSlot(c, f); if (a) a.cond = { poison: 0, burn: false, rot: '', paraUntil: 0 }; done(c, f); } },
  'ほえさけぶ': pickOppAny((c, f) => 20 * Math.floor((atkSlot(c, f)?.damage ?? 0) / 10)),
  'ガーランドレイ': { run: (c, f) => {
    const a = atkSlot(c, f)!;
    const ens = energiesOf(c, a);
    if (f.step === 0) return ask(c, f, 1, f.player, 'pickCards', ens, 0, Math.min(2, ens.length), '트래쉬할 에너지 (2장까지, 장당 120)', { cards: cardsOf(c, ens) });
    for (const e of f.picks ?? []) moveCard(c, e, { zone: 'discard', player: f.player });
    hit(c, f, 120 * (f.picks?.length ?? 0));
    done(c, f);
  } },
  'フルムーンロンド': { run: (c, f) => { hit(c, f, base(f) + 20 * (c.s.players[0].bench.length + c.s.players[1].bench.length)); done(c, f); } },
  'バチュチャージ': { run: (c, f) => then(c, f, [
    search('deck', { kind: 'energy', basicEnergy: true, etype: 'G' }, 2, 'attach', { shuffle: false, prompt: '기본 풀 에너지를 2장까지' }),
    search('deck', { kind: 'energy', basicEnergy: true, etype: 'L' }, 2, 'attach', { prompt: '기본 번개 에너지를 2장까지' })]) },
  'ビリビリウェブ': { run: (c, f) => { const a = atkSlot(c, f)!; const hasL = provided(c, a).some((u) => u === 'L' || u === '*'); hit(c, f, base(f) + (hasL ? 80 : 0)); done(c, f); } },
  'ごっつあんプリファイ': { run: (c, f) => { if (c.s.attackCtx) c.s.attackCtx.extraPrizes += 1; hit(c, f, base(f)); done(c, f); } },
  'トパーズボルト': { run: (c, f) => {
    const a = atkSlot(c, f)!;
    if (f.step === 0) {
      hit(c, f, base(f));
      const ens = energiesOf(c, a);
      if (ens.length <= 3) { for (const e of ens) moveCard(c, e, { zone: 'discard', player: f.player }); return done(c, f); }
      return ask(c, f, 1, f.player, 'pickCards', ens, 3, 3, '트래쉬할 에너지 3개', { cards: cardsOf(c, ens) });
    }
    for (const e of f.picks ?? []) moveCard(c, e, { zone: 'discard', player: f.player });
    done(c, f);
  } },
  'がっつく': { run: (c, f) => { hit(c, f, 80 * prizesTaken(c.s, f.player)); done(c, f); } },
  'ビッグバイト': { run: (c, f) => { const t = oppActive(c, f); hit(c, f, t && t.damage > 0 ? 30 : base(f)); done(c, f); } },
  'バーニングダーク': { run: (c, f) => { hit(c, f, base(f) + 30 * prizesTaken(c.s, other(f.player))); done(c, f); } },
  // 기술머신 에볼루션의 기술: 벤치 포켓몬 2마리까지 덱에서 진화
  'TM_EVOLUTION': { run: (c, f) => then(c, f, [['tmEvolution', {}]]) },

  // ── 공식 덱 레시피 ──
  '뒤집기GX': { run: (c, f) => { hit(c, f, base(f)); then(c, f, [['switchOwn', {}]]); } },
  '사이코파워': { run: (c, f) => then(c, f, [['placeCounters', { n: 3 }]]) },
  '예민해지기': { run: (c, f) => then(c, f, [search('deck', { kind: 'energy', basicEnergy: true, etype: 'F' }, 2, 'attachTo', { attachTo: f.data.sid, prompt: '이 포켓몬에게 붙일 기본 격투 에너지를 2장까지' })]) },
  '임팩트블로': { can: (c, s, slot) => (slot.effects.some((e) => e.kind === 'lockAttack' && e.name === '임팩트블로') ? '앞 차례에 쓴 기술이라 이번 차례에는 쓸 수 없습니다.' : null),
    run: (c, f) => { hit(c, f, base(f)); const a = atkSlot(c, f); if (a) a.effects.push({ kind: 'lockAttack', until: c.s.turnNumber + 2, name: '임팩트블로' }); done(c, f); } },
  '거다이일격': { run: (c, f) => {
    const a = atkSlot(c, f);
    const t = oppActive(c, f);
    if (a && t) dealAttackDamage(c, f.player, a, t, base(f), true, { ignoreEffects: true });
    if (a) for (const e of energiesOf(c, a)) moveCard(c, e, { zone: 'discard', player: f.player });
    done(c, f);
  } },
  '검은눈빛': { run: (c, f) => { hit(c, f, base(f)); defenderEffect(c, f, 'noRetreat'); done(c, f); } },
  '월광의칼날': { run: (c, f) => { const a = atkSlot(c, f); hit(c, f, base(f) + (a && a.damage > 0 ? 80 : 0)); done(c, f); } },
  '시치미스핏': { run: (c, f) => { const a = atkSlot(c, f); const t = oppActive(c, f); if (a && t) dealAttackDamage(c, f.player, a, t, base(f), true, { noWeak: true }); done(c, f); } },
  '로스트마인': { can: (c, s) => (lostCount(c.s, s) >= 10 ? null : '로스트존에 카드가 10장 이상 있어야 합니다.'), run: (c, f) => then(c, f, [['placeCounters', { n: 12 }]]) },
  '월광수리검': { run: (c, f) => {
    const a = atkSlot(c, f)!;
    if (f.step === 0) {
      const ens = energiesOf(c, a);
      if (ens.length <= 2) { for (const e of ens) moveCard(c, e, { zone: 'discard', player: f.player }); f.step = 2; }
      else return ask(c, f, 1, f.player, 'pickCards', ens, 2, 2, '트래쉬할 에너지 2개', { cards: cardsOf(c, ens) });
    }
    if (f.step === 1) { for (const e of f.picks ?? []) moveCard(c, e, { zone: 'discard', player: f.player }); f.picks = undefined; f.step = 2; }
    if (f.step === 2) {
      const opts = slotsOf(c.s, other(f.player)).map((sl) => sl.sid);
      const n = Math.min(2, opts.length);
      if (!n) return done(c, f);
      return ask(c, f, 3, f.player, 'pickSlot', opts, n, n, '90 데미지를 줄 상대 포켓몬 2마리');
    }
    for (const sid of f.picks ?? []) { const t = findSlot(c.s, sid); if (t) dealAttackDamage(c, f.player, a, t.slot, 90, t.active); }
    done(c, f);
  } },
  '어비스시크': { run: (c, f) => then(c, f, [['lookTake', { look: 4, take: 2, prompt: '덱 위 4장 중 패로 가져올 카드 2장 (나머지는 로스트존)' }]]) },
  '찢기': { run: (c, f) => { const a = atkSlot(c, f); const t = oppActive(c, f); if (a && t) dealAttackDamage(c, f.player, a, t, base(f), true, { ignoreEffects: true }); done(c, f); } },
  '다이내믹테일': { run: (c, f) => {
    if (f.step === 0) { hit(c, f, base(f)); return ask(c, f, 1, f.player, 'pickSlot', slotsOf(c.s, f.player).map((s) => s.sid), 1, 1, '60 데미지를 줄 내 포켓몬 1마리'); }
    const a = atkSlot(c, f);
    const t = findSlot(c.s, f.picks![0]);
    if (a && t) dealAttackDamage(c, f.player, a, t.slot, 60, false);
    done(c, f);
  } },
  '로스트임팩트': { run: (c, f) => {
    if (f.step === 0) {
      hit(c, f, base(f));
      const ens = slotsOf(c.s, f.player).flatMap((sl) => energiesOf(c, sl));
      if (ens.length <= 2) { for (const e of ens) moveCard(c, e, { zone: 'lost', player: f.player }); return done(c, f); }
      return ask(c, f, 1, f.player, 'pickCards', ens, 2, 2, '로스트존에 둘 내 필드의 에너지 2개', { cards: cardsOf(c, ens) });
    }
    for (const e of f.picks ?? []) moveCard(c, e, { zone: 'lost', player: f.player });
    done(c, f);
  } },
  '스타레퀴엠': { can: (c, s) => (lostCount(c.s, s) >= 10 ? null : '로스트존에 카드가 10장 이상 있어야 합니다.'), run: (c, f) => {
    const t = oppActive(c, f);
    if (t) { t.damage = Math.max(t.damage, maxHp(c, t)); note(c, `${slotName(c, t)}: 스타레퀴엠으로 기절`); }
    done(c, f);
  } },

  // ── 2023 코리안리그 시즌3 가디안 ex ──
  '메모리스킵': { run: (c, f) => {
    const t = oppActive(c, f);
    if (f.step === 0) {
      hit(c, f, base(f));
      const atks = t && !t.faceDown && remainingHp(c, t) > 0 ? slotData(c, t).pokemon?.attacks ?? [] : [];
      if (!atks.length) return done(c, f);
      const opts = atks.map((_, i) => String(i));
      return ask(c, f, 1, f.player, 'pickOption', opts, 1, 1, '상대의 다음 차례에 못 쓰게 할 기술을 고르세요.', { labels: Object.fromEntries(atks.map((a, i) => [String(i), `${a.name || a.nameJa} ${a.damage || ''}${a.op}`])) });
    }
    const a = t ? slotData(c, t).pokemon?.attacks[Number(f.picks![0])] : undefined;
    if (t && a) { t.effects.push({ kind: 'lockAttack', until: c.s.turnNumber + 1, name: a.name || a.nameJa }); note(c, `${slotName(c, t)}: 다음 차례에 [${a.name || a.nameJa}] 사용 불가`); }
    done(c, f);
  } },
  '텔레포트 브레이크': { run: (c, f) => { hit(c, f, base(f)); then(c, f, [['switchOwn', {}]]); } },
  '문라이트 리버스': { run: (c, f) => {
    const mine = slotsOf(c.s, f.player).filter((sl) => sl.damage >= 10);
    const n = mine.reduce((acc, sl) => acc + Math.min(2, Math.floor(sl.damage / 10)), 0);
    if (f.step === 0) {
      if (!n) { note(c, '옮길 데미지 카운터가 없습니다.'); return done(c, f); }
      return ask(c, f, 1, f.player, 'pickSlot', slotsOf(c.s, other(f.player)).map((sl) => sl.sid), 1, 1, `내 포켓몬의 데미지 카운터 ${n}개를 옮겨 올릴 상대 포켓몬`);
    }
    const t = findSlot(c.s, f.picks![0])?.slot;
    if (t) {
      for (const sl of mine) { const k = Math.min(2, Math.floor(sl.damage / 10)); sl.damage -= k * 10; emit(c, { type: 'heal', player: f.player, sid: sl.sid, amount: k * 10 }); }
      putCounters(c, t, n);
    }
    done(c, f);
  } },
  '스톰슬래시': psyBonus,
  '브레인웨이브': psyBonus,
  '아쿠아리턴': { can: (c, s) => (c.s.players[s].bench.length ? null : '벤치 포켓몬이 없으면 쓸 수 없습니다 (필드에 포켓몬이 남지 않음).'),
    run: (c, f) => {
      hit(c, f, base(f));
      const a = atkSlot(c, f);
      if (a) {
        for (const x of [...a.attached]) moveCard(c, x, { zone: 'deck', player: f.player, position: 'top' });
        for (const x of [...a.stack]) moveCard(c, x, { zone: 'deck', player: f.player, position: 'top' });
        shuffleDeck(c, f.player);
      }
      done(c, f);
      if (!c.s.players[f.player].active) c.s.stack.push({ id: `f${c.s.nextId++}`, kind: 'promote', step: 0, player: f.player, data: {} });
    } },
};

/** 데미지 카운터 n개를 상대 포켓몬에게 원하는 대로 (하나씩 고름) — data { n } */
FRAMES.placeCounters = (ctx, f) => {
  if (f.step === 0) { f.data.left = Number(f.data.n); f.step = 1; }
  if (f.step === 2 && f.picks?.length) { const t = findSlot(ctx.s, f.picks[0]); if (t) putCounters(ctx, t.slot, 1); f.data.left = Number(f.data.left) - 1; }
  const opts = slotsOf(ctx.s, other(f.player)).map((s) => s.sid);
  if (Number(f.data.left) <= 0 || !opts.length) return done(ctx, f);
  return ask(ctx, f, 2, f.player, 'pickSlot', opts, 1, 1, `데미지 카운터를 올릴 상대 포켓몬 (남은 ${f.data.left}개)`);
};

// 효과 없는 기술 (기본 데미지만)
for (const n of ['ひだね', 'ひをはく', 'かぜおこし', 'つばさでうつ', 'つぶやく', 'おにび', 'たいあたり', 'パワージェム', 'ちょっとうらむ', 'かみつく', 'リューズヘッド',
  'ジェットヘッド', 'スキップ', 'クォーツシャイン', 'スピードウイング', 'ずつき', 'サイコショット', 'ビンタ', 'アームプレス', 'マグネブラスト',
  '물기', '날카로운날개', '어둠엄니', '정권찌르기', '다이아크', '회전어택', '물뿌리기', '할퀴기', '루나블라스트']) ATTACKS[n] = plain;

export const TM_ATTACK = { name: '에볼루션', nameJa: 'TM_EVOLUTION', cost: ['C'] as EType[], damage: 0, op: '' as const, text: '자신의 벤치 포켓몬을 2마리까지 골라, 각각 덱에서 그 포켓몬으로부터 진화하는 카드를 찾아 진화시킨다.' };

FRAMES.tmEvolution = (ctx, f) => {
  const p = ctx.s.players[f.player];
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickSlot', p.bench.map((b) => b.sid), 0, 2, '진화시킬 벤치 포켓몬 (2마리까지)');
  if (f.step === 1) f.data.targets = f.picks ?? [];
  if (f.step === 3) {
    const targets = f.data.targets as string[];
    if (f.picks?.length) evolveFrom(ctx, f.player, f.picks[0], targets[0], false);
    f.data.targets = targets.slice(1);
  }
  // 남은 대상마다 덱에서 진화 카드 고르기 (진화할 카드가 없는 대상은 건너뜀)
  let left = f.data.targets as string[];
  while (left.length) {
    const slot = findSlot(ctx.s, left[0])?.slot;
    const nm = slot ? slotName(ctx, slot) : '';
    const opts = p.deck.filter((i) => dataOf(ctx, i).pokemon?.from === nm);
    if (opts.length) return ask(ctx, f, 3, f.player, 'pickCards', opts, 0, 1, `${nm}에서 진화하는 카드`, { cards: cardsOf(ctx, p.deck) });
    left = left.slice(1);
    f.data.targets = left;
  }
  shuffleDeck(ctx, f.player);
  done(ctx, f);
};
/** 기술 효과 실행 프레임 (데미지 + 효과) */
FRAMES.attackEffect = (ctx, f) => {
  const def = ATTACKS[String(f.data.attackJa)];
  if (!def) { hit(ctx, f, base(f)); note(ctx, '이 기술의 효과는 아직 자동화되지 않았습니다 (기본 데미지만)'); return done(ctx, f); }
  def.run(ctx, f);
};

// ───────────────────────── 벤치 칸 수 (제로의 대공동) ─────────────────────────

/** 스타디움·테라스탈 변화 뒤 벤치 칸 수를 다시 계산. 넘치면 넘친 만큼 트래쉬 (스타디움 주인부터) */
export function updateBench(ctx: Ctx) {
  const st = stadiumName(ctx);
  const order: Seat[] = ctx.s.stadium ? [ctx.s.cards[ctx.s.stadium].owner, other(ctx.s.cards[ctx.s.stadium].owner)] : [0, 1];
  for (const seat of order) {
    const p = ctx.s.players[seat];
    p.benchMax = st === '무너진 스타디움' ? 4 : st === '제로의 대공동' && hasTera(ctx, seat) ? 8 : 5;
    if (p.bench.length > p.benchMax) ctx.s.stack.push({ id: `f${ctx.s.nextId++}`, kind: 'benchTrim', step: 0, player: seat, data: {} });
  }
}
FRAMES.benchTrim = (ctx, f) => {
  const p = ctx.s.players[f.player];
  const over = p.bench.length - p.benchMax;
  if (over <= 0) return done(ctx, f);
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'pickSlot', p.bench.map((b) => b.sid), over, over, `벤치가 ${p.benchMax}마리가 되도록 트래쉬할 포켓몬 ${over}마리`);
  for (const sid of f.picks ?? []) { const t = findSlot(ctx.s, sid); if (t) clearSlot(ctx, t.slot, f.player, 'discard'); }
  done(ctx, f);
};

/** 새 배틀 포켓몬 내기 (배틀 포켓몬이 없을 때) */
FRAMES.promote = (ctx, f) => {
  const p = ctx.s.players[f.player];
  if (p.active || !p.bench.length) return done(ctx, f);
  if (f.step === 0) return ask(ctx, f, 1, f.player, 'promote', p.bench.map((b) => b.sid), 1, 1, '새 배틀 포켓몬을 고르세요.');
  const i = p.bench.findIndex((b) => b.sid === f.picks![0]);
  if (i >= 0) { p.active = p.bench.splice(i, 1)[0]; emit(ctx, { type: 'switch', player: f.player, from: '', to: p.active.sid }); }
  done(ctx, f);
};

// ───────────────────────── 자동화 여부 ─────────────────────────

const PASSIVE = new Set(['スカイライン', 'いたずらロック', 'ダイヤコート', 'フェアリーゾーン', 'ふくがん', 'みがる', 'ろうれんのわざ', 'がんばりハート', 'エースキャンセラー',
  'ブーストしんか', 'にじいろDNA', 'ほうせきさがし', 'れんごくしはい', 'フライングエントリー', 'ラピッドバーニア',
  '벤치배리어', '파도의 베일', '로스트 프로바이드', '와일드스타일', '다크시그널', '루미너스사인']);
const TOOLS = new Set(['반짝이는 결정', '풍선', '오기머리띠', '용기의부적', '학습장치', '부스트에너지 미래', '기술머신 에볼루션', '하늘의 봉인석']);
const STADIUMS = new Set(['제로의 대공동', '재밍타워', '그래비티 마운틴', '보울마을', '악의 탑', '정상으로 가는 눈길', '무너진 스타디움', '신오신전']);
const SPECIAL_ENERGY = new Set(['제트 에너지', '네오 어퍼 에너지', '루미너스 에너지', '일격 에너지', '캡쳐 에너지']);

/** 카드 효과가 자동화되었는가 (화면에 "수동" 표시용, 데이터 테스트에서 전부 true 인지 검사) */
export function isAutomated(d: CardData): boolean {
  if (d.kind === 'energy') return d.energy?.basic || SPECIAL_ENERGY.has(d.name);
  if (d.kind === 'trainer') return !!TRAINERS[d.name] || TOOLS.has(d.name) || STADIUMS.has(d.name);
  const p = d.pokemon!;
  return p.attacks.every((a) => !!ATTACKS[a.nameJa]) && p.abilities.every((a) => PASSIVE.has(a.nameJa) || !!ABILITIES[a.nameJa]);
}

export { ownerOfSlot };
