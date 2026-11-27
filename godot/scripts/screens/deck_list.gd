class_name DeckListScreen
extends Control
## 덱 목록: 아래 탭 [덱] 화면, 또는 대전 준비에서 덱을 고르는 화면(picker)
##  - 칸 탭: 탭 화면이면 덱 카드 목록, 고르기 화면이면 그 덱을 고르고 돌아감
##  - 길게 누르기: 덱 카드 목록 (앱 전체에서 길게 누르기 = 자세히 보기)

signal picked(id: String)   # 고르기 화면: 고른 덱 id ("" = 무작위)

var picker := false
var title_text := ""
var selected := ""
var allow_random := false
var _items: Array[TapArea] = []

func _init(p_picker := false, p_title := "", p_selected := "", p_random := false) -> void:
	picker = p_picker
	title_text = p_title
	selected = p_selected
	allow_random = p_random

func _ready() -> void:
	var n := DeckData.decks.filter(func(d): return not picker or d.get("playable", true) != false).size()
	var col := Lay.page(self, title_text if picker else "덱", ("길게 누르면 덱의 카드를 볼 수 있습니다" if picker else "2026 코리안리그 우승 덱 · %d개" % n))
	if DeckData.load_error != "":
		col.add_child(Lay.wrap("데이터 오류: " + DeckData.load_error, 26, UI.BAD))
		return
	if picker and allow_random:
		col.add_child(_random_item())
	var i := 0
	for d in DeckData.decks:
		if picker and d.get("playable", true) == false:
			continue   # 덱 뷰어 전용 (대전 규칙 준비 중)
		var item := _deck_item(d)
		col.add_child(item)
		_items.append(item)
		# 등장: 위에서부터 차례로 살짝
		item.modulate.a = 0.0
		var tw := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_interval(0.05 + i * 0.06)
		tw.tween_property(item, "modulate:a", 1.0, 0.3)
		i += 1
	if not picker:
		Lay.tabs(self, "덱")

func items() -> Array[TapArea]:
	return _items

func _deck_item(d: Dictionary) -> TapArea:
	var id := str(d["id"])
	var tint := Lay.deck_tint(d)
	var c := Lay.tap_card(tint, 18)
	var tap: TapArea = c[0]
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 20)
	(c[1] as VBoxContainer).add_child(row)
	row.add_child(Lay.cover(d, 128 if picker else 150))
	var info := VBoxContainer.new()
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_theme_constant_override("separation", 8)
	row.add_child(info)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nm := Lay.wrap(str(d["name"]), 34, UI.ACCENT)
	head.add_child(nm)
	if picker and id == selected:
		head.add_child(UI.chip("고른 덱", UI.ACCENT))
	info.add_child(head)
	info.add_child(Lay.wrap(short_note(str(d["note"])), 20, UI.TEXT_DIM))
	var printed := DeckData.choices_for(id).size()
	if printed > 0:
		info.add_child(UI.label("인쇄 %d종 바꿈" % printed, 20, UI.TEXT_DIM))
	info.add_child(Lay.kind_chips(d))
	if picker and id == selected:
		Lay.set_selected(tap, true, tint)
	tap.set_meta("deck", id)
	var deck_dict: Dictionary = d
	tap.long_pressed.connect(func(): Nav.push(DeckDetailScreen.new(deck_dict, false)))
	tap.tapped.connect(func(): _choose(id, deck_dict))
	return tap

## 고르기 화면: 무작위 (AI 상대)
func _random_item() -> TapArea:
	var c := Lay.tap_card(UI.PANEL, 22)
	var tap: TapArea = c[0]
	var col: VBoxContainer = c[1]
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(Lay.wrap("무작위", 34, UI.ACCENT))
	if selected == "":
		head.add_child(UI.chip("고른 덱", UI.ACCENT))
	col.add_child(head)
	col.add_child(Lay.wrap("대전마다 AI 덱을 무작위로 고릅니다.", 20, UI.TEXT_DIM))
	if selected == "":
		Lay.set_selected(tap, true)
	tap.set_meta("deck", "")
	tap.tapped.connect(func(): _choose("", {}))
	_items.append(tap)
	return tap

func _choose(id: String, d: Dictionary) -> void:
	if not picker:
		Nav.push(DeckDetailScreen.new(d))
		return
	picked.emit(id)
	Nav.back()

## "2026 코리안리그 시즌1 시니어 우승 (덱 코드 ...)" → 괄호 앞까지
static func short_note(note: String) -> String:
	var i := note.find(" (")
	return note.substr(0, i) if i > 0 else note
