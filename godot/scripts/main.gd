extends Control
## 앱 진입점: 화면 테마를 정하고, 화면 스택을 준비해 첫 화면(홈)을 띄운다.
## 실행 인자 --selftest : 화면 이동을 자동으로 한 번 돌려 보고 종료 (PC/CI 확인용)

func _ready() -> void:
	# 화면 테마 (저장된 설정, 실행 인자 --theme light|dark 로 강제 — 스크린샷용)
	var targs := OS.get_cmdline_user_args()
	var thi := targs.find("--theme")
	UI.load_theme(targs[thi + 1] if thi >= 0 and targs.size() > thi + 1 else "")

	var stack := Control.new()
	stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	stack.clip_contents = true
	add_child(stack)
	Nav.setup(stack)
	Nav.push(HomeScreen.new(), false)

	if "--selftest" in OS.get_cmdline_user_args():
		_selftest.call_deferred()
	var args := OS.get_cmdline_user_args()
	var ni := args.find("--nettest")
	if ni >= 0 and args.size() > ni + 2:
		_nettest.call_deferred(args[ni + 1], args[ni + 2])
	var shi := args.find("--battle-shot")
	if shi >= 0:
		_battle_shot.call_deferred(args[shi + 1] if args.size() > shi + 1 else "table")
	if "--ui-tests" in args:
		_ui_tests.call_deferred()
	var ci := args.find("--engine-compare")
	if ci >= 0 and args.size() > ci + 1:
		_engine_compare.call_deferred(args[ci + 1])
	var sci := args.find("--ui-scenes")
	if sci >= 0:
		_ui_scenes.call_deferred(args[sci + 1] if args.size() > sci + 1 else "shot", args[sci + 2] if args.size() > sci + 2 else "table")
	var ti := args.find("--ui-tour")
	if ti >= 0:
		_ui_tour.call_deferred(args[ti + 1] if args.size() > ti + 1 else "shot")
	var pi := args.find("--p2ptest")
	if pi >= 0 and args.size() > pi + 1:
		_p2ptest.call_deferred(args[pi + 1])
	if "--ai-bench" in args:
		(func(): AiBench.run(); get_tree().quit()).call_deferred()
	if "--offline-hard-test" in args:
		(func(): get_tree().quit(await AiDuel.offline_test(self))).call_deferred()
	var di := args.find("--ai-duel")
	if di >= 0:
		_ai_duel.call_deferred(int(args[di + 1]) if args.size() > di + 1 else 10, int(args[di + 2]) if args.size() > di + 2 else 0)
	var si := args.find("--solotest")
	if si >= 0 and args.size() > si + 1:
		_solotest.call_deferred(args[si + 1])

