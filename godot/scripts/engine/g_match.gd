class_name GMatch
extends RefCounted
## src/game/match.ts + catalog.ts + protocol.ts(toGameInput) 포팅 — 한 판의 상태 + 입력 로그, 입력 검증, 시점별 메시지.

var config: Dictionary
var inputs: Array = []
var state: Dictionary
var info: Dictionary
var lastEvents: Array = []

func _init(cfg: Dictionary, inf: Dictionary) -> void:
	config = cfg
	info = inf
	var r := GEngine.createGame(cfg, inf)
	state = r.state
	lastEvents = r.events

## 로그를 처음부터 재생. 실패하면 null
static func replay(log: Dictionary, inf: Dictionary) -> GMatch:
	var m := GMatch.new(log.config, inf)
	for gi in log.inputs:
		var r := m.apply(gi)
		if not r.ok:
			return null
	return m

## 자리 seat 의 클라이언트 입력을 처리 (player 는 여기서 채움)
func submit(seat: int, input: Dictionary) -> Dictionary:
	var gi = toGameInput(input, seat)
	if gi == null:
		return { "ok": false, "error": { "code": "bad_input", "message": "입력 형식 오류" } }
	return apply(gi)

## player 가 채워진 엔진 입력
func apply(gi: Dictionary) -> Dictionary:
	var r := GEngine.applyInput(state, gi, info)
	if not r.ok:
		return r
	state = r.state
	inputs.append(gi)
	lastEvents = r.events
	return { "ok": true, "events": r.events }

func snapshot(viewer) -> Dictionary:
	return { "t": "state", "view": GView.viewFor(state, viewer, info) }

## 입력 처리 결과를 viewer 에게 보낼 메시지 (이벤트 → 상태 순서)
func messagesFor(viewer, events: Array) -> Array:
	var ev := GView.eventsFor(events, viewer)
	return [{ "t": "events", "events": ev }, snapshot(viewer)] if ev.size() > 0 else [snapshot(viewer)]

func log_data() -> Dictionary:
	return { "v": 1, "config": config, "inputs": inputs.duplicate(true) }

## protocol.ts toGameInput (TS 와 같은 키 순서)
static func toGameInput(input: Dictionary, player: int):
	var t = input.get("type")
	match t:
		"choice":
			var picks: Array = []
			if input.get("picks") is Array:
				for p in input.picks:
					picks.append(str(p))
			return { "type": "choice", "player": player, "requestId": str(input.get("requestId", "")), "picks": picks }
		"play":
			if input.get("target") != null and str(input.target) != "":
				return { "type": "play", "player": player, "card": str(input.card), "target": str(input.target) }
			return { "type": "play", "player": player, "card": str(input.card) }
		"retreat": return { "type": "retreat", "player": player, "to": str(input.to) }
		"attack": return { "type": "attack", "player": player, "index": int(input.index) }
		"ability": return { "type": "ability", "player": player, "sid": str(input.sid) }
		"stadium": return { "type": "stadium", "player": player }
		"endTurn": return { "type": "endTurn", "player": player }
		"concede": return { "type": "concede", "player": player }
	return null

# ───────────────────────── 카탈로그 (catalog.ts) ─────────────────────────

## 앱의 덱 데이터(godot/data/decks.json) → 게임용 카탈로그 { decks, basics }
static func buildCatalog(raw: Dictionary) -> Dictionary:
	var decks: Array = []
	var basics := {}
	for d in raw.decks:
		var cards: Array = []
		for c in d.cards:
			var prints: Array = []
			if c.get("prints") is Array:
				for p in c.prints:
					prints.append(p.code)
			else:
				prints.append(c.code)
			var card := { "id": c.get("id", c.code) if c.get("id") != null else c.code, "code": c.code, "name": c.name, "count": int(c.count), "kind": c.kind, "basic": bool(c.get("basic", false)), "prints": prints }
			cards.append(card)
			if card.basic:
				basics[card.id] = true
		var cover = d.get("cover")
		if cover == null:
			cover = d.cards[0].code if d.cards.size() > 0 else ""
		decks.append({ "id": d.id, "name": d.name, "cover": cover, "cards": cards })
	return { "decks": decks, "basics": basics }

## 고른 인쇄를 반영한 게임용 덱. prints: {카드ID: 인쇄코드}
static func buildDeck(cat: Dictionary, deck_id: String, prints := {}) -> Array:
	var d = GCore.find_first(cat.decks, func(x): return x.id == deck_id)
	if d == null:
		return []
	var out: Array = []
	for c in d.cards:
		var want = prints.get(c.id)
		out.append({ "ruleId": c.id, "code": want if (want != null and c.prints.has(want)) else c.code, "name": c.name, "kind": c.kind, "basic": c.basic, "count": c.count })
	return out
