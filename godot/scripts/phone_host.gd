class_name PhoneHost
extends Node
## 폰끼리 대전 (서버·게임판 없이): 이 폰(방장)이 게임 서버 역할을 한다.
## - 규칙 엔진(GMatch)은 방장 폰 안에서 돈다. 상대 폰은 WebSocket(포트 8789)으로 접속하고,
##   PC 서버(server/session.ts)와 같은 메시지(hello / welcome / lobby / events / state / error)를 주고받는다
##   → 상대 폰의 Net 은 PC 서버에 붙을 때와 똑같이 동작하고, 대전 준비·대전 화면도 그대로 쓴다.
## - 방장 = 플레이어 1 (Net 에 직접 전달, LocalGame 처럼), 상대 = 플레이어 2 (자기 시점의 화면 정보만 받음).
## - 방 알림: 1초마다 UDP 8788 로 PC 서버와 같은 형식의 알림(kind "phone") → 상대 폰의 [폰끼리 대전] 목록에 뜬다.
## - 끊김: 상대는 자동 재접속(토큰으로 같은 자리). 진행 중인 게임은 user://phone_game.json 에 저장
##   → 방장 앱을 다시 켜고 [방 만들기]를 누르면 이어서 한다.

const PORT := 8789
const BEACON_PORT := 8788
const SAVE_PATH := "user://phone_game.json"
const HOST := 0
const GUEST := 1
const COUNTDOWN_SEC := 3.0
const HANDSHAKE_SEC := 10.0

var deliver: Callable            # 방장 화면으로 보낼 곳 (Net._on_message)
var code := ""                   # 방 코드 6자리 (주소로 직접 들어올 때 확인)
var match_: GMatch = null
var phase := "lobby"             # lobby / countdown / game
var seats: Array = []            # [{token, device, deckId, prints, ready}]
var listen_error := ""

var _server := TCPServer.new()
var _conns: Array = []           # 접속한 WebSocketPeer 들 (핸드셰이크 중 포함)
var _conn_at := {}               # WebSocketPeer → 접속 시각 (핸드셰이크 시간 초과 확인)
var _guest: WebSocketPeer = null # 플레이어 2 의 연결 (hello 를 마친 것)
var _udp := PacketPeerUDP.new()
var _beacon_t := 0.0
var _countdown := -1.0
var _countdown_ends := 0.0

func start() -> String:
	LocalGame.data()
	seats = [_empty_seat("이 폰"), _empty_seat("")]
	seats[HOST].token = "host"
	_load()
	if code == "":
		code = "%06d" % (randi() % 1000000)
	var err := _server.listen(PORT)
	if err != OK:
		listen_error = "포트 %d 를 열 수 없습니다 (%s). 앱을 완전히 껐다가 다시 켜 보세요." % [PORT, error_string(err)]
		return listen_error
	_udp.set_broadcast_enabled(true)
	_send_host({ "t": "welcome", "role": "player", "seat": HOST, "token": "host", "code": code, "protocol": Net.PROTOCOL, "dataVersion": DeckData.data_version, "serverTime": _now_ms() })
	_broadcast_lobby()
	if match_ != null:
		_send_host(match_.snapshot(HOST))
	return ""

func _exit_tree() -> void:
	for c in _conns:
		(c as WebSocketPeer).close()
	_conns.clear()
	_conn_at.clear()
	_guest = null
	_server.stop()
	_udp.close()

static func _empty_seat(device: String) -> Dictionary:
	return { "token": "", "device": device, "deckId": "", "prints": {}, "ready": false }

static func _now_ms() -> float:
	return Time.get_unix_time_from_system() * 1000.0

## 이 폰의 사설 IPv4 주소 (상대가 직접 입력할 주소 안내·방 알림용)
static func local_ips() -> Array:
	var out := []
	for a in IP.get_local_addresses():
		if a.contains(":") or a.begins_with("127.") or a.begins_with("169.254."):
			continue
		if a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172."):
			out.append(a)
	return out

