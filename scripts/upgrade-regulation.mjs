// 앱 덱의 카드를 같은 카드의 "가장 최근 레귤레이션(G/H/I)" 재판으로 바꿀 후보를 찾는다.
//  1) 한글 코드 → 일본판 카드: 같은 세트의 주변 번호를 그림(dHash)으로 비교해 찾는다
//     (한글판은 트레이너스 번호 순서가 일본판과 다를 수 있음)
//  2) Limitless 일본판 페이지에서 같은 카드의 재판 목록, TCGdex(ja)에서 각 재판의 레귤레이션 마크
//  3) 허용 마크(G/H/I) 중 가장 높은 마크의 재판을 고른다 (같은 마크면 현재 인쇄 유지, 아니면 일반 레어도 우선)
//  4) 고른 재판의 한글판 코드를 다시 그림 비교로 찾는다
// 결과: src/data/regulation_upgrade.json (덱 파일은 바꾸지 않음 — 확인 후 --apply)
// 사용: npm run upgrade-reg            (조사만)
//       npm run upgrade-reg -- --apply (decklists.txt 반영 + 이름/종류/기본 정보 복사)
import { readFileSync, writeFileSync } from 'node:fs';
import { P, ALLOWED, RANK, APP_DECKS, findInSet, hashOf, jpInfo, reprints, isPromo, KO_WINDOW, jpOf } from './print-lib.mjs';

const resolved = JSON.parse(readFileSync(P('src/data/resolved.json'), 'utf8'));
const OUT = P('src/data/regulation_upgrade.json');

// ── 메인 ──
const codes = new Map(); // code -> {decks:Set, name}
for (const d of resolved.decks.filter((x) => APP_DECKS.includes(x.id))) {
  for (const c of d.cards) {
    const code = resolved.cards[c.ref]?.ko;
    if (!code) continue;
    if (!codes.has(code)) codes.set(code, { decks: new Set(), name: c.nameEn });
    codes.get(code).decks.add(d.id);
  }
}

const results = {};
let i = 0;
for (const [code, meta] of codes) {
  i++;
  const r = { name: meta.name, decks: [...meta.decks], current: code, currentReg: null, jp: null, choice: null, newCode: code, status: '', note: '' };
  try {
    // 1) 일본판 대응 카드 (그림 비교, 직접 확인한 카드는 JP_OVERRIDE)
    const jm = await jpOf(code);
    if (!jm) { r.status = 'jp-not-found'; results[code] = r; console.log(`[${i}/${codes.size}] ${code} ${meta.name}: 일본판 대응 못 찾음`); continue; }
    r.jp = `${jm.set}-${jm.num}`;
    const cur = await jpInfo(jm.set, jm.num);
    r.currentReg = cur?.reg ?? null;
    // 2) 재판 + 레귤레이션
    const prints = [];
    for (const p of await reprints(jm.set, jm.num)) {
      if (isPromo(p.set)) continue;
      const inf = await jpInfo(p.set, p.num);
      if (!inf || !ALLOWED.includes(inf.reg)) continue;
      prints.push({ ...p, ...inf, regular: inf.official ? p.num <= inf.official : true });
    }
    if (!prints.length) { r.status = 'no-allowed-print'; results[code] = r; console.log(`[${i}] ${code}: 허용 마크 재판 없음 (현재 ${r.currentReg})`); continue; }
    const top = Math.max(...prints.map((p) => RANK[p.reg]));
    // 현재 인쇄가 이미 최고 마크면 유지
    if (RANK[r.currentReg] === top) { r.status = 'keep'; results[code] = r; console.log(`[${i}] ${code} ${meta.name}: 유지 (${r.currentReg})`); continue; }
    const cands = prints.filter((p) => RANK[p.reg] === top).sort((a, b) => (b.regular - a.regular) || (a.num - b.num));
    // 3) 한글판 코드 찾기
    for (const c of cands) {
      const jh = await hashOf('jp', c.set, c.num);
      if (!jh) continue;
      const km = await findInSet('ko', c.set, c.num, jh, KO_WINDOW(c.set));
      if (km) {
        r.choice = `${c.set}-${c.num} (${c.reg}${c.regular ? '' : ', 특수 레어'})`;
        r.newCode = `${c.set}_${String(km.num).padStart(3, '0')}`;
        r.status = 'upgrade';
        r.note = `일본판 대응 차이 ${jm.d}, 한글판 대응 차이 ${km.d}`;
        break;
      }
    }
    if (r.status !== 'upgrade') { r.status = 'ko-not-found'; r.note = `후보: ${cands.map((c) => `${c.set}-${c.num}(${c.reg})`).join(', ')}`; }
    console.log(`[${i}/${codes.size}] ${code} ${meta.name}: ${r.currentReg} → ${r.status === 'upgrade' ? `${r.newCode} ${r.choice}` : r.status}`);
  } catch (e) {
    r.status = 'error'; r.note = String(e.message ?? e);
    console.log(`[${i}] ${code}: 오류 ${r.note}`);
  }
  results[code] = r;
}

writeFileSync(OUT, JSON.stringify({ generated: new Date().toISOString(), allowed: ALLOWED, results }, null, 2));
const by = (s) => Object.values(results).filter((r) => r.status === s).length;
console.log(`\n교체 ${by('upgrade')} / 유지 ${by('keep')} / 허용 재판 없음 ${by('no-allowed-print')} / 일본판 못 찾음 ${by('jp-not-found')} / 한글판 못 찾음 ${by('ko-not-found')} / 오류 ${by('error')}`);
