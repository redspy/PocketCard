// 웹 화면 캡처 (개발용): Edge/Chrome 헤드리스를 원격 디버깅으로 띄워, 페이지가 실제로 그려질 때까지 기다린 뒤 PNG 저장
// 사용: node scripts/shot.mjs <url> <out.png> [width] [height] [waitMs] [clickSelector...]
//   clickSelector 는 "text=버튼글자" 또는 CSS 선택자. 순서대로 누르고 각 클릭 뒤 waitMs/2 기다림.
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [url, out, w = '1280', h = '800', waitMs = '2500', ...clicks] = process.argv.slice(2);
if (!url || !out) { console.error('사용: node scripts/shot.mjs <url> <out.png> [width] [height] [waitMs] [click...]'); process.exit(1); }

const browsers = [
  process.env.BROWSER,
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
].filter(Boolean);
const exe = browsers.find((b) => existsSync(b));
if (!exe) { console.error('Edge/Chrome 을 찾지 못했습니다 (환경변수 BROWSER 로 지정)'); process.exit(1); }

const profile = mkdtempSync(join(tmpdir(), 'pc-shot-'));
const port = 9300 + Math.floor(Math.random() * 500);
const proc = spawn(exe, ['--headless=new', '--disable-gpu', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, `--window-size=${w},${h}`, 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

try {
  let target = null;
  for (let i = 0; i < 50 && !target; i++) {
    await sleep(200);
    try { const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); target = list.find((t) => t.type === 'page'); } catch { /* 아직 안 뜸 */ }
  }
  if (!target) throw new Error('브라우저 연결 실패');
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r));
  let id = 0;
  const pending = new Map();
  const logs = [];
  ws.addEventListener('message', (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
    if (m.method === 'Runtime.exceptionThrown') logs.push(`예외: ${m.params.exceptionDetails?.exception?.description ?? m.params.exceptionDetails?.text}`);
    if (m.method === 'Runtime.consoleAPICalled' && ['error', 'warning'].includes(m.params.type)) logs.push(`${m.params.type}: ${m.params.args.map((a) => a.value ?? a.description).join(' ')}`);
  });
  const call = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  await call('Runtime.enable');
  await call('Page.enable');
  await call('Emulation.setDeviceMetricsOverride', { width: Number(w), height: Number(h), deviceScaleFactor: 1, mobile: false });
  await call('Page.navigate', { url });
  await sleep(Number(waitMs));
  for (const sel of clicks) {
    const expr = sel.startsWith('text=')
      ? `(() => { const t = ${JSON.stringify(sel.slice(5))}; const el = [...document.querySelectorAll('button, [role=button], .dp-pick, .dp-deck')].find((e) => e.textContent.includes(t) && !e.disabled); if (el) el.click(); return !!el; })()`
      : `(() => { const el = document.querySelector(${JSON.stringify(sel)}); if (el) el.click(); return !!el; })()`;
    const r = await call('Runtime.evaluate', { expression: expr, returnByValue: true });
    if (!r.result?.result?.value) logs.push(`클릭 대상 없음: ${sel}`);
    await sleep(Number(waitMs) / 2);
  }
  const shot = await call('Page.captureScreenshot', { format: 'png' });
  writeFileSync(out, Buffer.from(shot.result.data, 'base64'));
  console.log(`저장: ${out}`);
  for (const l of logs) console.log(l);
  ws.close();
} finally {
  proc.kill();
  await sleep(300);
  try { rmSync(profile, { recursive: true, force: true }); } catch { /* 브라우저가 아직 잡고 있음 */ }
}