# ───────────── 방장(이 폰) → "서버" ─────────────

func handle(msg: Dictionary) -> void:
	var err := _msg(HOST, msg)
	if err != "":
		_send_host({ "t": "error", "code": err.get_slice("|", 0), "message": err.get_slice("|", 1) })

# ───────────── 매 프레임: 접속 받기·메시지·방 알림·카운트다운 ─────────────

func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	while _server.is_listening() and _server.is_connection_available():
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = 1 << 20
		ws.outbound_buffer_size = 1 << 22
		if ws.accept_stream(_server.take_connection()) == OK:
			_conns.append(ws)
			_conn_at[ws] = now
	for ws: WebSocketPeer in _conns.duplicate():
		ws.poll()
		var st := ws.get_ready_state()
		if st == WebSocketPeer.STATE_CLOSED or (st == WebSocketPeer.STATE_CONNECTING and now - float(_conn_at.get(ws, now)) > HANDSHAKE_SEC):
			if st != WebSocketPeer.STATE_CLOSED:
				ws.close()
			_conns.erase(ws)
			_conn_at.erase(ws)
			if ws == _guest:
				_guest = null
				print("[PhoneHost] 상대 연결 끊김")
				if phase == "countdown":
					_cancel_countdown()
				_broadcast_lobby()
			continue
		while ws.get_ready_state() == WebSocketPeer.STATE_OPEN and ws.get_available_packet_count() > 0:
			var parsed = JSON.parse_string(ws.get_packet().get_string_from_utf8())
			if typeof(parsed) == TYPE_DICTIONARY:
				_on_guest(ws, GCore.intify(parsed))
	_beacon_t -= delta
	if _beacon_t <= 0.0:
		_beacon_t = 1.0
		_beacon()
	if _countdown >= 0.0:
		_countdown -= delta
		if _countdown < 0.0:
			_start_game()

func _beacon() -> void:
	var msg := JSON.stringify({ "app": "pocketcard", "protocol": 1, "kind": "phone", "name": OS.get_model_name(), "code": code,
		"port": PORT, "open": phase == "lobby" and not _guest_connected() }).to_utf8_buffer()
	var targets := ["255.255.255.255"]
	for ip in local_ips():
		var p: PackedStringArray = ip.split(".")
		targets.append("%s.%s.%s.255" % [p[0], p[1], p[2]])
	for t in targets:
		_udp.set_dest_address(t, BEACON_PORT)
		_udp.put_packet(msg)

func _guest_connected() -> bool:
	return _guest != null and _guest.get_ready_state() == WebSocketPeer.STATE_OPEN

# ───────────── 상대 폰 → "서버" ─────────────

func _on_guest(c: WebSocketPeer, m: Dictionary) -> void:
	if str(m.get("t", "")) == "hello":
		_hello(c, m)
		return
	if c != _guest:
		_send_ws(c, { "t": "error", "code": "bad_msg", "message": "먼저 접속(hello)이 필요합니다." })
		return
	var err := _msg(GUEST, m)
	if err != "":
		_send_ws(c, { "t": "error", "code": err.get_slice("|", 0), "message": err.get_slice("|", 1) })

