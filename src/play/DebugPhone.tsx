// 폰 화면 (웹): 웹 디버그 폰(/dev/phone?p=1|2) 페이지 + 데모 화면에 들어가는 폰 패널
//  - 패: 큰 카드를 겹쳐 가로 스크롤, 카드를 누르면 그 카드로 할 수 있는 행동
//  - 필드: 포켓몬마다 남은 HP·붙은 카드·특수상태
//  - 선택 요청: 카드 / 포켓몬 / 사이드 / 값 고르기
//  - 기술·특성·후퇴는 위쪽 행동 막대, 턴 종료·항복은 아래
import { useEffect, useMemo, useState } from 'react';
import { defaultServer, store, useGameClient } from './client.ts';
import type { GameClient } from './client.ts';
import { CardBack, CardImg, describe, nameOf, seatName } from './common.tsx';
import type { CatalogDeck } from '../game/catalog.ts';
import type { GameView, MoveView, PlayerView, RequestView, SlotView } from '../game/view.ts';
import './play.css';

export default function DebugPhone() {
  const params = new URLSearchParams(location.search);
  const p = params.get('p') === '2' ? '2' : '1';
  const tokenKey = `pocketcard.debug.token.p${p}`;
  const [server, setServer] = useState(() => store.get(`pocketcard.debug.server.p${p}`) ?? defaultServer());
  const [code, setCode] = useState(() => params.get('code') ?? store.get('pocketcard.debug.code') ?? '');
  const [joined, setJoined] = useState(() => !!store.get(tokenKey));
  const c = useGameClient({ role: 'player', server, code: code || undefined, tokenKey, device: `웹 디버그 폰 ${p}`, enabled: joined });

  if (!joined || c.fatal) {
    return (
      <div className="pc-root dp">
        <h2>디버그 폰 {p}</h2>
        {c.error && <div className="dp-error">{c.error.message}</div>}
        <label>서버 <input value={server} onChange={(e) => setServer(e.target.value)} /></label>
        <label>세션 코드 <input value={code} inputMode="numeric" maxLength={6} onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} /></label>
        <button className="dp-primary" disabled={code.length !== 6} onClick={() => {
          store.set(`pocketcard.debug.server.p${p}`, server); store.set('pocketcard.debug.code', code); store.set(tokenKey, null);
          setJoined(false); setTimeout(() => setJoined(true), 0);
        }}>참가</button>
      </div>
    );
  }
  return <PhonePanel c={c} title={`디버그 폰 ${p}`} onLeave={() => { store.set(tokenKey, null); setJoined(false); }} />;
}

const VALUE_LABEL: Record<string, string> = { first: '선공', second: '후공', ok: '확인', yes: '예', no: '아니오' };
const COND_LABEL: Record<string, string> = { asleep: '잠듦', paralyzed: '마비', confused: '혼란' };

