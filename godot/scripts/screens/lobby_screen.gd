class_name LobbyScreen
extends Control
## 대전 준비: [내 덱] 카드 · [상대] 카드 (AI 연습이면 AI 덱·난이도·속도) · 아래 [준비 완료]
## 덱은 고르기 화면(DeckListScreen picker)에서 — 덱 뷰어에서 고른 인쇄 그대로.
## 두 사람 모두 준비되면 게임판에서 카운트다운 → 대전 화면으로 넘어간다.

var _err: Label
var _opp: Label                  # 상대 상태 한 줄 (테스트가 읽음)
var _where: Label                # 폰끼리 대전 방장: 상대가 들어올 주소·방 코드 안내
var _cards: VBoxContainer        # 내 덱·상대 카드 (상태가 바뀌면 다시 그림)
var _ready_btn: TapArea
var _built := ""

func _ready() -> void:
	var col: VBoxContainer
	if Net.p2p():
		col = Lay.page(self, "폰끼리 대전", "%s · 방 코드 %s" % ["내가 방장" if Net.offline else "참가", Net.lobby.get("code", "")])
	else:
		col = Lay.page(self, "AI와 연습" if Net.solo else "대전 준비", ("서버 없이 이 폰에서" if Net.offline else "게임판 없이 폰 한 대로") if Net.solo else "세션 %s" % Net.code)
	_err = Lay.wrap("", 22, UI.BAD)
	_err.visible = false
	col.add_child(_err)
	_cards = VBoxContainer.new()
	_cards.add_theme_constant_override("separation", 18)
	col.add_child(_cards)
	_opp = Lay.wrap("", 22, UI.TEXT_DIM)
	_where = Lay.wrap("", 22, UI.TEXT)
	# 아래 고정: 준비 완료
	_ready_btn = UI.button("AI와 대전 시작" if Net.solo else "준비 완료", 32, true, true)
	(_ready_btn.get_meta("panel") as Control).set_anchors_preset(Control.PRESET_FULL_RECT)
	_ready_btn.tapped.connect(_toggle_ready)
	UI.footer(self).add_child(_ready_btn)
	Net.changed.connect(_refresh)
	_refresh()

func _exit_tree() -> void:
	if Net.changed.is_connected(_refresh):
		Net.changed.disconnect(_refresh)
	for n in [_opp, _where]:
		if is_instance_valid(n) and n.get_parent() == null:
			n.queue_free()

func on_shown() -> void:
	_built = ""
	_refresh()

## 뒤로 가기: 게임에서 나감 (토큰 삭제)
func on_back() -> bool:
	Net.leave()
	return false

func _me() -> Dictionary:
	var seats: Array = Net.lobby.get("seats", [])
	return seats[Net.seat] if Net.seat >= 0 and Net.seat < seats.size() else {}

func _other() -> Dictionary:
	var seats: Array = Net.lobby.get("seats", [])
	return seats[1 - Net.seat] if seats.size() == 2 and Net.seat >= 0 else {}

static func _deck(id: String) -> Dictionary:
	for d in DeckData.decks:
		if str(d["id"]) == id:
			return d
	return {}

func _refresh() -> void:
	if not is_inside_tree():
		return
	var me := _me()
	var o := _other()
	var my_deck := str(me.get("deckId", "")) if me.get("deckId") != null else ""
	var ready := bool(me.get("ready", false))
	_opp.text = _opp_line(o)
	if str(Net.lobby.get("phase", "")) == "countdown":
		_opp.text += " · 곧 시작!"
	# 폰끼리 대전 방장: 상대가 아직 없으면 들어올 방법 안내
	var waiting: bool = Net.p2p() and Net.offline and not o.is_empty() and not bool(o.get("connected", false))
	if waiting:
		var ips: Array = (Net.lobby.get("addresses", []) as Array).map(func(a): return str(a.address))
		_where.text = "상대 폰: [폰끼리 대전] → 목록에서 이 방을 누르세요.
