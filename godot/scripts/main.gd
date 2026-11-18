extends Control
## 앱 진입점: 화면 스택을 준비하고 덱 선택 화면을 띄운다.
## 실행 인자 --selftest : 화면 이동을 자동으로 한 번 돌려 보고 종료 (PC/CI 확인용)

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = UI.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var stack := Control.new()
	stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	stack.clip_contents = true
	add_child(stack)
	Nav.setup(stack)
	Nav.push(DeckSelectScreen.new(), false)

	if "--selftest" in OS.get_cmdline_user_args():
		_selftest.call_deferred()
	var args := OS.get_cmdline_user_args()
	var ni := args.find("--nettest")
	if ni >= 0 and args.size() > ni + 2:
		_nettest.call_deferred(args[ni + 1], args[ni + 2])
	var ci := args.find("--engine-compare")
	if ci >= 0 and args.size() > ci + 1:
		_engine_compare.call_deferred(args[ci + 1])
	var si := args.find("--solotest")
	if si >= 0 and args.size() > si + 1:
		_solotest.call_deferred(args[si + 1])

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
		if Nav.current() is GameScreen:
			break
	print("[nettest] 게임 화면: %s" % (Nav.current() is GameScreen))
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
	await _nettest_screen_check()
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

## 게임 화면의 탭을 모두 한 번씩 그려 본다 (스크립트 오류 확인)
func _nettest_screen_check() -> void:
	var gs := Nav.current() as GameScreen
	if gs == null:
		print("[nettest] 게임 화면 없음")
		return
	for t in ["field", "discard", "log", "hand"]:
		gs._tab = t
		gs._refresh()
		await get_tree().process_frame
	print("[nettest] 탭 그리기 정상")

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
		if Nav.current() is GameScreen:
			break
	print("[solotest] 게임 화면: %s" % (Nav.current() is GameScreen))
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
				if k in ["play", "attach", "evolve", "bench"] and pick.is_empty() and str(a["label"]).find("붙") >= 0:
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
	var gs := Nav.current() as GameScreen
	# 가로 스크롤 유지: 패를 오른쪽으로 넘긴 뒤 카드를 고르면 (다시 그려도) 그 자리 그대로
	if gs and gs._content.get_child_count() > 0 and gs._content.get_child(0) is ScrollContainer:
		var hs := gs._content.get_child(0) as ScrollContainer
		hs.scroll_horizontal = 160
		await get_tree().process_frame
		var before := hs.scroll_horizontal
		var hand: Array = Net.view["players"][Net.seat]["hand"]
		gs._selected = str(hand[hand.size() - 1]["iid"]) if hand.size() > 0 else ""
		gs._refresh()
		await get_tree().create_timer(0.4).timeout
		var hs2 := gs._content.get_child(0) as ScrollContainer
		print("[solotest] 가로 스크롤 유지: 전 %d → 다시 그린 뒤 %d" % [before, hs2.scroll_horizontal])
	if gs:
		await _gesture_check(gs)
	print("[solotest] 턴 %s, 필드 표시 %d개, 오류 %s" % [Net.view.get("turnNumber"), gs._field_box.get_child_count() if gs else -1, Net.last_error])
	if DisplayServer.get_name() != "headless":
		await get_tree().create_timer(0.5).timeout
		get_viewport().get_texture().get_image().save_png("user://solotest_game.png")
	Net.input({ "type": "concede" })
	for i in 50:
		await get_tree().create_timer(0.1).timeout
		if Net.view.get("result") != null:
			break
	await get_tree().create_timer(0.3).timeout
	print("[solotest] 결과: %s, 다시 하기 버튼 %s" % [Net.view.get("result"), gs._btn_again.visible if gs else false])
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
## 터치 동작 확인: 패 카드 길게 누르기 → 크게 보기, 좌우로 밀어 넘기기, 누르면 닫기
func _press(pos: Vector2, down: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = down
	e.position = pos
	e.global_position = pos
	Input.parse_input_event(e)

func _move(pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	e.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(e)

func _overlay_of(gs: GameScreen) -> TapArea:
	for c in gs.get_children():
		if c is TapArea and c.get_child_count() > 0 and c.get_child(0) is ColorRect:
			return c
	return null

func _gesture_check(gs: GameScreen) -> void:
	# 내 차례(AI 가 두지 않아 화면이 멈춘 때)까지 기다린다
	for k in 100:
		var v: Dictionary = Net.view
		if v.get("turnPlayer") == Net.seat and not (v.get("requests", []) as Array).any(func(r): return r.player == Net.seat):
			break
		await get_tree().create_timer(0.1).timeout
	gs._tab = "hand"
	gs._selected = ""
	gs._refresh()
	await get_tree().create_timer(0.4).timeout
	var strip: ScrollContainer = null
	for c in gs._content.get_children():
		if c is ScrollContainer:
			strip = c
	if strip == null:
		print("[solotest] 동작: 패 줄 없음")
		return
	var cell := (strip.get_child(0) as Control).get_child(0) as Control
	var p := cell.get_global_rect().get_center() - Vector2(cell.size.x * 0.3, 0)
	_press(p, true)
	await get_tree().create_timer(0.2).timeout
	await get_tree().create_timer(0.5).timeout
	_press(p, false)
	await get_tree().create_timer(0.2).timeout
	var ov := _overlay_of(gs)
	var info_before := ""
	if ov:
		info_before = (ov.get_child(2) as Label).text
	print("[solotest] 동작: 길게 누르기 → 크게 보기 %s (선택 안 됨: %s) [%s]" % [ov != null, gs._selected == "", info_before])
	if ov:
		var c0 := ov.get_global_rect().get_center()
		_press(c0, true)
		for k in 6:
			await get_tree().process_frame
			_move(c0 - Vector2(40.0 * (k + 1), 0))
		_press(c0 - Vector2(240, 0), false)
		await get_tree().create_timer(0.2).timeout
		print("[solotest] 동작: 왼쪽으로 밀기 → %s" % (ov.get_child(2) as Label).text)
		_press(c0, true)
		await get_tree().create_timer(0.1).timeout
		_press(c0, false)
		await get_tree().create_timer(0.2).timeout
		print("[solotest] 동작: 누르기 → 닫힘 %s" % (not is_instance_valid(ov) or ov.is_queued_for_deletion()))
	# 짧게 누르기 = 고르기
	_press(p, true)
	await get_tree().create_timer(0.1).timeout
	_press(p, false)
	await get_tree().create_timer(0.3).timeout
	print("[solotest] 동작: 짧게 누르기 → 고름 %s, 크게 보기 안 열림 %s" % [gs._selected != "", _overlay_of(gs) == null])
	gs._selected = ""
	gs._refresh()
## 엔진 비교 (TS ↔ GDScript): scripts/engine-compare.ts 가 부른다
func _engine_compare(path: String) -> void:
	var code := GCompare.run(path)
	get_tree().quit(code)