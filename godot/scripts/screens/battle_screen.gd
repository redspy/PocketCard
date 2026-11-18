class_name BattleScreen
extends Control
## 새 대전 화면 (docs/ui-pocket-design.md v2)
##  mode "table": AI 연습 — 한 화면 탁자 (상대·내 필드, 사이드·덱·트래쉬, 스타디움, 손패 부채)
##  mode "hand" : 서버 대전 — 게임판은 웹. 폰은 내 포켓몬 작은 줄 + 큰 손패 + 개인 선택
## 상태는 Net.view(내 시점)만 보고 그린다. 포켓몬 칸은 sid 로, 손패는 iid 로 노드를 유지한다.
## 조작: 손패 탭 → 놓을 곳이 맥동 → 그곳 탭 (또는 위로 밀기 = 바로 사용), 내 포켓몬 탭 → 기술·특성·후퇴 말풍선

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
var hand: BHand
var mid: Panel
var opp_hand: Label
var bar_title: Label
var status_label: Label
var notice_label: Label
var chips: Label
var end_btn: TapArea
var stadium_btn: TapArea
var toast: Label

# 조작 상태
var sel_card := ""                  # 고른 손패 iid
var retreat_mode := false           # 후퇴: 벤치를 고르는 중
var targets: Dictionary = {}        # 대상 → 행동: sid / "bench:N" / "zone"
var popover: Control = null
var popover_sid := ""
var sheet: Control = null
var sheet_key := ""
var picks: Dictionary = {}          # 요청 id -> Array
var only_usable := false
var last_sent: Dictionary = {}      # 테스트용: 마지막으로 보낸 입력
var _confirm_end := 0
var menu_btn: TapArea
var speed_btn: TapArea
var auto_btn: TapArea
var auto_play := false              # 자동: 내 차례도 AI 가 둔다 (AI 연습)
var _auto_ai: Callable
var _auto_rng: Array = []
var _auto_wait := -1.0
var _auto_ver := -1
var _toast_tw: Tween

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
		c.name = n
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

## 게임 중 뒤로 가기: 열린 것 닫기 → 그다음은 막음(항복은 메뉴에서)
func on_back() -> bool:
	if popover or sel_card != "" or retreat_mode:
		_clear_select()
		return true
	for c in sheet_layer.get_children():
		if c is BZoom:
			c.queue_free()
			return true
	if Net.solo and Net.view.get("result") != null:
		Net.send({ "t": "rematch" })
		return true
	_toast("게임 중에는 뒤로 갈 수 없습니다. 끝내려면 메뉴에서 항복하세요.")
	return true

func _build_static() -> void:
	mid = Panel.new()
	mid.name = "Mid"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.035)
	sb.set_corner_radius_all(14)
	sb.border_color = UI.ACCENT
	mid.add_theme_stylebox_override("panel", sb)
	mid.mouse_filter = Control.MOUSE_FILTER_STOP
	mid.gui_input.connect(func(e):
		if e is InputEventMouseButton and not e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			tap_zone())
	board.add_child(mid)
	stadium = BCard.new()
	stadium.name = "Stadium"
	stadium.tapped.connect(func(): if stadium.code != "": BZoom.open(sheet_layer, [stadium.code]))
	stadium.long_pressed.connect(func(): if stadium.code != "": BZoom.open(sheet_layer, [stadium.code]))
	board.add_child(stadium)
	for side in ["my", "opp"]:
		for k in ["deck", "discard"]:
			var p := BPile.new()
			p.name = "%s_%s" % [side, k]
			board.add_child(p)
			piles["%s_%s" % [side, k]] = p
			if k == "discard":
				var sd: String = side
				p.card.tapped.connect(func(): open_discard(sd))
				p.card.long_pressed.connect(func(): open_discard(sd))
		var arr: Array = []
		for i in 6:
			var c := BCard.new()
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if side == "my":
				var k := i
				c.tapped.connect(func(): tap_prize(k))
			board.add_child(c)
			arr.append(c)
		prize_cards[side] = arr
	opp_hand = UI.label("", 22, UI.TEXT_DIM)
	board.add_child(opp_hand)
	hand = BHand.new()
	hand.name = "Hand"
	hand.card_tapped.connect(tap_hand)
	hand.card_long.connect(func(iid): _zoom_hand(iid))
	hand.card_swipe_up.connect(swipe_up_hand)
	hand.card_drag_start.connect(_drag_start)
	hand.card_drag.connect(_drag_move)
	hand.card_drag_end.connect(_drag_end)
	board.add_child(hand)
	# 상단 바
	var bar := Panel.new()
	bar.name = "Bar"
	bar.add_theme_stylebox_override("panel", UI.box(UI.BG_DEEP, 0))
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(bar)
	bar_title = UI.label("", 26, UI.TEXT)
	hud.add_child(bar_title)
	menu_btn = UI.button("☰", 30)
	menu_btn.tapped.connect(open_menu)
	hud.add_child(menu_btn)
	speed_btn = UI.button("AI", 20)
	speed_btn.tapped.connect(func(): Net.cycle_ai_speed())
	hud.add_child(speed_btn)
	auto_btn = UI.button("자동", 20)
	auto_btn.tapped.connect(toggle_auto)
	hud.add_child(auto_btn)
	status_label = UI.label("", 22, UI.TEXT)
	hud.add_child(status_label)
	notice_label = UI.label("", 21, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true)
	hud.add_child(notice_label)
	chips = UI.label("", 20, UI.TEXT_DIM)
	hud.add_child(chips)
	end_btn = UI.button("턴 종료", 26, true, true)
	end_btn.tapped.connect(tap_end_turn)
	hud.add_child(end_btn)
	stadium_btn = UI.button("스타디움 효과", 20, true)
	stadium_btn.tapped.connect(tap_stadium_effect)
	hud.add_child(stadium_btn)
	toast = UI.label("", 24, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, true)
	toast.add_theme_stylebox_override("normal", UI.box(Color(0, 0, 0, 0.82), 14))
	toast.modulate.a = 0.0
	hud.add_child(toast)

