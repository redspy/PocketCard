class_name LobbyScreen
extends Control
## 로비: 내 자리·상대 상태, 덱 선택(덱 뷰어에서 고른 인쇄 그대로), 준비 완료
## 두 사람 모두 준비되면 게임판에서 카운트다운 → 게임 화면으로 넘어간다.

var _info: Label
var _opp: Label
var _decks: VBoxContainer
var _ready_btn: TapArea
var _err: Label
var _built_deck := "?"
var _built_ready := false
var _ai_box: HFlowContainer      # AI 연습: 상대(AI) 덱 고르기
var _built_ai := "?"
var _speed_box: HFlowContainer   # AI 연습: AI 속도
var _built_speed := -1

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = UI.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var layout := VBoxContainer.new()
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	layout.add_theme_constant_override("separation", 0)
	add_child(layout)
	layout.add_child(UI.top_bar(self, "AI와 연습" if Net.solo else "대전 준비", ("서버 없이 이 폰에서" if Net.offline else "게임판 없이 폰 한 대로") if Net.solo else "세션 %s" % Net.code))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.scroll_deadzone = 12
	layout.add_child(scroll)
	var m := UI.margin(26)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 18)
	m.add_child(col)

	_info = UI.label("", 30, UI.TEXT)
	col.add_child(_info)
	_opp = UI.label("", 24, UI.TEXT_DIM)
	col.add_child(_opp)
	_err = UI.label("", 24, Color(1, 0.55, 0.5), HORIZONTAL_ALIGNMENT_LEFT, true)
	_err.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_err)
	if Net.solo:
		col.add_child(UI.label("상대(AI) 덱", 30, UI.ACCENT))
		_ai_box = HFlowContainer.new()
		_ai_box.add_theme_constant_override("h_separation", 10)
		_ai_box.add_theme_constant_override("v_separation", 10)
		col.add_child(_ai_box)
		col.add_child(UI.label("AI 속도 (게임 중에도 바꿀 수 있음)", 26, UI.ACCENT))
		_speed_box = HFlowContainer.new()
		_speed_box.add_theme_constant_override("h_separation", 10)
		_speed_box.add_theme_constant_override("v_separation", 10)
		col.add_child(_speed_box)
	col.add_child(UI.label("내 덱" if Net.solo else "덱 선택", 30, UI.ACCENT))
	_decks = VBoxContainer.new()
	_decks.add_theme_constant_override("separation", 12)
	col.add_child(_decks)

	# 아래 고정: 준비 완료
	var foot := UI.margin(20)
	foot.add_theme_constant_override("margin_bottom", int(UI.safe_bottom(self)) + 20)
	layout.add_child(foot)
	_ready_btn = UI.button("AI와 대전 시작" if Net.solo else "준비 완료", 34, true, true)
	_ready_btn.tapped.connect(_toggle_ready)
	foot.add_child(_ready_btn)

	Net.changed.connect(_refresh)
	_refresh()

func _exit_tree() -> void:
	if Net.changed.is_connected(_refresh):
		Net.changed.disconnect(_refresh)

func on_shown() -> void:
	_refresh()

## 뒤로 가기: 게임에서 나감 (토큰 삭제)
func on_back() -> bool:
	Net.leave()
	return false

func _me() -> Dictionary:
	var seats: Array = Net.lobby.get("seats", [])
	return seats[Net.seat] if Net.seat >= 0 and Net.seat < seats.size() else {}

