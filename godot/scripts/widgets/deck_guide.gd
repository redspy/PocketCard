class_name DeckGuidePanel
extends PanelContainer
## 덱 목록 화면 맨 위의 「덱 설명」 패널.
## 접힌 상태: 한 줄 요약 + 「자세히 보기」. 펼친 상태: 콘셉트, 핵심 카드(탭하면 카드 크게 보기), 플랜, 팁, 강점·약점, 상성, 특징, 참고 자료.

signal card_requested(code: String)
signal toggled(expanded: bool)

const RATING_COLOR := {
	"fav": Color(0.36, 0.82, 0.52),
	"slight_fav": Color(0.62, 0.86, 0.45),
	"even": Color(0.85, 0.85, 0.85),
	"slight_unfav": Color(0.98, 0.70, 0.36),
	"unfav": Color(0.96, 0.45, 0.42),
}

var guide: Dictionary
var expanded := false
var _details: VBoxContainer
var _toggle_label: Label

func _init(guide_data: Dictionary, start_expanded := false) -> void:
	guide = guide_data
	expanded = start_expanded
	# PanelContainer 는 기본으로 터치를 가로채므로, 스크롤이 되도록 통과시킨다
	mouse_filter = Control.MOUSE_FILTER_PASS
	var sb := UI.box(UI.PANEL, 22)
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 20
	sb.content_margin_bottom = 18
	add_theme_stylebox_override("panel", sb)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	add_child(col)

	var head := HBoxContainer.new()
	head.add_child(UI.label("덱 설명", 30, UI.ACCENT))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	col.add_child(head)

	col.add_child(_wrap(guide.get("summary", ""), 24, UI.TEXT))

	# 펼침/접힘 버튼
	var tap := TapArea.new()
	tap.custom_minimum_size = Vector2(0, 56)
	_toggle_label = UI.label("", 22, UI.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	_toggle_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_toggle_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tap.add_child(_toggle_label)
	tap.tapped.connect(_toggle)

	_details = VBoxContainer.new()
	_details.add_theme_constant_override("separation", 14)
	_build_details()
	col.add_child(_details)
	col.add_child(tap)
	_apply(false)

func _toggle() -> void:
	expanded = not expanded
	_apply(true)
	toggled.emit(expanded)

func _apply(animate: bool) -> void:
	_details.visible = expanded
	_toggle_label.text = "접기 ▲" if expanded else "자세히 보기 ▼"
	if expanded and animate:
		_details.modulate.a = 0.0
		create_tween().tween_property(_details, "modulate:a", 1.0, 0.25)

# ───────────── 상세 내용 ─────────────

func _build_details() -> void:
	_details.add_child(_wrap(guide.get("concept", ""), 22, UI.TEXT_DIM))
	if guide.has("caution"):
		var warn := UI.panel(Color(0.98, 0.70, 0.36, 0.14), 12)
		warn.mouse_filter = Control.MOUSE_FILTER_PASS
		var wm := UI.margin(12)
		wm.add_child(_wrap("⚠ " + str(guide["caution"]), 21, Color(0.98, 0.78, 0.48)))
		warn.add_child(wm)
		_details.add_child(warn)

	_section("핵심 카드")
	for k in guide.get("keyCards", []):
		_details.add_child(_key_card(k))

	_section("게임 플랜")
	for p in guide.get("plan", []):
		_details.add_child(_labeled(str(p["label"]), str(p["text"])))

	_section("운영 팁")
	var i := 1
	for t in guide.get("tips", []):
		_details.add_child(_bullet("%d." % i, str(t)))
		i += 1

	_section("강점")
	for s in guide.get("strengths", []):
		_details.add_child(_bullet("＋", str(s), Color(0.45, 0.85, 0.55)))
	_section("약점")
	for s in guide.get("weaknesses", []):
		_details.add_child(_bullet("－", str(s), Color(0.96, 0.5, 0.45)))

	_section("상성 (참고용)")
	for m in guide.get("matchups", []):
		_details.add_child(_matchup(m))

	_section("한국 리그 리스트의 특징")
	for s in guide.get("koreanList", []):
		_details.add_child(_bullet("•", str(s)))

	_section("참고 자료")
	for s in guide.get("sources", []):
		_details.add_child(_source(s))

func _section(title: String) -> void:
	var l := UI.label(title, 26, UI.ACCENT)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", 10)
	m.add_child(l)
	_details.add_child(m)

func _wrap(text: String, size: int, color: Color) -> Label:
	var l := UI.label(text, size, color, HORIZONTAL_ALIGNMENT_LEFT, true)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l

func _bullet(mark: String, text: String, mark_color := UI.ACCENT) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var m := UI.label(mark, 22, mark_color)
	m.custom_minimum_size = Vector2(30, 0)
	m.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(m)
	row.add_child(_wrap(text, 22, UI.TEXT))
	return row

func _labeled(label: String, text: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.add_child(UI.label(label, 22, Color(0.62, 0.82, 1.0)))
	box.add_child(_wrap(text, 22, UI.TEXT))
	return box

## 핵심 카드: 썸네일 + 이름·역할 + 설명. 탭하면 카드 크게 보기
func _key_card(k: Dictionary) -> Control:
	var tap := TapArea.new()
	var panel := UI.panel(UI.PANEL_HI, 14)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tap.add_child(panel)
	tap.press_target = panel
	var m := UI.margin(10)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(m)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(row)

	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(72, 72 * UI.CARD_RATIO)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(thumb)
	var path := "res://cards/thumb/%s.webp" % k["code"]
	if ResourceLoader.exists(path):
		ImageCache.request(path, func(t): if is_instance_valid(thumb): thumb.texture = t)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 4)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title := HBoxContainer.new()
	title.add_theme_constant_override("separation", 8)
	title.add_child(UI.label(str(k.get("name", k["code"])), 24, UI.TEXT))
	title.add_child(UI.chip(str(k.get("role", "")), UI.ACCENT))
	info.add_child(title)
	info.add_child(_wrap(str(k.get("text", "")), 20, UI.TEXT_DIM))
	row.add_child(info)
	row.add_child(UI.label("›", 40, UI.TEXT_DIM))

	var code: String = k["code"]
	tap.tapped.connect(func(): card_requested.emit(code))
	return tap

func _matchup(m: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(170, 0)
	left.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	left.add_child(UI.label(str(m.get("vsName", m["vs"])), 22, UI.TEXT))
	left.add_child(UI.chip(str(m.get("ratingLabel", m["rating"])), RATING_COLOR.get(m["rating"], UI.TEXT)))
	row.add_child(left)
	row.add_child(_wrap(str(m.get("text", "")), 21, UI.TEXT_DIM))
	return row

func _source(s: Dictionary) -> Control:
	var tap := TapArea.new()
	tap.custom_minimum_size = Vector2(0, 44)
	var l := UI.label("🔗 " + str(s.get("title", s.get("url", ""))), 21, Color(0.55, 0.78, 1.0), HORIZONTAL_ALIGNMENT_LEFT, true)
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tap.add_child(l)
	var url := str(s.get("url", ""))
	tap.tapped.connect(func(): if url != "": OS.shell_open(url))
	return tap
