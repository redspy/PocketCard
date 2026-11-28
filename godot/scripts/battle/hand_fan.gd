class_name BHand
extends Control
## 손패 부채: 화면 아래에 겹친 카드를 부채꼴로. iid 로 카드 노드를 유지.
## - 탭: 고르기 (고른 카드는 위로 올라오고 똑바로 섬)  - 길게: 크게 보기  - 옆으로 끌기: 패 넘기기(카드가 많을 때, 손가락을 따라감)
## - 위로 밀기(swipe_up 신호): 화면이 "바로 사용" 처리 (3단계에서 끌어 놓기로 확장)

signal card_tapped(iid: String)
signal card_long(iid: String)
signal card_swipe_up(iid: String)
signal card_drag_start(iid: String, pos: Vector2)
signal card_drag(iid: String, pos: Vector2)
signal card_drag_end(iid: String, pos: Vector2)

var cards: Dictionary = {}      # iid -> BCard
var order: Array = []           # 손패 순서 (iid)
var codes: Dictionary = {}      # iid -> code
var usable: Dictionary = {}     # iid -> bool
var selected := ""
var card_size := Vector2(188, 262)
var offset := 0.0               # 패 넘기기 (카드가 화면보다 많을 때 가로 이동)
var _pan_from = null            # 옆으로 끄는 중이면 시작할 때의 offset, 아니면 null

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## hand: [{iid, code}], use: iid -> 쓸 수 있는가, sel: 고른 iid
func set_hand(hand: Array, use: Dictionary, sel: String, csize: Vector2) -> void:
	card_size = csize
	usable = use
	selected = sel
	var keep := {}
	var fresh := {}
	var had := cards.size()
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
			c.panned.connect(_on_pan)
			c.draggable = true
			c.drag_started.connect(func(pos: Vector2): card_drag_start.emit(iid, pos))
			c.dragged.connect(func(pos: Vector2): card_drag.emit(iid, pos))
			c.drag_ended.connect(func(pos: Vector2): card_drag_end.emit(iid, pos))
			add_child(c)
			cards[iid] = c
			fresh[iid] = true
	var gone := false
	for iid in cards.keys():
		if not keep.has(iid):
			cards[iid].queue_free()
			cards.erase(iid)
			gone = true
	# 카드가 들어오거나 나가면 남은 카드는 새 자리로 미끄러진다 (새 카드는 바로 제자리)
	_place(had > 0 and (gone or not fresh.is_empty()) and is_visible_in_tree(), fresh)

func _on_swipe(_iid: String, d: Vector2) -> void:
	# 위로 밀기는 끌어 놓기가 맡는다 (밀어서 바로 쓰기는 잘못 놓았을 때 엉뚱하게 쓰여서 없앰)
	# 옆으로 끌며 이미 넘겼으면(_on_pan) 또 넘기지 않는다
	if _pan_from == null and absf(d.x) > absf(d.y):
		offset = clampf(offset + d.x, -_overflow(), 0.0)
		_place(true)

## 옆으로 끌기: 카드가 화면보다 많으면 손가락을 따라 패를 넘긴다 (천천히 끌어도)
func _on_pan(d: Vector2, done: bool) -> void:
	if _pan_from == null and not done and _overflow() > 0.0 and absf(d.x) > 18.0 and absf(d.x) > absf(d.y):
		_pan_from = offset - d.x
	if _pan_from != null:
		offset = clampf(_pan_from + d.x, -_overflow(), 0.0)
		_place(false)
	if done:
		_pan_from = null

func _step() -> float:
	var n := order.size()
	if n <= 1:
		return card_size.x
	var fit := (size.x - 24.0 - card_size.x) / (n - 1)
	# 겹침은 카드 폭의 24%(손가락으로 누를 수 있는 최소)까지 — 그보다 많으면 옆으로 넘기기
	return clampf(fit, maxf(44.0, card_size.x * 0.24), card_size.x * 0.92)

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

func _place(anim: bool, fresh := {}) -> void:
	for i in order.size():
		var iid: String = order[i]
		var c: BCard = cards[iid]
		var r := card_rect(i)
		c.size = card_size
		c.pivot_offset = Vector2(card_size.x / 2, card_size.y)
		c.set_card(codes[iid], card_size.x >= 150)
		c.z_index = 100 if iid == selected else i
		c.set_mark("pick" if iid == selected else ("" if usable.get(iid, false) else "dim"))
		var old = c.get_meta("place_tw") if c.has_meta("place_tw") else null
		if old is Tween and (old as Tween).is_valid():
			(old as Tween).kill()
		if anim and not fresh.has(iid):
			var tw := c.create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tw.tween_property(c, "position", r.pos, 0.14)
			tw.tween_property(c, "rotation_degrees", r.rot, 0.14)
			c.set_meta("place_tw", tw)
		else:
			c.position = r.pos
			c.rotation_degrees = r.rot

func refresh_layout() -> void:
	offset = clampf(offset, -_overflow(), 0.0)
	_place(false)

## 이 카드를 눌렀을 때 다른 카드에 가리지 않고 화면 안인 지점 (전역 좌표) — 회전·겹침을 정확히 계산
func press_point(iid: String) -> Vector2:
	if not cards.has(iid):
		return Vector2(-1, -1)
	var c: BCard = cards[iid]
	var view := get_viewport_rect()
	for fy in [0.35, 0.5, 0.2, 0.65, 0.8]:
		for fx in [0.15, 0.3, 0.08, 0.45, 0.6, 0.75, 0.9]:
			var gp: Vector2 = c.get_global_transform() * (c.size * Vector2(fx, fy))
			if not view.has_point(gp):
				continue
			var covered := false
			for o in cards.values():
				if o == c or o.z_index < c.z_index or (o.z_index == c.z_index and o.get_index() < c.get_index()):
					continue
				var lp: Vector2 = o.get_global_transform().affine_inverse() * gp
				if Rect2(Vector2.ZERO, o.size).has_point(lp):
					covered = true
					break
			if not covered:
				return gp
	return c.get_global_transform() * (c.size * 0.5)

## 이 카드가 화면 안에 보이도록 패를 넘긴다
func reveal(iid: String) -> void:
	var i := order.find(iid)
	if i < 0 or _overflow() <= 0.0:
		return
	var x := 12.0 + i * _step()
	var want := clampf(size.x * 0.5 - x - card_size.x * 0.5, -_overflow(), 0.0)
	if absf(want - offset) > 1.0:
		offset = want
		_place(true)
