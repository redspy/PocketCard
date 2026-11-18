class_name GEngine
## src/game/engine.ts 포팅 — 규칙 엔진 (결정적): (상태, 입력) → (새 상태, 이벤트). 포팅 규칙: PORTING.md
## - 난수는 state.rng 만 사용 → 같은 시드 + 같은 입력이면 같은 결과
## - 입력은 legalMoves() 목록에 있는 것만 받는다
## - 효과·절차는 프레임 스택(state.stack)에서 실행

const HAND_START := 7
const PRIZE_COUNT := 6

static var _ready := false

## 엔진 프레임(endTurn 등)을 GEffects.FRAMES 에 등록 (처음 한 번)
static func ensure() -> void:
	if _ready:
		return
	_ready = true
	GEffects.ensure()
	var F: Dictionary = GEffects.FRAMES
	F["endTurn"] = func(ctx, f): GEngine._frame_endTurn(ctx, f)
	F["checkup"] = func(ctx, f): GEngine._frame_checkup(ctx, f)
	F["koCheck"] = func(ctx, f): GEngine._frame_koCheck(ctx, f)
	F["trainerDone"] = func(ctx, f): GEngine._frame_trainerDone(ctx, f)
	F["attack"] = func(ctx, f): GEngine._frame_attack(ctx, f)
	F["abilityRun"] = func(ctx, f): GEngine._frame_abilityRun(ctx, f)
	F["retreat"] = func(ctx, f): GEngine._frame_retreat(ctx, f)
	F["trainerRun"] = func(ctx, f): GEngine._frame_trainerRun(ctx, f)

# ───────────────────────── 생성 ─────────────────────────

## config: { seed, players: [{deckId, cards: [DeckCardDef]}, ...] }, info: { basics, db }
## 반환: { state, events }
static func createGame(config: Dictionary, info: Dictionary) -> Dictionary:
	ensure()
	var s := {
		"version": 0, "phase": "setup", "rng": GRng.seedRng(config.seed), "nextId": 1, "cards": {},
		"players": [emptyPlayer(config.players[0].deckId), emptyPlayer(config.players[1].deckId)],
		"stadium": null, "firstPlayer": null, "turnPlayer": null, "turnNumber": 0,
		"requests": [], "reveals": [], "setup": null, "result": null, "eventSeq": 0, "stack": [], "inCheckup": false, "using": [], "attackCtx": null,
	}
	for seat in [0, 1]:
		for def in config.players[seat].cards:
			for i in int(def.count):
				var iid := GCore.newId(s, "c")
				s.cards[iid] = { "iid": iid, "owner": seat, "ruleId": def.ruleId, "code": def.code }
				s.players[seat].deck.append(iid)
	var ctx := { "s": s, "ev": [], "info": info }
	var heads := GRng.coin(s.rng)
	var winner := 0 if heads else 1
	GCore.emit(ctx, { "type": "coin", "player": 0, "heads": heads, "reason": "선공 결정 (앞면이면 플레이어 1이 선택)" })
	s.setup = { "step": "coin", "coinWinner": winner, "activeChosen": [false, false], "benchChosen": [false, false], "bonusDone": [false, false] }
	GCore.request(ctx, winner, "chooseFirst", ["first", "second"], 1, 1, "코인 토스에서 이겼습니다. 선공/후공을 고르세요.")
	return { "state": s, "events": ctx.ev }

static func emptyPlayer(deck_id: String) -> Dictionary:
	return {
		"deckId": deck_id, "deck": [], "hand": [], "prizes": [], "discard": [], "active": null, "bench": [], "benchMax": GCore.BENCH_MAX, "mulligans": 0, "conceded": false,
		"turns": 0, "flags": { "energy": false, "supporter": false, "retreat": false, "stadium": false, "stadiumUsed": false, "names": [] }, "koTurn": -1, "effects": [],
	}

## 진행을 막는 요청 (공개 확인은 막지 않음)
static func blockingRequests(s: Dictionary, seat = null) -> Array:
	return s.requests.filter(func(r): return r.kind != "ackReveal" and (seat == null or r.player == seat))

static func isBasicCard(ctx: Dictionary, iid: String) -> bool:
	if ctx.info.basics.has(ctx.s.cards[iid].ruleId):
		return true
	var d := GCore.dataOf(ctx, iid)
	return d.has("pokemon") and d.pokemon.stage == 0

# ───────────────────────── 셋업 ─────────────────────────

