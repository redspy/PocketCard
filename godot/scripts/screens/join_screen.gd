class_name JoinScreen
extends Control
## 게임 참가: 같은 Wi-Fi 의 게임 목록(자동 탐색) 또는 주소·세션 코드 직접 입력
## 참가하면 로비 화면으로 넘어간다.

var _disc: LanDiscovery
var _list: VBoxContainer
var _status: Label
var _addr: LineEdit
var _code: LineEdit
var _going := false
var _solo := false          # AI 연습: 서버만 고르면 바로 연습 세션 (세션 코드 없음)

func _init(solo_mode := false) -> void:
	_solo = solo_mode

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
	layout.add_child(UI.top_bar(self, "AI와 연습" if _solo else "게임 참가", "PC에서 npm run server 실행 · 같은 Wi-Fi" if _solo else "PC의 게임판과 같은 Wi-Fi 에서"))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	layout.add_child(scroll)
	var m := UI.margin(28)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 20)
	m.add_child(col)

	_status = UI.label("", 24, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_status)

	if Net.can_resume() and Net.solo == _solo:
		var again := UI.button("이전 게임에 다시 연결 (%s)" % Net.address, 26, true)
		again.tapped.connect(func():
			_going = true
			Net.resume())
		col.add_child(again)

	if _solo:
		col.add_child(UI.label("게임판 없이 이 폰 하나로 AI와 1:1 대전합니다.\n카드 규칙·AI는 PC의 게임 서버가 처리합니다.", 22, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true))
	col.add_child(UI.label("같은 Wi-Fi 의 게임 서버" if _solo else "같은 Wi-Fi 의 게임", 30, UI.TEXT))
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 12)
	col.add_child(_list)

	col.add_child(UI.label("직접 입력", 30, UI.TEXT))
	_addr = UI.line_edit("PC 주소 (예: 192.168.0.12:8787)")
	_addr.text = Net.address
	col.add_child(_addr)
	_code = UI.line_edit("세션 코드 6자리")
	_code.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	_code.max_length = 6
	col.add_child(_code)
	_code.visible = not _solo
	var go := UI.button("AI와 연습 시작" if _solo else "참가", 30, true, true)
	go.tapped.connect(func(): _join(_addr.text.strip_edges(), _code.text.strip_edges()))
	col.add_child(go)
	if not _solo:
		col.add_child(UI.label("게임판 화면에 표시된 주소와 세션 코드를 입력하세요.\n목록에 안 보이면 공유기가 알림을 막는 경우입니다.", 22, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true))

	_disc = LanDiscovery.new()
	add_child(_disc)
	_disc.updated.connect(_refresh_list)
	Net.changed.connect(_on_net)
	_refresh_list()
	_on_net()

func _exit_tree() -> void:
	if Net.changed.is_connected(_on_net):
		Net.changed.disconnect(_on_net)

func _join(addr: String, code: String) -> void:
	if _solo:
		if addr == "":
			_status.text = "PC 주소를 입력하세요."
			return
		if not ":" in addr:
			addr += ":8787"
		_going = true
		Net.join_solo(addr)
		return
	if addr == "" or code.length() != 6:
		_status.text = "주소와 6자리 세션 코드를 입력하세요."
		return
	if not ":" in addr:
		addr += ":8787"
	_going = true
	Net.join(addr, code)

func _refresh_list() -> void:
	for c in _list.get_children():
		c.queue_free()
	if _disc.games.is_empty():
		var msg := _disc.bind_error if _disc.bind_error != "" else "찾는 중… (PC에서 npm run server 실행)"
		_list.add_child(UI.label(msg, 24, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true))
		return
	for k in _disc.games.keys():
		var g: Dictionary = _disc.games[k]
		var open: bool = g["open"]
		var b := UI.button(("%s · %s" % [g["name"], g["address"]]) if _solo else ("%s · 코드 %s · %s%s" % [g["name"], g["code"], g["address"], "" if open else " (게임 중)"]), 24, open or _solo)
		var addr: String = g["address"]
		var code: String = g["code"]
		b.tapped.connect(func(): _join(addr, code))
		_list.add_child(b)

func _on_net() -> void:
	match Net.status:
		"connecting": _status.text = "연결 중… (%s)" % Net.address
		"open": _status.text = "연결됨"
		"closed": _status.text = "연결 끊김 — 다시 시도 중" if not Net.fatal else ""
		_: _status.text = ""
	if not Net.last_error.is_empty():
		_status.text = str(Net.last_error.get("message", ""))
	# 참가 성공 → 로비 (또는 진행 중인 게임)
	if _going and Net.seat >= 0 and not Net.lobby.is_empty() and Nav.current() == self:
		_going = false
		Nav.push(LobbyScreen.new())
