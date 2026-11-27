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
var lost_tags: Dictionary = {}      # "my"/"opp" -> 로스트존 장수 버튼 (0장이면 숨김, 누르면 크게 보기)
var marker_tags: Dictionary = {}    # "my"/"opp" -> "GX·VSTAR 사용함" 표시
var prize_cards: Dictionary = {}    # "my"/"opp" -> Array[BCard]
var stadium: BCard
var stadium_name: Label
var recent_tiles: Array = []        # 탁자: 가운데 띠 왼쪽 최근 행동 카드 타일 (BCard)
var recent_evs: Array = []          # 타일에 보이는 사건 (최근 것부터)
var hand: BHand
var mid: Panel
var opp_hand: Label
var bar_title: Label
var status_label: Label
var notice_label: Label
var chips: Label
var end_btn: TapArea
var stadium_btn: TapArea
var use_btn: TapArea               # 대상이 없는 카드(아이템·서포트 등)를 고르면 뜨는 [사용]
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
var only_usable := false           # "고를 수 있는 카드만" — 지금 선택(요청) 하나에만 적용, 선택이 바뀌거나 끝나면 꺼짐
var _usable_req := ""
var last_sent: Dictionary = {}      # 테스트용: 마지막으로 보낸 입력
var _confirm_end := 0
var fx: BFx
var _fed_version := -1
var menu_btn: TapArea
var speed_btn: TapArea
var auto_btn: TapArea
var auto_play := false              # 자동: 내 차례도 AI 가 둔다 (AI 연습)
var _auto_ai: Callable
var _auto_rng: Array = []
var _auto_wait := -1.0
var _auto_ver := -1
var _toast_tw: Tween
var end_hint := false               # 남은 수가 턴 종료뿐 → [턴 종료] 맥동 (하스스톤식)
var _end_tw: Tween
var peek_btn: TapArea               # 선택 창 위 [판 보기]: 창을 잠깐 접고 판을 본다 (취소는 아님)
var peek_back: TapArea              # 판 보기 중 아래 [선택으로 돌아가기]
var peeking := false

func _init(m := "") -> void:
	mode = m

func _ready() -> void:
	if mode == "":
		mode = "table" if Net.no_board() else "hand"
	var bg := ColorRect.new()
	bg.color = UI.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	# 손패 카드는 겹침 순서로 z_index(최대 100)를 쓰므로, 위 레이어는 그보다 높여야 손패에 안 가림
	var layer_z := { "board": 0, "hud": 0, "sheet_layer": 200, "fx_layer": 300, "drag_layer": 400 }
	for n in ["board", "hud", "sheet_layer", "fx_layer", "drag_layer"]:
		var c := Control.new()
		c.name = n
		c.z_index = layer_z[n]
		c.set_anchors_preset(Control.PRESET_FULL_RECT)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(c)
		set(n, c)
	_build_static()
	fx = BFx.new(self)
	add_child(fx)
	fx.start_from_now()
	Net.changed.connect(_refresh)
	resized.connect(_refresh)
	_refresh()

func _exit_tree() -> void:
	Net.fx_busy = false   # 연출 도중 화면이 닫혀도 AI 가 멈추지 않게
	if Net.changed.is_connected(_refresh):
		Net.changed.disconnect(_refresh)