static func deal(ctx: Dictionary) -> void:
	var s: Dictionary = ctx.s
	for seat in [0, 1]:
		GCore.shuffleDeck(ctx, seat)
		for i in HAND_START:
			GCore.drawOne(ctx, seat)
	for guard in 200:
		var lacks: Array = [0, 1].filter(func(seat): return not s.players[seat].hand.any(func(iid): return GEngine.isBasicCard(ctx, iid)))
		if lacks.size() == 0:
			return
		for seat in lacks:
			var p: Dictionary = s.players[seat]
			var cards: Array = []
			for iid in p.hand:
				cards.append({ "iid": iid, "code": s.cards[iid].code })
			var rev := { "id": GCore.newId(s, "v"), "owner": seat, "reason": ("멀리건 (양쪽 모두): 처음 패 7장에 기본 포켓몬이 없어 패를 보여주고 덱에 되돌린 뒤 다시 뽑습니다. 둘 다 멀리건이면 추가 드로우는 없습니다." if lacks.size() == 2
				else "멀리건: 처음 패 7장에 기본 포켓몬이 없어서, 정말 없는지 패를 보여주고 덱에 되돌려 섞은 뒤 7장을 다시 뽑습니다. 상대는 멀리건 횟수만큼 카드를 더 뽑을 수 있습니다."),
				"cards": cards }
			s.reveals.append(rev)
			GCore.emit(ctx, { "type": "reveal", "reveal": rev })
			GCore.request(ctx, GCore.other(seat), "ackReveal", ["ok"], 1, 1, "상대가 공개한 패를 확인하세요.", { "revealId": rev.id })
			for iid in p.hand.duplicate():
				GCore.moveCard(ctx, iid, { "zone": "deck", "player": seat, "position": "top" })
			if lacks.size() == 1:
				p.mulligans += 1
				GCore.emit(ctx, { "type": "mulligan", "player": seat, "count": p.mulligans })
			GCore.shuffleDeck(ctx, seat)
			for i in HAND_START:
				GCore.drawOne(ctx, seat)
	GCore.fail(ctx, "mulligan_loop", "멀리건이 끝나지 않습니다 (덱에 기본 포켓몬이 없음).")

static func askActive(ctx: Dictionary, seat: int) -> void:
	var opts: Array = ctx.s.players[seat].hand.filter(func(iid): return GEngine.isBasicCard(ctx, iid))
	GCore.request(ctx, seat, "chooseActive", opts, 1, 1, "배틀 포켓몬으로 낼 기본 포켓몬 1장을 고르세요.")

static func askBench(ctx: Dictionary, seat: int, prompt: String) -> bool:
	var p: Dictionary = ctx.s.players[seat]
	var opts: Array = p.hand.filter(func(iid): return GEngine.isBasicCard(ctx, iid))
	var room: int = p.benchMax - p.bench.size()
	if opts.size() == 0 or room <= 0:
		return false
	GCore.request(ctx, seat, "chooseBench", opts, 0, mini(room, opts.size()), prompt)
	return true

static func advanceSetup(ctx: Dictionary) -> void:
	var s: Dictionary = ctx.s
	var st: Dictionary = s.setup
	if st.step == "bench" and st.benchChosen[0] and st.benchChosen[1]:
		for seat in [0, 1]:
			var p: Dictionary = s.players[seat]
			var pz: Array = []
			pz.resize(PRIZE_COUNT)
			pz.fill(null)
			p.prizes = pz
			for i in PRIZE_COUNT:
				if p.deck.is_empty():
					break
				GCore.moveCard(ctx, p.deck[0], { "zone": "prizes", "player": seat, "index": i })
		st.step = "bonus"
		for seat in [0, 1]:
			var n := mini(s.players[GCore.other(seat)].mulligans, s.players[seat].deck.size())
			if n > 0:
				var opts: Array = []
				for i in n + 1:
					opts.append(str(i))
				GCore.request(ctx, seat, "mulliganDraw", opts, 1, 1, "상대가 %d번 멀리건했습니다. 추가로 뽑을 장수를 고르세요." % s.players[GCore.other(seat)].mulligans)
			else:
				st.bonusDone[seat] = true
	if st.step == "bonus" and st.bonusDone[0] and st.bonusDone[1] and blockingRequests(s).size() == 0:
		for seat in [0, 1]:
			var p: Dictionary = s.players[seat]
			if p.active != null:
				p.active.faceDown = false
			for b in p.bench:
				b.faceDown = false
		GCore.emit(ctx, { "type": "flipUp" })
		st.step = "done"
		s.phase = "playing"
		startTurn(ctx, s.firstPlayer)

static func resolveSetupChoice(ctx: Dictionary, seat: int, r: Dictionary, picks: Array) -> void:
	var s: Dictionary = ctx.s
	var st: Dictionary = s.setup
	match r.kind:
		"chooseFirst":
			s.firstPlayer = seat if picks[0] == "first" else GCore.other(seat)
			GCore.emit(ctx, { "type": "firstPlayer", "player": s.firstPlayer })
			deal(ctx)
			st.step = "active"
			for p in [0, 1]:
				askActive(ctx, p)
		"chooseActive":
			GCore.moveCard(ctx, picks[0], { "zone": "active", "player": seat, "faceDown": true })
			st.activeChosen[seat] = true
			if st.activeChosen[0] and st.activeChosen[1]:
				st.step = "bench"
			if not askBench(ctx, seat, "벤치에 낼 기본 포켓몬을 고르세요 (0~5장, 나중에 내도 됩니다)."):
				st.benchChosen[seat] = true
			advanceSetup(ctx)
		"chooseBench":
			for iid in picks:
				GCore.moveCard(ctx, iid, { "zone": "bench", "player": seat, "faceDown": s.phase == "setup" })
			if st.step == "bonus":
				st.bonusDone[seat] = true
			else:
				st.benchChosen[seat] = true
			advanceSetup(ctx)
		"mulliganDraw":
			var n := int(picks[0])
			for i in n:
				GCore.drawOne(ctx, seat)
			if n == 0 or not askBench(ctx, seat, "추가로 뽑은 카드 중 기본 포켓몬을 벤치에 낼 수 있습니다."):
				st.bonusDone[seat] = true
			advanceSetup(ctx)

# ───────────────────────── 턴 흐름 ─────────────────────────

