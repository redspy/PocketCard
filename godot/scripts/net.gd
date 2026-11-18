extends Node
## Autoload: 게임 서버 연결 (WebSocket, JSON 메시지 — src/game/protocol.ts 와 같은 형식)
## - 접속할 때 hello(프로토콜·데이터 버전·토큰·코드·기기 이름)
## - 끊기면 자동 재접속 (토큰으로 같은 자리), 앱이 다시 앞으로 오면 즉시 재접속
## - 서버 → 앱 메시지를 lobby / view / log 로 정리해 신호로 알린다

signal changed                  # lobby·view·seat·status 중 무엇이든 바뀜
signal error_received(code: String, message: String)

const PROTOCOL := 3
const SAVE_PATH := "user://net.json"

var address := ""               # "192.168.0.12:8787"
var code := ""
var token := ""
var solo := false              # AI 연습 (게임판 없이 서버 AI 와 대전)
var offline := false           # 서버 없이 폰 안의 엔진으로 AI 연습 (LocalGame)
var fx_busy := false           # 대전 화면이 연출 중 (오프라인 AI 는 연출이 끝날 때까지 기다림)
var _local: LocalGame = null
var status := "idle"            # idle / connecting / open / closed
var seat := -1                  # 0, 1 (참가 전 -1)
var lobby: Dictionary = {}
var view: Dictionary = {}
var events_log: Array = []      # 이벤트 (최근 300개)
var last_error: Dictionary = {}
var fatal := false

var _ws: WebSocketPeer = null
var _active := false            # 연결을 유지해야 하는가
var _retry_at := 0.0
var _retries := 0
var _prev_state := WebSocketPeer.STATE_CLOSED

## AI 연습 속도 (AI 한 수 사이 간격 ms)
const AI_SPEEDS := [["느리게", 1500], ["보통", 700], ["빠르게", 250], ["즉시", 0]]

func ai_delay() -> int:
	return int(lobby.get("aiDelayMs", 700))

func ai_speed_name() -> String:
	for s in AI_SPEEDS:
		if int(s[1]) == ai_delay():
			return str(s[0])
	return "%dms" % ai_delay()

## 다음 속도로 (게임 화면의 버튼)
func cycle_ai_speed() -> void:
	var i := 0
	for k in AI_SPEEDS.size():
		if int(AI_SPEEDS[k][1]) == ai_delay():
			i = k
	send({ "t": "aiSpeed", "ms": AI_SPEEDS[(i + 1) % AI_SPEEDS.size()][1] })

const FATAL := ["protocol", "data_version", "bad_code", "full", "in_game"]

func _ready() -> void:
	_load()

# ───────────── 공개 함수 ─────────────

## 새 게임 참가 (이전 토큰은 같은 주소일 때만 재사용)
func join(addr: String, session_code: String) -> void:
	_stop_local()
	if addr != address:
		token = ""
	address = addr
	code = session_code
	solo = false
	fatal = false
	last_error = {}
	_save()
	_start()

## 서버 없이 AI 연습: 폰 안의 규칙 엔진(LocalGame)과 서버와 같은 메시지로 주고받는다
func start_offline() -> void:
	_stop_ws()
	_stop_local()
	offline = true
	solo = true
	fatal = false
	last_error = {}
	lobby = {}
	view = {}
	events_log = []
	_local = LocalGame.new()
	_local.deliver = _on_message
	add_child(_local)
	_set_status("open")
	_local.start()

func _stop_ws() -> void:
	_active = false
	if _ws:
		_ws.close()
	_ws = null

func _stop_local() -> void:
	if _local:
		_local.queue_free()
	_local = null
	offline = false

## AI 연습 시작: 서버가 이 폰만의 연습 세션을 만든다 (세션 코드 없음)
func join_solo(addr: String) -> void:
	_stop_local()
	address = addr
	code = ""
	token = ""
	solo = true
	fatal = false
	last_error = {}
	_save()
	_start()

## 저장된 참가 정보로 다시 연결 (앱을 다시 켰을 때)
func can_resume() -> bool:
	return address != "" and token != ""

func resume() -> void:
	if can_resume():
		fatal = false
		_start()

## 게임에서 나가기 (토큰 삭제)
func leave() -> void:
	_stop_ws()
	var was_offline := offline
	_stop_local()
	if was_offline:
		seat = -1
		lobby = {}
		view = {}
		events_log = []
		status = "idle"
		changed.emit()
		return
	token = ""
	seat = -1
	lobby = {}
	view = {}
	events_log = []
	status = "idle"
	_save()
	changed.emit()

