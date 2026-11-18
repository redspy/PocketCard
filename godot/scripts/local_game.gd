class_name LocalGame
extends Node
## 서버 없는 AI 연습: 폰 안의 규칙 엔진(scripts/engine, TS 엔진을 그대로 옮긴 것)으로 게임을 돌린다.
## 서버 세션(server/session.ts 의 AI 연습)과 같은 메시지(welcome / lobby / events / state / error)를 Net 에 넘겨
## 대전 준비·게임 화면은 서버와 똑같이 동작한다. 플레이어 1 = 나, 플레이어 2 = AI.
## 진행 중인 게임은 user://offline_game.json 에 저장 → 앱을 다시 켜도 이어서.

const SAVE_PATH := "user://offline_game.json"
const AI_SEAT := 1

static var _cat: Dictionary = {}
static var _info: Dictionary = {}

var deliver: Callable            # 서버 메시지를 받을 곳 (Net._on_message)
var match_: GMatch = null
var phase := "lobby"
var my_deck := ""
var my_prints := {}
var ai_deck := ""                # "" = 무작위
var ai_delay_ms := 700
var _ai: Callable
var _ai_rng: Array = []
var _ai_wait := -1.0             # AI 가 둘 때까지 남은 시간 (초), -1 = 할 일 없음

## 카탈로그·카드 규칙 데이터 (처음 한 번 읽음). 앱의 DeckData 는 고른 인쇄로 코드를 바꿔 두므로 원본 파일을 따로 읽는다
static func data() -> Dictionary:
	if _cat.is_empty():
		var raw = _read("res://data/decks.json")
		var rules = _read("res://data/rules.json")
		_cat = GMatch.buildCatalog(raw)
		_info = { "basics": _cat.basics, "db": rules.cards }
	return { "cat": _cat, "info": _info }

