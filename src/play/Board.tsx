// 웹 게임판 (테이블에 눕힌 태블릿 기준 "마주 보기")
//  - 로비: 큰 로고, 세션 코드·주소, 두 플레이어 상태(대기/연결/덱/준비)
//  - 게임: 아래 절반 = 플레이어 1, 위 절반 = 플레이어 2 (180° 회전), 가운데 띠는 방향 없는 요소
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { defaultServer, store, useGameClient } from './client.ts';
import { CardBack, CardImg, lastLine, nameOf, seatName } from './common.tsx';
import type { CatalogDeck } from '../game/catalog.ts';
import type { ClientMsg, LobbyInfo, SeatInfo } from '../game/protocol.ts';
import type { GameEvent, Seat } from '../game/types.ts';
import type { GameView, PlayerView, SlotView } from '../game/view.ts';
import './play.css';

export type Layout = 'face' | 'side';

export default function Board() {
  const server = useMemo(defaultServer, []);
  const c = useGameClient({ role: 'board', server, enabled: true });
  const [layout, setLayout] = useState<Layout>(() => (store.get('pocketcard.layout') as Layout) || 'face');
  useEffect(() => store.set('pocketcard.layout', layout), [layout]);

  // 태블릿: 화면 꺼짐 방지
  useEffect(() => {
    let lock: { release(): Promise<void> } | null = null;
    const nav = navigator as Navigator & { wakeLock?: { request(t: 'screen'): Promise<{ release(): Promise<void> }> } };
    const req = () => nav.wakeLock?.request('screen').then((l) => { lock = l; }).catch(() => {});
    req();
    const onVis = () => { if (document.visibilityState === 'visible') req(); };
    document.addEventListener('visibilitychange', onVis);
    return () => { document.removeEventListener('visibilitychange', onVis); lock?.release().catch(() => {}); };
  }, []);

  const lobby = c.lobby;
  if (!lobby) {
    return <div className="pc-root pc-center"><div className="pc-logo">POCKETCARD BATTLE</div><p className="pc-dim">게임 서버({server})에 연결하는 중… <br />PC에서 <code>npm run server</code> 를 실행했는지 확인하세요.</p></div>;
  }
  if (lobby.phase !== 'game' || !c.view) return <Lobby lobby={lobby} decks={c.decks} layout={layout} setLayout={setLayout} send={c.send} error={c.error} />;
  return <GameBoard view={c.view} lobby={lobby} decks={c.decks} line={lastLine(c.log, c.decks)} layout={layout} spot={lastSpot(c.log)} onRematch={lobby.boardAi ? () => c.send({ t: 'rematch' }) : undefined} />;
}

// ───────────────────────── 로비 ─────────────────────────

