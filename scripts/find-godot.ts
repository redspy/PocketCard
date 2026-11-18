// Godot 실행 파일 찾기 (환경 변수 GODOT, 없으면 winget 설치 위치)
import { existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

export function findGodot(): string | null {
  if (process.env.GODOT && existsSync(process.env.GODOT)) return process.env.GODOT;
  const base = join(process.env.LOCALAPPDATA ?? '', 'Microsoft/WinGet/Packages');
  if (!existsSync(base)) return null;
  for (const d of readdirSync(base).filter((x) => x.startsWith('GodotEngine.GodotEngine'))) {
    const exe = readdirSync(join(base, d)).find((f) => /^Godot_v.*_win64(_console)?\.exe$/.test(f) && f.includes('console')) ?? readdirSync(join(base, d)).find((f) => /^Godot_v.*_win64\.exe$/.test(f));
    if (exe) return join(base, d, exe);
  }
  return null;
}
