// 배경 제거(누끼): 가장자리에서 이어진 밝은 무채색 픽셀(흰 배경, 가짜 투명 체크무늬)을 투명하게 만든다.
// 윤곽선으로 둘러싸인 안쪽의 흰색(눈 하이라이트 등)은 가장자리와 이어지지 않으므로 보존된다.
// 사용: node scripts/cutout.mjs <입력> <출력.png> [--tol 40] [--min 190]
import sharp from 'sharp';

const [input, output] = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const opt = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? Number(process.argv[i + 1]) : d; };
const TOL = opt('--tol', 40);   // 채도 허용치 (무채색 판정)
const MIN = opt('--min', 190);  // 밝기 하한
if (!input || !output) { console.log('사용: node scripts/cutout.mjs <입력> <출력.png>'); process.exit(1); }

const { data, info } = await sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
const { width: W, height: H } = info;
const isBg = (i) => {
  const r = data[i], g = data[i + 1], b = data[i + 2];
  return Math.min(r, g, b) >= MIN && Math.max(r, g, b) - Math.min(r, g, b) <= TOL;
};
const seen = new Uint8Array(W * H);
const stack = [];
for (let x = 0; x < W; x++) stack.push(x, (H - 1) * W + x);
for (let y = 0; y < H; y++) stack.push(y * W, y * W + W - 1);
while (stack.length) {
  const p = stack.pop();
  if (seen[p]) continue;
  seen[p] = 1;
  if (!isBg(p * 4)) continue;
  data[p * 4 + 3] = 0;
  const x = p % W, y = (p / W) | 0;
  if (x > 0) stack.push(p - 1);
  if (x < W - 1) stack.push(p + 1);
  if (y > 0) stack.push(p - W);
  if (y < H - 1) stack.push(p + W);
}
// 윤곽선에 둘러싸인 체크무늬 영역도 제거:
// 남은 밝은 무채색 덩어리 중 회색 픽셀(밝기 < 245)이 섞인 것(= 체크무늬)만 지우고,
// 순백색 덩어리(눈 하이라이트 등)는 그대로 둔다.
const comp = new Int32Array(W * H).fill(-1);
for (let s = 0; s < W * H; s++) {
  if (comp[s] !== -1 || data[s * 4 + 3] === 0 || !isBg(s * 4)) continue;
  const pix = [];
  let grey = 0;
  const st = [s];
  comp[s] = s;
  while (st.length) {
    const p = st.pop();
    pix.push(p);
    const i = p * 4;
    if (Math.max(data[i], data[i + 1], data[i + 2]) < 245) grey++;
    const x = p % W, y = (p / W) | 0;
    for (const q of [x > 0 ? p - 1 : -1, x < W - 1 ? p + 1 : -1, y > 0 ? p - W : -1, y < H - 1 ? p + W : -1]) {
      if (q < 0 || comp[q] !== -1 || data[q * 4 + 3] === 0 || !isBg(q * 4)) continue;
      comp[q] = s;
      st.push(q);
    }
  }
  if (pix.length > 60 && grey / pix.length > 0.2) for (const p of pix) data[p * 4 + 3] = 0;
}

// 경계의 밝은 테두리(안티앨리어싱 잔여)를 1px 정리
const alpha = Uint8Array.from({ length: W * H }, (_, p) => data[p * 4 + 3]);
for (let y = 1; y < H - 1; y++) for (let x = 1; x < W - 1; x++) {
  const p = y * W + x;
  if (!alpha[p]) continue;
  const nearClear = !alpha[p - 1] || !alpha[p + 1] || !alpha[p - W] || !alpha[p + W];
  if (nearClear && isBg(p * 4)) data[p * 4 + 3] = 0;
}
await sharp(data, { raw: { width: W, height: H, channels: 4 } }).trim().png().toFile(output);
console.log(`cutout ok → ${output}`);
