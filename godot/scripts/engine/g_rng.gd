class_name GRng
## src/game/rng.ts 포팅 — 시드 기반 난수 (sfc32). 상태는 정수 4개 배열 (GameState.rng).
## JS 의 `>>> 0` (32비트 부호 없는 정수) 은 64비트 정수에 & 0xFFFFFFFF 로 맞춘다.

const M := 0xFFFFFFFF

## 32자리 16진수 시드 → 초기 상태 (앞부분 버림으로 섞기)
static func seedRng(seed_hex: String) -> Array:
	var hex := seed_hex.rpad(32, "0").substr(0, 32)
	var s: Array = []
	for i in 4:
		s.append(hex.substr(i * 8, 8).hex_to_int() & M)
	if s.all(func(v): return v == 0):
		s[0] = 0x9e3779b9
	for i in 16:
		nextU32(s)
	return s

## 다음 32비트 정수 (상태를 직접 바꾼다)
static func nextU32(s: Array) -> int:
	var a: int = s[0]
	var b: int = s[1]
	var c: int = s[2]
	var d: int = s[3]
	var t := (((a + b) & M) + d) & M
	s[3] = (d + 1) & M
	s[0] = (b ^ (b >> 9)) & M
	s[1] = (c + ((c << 3) & M)) & M
	var r := (((c << 21) & M) | (c >> 11)) & M
	s[2] = (r + t) & M
	return t

## 0 이상 n 미만 정수 (편향 없는 거절 샘플링)
static func randInt(s: Array, n: int) -> int:
	if n <= 0:
		push_error("randInt: n=%d" % n)
		return 0
	var limit := (0x100000000 / n) * n
	while true:
		var v := nextU32(s)
		if v < limit:
			return v % n
	return 0

## Fisher–Yates 셔플 (배열을 직접 바꾼다)
static func shuffleInPlace(s: Array, arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := randInt(s, i + 1)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp

## 코인: true = 앞면
static func coin(s: Array) -> bool:
	return randInt(s, 2) == 0