function Lobby({ lobby, decks, layout, setLayout, send, error }: { lobby: LobbyInfo; decks: CatalogDeck[]; layout: Layout; setLayout: (l: Layout) => void; send: (m: ClientMsg) => void; error: { message: string; at: number } | null }) {
  const [addr, setAddr] = useState(() => store.get('pocketcard.addr') ?? '');
  const shown = lobby.addresses.find((a) => a.address === addr) ?? lobby.addresses[0];
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 200); return () => clearInterval(t); }, []);
  const left = lobby.countdownEndsAt ? Math.max(0, Math.ceil((lobby.countdownEndsAt - now) / 1000)) : null;
  return (
    <div className="pc-root pc-lobby">
      <div className="pc-logo">POCKETCARD BATTLE</div>
      <div className="pc-sub">포켓몬 카드게임 1:1 대전</div>
      <div className="pc-join">
        <div className="pc-qr">QR<br /><small>다음 단계에서 추가</small></div>
        <div>
          <p>앱에서 <b>[게임 참가]</b> → 목록에서 이 게임을 고르세요.</p>
          <div className="pc-code">{lobby.code.slice(0, 3)} {lobby.code.slice(3)}</div>
          <p className="pc-dim">
            주소 {shown ? `${shown.address}:${lobby.port}` : '찾지 못함'}{' '}
            {lobby.addresses.length > 1 && (
              <select value={shown?.address ?? ''} onChange={(e) => { setAddr(e.target.value); store.set('pocketcard.addr', e.target.value); }}>
                {lobby.addresses.map((a) => <option key={a.address} value={a.address}>{a.preferred ? '★ ' : ''}{a.address} ({a.iface})</option>)}
              </select>
            )}
          </p>
          <p className="pc-dim small">연결이 안 되면: Windows 방화벽에서 Node.js 허용, 게스트 Wi-Fi가 아닌지 확인</p>
        </div>
      </div>
      <div className="pc-seats">
        {lobby.seats.map((s) => <SeatCard key={s.seat} s={s} decks={decks} onKick={s.taken && !s.connected && lobby.phase === 'lobby' ? () => send({ t: 'kick', seat: s.seat }) : undefined} />)}
      </div>
      <BoardAi lobby={lobby} decks={decks} send={send} error={error} />
      <div className="pc-status">
        {left !== null ? <span className="pc-countdown">{left}초 뒤 게임 시작</span> : lobby.boardAi ? '플레이어 1이 준비 완료하면 3초 뒤 AI와 게임이 시작됩니다.' : '두 사람 모두 준비 완료하면 3초 뒤 게임이 시작됩니다.'}
      </div>
      <div className="pc-solo">
        폰 없이 혼자 해 보기: <a href="/demo?p1=human&p2=ai">AI와 연습 대전</a> · <a href="/demo?p1=ai&p2=ai&auto=1">AI끼리 관전</a>
      </div>
      <div className="pc-layout">
        화면 배치{' '}
        <button className={layout === 'face' ? 'on' : ''} onClick={() => setLayout('face')}>마주 보기 (눕힌 태블릿)</button>
        <button className={layout === 'side' ? 'on' : ''} onClick={() => setLayout('side')}>나란히 보기 (세운 화면)</button>
      </div>
    </div>
  );
}

const AI_SPEEDS: [string, number][] = [['빠르게', 250], ['보통', 700], ['천천히', 1500]];

