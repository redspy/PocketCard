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
	if want.call("menu"):
		fails.append_array(await run_menu(host))
	if want.call("auto"):
		fails.append_array(await run_auto(host))
	if want.call("flow"):
		fails.append_array(await run_flow(host))
	if want.call("sizes"):
		fails.append_array(await run_sizes(host))
	if want.call("hints"):
		fails.append_array(run_hint_units())
		for m in ["table", "hand"]:
			fails.append_array(await run_hints(host, m))
	if want.call("fx"):
		fails.append_array(await run_fx(host))
	if only.has("lan"):
		var li: int = only.find("lan")
		fails.append_array(await run_lan(host, str(only[li + 1]), str(only[li + 2])))
	if only.has("setupshot"):
		await setup_shots(host)
	if only.has("hintshot"):
		await hint_shots(host)
	if only.has("fxshot"):
		await fx_shots(host)
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
	if v.is_empty() or (s.fx and s.fx.busy()):
		return out
	# 확대 보기·선택 창(sheet_layer)이 손패 위에 그려지는지 (손패 카드 z_index 가 위 레이어를 넘으면 가림)
	for c in s.hand.get_children():
		if c is CanvasItem and _abs_z(c) >= _abs_z(s.sheet_layer):
			out.append("손패 카드(z %d)가 확대 보기 레이어(z %d) 위에 그려짐" % [_abs_z(c), _abs_z(s.sheet_layer)])
			break
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
				var tw = node.get_meta("pos_tw") if node.has_meta("pos_tw") else null
				# 제자리로 미끄러지는 중이고 목적지가 맞으면 정상 (조작 직후 검사할 때)
				var tg = node.get_meta("target_pos", null)
				if (node as Control).visible and tw is Tween and (tw as Tween).is_running() and tg is Vector2 and (tg as Vector2).distance_to((it[1] as Rect2).position) <= 0.5:
					continue
				out.append("%s: %s 위치 다름 (지금 %s, 목표 %s, 기억 %s, 움직이는 중 %s, 크기 %s)" % [s.mode, sl.sid, (node as Control).position, (it[1] as Rect2).position, str(node.get_meta("target_pos", null)), str(tw is Tween and (tw as Tween).is_running()), str((node as Control).scale)])
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
	# 포켓몬이 있는 칸 자리에 빈 칸 틀이 보이면 안 됨
	for k in s.empties:
		var e: BSlot = s.empties[k]
		if not e.visible:
			continue
		var side2: String = k.split(":")[0]
		var idx := int(k.split(":")[1])
		var pp: Dictionary = v.players[Net.seat] if side2 == "my" else v.players[1 - Net.seat]
		var filled: bool = (idx == 0 and pp.active != null) or (idx > 0 and idx - 1 < (pp.bench as Array).size())
		if filled:
			out.append("%s: %s 빈 칸 틀이 포켓몬 뒤에 보임" % [s.mode, k])
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
	var rng := GRng.seedRng("5a07")
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
			if kind == "handpick":
				if not s.hand.cards.has(str(x)):
					return "준비 단계: 손패에 고를 카드 없음 %s" % str(x)
				(s.hand.cards[str(x)] as BCard).tapped.emit()
			elif kind == "slots":
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

# ───────────────────────── 5단계: 메뉴·항복·자동·앱 흐름 ─────────────────────────

static func _until_my_turn(host: Node, s: BattleScreen) -> void:
	for i in 400:
		await _frames(host, 1)
		var v: Dictionary = Net.view
		if v.is_empty():
			continue
		var r = s.my_request()
		if r != null:
			Net.input({ "type": "choice", "requestId": r.id, "picks": (r.options as Array).slice(0, maxi(1, int(r.min)) if int(r.max) > 0 else 0) })
			await _frames(host, 3)
			continue
		if s._my_turn():
			return

static func run_menu(host: Node) -> Array:
	var fails: Array = []
	await start_offline(host)
	var s := attach(host, BattleScreen.new("table")) as BattleScreen
	await _until_my_turn(host, s)
	s.menu_btn.tapped.emit()
	await _frames(host, 2)
	if s.menu == null:
		fails.append("메뉴가 안 열림")
		return fails
	var log_btn = _find_meta(s.menu, "item", "로그 보기")
	if log_btn == null:
		fails.append("메뉴에 로그 없음")
	else:
		log_btn.tapped.emit()
		await _frames(host, 2)
		if s.menu == null or int(s.menu.get_meta("log_lines", 0)) < 3:
			fails.append("로그 줄이 없음")
	if s.menu:
		_find_meta(s.menu, "close").tapped.emit()
		await _frames(host, 2)
	if s.menu != null:
		fails.append("메뉴가 안 닫힘")
	# 항복: 한 번 누르면 확인 문구, 두 번째에 항복
	s.open_menu()
	await _frames(host, 2)
	var cb = _find_meta(s.menu, "item", "항복")
	if cb == null:
		fails.append("메뉴에 항복 없음")
		return fails
	cb.tapped.emit()
	await _frames(host, 3)
	if Net.view.get("result") != null:
		fails.append("한 번 눌렀는데 항복됨")
	cb.tapped.emit()
	await _frames(host, 6)
	var res = Net.view.get("result")
	if res == null or int(res.winner) == Net.seat:
		fails.append("두 번 눌러도 항복 안 됨: %s" % str(res))
	print("[ui-tests] 메뉴: 로그·닫기·항복 2단계 %s" % ("정상" if fails.is_empty() else "문제"))
	s.queue_free()
	await _frames(host)
	return fails