/** 폰 화면 본체 (디버그 폰 페이지와 데모 화면이 같이 씀) */
export function PhonePanel({ c, title, onLeave, compact }: { c: GameClient; title: string; onLeave?: () => void; compact?: boolean }) {
  const [tab, setTab] = useState<'hand' | 'field' | 'discard' | 'log'>('hand');
  const [selected, setSelected] = useState<string | null>(null);
  const [zoom, setZoom] = useState<string | null>(null);
  const seat = c.seat;
  const lobby = c.lobby;
  const view = c.view;
  const me = seat !== null && lobby ? lobby.seats[seat] : null;
  useEffect(() => setSelected(null), [view?.version]);

  const header = (
    <div className="dp-head">
      <b>{title}</b> {seat !== null && <span>· {seatName(seat)}</span>}
      <span className={`pc-chip ${c.status === 'open' ? 'st-ready' : 'st-lost'}`}>{c.status === 'open' ? '연결됨' : '재접속 중…'}</span>
      {lobby?.paused && <span className="pc-chip st-lost">상대 재접속 대기</span>}
    </div>
  );

  // ── 로비
  if (!view || lobby?.phase !== 'game') {
    return (
      <div className={`pc-root dp ${compact ? 'compact' : ''}`}>
        {header}
        {c.error && <div className="dp-error">{c.error.message}</div>}
        <h3>덱 선택</h3>
        <div className="dp-decks">
          {c.decks.map((d) => (
            <button key={d.id} className={`dp-deck ${me?.deckId === d.id ? 'on' : ''}`} disabled={me?.ready} onClick={() => c.send({ t: 'chooseDeck', deckId: d.id })}>
              <CardImg code={d.cover} /> <span>{d.name}</span>
            </button>
          ))}
        </div>
        <button className={`dp-primary ${me?.ready ? 'on' : ''}`} disabled={!me?.deckId} onClick={() => c.send({ t: 'ready', ready: !me?.ready })}>
          {me?.ready ? '✔ 준비 완료 (누르면 해제)' : '준비 완료'}
        </button>
        {lobby?.countdownEndsAt && <p>곧 게임이 시작됩니다…</p>}
        <p className="pc-dim small">상대: {lobby ? (() => { const o = lobby.seats[seat === 0 ? 1 : 0]; return !o.taken ? '대기 중' : o.ready ? '준비 완료' : o.deckName ?? '덱 고르는 중'; })() : ''}</p>
        {onLeave && <button onClick={onLeave}>나가기 (토큰 삭제)</button>}
      </div>
    );
  }

  // ── 게임
  const mine = seat !== null ? view.players[seat] : null;
  const opp = seat !== null ? view.players[seat === 0 ? 1 : 0] : null;
  const myReqs = view.requests.filter((r) => r.player === seat && r.options);
  const waitingOpp = view.requests.filter((r) => r.player !== seat && r.kind !== 'ackReveal');
  const myTurn = view.phase === 'playing' && view.turnPlayer === seat;
  const acts = view.actions ?? [];
  const barActs = acts.filter((a) => ['attack', 'ability', 'retreat', 'stadium'].includes(a.kind));
  const cardActs = selected ? acts.filter((a) => a.card === selected) : [];
  const decks = c.decks;
  const send = (m: MoveView) => { const { player: _p, ...input } = m.input as MoveView['input'] & { player: number }; c.input(input as never); setSelected(null); };

  return (
    <div className={`pc-root dp ${compact ? 'compact' : ''}`}>
      {header}
      <div className="dp-status">
        {view.phase === 'setup' ? '게임 준비 중' : view.phase === 'ended' ? '게임 종료' : myTurn ? `턴 ${view.turnNumber} · 내 차례` : `턴 ${view.turnNumber} · 상대 차례`}
        {mine && <> · 덱 {mine.deckCount} · 사이드 {mine.prizes.filter(Boolean).length}</>}
        {opp && <> · 상대 사이드 {opp.prizes.filter(Boolean).length} · 상대 패 {opp.handCount}</>}
        {myTurn && mine && <div className="dp-flags">
          <span className={mine.flags.energy ? 'used' : ''}>에너지</span><span className={mine.flags.supporter ? 'used' : ''}>서포트</span>
          <span className={mine.flags.retreat ? 'used' : ''}>후퇴</span>
          {mine.effects.some((e) => e.kind === 'itemLock') && <span className="lock">아이템 잠금</span>}
        </div>}
      </div>
      {c.error && Date.now() - c.error.at < 5000 && <div className="dp-error">{c.error.message}</div>}
      {view.result && <div className="dp-result">{view.result.winner === null ? '무승부' : view.result.winner === seat ? '승리!' : '패배'} — {view.result.reason}</div>}
      {myReqs.map((r) => <RequestPanel key={r.id} r={r} view={view} decks={decks} onSubmit={(picks) => c.input({ type: 'choice', requestId: r.id, picks })} onZoom={setZoom} />)}
      {!myReqs.length && waitingOpp.length > 0 && <div className="dp-wait">상대가 고르는 중… ({waitingOpp[0].prompt})</div>}

      {barActs.length > 0 && !myReqs.length && (
        <div className="dp-bar">
          {barActs.map((a, i) => <button key={i} className={a.kind === 'attack' ? 'dp-attack' : ''} onClick={() => send(a)}>{a.label}</button>)}
        </div>
      )}

      <div className="dp-tabs">
        {(['hand', 'field', 'discard', 'log'] as const).map((t) => (
          <button key={t} className={tab === t ? 'on' : ''} onClick={() => setTab(t)}>{{ hand: `패 ${mine?.handCount ?? 0}`, field: '필드', discard: '트래쉬', log: '로그' }[t]}</button>
        ))}
      </div>

      {tab === 'hand' && (
        <>
          <div className="dp-strip">
            {mine?.hand?.map((h) => {
              const can = acts.some((a) => a.card === h.iid);
              return (
                <div key={h.iid} className={`${selected === h.iid ? 'on' : ''} ${can ? 'can' : 'cannot'}`} onClick={() => setSelected(selected === h.iid ? null : h.iid)}>
                  <CardImg code={h.code} name={nameOf(decks, h.code)} />
                </div>
              );
            })}
          </div>
          {selected && (
            <div className="dp-cardacts">
              <b>{nameOf(decks, mine?.hand?.find((h) => h.iid === selected)?.code ?? '')}</b>
              {cardActs.length ? cardActs.map((a, i) => <button key={i} className="dp-primary" onClick={() => send(a)}>{a.label}</button>) : <span className="pc-dim">지금은 쓸 수 없습니다.</span>}
              <button onClick={() => setZoom(mine?.hand?.find((h) => h.iid === selected)?.code ?? null)}>크게 보기</button>
            </div>
          )}
        </>
      )}
      {tab === 'field' && opp && mine && (
        <div className="dp-field">
          {[opp, mine].map((pl) => <FieldRow key={pl.seat} pl={pl} me={pl.seat === seat} decks={decks} onZoom={setZoom} />)}
          {view.stadium && <div className="dp-row"><span className="pc-dim">스타디움</span><CardImg code={view.stadium.code} onClick={() => setZoom(view.stadium!.code)} /></div>}
        </div>
      )}
      {tab === 'discard' && opp && mine && (
        <div>
          {[mine, opp].map((pl) => (
            <div key={pl.seat}>
              <div className="pc-dim">{pl.seat === seat ? '내' : '상대'} 트래쉬 {pl.discard.length}</div>
              <div className="dp-strip small">{[...pl.discard].reverse().map((d) => <div key={d.iid} onClick={() => setZoom(d.code)}><CardImg code={d.code} /></div>)}</div>
            </div>
          ))}
        </div>
      )}
      {tab === 'log' && <ol className="dp-log">{[...c.log].reverse().map((e) => { const d = describe(e, decks); return d ? <li key={e.seq}>{d}</li> : null; })}</ol>}

      <div className="dp-actions">
        <button disabled={!acts.some((a) => a.kind === 'endTurn')} className="dp-primary" onClick={() => { if (compact || confirm('턴을 끝낼까요?')) c.input({ type: 'endTurn' }); }}>턴 종료</button>
        <button disabled={!acts.some((a) => a.kind === 'concede')} onClick={() => { if (confirm('항복할까요?')) c.input({ type: 'concede' }); }}>항복</button>
      </div>
      {zoom && <div className="dp-zoom" onClick={() => setZoom(null)}><CardImg code={zoom} /></div>}
    </div>
  );
}

