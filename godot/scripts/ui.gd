class_name UI
## 공통 색상/스타일/위젯 헬퍼 + 화면 테마 (밝게 / 어둡게 / 기기 설정 따라)
## 색은 모두 여기 토큰으로만 쓴다. 테마를 바꾸면 apply_theme() 가 토큰을 바꾸고, 화면은 Nav.restart 로 다시 만든다.
## 카드 그림 위에 얹는 표시(HP 숫자·배지·매수 등)는 테마와 무관하게 어두운 바탕 + GOLD/흰 글자 (그림 위에서 읽히게).

const THEME_PATH := "user://ui.json"
const THEMES := [["auto", "기기 설정"], ["light", "밝게"], ["dark", "어둡게"]]

# ── 테마와 무관한 색 ──
const GOLD := Color(0.96, 0.77, 0.26)            # 카드 위 표시·동전 앞면
const ON_CARD := Color(0, 0, 0, 0.78)            # 카드 위 표시 바탕
const KIND_COLOR := {
	"pokemon": Color(0.93, 0.42, 0.36),
	"trainer": Color(0.36, 0.62, 0.95),
	"energy": Color(0.98, 0.80, 0.30),
}
const CARD_RATIO := 1212.0 / 868.0  # 세로/가로

# ── 테마 토큰 (apply_theme 가 채움) ──
static var theme_mode := "light"   # 저장된 설정: auto / light / dark
static var dark := false           # 지금 실제로 어두운 테마인가
static var BG := Color("#f8f6f0")         # 화면 바탕
static var BG_DEEP := Color("#edf2ee")    # 상단 바·옅은 칸
static var PANEL := Color("#ffffff")      # 카드형 패널·떠 있는 창
static var PANEL_HI := Color("#e7f2ed")   # 보조 버튼·강조 패널
static var LINE := Color("#dce6e0")       # 패널 테두리
static var ACCENT := Color("#14695d")     # 주 강조 (제목·주 버튼)
static var ON_ACCENT := Color.WHITE       # 주 버튼 글자
static var TEXT := Color("#182b3b")
static var TEXT_DIM := Color("#4b6068")
static var FIELD := Color("#e0eee7")      # 대전 탁자
static var HILITE := Color("#e39a12")     # 대전: 놓을 수 있는 곳·고른 것 (카드 그림 위에서도 보이게 따뜻한 색)
static var GOOD := Color("#2e9d5b")
static var BAD := Color("#c4473f")
static var WARN := Color("#a8620a")
static var LINK := Color("#2a6fb0")
static var SCRIM := Color("#f8f6f0", 0.97)    # 크게 보기 등 화면을 덮는 바탕
static var INVERSE := Color("#182b3b", 0.95)  # 알림(토스트) 바탕
static var ON_INVERSE := Color("#f8f6f0")
static var SHADOW := Color(0.09, 0.17, 0.23, 0.16)

const _LIGHT := {
	"BG": "#f8f6f0", "BG_DEEP": "#edf2ee", "PANEL": "#ffffff", "PANEL_HI": "#e7f2ed", "LINE": "#dce6e0",
	"ACCENT": "#14695d", "ON_ACCENT": "#ffffff", "TEXT": "#182b3b", "TEXT_DIM": "#4b6068", "FIELD": "#e0eee7",
	"HILITE": "#e39a12", "GOOD": "#2e9d5b", "BAD": "#c4473f", "WARN": "#a8620a", "LINK": "#2a6fb0",
}
const _DARK := {
	"BG": "#0f1715", "BG_DEEP": "#16211e", "PANEL": "#1b2824", "PANEL_HI": "#23352f", "LINE": "#2e413b",
	"ACCENT": "#4cc3a8", "ON_ACCENT": "#0c1a16", "TEXT": "#e8efec", "TEXT_DIM": "#9fb3ac", "FIELD": "#14221e",
	"HILITE": "#f5c542", "GOOD": "#5ccf86", "BAD": "#f07a70", "WARN": "#f2b766", "LINK": "#7fb6ff",
}

## 저장된 테마 설정을 읽어 적용 (앱 시작 때). override: 실행 인자 --theme 로 강제 (저장 안 함)
static func load_theme(override := "") -> void:
	var mode := "light"
	if FileAccess.file_exists(THEME_PATH):
		var f := FileAccess.open(THEME_PATH, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text()) if f else null
		if d is Dictionary and str(d.get("theme", "")) in ["auto", "light", "dark"]:
			mode = str(d.theme)
	theme_mode = mode
	apply_theme(override if override in ["light", "dark"] else mode)

