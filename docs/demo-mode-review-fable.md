코드는 열어 보지 않고 적어 주신 구조 설명만으로 판단했다.

**결론: (a) 브라우저 내 엔진 실행을 기본으로 하되, 서버와 같은 프로토콜을 말하는 로컬 호스트로 감싸서 Board와 DebugPhone을 그대로 재사용한다. 즉 (a)의 실행 위치 + (c)의 UI다.** (b)는 나중에 같은 봇 코드를 ws 클라이언트로 붙이면 싸게 얻는다.

## 1. 실행 위치 비교

| | (a) 브라우저 로컬 | (b) 서버 데모 세션 + 봇 | (c) 게임판에 폰 2개 내장(서버 사용) |
|---|---|---|---|
| 실제 경로와 같은 코드 | 엔진·view·UI는 같음. ws·토큰·로비·디스크는 안 탐 | 전부 같음 | 전부 같음 |
| 서버 없이 열기 | 가능 | 불가 | 불가 |
| 되돌리기·단계 실행·시드 재시작 | 쉬움(순수 함수라 로그 재생이면 됨) | 프로토콜에 디버그 메시지를 추가해야 함 | (b)와 같음 |
| 카드 효과 개발 궁합 | 좋음. 엔진 수정 → HMR → 로그 재생으로 같은 상황 복원 | 서버 재시작 + 리플레이 복원 필요 | 같음 |
| 봇 | 브라우저 타이머로 구동 | 서버에 봇 수명·속도 제어 필요 | 봇 없음(핫시트만) |
| 구현 비용 | 중 | 중~대 | 소 |

- **(a)를 고르는 이유:** 주 사용자가 개발자 한 명이고, 앞으로 할 일이 카드 효과 120개 구현이다. 가장 자주 쓸 기능은 되돌리기, 같은 시드로 다시, 한 단계씩이다. 서버 경로에서는 이것들이 모두 프로토콜 오염(디버그 전용 메시지)으로 이어진다.
- **(a)의 약점:** 실제 네트워크 경로(재접속, 일시정지, 로비)를 안 탄다. 이건 이미 있는 서버 통합 테스트의 몫이므로, 데모 모드는 그 경로를 검증하지 않는다고 문서에 명시하면 된다.
- **(c) 단독은 비추천:** 싸지만 서버가 필요하고 봇·되돌리기가 없어서 목표의 절반만 채운다. 다만 UI 조각(폰 패널 내장)은 그대로 가져온다.

## 2. 조작 방식과 비공개 정보

- **모드 대신 자리별 컨트롤러:** 각 자리에 `human | bot`을 지정한다. 사람/사람은 핫시트, 사람/봇은 혼자 플레이, 봇/봇은 자동 시연이 되어 세 모드가 하나의 개념으로 나온다.
- **자동 진행:** 재생/일시정지, 한 단계(입력 1개), 속도(지연 ms)를 둔다. 봇이 낀 자리에만 적용된다.
- **전지 시점은 만들지 않는다:** `viewFor`에 `'all'` 같은 시점을 추가하면 누출 테스트가 지키는 경계에 구멍이 생긴다. 게임판은 `'board'` 시점 그대로, 양쪽 폰 패널은 각각 `0`, `1` 시점으로 띄우면 화면 전체로는 모든 정보가 보이고 실제 필터를 그대로 탄다.
- **표시 토글:** 폰 패널을 `둘 다 / P1만 / P2만 / 숨김`으로 전환한다. 숨김 + 봇/봇이 관객용 시연 화면이다.
- **동시 요청(셋업):** 양쪽에 요청이 걸리므로 패널에 대기 배지를 달고, 한쪽만 대기 중이면 그 패널로 자동 포커스한다.

## 3. 데모 UI

- **넓은 화면(개발 PC, 주 사용 환경):** `P1 폰 | 게임판 | P2 폰` 3열. 게임판이 고정 크기가 아니라 컨테이너 크기에 맞춰 스케일되어야 한다.
- **태블릿:** 게임판이 전체를 차지하고, 폰 패널은 P1/P2 탭이 있는 슬라이드 서랍으로 둔다.
- **마주 보기 충돌:** 혼자 조작할 때 위쪽 180° 회전은 읽기 불편하다. 회전 끄기 토글을 두고 데모 기본값은 끔, 실제 레이아웃 확인이 필요할 때만 켠다.
- **상단 데모 바 한 줄:** 시드(표시·입력·새 시드), 덱 2개, 자리별 컨트롤러, 재생/일시정지/단계/속도, 되돌리기, 처음부터, 로그 내보내기/불러오기.
- **로그:** DebugPhone의 로그 탭은 시점 필터가 걸린 로그다. 데모 바에는 원본 입력 로그(번호 포함)를 따로 두고, 번호를 누르면 그 시점으로 되돌아가게 한다.
- **Board.tsx 분리:** 로비와 게임판이 한 컴포넌트라면 `Lobby`와 `GameBoard`로 나눠야 데모가 로비 없이 게임판만 쓸 수 있다.

