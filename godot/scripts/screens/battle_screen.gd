class_name BattleScreen
extends Control
## 새 대전 화면 (docs/ui-pocket-design.md v2)
##  mode "table": AI 연습 — 한 화면 탁자 (상대·내 필드, 사이드·덱·트래쉬, 스타디움, 손패 부채)
##  mode "hand" : 서버 대전 — 게임판은 웹. 폰은 내 포켓몬 작은 줄 + 큰 손패 + 개인 선택
## 상태는 Net.view(내 시점)만 보고 그린다. 포켓몬 칸은 sid 로, 손패는 iid 로 노드를 유지한다.

var mode := "table"
var L: Dictionary = {}
var board: Control
var hud: Control
var sheet_layer: Control
var fx_layer: Control
var drag_layer: Control
var slots: Dictionary = {}          # sid -> BSlot
var empties: Dictionary = {}        # "my:3" -> BSlot (빈 벤치 칸)
var piles: Dictionary = {}          # "my_deck" 등 -> BPile
var prize_cards: Dictionary = {}    # "my"/"opp" -> Array[BCard]
var stadium: BCard
var opp_hand: Label
var bar_title: Label
var status_label: Label
var notice_label: Label

func _init(m := "") -> void:
	mode = m

func _ready() -> void:
	if mode == "":
		mode = "table" if Net.solo else "hand"
	var bg := ColorRect.new()
	bg.color = UI.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	for n in ["board", "hud", "sheet_layer", "fx_layer", "drag_layer"]:
		var c := Control.new()
		c.set_anchors_preset(Control.PRESET_FULL_RECT)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(c)
		set(n, c)
	_build_static()
	Net.changed.connect(_refresh)
	resized.connect(_refresh)
	_refresh()

func _exit_tree() -> void:
	if Net.changed.is_connected(_refresh):
		Net.changed.disconnect(_refresh)

func _build_static() -> void:
	# 가운데 줄 (트레이너스를 놓는 곳) — 탁자 모드
	var mid := Panel.new()
	mid.name = "Mid"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.035)
	sb.set_corner_radius_all(14)
	mid.add_theme_stylebox_override("panel", sb)
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board.add_child(mid)
	stadium = BCard.new()
	stadium.name = "Stadium"
	board.add_child(stadium)
	for side in ["my", "opp"]:
		for k in ["deck", "discard"]:
			var p := BPile.new()
			p.name = "%s_%s" % [side, k]
			board.add_child(p)
			piles["%s_%s" % [side, k]] = p
		var arr: Array = []
		for i in 6:
			var c := BCard.new()
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
			board.add_child(c)
			arr.append(c)
		prize_cards[side] = arr
	opp_hand = UI.label("", 22, UI.TEXT_DIM)
	board.add_child(opp_hand)
	# 상단 바
	var bar := Panel.new()
	bar.name = "Bar"
	bar.add_theme_stylebox_override("panel", UI.box(UI.BG_DEEP, 0))
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(bar)
	bar_title = UI.label("", 26, UI.TEXT)
	hud.add_child(bar_title)
	status_label = UI.label("", 22, UI.TEXT)
	hud.add_child(status_label)
	notice_label = UI.label("", 21, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true)
	hud.add_child(notice_label)

# ───────────────────────── 갱신 ─────────────────────────

func _me() -> Dictionary:
	return Net.view.players[Net.seat] if Net.seat >= 0 else {}

func _opp() -> Dictionary:
	return Net.view.players[1 - Net.seat] if Net.seat >= 0 else {}

func _refresh() -> void:
	if not is_inside_tree() or Net.view.is_empty() or Net.seat < 0:
		return
	var v: Dictionary = Net.view
	var me := _me()
	var opp := _opp()
	var sz := size if size.x > 0 else Vector2(720, 1560)
	L = BLayout.compute(sz, mode, int(me.benchMax), int(opp.benchMax), UI.safe_top(self), UI.safe_bottom(self))
	var seen := {}
	_place_side(me, "my", seen)
	if mode == "table":
		_place_side(opp, "opp", seen)
	for sid in slots.keys():
		if not seen.has(sid):
			slots[sid].queue_free()
			slots.erase(sid)
	_place_board(v, me, opp)
	_place_hud(v, me, opp)