## 테마 설정을 바꾸고 저장 (화면 다시 만들기는 부른 쪽에서 Nav.restart)
static func set_theme(mode: String) -> void:
	theme_mode = mode
	var d := {}
	if FileAccess.file_exists(THEME_PATH):
		var rf := FileAccess.open(THEME_PATH, FileAccess.READ)
		var old = JSON.parse_string(rf.get_as_text()) if rf else null
		if old is Dictionary:
			d = old
	d["theme"] = mode
	var f := FileAccess.open(THEME_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d))
	apply_theme(mode)

static func system_dark() -> bool:
	return DisplayServer.is_dark_mode_supported() and DisplayServer.is_dark_mode()

static func apply_theme(mode: String) -> void:
	dark = system_dark() if mode == "auto" else mode == "dark"
	var t: Dictionary = _DARK if dark else _LIGHT
	BG = Color(t.BG)
	BG_DEEP = Color(t.BG_DEEP)
	PANEL = Color(t.PANEL)
	PANEL_HI = Color(t.PANEL_HI)
	LINE = Color(t.LINE)
	ACCENT = Color(t.ACCENT)
	ON_ACCENT = Color(t.ON_ACCENT)
	TEXT = Color(t.TEXT)
	TEXT_DIM = Color(t.TEXT_DIM)
	FIELD = Color(t.FIELD)
	HILITE = Color(t.HILITE)
	GOOD = Color(t.GOOD)
	BAD = Color(t.BAD)
	WARN = Color(t.WARN)
	LINK = Color(t.LINK)
	SCRIM = Color(BG, 0.97)
	INVERSE = Color(TEXT, 0.95)
	ON_INVERSE = BG
	SHADOW = Color(0, 0, 0, 0.45) if dark else Color(0.09, 0.17, 0.23, 0.16)
	RenderingServer.set_default_clear_color(BG)

## wrap=true 는 폭이 정해진 곳(세로 목록 등)에서만 쓸 것. 가로 배치 안에서 켜면 글자가 세로로 꺾인다.
static func label(text: String, size: int, color := TEXT, align := HORIZONTAL_ALIGNMENT_LEFT, wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap else TextServer.AUTOWRAP_OFF
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

static func box(color: Color, radius := 18, border := 0, border_color := Color.TRANSPARENT) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	if border > 0:
		sb.set_border_width_all(border)
		sb.border_color = border_color
	sb.anti_aliasing = true
	return sb

## 떠 있는 창(말풍선·메뉴·결과·대화상자): 패널색 + 옅은 테두리 + 그림자. border_color 를 주면 그 색 테두리
static func float_box(radius := 22, border_color = null, border := 2) -> StyleBoxFlat:
	var sb := box(PANEL, radius, border, LINE if border_color == null else border_color)
	sb.shadow_color = SHADOW
	sb.shadow_size = 14
	sb.shadow_offset = Vector2(0, 4)
	return sb

## 아래에서 올라오는 판(선택 창): 위쪽만 둥글게
static func sheet_box() -> StyleBoxFlat:
	var sb := float_box(26)
	sb.corner_radius_bottom_left = 0
	sb.corner_radius_bottom_right = 0
	sb.border_width_bottom = 0
	return sb

## 화면 알림(토스트·연출 설명): 반전색 알약
static func inverse_box(radius := 14) -> StyleBoxFlat:
	var sb := box(INVERSE, radius)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb

## 카드형 패널 (옅은 테두리)
static func panel(color: Color, radius := 18) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(color, radius, 2, LINE))
	return p

static func margin(all: int) -> MarginContainer:
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, all)
	return m

## 작은 꼬리표: 패널색에 color 를 살짝 섞은 바탕 + 본문 글자
static func chip(text: String, color: Color, size := 20) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := box(PANEL.lerp(color, 0.28 if dark else 0.19), 14)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	p.add_theme_stylebox_override("panel", sb)
	p.add_child(label(text, size, TEXT))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p

## 화면 위쪽 안전 영역(상태바/카메라 구멍) 높이를 뷰포트 좌표로 반환
static func safe_top(node: Node) -> float:
	var safe := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	if win.y <= 0:
		return 0.0
	var scale := node.get_viewport().get_visible_rect().size.y / float(win.y)
	return max(0.0, float(safe.position.y) * scale)

static func safe_bottom(node: Node) -> float:
	var safe := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	if win.y <= 0:
		return 0.0
	var scale := node.get_viewport().get_visible_rect().size.y / float(win.y)
	return max(0.0, float(win.y - safe.end.y) * scale)