static func startTurn(ctx: Dictionary, seat: int) -> void:
	var s: Dictionary = ctx.s
	s.turnPlayer = seat
	s.turnNumber += 1
	var p: Dictionary = s.players[seat]
	p.turns += 1
	p.flags = { "energy": false, "supporter": false, "retreat": false, "stadium": false, "stadiumUsed": false, "names": [] }
	GCore.emit(ctx, { "type": "turnStart", "player": seat, "turnNumber": s.turnNumber })
	if not GCore.drawOne(ctx, seat):
		endGame(ctx, GCore.other(seat), "플레이어 %d이(가) 턴 시작에 덱에서 카드를 뽑지 못했습니다." % (seat + 1))

static func endGame(ctx: Dictionary, winner, reason: String) -> void:
	var s: Dictionary = ctx.s
	if s.phase == "ended":
		return
	s.phase = "ended"
	s.result = { "winner": winner, "reason": reason }
	s.requests = s.requests.filter(func(r): return r.kind == "ackReveal")
	s.stack = []
	GCore.emit(ctx, { "type": "gameEnd", "result": s.result })

## 턴 종료 → 포켓몬 체크 → 기절 확인 → 상대 턴
static func _frame_endTurn(ctx: Dictionary, f: Dictionary) -> void:
	var s: Dictionary = ctx.s
	if f.step == 0:
		# 차례가 끝날 때: 기술머신 에볼루션 트래쉬
		for slot in GCore.slotsOf(s, f.player):
			var t = GCore.toolOf(ctx, slot)
			if t != null and GCore.nameOf(ctx, t) == "기술머신 에볼루션":
				GCore.moveCard(ctx, t, { "zone": "discard", "player": f.player })
		s.inCheckup = true
		GEffects.seq(ctx, f, 1, [["checkup", {}], ["koCheck", {}]])
		return
	s.inCheckup = false
	# 이 턴으로 만료되는 효과 정리
	for seat in [0, 1]:
		var p: Dictionary = s.players[seat]
		p.effects = p.effects.filter(func(e): return e.until > s.turnNumber)
		for slot in GCore.slotsOf(s, seat):
			slot.effects = slot.effects.filter(func(e): return e.until > s.turnNumber)
	GEffects.done(ctx, f)
	if s.phase == "playing":
		startTurn(ctx, GCore.other(f.player))

## 포켓몬 체크: 양쪽 배틀 포켓몬 — 독 → 화상 → 잠듦 → 마비
static func _frame_checkup(ctx: Dictionary, f: Dictionary) -> void:
	var s: Dictionary = ctx.s
	for seat in [s.turnPlayer, GCore.other(s.turnPlayer)]:
		var a = s.players[seat].active
		if a == null:
			continue
		if GCore.truthy(a.cond.poison):
			GCore.putCounters(ctx, a, a.cond.poison)
		if a.cond.burn:
			GCore.putCounters(ctx, a, 2)
			if GCore.flip(ctx, seat, "화상 회복"):
				a.cond.burn = false
				GCore.emit(ctx, { "type": "condition", "player": seat, "sid": a.sid, "cond": "burned", "on": false })
		if a.cond.rot == "asleep" and GCore.flip(ctx, seat, "잠듦 회복"):
			a.cond.rot = ""
			GCore.emit(ctx, { "type": "condition", "player": seat, "sid": a.sid, "cond": "asleep", "on": false })
		if a.cond.rot == "paralyzed" and a.cond.paraUntil <= s.turnNumber:
			a.cond.rot = ""
			GCore.emit(ctx, { "type": "condition", "player": seat, "sid": a.sid, "cond": "paralyzed", "on": false })
	GEffects.done(ctx, f)

