// 브라우저에서 직접 저장한 한글 카드 이미지(예: SV6_081.webp)를 public/cards/ko/ 로 복사한다.
// 파일명이 곧 한글판 코드이므로 이름만 맞으면 된다.
// 사용: npm run import-ko [-- "D:\폴더"]   (기본: 사용자 다운로드 폴더)
import { readdirSync, copyFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { ensureDirs, KO_DIR } from './ko-source.mjs';

const srcDir = process.argv[2] ?? join(homedir(), 'Downloads');
await ensureDirs();

const found = {};
for (const f of readdirSync(srcDir)) {
  const m = /^([A-Za-z0-9]+_\d{3})(?:\s*\(\d+\))?\.webp$/i.exec(f);
  if (!m) continue;
  const full = join(srcDir, f);
  const t = statSync(full).mtimeMs;
  if (!found[m[1]] || found[m[1]].t < t) found[m[1]] = { full, t, f };
}
for (const [code, { full, f }] of Object.entries(found)) {
  copyFileSync(full, new URL(`${code}.webp`, KO_DIR));
  console.log('ok  ', code, '←', f);
}
console.log(`가져옴 ${Object.keys(found).length}장 (검색 폴더: ${srcDir})`);