## 자동 진행만으로 한 판 끝까지 (내 손 안 대고)
static func run_auto(host: Node) -> Array:
	var fails: Array = []
	await start_offline(host)
	var s := attach(host, BattleScreen.new("table")) as BattleScreen
	s.auto_btn.tapped.emit()
	await _frames(host, 2)
	if not s.auto_play:
		fails.append("자동 버튼이 안 켜짐")
	var t0 := Time.get_ticks_msec()
	for i in 40000:
		await _frames(host, 1)
		if Net.view.get("result") != null:
			break
		if i % 20 == 0:
			for p in check_render(s):
				if fails.size() < 6:
					fails.append("자동 그리기: " + p)
		if Time.get_ticks_msec() - t0 > 300000:
			break
	var res = Net.view.get("result")
	if res == null:
		fails.append("자동 진행으로 게임이 끝나지 않음 (턴 %s)" % str(Net.view.get("turnNumber")))
	print("[ui-tests] 자동 진행: %s (%.0f초)" % [str(res.get("reason")) if res != null else "끝나지 않음", (Time.get_ticks_msec() - t0) / 1000.0])
	s.queue_free()
	await _frames(host)
	return fails

## 앱 흐름: 대전 준비 → (AI 연습) 새 탁자 화면 → 항복 → 다시 하기 → 대전 준비
static func run_flow(host: Node) -> Array:
	var fails: Array = []
	Net.leave()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LocalGame.SAVE_PATH))
	Net.start_offline()
	Nav.push(LobbyScreen.new(), false)
	Net.send({ "t": "aiSpeed", "ms": 0 })
	Net.send({ "t": "chooseDeck", "deckId": "gardevoir", "prints": {} })
	await _frames(host, 3)
	Net.send({ "t": "ready", "ready": true })
	for i in 40:
		await host.get_tree().create_timer(0.1).timeout
		if Nav.current() is BattleScreen:
			break
	if not (Nav.current() is BattleScreen):
		fails.append("AI 연습이 새 탁자 화면으로 안 열림 (%s)" % str(Nav.current()))
		return fails
	var s := Nav.current() as BattleScreen
	if s.mode != "table":
		fails.append("AI 연습인데 모드가 %s" % s.mode)
	Net.input({ "type": "concede" })
	for i in 60:
		await _frames(host, 1)
		if Net.view.get("result") != null:
			break
	await _frames(host, 3)
	if (s.end_btn.get_meta("label") as Label).text != "다시 하기":
		fails.append("끝난 뒤 다시 하기 버튼이 없음")
	for i in 30:
		await _frames(host, 2)
		if s.result_panel != null:
			break
	if s.result_panel == null:
		fails.append("결과 화면이 안 뜸")
		s.end_btn.tapped.emit()
	else:
		var title: String = (s.result_panel.find_children("*", "Label", true, false)[0] as Label).text
		if title != "패배":
			fails.append("항복했는데 결과가 %s" % title)
		_find_meta(s.result_panel, "result", "again").tapped.emit()
	for i in 40:
		await host.get_tree().create_timer(0.1).timeout
		if Nav.current() is LobbyScreen:
			break
	if not (Nav.current() is LobbyScreen):
		var cur = Nav.current()
		fails.append("다시 하기 → 대전 준비로 안 돌아감 (맨 위 %s, 깊이 %d, 바쁨 %s, 로비 단계 %s, 결과 %s, 버튼 %s)" % [cur.get_script().get_global_name() if cur and cur.get_script() else str(cur), Nav.depth(), Nav._busy, str(Net.lobby.get("phase")), str(Net.view.get("result")), (s.end_btn.get_meta("label") as Label).text])
	print("[ui-tests] 앱 흐름: 대전 준비 → 탁자 → 항복 → 다시 하기 → 대전 준비 %s" % ("정상" if fails.is_empty() else "문제"))
	while Nav.depth() > 1:
		Nav.pop()
		await host.get_tree().create_timer(0.4).timeout
	return fails

# ───────────────────────── 6단계: 연출 ─────────────────────────

