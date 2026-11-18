// 앱 아이콘/시작 화면 이미지 생성
// 사용:
//   npm run godot-icons                       → 기본 디자인(겹친 카드 두 장)
//   npm run godot-icons -- --orb              → 오리지널 구슬 디자인
//   npm run godot-icons -- <이미지 파일 경로>   → 사용자가 준 이미지로 아이콘 생성
//        (png/jpg/webp, 정사각형이 아니면 가운데를 기준으로 잘라 씀)
import sharp from 'sharp';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const out = (f) => fileURLToPath(new URL('../godot/assets/icon/' + f, import.meta.url));

const BG = '#0f3d2e';
// 디자인 선택: --orb (오리지널 구슬)  |  기본: 겹친 카드
const useOrb = process.argv.includes('--orb');
const fileArg = process.argv.slice(2).find((a) => !a.startsWith('--'));
const custom = fileArg ? resolve(fileArg) : null;
if (custom && !existsSync(custom)) {
  console.error(`이미지 파일을 찾을 수 없습니다: ${custom}`);
  process.exit(1);
}

// ── 기본 디자인: 카드 그림 (0~128 좌표계) ──
const cards = `
  <g transform="rotate(-10 64 64)">
    <rect x="30" y="22" width="54" height="76" rx="7" fill="#2b3a8c" stroke="#d8dce8" stroke-width="4"/>
    <path d="M38 34 l38 52 M76 34 l-38 52" stroke="#d8dce8" stroke-opacity=".18" stroke-width="3"/>
  </g>
  <g transform="rotate(8 64 64)">
    <rect x="46" y="28" width="54" height="76" rx="7" fill="#f5c542" stroke="#ffffff" stroke-width="4"/>
    <rect x="54" y="38" width="38" height="30" rx="3" fill="#145a40"/>
    <circle cx="73" cy="53" r="8" fill="#f5c542" opacity=".85"/>
    <rect x="54" y="74" width="38" height="5" rx="2" fill="#145a40" opacity=".6"/>
    <rect x="54" y="84" width="26" height="5" rx="2" fill="#145a40" opacity=".6"/>
  </g>`;
// ── 오리지널 구슬: 초록/금색 반구 + 대각선 띠 + 번개 마크 + 별 보석 ──
const orb = `
  <defs>
    <clipPath id="c"><circle cx="64" cy="64" r="46"/></clipPath>
    <radialGradient id="g1" cx="38%" cy="30%" r="75%"><stop offset="0" stop-color="#3fbf8a"/><stop offset="1" stop-color="#0b4a35"/></radialGradient>
    <radialGradient id="g2" cx="60%" cy="75%" r="75%"><stop offset="0" stop-color="#ffe08a"/><stop offset="1" stop-color="#d99a1e"/></radialGradient>
  </defs>
  <g clip-path="url(#c)">
    <rect width="128" height="128" fill="url(#g2)"/>
    <polygon points="0,0 128,0 128,40 0,88" fill="url(#g1)"/>
    <polygon points="0,80 128,32 128,50 0,98" fill="#1d2433"/>
    <path d="M57 46 L73 46 L64 60 L76 60 L52 86 L60 66 L50 66 Z" fill="#ffe08a" stroke="#1d2433" stroke-width="2.5" stroke-linejoin="round"/>
  </g>
  <circle cx="64" cy="64" r="46" fill="none" stroke="#f4f1e6" stroke-width="5"/>
  <polygon points="92,74 95,82 103,82 97,87 99,95 92,90 85,95 87,87 81,82 89,82" fill="#fff" stroke="#1d2433" stroke-width="2"/>
  <ellipse cx="46" cy="40" rx="10" ry="6" fill="#fff" opacity=".35" transform="rotate(-30 46 40)"/>`;

const svg = (size, { bg = true, scale = 1 } = {}) => Buffer.from(`
<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 128 128">
  ${bg ? `<rect width="128" height="128" rx="24" fill="${BG}"/>` : ''}
  <g transform="translate(64 64) scale(${scale}) translate(-64 -64)">${useOrb ? orb : cards}</g>
</svg>`);

// ── 사용자 이미지 ──
// 투명 배경(누끼) 이미지는 잘리지 않게 전체를 넣고(contain), 불투명 이미지는 정사각형으로 잘라 채운다(cover).
const customHasAlpha = custom ? (await sharp(custom).stats()).isOpaque === false : false;
async function art(size, scale = 1, withBg = false) {
  const inner = Math.round(size * scale);
  const img = await sharp(custom)
    .resize(inner, inner, customHasAlpha
      ? { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } }
      : { fit: 'cover', position: 'centre' })
    .png().toBuffer();
  const bg = withBg ? BG : { r: 0, g: 0, b: 0, alpha: 0 };
  return sharp({ create: { width: size, height: size, channels: 4, background: bg } })
    .composite([{ input: img, gravity: 'centre' }]).png().toBuffer();
}
async function rounded(buf, size) {
  const mask = Buffer.from(`<svg width="${size}" height="${size}"><rect width="${size}" height="${size}" rx="${size * 0.19}" fill="#fff"/></svg>`);
  return sharp(buf).composite([{ input: mask, blend: 'dest-in' }]).png().toBuffer();
}

if (custom) {
  // 192: 둥근 사각형 / 적응형: 전경=이미지(안전 영역 안), 배경=단색 / 시작 화면=이미지
  // 누끼 이미지는 배경색 위에 여백을 두고 배치, 불투명 이미지는 꽉 채움
  const s192 = customHasAlpha ? 0.86 : 1;
  await sharp(await rounded(await art(192, s192, customHasAlpha), 192)).toFile(out('icon_192.png'));
  await sharp(await art(432, customHasAlpha ? 0.62 : 0.72)).toFile(out('adaptive_fg_432.png'));
  await sharp(await art(432, customHasAlpha ? 0.62 : 0.72)).greyscale().toFile(out('adaptive_mono_432.png'));
  await sharp(customHasAlpha ? await art(512, 0.9) : await rounded(await art(512), 512)).toFile(out('../splash.png'));
} else {
  await sharp(svg(192)).png().toFile(out('icon_192.png'));
  await sharp(svg(432, { bg: false, scale: 0.62 })).png().toFile(out('adaptive_fg_432.png'));
  await sharp(svg(432, { bg: false, scale: 0.62 })).png().toFile(out('adaptive_mono_432.png'));
  await sharp(svg(512, { bg: false, scale: 0.9 })).png().toFile(out('../splash.png'));
}
await sharp({ create: { width: 432, height: 432, channels: 4, background: BG } }).png().toFile(out('adaptive_bg_432.png'));
console.log(custom ? `icons ok (이미지: ${custom})` : useOrb ? 'icons ok (오리지널 구슬)' : 'icons ok (기본 디자인)');
