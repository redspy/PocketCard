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

## 전체 실행 (단계마다 여기에 추가). 실행 인자로 일부만: --ui-tests layout render play drag ...
static func run_all(host: Node) -> Array:
	var args := OS.get_cmdline_user_args()
	var only: Array = Array(args.slice(args.find("--ui-tests") + 1)).filter(func(a): return not str(a).begins_with("--"))
	var want := func(name: String) -> bool: return only.is_empty() or only.has(name)
	var fails: Array = []
	if want.call("layout"):
		fails.append_array(run_layout())
	if want.call("render"):
		fails.append_array(await run_render(host))
	if want.call("play"):
		for m in ["table", "hand"]:
			fails.append_array(await run_play(host, m))
	if only.has("dragdbg"):
		await drag_debug(host)
	if want.call("drag"):
		for m in ["table", "hand"]:
			fails.append_array(await run_play(host, m, "charizard", "gardevoir", "d2a9", true))
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
static func ui_do(host: Node, s: BattleScreen, inp: Dictionary, drag := false) -> String:
	var v: Dictionary = Net.view
	match str(inp.type):
		"choice":
			var err0: String = await ui_choice(host, s, inp)
			if err0 != "":
				return err0
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
		"play" when drag:
			var err: String = await drag_play(host, s, inp)
			if err != "":
				return err
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
static func run_play(host: Node, mode: String, my_deck := "gardevoir", ai_deck := "charizard", seed := "c0de", drag := false) -> Array:
	var fails: Array = []
	await start_offline(host, my_deck, ai_deck)
	var s := attach(host, BattleScreen.new(mode)) as BattleScreen
	var d := LocalGame.data()
	var bot: Callable = GBot.makeAiBot(d.cat, d.info.db)
	var rng := GRng.seedRng(seed)
	var last := -1
	var steps := 0
	var kinds := {}
	var bad_drop_done := false
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
		if drag and not bad_drop_done and str(inp.type) == "play" and inp.get("target") != null:
			bad_drop_done = true
			var e2: String = await bad_drop(host, s, inp)
			if e2 != "":
				fails.append("%s 잘못 놓기: %s" % [mode, e2])
		var err: String = await ui_do(host, s, inp, drag)
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
	print("[ui-tests] 조작(%s%s): %d번 %s, 결과 %s" % [mode, ", 끌어 놓기" if drag else "", steps, JSON.stringify(kinds), str(res.get("reason")) if res != null else "-"])
	s.queue_free()
	await _frames(host)
	return fails

# ───────────────────────── 3단계: 끌어 놓기 (합성 터치) ─────────────────────────

