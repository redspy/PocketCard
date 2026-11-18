// PocketCard 게임 서버
//   npm run server                 저장된 세션이 있으면 이어서, 없으면 새 세션
//   npm run server -- --new        새 세션으로 시작 (저장된 게임 버림)
//   옵션: --port 8787  --data .data  --no-beacon
// 웹 게임판: npm run dev:lan 후 태블릿에서 http://<PC 주소>:5173
// 웹 디버그 폰: http://<PC 주소>:5173/dev/phone?p=1  (p=2)
import { readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import type { WebSocket } from 'ws';
import { buildCatalog, cardInfo } from '../src/game/catalog.ts';
import type { RawDecks } from '../src/game/catalog.ts';
import { DEFAULT_PORT } from '../src/game/protocol.ts';
import type { ClientMsg } from '../src/game/protocol.ts';
import { lanAddresses, startBeacon } from './net.ts';
import { Session } from './session.ts';
import type { Conn } from './session.ts';

const ROOT = fileURLToPath(new URL('../', import.meta.url));
const HEARTBEAT_MS = 5000;
const SOLO_IDLE_MS = 6 * 60 * 60 * 1000;   // 아무도 없는 AI 연습 세션은 6시간 뒤 정리

export type ServerOptions = { port?: number; dataDir?: string | null; fresh?: boolean; beacon?: boolean; quiet?: boolean; decksFile?: string; aiDelayMs?: number };

export async function startServer(opts: ServerOptions = {}) {
  const log = (m: string) => { if (!opts.quiet) console.log(`[${new Date().toLocaleTimeString()}] ${m}`); };
  const catalog = buildCatalog(JSON.parse(readFileSync(opts.decksFile ?? join(ROOT, 'godot/data/decks.json'), 'utf8')) as RawDecks);
  const info = cardInfo(catalog, JSON.parse(readFileSync(join(ROOT, 'src/data/rules/cards.json'), 'utf8')));
  const file = opts.dataDir === null ? null : join(opts.dataDir ?? join(ROOT, '.data'), 'session.json');
  if (opts.fresh && file) rmSync(file, { force: true });

  const wss = new WebSocketServer({ port: opts.port ?? DEFAULT_PORT, host: '0.0.0.0' });
  await new Promise<void>((res, rej) => { wss.once('listening', () => res()); wss.once('error', rej); });
  const port = (wss.address() as { port: number }).port;

  let session: Session;
  try {
    session = Session.load({ catalog, info, file, port, log }) ?? new Session({ catalog, info, file, port, log });
  } catch (e) {
    log(`저장된 세션을 불러오지 못해 새로 시작합니다: ${(e as Error).message}`);
    session = new Session({ catalog, info, file, port, log });
  }

  // AI 연습 세션 (게임판 없이 폰 한 대 vs 서버 AI): 플레이어 토큰 → 세션. 메모리에만 둔다.
  const solos = new Map<string, Session>();
  const soloOf = (token: unknown) => (typeof token === 'string' ? solos.get(token) : undefined);
  const pruneSolos = () => {
    for (const [tok, s] of solos) {
      if (s.conns.size === 0 && Date.now() - s.lastActive > SOLO_IDLE_MS) { s.dispose(); solos.delete(tok); }
    }
  };

  let nextId = 1;
  const alive = new WeakMap<WebSocket, boolean>();
  wss.on('connection', (ws, req) => {
    const conn: Conn = {
      id: nextId++, role: null, seat: null,
      send: (msg) => { if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg)); },
      close: () => ws.close(),
    };
    alive.set(ws, true);
    ws.on('pong', () => alive.set(ws, true));
    let cur: Session = session;
    cur.attach(conn);
    ws.on('message', (data) => {
      let msg: ClientMsg;
      try { msg = JSON.parse(String(data)); } catch { conn.send({ t: 'error', code: 'bad_json', message: 'JSON 형식 오류' }); return; }
      // hello 때 어느 세션으로 갈지 정한다: AI 연습(새로 또는 토큰으로 재접속) / 게임판 세션
      if (msg && msg.t === 'hello') {
        let target: Session = session;
        const known = soloOf(msg.token);
        if (known) target = known;
        else if (msg.solo && msg.role === 'player') {
          pruneSolos();
          target = new Session({ catalog, info, file: null, port, log, solo: true, aiDelayMs: opts.aiDelayMs });
          delete msg.token;
        }
        if (target !== cur) { cur.detach(conn); cur = target; cur.attach(conn); }
        cur.handle(conn, msg);
        if (cur.solo && conn.seat === 0 && cur.seats[0].token && !solos.has(cur.seats[0].token)) {
          solos.set(cur.seats[0].token, cur);
          log(`AI 연습 시작 (${cur.seats[0].device || '기기 이름 없음'})`);
        }
        return;
      }
      cur.handle(conn, msg);
    });
    ws.on('close', () => cur.detach(conn));
    ws.on('error', () => {});
    log(`연결 #${conn.id} (${req.socket.remoteAddress})`);
  });

  // 연결 확인: 응답 없는 연결은 끊는다 → 자리는 유지, 재접속 대기
  const hb = setInterval(() => {
    for (const ws of wss.clients) {
      if (!alive.get(ws)) { ws.terminate(); continue; }
      alive.set(ws, false);
      ws.ping();
    }
  }, HEARTBEAT_MS);

  const stopBeacon = opts.beacon === false ? () => {} : startBeacon(() => ({ code: session.code, port, open: session.phase === 'lobby' }));

  const addrs = lanAddresses();
  log(`게임 서버 시작 — 포트 ${port}, 세션 코드 ${session.code}${session.game ? ' (저장된 게임 복원)' : ''}`);
  for (const a of addrs) log(`  ${a.preferred ? '★' : ' '} ${a.address}:${port}  (${a.iface})`);
  log(`  데이터 버전 ${catalog.dataVersion}`);

  return {
    port, session, catalog, info, solos,
    close: async () => {
      clearInterval(hb);
      stopBeacon();
      session.dispose();
      for (const s of solos.values()) s.dispose();
      for (const ws of wss.clients) ws.terminate();
      await new Promise<void>((res) => wss.close(() => res()));
    },
  };
}

// 직접 실행했을 때만 시작
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const args = process.argv.slice(2);
  const val = (name: string) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
  startServer({
    port: val('--port') ? Number(val('--port')) : DEFAULT_PORT,
    dataDir: val('--data') ?? undefined,
    fresh: args.includes('--new'),
    beacon: !args.includes('--no-beacon'),
  }).catch((e) => { console.error(e); process.exit(1); });
}
