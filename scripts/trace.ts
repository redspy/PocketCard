// 한 판 추적: AI 대 AI 한 판을 진행하며 행동과 주요 사건을 출력 (AI·규칙 문제 찾기용)
// 사용: node scripts/trace.ts <시드 번호> <덱1> <덱2> [최대 턴]
import { readFileSync } from 'node:fs';
import { buildCatalog, buildDeck, cardInfo } from '../src/game/catalog.ts';
import type { RawDecks } from '../src/game/catalog.ts';
import { makeAiBot } from '../src/game/bot.ts';
import { legalMoves } from '../src/game/engine.ts';
import { Match } from '../src/game/match.ts';
import { seedRng } from '../src/game/rng.ts';
import type { GameEvent, Seat } from '../src/game/types.ts';
import { viewFor } from '../src/game/view.ts';

const ROOT = new URL('../', import.meta.url);
const catalog = buildCatalog(JSON.parse(readFileSync(new URL('godot/data/decks.json', ROOT), 'utf8')) as RawDecks);
const info = cardInfo(catalog, JSON.parse(readFileSync(new URL('src/data/rules/cards.json', ROOT), 'utf8')));
const [seedArg = '1', d1 = 'dragapult', d2 = 'gardevoir', maxTurn = '99'] = process.argv.slice(2);
const seed = Number(seedArg).toString(16).padStart(32, '0');
const m = new Match({ seed, players: [{ deckId: d1, cards: buildDeck(catalog, d1) }, { deckId: d2, cards: buildDeck(catalog, d2) }] }, info);
const ai = makeAiBot(catalog, info.db);
const rng = seedRng(seed.split('').reverse().join(''));
const name = (code: string) => { for (const d of catalog.decks) for (const c of d.cards) if (c.code === code || c.prints.includes(code)) return c.name; return code; };
const ev = (e: GameEvent) => {
  switch (e.type) {
    case 'attack': return `  ⚔ ${name(e.code)} [${e.name}]`;
    case 'damage': return `  ✸ ${e.counters ? '카운터' : '데미지'} ${e.amount} → P${e.player + 1}`;
    case 'ko': return `  ☠ P${e.player + 1} ${name(e.code)} 기절 (사이드 ${e.prizes})`;
    case 'note': return `  · ${e.text}`;
    case 'gameEnd': return `  ★ 종료: ${e.result.reason}`;
    default: return null;
  }
};
for (let i = 0; i < 3000 && m.state.phase !== 'ended' && m.state.turnNumber <= Number(maxTurn); i++) {
  const s = m.state;
  const req = s.requests.find((r) => r.kind !== 'ackReveal') ?? s.requests[0];
  const seat: Seat = req ? req.player : (s.turnPlayer ?? 0);
  const view = JSON.parse(JSON.stringify(viewFor(s, seat, info)));
  const input = ai(view, rng);
  if (!input) { console.log('할 일 없음'); break; }
  let label = '';
  if (input.type === 'choice') label = `선택 ${req?.kind}: ${req?.prompt.slice(0, 30)} → ${input.picks.map((p) => req?.labels?.[p] ?? (req?.cards?.find((c) => c.iid === p) ? name(req.cards.find((c) => c.iid === p)!.code) : p)).join(', ')}`;
  else label = legalMoves(s, seat, info).find((mv) => JSON.stringify({ ...mv.input, player: undefined }) === JSON.stringify({ ...input, player: undefined }))?.label ?? JSON.stringify(input);
  if (input.type === 'endTurn') {
    const p = s.players[seat];
    const act = p.active;
    const actName = act ? name(s.cards[act.stack[act.stack.length - 1]].code) : '-';
    const en = act ? act.attached.map((a) => name(s.cards[a].code)).join('+') : '';
    if (process.env.TRACE_MOVES) console.log('   가능:', legalMoves(s, seat, info).map((mv) => mv.label).join(' | '));
    console.log(`T${s.turnNumber} P${seat + 1} 턴 종료 — 배틀 ${actName} [${en}] 패 ${p.hand.length} 덱 ${p.deck.length} 사이드 ${p.prizes.filter(Boolean).length} | 패: ${p.hand.map((h) => name(s.cards[h].code)).join(', ')}`);
  } else console.log(`T${s.turnNumber} P${seat + 1} ${label}`);
  const r = m.submit(seat, input);
  if (!r.ok) { console.log('거절:', r.error); break; }
  for (const e of r.events) { const t = ev(e); if (t) console.log(t); }
}
