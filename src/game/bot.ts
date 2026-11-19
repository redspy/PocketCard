// 봇: 자기 시점 보기(view)만 보고 행동을 고른다 (상대 패·덱을 모름 → 폰과 같은 조건).
//  - randomBot: 합법 행동 중 무작위 (퍼징·버그 찾기용)
//  - makeAiBot: 1인용 AI — 카드 데이터(공개 정보)를 써서 간단한 우선순위로 플레이
// 봇 난수는 게임 시드와 별개 (게임 결정성에 영향 없음, 로그에는 봇의 입력이 그대로 남음).
import { randInt } from './rng.ts';
import type { RngState } from './rng.ts';
import type { CardData, CardDB, EType } from './cardData.ts';
import type { Catalog } from './catalog.ts';
import type { ClientInput } from './protocol.ts';
import type { GameView, MoveView, RequestView, SlotView } from './view.ts';

export type Bot = (view: GameView, rng: RngState) => ClientInput | null;

const strip = (m: MoveView): ClientInput => {
  const { player: _p, ...rest } = m.input as MoveView['input'] & { player: number };
  return rest as ClientInput;
};

/** 할 일이 있는가 (선택 요청 또는 내 차례 행동) */
export function botHasWork(view: GameView): boolean {
  if (typeof view.viewer !== 'number') return false;
  if (view.requests.some((r) => r.player === view.viewer && r.options)) return true;
  return !!view.actions?.some((a) => a.kind === 'endTurn');
}

function randomPicks(req: RequestView, rng: RngState): string[] {
  const min = req.min ?? 0, max = Math.min(req.max ?? 0, req.options?.length ?? 0);
  const n = min + randInt(rng, Math.max(1, max - min + 1));
  const pool = [...(req.options ?? [])];
  const picks: string[] = [];
  for (let i = 0; i < Math.min(n, max); i++) picks.push(pool.splice(randInt(rng, pool.length), 1)[0]);
  return picks;
}

export const randomBot: Bot = (view, rng) => {
  if (typeof view.viewer !== 'number') return null;
  const req = view.requests.find((r) => r.player === view.viewer && r.options);
  if (req) return { type: 'choice', requestId: req.id, picks: randomPicks(req, rng) };
  const acts = (view.actions ?? []).filter((a) => a.kind !== 'concede');
  if (!acts.length) return null;
  // 턴 종료는 낮은 확률로 (너무 빨리 끝내지 않게)
  const nonEnd = acts.filter((a) => a.kind !== 'endTurn');
  if (nonEnd.length && randInt(rng, 5) !== 0) return strip(nonEnd[randInt(rng, nonEnd.length)]);
  return strip(acts.find((a) => a.kind === 'endTurn') ?? acts[0]);
};

// ───────────────────────── 1인용 AI ─────────────────────────

/** 카드 코드(인쇄) → 카드 데이터 */
export function codeIndex(cat: Catalog, db: CardDB): Record<string, CardData> {
  const out: Record<string, CardData> = {};
  for (const d of cat.decks) for (const c of d.cards) { const data = db[c.id]; if (!data) continue; for (const p of c.prints) out[p] = data; out[c.code] = data; }
  return out;
}

