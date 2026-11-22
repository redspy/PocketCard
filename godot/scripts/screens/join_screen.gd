class_name JoinScreen
extends Control
## 게임 참가: 같은 Wi-Fi 의 게임 목록(자동 탐색) 또는 주소·세션 코드 직접 입력
## 참가하면 로비 화면으로 넘어간다.
## 폰끼리 대전(phone): [방 만들기](이 폰이 방장, PhoneHost) 또는 같은 Wi-Fi 의 방장 폰 목록에서 들어가기

var _disc: LanDiscovery
var _list: VBoxContainer
var _status: Label
var _addr: LineEdit
var _code: LineEdit
var _going := false
var _solo := false          # AI 연습: 서버만 고르면 바로 연습 세션 (세션 코드 없음)
var _phone := false         # 폰끼리 대전: 방장 폰 목록 (PC 서버 대신)

func _init(solo_mode := false, phone_mode := false) -> void:
	_solo = solo_mode
	_phone = phone_mode

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
	if _phone:
		layout.add_child(UI.top_bar(self, "폰끼리 대전", "같은 Wi-Fi 또는 한 폰의 핫스팟"))
	else:
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

	if _phone:
		var host := UI.button("🏠  방 만들기 (이 폰이 방장)", 30, true, true)
		host.tapped.connect(_host)
		col.add_child(host)
		col.add_child(UI.label("한 폰에서 [방 만들기], 다른 폰은 아래 목록에서 그 방을 누르세요.
카드 규칙은 방장 폰이 처리합니다. 두 폰에 같은 버전의 앱이 있어야 합니다.", 22, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true))
	elif Net.can_resume() and Net.solo == _solo:
		var again := UI.button("이전 게임에 다시 연결 (%s)" % Net.address, 26, true)
		again.tapped.connect(func():
			_going = true
			Net.resume())
		col.add_child(again)

	if _solo:
		col.add_child(UI.label("게임판 없이 이 폰 하나로 AI와 1:1 대전합니다.\n카드 규칙·AI는 PC의 게임 서버가 처리합니다.", 22, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true))
	col.add_child(UI.label("같은 Wi-Fi 의 방" if _phone else ("같은 Wi-Fi 의 게임 서버" if _solo else "같은 Wi-Fi 의 게임"), 30, UI.TEXT))
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 12)
	col.add_child(_list)

	col.add_child(UI.label("직접 입력", 30, UI.TEXT))
	_addr = UI.line_edit("방장 폰 주소 (예: 192.168.0.12)" if _phone else "PC 주소 (예: 192.168.0.12:8787)")
	_addr.text = "" if _phone else Net.address
	col.add_child(_addr)
	_code = UI.line_edit("방 코드 6자리" if _phone else "세션 코드 6자리")
	_code.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	_code.max_length = 6
	col.add_child(_code)
	_code.visible = not _solo
	var go := UI.button("AI와 연습 시작" if _solo else ("들어가기" if _phone else "참가"), 30, true, true)
	go.tapped.connect(func(): _join(_addr.text.strip_edges(), _code.text.strip_edges()))
	col.add_child(go)
	if _phone:
		col.add_child(UI.label("방장 폰의 대전 준비 화면에 표시된 주소와 방 코드를 입력하세요.
게스트 Wi-Fi(기기끼리 통신 차단)에서는 방이 안 보일 수 있습니다. 그럴 땐 한 폰의 핫스팟에 다른 폰을 연결하세요.", 22, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true))
	elif not _solo:
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
		addr += ":%d" % (PhoneHost.PORT if _phone else 8787)
	_going = true
	Net.join(addr, code)

## 폰끼리 대전: 이 폰이 방장 → 바로 대전 준비 화면 (상대가 들어오길 기다림)
func _host() -> void:
	var err := Net.start_phone_host()
	if err != "":
		_status.text = err
		return
	Nav.push(LobbyScreen.new())

func _refresh_list() -> void:
	for c in _list.get_children():
		c.queue_free()
	var keys := _disc.games.keys().filter(func(k): return (str(_disc.games[k].get("kind", "server")) == "phone") == _phone)
	if keys.is_empty():
		var msg := _disc.bind_error if _disc.bind_error != "" else ("찾는 중… (다른 폰에서 [방 만들기]를 누르세요)" if _phone else "찾는 중… (PC에서 npm run server 실행)")
		_list.add_child(UI.label(msg, 24, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true))
		return
	for k in keys:
		var g: Dictionary = _disc.games[k]
		var open: bool = g["open"]
		if _phone:
			var pb := UI.button("%s의 방 · %s%s" % [g["name"], g["address"].get_slice(":", 0), "" if open else " (대전 중 · 재접속만)"], 26, true, open)
			var pa: String = g["address"]
			var pc: String = g["code"]
			pb.tapped.connect(func(): _join(pa, pc))
			_list.add_child(pb)
			continue
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