func _refresh() -> void:
	if not is_inside_tree():
		return
	var me := _me()
	var seats: Array = Net.lobby.get("seats", [])
	var my_deck := str(me.get("deckId", "")) if me.get("deckId") != null else ""
	var ready := bool(me.get("ready", false))
	_info.text = "플레이어 %d%s" % [Net.seat + 1, "" if Net.status == "open" else " · 재접속 중…"]
	if seats.size() == 2 and Net.seat >= 0:
		var o: Dictionary = seats[1 - Net.seat]
		var st := "대기 중" if not bool(o["taken"]) else ("준비 완료" if bool(o["ready"]) else ("덱: %s" % o["deckName"] if o.get("deckName") != null else "덱 고르는 중"))
		_opp.text = "상대: %s" % st
		if Net.solo:
			_opp.text = "상대: AI · %s" % (str(o["deckName"]) if o.get("deckName") != null else "덱 무작위")
			var ai_deck := str(o["deckId"]) if o.get("deckId") != null else ""
			if ai_deck != _built_ai:
				_built_ai = ai_deck
				_build_ai(ai_deck)
			if Net.ai_delay() != _built_speed:
				_built_speed = Net.ai_delay()
				for c in _speed_box.get_children():
					c.queue_free()
				for sp in Net.AI_SPEEDS:
					var ms: int = sp[1]
					var on := ms == _built_speed
					var b := UI.button("%s (%s)" % [sp[0], "바로" if ms == 0 else "%.1f초" % (ms / 1000.0)], 24, on, on)
					b.tapped.connect(func(): Net.send({ "t": "aiSpeed", "ms": ms }))
					_speed_box.add_child(b)
	var phase := str(Net.lobby.get("phase", ""))
	if phase == "countdown":
		_opp.text += " · 곧 시작!"
	_err.text = str(Net.last_error.get("message", "")) if not Net.last_error.is_empty() else ""
	if not Net.solo:
		(_ready_btn.get_meta("label") as Label).text = "✔ 준비 완료 (누르면 해제)" if ready else "준비 완료"
	UI.set_enabled(_ready_btn, my_deck != "")
	if my_deck != _built_deck or ready != _built_ready:
		_built_deck = my_deck
		_built_ready = ready
		_build_decks(my_deck, ready)
	# 게임 시작 → 게임 화면
	if Net.in_game() and Nav.current() == self:
		# 새 대전 화면: AI 연습 = 탁자, 서버 대전 = 손패 (게임판은 웹). 예전 화면은 classic_ui 설정일 때만
		Nav.push(GameScreen.new() if LobbyScreen.classic_ui() else BattleScreen.new())

func _build_decks(selected: String, locked: bool) -> void:
	for c in _decks.get_children():
		c.queue_free()
	for d in DeckData.decks:
		if d.get("playable", true) == false:
			continue   # 덱 뷰어 전용 (대전 규칙 준비 중)
		var id: String = d["id"]
		var tap := TapArea.new()
		var p := PanelContainer.new()
		p.add_theme_stylebox_override("panel", UI.box(UI.PANEL, 18, 4 if id == selected else 0, UI.ACCENT))
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tap.add_child(p)
		tap.press_target = p
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 18)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mm := UI.margin(14)
		mm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mm.add_child(row)
		p.add_child(mm)
		var img := TextureRect.new()
		img.custom_minimum_size = Vector2(96, 134)
		img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		img.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var cover := DeckData.card_by_code(d, d["cover"])
		if not cover.is_empty():
			var ref: WeakRef = weakref(img)
			ImageCache.request(cover["thumb"], func(t):
				var r = ref.get_ref()
				if r:
					r.texture = t)
		row.add_child(img)
		var names := VBoxContainer.new()
		names.alignment = BoxContainer.ALIGNMENT_CENTER
		names.mouse_filter = Control.MOUSE_FILTER_IGNORE
		names.add_child(UI.label(d["name"], 32, UI.ACCENT if id == selected else UI.TEXT))
		var printed := DeckData.choices_for(id).size()
		names.add_child(UI.label("60장%s · 길게 눌러 카드 보기" % ("" if printed == 0 else " · 인쇄 %d종 변경" % printed), 22, UI.TEXT_DIM))
		row.add_child(names)
		if locked and id != selected:
			tap.modulate.a = 0.45
		# 길게 누르기: 덱의 카드 보기 (앱 전체에서 길게 누르기 = 크게 보기)
		var deck_dict: Dictionary = d
		tap.long_pressed.connect(func(): Nav.push(DeckDetailScreen.new(deck_dict)))
		tap.tapped.connect(func():
			if bool(_me().get("ready", false)):
				return
			Net.send({ "t": "chooseDeck", "deckId": id, "prints": DeckData.choices_for(id) }))
		_decks.add_child(tap)

func _build_ai(selected: String) -> void:
	for c in _ai_box.get_children():
		c.queue_free()
	var opts: Array = [["", "무작위"]]
	for d in DeckData.decks:
		if d.get("playable", true) != false:
			opts.append([str(d["id"]), str(d["name"])])
	for o in opts:
		var id: String = o[0]
		var b := UI.button(o[1], 24, id == selected, id == selected)
		b.tapped.connect(func(): Net.send({ "t": "aiDeck", "deckId": id if id != "" else null }))
		_ai_box.add_child(b)

func _toggle_ready() -> void:
	if not UI.is_enabled(_ready_btn):
		return
	Net.send({ "t": "ready", "ready": not bool(_me().get("ready", false)) })

## 예전 대전 화면을 쓰는가 (user://ui.json {"classic": true}) — 문제가 생겼을 때 되돌리는 용도
static func classic_ui() -> bool:
	if not FileAccess.file_exists("user://ui.json"):
		return false
	var f := FileAccess.open("user://ui.json", FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text()) if f else null
	return d is Dictionary and bool(d.get("classic", false))