export function makeAiBot(cat: Catalog, db: CardDB): Bot {
  const byCode = codeIndex(cat, db);
  // 이번 턴 행동 수 (무한 반복 방지). 턴이 바뀌거나 새 게임(버전이 줄어듦)이면 다시 셈
  let counted = { turn: -1, version: -1, seat: -1, n: 0 };
  const card = (code: string | undefined) => (code ? byCode[code] : undefined);
  const top = (s: SlotView | null) => (s?.stack ? card(s.stack[s.stack.length - 1].code) : undefined);
  const remain = (s: SlotView) => (s.hp ?? 0) - s.damage;
  const units = (s: SlotView): (EType | '*')[] => (s.attached ?? []).flatMap((a) => {
    const d = card(a.code);
    if (!d || d.kind !== 'energy') return [];
    if (d.energy?.basic && d.energy.type) return [d.energy.type];
    return d.name === '루미너스 에너지' ? ['*'] : ['C'];
  });
  const missing = (s: SlotView, cost: EType[]): EType[] => {
    const pool = units(s);
    const need: EType[] = [];
    for (const t of cost.filter((c) => c !== 'C')) { let i = pool.indexOf(t); if (i < 0) i = pool.indexOf('*'); if (i < 0) need.push(t); else pool.splice(i, 1); }
    const c = cost.filter((x) => x === 'C').length;
    for (let i = pool.length; i < c; i++) need.push('C');
    return need;
  };
  /** 이 포켓몬의 가장 센 기술 (기본 데미지 기준) */
  const bestAttack = (d?: CardData) => (d?.pokemon?.attacks ?? []).reduce<{ dmg: number; cost: EType[] } | null>((b, a) => {
    const dmg = a.damage || (a.text ? 30 : 0);
    return !b || dmg > b.dmg ? { dmg, cost: a.cost } : b;
  }, null);
  /** 카드 가치 (버릴 카드·가져올 카드 고르기). needTypes: 내 포켓몬 기술에 필요한 에너지 타입 */
  let needTypes = new Set<string>();
  const value = (code: string): number => {
    const d = card(code);
    if (!d) return 0;
    if (d.kind === 'pokemon') return 50 + (d.pokemon!.rule ? 30 : 0) + d.pokemon!.stage * 10;
    if (d.kind === 'trainer') return d.trainer === 'supporter' ? 45 : d.trainer === 'stadium' ? 15 : d.name === '기술머신 에볼루션' ? 10 : 35;
    if (d.energy?.basic) return needTypes.has(d.energy.type ?? '') ? 70 : 12;
    return 40;
  };

  return (view, rng) => {
    if (typeof view.viewer !== 'number') return null;
    const me = view.players[view.viewer];
    const opp = view.players[view.viewer === 0 ? 1 : 0];
    const mySids = new Set([me.active, ...me.bench].filter(Boolean).map((s) => s!.sid));
    needTypes = new Set([me.active, ...me.bench].filter(Boolean).flatMap((s) => bestAttack(top(s!))?.cost ?? []).filter((c) => c !== 'C'));
    for (const h of me.hand ?? []) { const d = card(h.code); if (d?.kind === 'pokemon') for (const c of bestAttack(d)?.cost ?? []) if (c !== 'C') needTypes.add(c); }
    const slotBySid = (sid: string) => [me.active, ...me.bench, opp.active, ...opp.bench].find((s) => s?.sid === sid) ?? null;

    // ── 선택 요청
    const req = view.requests.find((r) => r.player === view.viewer && r.options);
    if (req) {
      const opts = req.options ?? [];
      const min = req.min ?? 0, max = req.max ?? 0;
      const take = (sorted: string[], n: number) => ({ type: 'choice' as const, requestId: req.id, picks: sorted.slice(0, n) });
      const codeOf = (o: string) => req.cards?.find((c) => c.iid === o)?.code ?? me.hand?.find((h) => h.iid === o)?.code;
      switch (req.kind) {
        case 'chooseFirst': return take(['second'], 1);
        case 'ackReveal': return take(['ok'], 1);
        case 'mulliganDraw': return take([opts[opts.length - 1]], 1);
        case 'chooseActive': {
          // 공격을 빨리 할 수 있는 기본 포켓몬 (비용이 적고 HP 가 높은 것)
          const score = (o: string) => { const d = card(codeOf(o)); const b = bestAttack(d); return (d?.pokemon?.hp ?? 0) / 10 - (b?.cost.length ?? 4) * 5 - (d?.pokemon?.rule ? 8 : 0); };
          return take([...opts].sort((a, b) => score(b) - score(a)), 1);
        }
        case 'chooseBench': return take(opts, max);
        case 'takePrize': case 'promote': {
          if (req.kind === 'takePrize') return take(opts, min);
          const score = (sid: string) => { const s = slotBySid(sid); const b = bestAttack(top(s)); return s ? (b && missing(s, b.cost).length === 0 ? 1000 : 0) + units(s).length * 50 + remain(s) : 0; };
          return take([...opts].sort((a, b) => score(b) - score(a)), 1);
        }
        case 'pickOption': {
          if (opts.includes('yes')) return take(['yes'], 1);
          if (opts.includes('boost')) return take([top(opp.active)?.pokemon?.rule ? 'boost' : (opts.includes('switch') ? 'switch' : 'boost')], 1);
          // 숫자·기술 선택: 가장 큰 것
          const sorted = [...opts].sort((a, b) => (Number(b) || 0) - (Number(a) || 0));
          const lab = req.labels ?? {};
          const byDmg = [...opts].sort((a, b) => (parseInt(lab[b]?.replace(/\D/g, '') || '0') - parseInt(lab[a]?.replace(/\D/g, '') || '0')));
          return take(req.prompt.includes('기술') ? byDmg : sorted, 1);
        }
        case 'pickSlot': {
          const oppSide = opts.every((o) => !mySids.has(o));
          if (oppSide) {
            // 상대: 기절시킬 수 있는(남은 HP 낮은) 것, 사이드 가치 높은 것
            const score = (sid: string) => { const s = slotBySid(sid); if (!s) return 0; const d = top(s); return -remain(s) + (d?.pokemon?.rule ? 60 : 0); };
            return take([...opts].sort((a, b) => score(b) - score(a)), Math.max(min, Math.min(max, 1)));
          }
          // 내 포켓몬: 공격 준비에 가까운(에너지가 필요한) 주력
          const score = (sid: string) => { const s = slotBySid(sid); if (!s) return 0; const d = top(s); const b = bestAttack(d); return (b?.dmg ?? 0) + (s === me.active ? 40 : 0) + (d?.pokemon?.rule ? 30 : 0) + (b ? -missing(s, b.cost).length * 5 : 0); };
          if (req.prompt.includes('트래쉬')) return take([...opts].sort((a, b) => score(a) - score(b)), Math.max(min, 1));
          return take([...opts].sort((a, b) => score(b) - score(a)), Math.max(min, Math.min(max, 1)));
        }
        case 'pickCards': {
          const lose = /트래쉬|되돌릴|버릴/.test(req.prompt) && !/패로 가져올|가져올/.test(req.prompt);
          // 가져올 때: 이미 패에 있는 이름은 덜, 필드의 포켓몬에서 진화하는 카드는 더
          const fieldNames = new Set([me.active, ...me.bench].filter(Boolean).map((s) => top(s!)?.name));
          const handNames = (me.hand ?? []).map((h) => card(h.code)?.name);
          const gain = (o: string) => {
            const d = card(codeOf(o));
            let v = value(codeOf(o) ?? '');
            if (!d) return v;
            v -= 35 * handNames.filter((x) => x === d.name).length;
            if (d.pokemon?.from && fieldNames.has(d.pokemon.from)) v += 45;
            if (d.pokemon?.stage === 2 && [...fieldNames].some((nm) => Object.values(byCode).some((c) => c.pokemon?.stage === 1 && c.pokemon.from === nm && c.name === d.pokemon!.from))) v += 30;
            return v;
          };
          const sorted = [...opts].sort((a, b) => (lose ? value(codeOf(b) ?? '') - value(codeOf(a) ?? '') : gain(b) - gain(a)));
          if (lose) return take(sorted.reverse(), Math.max(min, req.prompt.includes('장당') ? max : min));
          return take(sorted, max);
        }
        default: return { type: 'choice', requestId: req.id, picks: randomPicks(req, rng) };
      }
    }

    // ── 내 차례 행동
    const acts = (view.actions ?? []).filter((a) => a.kind !== 'concede');
    if (!acts.length) return null;
    if (counted.turn !== view.turnNumber || counted.seat !== view.viewer || view.version < counted.version) counted = { turn: view.turnNumber, version: view.version, seat: view.viewer, n: 0 };
    counted.version = view.version;
    const n = ++counted.n;
    const end = acts.find((a) => a.kind === 'endTurn');
    if (n > 60 && end) return strip(end);
    const pick = (kind: string, pred: (m: MoveView) => boolean = () => true) => acts.find((a) => a.kind === kind && pred(a));
    const handCode = (iid?: string) => me.hand?.find((h) => h.iid === iid)?.code;
    const act = me.active;
    const actBest = bestAttack(top(act));
    const attacks0 = acts.filter((a) => a.kind === 'attack');
    const oppAct = opp.active;
    const canKo = (dmg: number, t: SlotView | null) => !!t && dmg >= remain(t);
    const prizesTakenBy = (p: typeof me) => 6 - p.prizes.filter(Boolean).length;
    const energyCount = (p: typeof me) => [p.active, ...p.bench].reduce((n, s) => n + (s?.attached ?? []).filter((a) => card(a.code)?.kind === 'energy').length, 0);
    /** 기술 데미지 추정 (×·+ 기술은 지금 상황으로 계산, 약점 반영) */
    const estimate = (s: SlotView | null, i: number): number => {
      const d = top(s);
      const a = d?.pokemon?.attacks[i];
      if (!a || !s) return 0;
      let dmg = a.damage;
      switch (a.nameJa) {
        case 'ユニオンビート': dmg = 30 * me.bench.length; break;
        case 'あおばのあらし': dmg = 60 * energyCount(opp); break;
        case 'ゴールドラッシュ': dmg = 50 * (me.hand ?? []).filter((h) => card(h.code)?.energy?.basic).length; break;
        case 'ガーランドレイ': dmg = 120 * Math.min(2, (s.attached ?? []).filter((x) => card(x.code)?.kind === 'energy').length); break;
        case 'がっつく': dmg = 80 * prizesTakenBy(me); break;
        case 'フルムーンロンド': dmg = 20 + 20 * (me.bench.length + opp.bench.length); break;
        case 'さんどづき': dmg = 15; break;
        case 'バーニングダーク': dmg = 180 + 30 * prizesTakenBy(opp); break;
        case 'ビッグバイト': dmg = oppAct && oppAct.damage > 0 ? 30 : 260; break;
        case 'ほえさけぶ': dmg = 20 * Math.floor(s.damage / 10); break;
        case 'クルーエルアロー': dmg = 100; break;
        case '스톰슬래시': case '브레인웨이브': dmg = 60 + 30 * (s.attached ?? []).filter((x) => card(x.code)?.energy?.type === 'P').length; break;
        default: if (!dmg && a.text) dmg = 20;
      }
      const od = top(oppAct);
      if (od?.pokemon?.weak && od.pokemon.weak === d?.pokemon?.type) dmg *= 2;
      if (od?.pokemon?.resist && od.pokemon.resist === d?.pokemon?.type) dmg -= 30;
      return Math.max(0, dmg);
    };
    const lowDeck = me.deckCount <= 8;

    // 1) 드로우·서치 특성 (커스드밤은 기절시킬 수 있을 때만, 사이코 임브레이스는 주력 에너지가 부족할 때만)
    const abil = acts.find((a) => {
      if (a.kind !== 'ability') return false;
      const s = slotBySid(a.target ?? '');
      const d = top(s);
      const ab = d?.pokemon?.abilities[0]?.nameJa;
      if (ab === 'カースドボム') { const c = d?.pokemon?.stage === 2 ? 130 : 50; if (opp.prizes.filter(Boolean).length <= 1) return false; return [opp.active, ...opp.bench].some((t) => t && remain(t) <= c && top(t)?.pokemon?.rule); }
      if (ab === 'サイコエンブレイス') return !!act && !!actBest && missing(act, actBest.cost).length > 0 && n < 20;
      // 하늘의 봉인석 [스타오더]: 배틀의 기본 포켓몬 V 가 지금 기술로 상대 배틀의 VSTAR·VMAX 를 기절시킬 수 있을 때만
      if ((a.input as { tool?: boolean }).tool) {
        const ad = top(act)?.pokemon, od = top(oppAct)?.pokemon;
        if (s !== act || !ad || ad.rule !== 'V' || ad.stage !== 0 || !od || (od.rule !== 'VSTAR' && od.rule !== 'VMAX')) return false;
        return attacks0.some((m) => canKo(estimate(act, Number((m.input as { index: number }).index)), oppAct));
      }
      if (ab === '검의 포효') return false;   // 쓰면 차례가 끝남 → 맨 마지막에 (아래 7번 뒤)
      const drawy = ['さかてにとる', 'リスタート', 'ボーナスコイン', 'ルナサイクル', 'ていさつしれい', '리파인'];
      if (lowDeck && drawy.includes(ab ?? '')) return false;
      return true;
    });
    if (abil) return strip(abil);
    // 2) 벤치에 기본 포켓몬 (벤치 1칸은 남김), 진화
    const bench = pick('play', () => me.bench.length < me.benchMax - 1);
    if (bench) return strip(bench);
    const evo = pick('evolve');
    if (evo) return strip(evo);
    // 3) 트레이너스
    const trainers = acts.filter((a) => a.kind === 'trainer');
    const gustNames = ['보스의 지령', '카운터 캐처', '프라임 캐처'];
    for (const t of trainers) {
      const d = card(handCode(t.card));
      const nm = d?.name ?? '';
      if (gustNames.includes(nm)) {
        // 끌어낼 상대 벤치 중 지금 기술로 기절시킬 수 있는 것이 있을 때만
        if (actBest && act && missing(act, actBest.cost).length === 0 && opp.bench.some((b) => canKo(actBest.dmg, b) && !canKo(actBest.dmg, oppAct))) return strip(t);
        continue;
      }
      if (nm === '포켓몬 교체' || nm === '투로박사의 시나리오' || nm === '에너지 갈아 달기') continue;
      const handN = me.hand?.length ?? 0;
      const noEnergy = !(me.hand ?? []).some((h) => card(h.code)?.kind === 'energy');
      if (nm === '모야모' && handN > 4 && !(opp.handCount >= 7)) continue;
      if (nm === '릴리에의 결심' && ((handN > 5 && !noEnergy) || lowDeck)) continue;
      if (nm === '모야모' && lowDeck && handN > 2) continue;
      if ((nm === '태권왕의 수련' || nm === '카지') && !(actBest && act && missing(act, actBest.cost).length === 0 && top(oppAct)?.pokemon?.rule)) continue;
      if (d?.trainer === 'stadium' && view.stadium) continue;
      return strip(t);
    }
    // 4) 에너지: 포켓몬마다 "가장 빨리 쓸 수 있는 기술"을 목표로, 그 기술에 필요한 에너지를 붙인다
    //    배틀 포켓몬이 공격도 후퇴도 못 하면 배틀 포켓몬 우선
    const attaches = acts.filter((a) => a.kind === 'attach');
    if (attaches.length) {
      const actStuck = !!act && !attacks0.length && (act.retreat ?? 0) > units(act).length;
      const plan = (s: SlotView) => {
        const atks = top(s)?.pokemon?.attacks ?? [];
        return atks.map((a) => ({ need: missing(s, a.cost), dmg: a.damage || (a.text ? 40 : 0) }))
          .filter((x) => x.dmg > 0).sort((x, y) => x.need.length - y.need.length || y.dmg - x.dmg)[0];
      };
      const score = (m: MoveView) => {
        const s = slotBySid(m.target ?? '');
        const d = card(handCode(m.card));
        if (!s) return -100;
        const pl = plan(s);
        const isAct = s === act;
        if (isAct && actStuck) return 300;
        if (!pl || !pl.need.length) return isAct ? -10 : -50;
        const t = d?.energy?.type;
        const fits = pl.need.some((x) => x === t || x === 'C') || d?.name === '루미너스 에너지' || (d?.name === '네오 어퍼 에너지' && top(s)?.pokemon?.stage === 2);
        return (fits ? 100 : 0) + (isAct ? 60 : 0) + (top(s)?.pokemon?.rule ? 20 : 0) + pl.dmg / 10 - pl.need.length * 5;
      };
      const best = [...attaches].sort((a, b) => score(b) - score(a))[0];
      if (score(best) > 0) return strip(best);
    }    // 5) 도구
    const tool = pick('tool', (m) => { const d = card(handCode(m.card)); if (d?.name === '기술머신 에볼루션') return false; const s = slotBySid(m.target ?? ''); if (d?.name === '풍선') return s === act && (act?.retreat ?? 0) >= 2; if (d?.name === '용기의부적') return top(s)?.pokemon?.stage === 0; return s === act || !!top(s)?.pokemon?.rule; });
    if (tool) return strip(tool);
    const attacks = acts.filter((a) => a.kind === 'attack');
    const dmgOfIdx = (s: SlotView | null, i: number) => estimate(s, i);
    const myBestNow = attacks.reduce((b, m) => Math.max(b, dmgOfIdx(act, Number((m.input as { index: number }).index))), 0);
    const readyBench = (s: SlotView) => { const b = bestAttack(top(s)); return b && missing(s, b.cost).length === 0 ? b.dmg : 0; };
    const swapTo = acts.filter((a) => a.kind === 'retreat').map((m) => ({ m, d: readyBench(slotBySid(m.target ?? '')!) })).sort((a, b) => b.d - a.d)[0];
    if (swapTo && swapTo.d >= Math.max(60, myBestNow * 2) && !me.flags.retreat) return strip(swapTo.m);
    const switchCard = acts.find((a) => a.kind === 'trainer' && card(handCode(a.card))?.name === '포켓몬 교체');
    if (switchCard && me.bench.some((b) => readyBench(b) >= Math.max(60, myBestNow * 2))) return strip(switchCard);
    // 6) 기술: 가장 센 것 (기절시킬 수 있으면 그것)
    if (attacks.length) {
      const dmgOf = (m: MoveView) => { const i = Number((m.input as { index: number }).index); const e = estimate(act, i); return (canKo(e, oppAct) ? 1000 : 0) + e; };
      const best = [...attacks].sort((a, b) => dmgOf(b) - dmgOf(a))[0];
      return strip(best);
    }
    // 7) 공격할 수 없으면 후퇴 (기술을 쓸 수 있는 벤치로)
    const retreat = acts.filter((a) => a.kind === 'retreat').sort((a, b) => {
      const sc = (m: MoveView) => { const s = slotBySid(m.target ?? ''); const bb = bestAttack(top(s)); return s && bb ? (missing(s, bb.cost).length === 0 ? 100 : 0) + bb.dmg / 10 : 0; };
      return sc(b) - sc(a);
    })[0];
    if (retreat && act) {
      const s = slotBySid(retreat.target ?? '');
      const bb = bestAttack(top(s));
      if (s && bb && missing(s, bb.cost).length === 0) return strip(retreat);
    }
    const stadium = pick('stadium');
    if (stadium) return strip(stadium);
    // 자시안 V "검의 포효": 공격할 수 없는 차례의 끝에 (쓰면 차례가 끝남)
    const sword = acts.find((a) => a.kind === 'ability' && !(a.input as { tool?: boolean }).tool && top(slotBySid(a.target ?? ''))?.pokemon?.abilities[0]?.nameJa === '검의 포효');
    if (sword) return strip(sword);
    return end ? strip(end) : null;
  };
}
