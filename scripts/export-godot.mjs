// 웹 프로젝트 데이터 → Godot 덱 뷰어 앱 데이터
//   godot/data/decks.json
//   godot/cards/full/<코드>.<ext>   (큰 이미지, 원본 복사)
//   godot/cards/thumb/<코드>.webp  (목록용 썸네일, 폭 256px)
// 이미지 우선순위는 웹과 동일: public/cards/ko/fixed/<코드>.png|.webp → public/cards/ko/<코드>.webp
// 기존 파일은 지우지 않는다(누적). 이미 있는 썸네일/이미지는 원본이 더 새로울 때만 다시 만든다.
// 사용: npm run export-godot
import { readFileSync, writeFileSync, existsSync, mkdirSync, copyFileSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { hashOf, dist } from './print-lib.mjs';
import { buildCatalog } from '../src/game/catalog.ts';

const ROOT = new URL('../', import.meta.url);
const P = (p) => new URL(p, ROOT);
// 앱에 넣을 덱 (코리안리그 시즌 순: 마스터 → 시니어)
const APP_DECKS = ['flareon', 'dragapult', 'charizard', 'gholdengo', 'gardevoir', 'pachirisu'];
const COVER = {
  flareon: 'SV8a_202', dragapult: 'SV6_120', charizard: 'SV4a_349',
  gholdengo: 'SV3a_050', gardevoir: 'SV1S_028', pachirisu: 'SV7_032',
};
// 한글판 코드를 모르는 카드의 종류 (이름 → 종류)
const UNKNOWN_KIND = { '태권왕의 수련': 'trainer', '머리띠 (139/175)': 'trainer' };
const THUMB_W = 256;
const KIND_ORDER = { pokemon: 0, trainer: 1, energy: 2 };

const resolved = JSON.parse(readFileSync(P('src/data/resolved.json'), 'utf8'));
const kindsJson = JSON.parse(readFileSync(P('src/data/kinds.json'), 'utf8'));
const KIND = {};
for (const k of ['pokemon', 'trainer', 'energy']) for (const c of kindsJson[k]) KIND[c] = k;
const NAMES = Object.fromEntries(
  [...readFileSync(P('src/data/names.ts'), 'utf8').matchAll(/\b([A-Za-z0-9]+_\d{3}):\s*'([^']+)'/g)].map((m) => [m[1], m[2]]),
);
const GUIDES = existsSync(P('src/data/deck_guides.json')) ? JSON.parse(readFileSync(P('src/data/deck_guides.json'), 'utf8')) : { guides: {} };
// 같은 카드의 다른 인쇄(레귤레이션별) — scripts/find-prints.mjs 결과
const PRINTS = existsSync(P('src/data/prints.json')) ? JSON.parse(readFileSync(P('src/data/prints.json'), 'utf8')).prints ?? {} : {};
const BASICS = new Set([...readFileSync(P('src/data/basics.ts'), 'utf8').matchAll(/'([A-Za-z0-9]+_\d{3})'/g)].map((m) => m[1]));

for (const d of ['godot/data', 'godot/cards/full', 'godot/cards/thumb']) mkdirSync(P(d), { recursive: true });

// --force=CODE1,CODE2 : 해당 카드는 시간과 상관없이 다시 만든다 (--force 만 주면 전부)
const forceArg = process.argv.find((a) => a.startsWith('--force'));
const FORCE_ALL = forceArg === '--force';
const FORCE = new Set(forceArg && !FORCE_ALL ? forceArg.split('=')[1].split(',') : []);
let currentCode = '';
const newer = (src, dst) => FORCE_ALL || FORCE.has(currentCode) || !existsSync(dst) || statSync(src).mtimeMs > statSync(dst).mtimeMs;

// 한글판 이미지가 없는 카드용 대체 이미지 (카드 모양 + 이름)
async function placeholder(code, name) {
  const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const svg = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="868" height="1212">
    <rect x="8" y="8" width="852" height="1196" rx="44" fill="#e9ecef" stroke="#9aa3ad" stroke-width="16"/>
    <rect x="70" y="210" width="728" height="520" rx="18" fill="#cfd5db"/>
    <text x="434" y="140" font-size="72" font-family="Malgun Gothic, Noto Sans KR, sans-serif" font-weight="700" text-anchor="middle" fill="#333">${esc(name)}</text>
    <text x="434" y="490" font-size="54" font-family="Malgun Gothic, Noto Sans KR, sans-serif" text-anchor="middle" fill="#6b7580">이미지 준비 중</text>
    <text x="434" y="880" font-size="40" font-family="Malgun Gothic, Noto Sans KR, sans-serif" text-anchor="middle" fill="#8a939c">한글판 코드 미확인</text>
  </svg>`);
  const fullDst = P(`godot/cards/full/${code}.webp`);
  const thumbDst = P(`godot/cards/thumb/${code}.webp`);
  await sharp(svg).webp({ quality: 90 }).toFile(fileURLToPath(fullDst));
  await sharp(svg).resize({ width: THUMB_W }).webp({ quality: 88 }).toFile(fileURLToPath(thumbDst));
  return { full: `res://cards/full/${code}.webp`, thumb: `res://cards/thumb/${code}.webp` };
}

const badFiles = [];
async function readable(url) {
  try { await sharp(fileURLToPath(url)).metadata(); await sharp(fileURLToPath(url)).raw().toBuffer(); return true; }
  catch { return false; }
}
// 우선순위대로 찾되, 읽을 수 없는(깨진) 파일은 건너뛰고 다음 후보를 쓴다
async function sourceImage(code) {
  for (const p of [`public/cards/ko/fixed/${code}.png`, `public/cards/ko/fixed/${code}.webp`, `public/cards/ko/${code}.webp`]) {
    if (!existsSync(P(p))) continue;
    if (await readable(P(p))) return P(p);
    badFiles.push(p);
  }
  return null;
}

// 큰 이미지(webp) + 썸네일을 만들고 res:// 경로를 돌려준다 (원본이 없으면 null)
const exported = new Map();
async function exportImage(code) {
  if (exported.has(code)) return exported.get(code);
  currentCode = code;
  const src = await sourceImage(code);
  let res = null;
  if (src) {
    // 큰 이미지는 앱 용량을 줄이려고 항상 webp 로 저장 (원본이 webp 면 그대로 복사)
    const fullDst = P(`godot/cards/full/${code}.webp`);
    if (newer(src, fullDst)) {
      if (src.pathname.endsWith('.webp')) copyFileSync(src, fullDst);
      else await sharp(fileURLToPath(src)).webp({ quality: 92 }).toFile(fileURLToPath(fullDst));
      copied++;
    }
    const thumbDst = P(`godot/cards/thumb/${code}.webp`);
    if (newer(src, thumbDst)) { await sharp(fileURLToPath(src)).resize({ width: THUMB_W }).webp({ quality: 88 }).toFile(fileURLToPath(thumbDst)); thumbs++; }
    res = { full: `res://cards/full/${code}.webp`, thumb: `res://cards/thumb/${code}.webp` };
  }
  exported.set(code, res);
  return res;
}
let printCount = 0, sameArt = 0;

// 그림이 같은 인쇄(세트 번호·마크만 다른 재판)는 하나만 남긴다. 이미지 파일은 지우지 않고 목록에서만 뺀다.
// 남기는 순서: 덱에 원래 들어간 인쇄 → 최근 레귤레이션 → 일반 레어도 → prints.json 순서
const SAME_ART = 30;   // 그림 해시 차이 이 이하이면 같은 그림 (같은 그림 0~25, 다른 그림 40 이상)
const REG_RANK = { G: 1, H: 2, I: 3 };
async function distinctPrints(deckCode, list) {
  const hs = await Promise.all(list.map((p) => { const [s, n] = p.code.split('_'); return hashOf('ko', s, +n); }));
  const order = list.map((p, i) => i).sort((a, b) =>
    (list[b].code === deckCode) - (list[a].code === deckCode)
    || (REG_RANK[list[b].reg] ?? 0) - (REG_RANK[list[a].reg] ?? 0)
    || list[a].special - list[b].special || a - b);
  const kept = [];
  for (const i of order) {
    if (hs[i] && kept.some((k) => hs[k] && dist(hs[i], hs[k]) <= SAME_ART)) { sameArt++; continue; }
    kept.push(i);
  }
  return kept.sort((a, b) => a - b).map((i) => list[i]);
}

const problems = [];   // 고쳐야 하는 문제 (종료 코드 1)
const warnings = [];   // 알려만 주는 것
const out = { version: 1, generated: new Date().toISOString(), decks: [] };
let copied = 0, thumbs = 0;

for (const deckId of APP_DECKS) {
  const d = resolved.decks.find((x) => x.id === deckId);
  if (!d) { problems.push(`덱 없음: ${deckId}`); continue; }
  const merged = new Map();
  const unknowns = [];
  d.cards.forEach((c, i) => {
    const code = resolved.cards[c.ref]?.ko;
    if (!code) { unknowns.push({ name: c.nameEn, count: c.count, order: i }); return; }
    const prev = merged.get(code);
    if (prev) prev.count += c.count;
    else merged.set(code, { code, count: c.count, order: i });
  });

  const cards = [];
  // 코드 미확인 카드: 대체 이미지로 표시 (덱 장수는 그대로 유지)
  for (const [n, u] of unknowns.entries()) {
    const code = `UNK_${deckId}_${n + 1}`;
    const img = await placeholder(code, u.name);
    warnings.push(`${deckId}: 한글판 미확인 ${u.name} (대체 이미지로 표시)`);
    cards.push({ code, name: u.name, count: u.count, kind: UNKNOWN_KIND[u.name] ?? 'trainer', basic: false, ...img, unresolved: true, _order: u.order });
  }
  for (const { code, count, order } of merged.values()) {
    const kind = KIND[code];
    if (!kind) problems.push(`${deckId}: 종류 미지정 ${code} (src/data/kinds.json)`);
    if (!NAMES[code]) problems.push(`${deckId}: 이름 미지정 ${code} (src/data/names.ts)`);
    const img = await exportImage(code);
    if (!img) problems.push(`${deckId}: 이미지 없음 ${code}`);
    const card = { id: code, code, name: NAMES[code] ?? code, count, kind: kind ?? 'trainer', basic: BASICS.has(code), full: img?.full ?? null, thumb: img?.thumb ?? null, _order: order };
    // 다른 인쇄: 이미지가 있는 것만 (덱 카드 자신 포함)
    if (PRINTS[code]) {
      const prints = [];
      for (const p of await distinctPrints(code, PRINTS[code])) {
        const pi = p.code === code ? img : await exportImage(p.code);
        if (pi) prints.push({ code: p.code, reg: p.reg ?? '', special: !!p.special, ...pi });
        else warnings.push(`${deckId}: 다른 인쇄 이미지 없음 ${p.code} (${card.name})`);
      }
      if (prints.length > 1) { card.prints = prints; printCount += prints.length - 1; }
    }
    cards.push(card);
  }
  cards.sort((a, b) => KIND_ORDER[a.kind] - KIND_ORDER[b.kind] || a._order - b._order);
  cards.forEach((c) => delete c._order);

  const total = cards.reduce((a, c) => a + c.count, 0);
  if (total !== 60) problems.push(`${deckId}: 총 ${total}장 (60장 아님)`);

  // 덱 설명: 핵심 카드에 이름을 붙이고, 덱에 없는 카드는 경고
  let guide = null;
  const gsrc = GUIDES.guides?.[deckId];
  if (gsrc) {
    const inDeck = new Set(cards.map((c) => c.code));
    for (const k of gsrc.keyCards ?? []) if (!inDeck.has(k.code)) problems.push(`${deckId}: 덱 설명의 핵심 카드 ${k.code} 가 덱에 없음`);
    guide = {
      ...gsrc,
      keyCards: (gsrc.keyCards ?? []).map((k) => ({ ...k, name: NAMES[k.code] ?? k.code })),
      matchups: (gsrc.matchups ?? []).map((m) => ({
        ...m,
        vsName: resolved.decks.find((x) => x.id === m.vs)?.name ?? m.vs,
        ratingLabel: GUIDES.ratingLabels?.[m.rating] ?? m.rating,
      })),
    };
  } else warnings.push(`${deckId}: 덱 설명 없음`);

  out.decks.push({
    guide,
    id: deckId,
    name: d.name,
    note: d.note ?? '',
    cover: COVER[deckId] ?? cards[0]?.code,
    total,
    counts: Object.fromEntries(['pokemon', 'trainer', 'energy'].map((k) => [k, cards.filter((c) => c.kind === k).reduce((a, c) => a + c.count, 0)])),
    cards,
  });
}

// 앱·서버 카드 데이터 버전 (서버와 같은 계산: src/game/catalog.ts) — 앱이 접속할 때 보내 비교한다
out.dataVersion = buildCatalog(out).dataVersion;
writeFileSync(P('godot/data/decks.json'), JSON.stringify(out, null, 2));
// 오프라인 AI 연습: 앱 안의 규칙 엔진(godot/scripts/engine)이 쓰는 카드 규칙 데이터
copyFileSync(P('src/data/rules/cards.json'), P('godot/data/rules.json'));
for (const dk of out.decks) console.log(`${dk.id}: ${dk.cards.length}종 ${dk.total}장 (포켓몬 ${dk.counts.pokemon} / 트레이너스 ${dk.counts.trainer} / 에너지 ${dk.counts.energy})`);
console.log(`큰 이미지 복사 ${copied}장, 썸네일 생성 ${thumbs}장, 다른 인쇄 ${printCount}개 (같은 그림이라 뺀 인쇄 ${sameArt}개)`);
if (badFiles.length) console.log('읽을 수 없는 이미지(건너뛰고 다음 후보 사용):\n  ' + [...new Set(badFiles)].join('\n  '));
if (warnings.length) console.log('참고:\n  ' + warnings.join('\n  '));
if (problems.length) { console.log('확인 필요:\n  ' + problems.join('\n  ')); process.exitCode = 1; }
