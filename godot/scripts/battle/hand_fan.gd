class_name BHand
extends Control
## 손패 부채: 화면 아래에 겹친 카드를 부채꼴로. iid 로 카드 노드를 유지.
## - 탭: 고르기 (고른 카드는 위로 올라오고 똑바로 섬)  - 길게: 크게 보기  - 옆으로 밀기: 패 넘기기(카드가 많을 때)
## - 위로 밀기(swipe_up 신호): 화면이 "바로 사용" 처리 (3단계에서 끌어 놓기로 확장)

signal card_tapped(iid: String)
signal card_long(iid: String)
signal card_swipe_up(iid: String)

var cards: Dictionary = {}      # iid -> BCard
var order: Array = []           # 손패 순서 (iid)
var codes: Dictionary = {}      # iid -> code
var usable: Dictionary = {}     # iid -> bool
var selected := ""
var card_size := Vector2(188, 262)
var offset := 0.0               # 패 넘기기 (카드가 화면보다 많을 때 가로 이동)

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## hand: [{iid, code}], use: iid -> 쓸 수 있는가, sel: 고른 iid
func set_hand(hand: Array, use: Dictionary, sel: String, csize: Vector2) -> void:
	card_size = csize
	usable = use
	selected = sel
	var keep := {}
	order = []
	for h in hand:
		var iid := str(h.iid)
		order.append(iid)
		codes[iid] = str(h.code)
		keep[iid] = true
		if not cards.has(iid):
			var c := BCard.new()
			c.name = "H_" + iid
			c.tapped.connect(func(): card_tapped.emit(iid))
			c.long_pressed.connect(func(): card_long.emit(iid))
			c.swiped.connect(func(d: Vector2): _on_swipe(iid, d))
			add_child(c)
			cards[iid] = c
	for iid in cards.keys():
		if not keep.has(iid):
			cards[iid].queue_free()
			cards.erase(iid)
	_place(false)

func _on_swipe(iid: String, d: Vector2) -> void:
	if d.y < -absf(d.x):
		card_swipe_up.emit(iid)
	elif absf(d.x) > absf(d.y):
		offset = clampf(offset + d.x, -_overflow(), 0.0)
		_place(true)

func _step() -> float:
	var n := order.size()
	if n <= 1:
		return card_size.x
	var fit := (size.x - 24.0 - card_size.x) / (n - 1)
	return clampf(fit, card_size.x * 0.34, card_size.x * 0.92)

func _overflow() -> float:
	var n := order.size()
	return maxf(0.0, (n - 1) * _step() + card_size.x + 24.0 - size.x)

## 카드 위치 (i 번째): 부채꼴 (가운데가 높고 양 끝이 살짝 내려가며 기울어짐)
func card_rect(i: int) -> Dictionary:
	var n := order.size()
	var step := _step()
	var total := (n - 1) * step + card_size.x
	var x0 := (size.x - total) / 2.0 if total <= size.x else 12.0 + offset
	var mid := (n - 1) / 2.0
	var t := (i - mid) / maxf(1.0, mid) if n > 1 else 0.0
	var iid: String = order[i]
	var up := iid == selected
	var y := 18.0 + absf(t) * 22.0 - (card_size.y * 0.24 if up else 0.0)
	var rot := 0.0 if up else t * 6.0
	return { "pos": Vector2(x0 + i * step, y), "rot": rot }

func _place(anim: bool) -> void:
	for i in order.size():
		var iid: String = order[i]
		var c: BCard = cards[iid]
		var r := card_rect(i)
		c.size = card_size
		c.pivot_offset = Vector2(card_size.x / 2, card_size.y)
		c.set_card(codes[iid], card_size.x >= 150)
		c.z_index = 100 if iid == selected else i
		c.set_mark("pick" if iid == selected else ("" if usable.get(iid, false) else "dim"))
		if anim:
			var tw := c.create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tw.tween_property(c, "position", r.pos, 0.14)
			tw.tween_property(c, "rotation_degrees", r.rot, 0.14)
		else:
			c.position = r.pos
			c.rotation_degrees = r.rot

func refresh_layout() -> void:
	offset = clampf(offset, -_overflow(), 0.0)
	_place(false)
