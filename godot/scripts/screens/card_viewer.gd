class_name CardViewer
extends Control
## 카드 크게 보기 (오버레이)
## - 썸네일 자리에서 커지며 열리고, 닫을 때 현재 카드의 썸네일 자리로 줄어든다
## - 좌우 스와이프: 이전/다음 카드   - 아래로 스와이프: 닫기
## - 핀치 / 더블탭: 확대(최대 4배), 확대 중 드래그: 이동
## - 썸네일을 먼저 보여주고 큰 이미지가 준비되면 교체, 앞뒤 카드는 미리 불러옴
## - 같은 카드의 다른 인쇄가 있으면 위쪽에 작은 썸네일 줄 → 누르면 덱의 그 카드를 해당 인쇄로 바꿈

enum Mode { NONE, UNDECIDED, PAGE, DISMISS, PAN, PINCH }

const OPEN_TIME := 0.34
const PAGE_TIME := 0.24
const MAX_ZOOM := 4.0
const DOUBLE_TAP_ZOOM := 2.5
const DRAG_SLOP := 14.0
const PAGE_GAP := 48.0
const PRINT_W := 74.0             # 인쇄 썸네일 폭
const PRINT_GAP := 12
const PRINTS_H := PRINT_W * 1212.0 / 868.0 + 34.0   # 썸네일 + 마크 글자

var deck: Dictionary
var cards: Array
var index: int
var source: DeckDetailScreen

var _bg: ColorRect
var _pages: Array[TextureRect] = []
var _info: Control
var _name_label: Label
var _sub_label: Label
var _close_btn: TapArea
var _prints: HBoxContainer        # 같은 카드의 다른 인쇄(레귤레이션) 썸네일 줄
var _reserve_prints := false      # 덱에 다른 인쇄가 있는 카드가 하나라도 있으면 위쪽 공간을 항상 비워 둠(넘길 때 카드 크기 유지)

var _fit := Rect2()
var _drag := Vector2.ZERO      # PAGE: x 오프셋, DISMISS: y 오프셋
var _zoom := 1.0
var _pan := Vector2.ZERO
var _mode := Mode.NONE
var _touches := {}
var _drag_start := Vector2.ZERO
var _pan_start := Vector2.ZERO
var _velocity := Vector2.ZERO
var _pinch_dist0 := 1.0
var _pinch_zoom0 := 1.0
var _pinch_pan0 := Vector2.ZERO
var _pinch_mid0 := Vector2.ZERO
var _last_tap_ms := 0
var _last_tap_pos := Vector2.ZERO
var _animating := false
var _tw: Tween

func _init(deck_data: Dictionary, flat_cards: Array, start_index: int, src: DeckDetailScreen) -> void:
	deck = deck_data
	cards = flat_cards
	index = start_index
	source = src

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP   # 아래 화면으로 터치가 새지 않게

	_bg = ColorRect.new()
	_bg.color = Color(0.02, 0.05, 0.04, 0.94)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.modulate.a = 0.0
	add_child(_bg)

	for i in 3:
		var r := TextureRect.new()
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		r.visible = false
		add_child(r)
		_pages.append(r)

	_build_info()
	_build_close()
	_prints = HBoxContainer.new()
	_prints.alignment = BoxContainer.ALIGNMENT_CENTER
	_prints.add_theme_constant_override("separation", PRINT_GAP)
	_prints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prints.modulate.a = 0.0
	add_child(_prints)
	for c in cards:
		if DeckData.has_prints(c):
			_reserve_prints = true
			break
	resized.connect(_on_resized)
	_open.call_deferred()

# ───────────────────────── 구성 ─────────────────────────

