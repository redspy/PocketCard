// 테스트 공용: 덱 카탈로그, 무작위 플레이어(합법 행동만), 불변식·누출 검사
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { buildCatalog, buildDeck, cardInfo } from '../../src/game/catalog.ts';
import type { RawDecks } from '../../src/game/catalog.ts';
import { applyInput, blockingRequests, countCards, createGame, legalMoves } from '../../src/game/engine.ts';
import { randInt, seedRng } from '../../src/game/rng.ts';
import type { RngState } from '../../src/game/rng.ts';
import type { GameConfig, GameEvent, GameInput, GameState, Seat, Viewer } from '../../src/game/types.ts';
import { GameError } from '../../src/game/types.ts';
import { eventsFor, viewFor } from '../../src/game/view.ts';

export const catalog = buildCatalog(JSON.parse(readFileSync(fileURLToPath(new URL('../../godot/data/decks.json', import.meta.url)), 'utf8')) as RawDecks);
export const info = cardInfo(catalog, JSON.parse(readFileSync(fileURLToPath(new URL('../../src/data/rules/cards.json', import.meta.url)), 'utf8')));
export const deckIds = catalog.decks.map((d) => d.id);

export function config(seed: string, a: string, b: string): GameConfig {
  return { seed, players: [{ deckId: a, cards: buildDeck(catalog, a) }, { deckId: b, cards: buildDeck(catalog, b) }] };
}

/** 지금 할 수 있는 입력 중 하나를 무작위로 고른다 (선택 요청이 있으면 그것부터, 행동은 합법 행동 목록에서) */
export function randomInput(s: GameState, r: RngState): GameInput | null {
  const reqs = s.requests;
  if (reqs.length) {
    const blocking = reqs.filter((x) => x.kind !== 'ackReveal');
    const req = (blocking.length ? blocking : reqs)[randInt(r, (blocking.length ? blocking : reqs).length)];
    const max = Math.min(req.max, req.options.length);
    const n = req.min + randInt(r, Math.max(1, max - req.min + 1));
    const pool = [...req.options];
    const picks: string[] = [];
    for (let i = 0; i < Math.min(n, max); i++) picks.push(pool.splice(randInt(r, pool.length), 1)[0]);
    return { type: 'choice', player: req.player, requestId: req.id, picks };
  }
  if (s.phase !== 'playing' || s.turnPlayer === null) return null;
  const moves = legalMoves(s, s.turnPlayer, info).filter((m) => m.kind !== 'concede');
  if (randInt(r, 400) === 0) return { type: 'concede', player: s.turnPlayer };
  const nonEnd = moves.filter((m) => m.kind !== 'endTurn');
  if (nonEnd.length && randInt(r, 6) !== 0) return nonEnd[randInt(r, nonEnd.length)].input;
  return moves.find((m) => m.kind === 'endTurn')?.input ?? null;
}
export type Played = { config: GameConfig; inputs: GameInput[]; states: GameState[]; events: GameEvent[][] };

export function playRandom(seed: string, a: string, b: string, maxSteps = 400): Played {
  const cfg = config(seed, a, b);
  const r = seedRng(seed.split('').reverse().join(''));
  const first = createGame(cfg, info);
  const out: Played = { config: cfg, inputs: [], states: [first.state], events: [first.events] };
  let s = first.state;
  for (let i = 0; i < maxSteps; i++) {
    const input = randomInput(s, r);
    if (!input) break;
    const res = applyInput(s, input, info);
    s = res.state;
    out.inputs.push(input);
    out.states.push(s);
    out.events.push(res.events);
  }
  return out;
}