# ───────────────────────── 보기 도우미 ─────────────────────────

func _me() -> Dictionary:
	return Net.view.players[Net.seat] if Net.seat >= 0 else {}

func _opp() -> Dictionary:
	return Net.view.players[1 - Net.seat] if Net.seat >= 0 else {}

func actions() -> Array:
	var a = Net.view.get("actions")
	return a if a is Array else []

func _moves_for_card(iid: String) -> Array:
	return actions().filter(func(m): return m.get("card") != null and str(m.card) == iid)

func my_request():
	for r in Net.view.get("requests", []):
		if int(r.player) == Net.seat and (r as Dictionary).has("options"):
			return r
	return null

func _my_turn() -> bool:
	var v: Dictionary = Net.view
	return str(v.get("phase")) == "playing" and v.get("turnPlayer") != null and int(v.turnPlayer) == Net.seat

# ───────────────────────── 갱신 ─────────────────────────

func _refresh() -> void:
	# AI 연습에서 다시 하기 → 대전 준비 화면으로
	if Net.solo and str(Net.lobby.get("phase", "game")) != "game" and Nav.current() == self:
		Nav.pop()
		return
	if not is_inside_tree() or Net.view.is_empty() or Net.seat < 0:
		return
	var v: Dictionary = Net.view
	var me := _me()
	var opp := _opp()
	var sz := size if size.x > 0 else Vector2(720, 1560)
	# 벤치 칸 수: 최대치와 실제 수 중 큰 쪽 (스타디움이 떠나 벤치를 줄이는 중에는 잠시 최대치보다 많음)
	L = BLayout.compute(sz, mode, bench_slots(me), bench_slots(opp), UI.safe_top(self), UI.safe_bottom(self))
	var seen := {}
	_place_side(me, "my", seen)
	if mode == "table":
		_place_side(opp, "opp", seen)
	for sid in slots.keys():
		if not seen.has(sid):
			slots[sid].queue_free()
			slots.erase(sid)
	_place_board(v, me, opp)
	_place_hand(me)
	_place_hud(v, me, opp)
	# 고른 카드·후퇴 대상이 더 이상 유효하지 않으면 해제
	if sel_card != "" and (_moves_for_card(sel_card).is_empty() or not _hand_has(sel_card)):
		_clear_select(false)
	if retreat_mode and not actions().any(func(m): return m.kind == "retreat"):
		_clear_select(false)
	if popover and not slots.has(popover_sid):
		_close_popover()
	_apply_marks()
	_build_request()
	_show_error()

func _hand_has(iid: String) -> bool:
	var h = _me().get("hand")
	return h is Array and (h as Array).any(func(x): return str(x.iid) == iid)

## 한쪽 필드: 배틀 + 벤치 (sid 노드 유지), 빈 벤치 칸
func _place_side(p: Dictionary, side: String, seen: Dictionary) -> void:
	var list: Array = []
	list.append([p.get("active"), L[side + "_active"], true, -1])
	var bench: Array = p.bench
	var rects: Array = L[side + "_bench"]
	for i in rects.size():
		list.append([bench[i] if i < bench.size() else null, rects[i], false, i])
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
				node.card.tapped.connect(func(): tap_slot(sid))
				node.card.long_pressed.connect(func(): zoom_slot(sid))
				board.add_child(node)
				slots[sid] = node
			node = slots[sid]
		else:
			var key := "%s:%d" % [side, i]
			if not empties.has(key):
				var e := BSlot.new()
				var bkey := "bench:%d" % int(list[i][3]) if side == "my" else ""
				e.hit.tapped.connect(func(): tap_empty(bkey))
				board.add_child(e)
				empties[key] = e
			node = empties[key]
		node.position = rect.position
		node.size = rect.size
		node.set_slot(s, bool(list[i][2]) and mode == "table")
		node.visible = true
	for key in empties:
		if key.begins_with(side + ":") and int(key.split(":")[1]) >= list.size():
			empties[key].visible = false