## 기절 확인 → 트래쉬 → 사이드 → 승패 → 새 배틀 포켓몬
static func _frame_koCheck(ctx: Dictionary, f: Dictionary) -> void:
	var s: Dictionary = ctx.s
	if f.step == 0:
		var takes := [0, 0]
		var any := false
		for seat in [0, 1]:
			for slot in GCore.slotsOf(s, seat):
				if slot.faceDown or GCore.remainingHp(ctx, slot) > 0:
					continue
				any = true
				var d := GCore.slotData(ctx, slot)
				var n := GCore.prizeValue(d)
				var was_active := is_same(s.players[seat].active, slot)
				# 이 기술로 상대 배틀 포켓몬을 기절시켰을 때의 추가 사이드 (무쇠손 ex, 브라이어)
				if s.attackCtx != null and s.attackCtx.seat != seat and was_active:
					n += s.attackCtx.extraPrizes
				takes[GCore.other(seat)] += n
				if not s.inCheckup and s.turnPlayer != seat:
					s.players[seat].koTurn = s.turnNumber
				GCore.emit(ctx, { "type": "ko", "player": seat, "sid": slot.sid, "code": GCore.inst(ctx, GCore.topOf(slot)).code, "prizes": n })
				# 학습장치: 상대 기술로 내 배틀 포켓몬이 기절하면 기본 에너지 1장을 장치를 단 포켓몬으로 옮김
				if was_active and s.attackCtx != null and s.attackCtx.seat != seat:
					var holder = GCore.find_first(s.players[seat].bench, func(b): return GCore.toolName(ctx, b) == "학습장치")
					var e = GCore.find_first(GCore.energiesOf(ctx, slot), func(x):
						var xd := GCore.dataOf(ctx, x)
						return xd.has("energy") and bool(xd.energy.basic))
					if holder != null and e != null:
						GCore.moveCard(ctx, e, { "zone": "attach", "sid": holder.sid })
						GCore.note(ctx, "학습장치: 기본 에너지를 옮김")
				GCore.clearSlot(ctx, slot, seat, "discard")
		if s.attackCtx != null:
			s.attackCtx.extraPrizes = 0
		if not any:
			GEffects.done(ctx, f)
			return
		GEffects.updateBench(ctx)
		var tp: int = s.turnPlayer if s.turnPlayer != null else 0
		f.data["takes"] = takes
		f.data["order"] = [tp, GCore.other(tp)]
		f.data["i"] = 0
		f.step = 1
	if f.step == 1 or f.step == 2:
		var takes: Array = f.data.takes
		var order: Array = f.data.order
		if f.step == 2:
			var taker: int = order[int(f.data.i)]
			for idx in (f.get("picks") if f.get("picks") != null else []):
				var iid = s.players[taker].prizes[int(idx)]
				if GCore.truthy(iid):
					GCore.moveCard(ctx, iid, { "zone": "hand", "player": taker })
			f.data["i"] = int(f.data.i) + 1
		while int(f.data.i) < 2:
			var taker: int = order[int(f.data.i)]
			var n := mini(takes[taker], GCore.prizesLeft(s, taker))
			if n > 0:
				var opts: Array = []
				var pz: Array = s.players[taker].prizes
				for i in pz.size():
					if GCore.truthy(pz[i]):
						opts.append(str(i))
				f.step = 2
				f.erase("picks")
				GCore.request(ctx, taker, "takePrize", opts, n, n, "사이드를 %d장 가져가세요." % n, { "frame": f.id })
				return
			f.data["i"] = int(f.data.i) + 1
		# 승패 확인 (공식 표: 조건을 더 많이 만족한 쪽 승리, 같으면 무승부)
		var a := _score(s, 0)
		var b := _score(s, 1)
		if a > 0 or b > 0:
			if a == b:
				endGame(ctx, null, "양쪽이 동시에 승리 조건을 만족 — 무승부")
			else:
				var w := 0 if a > b else 1
				endGame(ctx, w, "사이드를 모두 가져갔습니다." if GCore.prizesLeft(s, w) == 0 else "상대 필드에 포켓몬이 없습니다.")
			return
		# 새 배틀 포켓몬: 다음 차례 플레이어 먼저
		var nxt: int = GCore.other(s.turnPlayer) if s.inCheckup else s.turnPlayer
		var children: Array = []
		for p in [nxt, GCore.other(nxt)]:
			if s.players[p].active == null:
				children.append(["promote", p])
		then2(ctx, f, children)

static func _score(s: Dictionary, p: int) -> int:
	var took_all := 1 if GCore.prizesLeft(s, p) == 0 else 0
	var op: Dictionary = s.players[GCore.other(p)]
	var no_mon := 1 if (op.active == null and op.bench.size() == 0) else 0
	return took_all + no_mon

static func then2(ctx: Dictionary, f: Dictionary, children: Array) -> void:
	GEffects.done(ctx, f)
	for i in range(children.size() - 1, -1, -1):
		ctx.s.stack.append({ "id": GCore.newId(ctx.s, "f"), "kind": children[i][0], "step": 0, "player": children[i][1], "data": {} })

## 트레이너스 사용 끝: 사용 중인 카드를 트래쉬
static func _frame_trainerDone(ctx: Dictionary, f: Dictionary) -> void:
	var iid := str(f.data.card)
	if ctx.s.using.has(iid):
		GCore.moveCard(ctx, iid, { "zone": "discard", "player": f.player })
	GEffects.done(ctx, f)

## 기술 선언 → 혼란 확인 → 효과 실행
static func _frame_attack(ctx: Dictionary, f: Dictionary) -> void:
	var s: Dictionary = ctx.s
	var found = GCore.findSlot(s, str(f.data.sid))
	if found == null:
		GEffects.done(ctx, f)
		return
	var a: Dictionary = found.slot
	if a.cond.rot == "confused" and not GCore.flip(ctx, f.player, "혼란: 앞면이면 기술 사용"):
		GCore.putCounters(ctx, a, 3)
		GCore.note(ctx, "혼란으로 기술 실패 — 자신에게 데미지 카운터 3개")
		GEffects.done(ctx, f)
		return
	s.attackCtx = { "seat": f.player, "sid": a.sid, "extraPrizes": 0 }
	var ad := GCore.slotData(ctx, a)
	if GCore.playerHasEffect(s, f.player, "brier") and ad.has("pokemon") and ad.pokemon.tera:
		s.attackCtx.extraPrizes += 1
	GEffects.done(ctx, f)
	s.stack.append({ "id": GCore.newId(s, "f"), "kind": "attackEffect", "step": 0, "player": f.player, "data": { "sid": a.sid, "base": f.data.base, "attackJa": f.data.attackJa } })

# ───────────────────────── 실행 루프 ─────────────────────────

