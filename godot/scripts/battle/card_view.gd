class_name BCard
extends TapArea
## 카드 한 장 (앞면 이미지 또는 뒷면). 크기는 custom_minimum_size / size 로.
## 길게 누르기·탭 신호는 TapArea 그대로. 강조(맥동)·흐리게 상태를 가진다.

var code := ""
var _img: TextureRect
var _back: Panel
var _frame: Panel
var _glow_tw: Tween

func _init() -> void:
	super._init()
	_back = Panel.new()
	_back.add_theme_stylebox_override("panel", back_style())
	_back.set_anchors_preset(Control.PRESET_FULL_RECT)
	_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_back)
	_img = TextureRect.new()
	_img.set_anchors_preset(Control.PRESET_FULL_RECT)
	_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_img)
	press_target = _img

static func back_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.3, 0.62)
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(3)
	sb.border_color = Color(0.92, 0.94, 1.0)
	return sb

## code 가 "" 이면 뒷면
func set_card(c: String, big := false) -> void:
	if c == code and (_img.texture != null or c == ""):
		return
	code = c
	_back.visible = c == ""
	_img.texture = null
	_img.visible = c != ""
	if c == "":
		return
	var ref: WeakRef = weakref(_img)
	var want := c
	ImageCache.request("res://cards/thumb/%s.webp" % c, func(t):
		var r = ref.get_ref()
		if r and r.texture == null and is_instance_valid(self) and code == want:
			r.texture = t)
	if big:
		ImageCache.request("res://cards/full/%s.webp" % c, func(t):
			var r = ref.get_ref()
			if r and is_instance_valid(self) and code == want:
				r.texture = t)

## 강조: "target" = 놓을 수 있는 곳(금색 틀 맥동), "pick" = 고른 것(굵은 틀), "dim" = 흐리게, "" = 보통
func set_mark(kind: String) -> void:
	if _glow_tw:
		_glow_tw.kill()
		_glow_tw = null
	modulate = Color(0.45, 0.45, 0.45) if kind == "dim" else Color.WHITE
	if kind == "target" or kind == "pick":
		if _frame == null:
			_frame = Panel.new()
			_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
			_frame.offset_left = -4
			_frame.offset_top = -4
			_frame.offset_right = 4
			_frame.offset_bottom = 4
			add_child(_frame)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.96, 0.77, 0.26, 0.12 if kind == "target" else 0.18)
		sb.border_color = UI.ACCENT
		sb.set_border_width_all(5 if kind == "target" else 8)
		sb.set_corner_radius_all(12)
		_frame.add_theme_stylebox_override("panel", sb)
		_frame.visible = true
		_frame.modulate.a = 1.0
		if kind == "target":
			_glow_tw = create_tween().set_loops()
			_glow_tw.tween_property(_frame, "modulate:a", 0.35, 0.45)
			_glow_tw.tween_property(_frame, "modulate:a", 1.0, 0.45)
	elif _frame:
		_frame.visible = false

func mark() -> String:
	if _frame and _frame.visible:
		return "target" if _glow_tw != null else "pick"
	return "dim" if modulate.r < 0.9 else ""
