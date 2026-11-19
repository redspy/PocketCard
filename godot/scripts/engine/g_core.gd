class_name GCore
## src/game/core.ts (+ cardData.ts 일부) 포팅 — 카드 이동, 슬롯, 에너지 비용, HP·후퇴 보정, 데미지 계산, 요청·프레임 도우미.
## 포팅 규칙: PORTING.md. 모든 함수는 ctx.s(상태 복사본)를 직접 바꾼다.

const BENCH_MAX := 5
const TYPE_KO := { "G": "풀", "R": "불꽃", "W": "물", "L": "번개", "P": "초", "F": "격투", "D": "악", "M": "강철", "N": "드래곤", "C": "무색" }

# ───────────────────────── 포팅 도우미 (TS 에 없는 것) ─────────────────────────

## TS 의 throw 대신: 첫 오류만 기록 (엔진이 입력 처리 뒤 확인)
static func fail(ctx: Dictionary, code: String, message: String) -> void:
	if not ctx.has("err"):
		ctx["err"] = { "code": code, "message": message }

## JS 의 참/거짓 판정 (null, false, "", 0 은 거짓)
static func truthy(x) -> bool:
	if x == null:
		return false
	match typeof(x):
		TYPE_BOOL: return x
		TYPE_INT, TYPE_FLOAT: return x != 0
		TYPE_STRING, TYPE_STRING_NAME: return x != ""
	return true

## 객체(슬롯·프레임) 동일성으로 찾기 — Dictionary == 는 내용 비교라서 쓰면 안 됨
static func idx_same(arr: Array, obj) -> int:
	for i in arr.size():
		if is_same(arr[i], obj):
			return i
	return -1

static func has_same(arr: Array, obj) -> bool:
	return idx_same(arr, obj) >= 0

static func find_first(arr: Array, pred: Callable):
	for x in arr:
		if pred.call(x):
			return x
	return null

static func find_index(arr: Array, pred: Callable) -> int:
	for i in arr.size():
		if pred.call(arr[i]):
			return i
	return -1

## JS Array.sort 와 같은 안정 정렬 (병합 정렬). cmp(a, b) < 0 이면 a 가 앞. 새 배열을 돌려준다.
static func stable_sort(arr: Array, cmp: Callable) -> Array:
	if arr.size() <= 1:
		return arr.duplicate()
	var mid := arr.size() / 2
	var left := stable_sort(arr.slice(0, mid), cmp)
	var right := stable_sort(arr.slice(mid), cmp)
	var out: Array = []
	var i := 0
	var j := 0
	while i < left.size() and j < right.size():
		if cmp.call(right[j], left[i]) < 0:
			out.append(right[j])
			j += 1
		else:
			out.append(left[i])
			i += 1
	while i < left.size():
		out.append(left[i])
		i += 1
	while j < right.size():
		out.append(right[j])
		j += 1
	return out

## JSON 에서 읽은 값의 정수 같은 실수를 int 로 (Godot JSON 은 숫자를 모두 float 로 읽음)
static func intify(v):
	match typeof(v):
		TYPE_FLOAT:
			return int(v) if v == floorf(v) else v
		TYPE_ARRAY:
			var a: Array = []
			for x in v:
				a.append(intify(x))
			return a
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[k] = intify(v[k])
			return d
	return v

# ───────────────────────── 기본 ─────────────────────────

static func other(p: int) -> int:
	return 1 if p == 0 else 0

static func emit(ctx: Dictionary, e: Dictionary) -> void:
	var s: Dictionary = ctx.s
	s.eventSeq += 1
	var ev := e.duplicate()
	ev["seq"] = s.eventSeq
	ctx.ev.append(ev)

static func newId(s: Dictionary, prefix: String) -> String:
	var id := "%s%d" % [prefix, s.nextId]
	s.nextId += 1
	return id

static func note(ctx: Dictionary, text: String) -> void:
	emit(ctx, { "type": "note", "text": text })

## 기절 시 상대가 가져가는 사이드 수 (cardData.ts prizeValue)
static func prizeValue(c) -> int:
	if c == null or not (c as Dictionary).has("pokemon"):
		return 1
	var rule = c.pokemon.get("rule")
	return 3 if (rule == "mega" or rule == "VMAX") else (2 if truthy(rule) else 1)