## 4. 재현성 범위

**1차에 넣을 것(모두 "시드 + 입력 로그" 하나에서 파생되어 싸다):**
- URL 파라미터: `/demo?seed=..&d1=..&d2=..&p1=human&p2=bot`.
- 되돌리기와 처음부터: 로그 앞부분 재생 또는 상태 스냅숏 배열.
- 로그 JSON 내보내기/불러오기: 서버 디스크 저장 형식과 같게 한다. 그러면 실제 세션에서 난 버그 로그를 데모에서 열어 단계별로 볼 수 있고, 이것이 가장 큰 개발 가치다.
- sessionStorage에 로그 저장 후 새로고침·HMR 시 재생.
- 로그에 형식 버전과 엔진 버전 기록: 엔진이 바뀌면 옛 로그가 깨지므로, 재생 실패 시 몇 번째 입력에서 실패했는지 보여 준다.

**2차로 미룰 것:**
- 시나리오: 상태 스냅숏 파일은 상태 스키마가 계속 바뀌는 동안 금방 낡는다. `createGame` config에 덱 순서 고정 옵션을 넣는 방식이 낫다. 엔진에 치트 입력이 필요 없고 순수성도 유지된다. 카드 효과 단계에 들어가면 바로 필요해지므로 2차의 첫 항목이다.
- URL로 전체 로그 공유(압축해서 해시에 넣기): 혼자 쓰는 단계에서는 파일로 충분하다.

## 5. 위험과 함정

- **Node 의존:** `src/game/**`에 `node:` import, `process`, `Buffer`, `fs`가 있으면 안 된다. 시드 생성에 `node:crypto`를 쓰는 곳이 흔한 범인이다. 시드는 호스트가 만들어 config로 넘기고, import 검사 테스트로 강제한다.
- **번들 크기:** 카드 효과 120개는 수십 KB 수준이라 문제가 안 된다. `/demo` 라우트만 동적 import로 분리하면 된다.
- **카드 데이터·이미지:** 카탈로그를 서버가 `catalog` 메시지로 주고 있으므로 로컬 호스트도 같은 메시지를 만들어야 한다. `godot/data/decks.json`을 Vite에서 import할 수 있는지(루트 밖이면 `server.fs.allow`)와, 이미지를 Node 서버가 서빙한다면 서버 없이 어디서 가져올지 확인이 필요하다.
- **빌드:** 1차는 dev 서버 실행으로 충분하다. 정적 빌드 배포는 `vite build`가 dist의 카드 이미지를 지우지 않게 설정한 뒤로 미룬다.
- **경로 분기(가장 큰 위험):** `session.ts`에 "이 자리가 이 입력을 낼 수 있나, requestId가 유효한가, 이벤트와 상태를 어떤 순서로 보내나" 같은 로직이 있으면 로컬 호스트가 다시 구현하면서 갈라진다. 이 부분을 Node 없는 공용 코어로 뽑아 서버와 로컬이 같이 쓴다. 서버에는 ws·토큰·로비·카운트다운·디스크·일시정지만 남긴다.
- **직렬화 차이:** 서버 경로는 JSON을 거치고 로컬은 객체 참조를 넘긴다. `undefined` 필드, Map/Set, UI의 실수 변형이 로컬에서만 통과한다. 로컬 연결도 `JSON.parse(JSON.stringify())`를 거치고 비동기(`queueMicrotask`)로 전달한다.
- **봇 난수:** 봇이 `state.rng`를 쓰면 결정성이 깨진다. 봇은 별도 시드를 쓴다. 로그에는 봇의 입력이 그대로 기록되므로 재생은 봇과 무관하다.
- **합법 행동 목록:** 지금 무작위 플레이 테스트가 이미 어떤 식으로든 합법 입력을 고르고 있을 것이다. 그것을 `legalInputs(state, player)`로 엔진에 정식화하고 플레이어 시점(view)에 `actions`로 싣는다. 어차피 "서버가 합법 행동 목록을 준다"는 예정 항목이라 앞당기는 것뿐이다. 1단계에서는 요청 응답(options에서 min~max개) + `draw` + `endTurn`이면 끝이다.
- **봇 입력은 view만:** 봇은 `state`가 아니라 자기 시점 view만 받는다. 그래야 "규칙을 모르는 폰이 view만으로 행동할 수 있다"는 원칙이 매 판 검증되고, 같은 봇을 나중에 ws 클라이언트로 옮길 수 있다.
- **React 수명:** StrictMode 이중 effect로 게임이 두 번 만들어지지 않게 호스트는 컴포넌트 밖(ref나 모듈)에 둔다.
- **자동 진행 안전장치:** 입력 수 상한을 두고, 엔진 예외 시 자동 정지하며 시드와 로그를 표시한다. 이것이 곧 브라우저 내 퍼징이 된다.

