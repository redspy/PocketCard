import { useState, useEffect } from 'react';
import { cardDef, imageCandidates } from '../data/cards';

// fixed/ → 기본 순서로 이미지를 시도하고, 모두 없으면 이름 카드로 표시
export function CardImage({ cardKey, className }: { cardKey: string; className?: string }) {
  const def = cardDef(cardKey);
  const candidates = imageCandidates(cardKey);
  const [idx, setIdx] = useState(0);
  useEffect(() => setIdx(0), [cardKey]);

  if (idx >= candidates.length) {
    return <div className={`no-image ${className ?? ''}`}>{def.nameKo}<small>{def.resolved ? '이미지 없음' : '한글판 미확인'}</small></div>;
  }
  return <img className={className} src={candidates[idx]} alt={def.nameKo} draggable={false} onError={() => setIdx((i) => i + 1)} />;
}
