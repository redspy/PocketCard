class_name GHardBot
extends RefCounted
## 어려움 AI (Godot 전용 — TS 엔진에는 없고 엔진 비교 대상도 아니다).
## 보통 AI(GBot._aiMove)를 "기본 수"로 쓰고, 지금 고를 수 있는 행동마다
##   그 행동 → 이번 차례 나머지와 상대 차례를 보통 AI 로 엔진에서 미리 돌려 본 뒤
##   판세 점수가 가장 높은 행동을 고른다 (rollout 탐색).
## 숨은 정보(내 덱 순서·사이드, 상대 패·덱·사이드, 코인)는 시뮬레이션 전에 섞어서 엿보지 않는다.

const WIN := 1000000.0

var bc: Dictionary
var info: Dictionary
var opp_turn := true        # 상대 차례까지 내다보기
var samples := 1            # 숨은 정보를 다르게 섞어 보는 횟수 (점수는 평균). 1 로도 보통 AI 를 크게 이김
var max_cands := 18         # 한 번에 비교할 후보 행동 수 상한
var turn_cap := 30          # 시뮬레이션에서 한 차례 행동 수 상한
var budget_ms := 2500       # 한 수 생각 시간 상한 (0 = 무제한). 넘으면 그때까지 본 후보 중에서 고름
var _base_st := { "counted": { "turn": -1, "version": -1, "seat": -1, "n": 0 } }
var _turn := { "turn": -1, "n": 0 }
var stats := { "decisions": 0, "searched": 0, "sims": 0, "usec": 0, "maxUsec": 0, "timeouts": 0 }

func _init(by_code: Dictionary, inf: Dictionary) -> void:
	bc = by_code
	info = inf

static func make(cat: Dictionary, inf: Dictionary) -> GHardBot:
	return GHardBot.new(GBot.codeIndex(cat, inf.db), inf)

## 다른 스레드에서 엔진을 돌리기 전에 (메인 스레드에서) 한 번: 엔진의 지연 초기화를 미리 해 둔다
static func prewarm() -> void:
	GEngine.ensure()
	if GEffects._reWhat1 == null:
		var r1 := RegEx.new()
		r1.compile("\\s*(을|를)?\\s*고르세요\\.?$")
		var r2 := RegEx.new()
		r2.compile("\\.$")
		GEffects._reWhat2 = r2
		GEffects._reWhat1 = r1

static func _new_st() -> Dictionary:
	return { "counted": { "turn": -1, "version": -1, "seat": -1, "n": 0 } }

## 실제 상태 state 에서 seat 가 둘 입력 (ClientInput) 또는 null. rng: 봇 난수 상태 (바뀜)
func decide(state: Dictionary, seat: int, rng: Array):
	var t0 := Time.get_ticks_usec()
	stats.decisions += 1
	var view := GView.viewFor(state, seat, info)
	var base = GBot._aiMove(bc, _base_st, view, rng.duplicate())
	if base == null or state.phase != "playing":
		return base
	if _turn.turn != state.turnNumber:
		_turn.turn = state.turnNumber
		_turn.n = 0
	_turn.n += 1
	if _turn.n > 40:
		return base   # 무한 반복 방지: 이번 차례는 보통 AI 에 맡김 (60번째에 턴 종료)
	var req = GCore.find_first(view.requests, func(r): return r.player == seat and r.get("options") != null)
	var cands: Array = _choice_cands(req, base, state, rng) if req != null else _move_cands(view, base, state)
	if cands.size() <= 1:
		return base
	stats.searched += 1
	# 시간 제한 안에서 할 수 있는 만큼: 1회차는 후보 순서대로(0번 = 기본 수는 항상), 2회차부터는 남은 시간에
	var deadline := t0 + budget_ms * 1000
	var sums: Array = []
	var counts: Array = []
	sums.resize(cands.size())
	sums.fill(0.0)
	counts.resize(cands.size())
	counts.fill(0)
	var out_of_time := false
	for k in samples:
		var srng := _fork(rng)
		var det := _determinize(state, seat, srng, req)
		for i in cands.size():
			if counts[i] < 0:
				continue
			if i > 0 and budget_ms > 0 and Time.get_ticks_usec() > deadline:
				out_of_time = true
				break
			var gi = GMatch.toGameInput(cands[i], seat)
			var r := GEngine.applyInput(det, gi, info, true) if gi != null else { "ok": false }
			if not r.ok:
				counts[i] = -1
				continue
			stats.sims += 1
			sums[i] += evaluate(_rollout(r.state, seat, srng.duplicate()), seat)
			counts[i] += 1
		if out_of_time:
			break
	var best := 0
	var best_v: float = sums[0] / maxi(1, counts[0])
	for i in range(1, cands.size()):
		if counts[i] <= 0:
			continue
		var v: float = sums[i] / counts[i]
		# 점수 차가 아주 작으면 기본 수 그대로
		if v > best_v + 1.0:
			best = i
			best_v = v
	if out_of_time:
		stats.timeouts += 1
	var dt := Time.get_ticks_usec() - t0
	stats.usec += dt
	stats.maxUsec = maxi(stats.maxUsec, dt)
	return cands[best]