/** 플레이어 2 = 서버 AI: 폰 한 대로 게임판 흐름을 시험할 때 */
function BoardAi({ lobby, decks, send, error }: { lobby: LobbyInfo; decks: CatalogDeck[]; send: (m: ClientMsg) => void; error: { message: string; at: number } | null }) {
  const on = !!lobby.boardAi;
  const locked = lobby.phase !== 'lobby';
  const p2Human = !on && lobby.seats[1].taken && lobby.seats[1].connected;
  const set = (m: Partial<Extract<ClientMsg, { t: 'boardAi' }>>) => send({ t: 'boardAi', on, ...m });
  const recentErr = error && Date.now() - error.at < 8000 ? error.message : null;
  return (
    <div className="pc-boardai">
      <label>
        <input type="checkbox" checked={on} disabled={locked || p2Human} onChange={(e) => send({ t: 'boardAi', on: e.target.checked })} />
        {' '}플레이어 2를 AI로 (폰 한 대로 시험)
      </label>
      {on && (
        <>
          {' '}덱{' '}
          <select value={lobby.aiDeck ?? ''} disabled={locked} onChange={(e) => set({ deckId: e.target.value || null })}>
            <option value="">무작위</option>
            {decks.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
          </select>
          {' '}속도{' '}
          <select value={String(AI_SPEEDS.find(([, ms]) => ms === lobby.aiDelayMs)?.[1] ?? lobby.aiDelayMs ?? 700)} onChange={(e) => set({ ms: Number(e.target.value) })} disabled={locked}>
            {AI_SPEEDS.map(([n, ms]) => <option key={ms} value={ms}>{n}</option>)}
            {!AI_SPEEDS.some(([, ms]) => ms === lobby.aiDelayMs) && lobby.aiDelayMs !== undefined && <option value={lobby.aiDelayMs}>{lobby.aiDelayMs}ms</option>}
          </select>
        </>
      )}
      {p2Human && <span className="pc-dim small"> (플레이어 2 자리에 사람이 있음)</span>}
      {recentErr && <div className="pc-err small">{recentErr}</div>}
    </div>
  );
}

function SeatCard({ s, decks, onKick }: { s: SeatInfo; decks: CatalogDeck[]; onKick?: () => void }) {
  const deck = decks.find((d) => d.id === s.deckId);
  const state = !s.taken ? '대기 중' : !s.connected ? '연결 끊김' : s.ready ? '준비 완료' : s.deckId ? '덱 선택함' : '연결됨';
  return (
    <div className={`pc-seat ${s.ready ? 'ready' : ''} ${s.taken && !s.connected ? 'lost' : ''}`}>
      <div className="pc-seat-title">{seatName(s.seat)}</div>
      <div className={`pc-chip st-${!s.taken ? 'wait' : !s.connected ? 'lost' : s.ready ? 'ready' : 'on'}`}>{state}</div>
      <div className="pc-seat-device">{s.device || (s.taken ? '이름 없는 기기' : '')}</div>
      <div className="pc-seat-deck">
        {deck ? <><CardImg code={deck.cover} className="pc-cover" /> <span>{deck.name}</span></> : <span className="pc-dim">덱 미선택</span>}
      </div>
      {onKick && <button className="pc-kick" onClick={() => { if (confirm(`${seatName(s.seat)}(${s.device || '이름 없는 기기'})를 내보내고 자리를 비울까요?`)) onKick(); }}>내보내기 (자리 비우기)</button>}
    </div>
  );
}

// ───────────────────────── 게임판 ─────────────────────────

export function GameBoard({ view, lobby, decks, line, layout, spot, onRematch }: { view: GameView; lobby: LobbyInfo; decks: CatalogDeck[]; line: string; layout: Layout; spot?: GameEvent | null; onRematch?: () => void }) {
  const flip = layout === 'face';
  const [zoom, setZoom] = useState<ZoomInfo | null>(null);
  // 위쪽 절반(플레이어 2)에서 누른 카드는 마주 보기일 때 그쪽 방향으로 확대
  const zoomFor = (seat: Seat) => (z: Omit<ZoomInfo, 'up'>) => setZoom({ ...z, up: flip && seat === 1 });
  const waiting = (seat: Seat) => view.requests.filter((r) => r.player === seat && r.kind !== 'ackReveal');
  // 화면(진영 절반)의 크기에 맞춰 카드가 가장 크게 나오는 배치·크기를 고른다
  const halfRef = useRef<HTMLDivElement>(null);
  const bench = Math.max(view.players[0].benchMax, view.players[1].benchMax, 5);
  const fit = useFit(halfRef, bench);
  const fitStyle = { '--ch': `${fit.ch}px`, '--cw': `${fit.ch * CARD_AR}px`, '--bench-cols': Math.ceil(bench / 2), '--active-scale': fit.active } as React.CSSProperties;
  return (
    <div className={`pc-root pc-board fit-${fit.mode}`} style={fitStyle}>
      <div className={`pc-half top ${flip ? 'flip' : 'mirror'}`}><Side p={view.players[1]} view={view} decks={decks} waiting={waiting(1)} onZoom={zoomFor(1)} /></div>
      <div className="pc-band">
        <div className={`pc-line ${flip ? 'flip' : ''}`}>{line}</div>
        <div className="pc-turn">
          {view.phase === 'playing' && view.turnPlayer !== null
            ? <span className={`pc-arrow ${view.turnPlayer === 1 ? 'up' : 'down'}`}>{view.turnPlayer === 1 ? '▲' : '▼'} 턴 {view.turnNumber}</span>
            : <span className="pc-dim">{view.phase === 'setup' ? '게임 준비 중' : ''}</span>}
        </div>
        <div className="pc-stadium">{view.stadium ? <CardImg code={view.stadium.code} onClick={() => setZoom({ title: '스타디움', main: [view.stadium!.code], up: false })} /> : <div className="pc-slot empty small">스타디움</div>}</div>
        <div className="pc-line">{line}</div>
      </div>
      <div className="pc-half bottom" ref={halfRef}><Side p={view.players[0]} view={view} decks={decks} waiting={waiting(0)} onZoom={zoomFor(0)} /></div>

      <Spotlight ev={spot ?? null} decks={decks} flip={flip} />
      {zoom && <Zoom z={zoom} decks={decks} flip={flip} onFlip={() => setZoom({ ...zoom, up: !zoom.up })} onClose={() => setZoom(null)} onPick={(code) => setZoom({ ...zoom, main: [code], extra: undefined, list: undefined, title: nameOf(decks, code) })} />}
      {view.reveals.length > 0 && (
        <div className="pc-overlay">
          {view.reveals.map((r) => (
            <div key={r.id} className="pc-reveal">
              {[true, false].map((rot) => (
                <div key={String(rot)} className={`pc-reveal-row ${rot && flip ? 'flip' : ''}`}>
                  <div className="pc-reveal-title">{seatName(r.owner)}: {r.reason}</div>
                  <div className="pc-reveal-cards">{r.cards.map((c, i) => <CardImg key={i} code={c.code} name={nameOf(decks, c.code)} />)}</div>
                </div>
              ))}
            </div>
          ))}
        </div>
      )}
      {lobby.paused && <div className="pc-overlay"><Twice flip={flip}>재접속 대기 중… ({lobby.seats.filter((s) => !s.connected).map((s) => seatName(s.seat)).join(', ')})</Twice></div>}
      {view.result && (
        <div className="pc-overlay"><Twice flip={flip}>{view.result.winner === null ? '무승부' : `${seatName(view.result.winner)} 승리!`}<small>{view.result.reason}</small></Twice>
          {onRematch && <button className="pc-rematch" onClick={onRematch}>다시 하기 (대전 준비로)</button>}</div>
      )}
    </div>
  );
}

const CARD_AR = 868 / 1212;
/** 진영 절반 안의 배치 (px). 카드 높이 ch 를 기준으로 너비·높이를 어림한다 */
const FIT = { pad: 10, status: 30, gap: 8, hp: 12, active: 1.12, prizeW: 0.62, pileW: 0.8 };
export type FitMode = 'row' | 'two' | 'three' | 'four';
/** ch: 카드 높이(px), active: 배틀 포켓몬 배율 (세로가 남으면 더 크게) */
export type Fit = { mode: FitMode; ch: number; active: number };
/** 진영 절반(w×h px)에서 카드가 가장 크게 나오는 배치
 *  row  : [사이드][배틀][벤치 n][트래쉬] 한 줄 (가로가 넓은 화면)
 *  two  : 배틀 위 · 벤치 아래, 사이드·트래쉬는 양옆
 *  three: [사이드][배틀][트래쉬] 위 · 벤치 n장은 아래 줄 전체 너비 (좁고 긴 화면)
 *  four : three 와 같되 벤치를 두 줄로 접음 (더 좁고 긴 화면) */
export function fitCards(w: number, h: number, bench: number): Fit {
  const f = FIT;
  const H = h - f.pad * 2 - f.status - f.gap;
  const W = w - f.pad * 2;
  const byW = (units: number, gaps: number) => (W - f.gap * gaps) / units / CARD_AR;   // 가로 units 장(cw 단위)이 들어가는 ch
  const top = f.prizeW + f.active + f.pileW;                                              // [사이드][배틀][트래쉬] 줄
  const k = Math.ceil(bench / 2);
  const cands: Omit<Fit, 'active'>[] = [
    { mode: 'row', ch: Math.min((H - f.hp) / f.active, byW(f.prizeW + f.active + bench + f.pileW + 0.15, bench + 4)) },
    { mode: 'two', ch: Math.min((H - f.gap - f.hp * 2) / (f.active + 1), byW(f.prizeW + bench + f.pileW, bench + 3)) },
    { mode: 'three', ch: Math.min((H - f.gap - f.hp * 2) / (f.active + 1), byW(bench, bench - 1), byW(top, 2)) },
    { mode: 'four', ch: Math.min((H - f.gap * 2 - f.hp * 3) / (f.active + 2), byW(k, k - 1), byW(top, 2)) },
  ];
  // 거의 같으면 앞쪽(단순한) 배치를 쓴다
  let best = cands[0];
  for (const c of cands.slice(1)) if (c.ch > best.ch * 1.04) best = c;
  const ch = Math.max(40, Math.floor(best.ch));
  const cw = ch * CARD_AR;
  // 남는 공간만큼 배틀 포켓몬을 키운다 (1.12 ~ 1.7배)
  const benchRows = best.mode === 'four' ? 2 : best.mode === 'row' ? 0 : 1;
  const rows = benchRows + 1;
  const byH = (H - f.gap * (rows - 1) - f.hp * rows - benchRows * ch) / ch;
  const byWidth = best.mode === 'row'
    ? (W - f.gap * (bench + 4)) / cw - (f.prizeW + bench + f.pileW + 0.15)
    : (W - f.gap * 2) / cw - (f.prizeW + f.pileW);
  const active = Math.round(Math.max(f.active, Math.min(1.7, byH, byWidth)) * 100) / 100;
  return { mode: best.mode, ch, active };
}
function useFit(ref: React.RefObject<HTMLDivElement | null>, bench: number): Fit {
  const [fit, setFit] = useState<Fit>({ mode: 'row', ch: 120, active: 1.12 });
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => {
      const r = el.getBoundingClientRect();
      const next = fitCards(r.width, r.height, bench);
      setFit((cur) => (cur.mode === next.mode && Math.abs(cur.ch - next.ch) < 1 && cur.active === next.active ? cur : next));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [ref, bench]);
  return fit;
}

/** 같은 내용을 양쪽 방향으로 두 번 (마주 보는 두 사람이 모두 읽게) */
function Twice({ children, flip }: { children: React.ReactNode; flip: boolean }) {
  return <div className="pc-twice"><div className={`pc-msg ${flip ? 'flip' : ''}`}>{children}</div><div className="pc-msg">{children}</div></div>;
}

const KIND: Record<string, string> = {
  chooseFirst: '선공/후공 고르는 중', chooseActive: '배틀 포켓몬 고르는 중', chooseBench: '벤치 포켓몬 고르는 중',
  mulliganDraw: '추가 드로우 고르는 중', ackReveal: '공개 카드 확인 중',
};

function Side({ p, view, decks, waiting, onZoom }: { p: PlayerView; view: GameView; decks: CatalogDeck[]; waiting: GameView['requests']; onZoom: ZoomFn }) {
  const mine = view.turnPlayer === p.seat && view.phase === 'playing';
  const slots: (SlotView | null)[] = Array.from({ length: p.benchMax }, (_, i) => p.bench[i] ?? null);
  const prizesLeft = p.prizes.filter(Boolean).length;
  return (
    <div className={`pc-side ${mine ? 'turn' : ''}`}>
      <div className="pc-field">
        {/* 사이드: 뒷면이라 작게 겹쳐 쌓고 남은 장수만 크게 */}
        <div className="pc-prizes" title={`사이드 ${prizesLeft}장`}>
          {Array.from({ length: prizesLeft }, (_, i) => <CardBack key={i} className="pc-prize" />)}
          <b className="pc-count">{prizesLeft}</b>
        </div>
        <div className="pc-active-row"><Slot slot={p.active} decks={decks} big onZoom={onZoom} /></div>
        <div className="pc-bench-row">{slots.map((s, i) => <Slot key={s?.sid ?? `e${i}`} slot={s} decks={decks} onZoom={onZoom} />)}</div>
        <div className="pc-piles">
          <div className="pc-pile discard">
            {p.discard.length ? <CardImg code={p.discard[p.discard.length - 1].code} onClick={() => onZoom({ title: `트래쉬 ${p.discard.length}장`, main: [], list: [...p.discard].reverse().map((d) => d.code) })} /> : <div className="pc-slot empty">트래쉬</div>}
            <b className="pc-count">{p.discard.length}</b>
          </div>
          <div className="pc-pile-row">
            <div className="pc-pile deck">{p.deckCount ? <CardBack /> : <div className="pc-slot empty">덱</div>}<b className="pc-count">{p.deckCount}</b></div>
            {p.lost?.length > 0 && <div className="pc-pile deck"><CardImg code={p.lost[p.lost.length - 1].code} onClick={() => onZoom({ title: `로스트존 ${p.lost.length}장`, main: [], list: [...p.lost].reverse().map((d) => d.code) })} /><b className="pc-count">{p.lost.length}</b></div>}
          </div>
        </div>
      </div>
      <div className="pc-statusbar">
        <b>{seatName(p.seat)}</b>
        {mine && <span className="pc-chip st-ready">내 차례</span>}
        {waiting.map((r) => <span key={r.id} className="pc-chip st-on">{KIND[r.kind] ?? r.kind}</span>)}
        <span className="pc-hand">{Array.from({ length: Math.min(p.handCount, 10) }, (_, i) => <i key={i} />)}</span>
        <span>패 {p.handCount}</span><span>사이드 {prizesLeft}</span><span className="pc-dim">덱 {p.deckCount} · 트래쉬 {p.discard.length}{p.lost?.length ? ` · 로스트 ${p.lost.length}` : ''}</span>
        {p.mulligans > 0 && <span>멀리건 {p.mulligans}</span>}
        {p.gxUsed && <span className="pc-chip">GX 사용함</span>}
        {p.vstarUsed && <span className="pc-chip">VSTAR 사용함</span>}
      </div>
    </div>
  );
}

const COND: Record<string, string> = { asleep: '잠듦', paralyzed: '마비', confused: '혼란' };
function Slot({ slot, decks, big, onZoom }: { slot: SlotView | null; decks: CatalogDeck[]; big?: boolean; onZoom: ZoomFn }) {
  if (!slot) return <div className={`pc-slot empty ${big ? 'big' : ''}`}>{big ? '배틀 포켓몬' : ''}</div>;
  const top = slot.stack?.[slot.stack.length - 1];
  const left = slot.hp !== null ? slot.hp - slot.damage : null;
  const badges = [slot.cond.rot && COND[slot.cond.rot], slot.cond.poison ? '독' : '', slot.cond.burn ? '화상' : '',
    ...slot.effects.map((e) => ({ noAttack: '기술 불가', noRetreat: '후퇴 불가', reduce30: '−30', immuneBasicNonC: '기본 무효', lockAttack: `${e.name ?? '기술'} 불가` }[e.kind]))].filter(Boolean);
  return (
    <div className={`pc-slot ${big ? 'big' : ''} ${top && !slot.faceDown ? 'zoomable' : ''}`} onClick={() => { if (top && !slot.faceDown) onZoom({ title: nameOf(decks, top.code), main: [top.code], extra: [...slot.stack!.slice(0, -1).map((x) => x.code).reverse(), ...(slot.attached ?? []).map((a) => a.code)] }); }}>
      {slot.faceDown || !top ? <CardBack /> : <CardImg code={top.code} name={nameOf(decks, top.code)} />}
      {left !== null && (
        <div className="pc-hpbar"><i style={{ width: `${Math.max(0, Math.min(100, (left / (slot.hp || 1)) * 100))}%` }} className={left <= (slot.hp ?? 0) / 3 ? 'low' : ''} /><b>{left}</b></div>
      )}
      {badges.length > 0 && <div className="pc-badges">{badges.map((b, i) => <span key={i}>{b}</span>)}</div>}
      {(slot.attached?.length ?? 0) > 0 && <div className="pc-attached">{slot.attached!.map((a) => <CardImg key={a.iid} code={a.code} />)}</div>}
    </div>
  );
}

// ───────────────────────── 카드 확대 ─────────────────────────

/** main: 크게 볼 카드, extra: 진화 전·붙은 카드, list: 트래쉬처럼 여러 장 목록 (누르면 그 카드 확대) */
type ZoomInfo = { title: string; main: string[]; extra?: string[]; list?: string[]; up: boolean };
type ZoomFn = (z: Omit<ZoomInfo, 'up'>) => void;

function Zoom({ z, decks, flip, onFlip, onClose, onPick }: { z: ZoomInfo; decks: CatalogDeck[]; flip: boolean; onFlip: () => void; onClose: () => void; onPick: (code: string) => void }) {
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [onClose]);
  return (
    <div className="pc-zoom" onClick={onClose}>
      <div className={`pc-zoom-body ${z.up ? 'flip' : ''}`} onClick={(e) => e.stopPropagation()}>
        <div className="pc-zoom-title">{z.title}</div>
        {z.main.length > 0 && <div className="pc-zoom-main">{z.main.map((c, i) => <CardImg key={i} code={c} name={nameOf(decks, c)} onClick={onClose} />)}</div>}
        {z.extra && z.extra.length > 0 && <div className="pc-zoom-extra">{z.extra.map((c, i) => <CardImg key={i} code={c} name={nameOf(decks, c)} onClick={() => onPick(c)} />)}</div>}
        {z.list && <div className="pc-zoom-list">{z.list.map((c, i) => <CardImg key={i} code={c} name={nameOf(decks, c)} onClick={() => onPick(c)} />)}</div>}
        <div className="pc-zoom-bar">
          {flip && <button onClick={onFlip}>⇅ 방향 바꾸기</button>}
          <button onClick={onClose}>닫기</button>
        </div>
      </div>
    </div>
  );
}

