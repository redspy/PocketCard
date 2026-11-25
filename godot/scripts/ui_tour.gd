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
	# 인쇄가 가장 많은 카드 (썸네일 줄이 넘쳐 좌우로 밀어 보는 경우)
	var best_deck: Dictionary = {}
	var best_code := ""
	var best_n := 0
	for deck in DeckData.decks:
		for c in deck["cards"]:
			if DeckData.has_prints(c) and c["prints"].size() > best_n:
				best_n = c["prints"].size()
				best_deck = deck
				best_code = c["code"]
	if best_n > 0:
		var dm := DeckDetailScreen.new(best_deck)
		await _push(dm)
		await _wait(0.6)
		dm.open_card(best_code)
		await _wait(0.9)
		await _shot("card_prints_many")
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

# ───────────────────────── 2단계: 대전 중 장면 찾아 찍기 ─────────────────────────
## 봇끼리(내 자리도 봇) 여러 덱 조합으로 대전하며, 처음 나오는 장면을 한 장씩 찍는다:
## 선택 요청 종류(카드·포켓몬·사이드·값·공개), 특수상태, 도구, 에너지 많음, 벤치 8칸, 로스트존, 덱 부족,
## 상대 차례(생각 중), 연출(기술·기절·코인), 후퇴 고르기, 판 보기, 항복 확인, 턴 종료만 남음
## 실행: Godot --path godot --resolution 720x1560 -- --ui-scenes phone table
static var _seen := {}

static func scenes(host: Node, tag: String, mode: String) -> void:
	_host = host
	_tag = tag
	_n = 0
	_seen = {}
	await _wait(0.8)
	var pairs := [["gardevoir", "charizard"], ["dragapult", "gholdengo"], ["giratina", "umbreon"], ["pachirisu", "flareon"],
		["charizard", "gardevoir23"], ["gholdengo", "dragapult"], ["umbreon", "giratina"], ["flareon", "pachirisu"]]
	for p in pairs:
		await _scene_game(mode, p[0], p[1])
	print("[ui-scenes] 찍은 장면: %s" % ", ".join(PackedStringArray(_seen.keys())))

static func _once(key: String) -> bool:
	if _seen.has(key):
		return false
	_seen[key] = true
	return true

static func _scene_game(mode: String, my_deck: String, ai_deck: String) -> void:
	await _root()
	Net.leave()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LocalGame.SAVE_PATH))
	Net.start_offline()
	Net.send({ "t": "aiSpeed", "ms": 250 })
	Net.send({ "t": "aiDeck", "deckId": ai_deck })
	Net.send({ "t": "chooseDeck", "deckId": my_deck, "prints": {} })
	await _host.get_tree().process_frame
	Net.send({ "t": "ready", "ready": true })
	for i in 60:
		await _host.get_tree().process_frame
		if not Net.view.is_empty():
			break
	var s := BattleScreen.new(mode)
	await _push(s)
	var dt := LocalGame.data()
	var bot: Callable = GBot.makeAiBot(dt.cat, dt.info.db)
	var rng := GRng.seedRng("%08x" % (randi() & 0xFFFFFFF))
	var last := -1
	var t0 := Time.get_ticks_msec()
	var fx_seen := {}
	while Time.get_ticks_msec() - t0 < 150000:
		await _host.get_tree().process_frame
		var v: Dictionary = Net.view
		if v.is_empty():
			continue
		# 연출 장면 (처음 한 번씩)
		if s.fx and s.fx.busy():
			for k in ["attack", "ko", "coin", "evolve", "heal", "switch"]:
				var c := int(s.fx.counts.get(k, 0))
				if c > int(fx_seen.get(k, 0)):
					fx_seen[k] = c
					if _once("%s_fx_%s" % [mode, k]):
						await _wait(0.1)
						await _shot("%s_fx_%s" % [mode, k])
			continue
		if v.get("result") != null:
			break
		await _scan_state(s, v, mode)
		var req = s.my_request()
		if req != null:
			var kind := BRequest.kind_of(s, req)
			if _once("%s_req_%s_%s" % [mode, kind, str(req.kind)]):
				await _wait(0.5)
				await _shot("%s_req_%s_%s" % [mode, kind, str(req.kind)])
				if s.sheet and s.peek_btn.visible and _once("%s_peek" % mode):
					s.set_peek(true)
					await _shot("%s_peek" % mode)
					s.set_peek(false)
					await _wait(0.2)
		elif s._my_turn() and int(v.version) != last:
			var acts: Array = s.actions()
			if acts.any(func(m): return m.kind == "retreat") and _once("%s_retreat" % mode):
				s.start_retreat()
				await _shot("%s_retreat" % mode)
				s._clear_select()
				await _wait(0.2)
			if BHint.only_end_left(acts) and _once("%s_only_end" % mode):
				await _wait(0.8)
				await _shot("%s_only_end" % mode)
			if int(v.turnNumber) >= 5 and _once("%s_concede_confirm" % mode):
				s.open_menu()
				await _wait(0.2)
				var cb = BUiTests._find_meta(s.menu, "item", "항복")
				if cb:
					s.tap_concede(cb)
					await _shot("%s_concede_confirm" % mode)
				s.close_menu()
				await _wait(0.2)
		if int(v.version) != last and GBot.botHasWork(v):
			last = int(v.version)
			var inp = bot.call(v.duplicate(true), rng)
			if inp != null:
				Net.input(inp)
		elif not s._my_turn() and _once("%s_opp_turn" % mode):
			await _shot("%s_opp_turn" % mode)
	while s.fx and s.fx.busy():
		await _host.get_tree().process_frame
	if Net.view.get("result") != null and _once("%s_result_%s" % [mode, str(Net.view.result.get("reason", "")).left(6)]):
		await _wait(1.0)
		await _shot("%s_result_end" % mode)

## 판의 상태에서 드문 장면 찾기
static func _scan_state(s: BattleScreen, v: Dictionary, mode: String) -> void:
	for side in [0, 1]:
		var p: Dictionary = v.players[side]
		var all: Array = [p.get("active")] + (p.bench as Array)
		for sl in all:
			if not (sl is Dictionary):
				continue
			var cond: Dictionary = sl.get("cond", {})
			if str(cond.get("rot", "")) != "" and _once("%s_cond_%s" % [mode, str(cond.rot)]):
				await _shot("%s_cond_%s" % [mode, str(cond.rot)])
			if (int(cond.get("poison", 0)) > 0 or bool(cond.get("burn", false))) and _once("%s_cond_poison_burn" % mode):
				await _shot("%s_cond_poison_burn" % mode)
			var att: Array = sl.get("attached") if sl.get("attached") is Array else []
			if att.size() >= 5 and _once("%s_many_attached" % mode):
				await _shot("%s_many_attached" % mode)
			if att.any(func(a): return BData.is_tool_card(str(a.code))) and _once("%s_tool" % mode):
				await _shot("%s_tool" % mode)
			if (sl.get("effects", []) as Array).size() > 0 and _once("%s_effect_badge" % mode):
				await _shot("%s_effect_badge" % mode)
		if BattleScreen.bench_slots(p) > 5 and _once("%s_bench8" % mode):
			await _shot("%s_bench8" % mode)
		if (p.get("lost", []) as Array).size() > 0 and _once("%s_lost" % mode):
			await _shot("%s_lost" % mode)
		if int(p.deckCount) <= BPile.LOW_DECK and _once("%s_low_deck" % mode):
			await _shot("%s_low_deck" % mode)
	if v.get("stadium") != null and _once("%s_stadium" % mode):
		await _shot("%s_stadium" % mode)
