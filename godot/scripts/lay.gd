class_name Lay
## 화면 짜임 헬퍼 (battleTest 와 같은 틀):
##  - page: 바탕 + (상단 바) + 세로 스크롤 내용 (넓은 화면에서는 가운데 최대 1024)
##  - footer(UI.footer): 화면 아래 고정 판 — 그 화면의 주 행동(준비 완료·참가 등) 또는 탭 바. 엄지가 닿는 곳
##  - tabs: 첫 화면들(홈 / 덱 / 대전) 아래 탭
##  - card / tap_card: 둥근 패널 칸, segmented: 여러 값 중 하나 고르기

const MAX_CONTENT_WIDTH := 1024.0
const TABS := ["홈", "덱", "대전"]

## 화면에 바탕·상단 바·스크롤을 넣고, 내용을 담을 세로 칸을 돌려준다. title 이 비면 상단 바 없음(첫 화면: 큰 제목을 내용에).
static func page(screen: Control, title := "", sub := "") -> VBoxContainer:
	var bg := ColorRect.new()
	bg.color = UI.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(bg)
	var layout := VBoxContainer.new()
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	layout.add_theme_constant_override("separation", 0)
	screen.add_child(layout)
	if title != "":
		var bar := UI.top_bar(screen, title, sub)
		layout.add_child(bar)
		screen.set_meta("top_bar", bar)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.scroll_deadzone = 12
	layout.add_child(scroll)
	var m := UI.margin(24)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if title == "":
		m.add_theme_constant_override("margin_top", int(UI.safe_top(screen)) + 36)
	m.add_theme_constant_override("margin_bottom", 36)
	scroll.add_child(m)
	var fit_content := func():
		var side := maxi(24, int((scroll.size.x - MAX_CONTENT_WIDTH) * 0.5))
		m.add_theme_constant_override("margin_left", side)
		m.add_theme_constant_override("margin_right", side)
	scroll.resized.connect(fit_content)
	fit_content.call()
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 18)
	m.add_child(col)
	screen.set_meta("layout", layout)
	screen.set_meta("scroll", scroll)
	return col

## 내용 폭 (스크롤 안쪽, 좌우 여백 뺀 값)
static func content_width(screen: Control) -> float:
	var w := screen.get_viewport_rect().size.x
	return minf(w - 48.0, MAX_CONTENT_WIDTH)

static func wrap(text: String, size: int, color := UI.TEXT) -> Label:
	var l := UI.label(text, size, color, HORIZONTAL_ALIGNMENT_LEFT, true)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l

## 섹션 제목 (강조색) + 옅은 부제
static func section(title: String, sub := "") -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(UI.label(title, 30, UI.ACCENT))
	if sub != "":
		col.add_child(wrap(sub, 20, UI.TEXT_DIM))
	return col

static func chips(texts: Array, color_of: Callable) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", 8)
	f.add_theme_constant_override("v_separation", 8)
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for t in texts:
		f.add_child(UI.chip(str(t), color_of.call(str(t))))
	return f

## 덱 장수 꼬리표 (포켓몬 20 · 트레이너스 33 · 에너지 7)
static func kind_chips(deck: Dictionary) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", 8)
	f.add_theme_constant_override("v_separation", 8)
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for kind in ["pokemon", "trainer", "energy"]:
		f.add_child(UI.chip("%s %d" % [DeckData.KIND_LABEL[kind], int(deck["counts"][kind])], UI.KIND_COLOR[kind]))
	return f

## 둥근 패널 안에 여백을 둔 세로 칸. [패널, 칸] 을 돌려준다.
static func card(color := UI.PANEL, pad := 20) -> Array:
	var p := UI.panel(color, 22)
	p.mouse_filter = Control.MOUSE_FILTER_PASS
	var m := UI.margin(pad)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(col)
	return [p, col]

## 탭할 수 있는 카드. [탭 영역, 칸]
static func tap_card(color := UI.PANEL, pad := 20) -> Array:
	var tap := TapArea.new()
	var c := card(color, pad)
	var p: PanelContainer = c[0]
	p.set_anchors_preset(Control.PRESET_FULL_RECT)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tap.add_child(p)
	tap.press_target = p
	tap.set_meta("panel", p)
	return [tap, c[1]]

## 고른 칸 표시: 강조색 굵은 테두리
static func set_selected(tap: TapArea, on: bool, color := UI.PANEL) -> void:
	var p: PanelContainer = tap.get_meta("panel")
	p.add_theme_stylebox_override("panel", UI.box(color, 22, 4 if on else 2, UI.ACCENT if on else UI.LINE))

## 여러 값 중 하나: 같은 폭 버튼 줄, 고른 것은 채움. opts = [[값, 글자], ...]. 줄이 넘치면 다음 줄로
static func segmented(opts: Array, selected, on_pick: Callable, size := 22) -> HFlowContainer:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 8)
	row.add_theme_constant_override("v_separation", 8)
	for o in opts:
		var val = o[0]
		var on: bool = val == selected
		var b := UI.button(str(o[1]), size, on, on)
		b.set_meta("val", val)
		b.tapped.connect(func(): on_pick.call(val))
		row.add_child(b)
	return row

## 덱 대표 카드 그림 (살짝 기울임). w = 폭
static func cover(deck: Dictionary, w: float, tilt := -4.0, big := false) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(w, w * UI.CARD_RATIO)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var img := TextureRect.new()
	img.size = holder.custom_minimum_size
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.pivot_offset = img.size / 2
	img.rotation = deg_to_rad(tilt)
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(img)
	var c := DeckData.card_by_code(deck, deck["cover"])
	if not c.is_empty():
		var ref: WeakRef = weakref(img)
		ImageCache.request(c["full"] if big else c["thumb"], func(t):
			var r = ref.get_ref()
			if r:
				r.texture = t)
	return holder

## 덱 대표 카드의 타입 색을 아주 옅게 섞은 패널색 (덱 칸마다 조금씩 다른 색)
static func deck_tint(deck: Dictionary) -> Color:
	var c := DeckData.card_by_code(deck, deck["cover"])
	var pk = BData.card(str(c.get("code", deck["cover"]))).get("pokemon")
	var t: String = str(pk.get("type", "")) if pk is Dictionary else ""
	var col: Color = BData.TYPE_COLOR.get(t, UI.ACCENT)
	return UI.PANEL.lerp(col, 0.16 if UI.dark else 0.09)

## 첫 화면들 아래 탭 바
static func tabs(screen: Control, selected: String) -> void:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	UI.footer(screen).add_child(bar)
	for tab: String in TABS:
		var on := tab == selected
		var button := UI.button(tab, 24, on, on)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		(button.get_meta("panel") as Control).set_anchors_preset(Control.PRESET_FULL_RECT)
		button.set_meta("tab", tab)
		if not on:
			button.tapped.connect(open_tab.bind(tab))
		bar.add_child(button)

static func open_tab(tab: String) -> void:
	match tab:
		"홈": Nav.open_tab(null)
		"덱": Nav.open_tab(DeckListScreen.new())
		"대전": Nav.open_tab(HomeScreen.new(true))