/** 불변식: 카드 수 보존, iid 중복 없음, 카드 표와 구역이 일치 */
export function checkInvariants(s: GameState, expected: [number, number]) {
  for (const seat of [0, 1] as Seat[]) {
    const n = countCards(s, seat);
    if (n !== expected[seat]) throw new Error(`플레이어 ${seat + 1} 카드 수 ${n} (기대 ${expected[seat]})`);
  }
  const seen = new Set<string>();
  const add = (iid: string | null) => {
    if (!iid) return;
    if (seen.has(iid)) throw new Error(`iid 중복 ${iid}`);
    if (!s.cards[iid]) throw new Error(`카드 표에 없는 iid ${iid}`);
    seen.add(iid);
  };
  for (const p of s.players) {
    [...p.deck, ...p.hand, ...p.prizes, ...p.discard, ...p.lost].forEach(add);
    for (const slot of [p.active, ...p.bench]) if (slot) [...slot.stack, ...slot.attached].forEach(add);
  }
  if (s.stadium) add(s.stadium);
  s.using.forEach(add);
  if (seen.size !== Object.keys(s.cards).length) throw new Error(`카드 표 ${Object.keys(s.cards).length}장, 구역 ${seen.size}장`);
}

/** viewer 가 볼 수 없는 카드(iid) 목록 */
export function hiddenFrom(s: GameState, viewer: Viewer): string[] {
  const out: string[] = [];
  // 내 선택 요청에 보이는 카드 (덱 서치 등)는 나에게 공개된 것
  const shown = new Set(s.requests.filter((r) => r.player === viewer).flatMap((r) => (r.cards ?? []).map((c) => c.iid)));
  for (const seat of [0, 1] as Seat[]) {
    const p = s.players[seat];
    out.push(...p.deck, ...(p.prizes.filter(Boolean) as string[]));
    if (viewer !== seat) {
      out.push(...p.hand);
      for (const slot of [p.active, ...p.bench]) if (slot && slot.faceDown) out.push(...slot.stack, ...slot.attached);
    }
  }
  return out.filter((i) => !shown.has(i));
}

/**
 * 누출 검사 (차등): viewer 가 볼 수 없는 카드들의 코드를 서로 뒤섞어도 viewer 의 보기가 바뀌면 안 된다.
 * 보기가 바뀐다면, 보기 안에 숨겨진 카드의 정보가 들어 있다는 뜻.
 */
export function checkNoLeak(s: GameState, viewer: Viewer, r: RngState) {
  const before = JSON.stringify(viewFor(s, viewer, info));
  const hidden = hiddenFrom(s, viewer);
  if (hidden.length < 2) return;
  const t = structuredClone(s);
  const codes = hidden.map((iid) => t.cards[iid].code);
  for (let i = codes.length - 1; i > 0; i--) { const j = randInt(r, i + 1); [codes[i], codes[j]] = [codes[j], codes[i]]; }
  hidden.forEach((iid, i) => { t.cards[iid] = { ...t.cards[iid], code: codes[i] }; });
  const after = JSON.stringify(viewFor(t, viewer, info));
  if (before !== after) throw new Error(`누출: viewer=${viewer} 의 보기가 숨겨진 카드에 따라 달라짐 (version ${s.version})`);
}

/** 이벤트 누출 검사: 걸러진 이벤트에 카드가 있으면 출발/도착 중 한 곳은 viewer 에게 보여야 한다 */
export function checkEventsNoLeak(events: GameEvent[], viewer: Viewer) {
  for (const e of eventsFor(events, viewer)) {
    if (e.type !== 'move' || !e.card) continue;
    const vis = (z: { player: Seat; zone: string }, fd = false) =>
      z.zone === 'hand' ? viewer === z.player : (z.zone === 'deck' || z.zone === 'prizes') ? false
        : (z.zone === 'active' || z.zone === 'bench') ? (!fd || viewer === z.player) : true;
    if (!vis(e.to, e.faceDown) && !vis(e.from)) throw new Error(`이벤트 누출: viewer=${viewer} seq=${e.seq}`);
    if (!vis(e.to, e.faceDown) && e.card.iid !== '') throw new Error(`이벤트 누출(iid): viewer=${viewer} seq=${e.seq}`);
  }
}

export { applyInput, blockingRequests, createGame, GameError, viewFor, eventsFor };
