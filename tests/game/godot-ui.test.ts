// 앱 대전 화면(godot/scripts/screens/battle_screen.gd) 자동 테스트: 배치 단언, 상태와 그린 것 일치, 조작으로 끝까지 대전 등
// godot/scripts/battle/ui_tests.gd 를 Godot 헤드리스로 실행. Godot 이 없으면 건너뜀.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { findGodot } from '../../scripts/find-godot.ts';

test('앱 대전 화면 자동 테스트 (Godot)', { timeout: 1800000, skip: findGodot() ? false : 'Godot 없음' }, () => {
  const sh = fileURLToPath(new URL('../../scripts/godot-ui-tests.sh', import.meta.url));
  const r = spawnSync('sh', [sh], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  assert.equal(r.status, 0, (r.stdout ?? '') + (r.stderr ?? ''));
});
