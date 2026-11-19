class_name GEffects
## src/game/effects.ts 포팅 — 카드 효과 (트레이너스·특성·기술) 를 프레임 처리기로 구현.
## 프레임 처리기 규칙: (ctx, f) 를 받아 ① done(ctx,f) 로 끝내거나 ② ask(...) 로 선택을 요청하고 멈추거나
##                    ③ seq(...) 로 하위 프레임을 쌓고 다음 단계로 넘어간다. 상태는 f.step / f.data 에만 둔다(직렬화 가능).
## 포팅 규칙: PORTING.md. FRAMES / TRAINERS / ABILITIES / ATTACKS 는 ensure() 가 처음 한 번 채운다.
## can 처리기는 항상 인자 3개 (ctx, seat, iid 또는 slot) 를 받는다 (엔진이 3개로 부름).

static var FRAMES: Dictionary = {}
static var TRAINERS: Dictionary = {}
static var ABILITIES: Dictionary = {}
static var ATTACKS: Dictionary = {}
static var plain: Dictionary = {}
static var noAttackNext: Dictionary = {}
static var _inited := false
static var _reWhat1: RegEx = null
static var _reWhat2: RegEx = null

static func ensure() -> void:
	if _inited:
		return
	_inited = true
	_initFrames()
	_initTrainers()
	_initAbilities()
	_initAttacks()
	_initFrames2()
	_initFrames3()

# ───────────────────────── 포팅 도우미 (TS 에 없는 것) ─────────────────────────

## TS String(x ?? '')
static func _nz(v) -> String:
	return "" if v == null else str(v)

## TS f.picks ?? []
static func _picks(f: Dictionary) -> Array:
	var p = f.get("picks")
	return p if p != null else []

## TS d.energy?.basic (참/거짓)
static func _ebasic(d: Dictionary) -> bool:
	var e = d.get("energy")
	return e != null and GCore.truthy(e.basic)

## TS d.shuffle !== false
static func _shuffles(d: Dictionary) -> bool:
	var v = d.get("shuffle")
	return not (v is bool and v == false)

# ───────────────────────── 프레임 기본 ─────────────────────────

static func done(ctx: Dictionary, f: Dictionary) -> void:
	var st: Array = ctx.s.stack
	for i in range(st.size() - 1, -1, -1):
		if is_same(st[i], f):
			st.remove_at(i)
			return

## 하위 프레임들을 순서대로 실행한 뒤 이 프레임을 nextStep 으로 다시 실행
static func seq(ctx: Dictionary, f: Dictionary, nextStep: int, children: Array) -> void:
	f.step = nextStep
	for i in range(children.size() - 1, -1, -1):
		var id := GCore.newId(ctx.s, "f")
		var data: Dictionary = (children[i][1] as Dictionary).duplicate()
		data["parent"] = f.id
		ctx.s.stack.append({ "id": id, "kind": children[i][0], "step": 0, "player": f.player, "data": data })

## 하위 프레임만 쌓고 이 프레임은 끝냄
static func then(ctx: Dictionary, f: Dictionary, children: Array) -> void:
	# 부모는 여기서 끝나므로 출처(어떤 카드·특성·기술인지)를 자식에게 물려준다 (공개 이유 표시용)
	var src = frameSource(ctx, f)
	done(ctx, f)
	for i in range(children.size() - 1, -1, -1):
		var id := GCore.newId(ctx.s, "f")
		var data: Dictionary = (children[i][1] as Dictionary).duplicate()
		if GCore.truthy(src):
			data["src"] = src
		ctx.s.stack.append({ "id": id, "kind": children[i][0], "step": 0, "player": f.player, "data": data })

static func parentOf(ctx: Dictionary, f: Dictionary):
	var par = f.data.get("parent")
	return GCore.find_first(ctx.s.stack, func(x): return x.id == par)

# ───────────────────────── 카드 조건 (필터) ─────────────────────────
# Filter = Dictionary { kind?, stage?, evolution?, basicEnergy?, etype?, ptype?, maxHp?, tera?, ex?, noRule?, trainer?, name?, or? }

static func matches(d: Dictionary, flt: Dictionary) -> bool:
	if flt.has("or"):
		return (flt["or"] as Array).any(func(x): return GEffects.matches(d, x))
	if GCore.truthy(flt.get("kind")) and d.kind != flt.kind:
		return false
	var p = d.get("pokemon")
	if flt.has("stage") and (p == null or p.stage != flt.stage):
		return false
	if GCore.truthy(flt.get("evolution")) and (p == null or p.stage == 0):
		return false
	if GCore.truthy(flt.get("basicEnergy")) and not _ebasic(d):
		return false
	if GCore.truthy(flt.get("etype")):
		var e = d.get("energy")
		var et = e.type if e != null else null
		if et != flt.etype:
			return false
	if GCore.truthy(flt.get("ptype")):
		var pt = p.type if p != null else null
		if pt != flt.ptype:
			return false
	if flt.has("maxHp") and (p == null or p.hp > flt.maxHp):
		return false
	if GCore.truthy(flt.get("tera")) and not (p != null and GCore.truthy(p.tera)):
		return false
	if GCore.truthy(flt.get("ex")) and (p == null or p.get("rule") == null):
		return false
	if GCore.truthy(flt.get("noRule")) and (p == null or p.get("rule") != null):
		return false
	if GCore.truthy(flt.get("trainer")) and d.get("trainer") != flt.trainer:
		return false
	if GCore.truthy(flt.get("name")) and d.name != flt.name:
		return false
	return true

static func cardsMatching(ctx: Dictionary, iids: Array, flt: Dictionary) -> Array:
	return iids.filter(func(i): return GEffects.matches(GCore.dataOf(ctx, i), flt))

static func cardsOf(ctx: Dictionary, iids: Array) -> Array:
	return iids.map(func(iid): return { "iid": iid, "code": GCore.inst(ctx, iid).code })

# ───────────────────────── 출처 / 공개 이유 ─────────────────────────

## 이 프레임이 나타내는 카드·특성·기술 이름 (없으면 null)
static func frameSource(ctx: Dictionary, fr: Dictionary):
	var data: Dictionary = fr.data
	if data.get("src") is String:
		return data.src
	if fr.kind == "trainerRun":
		return "트레이너스 [" + _nz(data.get("name")) + "]"
	if fr.kind == "trigger":
		# 조건이 되면 발동하는 특성 (진화했을 때 등)
		var found = GCore.findSlot(ctx.s, _nz(data.get("sid")))
		var names := { "infernalReign": "연옥 지배", "jewelSeeker": "보석 찾기", "flyingEntry": "플라잉엔트리", "rapidVernier": "래피드 버니어", "darkSignal": "다크시그널" }
		var name: String = names.get(str(data.get("effect")), "")
		var who: String = GCore.slotName(ctx, found.slot) if found != null else "포켓몬"
		return who + "의 특성" + ((" [" + name + "]") if name != "" else "") + " (조건이 되어 발동)"
	if fr.kind == "abilityRun" or fr.kind == "attack" or fr.kind == "attackEffect":
		var found = GCore.findSlot(ctx.s, _nz(data.get("sid")))
		var who: String = GCore.slotName(ctx, found.slot) if found != null else "포켓몬"
		var pk = GCore.slotData(ctx, found.slot).get("pokemon") if found != null else null
		if fr.kind == "abilityRun":
			var abj = data.get("ab")
			var ab = GCore.find_first(pk.abilities, func(a): return a.nameJa == abj) if pk != null else null
			var abn: String = ab.name if (ab != null and GCore.truthy(ab.name)) else _nz(abj)
			return who + "의 특성 [" + abn + "]"
		var atj = data.get("attackJa")
		var at = GCore.find_first(pk.attacks, func(a): return a.nameJa == atj) if pk != null else null
		var atn: String = at.name if (at != null and GCore.truthy(at.name)) else _nz(atj)
		return who + "의 기술 [" + atn + "]"
	return null

## 지금 처리 중인 효과의 출처 (스택을 위에서부터 보고 가장 가까운 카드·특성·기술)
static func effectSource(ctx: Dictionary) -> String:
	var st: Array = ctx.s.stack
	for i in range(st.size() - 1, -1, -1):
		var label = frameSource(ctx, st[i])
		if GCore.truthy(label):
			return label
	return "카드 효과"

const ZONE_KO := { "deck": "덱", "discard": "트래쉬", "hand": "패" }
const TO_KO := { "hand": "패로 가져갑니다", "bench": "벤치에 내놓습니다", "deck": "덱으로 되돌립니다", "attach": "포켓몬에게 붙입니다", "top": "덱 위에 놓습니다", "save": "사용합니다" }

## 공개 이유: 무엇이(출처) · 어디서 무엇을 찾아 · 어디로, 그리고 왜 보여주는지 (규칙)
static func revealReason(ctx: Dictionary, d: Dictionary) -> String:
	if _reWhat1 == null:
		_reWhat1 = RegEx.new()
		_reWhat1.compile("\\s*(을|를)?\\s*고르세요\\.?$")
		_reWhat2 = RegEx.new()
		_reWhat2.compile("\\.$")
	var prompt = d.get("prompt")
	var what: String = str(prompt) if prompt != null else "카드"
	what = _reWhat1.sub(what, "")
	what = _reWhat2.sub(what, "")
	var look = d.get("look")
	var from_s: String = ("덱 위 " + str(look) + "장") if GCore.truthy(look) else str(ZONE_KO.get(d["from"], d["from"]))
	var why: String
	if d["from"] == "deck":
		why = "덱에서 정해진 종류의 카드를 찾으면, 조건에 맞는 카드인지 상대에게 보여줘야 합니다."
	elif d["from"] == "discard":
		why = "트래쉬에서 가져가는 카드는 무엇인지 상대에게 보여줍니다."
	else:
		why = "효과로 고른 카드를 상대에게 보여줍니다."
	return effectSource(ctx) + ": " + from_s + "에서 [" + what + "] → " + str(TO_KO.get(d["to"], "사용합니다")) + "\n" + why

# ───────────────────────── 트레이너스 도우미 ─────────────────────────

static func deckN(ctx: Dictionary, seat: int) -> int:
	return ctx.s.players[seat].deck.size()

static func benchRoom(ctx: Dictionary, seat: int) -> int:
	return ctx.s.players[seat].benchMax - ctx.s.players[seat].bench.size()

static func handOthers(ctx: Dictionary, seat: int, me) -> int:
	return ctx.s.players[seat].hand.filter(func(i): return i != me).size()

static func discardHas(ctx: Dictionary, seat: int, flt: Dictionary) -> bool:
	return cardsMatching(ctx, ctx.s.players[seat].discard, flt).size() > 0

static func needDeck(ctx: Dictionary, seat: int):
	return null if deckN(ctx, seat) > 0 else "덱에 카드가 없습니다."

const POKEMON := { "kind": "pokemon" }
const BASIC := { "kind": "pokemon", "stage": 0 }
const BASIC_ENERGY := { "kind": "energy", "basicEnergy": true }

static func search(from_zone: String, flt: Dictionary, mx: int, to_zone: String, extra: Dictionary = {}) -> Array:
	var d := { "from": from_zone, "filter": flt, "max": mx, "to": to_zone }
	for k in extra:
		d[k] = extra[k]
	return ["search", d]

# ───────────────────────── 공용 프레임 ─────────────────────────