# ───────────────────────── 카드 조회 ─────────────────────────

static func inst(ctx: Dictionary, iid: String) -> Dictionary:
	return ctx.s.cards[iid]

static func dataOf(ctx: Dictionary, iid: String) -> Dictionary:
	var c = ctx.s.cards.get(iid)
	var rid = c.ruleId if c != null else null
	var d = ctx.info.db.get(rid) if rid != null else null
	if d == null:
		fail(ctx, "no_card_data", "카드 데이터 없음: %s" % str(rid))
		return { "id": "", "name": "", "kind": "", "text": "" }
	return d

static func nameOf(ctx: Dictionary, iid: String) -> String:
	return dataOf(ctx, iid).name

static func topOf(slot: Dictionary) -> String:
	return slot.stack[slot.stack.size() - 1]

static func slotData(ctx: Dictionary, slot: Dictionary) -> Dictionary:
	return dataOf(ctx, topOf(slot))

static func slotName(ctx: Dictionary, slot: Dictionary) -> String:
	return slotData(ctx, slot).name

## 필드의 포켓몬 (배틀 먼저)
static func slotsOf(s: Dictionary, seat: int) -> Array:
	var p: Dictionary = s.players[seat]
	var out: Array = []
	if p.active != null:
		out.append(p.active)
	out.append_array(p.bench)
	return out

static func findSlot(s: Dictionary, sid: String):
	for seat in [0, 1]:
		var p: Dictionary = s.players[seat]
		if p.active != null and p.active.sid == sid:
			return { "slot": p.active, "owner": seat, "active": true }
		for b in p.bench:
			if b.sid == sid:
				return { "slot": b, "owner": seat, "active": false }
	return null

static func isActive(s: Dictionary, slot: Dictionary) -> bool:
	return is_same(s.players[0].active, slot) or is_same(s.players[1].active, slot)

static func ownerOfSlot(s: Dictionary, slot: Dictionary) -> int:
	return 0 if (is_same(s.players[0].active, slot) or has_same(s.players[0].bench, slot)) else 1

# ───────────────────────── 카드 이동 ─────────────────────────

static func locate(s: Dictionary, iid: String):
	for seat in [0, 1]:
		var p: Dictionary = s.players[seat]
		if p.deck.has(iid): return { "player": seat, "zone": "deck" }
		if p.hand.has(iid): return { "player": seat, "zone": "hand" }
		if p.prizes.has(iid): return { "player": seat, "zone": "prizes" }
		if p.discard.has(iid): return { "player": seat, "zone": "discard" }
		if p.lost.has(iid): return { "player": seat, "zone": "lost" }
		if p.active != null and (p.active.stack.has(iid) or p.active.attached.has(iid)): return { "player": seat, "zone": "active" }
		for b in p.bench:
			if b.stack.has(iid) or b.attached.has(iid):
				return { "player": seat, "zone": "bench" }
	if s.stadium == iid: return { "player": s.cards[iid].owner, "zone": "stadium" }
	if s.using.has(iid): return { "player": s.cards[iid].owner, "zone": "reveal" }
	return null

static func _drop(arr: Array, iid: String) -> void:
	var i := arr.find(iid)
	if i >= 0:
		arr.remove_at(i)

static func removeFrom(ctx: Dictionary, s: Dictionary, iid: String):
	var loc = locate(s, iid)
	if loc == null:
		fail(ctx, "card_missing", "카드 %s 를 찾을 수 없습니다." % iid)
		return null
	var p: Dictionary = s.players[loc.player]
	match loc.zone:
		"deck": _drop(p.deck, iid)
		"hand": _drop(p.hand, iid)
		"prizes": p.prizes[p.prizes.find(iid)] = null
		"discard": _drop(p.discard, iid)
		"lost": _drop(p.lost, iid)
		"stadium": s.stadium = null
		"reveal": _drop(s.using, iid)
		"active", "bench":
			var slot
			if loc.zone == "active":
				slot = p.active
			else:
				slot = find_first(p.bench, func(b): return b.stack.has(iid) or b.attached.has(iid))
			_drop(slot.stack, iid)
			_drop(slot.attached, iid)
			if slot.stack.size() == 0:
				if slot.attached.size() > 0:
					fail(ctx, "slot_not_empty", "붙은 카드가 남은 채로 포켓몬을 옮길 수 없습니다.")
					return loc
				if loc.zone == "active":
					p.active = null
				else:
					p.bench.remove_at(idx_same(p.bench, slot))
		_:
			fail(ctx, "bad_zone", str(loc.zone))
	return loc

