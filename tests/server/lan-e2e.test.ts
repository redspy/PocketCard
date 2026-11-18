// 서버 대전 끝-끝: 실제 게임 서버 + TS AI 상대 + Godot 앱(새 대전 화면 손패 모드)이 화면 조작으로 끝까지 → 결과 → 나가기
// scripts/lan-e2e.ts 실행. Godot 이 없으면 건너뜀.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { findGodot } from '../../scripts/find-godot.ts';

test('서버 대전 끝-끝 (앱 손패 모드)', { timeout: 1200000, skip: findGodot() ? false : 'Godot 없음' }, () => {
  const script = fileURLToPath(new URL('../../scripts/lan-e2e.ts', import.meta.url));
  const r = spawnSync(process.execPath, [script], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  assert.equal(r.status, 0, (r.stdout ?? '') + (r.stderr ?? ''));
});
