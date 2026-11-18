// 한글 공식 이미지 공통 유틸
import { mkdir, writeFile, access } from 'node:fs/promises';

export const KO_BASE = 'https://pokemoncard.co.kr/public-assets/home/data/cards.image_www/data/wmimages/';
export const KO_DIR = new URL('../public/cards/ko/', import.meta.url);

// 세트코드 → 사이트 상의 시리즈 폴더
export function seriesOf(set) {
  if (/^SV/i.test(set)) return 'SV';
  if (/^M/i.test(set)) return 'MEGA';
  if (/^S/i.test(set)) return 'S';
  throw new Error(`알 수 없는 세트 시리즈: ${set} (scripts/ko-source.mjs 의 seriesOf 에 추가)`);
}

export const koUrl = (code) => {
  const set = code.split('_')[0];
  return `${KO_BASE}${seriesOf(set)}/${set}/${code}.webp`;
};

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 파일이 이미 있으면 'skip', 받으면 'ok', 서버에 없으면 'missing' */
export async function download(url, file, { force = false } = {}) {
  if (!force) { try { await access(file); return 'skip'; } catch {} }
  const res = await fetch(url);
  if (res.status === 403 || res.status === 404) return 'missing';
  if (!res.ok) throw new Error(`${res.status} ${url}`);
  await writeFile(file, Buffer.from(await res.arrayBuffer()));
  return 'ok';
}

export async function ensureDirs() {
  await mkdir(KO_DIR, { recursive: true });
  await mkdir(new URL('fixed/', KO_DIR), { recursive: true });
}