static func emptyCond() -> Dictionary:
	return { "poison": 0, "burn": false, "rot": "", "paraUntil": 0 }

static func newSlot(s: Dictionary, iid: String, face_down := false) -> Dictionary:
	return { "sid": newId(s, "s"), "stack": [iid], "attached": [], "damage": 0, "faceDown": face_down, "enteredTurn": s.turnNumber, "abilityTurn": -1,
		"cond": emptyCond(), "effects": [] }

## 카드를 옮기고 새 iid 를 돌려준다.
## dest: { zone: deck(player, position) | hand/discard(player) | prizes(player, index) | active/bench(player, faceDown?) | attach/evolve(sid) | stadium | reveal }
static func moveCard(ctx: Dictionary, iid: String, dest: Dictionary) -> String:
	var s: Dictionary = ctx.s
	var from = removeFrom(ctx, s, iid)
	if from == null:
		return ""
	var old: Dictionary = s.cards[iid]
	s.cards.erase(iid)
	var nid := newId(s, "c")
	var nc := old.duplicate()
	nc["iid"] = nid
	s.cards[nid] = nc
	var to := {}
	var face_down := false
	match dest.zone:
		"deck":
			var p: Dictionary = s.players[dest.player]
			if dest.position == "top":
				p.deck.push_front(nid)
			else:
				p.deck.append(nid)
			to = { "player": dest.player, "zone": "deck" }
		"hand":
			s.players[dest.player].hand.append(nid)
			to = { "player": dest.player, "zone": "hand" }
		"discard":
			s.players[dest.player].discard.append(nid)
			to = { "player": dest.player, "zone": "discard" }
		"lost":
			s.players[dest.player].lost.append(nid)
			to = { "player": dest.player, "zone": "lost" }
		"prizes":
			s.players[dest.player].prizes[dest.index] = nid
			to = { "player": dest.player, "zone": "prizes" }
		"active", "bench":
			var p: Dictionary = s.players[dest.player]
			var fd := bool(dest.get("faceDown", false))
			var slot := newSlot(s, nid, fd)
			face_down = fd
			if dest.zone == "active":
				if p.active != null:
					fail(ctx, "active_taken", "이미 배틀 포켓몬이 있습니다.")
					return nid
				p.active = slot
			else:
				if p.bench.size() >= p.benchMax:
					fail(ctx, "bench_full", "벤치가 가득 찼습니다.")
					return nid
				p.bench.append(slot)
			to = { "player": dest.player, "zone": dest.zone }
		"attach", "evolve":
			var f = findSlot(s, dest.sid)
			if f == null:
				fail(ctx, "no_slot", "대상 포켓몬이 없습니다.")
				return nid
			if dest.zone == "attach":
				f.slot.attached.append(nid)
			else:
				f.slot.stack.append(nid)
				f.slot.enteredTurn = s.turnNumber
				f.slot.abilityTurn = -1
				f.slot.cond = emptyCond()
				f.slot.effects = []
			to = { "player": f.owner, "zone": "active" if f.active else "bench" }
		"stadium":
			s.stadium = nid
			to = { "player": old.owner, "zone": "stadium" }
		"reveal":
			s.using.append(nid)
			to = { "player": old.owner, "zone": "reveal" }
	var e := { "type": "move", "card": { "iid": nid, "code": old.code }, "from": from, "to": to }
	if face_down:
		e["faceDown"] = true
	emit(ctx, e)
	return nid

## 포켓몬과 붙은 카드 전부를 트래쉬 (기절) 또는 패로
static func clearSlot(ctx: Dictionary, slot: Dictionary, owner: int, to: String) -> void:
	for a in slot.attached.duplicate():
		moveCard(ctx, a, { "zone": "discard", "player": owner })
	for c in slot.stack.duplicate():
		var is_pokemon: bool = dataOf(ctx, c).kind == "pokemon"
		moveCard(ctx, c, { "zone": "hand" if (to == "hand" and is_pokemon) else "discard", "player": owner })