func _build_info() -> void:
	_info = VBoxContainer.new()
	_info.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info.alignment = BoxContainer.ALIGNMENT_END
	_info.add_theme_constant_override("separation", 4)
	_name_label = UI.label("", 40, UI.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	_sub_label = UI.label("", 24, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	_info.add_child(_name_label)
	_info.add_child(_sub_label)
	_info.modulate.a = 0.0
	add_child(_info)

func _build_close() -> void:
	_close_btn = TapArea.new()
	_close_btn.custom_minimum_size = Vector2(88, 88)
	_close_btn.size = Vector2(88, 88)
	_close_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	var x := UI.label("✕", 44, UI.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	x.set_anchors_preset(Control.PRESET_FULL_RECT)
	x.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_close_btn.add_child(x)
	_close_btn.tapped.connect(close)
	_close_btn.modulate.a = 0.0
	add_child(_close_btn)

func _compute_fit() -> void:
	var top := UI.safe_top(self) + 110.0
	# 인쇄 썸네일 줄: 닫기 버튼 오른쪽 위, 카드 위쪽 공간을 그만큼 비운다
	var px := 16.0 + 88.0 + 12.0
	_prints.position = Vector2(px, UI.safe_top(self) + 16)
	_prints.size = Vector2(size.x - px - 16.0, PRINTS_H)
	if _reserve_prints:
		top = UI.safe_top(self) + 16 + PRINTS_H + 20.0
	var bottom := UI.safe_bottom(self) + 150.0
	var avail := Vector2(size.x - 40.0, size.y - top - bottom)
	var w := minf(avail.x, avail.y / UI.CARD_RATIO)
	var h := w * UI.CARD_RATIO
	_fit = Rect2(Vector2((size.x - w) / 2.0, top + (avail.y - h) / 2.0), Vector2(w, h))
	_info.position = Vector2(0, size.y - UI.safe_bottom(self) - 130.0)
	_info.size = Vector2(size.x, 110)
	_close_btn.position = Vector2(16, UI.safe_top(self) + 16)

func _on_resized() -> void:
	if _animating:
		return
	_compute_fit()
	_clamp_pan()
	_layout()
	# 화면 폭이 바뀌면(폴드 펼침/접힘) 인쇄 썸네일 크기도 다시 맞춘다
	_prints.set_meta("for", "")
	_build_prints()

# ───────────────────────── 이미지 ─────────────────────────

func _set_textures() -> void:
	for i in 3:
		var idx := index + i - 1
		var r := _pages[i]
		if idx < 0 or idx >= cards.size():
			r.visible = false
			r.set_meta("code", "")
			continue
		r.visible = true
		_load_into(r, cards[idx])
	# 앞뒤 한 장 더 미리 불러오기
	for k in [index - 2, index + 2]:
		if k >= 0 and k < cards.size():
			ImageCache.preload_path(cards[k]["full"])
	_update_info()

func _load_into(r: TextureRect, card: Dictionary) -> void:
	var code: String = card["code"]
	if r.get_meta("code", "") == code:
		return
	r.set_meta("code", code)
	r.set_meta("full", false)
	r.texture = ImageCache.get_cached(card["full"])
	if r.texture:
		r.set_meta("full", true)
		return
	r.texture = ImageCache.get_cached(card["thumb"])
	ImageCache.request(card["thumb"], func(t):
		if is_instance_valid(r) and r.get_meta("code", "") == code and not r.get_meta("full", false):
			r.texture = t)
	ImageCache.request(card["full"], func(t):
		if is_instance_valid(r) and r.get_meta("code", "") == code:
			r.texture = t
			r.set_meta("full", true))

func _update_info() -> void:
	var c: Dictionary = cards[index]
	_name_label.text = c["name"]
	var reg: String = DeckData.current_print(c).get("reg", "")
	_sub_label.text = "%s%s · ×%d · %d / %d" % [c["code"], (" · " + reg) if reg != "" else "", int(c["count"]), index + 1, cards.size()]
	_build_prints()

# ───────────────────────── 다른 인쇄 ─────────────────────────

func _build_prints() -> void:
	var c: Dictionary = cards[index]
	var has := DeckData.has_prints(c)
	if _prints.get_meta("for", "") == c["id"] + "|" + c["code"] and _prints.visible == has:
		return
	_prints.set_meta("for", c["id"] + "|" + c["code"])
	for ch in _prints.get_children():
		ch.queue_free()
	_prints.visible = has
	if not has:
		return
	# 개수가 많으면 썸네일을 줄여 한 줄에 맞춘다
	var n: int = c["prints"].size()
	var w := minf(PRINT_W, (_prints.size.x - PRINT_GAP * (n - 1)) / n - 6.0)
	for p in c["prints"]:
		_prints.add_child(_print_item(c, p, w))

func _print_item(card: Dictionary, p: Dictionary, w: float) -> TapArea:
	var selected: bool = p["code"] == card["code"]
	var item := TapArea.new()
	item.mouse_filter = Control.MOUSE_FILTER_STOP
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_child(col)

	var frame := PanelContainer.new()
	var sb := UI.box(Color(0, 0, 0, 0.3), 8, 3 if selected else 1, UI.ACCENT if selected else Color(1, 1, 1, 0.25))
	sb.set_content_margin_all(3)
	frame.add_theme_stylebox_override("panel", sb)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var img := TextureRect.new()
	img.custom_minimum_size = Vector2(w, w * UI.CARD_RATIO)
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not selected:
		img.modulate = Color(1, 1, 1, 0.7)
	# 썸네일 줄을 다시 만들면 img 가 먼저 사라질 수 있어 약한 참조로 넘긴다
	var img_ref: WeakRef = weakref(img)
	ImageCache.request(p["thumb"], func(t):
		var r = img_ref.get_ref()
		if r:
			r.texture = t)
	frame.add_child(img)
	col.add_child(frame)

	var mark: String = p.get("reg", "")
	if mark == "":
		mark = "-"
	if p.get("special", false):
		mark += "★"
	col.add_child(UI.label(mark, 22, UI.ACCENT if selected else UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
	item.press_target = frame
	item.tapped.connect(func(): _choose_print(p["code"]))
	return item

func _over_print(pos: Vector2) -> bool:
	for ch in _prints.get_children():
		if ch is Control and (ch as Control).get_global_rect().has_point(pos):
			return true
	return false

func _choose_print(code: String) -> void:
	if _animating or _zoom > 1.01:
		return
	var c: Dictionary = cards[index]
	if not DeckData.set_print(deck, c, code):
		return
	var cur := _pages[1]
	cur.set_meta("code", "")
	_load_into(cur, c)
	cur.modulate.a = 0.35
	var tw := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(cur, "modulate:a", 1.0, 0.25)
	_update_info()
	if is_instance_valid(source):
		source.refresh_card(c)

# ───────────────────────── 배치 ─────────────────────────

func _layout() -> void:
	var page_w := size.x + PAGE_GAP
	var dismiss := clampf(_drag.y / maxf(size.y, 1.0), 0.0, 1.0)
	for i in 3:
		var r := _pages[i]
		r.size = _fit.size
		r.pivot_offset = _fit.size / 2.0
		var pos := _fit.position + Vector2((i - 1) * page_w + _drag.x, 0)
		if i == 1:
			r.position = pos + _pan + Vector2(0, _drag.y)
			var s := _zoom * (1.0 - dismiss * 0.4)
			r.scale = Vector2(s, s)
		else:
			r.position = pos
			r.scale = Vector2.ONE
	_bg.modulate.a = 1.0 - clampf(_drag.y / 520.0, 0.0, 0.9)
	_info.modulate.a = 1.0 - clampf(_drag.y / 200.0, 0.0, 1.0) if _zoom <= 1.01 else 0.0
	_close_btn.modulate.a = _info.modulate.a if _zoom <= 1.01 else 1.0
	_prints.modulate.a = _info.modulate.a

func _clamp_pan() -> void:
	var limit := _fit.size * (_zoom - 1.0) / 2.0
	_pan = _pan.clamp(-limit, limit)

# ───────────────────────── 열기 / 닫기 ─────────────────────────

func _open() -> void:
	_compute_fit()
	_set_textures()
	_layout()
	var from := _thumb_rect()
	var cur := _pages[1]
	for i in [0, 2]:
		_pages[i].modulate.a = 0.0
	_animating = true
	if from.has_area():
		cur.scale = Vector2.ONE
		cur.position = from.position
		cur.size = from.size
		cur.pivot_offset = from.size / 2.0
	else:
		cur.modulate.a = 0.0
	_tw = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tw.tween_property(cur, "position", _fit.position, OPEN_TIME)
	_tw.tween_property(cur, "size", _fit.size, OPEN_TIME)
	_tw.tween_property(cur, "modulate:a", 1.0, OPEN_TIME * 0.6)
	_tw.tween_property(_bg, "modulate:a", 1.0, OPEN_TIME)
	_tw.tween_property(_info, "modulate:a", 1.0, OPEN_TIME).set_delay(0.1)
	_tw.tween_property(_close_btn, "modulate:a", 1.0, OPEN_TIME).set_delay(0.1)
	_tw.tween_property(_prints, "modulate:a", 1.0, OPEN_TIME).set_delay(0.1)
	for i in [0, 2]:
		_tw.tween_property(_pages[i], "modulate:a", 1.0, 0.2).set_delay(OPEN_TIME)
	_tw.chain().tween_callback(func():
		_animating = false
		_layout())

func close() -> void:
	if _animating:
		return
	_animating = true
	_mode = Mode.NONE
	_touches.clear()
	# 현재 카드의 썸네일이 목록에서 보이도록 스크롤한 뒤 그 자리로 줄어든다
	var thumb := source.thumb_for(cards[index]["code"]) if is_instance_valid(source) else null
	if thumb:
		source.scroll_to(thumb)
		await get_tree().process_frame
	var to := _thumb_rect()
	var cur := _pages[1]
	# 현재 보이는 모습(확대/아래로 끌기 반영)을 위치/크기로 옮긴 뒤 애니메이션
	var vis_size := cur.size * cur.scale
	cur.position = cur.position + (cur.size - vis_size) / 2.0
	cur.size = vis_size
	cur.scale = Vector2.ONE
	_tw = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if to.has_area():
		_tw.tween_property(cur, "position", to.position, OPEN_TIME)
		_tw.tween_property(cur, "size", to.size, OPEN_TIME)
	else:
		_tw.tween_property(cur, "modulate:a", 0.0, OPEN_TIME)
	for i in [0, 2]:
		_tw.tween_property(_pages[i], "modulate:a", 0.0, 0.15)
	_tw.tween_property(_bg, "modulate:a", 0.0, OPEN_TIME)
	_tw.tween_property(_info, "modulate:a", 0.0, 0.15)
	_tw.tween_property(_close_btn, "modulate:a", 0.0, 0.15)
	_tw.tween_property(_prints, "modulate:a", 0.0, 0.15)
	_tw.chain().tween_callback(func():
		for p in _pages:
			p.texture = null
		Nav.drop(self)
		# 보기 화면에서 쓰던 큰 이미지 정리 (최근 2장만 남김)
		ImageCache.trim(2))

func _thumb_rect() -> Rect2:
	if not is_instance_valid(source):
		return Rect2()
	var t := source.thumb_for(cards[index]["code"])
	if t == null or not t.is_visible_in_tree():
		return Rect2()
	var r := t.image.get_global_rect()
	r.position -= global_position
	# 썸네일이 화면 밖이면 페이드로 처리
	if not Rect2(Vector2.ZERO, size).intersects(r):
		return Rect2()
	return r

## Android 뒤로 가기
func on_back() -> bool:
	if _zoom > 1.01:
		_animate_zoom(1.0, Vector2.ZERO)
	else:
		close()
	return true

# ───────────────────────── 페이지 넘기기 ─────────────────────────

func go(dir: int) -> void:
	var target := index + dir
	if dir == 0 or target < 0 or target >= cards.size():
		_animate_drag(Vector2.ZERO)
		return
	_animating = true
	var page_w := size.x + PAGE_GAP
	if _tw:
		_tw.kill()
	_tw = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tw.tween_method(func(v: float):
		_drag.x = v
		_layout(), _drag.x, -dir * page_w, PAGE_TIME)
	_tw.tween_callback(func():
		index = target
		_drag = Vector2.ZERO
		_zoom = 1.0
		_pan = Vector2.ZERO
		# 텍스처를 한 칸씩 밀어 재사용 (깜빡임 방지)
		if dir > 0:
			var first: TextureRect = _pages.pop_front()
			_pages.append(first)
		else:
			var last: TextureRect = _pages.pop_back()
			_pages.push_front(last)
		_set_textures()
		_layout()
		_animating = false)

func _animate_drag(to: Vector2) -> void:
	if _tw:
		_tw.kill()
	_tw = create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tw.tween_method(func(v: Vector2):
		_drag = v
		_layout(), _drag, to, 0.28)

func _animate_zoom(z: float, pan: Vector2) -> void:
	if _tw:
		_tw.kill()
	var z0 := _zoom
	var p0 := _pan
	_tw = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tw.tween_method(func(t: float):
		_zoom = lerpf(z0, z, t)
		_pan = p0.lerp(pan, t)
		_layout(), 0.0, 1.0, 0.25)

func _zoom_pan_for(z: float, focus: Vector2) -> Vector2:
	# focus 지점(화면 좌표)이 확대 후에도 손가락 아래에 있도록 하는 pan 값
	var c := _fit.get_center()
	var p := (focus - c) * (1.0 - z)
	var limit := _fit.size * (z - 1.0) / 2.0
	return p.clamp(-limit, limit)

# ───────────────────────── 터치 입력 ─────────────────────────

func _input(event: InputEvent) -> void:
	if Nav.current() != self or _animating:
		return
	# PC: 마우스 휠로 확대/축소 (커서 위치 기준), 좌우 방향키로 카드 넘기기
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var mb := event as InputEventMouseButton
		var z := clampf(_zoom * (1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15), 1.0, MAX_ZOOM)
		var c := _fit.get_center()
		var img_pt: Vector2 = (mb.position - c - _pan) / _zoom
		_zoom = z
		_pan = mb.position - c - img_pt * z
		_clamp_pan()
		_layout()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and _zoom <= 1.01:
		if event.keycode == KEY_RIGHT:
			go(1)
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_LEFT:
			go(-1)
			get_viewport().set_input_as_handled()
			return
	if event is InputEventScreenTouch:
		_on_touch(event)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		_on_drag(event)
		get_viewport().set_input_as_handled()

func _on_touch(e: InputEventScreenTouch) -> void:
	if e.pressed:
		# 닫기 버튼 위는 버튼에 맡김
		if _touches.is_empty() and _close_btn.get_global_rect().has_point(e.position):
			return
		# 인쇄 썸네일 위도 버튼에 맡김
		if _touches.is_empty() and _prints.visible and _zoom <= 1.01 and _over_print(e.position):
			return
		_touches[e.index] = e.position
		if _tw and _tw.is_running():
			_tw.kill()
		if _touches.size() == 1:
			_mode = Mode.UNDECIDED
			_drag_start = e.position
			_pan_start = _pan
			_velocity = Vector2.ZERO
		elif _touches.size() == 2:
			_start_pinch()
	else:
		if not _touches.has(e.index):
			return
		_touches.erase(e.index)
		if _touches.is_empty():
			_release(e.position)
		elif _mode == Mode.PINCH:
			# 손가락 하나만 남으면 이어서 이동
			_mode = Mode.PAN if _zoom > 1.01 else Mode.NONE
			_drag_start = _touches.values()[0]
			_pan_start = _pan

func _on_drag(e: InputEventScreenDrag) -> void:
	if not _touches.has(e.index):
		return
	_touches[e.index] = e.position
	_velocity = e.velocity
	if _touches.size() >= 2:
		_update_pinch()
		return
	var d := e.position - _drag_start
	if _mode == Mode.UNDECIDED and d.length() > DRAG_SLOP:
		if _zoom > 1.01:
			_mode = Mode.PAN
		elif absf(d.x) > absf(d.y):
			_mode = Mode.PAGE
		elif d.y > 0:
			_mode = Mode.DISMISS
		else:
			_mode = Mode.NONE
	match _mode:
		Mode.PAGE:
			var dx := d.x
			var at_edge := (dx > 0 and index == 0) or (dx < 0 and index == cards.size() - 1)
			_drag = Vector2(dx * (0.3 if at_edge else 1.0), 0)
			_layout()
		Mode.DISMISS:
			_drag = Vector2(0, maxf(0.0, d.y))
			_layout()
		Mode.PAN:
			_pan = _pan_start + d
			_clamp_pan()
			_layout()

func _release(pos: Vector2) -> void:
	match _mode:
		Mode.UNDECIDED:
			_on_tap(pos)
		Mode.PAGE:
			var page_w := size.x + PAGE_GAP
			var dir := 0
			if _drag.x < -page_w * 0.18 or _velocity.x < -700.0:
				dir = 1
			elif _drag.x > page_w * 0.18 or _velocity.x > 700.0:
				dir = -1
			go(dir)
		Mode.DISMISS:
			if _drag.y > 170.0 or _velocity.y > 900.0:
				close()
			else:
				_animate_drag(Vector2.ZERO)
		Mode.PINCH, Mode.PAN:
			if _zoom < 1.02:
				_animate_zoom(1.0, Vector2.ZERO)
	_mode = Mode.NONE

## 지금 화면에 보이는 카드 영역 (확대/이동 반영)
func _card_rect() -> Rect2:
	var r := _pages[1]
	var vis := r.size * r.scale
	return Rect2(r.position + (r.size - vis) / 2.0, vis)

func _on_tap(pos: Vector2) -> void:
	# 확대 중 카드 바깥(어두운 배경)을 누르면 확대 해제
	if _zoom > 1.01 and not _card_rect().has_point(pos):
		_last_tap_ms = 0
		_animate_zoom(1.0, Vector2.ZERO)
		return
	var now := Time.get_ticks_msec()
	if now - _last_tap_ms < 320 and pos.distance_to(_last_tap_pos) < 60.0:
		_last_tap_ms = 0
		if _zoom > 1.01:
			_animate_zoom(1.0, Vector2.ZERO)
		else:
			_animate_zoom(DOUBLE_TAP_ZOOM, _zoom_pan_for(DOUBLE_TAP_ZOOM, pos))
	else:
		_last_tap_ms = now
		_last_tap_pos = pos

func _start_pinch() -> void:
	var pts: Array = _touches.values()
	_mode = Mode.PINCH
	_pinch_dist0 = maxf((pts[0] as Vector2).distance_to(pts[1]), 1.0)
	_pinch_mid0 = ((pts[0] as Vector2) + (pts[1] as Vector2)) / 2.0
	_pinch_zoom0 = _zoom
	_pinch_pan0 = _pan
	_drag = Vector2.ZERO

func _update_pinch() -> void:
	if _mode != Mode.PINCH:
		_start_pinch()
	var pts: Array = _touches.values()
	var a: Vector2 = pts[0]
	var b: Vector2 = pts[1]
	var mid := (a + b) / 2.0
	var z := clampf(_pinch_zoom0 * a.distance_to(b) / _pinch_dist0, 0.85, MAX_ZOOM)
	# 처음 두 손가락 가운데 있던 이미지 지점이 계속 가운데 있도록
	var c := _fit.get_center()
	var img_pt := (_pinch_mid0 - c - _pinch_pan0) / _pinch_zoom0
	_zoom = z
	_pan = mid - c - img_pt * z
	_clamp_pan()
	_layout()
