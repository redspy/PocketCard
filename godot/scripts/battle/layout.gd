class_name BLayout
## 대전 화면 배치 계산 (순수 함수 — 노드 없이 테스트 가능).
## mode "table": AI 연습 탁자 (위 = 상대, 아래 = 나, 가운데 스타디움 줄, 아래 손패 부채)
## mode "hand" : 서버 대전 손패 화면 (게임판은 웹 — 내 포켓몬 작은 줄 + 큰 손패)
## 반환: { 이름: Rect2 } + "card": 손패 카드 크기(Vector2), "opp_bench"/"my_bench": Rect2 배열, "k": 축소 비율

const R := 1212.0 / 868.0
const PAD := 14.0
const GAP := 8.0

## size: 화면 크기, top/bottom: 안전 영역, opp_bench_max/my_bench_max: 5 또는 8
static func compute(size: Vector2, mode: String, my_bench_max := 5, opp_bench_max := 5, top := 0.0, bottom := 0.0) -> Dictionary:
	if mode == "hand":
		return _hand(size, my_bench_max, top, bottom)
	return _table(size, my_bench_max, opp_bench_max, top, bottom)

## 벤치 카드 폭: 기준 폭과 칸 수에 맞는 폭 중 작은 것
static func bench_w(avail_w: float, n: int, base: float) -> float:
	return minf(base, floorf((avail_w - (n - 1) * GAP) / n))

static func _row_rects(x0: float, y: float, avail_w: float, n: int, w: float) -> Array:
	var total := n * w + (n - 1) * GAP
	var x := x0 + (avail_w - total) / 2.0
	var out: Array = []
	for i in n:
		out.append(Rect2(x + i * (w + GAP), y, w, w * R))
	return out

static func _table(size: Vector2, my_bmax: int, opp_bmax: int, top: float, bottom: float) -> Dictionary:
	var W := size.x
	var aw := W - PAD * 2
	# 기준 크기 (720 폭 기준) — 세로가 모자라면 k 로 줄인다
	var base := {
		"bar": 64.0, "opp_hand": 40.0, "opp_bench": 104.0, "opp_active": 168.0, "mid": 70.0,
		"my_active": 196.0, "my_bench": 130.0, "chips": 44.0, "hand_card": 188.0,
	}
	var scale_w := minf(1.0, W / 720.0)
	var hand_w := func(k: float) -> float: return minf(base.hand_card * k * scale_w, W * 0.36)
	var need := func(k: float) -> float:
		var ob := bench_w(aw, opp_bmax, base.opp_bench * k * scale_w)
		var mb := bench_w(aw, my_bmax, base.my_bench * k * scale_w)
		return base.bar + base.opp_hand * k + ob * R + base.opp_active * k * scale_w * R + base.mid * k \
			+ base.my_active * k * scale_w * R + mb * R + base.chips * k + hand_w.call(k) * R * 0.72 + GAP * 9
	var avail := size.y - top - bottom
	var k := 1.0
	while k > 0.5 and need.call(k) > avail:
		k -= 0.02
	# 세로가 남으면 간격 대신 카드를 키운다 (배틀 포켓몬이 양옆 사이드·덱 더미와 겹치지 않는 한도, 최대 1.8배)
	var max_active := W - 2.0 * (PAD + 96.0 + GAP)
	while k < 1.8 and need.call(k + 0.02) + 90.0 <= avail and base.my_active * (k + 0.02) * scale_w <= max_active:
		k += 0.02
	var extra := maxf(0.0, avail - need.call(k))
	var gap := GAP + extra / 9.0
	var out := { "k": k, "mode": "table" }
	var y := top
	out["bar"] = Rect2(0, y, W, base.bar)
	y += base.bar + gap
	out["opp_hand"] = Rect2(PAD, y, aw, base.opp_hand * k)
	y += base.opp_hand * k + gap
	var ob: float = bench_w(aw, opp_bmax, base.opp_bench * k * scale_w)
	out["opp_bench"] = _row_rects(PAD, y, aw, opp_bmax, ob)
	y += ob * R + gap
	# 상대 배틀 줄: 왼쪽 사이드 더미, 가운데 배틀, 오른쪽 덱·트래쉬
	var oa: float = base.opp_active * k * scale_w
	var oh: float = oa * R
	out["opp_active"] = Rect2((W - oa) / 2.0, y, oa, oh)
	_piles(out, "opp", PAD, y, W, oh)
	y += oh + gap
	out["mid"] = Rect2(PAD, y, aw, base.mid * k)
	out["stadium"] = Rect2((W - base.mid * k * R) / 2.0, y + 2, base.mid * k * R, base.mid * k - 4)
	y += base.mid * k + gap
	var ma: float = base.my_active * k * scale_w
	var mh: float = ma * R
	out["my_active"] = Rect2((W - ma) / 2.0, y, ma, mh)
	_piles(out, "my", PAD, y, W, mh)
	y += mh + gap
	var mb: float = bench_w(aw, my_bmax, base.my_bench * k * scale_w)
	out["my_bench"] = _row_rects(PAD, y, aw, my_bmax, mb)
	y += mb * R + gap
	out["chips"] = Rect2(PAD, y, aw * 0.62, base.chips * k)
	var hc: float = hand_w.call(k)
	out["card"] = Vector2(hc, hc * R)
	# 손패 영역: 화면 아래까지 (카드 아래쪽 일부는 화면 밖으로 잘려 보임), 오른쪽 아래는 턴 종료
	var hand_top: float = y + base.chips * k + gap * 0.5
	out["hand"] = Rect2(0, hand_top, W, size.y - hand_top)
	out["end_turn"] = Rect2(W - PAD - 176, y - 4, 176, base.chips * k + 8)
	return out

