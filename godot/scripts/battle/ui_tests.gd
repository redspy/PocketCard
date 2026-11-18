class_name BUiTests
## 대전 화면 자동 테스트 (Godot 헤드리스): Godot --headless --path godot -- --ui-tests
## 단계마다 테스트를 추가한다. 실패가 있으면 종료 코드 1.

const SIZES := [Vector2(720, 1560), Vector2(720, 1280), Vector2(720, 1440), Vector2(720, 1700), Vector2(1100, 1560)]

static func run_layout() -> Array:
	var fails: Array = []
	var n := 0
	for size in SIZES:
		for mode in ["table", "hand"]:
			for mb in [5, 8]:
				for ob in [5, 8]:
					if mode == "hand" and ob == 8:
						continue
					n += 1
					var l := BLayout.compute(size, mode, mb, ob, 40.0, 30.0)
					for p in BLayout.check(l, size):
						fails.append("배치 %s %s 벤치 %d/%d: %s" % [mode, size, mb, ob, p])
					# 손패 카드가 충분히 큰가 (읽을 수 있어야 함)
					if l.card.x < 120:
						fails.append("배치 %s %s: 손패 카드가 너무 작음 %s" % [mode, size, l.card])
	print("[ui-tests] 배치: %d가지 경우, 문제 %d개" % [n, fails.size()])
	return fails

## 전체 실행 (단계마다 여기에 추가)
static func run_all(host: Node) -> Array:
	var fails: Array = []
	fails.append_array(run_layout())
	fails.append_array(await run_render(host))
	for m in ["table", "hand"]:
		fails.append_array(await run_play(host, m))
	return fails

# ───────────────────────── 오프라인 게임 도우미 ─────────────────────────

## 서버 없는 AI 연습을 시작 (AI 즉시 두기). 내 덱·AI 덱 지정
static func start_offline(host: Node, my_deck := "gardevoir", ai_deck := "charizard") -> void:
	Net.leave()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LocalGame.SAVE_PATH))
	Net.start_offline()
	Net.send({ "t": "aiSpeed", "ms": 0 })
	Net.send({ "t": "aiDeck", "deckId": ai_deck })
	Net.send({ "t": "chooseDeck", "deckId": my_deck, "prints": {} })
	await host.get_tree().process_frame
	Net.send({ "t": "ready", "ready": true })
	for i in 30:
		await host.get_tree().process_frame
		if not Net.view.is_empty():
			break

## 화면을 붙인다 (전체 크기)
static func attach(host: Node, screen: Control) -> Control:
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(screen)
	return screen

# ───────────────────────── 1단계: 그리기 ─────────────────────────

## 그린 것이 상태와 맞는지 (포켓몬 칸 수·위치·HP, 덱·트래쉬 장수, 사이드 수)
static func check_render(s: BattleScreen) -> Array:
	var out: Array = []
	var v: Dictionary = Net.view
	if v.is_empty():
		return out
	var sides := [["my", v.players[Net.seat]]]
	if s.mode == "table":
		sides.append(["opp", v.players[1 - Net.seat]])
	var expect := 0
	for sd in sides:
		var side: String = sd[0]
		var p: Dictionary = sd[1]
		var list: Array = []
		if p.active != null:
			list.append([p.active, s.L[side + "_active"]])
		for i in (p.bench as Array).size():
			list.append([p.bench[i], s.L[side + "_bench"][i]])
		expect += list.size()
		for it in list:
			var sl: Dictionary = it[0]
			var node = s.slots.get(str(sl.sid))
			if node == null:
				out.append("%s: %s 칸 없음" % [s.mode, sl.sid])
				continue
			if not (node as Control).visible or (node as Control).position.distance_to((it[1] as Rect2).position) > 0.5:
				out.append("%s: %s 위치 다름" % [s.mode, sl.sid])
			if sl.get("hp") != null and node.left_shown() != int(sl.hp) - int(sl.damage):
				out.append("%s: %s HP 표시 %d ≠ %d" % [s.mode, sl.sid, node.left_shown(), int(sl.hp) - int(sl.damage)])
		if s.mode == "table":
			if s.piles[side + "_deck"].count != int(p.deckCount):
				out.append("%s 덱 장수 다름" % side)
			if s.piles[side + "_discard"].count != (p.discard as Array).size():
				out.append("%s 트래쉬 장수 다름" % side)
			var shown: int = (s.prize_cards[side] as Array).filter(func(c): return c.visible).size()
			if shown != BattleScreen._count_true(p.prizes):
				out.append("%s 사이드 표시 %d ≠ %d" % [side, shown, BattleScreen._count_true(p.prizes)])
	if s.slots.size() != expect:
		out.append("%s: 칸 노드 %d ≠ 포켓몬 %d" % [s.mode, s.slots.size(), expect])
	return out