static func shuffleDeck(ctx: Dictionary, seat: int) -> void:
	var s: Dictionary = ctx.s
	var p: Dictionary = s.players[seat]
	GRng.shuffleInPlace(s.rng, p.deck)
	# 셔플 후에는 덱 안 카드의 iid 도 새로 발급 (셔플 전 위치 추적 방지)
	var nd: Array = []
	for iid in p.deck:
		var c: Dictionary = s.cards[iid]
		s.cards.erase(iid)
		var nid := newId(s, "c")
		var nc := c.duplicate()
		nc["iid"] = nid
		s.cards[nid] = nc
		nd.append(nid)
	p.deck = nd
	emit(ctx, { "type": "shuffle", "player": seat })

static func drawOne(ctx: Dictionary, seat: int) -> bool:
	var deck: Array = ctx.s.players[seat].deck
	if deck.is_empty():
		return false
	moveCard(ctx, deck[0], { "zone": "hand", "player": seat })
	return true

static func drawN(ctx: Dictionary, seat: int, n: int) -> void:
	for i in n:
		if not drawOne(ctx, seat):
			break

static func flip(ctx: Dictionary, seat: int, reason: String) -> bool:
	var heads := GRng.coin(ctx.s.rng)
	emit(ctx, { "type": "coin", "player": seat, "heads": heads, "reason": reason })
	return heads

## 배틀 포켓몬과 벤치 포켓몬을 맞바꾼다 (교체: 특수상태·포켓몬 효과는 사라짐)
static func switchActive(ctx: Dictionary, seat: int, bench_sid: String) -> void:
	var p: Dictionary = ctx.s.players[seat]
	var i := find_index(p.bench, func(b): return b.sid == bench_sid)
	if i < 0 or p.active == null:
		fail(ctx, "bad_switch", "교체할 포켓몬이 없습니다.")
		return
	var old: Dictionary = p.active
	old.cond = emptyCond()
	old.effects = []
	p.active = p.bench[i]
	p.bench[i] = old
	emit(ctx, { "type": "switch", "player": seat, "from": old.sid, "to": p.active.sid })

# ───────────────────────── 요청 / 프레임 ─────────────────────────

static func request(ctx: Dictionary, player: int, kind: String, options: Array, mn: int, mx: int, prompt: String, extra := {}) -> Dictionary:
	var r := { "id": newId(ctx.s, "r"), "player": player, "kind": kind, "options": options, "min": mn, "max": mx, "prompt": prompt }
	for k in extra:
		r[k] = extra[k]
	ctx.s.requests.append(r)
	return r

static func pushFrame(ctx: Dictionary, kind: String, player: int, data := {}) -> Dictionary:
	var f := { "id": newId(ctx.s, "f"), "kind": kind, "step": 0, "player": player, "data": data }
	ctx.s.stack.append(f)
	return f

## 프레임에서 선택을 요청하고 멈춘다 (답이 오면 frame.picks 에 담겨 같은 프레임이 다시 실행됨)
static func ask(ctx: Dictionary, f: Dictionary, next_step: int, player: int, kind: String, options: Array, mn: int, mx: int, prompt: String, extra := {}) -> void:
	f.step = next_step
	f.erase("picks")
	var ex := extra.duplicate()
	ex["frame"] = f.id
	request(ctx, player, kind, options, mini(mn, options.size()), mini(mx, options.size()), prompt, ex)

# ───────────────────────── 상태 판정 ─────────────────────────

static func stadiumName(ctx: Dictionary):
	return nameOf(ctx, ctx.s.stadium) if ctx.s.stadium != null else null

static func toolsActive(ctx: Dictionary) -> bool:
	return stadiumName(ctx) != "재밍타워"

static func toolOf(ctx: Dictionary, slot: Dictionary):
	return find_first(slot.attached, func(a): return GCore.dataOf(ctx, a).kind == "trainer")

static func toolName(ctx: Dictionary, slot: Dictionary):
	var t = toolOf(ctx, slot)
	return nameOf(ctx, t) if (t != null and toolsActive(ctx)) else null

static func energiesOf(ctx: Dictionary, slot: Dictionary) -> Array:
	return slot.attached.filter(func(a): return GCore.dataOf(ctx, a).kind == "energy")

