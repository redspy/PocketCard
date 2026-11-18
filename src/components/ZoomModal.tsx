import { AnimatePresence, motion } from 'framer-motion';
import { cardDef } from '../data/cards';
import { useGame } from '../store/gameStore';
import { CardImage } from './CardImage';

// 확대 보기
export function ZoomModal() {
  const card = useGame((s) => s.zoomed);
  const zoom = useGame((s) => s.zoom);
  const def = card ? cardDef(card.cardId) : null;

  return (
    <AnimatePresence>
      {card && def && (
        <motion.div className="zoom-backdrop" onClick={() => zoom(null)}
          initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}>
          <motion.div className="zoom-panel" initial={{ scale: 0.9 }} animate={{ scale: 1 }}
            onClick={(e) => e.stopPropagation()}>
            <h2>{def.nameKo} <small>{def.resolved ? card.cardId : '한글판 미확인'}</small></h2>
            <div className="zoom-image"><CardImage cardKey={card.cardId} /></div>
            <button onClick={() => zoom(null)}>닫기</button>
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