## 상단 바: 뒤로 가기 + 제목 (+ 부제). 뒤로 가기는 Nav.back
static func top_bar(node: Control, title: String, sub := "") -> PanelContainer:
	var bar := PanelContainer.new()
	var sb := box(BG_DEEP, 0)
	sb.content_margin_top = safe_top(node) + 10
	sb.content_margin_bottom = 14
	sb.content_margin_left = 10
	sb.content_margin_right = 22
	bar.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	bar.add_child(row)
	var back := TapArea.new()
	back.custom_minimum_size = Vector2(84, 84)
	var arrow := label("‹", 64, TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	arrow.set_anchors_preset(Control.PRESET_FULL_RECT)
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	arrow.position.y = -6
	back.add_child(arrow)
	back.tapped.connect(Nav.back)
	back.set_meta("back", true)
	row.add_child(back)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.alignment = BoxContainer.ALIGNMENT_CENTER
	titles.add_theme_constant_override("separation", 0)
	var tl := label(title, 36, ACCENT, HORIZONTAL_ALIGNMENT_LEFT, true)
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_child(tl)
	if sub != "":
		var sl := label(sub, 22, TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true)
		sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		titles.add_child(sl)
	row.add_child(titles)
	bar.set_meta("titles", titles)
	return bar

## 버튼 (탭 영역 + 둥근 패널 + 글자). primary = 강조색 테두리, fill = 강조색으로 채움 (화면의 주 행동)
static func button(text: String, size := 28, primary := false, fill := false) -> TapArea:
	var tap := TapArea.new()
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", button_box(primary, fill))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := label(text, size, ON_ACCENT if fill else TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	p.add_child(l)
	tap.add_child(p)
	tap.press_target = p
	tap.set_meta("label", l)
	tap.set_meta("panel", p)
	return tap

static func button_box(primary := false, fill := false) -> StyleBoxFlat:
	var sb := box(ACCENT if fill else PANEL_HI, 16, 3 if primary and not fill else 0, ACCENT)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	return sb

## 버튼 모양 바꾸기 (켜짐/꺼짐 전환 등)
static func restyle(b: TapArea, primary: bool, fill: bool) -> void:
	(b.get_meta("panel") as PanelContainer).add_theme_stylebox_override("panel", button_box(primary, fill))
	(b.get_meta("label") as Label).add_theme_color_override("font_color", ON_ACCENT if fill else TEXT)

## 버튼을 부모 폭에 맞춰 늘리고 글자는 줄바꿈 (목록 항목·화면 아래 큰 버튼). 긴 글자가 화면 밖으로 나가지 않게
static func wide(b: TapArea, align := HORIZONTAL_ALIGNMENT_CENTER) -> TapArea:
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	(b.get_meta("panel") as Control).set_anchors_preset(Control.PRESET_FULL_RECT)
	var l: Label = b.get_meta("label")
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = align
	return b

## 버튼 비활성 표시 (탭은 화면 쪽에서 무시)
static func set_enabled(b: TapArea, on: bool) -> void:
	b.modulate.a = 1.0 if on else 0.4
	b.set_meta("enabled", on)

static func is_enabled(b: TapArea) -> bool:
	return bool(b.get_meta("enabled", true))

## 입력칸
static func line_edit(placeholder: String, size := 30) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.add_theme_font_size_override("font_size", size)
	e.add_theme_color_override("font_color", TEXT)
	e.add_theme_color_override("font_placeholder_color", Color(TEXT_DIM, 0.75))
	e.add_theme_color_override("caret_color", ACCENT)
	e.add_theme_stylebox_override("normal", box(PANEL, 12, 2, LINE))
	e.add_theme_stylebox_override("focus", box(PANEL, 12, 2, ACCENT))
	for s in ["normal", "focus"]:
		var st: StyleBoxFlat = e.get_theme_stylebox(s)
		st.content_margin_left = 16
		st.content_margin_right = 16
		st.content_margin_top = 12
		st.content_margin_bottom = 12
	return e

## 화면 아래 고정 판 (주 행동 버튼·탭 바). 화면에 Lay.page 가 있어야 한다 (meta "layout")
static func footer(screen: Control) -> VBoxContainer:
	var layout: VBoxContainer = screen.get_meta("layout")
	var surface := PanelContainer.new()
	var sb := box(PANEL, 24, 2, LINE)
	sb.corner_radius_bottom_left = 0
	sb.corner_radius_bottom_right = 0
	sb.border_width_bottom = 0
	sb.shadow_color = SHADOW
	sb.shadow_size = 10
	surface.add_theme_stylebox_override("panel", sb)
	layout.add_child(surface)
	var center := CenterContainer.new()
	surface.add_child(center)
	var margin_box := margin(14)
	margin_box.add_theme_constant_override("margin_bottom", 14 + int(safe_bottom(screen)))
	center.add_child(margin_box)
	var fit := func():
		if is_instance_valid(margin_box):
			margin_box.custom_minimum_size.x = minf(screen.get_viewport_rect().size.x - 8.0, 1024.0)
	screen.resized.connect(fit)
	fit.call()
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	margin_box.add_child(col)
	screen.set_meta("footer", surface)
	return col
