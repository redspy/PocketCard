// 데모 플레이 (/demo): 서버·폰 없이 브라우저 하나로 게임을 끝까지 진행
//  - 게임판(시점 board) + 플레이어 1·2 폰 패널(각자 시점) — 실제와 같은 시점 필터·UI 코드를 탄다
//  - 자리별 사람/봇, 자동 진행, 되돌리기, 처음부터, 시드 지정, 로그 내보내기/불러오기
//  - URL: /demo?seed=<32hex>&d1=<덱>&d2=<덱>&p1=human|bot&p2=human|bot
import { useEffect, useMemo, useRef, useState } from 'react';
import rawDecks from '../../godot/data/decks.json';
import rawRules from '../data/rules/cards.json';
import type { CardDB } from '../game/cardData.ts';
import { buildCatalog } from '../game/catalog.ts';
import type { RawDecks } from '../game/catalog.ts';
import type { MatchLog } from '../game/match.ts';
import type { Seat } from '../game/types.ts';
import { GameBoard, lastSpot } from './Board.tsx';
import type { Layout } from './Board.tsx';
import { useGameClient } from './client.ts';
import { lastLine, seatName } from './common.tsx';
import { PhonePanel } from './DebugPhone.tsx';
import { LocalHost } from './localHost.ts';
import type { Controller, HostInfo } from './localHost.ts';
import './play.css';

const catalog = buildCatalog(rawDecks as RawDecks);
const db = (rawRules as unknown as { cards: CardDB }).cards;
const LOG_KEY = 'pocketcard.demo.log';
const CTL_LABEL: Record<Controller, string> = { human: '사람', ai: 'AI', bot: '무작위 봇' };
const session = {
  get(): MatchLog | null { try { const s = sessionStorage.getItem(LOG_KEY); return s ? JSON.parse(s) as MatchLog : null; } catch { return null; } },
  set(log: MatchLog) { try { sessionStorage.setItem(LOG_KEY, JSON.stringify(log)); } catch { /* 저장 불가 */ } },
};

// React StrictMode 의 이중 실행에도 게임이 두 번 만들어지지 않게 모듈에 하나만 둔다
let host: LocalHost | null = null;
function getHost(): LocalHost {
  if (host) return host;
  const q = new URLSearchParams(location.search);
  const ctl = (v: string | null, d: Controller): Controller => (v === 'bot' || v === 'human' || v === 'ai' ? v : d);
  const controllers: [Controller, Controller] = [ctl(q.get('p1'), 'human'), ctl(q.get('p2'), 'ai')];
  const ids = catalog.decks.map((d) => d.id);
  const pick = (v: string | null, d: string) => (v && ids.includes(v) ? v : d);
  const decks: [string, string] = [pick(q.get('d1'), 'dragapult'), pick(q.get('d2'), 'gardevoir')];
  const saved = q.get('seed') ? null : session.get();
  try {
    host = saved ? new LocalHost(catalog, db, { log: saved, controllers }) : new LocalHost(catalog, db, { seed: q.get('seed') ?? undefined, decks, controllers });
  } catch {
    host = new LocalHost(catalog, db, { decks, controllers });
  }
  return host;
}

