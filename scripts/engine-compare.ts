// 엔진 비교 (TS ↔ 앱의 GDScript 엔진): AI 대 AI 를 TS 로 여러 판 돌리며 입력마다 상태·이벤트·보기 지문(md5)을 기록하고,
// Godot 헤드리스로 같은 입력을 GDScript 엔진(godot/scripts/engine)에 넣어 지문이 같은지 확인한다.
// 사용: node scripts/engine-compare.ts [판 수=24] [시작 시드=1] [--random|--mixed] [--full=판번호] [--no-godot] [--all-decks]
//   --random: 무작위 봇 (AI 가 잘 안 쓰는 카드·선택까지 넓게), --mixed: AI·무작위 번갈아
//   --all-decks: playable: false 덱(대전 준비 중)도 포함 — 홀수 판은 그런 덱을 한쪽에 넣어 새 효과를 자주 쓰게 함
//   --full=N : N번째 판은 지문 대신 전체 정규화 문자열을 기록 (어긋난 곳 찾기용, Godot 이 차이 위치를 출력)
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { findGodot } from './find-godot.ts';
import { buildCatalog, buildDeck, cardInfo } from '../src/game/catalog.ts';
import type { RawDecks } from '../src/game/catalog.ts';
import { makeAiBot, randomBot } from '../src/game/bot.ts';
import { Match } from '../src/game/match.ts';
import { seedRng } from '../src/game/rng.ts';
import type { Seat } from '../src/game/types.ts';
import { viewFor } from '../src/game/view.ts';

const ROOT = new URL('../', import.meta.url);
const args = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const N = Number(args[0] ?? 24);
const START = Number(args[1] ?? 1);
const MODE = process.argv.includes('--random') ? 'random' : process.argv.includes('--mixed') ? 'mixed' : 'ai';
const FULL = Number(process.argv.find((a) => a.startsWith('--full='))?.split('=')[1] ?? -1);
const ALL_DECKS = process.argv.includes('--all-decks');
const rawDecks = JSON.parse(readFileSync(new URL('godot/data/decks.json', ROOT), 'utf8')) as RawDecks;
const newIds = rawDecks.decks.filter((d) => d.playable === false).map((d) => d.id);
if (ALL_DECKS) for (const d of rawDecks.decks) delete d.playable;
const catalog = buildCatalog(rawDecks);
const info = cardInfo(catalog, JSON.parse(readFileSync(new URL('src/data/rules/cards.json', ROOT), 'utf8')));
const ids = catalog.decks.map((d) => d.id);

/** 정규화 문자열 (GDScript 쪽 GCompare.canon 과 같은 규칙): 키 정렬, null·undefined 키 생략, 정수만 */
export function canon(v: unknown): string {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') return Number.isInteger(v) ? String(v) : `F${v}`;
  if (typeof v === 'string') return `"${v.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n')}"`;
  if (Array.isArray(v)) return `[${v.map(canon).join(',')}]`;
  const o = v as Record<string, unknown>;
  const keys = Object.keys(o).filter((k) => o[k] !== undefined && o[k] !== null).sort();
  return `{${keys.map((k) => `${canon(k)}:${canon(o[k])}`).join(',')}}`;
}
const md5 = (s: string) => createHash('md5').update(s, 'utf8').digest('hex');

type Step = { seat: Seat; input: unknown; view: string; state: string; events: string };
const games: { seed: string; bot: string; decks: [string, string]; init: { state: string; events: string }; steps: Step[] }[] = [];
for (let g = 0; g < N; g++) {
  const seedNum = START + g;
  const seed = seedNum.toString(16).padStart(32, '0');
  const d1 = ids[g % ids.length];
  const d2 = ALL_DECKS && newIds.length && g % 2 ? newIds[Math.floor(g / 2) % newIds.length] : ids[(g + 1 + Math.floor(g / ids.length)) % ids.length];
  const m = new Match({ seed, players: [{ deckId: d1, cards: buildDeck(catalog, d1) }, { deckId: d2, cards: buildDeck(catalog, d2) }] }, info);
  const kind = MODE === 'mixed' ? (g % 2 ? 'random' : 'ai') : MODE;
  const ai = kind === 'random' ? randomBot : makeAiBot(catalog, info.db);
  const rng = seedRng(seed.split('').reverse().join(''));
  const full = g === FULL;
  const h = (x: unknown) => (full ? canon(x) : md5(canon(x)));
  const game = { seed, bot: kind, decks: [d1, d2] as [string, string], init: { state: h(m.state), events: h(m.lastEvents) }, steps: [] as Step[] };
  for (let i = 0; i < 4000 && m.state.phase !== 'ended'; i++) {
    const s = m.state;
    const req = s.requests.find((r) => r.kind !== 'ackReveal') ?? s.requests[0];
    const seat: Seat = req ? req.player : (s.turnPlayer ?? 0);
    const view = JSON.parse(JSON.stringify(viewFor(s, seat, info)));
    const input = ai(view, rng);
    if (!input) throw new Error(`봇이 할 일을 못 찾음: 판 ${g} 입력 ${i}`);
    const r = m.submit(seat, input);
    if (!r.ok) throw new Error(`입력 거절: 판 ${g} 입력 ${i} ${r.error.message}`);
    game.steps.push({ seat, input, view: h(view), state: h(m.state), events: h(r.events) });
  }
  games.push(game);
}
const cacheDir = fileURLToPath(new URL('.cache/', ROOT));
mkdirSync(cacheDir, { recursive: true });
const file = join(cacheDir, 'engine-compare.json');
writeFileSync(file, JSON.stringify(ALL_DECKS ? { games, allDecks: true } : { games }));
console.log(`TS: ${games.length}판, 입력 ${games.reduce((a, g) => a + g.steps.length, 0)}개 기록 → ${file}`);

if (!process.argv.includes('--no-godot')) {
  const godot = findGodot();
  if (!godot) { console.log('Godot 을 찾지 못해 비교를 건너뜀'); process.exit(0); }
  const out = execFileSync(godot, ['--headless', '--path', fileURLToPath(new URL('godot/', ROOT)), '--', '--engine-compare', file], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
  const lines = out.split(/\r?\n/).filter((l) => l.startsWith('[compare]'));
  console.log(lines.join('\n'));
  const ok = lines.some((l) => l.includes('결과: 일치'));
  process.exitCode = ok ? 0 : 1;
}
