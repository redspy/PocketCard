class_name UiTour
extends RefCounted
## 화면 둘러보기: 앱의 모든 화면을 차례로 열어 스크린샷을 남긴다 (UI 점검용, 창 모드에서만)
## 실행: Godot --path godot --resolution 720x1560 -- --ui-tour phone
## 저장: user://tour/<tag>_<번호>_<이름>.png

static var _host: Node
static var _tag := ""
static var _n := 0

static func _wait(sec: float) -> void:
	await _host.get_tree().create_timer(sec).timeout

static func _shot(name: String) -> void:
	await _wait(0.45)
	_n += 1
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://tour"))
	var path := "user://tour/%s_%02d_%s.png" % [_tag, _n, name]
	_host.get_viewport().get_texture().get_image().save_png(path)
	print("[ui-tour] %s" % path.get_file())

static func _push(screen: Control) -> void:
	while Nav._busy:
		await _host.get_tree().process_frame
	Nav.push(screen)
	await _wait(0.5)

static func _root() -> void:
	while Nav._busy:
		await _host.get_tree().process_frame
	Nav.pop_to_root()
	await _wait(0.6)

static func run(host: Node, tag: String) -> void:
	_host = host
	_tag = tag
	_n = 0
	await _wait(1.0)
	await _shot("home")
	# 덱 화면 · 카드 크게 보기 · 덱 설명 펼침
	var d: Dictionary = DeckData.decks[0]
	var dd := DeckDetailScreen.new(d)
	await _push(dd)
	await _wait(0.8)
	await _shot("deck")
	var list := dd.flat_cards()
	var v := dd.open_card(list[1]["code"])
	await _wait(0.8)
	await _shot("card")
	for c in list:
		if DeckData.has_prints(c):
			v.index = list.find(c)
			v._set_textures()
			break
	await _wait(0.6)
	await _shot("card_prints")
	await _root()
	var dd2 := DeckDetailScreen.new(DeckData.decks[1] if DeckData.decks.size() > 1 else d)
	dd2._guide_expanded = true
	await _push(dd2)
	await _wait(0.8)
	await _shot("deck_guide")
	await _root()
	# 참가 화면 3종
	await _push(JoinScreen.new())
	await _shot("join")
	await _root()
	await _push(JoinScreen.new(true))
	await _shot("join_solo")
	await _root()
	await _push(JoinScreen.new(false, true))
	await _shot("join_phone")
	await _root()
	# 대전 준비: AI 연습 · 폰끼리 방장
	Net.leave()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LocalGame.SAVE_PATH))
	Net.start_offline()
	await _push(LobbyScreen.new())
	Net.send({ "t": "chooseDeck", "deckId": d["id"], "prints": {} })
	await _shot("lobby_ai")
	await _root()
	Net.leave()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PhoneHost.SAVE_PATH))
	if Net.start_phone_host() == "":
		await _push(LobbyScreen.new())
		await _shot("lobby_phone")
		await _root()
	Net.leave()
	# 대전 화면: 탁자 · 손패
	for mode in ["table", "hand"]:
		await _battle(mode)
	await _root()

static func _battle(mode: String) -> void:
	await _root()
	Net.leave()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LocalGame.SAVE_PATH))
	Net.start_offline()
	Net.send({ "t": "aiSpeed", "ms": 0 })
	Net.send({ "t": "aiDeck", "deckId": "charizard" })
	Net.send({ "t": "chooseDeck", "deckId": "gardevoir", "prints": {} })
	await _host.get_tree().process_frame
	Net.send({ "t": "ready", "ready": true })
	for i in 30:
		await _host.get_tree().process_frame
		if not Net.view.is_empty():
			break
	var s := BattleScreen.new(mode)
	await _push(s)
	# 준비 단계: 첫 선택 요청(배틀 포켓몬 고르기 등)
	for i in 300:
		await _host.get_tree().process_frame
		if s.my_request() != null:
			break
	await _wait(0.8)
	await _shot("%s_setup" % mode)
	# 봇으로 6턴까지
	var dt := LocalGame.data()
	var bot: Callable = GBot.makeAiBot(dt.cat, dt.info.db)
	var rng := GRng.seedRng("5a07")
	var last := -1
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 90000:
		await _host.get_tree().process_frame
		var v: Dictionary = Net.view
		if v.is_empty():
			continue
		if v.get("result") != null:
			break
		if int(v.turnNumber) >= 6 and v.get("turnPlayer") == Net.seat and s.my_request() == null and not s.fx.busy():
			break
		if int(v.version) != last and GBot.botHasWork(v):
			last = int(v.version)
			var inp = bot.call(v.duplicate(true), rng)
			if inp != null:
				Net.input(inp)
	while s.fx.busy():
		await _host.get_tree().process_frame
	await _wait(0.6)
	await _shot("%s_main" % mode)
	# 손패 카드 고르기
	var acts: Array = Net.view.get("actions", [])
	var mv = GCore.find_first(acts, func(m): return m.get("card") != null and m.get("target") != null)
	if mv == null:
		mv = GCore.find_first(acts, func(m): return m.get("card") != null)
	if mv != null:
		s.tap_hand(str(mv.card))
		await _shot("%s_select" % mode)
		s._clear_select()
	# 배틀 포켓몬 말풍선 (기술·특성·후퇴)
	var me: Dictionary = Net.view.players[Net.seat]
	if me.get("active") != null:
		s.open_popover(str(me.active.sid))
		await _shot("%s_popover" % mode)
		s._close_popover()
		var z := s.zoom_slot(str(me.active.sid))
		await _shot("%s_zoom" % mode)
		if z:
			z.queue_free()
	# 상대 배틀 포켓몬 크게 보기
	var opp: Dictionary = Net.view.players[1 - Net.seat]
	if opp.get("active") != null:
		var z2 := s.zoom_slot(str(opp.active.sid))
		await _shot("%s_zoom_opp" % mode)
		if z2:
			z2.queue_free()
	# 트래쉬 · 로그 · 메뉴
	var zd := s.open_discard("my")
	await _shot("%s_discard" % mode)
	if zd:
		zd.queue_free()
	s.open_log()
	await _shot("%s_log" % mode)
	s.close_menu()
	await _wait(0.3)
	s.open_menu()
	await _shot("%s_menu" % mode)
	s.close_menu()
	await _wait(0.3)
	# 결과
	Net.input({ "type": "concede" })
	for i in 300:
		await _host.get_tree().process_frame
		if s.result_panel != null:
			break
	await _wait(0.8)
	await _shot("%s_result" % mode)
