class_name GBot
## src/game/bot.ts 포팅 — 봇: 자기 시점 보기(view)만 보고 행동을 고른다.
##  - randomBot: 합법 행동 중 무작위 (퍼징·버그 찾기용)
##  - makeAiBot: 1인용 AI — 카드 데이터(공개 정보)를 써서 간단한 우선순위로 플레이
## 포팅 규칙: PORTING.md. 같은 view + 같은 봇 난수 상태면 TS 와 같은 입력을 돌려줘야 한다.
## 입력(ClientInput)은 Dictionary, 행동이 없으면 null.

static func strip(m: Dictionary) -> Dictionary:
	var rest: Dictionary = m.input.duplicate()
	rest.erase("player")
	return rest

## 할 일이 있는가 (선택 요청 또는 내 차례 행동)
static func botHasWork(view: Dictionary) -> bool:
	if typeof(view.viewer) != TYPE_INT:
		return false
	if view.requests.any(func(r): return r.player == view.viewer and r.get("options") != null):
		return true
	var actions = view.get("actions")
	if actions == null:
		return false
	return actions.any(func(a): return a.kind == "endTurn")

static func _nz(x) -> int:
	return 0 if x == null else x

static func randomPicks(req: Dictionary, rng: Array) -> Array:
	var opts = req.get("options")
	if opts == null:
		opts = []
	var mn: int = _nz(req.get("min"))
	var mx: int = mini(_nz(req.get("max")), opts.size())
	var n: int = mn + GRng.randInt(rng, maxi(1, mx - mn + 1))
	var pool: Array = opts.duplicate()
	var picks: Array = []
	for i in range(mini(n, mx)):
		picks.append(pool.pop_at(GRng.randInt(rng, pool.size())))
	return picks

static func randomBot(view: Dictionary, rng: Array):
	if typeof(view.viewer) != TYPE_INT:
		return null
	var req = GCore.find_first(view.requests, func(r): return r.player == view.viewer and r.get("options") != null)
	if req != null:
		return { "type": "choice", "requestId": req.id, "picks": randomPicks(req, rng) }
	var all_acts = view.get("actions")
	if all_acts == null:
		all_acts = []
	var acts: Array = all_acts.filter(func(a): return a.kind != "concede")
	if acts.is_empty():
		return null
	# 턴 종료는 낮은 확률로 (너무 빨리 끝내지 않게)
	var nonEnd: Array = acts.filter(func(a): return a.kind != "endTurn")
	if nonEnd.size() > 0 and GRng.randInt(rng, 5) != 0:
		return strip(nonEnd[GRng.randInt(rng, nonEnd.size())])
	var e = GCore.find_first(acts, func(a): return a.kind == "endTurn")
	return strip(e if e != null else acts[0])

# ───────────────────────── 1인용 AI ─────────────────────────

## 카드 코드(인쇄) → 카드 데이터
static func codeIndex(cat: Dictionary, db: Dictionary) -> Dictionary:
	var out := {}
	for d in cat.decks:
		for c in d.cards:
			var data = db.get(c.id)
			if not GCore.truthy(data):
				continue
			for p in c.prints:
				out[p] = data
			out[c.code] = data
	return out

## AI 봇. 반환: func(view: Dictionary, rng: Array) -> 입력 Dictionary 또는 null
static func makeAiBot(cat: Dictionary, db: Dictionary) -> Callable:
	var byCode := codeIndex(cat, db)
	# 이번 턴 행동 수 (무한 반복 방지). 턴이 바뀌거나 새 게임(버전이 줄어듦)이면 다시 셈
	var st := { "counted": { "turn": -1, "version": -1, "seat": -1, "n": 0 } }
	return func(view: Dictionary, rng: Array): return GBot._aiMove(byCode, st, view, rng)

# ── 닫힘(closure) 도우미들: TS 에서 makeAiBot 안의 화살표 함수. bc = byCode

static func card(bc: Dictionary, code):
	if code == null or code == "":
		return null
	return bc.get(code)

