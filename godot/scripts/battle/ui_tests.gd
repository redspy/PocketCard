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
	s.queue_free()
