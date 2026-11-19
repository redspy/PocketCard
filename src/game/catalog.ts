// 덱 카탈로그: 앱과 같은 덱 데이터(godot/data/decks.json)에서 게임용 덱을 만든다.
// 데이터 버전은 덱 구성(카드 ID·인쇄·장수)으로 계산 → 앱(APK)과 서버의 카드 목록이 다르면 접속을 거절한다.
import type { CardInfo, DeckCardDef } from './types.ts';
import type { CardDB } from './cardData.ts';

type RawPrint = { code: string; reg?: string; special?: boolean };
type RawCard = { id?: string; code: string; name: string; count: number; kind: DeckCardDef['kind']; basic: boolean; prints?: RawPrint[] };
type RawDeck = { id: string; name: string; cover?: string; total: number; cards: RawCard[]; playable?: boolean };
export type RawDecks = { decks: RawDeck[] };

export type CatalogCard = { id: string; code: string; name: string; count: number; kind: DeckCardDef['kind']; basic: boolean; prints: string[] };
export type CatalogDeck = { id: string; name: string; cover: string; cards: CatalogCard[] };

export type Catalog = {
  decks: CatalogDeck[];
  dataVersion: string;
  basics: Set<string>;    // 기본 포켓몬 ruleId
};

/** FNV-1a 32비트 ×2 (브라우저·Node 공용, 암호용 아님) */
function hash(text: string): string {
  let h1 = 0x811c9dc5, h2 = 0x01000193 ^ 0x5bd1e995;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 0x01000193) >>> 0;
    h2 = Math.imul(h2 ^ c, 0x5bd1e995) >>> 0;
  }
  return h1.toString(16).padStart(8, '0') + h2.toString(16).padStart(8, '0');
}

export function buildCatalog(raw: RawDecks): Catalog {
  // playable: false = 덱 뷰어 전용 (대전 규칙 준비 중) — 대전 카탈로그·데이터 버전에서 뺀다
  const decks: CatalogDeck[] = raw.decks.filter((d) => d.playable !== false).map((d) => ({
    id: d.id, name: d.name, cover: d.cover ?? d.cards[0]?.code ?? '',
    cards: d.cards.map((c) => ({
      id: c.id ?? c.code, code: c.code, name: c.name, count: c.count, kind: c.kind, basic: !!c.basic,
      prints: (c.prints?.map((p) => p.code) ?? [c.code]),
    })),
  }));
  const canonical = JSON.stringify(decks.map((d) => [d.id, d.cards.map((c) => [c.id, c.count, c.basic, c.kind, c.prints])]));
  const basics = new Set<string>();
  for (const d of decks) for (const c of d.cards) if (c.basic) basics.add(c.id);
  return { decks, dataVersion: hash(canonical), basics };
}

/** 고른 인쇄를 반영한 게임용 덱. prints: {카드ID: 인쇄코드} (없거나 잘못된 인쇄는 기본 인쇄) */
export function buildDeck(cat: Catalog, deckId: string, prints: Record<string, string> = {}): DeckCardDef[] {
  const d = cat.decks.find((x) => x.id === deckId);
  if (!d) throw new Error(`덱이 없습니다: ${deckId}`);
  return d.cards.map((c) => ({
    ruleId: c.id, code: c.prints.includes(prints[c.id]) ? prints[c.id] : c.code,
    name: c.name, kind: c.kind, basic: c.basic, count: c.count,
  }));
}

/** 엔진에 넘길 카드 정보 (카탈로그 + 카드 규칙 데이터 src/data/rules/cards.json) */
export function cardInfo(cat: Catalog, rules: { cards: CardDB }): CardInfo {
  return { basics: cat.basics, db: rules.cards };
}