func _hello(c: WebSocketPeer, m: Dictionary) -> void:
	if int(m.get("protocol", 0)) != Net.PROTOCOL:
		_reject(c, "protocol", "두 폰의 앱 버전이 다릅니다. 같은 버전의 앱을 설치하세요.")
		return
	if m.get("dataVersion") != null and str(m.dataVersion) != DeckData.data_version:
		_reject(c, "data_version", "두 폰의 카드 데이터가 다릅니다. 같은 버전의 앱을 설치하세요.")
		return
	var g: Dictionary = seats[GUEST]
	var tok := str(m.get("token", "")) if m.get("token") != null else ""
	if tok == "" or tok != str(g.token):
		# 새 참가자: 방 코드 확인, 자리가 비었거나 (대전 준비 중이면) 끊긴 사람 자리를 넘겨받는다
		if str(m.get("code", "")) != code:
			_send_ws(c, { "t": "error", "code": "bad_code", "message": "방 코드가 맞지 않습니다." })
			return
		if phase != "lobby":
			_reject(c, "in_game", "이미 대전 중인 방입니다.")
			return
		if str(g.token) != "" and _guest_connected() and _guest != c:
			_reject(c, "full", "이미 상대가 들어와 있습니다.")
			return
		seats[GUEST] = _empty_seat("")
		seats[GUEST].token = "%08x%08x" % [randi(), randi()]
	# 같은 자리의 이전 연결은 닫는다 (재접속)
	if _guest != null and _guest != c:
		_guest.close()
		_conns.erase(_guest)
		_conn_at.erase(_guest)
	_guest = c
	if m.get("device") != null and str(m.device) != "":
		seats[GUEST].device = str(m.device).left(40)
	print("[PhoneHost] 상대 접속: %s" % seats[GUEST].device)
	_save()
	_send_ws(c, { "t": "welcome", "role": "player", "seat": GUEST, "token": seats[GUEST].token, "code": code, "protocol": Net.PROTOCOL, "dataVersion": DeckData.data_version, "serverTime": _now_ms() })
	_broadcast_lobby()
	if match_ != null:
		_send_ws(c, match_.snapshot(GUEST))

func _reject(c: WebSocketPeer, err_code: String, message: String) -> void:
	_send_ws(c, { "t": "error", "code": err_code, "message": message })
	c.close()

# ───────────── 공통 처리 (방장·상대) — 오류는 "code|message" ─────────────

func _msg(seat: int, m: Dictionary) -> String:
	match str(m.get("t", "")):
		"chooseDeck":
			if phase == "game":
				return "in_game|게임 중에는 덱을 바꿀 수 없습니다."
			var id := str(m.get("deckId", ""))
			if not (LocalGame.data().cat.decks as Array).any(func(d): return d.id == id):
				return "no_deck|없는 덱입니다."
			if phase == "countdown":
				_cancel_countdown()
			seats[seat].deckId = id
			seats[seat].prints = m.get("prints", {}) if m.get("prints") is Dictionary else {}
			seats[seat].ready = false
			_save()
			_broadcast_lobby()
		"ready":
			if phase == "game":
				return "in_game|이미 게임 중입니다."
			var on := bool(m.get("ready", false))
			if on and str(seats[seat].deckId) == "":
				return "no_deck|먼저 덱을 고르세요."
			seats[seat].ready = on
			if not on and phase == "countdown":
				_cancel_countdown()
			_maybe_countdown()
			_save()
			_broadcast_lobby()
		"input":
			if match_ == null:
				return "no_game|게임이 시작되지 않았습니다."
			if not _guest_connected():
				return "paused|상대의 재접속을 기다리는 중입니다."
			var r := match_.submit(seat, m.get("input", {}) if m.get("input") is Dictionary else {})
			if not r.ok:
				return "%s|%s" % [r.error.code, r.error.message]
			_save()
			_broadcast_game(r.events)
		"rematch":
			if match_ != null and str(match_.state.phase) != "ended":
				return "in_game|게임이 끝난 뒤에 다시 할 수 있습니다."
			match_ = null
			phase = "lobby"
			for s in seats:
				s.ready = false
			_save()
			_broadcast_lobby()
		"hello":
			pass
		_:
			return "bad_msg|알 수 없는 메시지"
	return ""

func _maybe_countdown() -> void:
	if phase != "lobby" or not (bool(seats[HOST].ready) and bool(seats[GUEST].ready) and _guest_connected()):
		return
	phase = "countdown"
	_countdown = COUNTDOWN_SEC
	_countdown_ends = _now_ms() + COUNTDOWN_SEC * 1000.0