# ───────────── 후보 ─────────────

## 내 차례 행동 후보: 합법 행동 (항복 제외), 같은 카드·같은 대상이면 하나로. 0번 = 기본 수
func _move_cands(view: Dictionary, base: Dictionary, state: Dictionary) -> Array:
	var out: Array = [base]
	var seen := { _key(base, state): true }
	var acts = view.get("actions")
	for a in (acts if acts != null else []):
		if a.kind == "concede":
			continue
		var inp := GBot.strip(a)
		var k := _key(inp, state)
		if seen.has(k):
			continue
		seen[k] = true
		out.append(inp)
	# 시간이 모자랄 때를 위해 중요한 행동(공격·특성)을 앞에
	var rest := GCore.stable_sort(out.slice(1), func(a, b): return GHardBot._prio(a) - GHardBot._prio(b))
	return _cap([base] + rest)

const _PRIO := { "attack": 0, "ability": 1, "play": 2, "retreat": 3, "stadium": 4, "endTurn": 5 }
static func _prio(inp: Dictionary) -> int:
	return _PRIO.get(str(inp.get("type")), 3)

## 선택 요청 후보: 하나 고르기면 보기마다 (같은 카드는 하나로), 여러 장 고르기면 기본 수 + 무작위 몇 가지
func _choice_cands(req: Dictionary, base: Dictionary, state: Dictionary, rng: Array) -> Array:
	var out: Array = [base]
	if req.kind in ["ackReveal", "chooseFirst", "mulliganDraw", "takePrize", "chooseActive", "chooseBench"]:
		return out
	var opts: Array = req.options
	var mn: int = GBot._nz(req.get("min"))
	var mx: int = mini(GBot._nz(req.get("max")), opts.size())
	var seen := { _pick_key(base.picks, state): true }
	var add = func(picks: Array):
		var k := _pick_key(picks, state)
		if not seen.has(k):
			seen[k] = true
			out.append({ "type": "choice", "requestId": req.id, "picks": picks })
	if mx <= 1:
		if mn == 0:
			add.call([])
		for o in opts:
			add.call([o])
	else:
		for i in 5:
			add.call(GBot.randomPicks(req, rng))
	return _cap(out)

func _cap(c: Array) -> Array:
	return c.slice(0, max_cands) if c.size() > max_cands else c

## 입력 비교 키: 카드 iid 대신 카드 코드 (같은 카드 두 장 = 같은 수)
static func _key(inp: Dictionary, state: Dictionary) -> String:
	var keys: Array = inp.keys()
	keys.sort()
	var parts: Array = []
	for k in keys:
		var v = inp[k]
		if k == "card" and state.cards.has(str(v)):
			v = state.cards[str(v)].code
		parts.append("%s=%s" % [k, str(v)])
	return ",".join(parts)

static func _pick_key(picks: Array, state: Dictionary) -> String:
	var xs: Array = []
	for p in picks:
		var c = state.cards.get(str(p))
		xs.append(c.code if c != null else str(p))
	xs.sort()
	return ",".join(xs)

# ───────────── 시뮬레이션 ─────────────

## 봇 난수에서 새 난수 상태를 떼어 낸다
static func _fork(rng: Array) -> Array:
	return GRng.seedRng("%08x%08x%08x%08x" % [GRng.nextU32(rng), GRng.nextU32(rng), GRng.nextU32(rng), GRng.nextU32(rng)])

## 숨은 정보를 섞은 복사본. 걸려 있는 선택 요청(req)의 보기가 숨은 구역의 카드면(덱 위 카드 보기 등) 그 쪽은 섞지 않음
static func _determinize(state: Dictionary, seat: int, rng: Array, req) -> Dictionary:
	var s: Dictionary = state.duplicate(true)
	s.rng = _fork(rng)
	var seen := {}
	if req != null:
		for o in req.get("options", []):
			seen[str(o)] = true
		for c in (req.get("cards") if req.get("cards") is Array else []):
			seen[str(c.get("iid", ""))] = true
	var mine: Dictionary = s.players[seat]
	var opp: Dictionary = s.players[1 - seat]
	if not _touches(mine, ["deck", "prizes"], seen):
		_mix(mine, ["deck", "prizes"], rng)
	if not _touches(opp, ["hand", "deck", "prizes"], seen):
		_mix(opp, ["hand", "deck", "prizes"], rng)
	return s

static func _touches(p: Dictionary, zones: Array, seen: Dictionary) -> bool:
	if seen.is_empty():
		return false
	for z in zones:
		for iid in p[z]:
			if iid != null and seen.has(str(iid)):
				return true
	return false

## 여러 구역의 카드를 한데 섞어 원래 장수대로 다시 나눈다 (사이드의 빈자리는 그대로)
static func _mix(p: Dictionary, zones: Array, rng: Array) -> void:
	var pool: Array = []
	for z in zones:
		for iid in p[z]:
			if iid != null:
				pool.append(iid)
	GRng.shuffleInPlace(rng, pool)
	var at := 0
	for z in zones:
		var arr: Array = p[z]
		for i in arr.size():
			if arr[i] != null:
				arr[i] = pool[at]
				at += 1

