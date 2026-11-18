// 앱 덱의 각 카드에 대해 "같은 카드의 다른 인쇄"(G/H/I 레귤레이션) 한글판 코드를 모은다.
// 앱의 카드 크게 보기 화면 위쪽 썸네일 → 눌러서 덱의 인쇄를 바꾸는 기능에 쓰인다.
// 결과: src/data/prints.json  { prints: { 덱카드코드: [{code, reg, jp, special}] } }  (인쇄가 2종 이상인 카드만)
// 새로 찾은 인쇄의 한글 이미지는 public/cards/ko/ 에 내려받는다(기존 이미지는 지우지 않음).
// 사용: npm run find-prints
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { P, ALLOWED, RANK, APP_DECKS, jpInfo, reprints, isPromo, jpOf, koOf } from './print-lib.mjs';
import { koUrl, download, ensureDirs, KO_DIR } from './ko-source.mjs';

const resolved = JSON.parse(readFileSync(P('src/data/resolved.json'), 'utf8'));
const codes = new Map(); // code -> 이름(영문)
for (const d of resolved.decks.filter((x) => APP_DECKS.includes(x.id))) {
  for (const c of d.cards) {
    const code = resolved.cards[c.ref]?.ko;
    if (code && !codes.has(code)) codes.set(code, c.nameEn);
  }
}

await ensureDirs();
const out = {};
const notes = [];
let i = 0, downloaded = 0;
for (const [code, name] of codes) {
  i++;
  try {
    const jm = await jpOf(code);
    if (!jm) { notes.push(`${code} ${name}: 일본판 대응 못 찾음`); continue; }
    const curInfo = await jpInfo(jm.set, jm.num);
    const list = [{ code, reg: curInfo?.reg ?? null, jp: `${jm.set}-${jm.num}`, special: !!(curInfo?.official && jm.num > curInfo.official) }];
    for (const p of await reprints(jm.set, jm.num)) {
      if (isPromo(p.set) || (p.set === jm.set && p.num === jm.num)) continue;
      const inf = await jpInfo(p.set, p.num);
      if (!inf || !ALLOWED.includes(inf.reg)) continue;
      const ko = await koOf(p.set, p.num);
      if (!ko || list.some((x) => x.code === ko.code)) continue;
      const st = await download(koUrl(ko.code), fileURLToPath(new URL(`${ko.code}.webp`, KO_DIR)));
      if (st === 'missing') continue;
      if (st === 'ok') downloaded++;
      list.push({ code: ko.code, reg: inf.reg, jp: `${p.set}-${p.num}`, special: !!(inf.official && p.num > inf.official), d: ko.d });
    }
    // 최근 레귤레이션 → 일반 인쇄 → 코드 순
    list.sort((a, b) => (RANK[b.reg] ?? 0) - (RANK[a.reg] ?? 0) || a.special - b.special || a.code.localeCompare(b.code));
    if (list.length > 1) out[code] = list;
    console.log(`[${i}/${codes.size}] ${code} ${name}: ${list.map((x) => `${x.code}(${x.reg ?? '-'}${x.special ? '★' : ''})`).join(' ')}`);
  } catch (e) {
    notes.push(`${code} ${name}: 오류 ${e.message ?? e}`);
  }
}

writeFileSync(P('src/data/prints.json'), JSON.stringify({ generated: new Date().toISOString(), allowed: ALLOWED, prints: out }, null, 2) + '\n');
console.log(`\n다른 인쇄가 있는 카드 ${Object.keys(out).length}종, 인쇄 ${Object.values(out).reduce((a, l) => a + l.length, 0)}개, 새 이미지 ${downloaded}장`);
if (notes.length) console.log('참고:\n  ' + notes.join('\n  '));
