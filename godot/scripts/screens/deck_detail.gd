class_name DeckDetailScreen
extends Control
## 덱 카드 목록 화면: 상단 바 + 덱 설명 + 종류별 섹션 + 썸네일 격자(매수 배지) + 아래 [이 덱으로 AI와 연습]

signal card_tapped(card: Dictionary)

const GAP := 14
const MIN_THUMB_W := 190.0

var deck: Dictionary
var show_play := true          # 아래 [이 덱으로 AI와 연습] (대전 준비에서 길게 눌러 연 경우는 없음)
var _scroll: ScrollContainer
var _content: VBoxContainer
var _thumbs: Array[CardThumb] = []
var _guide_expanded := false

func _init(deck_data: Dictionary, p_show_play := true) -> void:
	deck = deck_data
	show_play = p_show_play and deck_data.get("playable", true) != false

func _ready() -> void:
	_content = Lay.page(self, str(deck["name"]), "%d장 · %d종" % [int(deck["total"]), deck["cards"].size()])
	_scroll = get_meta("scroll")
	# 주 행동: 이 덱으로 바로 AI와 연습 (화면 아래, 엄지가 닿는 곳)
	if show_play:
		var play := UI.button("이 덱으로 AI와 연습", 30, true, true)
		(play.get_meta("panel") as Control).set_anchors_preset(Control.PRESET_FULL_RECT)
		play.set_meta("play", true)
		play.tapped.connect(func(): HomeScreen.start_solo(str(deck["id"])))
		UI.footer(self).add_child(play)
	# 폭이 정해진 뒤 격자를 만든다 (폴드 화면 펼침/접힘에도 다시 배치)
	_scroll.resized.connect(_rebuild)

func _exit_tree() -> void:
	# 목록을 떠나면 썸네일/큰 이미지 캐시를 비워 메모리를 돌려준다
	ImageCache.trim_thumbs()
	ImageCache.trim(0)

func _rebuild() -> void:
	var side := maxi(24, int((_scroll.size.x - Lay.MAX_CONTENT_WIDTH) * 0.5))
	var width := _scroll.size.x - side * 2 - 2
	if width <= 0:
		return
	var cols := maxi(3, int((width + GAP) / (MIN_THUMB_W + GAP)))
	var thumb_w := floorf((width - GAP * (cols - 1)) / cols)
	if _content.get_child_count() > 0 and _content.get_meta("cols", 0) == cols and is_equal_approx(_content.get_meta("thumb_w", 0.0), thumb_w):
		return
	_content.set_meta("cols", cols)
	_content.set_meta("thumb_w", thumb_w)
	for c in _content.get_children():
		c.queue_free()
	_thumbs.clear()

	# 덱 설명 패널 (접힘/펼침 상태는 다시 배치해도 유지)
	var g = deck.get("guide")
	if g is Dictionary and not g.is_empty():
		var panel := DeckGuidePanel.new(g, _guide_expanded)
		panel.card_requested.connect(func(code: String): open_card(code))
		panel.toggled.connect(func(e: bool): _guide_expanded = e)
		_content.add_child(panel)

	var order := 0
	for s in DeckData.sections(deck):
		var header := HBoxContainer.new()
		header.add_theme_constant_override("separation", 10)
		var dot := ColorRect.new()
		dot.color = UI.KIND_COLOR[s["kind"]]
		dot.custom_minimum_size = Vector2(8, 34)
		header.add_child(dot)
		header.add_child(UI.label("%s" % s["label"], 30, UI.ACCENT))
		var cnt := UI.label("%d장" % s["count"], 24, UI.TEXT_DIM)
		cnt.size_flags_vertical = Control.SIZE_SHRINK_END
		header.add_child(cnt)
		_content.add_child(header)

		var grid := GridContainer.new()
		grid.columns = cols
		grid.add_theme_constant_override("h_separation", GAP)
		grid.add_theme_constant_override("v_separation", GAP)
		for c in s["cards"]:
			var t := CardThumb.new(c, thumb_w)
			t.tapped.connect(func(): open_card(c["code"]))
			grid.add_child(t)
			_thumbs.append(t)
			_appear(t, order)
			order += 1
		_content.add_child(grid)

func _appear(node: Control, order: int) -> void:
	# 처음 보이는 몇 줄만 순차 등장, 나머지는 바로 표시
	if order > 16:
		return
	node.modulate.a = 0.0
	var tw := node.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.12 + order * 0.025)
	tw.tween_property(node, "modulate:a", 1.0, 0.25)

## 목록 순서(섹션 순) 그대로의 카드 배열
func flat_cards() -> Array:
	var out := []
	for s in DeckData.sections(deck):
		out.append_array(s["cards"])
	return out

## 카드 크게 보기 열기
func open_card(code: String) -> CardViewer:
	if Nav.current() != self:
		return null
	var list := flat_cards()
	var idx := 0
	for i in list.size():
		if list[i]["code"] == code or list[i].get("id", "") == code:
			idx = i
	card_tapped.emit(list[idx])
	var v := CardViewer.new(deck, list, idx, self)
	Nav.push_overlay(v)
	return v

## 해당 썸네일이 화면에 보이도록 스크롤 (보기에서 닫을 때 사용)
func scroll_to(thumb: Control) -> void:
	var top := thumb.get_global_rect().position.y - _scroll.get_global_rect().position.y
	var bottom := top + thumb.size.y
	if top < 0 or bottom > _scroll.size.y:
		_scroll.scroll_vertical = int(_scroll.scroll_vertical + top - (_scroll.size.y - thumb.size.y) / 2.0)

## 카드의 인쇄가 바뀌었을 때 목록 썸네일 이미지를 다시 불러온다
func refresh_card(card: Dictionary) -> void:
	var t := thumb_for(card["code"])
	if t:
		t.refresh()

func thumb_for(code: String) -> CardThumb:
	for t in _thumbs:
		if t.card["code"] == code:
			return t
	return null