## 막는 요청이 없는 동안 스택 맨 위 프레임을 실행
static func run(ctx: Dictionary) -> void:
	var s: Dictionary = ctx.s
	for guard in 10000:
		if ctx.has("err"):
			return
		if s.phase == "ended":
			s.stack = []
			return
		if blockingRequests(s).size() > 0:
			return
		if s.stack.is_empty():
			return
		var f: Dictionary = s.stack[s.stack.size() - 1]
		var h = GEffects.FRAMES.get(f.kind)
		if h == null:
			GCore.fail(ctx, "no_frame", "처리기 없음: %s" % f.kind)
			return
		var before := "%d|%d|%d" % [s.stack.size(), f.step, s.requests.size()]
		(h as Callable).call(ctx, f)
		if ctx.has("err"):
			return
		var top = s.stack[s.stack.size() - 1] if s.stack.size() > 0 else null
		if "%d|%d|%d" % [s.stack.size(), f.step, s.requests.size()] == before and is_same(top, f) and f.get("picks") == null:
			# 같은 상태로 다시 실행되면 무한 반복 → 오류
			GCore.fail(ctx, "frame_stuck", "프레임 진행 없음: %s step %d" % [f.kind, f.step])
			return
		if f.get("picks") != null and is_same(top, f) and not s.requests.any(func(r): return r.get("frame") == f.id):
			f.erase("picks")
	GCore.fail(ctx, "loop", "효과 처리가 끝나지 않습니다.")

# ───────────────────────── 합법 행동 ─────────────────────────

static func _mv(input: Dictionary, kind: String, label: String, card = null, target = null) -> Dictionary:
	var m := { "input": input, "kind": kind, "label": label }
	if card != null:
		m["card"] = card
	if target != null:
		m["target"] = target
	return m

## 선택 요청 말고 지금 할 수 있는 행동 목록 (폰 버튼·봇·입력 검증이 모두 이것을 씀)
static func legalMoves(s: Dictionary, seat: int, info: Dictionary) -> Array:
	ensure()
	var out: Array = []
	if s.phase != "ended":
		out.append(_mv({ "type": "concede", "player": seat }, "concede", "항복"))
	if s.phase != "playing" or s.turnPlayer != seat or blockingRequests(s).size() > 0 or s.stack.size() > 0:
		return out
	var ctx := { "s": s, "ev": [], "info": info }
	var p: Dictionary = s.players[seat]
	var my_turns: int = p.turns
	var first_turn_of_game: bool = seat == s.firstPlayer and my_turns == 1
	var slots := GCore.slotsOf(s, seat)
	var bench_room: int = p.benchMax - p.bench.size()
	var opp_field := GCore.slotsOf(s, GCore.other(seat))
	var ace_locked := opp_field.any(func(sl): return GCore.hasAbility(ctx, sl, "エースキャンセラー") and GCore.toolOf(ctx, sl) != null)
	var item_lock := GCore.playerHasEffect(s, seat, "itemLock")

	for iid in p.hand:
		var d := GCore.dataOf(ctx, iid)
		var nm: String = d.name
		if d.kind == "pokemon":
			var pk: Dictionary = d.pokemon
			if pk.stage == 0:
				if bench_room > 0:
					out.append(_mv({ "type": "play", "player": seat, "card": iid }, "play", "%s 벤치에 내기" % nm, iid))
				continue
			for sl in slots:
				if canEvolve(ctx, seat, sl, iid):
					out.append(_mv({ "type": "play", "player": seat, "card": iid, "target": sl.sid }, "evolve", "%s → %s 진화" % [GCore.slotName(ctx, sl), nm], iid, sl.sid))
		elif d.kind == "energy":
			if p.flags.energy or (d.get("ace", false) and ace_locked):
				continue
			for sl in slots:
				out.append(_mv({ "type": "play", "player": seat, "card": iid, "target": sl.sid }, "attach", "%s → %s" % [nm, GCore.slotName(ctx, sl)], iid, sl.sid))
		else:
			var sub = d.get("trainer")
			if d.get("ace", false) and ace_locked:
				continue
			if sub == "tool":
				# 포켓몬의 도구는 아이템이 아니므로 아이템 잠금의 영향을 받지 않는다
				for sl in slots:
					if GCore.toolOf(ctx, sl) == null:
						out.append(_mv({ "type": "play", "player": seat, "card": iid, "target": sl.sid }, "tool", "%s → %s" % [nm, GCore.slotName(ctx, sl)], iid, sl.sid))
				continue
			if sub == "item" and item_lock:
				continue
			if sub == "supporter" and (p.flags.supporter or first_turn_of_game):
				continue
			if sub == "stadium":
				if p.flags.stadium or GCore.stadiumName(ctx) == nm:
					continue
				out.append(_mv({ "type": "play", "player": seat, "card": iid }, "trainer", "%s 내기" % nm, iid))
				continue
			if nm == "이상한사탕":
				if my_turns <= 1:
					continue
				for sl in slots:
					if sl.enteredTurn < s.turnNumber and GEffects.candyCards(ctx, seat, sl).size() > 0:
						out.append(_mv({ "type": "play", "player": seat, "card": iid, "target": sl.sid }, "trainer", "이상한사탕 → %s" % GCore.slotName(ctx, sl), iid, sl.sid))
				continue
			var def = GEffects.TRAINERS.get(nm)
			if def == null:
				continue
			if def.has("can") and GCore.truthy(def.can.call(ctx, seat, iid)):
				continue
			out.append(_mv({ "type": "play", "player": seat, "card": iid }, "trainer", "%s 사용" % nm, iid))
	# 스타디움 효과 (보물마을)
	if GCore.stadiumName(ctx) == "보물마을" and not p.flags.stadiumUsed and bench_room > 0 and p.deck.size() > 0:
		out.append(_mv({ "type": "stadium", "player": seat }, "stadium", "보물마을: 덱에서 기본 포켓몬을 벤치로"))
	# 특성
	for sl in slots:
		if not GCore.abilityActive(ctx, sl):
			continue
		var ab: Dictionary = GCore.slotData(ctx, sl).pokemon.abilities[0]
		var def = GEffects.ABILITIES.get(ab.nameJa)
		if def == null:
			continue
		if def.get("once") == "pokemon" and sl.abilityTurn == s.turnNumber:
			continue
		if def.get("once") == "name" and p.flags.names.has(ab.nameJa):
			continue
		if def.has("can") and GCore.truthy(def.can.call(ctx, seat, sl)):
			continue
		out.append(_mv({ "type": "ability", "player": seat, "sid": sl.sid }, "ability", "특성: %s %s" % [GCore.slotName(ctx, sl), ab.name if ab.name != "" else ab.nameJa], null, sl.sid))
	# 후퇴
	var act = p.active
	if act != null and not p.flags.retreat and p.bench.size() > 0 and act.cond.rot != "asleep" and act.cond.rot != "paralyzed" and not GCore.slotHasEffect(act, "noRetreat"):
		var cost := GCore.retreatCost(ctx, act, seat)
		if GCore.provided(ctx, act).size() >= cost:
			for b in p.bench:
				out.append(_mv({ "type": "retreat", "player": seat, "to": b.sid }, "retreat", "후퇴 → %s (비용 %d)" % [GCore.slotName(ctx, b), cost], null, b.sid))
	# 기술
	if act != null and not first_turn_of_game and act.cond.rot != "asleep" and act.cond.rot != "paralyzed" and not GCore.slotHasEffect(act, "noAttack"):
		var atks := attacksOf(ctx, act)
		for i in atks.size():
			var a: Dictionary = atks[i]
			var cost := GCore.attackCost(ctx, act, seat, a.cost, a.nameJa)
			if not GCore.canPay(GCore.provided(ctx, act), cost):
				continue
			var def = GEffects.ATTACKS.get(a.nameJa)
			if def != null and def.has("can") and GCore.truthy(def.can.call(ctx, seat, act)):
				continue
			var dmg_txt := (" %d%s" % [a.damage, a.op]) if GCore.truthy(a.damage) else ""
			out.append(_mv({ "type": "attack", "player": seat, "index": i }, "attack", "기술: %s%s" % [a.name if a.name != "" else a.nameJa, dmg_txt]))
	out.append(_mv({ "type": "endTurn", "player": seat }, "endTurn", "턴 종료"))
	return out