static func _abilities(d: Dictionary) -> Array:
	return d.pokemon.abilities if d.has("pokemon") else []

static func _ability0_ja(d: Dictionary):
	var abs := _abilities(d)
	return abs[0].nameJa if abs.size() > 0 else null

## 클레피 "장난 잠금": 양쪽 배틀 필드 어디든 클레피가 있으면 기본 포켓몬의 특성(장난 잠금 제외)이 없어진다
static func abilityActive(ctx: Dictionary, slot: Dictionary) -> bool:
	var d := slotData(ctx, slot)
	if _abilities(d).is_empty() or slot.faceDown:
		return false
	# 정상으로 가는 눈길: 서로의 룰을 가진 포켓몬의 특성은 모두 없어진다
	if d.pokemon.rule != null and stadiumName(ctx) == "정상으로 가는 눈길":
		return false
	if d.pokemon.stage != 0 or d.pokemon.abilities[0].nameJa == "いたずらロック":
		return true
	for seat in [0, 1]:
		var a = ctx.s.players[seat].active
		if a != null and not a.faceDown and _ability0_ja(slotData(ctx, a)) == "いたずらロック":
			return false
	return true

static func hasAbility(ctx: Dictionary, slot: Dictionary, name_ja: String) -> bool:
	return _ability0_ja(slotData(ctx, slot)) == name_ja and abilityActive(ctx, slot)

## 이 플레이어 필드에 특성이 켜진 포켓몬이 있는가
static func fieldHasAbility(ctx: Dictionary, seat: int, name_ja: String) -> bool:
	return slotsOf(ctx.s, seat).any(func(sl): return GCore.hasAbility(ctx, sl, name_ja))

static func hasTera(ctx: Dictionary, seat: int) -> bool:
	return slotsOf(ctx.s, seat).any(func(sl):
		var d := GCore.slotData(ctx, sl)
		return d.has("pokemon") and bool(d.pokemon.tera))

static func maxHp(ctx: Dictionary, slot: Dictionary) -> int:
	var p: Dictionary = slotData(ctx, slot).pokemon
	var hp: int = p.hp
	if toolName(ctx, slot) == "용기의부적" and p.stage == 0:
		hp += 50
	if stadiumName(ctx) == "그래비티 마운틴" and p.stage == 2:
		hp -= 30
	return hp

static func remainingHp(ctx: Dictionary, slot: Dictionary) -> int:
	return maxHp(ctx, slot) - slot.damage

static func retreatCost(ctx: Dictionary, slot: Dictionary, seat: int) -> int:
	var p: Dictionary = slotData(ctx, slot).pokemon
	var c: int = p.retreat
	var tool = toolName(ctx, slot)
	if tool == "풍선":
		c -= 2
	if tool == "부스트에너지 미래" and p.future:
		c = 0
	if p.stage == 0 and fieldHasAbility(ctx, seat, "スカイライン"):
		c = 0
	if hasAbility(ctx, slot, "みがる") and energiesOf(ctx, slot).size() == 0:
		c = 0
	return maxi(0, c)

## 붙은 에너지가 제공하는 에너지 단위. '*' = 모든 타입
static func provided(ctx: Dictionary, slot: Dictionary) -> Array:
	var out: Array = []
	var ens := energiesOf(ctx, slot)
	var specials := ens.filter(func(e):
		var d := GCore.dataOf(ctx, e)
		return not (d.has("energy") and d.energy.basic))
	var sd := slotData(ctx, slot)
	var stage: int = sd.pokemon.stage if sd.has("pokemon") else 0
	for e in ens:
		var d := dataOf(ctx, e)
		if d.has("energy") and d.energy.basic and truthy(d.energy.type):
			out.append(d.energy.type)
			continue
		match d.name:
			"제트 에너지", "캡쳐 에너지": out.append("C")
			"일격 에너지": out.append("FD")
			"루미너스 에너지": out.append("C" if specials.size() > 1 else "*")
			"네오 어퍼 에너지":
				if stage == 2:
					out.append("*")
					out.append("*")
				else:
					out.append("C")
			_: out.append("C")
	return out

