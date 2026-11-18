// 카드/덱 데이터 — 한글판만 사용한다.
// - 덱 리스트 원본: scripts/decklists.txt
// - `npm run resolve-ko` 가 한글판 코드를 찾아 src/data/resolved.json 을 만들고 이미지를 받는다.
// - 한글판 코드를 못 찾은 카드는 'unresolved:<영문 세트-번호>' 키로 남아 이름만 표시된다.
import resolved from './resolved.json';
import { KO_NAMES } from './names';

export interface CardDef {
  key: string;          // 한글판 코드(예: SV6_081) 또는 unresolved:<ref>
  nameKo: string;
  nameEn: string;       // 참고용 (화면에는 한글명 우선)
  resolved: boolean;
}

interface ResolvedFile {
  decks: { id: string; name: string; note?: string; cards: { count: number; nameEn: string; ref: string }[] }[];
  cards: Record<string, { nameEn: string; ko: string | null }>;
}
const data = resolved as ResolvedFile;

export const CARDS: Record<string, CardDef> = {};
for (const [ref, c] of Object.entries(data.cards)) {
  const key = c.ko ?? `unresolved:${ref}`;
  CARDS[key] = { key, nameEn: c.nameEn, nameKo: (c.ko && KO_NAMES[c.ko]) || c.nameEn, resolved: !!c.ko };
}

export interface DeckDef { id: string; name: string; note?: string; list: Record<string, number> }

export const DECKS: Record<string, DeckDef> = Object.fromEntries(
  data.decks.map((d) => {
    const list: Record<string, number> = {};
    for (const c of d.cards) {
      const ko = data.cards[c.ref]?.ko;
      const key = ko ?? `unresolved:${c.ref}`;
      list[key] = (list[key] ?? 0) + c.count;
    }
    return [d.id, { id: d.id, name: d.name, note: d.note, list }];
  }),
);

export const cardDef = (key: string): CardDef =>
  CARDS[key] ?? { key, nameKo: key, nameEn: key, resolved: false };

/**
 * 표시할 이미지 후보 (앞에서부터 시도, 실패하면 다음 후보):
 *   1) public/cards/ko/fixed/<코드>.png / .webp  — 있으면 우선 사용
 *   2) public/cards/ko/<코드>.webp               — 기본
 */
export const imageCandidates = (key: string): string[] =>
  key.startsWith('unresolved:')
    ? []
    : [`/cards/ko/fixed/${key}.png`, `/cards/ko/fixed/${key}.webp`, `/cards/ko/${key}.webp`];