static func _initFrames() -> void:
	## 카드 고르기 (덱·트래쉬): data = { from, filter, min, max, to, reveal, shuffle, prompt, distinct, look, exclude, save }
	##  to: 'hand' | 'bench' | 'deck'(덱으로 되돌림) | 'attach'(고른 뒤 붙일 포켓몬을 한 장씩 고름) | 'top'(덱 위, 순서 고르기) | 'save'(부모 data[save] 에 iid 저장)
	FRAMES["search"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var d: Dictionary = f.data
		var p: Dictionary = ctx.s.players[f.player]
		if f.step == 0:
			var zone: Array
			if d["from"] == "deck":
				zone = p.deck
			elif d["from"] == "discard":
				zone = p.discard
			else:
				zone = p.hand
			var look = d.get("look")
			var pool: Array = zone.slice(0, look) if GCore.truthy(look) else zone
			var exclude: Array = d.exclude if d.get("exclude") != null else []
			var opts: Array = GEffects.cardsMatching(ctx, pool, d["filter"]).filter(func(i): return not exclude.has(i))
			var mx: int = d["max"]
			if d["to"] == "bench":
				mx = mini(mx, p.benchMax - p.bench.size())
			if mx <= 0 or opts.size() == 0:
				if d["from"] == "deck" and pool.size() > 0 and opts.size() == 0:
					GCore.note(ctx, "조건에 맞는 카드가 없습니다.")
				f.step = 2
				if d["from"] == "deck" and GEffects._shuffles(d):
					GCore.shuffleDeck(ctx, f.player)
				GEffects.done(ctx, f)
				return
			# 덱을 보는 효과: 고르는 사람에게만 보이는 카드 목록(보기 범위 전체)을 함께 보낸다
			var shown: Array = GEffects.cardsOf(ctx, pool) if d["from"] == "deck" else GEffects.cardsOf(ctx, opts)
			var mn: int = d["min"] if d.get("min") != null else 0
			var prompt: String = d.prompt if d.get("prompt") != null else "카드를 고르세요."
			GCore.ask(ctx, f, 1, f.player, "pickCards", opts, mn, mx, prompt, { "cards": shown })
			return
		if f.step == 1:
			var picks: Array = GEffects._picks(f)
			if d.get("distinct") == "type":
				# 서로 다른 타입만 (같은 타입이면 앞의 것만)
				var seen := {}
				picks = picks.filter(func(i):
					var e = GCore.dataOf(ctx, i).get("energy")
					var t = e.type if e != null else null
					if t == null:
						var pk = GCore.dataOf(ctx, i).get("pokemon")
						t = pk.type if pk != null else null
					if t == null:
						t = ""
					if seen.has(t):
						return false
					seen[t] = true
					return true)
			var moved: Array = []
			if GCore.truthy(d.get("reveal")) and picks.size() > 0:
				var rev := { "id": GCore.newId(ctx.s, "v"), "owner": f.player, "reason": GEffects.revealReason(ctx, d), "cards": GEffects.cardsOf(ctx, picks) }
				ctx.s.reveals.append(rev)
				GCore.emit(ctx, { "type": "reveal", "reveal": rev })
				ctx.s.requests.append({ "id": GCore.newId(ctx.s, "r"), "player": GCore.other(f.player), "kind": "ackReveal", "options": ["ok"], "min": 1, "max": 1, "prompt": "상대가 보여준 카드를 확인하세요.", "revealId": rev.id })
			for iid in picks:
				match d["to"]:
					"hand":
						moved.append(GCore.moveCard(ctx, iid, { "zone": "hand", "player": f.player }))
					"bench":
						moved.append(GCore.moveCard(ctx, iid, { "zone": "bench", "player": f.player }))
					"deck":
						moved.append(GCore.moveCard(ctx, iid, { "zone": "deck", "player": f.player, "position": "bottom" }))
					"attachTo":
						moved.append(GCore.moveCard(ctx, iid, { "zone": "attach", "sid": d.attachTo }))
					_:
						moved.append(iid)
			if d["to"] == "attach":
				d["pending"] = picks
				f.step = 3
				return
			if d["to"] == "save":
				var par = GEffects.parentOf(ctx, f)
				if par != null:
					par.data[d.save] = picks
			if GCore.truthy(d.get("save")) and d["to"] != "save":
				var par2 = GEffects.parentOf(ctx, f)
				if par2 != null:
					par2.data[d.save] = moved
			if d["from"] == "deck" and GEffects._shuffles(d):
				GCore.shuffleDeck(ctx, f.player)
			GEffects.done(ctx, f)
			return
		if f.step == 3 or f.step == 4:
			# 고른 에너지를 한 장씩 붙일 포켓몬 고르기
			if f.step == 4 and GEffects._picks(f).size() > 0:
				var pend0: Array = d.pending
				GCore.moveCard(ctx, pend0[0], { "zone": "attach", "sid": f.picks[0] })
				d["pending"] = pend0.slice(1)
			var pend: Array = d.pending
			if pend.is_empty():
				if d["from"] == "deck" and GEffects._shuffles(d):
					GCore.shuffleDeck(ctx, f.player)
				GEffects.done(ctx, f)
				return
			var slots: Array
			if GCore.truthy(d.get("attachTo")):
				slots = [d.attachTo]
			else:
				slots = GCore.slotsOf(ctx.s, f.player).map(func(sl): return sl.sid)
			GCore.ask(ctx, f, 4, f.player, "pickSlot", slots, 1, 1, GCore.nameOf(ctx, pend[0]) + "을(를) 붙일 포켓몬을 고르세요.", { "cards": GEffects.cardsOf(ctx, [pend[0]]) })
			return

	FRAMES["shuffle"] = func(ctx: Dictionary, f: Dictionary) -> void:
		GCore.shuffleDeck(ctx, f.player)
		GEffects.done(ctx, f)

	FRAMES["draw"] = func(ctx: Dictionary, f: Dictionary) -> void:
		GCore.drawN(ctx, f.player, int(f.data.n))
		GEffects.done(ctx, f)

	## 패에서 n장 버리기 (비용) — data { n, exclude? , save? }
	FRAMES["discardHand"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		var n := int(f.data.n)
		if f.step == 0:
			var ex = f.data.get("exclude")
			var opts: Array = p.hand.filter(func(i): return not (ex != null and ex.has(i)))
			GCore.ask(ctx, f, 1, f.player, "pickCards", opts, n, n, "패에서 " + str(n) + "장을 트래쉬하세요.", { "cards": GEffects.cardsOf(ctx, opts) })
			return
		var moved: Array = GEffects._picks(f).map(func(i): return GCore.moveCard(ctx, i, { "zone": "discard", "player": f.player }))
		if GCore.truthy(f.data.get("save")):
			var par = GEffects.parentOf(ctx, f)
			if par != null:
				par.data[str(f.data.save)] = moved
		GEffects.done(ctx, f)

	## 내 배틀 포켓몬을 벤치와 교체 — data { optional? }
	FRAMES["switchOwn"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		if f.step == 0:
			if p.bench.is_empty() or p.active == null:
				GEffects.done(ctx, f)
				return
			GCore.ask(ctx, f, 1, f.player, "pickSlot", p.bench.map(func(b): return b.sid), 0 if GCore.truthy(f.data.get("optional")) else 1, 1, "배틀 포켓몬과 바꿀 벤치 포켓몬을 고르세요.")
			return
		if GEffects._picks(f).size() > 0:
			GCore.switchActive(ctx, f.player, f.picks[0])
		GEffects.done(ctx, f)

	## 상대 벤치 포켓몬을 배틀 포켓몬과 교체 (상대 플레이어가 아니라 사용자가 고름)
	FRAMES["gust"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var opp := GCore.other(f.player)
		var p: Dictionary = ctx.s.players[opp]
		if f.step == 0:
			if p.bench.is_empty():
				GEffects.done(ctx, f)
				return
			GCore.ask(ctx, f, 1, f.player, "pickSlot", p.bench.map(func(b): return b.sid), 1, 1, "배틀 필드로 끌어낼 상대 벤치 포켓몬을 고르세요.")
			return
		if GEffects._picks(f).size() > 0:
			GCore.switchActive(ctx, opp, f.picks[0])
		GEffects.done(ctx, f)

	## 예/아니오 — 부모 data[save] = 'yes'|'no'
	FRAMES["yesno"] = func(ctx: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			GCore.ask(ctx, f, 1, f.player, "pickOption", ["yes", "no"], 1, 1, str(f.data.get("prompt")), { "labels": { "yes": "예", "no": "아니오" } })
			return
		var par = GEffects.parentOf(ctx, f)
		if par != null:
			var pk: Array = GEffects._picks(f)
			par.data[str(f.data.get("save"))] = pk[0] if pk.size() > 0 else "no"
		GEffects.done(ctx, f)

	# 트레이너스 하위 프레임 ─────────────

	FRAMES["glassTrumpet"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		var chosen: Array = f.data.chosen if f.data.get("chosen") != null else []
		if f.step == 0 or f.step == 2:
			if f.step == 2 and GEffects._picks(f).size() > 0:
				var ens: Array = GEffects.cardsMatching(ctx, p.discard, GEffects.BASIC_ENERGY)
				var e = ens[0] if ens.size() > 0 else null
				if GCore.truthy(e):
					GCore.moveCard(ctx, e, { "zone": "attach", "sid": f.picks[0] })
					chosen.append(f.picks[0])
					f.data["chosen"] = chosen
			if f.step == 2 and GEffects._picks(f).size() == 0:
				GEffects.done(ctx, f)
				return
			var opts: Array = p.bench.map(func(b): return b.sid).filter(func(sid): return not chosen.has(sid))
			if chosen.size() >= 2 or opts.is_empty() or GEffects.cardsMatching(ctx, p.discard, GEffects.BASIC_ENERGY).is_empty():
				GEffects.done(ctx, f)
				return
			GCore.ask(ctx, f, 2, f.player, "pickSlot", opts, 0, 1, "트래쉬의 기본 에너지를 붙일 벤치 포켓몬 (" + str(chosen.size() + 1) + "/2, 그만하려면 고르지 않고 결정)")
			return

	FRAMES["crispin"] = func(ctx: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			GEffects.seq(ctx, f, 1, [GEffects.search("deck", GEffects.BASIC_ENERGY, 2, "save", { "save": "picked", "distinct": "type", "shuffle": false, "prompt": "서로 다른 타입의 기본 에너지를 2장까지 고르세요." })])
			return
		var picked: Array = f.data.picked if f.data.get("picked") != null else []
		if f.step == 1:
			if picked.size() == 0:
				GCore.shuffleDeck(ctx, f.player)
				GEffects.done(ctx, f)
				return
			if picked.size() == 1:
				GCore.moveCard(ctx, picked[0], { "zone": "hand", "player": f.player })
				GCore.shuffleDeck(ctx, f.player)
				GEffects.done(ctx, f)
				return
			GCore.ask(ctx, f, 2, f.player, "pickCards", picked, 1, 1, "패로 가져올 에너지 1장 (나머지는 포켓몬에 붙임)", { "cards": GEffects.cardsOf(ctx, picked) })
			return
		if f.step == 2:
			var toHand = f.picks[0]
			f.data["rest"] = picked.filter(func(i): return i != toHand)
			GCore.moveCard(ctx, toHand, { "zone": "hand", "player": f.player })
			GCore.ask(ctx, f, 3, f.player, "pickSlot", GCore.slotsOf(ctx.s, f.player).map(func(sl): return sl.sid), 1, 1, "나머지 에너지를 붙일 포켓몬을 고르세요.")
			return
		for e in f.data.rest:
			GCore.moveCard(ctx, e, { "zone": "attach", "sid": f.picks[0] })
		GCore.shuffleDeck(ctx, f.player)
		GEffects.done(ctx, f)

	FRAMES["scoopUp"] = func(ctx: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			GCore.ask(ctx, f, 1, f.player, "pickSlot", GCore.slotsOf(ctx.s, f.player).map(func(sl): return sl.sid), 1, 1, "패로 되돌릴 포켓몬을 고르세요 (포켓몬 외 카드는 트래쉬).")
			return
		var found = GCore.findSlot(ctx.s, f.picks[0])
		if found != null:
			GCore.clearSlot(ctx, found.slot, f.player, "hand")
		GEffects.done(ctx, f)
		# 배틀 포켓몬을 되돌렸으면 새 배틀 포켓몬
		if ctx.s.players[f.player].active == null:
			GCore.pushFrame(ctx, "promote", f.player, {})

	FRAMES["carmine"] = func(ctx: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			var opts: Array = ["boost"]
			if ctx.s.players[f.player].bench.size() > 0:
				opts.push_front("switch")
			GCore.ask(ctx, f, 1, f.player, "pickOption", opts, 1, 1, "카지: 효과를 고르세요.", { "labels": { "switch": "배틀 포켓몬 교체", "boost": "이번 차례 ex·V 에게 +30" } })
			return
		var pk: Array = GEffects._picks(f)
		if pk.size() > 0 and pk[0] == "switch":
			GEffects.then(ctx, f, [["switchOwn", {}]])
			return
		ctx.s.players[f.player].effects.append({ "kind": "boostExV30", "until": ctx.s.turnNumber })
		GEffects.done(ctx, f)

	## 이상한사탕: 대상 기본 포켓몬(data.target)에 패의 2진화를 바로 올린다
	FRAMES["rareCandy"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var target = GCore.findSlot(ctx.s, str(f.data.get("target")))
		if target == null:
			GEffects.done(ctx, f)
			return
		var opts: Array = GEffects.candyCards(ctx, f.player, target.slot)
		if f.step == 0:
			GCore.ask(ctx, f, 1, f.player, "pickCards", opts, 1, 1, "진화시킬 2진화 포켓몬을 고르세요.", { "cards": GEffects.cardsOf(ctx, opts) })
			return
		if GEffects._picks(f).size() > 0:
			GEffects.evolveFrom(ctx, f.player, f.picks[0], target.slot.sid)
		GEffects.done(ctx, f)

	FRAMES["superRetrieval"] = func(ctx: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			GEffects.seq(ctx, f, 1, [["discardHand", { "n": 2, "save": "discarded" }]])
			return
		if f.step == 1:
			var disc = f.data.get("discarded")
			GEffects.seq(ctx, f, 2, [GEffects.search("discard", GEffects.BASIC_ENERGY, 4, "hand", { "min": 1, "reveal": true, "exclude": disc if disc != null else [], "prompt": "트래쉬의 기본 에너지를 4장까지 고르세요." })])
			return
		GEffects.done(ctx, f)

	FRAMES["cipher"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		if f.step == 0:
			GCore.ask(ctx, f, 1, f.player, "pickCards", p.deck.duplicate(), mini(2, p.deck.size()), 2, "덱 위에 놓을 카드를 2장 고르세요.", { "cards": GEffects.cardsOf(ctx, p.deck) })
			return
		if f.step == 1:
			f.data["chosen"] = GEffects._picks(f)
			# 고른 카드를 잠시 빼 두고 셔플 → 덱 위에 올림 (순서는 다음 단계)
			var chosen: Array = f.data.chosen
			if chosen.size() < 2:
				GCore.shuffleDeck(ctx, f.player)
				var _moved: Array = chosen.map(func(i): return GEffects.moveCardKeep(ctx, i, f.player))
				GEffects.done(ctx, f)
				return
			GCore.ask(ctx, f, 2, f.player, "pickCards", chosen, 1, 1, "맨 위에 둘 카드를 고르세요.", { "cards": GEffects.cardsOf(ctx, chosen) })
			return
		var chosen2: Array = f.data.chosen
		var top = f.picks[0]
		var second = GCore.find_first(chosen2, func(i): return i != top)
		# 두 장을 빼고 나머지 셔플 후, 두 번째 → 맨 위 순서로 올린다
		var p2: Dictionary = ctx.s.players[f.player]
		p2.deck = p2.deck.filter(func(i): return i != top and i != second)
		GCore.shuffleDeck(ctx, f.player)
		p2.deck.push_front(second)
		p2.deck.push_front(top)
		GEffects.done(ctx, f)

	FRAMES["energySwitch"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var slots: Array = GCore.slotsOf(ctx.s, f.player)
		if f.step == 0:
			var opts: Array = slots.filter(func(sl): return GCore.energiesOf(ctx, sl).any(func(e): return GEffects._ebasic(GCore.dataOf(ctx, e)))).map(func(sl): return sl.sid)
			GCore.ask(ctx, f, 1, f.player, "pickSlot", opts, 1, 1, "기본 에너지를 뗄 포켓몬을 고르세요.")
			return
		if f.step == 1:
			f.data["from"] = f.picks[0]
			var src: Dictionary = GCore.findSlot(ctx.s, f.picks[0]).slot
			var ens: Array = GCore.energiesOf(ctx, src).filter(func(e): return GEffects._ebasic(GCore.dataOf(ctx, e)))
			GCore.ask(ctx, f, 2, f.player, "pickCards", ens, 1, 1, "옮길 기본 에너지를 고르세요.", { "cards": GEffects.cardsOf(ctx, ens) })
			return
		if f.step == 2:
			f.data["energy"] = f.picks[0]
			var fromSid = f.data["from"]
			GCore.ask(ctx, f, 3, f.player, "pickSlot", slots.map(func(sl): return sl.sid).filter(func(sid): return sid != fromSid), 1, 1, "에너지를 붙일 포켓몬을 고르세요.")
			return
		GCore.moveCard(ctx, str(f.data.energy), { "zone": "attach", "sid": f.picks[0] })
		GEffects.done(ctx, f)

	## 선택형 발동 특성: 쓸지 묻고 쓰면 효과
	FRAMES["trigger"] = func(ctx: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			GEffects.seq(ctx, f, 1, [["yesno", { "prompt": str(f.data.get("prompt")), "save": "answer" }]])
			return
		if f.data.get("answer") != "yes":
			GEffects.done(ctx, f)
			return
		var slot = GCore.findSlot(ctx.s, str(f.data.get("sid")))
		if slot != null:
			var code = GCore.inst(ctx, GCore.topOf(slot.slot)).code
			var pk = GCore.slotData(ctx, slot.slot).get("pokemon")
			var ab0 = pk.abilities[0] if (pk != null and pk.abilities.size() > 0) else null
			var nm = ""
			if ab0 != null and GCore.truthy(ab0.name):
				nm = ab0.name
			elif ab0 != null and GCore.truthy(ab0.nameJa):
				nm = ab0.nameJa
			GCore.emit(ctx, { "type": "ability", "player": f.player, "code": code, "name": nm })
		match f.data.get("effect"):
			"infernalReign":
				GEffects.then(ctx, f, [GEffects.search("deck", { "kind": "energy", "basicEnergy": true, "etype": "R" }, 3, "attach", { "prompt": "붙일 기본 불꽃 에너지를 3장까지 고르세요." })])
				return
			"jewelSeeker":
				GEffects.then(ctx, f, [GEffects.search("deck", { "kind": "trainer" }, 2, "hand", { "reveal": true, "prompt": "트레이너스를 2장까지 고르세요." })])
				return
			"flyingEntry":
				GEffects.then(ctx, f, [["flyingEntry", {}]])
				return
			"rapidVernier":
				GEffects.then(ctx, f, [["rapidVernier", { "sid": f.data.get("sid") }]])
				return
			"darkSignal":
				GEffects.then(ctx, f, [["gust", {}]])
				return
		GEffects.done(ctx, f)

	FRAMES["flyingEntry"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var opp: Dictionary = ctx.s.players[GCore.other(f.player)]
		if f.step == 0:
			GCore.ask(ctx, f, 1, f.player, "pickSlot", opp.bench.map(func(b): return b.sid), mini(2, opp.bench.size()), 2, "데미지 카운터를 1개씩 올릴 상대 벤치 포켓몬 2마리")
			return
		for sid in GEffects._picks(f):
			var t = GCore.findSlot(ctx.s, sid)
			if t != null:
				GCore.putCounters(ctx, t.slot, 1)
		GEffects.done(ctx, f)

	FRAMES["rapidVernier"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		if f.step == 0:
			GCore.switchActive(ctx, f.player, str(f.data.get("sid")))
			f.step = 1
		# 벤치 포켓몬의 에너지를 원하는 만큼 옮김: 에너지를 하나씩 고름 (그만하려면 고르지 않음)
		if f.step == 2 and GEffects._picks(f).size() > 0:
			GCore.moveCard(ctx, f.picks[0], { "zone": "attach", "sid": p.active.sid })
		if f.step == 2 and GEffects._picks(f).size() == 0:
			GEffects.done(ctx, f)
			return
		var opts: Array = []
		for b in p.bench:
			opts.append_array(GCore.energiesOf(ctx, b))
		if opts.is_empty():
			GEffects.done(ctx, f)
			return
		GCore.ask(ctx, f, 2, f.player, "pickCards", opts, 0, 1, "배틀 포켓몬으로 옮길 에너지 (그만하려면 고르지 않고 결정)", { "cards": GEffects.cardsOf(ctx, opts) })

	FRAMES["cursedBomb"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var me = GEffects.slotOfFrame(ctx, f)
		if me == null:
			GEffects.done(ctx, f)
			return
		var pk = GCore.slotData(ctx, me).get("pokemon")
		var n: int = 13 if (pk != null and pk.stage == 2) else 5
		if f.step == 0:
			GCore.ask(ctx, f, 1, f.player, "pickSlot", GCore.slotsOf(ctx.s, GCore.other(f.player)).map(func(sl): return sl.sid), 1, 1, "데미지 카운터 " + str(n) + "개를 올릴 상대 포켓몬")
			return
		var t = GCore.findSlot(ctx.s, f.picks[0])
		if t != null:
			GCore.putCounters(ctx, t.slot, n)
		# 이 포켓몬은 기절 (기절 처리는 뒤의 기절 확인에서)
		me.damage = maxi(me.damage, GCore.maxHp(ctx, me))
		GCore.note(ctx, GCore.slotName(ctx, me) + ": 커스드밤으로 기절")
		GEffects.done(ctx, f)

	FRAMES["lunarCycle"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		var opts: Array = p.hand.filter(func(i): return GEffects.matches(GCore.dataOf(ctx, i), { "kind": "energy", "basicEnergy": true, "etype": "F" }))
		if f.step == 0:
			GCore.ask(ctx, f, 1, f.player, "pickCards", opts, 1, 1, "트래쉬할 기본 격투 에너지", { "cards": GEffects.cardsOf(ctx, opts) })
			return
		GCore.moveCard(ctx, f.picks[0], { "zone": "discard", "player": f.player })
		GCore.drawN(ctx, f.player, 3)
		GEffects.done(ctx, f)

	FRAMES["adrenaBrain"] = func(ctx: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			GCore.ask(ctx, f, 1, f.player, "pickSlot", GCore.slotsOf(ctx.s, f.player).filter(func(sl): return sl.damage > 0).map(func(sl): return sl.sid), 1, 1, "데미지 카운터를 옮길 내 포켓몬")
			return
		if f.step == 1:
			f.data["from"] = f.picks[0]
			var src0: Dictionary = GCore.findSlot(ctx.s, f.picks[0]).slot
			var n0 := mini(3, floori(float(src0.damage) / 10))
			var opts: Array = []
			for i in range(n0):
				opts.append(str(i + 1))
			var labels := {}
			for o in opts:
				labels[o] = o + "개"
			GCore.ask(ctx, f, 2, f.player, "pickOption", opts, 1, 1, "옮길 데미지 카운터 수", { "labels": labels })
			return
		if f.step == 2:
			f.data["n"] = int(f.picks[0])
			GCore.ask(ctx, f, 3, f.player, "pickSlot", GCore.slotsOf(ctx.s, GCore.other(f.player)).map(func(sl): return sl.sid), 1, 1, "데미지 카운터를 올릴 상대 포켓몬")
			return
		var fs = GCore.findSlot(ctx.s, str(f.data.get("from")))
		var src = fs.slot if fs != null else null
		var fd = GCore.findSlot(ctx.s, f.picks[0])
		var dst = fd.slot if fd != null else null
		var n := int(f.data.n)
		if src != null and dst != null:
			src.damage -= n * 10
			GCore.emit(ctx, { "type": "heal", "player": f.player, "sid": src.sid, "amount": n * 10 })
			GCore.putCounters(ctx, dst, n)
		GEffects.done(ctx, f)

	FRAMES["recon"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		var top2: Array = p.deck.slice(0, 2)
		if f.step == 0:
			GCore.ask(ctx, f, 1, f.player, "pickCards", top2, 1, 1, "덱 위 2장 중 패로 가져올 1장 (나머지는 덱 아래)", { "cards": GEffects.cardsOf(ctx, top2) })
			return
		var pick = f.picks[0]
		for i in top2:
			if i == pick:
				GCore.moveCard(ctx, i, { "zone": "hand", "player": f.player })
			else:
				GCore.moveCard(ctx, i, { "zone": "deck", "player": f.player, "position": "bottom" })
		GEffects.done(ctx, f)

	FRAMES["psychicEmbrace"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		var ens: Array = GEffects.cardsMatching(ctx, p.discard, { "kind": "energy", "basicEnergy": true, "etype": "P" })
		if f.step == 0:
			var okSlots: Array = GCore.slotsOf(ctx.s, f.player).filter(func(sl):
				if not (GCore.remainingHp(ctx, sl) > 20):
					return false
				var pk = GCore.slotData(ctx, sl).get("pokemon")
				return pk != null and pk.type == "P")
			var opts: Array = okSlots.map(func(sl): return sl.sid)
			GCore.ask(ctx, f, 1, f.player, "pickSlot", opts, 1, 1, "초 에너지를 붙일 초 포켓몬 (데미지 카운터 2개)")
			return
		var fs = GCore.findSlot(ctx.s, f.picks[0])
		var t = fs.slot if fs != null else null
		if t != null and ens.size() > 0:
			GCore.moveCard(ctx, ens[0], { "zone": "attach", "sid": t.sid })
			GCore.putCounters(ctx, t, 2)
		GEffects.done(ctx, f)

# ───────────────────────── 트레이너스 ─────────────────────────
# TRAINERS[name] = { can?: func(ctx, seat, selfIid) -> String|null, run: Handler }  (f.data.card = 사용 중인 카드 iid)

static func _initTrainers() -> void:
	var t: Dictionary

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		var r = GEffects.needDeck(c, s)
		if r != null:
			return r
		return null if GEffects.benchRoom(c, s) > 0 else "벤치가 가득 찼습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", GEffects.BASIC, 1, "bench", { "prompt": "벤치에 낼 기본 포켓몬을 고르세요." })])
	TRAINERS["네스트볼"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, me):
		return null if GEffects.handOthers(c, s, me) >= 2 else "패를 2장 트래쉬해야 합니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["discardHand", { "n": 2 }], GEffects.search("deck", GEffects.POKEMON, 1, "hand", { "reveal": true, "prompt": "패로 가져올 포켓몬을 고르세요." })])
	TRAINERS["하이퍼볼"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		var r = GEffects.needDeck(c, s)
		if r != null:
			return r
		return null if GEffects.benchRoom(c, s) > 0 else "벤치가 가득 찼습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", { "kind": "pokemon", "stage": 0, "maxHp": 70 }, 2, "bench", { "prompt": "HP 70 이하 기본 포켓몬을 2장까지 고르세요." })])
	TRAINERS["절친 포핀"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", { "kind": "pokemon", "tera": true }, 1, "hand", { "reveal": true, "prompt": "테라스탈 포켓몬을 고르세요." })])
	TRAINERS["테라스탈오브"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		if GCore.prizesLeft(c.s, s) > GCore.prizesLeft(c.s, GCore.other(s)):
			return null if c.s.players[GCore.other(s)].bench.size() > 0 else "상대 벤치가 없습니다."
		return "내 사이드가 상대보다 많을 때만 쓸 수 있습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["gust", {}]])
	TRAINERS["카운터 캐처"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		return null if GEffects.discardHas(c, s, { "or": [GEffects.POKEMON, GEffects.BASIC_ENERGY] }) else "트래쉬에 포켓몬·기본 에너지가 없습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("discard", { "or": [GEffects.POKEMON, GEffects.BASIC_ENERGY] }, 1, "hand", { "min": 1, "reveal": true, "prompt": "패로 가져올 포켓몬 또는 기본 에너지를 고르세요." })])
	TRAINERS["밤의 들것"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		return null if c.s.players[s].bench.size() > 0 else "벤치 포켓몬이 없습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["switchOwn", {}]])
	TRAINERS["포켓몬 교체"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		if not GCore.hasTera(c, s):
			return "테라스탈 포켓몬이 있어야 합니다."
		if c.s.players[s].bench.is_empty():
			return "벤치 포켓몬이 없습니다."
		return null if GEffects.discardHas(c, s, GEffects.BASIC_ENERGY) else "트래쉬에 기본 에너지가 없습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["glassTrumpet", {}]])
	TRAINERS["유리나팔"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["crispin", {}]])
	TRAINERS["하솔"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		return null if c.s.players[GCore.other(s)].bench.size() > 0 else "상대 벤치가 없습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["gust", {}]])
	TRAINERS["보스의 지령"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		for seat in [f.player, GCore.other(f.player)]:
			var p: Dictionary = c.s.players[seat]
			for iid in p.hand.duplicate():
				GCore.moveCard(c, iid, { "zone": "deck", "player": seat, "position": "bottom" })
		for seat in [f.player, GCore.other(f.player)]:
			GCore.drawN(c, seat, GCore.prizesLeft(c.s, seat))
		GEffects.done(c, f)
	TRAINERS["모야모"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", { "kind": "pokemon", "ex": true }, 3, "hand", { "reveal": true, "prompt": "포켓몬 ex 를 3장까지 고르세요." })])
	TRAINERS["시아노"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		return null if GCore.slotsOf(c.s, s).size() >= 2 else "필드에 포켓몬이 2마리 이상 있어야 합니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["scoopUp", {}]])
	TRAINERS["투로박사의 시나리오"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["carmine", {}]])
	TRAINERS["카지"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		c.s.players[f.player].effects.append({ "kind": "boostEx40", "until": c.s.turnNumber })
		GEffects.done(c, f)
	TRAINERS["태권왕의 수련"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		return null if GCore.prizesLeft(c.s, GCore.other(s)) == 2 else "상대 사이드가 2장일 때만 쓸 수 있습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		c.s.players[f.player].effects.append({ "kind": "brier", "until": c.s.turnNumber })
		GEffects.done(c, f)
	TRAINERS["브라이어"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		# TS { target: f.data.target } — target 이 없으면 undefined 값 (직렬화 시 빠짐) → 키를 넣지 않는다
		var cd := {}
		if f.data.has("target"):
			cd["target"] = f.data.target
		GEffects.then(c, f, [["rareCandy", cd]])
	TRAINERS["이상한사탕"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		return null if GEffects.discardHas(c, s, { "or": [GEffects.POKEMON, GEffects.BASIC_ENERGY] }) else "트래쉬에 포켓몬·기본 에너지가 없습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("discard", { "or": [GEffects.POKEMON, GEffects.BASIC_ENERGY] }, 3, "deck", { "min": 1, "reveal": true, "prompt": "덱으로 되돌릴 포켓몬·기본 에너지를 3장까지 고르세요." }), ["shuffle", {}]])
	TRAINERS["대단한낚싯대"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		return null if c.s.players[GCore.other(s)].bench.size() > 0 else "상대 벤치가 없습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["gust", {}], ["switchOwn", {}]])
	TRAINERS["프라임 캐처"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [
			GEffects.search("deck", { "kind": "pokemon", "stage": 0 }, 1, "hand", { "reveal": true, "shuffle": false, "prompt": "기본 포켓몬 1장" }),
			GEffects.search("deck", { "kind": "pokemon", "stage": 1 }, 1, "hand", { "reveal": true, "shuffle": false, "prompt": "1진화 포켓몬 1장" }),
			GEffects.search("deck", { "kind": "pokemon", "stage": 2 }, 1, "hand", { "reveal": true, "prompt": "2진화 포켓몬 1장" })])
	TRAINERS["빛나"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", { "or": [{ "kind": "pokemon", "stage": 0, "ptype": "F" }, { "kind": "energy", "basicEnergy": true, "etype": "F" }] }, 1, "hand", { "reveal": true, "prompt": "격투 기본 포켓몬 또는 기본 격투 에너지" })])
	TRAINERS["파이팅공"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, me):
		return GEffects.needDeck(c, s) if GEffects.handOthers(c, s, me) >= 1 else "패를 1장 트래쉬해야 합니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["discardHand", { "n": 1 }], GEffects.search("deck", GEffects.BASIC_ENERGY, 2, "hand", { "reveal": true, "prompt": "기본 에너지를 2장까지 고르세요." })])
	TRAINERS["대지의 그릇"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, me):
		if GEffects.handOthers(c, s, me) >= 2:
			return null if GEffects.discardHas(c, s, GEffects.BASIC_ENERGY) else "트래쉬에 기본 에너지가 없습니다."
		return "패를 2장 트래쉬해야 합니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["superRetrieval", {}]])
	TRAINERS["수퍼 에너지 회수"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", { "kind": "trainer", "trainer": "item" }, 1, "hand", { "reveal": true, "shuffle": false, "prompt": "아이템 1장" }), GEffects.search("deck", { "kind": "trainer", "trainer": "tool" }, 1, "hand", { "reveal": true, "prompt": "포켓몬의 도구 1장" })])
	TRAINERS["페퍼"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["cipher", {}]])
	TRAINERS["암호마니아의 해독"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		return null if GEffects.discardHas(c, s, { "or": [{ "kind": "pokemon", "noRule": true }, GEffects.BASIC_ENERGY] }) else "트래쉬에 대상이 없습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("discard", { "or": [{ "kind": "pokemon", "noRule": true }, GEffects.BASIC_ENERGY] }, 3, "hand", { "min": 1, "reveal": true, "prompt": "룰 없는 포켓몬·기본 에너지를 3장까지" })])
	TRAINERS["수련의 돌봄"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = c.s.players[f.player]
		for iid in p.hand.duplicate():
			GCore.moveCard(c, iid, { "zone": "deck", "player": f.player, "position": "top" })
		GCore.shuffleDeck(c, f.player)
		GCore.drawN(c, f.player, 8 if GCore.prizesLeft(c.s, f.player) == 6 else 6)
		GEffects.done(c, f)
	TRAINERS["릴리에의 결심"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", { "kind": "pokemon", "evolution": true }, 1, "hand", { "reveal": true, "shuffle": false, "prompt": "진화 포켓몬 1장" }), GEffects.search("deck", { "kind": "energy" }, 1, "hand", { "reveal": true, "prompt": "에너지 1장" })])
	TRAINERS["투희"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, me):
		return null if GEffects.handOthers(c, s, me) >= 3 else "패를 3장 트래쉬해야 합니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["discardHand", { "n": 3 }],
			GEffects.search("deck", { "kind": "trainer", "trainer": "item" }, 1, "hand", { "reveal": true, "shuffle": false, "prompt": "아이템 1장" }),
			GEffects.search("deck", { "kind": "trainer", "trainer": "tool" }, 1, "hand", { "reveal": true, "shuffle": false, "prompt": "포켓몬의 도구 1장" }),
			GEffects.search("deck", { "kind": "trainer", "trainer": "supporter" }, 1, "hand", { "reveal": true, "shuffle": false, "prompt": "서포트 1장" }),
			GEffects.search("deck", { "kind": "trainer", "trainer": "stadium" }, 1, "hand", { "reveal": true, "prompt": "스타디움 1장" })])
	TRAINERS["시크릿박스"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", { "kind": "trainer", "trainer": "supporter" }, 1, "hand", { "look": 7, "reveal": true, "prompt": "덱 위 7장 중 서포트를 1장 가져올 수 있습니다." })])
	TRAINERS["포켓기어3.0"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		var ok: bool = GCore.slotsOf(c.s, s).size() >= 2 and GCore.slotsOf(c.s, s).any(func(sl): return GCore.energiesOf(c, sl).any(func(e): return GEffects._ebasic(GCore.dataOf(c, e))))
		return null if ok else "옮길 기본 에너지가 없습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["energySwitch", {}]])
	TRAINERS["에너지 갈아 달기"] = t

	# ── 공식 덱 레시피: 블래키 VMAX · 기라티나 VSTAR ──
	t = {}
	t["can"] = func(c: Dictionary, s: int, me):
		return GEffects.needDeck(c, s) if GEffects.handOthers(c, s, me) >= 1 else "패를 1장 트래쉬해야 합니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["discardHand", { "n": 1 }], GEffects.search("deck", GEffects.BASIC, 1, "hand", { "reveal": true, "prompt": "패로 가져올 기본 포켓몬을 고르세요." })])
	TRAINERS["퀵볼"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, me):
		var ok: bool = c.s.players[s].hand.any(func(i): return i != me and GCore.dataOf(c, i).kind == "pokemon")
		return null if ok else "패에 덱으로 되돌릴 포켓몬이 없습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("hand", GEffects.POKEMON, 1, "deck", { "min": 1, "reveal": true, "shuffle": false, "prompt": "덱으로 되돌릴 패의 포켓몬을 고르세요." }),
			GEffects.search("deck", GEffects.POKEMON, 1, "hand", { "reveal": true, "prompt": "패로 가져올 포켓몬을 고르세요." })])
	TRAINERS["포켓몬통신"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", { "kind": "pokemon", "evolution": true }, 1, "hand", { "reveal": true, "prompt": "패로 가져올 진화 포켓몬을 고르세요." })])
	TRAINERS["진화향로"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		return null if GEffects.discardHas(c, s, { "name": "일격 에너지" }) else "트래쉬에 일격 에너지가 없습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("discard", { "name": "일격 에너지" }, 2, "deck", { "min": 1, "reveal": true, "prompt": "덱으로 되돌릴 일격 에너지를 2장까지 고르세요." }), ["shuffle", {}]])
	TRAINERS["활력의 항아리"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		return null if GEffects.discardHas(c, s, { "or": [GEffects.POKEMON, GEffects.BASIC_ENERGY] }) else "트래쉬에 포켓몬·기본 에너지가 없습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("discard", GEffects.POKEMON, 2, "deck", { "reveal": true, "prompt": "덱으로 되돌릴 포켓몬을 2장까지 고르세요." }),
			GEffects.search("discard", GEffects.BASIC_ENERGY, 2, "deck", { "reveal": true, "prompt": "덱으로 되돌릴 기본 에너지를 2장까지 고르세요." }), ["shuffle", {}]])
	TRAINERS["보통낚싯대"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = c.s.players[f.player]
		for iid in p.hand.duplicate():
			GCore.moveCard(c, iid, { "zone": "discard", "player": f.player })
		GCore.drawN(c, f.player, 7)
		GEffects.done(c, f)
	TRAINERS["박사의 연구"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		for seat in [f.player, GCore.other(f.player)]:
			var p: Dictionary = c.s.players[seat]
			var hand: Array = p.hand.duplicate()
			GRng.shuffleInPlace(c.s.rng, hand)  # 뒷면으로 섞어서 덱 아래로
			for iid in hand:
				GCore.moveCard(c, iid, { "zone": "deck", "player": seat, "position": "bottom" })
		GCore.drawN(c, f.player, 5)
		GCore.drawN(c, GCore.other(f.player), 4)
		GEffects.done(c, f)
	TRAINERS["마리"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, me):
		return "패가 이 카드를 포함해 6장 이상이면 쓸 수 없습니다." if GEffects.handOthers(c, s, me) + 1 >= 6 else GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GCore.drawN(c, f.player, GCore.slotsOf(c.s, GCore.other(f.player)).size())
		GEffects.done(c, f)
	TRAINERS["민화의 대접"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		if c.s.players[s].turns != 1:
			return "자신의 첫 번째 차례에만 쓸 수 있습니다."
		var r = GEffects.needDeck(c, s)
		if r != null:
			return r
		return null if GEffects.benchRoom(c, s) > 0 else "벤치가 가득 찼습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", GEffects.BASIC, 2, "bench", { "prompt": "벤치에 낼 기본 포켓몬을 2장까지 고르세요." })])
	TRAINERS["배틀VIP패스"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		return "로스트존에 카드가 7장 이상 있어야 합니다." if GCore.lostCount(c.s, s) < 7 else GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", GEffects.BASIC_ENERGY, 2, "attach", { "distinct": "type", "prompt": "서로 다른 타입의 기본 에너지를 2장까지 고르세요." })])
	TRAINERS["미라주게이트"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		var p: Dictionary = c.s.players[s]
		if p.bench.is_empty():
			return "벤치 포켓몬이 없습니다."
		if p.active != null:
			var pk = GCore.slotData(c, p.active).get("pokemon")
			if pk != null and pk.stage == 0:
				return null
		return "배틀 포켓몬이 기본 포켓몬일 때만 쓸 수 있습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["switchCart", {}]])
	TRAINERS["교체카트"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		return null if (c.s.players[s].bench.size() > 0 or c.s.players[GCore.other(s)].bench.size() > 0) else "양쪽 모두 벤치 포켓몬이 없습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["escapeRope", {}]])
	TRAINERS["동굴탈출로프"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, me):
		if GEffects.handOthers(c, s, me) < 1:
			return "패를 1장 로스트존에 두어야 합니다."
		return null if GEffects.sweeperTargets(c).size() > 0 else "포켓몬의 도구·스타디움이 없습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["lostSweeper", {}]])
	TRAINERS["로스트스위퍼"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["heavyBall", { "card": f.data.get("card") }]])
	TRAINERS["히스이의 헤비볼"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["lookTake", { "look": 5, "take": 3, "prompt": "덱 위 5장 중 패로 가져올 카드 3장 (나머지는 로스트존)" }]])
	TRAINERS["아크로마의 실험"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _me):
		return null if GCore.prizesLeft(c.s, GCore.other(s)) <= 3 else "상대의 남은 사이드가 3장 이하일 때만 쓸 수 있습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		for seat in [f.player, GCore.other(f.player)]:
			var p: Dictionary = c.s.players[seat]
			for iid in p.hand.duplicate():
				GCore.moveCard(c, iid, { "zone": "deck", "player": seat, "position": "top" })
			GCore.shuffleDeck(c, seat)
		GCore.drawN(c, f.player, 6)
		GCore.drawN(c, GCore.other(f.player), 2)
		GEffects.done(c, f)
	TRAINERS["원규"] = t

# ───────────────────────── 이상한사탕 · 진화 ─────────────────────────

## 기본 포켓몬 슬롯에 이상한사탕으로 올릴 수 있는 패의 2진화
static func candyCards(ctx: Dictionary, seat: int, slot: Dictionary) -> Array:
	var base_d := GCore.slotData(ctx, slot)
	var bp = base_d.get("pokemon")
	if bp == null or bp.stage != 0:
		return []
	var stage1Names := {}
	for d in ctx.info.db.values():
		var pk = d.get("pokemon")
		if pk != null and pk.stage == 1 and pk["from"] == base_d.name:
			stage1Names[d.name] = true
	return ctx.s.players[seat].hand.filter(func(i):
		var pk2 = GCore.dataOf(ctx, i).get("pokemon")
		return pk2 != null and pk2.stage == 2 and GCore.truthy(pk2["from"]) and stage1Names.has(pk2["from"]))

## 덱 안의 카드를 맨 위로 (셔플 뒤 재배치용)
static func moveCardKeep(ctx: Dictionary, iid: String, seat: int) -> String:
	var p: Dictionary = ctx.s.players[seat]
	var i: int = p.deck.find(iid)
	if i >= 0:
		p.deck.remove_at(i)
		p.deck.push_front(iid)
	return iid

## 진화 (손에서). 진화 시 발동하는 특성(리자몽 ex, 야부엉)은 프레임으로 쌓는다
static func evolveFrom(ctx: Dictionary, seat: int, cardIid: String, sid: String, fromHand: bool = true) -> void:
	var nid := GCore.moveCard(ctx, cardIid, { "zone": "evolve", "sid": sid })
	if ctx.has("err"):
		return  # TS 에서는 moveCard 가 throw (이 입력은 오류로 버려짐)
	GCore.emit(ctx, { "type": "play", "player": seat, "code": GCore.inst(ctx, nid).code, "what": "진화" })
	var slot: Dictionary = GCore.findSlot(ctx.s, sid).slot
	var pk = GCore.slotData(ctx, slot).get("pokemon")
	var ab = pk.abilities[0].nameJa if (pk != null and pk.abilities.size() > 0) else null
	if not GCore.abilityActive(ctx, slot):
		return
	if ab == "れんごくしはい" and ctx.s.players[seat].deck.size() > 0:
		pushTrigger(ctx, seat, "infernalReign", sid, "리자몽 ex 특성: 덱에서 기본 에너지를 3장까지 붙일까요?")
	if ab == "ほうせきさがし" and GCore.hasTera(ctx, seat) and ctx.s.players[seat].deck.size() > 0:
		pushTrigger(ctx, seat, "jewelSeeker", sid, "야부엉 특성: 덱에서 트레이너스를 2장까지 가져올까요?")
	if ab == "다크시그널" and fromHand and ctx.s.players[GCore.other(seat)].bench.size() > 0:
		pushTrigger(ctx, seat, "darkSignal", sid, "블래키 VMAX 특성: 상대 벤치 포켓몬을 배틀 포켓몬과 교체할까요?")

static func pushTrigger(ctx: Dictionary, seat: int, kind: String, sid: String, prompt: String) -> void:
	GCore.pushFrame(ctx, "trigger", seat, { "effect": kind, "sid": sid, "prompt": prompt })

## 벤치에 냈을 때 발동하는 특성
static func onBenched(ctx: Dictionary, seat: int, sid: String) -> void:
	var slot: Dictionary = GCore.findSlot(ctx.s, sid).slot
	if not GCore.abilityActive(ctx, slot):
		return
	var pk = GCore.slotData(ctx, slot).get("pokemon")
	var ab = pk.abilities[0].nameJa if (pk != null and pk.abilities.size() > 0) else null
	if ab == "フライングエントリー" and ctx.s.players[GCore.other(seat)].bench.size() > 0:
		pushTrigger(ctx, seat, "flyingEntry", sid, "루차불 특성: 상대 벤치 포켓몬 2마리에 데미지 카운터를 1개씩 올릴까요?")
	if ab == "ラピッドバーニア" and ctx.s.players[seat].active != null:
		pushTrigger(ctx, seat, "rapidVernier", sid, "무쇠잎새 ex 특성: 배틀 포켓몬과 바꾸고 벤치의 에너지를 옮길까요?")

# ───────────────────────── 특성 (선언해서 쓰는 것) ─────────────────────────
# ABILITIES[nameJa] = { once: 'pokemon'|'name'|'none', can?: func(ctx, seat, slot) -> String|null, run: Handler (f.data.sid) }

static func slotOfFrame(ctx: Dictionary, f: Dictionary):
	var fs = GCore.findSlot(ctx.s, str(f.data.get("sid")))
	return fs.slot if fs != null else null

static func _initAbilities() -> void:
	var t: Dictionary

	t = { "once": "name" }
	t["can"] = func(c: Dictionary, s: int, _sl):
		return GEffects.needDeck(c, s) if c.s.players[s].turns == 1 else "자신의 첫 차례에만 쓸 수 있습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", { "kind": "pokemon", "maxHp": 100, "ptype": "C" }, 3, "hand", { "reveal": true, "prompt": "HP 100 이하 무색 포켓몬을 3장까지" })])
	ABILITIES["ファンコール"] = t

	t = { "once": "name" }
	t["can"] = func(c: Dictionary, s: int, _sl):
		return GEffects.needDeck(c, s) if (c.s.players[s].koTurn == c.s.turnNumber - 1 and c.s.turnNumber > 1) else "앞의 상대 차례에 내 포켓몬이 기절했을 때만 쓸 수 있습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GCore.drawN(c, f.player, 3)
		GEffects.done(c, f)
	ABILITIES["さかてにとる"] = t

	t = { "once": "pokemon" }
	t["can"] = func(c: Dictionary, s: int, _sl):
		return GEffects.needDeck(c, s) if c.s.players[s].hand.size() < 3 else "패가 3장 이상입니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = c.s.players[f.player]
		while p.hand.size() < 3 and GCore.drawOne(c, f.player):
			pass  # 3장까지
		GEffects.done(c, f)
	ABILITIES["リスタート"] = t

	t = { "once": "name" }
	t["can"] = func(c: Dictionary, s: int, _sl): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", {}, 1, "hand", { "min": 1, "prompt": "패로 가져올 카드 1장" })])
	ABILITIES["マッハサーチ"] = t

	t = { "once": "pokemon" }
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["cursedBomb", { "sid": f.data.get("sid") }]])
	ABILITIES["カースドボム"] = t

	t = { "once": "pokemon" }
	t["can"] = func(c: Dictionary, s: int, _sl): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var slot = GEffects.slotOfFrame(c, f)
		GCore.drawN(c, f.player, 2 if (slot != null and GCore.isActive(c.s, slot)) else 1)
		GEffects.done(c, f)
	ABILITIES["ボーナスコイン"] = t

	t = { "once": "name" }
	t["can"] = func(c: Dictionary, s: int, _sl):
		if not GCore.slotsOf(c.s, s).any(func(sl): return GCore.slotData(c, sl).name == "솔록"):
			return "필드에 솔록이 있어야 합니다."
		if not c.s.players[s].hand.any(func(i): return GEffects.matches(GCore.dataOf(c, i), { "kind": "energy", "basicEnergy": true, "etype": "F" })):
			return "패에 기본 격투 에너지가 있어야 합니다."
		return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["lunarCycle", {}]])
	ABILITIES["ルナサイクル"] = t

	t = { "once": "pokemon" }
	t["can"] = func(c: Dictionary, s: int, _sl): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", { "kind": "pokemon", "evolution": true, "ptype": "M" }, 2, "hand", { "reveal": true, "prompt": "강철 타입 진화 포켓몬을 2장까지" })])
	ABILITIES["メタルシグナル"] = t

	t = { "once": "pokemon" }
	t["can"] = func(c: Dictionary, s: int, slot: Dictionary):
		var hasDark: bool = GCore.energiesOf(c, slot).any(func(e):
			var one: Dictionary = slot.duplicate()
			one["attached"] = [e]
			return GCore.provided(c, one).any(func(u): return u == "D" or u == "*"))
		if not hasDark:
			return "악 에너지가 붙어 있어야 합니다."
		if not GCore.slotsOf(c.s, s).any(func(sl): return sl.damage > 0):
			return "데미지 카운터가 올라간 내 포켓몬이 없습니다."
		return null
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["adrenaBrain", {}]])
	ABILITIES["アドレナブレイン"] = t

	t = { "once": "pokemon" }
	t["can"] = func(c: Dictionary, s: int, _sl): return GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["recon", {}]])
	ABILITIES["ていさつしれい"] = t

	t = { "once": "none" }
	t["can"] = func(c: Dictionary, s: int, _sl):
		if not GEffects.discardHas(c, s, { "kind": "energy", "basicEnergy": true, "etype": "P" }):
			return "트래쉬에 기본 초 에너지가 없습니다."
		var any_p: bool = GCore.slotsOf(c.s, s).any(func(sl):
			if not (GCore.remainingHp(c, sl) > 20):
				return false
			var pk = GCore.slotData(c, sl).get("pokemon")
			return pk != null and pk.type == "P")
		if not any_p:
			return "붙일 수 있는 초 포켓몬이 없습니다."
		return null
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["psychicEmbrace", {}]])
	ABILITIES["サイコエンブレイス"] = t

	t = { "once": "pokemon" }
	t["can"] = func(c: Dictionary, s: int, _sl):
		var r = GEffects.needDeck(c, s)
		if r != null:
			return r
		return null if GEffects.benchRoom(c, s) > 0 else "벤치가 가득 찼습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", { "kind": "pokemon", "stage": 0, "ptype": "L" }, 2, "bench", { "prompt": "번개 타입 기본 포켓몬을 2장까지" })])
	ABILITIES["タンデムユニット"] = t

	# ── 공식 덱 레시피 ──
	t = { "once": "name" }
	t["can"] = func(c: Dictionary, s: int, _sl):
		return GEffects.needDeck(c, s) if (c.s.players[s].koTurn == c.s.turnNumber - 1 and c.s.turnNumber > 1) else "앞의 상대 차례에 내 포켓몬이 기절했을 때만 쓸 수 있습니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GCore.drawN(c, f.player, 3)
		GEffects.done(c, f)
	ABILITIES["전별의 춤"] = t

	t = { "once": "pokemon" }
	t["can"] = func(c: Dictionary, s: int, _sl):
		if not c.s.players[s].deck.any(func(i): return GCore.nameOf(c, i) == "일격 에너지"):
			return "덱에 일격 에너지가 없습니다."
		if not GCore.slotsOf(c.s, s).any(func(sl): return GEffects.hasTag(GCore.slotData(c, sl), "일격")):
			return "'일격' 포켓몬이 없습니다."
		return null
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["singleStrikeRoar", {}]])
	ABILITIES["일격의 포효"] = t

	t = { "once": "pokemon" }
	t["can"] = func(c: Dictionary, s: int, slot):
		return "배틀 포켓몬일 때만 쓸 수 있습니다." if not is_same(c.s.players[s].active, slot) else GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["flowerSelecting", {}]])
	ABILITIES["꽃고르기"] = t

	t = { "once": "pokemon" }
	t["can"] = func(c: Dictionary, s: int, _sl):
		return "패에 에너지가 없습니다." if not c.s.players[s].hand.any(func(i): return GCore.dataOf(c, i).kind == "energy") else GEffects.needDeck(c, s)
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["concealedCards", {}]])
	ABILITIES["숨겨진 수단"] = t

# ───────────────────────── 기술 ─────────────────────────
# 기술 처리기: f.data = { sid(공격 포켓몬), base(기본 데미지), attackJa } — 기본: 상대 배틀 포켓몬에게 base
# ATTACKS[nameJa] = { can?: func(ctx, seat, slot) -> String|null, run: Handler }

static func atkSlot(ctx: Dictionary, f: Dictionary):
	var fs = GCore.findSlot(ctx.s, str(f.data.get("sid")))
	return fs.slot if fs != null else null

static func oppActive(ctx: Dictionary, f: Dictionary):
	return ctx.s.players[GCore.other(f.player)].active

## 상대 배틀 포켓몬에게 데미지
static func hit(ctx: Dictionary, f: Dictionary, amount: int, wr: bool = true) -> void:
	var a = atkSlot(ctx, f)
	var t = oppActive(ctx, f)
	if a != null and t != null:
		GCore.dealAttackDamage(ctx, f.player, a, t, amount, wr)

static func base(f: Dictionary) -> int:
	return int(f.data.base)

static func selfEffect(ctx: Dictionary, f: Dictionary, kind: String, turns: int) -> void:
	var a = atkSlot(ctx, f)
	if a != null:
		a.effects.append({ "kind": kind, "until": ctx.s.turnNumber + turns })

static func defenderEffect(ctx: Dictionary, f: Dictionary, kind: String) -> void:
	var t = oppActive(ctx, f)
	if t != null:
		t.effects.append({ "kind": kind, "until": ctx.s.turnNumber + 1 })

static func allEnergiesOn(ctx: Dictionary, seat: int) -> int:
	return GCore.slotsOf(ctx.s, seat).reduce(func(a, sl): return a + GCore.energiesOf(ctx, sl).size(), 0)

## dmgOf: func(ctx, f) -> int
static func pickOppAny(dmgOf: Callable) -> Dictionary:
	var run := func(c: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			GCore.ask(c, f, 1, f.player, "pickSlot", GCore.slotsOf(c.s, GCore.other(f.player)).map(func(sl): return sl.sid), 1, 1, "데미지를 줄 상대 포켓몬")
			return
		var t = GCore.findSlot(c.s, f.picks[0])
		var a = GEffects.atkSlot(c, f)
		if t != null and a != null:
			GCore.dealAttackDamage(c, f.player, a, t.slot, dmgOf.call(c, f), t.active)
		GEffects.done(c, f)
	return { "run": run }

static func _initAttacks() -> void:
	plain = {}
	plain["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		GEffects.done(c, f)
	noAttackNext = {}
	noAttackNext["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		GEffects.selfEffect(c, f, "noAttack", 2)
		GEffects.done(c, f)

	var t: Dictionary

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var n := 0
		for i in range(3):
			if GCore.flip(c, f.player, "삼단 찌르기"):
				n += 1
		GEffects.hit(c, f, 10 * n)
		GEffects.done(c, f)
	ATTACKS["さんどづき"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		if not GCore.truthy(c.s.stadium):
			GCore.note(c, "스타디움이 없어 기술 실패")
			GEffects.done(c, f)
			return
		GEffects.hit(c, f, GEffects.base(f))
		GEffects.done(c, f)
	ATTACKS["とつげきランディング"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		var a = GEffects.atkSlot(c, f)
		if a != null:
			a.damage += 10
			GCore.emit(c, { "type": "damage", "player": f.player, "sid": a.sid, "amount": 10 })
		GEffects.done(c, f)
	ATTACKS["とつげき"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", GEffects.POKEMON, 3, "hand", { "reveal": true, "distinct": "type", "prompt": "서로 다른 타입의 포켓몬을 3장까지" })])
	ATTACKS["カラフルフレンズ"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			GEffects.hit(c, f, GEffects.base(f))
			if c.s.players[f.player].deck.is_empty():
				GEffects.done(c, f)
				return
			GCore.ask(c, f, 1, f.player, "pickSlot", GCore.slotsOf(c.s, f.player).map(func(sl): return sl.sid), 1, 1, "기본 에너지를 붙일 포켓몬 1마리")
			return
		GEffects.then(c, f, [GEffects.search("deck", GEffects.BASIC_ENERGY, 2, "attachTo", { "attachTo": f.picks[0], "prompt": "붙일 기본 에너지를 2장까지" })])
	ATTACKS["バーニングチャージ"] = t

	ATTACKS["カーネリアン"] = noAttackNext

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, 60 * GEffects.allEnergiesOn(c, GCore.other(f.player)))
		GEffects.done(c, f)
	ATTACKS["あおばのあらし"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		for b in c.s.players[f.player].bench:
			GCore.heal(c, b, 100)
		GEffects.done(c, f)
	ATTACKS["モスアゲート"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		GEffects.defenderEffect(c, f, "noRetreat")
		GEffects.done(c, f)
	ATTACKS["すすりなく"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var a = GEffects.atkSlot(c, f)
		if f.step == 0:
			GEffects.hit(c, f, GEffects.base(f))
			if GCore.energiesOf(c, a).size() < 3 or c.s.players[GCore.other(f.player)].bench.is_empty():
				GEffects.done(c, f)
				return
			GEffects.seq(c, f, 1, [["yesno", { "prompt": "에너지 3개를 덱으로 되돌리고 상대 벤치에 120 데미지를 줄까요?", "save": "answer" }]])
			return
		if f.step == 1:
			if f.data.get("answer") != "yes":
				GEffects.done(c, f)
				return
			var ens: Array = GCore.energiesOf(c, a)
			GCore.ask(c, f, 2, f.player, "pickCards", ens, 3, 3, "덱으로 되돌릴 에너지 3개", { "cards": GEffects.cardsOf(c, ens) })
			return
		if f.step == 2:
			for e in f.picks:
				GCore.moveCard(c, e, { "zone": "deck", "player": f.player, "position": "top" })
			GCore.shuffleDeck(c, f.player)
			GCore.ask(c, f, 3, f.player, "pickSlot", c.s.players[GCore.other(f.player)].bench.map(func(b): return b.sid), 1, 1, "120 데미지를 줄 상대 벤치 포켓몬")
			return
		var t2 = GCore.findSlot(c.s, f.picks[0])
		if t2 != null:
			GCore.dealAttackDamage(c, f.player, a, t2.slot, 120, false)
		GEffects.done(c, f)
	ATTACKS["げきりゅうポンプ"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _sl):
		return "후공 플레이어의 첫 차례에는 쓸 수 없습니다." if (s != c.s.firstPlayer and c.s.players[s].turns == 1) else null
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, 30 * c.s.players[f.player].bench.size())
		GEffects.done(c, f)
	ATTACKS["ユニオンビート"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		GEffects.selfEffect(c, f, "immuneBasicNonC", 1)
		GEffects.done(c, f)
	ATTACKS["クラウンオパール"] = t

	ATTACKS["クルーエルアロー"] = pickOppAny(func(_c, _f): return 100)

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var tg = GEffects.oppActive(c, f)
		var atks: Array = []
		if tg != null and not tg.faceDown:
			var pk = GCore.slotData(c, tg).get("pokemon")
			atks = pk.attacks if pk != null else []
		if f.step == 0:
			if atks.is_empty():
				GEffects.done(c, f)
				return
			var opts: Array = []
			var labels := {}
			for i in range(atks.size()):
				opts.append(str(i))
			for i in range(atks.size()):
				var at = atks[i]
				labels[str(i)] = (at.name if GCore.truthy(at.name) else at.nameJa) + " " + (str(at.damage) if GCore.truthy(at.damage) else "") + str(at.op)
			GCore.ask(c, f, 1, f.player, "pickOption", opts, 1, 1, "사용할 상대 배틀 포켓몬의 기술", { "labels": labels })
			return
		var idx := int(f.picks[0])
		var a = atks[idx] if (idx >= 0 and idx < atks.size()) else null
		GEffects.done(c, f)
		if a == null:
			return
		# 고른 기술을 이 포켓몬의 기술로 실행 (게놈 해킹으로 다시 게놈 해킹은 하지 않음)
		if a.nameJa == "ゲノムハック":
			return
		GCore.pushFrame(c, "attackEffect", f.player, { "sid": f.data.get("sid"), "base": a.damage, "attackJa": a.nameJa })
	ATTACKS["ゲノムハック"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		if GCore.truthy(c.s.stadium):
			GCore.moveCard(c, c.s.stadium, { "zone": "discard", "player": c.s.cards[c.s.stadium].owner })
		GEffects.updateBench(c)
		GEffects.done(c, f)
	ATTACKS["まるやけ"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			GEffects.hit(c, f, GEffects.base(f))
			if not GCore.truthy(c.s.stadium):
				GEffects.done(c, f)
				return
			GEffects.seq(c, f, 1, [["yesno", { "prompt": "스타디움을 트래쉬할까요?", "save": "answer" }]])
			return
		if f.data.get("answer") == "yes" and GCore.truthy(c.s.stadium):
			GCore.moveCard(c, c.s.stadium, { "zone": "discard", "player": c.s.cards[c.s.stadium].owner })
			GEffects.updateBench(c)
		GEffects.done(c, f)
	ATTACKS["ふきすさぶ"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("discard", { "kind": "pokemon", "name": "해골몽" }, 3, "bench", { "prompt": "벤치에 낼 해골몽을 3장까지" })])
	ATTACKS["むかえにいく"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		GEffects.defenderEffect(c, f, "noRetreat")
		GEffects.done(c, f)
	ATTACKS["かげしばり"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var tg = GEffects.oppActive(c, f)
		var tool = GCore.toolOf(c, tg) if tg != null else null
		if GCore.truthy(tool):
			GCore.moveCard(c, tool, { "zone": "discard", "player": GCore.other(f.player) })
		GEffects.hit(c, f, GEffects.base(f))
		GEffects.done(c, f)
	ATTACKS["ねらいおとす"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", GEffects.BASIC_ENERGY, 2, "hand", { "reveal": true, "prompt": "기본 에너지를 2장까지" })])
	ATTACKS["ちいさなおつかい"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = c.s.players[f.player]
		var opts: Array = GEffects.cardsMatching(c, p.hand, GEffects.BASIC_ENERGY)
		if f.step == 0:
			GCore.ask(c, f, 1, f.player, "pickCards", opts, 0, opts.size(), "트래쉬할 기본 에너지 (장당 50 데미지)", { "cards": GEffects.cardsOf(c, opts) })
			return
		for e in GEffects._picks(f):
			GCore.moveCard(c, e, { "zone": "discard", "player": f.player })
		GEffects.hit(c, f, 50 * GEffects._picks(f).size())
		GEffects.done(c, f)
	ATTACKS["ゴールドラッシュ"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		if not c.s.players[f.player].bench.any(func(b): return GCore.slotData(c, b).name == "루나톤"):
			GCore.note(c, "벤치에 루나톤이 없어 기술 실패")
			GEffects.done(c, f)
			return
		GEffects.hit(c, f, GEffects.base(f), false)
		GEffects.done(c, f)
	ATTACKS["コスモビーム"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		GEffects.selfEffect(c, f, "reduce30", 1)
		GEffects.done(c, f)
	ATTACKS["プロテクトチャージ"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		var tg = GEffects.oppActive(c, f)
		if tg != null:
			GCore.setRot(c, tg, "confused")
		GEffects.done(c, f)
	ATTACKS["サイコトリップ"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			GEffects.hit(c, f, GEffects.base(f))
			f.data["left"] = 6
			f.step = 1
		if f.step == 2 and GEffects._picks(f).size() > 0:
			var tg = GCore.findSlot(c.s, f.picks[0])
			if tg != null:
				GCore.putCounters(c, tg.slot, 1)
			f.data["left"] = int(f.data.left) - 1
		var bench: Array = c.s.players[GCore.other(f.player)].bench
		if int(f.data.left) <= 0 or bench.is_empty():
			GEffects.done(c, f)
			return
		GCore.ask(c, f, 2, f.player, "pickSlot", bench.map(func(b): return b.sid), 1, 1, "데미지 카운터를 올릴 상대 벤치 포켓몬 (남은 " + str(f.data.left) + "개)")
	ATTACKS["ファントムダイブ"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		c.s.players[GCore.other(f.player)].effects.append({ "kind": "itemLock", "until": c.s.turnNumber + 1 })
		GEffects.done(c, f)
	ATTACKS["むずむずかふん"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		c.s.players[GCore.other(f.player)].effects.append({ "kind": "itemLock", "until": c.s.turnNumber + 1 })
		GEffects.done(c, f)
	ATTACKS["うみのかげ"] = t

	ATTACKS["ブラッドムーン"] = noAttackNext
	ATTACKS["むげんのやいば"] = noAttackNext
	ATTACKS["フォトンブラスター"] = noAttackNext
	ATTACKS["プリズムエッジ"] = noAttackNext

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GCore.drawOne(c, f.player)
		GEffects.done(c, f)
	ATTACKS["もってくる"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", GEffects.POKEMON, 3, "hand", { "reveal": true, "prompt": "포켓몬을 3장까지" })])
	ATTACKS["コールサイン"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		var a = GEffects.atkSlot(c, f)
		if a != null:
			a.cond = { "poison": 0, "burn": false, "rot": "", "paraUntil": 0 }
		GEffects.done(c, f)
	ATTACKS["ミラクルフォース"] = t

	ATTACKS["ほえさけぶ"] = pickOppAny(func(c, f):
		var a = GEffects.atkSlot(c, f)
		var dmg: int = a.damage if a != null else 0
		return 20 * floori(float(dmg) / 10))

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var a = GEffects.atkSlot(c, f)
		var ens: Array = GCore.energiesOf(c, a)
		if f.step == 0:
			GCore.ask(c, f, 1, f.player, "pickCards", ens, 0, mini(2, ens.size()), "트래쉬할 에너지 (2장까지, 장당 120)", { "cards": GEffects.cardsOf(c, ens) })
			return
		for e in GEffects._picks(f):
			GCore.moveCard(c, e, { "zone": "discard", "player": f.player })
		GEffects.hit(c, f, 120 * GEffects._picks(f).size())
		GEffects.done(c, f)
	ATTACKS["ガーランドレイ"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f) + 20 * (c.s.players[0].bench.size() + c.s.players[1].bench.size()))
		GEffects.done(c, f)
	ATTACKS["フルムーンロンド"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [
			GEffects.search("deck", { "kind": "energy", "basicEnergy": true, "etype": "G" }, 2, "attach", { "shuffle": false, "prompt": "기본 풀 에너지를 2장까지" }),
			GEffects.search("deck", { "kind": "energy", "basicEnergy": true, "etype": "L" }, 2, "attach", { "prompt": "기본 번개 에너지를 2장까지" })])
	ATTACKS["バチュチャージ"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var a = GEffects.atkSlot(c, f)
		var hasL: bool = GCore.provided(c, a).any(func(u): return u == "L" or u == "*")
		GEffects.hit(c, f, GEffects.base(f) + (80 if hasL else 0))
		GEffects.done(c, f)
	ATTACKS["ビリビリウェブ"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		if c.s.attackCtx != null:
			c.s.attackCtx.extraPrizes += 1
		GEffects.hit(c, f, GEffects.base(f))
		GEffects.done(c, f)
	ATTACKS["ごっつあんプリファイ"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var a = GEffects.atkSlot(c, f)
		if f.step == 0:
			GEffects.hit(c, f, GEffects.base(f))
			var ens: Array = GCore.energiesOf(c, a)
			if ens.size() <= 3:
				for e in ens:
					GCore.moveCard(c, e, { "zone": "discard", "player": f.player })
				GEffects.done(c, f)
				return
			GCore.ask(c, f, 1, f.player, "pickCards", ens, 3, 3, "트래쉬할 에너지 3개", { "cards": GEffects.cardsOf(c, ens) })
			return
		for e in GEffects._picks(f):
			GCore.moveCard(c, e, { "zone": "discard", "player": f.player })
		GEffects.done(c, f)
	ATTACKS["トパーズボルト"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, 80 * GCore.prizesTaken(c.s, f.player))
		GEffects.done(c, f)
	ATTACKS["がっつく"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var tg = GEffects.oppActive(c, f)
		GEffects.hit(c, f, 30 if (tg != null and tg.damage > 0) else GEffects.base(f))
		GEffects.done(c, f)
	ATTACKS["ビッグバイト"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f) + 30 * GCore.prizesTaken(c.s, GCore.other(f.player)))
		GEffects.done(c, f)
	ATTACKS["バーニングダーク"] = t

	# 기술머신 에볼루션의 기술: 벤치 포켓몬 2마리까지 덱에서 진화
	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["tmEvolution", {}]])
	ATTACKS["TM_EVOLUTION"] = t

	# ── 공식 덱 레시피 ──
	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		GEffects.then(c, f, [["switchOwn", {}]])
	ATTACKS["뒤집기GX"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["placeCounters", { "n": 3 }]])
	ATTACKS["사이코파워"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [GEffects.search("deck", { "kind": "energy", "basicEnergy": true, "etype": "F" }, 2, "attachTo", { "attachTo": f.data.get("sid"), "prompt": "이 포켓몬에게 붙일 기본 격투 에너지를 2장까지" })])
	ATTACKS["예민해지기"] = t

	t = {}
	t["can"] = func(_c: Dictionary, _s: int, slot):
		return "앞 차례에 쓴 기술이라 이번 차례에는 쓸 수 없습니다." if slot.effects.any(func(e): return e.kind == "lockAttack" and e.get("name") == "임팩트블로") else null
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		var a = GEffects.atkSlot(c, f)
		if a != null:
			a.effects.append({ "kind": "lockAttack", "until": c.s.turnNumber + 2, "name": "임팩트블로" })
		GEffects.done(c, f)
	ATTACKS["임팩트블로"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var a = GEffects.atkSlot(c, f)
		var tg = GEffects.oppActive(c, f)
		if a != null and tg != null:
			GCore.dealAttackDamage(c, f.player, a, tg, GEffects.base(f), true, { "ignoreEffects": true })
		if a != null:
			for e in GCore.energiesOf(c, a):
				GCore.moveCard(c, e, { "zone": "discard", "player": f.player })
		GEffects.done(c, f)
	ATTACKS["거다이일격"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.hit(c, f, GEffects.base(f))
		GEffects.defenderEffect(c, f, "noRetreat")
		GEffects.done(c, f)
	ATTACKS["검은눈빛"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var a = GEffects.atkSlot(c, f)
		GEffects.hit(c, f, GEffects.base(f) + (80 if (a != null and a.damage > 0) else 0))
		GEffects.done(c, f)
	ATTACKS["월광의칼날"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var a = GEffects.atkSlot(c, f)
		var tg = GEffects.oppActive(c, f)
		if a != null and tg != null:
			GCore.dealAttackDamage(c, f.player, a, tg, GEffects.base(f), true, { "noWeak": true })
		GEffects.done(c, f)
	ATTACKS["시치미스핏"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _sl):
		return null if GCore.lostCount(c.s, s) >= 10 else "로스트존에 카드가 10장 이상 있어야 합니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["placeCounters", { "n": 12 }]])
	ATTACKS["로스트마인"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var a = GEffects.atkSlot(c, f)
		if f.step == 0:
			var ens: Array = GCore.energiesOf(c, a)
			if ens.size() <= 2:
				for e in ens:
					GCore.moveCard(c, e, { "zone": "discard", "player": f.player })
				f.step = 2
			else:
				GCore.ask(c, f, 1, f.player, "pickCards", ens, 2, 2, "트래쉬할 에너지 2개", { "cards": GEffects.cardsOf(c, ens) })
				return
		if f.step == 1:
			for e in GEffects._picks(f):
				GCore.moveCard(c, e, { "zone": "discard", "player": f.player })
			f.erase("picks")
			f.step = 2
		if f.step == 2:
			var opts: Array = GCore.slotsOf(c.s, GCore.other(f.player)).map(func(sl): return sl.sid)
			var n := mini(2, opts.size())
			if n == 0:
				GEffects.done(c, f)
				return
			GCore.ask(c, f, 3, f.player, "pickSlot", opts, n, n, "90 데미지를 줄 상대 포켓몬 2마리")
			return
		for sid in GEffects._picks(f):
			var tg = GCore.findSlot(c.s, sid)
			if tg != null:
				GCore.dealAttackDamage(c, f.player, a, tg.slot, 90, tg.active)
		GEffects.done(c, f)
	ATTACKS["월광수리검"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		GEffects.then(c, f, [["lookTake", { "look": 4, "take": 2, "prompt": "덱 위 4장 중 패로 가져올 카드 2장 (나머지는 로스트존)" }]])
	ATTACKS["어비스시크"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var a = GEffects.atkSlot(c, f)
		var tg = GEffects.oppActive(c, f)
		if a != null and tg != null:
			GCore.dealAttackDamage(c, f.player, a, tg, GEffects.base(f), true, { "ignoreEffects": true })
		GEffects.done(c, f)
	ATTACKS["찢기"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			GEffects.hit(c, f, GEffects.base(f))
			GCore.ask(c, f, 1, f.player, "pickSlot", GCore.slotsOf(c.s, f.player).map(func(sl): return sl.sid), 1, 1, "60 데미지를 줄 내 포켓몬 1마리")
			return
		var a = GEffects.atkSlot(c, f)
		var tg = GCore.findSlot(c.s, f.picks[0])
		if a != null and tg != null:
			GCore.dealAttackDamage(c, f.player, a, tg.slot, 60, false)
		GEffects.done(c, f)
	ATTACKS["다이내믹테일"] = t

	t = {}
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			GEffects.hit(c, f, GEffects.base(f))
			var ens: Array = []
			for sl in GCore.slotsOf(c.s, f.player):
				ens.append_array(GCore.energiesOf(c, sl))
			if ens.size() <= 2:
				for e in ens:
					GCore.moveCard(c, e, { "zone": "lost", "player": f.player })
				GEffects.done(c, f)
				return
			GCore.ask(c, f, 1, f.player, "pickCards", ens, 2, 2, "로스트존에 둘 내 필드의 에너지 2개", { "cards": GEffects.cardsOf(c, ens) })
			return
		for e in GEffects._picks(f):
			GCore.moveCard(c, e, { "zone": "lost", "player": f.player })
		GEffects.done(c, f)
	ATTACKS["로스트임팩트"] = t

	t = {}
	t["can"] = func(c: Dictionary, s: int, _sl):
		return null if GCore.lostCount(c.s, s) >= 10 else "로스트존에 카드가 10장 이상 있어야 합니다."
	t["run"] = func(c: Dictionary, f: Dictionary) -> void:
		var tg = GEffects.oppActive(c, f)
		if tg != null:
			tg.damage = maxi(tg.damage, GCore.maxHp(c, tg))
			GCore.note(c, GCore.slotName(c, tg) + ": 스타레퀴엠으로 기절")
		GEffects.done(c, f)
	ATTACKS["스타레퀴엠"] = t

	# 효과 없는 기술 (기본 데미지만)
	for plain_ja in ["ひだね", "ひをはく", "かぜおこし", "つばさでうつ", "つぶやく", "おにび", "たいあたり", "パワージェム", "ちょっとうらむ", "かみつく", "リューズヘッド",
		"ジェットヘッド", "スキップ", "クォーツシャイン", "スピードウイング", "ずつき", "サイコショット", "ビンタ", "アームプレス", "マグネブラスト",
		"물기", "날카로운날개", "어둠엄니", "정권찌르기", "다이아크", "회전어택", "물뿌리기", "할퀴기"]:
		ATTACKS[plain_ja] = plain

const TM_ATTACK := { "name": "에볼루션", "nameJa": "TM_EVOLUTION", "cost": ["C"], "damage": 0, "op": "", "text": "자신의 벤치 포켓몬을 2마리까지 골라, 각각 덱에서 그 포켓몬으로부터 진화하는 카드를 찾아 진화시킨다." }

static func _initFrames2() -> void:
	FRAMES["tmEvolution"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		if f.step == 0:
			GCore.ask(ctx, f, 1, f.player, "pickSlot", p.bench.map(func(b): return b.sid), 0, 2, "진화시킬 벤치 포켓몬 (2마리까지)")
			return
		if f.step == 1:
			f.data["targets"] = GEffects._picks(f)
		if f.step == 3:
			var targets: Array = f.data.targets
			if GEffects._picks(f).size() > 0:
				GEffects.evolveFrom(ctx, f.player, f.picks[0], targets[0], false)
			f.data["targets"] = targets.slice(1)
		# 남은 대상마다 덱에서 진화 카드 고르기 (진화할 카드가 없는 대상은 건너뜀)
		var left: Array = f.data.targets
		while left.size() > 0:
			var fs = GCore.findSlot(ctx.s, left[0])
			var slot = fs.slot if fs != null else null
			var nm: String = GCore.slotName(ctx, slot) if slot != null else ""
			var opts: Array = p.deck.filter(func(i):
				var pk = GCore.dataOf(ctx, i).get("pokemon")
				return pk != null and pk["from"] == nm)
			if opts.size() > 0:
				GCore.ask(ctx, f, 3, f.player, "pickCards", opts, 0, 1, nm + "에서 진화하는 카드", { "cards": GEffects.cardsOf(ctx, p.deck) })
				return
			left = left.slice(1)
			f.data["targets"] = left
		GCore.shuffleDeck(ctx, f.player)
		GEffects.done(ctx, f)

	## 기술 효과 실행 프레임 (데미지 + 효과)
	FRAMES["attackEffect"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var dfn = GEffects.ATTACKS.get(str(f.data.get("attackJa")))
		if dfn == null:
			GEffects.hit(ctx, f, GEffects.base(f))
			GCore.note(ctx, "이 기술의 효과는 아직 자동화되지 않았습니다 (기본 데미지만)")
			GEffects.done(ctx, f)
			return
		dfn.run.call(ctx, f)

	FRAMES["benchTrim"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		var over: int = p.bench.size() - p.benchMax
		if over <= 0:
			GEffects.done(ctx, f)
			return
		if f.step == 0:
			GCore.ask(ctx, f, 1, f.player, "pickSlot", p.bench.map(func(b): return b.sid), over, over, "벤치가 " + str(p.benchMax) + "마리가 되도록 트래쉬할 포켓몬 " + str(over) + "마리")
			return
		for sid in GEffects._picks(f):
			var tg = GCore.findSlot(ctx.s, sid)
			if tg != null:
				GCore.clearSlot(ctx, tg.slot, f.player, "discard")
		GEffects.done(ctx, f)

	## 새 배틀 포켓몬 내기 (배틀 포켓몬이 없을 때)
	FRAMES["promote"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		if p.active != null or p.bench.is_empty():
			GEffects.done(ctx, f)
			return
		if f.step == 0:
			GCore.ask(ctx, f, 1, f.player, "promote", p.bench.map(func(b): return b.sid), 1, 1, "새 배틀 포켓몬을 고르세요.")
			return
		var pick = f.picks[0]
		var i := GCore.find_index(p.bench, func(b): return b.sid == pick)
		if i >= 0:
			p.active = p.bench.pop_at(i)
			GCore.emit(ctx, { "type": "switch", "player": f.player, "from": "", "to": p.active.sid })
		GEffects.done(ctx, f)

# ───────────────────────── 공식 덱 레시피 하위 프레임 ─────────────────────────

## 로스트스위퍼 대상: 양쪽 필드의 포켓몬의 도구 + 스타디움
static func sweeperTargets(ctx: Dictionary) -> Array:
	var out: Array = []
	for seat in [0, 1]:
		for sl in GCore.slotsOf(ctx.s, seat):
			var t = GCore.toolOf(ctx, sl)
			if GCore.truthy(t):
				out.append(t)
	if GCore.truthy(ctx.s.stadium):
		out.append(ctx.s.stadium)
	return out

## TS (d.tags ?? []).includes(tag)
static func hasTag(d: Dictionary, tag: String) -> bool:
	var tg = d.get("tags")
	return tg != null and (tg as Array).has(tag)

static func _initFrames3() -> void:
	## 덱 위 look 장을 보고 take 장을 패로, 나머지는 로스트존 (어비스시크·아크로마의 실험)
	FRAMES["lookTake"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		var look := int(f.data.look)
		var top: Array = p.deck.slice(0, look)
		if f.step == 0:
			if top.is_empty():
				GEffects.done(ctx, f)
				return
			var take := mini(int(f.data.take), top.size())
			GCore.ask(ctx, f, 1, f.player, "pickCards", top, take, take, str(f.data.get("prompt")), { "cards": GEffects.cardsOf(ctx, top) })
			return
		var picks: Array = GEffects._picks(f)
		for iid in top:
			if picks.has(iid):
				GCore.moveCard(ctx, iid, { "zone": "hand", "player": f.player })
			else:
				GCore.moveCard(ctx, iid, { "zone": "lost", "player": f.player })
		GEffects.done(ctx, f)

	## 교체카트: 기본 배틀 포켓몬을 벤치와 교체 → 벤치로 간 포켓몬 HP 30 회복
	FRAMES["switchCart"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		if f.step == 0:
			if p.bench.is_empty() or p.active == null:
				GEffects.done(ctx, f)
				return
			f.data["old"] = p.active.sid
			GCore.ask(ctx, f, 1, f.player, "pickSlot", p.bench.map(func(b): return b.sid), 1, 1, "배틀 포켓몬과 바꿀 벤치 포켓몬을 고르세요.")
			return
		if GEffects._picks(f).size() > 0:
			GCore.switchActive(ctx, f.player, f.picks[0])
		var old = GCore.findSlot(ctx.s, str(f.data.old))
		if old != null:
			GCore.heal(ctx, old.slot, 30)
		GEffects.done(ctx, f)

	## 동굴탈출로프: 상대부터 각자 배틀 포켓몬을 벤치와 교체 (각자 고름)
	FRAMES["escapeRope"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var opp := GCore.other(f.player)
		if f.step == 0:
			var ob: Array = ctx.s.players[opp].bench
			if ob.size() > 0 and ctx.s.players[opp].active != null:
				GCore.ask(ctx, f, 1, opp, "pickSlot", ob.map(func(b): return b.sid), 1, 1, "동굴탈출로프: 배틀 포켓몬과 바꿀 내 벤치 포켓몬을 고르세요.")
				return
			f.step = 1
		if f.step == 1:
			if GEffects._picks(f).size() > 0:
				GCore.switchActive(ctx, opp, f.picks[0])
			f.erase("picks")
			var mb: Array = ctx.s.players[f.player].bench
			if mb.size() > 0 and ctx.s.players[f.player].active != null:
				GCore.ask(ctx, f, 2, f.player, "pickSlot", mb.map(func(b): return b.sid), 1, 1, "배틀 포켓몬과 바꿀 벤치 포켓몬을 고르세요.")
				return
			GEffects.done(ctx, f)
			return
		if GEffects._picks(f).size() > 0:
			GCore.switchActive(ctx, f.player, f.picks[0])
		GEffects.done(ctx, f)

	FRAMES["lostSweeper"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		if f.step == 0:
			GCore.ask(ctx, f, 1, f.player, "pickCards", p.hand.duplicate(), 1, 1, "로스트존에 둘 패 1장 (사용 비용)", { "cards": GEffects.cardsOf(ctx, p.hand) })
			return
		if f.step == 1:
			if GEffects._picks(f).size() > 0:
				GCore.moveCard(ctx, f.picks[0], { "zone": "lost", "player": f.player })
			var opts: Array = GEffects.sweeperTargets(ctx)
			if opts.is_empty():
				GEffects.done(ctx, f)
				return
			GCore.ask(ctx, f, 2, f.player, "pickCards", opts, 1, 1, "로스트존에 둘 포켓몬의 도구 또는 스타디움", { "cards": GEffects.cardsOf(ctx, opts) })
			return
		var pk: Array = GEffects._picks(f)
		var t = pk[0] if pk.size() > 0 else null
		if GCore.truthy(t):
			var was_stadium: bool = ctx.s.stadium == t
			GCore.moveCard(ctx, t, { "zone": "lost", "player": ctx.s.cards[t].owner })
			if was_stadium:
				GEffects.updateBench(ctx)
		GEffects.done(ctx, f)

	## 히스이의 헤비볼: 사이드를 모두 보고 기본 포켓몬 1장을 이 카드와 바꿔 패로 → 사이드를 섞음
	FRAMES["heavyBall"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		var prizes: Array = p.prizes.filter(func(x): return GCore.truthy(x))
		if f.step == 0:
			if prizes.is_empty():
				GEffects.done(ctx, f)
				return
			var opts: Array = GEffects.cardsMatching(ctx, prizes, GEffects.BASIC)
			GCore.ask(ctx, f, 1, f.player, "pickCards", opts, 0, 1, "사이드(프라이즈) 중 패로 가져올 기본 포켓몬 (없으면 그냥 결정)", { "cards": GEffects.cardsOf(ctx, prizes) })
			return
		var pk: Array = GEffects._picks(f)
		var pick = pk[0] if pk.size() > 0 else null
		var ball := str(f.data.card)
		if GCore.truthy(pick):
			var idx: int = p.prizes.find(pick)
			var nid := GCore.moveCard(ctx, pick, { "zone": "hand", "player": f.player })
			var rev := { "id": GCore.newId(ctx.s, "v"), "owner": f.player, "reason": GEffects.effectSource(ctx) + ": 사이드에서 [기본 포켓몬] → 패로 가져갑니다\n효과로 가져가는 카드를 상대에게 보여줍니다.", "cards": GEffects.cardsOf(ctx, [nid]) }
			ctx.s.reveals.append(rev)
			GCore.emit(ctx, { "type": "reveal", "reveal": rev })
			ctx.s.requests.append({ "id": GCore.newId(ctx.s, "r"), "player": GCore.other(f.player), "kind": "ackReveal", "options": ["ok"], "min": 1, "max": 1, "prompt": "상대가 보여준 카드를 확인하세요.", "revealId": rev.id })
			if ctx.s.using.has(ball):
				GCore.moveCard(ctx, ball, { "zone": "prizes", "player": f.player, "index": idx })
		# 사이드를 뒷면으로 섞는다 (자리 그대로, 카드 순서만 섞고 새 iid)
		var idxs: Array = []
		for i in p.prizes.size():
			if GCore.truthy(p.prizes[i]):
				idxs.append(i)
		var vals: Array = idxs.map(func(i): return p.prizes[i])
		GRng.shuffleInPlace(ctx.s.rng, vals)
		for k in idxs.size():
			var c: Dictionary = ctx.s.cards[vals[k]]
			ctx.s.cards.erase(vals[k])
			var nid2 := GCore.newId(ctx.s, "c")
			var nc := c.duplicate()
			nc["iid"] = nid2
			ctx.s.cards[nid2] = nc
			p.prizes[idxs[k]] = nid2
		GEffects.done(ctx, f)

	## 악의 탑 (스타디움 효과): 패의 「일격」 카드 1장 트래쉬 → 2장 뽑기
	FRAMES["darkTower"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		var opts: Array = p.hand.filter(func(i): return GEffects.hasTag(GCore.dataOf(ctx, i), "일격"))
		if f.step == 0:
			if opts.is_empty():
				GEffects.done(ctx, f)
				return
			GCore.ask(ctx, f, 1, f.player, "pickCards", opts, 1, 1, "트래쉬할 '일격' 카드를 고르세요.", { "cards": GEffects.cardsOf(ctx, opts) })
			return
		if GEffects._picks(f).size() > 0:
			GCore.moveCard(ctx, f.picks[0], { "zone": "discard", "player": f.player })
			GCore.drawN(ctx, f.player, 2)
		GEffects.done(ctx, f)

	## 헬가 "일격의 포효": 덱의 일격 에너지를 일격 포켓몬에게 붙이고 그 포켓몬에 카운터 2개
	FRAMES["singleStrikeRoar"] = func(ctx: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			GEffects.seq(ctx, f, 1, [GEffects.search("deck", { "name": "일격 에너지" }, 1, "save", { "save": "picked", "shuffle": false, "prompt": "붙일 일격 에너지를 고르세요." })])
			return
		var picked: Array = f.data.picked if f.data.get("picked") != null else []
		if f.step == 1:
			var targets: Array = GCore.slotsOf(ctx.s, f.player).filter(func(sl): return GEffects.hasTag(GCore.slotData(ctx, sl), "일격")).map(func(sl): return sl.sid)
			if picked.is_empty() or targets.is_empty():
				GCore.shuffleDeck(ctx, f.player)
				GEffects.done(ctx, f)
				return
			GCore.ask(ctx, f, 2, f.player, "pickSlot", targets, 1, 1, "일격 에너지를 붙일 '일격' 포켓몬 (데미지 카운터 2개)", { "cards": GEffects.cardsOf(ctx, picked) })
			return
		var fs = GCore.findSlot(ctx.s, f.picks[0])
		var t = fs.slot if fs != null else null
		if t != null:
			GCore.moveCard(ctx, picked[0], { "zone": "attach", "sid": t.sid })
		GCore.shuffleDeck(ctx, f.player)
		if t != null:
			GCore.putCounters(ctx, t, 2)
		GEffects.done(ctx, f)

	## 큐아링 "꽃고르기": 덱 위 2장 중 1장 패로, 나머지 로스트존
	FRAMES["flowerSelecting"] = func(ctx: Dictionary, f: Dictionary) -> void:
		GEffects.then(ctx, f, [["lookTake", { "look": 2, "take": 1, "prompt": "덱 위 2장 중 패로 가져올 1장 (나머지는 로스트존)" }]])

	## 찬란한 개굴닌자 "숨겨진 수단": 패의 에너지 1장 트래쉬 → 2장 뽑기
	FRAMES["concealedCards"] = func(ctx: Dictionary, f: Dictionary) -> void:
		var p: Dictionary = ctx.s.players[f.player]
		var opts: Array = p.hand.filter(func(i): return GCore.dataOf(ctx, i).kind == "energy")
		if f.step == 0:
			GCore.ask(ctx, f, 1, f.player, "pickCards", opts, 1, 1, "트래쉬할 에너지를 고르세요.", { "cards": GEffects.cardsOf(ctx, opts) })
			return
		if GEffects._picks(f).size() > 0:
			GCore.moveCard(ctx, f.picks[0], { "zone": "discard", "player": f.player })
			GCore.drawN(ctx, f.player, 2)
		GEffects.done(ctx, f)

	## 데미지 카운터 n개를 상대 포켓몬에게 원하는 대로 (하나씩 고름) — data { n }
	FRAMES["placeCounters"] = func(ctx: Dictionary, f: Dictionary) -> void:
		if f.step == 0:
			f.data["left"] = int(f.data.n)
			f.step = 1
		if f.step == 2 and GEffects._picks(f).size() > 0:
			var t = GCore.findSlot(ctx.s, f.picks[0])
			if t != null:
				GCore.putCounters(ctx, t.slot, 1)
			f.data["left"] = int(f.data.left) - 1
		var opts: Array = GCore.slotsOf(ctx.s, GCore.other(f.player)).map(func(sl): return sl.sid)
		if int(f.data.left) <= 0 or opts.is_empty():
			GEffects.done(ctx, f)
			return
		GCore.ask(ctx, f, 2, f.player, "pickSlot", opts, 1, 1, "데미지 카운터를 올릴 상대 포켓몬 (남은 " + str(f.data.left) + "개)")

# ───────────────────────── 벤치 칸 수 (제로의 대공동) ─────────────────────────

## 스타디움·테라스탈 변화 뒤 벤치 칸 수를 다시 계산. 넘치면 넘친 만큼 트래쉬 (스타디움 주인부터)
static func updateBench(ctx: Dictionary) -> void:
	var st = GCore.stadiumName(ctx)
	var order: Array
	if GCore.truthy(ctx.s.stadium):
		var owner: int = ctx.s.cards[ctx.s.stadium].owner
		order = [owner, GCore.other(owner)]
	else:
		order = [0, 1]
	for seat in order:
		var p: Dictionary = ctx.s.players[seat]
		p.benchMax = 8 if (st == "제로의 대공동" and GCore.hasTera(ctx, seat)) else 5
		if p.bench.size() > p.benchMax:
			GCore.pushFrame(ctx, "benchTrim", seat, {})

# ───────────────────────── 자동화 여부 ─────────────────────────

const PASSIVE := ["スカイライン", "いたずらロック", "ダイヤコート", "フェアリーゾーン", "ふくがん", "みがる", "ろうれんのわざ", "がんばりハート", "エースキャンセラー",
	"ブーストしんか", "にじいろDNA", "ほうせきさがし", "れんごくしはい", "フライングエントリー", "ラピッドバーニア",
	"벤치배리어", "파도의 베일", "로스트 프로바이드", "와일드스타일", "다크시그널"]
const TOOLS := ["반짝이는 결정", "풍선", "오기머리띠", "용기의부적", "학습장치", "부스트에너지 미래", "기술머신 에볼루션"]
const STADIUMS := ["제로의 대공동", "재밍타워", "그래비티 마운틴", "보울마을", "악의 탑", "정상으로 가는 눈길"]
const SPECIAL_ENERGY := ["제트 에너지", "네오 어퍼 에너지", "루미너스 에너지", "일격 에너지", "캡쳐 에너지"]

## 카드 효과가 자동화되었는가 (화면에 "수동" 표시용, 데이터 테스트에서 전부 true 인지 검사)
static func isAutomated(d: Dictionary) -> bool:
	ensure()
	if d.kind == "energy":
		return _ebasic(d) or SPECIAL_ENERGY.has(d.name)
	if d.kind == "trainer":
		return TRAINERS.has(d.name) or TOOLS.has(d.name) or STADIUMS.has(d.name)
	var p: Dictionary = d.pokemon
	return p.attacks.all(func(a): return GEffects.ATTACKS.has(a.nameJa)) and p.abilities.all(func(a): return GEffects.PASSIVE.has(a.nameJa) or GEffects.ABILITIES.has(a.nameJa))

## TS: export { ownerOfSlot } (core.ts 재수출)
static func ownerOfSlot(s: Dictionary, slot: Dictionary) -> int:
	return GCore.ownerOfSlot(s, slot)
