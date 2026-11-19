# 공격 연출 — 하스스톤 벤치마킹 1단계 (두 조사 종합)

하스스톤의 공격·피해·기절 연출을 웹으로 조사하고(Claude), 같은 지시를 Fable 헤드리스에 내려 따로 조사한 뒤(원문 `fx-hearthstone-review-fable.md`) 우리 연출(`godot/scripts/battle/fx.gd`)과 대조했다. 가져오는 것은 **모션·타이밍·피드백 원리**이고, 블리자드 고유 모양(톱니형 피해 배지, 판 균열, 해골 표식 등)은 쓰지 않는다.

**한계:** 하스스톤 공격 모션의 프레임 수치는 어떤 글에도 없었다. 아래 "하스스톤 모션 분해"는 Fable 의 기억 기반 추정이고, 2단계(영상 프레임 측정)로 확정해야 한다. 글로 확인된 것은 연출 길이 정책, VFX 원칙, 화면 흔들림이 공격력에 따라 커진다는 점이다.

## 1. 두 조사가 확인한 것

| 내용 | 근거 | 누가 |
|---|---|---|
| 이펙트의 첫째 역할은 **정보 전달**. 턴 내내 남는 효과는 화면 전체를 덮지 말고 가볍게. 선택지를 화려하게 꾸미면 "정답처럼" 보여 판단을 왜곡 | [공식 개발자 블로그](https://hearthstone.blizzard.com/en-us/blog/22552047) ([한국어](https://hearthstone.blizzard.com/ko-kr/blog/22552047)) | 둘 다 본문 |
| 대부분의 이펙트는 클라이언트 쪽, 서버는 피해·회복 수치만 보냄. 타이밍은 게임 로직이 정하고 연출이 거기에 맞춤 | 같은 블로그 | Claude |
| **화면 흔들림은 공격력에 비례**: 공격력 6~7 중간, 8 이상 강하게 + 먼지·파편, 영웅 사망은 훨씬 강하게. 설정에서 끌 수 있음 | [TV Tropes](https://www.tvtropes.org/pmwiki/pmwiki.php/HearthstoneHeroesOfWarcraft/TropesSToZ) (검색 요약), [공식 포럼](https://us.forums.blizzard.com/en/hearthstone/t/stop-making-the-screen-shake/4722) | 둘 다 (2차 출처) |
| 전장에서 15 이상 피해는 더 큰 공격 연출 | 검색 요약 | Fable |
| **연출 길이는 빈도로 정함**: 자주·연쇄로 나오는 트리거 0.8초 → 0.2초(일부 0초), 연쇄 안 되는 큰 순간만 길게(7초 전설) | [outof.games](https://outof.games/news/758-hearthstone-gameplay-is-going-to-be-faster-minion-trigger-speeds-increasing-by-300-in-an-upcoming-patch/), [Shacknews](https://www.shacknews.com/article/117568/hearthstone-interview-demon-hunters-and-making-the-game-faster) | 둘 다 |
| 긴 연쇄는 진행될수록 가속, 마지막은 감속 | [31.6 패치 노트](https://hearthstone.blizzard.com/en-us/news/24179332/31-6-patch-notes) | Fable |
| 공격 뒤 다음 행동까지 1~2초 지연이 지금도 불만 | [공식 포럼](https://us.forums.blizzard.com/en/hearthstone/t/delay-when-attacking-with-minions/147400) | Fable |
| 공격자·방어자 피해는 동시, 사망은 트리거가 끝난 뒤 한 번에 | [wiki Combat](https://hearthstone.wiki.gg/wiki/Combat) | 둘 다 |
| **히트 스톱**: 맞는 순간 잠깐 멈춤. 무게에 비례해야 하고, 모두 같으면 "잡음"이 됨. 너무 길면(약 20프레임 이상) 버그처럼 느껴짐 | [SSB Wiki](https://www.ssbwiki.com/Hitlag), [critpoints](https://critpoints.net/2017/05/17/hitstophitfreezehitlaghitpausehitshit/), [Godot 포럼 체크리스트](https://forum.godotengine.org/t/game-feel-checklist-for-godot-4-hit-stop-trauma-shake-coyote-time-and-more/145340) | 둘 다 |
| game feel 체크리스트(Vlambeer "The Art of Screenshake"): 넉백, 화면 흔들림, 히트 멈춤, 잔존물(permanence) | [Bayreuth 강의 자료](https://medienwissenschaft.uni-bayreuth.de/wp-content/uploads/GxD-10-Game-Feel.pdf), [Gamedeveloper](https://gamedeveloper.com/design/vlambeer-co-founder-shares-advice-on-building-better-action-games) | 둘 다 |
| 즉각 피드백, 과장된 충돌 반응, 같은 동작에도 약간의 변주 | [Swink, Principles of Virtual Sensation](https://www.gamedeveloper.com/design/principles-of-virtual-sensation) | Fable |
| 이펙트 크기는 중요도에 비례, 예비 → 임팩트 → 소멸, 최고점은 앞쪽 1/4 | [LoL VFX 가이드 요약](https://www.vfxapprentice.com/blog/10-league-of-legends-vfx-design-tips) | Fable |

## 2. 하스스톤 공격 한 번 (추정 — 2단계에서 측정)

예비 동작(반대쪽으로 살짝, 0.10~0.15초) → 가속 돌진(0.10~0.15초, ease-in) → **충돌: 숫자·흔들림·소리가 한 프레임에** (맞은 쪽 밀림, 큰 공격이면 판 흔들림) → 느린 복귀(0.25~0.35초, 돌진보다 느려 무게감) → 피해 배지는 제자리에 머물다 사라짐(약 1초, 움직이지 않아야 읽힘) → 사망은 숫자를 읽은 뒤, 동시 사망은 한 번에 떨다가 사라짐.

## 3. 우리 연출과 대조

지금(`fx.gd` 탁자 모드): 기술 = 가운데 배너 0.6초(기다리지 않음) + 60px 돌진 0.14초·복귀 0.18초 + 0.45초 대기 → **그다음** 피해 사건 = HP 감소·"-N" 54px 숫자가 바로 70px 떠오름·좌우 10px 4번 흔들림·진동 15ms·0.4초 대기. 기절 = 회색 0.2초 → 트래쉬로 0.35초 + "기절!" 배너.

| 문제 | 하스스톤 원리 |
|---|---|
| 돌진이 끝나고 0.45초 뒤에 피해가 따로 뜸 → 맞는 느낌이 없음 | 충돌 순간에 숫자·HP·흔들림·진동을 한 프레임에 |
| 10 피해든 200 피해든 연출이 같음 | 흔들림·멈춤·숫자 크기를 위력에 비례 |
| 숫자가 뜨자마자 움직여 읽기 어려움 | 제자리에서 튀고 → 멈춰 읽히고 → 사라짐 |
| 예비 동작 없는 등속 돌진 | 예비 → 빠른 돌진 → 느린 복귀 |
| 기술 배너가 판 가운데를 가림 | 정보는 칸 근처에 작게 |

## 4. 개선안 (적용 순서)

피해 등급(PTCG 수치 기준, 조정 가능): **소** ≤30 / **중** 40~90 / **대** 100~190 / **특대** 200 이상 또는 기절시키는 타격. 모든 시간은 지금처럼 배속으로 나누고, 화면을 누르면 건너뛴다. 즉시 모드는 연출 없음 그대로.

| 순위 | 대상 | 바꿀 내용 (출발값, 실기기 조율) | 난이도 |
|---|---|---|---|
| 1 | **충돌 동기화** | 기술 사건 처리 때 큐에서 바로 뒤따르는 같은 기술의 피해 사건을 미리 꺼내, 돌진이 상대 칸에 닿는 순간 숫자·HP·흔들림·진동을 실행. 0.45초 대기는 복귀와 겹침 | 중 (큐 처리 순서) |
| 2 | **피해 4등급** | 숫자 44/54/68/84px, 진동 10/15/25/40ms, 판 전체 흔들림은 대 5px·특대 9px만(0.2초 감쇠) + 설정에서 흔들림·진동 끄기 | 하 |
| 3 | **숫자 움직임** | 칸 가운데 0.5→1.25배(0.08초) → 1.0배(0.10초) → 정지 0.40초 → 24px 떠오르며 사라짐(0.22초). 소·중은 ±4° 기울기 변주 | 하 |
| 4 | **예비·돌진·넉백** | 반대쪽 14px(0.10초, ease-out) → 80px 돌진(0.09초, ease-in, 1.06배) → 복귀 0.24초(ease-out). 맞은 칸은 공격 방향으로 8/14/20/26px 밀렸다 0.18초에 복귀(BACK) + 감쇠 흔들림 | 하 |
| 5 | **기술 이름 위치** | 가운데 배너 → 공격 포켓몬 칸 위 이름표, 예비 동작과 동시 시작 | 하 |
| 6 | **히트 스톱·번쩍임** | 충돌 순간 해당 칸 Tween 만 멈춤: 중 0.04 / 대 0.07 / 특대 0.10초(전체 시간 배율은 안 건드림). 맞은 칸 위 흰 사각형 알파 0.7→0, 0.12초 | 하~중 |
| 7 | **기절 순서** | 숫자 읽기 0.35초 → 6px 떨림 3번 + 회색·0.92배 → 트래쉬로 0.30초. 동시 기절은 0.06초씩 어긋난 한 묶음. "기절!"은 칸 위 이름표 | 중 |
| 8 | **약점·저항 라벨** | 숫자 옆 "약점 ×2" / "저항 −30" (약점이면 등급 한 단계 위). **엔진 피해 사건에 약점·저항 정보 추가 필요**(TS·GD 둘 다 + 엔진 비교 테스트) | 중 |
| 9 | 반복 가속·길이 예산 | 한 턴에 같은 연출 3번째부터 0.75배·5번째부터 0.5배(마지막 기절은 1배). 매 턴 나오는 연출은 막는 시간 0.3초 이하 | 중 |

예상 길이: 지금 기술 한 번 약 0.85초(0.45 + 0.4) → 개선안 약 0.6~0.7초인데 전달하는 정보는 더 많다.

**적용 위치:** 탁자 모드(AI 연습)에 전부. 손패 모드(서버 대전)는 큰 연출을 웹 게임판이 맡는다는 원칙대로 숫자·진동 등급만. 웹 게임판에는 같은 원리를 나중에 따로.

## 5. 가져오지 않을 것

- 긴 전용 연출(수 초짜리 등장·필살 연출) — 하스스톤도 연쇄되지 않는 큰 순간에만 허용. 연습 앱은 반복이 훨씬 많다.
- 연출이 끝날 때까지 입력 막기 — 하스스톤의 현재 불만. 우리는 배속·건너뛰기를 유지.
- 매 타격 화면 전체 흔들림 — 피로해서 끄기 요청이 나옴. 대·특대만, 끄기 옵션.
- 화면 가운데를 덮는 배너·비네트 — 판 읽기 방해.
- 0.15초 이상의 히트 스톱 — 버그처럼 느껴짐. 상한 0.10초.
- 블리자드 고유 모양(톱니 배지, 판 균열, 영웅 유리 깨짐).

## 6. 2단계: 영상 측정 체크리스트

60fps 영상을 프레임으로 잘라 잰다. 후보: [Kotaku 슬로모션 편집](https://kotaku.com/hearthstone-effects-in-slow-motion-are-hypnotic-1732035792)([영상](https://www.youtube.com/watch?v=XY_9X8HSakg)), 해설 없는 고화질 플레이 영상의 공격 장면(작은 공격 1개 + 공격력 8 이상 1개).

- 공격: 예비 동작 거리·프레임, 돌진 프레임·가속, 히트 스톱 유무·프레임, 복귀 프레임·오버슈트, 맞은 쪽 넉백 거리
- 차등: 공격력 1·4·8·12에서 흔들림 진폭·길이, 임계값
- 숫자: 뜨는 프레임(접촉과 같은지), 크기 변화, 유지·사라짐 프레임, 떠오르는지, 피해량에 따라 크기가 다른지, 광역은 동시인지
- 사망: 접촉 → 사망 시작 지연, 떨림 횟수·진폭, 사라짐 프레임, 동시 사망 간격
- 흐름: 공격 끝 → 다음 입력 가능까지 프레임

## 출처

- Claude: [공식 개발자 블로그(VFX)](https://hearthstone.blizzard.com/en-us/blog/22552047), [TV Tropes(화면 흔들림 임계값, 검색 요약)](https://www.tvtropes.org/pmwiki/pmwiki.php/HearthstoneHeroesOfWarcraft/TropesSToZ), [공식 포럼 공격 연출](https://us.forums.blizzard.com/en/hearthstone/t/attack-animation/90660), [wiki Combat](https://hearthstone.wiki.gg/wiki/Combat), [PC Gamer 데스윙 애니메이션](https://pcgamer.com/deathwing-finally-gets-the-animation-it-deserves), [r/gamedev 공격 재현](https://redlib.hbubli.cc/r/gamedev/comments/alihy2/i_recreated_hearthstones_swipe_animation_to_show/efeuswy/?context=3), [realtimevfx 팬 FX](https://realtimevfx.com/t/hearthstone-fan-fx/2490), [SSB Wiki Hitlag](https://www.ssbwiki.com/Hitlag), [Sakurai 히트 스톱 칼럼](https://sourcegaming.info/2015/11/11/thoughts-on-hitstop-sakurais-famitsu-column-vol-490-1/), [Bayreuth Game Feel 자료](https://medienwissenschaft.uni-bayreuth.de/wp-content/uploads/GxD-10-Game-Feel.pdf), [Godot 포럼 trauma shake·hit-stop](https://forum.godotengine.org/t/game-feel-effects-that-stack-without-fighting-your-code-trauma-shake-real-time-hit-stop-and-apply-the-difference/146379)
- Fable: 원문 `fx-hearthstone-review-fable.md` 의 출처 표(21개, 본문 확인/검색 요약 구분)

## 부록: Fable 에 준 지시 (요약)

우리 연출의 현재 수치(돌진·숫자·흔들림·기절·특수상태)를 주고, 하스스톤의 공격 모션·충돌 피드백·피해 숫자·사망·주문 이펙트·사운드 동기화·개발자 발언·game feel 일반 원칙을 출처 URL 로 확인해 "Tween 으로 가능한 구체 수치의 개선안 표", "가져오면 안 되는 것", "우선순위와 영상 측정 체크리스트"를 내라고 지시. 블리자드 고유 모양 제외, 확인 못 한 수치는 "추정".

## 진행 기록

- **1~7번 적용** (`godot/scripts/battle/fx.gd`): 충돌 동기화, 피해 4등급, 숫자 튀고 멈춤, 예비·돌진·넉백, 칸 위 기술 이름표, 히트 스톱·번쩍임, 기절 묶음. 메뉴에 화면 흔들림·진동 끄기.
- **8번 약점·저항 라벨**: 두 엔진(`src/game/core.ts`, `godot/scripts/engine/g_core.gd`)의 기술 피해 사건에 `weak`/`resist`(적용됐을 때만 true). 숫자 아래 "약점 ×2"(금색)·"저항 −30"(회청색) 띠, 약점이면 등급 한 단계 위(진동·밀림·히트 스톱·판 흔들림 모두). 기록 줄에도 표시. 엔진 비교 테스트가 두 엔진의 사건을 그대로 비교하므로 함께 검증됨, 규칙 테스트에 사건 표시 확인 추가.
- **9번 반복 가속**: 한 턴(차례 시작마다 초기화)에 같은 연출 종류 3번째부터 0.75배, 5번째부터 0.5배 길이. 종류 = 사건 종류(카드 사용은 "무엇을"까지, 덱 → 손패 이동은 "뽑기"). 승부를 가르는 마지막 기절은 1배. 배속·건너뛰기와 곱해짐.
- 길이 예산(매 턴 연출 0.3초 이하)은 차례 배너(0.7초)만 넘는데, 차례 전환은 놓치면 안 되는 정보라 그대로 두고 실기기에서 판단.
