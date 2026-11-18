import { create } from 'zustand';
import { DECKS } from '../data/cards';
import { isBasicPokemon } from '../data/basics';
import { draw, setupPlayer, type CardInstance } from '../engine/deck';

export type PlayerId = 'p1' | 'p2';
export type Phase = 'setup' | 'play';
export type Slot = 'active' | number; // number = 벤치 0~4
export const BENCH_SIZE = 5;
const other = (p: PlayerId): PlayerId => (p === 'p1' ? 'p2' : 'p1');

export interface PlayerState {
  deckName: string;
  deck: CardInstance[];
  hand: CardInstance[];
  prizes: (CardInstance | null)[]; // 가져간 자리는 null
  active: CardInstance | null;
  bench: (CardInstance | null)[];
  ready: boolean;      // 준비 단계 배치 완료
  mulligans: number;
  bonusDraws: number;  // 상대 멀리건 횟수만큼 추가로 뽑을 수 있는 장수
}

interface GameState {
  phase: Phase;
  players: Record<PlayerId, PlayerState>;
  selected: { player: PlayerId; uid: string } | null;
  message: string;
  zoomed: CardInstance | null;
  newGame: () => void;
  drawCard: (p: PlayerId) => void;
  drawBonus: (p: PlayerId) => void;
  takePrize: (p: PlayerId, index: number) => void;
  selectCard: (p: PlayerId, uid: string) => void;
  placeSelected: (p: PlayerId, slot: Slot) => void;
  returnToHand: (p: PlayerId, slot: Slot) => void;
  confirmSetup: (p: PlayerId) => void;
  zoom: (c: CardInstance | null) => void;
}

const DECK_OF: Record<PlayerId, string> = { p1: 'dragapult', p2: 'gardevoir' };

const initPlayers = (): Record<PlayerId, PlayerState> => {
  const s = { p1: setupPlayer(DECKS[DECK_OF.p1]), p2: setupPlayer(DECKS[DECK_OF.p2]) };
  const mk = (p: PlayerId): PlayerState => ({
    deckName: DECKS[DECK_OF[p]].name,
    deck: s[p].deck,
    hand: s[p].hand,
    prizes: s[p].prizes,
    active: null,
    bench: Array(BENCH_SIZE).fill(null),
    ready: false,
    mulligans: s[p].mulligans,
    bonusDraws: s[other(p)].mulligans,
  });
  return { p1: mk('p1'), p2: mk('p2') };
};

const SETUP_MSG = '준비 단계: 패에서 기본 포켓몬을 골라 배틀 포켓몬 자리에 1장, 벤치에 최대 5장 놓으세요.';

const drawInto = (pl: PlayerState, n: number): PlayerState => {
  const { drawn, deck } = draw(pl.deck, n);
  return { ...pl, deck, hand: [...pl.hand, ...drawn] };
};

const slotCard = (pl: PlayerState, slot: Slot) => (slot === 'active' ? pl.active : pl.bench[slot]);
const withSlot = (pl: PlayerState, slot: Slot, card: CardInstance | null): PlayerState => {
  if (slot === 'active') return { ...pl, active: card };
  const bench = pl.bench.slice();
  bench[slot] = card;
  return { ...pl, bench };
};

export const useGame = create<GameState>((set) => ({
  phase: 'setup',
  players: initPlayers(),
  selected: null,
  message: SETUP_MSG,
  zoomed: null,

  newGame: () => set({ phase: 'setup', players: initPlayers(), selected: null, message: SETUP_MSG, zoomed: null }),

  drawCard: (p) =>
    set((s) => {
      if (s.phase === 'setup') return { message: '준비 단계에서는 드로우할 수 없습니다. 배치를 먼저 끝내세요.' };
      const pl = s.players[p];
      if (pl.deck.length === 0) return s;
      return { players: { ...s.players, [p]: drawInto(pl, 1) } };
    }),

  drawBonus: (p) =>
    set((s) => {
      const pl = s.players[p];
      if (pl.bonusDraws === 0) return s;
      return { players: { ...s.players, [p]: { ...drawInto(pl, pl.bonusDraws), bonusDraws: 0 } } };
    }),

  takePrize: (p, index) =>
    set((s) => {
      if (s.phase === 'setup') return { message: '준비 단계에서는 프라이즈 카드를 가져올 수 없습니다.' };
      const pl = s.players[p];
      const card = pl.prizes[index];
      if (!card) return s;
      const prizes = pl.prizes.slice();
      prizes[index] = null;
      return { players: { ...s.players, [p]: { ...pl, prizes, hand: [...pl.hand, card] } } };
    }),

  selectCard: (p, uid) =>
    set((s) => {
      const pl = s.players[p];
      const card = pl.hand.find((c) => c.uid === uid);
      if (!card) return s;
      if (s.phase === 'setup' && pl.ready) return { message: '이미 배치를 완료했습니다.' };
      if (!isBasicPokemon(card.cardId)) return { zoomed: card };
      const same = s.selected?.player === p && s.selected.uid === uid;
      return {
        selected: same ? null : { player: p, uid },
        message: same ? s.message : '놓을 자리(배틀 포켓몬 또는 벤치)를 클릭하세요.',
      };
    }),

  placeSelected: (p, slot) =>
    set((s) => {
      const sel = s.selected;
      if (!sel || sel.player !== p) return s;
      let pl = s.players[p];
      if (s.phase === 'setup' && pl.ready) return s;
      const card = pl.hand.find((c) => c.uid === sel.uid);
      if (!card || !isBasicPokemon(card.cardId)) return { selected: null };
      if (slotCard(pl, slot)) return { message: '이미 포켓몬이 있는 자리입니다.' };
      pl = withSlot({ ...pl, hand: pl.hand.filter((c) => c.uid !== card.uid) }, slot, card);
      const msg = !pl.active ? '배틀 포켓몬 자리를 채워야 배치를 완료할 수 있습니다.'
        : s.phase === 'setup' ? '벤치를 더 놓거나 「배치 완료」를 누르세요.' : '';
      return { players: { ...s.players, [p]: pl }, selected: null, message: msg };
    }),

  returnToHand: (p, slot) =>
    set((s) => {
      // 되돌리기는 준비 단계에서만 허용
      if (s.phase !== 'setup') return s;
      const pl = s.players[p];
      if (pl.ready) return s;
      const card = slotCard(pl, slot);
      if (!card) return s;
      return { players: { ...s.players, [p]: withSlot({ ...pl, hand: [...pl.hand, card] }, slot, null) } };
    }),

  confirmSetup: (p) =>
    set((s) => {
      const pl = s.players[p];
      if (!pl.active) return { message: '배틀 포켓몬을 1장 놓아야 합니다.' };
      const players = { ...s.players, [p]: { ...pl, ready: true } };
      const bothReady = players.p1.ready && players.p2.ready;
      return {
        players,
        selected: null,
        phase: bothReady ? 'play' : 'setup',
        message: bothReady ? '양쪽 배치 완료! 배치한 포켓몬을 공개하고 게임을 시작합니다.' : '상대의 배치를 기다리는 중…',
      };
    }),

  zoom: (c) => set({ zoomed: c }),
}));