## 게임 중 뒤로 가기: 열린 것 닫기 → 그다음은 막음(항복은 메뉴에서)
func on_back() -> bool:
	if peeking:
		set_peek(false)
		return true
	if popover or sel_card != "" or retreat_mode:
		_clear_select()
		return true
	for c in sheet_layer.get_children():
		if c is BZoom:
			c.queue_free()
			return true
	if Net.can_rematch() and Net.view.get("result") != null:
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
	stadium_name = UI.label("", 20, UI.TEXT_DIM)
	board.add_child(stadium_name)
	for i in RECENT_MAX:
		var t := BCard.new()
		t.name = "recent_%d" % i
		var k := i
		t.tapped.connect(func(): open_recent(k))
		t.long_pressed.connect(func(): open_recent(k))
		var fr := Panel.new()
		fr.name = "frame"
		fr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fr.set_anchors_preset(Control.PRESET_FULL_RECT)
		t.add_child(fr)
		t.visible = false
		board.add_child(t)
		recent_tiles.append(t)
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
		var lt := UI.button("로스트 0", 18)
		var lsd: String = side
		lt.tapped.connect(func(): open_lost(lsd))
		lt.visible = false
		board.add_child(lt)
		lost_tags[side] = lt
		var mk := UI.label("", 16, Color(0.95, 0.8, 0.45), HORIZONTAL_ALIGNMENT_LEFT)
		mk.visible = false
		board.add_child(mk)
		marker_tags[side] = mk
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
	# 손패 모드: 상대 행동 알림을 누르면 최근 기록
	notice_label.mouse_filter = Control.MOUSE_FILTER_STOP
	notice_label.gui_input.connect(func(e):
		if e is InputEventMouseButton and not e.pressed and e.button_index == MOUSE_BUTTON_LEFT and notice_label.text != "":
			open_log())
	chips = UI.label("", 20, UI.TEXT_DIM)
	hud.add_child(chips)
	end_btn = UI.button("턴 종료", 26, true, true)
	end_btn.tapped.connect(tap_end_turn)
	hud.add_child(end_btn)
	use_btn = UI.button("사용", 28, true, true)
	use_btn.set_meta("use", true)
	use_btn.tapped.connect(tap_zone)
	use_btn.visible = false
	hud.add_child(use_btn)
	stadium_btn = UI.button("스타디움 효과", 20, true)
	stadium_btn.tapped.connect(tap_stadium_effect)
	hud.add_child(stadium_btn)
	peek_btn = UI.button("판 보기", 20)
	peek_btn.tapped.connect(func(): set_peek(true))
	peek_btn.visible = false
	sheet_layer.add_child(peek_btn)
	peek_back = UI.button("▲ 선택으로 돌아가기", 24, true, true)
	peek_back.tapped.connect(func(): set_peek(false))
	peek_back.visible = false
	sheet_layer.add_child(peek_back)
	toast = UI.label("", 24, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, true)
	var tsb := UI.box(Color(0.02, 0.04, 0.03, 0.94), 14, 2, Color(1, 1, 1, 0.18))
	tsb.content_margin_left = 14
	tsb.content_margin_right = 14
	tsb.content_margin_top = 8
	tsb.content_margin_bottom = 8
	toast.add_theme_stylebox_override("normal", tsb)
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
	if Net.can_rematch() and str(Net.lobby.get("phase", "game")) != "game" and Nav.current() == self:
		Nav.pop()
		return
	if not is_inside_tree() or Net.view.is_empty() or Net.seat < 0:
		return
	var v: Dictionary = Net.view
	# 새 상태가 오면 새 사건을 연출 큐에 (HP 지연 표시·기절 칸 유지가 먼저 정해져야 해서 그리기 전에)
	if fx and int(v.version) != _fed_version:
		_fed_version = int(v.version)
		fx.feed()
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
		if not seen.has(sid) and not (fx and fx.hold.has(sid)):
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
	_update_result()

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
			# 포켓몬이 있는 칸의 빈 칸 틀은 숨긴다 (안 그러면 칸 수가 바뀔 때 옛 틀이 뒤에 남음)
			var ekey := "%s:%d" % [side, i]
			if empties.has(ekey):
				empties[ekey].visible = false
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
		# 자리가 바뀌면(후퇴·교체·벤치 당김) 미끄러지듯 이동
		if s != null and node.has_meta("placed") and fx and fx.speed() > 0.0 and node.position.distance_to(rect.position) > 1.0:
			BattleScreen.move_node(node, rect.position, 0.22 / fx.speed())
		else:
			BattleScreen.move_node(node, rect.position, 0.0)
		node.set_meta("placed", true)
		node.size = rect.size
		node.set_slot(s, bool(list[i][2]) and mode == "table")
		if s != null and fx:
			var pend := int(fx.pending_hp.get(str(s.sid), 0))
			node.show_hp(clampi(node.real_left() + pend, 0, node.max_hp()) if pend != 0 else -1)
		node.visible = true
		# 배틀 포켓몬은 맨 나중에 그린다: 카드 위 바깥의 약점·저항 표시가 위 줄(상대 벤치) 카드에 가리지 않게
		if bool(list[i][2]) and s != null:
			board.move_child(node, -1)
	for key in empties:
		if key.begins_with(side + ":") and int(key.split(":")[1]) >= list.size():
			empties[key].visible = false

# ───────────────────────── 최근 행동 타일 (탁자) ─────────────────────────

const RECENT_MAX := 5
const RECENT_MINE := Color(0.96, 0.77, 0.26)
const RECENT_OPP := Color(0.95, 0.45, 0.4)

## 연출까지 끝난 카드 사용·기술·특성 (최근 것부터, 에너지 붙이기는 제외 — 매 턴 있어 정보가 적음)
func recent_events() -> Array:
	var out: Array = []
	var upto: int = fx.played_seq if fx else 1 << 30
	for i in range(Net.events_log.size() - 1, -1, -1):
		var e: Dictionary = Net.events_log[i]
		if int(e.get("seq", -1)) > upto:
			continue
		var t := str(e.get("type", ""))
		if not (t in ["play", "attack", "ability"]) or str(e.get("code", "")) == "":
			continue
		if t == "play" and str(e.get("what", "")) == "에너지 붙이기":
			continue
		out.append(e)
		if out.size() >= RECENT_MAX:
			break
	return out