## 오프라인 게임을 AI 끼리(내 자리도 봇) 끝까지 두며 탁자·손패 화면이 늘 상태와 맞는지 확인
static func run_render(host: Node) -> Array:
	var fails: Array = []
	await start_offline(host)
	var table := attach(host, BattleScreen.new("table")) as BattleScreen
	var hand := attach(host, BattleScreen.new("hand")) as BattleScreen
	var d := LocalGame.data()
	var bot: Callable = GBot.makeAiBot(d.cat, d.info.db)
	var rng := GRng.seedRng("ab12")
	var last := -1
	var steps := 0
	var checks := 0
	for i in 4000:
		await host.get_tree().process_frame
		var v: Dictionary = Net.view
		if v.is_empty():
			continue
		for s in [table, hand]:
			for p in check_render(s):
				if fails.size() < 20:
					fails.append("턴 %d: %s" % [int(v.turnNumber), p])
		checks += 1
		if v.get("result") != null:
			break
		if int(v.version) != last and GBot.botHasWork(v):
			last = int(v.version)
			var inp = bot.call(v.duplicate(true), rng)
			if inp != null:
				Net.input(inp)
				steps += 1
	var res = Net.view.get("result")
	if res == null:
		fails.append("그리기 테스트: 게임이 끝나지 않음 (턴 %s)" % str(Net.view.get("turnNumber")))
	print("[ui-tests] 그리기: 입력 %d번, 검사 %d번, 결과 %s" % [steps, checks, str(res.get("reason")) if res != null else "-"])
	table.queue_free()
	hand.queue_free()
	return fails

## 창 모드 화면 저장: 오프라인 게임을 turn 턴까지 봇으로 진행한 뒤 user://shot_<이름>.png
static func shot(host: Node, mode: String, turn := 6, name := "") -> void:
	await start_offline(host)
	var s := attach(host, BattleScreen.new(mode)) as BattleScreen
	var d := LocalGame.data()
	var bot: Callable = GBot.makeAiBot(d.cat, d.info.db)
	var rng := GRng.seedRng("5h07")
	var last := -1
	for i in 3000:
		await host.get_tree().process_frame
		var v: Dictionary = Net.view
		if v.is_empty():
			continue
		if v.get("result") != null or (int(v.turnNumber) >= turn and v.get("turnPlayer") == Net.seat and not GBot.botHasWork(v) == false and i > 5):
			break
		if int(v.version) != last and GBot.botHasWork(v):
			last = int(v.version)
			var inp = bot.call(v.duplicate(true), rng)
			if inp != null:
				Net.input(inp)
	for i in 20:
		await host.get_tree().process_frame
	await host.get_tree().create_timer(0.5).timeout
	host.get_viewport().get_texture().get_image().save_png("user://shot_%s.png" % (name if name != "" else mode))
	print("[ui-tests] 화면 저장: shot_%s.png (턴 %s)" % [name if name != "" else mode, str(Net.view.get("turnNumber"))])
	# 손패에서 쓸 수 있는 카드 하나 고른 화면
	var acts: Array = Net.view.get("actions", [])
	var mv = GCore.find_first(acts, func(m): return m.get("card") != null and m.get("target") != null)
	if mv == null:
		mv = GCore.find_first(acts, func(m): return m.get("card") != null)
	if mv != null:
		s.tap_hand(str(mv.card))
		await host.get_tree().create_timer(0.6).timeout
		host.get_viewport().get_texture().get_image().save_png("user://shot_%s_sel.png" % mode)
		s._clear_select()
	var me: Dictionary = Net.view.players[Net.seat]
	if me.get("active") != null:
		s.open_popover(str(me.active.sid))
		await host.get_tree().create_timer(0.6).timeout
		host.get_viewport().get_texture().get_image().save_png("user://shot_%s_pop.png" % mode)
	print("[ui-tests] 화면 저장: 고르기·말풍선")
	s.queue_free()

# ───────────────────────── 2단계: 화면 조작으로 끝까지 ─────────────────────────

static func _frames(host: Node, n := 2) -> void:
	for i in n:
		await host.get_tree().process_frame