## 연출을 켠 채(2배속) 자동 진행으로 끝까지: 연출이 멈춘 순간마다 화면 == 상태, 남은 지연·기절 칸 없음, 누르면 건너뛰기
static func run_fx(host: Node) -> Array:
	var fails: Array = []
	await start_offline(host)
	Net.send({ "t": "aiSpeed", "ms": 250 })
	await _frames(host, 2)
	var s := attach(host, BattleScreen.new("table")) as BattleScreen
	s.auto_btn.tapped.emit()
	var t0 := Time.get_ticks_msec()
	var idle_checks := 0
	var skipped := false
	var was_busy := false
	var think_seen := 0
	var recent_seen := 0
	var shown_idle := {}
	var early_req := false
	for i in 200000:
		await _frames(host, 1)
		var v: Dictionary = Net.view
		if v.get("result") != null and not s.fx.busy():
			break
		var busy: bool = s.fx.busy()
		# 새 선택 요청은 연출이 끝난 뒤에만 뜬다 (연출 중 떠 있는 창은 연출 전부터 있던 것)
		var sk_id: String = s.sheet_key.get_slice("|", 0)
		if not busy:
			if sk_id != "":
				shown_idle[sk_id] = true
		elif sk_id != "" and not shown_idle.has(sk_id) and not early_req:
			early_req = true
			fails.append("연출 중에 새 선택 창이 먼저 뜸 (%s)" % str(s.my_request().get("kind") if s.my_request() else "-"))
		if busy and not skipped and not s._my_turn() and s.fx.catcher and s.fx.catcher.visible and int(v.get("turnNumber", 0)) >= 6:
			# 상대 차례 연출 중 화면을 누르면 건너뛰기
			skipped = true
			var before := Time.get_ticks_msec()
			s.fx.catcher.tapped.emit()
			for k in 120:
				await _frames(host, 1)
				if not s.fx.busy():
					break
			if s.fx.busy():
				fails.append("누르기로 연출이 건너뛰어지지 않음")
			print("[ui-tests] 연출 건너뛰기: %.2f초" % ((Time.get_ticks_msec() - before) / 1000.0))
		if was_busy and not busy:
			# 연출이 막 끝남: 화면 == 상태
			await host.get_tree().create_timer(0.3).timeout
			# 자리 이동(미끄러짐)이 끝날 때까지 (연출이 없는 사건 직후에는 이동만 진행 중일 수 있음)
			for k in 20:
				var moving := s.slots.values().any(func(n): return n.has_meta("pos_tw") and (n.get_meta("pos_tw") as Tween).is_valid() and (n.get_meta("pos_tw") as Tween).is_running())
				if not moving:
					break
				await host.get_tree().create_timer(0.05).timeout
			if not s.fx.busy():
				idle_checks += 1
				if not s.fx.pending_hp.is_empty():
					fails.append("연출 후 HP 지연이 남음 %s" % JSON.stringify(s.fx.pending_hp))
				if not s.fx.hold.is_empty():
					fails.append("연출 후 기절 칸이 남음 %s" % JSON.stringify(s.fx.hold.keys()))
				for p in check_render(s):
					if fails.size() < 10:
						fails.append("연출 후 그리기: " + p)
				# 상대 상태: AI 차례에 연출이 끝났으면 "AI 생각 중…", 덱 5장 이하면 경고색
				v = Net.view     # 기다리는 동안 상태가 바뀌었을 수 있음
				var th: bool = str(v.get("phase")) == "playing" and v.get("turnPlayer") != null and not s._my_turn() and s.my_request() == null
				if th != (s.chips.text == "AI 생각 중…"):
					if fails.size() < 10:
						fails.append("생각 중 표시 '%s' (기대 %s, 지금 계산 '%s', 판 %s/%s, 단계 %s)" % [s.chips.text, th, s.thinking_text(), v.version, s._fed_version, str(v.get("phase"))])
				if th:
					think_seen += 1
				# 최근 행동 타일: 연출 끝난 사건만, 최근 것부터, 가운데 띠 안 · 스타디움과 안 겹침
				var rev: Array = s.recent_events()
				var shown: Array = s.recent_tiles.filter(func(t): return t.visible)
				if shown.size() != mini(rev.size(), shown.size()) or (rev.size() > 0 and shown.is_empty()):
					if fails.size() < 10:
						fails.append("최근 행동 타일 %d개 (사건 %d개)" % [shown.size(), rev.size()])
				for ti in shown.size():
					var tl: BCard = shown[ti]
					if tl.code != str(rev[ti].code) or int(rev[ti].seq) > s.fx.played_seq:
						if fails.size() < 10:
							fails.append("최근 행동 타일 %d: %s ≠ %s" % [ti, tl.code, str(rev[ti].code)])
					var mr: Rect2 = s.L.mid
					var tr := Rect2(tl.position, tl.size)
					if not mr.grow(1).encloses(tr) or tr.intersects(s.L.stadium):
						if fails.size() < 10:
							fails.append("최근 행동 타일 %d 위치 %s (띠 %s)" % [ti, tr, mr])
				recent_seen = maxi(recent_seen, shown.size())
				for side in ["my", "opp"]:
					var pv: Dictionary = s._me() if side == "my" else s._opp()
					var pl: BPile = s.piles[side + "_deck"]
					if pl.low != (int(pv.deckCount) <= BPile.LOW_DECK):
						if fails.size() < 10:
							fails.append("덱 경고 %s: 덱 %d, 경고 %s" % [side, int(pv.deckCount), pl.low])
		was_busy = busy
		if Time.get_ticks_msec() - t0 > 600000:
			fails.append("연출 테스트 시간 초과 (턴 %s)" % str(v.get("turnNumber")))
			break
	var c: Dictionary = s.fx.counts
	if c.is_empty():
		# 가끔 전체 실행에서만 재생 0 이 나옴 → 다음에 원인을 볼 수 있게 상태를 남긴다
		fails.append("연출 재생 0: 턴 %s, 결과 %s, 사건 %d개(마지막 seq %s), fx last_seq %d, fed %d, 화면 트리 안 %s, Nav 깊이 %d" % [
			str(Net.view.get("turnNumber")), str(Net.view.get("result") != null), Net.events_log.size(),
			str(Net.events_log[-1].get("seq")) if not Net.events_log.is_empty() else "-", s.fx.last_seq, s._fed_version,
			str(s.is_inside_tree()), Nav.depth()])
	for need in ["turnStart", "play", "attack", "damage", "move"]:
		if int(c.get(need, 0)) == 0:
			fails.append("연출 안 된 사건: %s" % need)
	if Net.view.get("result") == null:
		fails.append("연출 테스트: 게임이 끝나지 않음")
	# 공격 연출 (docs/fx-hearthstone-review.md): 등급 경계, 기술 → 피해 충돌 동기화, 판 흔들림 후 제자리
	for tc in [[10, false, 0], [30, false, 0], [40, false, 1], [90, false, 1], [100, false, 2], [190, false, 2], [200, false, 3], [10, true, 3]]:
		if BFx.tier(tc[0], tc[1]) != tc[2]:
			fails.append("피해 등급 %d%s → %d (기대 %d)" % [tc[0], " 기절" if tc[1] else "", BFx.tier(tc[0], tc[1]), tc[2]])
	var imp: Array = s.fx.impacts
	var synced := imp.filter(func(x): return x.synced).size()
	var tiers := {}
	for x in imp:
		tiers[int(x.tier)] = int(tiers.get(int(x.tier), 0)) + 1
	if synced == 0:
		fails.append("기술과 피해가 한 번도 동기화되지 않음 (충돌 %d번)" % imp.size())
	if s.board.position != Vector2.ZERO:
		fails.append("판 흔들림 뒤 판이 제자리가 아님 %s" % s.board.position)
	# 8) 약점·저항: 약점이면 한 등급 위, 숫자 아래 보조 표시, 기록 줄
	for tc in [[{ "amount": 60, "weak": true }, 2], [{ "amount": 30, "weak": true }, 1], [{ "amount": 200, "weak": true }, 3], [{ "amount": 20, "resist": true }, 0]]:
		if BFx.tier_of(tc[0]) != tc[1]:
			fails.append("약점·저항 등급 %s → %d (기대 %d)" % [JSON.stringify(tc[0]), BFx.tier_of(tc[0]), tc[1]])
	if BFx.wr_label({ "weak": true }) != "약점 ×2" or BFx.wr_label({ "resist": true }) != "저항 −30" or BFx.wr_label({}) != "":
		fails.append("약점·저항 표시 글자가 다름")
	if not BLog.line({ "type": "damage", "player": 0, "sid": "s1", "amount": 60, "weak": true }, 0).contains("약점"):
		fails.append("기록 줄에 약점 표시 없음")
	var wr_events := Net.events_log.filter(func(x): return str(x.get("type", "")) == "damage" and (bool(x.get("weak", false)) or bool(x.get("resist", false)))).size()
	if not s.slots.is_empty():
		var sid0: String = str(s.slots.keys()[0])
		s.fx._number(sid0, "-120", Color.RED, 2, "약점 ×2")
		var found := s.fx_layer.get_children().any(func(ch): return ch.has_meta("fx_wr") and str(ch.get_meta("fx_wr")) == "약점 ×2")
		if not found:
			fails.append("숫자 아래 약점 표시가 그려지지 않음")
	# 9) 반복 가속: 3번째부터 0.75배, 5번째부터 0.5배 (승부를 가르는 마지막 기절은 1배)
	for tc in [[1, 1.0], [2, 1.0], [3, 0.75], [4, 0.75], [5, 0.5], [9, 0.5]]:
		if BFx.accel_for(tc[0]) != tc[1]:
			fails.append("반복 가속 %d번째 → %s (기대 %s)" % [tc[0], BFx.accel_for(tc[0]), tc[1]])
	var al: Array = s.fx.accel_log
	var fast := 0
	for x in al:
		var want := BFx.accel_for(int(x.n))
		if float(x.accel) < 1.0:
			fast += 1
		if float(x.accel) != want and not (str(x.key) == "ko" and float(x.accel) == 1.0):
			fails.append("반복 가속 기록 이상 %s" % JSON.stringify(x))
			break
	if s.fx._accel != 1.0:
		fails.append("연출이 끝났는데 반복 가속이 남음 %s" % s.fx._accel)
	print("[ui-tests] AI 생각 중 표시 확인 %d번" % think_seen)
	if think_seen == 0:
		fails.append("AI 차례에 '생각 중' 표시를 한 번도 확인하지 못함")
	# 최근 행동 타일 탭 → 그 카드들 크게 + 기록 한 줄
	if recent_seen == 0:
		fails.append("최근 행동 타일이 한 번도 보이지 않음")
	elif not s.recent_evs.is_empty():
		var z: BZoom = s.open_recent(0)
		await _frames(host, 2)
		var want: String = BLog.line(s.recent_evs[0], Net.seat).strip_edges()
		if z == null or not z.info_text().contains(want) or z.list.size() != s.recent_evs.size():
			fails.append("최근 행동 크게 보기: '%s' (기대 '%s')" % [z.info_text() if z else "없음", want])
		if z:
			z.queue_free()
			await _frames(host, 2)
	print("[ui-tests] 최근 행동 타일 최대 %d개" % recent_seen)
	var bp := BPile.new()
	for tc in [["deck", 5, true], ["deck", 0, true], ["deck", 6, false], ["discard", 2, false]]:
		bp.set_pile(tc[0], tc[1])
		if bp.low != tc[2]:
			fails.append("덱 경고 %s %d → %s (기대 %s)" % [tc[0], tc[1], bp.low, tc[2]])
	bp.free()
	print("[ui-tests] 약점·저항 사건 %d개 (표시 %d), 반복 가속 %d/%d개" % [wr_events, s.fx.wr_shown.size(), fast, al.size()])
	print("[ui-tests] 공격 연출: 충돌 %d번 (기술과 동기화 %d), 등급별 %s" % [imp.size(), synced, JSON.stringify(tiers)])
	print("[ui-tests] 연출(2배속): %.0f초, 연출 후 검사 %d번, 재생 %s" % [(Time.get_ticks_msec() - t0) / 1000.0, idle_checks, JSON.stringify(c)])
	s.queue_free()
	await _frames(host)
	return fails