func _place_board(v: Dictionary, me: Dictionary, opp: Dictionary) -> void:
	var table := mode == "table"
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
		for k in ["deck", "discard"]:
			var pile: BPile = piles["%s_%s" % [side, k]]
			pile.visible = table
			if not table:
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
			c.visible = table and i < pz.size() and bool(pz[i])
			if c.visible:
				var r: Rect2 = L[side + "_prizes"][i]
				c.position = r.position
				c.size = r.size
				c.set_card("")
	opp_hand.visible = table
	if table:
		opp_hand.position = L.opp_hand.position
		opp_hand.text = "AI  패 %d장 · 사이드 %d" % [int(opp.handCount), _count_true(opp.prizes)]

func _place_hand(me: Dictionary) -> void:
	hand.position = L.hand.position
	hand.size = L.hand.size
	var h: Array = me.get("hand") if me.get("hand") is Array else []
	var use := {}
	var acts := actions()
	for c in h:
		var iid := str(c.iid)
		use[iid] = acts.any(func(m): return m.get("card") != null and str(m.card) == iid)
	if only_usable:
		h = h.filter(func(c): return use.get(str(c.iid), false) or str(c.iid) == sel_card)
	hand.set_hand(h, use, sel_card, L.card)
	hand.visible = sheet == null or not sheet.has_meta("covers_hand")

func _place_hud(v: Dictionary, me: Dictionary, opp: Dictionary) -> void:
	var bar: Control = hud.get_node("Bar")
	bar.position = Vector2(0, 0)
	bar.size = Vector2(size.x, L.bar.position.y + L.bar.size.y)
	var phase := str(v.phase)
	var t := "게임 준비 중" if phase == "setup" else ("게임 종료" if phase == "ended" else "턴 %d · %s" % [int(v.turnNumber), "내 차례" if _my_turn() else "상대 차례"])
	bar_title.text = t
	var by: float = L.bar.position.y
	menu_btn.position = Vector2(8, by + 4)
	bar_title.position = Vector2(84, by + 14)
	var solo := Net.solo
	speed_btn.visible = solo
	auto_btn.visible = solo
	if solo:
		(speed_btn.get_meta("label") as Label).text = "AI %s" % Net.ai_speed_name()
		(auto_btn.get_meta("label") as Label).text = "자동 켜짐" if auto_play else "자동"
		(auto_btn.get_meta("panel") as PanelContainer).add_theme_stylebox_override("panel", _btn_box(auto_play))
		var aw: float = auto_btn.get_combined_minimum_size().x
		var sw: float = speed_btn.get_combined_minimum_size().x
		auto_btn.position = Vector2(size.x - aw - 10, by + 6)
		speed_btn.position = Vector2(auto_btn.position.x - sw - 8, by + 6)
	status_label.visible = mode == "hand"
	notice_label.visible = mode == "hand"
	if mode == "hand":
		status_label.position = L.status.position
		status_label.text = "덱 %d · 사이드 %d · 트래쉬 %d\n상대: 패 %d · 사이드 %d" % [int(me.deckCount), _count_true(me.prizes), (me.discard as Array).size(), int(opp.handCount), _count_true(opp.prizes)]
		notice_label.position = L.notice.position
		notice_label.size = L.notice.size
	# 이번 턴 사용 칩 + 턴 종료
	chips.position = L.chips.position
	if _my_turn():
		var fl: Dictionary = me.flags
		chips.text = "에너지 %s  서포트 %s  후퇴 %s" % ["✔" if fl.energy else "○", "✔" if fl.supporter else "○", "✔" if fl.retreat else "○"]
	else:
		chips.text = ""
	end_btn.position = L.end_turn.position
	var can_end := actions().any(func(m): return m.kind == "endTurn")
	var ended := phase == "ended"
	(end_btn.get_meta("label") as Label).text = "다시 하기" if (ended and Net.solo) else "턴 종료"
	end_btn.visible = not ended or Net.solo
	UI.set_enabled(end_btn, can_end or (ended and Net.solo))
	var st_move := actions().any(func(m): return m.kind == "stadium")
	stadium_btn.visible = st_move
	if st_move:
		stadium_btn.position = L.end_turn.position - Vector2(220, 0)
	toast.size = Vector2(size.x * 0.84, 0)
	toast.position = Vector2(size.x * 0.08, L.bar.position.y + L.bar.size.y + 10)

func _btn_box(on: bool) -> StyleBoxFlat:
	var sb := UI.box(UI.ACCENT if on else UI.PANEL_HI, 16, 0)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	return sb

static func bench_slots(p: Dictionary) -> int:
	return maxi(int(p.benchMax), (p.bench as Array).size())

static func _count_true(arr) -> int:
	var n := 0
	for x in arr:
		if bool(x):
			n += 1
	return n

# ───────────────────────── 고르기·대상 ─────────────────────────