func _cancel_countdown() -> void:
	_countdown = -1.0
	phase = "lobby"

func _start_game() -> void:
	_countdown = -1.0
	var a: Dictionary = seats[HOST]
	var b: Dictionary = seats[GUEST]
	if str(a.deckId) == "" or str(b.deckId) == "" or not _guest_connected():
		phase = "lobby"
		_broadcast_lobby()
		return
	var seed := ""
	for i in 4:
		seed += "%08x" % (randi() & 0xFFFFFFFF)
	var cat: Dictionary = LocalGame.data().cat
	var config := { "seed": seed, "players": [
		{ "deckId": a.deckId, "cards": GMatch.buildDeck(cat, a.deckId, a.prints) },
		{ "deckId": b.deckId, "cards": GMatch.buildDeck(cat, b.deckId, b.prints) }] }
	match_ = GMatch.new(config, LocalGame.data().info)
	phase = "game"
	print("[PhoneHost] 게임 시작: %s vs %s" % [a.deckId, b.deckId])
	_save()
	_broadcast_lobby()
	_broadcast_game(match_.lastEvents)

# ───────────── 보내기 ─────────────

func _send_host(m: Dictionary) -> void:
	if deliver.is_valid():
		deliver.call(m)

func _send_ws(c: WebSocketPeer, m: Dictionary) -> void:
	if c != null and c.get_ready_state() == WebSocketPeer.STATE_OPEN:
		c.send_text(JSON.stringify(m))

func _broadcast_game(events: Array) -> void:
	for m in match_.messagesFor(HOST, events):
		_send_host(m)
	for m in match_.messagesFor(GUEST, events):
		_send_ws(_guest, m)

func _deck_name(id: String):
	for d in LocalGame.data().cat.decks:
		if d.id == id:
			return d.name
	return null

func lobby_info() -> Dictionary:
	var out := []
	for i in 2:
		var s: Dictionary = seats[i]
		var id := str(s.deckId)
		out.append({ "seat": i, "taken": i == HOST or str(s.token) != "", "connected": i == HOST or _guest_connected(), "device": s.device,
			"deckId": id if id != "" else null, "deckName": _deck_name(id), "ready": bool(s.ready) })
	var addrs := []
	for ip in local_ips():
		addrs.append({ "address": ip, "iface": "", "preferred": addrs.is_empty() })
	return { "code": code, "phase": phase, "countdownEndsAt": _countdown_ends if phase == "countdown" else null, "seats": out,
		"addresses": addrs, "port": PORT, "paused": phase == "game" and not _guest_connected(), "p2p": true }

func _broadcast_lobby() -> void:
	var m := { "t": "lobby", "lobby": lobby_info() }
	_send_host(m)
	_send_ws(_guest, m)

# ───────────── 저장 / 이어서 ─────────────

func _save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	var d := { "code": code, "seats": seats }
	if match_ != null and str(match_.state.phase) != "ended":
		d["log"] = match_.log_data()
	f.store_string(JSON.stringify(d))

func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	var d = GCore.intify(JSON.parse_string(f.get_as_text())) if f else null
	if not (d is Dictionary):
		return
	code = str(d.get("code", ""))
	if d.get("seats") is Array and (d.seats as Array).size() == 2:
		for i in 2:
			var s = d.seats[i]
			if s is Dictionary:
				seats[i] = { "token": str(s.get("token", "")), "device": str(s.get("device", "")), "deckId": str(s.get("deckId", "")),
					"prints": s.get("prints", {}) if s.get("prints") is Dictionary else {}, "ready": false }
	seats[HOST].token = "host"
	seats[HOST].device = "이 폰"
	if d.get("log") is Dictionary:
		var m := GMatch.replay(d.log, LocalGame.data().info)
		if m != null and str(m.state.phase) != "ended":
			match_ = m
			phase = "game"