목록에 없으면 주소 %s · 방 코드 %s 입력" % [" / ".join(PackedStringArray(ips)) if not ips.is_empty() else "(Wi-Fi 연결 없음)", Net.lobby.get("code", "")]
	_err.text = str(Net.last_error.get("message", "")) if not Net.last_error.is_empty() else ""
	_err.visible = _err.text != ""
	if not Net.solo:
		(_ready_btn.get_meta("label") as Label).text = "준비 취소" if ready else "준비 완료"
		UI.restyle(_ready_btn, true, not ready)
	UI.set_enabled(_ready_btn, my_deck != "")
	# 다시 그릴 필요가 있을 때만 (고르는 중 깜빡이지 않게)
	var sig := JSON.stringify([my_deck, ready, DeckData.choices_for(my_deck).size() if my_deck != "" else 0, o, Net.ai_level(), Net.ai_delay(), Net.status, waiting, _where.text])
	if sig != _built:
		_built = sig
		_build(my_deck, ready, o, waiting)
	# 게임 시작 → 대전 화면
	if Net.in_game() and Nav.current() == self:
		Nav.push(BattleScreen.new())

func _opp_line(o: Dictionary) -> String:
	if o.is_empty():
		return ""
	if Net.solo:
		return "AI · %s" % (str(o["deckName"]) if o.get("deckName") != null else "덱 무작위")
	var st := "기다리는 중" if not bool(o["taken"]) else ("준비 완료" if bool(o["ready"]) else ("덱: %s" % o["deckName"] if o.get("deckName") != null else "덱 고르는 중"))
	if Net.p2p() and bool(o["taken"]):
		return "%s · %s" % [o.get("device", ""), st if bool(o.get("connected", true)) else "연결 끊김 — 재접속 기다리는 중"]
	return st

func _build(my_deck: String, ready: bool, o: Dictionary, waiting: bool) -> void:
	# 계속 쓰는 글자(_opp·_where)는 떼어 두고 나머지 칸은 버린다
	for n in [_opp, _where]:
		if n.get_parent():
			n.get_parent().remove_child(n)
	for c in _cards.get_children():
		_cards.remove_child(c)
		c.queue_free()
	if waiting:
		_cards.add_child(_where_card())
	_cards.add_child(_my_card(my_deck, ready))
	_cards.add_child(_opp_card(o))

## 내 덱: 고른 덱 (누르면 카드 목록) + [덱 고르기/바꾸기]
func _my_card(my_deck: String, ready: bool) -> Control:
	var c := Lay.card(UI.PANEL_HI, 20)
	var col: VBoxContainer = c[1]
	col.add_theme_constant_override("separation", 12)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	var who := "내 덱"
	if Net.p2p():
		who = "내 덱 · %s" % ("방장" if Net.offline else "참가")
	elif not Net.solo:
		who = "내 덱 · 플레이어 %d" % (Net.seat + 1)
	head.add_child(UI.label(who, 28, UI.ACCENT))
	if not Net.solo and my_deck != "":
		head.add_child(UI.chip("준비 완료" if ready else "준비 중", UI.GOOD if ready else UI.TEXT_DIM))
	col.add_child(head)
	if Net.status != "open" and not Net.offline:
		col.add_child(UI.label("재접속 중…", 22, UI.WARN))
	var d := _deck(my_deck)
	if d.is_empty():
		col.add_child(Lay.wrap("덱을 고르지 않았습니다. 아래 [덱 고르기]를 누르세요.", 22, UI.TEXT_DIM))
	else:
		col.add_child(_deck_row(d))
	var choose := UI.button("덱 고르기" if d.is_empty() else "덱 바꾸기", 24, true, d.is_empty())
	(choose.get_meta("panel") as Control).set_anchors_preset(Control.PRESET_FULL_RECT)
	choose.set_meta("choose", "mine")
	UI.set_enabled(choose, Net.solo or not ready)
	choose.tapped.connect(func():
		if UI.is_enabled(choose):
			_pick_deck(false, my_deck))
	col.add_child(choose)
	return c[0]

