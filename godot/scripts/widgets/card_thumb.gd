class_name CardThumb
extends TapArea
## 덱 목록의 카드 썸네일 한 칸: 이미지 + 매수 배지 + 카드명

var card: Dictionary
var image: TextureRect
var _placeholder: Panel

func _init(card_data: Dictionary, width: float) -> void:
	super()
	card = card_data
	var img_h := width * UI.CARD_RATIO
	custom_minimum_size = Vector2(width, img_h + 52)

	var frame := Control.new()
	frame.size = Vector2(width, img_h)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(frame)

	_placeholder = Panel.new()
	_placeholder.add_theme_stylebox_override("panel", UI.box(UI.PANEL_HI, 10))
	_placeholder.size = frame.size
	_placeholder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(_placeholder)

	image = TextureRect.new()
	image.size = frame.size
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.modulate.a = 0.0
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(image)

	# 매수 배지 (오른쪽 아래)
	var badge := PanelContainer.new()
	var sb := UI.box(Color(0, 0, 0, 0.78), 14, 2, UI.ACCENT)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	badge.add_theme_stylebox_override("panel", sb)
	badge.add_child(UI.label("×%d" % int(card["count"]), 24, UI.ACCENT, HORIZONTAL_ALIGNMENT_CENTER))
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(badge)
	badge.ready.connect(func(): badge.position = Vector2(width - badge.size.x - 6, img_h - badge.size.y - 6), CONNECT_ONE_SHOT)

	var name_label := UI.label(card["name"], 19, UI.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.clip_text = true
	name_label.position = Vector2(0, img_h + 8)
	name_label.size = Vector2(width, 36)
	add_child(name_label)

	press_target = frame

func _ready() -> void:
	super()
	refresh()

## 카드 인쇄가 바뀌면 새 썸네일로 교체 (이전 이미지는 그대로 두었다가 덮어씀)
func refresh() -> void:
	var path = card.get("thumb")
	if path is String:
		# 늦게 도착한 이전 인쇄의 이미지는 무시
		ImageCache.request(path, func(t):
			if card.get("thumb") == path:
				_on_texture(t))

func _on_texture(tex: Texture2D) -> void:
	if not is_instance_valid(image):
		return
	if image.texture != null and image.texture != tex:
		image.texture = tex
		return
	image.texture = tex
	var tw := create_tween()
	tw.tween_property(image, "modulate:a", 1.0, 0.22)
	tw.tween_callback(_placeholder.hide)