## 창 모드: 연출 중 장면 몇 장 저장 (user://fx_N.png)
static func fx_shots(host: Node) -> void:
	await start_offline(host)
	Net.send({ "t": "aiSpeed", "ms": 700 })
	var s := attach(host, BattleScreen.new("table")) as BattleScreen
	s.auto_btn.tapped.emit()
	var n := 0
	var t0 := Time.get_ticks_msec()
	var last_kind := ""
	while n < 8 and Time.get_ticks_msec() - t0 < 240000:
		await host.get_tree().create_timer(0.12).timeout
		var c: Dictionary = s.fx.counts
		var kind := ""
		for k in ["attack", "ko", "coin", "damage", "play", "turnStart"]:
			if int(c.get(k, 0)) > int(s.get_meta("seen_" + k, 0)):
				kind = k
				s.set_meta("seen_" + k, int(c.get(k, 0)))
				break
		if kind != "" and s.fx.busy() and int(Net.view.get("turnNumber", 0)) >= 3 and (kind != last_kind or kind in ["ko", "coin"]):
			last_kind = kind
			await host.get_tree().create_timer(0.15).timeout
			host.get_viewport().get_texture().get_image().save_png("user://fx_%d_%s.png" % [n, kind])
			print("[ui-tests] 연출 장면 저장: fx_%d_%s.png" % [n, kind])
			n += 1

