import type { DeckDef } from '../data/cards';
import { isBasicPokemon } from '../data/basics';

export interface CardInstance { uid: string; cardId: string }

let seq = 0;

export function buildDeck(def: DeckDef): CardInstance[] {
  const cards: CardInstance[] = [];
  for (const [cardId, count] of Object.entries(def.list)) {
    for (let i = 0; i < count; i++) cards.push({ uid: `c${++seq}`, cardId });
  }
  return shuffle(cards);
}

// Fisher–Yates
export function shuffle<T>(arr: T[]): T[] {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

export function draw(deck: CardInstance[], n = 1) {
  return { drawn: deck.slice(0, n), deck: deck.slice(n) };
}

export const HAND_SIZE = 7;
export const PRIZE_COUNT = 6;

export interface SetupResult {
  deck: CardInstance[];
  hand: CardInstance[];
  prizes: CardInstance[];
  mulligans: number;            // 기본 포켓몬이 없어 다시 뽑은 횟수
  mulliganHands: CardInstance[][]; // 멀리건으로 공개된 패 (참고용)
}

/**
 * 게임 준비:
 *  1) 덱을 섞고 7장 드로우
 *  2) 패에 기본 포켓몬이 없으면 패를 공개하고 덱에 되돌려 다시 섞은 뒤 7장 드로우 (멀리건)
 *  3) 덱 위에서 6장을 뒷면으로 프라이즈 카드에 놓는다
 */
export function setupPlayer(def: DeckDef): SetupResult {
  const all = buildDeck(def);
  if (!all.some((c) => isBasicPokemon(c.cardId))) {
    throw new Error(`${def.name}: 덱에 기본 포켓몬이 없습니다 (data/basics.ts 확인)`);
  }
  let deck = all;
  let hand: CardInstance[] = [];
  const mulliganHands: CardInstance[][] = [];
  for (;;) {
    ({ drawn: hand, deck } = draw(shuffle(deck), HAND_SIZE));
    if (hand.some((c) => isBasicPokemon(c.cardId))) break;
    mulliganHands.push(hand);
    deck = [...deck, ...hand];
  }
  const { drawn: prizes, deck: rest } = draw(deck, PRIZE_COUNT);
  return { deck: rest, hand, prizes, mulligans: mulliganHands.length, mulliganHands };
}