static func _pk(d):
	if d == null:
		return null
	return d.get("pokemon")

static func top(bc: Dictionary, s):
	if s == null or s.get("stack") == null:
		return null
	var stack: Array = s.stack
	return card(bc, stack[stack.size() - 1].code)

static func remain(s: Dictionary) -> int:
	return _nz(s.get("hp")) - int(s.damage)

static func units(bc: Dictionary, s: Dictionary) -> Array:
	var out: Array = []
	var att = s.get("attached")
	if att == null:
		att = []
	for a in att:
		var d = card(bc, a.code)
		if d == null or d.kind != "energy":
			continue
		var en = d.get("energy")
		if en != null and GCore.truthy(en.get("basic")) and GCore.truthy(en.get("type")):
			out.append(en.type)
			continue
		out.append("*" if d.name == "루미너스 에너지" else "C")
	return out

static func missing(bc: Dictionary, s: Dictionary, cost: Array) -> Array:
	var pool := units(bc, s)
	var need: Array = []
	for t in cost.filter(func(c): return c != "C"):
		var i := pool.find(t)
		if i < 0:
			i = pool.find("*")
		if i < 0:
			need.append(t)
		else:
			pool.remove_at(i)
	var cc: int = cost.filter(func(x): return x == "C").size()
	for i in range(pool.size(), cc):
		need.append("C")
	return need

## 이 포켓몬의 가장 센 기술 (기본 데미지 기준). { dmg, cost } 또는 null
static func bestAttack(d):
	var pk = _pk(d)
	var atks = pk.get("attacks") if pk != null else null
	if atks == null:
		atks = []
	var b = null
	for a in atks:
		var dmg: int = a.damage if GCore.truthy(a.damage) else (30 if GCore.truthy(a.get("text")) else 0)
		if b == null or dmg > b.dmg:
			b = { "dmg": dmg, "cost": a.cost }
	return b

## 카드 가치 (버릴 카드·가져올 카드 고르기). nt: 내 포켓몬 기술에 필요한 에너지 타입 (Dictionary 집합)
static func value(bc: Dictionary, nt: Dictionary, code) -> int:
	var d = card(bc, code)
	if d == null:
		return 0
	if d.kind == "pokemon":
		return 50 + (30 if GCore.truthy(d.pokemon.rule) else 0) + int(d.pokemon.stage) * 10
	if d.kind == "trainer":
		var tr = d.get("trainer")
		if tr == "supporter":
			return 45
		if tr == "stadium":
			return 15
		if d.name == "기술머신 에볼루션":
			return 10
		return 35
	var en = d.get("energy")
	if en != null and GCore.truthy(en.get("basic")):
		var et = en.get("type")
		return 70 if nt.has(et if et != null else "") else 12
	return 40

static func slotBySid(me: Dictionary, opp: Dictionary, sid) -> Variant:
	var all: Array = [me.active]
	all.append_array(me.bench)
	all.append(opp.active)
	all.append_array(opp.bench)
	for s in all:
		if s != null and s.sid == sid:
			return s
	return null

static func take(req: Dictionary, sorted: Array, n: int) -> Dictionary:
	return { "type": "choice", "requestId": req.id, "picks": sorted.slice(0, n) }

static func _jsNumber(x: String):
	# JS Number(x) || 0
	var t := x.strip_edges()
	if t == "":
		return 0
	if t.is_valid_int():
		return t.to_int()
	if t.is_valid_float():
		return t.to_float()
	return 0

static func _labelNum(lab: Dictionary, o) -> int:
	# parseInt(lab[o]?.replace(/\D/g, '') || '0')
	var l = lab.get(o)
	if l == null:
		return 0
	var digits := ""
	for ch in String(l):
		if ch >= "0" and ch <= "9":
			digits += ch
	if digits == "":
		digits = "0"
	return digits.to_int()