export default function Demo() {
  const h = useMemo(getHost, []);
  const [info, setInfo] = useState<HostInfo>(h.hostInfo);
  const [panels, setPanels] = useState<'both' | 'p1' | 'p2' | 'none'>('both');
  const [layout, setLayout] = useState<Layout>('side');
  const [seedInput, setSeedInput] = useState(info.seed);
  const fileRef = useRef<HTMLInputElement>(null);

  useEffect(() => h.changed.on((i) => { setInfo(i); session.set(h.exportLog()); }), [h]);
  // 1인용(사람 vs AI): 바로 자동 진행 — AI 차례가 오면 알아서 둔다. URL speed=ms 로 속도 지정
  useEffect(() => {
    const q = new URLSearchParams(location.search);
    if (q.get('speed')) h.setSpeed(Number(q.get('speed')));
    const c = h.hostInfo.controllers;
    if ((c.includes('human') && c.some((x) => x !== 'human')) || q.get('auto') === '1') h.play();
  }, [h]);
  useEffect(() => { setSeedInput(info.seed); }, [info.seed]);

  const board = useGameClient({ role: 'board', connect: () => h.connect('board'), connKey: 'demo-board', enabled: true });
  const p1 = useGameClient({ role: 'player', connect: () => h.connect(0), connKey: 'demo-p1', enabled: true });
  const p2 = useGameClient({ role: 'player', connect: () => h.connect(1), connKey: 'demo-p2', enabled: true });

  const view = board.view;
  const waits = (seat: Seat) => !!view?.requests.some((r) => r.player === seat && r.kind !== 'ackReveal') || (view?.phase === 'playing' && view.turnPlayer === seat && !view.requests.length);

  const download = () => {
    const blob = new Blob([JSON.stringify(h.exportLog(), null, 1)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `pocketcard-${info.seed.slice(0, 8)}-${info.inputCount}.json`;
    a.click();
    URL.revokeObjectURL(a.href);
  };
  const load = async (f: File) => { try { h.importLog(JSON.parse(await f.text()) as MatchLog); } catch (e) { alert(`불러오기 실패: ${(e as Error).message}`); } };

  const showP1 = panels === 'both' || panels === 'p1';
  const showP2 = panels === 'both' || panels === 'p2';

  return (
    <div className="pc-root demo">
      <div className="demo-bar">
        <div className="grp"><b>데모</b></div>
        <div className="grp">
          시드 <input className="seed" value={seedInput} onChange={(e) => setSeedInput(e.target.value.replace(/[^0-9a-f]/gi, '').slice(0, 32))} title={info.seed} />
          <button onClick={() => h.restart({ seed: seedInput.padEnd(32, '0') })} title="이 시드로 처음부터">이 시드로</button>
          <button onClick={() => h.restart()}>새 시드</button>
        </div>
        <div className="grp">
          {([0, 1] as Seat[]).map((seat) => (
            <span key={seat}>
              {seatName(seat).replace('플레이어 ', 'P')}{' '}
              <select value={info.decks[seat]} onChange={(e) => { const d = [...info.decks] as [string, string]; d[seat] = e.target.value; h.restart({ seed: info.seed, decks: d }); }}>
                {catalog.decks.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
              </select>{' '}
              <select value={info.controllers[seat]} onChange={(e) => h.setController(seat, e.target.value as Controller)}>
                <option value="human">사람</option><option value="ai">AI</option><option value="bot">무작위 봇</option>
              </select>
            </span>
          ))}
        </div>
        <div className="grp">
          {info.playing ? <button onClick={() => h.pause()}>⏸ 멈춤</button> : <button className="on" onClick={() => h.play()}>▶ 자동</button>}
          <button onClick={() => h.step()} title="봇 입력 하나">한 단계</button>
          <input type="range" min={0} max={1500} step={50} value={info.speedMs} onChange={(e) => h.setSpeed(Number(e.target.value))} title={`${info.speedMs}ms`} />
        </div>
        <div className="grp">
          <button disabled={!info.inputCount} onClick={() => h.undo()}>↶ 되돌리기</button>
          <button disabled={info.inputCount >= info.timelineCount} onClick={() => h.redo()}>↷ 다시</button>
          <button onClick={() => h.goto(0)}>처음부터</button>
          <span className="pc-dim">입력 {info.inputCount}{info.timelineCount > info.inputCount ? ` / ${info.timelineCount}` : ''}</span>
        </div>
        <div className="grp">
          <button onClick={download}>로그 저장</button>
          <button onClick={() => fileRef.current?.click()}>불러오기</button>
          <input ref={fileRef} type="file" accept="application/json" hidden onChange={(e) => { const f = e.target.files?.[0]; if (f) load(f); e.target.value = ''; }} />
        </div>
        <div className="grp">
          폰 <select value={panels} onChange={(e) => setPanels(e.target.value as typeof panels)}>
            <option value="both">둘 다</option><option value="p1">P1만</option><option value="p2">P2만</option><option value="none">숨김</option>
          </select>
          <button className={layout === 'face' ? 'on' : ''} onClick={() => setLayout(layout === 'face' ? 'side' : 'face')} title="위쪽 진영 180° 회전 (실제 마주 보기 확인용)">마주 보기</button>
        </div>
      </div>
      {info.error && <div className="demo-err">{info.error}</div>}
      <div className="demo-main">
        {showP1 && <div className={`demo-phone ${waits(0) ? 'wait' : ''}`}><PhonePanel c={p1} title={`P1 · ${CTL_LABEL[info.controllers[0]]}`} compact /></div>}
        <div className="pc-board-host">
          {view && board.lobby
            ? <GameBoard view={view} lobby={board.lobby} decks={board.decks} line={lastLine(board.log, board.decks)} layout={layout} spot={lastSpot(board.log)} />
            : <div className="pc-root pc-center">불러오는 중…</div>}
        </div>
        {showP2 && <div className={`demo-phone right ${waits(1) ? 'wait' : ''}`}><PhonePanel c={p2} title={`P2 · ${CTL_LABEL[info.controllers[1]]}`} compact /></div>}
      </div>
    </div>
  );
}
