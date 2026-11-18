extends Node
## Autoload: res://data/decks.json 을 읽어 덱/카드 정보를 제공한다.
## (데이터는 웹 프로젝트에서 `npm run export-godot` 으로 생성)

const DATA_PATH := "res://data/decks.json"
const KIND_LABEL := { "pokemon": "포켓몬", "trainer": "트레이너스", "energy": "에너지" }

var decks: Array = []      # Array[Dictionary]
var data_version := ""     # 서버와 비교하는 카드 데이터 버전 (export-godot 이 기록)
var load_error := ""

func _ready() -> void:
	_load()

func _load() -> void:
	var f := FileAccess.open(DATA_PATH, FileAccess.READ)
	if f == null:
		load_error = "decks.json 을 열 수 없습니다 (%s)" % error_string(FileAccess.get_open_error())
		push_error(load_error)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("decks"):
		load_error = "decks.json 형식 오류"
		push_error(load_error)
		return
	decks = parsed["decks"]
	data_version = str(parsed.get("dataVersion", ""))
	for d in decks:
		var total := 0
		for c in d["cards"]:
			total += int(c["count"])
		print("[DeckData] %s: %d종 %d장" % [d["name"], d["cards"].size(), total])
	_apply_choices()

# ───────────── 인쇄(레귤레이션) 선택 ─────────────
## 카드마다 "id"(덱 원래 코드)는 그대로 두고, code/full/thumb 만 고른 인쇄로 바꾼다.
## 선택은 user://print_choice.json 에 {덱id: {카드id: 인쇄코드}} 로 저장.

const CHOICE_PATH := "user://print_choice.json"
var _choices := {}

func _apply_choices() -> void:
	if FileAccess.file_exists(CHOICE_PATH):
		var f := FileAccess.open(CHOICE_PATH, FileAccess.READ)
		var parsed = JSON.parse_string(f.get_as_text()) if f else null
		if typeof(parsed) == TYPE_DICTIONARY:
			_choices = parsed
	for d in decks:
		var sel: Dictionary = _choices.get(d["id"], {})
		for c in d["cards"]:
			if not c.has("id"):
				c["id"] = c["code"]
			if sel.has(c["id"]):
				_switch(c, sel[c["id"]])

## 대전에 보낼 인쇄 선택 {카드id: 인쇄코드}
func choices_for(deck_id: String) -> Dictionary:
	var sel: Dictionary = _choices.get(deck_id, {})
	return sel.duplicate()

func has_prints(card: Dictionary) -> bool:
	var p = card.get("prints")
	return p is Array and p.size() > 1

## 현재 보이는 인쇄 정보 {code, reg, special, full, thumb} (없으면 빈 사전)
func current_print(card: Dictionary) -> Dictionary:
	if not has_prints(card):
		return {}
	for p in card["prints"]:
		if p["code"] == card["code"]:
			return p
	return {}

func _switch(card: Dictionary, code: String) -> bool:
	if not has_prints(card):
		return false
	for p in card["prints"]:
		if p["code"] == code:
			card["code"] = p["code"]
			card["full"] = p["full"]
			card["thumb"] = p["thumb"]
			return true
	return false

## 덱의 카드를 다른 인쇄로 바꾸고 저장한다. 바뀌었으면 true.
func set_print(deck: Dictionary, card: Dictionary, code: String) -> bool:
	if card["code"] == code or not _switch(card, code):
		return false
	var sel: Dictionary = _choices.get(deck["id"], {})
	if code == card["id"]:
		sel.erase(card["id"])
	else:
		sel[card["id"]] = code
	_choices[deck["id"]] = sel
	var f := FileAccess.open(CHOICE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_choices))
	return true

func get_deck(id: String) -> Dictionary:
	for d in decks:
		if d["id"] == id:
			return d
	return {}

## 카드 목록을 종류별로 묶어 [{kind, label, count, cards}] 로 반환
func sections(deck: Dictionary) -> Array:
	var out := []
	for kind in ["pokemon", "trainer", "energy"]:
		var all_cards: Array = deck["cards"]
		var cards: Array = all_cards.filter(func(c): return c["kind"] == kind)
		if cards.is_empty():
			continue
		var n := 0
		for c in cards:
			n += int(c["count"])
		out.append({ "kind": kind, "label": KIND_LABEL[kind], "count": n, "cards": cards })
	return out

func card_by_code(deck: Dictionary, code: String) -> Dictionary:
	for c in deck["cards"]:
		if c["code"] == code or c.get("id", "") == code:
			return c
	return {}
