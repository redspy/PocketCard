// 앱 덱 6종의 카드 규칙 데이터 조사
//  한글 코드 → 일본판 카드(그림 대응) → TCGdex(ja) 카드 데이터(HP, 타입, 기술, 특성, 트레이너스 문구 등)
// 결과: src/data/rules/survey.json (원본 데이터 + 덱별 장수), 콘솔에 요약
// 사용: node scripts/card-rules-survey.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { P, APP_DECKS, fetchJson, jpOf } from './print-lib.mjs';

const resolved = JSON.parse(readFileSync(P('src/data/resolved.json'), 'utf8'));
const NAMES = Object.fromEntries([...readFileSync(P('src/data/names.ts'), 'utf8').matchAll(/\b([A-Za-z0-9]+_\d{3}):\s*'([^']+)'/g)].map((m) => [m[1], m[2]]));
const kinds = JSON.parse(readFileSync(P('src/data/kinds.json'), 'utf8'));
const KIND = {};
for (const k of ['pokemon', 'trainer', 'energy']) for (const c of kinds[k]) KIND[c] = k;

const cards = new Map(); // code -> {name, kind, decks:{deck:count}}
for (const d of resolved.decks.filter((x) => APP_DECKS.includes(x.id))) {
  for (const c of d.cards) {
    const code = resolved.cards[c.ref]?.ko;
    if (!code) continue;
    if (!cards.has(code)) cards.set(code, { code, name: NAMES[code] ?? c.nameEn, kind: KIND[code], decks: {} });
    const e = cards.get(code);
    e.decks[d.id] = (e.decks[d.id] ?? 0) + c.count;
  }
}

const out = [];
const missing = [];
for (const e of cards.values()) {
  const jm = e.kind === 'energy' && /^기본/.test(e.name) ? null : await jpOf(e.code);
  let data = null;
  if (jm) {
    const id = `${jm.set}-${String(jm.num).padStart(3, '0')}`;
    const j = await fetchJson(`https://api.tcgdex.net/v2/ja/cards/${encodeURIComponent(id)}`);
    if (j) {
      data = {
        jp: id, name: j.name, category: j.category, stage: j.stage ?? null, hp: j.hp ?? null, types: j.types ?? null,
        evolveFrom: j.evolveFrom ?? null, suffix: j.suffix ?? null, regulationMark: j.regulationMark ?? null,
        abilities: (j.abilities ?? []).map((a) => ({ type: a.type, name: a.name, effect: a.effect })),
        attacks: (j.attacks ?? []).map((a) => ({ cost: a.cost ?? [], name: a.name, damage: a.damage ?? null, effect: a.effect ?? null })),
        weaknesses: j.weaknesses ?? null, resistances: j.resistances ?? null, retreat: j.retreat ?? null,
        trainerType: j.trainerType ?? null, energyType: j.energyType ?? null, effect: j.effect ?? null, rarity: j.rarity ?? null,
      };
    }
  }
  if (!data && !(e.kind === 'energy' && /^기본/.test(e.name))) missing.push(`${e.code} ${e.name}`);
  out.push({ ...e, rules: data });
}

mkdirSync(P('src/data/rules'), { recursive: true });
writeFileSync(P('src/data/rules/survey.json'), JSON.stringify({ generated: new Date().toISOString(), cards: out }, null, 2) + '\n');

// 사람이 읽는 요약 (조사용)
const lines = [];
for (const c of out) {
  const r = c.rules;
  const deckStr = Object.entries(c.decks).map(([d, n]) => `${d}×${n}`).join(',');
  if (!r) { lines.push(`## ${c.code} ${c.name} [${c.kind}] (${deckStr}) — 데이터 없음`); continue; }
  lines.push(`## ${c.code} ${c.name} [${r.category}${r.stage ? '/' + r.stage : ''}${r.trainerType ? '/' + r.trainerType : ''}${r.energyType ? '/' + r.energyType : ''}${r.suffix ? '/' + r.suffix : ''}] jp=${r.jp} (${deckStr})`);
  if (r.hp) lines.push(`HP${r.hp} ${r.types?.join('/') ?? ''} 진화전:${r.evolveFrom ?? '-'} 약점:${JSON.stringify(r.weaknesses)} 저항:${JSON.stringify(r.resistances)} 후퇴:${r.retreat}`);
  for (const a of r.abilities) lines.push(`  [특성] ${a.name}: ${a.effect}`);
  for (const a of r.attacks) lines.push(`  [기술] ${a.name} (${a.cost.join('')}) ${a.damage ?? ''}: ${a.effect ?? ''}`);
  if (r.effect) lines.push(`  [효과] ${r.effect}`);
}
writeFileSync(P('src/data/rules/survey.txt'), lines.join('\n') + '\n');
console.log(`카드 ${out.length}종, 데이터 없음 ${missing.length}종`);
if (missing.length) console.log('  ' + missing.join('\n  '));