/** 한 플레이어의 필드 (배틀 + 벤치) */
function FieldRow({ pl, me, decks, onZoom }: { pl: PlayerView; me: boolean; decks: CatalogDeck[]; onZoom: (c: string) => void }) {
  return (
    <div className="dp-fieldrow">
      <div className="pc-dim">{seatName(pl.seat)}{me ? ' (나)' : ''} · 벤치 {pl.bench.length}/{pl.benchMax}</div>
      <div className="dp-row">
        {pl.active ? <SlotTile s={pl.active} decks={decks} active onZoom={onZoom} /> : <div className="pc-slot empty">배틀</div>}
        {pl.bench.map((b) => <SlotTile key={b.sid} s={b} decks={decks} onZoom={onZoom} />)}
      </div>
    </div>
  );
}

export function SlotTile({ s, decks, active, onZoom, onClick, selected }: { s: SlotView; decks: CatalogDeck[]; active?: boolean; onZoom?: (c: string) => void; onClick?: () => void; selected?: boolean }) {
  const topCode = s.stack?.[s.stack.length - 1]?.code;
  const left = s.hp !== null ? s.hp - s.damage : null;
  const cond = [s.cond.rot && COND_LABEL[s.cond.rot], s.cond.poison ? '독' : '', s.cond.burn ? '화상' : ''].filter(Boolean);
  return (
    <div className={`dp-tile ${active ? 'active' : ''} ${selected ? 'on' : ''}`} onClick={onClick ?? (() => topCode && onZoom?.(topCode))}>
      {s.faceDown || !topCode ? <CardBack /> : <CardImg code={topCode} name={nameOf(decks, topCode)} />}
      {left !== null && <span className={`dp-hp ${left <= 50 ? 'low' : ''}`}>{left}/{s.hp}</span>}
      {cond.length > 0 && <span className="dp-cond">{cond.join('·')}</span>}
      {(s.attached?.length ?? 0) > 0 && <div className="dp-att">{s.attached!.map((a) => <CardImg key={a.iid} code={a.code} />)}</div>}
    </div>
  );
}