## 폰끼리 대전 자가 테스트 (PC 에서 두 개를 띄움): 방장은 [방 만들기], 참가자는 방 알림 목록에서 그 방 → 덱·준비
## → 양쪽 AI 가 자기 차례를 둔다 → 참가자는 3턴에 연결을 끊었다가 자동 재접속 → 방장이 8턴에 항복 → 다시 하기 → 대전 준비
## 실행: Godot --headless --path godot -- --p2ptest host   /   Godot --headless --path godot -- --p2ptest join
func _p2ptest(role: String) -> void:
	var host := role == "host"
	Net.leave()
	if host:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PhoneHost.SAVE_PATH))
	var js := JoinScreen.new(false, true)
	Nav.push(js, false)
	await get_tree().create_timer(0.5).timeout
	if host:
		js._disc.queue_free()   # 같은 PC 의 참가자가 알림 포트(8788)를 받을 수 있게
		js._host()
	else:
		var found := false
		for i in 100:
			await get_tree().create_timer(0.1).timeout
			for k in js._disc.games.keys():
				var g: Dictionary = js._disc.games[k]
				if str(g.get("kind", "")) == "phone":
					print("[p2ptest] 방 찾음: %s · %s · 코드 %s" % [g.name, g.address, g.code])
					js._join(str(g.address).replace(str(g.address).get_slice(":", 0), "127.0.0.1"), str(g.code))
					found = true
					break
			if found:
				break
		if not found:
			print("[p2ptest] 방을 못 찾음 (%s)" % js._disc.bind_error)
			get_tree().quit(1)
			return
	for i in 100:
		await get_tree().create_timer(0.1).timeout
		if Nav.current() is LobbyScreen:
			break
	print("[p2ptest] %s 대전 준비: %s, 자리 %d, p2p %s" % [role, Nav.current() is LobbyScreen, Net.seat + 1, Net.p2p()])
	await get_tree().create_timer(1.0).timeout
	_p2p_shot(role, "1_lobby")
	if host and Nav.current() is LobbyScreen:
		print("[p2ptest] 방장 안내: %s" % (Nav.current() as LobbyScreen)._where.text.replace("
", " / "))
	var deck := "gardevoir" if host else "charizard"
	Net.send({ "t": "chooseDeck", "deckId": deck, "prints": DeckData.choices_for(deck) })
	await get_tree().create_timer(0.3).timeout
	await get_tree().create_timer(0.4).timeout
	_p2p_shot(role, "2_lobby_deck")
	Net.send({ "t": "ready", "ready": true })
	for i in 300:
		await get_tree().create_timer(0.1).timeout
		if Nav.current() is BattleScreen:
			break
	await get_tree().create_timer(0.5).timeout
	print("[p2ptest] %s 대전 화면: %s (모드 %s)" % [role, Nav.current() is BattleScreen, (Nav.current() as BattleScreen).mode if Nav.current() is BattleScreen else "-"])
	var d := LocalGame.data()
	var bot := GBot.makeAiBot(d.cat, d.info.db)
	var rng := GRng.seedRng("%08x" % (0xa11ce if host else 0xb0b))
	var last_ver := -1
	var dropped := false
	var conceded := false
	var sent_at := 0
	for i in 4000:
		await get_tree().create_timer(0.05).timeout
		var v: Dictionary = Net.view
		if v.is_empty() or v.get("version") == null:
			continue
		if v.get("result") != null:
			break
		if not host and not dropped and int(v.turnNumber) >= 3:
			dropped = true
			print("[p2ptest] 참가자: 연결 끊기 (턴 %d)" % int(v.turnNumber))
			Net._ws.close()
			await get_tree().create_timer(0.3).timeout
			_p2p_shot(role, "3_reconnecting")
			continue
		if host and bool(Net.lobby.get("paused", false)) and not has_meta("shot_paused"):
			set_meta("shot_paused", true)
			_p2p_shot(role, "3_opp_paused")
		if host and not conceded and int(v.turnNumber) >= 8:
			conceded = true
			print("[p2ptest] 방장: 항복 (턴 %d, 상대 연결 %s)" % [int(v.turnNumber), not bool(Net.lobby.get("paused", false))])
			Net.input({ "type": "concede" })
			continue
		# 거절된 입력(상대 재접속 대기 등)은 1.5초 뒤 다시 둔다
		if int(v.version) == last_ver and Time.get_ticks_msec() - sent_at > 1500:
			last_ver = -1
		if int(v.version) == last_ver or not GBot.botHasWork(v):
			continue
		sent_at = Time.get_ticks_msec()
		var inp = bot.call(v.duplicate(true), rng)
		if inp != null:
			last_ver = int(v.version)
			Net.input(inp)
	await get_tree().create_timer(1.5).timeout
	_p2p_shot(role, "4_result")
	var res = Net.view.get("result")
	print("[p2ptest] %s 결과: %s, 턴 %s, 오류 %s" % [role, res, Net.view.get("turnNumber"), Net.last_error])
	if res != null and Net.seat == 0 and not host:
		print("[p2ptest] 잘못된 자리")
	await get_tree().create_timer(1.5).timeout
	if host:
		Net.send({ "t": "rematch" })
	for i in 100:
		await get_tree().create_timer(0.1).timeout
		if Nav.current() is LobbyScreen:
			break
	print("[p2ptest] %s 다시 하기 → 대전 준비: %s, 단계 %s" % [role, Nav.current() is LobbyScreen, Net.lobby.get("phase")])
	await get_tree().create_timer(0.6).timeout
	_p2p_shot(role, "5_rematch_lobby")
	await get_tree().create_timer(1.0).timeout
	get_tree().quit()

func _p2p_shot(role: String, name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://tour"))
	get_viewport().get_texture().get_image().save_png("user://tour/p2p_%s_%s.png" % [role, name])

## 서버 접속 자가 테스트: 참가 → 덱 선택·준비 → 게임 화면 → 셋업 선택 자동 응답 → 내 차례면 턴 종료
## 실행: Godot --headless --path godot -- --nettest 127.0.0.1:8787 123456
func _nettest(addr: String, code: String) -> void:
	Net.leave()
	Nav.push(JoinScreen.new(), false)
	await get_tree().create_timer(0.3).timeout
	(Nav.current() as JoinScreen)._join(addr, code)
	for i in 100:
		await get_tree().create_timer(0.1).timeout
		if Nav.current() is LobbyScreen:
			break
	print("[nettest] 로비: 자리 %d, 연결 %s" % [Net.seat + 1, Net.status])
	Net.send({ "t": "chooseDeck", "deckId": "gardevoir", "prints": DeckData.choices_for("gardevoir") })
	await get_tree().create_timer(0.3).timeout
	Net.send({ "t": "ready", "ready": true })
	for i in 150:
		await get_tree().create_timer(0.1).timeout
		if Nav.current() is BattleScreen:
			break
	print("[nettest] 게임 화면: %s" % (Nav.current() is BattleScreen))
	var ended_turn := false
	var did_action := false
	for i in 200:
		await get_tree().create_timer(0.1).timeout
		var v: Dictionary = Net.view
		if v.is_empty():
			continue
		for r in v["requests"]:
			if int(r["player"]) == Net.seat and r.has("options"):
				var opts: Array = r["options"]
				Net.input({ "type": "choice", "requestId": r["id"], "picks": opts.slice(0, maxi(int(r["min"]), 1) if int(r["max"]) > 0 else 0) })
		var acts = v.get("actions")
		if acts is Array and not ended_turn:
			# 할 수 있는 행동 중 하나(턴 종료 제외)를 해 보고, 그다음 턴 종료
			for a in acts:
				var k := str(a["kind"])
				if k in ["play", "attach", "evolve"] and not did_action:
					did_action = true
					var inp: Dictionary = (a["input"] as Dictionary).duplicate()
					inp.erase("player")
					Net.input(inp)
					print("[nettest] 행동: %s" % a["label"])
					break
			if did_action:
				for a in acts:
					if str(a["kind"]) == "endTurn":
						ended_turn = true
						Net.input({ "type": "endTurn" })
		if ended_turn and str(v["phase"]) == "playing" and int(v["turnNumber"]) >= 3:
			break
	var me: Dictionary = Net.view["players"][Net.seat]
	print("[nettest] 단계 %s, 턴 %d, 내 패 %d장, 사이드 %d칸, 오류 %s" % [Net.view["phase"], int(Net.view["turnNumber"]), (me["hand"] as Array).size(), (me["prizes"] as Array).size(), Net.last_error])
	if DisplayServer.get_name() != "headless":
		get_viewport().get_texture().get_image().save_png("user://nettest.png")
	get_tree().quit()

func _selftest() -> void:
	await get_tree().create_timer(0.5).timeout
	for d in DeckData.decks:
		var screen := DeckDetailScreen.new(d)
		Nav.push(screen)
		await get_tree().create_timer(1.0).timeout
		print("[selftest] %s 목록: 썸네일 %d개" % [d["name"], screen._thumbs.size()])
		# 크게 보기: 두 번째 카드 열기 → 다음 → 다음 → 이전 → 닫기
		var list := screen.flat_cards()
		var v := screen.open_card(list[1]["code"])
		await get_tree().create_timer(0.6).timeout
		v.go(1)
		await get_tree().create_timer(0.4).timeout
		v.go(1)
		await get_tree().create_timer(0.4).timeout
		v.go(-1)
		await get_tree().create_timer(0.4).timeout
		print("[selftest]   보기: %d번째 카드 %s (기대: %s)" % [v.index + 1, list[v.index]["name"], list[2]["name"]])
		# 다른 인쇄가 가장 많은 카드로 가서 인쇄를 바꿨다가 원래대로 되돌린다
		var best := -1
		for i in list.size():
			if DeckData.has_prints(list[i]) and (best < 0 or list[i]["prints"].size() > list[best]["prints"].size()):
				best = i
		if best >= 0:
			var i := best
			var c: Dictionary = list[i]
			var orig: String = c["code"]
			v.index = i
			v._set_textures()
			var other: String = c["prints"][0]["code"] if c["prints"][0]["code"] != orig else c["prints"][1]["code"]
			v._choose_print(other)
			await get_tree().create_timer(0.4).timeout
			if "--shot" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless":
				await get_tree().create_timer(0.6).timeout
				get_viewport().get_texture().get_image().save_png("user://shot_%s.png" % d["id"])
			var ok: bool = c["code"] == other and screen.thumb_for(other) != null and v._prints.get_child_count() == c["prints"].size()
			v._choose_print(orig)
			await get_tree().create_timer(0.3).timeout
			print("[selftest]   인쇄 바꾸기 %s: %s → %s %s, 되돌림 %s" % [c["name"], orig, other, "정상" if ok else "실패", "정상" if c["code"] == orig else "실패"])
		Nav.back()
		await get_tree().create_timer(0.8).timeout
		print("[selftest]   보기 닫힘: 스택 깊이 %d (2면 정상)" % Nav.depth())
		Nav.back()
		await get_tree().create_timer(0.6).timeout
	print("[selftest] 화면 스택 깊이 %d (1이면 정상)" % Nav.depth())
	get_tree().quit()

## AI 연습 자가 테스트: 덱 화면의 [AI와 연습] → 서버 주소로 연습 세션 → AI 덱·내 덱 → 시작
## → (선택 요청은 첫 선택지, 기술이 있으면 기술, 없으면 턴 종료) 6턴까지 → 화면 저장 → 항복 → 다시 하기 → 대전 준비 화면
## 실행: Godot --path godot -- --solotest 127.0.0.1:8787
func _solotest(addr: String) -> void:
	Net.leave()
	if addr == "offline":
		# 서버 없이: 폰 안의 엔진
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LocalGame.SAVE_PATH))
		Net.start_offline()
		Nav.push(LobbyScreen.new(), false)
	else:
		Nav.push(JoinScreen.new(true), false)
		await get_tree().create_timer(0.3).timeout
		(Nav.current() as JoinScreen)._join(addr, "")
	for i in 100:
		await get_tree().create_timer(0.1).timeout
		if Nav.current() is LobbyScreen:
			break
	print("[solotest] 로비: %s, 자리 %d, solo %s" % [Nav.current() is LobbyScreen, Net.seat + 1, Net.solo])
	Net.send({ "t": "aiDeck", "deckId": "charizard" })
	Net.send({ "t": "chooseDeck", "deckId": "gardevoir", "prints": DeckData.choices_for("gardevoir") })
	await get_tree().create_timer(0.5).timeout
	print("[solotest] 상대: %s" % (Nav.current() as LobbyScreen)._opp.text)
	if DisplayServer.get_name() != "headless":
		get_viewport().get_texture().get_image().save_png("user://solotest_lobby.png")
	Net.send({ "t": "ready", "ready": true })
	for i in 100:
		await get_tree().create_timer(0.1).timeout
		if Nav.current() is BattleScreen:
			break
	print("[solotest] 게임 화면: %s" % (Nav.current() is BattleScreen))
	Net.send({ "t": "aiSpeed", "ms": 250 })
	await get_tree().create_timer(0.3).timeout
	print("[solotest] AI 속도: %s" % Net.ai_speed_name())
	var last_ver := -1
	for i in 1200:
		await get_tree().create_timer(0.1).timeout
		var v: Dictionary = Net.view
		if v.is_empty() or v.get("result") != null:
			continue
		if int(v["turnNumber"]) >= 6:
			break
		if int(v["version"]) == last_ver:
			continue
		var acted := false
		for r in v["requests"]:
			if int(r["player"]) == Net.seat and r.has("options"):
				var opts: Array = r["options"]
				Net.input({ "type": "choice", "requestId": r["id"], "picks": opts.slice(0, maxi(int(r["min"]), 1) if int(r["max"]) > 0 else 0) })
				acted = true
				break
		var acts = v.get("actions")
		if not acted and acts is Array:
			var pick := {}
			for a in acts:
				var k := str(a["kind"])
				if k == "attach" and pick.is_empty():
					pick = a
			for a in acts:
				if str(a["kind"]) == "attack" and pick.is_empty():
					pick = a
			for a in acts:
				if str(a["kind"]) == "endTurn" and pick.is_empty():
					pick = a
			if not pick.is_empty():
				var inp: Dictionary = (pick["input"] as Dictionary).duplicate()
				inp.erase("player")
				Net.input(inp)
				acted = true
		if acted:
			last_ver = int(v["version"])
	var bs := Nav.current() as BattleScreen
	print("[solotest] 턴 %s, 포켓몬 칸 %d개, 오류 %s" % [Net.view.get("turnNumber"), bs.slots.size() if bs else -1, Net.last_error])
	if DisplayServer.get_name() != "headless":
		await get_tree().create_timer(0.5).timeout
		get_viewport().get_texture().get_image().save_png("user://solotest_game.png")
	Net.input({ "type": "concede" })
	for i in 50:
		await get_tree().create_timer(0.1).timeout
		if Net.view.get("result") != null:
			break
	await get_tree().create_timer(0.3).timeout
	print("[solotest] 결과: %s, 다시 하기 버튼 %s" % [Net.view.get("result"), (bs.end_btn.get_meta("label") as Label).text == "다시 하기" if bs else false])
	if DisplayServer.get_name() != "headless":
		get_viewport().get_texture().get_image().save_png("user://solotest_end.png")
	Net.send({ "t": "rematch" })
	for i in 50:
		await get_tree().create_timer(0.1).timeout
		if Nav.current() is LobbyScreen:
			break
	await get_tree().create_timer(0.5).timeout
	print("[solotest] 다시 하기 → 대전 준비 화면: %s" % (Nav.current() is LobbyScreen))
	get_tree().quit()
## AI 끼리 대전 (어려움 대 보통): scripts/ai_duel.gd
func _ai_duel(games: int, start: int) -> void:
	AiDuel.run(games, start)
	get_tree().quit()

## 엔진 비교 (TS ↔ GDScript): scripts/engine-compare.ts 가 부른다
func _engine_compare(path: String) -> void:
	var code := GCompare.run(path)
	get_tree().quit(code)
## 대전 화면 자동 테스트 (battle/ui_tests.gd)
func _ui_tests() -> void:
	var fails: Array = await BUiTests.run_all(self)
	for f in fails.slice(0, 30):
		print("[ui-tests] 실패: " + str(f))
	print("[ui-tests] 결과: %s (실패 %d)" % ["통과" if fails.is_empty() else "실패", fails.size()])
	get_tree().quit(0 if fails.is_empty() else 1)

## 대전 중 장면 찾아 찍기 (scripts/ui_tour.gd)
func _ui_scenes(tag: String, mode: String) -> void:
	await UiTour.scenes(self, tag, mode)
	get_tree().quit()

## 화면 둘러보기 스크린샷 (scripts/ui_tour.gd)
func _ui_tour(tag: String) -> void:
	await UiTour.run(self, tag)
	get_tree().quit()

func _battle_shot(mode: String) -> void:
	await BUiTests.shot(self, mode)
	get_tree().quit()