## 한쪽 필드: 배틀 + 벤치 (sid 노드 유지), 빈 벤치 칸
func _place_side(p: Dictionary, side: String, seen: Dictionary) -> void:
	var list: Array = []
	list.append([p.get("active"), L[side + "_active"], true])
	var bench: Array = p.bench
	var rects: Array = L[side + "_bench"]
	for i in rects.size():
		list.append([bench[i] if i < bench.size() else null, rects[i], false])
	for i in list.size():
		var s = list[i][0]
		var rect: Rect2 = list[i][1]
		var node: BSlot
		if s != null:
			var sid := str(s.sid)
			seen[sid] = true
			if not slots.has(sid):
				node = BSlot.new()
				node.name = "S_" + sid
				board.add_child(node)
				slots[sid] = node
			node = slots[sid]
		else:
			var key := "%s:%d" % [side, i]
			if not empties.has(key):
				var e := BSlot.new()
				board.add_child(e)
				empties[key] = e
			node = empties[key]
		node.position = rect.position
		node.size = rect.size
		node.set_slot(s, bool(list[i][2]) and mode == "table")
		node.visible = true
	# 칸 수가 줄면 남는 빈 칸 숨김 (벤치 8 → 5)
	for key in empties:
		if key.begins_with(side + ":") and int(key.split(":")[1]) >= list.size():
			empties[key].visible = false

func _place_board(v: Dictionary, me: Dictionary, opp: Dictionary) -> void:
	var table := mode == "table"
	var mid: Control = board.get_node("Mid")
	mid.visible = table
	if table:
		mid.position = L.mid.position
		mid.size = L.mid.size
	var st = v.get("stadium")
	stadium.visible = table and st != null
	if stadium.visible:
		stadium.position = L.stadium.position
		stadium.size = L.stadium.size
		stadium.set_card(str(st.code))
	for side in ["my", "opp"]:
		var p := me if side == "my" else opp
		var show := table
		for k in ["deck", "discard"]:
			var pile: BPile = piles["%s_%s" % [side, k]]
			pile.visible = show
			if not show:
				continue
			var r: Rect2 = L["%s_%s" % [side, k]]
			pile.position = r.position
			pile.size = r.size
			var dis: Array = p.discard
			pile.set_pile(k, int(p.deckCount) if k == "deck" else dis.size(), str(dis[dis.size() - 1].code) if (k == "discard" and dis.size() > 0) else "")
		var pz: Array = p.prizes
		var cards: Array = prize_cards[side]
		for i in 6:
			var c: BCard = cards[i]
			c.visible = show and i < pz.size() and bool(pz[i])
			if c.visible:
				var r: Rect2 = L[side + "_prizes"][i]
				c.position = r.position
				c.size = r.size
				c.set_card("")
	opp_hand.visible = table
	if table:
		opp_hand.position = L.opp_hand.position
		opp_hand.text = "AI  패 %d장 · 사이드 %d" % [int(opp.handCount), _count_true(opp.prizes)]

func _place_hud(v: Dictionary, me: Dictionary, opp: Dictionary) -> void:
	var bar: Control = hud.get_node("Bar")
	bar.position = Vector2(0, 0)
	bar.size = Vector2(size.x, L.bar.position.y + L.bar.size.y)
	var phase := str(v.phase)
	var tp = v.get("turnPlayer")
	var t := "게임 준비 중" if phase == "setup" else ("게임 종료" if phase == "ended" else "턴 %d · %s" % [int(v.turnNumber), "내 차례" if (tp != null and int(tp) == Net.seat) else "상대 차례"])
	bar_title.text = t
	bar_title.position = Vector2(84, L.bar.position.y + 14)
	status_label.visible = mode == "hand"
	notice_label.visible = mode == "hand"
	if mode == "hand":
		status_label.position = L.status.position
		status_label.text = "덱 %d · 사이드 %d · 트래쉬 %d\n상대: 패 %d · 사이드 %d" % [int(me.deckCount), _count_true(me.prizes), (me.discard as Array).size(), int(opp.handCount), _count_true(opp.prizes)]
		notice_label.position = L.notice.position
		notice_label.size = L.notice.size

static func _count_true(arr) -> int:
	var n := 0
	for x in arr:
		if bool(x):
			n += 1
	return n
