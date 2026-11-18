# 규칙 엔진 GDScript 포팅 규칙 (오프라인 AI 연습용)

원본은 `src/game/*.ts` (서버·웹이 쓰는 TypeScript 엔진). 이 폴더는 그것을 **한 줄 한 줄 그대로** 옮긴 것이다.
같은 시드 + 같은 입력이면 두 엔진의 상태·이벤트가 완전히 같아야 한다 (`npm test` 의 엔진 비교 테스트가 검사).
**규칙을 고칠 때는 TS 와 이 폴더를 같이 고친다.** 해석·개선을 섞지 말고 TS 동작을 그대로 따른다.

## 파일 · 클래스
| TS | GDScript | class_name |
|---|---|---|
| rng.ts | g_rng.gd | GRng |
| core.ts (+ cardData.ts 의 prizeValue, TYPE_KO) | g_core.gd | GCore |
| effects.ts | g_effects.gd | GEffects |
| engine.ts | g_engine.gd | GEngine |
| view.ts | g_view.gd | GView |
| bot.ts | g_bot.gd | GBot |
| match.ts + catalog.ts | g_match.gd | GMatch |

## 규칙
- 모든 함수는 `static func`, **TS 와 같은 이름**(camelCase 그대로). 다른 모듈 함수는 `GCore.moveCard(...)` 처럼 클래스로 부른다.
  같은 파일 안이라도 람다 안에서는 `GEffects.foo()` 처럼 클래스 이름을 붙인다.
- 모듈 상수 → `const`. 바뀌는 표(FRAMES, TRAINERS, ABILITIES, ATTACKS) → `static var X: Dictionary = {}` 이고,
  `static func ensure()` 가 처음 한 번 채운다 (람다로). GEngine 도 자기 프레임(endTurn 등)을 `GEffects.FRAMES` 에 넣는다.
  - 프레임 처리기: `func(ctx: Dictionary, f: Dictionary) -> void`
  - TRAINERS[name] = `{ "can": Callable 또는 없음, "run": Callable }` — `can(ctx, seat, iid)` 은 TS 와 같이 "못 쓰는 이유"(String) 또는 `null`/""(쓸 수 있음).
    TS 에서 `def.can && def.can(...)` 이 참이면 못 씀 → GDScript 에서는 `GCore.truthy(def.can.call(...))`.
  - ABILITIES[nameJa] = `{ "once": "pokemon"|"name"|"none", "can": ..., "run": ... }`, ATTACKS[nameJa] = `{ "can": ..., "run": ... }` (TS 와 같은 키, 없는 키는 넣지 않음)
- **자료형**: TS 객체 = Dictionary, **키 이름 똑같이**. TS 에서 `undefined`(없는 선택 키) → 키를 넣지 않는다. `null` → null.
  `{...a, b: 1}` → `a.duplicate()` 후 키 설정 (얕은 복사, TS 와 같음).
- **숫자**: 전부 int. JSON 에서 읽은 데이터는 `GCore.intify()` 로 정수화되어 있다. `Math.floor(a/b)` → `floori(float(a)/b)`,
  `Math.min/max` → `mini/maxi`. 문자열→숫자 `Number(x)` → `int(x)`, 숫자→문자열 `String(i)` → `str(i)`.
- **객체 동일성**: TS 의 `===` (슬롯·프레임·요청 객체 비교) → `is_same(a, b)`.
  **GDScript 의 Dictionary `==`, `Array.has`, `Array.find` 는 내용 비교**라서 슬롯·프레임에 쓰면 안 된다 →
  `GCore.idx_same(arr, obj)` (indexOf), `GCore.has_same(arr, obj)` (includes).
  문자열·숫자 배열은 `has` / `find` 그대로 써도 된다.
- **배열 메서드**: `filter/map/any/all/reduce` 는 Godot 에도 있다 (람다). `some`→`any`, `every`→`all`.
  `find(pred)` → `GCore.find_first(arr, pred)` (없으면 null), `findIndex` → `GCore.find_index(arr, pred)` (-1),
  `unshift` → `push_front`, `splice(i,1)` → `remove_at(i)`, `lastIndexOf` → `rfind`, `[...a]` → `a.duplicate()`.
- **정렬**: JS `sort` 는 안정 정렬, Godot `sort_custom` 은 아님 → 반드시 `GCore.stable_sort(arr, cmp)` (새 배열 반환).
  `cmp(a, b)` 는 JS 와 같이 숫자(음수면 a 가 앞).
- **예외 없음**: TS 가 `throw new GameError(code, msg)` 하는 곳 → `GCore.fail(ctx, code, msg)` 후 바로 `return`(자료형에 맞는 빈 값).
  엔진이 입력 처리 뒤 `ctx.err` 를 보고 오류로 돌려준다 (상태는 깊은 복사본이라 버려짐).
- **이벤트**: `GCore.emit(ctx, {"type": ..., ...})` — TS 와 같은 키 (TS 가 넣지 않는 선택 키는 넣지 않는다).
- **결정성**: `ctx.s.rng`, `nextId`, `eventSeq` 를 건드리는 호출의 **순서가 TS 와 정확히 같아야** 한다.
  반복 순서(배열 순서, Dictionary 삽입 순서)도 TS 와 같게.
- `?.`, `??` 는 명시적 null 검사로. 람다는 바깥 지역 변수(원시값)를 **복사**로 잡으므로, 람다 안에서 바꿔야 하는 값은 Dictionary/Array 에 담는다.
- Ctx = `{ "s": 상태, "ev": 이벤트 배열, "info": { "basics": Dictionary(ruleId→true), "db": 카드 규칙 데이터 } }`.
