// src/data/regulation_upgrade.json 의 "upgrade" 결과를 앱 덱에 반영한다.
//  - scripts/decklists.txt : 앱 덱 섹션에서만 ko=이전코드 → ko=새코드
//  - src/data/names.ts / kinds.json / basics.ts : 새 코드에 이전 코드의 이름·종류·기본 여부를 복사
// 기존 이미지와 이전 코드 정보는 지우지 않는다(누적).
// 사용: node scripts/apply-regulation.mjs [--skip CODE1,CODE2]
import { readFileSync, writeFileSync } from 'node:fs';

const P = (p) => new URL(`../${p}`, import.meta.url);
const APP_DECKS = ['flareon', 'dragapult', 'charizard', 'gholdengo', 'gardevoir', 'pachirisu'];
const skipArg = process.argv.find((a) => a.startsWith('--skip'));
const SKIP = new Set(skipArg ? (skipArg.split('=')[1] ?? process.argv[process.argv.indexOf(skipArg) + 1] ?? '').split(',') : []);

const up = JSON.parse(readFileSync(P('src/data/regulation_upgrade.json'), 'utf8')).results;
const changes = Object.values(up).filter((r) => r.status === 'upgrade' && r.newCode !== r.current && !SKIP.has(r.current));
const map = Object.fromEntries(changes.map((r) => [r.current, r.newCode]));

// 1) decklists.txt (앱 덱 섹션만)
const deckPath = P('scripts/decklists.txt');
const lines = readFileSync(deckPath, 'utf8').split(/\r?\n/);
let section = null, replaced = 0;
for (let i = 0; i < lines.length; i++) {
  const h = /^##\s*([a-z_]+)\s*\|/.exec(lines[i]);
  if (h) { section = h[1]; continue; }
  if (!APP_DECKS.includes(section)) continue;
  lines[i] = lines[i].replace(/ko=([A-Za-z0-9]+_\d{3})$/, (m, code) => {
    if (!map[code]) return m;
    replaced++;
    return `ko=${map[code]}`;
  });
}
writeFileSync(deckPath, lines.join('\n'));

// 2) names.ts
const namesPath = P('src/data/names.ts');
let names = readFileSync(namesPath, 'utf8');
const NAMES = Object.fromEntries([...names.matchAll(/\b([A-Za-z0-9]+_\d{3}):\s*'([^']+)'/g)].map((m) => [m[1], m[2]]));
const addNames = changes.filter((r) => !NAMES[r.newCode] && NAMES[r.current]).map((r) => `  ${r.newCode}: '${NAMES[r.current]}',`);
if (addNames.length) {
  names = names.replace(/\n};\s*$/, `\n  // 레귤레이션 교체로 추가 (${new Date().toISOString().slice(0, 10)})\n${addNames.join('\n')}\n};\n`);
  writeFileSync(namesPath, names);
}

// 3) kinds.json
const kindsPath = P('src/data/kinds.json');
const kinds = JSON.parse(readFileSync(kindsPath, 'utf8'));
for (const r of changes) for (const k of ['pokemon', 'trainer', 'energy']) {
  if (kinds[k].includes(r.current) && !kinds[k].includes(r.newCode)) kinds[k].push(r.newCode);
}
writeFileSync(kindsPath, JSON.stringify(kinds, null, 2) + '\n');

// 4) basics.ts
const basicsPath = P('src/data/basics.ts');
let basics = readFileSync(basicsPath, 'utf8');
const BASICS = new Set([...basics.matchAll(/'([A-Za-z0-9]+_\d{3})'/g)].map((m) => m[1]));
const addBasics = changes.filter((r) => BASICS.has(r.current) && !BASICS.has(r.newCode)).map((r) => `'${r.newCode}'`);
if (addBasics.length) {
  basics = basics.replace(/\]\);\s*\n/, `  // 레귤레이션 교체로 추가\n  ${addBasics.join(', ')},\n]);\n`);
  writeFileSync(basicsPath, basics);
}

console.log(`교체 ${changes.length}종 (덱 줄 ${replaced}곳), 이름 추가 ${addNames.length}, 기본 포켓몬 추가 ${addBasics.length}`);
for (const r of changes) console.log(`  ${r.current} → ${r.newCode}  ${r.name}  (${r.currentReg} → ${r.choice})`);