static func _pick(acts: Array, kind: String, pred = null):
	for a in acts:
		if a.kind == kind and (pred == null or pred.call(a)):
			return a
	return null

static func canKo(dmg, t) -> bool:
	return t != null and dmg >= remain(t)

static func prizesTakenBy(p: Dictionary) -> int:
	return 6 - p.prizes.filter(func(x): return GCore.truthy(x)).size()

## cards(CardView 배열) 중 card(code)?.kind === 'energy' 인 수
static func _countEnergy(bc: Dictionary, cards: Array) -> int:
	var n := 0
	for a in cards:
		var d = card(bc, a.code)
		if d != null and d.kind == "energy":
			n += 1
	return n

## cards 중 card(code)?.energy?.basic 인 수
static func _countBasicEnergy(bc: Dictionary, cards: Array) -> int:
	var n := 0
	for h in cards:
		var d = card(bc, h.code)
		var en = d.get("energy") if d != null else null
		if en != null and GCore.truthy(en.get("basic")):
			n += 1
	return n

static func energyCount(bc: Dictionary, p: Dictionary) -> int:
	var all: Array = [p.active]
	all.append_array(p.bench)
	var n := 0
	for s in all:
		var att = s.get("attached") if s != null else null
		if att == null:
			att = []
		n += _countEnergy(bc, att)
	return n

## 기술 데미지 추정 (×·+ 기술은 지금 상황으로 계산, 약점 반영)
static func estimate(bc: Dictionary, me: Dictionary, opp: Dictionary, s, i: int) -> int:
	var d = top(bc, s)
	var pk = _pk(d)
	var a = null
	if pk != null and i >= 0 and i < pk.attacks.size():
		a = pk.attacks[i]
	if a == null or s == null:
		return 0
	var oppAct = opp.active
	var hand = me.hand if me.hand != null else []
	var dmg: int = a.damage
	match a.nameJa:
		"ユニオンビート":
			dmg = 30 * me.bench.size()
		"あおばのあらし":
			dmg = 60 * energyCount(bc, opp)
		"ゴールドラッシュ":
			dmg = 50 * _countBasicEnergy(bc, hand)
		"ガーランドレイ":
			var att = s.get("attached")
			if att == null:
				att = []
			dmg = 120 * mini(2, _countEnergy(bc, att))
		"がっつく":
			dmg = 80 * prizesTakenBy(me)
		"フルムーンロンド":
			dmg = 20 + 20 * (me.bench.size() + opp.bench.size())
		"さんどづき":
			dmg = 15
		"バーニングダーク":
			dmg = 180 + 30 * prizesTakenBy(opp)
		"ビッグバイト":
			dmg = 30 if (oppAct != null and oppAct.damage > 0) else 260
		"ほえさけぶ":
			dmg = 20 * floori(float(s.damage) / 10)
		"クルーエルアロー":
			dmg = 100
		"스톰슬래시", "브레인웨이브":
			var att2 = s.get("attached")
			if att2 == null:
				att2 = []
			var np := 0
			for x in att2:
				var xd = card(bc, x.code)
				var xe = xd.get("energy") if xd != null else null
				if xe != null and xe.get("type") == "P":
					np += 1
			dmg = 60 + 30 * np
		_:
			if not GCore.truthy(dmg) and GCore.truthy(a.get("text")):
				dmg = 20
	var od = top(bc, oppAct)
	var opk = _pk(od)
	var mytype = pk.type
	if opk != null and GCore.truthy(opk.weak) and opk.weak == mytype:
		dmg *= 2
	if opk != null and GCore.truthy(opk.resist) and opk.resist == mytype:
		dmg -= 30
	return maxi(0, dmg)

static func readyBench(bc: Dictionary, s) -> int:
	var b = bestAttack(top(bc, s))
	return b.dmg if (b != null and missing(bc, s, b.cost).size() == 0) else 0

