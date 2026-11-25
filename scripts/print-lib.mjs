// 같은 카드의 다른 인쇄(재판)를 찾는 공통 유틸
//  - 한글 코드 ↔ 일본판 카드: 그림(dHash) 비교 (한글판 트레이너스 번호는 일본판과 다를 수 있음)
//  - Limitless 일본판 페이지: 재판 목록 / TCGdex(ja): 레귤레이션 마크·레어도
// upgrade-regulation.mjs, find-prints.mjs 에서 사용
import sharp from 'sharp';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { koUrl, sleep } from './ko-source.mjs';

const ROOT = new URL('../', import.meta.url);
export const P = (p) => new URL(p, ROOT);
export const ALLOWED = ['G', 'H', 'I'];
// 옛 레귤레이션 덱(공식 레시피 그대로 보관)은 레귤레이션과 상관없이 모든 인쇄를 고를 수 있게 한다
export const ANY = '*';
export const DECK_ALLOWED = { giratina: ANY };
export const allowedFor = (deckId) => DECK_ALLOWED[deckId] ?? ALLOWED;
export const regOk = (allowed, reg) => allowed === ANY || allowed.includes(reg);
export const RANK = { D: 0.3, E: 0.4, F: 0.5, G: 1, H: 2, I: 3 };
export const APP_DECKS = ['flareon', 'dragapult', 'charizard', 'gholdengo', 'gardevoir', 'pachirisu', 'umbreon', 'giratina', 'gardevoir23'];
export const MATCH_OK = 34;        // 256비트 중 이 이하이면 같은 카드로 본다
const CACHE = P('.cache/regulation/');
mkdirSync(CACHE, { recursive: true });

const memo = new Map();
export async function fetchBuf(url) {
  if (memo.has(url)) return memo.get(url);
  const key = url.replace(/[^A-Za-z0-9]+/g, '_').slice(-120);
  const f = new URL(key, CACHE);
  let buf = null;
  if (existsSync(f)) buf = readFileSync(f);
  else {
    const r = await fetch(url);
    if (r.ok) { buf = Buffer.from(await r.arrayBuffer()); writeFileSync(f, buf); }
    else writeFileSync(f, Buffer.alloc(0));
    await sleep(120);
  }
  if (buf && buf.length === 0) buf = null;
  memo.set(url, buf);
  return buf;
}
export async function fetchJson(url) { const b = await fetchBuf(url); try { return b ? JSON.parse(b.toString('utf8')) : null; } catch { return null; } }
export async function fetchText(url) { const b = await fetchBuf(url); return b ? b.toString('utf8') : null; }

async function artHash(buf) {
  const img = sharp(buf);
  const { width, height } = await img.metadata();
  const region = { left: Math.round(width * 0.1), top: Math.round(height * 0.12), width: Math.round(width * 0.8), height: Math.round(height * 0.36) };
  const px = await sharp(buf).extract(region).grayscale().resize(17, 16, { fit: 'fill' }).raw().toBuffer();
  const bits = [];
  for (let y = 0; y < 16; y++) for (let x = 0; x < 16; x++) bits.push(px[y * 17 + x] > px[y * 17 + x + 1] ? 1 : 0);
  return bits;
}
export const dist = (a, b) => a.reduce((d, v, i) => d + (v !== b[i]), 0);

export const koCode = (set, num) => `${set}_${String(num).padStart(3, '0')}`;
const jpImg = (s, n) => `https://limitlesstcg.nyc3.cdn.digitaloceanspaces.com/tpc/${s}/${s}_${n}_R_JP_SM.png`;
const hashMemo = new Map();
export async function hashOf(kind, set, num) {
  const k = `${kind}:${set}:${num}`;
  if (hashMemo.has(k)) return hashMemo.get(k);
  let buf = null;
  if (kind === 'ko') {
    const code = koCode(set, num);
    const local = P(`public/cards/ko/${code}.webp`);   // 원본(워터마크 포함) 기준으로 비교
    buf = existsSync(local) ? readFileSync(local) : await fetchBuf(koUrl(code));
  } else buf = await fetchBuf(jpImg(set, num));
  const h = buf ? await artHash(buf).catch(() => null) : null;
  hashMemo.set(k, h);
  return h;
}

// 기준 해시와 가장 닮은 번호를 set 안에서 찾는다 (가까운 번호부터, 충분히 닮으면 중단)
export async function findInSet(kind, set, center, refHash, radius) {
  let best = null;
  const order = [0];
  for (let d = 1; d <= radius; d++) order.push(d, -d);
  for (const off of order) {
    const n = center + off;
    if (n < 1) continue;
    const h = await hashOf(kind, set, n);
    if (!h) continue;
    const d = dist(refHash, h);
    if (!best || d < best.d) best = { num: n, d };
    if (d <= 22) break;
  }
  return best && best.d <= MATCH_OK ? best : null;
}

const regMemo = new Map();
export async function jpInfo(set, num) {
  const id = `${set}-${String(num).padStart(3, '0')}`;
  if (regMemo.has(id)) return regMemo.get(id);
  const j = await fetchJson(`https://api.tcgdex.net/v2/ja/cards/${encodeURIComponent(id)}`);
  const info = j ? { reg: j.regulationMark ?? null, rarity: j.rarity ?? null, name: j.name, official: j.set?.cardCount?.official ?? null } : null;
  regMemo.set(id, info);
  return info;
}

export async function reprints(set, num) {
  const html = await fetchText(`https://limitlesstcg.com/cards/jp/${set}/${num}`);
  if (!html) return [{ set, num }];
  const list = [...new Set([...html.matchAll(/href="\/cards\/jp\/([A-Za-z0-9-]+)\/(\d+)"/g)].map((m) => `${m[1]}|${m[2]}`))]
    .map((s) => { const [a, b] = s.split('|'); return { set: a, num: +b }; });
  return list.length ? list : [{ set, num }];
}

export const isPromo = (s) => /-P$|P$/.test(s) && !/^SV\d/.test(s);
export const KO_WINDOW = (set) => (set === 'MC' ? 45 : 14);

// 그림 비교로 못 찾는 카드의 일본판 대응 (직접 확인)
export const JP_OVERRIDE = { SV8a_200: 'SV8a-200', SV7_130: 'SV7-130', SV8a_179: 'SV8a-163' };

/** 한글 코드 → 일본판 {set, num, d} (없으면 null) */
export async function jpOf(code) {
  if (JP_OVERRIDE[code]) { const [s, n] = JP_OVERRIDE[code].split('-'); return { set: s, num: +n, d: 0 }; }
  const [kset, knumS] = code.split('_');
  const kh = await hashOf('ko', kset, +knumS);
  if (!kh) return null;
  const m = await findInSet('jp', kset, +knumS, kh, KO_WINDOW(kset));
  return m ? { set: kset, num: m.num, d: m.d } : null;
}

/** 일본판 인쇄 → 한글 코드 (없으면 null) */
export async function koOf(set, num) {
  const jh = await hashOf('jp', set, num);
  if (!jh) return null;
  const m = await findInSet('ko', set, num, jh, KO_WINDOW(set));
  return m ? { code: koCode(set, m.num), d: m.d } : null;
}