## 지금 강조할 대상들을 칸에 표시
func _apply_marks() -> void:
	var bp_opts: Array = []
	var bp_picks: Array = []
	if not board_pick.is_empty():
		bp_opts = board_pick.req.options
		bp_picks = picks.get(str(board_pick.req.id), [])
	for sid in slots:
		var mk := "target" if targets.has(sid) else ""
		if board_pick.get("kind") == "slots":
			mk = "pick" if bp_picks.has(sid) else ("target" if bp_opts.has(sid) else "dim")
		slots[sid].set_mark(mk)
	for i in 6:
		var pc: BCard = prize_cards["my"][i]
		pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if board_pick.get("kind") == "prizes":
			pc.mouse_filter = Control.MOUSE_FILTER_STOP
			pc.set_mark("pick" if bp_picks.has(str(i)) else ("target" if bp_opts.has(str(i)) else ""))
		else:
			pc.set_mark("")
	for key in empties:
		var e: BSlot = empties[key]
		var bkey := "bench:%s" % key.split(":")[1] if key.begins_with("my:") else ""
		e.set_mark("target" if (bkey != "" and targets.has(bkey)) or (bkey != "" and targets.has("bench")) else "")
	var zone := targets.has("zone")
	var sb := mid.get_theme_stylebox("panel") as StyleBoxFlat
	sb.set_border_width_all(4 if zone else 0)

func _clear_select(refresh := true) -> void:
	sel_card = ""
	retreat_mode = false
	targets = {}
	_close_popover()
	if refresh:
		_place_hand(_me())
		_apply_marks()

## 손패 카드 탭: 고르기 ↔ 해제. 고르면 놓을 곳이 맥동
func tap_hand(iid: String) -> void:
	if my_request() != null:
		return
	_close_popover()
	if sel_card == iid:
		_clear_select()
		return
	_clear_select(false)
	var moves := _moves_for_card(iid)
	if moves.is_empty():
		_toast("지금은 쓸 수 없는 카드입니다." if _my_turn() else "상대 차례입니다.")
		_place_hand(_me())
		return
	sel_card = iid
	targets = {}
	for m in moves:
		if m.get("target") != null:
			targets[str(m.target)] = m
		elif m.kind == "play" and BData.card(hand.codes.get(iid, "")).get("kind") == "pokemon":
			targets["bench"] = m      # 기본 포켓몬: 빈 벤치 칸 아무 데나
			targets["zone"] = m
		else:
			targets["zone"] = m       # 아이템·서포트·스타디움: 가운데(또는 위로 밀기)
	if mode == "hand" and targets.has("zone") and targets.size() == 1:
		# 손패 모드에는 가운데 줄이 없으니 바로 확인 버튼
		_toast("한 번 더 누르거나 위로 밀면 사용: %s" % str(targets.zone.label))
	_place_hand(_me())
	_apply_marks()

## 손패 카드를 위로 밀기: 할 수 있는 행동이 하나면 바로, 아니면 고르기
func swipe_up_hand(iid: String) -> void:
	if my_request() != null:
		return
	var moves := _moves_for_card(iid)
	var untargeted := moves.filter(func(m): return m.get("target") == null)
	if moves.size() == 1 or (untargeted.size() == 1 and moves.size() == untargeted.size()):
		_send_move(moves[0])
	elif untargeted.size() == 1:
		_send_move(untargeted[0])
	elif sel_card != iid:
		tap_hand(iid)

## 가운데(트레이너스 놓는 곳) 탭
func tap_zone() -> void:
	if targets.has("zone"):
		_send_move(targets.zone)
	elif sel_card != "":
		_clear_select()

## 빈 벤치 칸 탭
func tap_empty(bkey: String) -> void:
	if bkey != "" and targets.has("bench"):
		_send_move(targets.bench)
	elif sel_card != "" or retreat_mode:
		_clear_select()

## 포켓몬 칸 탭: 대상이면 실행, 아니면 (내 포켓몬) 말풍선 / (상대) 크게 보기
func tap_slot(sid: String) -> void:
	if not board_pick.is_empty():
		if board_pick.kind == "slots":
			board_pick_tap(sid)
		return
	var req = my_request()
	if req != null:
		return
	if targets.has(sid):
		_send_move(targets[sid])
		return
	if sel_card != "" or retreat_mode:
		_clear_select()
		return
	if popover and popover_sid == sid:
		_close_popover()
		return
	if _is_mine(sid) and _slot_moves(sid).size() > 0:
		open_popover(sid)
	else:
		zoom_slot(sid)

func _is_mine(sid: String) -> bool:
	var me := _me()
	if me.get("active") != null and str(me.active.sid) == sid:
		return true
	return (me.bench as Array).any(func(b): return str(b.sid) == sid)

func _slot_data(sid: String):
	for p in Net.view.players:
		if p.get("active") != null and str(p.active.sid) == sid:
			return p.active
		for b in p.bench:
			if str(b.sid) == sid:
				return b
	return null

func zoom_slot(sid: String) -> BZoom:
	var s = _slot_data(sid)
	if s == null or s.get("stack") == null:
		return null
	var ct := BZoom.slot_codes(s)
	return BZoom.open(sheet_layer, ct[0], 0, ct[1])

