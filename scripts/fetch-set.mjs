// 한글판 세트 전체 이미지를 받는다 (001번부터 연속 3번 없을 때까지).
// 사용: npm run fetch-set -- SV6 SV4M [--from 1] [--max 400]
// 이미 받은 파일은 건너뛰고, 요청 사이에 간격을 둔다.
import { ensureDirs, download, koUrl, KO_DIR, sleep } from './ko-source.mjs';

const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? Number(args.splice(i, 2)[1]) : def; };
const from = opt('--from', 1);
const max = opt('--max', 400);
const sets = args;
if (!sets.length) { console.log('사용: npm run fetch-set -- SV6 [SV4M ...]'); process.exit(1); }

await ensureDirs();
for (const set of sets) {
  let ok = 0, skip = 0, misses = 0, n = from;
  for (; n <= max && misses < 3; n++) {
    const code = `${set}_${String(n).padStart(3, '0')}`;
    const r = await download(koUrl(code), new URL(`${code}.webp`, KO_DIR));
    if (r === 'missing') { misses++; continue; }
    misses = 0;
    if (r === 'ok') { ok++; process.stdout.write(`\r${set}: ${code} 받는 중…   `); await sleep(400); }
    else skip++;
  }
  console.log(`\r${set}: 새로 받음 ${ok}장, 이미 있음 ${skip}장 (마지막 확인 번호 ${n - 1 - misses})`);
}