static func _read(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	return GCore.intify(JSON.parse_string(f.get_as_text())) if f else null

func start() -> void:
	data()
	_ai = GBot.makeAiBot(_cat, _info.db)
	_load()
	_send({ "t": "welcome", "role": "player", "seat": 0, "token": "local", "code": "AI", "protocol": 3, "dataVersion": DeckData.data_version, "serverTime": Time.get_unix_time_from_system() * 1000 })
	_send_lobby()
	if match_ != null:
		_send(match_.snapshot(0))
		_schedule_ai()

## 앱 → "서버" 메시지
func handle(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"chooseDeck":
			if phase != "lobby":
				return _error("in_game", "게임 중에는 덱을 바꿀 수 없습니다.")
			my_deck = str(msg.get("deckId", ""))
			my_prints = msg.get("prints", {}) if msg.get("prints") is Dictionary else {}
			_send_lobby()
		"aiDeck":
			if phase != "lobby":
				return _error("in_game", "게임 중에는 덱을 바꿀 수 없습니다.")
			ai_deck = str(msg.deckId) if msg.get("deckId") != null else ""
			_send_lobby()
		"aiSpeed":
			ai_delay_ms = clampi(int(msg.get("ms", 700)), 0, 5000)
			_save()
			_send_lobby()
		"ready":
			if bool(msg.get("ready", false)) and phase == "lobby":
				if my_deck == "":
					return _error("no_deck", "먼저 덱을 고르세요.")
				_start_game()
		"input":
			if match_ == null:
				return _error("no_game", "게임이 시작되지 않았습니다.")
			var r := match_.submit(0, msg.get("input", {}))
			if not r.ok:
				return _error(r.error.code, r.error.message)
			_after(r.events)
		"rematch":
			match_ = null
			phase = "lobby"
			_ai_wait = -1.0
			DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
			_send_lobby()

func _start_game() -> void:
	var decks: Array = _cat.decks
	var ad := ai_deck
	if ad == "" or not decks.any(func(d): return d.id == ad):
		ad = decks[randi() % decks.size()].id
	var seed := ""
	for i in 4:
		seed += "%08x" % (randi() & 0xFFFFFFFF)
	var config := { "seed": seed, "players": [
		{ "deckId": my_deck, "cards": GMatch.buildDeck(_cat, my_deck, my_prints) },
		{ "deckId": ad, "cards": GMatch.buildDeck(_cat, ad) }] }
	match_ = GMatch.new(config, _info)
	_ai_rng = GRng.seedRng(seed.reverse())
	phase = "game"
	_send_lobby()
	_after(match_.lastEvents)

## 입력 처리 뒤: 내 시점 메시지 보내기 → 저장 → AI 차례 예약
func _after(events: Array) -> void:
	for m in match_.messagesFor(0, events):
		_send(m)
	_save()
	_schedule_ai()

func _schedule_ai() -> void:
	_ai_wait = -1.0
	if match_ == null or match_.state.phase == "ended":
		return
	if GBot.botHasWork(GView.viewFor(match_.state, AI_SEAT, _info)):
		_ai_wait = ai_delay_ms / 1000.0

func _process(delta: float) -> void:
	if _ai_wait < 0.0 or Net.fx_busy:
		return
	_ai_wait -= delta
	if _ai_wait > 0.0:
		return
	_ai_wait = -1.0
	if match_ == null or match_.state.phase == "ended":
		return
	var view := GView.viewFor(match_.state, AI_SEAT, _info)
	var input = _ai.call(view, _ai_rng)
	if input == null:
		return
	var r := match_.submit(AI_SEAT, input)
	if not r.ok:
		push_warning("AI 입력 거절: %s" % r.error.message)
		return
	_after(r.events)

# ───────────── 보내기 ─────────────

func _send(m: Dictionary) -> void:
	if deliver.is_valid():
		deliver.call(m)

func _error(code: String, message: String) -> void:
	_send({ "t": "error", "code": code, "message": message })

func _deck_name(id: String):
	for d in _cat.decks:
		if d.id == id:
			return d.name
	return null

func _send_lobby() -> void:
	var ai_shown := ai_deck
	if match_ != null:
		ai_shown = match_.config.players[1].deckId
	var seats := [
		{ "seat": 0, "taken": true, "connected": true, "device": "이 폰", "deckId": my_deck if my_deck != "" else null, "deckName": _deck_name(my_deck), "ready": phase == "game" },
		{ "seat": 1, "taken": true, "connected": true, "device": "AI", "deckId": ai_shown if ai_shown != "" else null, "deckName": _deck_name(ai_shown), "ready": phase == "game" },
	]
	_send({ "t": "lobby", "lobby": { "code": "AI", "phase": phase, "countdownEndsAt": null, "seats": seats, "addresses": [], "port": 0, "paused": false, "solo": true, "aiDelayMs": ai_delay_ms, "offline": true } })

# ───────────── 저장 / 이어서 ─────────────

func _save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	var d := { "aiDeck": ai_deck, "aiDelayMs": ai_delay_ms, "myDeck": my_deck, "myPrints": my_prints }
	if match_ != null and match_.state.phase != "ended":
		d["log"] = match_.log_data()
		d["aiRng"] = _ai_rng
	f.store_string(JSON.stringify(d))

func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var d = _read(SAVE_PATH)
	if not (d is Dictionary):
		return
	ai_deck = str(d.get("aiDeck", ""))
	ai_delay_ms = int(d.get("aiDelayMs", 700))
	my_deck = str(d.get("myDeck", ""))
	my_prints = d.get("myPrints", {}) if d.get("myPrints") is Dictionary else {}
	if d.get("log") is Dictionary:
		var m := GMatch.replay(d.log, _info)
		if m != null and m.state.phase != "ended":
			match_ = m
			phase = "game"
			_ai_rng = d.aiRng if d.get("aiRng") is Array else GRng.seedRng(str(m.config.seed).reverse())