## 이 포켓몬이 쓸 수 있는 기술 (기술머신 에볼루션 포함)
static func attacksOf(ctx: Dictionary, slot: Dictionary) -> Array:
	var sd := GCore.slotData(ctx, slot)
	var list: Array = (sd.pokemon.attacks as Array).duplicate() if sd.has("pokemon") else []
	if GCore.toolName(ctx, slot) == "기술머신 에볼루션":
		list.append(GEffects.TM_ATTACK)
	return list

static func canEvolve(ctx: Dictionary, seat: int, slot: Dictionary, iid: String) -> bool:
	var s: Dictionary = ctx.s
	if slot.faceDown:
		return false
	var d: Dictionary = GCore.dataOf(ctx, iid).pokemon
	var top := GCore.slotData(ctx, slot)
	var via_dna: bool = top.name == "이브이 ex" and GCore.hasAbility(ctx, slot, "にじいろDNA") and d.from == "이브이" and d.rule == "ex"
	if d.from != top.name and not via_dna:
		return false
	var boost: bool = GCore.hasAbility(ctx, slot, "ブーストしんか") and is_same(s.players[seat].active, slot)
	if not boost:
		if s.players[seat].turns <= 1:
			return false
		if slot.enteredTurn >= s.turnNumber:
			return false
	return true

# ───────────────────────── 입력 처리 ─────────────────────────

## 입력 비교 (키 순서와 무관, 값이 없는 키는 무시)
static func canon(x: Dictionary) -> String:
	var keys: Array = x.keys().filter(func(k): return x[k] != null)
	keys.sort()
	var parts: Array = []
	for k in keys:
		parts.append("%s=%s" % [k, JSON.stringify(GCore.intify(x[k]))])
	return "|".join(parts)

static func sameInput(a: Dictionary, b: Dictionary) -> bool:
	return canon(a) == canon(b)

## 반환: { ok: true, state, events } 또는 { ok: false, error: { code, message } } (오류면 원래 상태는 그대로)
static func applyInput(state: Dictionary, input: Dictionary, info: Dictionary) -> Dictionary:
	ensure()
	var s: Dictionary = state.duplicate(true)
	var ctx := { "s": s, "ev": [], "info": info }
	var player = input.get("player")
	if player != 0 and player != 1:
		return _err("bad_player", "플레이어가 올바르지 않습니다.")
	if s.phase == "ended" and input.type != "choice":
		return _err("ended", "게임이 끝났습니다.")
	if input.type == "choice":
		resolveChoice(ctx, player, str(input.requestId), input.picks)
	else:
		var moves := legalMoves(s, player, info)
		var norm := input.duplicate()
		if norm.has("target") and norm.target == null:
			norm.erase("target")
		if not moves.any(func(m): return GEngine.sameInput(m.input, norm)):
			return _err("illegal", illegalReason(s, player))
		doMove(ctx, player, norm)
	if not ctx.has("err"):
		run(ctx)
	if ctx.has("err"):
		return { "ok": false, "error": ctx.err }
	s.version += 1
	return { "ok": true, "state": s, "events": ctx.ev }