func _place_recent() -> void:
	var table := mode == "table"
	recent_evs = recent_events() if table else []
	var m: Rect2 = L.get("mid", Rect2())
	var h: float = m.size.y - 8
	var w: float = h / UI.CARD_RATIO
	var right: float = (L.stadium as Rect2).position.x - 10 if L.has("stadium") else m.end.x
	var fit := int(floor((right - m.position.x - 4 + 6) / (w + 6)))
	for i in RECENT_MAX:
		var t: BCard = recent_tiles[i]
		t.visible = table and i < recent_evs.size() and i < fit
		if not t.visible:
			continue
		var e: Dictionary = recent_evs[i]
		t.position = Vector2(m.position.x + 4 + i * (w + 6), m.position.y + 4)
		t.size = Vector2(w, h)
		t.set_card(str(e.code))
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0)
		sb.border_color = RECENT_MINE if int(e.get("player", -1)) == Net.seat else RECENT_OPP
		sb.set_border_width_all(3)
		sb.set_corner_radius_all(6)
		(t.get_node("frame") as Panel).add_theme_stylebox_override("panel", sb)
		t.modulate.a = 1.0 if i == 0 else 0.85

## 타일 탭: 최근 행동 카드들을 크게 (설명 = 기록 한 줄)
func open_recent(i: int) -> BZoom:
	if i >= recent_evs.size():
		return null
	var codes: Array = recent_evs.map(func(e): return str(e.code))
	var tags: Array = recent_evs.map(func(e): return BLog.line(e, Net.seat).strip_edges())
	return BZoom.open(sheet_layer, codes, i, tags)

func _place_board(v: Dictionary, me: Dictionary, opp: Dictionary) -> void:
	_place_recent()
	var table := mode == "table"
	mid.visible = table
	if table:
		mid.position = L.mid.position
		mid.size = L.mid.size
	var st = v.get("stadium")
	stadium.visible = table and st != null
	stadium_name.visible = false
	if stadium.visible:
		# 스타디움은 가운데 줄에 가로로 눕혀 (탁자 위 실물처럼) + 이름
		var r: Rect2 = L.stadium
		stadium.size = Vector2(r.size.y, r.size.x)
		stadium.pivot_offset = stadium.size / 2
		stadium.rotation_degrees = 90
		stadium.position = r.position + (r.size - stadium.size) / 2
		stadium.set_card(str(st.code))
		stadium_name.visible = true
		stadium_name.text = "스타디움: %s" % BData.name_of(str(st.code))
		stadium_name.position = Vector2(r.position.x + r.size.x + 14, r.position.y + r.size.y / 2 - 14)
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
		# 로스트존 (공개): 트래쉬 아래 장수, 누르면 크게 보기
		var lost_n: int = (p.get("lost", []) as Array).size()
		var lt: TapArea = lost_tags[side]
		lt.visible = table and lost_n > 0
		if lt.visible:
			(lt.get_meta("label") as Label).text = "로스트 %d" % lost_n
			var dr: Rect2 = L[side + "_discard"]
			var lsz: Vector2 = lt.get_combined_minimum_size()
			lt.position = Vector2(dr.position.x - lsz.x - 8, dr.position.y + (dr.size.y - lsz.y) / 2)
		# GX 기술·VSTAR 파워 사용 기록 (대전 중 1번): 사이드 아래
		var used: Array = []
		if bool(p.get("gxUsed", false)):
			used.append("GX")
		if bool(p.get("vstarUsed", false)):
			used.append("VSTAR")
		var mk: Label = marker_tags[side]
		mk.visible = table and not used.is_empty()
		if mk.visible:
			mk.text = "%s 사용함" % "·".join(used)
			var pb: Rect2 = L[side + "_prizes_box"]
			mk.position = Vector2(pb.position.x, pb.position.y + pb.size.y + 2)
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
		opp_hand.text = "%s  패 %d장 · 사이드 %d" % [opp_name(), int(opp.handCount), _count_true(opp.prizes)]

func _place_hand(me: Dictionary) -> void:
	hand.position = L.hand.position
	hand.size = L.hand.size
	var h: Array = me.get("hand") if me.get("hand") is Array else []
	var use := {}
	var acts := actions()
	for c in h:
		var iid := str(c.iid)
		use[iid] = acts.any(func(m): return m.get("card") != null and str(m.card) == iid)
	var hp_opts: Array = []
	var hp_picks: Array = []
	if board_pick.get("kind") == "handpick":
		hp_opts = board_pick.req.options
		hp_picks = picks.get(str(board_pick.req.id), [])
		for c in h:
			use[str(c.iid)] = hp_opts.has(str(c.iid))
	if only_usable and board_pick.get("kind") == "handpick":
		h = h.filter(func(c): return use.get(str(c.iid), false) or str(c.iid) == sel_card)
	hand.set_hand(h, use, sel_card, L.card)
	for iid in hp_picks:
		if hand.cards.has(iid):
			hand.cards[iid].set_mark("pick")
	if not hp_opts.is_empty():
		for c in h:
			if hp_opts.has(str(c.iid)) and not hp_picks.has(str(c.iid)):
				hand.cards[str(c.iid)].set_mark("target")
	hand.visible = sheet == null or not sheet.has_meta("covers_hand") or peeking