## 봇이 고른 입력을 실제 화면 조작(손패 탭 → 대상 탭, 말풍선 버튼, 시트 버튼, 턴 종료)으로 수행한다
static func ui_do(host: Node, s: BattleScreen, inp: Dictionary) -> String:
	var v: Dictionary = Net.view
	match str(inp.type):
		"choice":
			var req = GCore.find_first(v.requests, func(r): return str(r.id) == str(inp.requestId))
			await _frames(host)
			if s.sheet == null:
				return "선택 시트가 없음 (%s)" % str(req.kind)
			var kind := BRequest.kind_of(s, req)
			var pk: Array = inp.picks
			if kind == "reveal":
				s.choose_now(req, "ok")
			elif kind == "values" and int(req.min) == 1 and int(req.max) == 1:
				s.choose_now(req, str(pk[0]))
			else:
				for x in pk:
					s.toggle_pick(req, str(x))
				s.confirm_request(req)
		"endTurn":
			s.tap_end_turn()
			if s.last_sent.get("type") != "endTurn":
				s.tap_end_turn()
		"stadium":
			s.tap_stadium_effect()
		"attack", "ability", "retreat":
			var me: Dictionary = v.players[Net.seat]
			var sid := str(inp.sid) if inp.type == "ability" else str(me.active.sid)
			s.tap_slot(sid)
			await _frames(host)
			if s.popover == null:
				return "말풍선이 안 열림 (%s)" % inp.type
			var btns: Array = s.popover_buttons()
			var b = null
			for x in btns:
				if inp.type == "attack" and x.has_meta("attack_index") and int(x.get_meta("attack_index")) == int(inp.index) and UI.is_enabled(x):
					b = x
				elif inp.type == "ability" and x.has_meta("ability") and str(x.get_meta("move").input.sid) == sid:
					b = x
				elif inp.type == "retreat" and x.has_meta("retreat"):
					b = x
			if b == null:
				return "말풍선에 버튼 없음 (%s)" % JSON.stringify(inp)
			b.tapped.emit()
			if inp.type == "retreat":
				await _frames(host)
				s.tap_slot(str(inp.to))
		"play":
			s.tap_hand(str(inp.card))
			await _frames(host)
			if s.sel_card != str(inp.card) and s.last_sent.is_empty():
				return "손패 카드가 골라지지 않음"
			if inp.get("target") != null:
				s.tap_slot(str(inp.target))
			elif s.targets.has("bench"):
				s.tap_empty("bench:0")
			else:
				s.tap_zone()
		"concede":
			return "항복은 5단계"
	await _frames(host)
	if GEngine.canon(s.last_sent) != GEngine.canon(inp):
		return "보낸 입력 다름: 기대 %s / 보냄 %s" % [JSON.stringify(inp), JSON.stringify(s.last_sent)]
	return ""

## 화면 조작만으로 AI 와 끝까지 대전 (내 자리 판단은 봇, 실행은 화면)
static func run_play(host: Node, mode: String, my_deck := "gardevoir", ai_deck := "charizard", seed := "c0de") -> Array:
	var fails: Array = []
	await start_offline(host, my_deck, ai_deck)
	var s := attach(host, BattleScreen.new(mode)) as BattleScreen
	var d := LocalGame.data()
	var bot: Callable = GBot.makeAiBot(d.cat, d.info.db)
	var rng := GRng.seedRng(seed)
	var last := -1
	var steps := 0
	var kinds := {}
	for i in 6000:
		await host.get_tree().process_frame
		var v: Dictionary = Net.view
		if v.is_empty():
			continue
		if v.get("result") != null:
			break
		if int(v.version) == last or not GBot.botHasWork(v):
			continue
		last = int(v.version)
		var inp = bot.call(v.duplicate(true), rng)
		if inp == null:
			continue
		s.last_sent = {}
		var err: String = await ui_do(host, s, inp)
		kinds[str(inp.type)] = int(kinds.get(str(inp.type), 0)) + 1
		steps += 1
		if err != "":
			fails.append("%s 조작 %d (턴 %d): %s" % [mode, steps, int(v.turnNumber), err])
			if fails.size() > 8:
				break
			if s.last_sent.is_empty():
				Net.input(inp)   # 화면으로 못 했으면 직접 보내 계속 진행
		for p in check_render(s):
			if fails.size() < 12:
				fails.append("%s 그리기: %s" % [mode, p])
	var res = Net.view.get("result")
	if res == null:
		fails.append("%s: 게임이 끝나지 않음" % mode)
	print("[ui-tests] 조작(%s): %d번 %s, 결과 %s" % [mode, steps, JSON.stringify(kinds), str(res.get("reason")) if res != null else "-"])
	s.queue_free()
	await _frames(host)
	return fails
