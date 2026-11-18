// 게임 상태 · 입력 · 이벤트 타입 (서버 엔진과 웹 클라이언트 공용)
import type { RngState } from './rng.ts';
import type { CardDB } from './cardData.ts';

export type Seat = 0 | 1;
export type Viewer = Seat | 'board';

/** 덱을 이루는 카드 한 종류 (덱 데이터에서 온 것) */
export type DeckCardDef = {
  ruleId: string;   // 덱 카드 ID (같은 카드면 인쇄가 달라도 같음) — 카드 규칙 데이터의 키
  code: string;     // 이 게임에서 쓰는 인쇄 코드 (이미지)
  name: string;
  kind: 'pokemon' | 'trainer' | 'energy';
  basic: boolean;   // 기본 포켓몬
  count: number;
};

export type GameConfig = {
  seed: string;                 // 32자리 16진수
  players: [{ deckId: string; cards: DeckCardDef[] }, { deckId: string; cards: DeckCardDef[] }];
};

/** 엔진이 아는 카드 정보 */
export type CardInfo = { basics: Set<string>; db: CardDB };

/** 카드 개체. iid 는 카드가 구역을 옮길 때마다 새로 발급된다 (비공개 정보 추적 방지). */
export type CardInst = { iid: string; owner: Seat; ruleId: string; code: string };

export type Rot = '' | 'asleep' | 'paralyzed' | 'confused';
export type Conditions = { poison: number; burn: boolean; rot: Rot; paraUntil: number };

/** 포켓몬에 걸린 효과 (벤치로 가거나 진화하면 사라짐) — until: 이 턴 번호가 끝날 때 만료 */
export type SlotEffect = { kind: 'noAttack' | 'noRetreat' | 'reduce30' | 'immuneBasicNonC'; until: number };
/** 플레이어에 걸린 효과 */
export type PlayerEffect = { kind: 'itemLock' | 'boostExV30' | 'boostEx40' | 'brier'; until: number };

/** 필드의 포켓몬 한 마리 */
export type PokemonSlot = {
  sid: string;          // 필드 위치 ID (배틀↔벤치 이동해도 유지, 필드를 떠나면 사라짐)
  stack: string[];      // 포켓몬 카드 iid (아래 = 기본, 위 = 현재 단계)
  attached: string[];   // 에너지·도구 iid
  damage: number;       // 데미지 (10 = 카운터 1개)
  faceDown: boolean;    // 셋업 중 뒷면
  enteredTurn: number;  // 이 단계가 된(나온·진화한) 턴 번호 — 같은 턴에는 진화 불가
  abilityTurn: number;  // 특성("1번") 을 마지막으로 쓴 턴
  cond: Conditions;
  effects: SlotEffect[];
};

export type HiddenZone = 'deck' | 'hand' | 'prizes';
export type PublicZone = 'discard' | 'active' | 'bench' | 'stadium' | 'reveal';
export type Zone = HiddenZone | PublicZone;

export type TurnFlags = { energy: boolean; supporter: boolean; retreat: boolean; stadium: boolean; stadiumUsed: boolean; names: string[] };

export type PlayerState = {
  deckId: string;
  deck: string[];       // iid, [0] = 맨 위
  hand: string[];
  prizes: (string | null)[];  // 6칸, 가져간 칸은 null
  discard: string[];    // [마지막] = 맨 위
  active: PokemonSlot | null;
  bench: PokemonSlot[];
  benchMax: number;
  mulligans: number;
  conceded: boolean;
  turns: number;        // 이 플레이어가 시작한 턴 수 (1 = 자기 첫 턴)
  flags: TurnFlags;     // 이번 턴 사용 기록
  koTurn: number;       // 상대 턴에 이 플레이어의 포켓몬이 기절한 마지막 턴 번호
  effects: PlayerEffect[];
};

export type RequestKind =
  | 'chooseFirst' | 'chooseActive' | 'chooseBench' | 'mulliganDraw' | 'ackReveal'
  | 'pickCards'        // 카드 고르기 (덱·트래쉬·패) — cards 에 코드 포함
  | 'pickSlot'         // 포켓몬 고르기 (sid)
  | 'pickOption'       // 값 고르기 (labels)
  | 'takePrize'        // 사이드 칸 고르기 (칸 번호)
  | 'promote';         // 새 배틀 포켓몬 (벤치 sid)

/** 플레이어에게 보내는 선택 요청 */
export type PendingRequest = {
  id: string;
  player: Seat;
  kind: RequestKind;
  options: string[];    // 고를 수 있는 것 (iid, sid, 칸 번호, 값)
  min: number;
  max: number;
  prompt: string;
  revealId?: string;
  labels?: Record<string, string>;            // 값 → 표시 글자
  cards?: { iid: string; code: string }[];    // 요청한 사람에게만 보이는 카드 (덱 서치 등)
  frame?: string;                             // 이어서 실행할 프레임 id
};

