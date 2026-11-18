// decklists.txt 의 카드마다 한글판 코드를 찾아 검증하고 이미지를 받는다.
//  1) Limitless 카드 페이지에서 일본판 인쇄 목록(세트/번호)을 얻는다
//  2) 같은 세트/번호의 한글 공식 이미지가 있는지 확인
//  3) 한글 이미지와 일본판 이미지의 그림 영역 해시를 비교해 같은 카드인지 검증
//     (일본판 이미지는 검증용으로만 쓰고 저장하지 않는다)
//  4) 검증된 한글 이미지를 public/cards/ko/<코드>.webp 로 저장, 결과를 src/data/resolved.json 에 기록
// 사용: npm run resolve-ko
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import sharp from 'sharp';
import { koUrl, seriesOf, KO_DIR, ensureDirs, sleep } from './ko-source.mjs';

const LIMITLESS = 'https://limitlesstcg.com';
const JP_IMG = (s, n) => `https://limitlesstcg.nyc3.cdn.digitaloceanspaces.com/tpc/${s}/${s}_${n}_R_JP_SM.png`;
const OUT = new URL('../src/data/resolved.json', import.meta.url);
const THRESHOLD = 60; // 256비트 중 허용 차이

// ── 덱 리스트 파싱 ──
const decks = [];
const manual = {};
const unknownRefs = new Set();
for (const raw of readFileSync(new URL('./decklists.txt', import.meta.url), 'utf8').split(/\r?\n/)) {
  const line = raw.trim();
  if (!line || (line.startsWith('#') && !line.startsWith('##'))) continue;
  if (line.startsWith('##')) {
    const [id, name, note] = line.slice(2).split('|').map((s) => s.trim());
    decks.push({ id, name, note, cards: [] });
    continue;
  }
  // 형식: <매수> <영문명> <세트> <번호> [ko=<한글판 코드>]   (ko= 를 주면 자동 탐색 대신 그 코드를 사용)
  //       <매수> <이름> ko=<한글판 코드>                (영문 참조 없이 한글판 코드만)
  //       <매수> <이름> ko=?                            (한글판 코드 미확인 — 이름만 표시)
  const u = /^(\d+)\s+(.+?)\s+ko=\?$/.exec(line);
  if (u) {
    decks.at(-1).cards.push({ count: +u[1], nameEn: u[2], ref: `name:${u[2]}` });
    unknownRefs.add(`name:${u[2]}`);
    continue;
  }
  const k = /^(\d+)\s+(.+?)\s+ko=([A-Za-z0-9]+_\d{3})$/.exec(line);
  if (k && !/\s[A-Z0-9]{2,4}\s+\d+$/.test(k[2])) {
    const ref = `ko:${k[3]}`;
    decks.at(-1).cards.push({ count: +k[1], nameEn: k[2], ref });
    manual[ref] = k[3];
    continue;
  }
  const m = /^(\d+)\s+(.+?)\s+([A-Z0-9]{2,4})\s+(\d+)(?:\s+ko=([A-Za-z0-9]+_\d{3}))?$/.exec(line);
  if (!m) { console.warn('해석 불가:', line); continue; }
  const ref = `${m[3]}-${m[4]}`;
  decks.at(-1).cards.push({ count: +m[1], nameEn: m[2], ref });
  if (m[5]) manual[ref] = m[5];
}

// ── 이미지 해시 (그림 영역 dHash 16x16) ──
async function artHash(buf) {
  const img = sharp(buf);
  const { width, height } = await img.metadata();
  const region = { left: Math.round(width * 0.1), top: Math.round(height * 0.12), width: Math.round(width * 0.8), height: Math.round(height * 0.36) };
  const px = await sharp(buf).extract(region).grayscale().resize(17, 16, { fit: 'fill' }).raw().toBuffer();
  const bits = [];
  for (let y = 0; y < 16; y++) for (let x = 0; x < 16; x++) bits.push(px[y * 17 + x] > px[y * 17 + x + 1] ? 1 : 0);
  return bits;
}
const dist = (a, b) => a.reduce((d, v, i) => d + (v !== b[i]), 0);

