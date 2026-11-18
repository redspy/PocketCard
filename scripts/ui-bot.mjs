// UI 봇: 헤드리스 브라우저에서 데모(/demo, 사람 vs AI)를 열고, 사람 자리(P1)를 실제 버튼 클릭으로 끝까지 플레이
//  - 선택 요청이 있으면 선택지 하나 고르고 결정, 없으면 기술 → 패의 카드 행동 → 턴 종료 순으로 클릭
//  - 페이지 예외·콘솔 오류를 모으고, 끝나면 화면을 저장
// 사용: node scripts/ui-bot.mjs [url] [out.png] [최대 클릭 수]
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const url = process.argv[2] ?? 'http://localhost:5173/demo?p1=human&p2=ai&speed=30&d1=charizard&d2=gardevoir&seed=000000000000000000000000000000c1';
const out = process.argv[3] ?? join(tmpdir(), 'ui-bot.png');
const MAX = Number(process.argv[4] ?? 900);
const exe = ['C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', 'C:/Program Files/Microsoft/Edge/Application/msedge.exe', 'C:/Program Files/Google/Chrome/Application/chrome.exe'].find((b) => existsSync(b));
const profile = mkdtempSync(join(tmpdir(), 'pc-uibot-'));
const port = 9800 + Math.floor(Math.random() * 100);
const proc = spawn(exe, ['--headless=new', '--disable-gpu', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--window-size=1600,900', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 페이지 안에서 실행: 사람 자리(왼쪽 폰 패널)에서 할 수 있는 것 하나를 클릭하고 무엇을 했는지 돌려줌
const STEP = `(() => {
  const panel = document.querySelector('.demo-phone');
  if (!panel) return 'no-panel';
  const zoom = document.querySelector('.dp-zoom');
  if (zoom) { zoom.click(); return 'close-zoom'; }
  const result = panel.querySelector('.dp-result');
  if (result) return 'END:' + result.textContent;
  const req = panel.querySelector('.dp-request');
  if (req) {
    const vals = [...req.querySelectorAll('.dp-values button')];
    const cards = [...req.querySelectorAll('.dp-strip:not(.small) > div:not(.cannot)')];
    const tiles = [...req.querySelectorAll('.dp-tile')];
    const prizes = [...req.querySelectorAll('.dp-prize')];
    const ok = [...req.querySelectorAll('button.dp-primary')].pop();
    const prompt = req.querySelector('.dp-prompt')?.textContent ?? '';
    const m = /\\((\\d+)~(\\d+)개\\)/.exec(prompt);
    const need = m ? Math.max(Number(m[1]), Math.min(1, Number(m[2]))) : 1;
    const pool = cards.length ? cards : tiles.length ? tiles : prizes.length ? prizes : [];
    if (!pool.length && vals.length) { vals[0].click(); if (ok && !ok.disabled) ok.click(); return 'value'; }
    const selected = pool.filter((e) => e.classList.contains('on')).length;
    if (selected < need && pool.length > selected) { pool.find((e) => !e.classList.contains('on')).click(); return 'pick'; }
    if (ok && !ok.disabled) { ok.click(); return 'confirm'; }
    if (pool.length) { pool[0].click(); return 'pick2'; }
    return 'stuck-request:' + prompt;
  }
  const atk = [...panel.querySelectorAll('.dp-bar button')].find((b) => b.classList.contains('dp-attack'));
  const hand = [...panel.querySelectorAll('.dp-strip > .can')];
  const acts = [...panel.querySelectorAll('.dp-cardacts button.dp-primary')];
  if (acts.length && !window.__tried?.has(acts[0].textContent)) { (window.__tried ??= new Set()).add(acts[0].textContent); acts[0].click(); return 'cardact:' + acts[0].textContent; }
  const untried = hand.find((h) => !(window.__triedCard ??= new Set()).has(h));
  if (untried && (window.__handTries = (window.__handTries ?? 0) + 1) < 25) { window.__triedCard.add(untried); untried.click(); return 'select-card'; }
  if (atk) { window.__handTries = 0; window.__tried = new Set(); window.__triedCard = new Set(); atk.click(); return 'attack:' + atk.textContent; }
  const end = [...panel.querySelectorAll('.dp-actions button.dp-primary')].find((b) => !b.disabled);
  if (end) { window.__handTries = 0; window.__tried = new Set(); window.__triedCard = new Set(); end.click(); return 'end-turn'; }
  return 'wait';
})()`;

try {
  let target = null;
  for (let i = 0; i < 50 && !target; i++) { await sleep(200); try { target = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((t) => t.type === 'page'); } catch { /* 대기 */ } }
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r));
  let id = 0;
  const pending = new Map();
  const errors = [];
  ws.addEventListener('message', (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
    if (m.method === 'Runtime.exceptionThrown') errors.push(m.params.exceptionDetails?.exception?.description ?? m.params.exceptionDetails?.text);
    if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') errors.push(m.params.args.map((a) => a.value ?? a.description).join(' '));
  });
  const call = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  await call('Runtime.enable');
  await call('Page.enable');
  await call('Emulation.setDeviceMetricsOverride', { width: 1600, height: 900, deviceScaleFactor: 1, mobile: false });
  await call('Page.navigate', { url });
  await sleep(2500);
  const counts = {};
  let last = '', same = 0, end = null;
  for (let i = 0; i < MAX; i++) {
    const r = await call('Runtime.evaluate', { expression: STEP, returnByValue: true });
    const v = String(r.result?.result?.value ?? r.result?.exceptionDetails?.text ?? '?');
    const k = v.split(':')[0];
    counts[k] = (counts[k] ?? 0) + 1;
    if (v.startsWith('END')) { end = v; break; }
    if (v.startsWith('stuck')) { errors.push(v); break; }
    same = v === last && k !== 'wait' ? same + 1 : 0;
    if (same > 30) { errors.push(`같은 동작 반복: ${v}`); break; }
    last = v;
    await sleep(k === 'wait' ? 250 : 120);
  }
  const shot = await call('Page.captureScreenshot', { format: 'png' });
  writeFileSync(out, Buffer.from(shot.result.data, 'base64'));
  console.log('결과:', end ?? '끝나지 않음');
  console.log('동작 수:', JSON.stringify(counts));
  console.log('오류:', errors.length ? errors.slice(0, 8).join('\n  ') : '없음');
  console.log('화면:', out);
  ws.close();
  process.exitCode = end && !errors.length ? 0 : 1;
} finally {
  proc.kill();
  await sleep(300);
  try { rmSync(profile, { recursive: true, force: true }); } catch { /* 잠김 */ }
}