/** 카드 사용·기술 스포트라이트 (2.5초, 양쪽 방향) */
function Spotlight({ ev, decks, flip }: { ev: GameEvent | null; decks: CatalogDeck[]; flip: boolean }) {
  const [shown, setShown] = useState<GameEvent | null>(null);
  useEffect(() => {
    if (!ev) return;
    setShown(ev);
    const t = setTimeout(() => setShown(null), 2500);
    return () => clearTimeout(t);
  }, [ev?.seq]);
  if (!shown || !('code' in shown)) return null;
  const text = shown.type === 'attack' ? `기술 [${shown.name}]` : shown.type === 'ability' ? `특성 [${shown.name}]` : shown.type === 'play' ? shown.what : '';
  const card = <><CardImg code={shown.code} name={nameOf(decks, shown.code)} /><div className="pc-spot-text">{seatName((shown as { player: Seat }).player)} · {nameOf(decks, shown.code)} — {text}</div></>;
  return (
    <div className="pc-spot">
      <div className={`pc-spot-one ${flip ? 'flip' : ''}`}>{card}</div>
      <div className="pc-spot-one">{card}</div>
    </div>
  );
}

/** 스포트라이트로 보여줄 마지막 사건 (카드 사용·기술·특성) */
export function lastSpot(log: GameEvent[]): GameEvent | null {
  for (let i = log.length - 1; i >= 0; i--) { const e = log[i]; if (e.type === 'attack' || e.type === 'ability' || (e.type === 'play' && e.what !== '에너지 붙이기')) return e; }
  return null;
}