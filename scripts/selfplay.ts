// 자가 대전: 봇끼리 끝까지 여러 판 → 불변식·누출 검사, 결과 통계, 오류 재현 정보
// 사용: node scripts/selfplay.ts [판 수=60] [모드=ai|random|mixed] [시작 시드 번호=1] [--leak]
import { readFileSync } from 'node:fs';
import { buildCatalog, cardInfo } from '../src/game/catalog.ts';
import type { RawDecks } from '../src/game/catalog.ts';
import { makeAiBot, randomBot } from '../src/game/bot.ts';
import type { Bot } from '../src/game/bot.ts';
import { countCards, legalMoves } from '../src/game/engine.ts';
import { Match } from '../src/game/match.ts';
import { seedRng } from '../src/game/rng.ts';
import { buildDeck } from '../src/game/catalog.ts';
import type { GameState, Seat } from '../src/game/types.ts';
import { viewFor } from '../src/game/view.ts';

const ROOT = new URL('../', import.meta.url);
const catalog = buildCatalog(JSON.parse(readFileSync(new URL('godot/data/decks.json', ROOT), 'utf8')) as RawDecks);
const info = cardInfo(catalog, JSON.parse(readFileSync(new URL('src/data/rules/cards.json', ROOT), 'utf8')));
const args = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const N = Number(args[0] ?? 60);
const MODE = args[1] ?? 'ai';
const START = Number(args[2] ?? 1);
const LEAK = process.argv.includes('--leak');
const ai = makeAiBot(catalog, info.db);
const ids = catalog.decks.map((d) => d.id);

function checkInv(s: GameState) {
  for (const seat of [0, 1] as Seat[]) { const n = countCards(s, seat); if (n !== 60) throw new Error(`카드 수 ${n} (플레이어 ${seat + 1})`); }
  const seen = new Set<string>();
  const add = (i: string | null) => { if (!i) return; if (seen.has(i)) throw new Error(`iid 중복 ${i}`); seen.add(i); };
  for (const p of s.players) { [...p.deck, ...p.hand, ...p.prizes, ...p.discard].forEach(add); for (const sl of [p.active, ...p.bench]) if (sl) [...sl.stack, ...sl.attached].forEach(add); }
  if (s.stadium) add(s.stadium);
  s.using.forEach(add);
  if (seen.size !== Object.keys(s.cards).length) throw new Error('카드 표 불일치');
  for (const p of s.players) if (p.bench.length > p.benchMax && s.stack.length === 0 && !s.requests.length) throw new Error(`벤치 초과 ${p.bench.length}/${p.benchMax}`);
}

