// 카드 규칙 데이터 형식 (src/data/rules/cards.json — scripts/build-card-rules.mjs 가 생성)
// 키는 덱 카드 ID(덱 데이터의 card.id = 덱 원래 인쇄 코드). 인쇄가 달라도 같은 덱 카드면 같은 데이터.

/** 에너지 타입: 풀 R=불꽃 물 번개 초 격투 악 강철 N=드래곤 C=무색 */
export type EType = 'G' | 'R' | 'W' | 'L' | 'P' | 'F' | 'D' | 'M' | 'N' | 'C';
export const TYPE_KO: Record<EType, string> = { G: '풀', R: '불꽃', W: '물', L: '번개', P: '초', F: '격투', D: '악', M: '강철', N: '드래곤', C: '무색' };

export type AttackData = {
  name: string;        // 한글 기술명 (모르면 '')
  nameJa: string;
  cost: EType[];
  damage: number;      // 기본 데미지 (없으면 0)
  op: '' | '+' | '×' | '-';
  text: string;        // 효과 원문 (없으면 '')
};
export type AbilityData = { name: string; nameJa: string; text: string };

export type PokemonData = {
  stage: 0 | 1 | 2;
  from: string | null;   // 진화 전 포켓몬 한글 이름
  hp: number;
  type: EType;
  weak: EType | null;    // 약점 ×2
  resist: EType | null;  // 저항력 −30
  retreat: number;
  rule: null | 'ex' | 'mega';
  tera: boolean;
  future: boolean;
  attacks: AttackData[];
  abilities: AbilityData[];
};

export type CardData = {
  id: string;            // 덱 카드 ID
  name: string;          // 한글 이름 (같은 이름 4장 제한·진화 연결 기준)
  kind: 'pokemon' | 'trainer' | 'energy';
  pokemon?: PokemonData;
  trainer?: 'item' | 'tool' | 'supporter' | 'stadium';
  ace?: boolean;
  energy?: { basic: boolean; type: EType | null };   // 기본 에너지의 타입 (특수 에너지는 null)
  text: string;          // 트레이너스·특수 에너지 효과 원문
  automated?: boolean;   // 효과 자동화 여부 (effects.ts 가 채움)
};

export type CardDB = Record<string, CardData>;

/** 기절 시 상대가 가져가는 사이드 수 (룰 박스) */
export const prizeValue = (c: CardData | undefined): number => (c?.pokemon?.rule === 'mega' ? 3 : c?.pokemon?.rule === 'ex' ? 2 : 1);
