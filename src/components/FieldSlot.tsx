import { motion } from 'framer-motion';
import { cardDef } from '../data/cards';
import { useGame, type PlayerId, type Slot } from '../store/gameStore';
import { CardImage } from './CardImage';

// 배틀 포켓몬 / 벤치 자리.
// - 선택한 카드가 있으면 클릭으로 배치
// - 준비 단계에서는 상대에게 보이지 않도록 뒷면으로 두고, 양쪽 배치가 끝나면 공개
// - 준비 단계에서 놓인 카드를 클릭하면 패로 되돌림, 공개 후에는 확대
export function FieldSlot({ owner, slot }: { owner: PlayerId; slot: Slot }) {
  const card = useGame((s) => (slot === 'active' ? s.players[owner].active : s.players[owner].bench[slot]));
  const phase = useGame((s) => s.phase);
  const ready = useGame((s) => s.players[owner].ready);
  const canPlace = useGame((s) => s.selected?.player === owner && !card);
  const placeSelected = useGame((s) => s.placeSelected);
  const returnToHand = useGame((s) => s.returnToHand);
  const zoom = useGame((s) => s.zoom);

  const isActive = slot === 'active';
  const hidden = phase === 'setup';

  const onClick = () => {
    if (!card) return placeSelected(owner, slot);
    if (phase === 'setup' && !ready) return returnToHand(owner, slot);
    if (!hidden) zoom(card);
  };

  return (
    <div
      className={`zone ${isActive ? 'active' : 'bench-slot'} ${canPlace ? 'droppable' : ''}`}
      onClick={onClick}
      title={card ? (hidden ? (ready ? '배치 완료 (공개 대기)' : '클릭: 패로 되돌리기') : cardDef(card.cardId).nameKo) : canPlace ? '여기에 놓기' : ''}
    >
      {card ? (
        <motion.div
          key={card.uid}
          layoutId={card.uid}
          className="placed"
          style={{ perspective: 800 }}
        >
          <motion.div
            className="placed-inner"
            initial={false}
            animate={{ rotateY: hidden ? 180 : 0 }}
            transition={{ duration: 0.6, ease: 'easeInOut', delay: hidden ? 0 : (isActive ? 0 : 0.1 + Number(slot) * 0.08) }}
          >
            <div className="card-face front"><CardImage cardKey={card.cardId} /></div>
            <div className="card-face back card-back" />
          </motion.div>
        </motion.div>
      ) : (
        <span>{isActive ? '배틀 포켓몬' : '벤치'}</span>
      )}
    </div>
  );
}