## 상대: 상태 한 줄. AI 연습이면 AI 덱 + 난이도 + 속도
func _opp_card(o: Dictionary) -> Control:
	var c := Lay.card(UI.PANEL, 20)
	var col: VBoxContainer = c[1]
	col.add_theme_constant_override("separation", 12)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.add_child(UI.label("상대 (AI)" if Net.solo else "상대", 28, UI.ACCENT))
	if not Net.solo and not o.is_empty() and bool(o["taken"]):
		head.add_child(UI.chip("준비 완료" if bool(o["ready"]) else "준비 중", UI.GOOD if bool(o["ready"]) else UI.TEXT_DIM))
	col.add_child(head)
	col.add_child(_opp)
	if not Net.solo:
		var od := _deck(str(o.get("deckId", "")) if o.get("deckId") != null else "")
		if not od.is_empty():
			col.add_child(_deck_row(od))
		return c[0]
	var ai_deck := str(o.get("deckId", "")) if o.get("deckId") != null else ""
	var ad := _deck(ai_deck)
	if not ad.is_empty():
		col.add_child(_deck_row(ad))
	var ch := UI.button("AI 덱 바꾸기", 24, true)
	(ch.get_meta("panel") as Control).set_anchors_preset(Control.PRESET_FULL_RECT)
	ch.set_meta("choose", "ai")
	ch.tapped.connect(func(): _pick_deck(true, ai_deck))
	col.add_child(ch)
	if Net.offline:
		col.add_child(UI.label("AI 난이도", 24, UI.TEXT))
		var lv: Array = Net.AI_LEVELS.map(func(l): return [l[1], str(l[0]) + (" (미리 수를 읽음)" if l[1] == "hard" else "")])
		var lrow := Lay.segmented(lv, Net.ai_level(), func(key): Net.send({ "t": "aiLevel", "level": key }))
		lrow.set_meta("seg", "level")
		col.add_child(lrow)
	col.add_child(UI.label("AI 속도 (게임 중에도 바꿀 수 있음)", 24, UI.TEXT))
	var sp: Array = Net.AI_SPEEDS.map(func(s): return [s[1], "%s (%s)" % [s[0], "바로" if int(s[1]) == 0 else "%.1f초" % (int(s[1]) / 1000.0)]])
	var srow := Lay.segmented(sp, Net.ai_delay(), func(ms): Net.send({ "t": "aiSpeed", "ms": ms }))
	srow.set_meta("seg", "speed")
	col.add_child(srow)
	return c[0]

## 폰끼리 대전 방장: 상대가 들어올 방법 (주소·방 코드 크게)
func _where_card() -> Control:
	var c := Lay.card(UI.PANEL, 20)
	var col: VBoxContainer = c[1]
	col.add_child(UI.label("상대를 기다리는 중", 28, UI.ACCENT))
	col.add_child(_where)
	var ips: Array = (Net.lobby.get("addresses", []) as Array).map(func(a): return str(a.address))
	for ip in ips:
		col.add_child(UI.label(str(ip), 34, UI.ACCENT))
	col.add_child(UI.label("방 코드 %s" % Net.lobby.get("code", ""), 34, UI.TEXT))
	return c[0]

## 덱 한 줄: 대표 카드 + 이름 + 장수. 누르거나 길게 누르면 덱의 카드 보기
func _deck_row(d: Dictionary) -> Control:
	var tap := TapArea.new()
	tap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	tap.add_child(row)
	row.add_child(Lay.cover(d, 96, -3))
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_theme_constant_override("separation", 6)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(info)
	info.add_child(Lay.wrap(str(d["name"]), 32, UI.TEXT))
	var printed := DeckData.choices_for(str(d["id"])).size()
	info.add_child(Lay.wrap("%d장%s · 누르면 카드 보기" % [int(d["total"]), "" if printed == 0 else " · 인쇄 %d종 바꿈" % printed], 20, UI.TEXT_DIM))
	info.add_child(Lay.kind_chips(d))
	var dd: Dictionary = d
	tap.tapped.connect(func(): Nav.push(DeckDetailScreen.new(dd, false)))
	tap.long_pressed.connect(func(): Nav.push(DeckDetailScreen.new(dd, false)))
	return tap

## 덱 고르기 화면 (내 덱 / AI 덱)
func _pick_deck(ai: bool, current: String) -> void:
	var p := DeckListScreen.new(true, "AI 덱 고르기" if ai else "내 덱 고르기", current, ai)
	p.picked.connect(func(id: String):
		if ai:
			Net.send({ "t": "aiDeck", "deckId": id if id != "" else null })
		else:
			Net.send({ "t": "chooseDeck", "deckId": id, "prints": DeckData.choices_for(id) }))
	Nav.push(p)

func _toggle_ready() -> void:
	if not UI.is_enabled(_ready_btn):
		return
	Net.send({ "t": "ready", "ready": not bool(_me().get("ready", false)) })