func _zoom_hand(iid: String) -> void:
	var codes: Array = hand.order.map(func(i): return hand.codes[i])
	BZoom.open(sheet_layer, codes, hand.order.find(iid))

func open_discard(side: String) -> BZoom:
	var p := _me() if side == "my" else _opp()
	var dis: Array = p.discard
	var codes: Array = []
	for i in range(dis.size() - 1, -1, -1):
		codes.append(str(dis[i].code))
	if codes.is_empty():
		_toast("트래쉬가 비어 있습니다.")
		return null
	return BZoom.open(sheet_layer, codes, 0)

# ───────────────────────── 기술·특성·후퇴 말풍선 ─────────────────────────

## 이 포켓몬으로 할 수 있는 행동 (배틀: 기술·특성·후퇴, 벤치: 특성)
func _slot_moves(sid: String) -> Array:
	var me := _me()
	var is_active: bool = me.get("active") != null and str(me.active.sid) == sid
	var out: Array = []
	for m in actions():
		var k := str(m.kind)
		if k == "ability" and str(m.get("target", "")) == sid:
			out.append(m)
		elif is_active and (k == "attack" or k == "retreat"):
			out.append(m)
	return out

func open_popover(sid: String) -> void:
	_close_popover()
	var s = _slot_data(sid)
	if s == null:
		return
	popover_sid = sid
	var me := _me()
	var is_active: bool = me.get("active") != null and str(me.active.sid) == sid
	var moves := _slot_moves(sid)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UI.box(Color(0.05, 0.08, 0.07, 0.96), 16, 3, UI.ACCENT))
	var mm := UI.margin(12)
	panel.add_child(mm)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	mm.add_child(col)
	var top := str(s.stack[(s.stack as Array).size() - 1].code)
	var data := BData.card(top)
	col.add_child(UI.label(BData.name_of(top), 26, UI.ACCENT))
	# 기술: 카드의 모든 기술을 보여주고, 지금 쓸 수 없는 것은 흐리게
	if is_active:
		var pk = data.get("pokemon")
		var atks: Array = pk.attacks if pk is Dictionary else []
		var opp_act = _opp().get("active")
		var opp_weak := ""
		if opp_act != null and opp_act.get("stack") != null:
			var od = BData.card(str(opp_act.stack[(opp_act.stack as Array).size() - 1].code)).get("pokemon")
			if od is Dictionary and od.get("weak") != null:
				opp_weak = str(od.weak)
		var shown := {}
		for i in atks.size():
			var a: Dictionary = atks[i]
			var mv = GCore.find_first(moves, func(m): return m.kind == "attack" and int(m.input.index) == i)
			shown[i] = true
			var dmg := ""
			if int(a.get("damage", 0)) > 0:
				dmg = "%d%s" % [int(a.damage), str(a.get("op", ""))]
				if pk is Dictionary and opp_weak != "" and opp_weak == str(pk.type):
					dmg += " (약점 ×2)"
			var cost := "".join((a.cost as Array).map(func(c): return BData.TYPE_SHORT.get(str(c), str(c)).left(1)))
			var b := _pop_button("[%s] %s  %s" % [cost, str(a.name) if str(a.name) != "" else str(a.nameJa), dmg], mv != null, mv)
			b.set_meta("attack_index", i)
			col.add_child(b)
		for m in moves:
			if m.kind == "attack" and not shown.has(int(m.input.index)):
				var b2 := _pop_button(str(m.label), true, m)
				b2.set_meta("attack_index", int(m.input.index))
				col.add_child(b2)
	for m in moves:
		if m.kind == "ability":
			var b3 := _pop_button(str(m.label), true, m)
			b3.set_meta("ability", true)
			col.add_child(b3)
	var retreats := moves.filter(func(m): return m.kind == "retreat")
	if not retreats.is_empty():
		var cost := str(retreats[0].label).get_slice("비용 ", 1).trim_suffix(")")
		var rb := _pop_button("후퇴 (비용 %s) → 벤치 포켓몬 고르기" % cost, true, null)
		rb.set_meta("retreat", true)
		rb.tapped.connect(start_retreat)
		col.add_child(rb)
	var zb := _pop_button("크게 보기", true, null)
	zb.tapped.connect(func():
		_close_popover()
		zoom_slot(sid))
	col.add_child(zb)
	hud.add_child(panel)
	popover = panel
	await get_tree().process_frame
	if not is_instance_valid(panel):
		return
	var node: BSlot = slots.get(sid)
	if node == null:
		return
	var w: float = minf(size.x - 28, 560)
	panel.size = Vector2(w, 0)
	var ps := panel.get_combined_minimum_size()
	var y := node.position.y - ps.y - 10
	if y < L.bar.position.y + L.bar.size.y:
		y = node.position.y + node.size.y + 10
	panel.position = Vector2(clampf(node.position.x + node.size.x / 2 - w / 2, 14, size.x - w - 14), clampf(y, 0, size.y - ps.y))

