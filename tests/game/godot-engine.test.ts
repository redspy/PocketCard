// 앱 안의 GDScript 규칙 엔진(godot/scripts/engine, 서버 없는 AI 연습용)이 TS 엔진과 똑같이 동작하는지:
// AI·무작위 봇 대전을 TS 로 기록하고 Godot 헤드리스로 다시 돌려 입력마다 상태·이벤트·보기·AI 선택을 비교한다.
// Godot 이 없으면 건너뜀. 규칙을 고치면 TS 와 godot/scripts/engine 을 같이 고쳐야 이 테스트가 통과한다.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { findGodot } from '../../scripts/find-godot.ts';

test('GDScript 엔진 = TS 엔진 (AI·무작위 봇 대전 비교)', { timeout: 900000, skip: findGodot() ? false : 'Godot 없음' }, () => {
  const script = fileURLToPath(new URL('../../scripts/engine-compare.ts', import.meta.url));
  const out = execFileSync(process.execPath, [script, '8', '900', '--mixed'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  assert.match(out, /결과: 일치/, out);
});