## 진화 2단계 카드 d 의 진화 전(1단계)이 필드의 포켓몬에서 진화하는가
static func _stage1Links(bc: Dictionary, fieldNames: Dictionary, from_name) -> bool:
	for nm in fieldNames:
		for c in bc.values():
			var cp = _pk(c)
			if cp != null and cp.stage == 1 and cp.from == nm and c.name == from_name:
				return true
	return false

static func _aiMove(bc: Dictionary, st: Dictionary, view: Dictionary, rng: Array):
	if typeof(view.viewer) != TYPE_INT:
		return null
	var viewer: int = view.viewer
	var me: Dictionary = view.players[viewer]
	var opp: Dictionary = view.players[1 if viewer == 0 else 0]
	var mine: Array = [me.active]
	mine.append_array(me.bench)
	mine = mine.filter(func(s): return s != null)
	var mySids := {}
	for s in mine:
		mySids[s.sid] = true
	var nt := {}
	for s in mine:
		var b = bestAttack(top(bc, s))
		var cost: Array = b.cost if b != null else []
		for c in cost:
			if c != "C":
				nt[c] = true
	var hand: Array = me.hand if me.hand != null else []
	for h in hand:
		var d = card(bc, h.code)
		if d != null and d.kind == "pokemon":
			var b = bestAttack(d)
			var cost: Array = b.cost if b != null else []
			for c in cost:
				if c != "C":
					nt[c] = true

	# ── 선택 요청
	var req = GCore.find_first(view.requests, func(r): return r.player == view.viewer and r.get("options") != null)
	if req != null:
		var opts: Array = req.get("options") if req.get("options") != null else []
		var mn: int = _nz(req.get("min"))
		var mx: int = _nz(req.get("max"))
		var codeOf = func(o):
			var rc = req.get("cards")
			if rc != null:
				var c = GCore.find_first(rc, func(x): return x.iid == o)
				if c != null and c.code != null:
					return c.code
			if me.hand != null:
				var h = GCore.find_first(me.hand, func(x): return x.iid == o)
				if h != null:
					return h.code
			return null
		match req.kind:
			"chooseFirst":
				return take(req, ["second"], 1)
			"ackReveal":
				return take(req, ["ok"], 1)
			"mulliganDraw":
				return take(req, [opts[opts.size() - 1] if opts.size() > 0 else null], 1)
			"chooseActive":
				# 공격을 빨리 할 수 있는 기본 포켓몬 (비용이 적고 HP 가 높은 것)
				var score = func(o):
					var d = GBot.card(bc, codeOf.call(o))
					var b = GBot.bestAttack(d)
					var pk = GBot._pk(d)
					var hp = pk.get("hp") if pk != null else null
					var hpv: float = float(hp if hp != null else 0) / 10.0
					var clen: int = b.cost.size() if b != null else 4
					var rulev: int = 8 if (pk != null and GCore.truthy(pk.rule)) else 0
					return hpv - clen * 5 - rulev
				return take(req, GCore.stable_sort(opts, func(a, b): return score.call(b) - score.call(a)), 1)
			"chooseBench":
				return take(req, opts, mx)
			"takePrize", "promote":
				if req.kind == "takePrize":
					return take(req, opts, mn)
				var score = func(sid):
					var s = GBot.slotBySid(me, opp, sid)
					var b = GBot.bestAttack(GBot.top(bc, s))
					if s == null:
						return 0
					return (1000 if (b != null and GBot.missing(bc, s, b.cost).size() == 0) else 0) + GBot.units(bc, s).size() * 50 + GBot.remain(s)
				return take(req, GCore.stable_sort(opts, func(a, b): return score.call(b) - score.call(a)), 1)
			"pickOption":
				if opts.has("yes"):
					return take(req, ["yes"], 1)
				if opts.has("boost"):
					var opk = _pk(top(bc, opp.active))
					var choice: String
					if opk != null and GCore.truthy(opk.rule):
						choice = "boost"
					else:
						choice = "switch" if opts.has("switch") else "boost"
					return take(req, [choice], 1)
				# 숫자·기술 선택: 가장 큰 것
				var lab: Dictionary = req.get("labels") if req.get("labels") != null else {}
				if String(req.prompt).contains("기술"):
					return take(req, GCore.stable_sort(opts, func(a, b): return GBot._labelNum(lab, b) - GBot._labelNum(lab, a)), 1)
				return take(req, GCore.stable_sort(opts, func(a, b): return GBot._jsNumber(String(b)) - GBot._jsNumber(String(a))), 1)
			"pickSlot":
				var oppSide: bool = opts.all(func(o): return not mySids.has(o))
				if oppSide:
					# 상대: 기절시킬 수 있는(남은 HP 낮은) 것, 사이드 가치 높은 것
					var scoreOpp = func(sid):
						var s = GBot.slotBySid(me, opp, sid)
						if s == null:
							return 0
						var pk = GBot._pk(GBot.top(bc, s))
						return -GBot.remain(s) + (60 if (pk != null and GCore.truthy(pk.rule)) else 0)
					return take(req, GCore.stable_sort(opts, func(a, b): return scoreOpp.call(b) - scoreOpp.call(a)), maxi(mn, mini(mx, 1)))
				# 내 포켓몬: 공격 준비에 가까운(에너지가 필요한) 주력
				var score = func(sid):
					var s = GBot.slotBySid(me, opp, sid)
					if s == null:
						return 0
					var d = GBot.top(bc, s)
					var b = GBot.bestAttack(d)
					var pk = GBot._pk(d)
					return (b.dmg if b != null else 0) + (40 if is_same(s, me.active) else 0) + (30 if (pk != null and GCore.truthy(pk.rule)) else 0) + (-GBot.missing(bc, s, b.cost).size() * 5 if b != null else 0)
				if String(req.prompt).contains("트래쉬"):
					return take(req, GCore.stable_sort(opts, func(a, b): return score.call(a) - score.call(b)), maxi(mn, 1))
				return take(req, GCore.stable_sort(opts, func(a, b): return score.call(b) - score.call(a)), maxi(mn, mini(mx, 1)))
			"pickCards":
				var p: String = req.prompt
				var lose: bool = (p.contains("트래쉬") or p.contains("되돌릴") or p.contains("버릴")) and not (p.contains("패로 가져올") or p.contains("가져올"))
				# 가져올 때: 이미 패에 있는 이름은 덜, 필드의 포켓몬에서 진화하는 카드는 더
				var fieldNames := {}
				for s in mine:
					var td = top(bc, s)
					if td != null:
						fieldNames[td.name] = true
				var handNames: Array = []
				for h in hand:
					var hd = card(bc, h.code)
					handNames.append(hd.name if hd != null else null)
				var gain = func(o):
					var co = codeOf.call(o)
					var d = GBot.card(bc, co)
					var v: int = GBot.value(bc, nt, co if co != null else "")
					if d == null:
						return v
					v -= 35 * handNames.filter(func(x): return x == d.name).size()
					var pk = GBot._pk(d)
					if pk != null and GCore.truthy(pk.from) and fieldNames.has(pk.from):
						v += 45
					if pk != null and pk.stage == 2 and GBot._stage1Links(bc, fieldNames, pk.from):
						v += 30
					return v
				var sorted: Array
				if lose:
					sorted = GCore.stable_sort(opts, func(a, b):
						var cb = codeOf.call(b)
						var ca = codeOf.call(a)
						return GBot.value(bc, nt, cb if cb != null else "") - GBot.value(bc, nt, ca if ca != null else ""))
				else:
					sorted = GCore.stable_sort(opts, func(a, b): return gain.call(b) - gain.call(a))
				if lose:
					sorted.reverse()
					return take(req, sorted, maxi(mn, mx if p.contains("장당") else mn))
				return take(req, sorted, mx)
			_:
				return { "type": "choice", "requestId": req.id, "picks": randomPicks(req, rng) }

	# ── 내 차례 행동
	var all_acts = view.get("actions")
	if all_acts == null:
		all_acts = []
	var acts: Array = all_acts.filter(func(a): return a.kind != "concede")
	if acts.is_empty():
		return null
	var counted: Dictionary = st.counted
	if counted.turn != view.turnNumber or counted.seat != viewer or view.version < counted.version:
		counted.turn = view.turnNumber
		counted.version = view.version
		counted.seat = viewer
		counted.n = 0
	counted.version = view.version
	counted.n += 1
	var n: int = counted.n
	var end = GCore.find_first(acts, func(a): return a.kind == "endTurn")
	if n > 60 and end != null:
		return strip(end)
	var handCode = func(iid):
		if me.hand == null:
			return null
		var h = GCore.find_first(me.hand, func(x): return x.iid == iid)
		return h.code if h != null else null
	var act = me.active
	var actBest = bestAttack(top(bc, act))
	var attacks0: Array = acts.filter(func(a): return a.kind == "attack")
	var oppAct = opp.active
	var lowDeck: bool = me.deckCount <= 8

	# 1) 드로우·서치 특성 (커스드밤은 기절시킬 수 있을 때만, 사이코 임브레이스는 주력 에너지가 부족할 때만)
	var abilPred = func(a):
		if a.kind != "ability":
			return false
		var tg = a.get("target")
		var s = GBot.slotBySid(me, opp, tg if tg != null else "")
		var d = GBot.top(bc, s)
		var pk = GBot._pk(d)
		var ab = null
		if pk != null and pk.abilities.size() > 0:
			ab = pk.abilities[0].nameJa
		if ab == "カースドボム":
			var c: int = 130 if pk.stage == 2 else 50
			if opp.prizes.filter(func(x): return GCore.truthy(x)).size() <= 1:
				return false
			var targets: Array = [opp.active]
			targets.append_array(opp.bench)
			for t in targets:
				if t == null or GBot.remain(t) > c:
					continue
				var tpk = GBot._pk(GBot.top(bc, t))
				if tpk != null and GCore.truthy(tpk.rule):
					return true
			return false
		if ab == "サイコエンブレイス":
			return act != null and actBest != null and GBot.missing(bc, act, actBest.cost).size() > 0 and n < 20
		# 하늘의 봉인석 [스타오더]: 배틀의 기본 포켓몬 V 가 지금 기술로 상대 배틀의 VSTAR·VMAX 를 기절시킬 수 있을 때만
		if GCore.truthy(a.input.get("tool")):
			var adk = GBot._pk(GBot.top(bc, act))
			var odk = GBot._pk(GBot.top(bc, oppAct))
			if not is_same(s, act) or adk == null or adk.get("rule") != "V" or adk.stage != 0 or odk == null or (odk.get("rule") != "VSTAR" and odk.get("rule") != "VMAX"):
				return false
			return attacks0.any(func(m): return GBot.canKo(GBot.estimate(bc, me, opp, act, int(m.input.index)), oppAct))
		if ab == "검의 포효":
			return false   # 쓰면 차례가 끝남 → 맨 마지막에 (아래 7번 뒤)
		var drawy := ["さかてにとる", "リスタート", "ボーナスコイン", "ルナサイクル", "ていさつしれい", "리파인"]
		if lowDeck and drawy.has(ab if ab != null else ""):
			return false
		return true
	var abil = GCore.find_first(acts, abilPred)
	if abil != null:
		return strip(abil)
	# 2) 벤치에 기본 포켓몬 (벤치 1칸은 남김), 진화
	var bench = _pick(acts, "play", func(_m): return me.bench.size() < me.benchMax - 1)
	if bench != null:
		return strip(bench)
	var evo = _pick(acts, "evolve")
	if evo != null:
		return strip(evo)
	# 3) 트레이너스
	var trainers: Array = acts.filter(func(a): return a.kind == "trainer")
	var gustNames := ["보스의 지령", "카운터 캐처", "프라임 캐처"]
	for t in trainers:
		var d = card(bc, handCode.call(t.get("card")))
		var nm: String = d.name if d != null else ""
		if gustNames.has(nm):
			# 끌어낼 상대 벤치 중 지금 기술로 기절시킬 수 있는 것이 있을 때만
			if actBest != null and act != null and missing(bc, act, actBest.cost).size() == 0 and opp.bench.any(func(b): return GBot.canKo(actBest.dmg, b) and not GBot.canKo(actBest.dmg, oppAct)):
				return strip(t)
			continue
		if nm == "포켓몬 교체" or nm == "투로박사의 시나리오" or nm == "에너지 갈아 달기":
			continue
		var handN: int = me.hand.size() if me.hand != null else 0
		var noEnergy: bool = _countEnergy(bc, hand) == 0
		if nm == "모야모" and handN > 4 and not (opp.handCount >= 7):
			continue
		if nm == "릴리에의 결심" and ((handN > 5 and not noEnergy) or lowDeck):
			continue
		if nm == "모야모" and lowDeck and handN > 2:
			continue
		if nm == "태권왕의 수련" or nm == "카지":
			var ok := false
			if actBest != null and act != null and missing(bc, act, actBest.cost).size() == 0:
				var opk = _pk(top(bc, oppAct))
				ok = opk != null and GCore.truthy(opk.rule)
			if not ok:
				continue
		if d != null and d.get("trainer") == "stadium" and view.stadium != null:
			continue
		return strip(t)
	# 4) 에너지: 포켓몬마다 "가장 빨리 쓸 수 있는 기술"을 목표로, 그 기술에 필요한 에너지를 붙인다
	#    배틀 포켓몬이 공격도 후퇴도 못 하면 배틀 포켓몬 우선
	var attaches: Array = acts.filter(func(a): return a.kind == "attach")
	if attaches.size() > 0:
		var actStuck: bool = act != null and attacks0.is_empty() and _nz(act.get("retreat")) > units(bc, act).size()
		var plan = func(s):
			var pk = GBot._pk(GBot.top(bc, s))
			var atks = pk.get("attacks") if pk != null else null
			if atks == null:
				atks = []
			var xs: Array = atks.map(func(a): return { "need": GBot.missing(bc, s, a.cost), "dmg": a.damage if GCore.truthy(a.damage) else (40 if GCore.truthy(a.get("text")) else 0) })
			xs = xs.filter(func(x): return x.dmg > 0)
			xs = GCore.stable_sort(xs, func(x, y):
				var dl: int = x.need.size() - y.need.size()
				if dl != 0:
					return dl
				return y.dmg - x.dmg)
			return xs[0] if xs.size() > 0 else null
		var score = func(m):
			var tg = m.get("target")
			var s = GBot.slotBySid(me, opp, tg if tg != null else "")
			var d = GBot.card(bc, handCode.call(m.get("card")))
			if s == null:
				return -100
			var pl = plan.call(s)
			var isAct: bool = is_same(s, act)
			if isAct and actStuck:
				return 300
			if pl == null or pl.need.size() == 0:
				return -10 if isAct else -50
			var en = d.get("energy") if d != null else null
			var t = en.get("type") if en != null else null
			var spk = GBot._pk(GBot.top(bc, s))
			var fits: bool = pl.need.any(func(x): return x == t or x == "C") or (d != null and d.name == "루미너스 에너지") or (d != null and d.name == "네오 어퍼 에너지" and spk != null and spk.stage == 2)
			return (100 if fits else 0) + (60 if isAct else 0) + (20 if (spk != null and GCore.truthy(spk.rule)) else 0) + float(pl.dmg) / 10.0 - pl.need.size() * 5
		var best = GCore.stable_sort(attaches, func(a, b): return score.call(b) - score.call(a))[0]
		if score.call(best) > 0:
			return strip(best)
	# 5) 도구
	var toolPred = func(m):
		var d = GBot.card(bc, handCode.call(m.get("card")))
		var dname = d.name if d != null else null
		if dname == "기술머신 에볼루션":
			return false
		var tg = m.get("target")
		var s = GBot.slotBySid(me, opp, tg if tg != null else "")
		if dname == "풍선":
			var rt = act.get("retreat") if act != null else null
			return is_same(s, act) and GBot._nz(rt) >= 2
		var spk = GBot._pk(GBot.top(bc, s))
		if dname == "용기의부적":
			return spk != null and spk.stage == 0
		return is_same(s, act) or (spk != null and GCore.truthy(spk.rule))
	var tool = _pick(acts, "tool", toolPred)
	if tool != null:
		return strip(tool)
	var attacks: Array = acts.filter(func(a): return a.kind == "attack")
	var myBestNow: int = 0
	for m in attacks:
		myBestNow = maxi(myBestNow, estimate(bc, me, opp, act, int(m.input.index)))
	var swaps: Array = acts.filter(func(a): return a.kind == "retreat").map(func(m):
		var tg = m.get("target")
		return { "m": m, "d": GBot.readyBench(bc, GBot.slotBySid(me, opp, tg if tg != null else "")) })
	swaps = GCore.stable_sort(swaps, func(a, b): return b.d - a.d)
	var swapTo = swaps[0] if swaps.size() > 0 else null
	if swapTo != null and swapTo.d >= maxi(60, myBestNow * 2) and not GCore.truthy(me.flags.get("retreat")):
		return strip(swapTo.m)
	var switchCard = GCore.find_first(acts, func(a):
		if a.kind != "trainer":
			return false
		var sd = GBot.card(bc, handCode.call(a.get("card")))
		return sd != null and sd.name == "포켓몬 교체")
	if switchCard != null and me.bench.any(func(b): return GBot.readyBench(bc, b) >= maxi(60, myBestNow * 2)):
		return strip(switchCard)
	# 6) 기술: 가장 센 것 (기절시킬 수 있으면 그것)
	if attacks.size() > 0:
		var dmgOf = func(m):
			var i: int = int(m.input.index)
			var e: int = GBot.estimate(bc, me, opp, act, i)
			return (1000 if GBot.canKo(e, oppAct) else 0) + e
		var best = GCore.stable_sort(attacks, func(a, b): return dmgOf.call(b) - dmgOf.call(a))[0]
		return strip(best)
	# 7) 공격할 수 없으면 후퇴 (기술을 쓸 수 있는 벤치로)
	var sc = func(m):
		var tg = m.get("target")
		var s = GBot.slotBySid(me, opp, tg if tg != null else "")
		var bb = GBot.bestAttack(GBot.top(bc, s))
		if s == null or bb == null:
			return 0
		return (100 if GBot.missing(bc, s, bb.cost).size() == 0 else 0) + float(bb.dmg) / 10.0
	var retreats: Array = GCore.stable_sort(acts.filter(func(a): return a.kind == "retreat"), func(a, b): return sc.call(b) - sc.call(a))
	var retreat = retreats[0] if retreats.size() > 0 else null
	if retreat != null and act != null:
		var tg = retreat.get("target")
		var s = slotBySid(me, opp, tg if tg != null else "")
		var bb = bestAttack(top(bc, s))
		if s != null and bb != null and missing(bc, s, bb.cost).size() == 0:
			return strip(retreat)
	var stadium = _pick(acts, "stadium")
	if stadium != null:
		return strip(stadium)
	# 자시안 V "검의 포효": 공격할 수 없는 차례의 끝에 (쓰면 차례가 끝남)
	var sword = GCore.find_first(acts, func(a):
		if a.kind != "ability" or GCore.truthy(a.input.get("tool")):
			return false
		var tg = a.get("target")
		var spk = GBot._pk(GBot.top(bc, GBot.slotBySid(me, opp, tg if tg != null else "")))
		return spk != null and spk.abilities.size() > 0 and spk.abilities[0].nameJa == "검의 포효")
	if sword != null:
		return strip(sword)
	return strip(end) if end != null else null
