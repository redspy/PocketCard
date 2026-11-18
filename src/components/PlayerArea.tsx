import { AnimatePresence, motion } from 'framer-motion';
import { useGame, BENCH_SIZE, type PlayerId } from '../store/gameStore';
import { Card } from './Card';
import { FieldSlot } from './FieldSlot';

export function PlayerArea({ id, flipped }: { id: PlayerId; flipped?: boolean }) {
  const player = useGame((s) => s.players[id]);
  const phase = useGame((s) => s.phase);
  const drawCard = useGame((s) => s.drawCard);
  const drawBonus = useGame((s) => s.drawBonus);
  const takePrize = useGame((s) => s.takePrize);
  const confirmSetup = useGame((s) => s.confirmSetup);
  const prizesLeft = player.prizes.filter(Boolean).length;

  return (
    <section className={`player ${flipped ? 'top' : 'bottom'}`}>
      <div className="field">
        {/* 프라이즈 카드 6장 (뒷면, 게임 중 클릭하면 패로) */}
        <div className="prizes" aria-label={`프라이즈 카드 ${prizesLeft}장 남음`}>
          {player.prizes.map((c, i) => (
            <div key={i} className="prize-slot">
              <AnimatePresence>
                {c && (
                  <motion.button
                    key={c.uid}
                    className="prize card-back"
                    title="프라이즈 카드 가져오기"
                    onClick={() => takePrize(id, i)}
                    initial={{ opacity: 0, scale: 0.6, y: -20 }}
                    animate={{ opacity: 1, scale: 1, y: 0 }}
                    exit={{ opacity: 0, scale: 0.6 }}
                    transition={{ delay: 0.6 + i * 0.08 }}
                  />
                )}
              </AnimatePresence>
            </div>
          ))}
          <div className="prize-label">프라이즈 {prizesLeft}</div>
        </div>

        <div className="mat">
          <FieldSlot owner={id} slot="active" />
          <div className="bench">
            {Array.from({ length: BENCH_SIZE }).map((_, i) => <FieldSlot key={i} owner={id} slot={i} />)}
          </div>
        </div>

        <div className="side">
          <button
            className="deck-pile card-back"
            onClick={() => drawCard(id)}
            disabled={player.deck.length === 0}
            aria-label={`${player.deckName} 덱에서 한 장 뽑기`}
          >
            <span className="count">{player.deck.length}</span>
          </button>
          <div className="deck-label">
            {player.deckName}<br /><small>{phase === 'setup' ? '준비 단계' : '클릭해서 드로우'}</small>
            {player.mulligans > 0 && <div className="note">멀리건 {player.mulligans}회</div>}
            {player.bonusDraws > 0 && (
              <button className="bonus" onClick={() => drawBonus(id)}>
                상대 멀리건 보너스 +{player.bonusDraws}장 뽑기
              </button>
            )}
            {phase === 'setup' && (
              <button className="confirm" onClick={() => confirmSetup(id)} disabled={player.ready || !player.active}>
                {player.ready ? '배치 완료 ✓' : '배치 완료'}
              </button>
            )}
          </div>
        </div>
      </div>
      <div className="hand">
        {player.hand.map((c) => <Card key={c.uid} card={c} owner={id} />)}
        {player.hand.length === 0 && <div className="hand-empty">손패 없음</div>}
      </div>
    </section>
  );
}
