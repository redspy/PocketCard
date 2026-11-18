// 덱 뷰어 앱 빌드 + 폰 설치 한 번에
//   1) npm run export-godot 와 같은 데이터/이미지 내보내기
//   2) Godot 헤드리스로 리소스 가져오기 + 디버그 APK 내보내기 → build/PocketCardDeckViewer.apk
//   3) 연결된 폰에 설치 후 실행 (--no-install 이면 생략)
// 사용: npm run app   |   npm run app -- --no-install
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('../', import.meta.url));
const GODOT_DIR = join(ROOT, 'godot');
const APK = join(ROOT, 'build', 'PocketCardDeckViewer.apk');
const PKG = 'com.pocketcard.deckviewer';

function findGodot() {
  if (process.env.GODOT) return process.env.GODOT;
  const base = join(process.env.LOCALAPPDATA ?? '', 'Microsoft', 'WinGet', 'Packages');
  for (const d of existsSync(base) ? readdirSync(base) : []) {
    if (!d.startsWith('GodotEngine.GodotEngine_')) continue;
    const exe = readdirSync(join(base, d)).find((f) => /^Godot_v4.*_console\.exe$/.test(f));
    if (exe) return join(base, d, exe);
  }
  throw new Error('Godot 실행 파일을 찾지 못했습니다. 환경변수 GODOT 에 경로를 지정하세요.');
}

const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { stdio: 'inherit', ...opts });

// 덱(decks.json)에서 쓰지 않는 카드 이미지는 파일은 그대로 두고 앱 패키지에서만 뺀다
// (export_presets.cfg 의 exclude_filter 를 빌드 때마다 다시 씀)
function excludeUnusedImages() {
  const decks = JSON.parse(readFileSync(join(GODOT_DIR, 'data', 'decks.json'), 'utf8'));
  const used = new Set();
  for (const d of decks.decks) for (const c of d.cards) {
    for (const p of [c, ...(c.prints ?? [])]) for (const k of ['full', 'thumb']) if (p[k]) used.add(p[k].replace('res://', ''));
  }
  const unused = [];
  for (const dir of ['cards/full', 'cards/thumb']) {
    for (const f of readdirSync(join(GODOT_DIR, dir))) {
      if (f.endsWith('.import')) continue;
      const rel = `${dir}/${f}`;
      if (!used.has(rel) && !rel.endsWith('.png')) unused.push(rel);
    }
  }
  const filter = ['cards/full/*.png', ...unused].join(', ');
  const cfg = join(GODOT_DIR, 'export_presets.cfg');
  writeFileSync(cfg, readFileSync(cfg, 'utf8').replace(/^exclude_filter=".*"$/gm, `exclude_filter="${filter}"`));
  console.log(`  앱에 넣는 카드 이미지 ${used.size}개, 덱에서 쓰지 않아 뺀 이미지 ${unused.length}개 (파일은 유지)`);
}

// --win : Windows 실행 파일을 만들고 바로 실행 (폰 설치 대신)
if (process.argv.includes('--win')) {
  const EXE = join(ROOT, 'build', 'windows', 'PocketCardDeckViewer.exe');
  mkdirSync(join(ROOT, 'build', 'windows'), { recursive: true });
  console.log('▶ 데이터/이미지 내보내기');
  run(process.execPath, [join(ROOT, 'scripts', 'export-godot.mjs')]);
  excludeUnusedImages();
  const godot = findGodot();
  console.log('▶ Godot 리소스 가져오기');
  run(godot, ['--headless', '--path', GODOT_DIR, '--import'], { stdio: 'ignore' });
  console.log('▶ Windows 실행 파일 내보내기');
  run(godot, ['--headless', '--path', GODOT_DIR, '--export-debug', 'Windows Desktop', EXE.replaceAll('\\', '/')], { stdio: 'ignore' });
  console.log(`  → ${EXE}`);
  if (!process.argv.includes('--no-run')) {
    const { spawn } = await import('node:child_process');
    spawn(EXE, [], { detached: true, stdio: 'ignore' }).unref();
    console.log('  → 실행했습니다.');
  }
  process.exit(0);
}

console.log('▶ 데이터/이미지 내보내기');
run(process.execPath, [join(ROOT, 'scripts', 'export-godot.mjs')]);
excludeUnusedImages();

const godot = findGodot();
mkdirSync(join(ROOT, 'build'), { recursive: true });
console.log('▶ Godot 리소스 가져오기');
run(godot, ['--headless', '--path', GODOT_DIR, '--import'], { stdio: 'ignore' });
console.log('▶ APK 내보내기');
run(godot, ['--headless', '--path', GODOT_DIR, '--export-debug', 'Android', APK.replaceAll('\\', '/')], { stdio: 'ignore' });
if (!existsSync(APK)) throw new Error('APK 가 만들어지지 않았습니다.');
console.log(`  → ${APK}`);

if (!process.argv.includes('--no-install')) {
  console.log('▶ 폰에 설치');
  run('adb', ['install', '-r', APK]);
  run('adb', ['shell', 'monkey', '-p', PKG, '-c', 'android.intent.category.LAUNCHER', '1'], { stdio: 'ignore' });
  console.log('  → 실행했습니다.');
}