## 창 모드: 준비 단계(손패에서 고르기) · 결과 화면 저장
static func setup_shots(host: Node) -> void:
	await start_offline(host)
	var s := attach(host, BattleScreen.new("table")) as BattleScreen
	for i in 200:
		await _frames(host, 1)
		var r = s.my_request()
		if r != null and str(r.kind) == "chooseActive":
			break
		if r != null:
			Net.input({ "type": "choice", "requestId": r.id, "picks": (r.options as Array).slice(0, maxi(1, int(r.min))) })
			await _frames(host, 3)
	await host.get_tree().create_timer(0.8).timeout
	host.get_viewport().get_texture().get_image().save_png("user://setup_active.png")
	print("[ui-tests] 준비 단계 화면 저장")
	Net.input({ "type": "concede" })
	await host.get_tree().create_timer(1.2).timeout
	host.get_viewport().get_texture().get_image().save_png("user://result.png")
	print("[ui-tests] 결과 화면 저장")

# ───────────────────────── 8단계: 서버 대전 (손패 모드) ─────────────────────────

## 실제 서버에 참가해 상대(TS AI)와 끝까지: scripts/lan-e2e.ts 가 서버·상대를 띄우고 부른다
static func run_lan(host: Node, addr: String, code: String) -> Array:
	var fails: Array = []
	Net.leave()
	Net.join(addr, code)
	for i in 100:
		await host.get_tree().create_timer(0.1).timeout
		if Net.seat >= 0 and not Net.lobby.is_empty():
			break
	if Net.seat < 0:
		fails.append("서버 참가 실패: %s" % JSON.stringify(Net.last_error))
		return fails
	Nav.push(LobbyScreen.new(), false)
	Net.send({ "t": "chooseDeck", "deckId": "gardevoir", "prints": {} })
	await host.get_tree().create_timer(0.3).timeout
	Net.send({ "t": "ready", "ready": true })
	for i in 200:
		await host.get_tree().create_timer(0.1).timeout
		if Nav.current() is BattleScreen:
			break
	if not (Nav.current() is BattleScreen):
		fails.append("게임 화면이 안 열림 (%s, 로비 %s)" % [str(Nav.current()), str(Net.lobby.get("phase"))])
		return fails
	var s := Nav.current() as BattleScreen
	if s.mode != "hand":
		fails.append("서버 대전인데 모드가 %s" % s.mode)
	await host.get_tree().create_timer(0.5).timeout
	var d := LocalGame.data()
	var bot: Callable = GBot.makeAiBot(d.cat, d.info.db)
	var rng := GRng.seedRng("1a2b")
	var last := -1
	var steps := 0
	var kinds := {}
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 600000:
		await host.get_tree().create_timer(0.05).timeout
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
			fails.append("서버 대전 조작 %d (턴 %d): %s" % [steps, int(v.turnNumber), err])
			if fails.size() > 8:
				break
			if s.last_sent.is_empty():
				Net.input(inp)
		for p in check_render(s):
			if fails.size() < 12:
				fails.append("서버 대전 그리기: " + p)
	var res = Net.view.get("result")
	if res == null:
		fails.append("서버 대전: 게임이 끝나지 않음")
	print("[ui-tests] 서버 대전(손패 모드): %d번 %s, 결과 %s" % [steps, JSON.stringify(kinds), str(res.get("reason")) if res != null else "-"])
	# 결과 화면 → 나가기 → 첫 화면
	for i in 60:
		await host.get_tree().create_timer(0.1).timeout
		if s.result_panel != null:
			break
	if s.result_panel == null:
		fails.append("서버 대전: 결과 화면이 안 뜸 (연출 중 %s, 재생 중 %s, 남은 사건 %d, 화면 %s, 판 %s/%s)" % [s.fx.busy(), s.fx.playing, s.fx.queue.size(), str(Nav.current()), Net.view.get("version"), s._fed_version])
		return fails
	var out = _find_meta(s.result_panel, "result", "leave")
	if out == null:
		fails.append("서버 대전 결과에 나가기 없음")
		return fails
	out.tapped.emit()
	for i in 40:
		await host.get_tree().create_timer(0.1).timeout
		if Nav.depth() == 1:
			break
	if Nav.depth() != 1 or Net.seat != -1:
		fails.append("나가기 후 첫 화면으로 안 돌아감 (깊이 %d, 자리 %d)" % [Nav.depth(), Net.seat])
	print("[ui-tests] 서버 대전 결과 → 나가기 → 첫 화면 %s" % ("정상" if fails.is_empty() else "문제"))
	return fails

