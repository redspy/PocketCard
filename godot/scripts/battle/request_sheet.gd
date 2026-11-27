class_name BRequest
## 선택 요청 시트 (아래에서 올라오는 판): 카드 고르기 / 포켓몬 고르기 / 사이드 / 값 / 공개 확인.
## 버튼은 화면(BattleScreen)의 toggle_pick / confirm_request / choose_now 를 부른다 (테스트도 같은 함수를 씀).

const VALUE_LABEL := { "first": "선공", "second": "후공", "ok": "확인", "yes": "예", "no": "아니오" }

## 요청 종류: "prizes" / "slots" / "cards" / "values" / "reveal"
static func kind_of(screen, req: Dictionary) -> String:
	if str(req.kind) == "ackReveal":
		return "reveal"
	if str(req.kind) == "takePrize":
		return "prizes"
	# 준비 단계(배틀·벤치 포켓몬 내기): 손패에서 바로 고른다
	if str(req.kind) in ["chooseActive", "chooseBench"]:
		return "handpick"
	var opts: Array = req.options
	if opts.is_empty():
		# 고를 카드가 없어도 본 카드(예: 덱 위 몇 장)가 실려 있으면 카드 창으로 보여준다 (아래 창 — 다른 카드 고르기와 같은 자리)
		return "cards" if req.get("cards") is Array and (req.cards as Array).size() > 0 else "values"
	if opts.all(func(o): return screen._slot_data(str(o)) != null):
		return "slots"
	var known := code_map(screen, req)
	if opts.all(func(o): return known.has(str(o))):
		return "cards"
	return "values"

## 요청에 실린 카드 + 내 패: iid -> code
static func code_map(screen, req: Dictionary) -> Dictionary:
	var m := {}
	if req.get("cards") is Array:
		for c in req.cards:
			m[str(c.iid)] = str(c.code)
	var h = screen._me().get("hand")
	if h is Array:
		for c in h:
			if not m.has(str(c.iid)):
				m[str(c.iid)] = str(c.code)
	return m

static func build(screen, req: Dictionary) -> Control:
	var root := PanelContainer.new()
	root.add_theme_stylebox_override("panel", UI.sheet_box() if kind_of(screen, req) != "values" else UI.float_box(26))
	var mm := UI.margin(16)
	root.add_child(mm)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	mm.add_child(col)
	var id := str(req.id)
	var opts: Array = req.options
	var mn := int(req.min)
	var mx := int(req.max)
	var p: Array = screen.picks.get(id, [])
	var kind := kind_of(screen, req)
	root.set_meta("kind", kind)
	# 고를 개수: 하나만 고르는 경우·고를 게 없는 경우(0~0)는 생략
	var prompt := str(req.prompt) + ("" if (mn == 1 and mx == 1) or mx <= 0 else ("  (%d개)" % mx if mn == mx else "  (%d~%d개)" % [mn, mx]))
	var w: float = screen.size.x if screen.size.x > 0 else 720.0
	# 줄바꿈 글자의 폭을 처음부터 정해 둔다: 폭이 0인 첫 프레임에 글자가 한 글자씩 세로로 서서 창 내용이 아래로 밀렸다가 돌아오던 것 (카드를 고를 때마다 위아래로 흔들림)
	var text_w: float = (minf(w - 40, 640) if kind == "values" else w) - 44
	var pl := UI.label(prompt, 26, UI.TEXT, HORIZONTAL_ALIGNMENT_LEFT, true)
	pl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pl.custom_minimum_size.x = text_w
	col.add_child(pl)
	match kind:
		"reveal":
			for rv in Net.view.get("reveals", []):
				if str(rv.id) == str(req.get("revealId", "")):
					var why := UI.label(str(rv.get("reason", "")), 22, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true)
					why.size_flags_horizontal = Control.SIZE_EXPAND_FILL
					why.custom_minimum_size.x = text_w
					col.add_child(why)
					var codes: Array = (rv.cards as Array).map(func(c): return str(c.code))
					col.add_child(_strip(screen, codes, codes.map(func(_c): return ""), w * 0.3, func(_i): pass))
			var ok := UI.button("확인", 28, true, true)
			ok.set_meta("val", "ok")
			ok.tapped.connect(func(): screen.choose_now(req, "ok"))
			col.add_child(ok)
			return root
		"cards":
			var cm := code_map(screen, req)
			var shown: Array = []
			if req.get("cards") is Array and (req.cards as Array).size() > 0:
				shown = (req.cards as Array).map(func(c): return str(c.iid))
			else:
				shown = opts.map(func(o): return str(o))
			var usable: Array = shown.filter(func(x): return opts.has(x))
			if usable.size() < shown.size() and not usable.is_empty():
				var tb := UI.button(("✔ 고를 수 있는 카드만 %d/%d" if screen.only_usable else "고를 수 있는 카드만 보기 %d/%d") % [usable.size(), shown.size()], 20, screen.only_usable, screen.only_usable)
				tb.tapped.connect(func():
					screen.only_usable = not screen.only_usable
					screen._build_request())
				col.add_child(tb)
				if screen.only_usable:
					shown = usable
			var codes: Array = shown.map(func(x): return cm.get(x, ""))
			var states: Array = shown.map(func(x): return "on" if p.has(x) else ("" if opts.has(x) else "off"))
			var strip := _strip(screen, codes, states, w * 0.34, func(i):
				if opts.has(shown[i]):
					screen.toggle_pick(req, shown[i]))
			var cells: Array = strip.get_child(0).get_children()
			for i in cells.size():
				cells[i].set_meta("val", shown[i])
			col.add_child(strip)
		"slots":
			var row := HFlowContainer.new()
			row.add_theme_constant_override("h_separation", 10)
			row.add_theme_constant_override("v_separation", 10)
			for o in opts:
				var sid := str(o)
				var s = screen._slot_data(sid)
				var c := BSlot.new()
				c.custom_minimum_size = Vector2(130, 130 * UI.CARD_RATIO)
				c.size = c.custom_minimum_size
				c.set_slot(s, false)
				c.set_mark("pick" if p.has(sid) else "")
				c.card.tapped.connect(func(): screen.toggle_pick(req, sid))
				c.card.set_meta("val", sid)
				c.card.long_pressed.connect(func(): screen.zoom_slot(sid))
				row.add_child(c)
			col.add_child(row)
		"prizes":
			var row := HFlowContainer.new()
			row.add_theme_constant_override("h_separation", 10)
			for o in opts:
				var val := str(o)
				var b := UI.button("사이드 %d" % (int(val) + 1), 24, p.has(val), p.has(val))
				b.set_meta("val", val)
				b.tapped.connect(func(): screen.toggle_pick(req, val))
				row.add_child(b)
			col.add_child(row)
		_:
			var labels: Dictionary = req.labels if req.get("labels") is Dictionary else {}
			var row := HFlowContainer.new()
			row.add_theme_constant_override("h_separation", 10)
			row.add_theme_constant_override("v_separation", 10)
			for o in opts:
				var val := str(o)
				var b := UI.button(str(labels.get(val, VALUE_LABEL.get(val, val))), 26, p.has(val), p.has(val))
				b.set_meta("val", val)
				if mn == 1 and mx == 1:
					b.tapped.connect(func(): screen.choose_now(req, val))
				else:
					b.tapped.connect(func(): screen.toggle_pick(req, val))
				row.add_child(b)
			col.add_child(row)
			if mn == 1 and mx == 1:
				return root
	var okb := UI.button("결정%s" % ("" if p.is_empty() else " (%d)" % p.size()), 28, true, true)
	UI.set_enabled(okb, p.size() >= mini(mn, opts.size()) and p.size() <= mx)
	okb.set_meta("confirm", true)
	okb.tapped.connect(func(): screen.confirm_request(req))
	col.add_child(okb)
	return root

