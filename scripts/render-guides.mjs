// src/data/deck_guides.json → docs/deck-guides.md (검토용 읽기 문서)
// 사용: npm run render-guides
import { readFileSync, writeFileSync } from 'node:fs';

const P = (p) => new URL(`../${p}`, import.meta.url);
const g = JSON.parse(readFileSync(P('src/data/deck_guides.json'), 'utf8'));
const resolved = JSON.parse(readFileSync(P('src/data/resolved.json'), 'utf8'));
const NAMES = Object.fromEntries([...readFileSync(P('src/data/names.ts'), 'utf8').matchAll(/\b([A-Za-z0-9]+_\d{3}):\s*'([^']+)'/g)].map((m) => [m[1], m[2]]));
const deckName = (id) => resolved.decks.find((d) => d.id === id)?.name ?? id;
const deckNote = (id) => (resolved.decks.find((d) => d.id === id)?.note ?? '').replace(/\s*\(.*\)$/, '');
const ORDER = ['flareon', 'dragapult', 'charizard', 'gholdengo', 'gardevoir', 'pachirisu'];

const out = ['# 덱 설명 (초안)', '', '> 카드 효과는 한글판 카드 기준, 운영·상성은 여러 자료를 바탕으로 정리한 참고용 설명입니다.', ''];
for (const id of ORDER) {
  const d = g.guides[id];
  if (!d) continue;
  out.push(`## ${deckName(id)}`, `*${deckNote(id)}*`, '', `**${d.summary}**`, '', d.concept, '');
  if (d.caution) out.push(`> ⚠ ${d.caution}`, '');
  out.push('### 핵심 카드');
  for (const c of d.keyCards) out.push(`- **${NAMES[c.code] ?? c.code}** (${c.role}) — ${c.text}`);
  out.push('', '### 게임 플랜');
  for (const p of d.plan) out.push(`- **${p.label}**: ${p.text}`);
  out.push('', '### 운영 팁');
  d.tips.forEach((t, i) => out.push(`${i + 1}. ${t}`));
  out.push('', '### 강점', ...d.strengths.map((s) => `- ${s}`), '', '### 약점', ...d.weaknesses.map((s) => `- ${s}`));
  out.push('', '### 상성 (참고용)', '| 상대 | 판정 | 이유 |', '|---|---|---|');
  for (const m of d.matchups) out.push(`| ${deckName(m.vs)} | ${g.ratingLabels[m.rating]} | ${m.text} |`);
  out.push('', '### 한국 리그 리스트의 특징', ...d.koreanList.map((s) => `- ${s}`));
  out.push('', '### 참고 자료', ...d.sources.map((s) => `- [${s.title}](${s.url})`), '', '---', '');
}
writeFileSync(P('docs/deck-guides.md'), out.join('\n'));
console.log('docs/deck-guides.md 생성');
