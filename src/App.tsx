import { LayoutGroup } from 'framer-motion';
import { PlayerArea } from './components/PlayerArea';
import { ZoomModal } from './components/ZoomModal';
import { useGame } from './store/gameStore';

export default function App() {
  const newGame = useGame((s) => s.newGame);
  const message = useGame((s) => s.message);
  const phase = useGame((s) => s.phase);
  return (
    <div className="board">
      <header>
        <h1>PocketCard <span className={`phase ${phase}`}>{phase === 'setup' ? '준비 단계' : '게임 진행'}</span></h1>
        <button onClick={newGame}>새 게임</button>
      </header>
      {message && <div className="message">{message}</div>}
      <LayoutGroup>
        <PlayerArea id="p2" flipped />
        <div className="divider" />
        <PlayerArea id="p1" />
      </LayoutGroup>
      <ZoomModal />
    </div>
  );
}
