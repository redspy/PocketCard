// 시드 기반 난수 (sfc32). 상태를 GameState 안에 숫자 배열로 두어 엔진을 결정적으로 만든다.
// 같은 시드 + 같은 입력이면 항상 같은 셔플·코인 결과 → 리플레이·복원·버그 재현에 사용.

export type RngState = [number, number, number, number];

/** 32자리 16진수 시드 → 초기 상태 (앞부분 버림으로 섞기) */
export function seedRng(seedHex: string): RngState {
  const hex = seedHex.padEnd(32, '0').slice(0, 32);
  const s: RngState = [0, 1, 2, 3].map((i) => parseInt(hex.slice(i * 8, i * 8 + 8), 16) >>> 0) as RngState;
  if (s.every((v) => v === 0)) s[0] = 0x9e3779b9;
  for (let i = 0; i < 16; i++) nextU32(s);
  return s;
}

/** 다음 32비트 정수 (상태를 직접 바꾼다) */
export function nextU32(s: RngState): number {
  const [a, b, c, d] = s;
  const t = (((a + b) >>> 0) + d) >>> 0;
  s[3] = (d + 1) >>> 0;
  s[0] = (b ^ (b >>> 9)) >>> 0;
  s[1] = (c + (c << 3)) >>> 0;
  const r = ((c << 21) | (c >>> 11)) >>> 0;
  s[2] = (r + t) >>> 0;
  return t;
}

/** 0 이상 n 미만 정수 (편향 없는 거절 샘플링) */
export function randInt(s: RngState, n: number): number {
  if (n <= 0) throw new Error(`randInt: n=${n}`);
  const limit = Math.floor(0x100000000 / n) * n;
  for (;;) {
    const v = nextU32(s);
    if (v < limit) return v % n;
  }
}

/** Fisher–Yates 셔플 (배열을 직접 바꾼다) */
export function shuffleInPlace<T>(s: RngState, arr: T[]): void {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = randInt(s, i + 1);
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
}

/** 코인: true = 앞면 */
export const coin = (s: RngState): boolean => randInt(s, 2) === 0;