async function get(url) {
  const res = await fetch(url);
  if (!res.ok) return null;
  return Buffer.from(await res.arrayBuffer());
}

// ── 일본판 인쇄 후보 ──
async function jpPrints(ref) {
  const [set, num] = ref.split('-');
  const html = await (await fetch(`${LIMITLESS}/cards/${set}/${num}`)).text();
  const prints = [...new Set([...html.matchAll(/href="\/cards\/jp\/([A-Za-z0-9-]+)\/(\d+)"/g)].map((m) => `${m[1]}|${m[2]}`))]
    .map((s) => { const [s1, n] = s.split('|'); return { set: s1, num: +n }; });
  // 정규 확장팩 우선, 프로모/스타터/MC 는 뒤로
  const rank = (p) => (/P$|-P$/.test(p.set) ? 3 : /^(MC|MA|MB|SVK|SVL|SVN|SVO|SVM|SVG)/.test(p.set) ? 2 : 0);
  return prints.sort((a, b) => rank(a) - rank(b));
}

await ensureDirs();
const prev = existsSync(OUT) ? JSON.parse(readFileSync(OUT, 'utf8')).cards ?? {} : {};
const cards = {};
const refs = [...new Set(decks.flatMap((d) => d.cards.map((c) => c.ref)))];

for (const ref of refs) {
  const nameEn = decks.flatMap((d) => d.cards).find((c) => c.ref === ref).nameEn;
  if (unknownRefs.has(ref)) {
    cards[ref] = { nameEn, ko: null, score: null, tried: ['unknown'] };
    console.log('UNKNOWN', ref);
    continue;
  }
  if (manual[ref]) {
    const code = manual[ref];
    const ko = existsSync(new URL(`${code}.webp`, KO_DIR)) ? true : await get(koUrl(code));
    if (ko && ko !== true) await writeFile(new URL(`${code}.webp`, KO_DIR), ko);
    cards[ref] = { nameEn, ko: ko ? code : null, score: null, tried: ['manual'] };
    console.log(ko ? 'manual ' : 'FAIL   ', ref, '→', code);
    continue;
  }
  if (prev[ref]?.ko && prev[ref].tried?.[0] !== 'manual') { cards[ref] = prev[ref]; console.log('cached ', ref, '→', prev[ref].ko); continue; }

  let best = null;
  const tried = [];
  for (const p of await jpPrints(ref)) {
    try { seriesOf(p.set); } catch { continue; }
    const code = `${p.set}_${String(p.num).padStart(3, '0')}`;
    const ko = await get(koUrl(code));
    await sleep(250);
    if (!ko) { tried.push(`${code}:없음`); continue; }
    const jp = await get(JP_IMG(p.set, p.num));
    if (!jp) { tried.push(`${code}:jp없음`); continue; }
    const d = dist(await artHash(ko), await artHash(jp));
    tried.push(`${code}:${d}`);
    if (d <= THRESHOLD && (!best || d < best.d)) { best = { code, d, buf: ko }; if (d < 25) break; }
  }
  if (best) await writeFile(new URL(`${best.code}.webp`, KO_DIR), best.buf);
  cards[ref] = { nameEn, ko: best?.code ?? null, score: best?.d ?? null, tried };
  console.log(best ? 'ok     ' : 'FAIL   ', ref.padEnd(8), nameEn.padEnd(28), best ? `→ ${best.code} (차이 ${best.d})` : '', '|', tried.slice(0, 6).join(' '));
}

writeFileSync(OUT, JSON.stringify({ decks, cards }, null, 2));
const fails = Object.entries(cards).filter(([, c]) => !c.ko);
console.log(`\n${refs.length}종 중 ${refs.length - fails.length}종 확인, 실패 ${fails.length}종`);
for (const [r, c] of fails) console.log('  -', r, c.nameEn);
