// 게임판·디버그 폰 공용: 카드 이미지, 카드 뒷면, 이벤트 문장
import { useEffect, useState } from 'react';
import type { CatalogDeck } from '../game/catalog.ts';
import type { GameEvent, Seat } from '../game/types.ts';

const candidates = (code: string) => [`/cards/ko/fixed/${code}.png`, `/cards/ko/fixed/${code}.webp`, `/cards/ko/${code}.webp`];

/** 카드 앞면 (fixed → 기본 순서), 없으면 이름 상자 */
export function CardImg({ code, name, className, onClick }: { code: string; name?: string; className?: string; onClick?: () => void }) {
  const list = candidates(code);
  const [i, setI] = useState(0);
  useEffect(() => setI(0), [code]);
  if (i >= list.length) return <div className={`pc-card pc-noimg ${className ?? ''}`} onClick={onClick}>{name ?? code}</div>;
  return <img className={`pc-card ${className ?? ''}`} src={list[i]} alt={name ?? code} draggable={false} onError={() => setI(i + 1)} onClick={onClick} />;
}

export function CardBack({ className }: { className?: string }) {
  return <div className={`pc-card pc-back ${className ?? ''}`} />;
}

export const seatName = (seat: Seat) => `플레이어 ${seat + 1}`;

/** 카드 코드 → 이름 (카탈로그에서 인쇄 코드까지 찾아봄) */
export function nameOf(decks: CatalogDeck[], code: string): string {
  for (const d of decks) for (const c of d.cards) if (c.code === code || c.prints.includes(code)) return c.name;
  return code;
}

const ZONE: Record<string, string> = { deck: '덱', hand: '패', prizes: '사이드', discard: '트래쉬', active: '배틀 필드', bench: '벤치', stadium: '스타디움', reveal: '공개' };

/** 이벤트 → 한 줄 문장 (내 시점으로 걸러진 이벤트 기준) */
export function describe(e: GameEvent, decks: CatalogDeck[]): string | null {
  switch (e.type) {
    case 'move': {
      const who = seatName(e.to.player);
      const card = e.card ? nameOf(decks, e.card.code) : '카드';
      if (e.from.zone === 'deck' && e.to.zone === 'hand') return `${who}: ${e.card ? `${card} ` : ''}드로우`;
      if (e.from.zone === 'deck' && e.to.zone === 'prizes') return null;   // 사이드 배치는 한 줄로 충분
      if (e.faceDown) return `${who}: ${ZONE[e.to.zone]}에 포켓몬을 뒷면으로 놓음`;
      return `${who}: ${card} ${ZONE[e.from.zone]} → ${ZONE[e.to.zone]}`;
    }
    case 'shuffle': return `${seatName(e.player)}: 덱 셔플`;
    case 'coin': return `코인: ${e.heads ? '앞면' : '뒷면'} (${e.reason})`;
    case 'firstPlayer': return `${seatName(e.player)}이(가) 선공`;
    case 'mulligan': return `${seatName(e.player)}: 멀리건 (${e.count}번째)`;
    case 'reveal': return `${seatName(e.reveal.owner)}: 패 공개 — ${e.reveal.reason}`;
    case 'flipUp': return '배틀·벤치 포켓몬을 모두 앞면으로 — 게임 시작';
    case 'turnStart': return `턴 ${e.turnNumber}: ${seatName(e.player)} 차례`;
    case 'gameEnd': return e.result.winner === null ? `게임 종료 — 무승부 (${e.result.reason})` : `게임 종료 — ${seatName(e.result.winner)} 승리 (${e.result.reason})`;
    case 'play': return `${seatName(e.player)}: ${nameOf(decks, e.code)} — ${e.what}`;
    case 'attack': return `${seatName(e.player)}: ${nameOf(decks, e.code)}의 기술 [${e.name}]`;
    case 'ability': return `${seatName(e.player)}: ${nameOf(decks, e.code)}의 특성 [${e.name}]`;
    case 'damage': return e.counters ? `데미지 카운터 ${e.amount / 10}개` : `데미지 ${e.amount}`;
    case 'heal': return `HP ${e.amount} 회복`;
    case 'condition': return `특수상태: ${e.cond}${e.on ? '' : ' 회복'}`;
    case 'ko': return `${seatName(e.player)}의 ${nameOf(decks, e.code)} 기절 — 상대가 사이드 ${e.prizes}장`;
    case 'switch': return `${seatName(e.player)}: 배틀 포켓몬 교체`;
    case 'note': return e.text;
  }
}

export function lastLine(log: GameEvent[], decks: CatalogDeck[]): string {
  for (let i = log.length - 1; i >= 0; i--) { const d = describe(log[i], decks); if (d) return d; }
  return '';
}
