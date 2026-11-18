// 카드 규칙 데이터 테스트: 필수 항목, 진화 연결, 덱 규칙(이름 4장·ACE SPEC 1장), 효과 자동화
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isAutomated } from '../../src/game/effects.ts';
import { catalog, info } from './helpers.ts';

test('모든 덱 카드에 규칙 데이터가 있고 필수 항목이 채워져 있다', () => {
  for (const d of catalog.decks) for (const c of d.cards) {
    const r = info.db[c.id];
    assert.ok(r, `${d.id}: ${c.id} ${c.name} 데이터 없음`);
    if (r.kind === 'pokemon') {
      const p = r.pokemon!;
      assert.ok(p.hp > 0, `${r.name} HP`);
      assert.ok(p.attacks.length > 0, `${r.name} 기술`);
      if (p.stage > 0) assert.ok(p.from, `${r.name} 진화 전`);
    }
    if (r.kind === 'trainer') assert.ok(r.trainer, `${r.name} 트레이너스 종류`);
  }
});

test('덱 규칙: 같은 이름 4장 이하(기본 에너지 제외), ACE SPEC 1장 이하, 60장', () => {
  for (const d of catalog.decks) {
    const byName: Record<string, number> = {};
    let ace = 0, total = 0;
    for (const c of d.cards) {
      const r = info.db[c.id];
      total += c.count;
      if (r.ace) ace += c.count;
      if (r.energy?.basic) continue;
      byName[r.name] = (byName[r.name] ?? 0) + c.count;
    }
    assert.equal(total, 60, d.id);
    assert.ok(ace <= 1, `${d.id}: ACE SPEC ${ace}장`);
    for (const [n, k] of Object.entries(byName)) assert.ok(k <= 4, `${d.id}: ${n} ${k}장`);
  }
});

test('6개 덱의 모든 카드 효과가 자동화되어 있다', () => {
  const manual = Object.values(info.db).filter((c) => !isAutomated(c)).map((c) => `${c.id} ${c.name}`);
  assert.deepEqual(manual, []);
});
