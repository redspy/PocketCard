class_name BZoom
extends TapArea
## 카드 크게 보기 (어디서나): 좌우로 밀어 같은 묶음의 다른 카드로, 위·아래로 밀거나 누르면 닫힘.
## 여러 장이면 아래에 작은 카드 줄 (지금 보는 카드 강조, 누르면 이동). tags[i]: 설명("붙은 카드 1/2" 등)

var list: Array = []
var tags: Array = []
var index := 0
var _img: TextureRect
var _info: Label
var _cells: Array = []

static func open(parent: Control, codes: Array, idx := 0, tg: Array = []) -> BZoom:
	var z := BZoom.new()
	for i in codes.size():
		if str(codes[i]) != "":
			z.list.append(str(codes[i]))
			z.tags.append(str(tg[i]) if i < tg.size() else "")
	if z.list.is_empty():
		return null
	z.index = clampi(idx, 0, z.list.size() - 1)
	z.set_anchors_preset(Control.PRESET_FULL_RECT)
	parent.add_child(z)
	return z

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = UI.SCRIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var multi := list.size() > 1
	var thumb_w := 84.0
	var strip_h := thumb_w * UI.CARD_RATIO + 20.0 if multi else 0.0
	var sb := UI.safe_bottom(self)
	_img = TextureRect.new()
	_img.set_anchors_preset(Control.PRESET_FULL_RECT)
	_img.offset_left = 24
	_img.offset_right = -24
	_img.offset_top = UI.safe_top(self) + 40
	_img.offset_bottom = -sb - 90 - strip_h
	_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_img)
	_info = UI.label("", 22, UI.TEXT, HORIZONTAL_ALIGNMENT_CENTER, true)
	_info.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_info.offset_top = -sb - 80
	_info.offset_bottom = -sb - 12
	_info.offset_left = 20
	_info.offset_right = -20
	_info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_info)
	if multi:
		var sc := ScrollContainer.new()
		sc.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		sc.offset_top = -sb - 86 - strip_h
		sc.offset_bottom = -sb - 86
		sc.offset_left = 16
		sc.offset_right = -16
		sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sc.add_child(row)
		for i in list.size():
			var k := i
			var c := BCard.new()
			c.custom_minimum_size = Vector2(thumb_w, thumb_w * UI.CARD_RATIO)
			c.set_card(list[i])
			c.mouse_filter = Control.MOUSE_FILTER_STOP   # 눌러도 크게 보기가 닫히지 않게
			c.tapped.connect(func(): go(k))
			row.add_child(c)
			_cells.append(c)
		add_child(sc)
	tapped.connect(close)
	swiped.connect(func(d: Vector2):
		if absf(d.x) > absf(d.y) and list.size() > 1:
			go((index + (1 if d.x < 0 else -1) + list.size()) % list.size())
		elif absf(d.y) >= absf(d.x):
			close())
	_show()

func go(i: int) -> void:
	index = i
	_show()

func close() -> void:
	queue_free()

func info_text() -> String:
	return _info.text

func _show() -> void:
	var code := str(list[index])
	_img.texture = null
	ImageCache.request("res://cards/thumb/%s.webp" % code, BZoom._apply.bind(weakref(self), code, true))
	ImageCache.request("res://cards/full/%s.webp" % code, BZoom._apply.bind(weakref(self), code, false))
	var tag := str(tags[index]) if index < tags.size() else ""
	if list.size() > 1:
		_info.text = "%s%d / %d  ·  좌우로 밀어 넘기기 · 누르면 닫기" % [(tag + "  ·  ") if tag != "" else "", index + 1, list.size()]
	else:
		_info.text = (tag + "  ·  " if tag != "" else "") + "누르거나 아래로 밀면 닫기"
	for k in _cells.size():
		(_cells[k] as Control).modulate = Color.WHITE if k == index else Color(0.55, 0.55, 0.55)

## 포켓몬 칸의 카드들: 지금 모습 → 진화 전 → 붙은 카드 (설명 포함)
static func slot_codes(slot: Dictionary) -> Array:
	var codes: Array = []
	var tg: Array = []
	var st = slot.get("stack")
	if st is Array:
		for i in range(st.size() - 1, -1, -1):
			codes.append(str(st[i].code))
			tg.append("지금 모습" if i == st.size() - 1 else "진화 전")
	var att = slot.get("attached")
	if att is Array:
		for i in att.size():
			codes.append(str(att[i].code))
			tg.append("붙은 카드 %d/%d" % [i + 1, att.size()])
	return [codes, tg]

static func _apply(t: Texture2D, ref: WeakRef, want: String, only_if_empty: bool) -> void:
	var me = ref.get_ref()
	if me == null or str(me.list[me.index]) != want:
		return
	if only_if_empty and me._img.texture != null:
		return
	me._img.texture = t
