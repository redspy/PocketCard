// 카드 규칙 데이터 만들기: survey.json(TCGdex 일본어 데이터) + overrides.json(수동 보정) → src/data/rules/cards.json
// 결과는 저장소에 고정해 두고 엔진·서버·데모가 쓴다. (빌드 때마다 인터넷에서 받지 않음)
// 사용: npm run card-rules   (먼저 npm run card-survey 로 survey.json 을 만든다)
import { readFileSync, writeFileSync } from 'node:fs';

const P = (p) => new URL(`../${p}`, import.meta.url);
const survey = JSON.parse(readFileSync(P('src/data/rules/survey.json'), 'utf8')).cards;
const ov = JSON.parse(readFileSync(P('src/data/rules/overrides.json'), 'utf8'));
const decks = JSON.parse(readFileSync(P('godot/data/decks.json'), 'utf8')).decks;

const T = { Grass: 'G', Fire: 'R', Water: 'W', Lightning: 'L', Psychic: 'P', Fighting: 'F', Darkness: 'D', Metal: 'M', Dragon: 'N', Colorless: 'C', Fairy: 'P' };
const ENERGY_KO = { 풀: 'G', 불꽃: 'R', 물: 'W', 번개: 'L', 초: 'P', 격투: 'F', 악: 'D', 강철: 'M' };
const TRAINER = { Item: 'item', Tool: 'tool', Supporter: 'supporter', Stadium: 'stadium' };
const STAGE = { Basic: 0, Stage1: 1, Stage2: 2 };

const problems = [];
const out = {};

// 덱에 있는 모든 카드 (덱 데이터 기준)
const deckCards = new Map();
for (const d of decks) for (const c of d.cards) if (!deckCards.has(c.id)) deckCards.set(c.id, c);

for (const [id, dc] of deckCards) {
  const s = survey.find((x) => x.code === id);
  const r = s?.rules;
  const name = dc.name;
  const o = { ...(ov.byName[name] ?? {}), ...(ov.byCode[id] ?? {}) };
  const card = { id, name: o.name ?? name, kind: o.kind ?? dc.kind, text: '' };

  if (card.kind === 'energy') {
    const m = /^기본 (.+) 에너지$/.exec(name);
    card.energy = { basic: !!m, type: m ? ENERGY_KO[m[1]] ?? null : null };
    card.text = o.text ?? r?.effect ?? '';
    if (m && !card.energy.type) problems.push(`${id} ${name}: 에너지 타입 모름`);
  } else if (card.kind === 'trainer') {
    card.trainer = o.trainer ?? TRAINER[r?.trainerType] ?? null;
    if (!card.trainer) problems.push(`${id} ${name}: 트레이너스 종류 모름`);
    card.text = o.text ?? r?.effect ?? '';
  } else {
    const p = {
      stage: o.stage ?? STAGE[r?.stage] ?? 0,
      from: o.from ?? null,
      hp: o.hp ?? Number(r?.hp ?? 0),
      type: o.type ?? T[r?.types?.[0]] ?? 'C',
      weak: o.weak !== undefined ? o.weak : (T[r?.weaknesses?.[0]?.type] ?? null),
      resist: o.resist !== undefined ? o.resist : (T[r?.resistances?.[0]?.type] ?? null),
      retreat: o.retreat ?? Number(r?.retreat ?? 0),
      rule: o.rule !== undefined ? o.rule : (r?.suffix === 'EX' ? 'ex' : null),
      ...(o.radiant ? { radiant: true } : {}),
      ...(o.resistValue ? { resistValue: o.resistValue } : {}),
      tera: !!o.tera,
      future: !!o.future,
      attacks: (o.attacks ?? r?.attacks ?? []).map((a, i) => {
        const dm = /^(\d+)\s*([+×x\-]?)$/.exec(String(a.damage ?? '').trim());
        return {
          name: ov.jaKo?.[a.nameJa ?? a.name] ?? (a.name && /[가-힣]/.test(a.name) ? a.name : ''),
          nameJa: a.nameJa ?? a.name ?? '',
          cost: (a.cost ?? []).map((c) => (c.length === 1 ? c : T[c] ?? 'C')),
          damage: dm ? Number(dm[1]) : 0,
          op: dm ? (dm[2] === 'x' ? '×' : dm[2] || '') : (a.op ?? ''),
          text: o[`attackText${i}`] ?? a.effect ?? a.text ?? '',
          ...(a.kind ? { kind: a.kind } : {}),
        };
      }),
      abilities: (o.abilities ?? r?.abilities ?? []).map((a) => ({ name: ov.jaKo?.[a.nameJa ?? a.name] ?? (a.name && /[가-힣]/.test(a.name) ? a.name : ''), nameJa: a.nameJa ?? a.name ?? '', text: o.abilityText ?? a.effect ?? a.text ?? '' })),
    };
    if (p.stage > 0 && !p.from) problems.push(`${id} ${name}: 진화 전 포켓몬 모름`);
    if (!p.hp) problems.push(`${id} ${name}: HP 없음`);
    for (const a of [...p.attacks, ...p.abilities]) if (!a.name) problems.push(`${id} ${name}: 한글 이름 없음 (${a.nameJa})`);
    card.pokemon = p;
  }
  if (o.ace) card.ace = true;
  if (o.tags?.length) card.tags = o.tags;
  if (!r && !ov.byCode[id] && !(card.kind === 'energy' && card.energy.basic)) problems.push(`${id} ${name}: 원본 데이터 없음`);
  out[id] = card;
}

// 진화 연결 검사: from 이름의 포켓몬이 같은 덱에 있어야 한다 (이브이 ex 의 특성 진화는 예외 처리)
for (const d of decks) {
  const names = new Set(d.cards.map((c) => out[c.id].name));
  for (const c of d.cards) {
    const p = out[c.id].pokemon;
    if (p?.from && !names.has(p.from) && !(p.from === '이브이' && names.has('이브이 ex'))) problems.push(`${d.id}: ${out[c.id].name} 의 진화 전 ${p.from} 이(가) 덱에 없음`);
  }
}

writeFileSync(P('src/data/rules/cards.json'), JSON.stringify({ version: 1, generated: new Date().toISOString(), cards: out }, null, 1) + '\n');
console.log(`카드 규칙 ${Object.keys(out).length}종 → src/data/rules/cards.json`);
if (problems.length) { console.log('확인 필요:\n  ' + problems.join('\n  ')); process.exitCode = 1; }