## 비용을 낼 수 있는가 (특정 타입부터 맞추고, 무색은 남은 것으로)
static func canPay(units: Array, cost: Array) -> bool:
	var pool := units.duplicate()
	var specific := cost.filter(func(c): return c != "C")
	var colorless := cost.size() - specific.size()
	for t in specific:
		var i := pool.find(t)
		if i < 0:
			i = find_index(pool, func(u): return String(u).length() == 2 and String(u).contains(t))
		if i < 0:
			i = pool.find("*")
		if i < 0:
			return false
		pool.remove_at(i)
	return pool.size() >= colorless

## 기술 비용 (카드 효과로 줄어든 것 반영)
static func attackCost(ctx: Dictionary, slot: Dictionary, seat: int, cost: Array, attack_ja: String) -> Array:
	var c := cost.duplicate()
	var d: Dictionary = slotData(ctx, slot).pokemon
	if toolName(ctx, slot) == "반짝이는 결정" and d.tera:
		var i := c.rfind("C")
		if i >= 0:
			c.remove_at(i)
		else:
			c.pop_back()
	# 윽우지 "로스트 프로바이드": 로스트존 4장 이상이면 기술 에너지가 모두 없어짐
	if hasAbility(ctx, slot, "로스트 프로바이드") and ctx.s.players[seat].lost.size() >= 4:
		return []
	# 드래피온 V "와일드스타일": 상대 필드의 일격·연격·퓨전 포켓몬 수만큼 무색 에너지가 적어짐
	if hasAbility(ctx, slot, "와일드스타일"):
		var n := slotsOf(ctx.s, other(seat)).filter(func(sl):
			if sl.faceDown:
				return false
			var tg = GCore.slotData(ctx, sl).get("tags")
			return tg != null and (tg as Array).any(func(t): return t == "일격" or t == "연격" or t == "퓨전")).size()
		for k in n:
			var j := c.rfind("C")
			if j >= 0:
				c.remove_at(j)
	if attack_ja == "ブラッドムーン" and hasAbility(ctx, slot, "ろうれんのわざ"):
		var taken := prizesTaken(ctx.s, other(seat))
		for k in taken:
			var j := c.rfind("C")
			if j >= 0:
				c.remove_at(j)
	return c

static func lostCount(s: Dictionary, seat: int) -> int:
	return s.players[seat].lost.size()

static func prizesLeft(s: Dictionary, seat: int) -> int:
	return s.players[seat].prizes.filter(func(x): return GCore.truthy(x)).size()

static func prizesTaken(s: Dictionary, seat: int) -> int:
	return 6 - prizesLeft(s, seat)

static func playerHasEffect(s: Dictionary, seat: int, kind: String) -> bool:
	return s.players[seat].effects.any(func(e): return e.kind == kind)

static func slotHasEffect(slot: Dictionary, kind: String) -> bool:
	return slot.effects.any(func(e): return e.kind == kind)

# ───────────────────────── 데미지 ─────────────────────────