function RequestPanel({ r, view, decks, onSubmit, onZoom }: { r: RequestView; view: GameView; decks: CatalogDeck[]; onSubmit: (picks: string[]) => void; onZoom: (c: string) => void }) {
  const [picks, setPicks] = useState<string[]>([]);
  useEffect(() => setPicks([]), [r.id]);
  const opts = r.options ?? [];
  const min = r.min ?? 0, max = r.max ?? 0;
  const me = view.players[view.viewer as 0 | 1];
  const codeOf = useMemo(() => {
    const m: Record<string, string> = {};
    for (const c of r.cards ?? []) m[c.iid] = c.code;
    for (const h of me.hand ?? []) m[h.iid] ??= h.code;
    return m;
  }, [r, me.hand]);
  const slots = useMemo(() => {
    const m: Record<string, SlotView> = {};
    for (const p of view.players) for (const s of [p.active, ...p.bench]) if (s) m[s.sid] = s;
    return m;
  }, [view]);
  const toggle = (o: string) => setPicks((ps) => (ps.includes(o) ? ps.filter((x) => x !== o) : max === 1 ? [o] : ps.length < max ? [...ps, o] : ps));
  const reveal = r.revealId ? view.reveals.find((v) => v.id === r.revealId) : null;
  const kind: 'cards' | 'slots' | 'prizes' | 'values' =
    r.kind === 'takePrize' ? 'prizes' : opts.length && opts.every((o) => slots[o]) ? 'slots' : opts.length && opts.every((o) => codeOf[o]) ? 'cards' : 'values';
  // 덱을 보는 효과: 고를 수 없는 카드도 함께 보여줌 (흐리게)
  const shown = kind === 'cards' && r.cards?.length ? r.cards.map((c) => c.iid) : opts;
  const ok = picks.length >= Math.min(min, opts.length) && picks.length <= max;
  return (
    <div className="dp-request">
      <div className="dp-prompt">{r.prompt} {(max > 1 || min === 0) && <span className="pc-dim">({min}~{max}개)</span>}</div>
      {reveal && <div className="dp-strip small">{reveal.cards.map((c, i) => <div key={i} onClick={() => onZoom(c.code)}><CardImg code={c.code} name={nameOf(decks, c.code)} /></div>)}</div>}
      {kind === 'cards' && (
        <div className="dp-strip">
          {shown.map((o) => {
            const can = opts.includes(o);
            return <div key={o} className={`${picks.includes(o) ? 'on' : ''} ${can ? 'can' : 'cannot'}`} onClick={() => can && toggle(o)}><CardImg code={codeOf[o]} name={nameOf(decks, codeOf[o])} />{picks.includes(o) && <span className="dp-check">✔</span>}</div>;
          })}
        </div>
      )}
      {kind === 'slots' && (
        <div className="dp-row wrap">{opts.map((o) => <SlotTile key={o} s={slots[o]} decks={decks} selected={picks.includes(o)} onClick={() => toggle(o)} />)}</div>
      )}
      {kind === 'prizes' && (
        <div className="dp-row wrap">{opts.map((o) => <div key={o} className={`dp-prize ${picks.includes(o) ? 'on' : ''}`} onClick={() => toggle(o)}><CardBack /><span>{Number(o) + 1}</span></div>)}</div>
      )}
      {kind === 'values' && (
        <div className="dp-values">{opts.map((o) => <button key={o} className={picks.includes(o) ? 'on' : ''} onClick={() => (max === 1 && min === 1 ? onSubmit([o]) : toggle(o))}>{r.labels?.[o] ?? VALUE_LABEL[o] ?? o}</button>)}</div>
      )}
      {!(kind === 'values' && max === 1 && min === 1) && <button className="dp-primary" disabled={!ok} onClick={() => { onSubmit(picks); setPicks([]); }}>결정{picks.length ? ` (${picks.length})` : ''}</button>}
    </div>
  );
}