# ───────────────────────── 9단계: 화면 크기 ─────────────────────────

## 작은 폰·태블릿 크기에서 실제 게임: 칸·손패·버튼이 화면 안, 상태와 일치
static func run_sizes(host: Node) -> Array:
	var fails: Array = []
	for sz in [Vector2(720, 1280), Vector2(1100, 1560), Vector2(720, 1700)]:
		for mode in ["table", "hand"]:
			await start_offline(host)
			var box := Control.new()
			box.size = sz
			box.clip_contents = true
			host.add_child(box)
			var s := BattleScreen.new(mode)
			s.set_anchors_preset(Control.PRESET_FULL_RECT)
			box.add_child(s)
			var d := LocalGame.data()
			var bot: Callable = GBot.makeAiBot(d.cat, d.info.db)
			var rng := GRng.seedRng("51fe")
			var last := -1
			var checks := 0
			for i in 3000:
				await _frames(host, 1)
				var v: Dictionary = Net.view
				if v.is_empty():
					continue
				if v.get("result") != null or int(v.turnNumber) >= 12:
					break
				for p in check_render(s):
					if fails.size() < 12:
						fails.append("%s %s: %s" % [mode, sz, p])
				var screen := Rect2(Vector2.ZERO, sz)
				for n in s.slots.values():
					if (n as Control).visible and not screen.encloses((n as Control).get_rect().grow(-1)):
						if fails.size() < 12:
							fails.append("%s %s: 칸이 화면 밖 %s" % [mode, sz, (n as Control).get_rect()])
				if not screen.encloses(Rect2(s.end_btn.position, s.end_btn.get_combined_minimum_size()).grow(-1)):
					if fails.size() < 12:
						fails.append("%s %s: 턴 종료 버튼이 화면 밖" % [mode, sz])
				checks += 1
				if int(v.version) != last and GBot.botHasWork(v):
					last = int(v.version)
					var inp = bot.call(v.duplicate(true), rng)
					if inp != null:
						Net.input(inp)
			print("[ui-tests] 화면 크기 %s %s: 검사 %d번" % [mode, sz, checks])
			box.queue_free()
			await _frames(host)
	return fails

## 실제로 그려지는 z (z_as_relative 누적)
static func _abs_z(n: CanvasItem) -> int:
	var z := 0
	var c: Node = n
	while c is CanvasItem:
		z += (c as CanvasItem).z_index
		if not (c as CanvasItem).z_as_relative:
			break
		c = c.get_parent()
	return z

# ───────────────────── 하스스톤식 안내: 턴 종료 강조·준비된 포켓몬·못 쓰는 이유·판 보기 ─────────────────────