static func _err(code: String, message: String) -> Dictionary:
	return { "ok": false, "error": { "code": code, "message": message } }

static func illegalReason(s: Dictionary, seat: int) -> String:
	if s.phase != "playing":
		return "지금은 할 수 없습니다."
	if s.turnPlayer != seat:
		return "내 차례가 아닙니다."
	if blockingRequests(s).size() > 0 or s.stack.size() > 0:
		return "먼저 선택을 끝내세요."
	return "지금 할 수 없는 행동입니다."

static func _push(s: Dictionary, kind: String, player: int, data: Dictionary) -> void:
	s.stack.append({ "id": GCore.newId(s, "f"), "kind": kind, "step": 0, "player": player, "data": data })

static func doMove(ctx: Dictionary, seat: int, input: Dictionary) -> void:
	var s: Dictionary = ctx.s
	var p: Dictionary = s.players[seat]
	match input.type:
		"concede":
			p.conceded = true
			endGame(ctx, GCore.other(seat), "플레이어 %d이(가) 항복했습니다." % (seat + 1))
		"endTurn":
			_push(s, "endTurn", seat, {})
		"retreat":
			var act: Dictionary = p.active
			var cost := GCore.retreatCost(ctx, act, seat)
			_push(s, "retreat", seat, { "to": input.to, "cost": cost })
		"attack":
			var act: Dictionary = p.active
			var a: Dictionary = attacksOf(ctx, act)[int(input.index)]
			GCore.emit(ctx, { "type": "attack", "player": seat, "code": GCore.inst(ctx, GCore.topOf(act)).code, "name": a.name if a.name != "" else a.nameJa, "index": int(input.index) })
			_push(s, "endTurn", seat, {})
			_push(s, "koCheck", seat, {})
			_push(s, "attack", seat, { "sid": act.sid, "base": a.damage, "attackJa": a.nameJa })
		"ability":
			var slot: Dictionary = GCore.findSlot(s, input.sid).slot
			var ab: Dictionary = GCore.slotData(ctx, slot).pokemon.abilities[0]
			slot.abilityTurn = s.turnNumber
			p.flags.names.append(ab.nameJa)
			GCore.emit(ctx, { "type": "ability", "player": seat, "code": GCore.inst(ctx, GCore.topOf(slot)).code, "name": ab.name if ab.name != "" else ab.nameJa })
			_push(s, "koCheck", seat, {})
			_push(s, "abilityRun", seat, { "sid": slot.sid, "ab": ab.nameJa })
		"stadium":
			p.flags.stadiumUsed = true
			GCore.emit(ctx, { "type": "play", "player": seat, "code": GCore.inst(ctx, s.stadium).code, "what": "스타디움 효과" })
			_push(s, "search", seat, { "from": "deck", "filter": { "kind": "pokemon", "stage": 0, "noRule": true }, "max": 1, "to": "bench", "prompt": "벤치에 낼 룰 없는 기본 포켓몬" })
		"play":
			playCard(ctx, seat, input.card, input.get("target"))

static func _frame_abilityRun(ctx: Dictionary, f: Dictionary) -> void:
	var def = GEffects.ABILITIES.get(str(f.data.ab))
	if def == null:
		GEffects.done(ctx, f)
		return
	def.run.call(ctx, f)

static func _frame_retreat(ctx: Dictionary, f: Dictionary) -> void:
	var s: Dictionary = ctx.s
	var p: Dictionary = s.players[f.player]
	var act: Dictionary = p.active
	var cost := int(f.data.cost)
	var ens := GCore.energiesOf(ctx, act)
	if f.step == 0 and cost > 0:
		var units := GCore.provided(ctx, act).size()
		if ens.size() <= cost and units >= cost and units == ens.size():
			for e in ens:
				GCore.moveCard(ctx, e, { "zone": "discard", "player": f.player })
			f.step = 2
		else:
			f.step = 1
			f.erase("picks")
			GCore.request(ctx, f.player, "pickCards", ens, 1, ens.size(), "후퇴 비용: 트래쉬할 에너지 (%d개 분량)" % cost, { "frame": f.id, "cards": _cards(ctx, ens) })
			return
	if f.step == 1:
		var picks: Array = f.get("picks") if f.get("picks") != null else []
		var tmp := act.duplicate()
		tmp["attached"] = picks
		var got := GCore.provided(ctx, tmp).size()
		if got < cost:
			f.erase("picks")
			GCore.request(ctx, f.player, "pickCards", ens, 1, ens.size(), "에너지가 부족합니다. %d개 분량을 고르세요." % cost, { "frame": f.id, "cards": _cards(ctx, ens) })
			return
		for e in picks:
			GCore.moveCard(ctx, e, { "zone": "discard", "player": f.player })
	p.flags.retreat = true
	GCore.switchActive(ctx, f.player, str(f.data.to))
	GEffects.done(ctx, f)

static func _cards(ctx: Dictionary, iids: Array) -> Array:
	var out: Array = []
	for iid in iids:
		out.append({ "iid": iid, "code": GCore.inst(ctx, iid).code })
	return out

