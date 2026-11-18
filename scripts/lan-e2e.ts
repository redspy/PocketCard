// 서버 대전 끝-끝 테스트: 실제 게임 서버 + TS AI 상대(플레이어 2) + Godot 앱(플레이어 1, 새 대전 화면 손패 모드)
// 앱은 서버에 참가 → 대전 준비 → 게임 → 화면 조작(ui_tests.gd 의 ui_do)으로 끝까지 → 결과 화면 → 나가기.
// 사용: node scripts/lan-e2e.ts   (Godot 이 없으면 건너뜀)
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { startServer } from '../server/main.ts';
import { makeAiBot, botHasWork } from '../src/game/bot.ts';
import { seedRng } from '../src/game/rng.ts';
import { PROTOCOL_VERSION } from '../src/game/protocol.ts';
import type { ClientMsg, ServerMsg } from '../src/game/protocol.ts';
import type { GameView } from '../src/game/view.ts';
import { findGodot } from './find-godot.ts';

const godot = findGodot();
if (!godot) { console.log('Godot 없음 — 건너뜀'); process.exit(0); }
const PORT = 8795;
const srv = await startServer({ port: PORT, dataDir: null, beacon: false, quiet: true });
const code = srv.session.code;

// 상대: TS AI 클라이언트 (자리가 정해진 뒤 덱 고르고 준비, 게임에서는 메시지가 잠시 멈추면 둔다)
const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
await new Promise((r) => ws.addEventListener('open', r));
const send = (m: ClientMsg) => ws.send(JSON.stringify(m));
const ai = makeAiBot(srv.catalog, srv.info.db);
const rng = seedRng('e2e');
let view: GameView | null = null;
let lastMsg = Date.now();
let lastVer = -1;
let started = false;
ws.addEventListener('message', (ev) => {
  const m = JSON.parse(String(ev.data)) as ServerMsg;
  lastMsg = Date.now();
  if (m.t === 'state') view = m.view;
  if (m.t === 'lobby' && m.lobby.seats[0].taken && !started) {
    started = true;
    send({ t: 'chooseDeck', deckId: 'charizard' });
    setTimeout(() => send({ t: 'ready', ready: true }), 200);
  }
});
send({ t: 'hello', protocol: PROTOCOL_VERSION, role: 'player', code, device: 'e2e-bot', dataVersion: srv.catalog.dataVersion });
// 상대가 먼저 자리를 잡으면 앱이 플레이어 2 가 되므로: 앱이 먼저 오도록 상대 hello 를 늦춤 → 여기서는 서버가 빈 자리 순서로 주므로 앱 자리는 테스트가 읽어서 씀
const timer = setInterval(() => {
  const v = view;
  if (!v || v.result || Date.now() - lastMsg < 60 || v.version === lastVer || !botHasWork(v)) return;
  lastVer = v.version;
  const inp = ai(JSON.parse(JSON.stringify(v)), rng);
  if (inp) send({ t: 'input', input: inp });
}, 20);

const proj = fileURLToPath(new URL('../godot/', import.meta.url));
spawnSync(godot, ['--headless', '--path', proj, '--import'], { stdio: 'ignore' });
// 서버가 같은 프로세스에서 돌아가므로 Godot 은 비동기로 실행 (동기 실행이면 서버가 멈춤)
const out = await new Promise<string>((resolve) => {
  const child = spawn(godot, ['--headless', '--path', proj, '--', '--ui-tests', 'lan', `127.0.0.1:${PORT}`, code]);
  let buf = '';
  child.stdout.on('data', (d) => { buf += d; });
  child.stderr.on('data', (d) => { buf += d; });
  const kill = setTimeout(() => { buf += '\n[ui-tests] 시간 초과'; child.kill(); }, 900000);
  child.on('close', () => { clearTimeout(kill); resolve(buf); });
});
clearInterval(timer);
ws.close();
await srv.close();
const lines = out.split(/\r?\n/).filter((l) => l.startsWith('[ui-tests]') || /SCRIPT ERROR|Parse Error/.test(l));
console.log([...new Set(lines)].slice(0, 40).join('\n'));
const ok = /결과: 통과/.test(out) && !/SCRIPT ERROR|Parse Error/.test(out);
process.exitCode = ok ? 0 : 1;