## 사이드 더미(왼쪽, 2×3 작은 뒷면)와 덱·트래쉬(오른쪽, 위아래)
static func _piles(out: Dictionary, side: String, x0: float, y: float, W: float, h: float) -> void:
	var pw := minf(46.0, (h - 2 * 4.0) / 3.0 / R)
	var ph := pw * R
	var grid: Array = []
	for r in 3:
		for c in 2:
			grid.append(Rect2(x0 + c * (pw + 4), y + r * (ph + 4), pw, ph))
	out[side + "_prizes"] = grid
	out[side + "_prizes_box"] = Rect2(x0, y, pw * 2 + 4, ph * 3 + 8)
	var dw := minf(78.0, (h - 56.0) / 2.0 / R)
	var dh := dw * R
	out[side + "_deck"] = Rect2(W - x0 - dw, y, dw, dh)
	out[side + "_discard"] = Rect2(W - x0 - dw, y + dh + 28, dw, dh)

## 서버 대전 손패 화면: 위 상태, 상대 행동 알림, 내 포켓몬 작은 줄, 가운데 여유(선택 안내), 칩·턴 종료, 큰 손패
static func _hand(size: Vector2, my_bmax: int, top: float, bottom: float) -> Dictionary:
	var W := size.x
	var aw := W - PAD * 2
	var out := { "k": 1.0, "mode": "hand" }
	var y := top
	out["bar"] = Rect2(0, y, W, 64)
	y += 64 + GAP
	out["status"] = Rect2(PAD, y, aw, 76)
	y += 76 + GAP
	out["notice"] = Rect2(PAD, y, aw, 96)
	y += 96 + GAP
	var hc := minf(236.0, W * 0.33)
	var hand_h := hc * R + 40
	var chips_y := size.y - bottom - hand_h - 56
	# 내 포켓몬: 가운데 안내 칸(최소 64)만 남기고 세로 공간을 채운다. 카드가 더 크게 나오는 쪽을 고름
	#  A: [배틀][벤치 n] 한 줄  /  B: 배틀 위(가운데) · 벤치 아래 전체 너비
	var n := my_bmax
	var avail_h := maxf(0.0, chips_y - y - GAP * 2 - 64.0)
	var a_bw := floorf(minf((aw - n * GAP - GAP) / (n + 1.3), avail_h / 1.3 / R))
	var b_bw := floorf(minf((aw - (n - 1) * GAP) / n, (avail_h - GAP) / (2.25 * R)))
	if b_bw > a_bw * 1.04:
		var act := floorf(minf(minf(aw * 0.75, b_bw * 3.4), (avail_h - GAP - b_bw * R) / R))
		out["my_active"] = Rect2((W - act) / 2.0, y, act, act * R)
		y += act * R + GAP
		out["my_bench"] = _row_rects(PAD, y, aw, n, b_bw)
		y += b_bw * R + GAP
	else:
		var bw := a_bw
		var act := floorf(minf(avail_h / R, aw - n * (bw + GAP) - GAP))
		var total := act + GAP * 2 + n * bw + (n - 1) * GAP
		var x0 := PAD + maxf(0.0, (aw - total) / 2.0)
		out["my_active"] = Rect2(x0, y, act, act * R)
		var bench: Array = []
		var bx := x0 + act + GAP * 2
		for i in n:
			bench.append(Rect2(bx + i * (bw + GAP), y + (act - bw) * R, bw, bw * R))
		out["my_bench"] = bench
		y += act * R + GAP
	out["center"] = Rect2(PAD, y, aw, maxf(0.0, chips_y - y - GAP))
	out["chips"] = Rect2(PAD, chips_y, aw * 0.62, 48)
	out["end_turn"] = Rect2(W - PAD - 176, chips_y - 4, 176, 56)
	out["card"] = Vector2(hc, hc * R)
	out["hand"] = Rect2(0, chips_y + 56, W, size.y - chips_y - 56)
	return out

## 배치 검사 (테스트용): 겹침·화면 밖·최소 터치 크기. 문제 목록을 돌려준다
static func check(l: Dictionary, size: Vector2) -> Array:
	var problems: Array = []
	var rects: Array = []
	for k in l:
		var v = l[k]
		if v is Rect2:
			rects.append([k, v])
		elif v is Array:
			for i in v.size():
				if v[i] is Rect2:
					rects.append(["%s[%d]" % [k, i], v[i]])
	var screen := Rect2(Vector2.ZERO, size)
	for r in rects:
		var name: String = r[0]
		var rect: Rect2 = r[1]
		if name == "hand":
			continue   # 손패는 아래가 화면 밖으로 잘려도 됨
		if not screen.encloses(rect.grow(-0.5)):
			problems.append("%s 화면 밖 %s" % [name, rect])
		if not name.contains("prizes") and not name.begins_with("mid") and not name.begins_with("bar") and not name.begins_with("status") and not name.begins_with("notice") and not name.begins_with("center") and not name.begins_with("opp_hand") and not name.begins_with("chips") and (rect.size.x < 44 or rect.size.y < 44):
			problems.append("%s 너무 작음 %s" % [name, rect.size])
	# 서로 겹치면 안 되는 것들
	var solid := rects.filter(func(r): return not (r[0] in ["hand", "mid", "bar", "center", "chips", "end_turn", "opp_prizes_box", "my_prizes_box"]))
	for i in solid.size():
		for j in range(i + 1, solid.size()):
			var a: Rect2 = solid[i][1]
			var b: Rect2 = solid[j][1]
			if a.grow(-1).intersects(b.grow(-1)):
				problems.append("%s ↔ %s 겹침" % [solid[i][0], solid[j][0]])
	return problems