/** 모두에게 공개된 카드 묶음 — 상대가 확인할 때까지 유지 */
export type Reveal = { id: string; owner: Seat; reason: string; cards: { iid: string; code: string }[] };

export type Phase = 'setup' | 'playing' | 'ended';
export type GameResult = { winner: Seat | null; reason: string };

/** 실행 중인 효과·절차 (직렬화 가능). 선택이 필요하면 멈추고 요청을 보낸 뒤, 답이 오면 이어서 실행 */
export type Frame = {
  id: string;
  kind: string;          // 처리기 이름 (frames.ts / effects.ts)
  step: number;
  player: Seat;          // 효과를 쓰는 플레이어
  data: Record<string, unknown>;
  picks?: string[];      // 마지막 요청의 답
};

export type GameState = {
  version: number;
  phase: Phase;
  rng: RngState;
  nextId: number;
  cards: Record<string, CardInst>;
  players: [PlayerState, PlayerState];
  stadium: string | null;
  firstPlayer: Seat | null;
  turnPlayer: Seat | null;
  turnNumber: number;
  requests: PendingRequest[];
  reveals: Reveal[];
  setup: SetupState | null;
  result: GameResult | null;
  eventSeq: number;
  stack: Frame[];        // 위 = 마지막
  inCheckup: boolean;
  using: string[];       // 사용 중인 트레이너스 (효과가 끝나면 트래쉬)
  /** 기술 처리 중: 이 기술로 상대 포켓몬이 기절하면 추가로 가져가는 사이드 (무쇠손 ex, 브라이어) */
  attackCtx: { seat: Seat; sid: string; extraPrizes: number } | null;
};

export type SetupState = {
  step: 'coin' | 'draw' | 'active' | 'bench' | 'prizes' | 'bonus' | 'bonusBench' | 'done';
  coinWinner: Seat;
  activeChosen: [boolean, boolean];
  benchChosen: [boolean, boolean];
  bonusDone: [boolean, boolean];
};

/** 플레이어 입력 (서버가 검증 후 엔진에 넣는다) */
export type GameInput =
  | { type: 'choice'; player: Seat; requestId: string; picks: string[] }
  | { type: 'play'; player: Seat; card: string; target?: string }   // 패의 카드 사용 (포켓몬 내기·진화·에너지·트레이너스)
  | { type: 'retreat'; player: Seat; to: string }
  | { type: 'attack'; player: Seat; index: number }
  | { type: 'ability'; player: Seat; sid: string }
  | { type: 'stadium'; player: Seat }                                 // 스타디움 효과 사용
  | { type: 'endTurn'; player: Seat }
  | { type: 'concede'; player: Seat };

export type ZoneRef = { player: Seat; zone: Zone };

/** 엔진 이벤트 (연출·로그용). 시점별로 걸러서 보낸다. */
export type GameEvent =
  | { seq: number; type: 'move'; card: { iid: string; code: string } | null; from: ZoneRef; to: ZoneRef; faceDown?: boolean }
  | { seq: number; type: 'shuffle'; player: Seat }
  | { seq: number; type: 'coin'; player: Seat; heads: boolean; reason: string }
  | { seq: number; type: 'reveal'; reveal: Reveal }
  | { seq: number; type: 'firstPlayer'; player: Seat }
  | { seq: number; type: 'mulligan'; player: Seat; count: number }
  | { seq: number; type: 'flipUp' }
  | { seq: number; type: 'turnStart'; player: Seat; turnNumber: number }
  | { seq: number; type: 'gameEnd'; result: GameResult }
  | { seq: number; type: 'play'; player: Seat; code: string; what: string }          // 카드 사용 알림 (스포트라이트)
  | { seq: number; type: 'attack'; player: Seat; code: string; name: string; index: number }
  | { seq: number; type: 'ability'; player: Seat; code: string; name: string }
  | { seq: number; type: 'damage'; player: Seat; sid: string; amount: number; counters?: boolean; note?: string }
  | { seq: number; type: 'heal'; player: Seat; sid: string; amount: number }
  | { seq: number; type: 'condition'; player: Seat; sid: string; cond: string; on: boolean }
  | { seq: number; type: 'ko'; player: Seat; code: string; prizes: number }
  | { seq: number; type: 'switch'; player: Seat; from: string; to: string }
  | { seq: number; type: 'note'; text: string };

export type ApplyResult = { state: GameState; events: GameEvent[] };

export class GameError extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}