## 판정 함수 단위 검사 (가짜 보기)
static func run_hint_units() -> Array:
	var fails: Array = []
	var A := func(kinds: Array) -> Array: return kinds.map(func(k): return { "kind": k })
	if not BHint.only_end_left(A.call(["concede", "endTurn"])):
		fails.append("턴 종료만 남았는데 강조 안 함")
	if not BHint.only_end_left(A.call(["concede", "retreat", "endTurn"])):
		fails.append("후퇴만 남았는데 강조 안 함")
	if BHint.only_end_left(A.call(["concede", "attack", "endTurn"])):
		fails.append("기술이 남았는데 강조함")
	if BHint.only_end_left(A.call(["concede"])):
		fails.append("상대 차례(턴 종료 없음)인데 강조함")
	var acts := [{ "kind": "ability", "target": "b1" }, { "kind": "attack" }]
	if not BHint.slot_ready(acts, "a1", "a1") or not BHint.slot_ready(acts, "b1", "a1") or BHint.slot_ready(acts, "b2", "a1"):
		fails.append("준비된 포켓몬 판정 틀림")
	# 못 쓰는 이유: 카드 종류별 대표 코드를 데이터에서 찾는다
	var pick := func(test: Callable) -> String:
		var d := LocalGame.data()
		for code in GBot.codeIndex(d.cat, d.info.db):
			if test.call(BData.card(code)):
				return str(code)
		return ""
	var energy: String = pick.call(func(c): return c.get("kind") == "energy")
	var supporter: String = pick.call(func(c): return c.get("kind") == "trainer" and c.get("trainer") == "supporter")
	var stage1: String = pick.call(func(c): return c.get("kind") == "pokemon" and int(c.pokemon.get("stage", 0)) == 1)
	var basic: String = pick.call(func(c): return c.get("kind") == "pokemon" and int(c.pokemon.get("stage", 0)) == 0)
	var me := { "flags": { "energy": true, "supporter": false, "retreat": false, "stadium": false }, "turns": 1, "benchMax": 5, "active": null, "bench": [], "effects": [] }
	var v := { "phase": "playing", "turnPlayer": 0, "firstPlayer": 0, "players": [me, {}], "stadium": null }
	var cases := [
		[energy, "이미 붙였습니다"], [supporter, "선공 플레이어는 첫 턴"], [stage1, "필드에 없습니다"], [basic, "벤치가 가득"],
	]
	for c in cases:
		if c[0] == "":
			fails.append("검사용 카드 없음: %s" % c[1])
			continue
		var why := BHint.why_unusable(v, 0, c[0])
		if not why.contains(c[1]):
			fails.append("못 쓰는 이유 %s: '%s' 에 '%s' 없음" % [BData.name_of(c[0]), why, c[1]])
	me.flags.supporter = true
	me.turns = 3
	if not BHint.why_unusable(v, 0, supporter).contains("이미 썼습니다"):
		fails.append("서포트 사용 후 이유 틀림")
	v.turnPlayer = 1
	if BHint.why_unusable(v, 0, energy) != "상대 차례입니다.":
		fails.append("상대 차례 이유 틀림")
	print("[ui-tests] 안내 판정 단위 검사 %s" % ("정상" if fails.is_empty() else "문제"))
	return fails