func _place_hud(v: Dictionary, me: Dictionary, opp: Dictionary) -> void:
	var bar: Control = hud.get_node("Bar")
	bar.position = Vector2(0, 0)
	bar.size = Vector2(size.x, L.bar.position.y + L.bar.size.y)
	var phase := str(v.phase)
	var t := "게임 준비 중" if phase == "setup" else ("게임 종료" if phase == "ended" else "턴 %d · %s" % [int(v.turnNumber), "내 차례" if _my_turn() else "상대 차례"])
	# 탁자 모드에는 상태 줄이 없으므로 연결 상태는 제목에 (폰끼리 대전·서버 대전)
	if phase != "ended":
		if Net.status != "open" and not Net.offline:
			t += " · 재접속 중…"
		elif bool(Net.lobby.get("paused", false)):
			t += " · 상대 재접속 대기"
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
		var conn := ""
		if Net.status != "open":
			conn = "  · 재접속 중…"
		elif bool(Net.lobby.get("paused", false)):
			conn = "  · 상대 재접속 대기"
		var my_deck := "덱 %d%s" % [int(me.deckCount), " ⚠" if int(me.deckCount) <= BPile.LOW_DECK else ""]
		var opp_deck := (" · 덱 %d ⚠" % int(opp.deckCount)) if int(opp.deckCount) <= BPile.LOW_DECK else ""
		var my_lost_n: int = (me.get("lost", []) as Array).size()
		var opp_lost_n: int = (opp.get("lost", []) as Array).size()
		var my_lost := (" · 로스트 %d" % my_lost_n) if my_lost_n > 0 else ""
		var opp_lost := (" · 로스트 %d" % opp_lost_n) if opp_lost_n > 0 else ""
		status_label.text = "%s · 사이드 %d · 트래쉬 %d%s%s\n상대: 패 %d · 사이드 %d%s%s · 큰 화면은 게임판에서" % [my_deck, _count_true(me.prizes), (me.discard as Array).size(), my_lost, conn, int(opp.handCount), _count_true(opp.prizes), opp_deck, opp_lost]
		notice_label.position = L.notice.position
		notice_label.size = L.notice.size
	# 이번 턴 사용 칩 + 턴 종료
	chips.position = L.chips.position
	if _my_turn():
		var fl: Dictionary = me.flags
		chips.text = "에너지 %s  서포트 %s  후퇴 %s" % ["✔" if fl.energy else "○", "✔" if fl.supporter else "○", "✔" if fl.retreat else "○"]
	else:
		chips.text = thinking_text()
	end_btn.position = L.end_turn.position
	var can_end := actions().any(func(m): return m.kind == "endTurn")
	var ended := phase == "ended"
	(end_btn.get_meta("label") as Label).text = "다시 하기" if (ended and Net.can_rematch()) else "턴 종료"
	end_btn.visible = not ended or Net.can_rematch()
	UI.set_enabled(end_btn, can_end or (ended and Net.can_rematch()))
	_set_end_hint(can_end and _my_turn() and my_request() == null and BHint.only_end_left(actions()))
	var st_move := actions().any(func(m): return m.kind == "stadium")
	stadium_btn.visible = st_move
	if st_move:
		stadium_btn.position = L.end_turn.position - Vector2(220, 0)
		var chips_end: float = chips.position.x + chips.get_combined_minimum_size().x + 12
		if stadium_btn.position.x < chips_end + 12:
			stadium_btn.position = Vector2(L.end_turn.position.x + L.end_turn.size.x - stadium_btn.get_combined_minimum_size().x, L.end_turn.position.y - stadium_btn.get_combined_minimum_size().y - 10)
	# 탁자: 위쪽 상대 정보 줄을 통째로 덮는다 (반쯤 걸치면 글자가 삐져나와 지저분)
	toast.size = Vector2(size.x * 0.84 if mode == "hand" else size.x - 24, 0)
	var ty: float = (L.center.position.y + 10) if mode == "hand" else (L.bar.position.y + L.bar.size.y + 10)
	toast.position = Vector2(size.x * 0.08 if mode == "hand" else 12.0, ty if mode == "hand" else ty - 6)

## 상대를 부르는 말: AI 연습이면 "AI", 사람끼리면 "상대"
static func opp_name() -> String:
	return "AI" if Net.solo else "상대"

## 상대 차례에 연출이 없고 내가 고를 것도 없으면 "생각 중…" (상대 손패를 만지는 모습은 보여 주지 않음)
func thinking_text() -> String:
	var v: Dictionary = Net.view
	if str(v.get("phase")) != "playing" or v.get("turnPlayer") == null or _my_turn():
		return ""
	if my_request() != null or (fx and fx.busy()):
		return ""
	return "AI 생각 중…" if Net.solo else "상대 생각 중…"