static func _press(pos: Vector2, down: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = down
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	e.position = pos
	e.global_position = pos
	Input.parse_input_event(e)

static func _move(pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	e.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(e)

## 손패 카드를 눌러 to 까지 끌고 놓는다
static func drag_card(host: Node, s: BattleScreen, iid: String, to: Vector2) -> void:
	s.hand.reveal(iid)
	await host.get_tree().create_timer(0.2).timeout
	var from := s.hand.press_point(iid)
	var e := InputEventMouseMotion.new()
	e.position = from
	e.global_position = from
	Input.parse_input_event(e)
	await _frames(host, 1)
	var hov = host.get_viewport().gui_get_hovered_control()
	s.dbg_drag["hover"] = str(hov.get_path()) if hov else "없음"
	s.dbg_drag["from"] = from
	s.dbg_drag["sheet"] = s.sheet != null
	s.dbg_drag["hand_vis"] = s.hand.visible
	_press(from, true)
	await _frames(host, 1)
	for k in range(1, 9):
		_move(from.lerp(to, k / 8.0))
		await _frames(host, 1)
	_press(to, false)
	await _frames(host, 2)

## 행동의 놓을 곳 (전역 좌표)
static func drop_point(s: BattleScreen, inp: Dictionary) -> Vector2:
	if inp.get("target") != null and s.slots.has(str(inp.target)):
		return (s.slots[str(inp.target)] as Control).get_global_rect().get_center()
	if BData.card(s.hand.codes.get(str(inp.card), "")).get("kind") == "pokemon":
		for k in s.empties:
			if k.begins_with("my:") and s.empties[k].visible:
				return (s.empties[k] as Control).get_global_rect().get_center()
	if s.mode == "table":
		return s.mid.get_global_rect().get_center()
	return (s.L.center as Rect2).get_center()

static func drag_play(host: Node, s: BattleScreen, inp: Dictionary) -> String:
	var iid := str(inp.card)
	if not s.hand.cards.has(iid):
		return "손패에 카드 노드 없음 (손패 %s, 보기 손패 %s)" % [JSON.stringify(s.hand.order), JSON.stringify((Net.view.players[Net.seat].hand as Array).map(func(h): return h.iid))]
	s.dbg_drag = {}
	var to := drop_point(s, inp)
	var from := s.hand.press_point(iid)
	await drag_card(host, s, iid, to)
	if s.last_sent.is_empty():
		return "끌어 놓았는데 보내지 않음 (%s) 누른 곳 %s → %s, 끌기 %s, 눌린 노드 %s" % [JSON.stringify(inp), from, to, JSON.stringify(s.dbg_drag), str(host.get_viewport().gui_get_hovered_control())]
	return ""

## 대상 카드를 엉뚱한 곳(상대 덱 근처 / 내 정보 줄)에 놓으면 아무것도 보내지 않고 카드가 돌아와야 함
static func bad_drop(host: Node, s: BattleScreen, inp: Dictionary) -> String:
	var iid := str(inp.card)
	if not s.hand.cards.has(iid):
		return ""
	var spot: Vector2 = (s.L.opp_deck as Rect2).get_center() if s.mode == "table" else (s.L.status as Rect2).get_center()
	# 이 카드가 그 자리를 대상으로 삼을 수 있으면 검사하지 않음
	s.last_sent = {}
	await drag_card(host, s, iid, spot)
	if not s.last_sent.is_empty():
		var opts: Array = s.targets.keys()
		return "못 놓는 곳인데 보냄: %s" % JSON.stringify(s.last_sent)
	if s.drag_ghost != null:
		return "끌던 카드가 남아 있음"
	if s.hand.cards.has(iid) and (s.hand.cards[iid] as Control).modulate.a < 0.9:
		return "카드가 손패로 돌아오지 않음(흐린 채)"
	return ""

# ───────────────────────── 4단계: 선택 요청을 실제 노드로 ─────────────────────────

static func _find_meta(root: Node, key: String, val = null) -> Node:
	if root == null:
		return null
	for n in root.find_children("*", "", true, false):
		if n.has_meta(key) and (val == null or str(n.get_meta(key)) == str(val)):
			return n
	return null

## 선택 요청: 탁자 고르기(포켓몬·사이드)는 탁자 노드를, 시트·대화상자는 그 안의 버튼·카드를 누른다
static func ui_choice(host: Node, s: BattleScreen, inp: Dictionary) -> String:
	var req = GCore.find_first(Net.view.requests, func(r): return str(r.id) == str(inp.requestId))
	await _frames(host, 3)
	if s.sheet == null:
		return "선택 화면이 없음 (%s)" % str(req.kind)
	var kind := BRequest.kind_of(s, req)
	var pk: Array = inp.picks
	var single := int(req.min) == 1 and int(req.max) == 1
	if not s.board_pick.is_empty():
		for x in pk:
			if kind == "slots":
				if not s.slots.has(str(x)):
					return "탁자에 고를 포켓몬이 없음 %s" % str(x)
				(s.slots[str(x)] as BSlot).card.tapped.emit()
			else:
				var pc: BCard = s.prize_cards["my"][int(x)]
				if not pc.visible:
					return "사이드 %s 가 안 보임" % str(x)
				pc.tapped.emit()
			await _frames(host, 1)
		if not single:
			var ok = _find_meta(s.sheet, "confirm")
			if ok == null:
				return "안내 띠에 결정 버튼 없음"
			ok.tapped.emit()
	else:
		for x in pk:
			var n = _find_meta(s.sheet, "val", x)
			if n == null and kind == "cards" and s.only_usable == false:
				return "시트에 고를 것 없음 %s (%s)" % [str(x), kind]
			if n == null:
				return "시트에 고를 것 없음 %s (%s)" % [str(x), kind]
			n.tapped.emit()
			await _frames(host, 2)
		if not (single and (kind == "values" or kind == "reveal")) and pk.size() >= 0 and not (kind == "reveal"):
			if not (single and kind == "values"):
				var ok2 = _find_meta(s.sheet, "confirm")
				if ok2 == null:
					return "시트에 결정 버튼 없음 (%s)" % kind
				ok2.tapped.emit()
	return ""

static func drag_debug(host: Node) -> void:
	await start_offline(host)
	var s := attach(host, BattleScreen.new("table")) as BattleScreen
	for i in 200:
		await _frames(host, 1)
		var v: Dictionary = Net.view
		if v.is_empty():
			continue
		if s.my_request() != null:
			var r = s.my_request()
			Net.input({ "type": "choice", "requestId": r.id, "picks": (r.options as Array).slice(0, maxi(1, int(r.min))) })
			await _frames(host, 3)
			continue
		if s._my_turn():
			break
	var iid: String = s.hand.order[0]
	var c: BCard = s.hand.cards[iid]
	var from := s.hand.press_point(iid)
	var to := from + Vector2(0, -400)
	print("[ui-tests] dbg card %s draggable %s from %s" % [iid, c.draggable, from])
	var e := InputEventMouseMotion.new()
	e.position = from
	e.global_position = from
	Input.parse_input_event(e)
	await _frames(host, 2)
	print("[ui-tests] dbg hover %s" % str(host.get_viewport().gui_get_hovered_control()))
	_press(from, true)
	await _frames(host, 2)
	print("[ui-tests] dbg after press: pressing %s dragging %s focus %s" % [c._pressing, c.dragging, str(host.get_viewport().gui_get_focus_owner())])
	for k in range(1, 5):
		_move(from.lerp(to, k / 4.0))
		await _frames(host, 2)
		print("[ui-tests] dbg move %d: pressing %s dragging %s" % [k, c._pressing, c.dragging])
	_press(to, false)
	await _frames(host, 2)
	print("[ui-tests] dbg end: dragging %s last_sent %s dbg %s" % [c.dragging, JSON.stringify(s.last_sent), JSON.stringify(s.dbg_drag)])