func _pop_button(text: String, enabled: bool, mv) -> TapArea:
	var b := UI.button(text, 22, enabled and mv != null, false)
	(b.get_meta("label") as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	UI.set_enabled(b, enabled)
	if mv != null:
		b.tapped.connect(func(): if UI.is_enabled(b): _send_move(mv))
	b.set_meta("move", mv)
	return b

func _close_popover() -> void:
	if popover:
		popover.queue_free()
	popover = null
	popover_sid = ""

## 말풍선의 버튼들 (테스트용)
func popover_buttons() -> Array:
	if popover == null:
		return []
	return popover.find_children("*", "TapArea", true, false)

func start_retreat() -> void:
	_close_popover()
	retreat_mode = true
	targets = {}
	for m in actions():
		if m.kind == "retreat":
			targets[str(m.target)] = m
	_toast("후퇴: 나올 벤치 포켓몬을 누르세요.")
	_apply_marks()

# ───────────────────────── 턴 종료·스타디움 ─────────────────────────

func tap_end_turn() -> void:
	if str(Net.view.get("phase")) == "ended":
		if Net.solo:
			Net.send({ "t": "rematch" })
		return
	if not UI.is_enabled(end_btn) or my_request() != null:
		return
	var others := actions().any(func(m): return not (m.kind in ["endTurn", "concede"]))
	var now := Time.get_ticks_msec()
	if others and now - _confirm_end > 2500:
		_confirm_end = now
		_toast("한 번 더 누르면 턴을 끝냅니다.")
		return
	_confirm_end = 0
	var m = GCore.find_first(actions(), func(x): return x.kind == "endTurn")
	if m != null:
		_send_move(m)

func tap_stadium_effect() -> void:
	var m = GCore.find_first(actions(), func(x): return x.kind == "stadium")
	if m != null:
		_send_move(m)

# ───────────────────────── 보내기·알림 ─────────────────────────

func _send_move(m: Dictionary) -> void:
	var inp: Dictionary = (m.input as Dictionary).duplicate()
	inp.erase("player")
	send_input(inp)

func send_input(inp: Dictionary) -> void:
	last_sent = inp
	_clear_select(false)
	Net.input(inp)
	Input.vibrate_handheld(10)

func _toast(text: String) -> void:
	toast.text = text
	toast.modulate.a = 1.0
	if _toast_tw:
		_toast_tw.kill()
	_toast_tw = toast.create_tween()
	_toast_tw.tween_interval(2.2)
	_toast_tw.tween_property(toast, "modulate:a", 0.0, 0.4)

var _shown_err := 0

func _show_error() -> void:
	var e: Dictionary = Net.last_error
	if e.is_empty() or int(e.get("at", 0)) == _shown_err:
		return
	_shown_err = int(e.get("at", 0))
	_toast(str(e.get("message", "")))

# ───────────────────────── 선택 요청 (기본 시트 — 4단계에서 탁자 고르기로 확장) ─────────────────────────

func _build_request() -> void:
	var req = my_request()
	var key := ""
	if req != null:
		key = "%s|%s|%s" % [str(req.id), JSON.stringify(picks.get(str(req.id), [])), only_usable]
	if key == sheet_key:
		return
	sheet_key = key
	if sheet:
		sheet.queue_free()
		sheet = null
	board_pick = {}
	if req == null:
		hand.visible = true
		_apply_marks()
		return
	_clear_select(false)
	var kind := BRequest.kind_of(self, req)
	var top_y: float = L.bar.position.y + L.bar.size.y
	if mode == "table" and (kind == "slots" or kind == "prizes"):
		# 탁자에서 직접 고르기: 후보가 맥동, 위에 안내 띠
		board_pick = { "req": req, "kind": kind }
		sheet = BRequest.pick_bar(self, req)
		sheet_layer.add_child(sheet)
		sheet.size = Vector2(size.x - 24, 0)
		sheet.position = Vector2(12, top_y + 6)
		hand.visible = true
		_apply_marks()
		return
	sheet = BRequest.build(self, req)
	sheet_layer.add_child(sheet)
	if kind == "values" or kind == "reveal":
		# 작은 선택(예·아니오·확인 등)은 가운데 대화상자
		await get_tree().process_frame
		if not is_instance_valid(sheet):
			return
		var w: float = minf(size.x - 40, 640)
		sheet.size = Vector2(w, 0)
		var h := sheet.get_combined_minimum_size().y
		sheet.position = Vector2((size.x - w) / 2, clampf((size.y - h) / 2, top_y, size.y - h))
		hand.visible = true
		return
	sheet.set_meta("covers_hand", true)
	hand.visible = false
	sheet.position = Vector2(0, maxf(top_y, size.y * 0.42))
	sheet.size = Vector2(size.x, size.y - sheet.position.y)

var board_pick: Dictionary = {}     # 탁자에서 고르는 중인 요청 { req, kind }

## 탁자 고르기: 포켓몬 또는 사이드 칸을 눌렀을 때
func board_pick_tap(val: String) -> void:
	if board_pick.is_empty():
		return
	var req: Dictionary = board_pick.req
	if not (req.options as Array).has(val):
		_toast("여기는 고를 수 없습니다.")
		return
	if int(req.min) == 1 and int(req.max) == 1:
		choose_now(req, val)
	else:
		toggle_pick(req, val)

func tap_prize(i: int) -> void:
	if not board_pick.is_empty() and board_pick.kind == "prizes":
		board_pick_tap(str(i))

## 요청 안의 고르기 토글
func toggle_pick(req: Dictionary, val: String) -> void:
	var id := str(req.id)
	var p: Array = picks.get(id, [])
	var mx := int(req.max)
	if p.has(val):
		p.erase(val)
	elif mx == 1:
		p = [val]
	elif p.size() < mx:
		p.append(val)
	picks[id] = p
	_build_request()
	_apply_marks()

func confirm_request(req: Dictionary) -> void:
	var id := str(req.id)
	var p: Array = picks.get(id, [])
	var mn := mini(int(req.min), (req.options as Array).size())
	if p.size() < mn or p.size() > int(req.max):
		_toast("%d~%d개를 고르세요." % [mn, int(req.max)])
		return
	picks.erase(id)
	send_input({ "type": "choice", "requestId": id, "picks": p })

func choose_now(req: Dictionary, val: String) -> void:
	send_input({ "type": "choice", "requestId": str(req.id), "picks": [val] })

# ───────────────────────── 끌어 놓기 ─────────────────────────

var drag_ghost: BCard = null
var drag_iid := ""
var drag_hover := ""

var dbg_drag: Dictionary = {}       # 테스트 진단: 마지막 끌기

func _drag_start(iid: String, pos: Vector2) -> void:
	dbg_drag = { "start": iid, "pos": pos }
	if my_request() != null:
		dbg_drag["why"] = "request"
		return
	_close_popover()
	if sel_card != iid:
		tap_hand(iid)
	if sel_card != iid:
		return   # 쓸 수 없는 카드 (tap_hand 가 알림)
	drag_iid = iid
	drag_ghost = BCard.new()
	drag_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_ghost.size = L.card * 0.78
	drag_ghost.set_card(hand.codes.get(iid, ""), true)
	drag_ghost.modulate.a = 0.92
	drag_layer.add_child(drag_ghost)
	if hand.cards.has(iid):
		hand.cards[iid].modulate.a = 0.25
	_drag_move(iid, pos)

func _drag_move(iid: String, pos: Vector2) -> void:
	if drag_ghost == null or iid != drag_iid:
		return
	drag_ghost.position = pos - drag_ghost.size * Vector2(0.5, 0.75)
	drag_ghost.rotation_degrees = clampf((pos.x - size.x / 2) / size.x * 8.0, -6, 6)
	var t := drop_target(pos)
	if t != drag_hover:
		drag_hover = t
		drag_ghost.scale = Vector2(1.08, 1.08) if t != "" else Vector2.ONE

## 놓은 곳(전역 좌표)의 대상 키: 포켓몬 sid / "bench" / "zone" / "" (못 놓는 곳)
func drop_target(pos: Vector2) -> String:
	for key in targets:
		if slots.has(key) and (slots[key] as Control).get_global_rect().grow(10).has_point(pos):
			return key
	if targets.has("bench"):
		for k in empties:
			var e: BSlot = empties[k]
			if k.begins_with("my:") and e.visible and e.get_global_rect().grow(10).has_point(pos):
				return "bench"
	if targets.has("zone"):
		# 가운데 줄(탁자) 또는 손패보다 위 아무 곳 (포켓몬 위가 아니면)
		var above_hand := pos.y < hand.global_position.y - 10
		var on_slot := slots.values().any(func(n): return (n as Control).get_global_rect().has_point(pos))
		if (mode == "table" and mid.get_global_rect().grow(16).has_point(pos)) or (above_hand and not on_slot):
			return "zone"
	if targets.has("bench") and pos.y < hand.global_position.y - 10:
		var on_slot2 := slots.values().any(func(n): return (n as Control).get_global_rect().has_point(pos))
		if not on_slot2:
			return "bench"
	return ""

func _drag_end(iid: String, pos: Vector2) -> void:
	if iid != drag_iid:
		return
	var t := drop_target(pos)
	dbg_drag["end"] = pos
	dbg_drag["t"] = t
	dbg_drag["targets"] = targets.keys()
	dbg_drag["rects"] = targets.keys().filter(func(k): return slots.has(k)).map(func(k): return str((slots[k] as Control).get_global_rect()))
	if drag_ghost:
		drag_ghost.queue_free()
	drag_ghost = null
	drag_iid = ""
	drag_hover = ""
	if hand.cards.has(iid):
		hand.cards[iid].modulate.a = 1.0
	if t != "" and targets.has(t):
		_send_move(targets[t])
		return
	if pos.y < hand.global_position.y - 10:
		_toast(_why_not(iid))
	_clear_select()

## 못 놓는 곳에 놓았을 때 안내 (어디에 놓을 수 있는지)
func _why_not(iid: String) -> String:
	var moves := _moves_for_card(iid)
	if moves.is_empty():
		return "지금은 쓸 수 없는 카드입니다."
	var names: Array = []
	for m in moves:
		if m.get("target") != null:
			var s = _slot_data(str(m.target))
			if s != null and s.get("stack") != null:
				names.append(BData.name_of(str(s.stack[(s.stack as Array).size() - 1].code)))
	if not names.is_empty():
		return "여기에는 놓을 수 없습니다. 놓을 수 있는 포켓몬: %s" % ", ".join(names)
	return "여기에는 놓을 수 없습니다."

# ───────────────────────── 메뉴 · 로그 · 항복 ─────────────────────────

var menu: Control = null
var _concede_armed := 0

func _sheet_panel(title: String) -> VBoxContainer:
	close_menu()
	var root := PanelContainer.new()
	root.add_theme_stylebox_override("panel", UI.box(Color(0.04, 0.09, 0.07, 0.97), 22, 3, UI.ACCENT))
	var mm := UI.margin(18)
	root.add_child(mm)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	mm.add_child(col)
	var head := HBoxContainer.new()
	var tl := UI.label(title, 30, UI.ACCENT)
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(tl)
	var x := UI.button("닫기", 22)
	x.set_meta("close", true)
	x.tapped.connect(close_menu)
	head.add_child(x)
	col.add_child(head)
	hud.add_child(root)
	menu = root
	root.position = Vector2(16, L.bar.position.y + L.bar.size.y + 8)
	root.size = Vector2(size.x - 32, 0)
	return col

func close_menu() -> void:
	if menu:
		menu.queue_free()
	menu = null

func open_menu() -> void:
	var col := _sheet_panel("메뉴")
	var items := [
		["로그 보기", open_log],
		["내 트래쉬 (%d장)" % (_me().discard as Array).size(), func():
			close_menu()
			open_discard("my")],
		["상대 트래쉬 (%d장)" % (_opp().discard as Array).size(), func():
			close_menu()
			open_discard("opp")],
	]
	for it in items:
		var b := UI.button(it[0], 26)
		b.set_meta("item", it[0])
		b.tapped.connect(it[1])
		col.add_child(b)
	if actions().any(func(m): return m.kind == "concede"):
		var cb := UI.button("항복", 26)
		cb.set_meta("item", "항복")
		cb.tapped.connect(func(): tap_concede(cb))
		col.add_child(cb)

## 항복: 두 번 눌러야 (첫 번째는 확인 문구)
func tap_concede(b: TapArea) -> void:
	var now := Time.get_ticks_msec()
	if now - _concede_armed > 3000:
		_concede_armed = now
		(b.get_meta("label") as Label).text = "정말 항복할까요? 한 번 더 누르세요"
		(b.get_meta("panel") as PanelContainer).add_theme_stylebox_override("panel", UI.box(Color(0.75, 0.22, 0.2), 16))
		return
	_concede_armed = 0
	close_menu()
	var m = GCore.find_first(actions(), func(x): return x.kind == "concede")
	if m != null:
		_send_move(m)

func open_log() -> void:
	var col := _sheet_panel("로그")
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, size.y * 0.6)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var lines := VBoxContainer.new()
	lines.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(lines)
	for l in BLog.recent(Net.events_log, Net.seat, 200):
		var lab := UI.label(l, 22, UI.TEXT if not l.begins_with(" ") else UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true)
		lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lines.add_child(lab)
	col.add_child(sc)
	menu.set_meta("log_lines", lines.get_child_count())