## 실제 게임(봇이 둠): 멈춰 있을 때마다 화면 안내 == 판정, 못 쓰는 카드 탭 → 이유 토스트, 선택 창 [판 보기] 왕복
static func run_hints(host: Node, mode: String) -> Array:
	var fails: Array = []
	await start_offline(host)
	var s := attach(host, BattleScreen.new(mode)) as BattleScreen
	var d := LocalGame.data()
	var bot: Callable = GBot.makeAiBot(d.cat, d.info.db)
	var rng := GRng.seedRng("41a7" if mode == "table" else "41a8")
	var last := -1
	var n := { "end_hint": 0, "ready": 0, "why": 0, "why_generic": 0, "peek": 0, "checks": 0, "usable_on": 0 }
	var generic: Array = []
	var add := func(msg: String) -> void:
		if fails.size() < 12:
			fails.append("%s: %s" % [mode, msg])
	for i in 6000:
		await _frames(host, 2)
		var v: Dictionary = Net.view
		if v.is_empty():
			continue
		if v.get("result") != null:
			break
		if int(v.version) == last or not GBot.botHasWork(v):
			continue
		await _frames(host, 2)
		v = Net.view
		var mine := s._my_turn() and s.my_request() == null
		if mine:
			n.checks += 1
			# "고를 수 있는 카드만"은 그 선택에만: 선택이 끝난 뒤 손패는 전부
			var hand_n: int = (v.players[Net.seat].hand as Array).size()
			if s.only_usable or s.hand.order.size() != hand_n:
				add.call("턴 %d: 선택 후에도 고를 수 있는 카드만 (켜짐 %s, 손패 %d/%d)" % [int(v.turnNumber), s.only_usable, s.hand.order.size(), hand_n])
			# 1) 턴 종료 강조 == 남은 수가 턴 종료뿐
			var want := BHint.only_end_left(s.actions())
			if s.end_hint != want:
				add.call("턴 %d: 턴 종료 강조 %s, 판정 %s" % [int(v.turnNumber), s.end_hint, want])
			if want:
				n.end_hint += 1
			# 2) 준비된 포켓몬 틀 == 판정
			var me: Dictionary = v.players[Net.seat]
			var act_sid := str(me.active.sid) if me.get("active") != null else ""
			for sid in s.slots:
				if not s._is_mine(sid):
					continue
				var r := BHint.slot_ready(s.actions(), sid, act_sid)
				var mk: String = s.slots[sid].mark()
				if (mk == "ready") != r:
					add.call("턴 %d: %s 표시 %s, 판정 %s" % [int(v.turnNumber), sid, mk, r])
				if r:
					n.ready += 1
			# 3) 못 쓰는 카드 탭 → 이유 토스트 (선택은 안 됨)
			for iid in s.hand.order:
				if s._moves_for_card(iid).is_empty():
					s.tap_hand(iid)
					var t: String = s.toast.text
					if s.sel_card != "" or t == "":
						add.call("못 쓰는 카드 탭: 선택 %s, 안내 '%s'" % [s.sel_card, t])
					n.why += 1
					if t.begins_with("지금은"):
						n.why_generic += 1
						var gn := BData.name_of(str(s.hand.codes.get(iid, "")))
						if not generic.has(gn):
							generic.append(gn)
					s._clear_select()
					break
		if s.my_request() != null and s.board_pick.get("kind") == "handpick" and not s.only_usable:
			s.only_usable = true
			s._build_request()
			n.usable_on += 1
		# 4) 선택 창이면 [판 보기] → 창 접힘·손패 보임 → [돌아가기] → 창 펼침
		if s.my_request() != null and s.board_pick.is_empty() and is_instance_valid(s.sheet):
			if not s.peek_btn.visible:
				add.call("선택 창에 [판 보기]가 없음 (%s)" % str(s.my_request().kind))
			else:
				s.peek_btn.tapped.emit()
				await _frames(host, 2)
				if s.sheet.visible or not s.peek_back.visible or not s.hand.visible:
					add.call("판 보기: 창 %s, 돌아가기 %s, 손패 %s" % [s.sheet.visible, s.peek_back.visible, s.hand.visible])
				s.peek_back.tapped.emit()
				await _frames(host, 2)
				if not s.sheet.visible or s.peek_back.visible:
					add.call("돌아가기 후 창이 안 펼쳐짐")
				n.peek += 1
				# 사용자가 "고를 수 있는 카드만"을 켠 상태로 답한다
				s.only_usable = true
				s._build_request()
				n.usable_on += 1
		last = int(v.version)
		var inp = bot.call(v.duplicate(true), rng)
		if inp != null:
			Net.input(inp)
	if Net.view.get("result") == null:
		add.call("게임이 끝나지 않음")
	# 턴 종료 강조는 게임에 따라 안 나올 수 있음 (판정 일치는 매번 검사, 강조 자체는 단위 검사)
	if n.checks == 0 or n.ready == 0 or n.peek == 0:
		add.call("검사가 충분히 안 됨 %s" % JSON.stringify(n))
	print("[ui-tests] 안내(%s): %s, 일반 문구 카드 %s" % [mode, JSON.stringify(n), ", ".join(generic)])
	s.queue_free()
	await _frames(host)
	return fails

## 창 모드 화면 저장: 준비된 포켓몬 틀 + 못 쓰는 이유, 턴 종료 강조, 선택 창 [판 보기] / 판 보기 중
static func hint_shots(host: Node) -> void:
	await start_offline(host)
	var s := attach(host, BattleScreen.new("table")) as BattleScreen
	var d := LocalGame.data()
	var bot: Callable = GBot.makeAiBot(d.cat, d.info.db)
	var rng := GRng.seedRng("41a7")
	var last := -1
	var got := {}
	var save := func(name: String) -> void:
		await host.get_tree().create_timer(0.7).timeout
		host.get_viewport().get_texture().get_image().save_png("user://shot_hint_%s.png" % name)
		got[name] = true
		print("[ui-tests] 화면 저장: shot_hint_%s.png" % name)
	for i in 6000:
		await _frames(host, 2)
		var v: Dictionary = Net.view
		if v.is_empty() or v.get("result") != null or got.size() >= 4:
			break
		if int(v.version) == last or not GBot.botHasWork(v):
			continue
		await _frames(host, 4)
		if s._my_turn() and s.my_request() == null:
			if s.end_hint and not got.has("end"):
				await save.call("end")
			elif not got.has("ready") and int(v.turnNumber) >= 5:
				for iid in s.hand.order:
					if s._moves_for_card(iid).is_empty():
						s.tap_hand(iid)
						await save.call("ready")
						s._clear_select()
						break
		elif s.my_request() != null and s.board_pick.is_empty() and is_instance_valid(s.sheet) and not got.has("sheet") and s.sheet.has_meta("covers_hand"):
			await save.call("sheet")
			s.peek_btn.tapped.emit()
			await save.call("peek")
			s.peek_back.tapped.emit()
		last = int(Net.view.version)
		var inp = bot.call(Net.view.duplicate(true), rng)
		if inp != null:
			Net.input(inp)
	s.queue_free()