## 할 수 있는 게 턴 종료뿐이면 버튼이 천천히 맥동 (누르라고 알려 줄 뿐, 강제는 아님)
func _set_end_hint(on: bool) -> void:
	if on == end_hint:
		return
	end_hint = on
	var p := end_btn.get_meta("panel") as Control
	if _end_tw:
		_end_tw.kill()
		_end_tw = null
	p.self_modulate = Color.WHITE
	p.scale = Vector2.ONE
	if on:
		p.pivot_offset = p.size / 2
		_end_tw = p.create_tween().set_loops().set_trans(Tween.TRANS_SINE)
		_end_tw.tween_property(p, "scale", Vector2(1.08, 1.08), 0.55)
		_end_tw.parallel().tween_property(p, "self_modulate", Color(1.25, 1.25, 1.1), 0.55)
		_end_tw.tween_property(p, "scale", Vector2.ONE, 0.55)
		_end_tw.parallel().tween_property(p, "self_modulate", Color.WHITE, 0.55)

func _btn_box(on: bool) -> StyleBoxFlat:
	var sb := UI.box(UI.ACCENT if on else UI.PANEL_HI, 16, 0)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	return sb

## 칸의 위치 이동은 한 번에 하나만 (흔들기·돌진·자리 이동이 겹쳐 엉뚱한 곳에 멈추지 않게). 목표 위치를 meta 로 기억
static func move_node(node: Control, pos: Vector2, dur: float) -> void:
	var old = node.get_meta("pos_tw") if node.has_meta("pos_tw") else null
	var running: bool = old is Tween and (old as Tween).is_valid() and (old as Tween).is_running()
	# 같은 목표로 이미 움직이는 중이면 그대로 둔다 (다시 그릴 때마다 처음부터 다시 움직이지 않게)
	if running and node.has_meta("target_pos") and (node.get_meta("target_pos") as Vector2).distance_to(pos) < 0.5 and dur > 0.0:
		return
	if old is Tween and (old as Tween).is_valid():
		(old as Tween).kill()
	node.set_meta("target_pos", pos)
	if dur <= 0.0:
		node.position = pos
		return
	var tw := node.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "position", pos, dur)
	node.set_meta("pos_tw", tw)

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
	var acts := actions()
	var idle := board_pick.is_empty() and sel_card == "" and not retreat_mode and _my_turn() and my_request() == null
	var me := _me()
	var active_sid := str(me.active.sid) if not me.is_empty() and me.get("active") != null else ""
	for sid in slots:
		var mk := "target" if targets.has(sid) else ""
		if mk == "" and idle and BHint.slot_ready(acts, sid, active_sid):
			mk = "ready"     # 기술·특성·후퇴를 지금 쓸 수 있는 내 포켓몬 (하스스톤의 초록 틀)
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
	if board_pick.get("kind") == "handpick":
		var rk := str(board_pick.req.kind)
		for key in empties:
			var e2: BSlot = empties[key]
			if key == "my:0" and rk == "chooseActive":
				e2.set_mark("target")
			elif key.begins_with("my:") and key != "my:0" and rk == "chooseBench":
				e2.set_mark("target")
	var zone := targets.has("zone")
	# 고른 카드에 대상 없는 쓰기가 있으면 손패 위에 [사용] (끌어 올려도 됨)
	use_btn.visible = zone and sel_card != ""
	if use_btn.visible:
		var lab := str(targets.zone.label)
		(use_btn.get_meta("label") as Label).text = "사용: " + (lab.trim_suffix(" 사용") if not lab.ends_with("벤치에 내기") else lab)
		var w := use_btn.get_combined_minimum_size().x
		use_btn.position = Vector2((size.x - w) / 2, hand.position.y - use_btn.get_combined_minimum_size().y - 64)
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
	if board_pick.get("kind") == "handpick":
		board_pick_tap(iid)
		return
	if my_request() != null:
		return
	_close_popover()
	if sel_card == iid:
		_clear_select()
		return
	_clear_select(false)
	var moves := _moves_for_card(iid)
	if moves.is_empty():
		_toast(BHint.why_unusable(Net.view, Net.seat, str(hand.codes.get(iid, ""))))
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
		if peeking:
			zoom_slot(sid)
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
		if _is_mine(sid) and _my_turn():
			var why := _ability_why(sid)
			if why != "":
				_toast(why)
		zoom_slot(sid)

## 내 포켓몬의 특성을 지금 못 쓰는 이유 (조건이 있는 특성만, 없으면 "")
func _ability_why(sid: String) -> String:
	var s = _slot_data(sid)
	if s == null or s.get("stack") == null or (s.stack as Array).is_empty():
		return ""
	var pk = BData.card(str(s.stack[(s.stack as Array).size() - 1].code)).get("pokemon")
	if not (pk is Dictionary) or (pk.get("abilities", []) as Array).is_empty():
		return ""
	var me := _me()
	var is_active: bool = me.get("active") != null and str(me.active.sid) == sid
	return BHint.ability_unusable(str(pk.abilities[0].get("name", "")), is_active)

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