## 지금 둘 사람: 선택 요청이 걸린 사람, 없으면 차례인 사람
static func _actor(s: Dictionary):
	for r in s.requests:
		if r.get("options") != null:
			return r.player
	return s.turnPlayer if s.phase == "playing" else null

## 보통 AI 끼리 이번 차례 끝까지(opp_turn 이면 상대 차례 끝까지) 진행한 상태
func _rollout(s: Dictionary, seat: int, rng: Array) -> Dictionary:
	var sts: Array = [_new_st(), _new_st()]
	var left := false
	var steps := 0
	var cur_turn: int = s.turnNumber
	for guard in turn_cap * 3:
		if s.phase == "ended":
			break
		if s.turnPlayer != seat:
			left = true
			if not opp_turn:
				break
		elif left:
			break
		if s.turnNumber != cur_turn:
			cur_turn = s.turnNumber
			steps = 0
		steps += 1
		var who = _actor(s)
		if who == null:
			break
		var inp = null
		var forced: bool = steps > turn_cap and who == s.turnPlayer and not s.requests.any(func(r): return r.get("options") != null)
		if forced:
			inp = { "type": "endTurn" }
		else:
			inp = GBot._aiMove(bc, sts[who], GView.viewFor(s, who, info, false), rng)
		if inp == null:
			break
		var r := GEngine.applyInput(s, GMatch.toGameInput(inp, who), info, not forced)
		if not r.ok:
			if inp.type == "endTurn":
				break
			r = GEngine.applyInput(s, { "type": "endTurn", "player": who }, info)
			if not r.ok:
				break
		s = r.state
	return s

# ───────────── 판세 점수 (seat 쪽에서 본) ─────────────

func evaluate(s: Dictionary, seat: int) -> float:
	if s.phase == "ended":
		var w = s.result.get("winner") if s.result is Dictionary else null
		if w == null:
			return 0.0
		return WIN if int(w) == seat else -WIN
	var v := GView.viewFor(s, seat, info, false)
	var me: Dictionary = v.players[seat]
	var opp: Dictionary = v.players[1 - seat]
	var sc := 1000.0 * (GBot.prizesTakenBy(me) - GBot.prizesTakenBy(opp))
	sc += _side(me) - _side(opp)
	# 다음에 둘 쪽의 위협이 더 급하다
	var my_w := 1.0 if s.turnPlayer == seat else 0.5
	sc += _threat(me, opp) * my_w - _threat(opp, me) * (1.5 - my_w)
	return sc

## 한쪽 필드·패·덱의 가치
func _side(p: Dictionary) -> float:
	var t := 0.0
	var slots: Array = [p.active]
	slots.append_array(p.bench)
	for s in slots:
		if s == null or s.stack == null:
			continue
		var d = GBot.top(bc, s)
		var pk = GBot._pk(d)
		if pk == null:
			continue
		t += 60.0 + int(pk.stage) * 45.0 + (25.0 if GCore.truthy(pk.rule) else 0.0)
		var hp: int = maxi(1, GBot._nz(s.get("hp")))
		t += 80.0 * maxi(0, GBot.remain(s)) / hp
		var u: int = GBot.units(bc, s).size()
		var b = GBot.bestAttack(d)
		if b != null and b.dmg > 0:
			t += 30.0 * mini(u, b.cost.size()) + 6.0 * maxi(0, u - b.cost.size())
			if GBot.missing(bc, s, b.cost).is_empty():
				t += 40.0 + b.dmg / 4.0
		else:
			t += 8.0 * u
	var hc: int = p.handCount
	t += 7.0 * mini(hc, 10)
	if p.deckCount < 6:
		t -= 70.0 * (6 - p.deckCount)
	return t

## a 의 배틀 포켓몬이 다음 공격으로 b 의 배틀 포켓몬에 주는 위협 (에너지 1장 더 붙이면 되는 기술은 70%)
func _threat(a: Dictionary, b: Dictionary) -> float:
	var att = a.active
	var tgt = b.active
	if att == null or tgt == null or att.stack == null or tgt.stack == null:
		return 0.0
	var pk = GBot._pk(GBot.top(bc, att))
	if pk == null:
		return 0.0
	var best := 0.0
	for i in pk.attacks.size():
		var miss: int = GBot.missing(bc, att, pk.attacks[i].cost).size()
		if miss > 1:
			continue
		var dmg: int = GBot.estimate(bc, a, b, att, i)
		var w := 1.0 if miss == 0 else 0.7
		var rem: int = maxi(1, GBot.remain(tgt))
		var val: float
		if dmg >= rem:
			val = 350.0 * GCore.prizeValue(GBot.top(bc, tgt))
		else:
			val = 150.0 * dmg / rem
		best = maxf(best, val * w)
	return best
