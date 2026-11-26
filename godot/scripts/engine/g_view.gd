class_name GView
## src/game/view.ts 포팅 — 시점별 보기: 보는 사람(플레이어 0·1, "board")이 알 수 없는 정보를 지운다.
## 결과는 상태와 공유하지 않는 깊은 복사본이다 (화면·봇이 바꿔도 상태에 영향 없음).

static func _cv(s: Dictionary, iid: String) -> Dictionary:
	return { "iid": iid, "code": s.cards[iid].code }

static func slotView(s: Dictionary, slot: Dictionary, owner: int, viewer, info: Dictionary) -> Dictionary:
	var hide: bool = slot.faceDown and not (typeof(viewer) == TYPE_INT and viewer == owner)
	var ctx := { "s": s, "ev": [], "info": info }
	var known: bool = info.db.has(s.cards[slot.stack[slot.stack.size() - 1]].ruleId)
	var stack = null
	var attached = null
	if not hide:
		stack = slot.stack.map(func(i): return GView._cv(s, i))
		attached = slot.attached.map(func(i): return GView._cv(s, i))
	return {
		"sid": slot.sid, "faceDown": slot.faceDown, "damage": 0 if hide else slot.damage,
		"stack": stack,
		"attached": attached,
		"hp": null if (hide or not known) else GCore.maxHp(ctx, slot),
		"cond": slot.cond, "effects": slot.effects,
		"retreat": null if (hide or not known) else GCore.retreatCost(ctx, slot, owner),
	}

## viewer: 0 / 1 / "board". copy = false 면 마지막 깊은 복사를 건너뛴다 (상태와 일부 공유 — 읽기만 하는 어려움 AI 시뮬레이션용, Godot 전용)
static func viewFor(s: Dictionary, viewer, info: Dictionary, copy := true) -> Dictionary:
	var players: Array = []
	var is_seat := typeof(viewer) == TYPE_INT
	for seat in [0, 1]:
		var p: Dictionary = s.players[seat]
		players.append({
			"seat": seat, "deckId": p.deckId, "deckCount": p.deck.size(), "handCount": p.hand.size(),
			"hand": p.hand.map(func(i): return GView._cv(s, i)) if (is_seat and viewer == seat) else null,
			"prizes": p.prizes.map(func(x): return x != null),
			"discard": p.discard.map(func(i): return GView._cv(s, i)),
			"lost": p.lost.map(func(i): return GView._cv(s, i)), "gxUsed": p.gxUsed, "vstarUsed": p.vstarUsed,
			"active": slotView(s, p.active, seat, viewer, info) if p.active != null else null,
			"bench": p.bench.map(func(b): return GView.slotView(s, b, seat, viewer, info)),
			"benchMax": p.benchMax, "mulligans": p.mulligans, "conceded": p.conceded, "turns": p.turns, "flags": p.flags, "effects": p.effects,
		})
	var reqs: Array = []
	for r in s.requests:
		if is_seat and r.player == viewer:
			var rv := { "id": r.id, "player": r.player, "kind": r.kind, "prompt": r.prompt, "options": r.options, "min": r.min, "max": r.max }
			for k in ["revealId", "labels", "cards"]:
				if r.get(k) != null:
					rv[k] = r[k]
			reqs.append(rv)
		else:
			reqs.append({ "id": r.id, "player": r.player, "kind": r.kind, "prompt": r.prompt })
	var v := {
		"viewer": viewer, "version": s.version, "phase": s.phase, "setupStep": s.setup.step if s.setup != null else null, "players": players,
		"stadium": _cv(s, s.stadium) if s.stadium != null else null,
		"using": s.using.map(func(i): return GView._cv(s, i)),
		"firstPlayer": s.firstPlayer, "turnPlayer": s.turnPlayer, "turnNumber": s.turnNumber,
		"requests": reqs,
		"reveals": s.reveals,
		"result": s.result,
		"actions": GEngine.legalMoves(s, viewer, info) if is_seat else null,
	}
	return v.duplicate(true) if copy else v

## 이 구역의 카드를 viewer 가 볼 수 있는가
static func zoneVisible(ref: Dictionary, viewer, face_down := false) -> bool:
	match ref.zone:
		"deck", "prizes": return false
		"hand": return typeof(viewer) == TYPE_INT and viewer == ref.player
		"active", "bench": return not face_down or (typeof(viewer) == TYPE_INT and viewer == ref.player)
	return true

## 이벤트를 viewer 시점으로 거른다 (보이지 않는 카드 이동은 카드 정보를 지움)
static func eventsFor(events: Array, viewer) -> Array:
	var out: Array = []
	for e in events:
		if e.type != "move" or e.card == null or zoneVisible(e.to, viewer, bool(e.get("faceDown", false))):
			out.append(e.duplicate(true))
			continue
		var c: Dictionary = e.duplicate(true)
		if zoneVisible(e.from, viewer):
			c["card"] = { "iid": "", "code": e.card.code }
		else:
			c["card"] = null
		out.append(c)
	return out