## 겹친 카드 가로 줄 (탭 = on_tap(i), 길게 = 크게 보기)
static func _strip(screen, codes: Array, states: Array, w: float, on_tap: Callable) -> ScrollContainer:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.custom_minimum_size = Vector2(0, w * UI.CARD_RATIO + 24)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", -int(w * 0.22))
	sc.add_child(row)
	for i in codes.size():
		var k := i
		var c := BCard.new()
		c.custom_minimum_size = Vector2(w, w * UI.CARD_RATIO)
		c.set_card(str(codes[i]))
		var st: String = states[i] if i < states.size() else ""
		c.set_mark("pick" if st == "on" else ("dim" if st == "off" else ""))
		c.tapped.connect(func(): on_tap.call(k))
		c.long_pressed.connect(func(): BZoom.open(screen.sheet_layer, codes, k))
		row.add_child(c)
	return sc

## 탁자에서 직접 고를 때 위에 뜨는 안내 띠 (안내 + 고른 수 + 결정)
static func pick_bar(screen, req: Dictionary) -> Control:
	var root := PanelContainer.new()
	root.add_theme_stylebox_override("panel", UI.float_box(18, UI.HILITE, 3))   # 불투명: 뒤 상태 글자가 비치지 않게. 테두리 = 고를 대상과 같은 색
	var mm := UI.margin(12)
	root.add_child(mm)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	mm.add_child(row)
	var id := str(req.id)
	var mn := int(req.min)
	var mx := int(req.max)
	var p: Array = screen.picks.get(id, [])
	var single := mn == 1 and mx == 1
	# 안내문에 이미 범위가 있는 경우가 많아(예: 0~5장) 여기서는 고른 수와 최대만
	var txt := str(req.prompt) + ("" if single else "
%d장 고름 (최대 %d장)" % [p.size(), mx])
	var l := UI.label(txt, 22, UI.TEXT, HORIZONTAL_ALIGNMENT_LEFT, true)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size.x = 300
	row.add_child(l)
	if not single:
		var okb := UI.button("결정", 24, true, true)
		okb.set_meta("confirm", true)
		UI.set_enabled(okb, p.size() >= mini(mn, (req.options as Array).size()) and p.size() <= mx)
		okb.tapped.connect(func(): screen.confirm_request(req))
		row.add_child(okb)
	root.set_meta("kind", "board")
	return root
