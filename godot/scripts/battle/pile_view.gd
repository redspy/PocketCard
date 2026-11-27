class_name BPile
extends Control
## 덱(뒷면 + 남은 장수) / 트래쉬(맨 위 카드 + 장수). 탭하면 화면이 트래쉬 시트를 연다.

var kind := "deck"
var count := 0
var top_code := ""
var card: BCard
var _count: Label
var low := false                     # 덱이 얼마 안 남음 (경고색)
const LOW_DECK := 5                  # 덱이 비면 뽑지 못해 패배 → 5장 이하면 경고


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	card = BCard.new()
	card.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(card)
	_count = UI.label("", 20, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	add_child(_count)
	resized.connect(_relayout)

func set_pile(k: String, n: int, code := "") -> void:
	kind = k
	count = n
	top_code = code
	card.visible = n > 0
	card.set_card("" if k == "deck" else code)
	_count.text = ("덱 %d" if k == "deck" else "트래쉬 %d") % n
	low = k == "deck" and n <= LOW_DECK
	_count.add_theme_color_override("font_color", UI.BAD if low else UI.TEXT_DIM)
	_relayout()

func _relayout() -> void:
	_count.add_theme_font_size_override("font_size", maxi(14, int(size.x * 0.2)))
	_count.size = Vector2(size.x + 40, 0)
	_count.position = Vector2(-20, size.y + 2)