static func playCard(ctx: Dictionary, seat: int, iid: String, target) -> void:
	var s: Dictionary = ctx.s
	var p: Dictionary = s.players[seat]
	var d := GCore.dataOf(ctx, iid)
	var code: String = GCore.inst(ctx, iid).code
	if d.kind == "pokemon":
		if d.pokemon.stage == 0:
			var nid := GCore.moveCard(ctx, iid, { "zone": "bench", "player": seat })
			GCore.emit(ctx, { "type": "play", "player": seat, "code": code, "what": "벤치에 냄" })
			var slot = GCore.find_first(p.bench, func(b): return b.stack.has(nid))
			GEffects.updateBench(ctx)
			GEffects.onBenched(ctx, seat, slot.sid)
			return
		GEffects.evolveFrom(ctx, seat, iid, target)
		GEffects.updateBench(ctx)
		return
	if d.kind == "energy":
		p.flags.energy = true
		GCore.moveCard(ctx, iid, { "zone": "attach", "sid": target })
		GCore.emit(ctx, { "type": "play", "player": seat, "code": code, "what": "에너지 붙이기" })
		if d.name == "제트 에너지":
			var t = GCore.findSlot(s, target)
			if t != null and not t.active:
				GCore.switchActive(ctx, seat, t.slot.sid)
				GCore.note(ctx, "제트 에너지: 배틀 포켓몬과 교체")
		return
	# 트레이너스
	var sub = d.get("trainer")
	if sub == "tool":
		GCore.moveCard(ctx, iid, { "zone": "attach", "sid": target })
		GCore.emit(ctx, { "type": "play", "player": seat, "code": code, "what": "도구 붙이기" })
		return
	if sub == "stadium":
		p.flags.stadium = true
		if s.stadium != null:
			GCore.moveCard(ctx, s.stadium, { "zone": "discard", "player": s.cards[s.stadium].owner })
		GCore.moveCard(ctx, iid, { "zone": "stadium" })
		GCore.emit(ctx, { "type": "play", "player": seat, "code": code, "what": "스타디움" })
		GEffects.updateBench(ctx)
		return
	if sub == "supporter":
		p.flags.supporter = true
	var nid := GCore.moveCard(ctx, iid, { "zone": "reveal" })
	GCore.emit(ctx, { "type": "play", "player": seat, "code": code, "what": "서포트" if sub == "supporter" else "아이템" })
	_push(s, "koCheck", seat, {})
	_push(s, "trainerDone", seat, { "card": nid })
	var data := { "card": nid, "name": d.name }
	if target != null:
		data["target"] = target
	_push(s, "trainerRun", seat, data)

static func _frame_trainerRun(ctx: Dictionary, f: Dictionary) -> void:
	var def = GEffects.TRAINERS.get(str(f.data.name))
	if def == null:
		GCore.note(ctx, "이 카드의 효과는 아직 자동화되지 않았습니다.")
		GEffects.done(ctx, f)
		return
	def.run.call(ctx, f)

static func resolveChoice(ctx: Dictionary, seat: int, request_id: String, picks) -> void:
	var s: Dictionary = ctx.s
	var r = GCore.find_first(s.requests, func(x): return x.id == request_id)
	if r == null:
		GCore.fail(ctx, "no_request", "이미 처리되었거나 없는 선택입니다.")
		return
	if r.player != seat:
		GCore.fail(ctx, "not_yours", "내 선택이 아닙니다.")
		return
	if not (picks is Array):
		GCore.fail(ctx, "bad_picks", "선택이 올바르지 않습니다.")
		return
	var pk: Array = []
	for x in picks:
		pk.append(str(x))
	var uniq := {}
	for x in pk:
		uniq[x] = true
	if uniq.size() != pk.size():
		GCore.fail(ctx, "bad_picks", "선택이 올바르지 않습니다.")
		return
	if pk.size() < r.min or pk.size() > r.max:
		GCore.fail(ctx, "bad_count", "%d~%d개를 골라야 합니다." % [r.min, r.max])
		return
	if pk.any(func(x): return not r.options.has(x)):
		GCore.fail(ctx, "bad_option", "고를 수 없는 것을 골랐습니다.")
		return
	s.requests = s.requests.filter(func(x): return x.id != r.id)
	if r.kind == "ackReveal":
		if not s.requests.any(func(x): return x.get("revealId") == r.get("revealId")):
			s.reveals = s.reveals.filter(func(v): return v.id != r.get("revealId"))
		return
	if r.get("frame") != null:
		var f = GCore.find_first(s.stack, func(x): return x.id == r.frame)
		if f == null:
			GCore.fail(ctx, "no_frame", "처리 중인 효과가 없습니다.")
			return
		f["picks"] = pk
		return
	resolveSetupChoice(ctx, seat, r, pk)

# ───────────────────────── 검사 도우미 ─────────────────────────

## 플레이어가 가진 카드 수 (모든 구역 합) — 불변식 검사용
static func countCards(s: Dictionary, seat: int) -> int:
	var p: Dictionary = s.players[seat]
	var n: int = p.deck.size() + p.hand.size() + GCore.prizesLeft(s, seat) + p.discard.size()
	if p.active != null:
		n += p.active.stack.size() + p.active.attached.size()
	for b in p.bench:
		n += b.stack.size() + b.attached.size()
	if s.stadium != null and s.cards[s.stadium].owner == seat:
		n += 1
	for i in s.using:
		if s.cards[i].owner == seat:
			n += 1
	return n