## 로스트존 크게 보기 (최근 것부터)
func open_lost(side: String) -> BZoom:
	var p := _me() if side == "my" else _opp()
	var lost: Array = p.get("lost", [])
	var codes: Array = []
	for i in range(lost.size() - 1, -1, -1):
		codes.append(str(lost[i].code))
	if codes.is_empty():
		return null
	return BZoom.open(sheet_layer, codes, 0, codes.map(func(_c): return "로스트존 (게임에서 제외된 카드)"))

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
			var b := _pop_button("%s%s  %s" % [("[%s] " % cost) if cost != "" else "", str(a.name) if str(a.name) != "" else str(a.nameJa), dmg], mv != null, mv)
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
	var below := node.position.y + node.size.y + 10
	# 배틀 포켓몬: 아래(내 벤치 쪽)에 띄운다 — 위로 띄우면 기술을 고를 때 봐야 할 상대 배틀 포켓몬을 가린다
	if (is_active and below + ps.y <= size.y - 8) or y < L.bar.position.y + L.bar.size.y:
		y = below
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
		if Net.can_rematch():
			Net.send({ "t": "rematch" })
		return
	if not UI.is_enabled(end_btn) or my_request() != null:
		return
	var others := not BHint.only_end_left(actions())
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

## 손패 모드: 상대 행동 한 줄 알림 (최근 2줄)
var _notices: Array = []

func notify(text: String) -> void:
	if text == "":
		return
	_notices.push_front(text)
	_notices = _notices.slice(0, 2)
	notice_label.text = "\n".join(_notices)

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
	_toast(my_words(str(e.get("message", ""))))

# ───────────────────────── 선택 요청 (기본 시트 — 4단계에서 탁자 고르기로 확장) ─────────────────────────

## 화면에 띄울 선택 요청: 새 요청은 앞선 연출이 끝난 뒤에 (기절 연출 전에 "사이드를 가져가세요"가 먼저 뜨지 않게).
## 이미 떠 있는 요청은 연출 중에도 그대로 둔다. 탁자 모드만 (손패 모드는 큰 연출이 웹 게임판에 있어 바로 띄움)
func shown_request():
	var r = my_request()
	if r != null and mode == "table" and fx and fx.busy() and not sheet_key.begins_with(str(r.id) + "|"):
		return null
	return r

func _build_request() -> void:
	var req = shown_request()
	var rid := str(req.id) if req != null else ""
	if rid != _usable_req:
		_usable_req = rid
		if only_usable:
			only_usable = false
			# 손패는 이 함수보다 먼저 그려졌으므로 선택 정리가 끝난 뒤 한 번 더 (전체 손패로)
			(func(): if is_inside_tree() and not Net.view.is_empty(): _place_hand(_me())).call_deferred()
	var key := ""
	if req != null:
		key = "%s|%s|%s|%s" % [str(req.id), JSON.stringify(picks.get(str(req.id), [])), only_usable, size]   # 화면 크기가 바뀌면(폴드 접기·펴기) 다시 그림
	if key == sheet_key:
		return
	sheet_key = key
	if sheet:
		sheet.queue_free()
		sheet = null
	board_pick = {}
	peeking = false
	peek_btn.visible = false
	peek_back.visible = false
	if req == null:
		hand.visible = true
		_apply_marks()
		return
	_clear_select(false)
	var kind := BRequest.kind_of(self, req)
	var top_y: float = L.bar.position.y + L.bar.size.y
	if kind == "handpick" or (mode == "table" and (kind == "slots" or kind == "prizes")):
		# 탁자에서 직접 고르기: 후보가 맥동, 위에 안내 띠
		board_pick = { "req": req, "kind": kind }
		if kind == "handpick":
			_place_hand(_me())
		sheet = BRequest.pick_bar(self, req)
		sheet_layer.add_child(sheet)
		sheet.size = Vector2(size.x - 24, 0)
		sheet.position = Vector2(12, top_y + 6)
		hand.visible = true
		_apply_marks()
		_keep_bar_off_targets(sheet, req)
		return
	sheet = BRequest.build(self, req)
	sheet_layer.add_child(sheet)
	if kind == "values":
		# 작은 선택(예·아니오·선공/후공 등)은 가운데 대화상자. 카드를 보여주는 창(고르기·공개 확인)은 모두 아래 창
		await get_tree().process_frame
		if not is_instance_valid(sheet):
			return
		var w: float = minf(size.x - 40, 640)
		sheet.size = Vector2(w, 0)
		await get_tree().process_frame
		if not is_instance_valid(sheet):
			return
		sheet.size = Vector2(w, 0)
		var h := sheet.get_combined_minimum_size().y
		sheet.size = Vector2(w, h)
		sheet.position = Vector2((size.x - w) / 2, clampf((size.y - h) / 2, top_y + 70, size.y - h))
		hand.visible = true
		_show_peek_btn()
		return
	sheet.set_meta("covers_hand", true)
	hand.visible = false
	# 같은 요청을 다시 그릴 때(카드를 고를 때마다)는 맞춰 둔 높이에서 바로 시작 — 한 프레임 다른 자리에 그려졌다 튀지 않게.
	# 처음 뜰 때는 높이를 맞출 때까지 투명하게
	var refit: bool = _sheet_fit.get("id") == str(req.id) and _sheet_fit.get("size") == size
	var fit_y: float = _sheet_fit.y if refit else maxf(top_y + 70, size.y * 0.42)
	if not refit:
		sheet.modulate.a = 0.0
	sheet.position = Vector2(0, fit_y)
	sheet.size = Vector2(size.x, size.y - fit_y)
	_show_peek_btn()
	_fit_sheet(sheet, top_y, str(req.id))

