import { motion } from 'framer-motion';
import { cardDef } from '../data/cards';
import { isBasicPokemon } from '../data/basics';
import type { CardInstance } from '../engine/deck';
import { useGame, type PlayerId } from '../store/gameStore';
import { CardImage } from './CardImage';

// 손패의 카드: 뒷면 → 앞면으로 뒤집히며 등장.
// 클릭: 기본 포켓몬이면 선택(배치용), 아니면 확대. 더블클릭: 항상 확대.
export function Card({ card, owner }: { card: CardInstance; owner: PlayerId }) {
  const def = cardDef(card.cardId);
  const zoom = useGame((s) => s.zoom);
  const selectCard = useGame((s) => s.selectCard);
  const selected = useGame((s) => s.selected?.uid === card.uid);
  const basic = isBasicPokemon(card.cardId);

  return (
    <motion.div
      className={`card-slot ${selected ? 'selected' : ''} ${basic ? 'basic' : ''}`}
      layout
      layoutId={card.uid}
      initial={{ y: -160, opacity: 0, scale: 0.8 }}
      animate={{ y: selected ? -14 : 0, opacity: 1, scale: 1 }}
      transition={{ type: 'spring', stiffness: 260, damping: 24 }}
      onClick={() => selectCard(owner, card.uid)}
      onDoubleClick={() => zoom(card)}
      title={`${def.nameKo}${basic ? ' · 기본 포켓몬 (클릭해서 선택)' : ''} · 더블클릭: 확대`}
    >
      <motion.div
        className="card-inner"
        initial={{ rotateY: 180 }}
        animate={{ rotateY: 0 }}
        transition={{ delay: 0.25, duration: 0.5, ease: 'easeInOut' }}
      >
        <div className="card-face front"><CardImage cardKey={card.cardId} /></div>
        <div className="card-face back card-back" />
      </motion.div>
      <div className={`ko-badge ${def.resolved ? '' : 'unverified'}`}>{def.nameKo}</div>
    </motion.div>
  );
}