## 6. 최종 추천 설계

**파일 구조**

```
src/game/match.ts        # 공용 코어: 상태+로그, 자리 검증, 시점별 메시지 생성
src/game/bot.ts          # randomBot(view, rng) → Input | null
src/play/transport.ts    # GameConnection 인터페이스 + WsConnection(기존 client.ts에서 분리)
src/play/localHost.ts    # LocalHost: match.ts를 브라우저에서 구동, 데모 제어 API
src/play/Demo.tsx        # /demo 페이지: 데모 바 + GameBoard + 폰 패널 2개
src/play/GameBoard.tsx   # Board.tsx에서 분리 (Lobby는 Board.tsx에 남김)
server/session.ts        # match.ts를 쓰도록 축소
```

**핵심 인터페이스**

```ts
// match.ts — Node·DOM 의존 없음
type Viewer = 0 | 1 | 'board';
interface MatchLog { v: 1; engine: string; config: GameConfig; inputs: Input[] }
interface Match {
  readonly log: MatchLog;
  submit(seat: 0 | 1, input: Input):
    | { ok: true; out: Map<Viewer, ServerMsg[]> }   // events → state 순서 고정
    | { ok: false; error: ServerMsg };
  snapshot(viewer: Viewer): ServerMsg;               // 접속·재접속용 state
}
function createMatch(config: GameConfig, info: Info): Match;
function replayMatch(log: MatchLog, info: Info, upTo?: number): Match;

// transport.ts — 추상화 지점은 프로토콜 메시지 수준
interface GameConnection {
  send(msg: ClientMsg): void;
  subscribe(fn: (msg: ServerMsg) => void): () => void;
  close(): void;
}

// localHost.ts
interface LocalHost {
  connect(viewer: Viewer): GameConnection;   // hello → welcome/catalog/state
  setController(seat: 0 | 1, c: 'human' | 'bot'): void;
  play(): void; pause(): void; step(): void; setSpeed(ms: number): void;
  undo(n?: number): void; restart(seed?: string): void;
  exportLog(): MatchLog; importLog(log: MatchLog): void;
}

// bot.ts
type Bot = (view: PlayerView, rng: () => number) => Input | null;
```

- 추상화는 `GameHost`(상태·입력 수준)가 아니라 트랜스포트 수준에 둔다. UI가 이미 `ClientMsg`/`ServerMsg`에 맞춰 짜여 있어 `useGameClient`가 연결을 주입받기만 하면 Board와 DebugPhone이 수정 없이 돈다.
- 되돌리기 등 데모 제어는 프로토콜 밖의 `LocalHost` 메서드로 둔다. 실행 후에는 모든 연결에 새 `state`를 다시 보낸다.

**작업 순서(1차)**

1. `session.ts`에서 `match.ts`를 추출한다. 기존 서버 테스트가 그대로 통과해야 한다.
2. `legalInputs`를 추가하고 view에 싣는다. `bot.ts`를 만들고 기존 무작위 플레이 테스트를 이 봇으로 교체한다.
3. `transport.ts`를 분리하고 `useGameClient`에 연결을 주입한다.
4. `localHost.ts`와 `Demo.tsx`를 만든다(4절의 1차 항목 포함).

**테스트**

- **동등성 테스트(분기 방지의 핵심):** 같은 시드와 입력열을 실제 ws 서버와 LocalHost에 넣고, 시점별 `ServerMsg` 열이 같은지 비교한다.
- **봇 대 봇:** 시드 N개를 종료까지 돌리며 불변식을 검사한다. 봇은 view만 본다.
- **되돌리기:** `replayMatch(log, n)`의 상태가 n번째 스냅숏과 같은지 확인한다.
- **import 가드:** `src/game/**`에 Node 전용 참조가 없는지 검사한다.
- **UI:** 1차는 수동 확인으로 둔다. `/demo?p1=bot&p2=bot`이 종료까지 가는 스모크 테스트는 나중에 추가한다.

**나중 범위:** 덱 순서 고정과 시나리오, 규칙 기반 봇, 서버에 붙는 ws 봇((b)), URL 공유, 브라우저 내 대량 퍼징 버튼.