var _sheet_fit := {}   # 아래 창을 마지막으로 맞춘 요청·위치·화면 크기 { id, y, size }

## 아래 선택 창 높이를 내용에 맞춘다 (내용이 짧으면 판이 더 보이게, 길면 위로 늘림). 아래 끝은 늘 화면 아래
func _fit_sheet(sh: Control, top_y: float, rid: String) -> void:
	await get_tree().process_frame
	if not is_instance_valid(sh) or sh != sheet:
		return
	var h := sh.get_combined_minimum_size().y + UI.safe_bottom(self) + 12
	var y := clampf(size.y - h, top_y + 70, size.y - 160)
	sh.position = Vector2(0, y)
	sh.size = Vector2(size.x, size.y - y)
	sh.modulate.a = 1.0
	_sheet_fit = { "id": rid, "y": y, "size": size }
	_show_peek_btn()

## 탁자 고르기 안내 띠가 고를 대상(상대 벤치 등)을 가리면 가운데 띠(스타디움 줄) 위로 옮긴다
func _keep_bar_off_targets(bar: Control, req: Dictionary) -> void:
	await get_tree().process_frame
	if not is_instance_valid(bar) or bar != sheet:
		return
	bar.size = Vector2(bar.size.x, 0)
	var r := Rect2(bar.position, Vector2(bar.size.x, bar.get_combined_minimum_size().y))
	var hit := false
	for o in req.options:
		var n: Control = slots.get(str(o))
		if n != null and n.visible and Rect2(n.position, n.size).intersects(r):
			hit = true
	if hit and mid.visible and mid.size.y > 0:
		bar.position.y = mid.position.y + (mid.size.y - r.size.y) / 2.0

## 선택 창 오른쪽 위에 [판 보기]
func _show_peek_btn() -> void:
	if not is_instance_valid(sheet):
		return
	var ms := peek_btn.get_combined_minimum_size()
	peek_btn.position = Vector2(sheet.position.x + sheet.size.x - ms.x - 12, sheet.position.y - ms.y - 8)
	peek_btn.visible = true
	sheet_layer.move_child(peek_btn, -1)
	sheet_layer.move_child(peek_back, -1)

## 판 보기: 선택 창을 접어 판(과 손패)을 보이고, 아래 띠로 다시 펼친다. 선택은 그대로 남음
func set_peek(on: bool) -> void:
	if not is_instance_valid(sheet) or my_request() == null:
		return
	peeking = on
	sheet.visible = not on
	peek_btn.visible = not on
	peek_back.visible = on
	if sheet.get_meta("covers_hand", false):
		hand.visible = on
	if on:
		var ms := peek_back.get_combined_minimum_size()
		# 가운데 띠(스타디움 줄) 위에: 칸·손패·칩을 가리지 않음
		var c: Vector2 = mid.position + mid.size / 2 if mid.visible and mid.size.y > 0 else Vector2(size.x / 2, size.y * 0.5)
		peek_back.position = Vector2((size.x - ms.x) / 2, c.y - ms.y / 2)

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
	if board_pick.get("kind") == "handpick":
		_place_hand(_me())

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
	if board_pick.get("kind") == "handpick":
		board_pick_tap(iid)   # 준비 단계: 끌어 올려도 고르기
		return
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
		return BHint.why_unusable(Net.view, Net.seat, str(hand.codes.get(iid, "")))
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
	# 연출 설정: 큰 피해 때 판 흔들림·진동 (끄면 user://fx.json 에 저장)
	BFx.load_settings()
	for st in [["shake", "화면 흔들림"], ["vibrate", "진동"]]:
		var key: String = st[0]
		var on: bool = BFx.shake_on if key == "shake" else BFx.vibrate_on
		var sb := UI.button("%s: %s" % [st[1], "켜짐" if on else "꺼짐"], 26)
		sb.set_meta("item", key)
		sb.tapped.connect(func():
			if key == "shake":
				BFx.shake_on = not BFx.shake_on
			else:
				BFx.vibrate_on = not BFx.vibrate_on
			BFx.save_settings()
			var now_on: bool = BFx.shake_on if key == "shake" else BFx.vibrate_on
			(sb.get_meta("label") as Label).text = "%s: %s" % [st[1], "켜짐" if now_on else "꺼짐"])
		col.add_child(sb)
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
	if Net.can_rematch() and str(Net.lobby.get("phase", "game")) != "game" and Nav.current() == self and not Nav._busy:
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