# ───────────────────────── 자동 진행 (AI 연습) ─────────────────────────

func toggle_auto() -> void:
	auto_play = not auto_play
	if auto_play and not _auto_ai.is_valid():
		var d := LocalGame.data()
		_auto_ai = GBot.makeAiBot(d.cat, d.info.db)
		_auto_rng = GRng.seedRng("%08x" % (randi() & 0xFFFFFFFF))
	_auto_ver = -1
	_toast("자동 진행 켜짐 — 내 차례도 AI 가 둡니다." if auto_play else "자동 진행 꺼짐")
	_refresh()

func _process(delta: float) -> void:
	# AI 연습 다시 하기 → 대전 준비 (화면 전환 중에 신호가 오면 놓칠 수 있어 매 프레임 확인)
	if Net.solo and str(Net.lobby.get("phase", "game")) != "game" and Nav.current() == self and not Nav._busy:
		Nav.pop()
		return
	if not auto_play or Net.view.is_empty():
		return
	var v: Dictionary = Net.view
	if v.get("result") != null or not GBot.botHasWork(v):
		_auto_wait = -1.0
		return
	if int(v.version) == _auto_ver:
		return
	if _auto_wait < 0.0:
		_auto_wait = maxf(0.25, Net.ai_delay() / 1000.0)
	_auto_wait -= delta
	if _auto_wait > 0.0:
		return
	_auto_wait = -1.0
	_auto_ver = int(v.version)
	var inp = _auto_ai.call(v.duplicate(true), _auto_rng)
	if inp != null:
		send_input(inp)