## 기술 데미지를 준다 (규칙서 데미지 계산 순서).
## base: 기술 데미지(+, × 반영 후), wr: 약점·저항력 계산 여부(상대 배틀 포켓몬에게만 true)
## opts: { ignoreEffects?, noWeak? }
static func dealAttackDamage(ctx: Dictionary, seat: int, atk: Dictionary, target: Dictionary, base: int, wr: bool, opts: Dictionary = {}) -> int:
	var s: Dictionary = ctx.s
	var t_owner := ownerOfSlot(s, target)
	var t_active := isActive(s, target)
	var ad: Dictionary = slotData(ctx, atk).pokemon
	var td: Dictionary = slotData(ctx, target).pokemon
	var dmg := base
	if dmg <= 0:
		return 0
	# 테라스탈 룰: 벤치의 테라스탈 포켓몬은 기술 데미지를 받지 않는다
	if not t_active and td.tera:
		note(ctx, "%s: 테라스탈 — 벤치에서는 기술 데미지를 받지 않음" % slotName(ctx, target))
		return 0
	var on_opp_active := t_active and t_owner != seat
	# 뮤 "벤치배리어"·마나피 "파도의 베일": 상대 기술로 벤치 포켓몬은 데미지를 받지 않는다
	if not t_active and t_owner != seat and (fieldHasAbility(ctx, t_owner, "벤치배리어") or fieldHasAbility(ctx, t_owner, "파도의 베일")):
		note(ctx, "%s: 벤치 포켓몬은 상대 기술의 데미지를 받지 않음" % slotName(ctx, target))
		return 0
	# 2) 공격하는 쪽 효과
	if on_opp_active:
		var t_rule: bool = td.rule != null
		if playerHasEffect(s, seat, "boostExV30") and t_rule:
			dmg += 30
		if playerHasEffect(s, seat, "boostEx40") and t_rule:
			dmg += 40
		var tool = toolName(ctx, atk)
		if tool == "오기머리띠" and prizesLeft(s, seat) > prizesLeft(s, other(seat)):
			dmg += 30
		if tool == "부스트에너지 미래" and ad.future:
			dmg += 20
		if hasAbility(ctx, atk, "ふくがん") and td.abilities.size() > 0:
			dmg += 50
		# 일격 에너지: 붙인 포켓몬의 기술이 상대 배틀 포켓몬에게 주는 데미지 +20 (장마다)
		dmg += 20 * energiesOf(ctx, atk).filter(func(e): return GCore.nameOf(ctx, e) == "일격 에너지").size()
	if dmg <= 0:
		return 0
	# 3) 약점 4) 저항력 (연출용으로 적용 여부를 사건에 남김)
	var w_hit := false
	var r_hit := false
	if wr and on_opp_active:
		# 릴리에의 삐삐 ex "페어리존": 상대 필드의 드래곤 타입 포켓몬의 약점은 초 타입
		var weak = "P" if (td.type == "N" and fieldHasAbility(ctx, seat, "フェアリーゾーン")) else td.weak
		if truthy(weak) and weak == ad.type and not truthy(opts.get("noWeak")):
			dmg *= 2
			w_hit = true
		if truthy(td.resist) and td.resist == ad.type:
			dmg -= int(td.get("resistValue", 30)) if td.get("resistValue") != null else 30
			r_hit = true
		if dmg <= 0:
			return 0
	# 5) 받는 쪽 효과 ("상대 배틀 포켓몬에게 걸려 있는 효과를 계산하지 않는" 기술은 건너뜀)
	if t_owner != seat and not (truthy(opts.get("ignoreEffects")) and t_active):
		if slotHasEffect(target, "reduce30"):
			dmg -= 30
		if hasAbility(ctx, target, "ダイヤコート"):
			dmg -= 30
		if slotHasEffect(target, "immuneBasicNonC") and ad.stage == 0 and ad.type != "C":
			note(ctx, "%s: 기본 포켓몬의 기술 데미지를 받지 않음" % slotName(ctx, target))
			return 0
	if dmg <= 0:
		return 0
	# 피카츄 ex "버티는 하트": HP 만땅에서 기술 데미지로 기절할 때 HP 10 으로 남음
	var hp := maxHp(ctx, target)
	if target.damage == 0 and target.damage + dmg >= hp and hasAbility(ctx, target, "がんばりハート"):
		dmg = hp - 10
		note(ctx, "%s: 버티는 하트 — HP 10 으로 남음" % slotName(ctx, target))
	target.damage += dmg
	var ev := { "type": "damage", "player": t_owner, "sid": target.sid, "amount": dmg }
	if w_hit:
		ev["weak"] = true
	if r_hit:
		ev["resist"] = true
	emit(ctx, ev)
	return dmg

## 데미지 카운터 올리기 (데미지가 아님: 약점·저항력·데미지 증감 무시)
static func putCounters(ctx: Dictionary, target: Dictionary, n: int) -> void:
	if n <= 0:
		return
	target.damage += n * 10
	emit(ctx, { "type": "damage", "player": ownerOfSlot(ctx.s, target), "sid": target.sid, "amount": n * 10, "counters": true })

static func heal(ctx: Dictionary, target: Dictionary, amount: int) -> void:
	var h := mini(amount, target.damage)
	if h <= 0:
		return
	target.damage -= h
	emit(ctx, { "type": "heal", "player": ownerOfSlot(ctx.s, target), "sid": target.sid, "amount": h })

static func setRot(ctx: Dictionary, target: Dictionary, rot: String) -> void:
	target.cond.rot = rot
	if rot == "paralyzed":
		target.cond.paraUntil = ctx.s.turnNumber + 1
	emit(ctx, { "type": "condition", "player": ownerOfSlot(ctx.s, target), "sid": target.sid, "cond": rot, "on": true })