const evc: Record<string, number> = {};
const used = new Set<string>();
const nameByCode: Record<string, string> = {};
for (const d of catalog.decks) for (const c of d.cards) for (const p of c.prints) nameByCode[p] = c.name;
const stats = { games: 0, ended: 0, stuck: 0, errors: 0, reasons: {} as Record<string, number>, turns: [] as number[], inputs: [] as number[], wins: {} as Record<string, number> };
const errors: string[] = [];
const t0 = Date.now();
for (let g = 0; g < N; g++) {
  const seedNum = START + g;
  const seed = seedNum.toString(16).padStart(32, '0');
  const d1 = ids[g % ids.length], d2 = ids[Math.floor(g / ids.length) % ids.length];
  const m = new Match({ seed, players: [{ deckId: d1, cards: buildDeck(catalog, d1) }, { deckId: d2, cards: buildDeck(catalog, d2) }] }, info);
  const rng = seedRng(seed.split('').reverse().join(''));
  const bots: [Bot, Bot] = MODE === 'random' ? [randomBot, randomBot] : MODE === 'mixed' ? [ai, randomBot] : [ai, ai];
  stats.games++;
  let i = 0;
  try {
    for (; i < 4000 && m.state.phase !== 'ended'; i++) {
      const s = m.state;
      // 누가 행동해야 하나: 막는 요청의 주인 → 그 외 요청 → 차례인 플레이어
      const req = s.requests.find((r) => r.kind !== 'ackReveal') ?? s.requests[0];
      const seat: Seat = req ? req.player : (s.turnPlayer ?? 0);
      const view = JSON.parse(JSON.stringify(viewFor(s, seat, info)));
      const input = bots[seat](view, rng);
      if (!input) throw new Error(`봇이 할 일을 못 찾음 (플레이어 ${seat + 1}, 단계 ${s.phase})`);
      if (input.type === 'endTurn') {
        const lm = legalMoves(s, seat, info);
        const k = lm.some((x) => x.kind === 'attack') ? '공격 가능한데 안 함' : s.players[seat].turns === 1 && seat === s.firstPlayer ? '선공 첫 턴' : !s.players[seat].active ? '배틀 없음' : s.players[seat].active!.effects.some((e) => e.kind === 'noAttack') ? '기술 불가 효과' : '에너지 부족 등';
        evc[k] = (evc[k] ?? 0) + 1;
        if (k === '공격 가능한데 안 함' && !evc._shown) { evc._shown = 1; console.log('[예시] 시드', seedNum, d1, d2, '턴', s.turnNumber, 'P' + (seat + 1), lm.map((x) => x.label).join(' | ')); }
      }
      const r = m.submit(seat, input);
      if (!r.ok) throw new Error(`거절된 입력 ${JSON.stringify(input)}: ${r.error.code} ${r.error.message}`);
      for (const e of r.events) {
        evc[e.type] = (evc[e.type] ?? 0) + 1;
        if (e.type === 'attack' || e.type === 'ability') used.add(e.name);
        if (e.type === 'play') used.add(nameByCode[e.code] ?? e.code);
      }
      checkInv(m.state);
      if (LEAK && i % 7 === 0) for (const v of [0, 1, 'board'] as const) JSON.stringify(viewFor(m.state, v, info));
    }
    if (m.state.phase === 'ended') {
      stats.ended++;
      const reason = m.state.result!.reason.replace(/플레이어 \d/, '플레이어 x');
      if (m.state.result!.winner === null) console.log('[무승부] 시드', seedNum, d1, d2, '턴', m.state.turnNumber);
      stats.reasons[reason] = (stats.reasons[reason] ?? 0) + 1;
      const w = m.state.result!.winner;
      const key = w === null ? '무승부' : `${w === 0 ? d1 : d2}`;
      stats.wins[key] = (stats.wins[key] ?? 0) + 1;
      stats.turns.push(m.state.turnNumber);
      stats.inputs.push(i);
    } else { stats.stuck++; errors.push(`[끝나지 않음] 시드 ${seedNum} ${d1} vs ${d2} 턴 ${m.state.turnNumber}`); }
  } catch (e) {
    stats.errors++;
    errors.push(`[오류] 시드 ${seedNum} ${d1} vs ${d2} 입력 ${i}: ${(e as Error).message}\n    ${(e as Error).stack?.split('\n').slice(1, 4).join('\n    ')}`);
  }
}
const avg = (a: number[]) => (a.length ? (a.reduce((x, y) => x + y, 0) / a.length).toFixed(1) : '-');
console.log(`모드 ${MODE}: ${stats.games}판, 끝남 ${stats.ended}, 끝나지 않음 ${stats.stuck}, 오류 ${stats.errors} (${((Date.now() - t0) / 1000).toFixed(1)}초)`);
console.log(`평균 턴 ${avg(stats.turns)}, 평균 입력 ${avg(stats.inputs)}`);
console.log('끝난 이유:', JSON.stringify(stats.reasons));
console.log('승리 덱:', JSON.stringify(stats.wins));
console.log('턴 종료 이유:', JSON.stringify(Object.fromEntries(Object.entries(evc).filter(([k]) => /[가-힣]/.test(k)))));
console.log('사건 수:', JSON.stringify({ turns: stats.turns.reduce((a, b) => a + b, 0), attack: evc.attack, ko: evc.ko, play: evc.play, ability: evc.ability, note: evc.note }));
if (errors.length) console.log(errors.slice(0, 15).join('\n'));
process.exitCode = stats.errors || stats.stuck ? 1 : 0;

// 한 번도 쓰이지 않은 카드·기술·특성 (자가 대전 범위 확인)
const never: string[] = [];
for (const c of Object.values(info.db)) {
  if (c.kind === 'trainer' && !used.has(c.name)) never.push(`[트레이너스] ${c.name}`);
  if (c.kind === 'pokemon') {
    for (const a of c.pokemon!.attacks) if (!used.has(a.name)) never.push(`[기술] ${c.name} ${a.name}`);
    for (const a of c.pokemon!.abilities) if (!used.has(a.name) && !['스카이라인', '짓궂은 록', '다이아 코트', '페어리존', '복안', '날램', '노련한 기술', '노력 하트', '에이스 캔슬러', '부스트 진화', '무지갯빛DNA'].includes(a.name)) never.push(`[특성] ${c.name} ${a.name}`);
  }
}
console.log(`한 번도 쓰이지 않음 ${[...new Set(never)].length}개:`, [...new Set(never)].join(', '));