func send(msg: Dictionary) -> void:
	if offline:
		# 화면이 자기 처리 중에 다시 그려지지 않게 다음 프레임에 처리 (서버 왕복처럼)
		if _local:
			_local.handle.call_deferred(msg)
		return
	if _ws and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(msg))

func input(inp: Dictionary) -> void:
	send({ "t": "input", "input": inp })

func in_game() -> bool:
	return str(lobby.get("phase", "")) == "game" and not view.is_empty()

# ───────────── 연결 ─────────────

func _start() -> void:
	_active = true
	_retries = 0
	_open()

func _open() -> void:
	if _ws:
		_ws.close()
	_ws = WebSocketPeer.new()
	var err := _ws.connect_to_url("ws://%s" % address)
	_prev_state = WebSocketPeer.STATE_CONNECTING
	_set_status("connecting")
	if err != OK:
		_ws = null
		_schedule_retry()

func _schedule_retry() -> void:
	_set_status("closed")
	if not _active or fatal:
		return
	_retries = mini(_retries + 1, 5)
	_retry_at = Time.get_ticks_msec() / 1000.0 + 0.6 * _retries

func _process(_delta: float) -> void:
	if _ws == null:
		if _active and not fatal and _retry_at > 0.0 and Time.get_ticks_msec() / 1000.0 >= _retry_at:
			_retry_at = 0.0
			_open()
		return
	_ws.poll()
	var st := _ws.get_ready_state()
	if st != _prev_state:
		_prev_state = st
		if st == WebSocketPeer.STATE_OPEN:
			_retries = 0
			_set_status("open")
			_hello()
		elif st == WebSocketPeer.STATE_CLOSED:
			_ws = null
			_schedule_retry()
			return
	while _ws and _ws.get_available_packet_count() > 0:
		var text := _ws.get_packet().get_string_from_utf8()
		var parsed = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY:
			_on_message(parsed)

func _notification(what: int) -> void:
	# 앱이 다시 앞으로 오면 기다리지 않고 재접속
	if what == NOTIFICATION_APPLICATION_RESUMED and _active and _ws == null and not fatal:
		_open()

func _hello() -> void:
	var m := { "t": "hello", "protocol": PROTOCOL, "role": "player", "dataVersion": DeckData.data_version, "device": OS.get_model_name() }
	if token != "":
		m["token"] = token
	if code != "":
		m["code"] = code
	if solo:
		m["solo"] = true
	send(m)

func _on_message(m: Dictionary) -> void:
	match str(m.get("t", "")):
		"welcome":
			seat = int(m["seat"]) if m.get("seat") != null else -1
			last_error = {}
			if not offline:   # 오프라인 연습은 서버 접속 정보(토큰·코드)를 건드리지 않는다
				if m.get("token") != null and str(m["token"]) != "":
					token = str(m["token"])
				code = str(m.get("code", code))
				_save()
		"lobby":
			lobby = m["lobby"]
			# 게임이 끝나 대전 준비로 돌아가면 (AI 연습 다시 하기) 이전 게임 화면 정보를 비운다
			if str(lobby.get("phase", "")) != "game":
				view = {}
				events_log = []
		"state":
			view = m["view"]
		"events":
			events_log.append_array(m["events"])
			if events_log.size() > 300:
				events_log = events_log.slice(events_log.size() - 300)
		"error":
			var c := str(m.get("code", ""))
			# 서버가 새 세션이라 토큰이 낡았으면: 토큰을 지우고 코드로 다시 참가
			if c == "bad_code" and token != "" and code != "":
				token = ""
				_save()
				_hello()
				return
			last_error = { "code": c, "message": str(m.get("message", "")), "at": Time.get_ticks_msec() }
			if c in FATAL:
				fatal = true
				_active = false
				if _ws:
					_ws.close()
			error_received.emit(c, str(m.get("message", "")))
		_:
			return
	changed.emit()

func _set_status(s: String) -> void:
	if status != s:
		status = s
		changed.emit()

# ───────────── 저장 ─────────────

func _save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({ "address": address, "code": code, "token": token, "solo": solo }))

func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	if typeof(d) == TYPE_DICTIONARY:
		address = str(d.get("address", ""))
		code = str(d.get("code", ""))
		token = str(d.get("token", ""))
		solo = bool(d.get("solo", false))