# ───────────────────────── 결과 화면 ─────────────────────────

var result_panel: Control = null

## 게임이 끝나고 마지막 연출이 끝나면 결과 (승패·이유·턴·사이드, 다시 하기·로그·나가기)
func _update_result() -> void:
	var res = Net.view.get("result")
	if res == null:
		if result_panel:
			result_panel.queue_free()
			result_panel = null
		return
	if result_panel or (fx and fx.busy()):
		return
	var win = res.get("winner")
	var me := _me()
	var opp := _opp()
	var title := "무승부" if win == null else ("승리!" if int(win) == Net.seat else "패배")
	var color := UI.TEXT if win == null else (UI.ACCENT if int(win) == Net.seat else Color(0.95, 0.5, 0.45))
	var root := PanelContainer.new()
	root.add_theme_stylebox_override("panel", UI.box(Color(0.04, 0.08, 0.06, 0.97), 26, 4, color))
	var mm := UI.margin(26)
	root.add_child(mm)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	mm.add_child(col)
	var t := UI.label(title, 64, color, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(t)
	var why := UI.label(result_words(res), 24, UI.TEXT, HORIZONTAL_ALIGNMENT_CENTER, true)
	why.custom_minimum_size.x = minf(size.x - 120, 560)
	col.add_child(why)
	col.add_child(UI.label("턴 %d · 가져간 사이드 나 %d : 상대 %d" % [int(Net.view.turnNumber), _taken(opp), _taken(me)], 22, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	col.add_child(row)
	if Net.can_rematch():
		var again := UI.button("다시 하기", 28, true, true)
		again.set_meta("result", "again")
		again.tapped.connect(func(): Net.send({ "t": "rematch" }))
		row.add_child(again)
	var lg := UI.button("로그", 26)
	lg.set_meta("result", "log")
	lg.tapped.connect(open_log)
	row.add_child(lg)
	if not Net.solo:
		var out := UI.button("나가기", 26, true)
		out.set_meta("result", "leave")
		out.tapped.connect(_leave_to_root)
		row.add_child(out)
	var close := UI.button("판 보기", 22)
	close.set_meta("result", "board")
	close.tapped.connect(func():
		if result_panel:
			result_panel.visible = false)
	row.add_child(close)
	hud.add_child(root)
	result_panel = root
	await get_tree().process_frame
	if not is_instance_valid(root):
		return
	var w: float = minf(size.x - 40, 640)
	root.size = Vector2(w, 0)
	var h := root.get_combined_minimum_size().y
	root.position = Vector2((size.x - w) / 2, (size.y - h) * 0.42)
	root.pivot_offset = Vector2(w / 2, h / 2)
	root.scale = Vector2(0.85, 0.85)
	root.create_tween().tween_property(root, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	Input.vibrate_handheld(40)

## 내가 가져간 사이드 = 상대 사이드 칸 중 빈 칸 수 (사이드를 깔기 전이면 0)
static func _taken(p: Dictionary) -> int:
	return (p.prizes as Array).size() - _count_true(p.prizes)

## 엔진 문구의 "플레이어 1/2" 를 내 시점 "나/상대" 로
## 결과 이유를 내 시점으로: 엔진의 승리 이유 일부는 이긴 쪽 시점("상대 필드에…")이라 진 쪽에서는 뒤집어 보여 준다
static func result_words(res: Dictionary) -> String:
	var t := my_words(str(res.get("reason", "")))
	var win = res.get("winner")
	if win == null or Net.seat < 0 or int(win) == Net.seat:
		return t
	return { "사이드를 모두 가져갔습니다.": "상대가 사이드를 모두 가져갔습니다.", "상대 필드에 포켓몬이 없습니다.": "내 필드에 포켓몬이 없습니다." }.get(t, t)

static func my_words(t: String) -> String:
	if Net.seat < 0:
		return t
	var me_n := "플레이어 %d" % (Net.seat + 1)
	var op_n := "플레이어 %d" % (2 - Net.seat)
	return t.replace(me_n + "이(가)", "내가").replace(op_n + "이(가)", "상대가").replace(me_n, "나").replace(op_n, "상대")

## 서버 대전이 끝난 뒤 나가기: 참가 정보 지우고 첫 화면으로
func _leave_to_root() -> void:
	Net.leave()
	Nav.pop_to_root()   # 이 화면은 곧 사라지므로 이어지는 처리는 Nav 가 한다
