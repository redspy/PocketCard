class_name GameScreen
extends Control
## 대전 화면 (폰): 서버가 보낸 내 시점 view 만으로 그린다 (규칙·합법 행동은 서버가 판단).
##  - 위: 상태 (턴·차례·덱·사이드·상대 패·이번 턴 사용 기록), 오류/결과
##  - 선택 요청 패널: 카드 / 포켓몬 / 사이드 / 값
##  - 행동 막대: 기술·특성·후퇴·스타디움
##  - 탭: 패(큰 카드 가로 스크롤, 누르면 그 카드의 행동) / 필드 / 트래쉬 / 로그
##  - 아래: 턴 종료 · 항복

const VALUE_LABEL := { "first": "선공", "second": "후공", "ok": "확인", "yes": "예", "no": "아니오" }
const COND_LABEL := { "asleep": "잠듦", "paralyzed": "마비", "confused": "혼란" }

var _status: Label
var _err: Label
var _req_box: VBoxContainer
var _bar: HFlowContainer
var _tabs: HBoxContainer
var _content: VBoxContainer
var _scroll: ScrollContainer
var _btn_end: TapArea
var _btn_concede: TapArea
var _btn_again: TapArea          # AI 연습: 끝난 뒤 다시 하기
var _field_box: VBoxContainer    # AI 연습: 게임판 대신 양쪽 필드를 늘 보여줌
var _tab := "hand"
var _picks: Dictionary = {}       # request id -> Array[String]
var _selected := ""               # 패에서 고른 카드 iid
var _built: Dictionary = {}       # 부분별로 마지막에 그린 내용 (같으면 다시 그리지 않음)
var _confirm_end := 0
var _confirm_concede := 0
var _hscroll: Dictionary = {}     # 카드 줄 이름 → 가로 스크롤 위치 (다시 그려도 보던 자리 유지)
var _only_usable := false         # 카드 고르기·패: 고를 수 있는(쓸 수 있는) 카드만 보기 (기본: 전체)
var _strip_key := ""
var _strip_swipe := Callable()     # 다음 _strip 의 카드 스와이프 처리 (idx, delta)
var _last_seq := -1               # 스포트라이트로 이미 보여준 마지막 사건
var _spot: Control                # AI 행동 스포트라이트 (누름은 통과)
var _btn_speed: TapArea           # AI 연습: AI 속도             # 다음 _strip 의 줄 이름

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = UI.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var layout := VBoxContainer.new()
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	layout.add_theme_constant_override("separation", 0)
	add_child(layout)

	var head := PanelContainer.new()
	var sb := UI.box(UI.BG_DEEP, 0)
	sb.content_margin_top = UI.safe_top(self) + 14
	sb.content_margin_bottom = 12
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	head.add_theme_stylebox_override("panel", sb)
	var hv := VBoxContainer.new()
	head.add_child(hv)
	_status = UI.label("", 26, UI.TEXT)
	hv.add_child(_status)
	_err = UI.label("", 22, Color(1, 0.55, 0.5), HORIZONTAL_ALIGNMENT_LEFT, true)
	_err.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hv.add_child(_err)
	layout.add_child(head)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.scroll_deadzone = 12
	layout.add_child(_scroll)
	var m := UI.margin(18)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	m.add_child(col)
	_req_box = VBoxContainer.new()
	_req_box.add_theme_constant_override("separation", 12)
	col.add_child(_req_box)
	_field_box = VBoxContainer.new()
	_field_box.add_theme_constant_override("separation", 8)
	col.add_child(_field_box)
	_bar = HFlowContainer.new()
	_bar.add_theme_constant_override("h_separation", 10)
	_bar.add_theme_constant_override("v_separation", 10)
	col.add_child(_bar)
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 8)
	col.add_child(_tabs)
	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 12)
	col.add_child(_content)

	var foot := PanelContainer.new()
	var fs := UI.box(UI.BG_DEEP, 0)
	fs.content_margin_top = 12
	fs.content_margin_bottom = UI.safe_bottom(self) + 12
	fs.content_margin_left = 16
	fs.content_margin_right = 16
	foot.add_theme_stylebox_override("panel", fs)
	var fr := HBoxContainer.new()
	fr.add_theme_constant_override("separation", 14)
	fr.alignment = BoxContainer.ALIGNMENT_CENTER
	foot.add_child(fr)
	_btn_end = UI.button("턴 종료", 28, true, true)
	_btn_concede = UI.button("항복", 26)
	fr.add_child(_btn_end)
	fr.add_child(_btn_concede)
	_btn_again = UI.button("다시 하기", 28, true, true)
	_btn_again.visible = false
	_btn_again.tapped.connect(func(): Net.send({ "t": "rematch" }))
	fr.add_child(_btn_again)
	_btn_speed = UI.button("AI 속도", 22)
	_btn_speed.visible = Net.solo
	_btn_speed.tapped.connect(func(): Net.cycle_ai_speed())
	fr.add_child(_btn_speed)
	_btn_end.tapped.connect(_end_turn)
	_btn_concede.tapped.connect(_concede)
	layout.add_child(foot)

	Net.changed.connect(_refresh)
	_last_seq = _max_seq()     # 들어오기 전 일은 스포트라이트로 다시 보여주지 않는다
	_refresh()

func _exit_tree() -> void:
	if Net.changed.is_connected(_refresh):
		Net.changed.disconnect(_refresh)
	ImageCache.trim_thumbs()
	ImageCache.trim(0)

## 게임 중에는 뒤로 가기로 나가지 않는다 (실수 방지)
func on_back() -> bool:
	# AI 연습이 끝났으면 뒤로 가기 = 대전 준비로
	if Net.solo and Net.view.get("result") != null:
		Net.send({ "t": "rematch" })
		return true
	_err.text = "게임 중에는 뒤로 갈 수 없습니다. 끝내려면 [항복]을 누르세요."
	return true

func _actions() -> Array:
	var a = Net.view.get("actions")
	return a if a is Array else []

func _has_kind(kind: String) -> bool:
	for a in _actions():
		if str(a["kind"]) == kind:
			return true
	return false

# ───────────────────────── 갱신 ─────────────────────────

func _refresh() -> void:
	if not is_inside_tree():
		return
	# AI 연습에서 다시 하기 → 대전 준비 화면으로
	if Net.solo and str(Net.lobby.get("phase", "game")) != "game" and Nav.current() == self:
		Nav.pop()
		return
	var v: Dictionary = Net.view
	if v.is_empty():
		return
	var seat := Net.seat
	var players: Array = v["players"]
	var me: Dictionary = players[seat]
	var opp: Dictionary = players[1 - seat]
	var phase := str(v["phase"])
	var turn_player = v.get("turnPlayer")
	var my_turn: bool = phase == "playing" and turn_player != null and int(turn_player) == seat
	var s := ""
	if phase == "setup":
		s = "게임 준비 중"
	elif phase == "ended":
		s = "게임 종료"
	else:
		s = "턴 %d · %s" % [int(v["turnNumber"]), "내 차례" if my_turn else "상대 차례"]
	if Net.solo:
		s += " · 덱 %d · 사이드 나 %d : AI %d · AI 패 %d" % [int(me["deckCount"]), _count_true(me["prizes"]), _count_true(opp["prizes"]), int(opp["handCount"])]
	else:
		s += "\n덱 %d · 사이드 %d · 상대 사이드 %d · 상대 패 %d" % [int(me["deckCount"]), _count_true(me["prizes"]), _count_true(opp["prizes"]), int(opp["handCount"])]
	if my_turn:
		var fl: Dictionary = me["flags"]
		s += "\n에너지 %s · 서포트 %s · 후퇴 %s" % ["✔" if bool(fl["energy"]) else "○", "✔" if bool(fl["supporter"]) else "○", "✔" if bool(fl["retreat"]) else "○"]
		for e in me["effects"]:
			if str(e["kind"]) == "itemLock":
				s += " · 아이템 잠금"
	if Net.status != "open":
		s += " · 재접속 중…"
	if bool(Net.lobby.get("paused", false)):
		s += " · 상대 재접속 대기"
	_status.text = s
	var res = v.get("result")
	if res != null:
		var w = res.get("winner")
		_err.add_theme_color_override("font_color", UI.ACCENT)
		_err.text = ("무승부" if w == null else ("승리!" if int(w) == seat else "패배")) + " — " + str(res.get("reason", ""))
	elif not Net.last_error.is_empty() and Time.get_ticks_msec() - int(Net.last_error.get("at", 0)) < 6000:
		_err.add_theme_color_override("font_color", Color(1, 0.55, 0.5))
		_err.text = str(Net.last_error.get("message", ""))
	elif _confirm_end == 0 and _confirm_concede == 0:
		_err.text = ""

	UI.set_enabled(_btn_end, _has_kind("endTurn"))
	UI.set_enabled(_btn_concede, _has_kind("concede"))
	var over := v.get("result") != null
	_btn_again.visible = Net.solo and over
	_btn_end.visible = not (Net.solo and over)
	_btn_concede.visible = not (Net.solo and over)
	if Net.solo:
		(_btn_speed.get_meta("label") as Label).text = "AI 속도: %s" % Net.ai_speed_name()
		_check_spot()

	# 부분마다 내용이 바뀔 때만 다시 그린다 — 상대(AI)가 둘 때마다 패까지 다시 만들면
	# 누르고 있던 카드가 사라져 길게 누르기·밀기가 끊긴다
	var acts_json := JSON.stringify(_actions())
	var keys := {
		"req": "%s|%s|%s|%s" % [JSON.stringify(v["requests"]), JSON.stringify(v["reveals"]), JSON.stringify(_picks), _only_usable],
		"field": "%s|%s|%s" % [JSON.stringify(v["players"]), JSON.stringify(v.get("stadium")), JSON.stringify(_opp_actions(2))] if Net.solo else "",
		"bar": acts_json + JSON.stringify(v["requests"]),
		"tabs": "%s|%d" % [_tab, int(me["handCount"])],
		"content": "%s|%s|%s|%s|%s" % [_tab, _selected, JSON.stringify(me.get("hand")), acts_json, _only_usable] + _content_extra(v),
	}
	if keys["req"] != _built.get("req"):
		_build_requests(v, me)
	if keys["field"] != _built.get("field"):
		_build_field(v, me, opp)
	if keys["bar"] != _built.get("bar"):
		_build_bar(v)
	if keys["tabs"] != _built.get("tabs"):
		_build_tabs(me)
	if keys["content"] != _built.get("content"):
		_build_content(v, me, opp)
	_built = keys
	var choosing := false
	for r in v["requests"]:
		if int(r["player"]) == Net.seat and (r as Dictionary).has("options"):
			choosing = true
	_tabs.visible = not (Net.solo and choosing)
	_content.visible = not (Net.solo and choosing)

## 탭별로 내용에 영향을 주는 것 (필드·트래쉬·로그 탭)
func _content_extra(v: Dictionary) -> String:
	match _tab:
		"field": return JSON.stringify(v["players"]) + JSON.stringify(v.get("stadium"))
		"discard":
			var n := ""
			for p in v["players"]:
				n += "|%d" % (p["discard"] as Array).size()
			return n
		"log": return "|%d" % _max_seq()
	return ""

func _count_true(arr: Array) -> int:
	var n := 0
	for x in arr:
		if bool(x):
			n += 1
	return n

## sid → 슬롯 (양쪽 필드)
func _slot_map(v: Dictionary) -> Dictionary:
	var out := {}
	for p in v["players"]:
		var pd: Dictionary = p
		if pd.get("active") != null:
			out[str(pd["active"]["sid"])] = pd["active"]
		for b in pd["bench"]:
			out[str(b["sid"])] = b
	return out

func _top_code(slot: Dictionary) -> String:
	var st = slot.get("stack")
	if st is Array and st.size() > 0:
		return str(st[st.size() - 1]["code"])
	return ""

# ───────────────────────── 선택 요청 ─────────────────────────

func _build_requests(v: Dictionary, me: Dictionary) -> void:
	for c in _req_box.get_children():
		c.queue_free()
	var mine := 0
	for r in v["requests"]:
		var req: Dictionary = r
		if int(req["player"]) == Net.seat and req.has("options"):
			_req_box.add_child(_request_panel(req, v, me))
			mine += 1
	if mine == 0:
		for r in v["requests"]:
			var req: Dictionary = r
			if int(req["player"]) != Net.seat and str(req["kind"]) != "ackReveal":
				_req_box.add_child(UI.label("상대가 고르는 중… (%s)" % str(req["prompt"]), 22, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true))
				break

func _request_panel(req: Dictionary, v: Dictionary, me: Dictionary) -> Control:
	var id := str(req["id"])
	if not _picks.has(id):
		_picks[id] = []
	var picks: Array = _picks[id]
	var opts: Array = req["options"]
	var mn := int(req["min"])
	var mx := int(req["max"])
	var labels: Dictionary = req["labels"] if req.get("labels") is Dictionary else {}

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UI.box(Color(0.96, 0.77, 0.26, 0.12), 18, 3, UI.ACCENT))
	var mm := UI.margin(14)
	panel.add_child(mm)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	mm.add_child(col)
	var prompt := UI.label(str(req["prompt"]) + ("" if (mn == 1 and mx == 1) else "  (%d~%d개)" % [mn, mx]), 24, UI.TEXT, HORIZONTAL_ALIGNMENT_LEFT, true)
	prompt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(prompt)

	# 공개 확인: 공개된 카드
	if req.get("revealId") != null:
		for rv in v["reveals"]:
			if str(rv["id"]) == str(req["revealId"]):
				# 왜 보여주는지 (어떤 카드·특성·기술로, 무엇을 찾아 어디로, 규칙)
				var why := UI.label(str(rv.get("reason", "")), 22, UI.TEXT, HORIZONTAL_ALIGNMENT_LEFT, true)
				why.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				col.add_child(why)
				var codes: Array = []
				for c in rv["cards"]:
					codes.append(str(c["code"]))
				col.add_child(_strip(codes, [], 0.3, func(_i: int): pass))

	# 카드 코드 표 (요청에 실린 카드 + 내 패)
	var code_of := {}
	if req.get("cards") is Array:
		for c in req["cards"]:
			code_of[str(c["iid"])] = str(c["code"])
	var hand = me.get("hand")
	if hand is Array:
		for h in hand:
			if not code_of.has(str(h["iid"])):
				code_of[str(h["iid"])] = str(h["code"])
	var slots := _slot_map(v)
	var kind := "values"
	if str(req["kind"]) == "takePrize":
		kind = "prizes"
	elif not opts.is_empty() and opts.all(func(o): return slots.has(str(o))):
		kind = "slots"
	elif not opts.is_empty() and opts.all(func(o): return code_of.has(str(o))):
		kind = "cards"

	match kind:
		"cards":
			# 덱을 보는 효과: 고를 수 없는 카드도 흐리게 함께 보여줌
			var shown: Array = []
			if req.get("cards") is Array and (req["cards"] as Array).size() > 0:
				for c in req["cards"]:
					shown.append(str(c["iid"]))
			else:
				for o in opts:
					shown.append(str(o))
			var usable: Array = shown.filter(func(x): return opts.has(x))
			if usable.size() < shown.size():
				var total := shown.size()
				col.add_child(_usable_toggle("고를 수 있는", usable.size(), total))
				if _only_usable:
					shown = usable
			var codes: Array = []
			var states: Array = []
			for iid in shown:
				codes.append(code_of.get(iid, ""))
				states.append("on" if picks.has(iid) else ("" if opts.has(iid) else "off"))
			_strip_key = "req:%s:%s" % [id, _only_usable]
			col.add_child(_strip(codes, states, 0.36 if Net.solo else 0.42, func(i: int):
				var iid: String = shown[i]
				if opts.has(iid):
					_toggle(id, iid, mx)))
		"slots":
			var row := HFlowContainer.new()
			row.add_theme_constant_override("h_separation", 10)
			row.add_theme_constant_override("v_separation", 10)
			for o in opts:
				var sid := str(o)
				var tile := _slot_tile(slots[sid], 160.0, false)
				if picks.has(sid):
					_mark_selected(tile)
				elif not picks.is_empty():
					tile.modulate = Color(1, 1, 1, 0.55)
				tile.tapped.connect(func(): _toggle(id, sid, mx))
				row.add_child(tile)
			col.add_child(row)
		"prizes":
			var row := HFlowContainer.new()
			row.add_theme_constant_override("h_separation", 10)
			for o in opts:
				var val := str(o)
				var b := UI.button("사이드 %d" % (int(val) + 1), 24, picks.has(val), picks.has(val))
				b.tapped.connect(func(): _toggle(id, val, mx))
				row.add_child(b)
			col.add_child(row)
		_:
			var row := HFlowContainer.new()
			row.add_theme_constant_override("h_separation", 10)
			row.add_theme_constant_override("v_separation", 10)
			for o in opts:
				var val := str(o)
				var text := str(labels.get(val, VALUE_LABEL.get(val, val)))
				var b := UI.button(text, 26, picks.has(val), picks.has(val))
				if mn == 1 and mx == 1:
					b.tapped.connect(func(): Net.input({ "type": "choice", "requestId": id, "picks": [val] }))
				else:
					b.tapped.connect(func(): _toggle(id, val, mx))
				row.add_child(b)
			col.add_child(row)
			if mn == 1 and mx == 1:
				return panel

	var ok := UI.button("결정%s" % ("" if picks.is_empty() else " (%d)" % picks.size()), 26, true, true)
	UI.set_enabled(ok, picks.size() >= mini(mn, opts.size()) and picks.size() <= mx)
	ok.tapped.connect(func():
		var p: Array = _picks.get(id, [])
		if p.size() < mini(mn, opts.size()) or p.size() > mx:
			return
		Net.input({ "type": "choice", "requestId": id, "picks": p })
		_picks.erase(id))
	col.add_child(ok)
	return panel

func _toggle(id: String, val: String, mx: int) -> void:
	var p: Array = _picks.get(id, [])
	if p.has(val):
		p.erase(val)
	elif mx == 1:
		p = [val]
	elif p.size() < mx:
		p.append(val)
	_picks[id] = p
	_refresh()

# ───────────────────────── AI 연습: 늘 보이는 필드 ─────────────────────────

## 게임판이 없으니 상대·내 필드와 최근 일을 위에 늘 보여준다 (필드 탭으로 가지 않아도 되게)
func _build_field(v: Dictionary, me: Dictionary, opp: Dictionary) -> void:
	for c in _field_box.get_children():
		c.queue_free()
	if not Net.solo:
		return
	# 스크롤 없이 한 화면에: AI 가 최근에 한 일(카드 + 결과), 플레이어마다 한 줄 (배틀 + 벤치를 화면 폭에 맞춰)
	var recent := HBoxContainer.new()
	recent.add_theme_constant_override("separation", 10)
	recent.custom_minimum_size.y = 64.0 * UI.CARD_RATIO   # 높이 고정 (AI 가 둘 때마다 아래 패가 움직이지 않게)
	var acts := _opp_actions(2)
	if not acts.is_empty():
		var last: Dictionary = Net.events_log[acts[0]]
		var lc := str(last.get("code", ""))
		var cell := _card_cell(lc, 64.0)
		var recent_codes: Array = []
		for k in acts:
			recent_codes.append(str(Net.events_log[k].get("code", "")))
		cell.tapped.connect(func(): _zoom_list(recent_codes, 0))
		cell.long_pressed.connect(func(): _zoom_list(recent_codes, 0))
		recent.add_child(cell)
	var texts: Array = []
	for i in acts:
		texts.append(_action_text(i))
	var lab := UI.label("\n".join(texts) if not texts.is_empty() else "AI가 한 일이 여기에 표시됩니다.", 19, UI.TEXT, HORIZONTAL_ALIGNMENT_LEFT, true)
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lab.custom_minimum_size.y = 64.0 * UI.CARD_RATIO if not acts.is_empty() else 0.0
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	recent.add_child(lab)
	if not acts.is_empty():
		var hint := UI.label("눌러서\n크게 보기", 16, UI.TEXT_DIM)
		recent.add_child(hint)
	_field_box.add_child(recent)
	var avail := (size.x if size.x > 0 else 720.0) - 36.0
	for p in [opp, me]:
		var pd: Dictionary = p
		var mine := int(pd["seat"]) == Net.seat
		var bench: Array = pd["bench"]
		var n := maxi(5, bench.size())
		var act_w := avail * 0.21
		var bench_w := minf(avail * 0.145, (avail - act_w - 8.0 * n) / n)
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 10)
		head.custom_minimum_size.y = 46.0
		head.add_child(UI.label("%s · 벤치 %d/%d · 트래쉬 %d" % ["나" if mine else "AI", bench.size(), int(pd["benchMax"]), (pd["discard"] as Array).size()], 20, UI.ACCENT if mine else UI.TEXT))
		if not mine and v.get("stadium") != null:
			var sc := str(v["stadium"]["code"])
			var sb := UI.button("스타디움 보기", 18)
			sb.tapped.connect(func(): _zoom(sc))
			head.add_child(sb)
		_field_box.add_child(head)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		if pd.get("active") != null:
			row.add_child(_slot_tile(pd["active"], act_w))
		else:
			var empty := UI.label("(배틀 없음)", 18, UI.TEXT_DIM)
			empty.custom_minimum_size = Vector2(act_w, act_w * UI.CARD_RATIO)
			row.add_child(empty)
		for b in bench:
			row.add_child(_slot_tile(b, bench_w))
		_field_box.add_child(row)
# ───────────────────────── 행동 막대 ─────────────────────────

func _send_move(m: Dictionary) -> void:
	var inp: Dictionary = (m["input"] as Dictionary).duplicate()
	inp.erase("player")
	Net.input(inp)
	_selected = ""

func _build_bar(v: Dictionary) -> void:
	for c in _bar.get_children():
		c.queue_free()
	var has_req := false
	for r in v["requests"]:
		if int(r["player"]) == Net.seat and (r as Dictionary).has("options"):
			has_req = true
	if has_req:
		return
	for a in _actions():
		var mv: Dictionary = a
		var k := str(mv["kind"])
		if k in ["attack", "ability", "retreat", "stadium"]:
			var b := UI.button(str(mv["label"]), 24, k == "attack", false)
			b.tapped.connect(func(): _send_move(mv))
			_bar.add_child(b)

# ───────────────────────── 탭 ─────────────────────────

func _build_tabs(me: Dictionary) -> void:
	for c in _tabs.get_children():
		c.queue_free()
	var names := { "hand": "패 %d" % int(me["handCount"]), "field": "필드", "discard": "트래쉬", "log": "로그" }
	for k in ["hand", "field", "discard", "log"]:
		var key: String = k
		var b := UI.button(names[key], 24, _tab == key, _tab == key)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tapped.connect(func():
			_tab = key
			_refresh())
		_tabs.add_child(b)

func _build_content(v: Dictionary, me: Dictionary, opp: Dictionary) -> void:
	for c in _content.get_children():
		c.queue_free()
	match _tab:
		"hand":
			var hand = me.get("hand")
			var codes: Array = []
			var iids: Array = []
			var states: Array = []
			var acts := _actions()
			if hand is Array:
				for h in hand:
					var iid := str(h["iid"])
					iids.append(iid)
					codes.append(str(h["code"]))
					var can := false
					for a in acts:
						if a.get("card") != null and str(a["card"]) == iid:
							can = true
					states.append("on" if iid == _selected else ("" if can else "off"))
			if codes.is_empty():
				_content.add_child(UI.label("패가 비어 있습니다.", 24, UI.TEXT_DIM))
				return
			var usable_n := states.filter(func(x): return x != "off").size()
			# 안내·전환 버튼은 늘 보인다 (고를 때 사라지면 패가 위로 움직임)
			var head := HBoxContainer.new()
			head.add_theme_constant_override("separation", 10)
			var hint := UI.label("누르기: 고르기 · 길게: 크게 보기 · 위로 밀기: 사용", 18, UI.TEXT_DIM)
			hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			hint.clip_text = true
			head.add_child(hint)
			head.add_child(_usable_toggle("쓸 수 있는", usable_n, codes.size()))
			_content.add_child(head)
			if _only_usable:
				var keep: Array = []
				for i in codes.size():
					if states[i] != "off":
						keep.append(i)
				codes = keep.map(func(i): return codes[i])
				iids = keep.map(func(i): return iids[i])
				states = keep.map(func(i): return states[i])
				if codes.is_empty():
					_content.add_child(UI.label("지금 쓸 수 있는 카드가 없습니다.", 24, UI.TEXT_DIM))
					return
			_strip_key = "hand:%s" % _only_usable
			_strip_swipe = func(i: int, d: Vector2): _hand_swipe(iids[i], d)
			_content.add_child(_strip(codes, states, 0.36 if Net.solo else 0.42, func(i: int):
				_selected = "" if _selected == iids[i] else iids[i]
				_refresh()))
			if _selected != "":
				var box := HFlowContainer.new()
				box.add_theme_constant_override("h_separation", 10)
				box.add_theme_constant_override("v_separation", 10)
				var any := false
				for a in acts:
					var mv: Dictionary = a
					if mv.get("card") != null and str(mv["card"]) == _selected:
						any = true
						var b := UI.button(str(mv["label"]), 24, true, true)
						b.tapped.connect(func(): _send_move(mv))
						box.add_child(b)
				if not any:
					box.add_child(UI.label("지금은 쓸 수 없는 카드입니다.", 22, UI.TEXT_DIM))
				_content.add_child(box)
		"field":
			for p in [opp, me]:
				var pd: Dictionary = p
				_content.add_child(UI.label("플레이어 %d%s · 벤치 %d/%d" % [int(pd["seat"]) + 1, " (나)" if int(pd["seat"]) == Net.seat else "", (pd["bench"] as Array).size(), int(pd["benchMax"])], 24, UI.TEXT_DIM))
				var row := HFlowContainer.new()
				row.add_theme_constant_override("h_separation", 10)
				row.add_theme_constant_override("v_separation", 10)
				if pd.get("active") != null:
					row.add_child(_slot_tile(pd["active"], 200.0))
				for b in pd["bench"]:
					row.add_child(_slot_tile(b, 150.0))
				_content.add_child(row)
			if v.get("stadium") != null:
				_content.add_child(UI.label("스타디움", 24, UI.TEXT_DIM))
				var sc := str(v["stadium"]["code"])
				_content.add_child(_strip([sc], [], 0.3, func(_i: int): _zoom(sc)))
		"discard":
			for p in [me, opp]:
				var pd: Dictionary = p
				var codes: Array = []
				var dis: Array = pd["discard"]
				for i in range(dis.size() - 1, -1, -1):
					codes.append(str(dis[i]["code"]))
				_content.add_child(UI.label("%s 트래쉬 %d장" % ["내" if int(pd["seat"]) == Net.seat else "상대", codes.size()], 24, UI.TEXT_DIM))
				if not codes.is_empty():
					_strip_key = "discard:%d" % int(pd["seat"])
					_content.add_child(_strip(codes, [], 0.3, func(i: int): _zoom_list(codes, i)))
		"log":
			var lines: Array = []
			for e in Net.events_log:
				var line := _describe(e)
				if line != "":
					lines.append(line)
			lines.reverse()
			for l in lines.slice(0, 100):
				var lab := UI.label(l, 22, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true)
				lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				_content.add_child(lab)

# ───────────────────────── 카드 표시 ─────────────────────────

## 큰 카드를 겹쳐 가로로 스크롤하는 줄. states[i]: "on"(선택) / "off"(흐리게) / ""
## width_ratio: 화면 폭 대비 카드 폭
func _strip(codes: Array, states: Array, width_ratio: float, on_tap: Callable) -> ScrollContainer:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.scroll_deadzone = 12
	var w := maxf(140.0, size.x * width_ratio) if size.x > 0 else 300.0
	var h := w * UI.CARD_RATIO
	sc.custom_minimum_size = Vector2(0, h + 24)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", -int(w * 0.28))   # 겹쳐 보이게
	sc.add_child(row)
	_keep_scroll(sc, _strip_key)
	_strip_key = ""
	var swipe := _strip_swipe
	_strip_swipe = Callable()
	for i in codes.size():
		var idx := i
		var st: String = states[i] if i < states.size() else ""
		var cell := _card_cell(str(codes[i]), w)
		if st == "on":
			cell.position.y = -14
			_mark_selected(cell)
		elif st == "off":
			cell.modulate = Color(0.55, 0.55, 0.55)
		cell.tapped.connect(func(): on_tap.call(idx))
		cell.long_pressed.connect(func(): _zoom_list(codes, idx))
		if swipe.is_valid():
			cell.swiped.connect(func(d: Vector2): swipe.call(idx, d))
		row.add_child(cell)
	return sc

## 카드 줄을 다시 만들어도 가로 스크롤 위치를 유지한다 (카드를 고를 때마다 맨 앞으로 돌아가지 않게)
func _keep_scroll(sc: ScrollContainer, key: String) -> void:
	if key == "":
		return
	var bar := sc.get_h_scroll_bar()
	var target: float = _hscroll.get(key, 0.0)
	var state := { "restored": target <= 0.0 }
	# 내용 크기가 정해져 스크롤 최대값이 충분해지면 그때 한 번 되돌린다
	bar.changed.connect(func():
		if not state["restored"] and bar.max_value - bar.page >= target - 1.0:
			state["restored"] = true
			sc.scroll_horizontal = int(target))
	bar.value_changed.connect(func(val: float):
		if state["restored"]:
			_hscroll[key] = val)
	# 카드가 줄어 그만큼 스크롤할 수 없으면: 잠시 뒤 갈 수 있는 만큼만
	if not state["restored"] and is_inside_tree():
		var ref: WeakRef = weakref(sc)
		get_tree().create_timer(0.25).timeout.connect(func():
			var s = ref.get_ref()
			if s and not state["restored"]:
				state["restored"] = true
				s.scroll_horizontal = int(target))

## 고른 카드 표시: 카드 테두리 전체를 굵은 강조색 틀로 + 왼쪽 위 ✔ 배지
func _mark_selected(cell: Control) -> void:
	var frame := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.96, 0.77, 0.26, 0.14)
	sb.border_color = UI.ACCENT
	sb.set_border_width_all(7)
	sb.set_corner_radius_all(12)
	frame.add_theme_stylebox_override("panel", sb)
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.offset_left = -3
	frame.offset_top = -3
	frame.offset_right = 3
	frame.offset_bottom = 3
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(frame)
	var mark := UI.label(" ✔ ", 30, Color(0.1, 0.1, 0.1))
	mark.add_theme_stylebox_override("normal", UI.box(UI.ACCENT, 10))
	mark.position = Vector2(8, 8)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(mark)

func _card_cell(code: String, w: float) -> TapArea:
	var tap := TapArea.new()
	tap.custom_minimum_size = Vector2(w, w * UI.CARD_RATIO)
	if code == "":
		var back := Panel.new()
		back.add_theme_stylebox_override("panel", UI.box(Color(0.16, 0.38, 0.77), 8, 3, Color.WHITE))
		back.set_anchors_preset(Control.PRESET_FULL_RECT)
		back.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tap.add_child(back)
		return tap
	var img := TextureRect.new()
	img.set_anchors_preset(Control.PRESET_FULL_RECT)
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ref: WeakRef = weakref(img)
	# 큰 카드는 큰 이미지로 (썸네일 먼저)
	ImageCache.request("res://cards/thumb/%s.webp" % code, func(t):
		var r = ref.get_ref()
		if r and r.texture == null:
			r.texture = t)
	if w >= 200.0:
		ImageCache.request("res://cards/full/%s.webp" % code, func(t):
			var r = ref.get_ref()
			if r:
				r.texture = t)
	tap.add_child(img)
	tap.press_target = img
	return tap

## 필드의 포켓몬 한 마리: 카드 + 남은 HP + 특수상태 + 붙은 카드 수
func _slot_tile(slot: Dictionary, w: float, tap_zoom := true) -> TapArea:
	var code := "" if bool(slot.get("faceDown", false)) else _top_code(slot)
	var tile := _card_cell(code, w)
	tile.size_flags_vertical = Control.SIZE_SHRINK_BEGIN   # 줄 높이에 늘어나지 않게 (표시가 카드 위에 붙도록)
	var small := w < 160.0
	var hp = slot.get("hp")
	if hp != null:
		var left := int(hp) - int(slot.get("damage", 0))
		var hl := UI.label((" %d " % left) if small else (" %d/%d " % [left, int(hp)]), 18 if small else 22, Color.WHITE)
		hl.add_theme_stylebox_override("normal", UI.box(Color(0.8, 0.25, 0.2) if left <= int(hp) / 3 else Color(0, 0, 0, 0.78), 8))
		hl.position = Vector2(w - 52, 4) if small else Vector2(w - 110, 6)
		tile.add_child(hl)
	var cond: Dictionary = slot.get("cond", {})
	var badges: Array = []
	if str(cond.get("rot", "")) != "":
		badges.append(COND_LABEL.get(str(cond["rot"]), str(cond["rot"])))
	if int(cond.get("poison", 0)) > 0:
		badges.append("독")
	if bool(cond.get("burn", false)):
		badges.append("화상")
	if not badges.is_empty():
		var bl := UI.label(" " + "·".join(badges) + " ", 20, Color.WHITE)
		bl.add_theme_stylebox_override("normal", UI.box(Color(0.48, 0.25, 0.63), 8))
		bl.position = Vector2(6, 40)
		tile.add_child(bl)
	var att = slot.get("attached")
	if att is Array and (att as Array).size() > 0:
		var al := UI.label((" +%d " if small else " 붙은 카드 %d ") % (att as Array).size(), 18, Color.WHITE)
		al.add_theme_stylebox_override("normal", UI.box(Color(0, 0, 0, 0.7), 8))
		al.position = Vector2(6, w * UI.CARD_RATIO - 34)
		tile.add_child(al)
	if code != "":
		var list := _slot_codes(slot)
		var tags := _slot_tags(slot)
		tile.long_pressed.connect(func(): _zoom_list(list, 0, tags))
		if tap_zoom:
			tile.tapped.connect(func(): _zoom_list(list, 0, tags))
	return tile

## _slot_codes 의 각 카드 설명
func _slot_tags(slot: Dictionary) -> Array:
	var out: Array = []
	var st = slot.get("stack")
	if st is Array:
		for i in (st as Array).size():
			out.append("지금 모습" if i == 0 else "진화 전")
	var att = slot.get("attached")
	if att is Array:
		var n := (att as Array).size()
		for i in n:
			out.append("붙은 카드 %d/%d" % [i + 1, n])
	return out

## 포켓몬 한 마리의 카드들: 맨 위(지금 모습) → 진화 전 → 붙은 카드
func _slot_codes(slot: Dictionary) -> Array:
	var out: Array = []
	var st = slot.get("stack")
	if st is Array:
		for i in range((st as Array).size() - 1, -1, -1):
			out.append(str(st[i]["code"]))
	var att = slot.get("attached")
	if att is Array:
		for a in att:
			out.append(str(a["code"]))
	return out

## 카드 크게 보기 (한 장)
func _zoom(code: String) -> void:
	_zoom_list([code], 0)

## 카드 크게 보기: 좌우로 밀어 같은 줄의 다른 카드로, 위·아래로 밀거나 누르면 닫힘.
## 여러 장이면 아래에 작은 카드 줄 (붙은 카드·진화 전 카드를 한눈에, 누르면 그 카드로). tags[i]: 카드 설명 ("붙은 카드" 등)
func _zoom_list(codes: Array, index: int, tags: Array = []) -> void:
	var list: Array = []
	var tg: Array = []
	for i in codes.size():
		if str(codes[i]) != "":
			list.append(str(codes[i]))
			tg.append(str(tags[i]) if i < tags.size() else "")
	if list.is_empty():
		return
	var state := { "i": clampi(index, 0, list.size() - 1) }
	var ov := TapArea.new()
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.9)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ov.add_child(dim)
	var multi := list.size() > 1
	var thumb_w := 84.0
	var strip_h := thumb_w * UI.CARD_RATIO + 20.0 if multi else 0.0
	var img := TextureRect.new()
	img.set_anchors_preset(Control.PRESET_FULL_RECT)
	img.offset_left = 24
	img.offset_right = -24
	img.offset_top = UI.safe_top(self) + 40
	img.offset_bottom = -UI.safe_bottom(self) - 90 - strip_h
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ov.add_child(img)
	var info := UI.label("", 22, UI.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	info.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	info.offset_top = -UI.safe_bottom(self) - 80
	info.offset_bottom = -UI.safe_bottom(self) - 20
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ov.add_child(info)
	# 아래 작은 카드 줄 (지금 보는 카드는 강조)
	var cells: Array = []
	if multi:
		var sc := ScrollContainer.new()
		sc.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		sc.offset_top = -UI.safe_bottom(self) - 86 - strip_h
		sc.offset_bottom = -UI.safe_bottom(self) - 86
		sc.offset_left = 16
		sc.offset_right = -16
		sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sc.add_child(row)
		for i in list.size():
			var k := i
			var c := _card_cell(list[i], thumb_w)
			c.mouse_filter = Control.MOUSE_FILTER_STOP   # 눌러도 크게 보기가 닫히지 않게
			c.tapped.connect(func():
				state["i"] = k
				GameScreen._zoom_show(state, list, tg, ref_holder(img), info, cells))
			row.add_child(c)
			cells.append(c)
		ov.add_child(sc)
	_zoom_show(state, list, tg, ref_holder(img), info, cells)
	ov.tapped.connect(func(): ov.queue_free())
	ov.swiped.connect(func(d: Vector2):
		if absf(d.x) > absf(d.y) and list.size() > 1:
			state["i"] = (state["i"] + (1 if d.x < 0 else -1) + list.size()) % list.size()
			GameScreen._zoom_show(state, list, tg, ref_holder(img), info, cells)
		elif absf(d.y) >= absf(d.x):
			ov.queue_free())
	add_child(ov)

static func ref_holder(img: TextureRect) -> WeakRef:
	return weakref(img)

## 크게 보기에서 state.i 번째 카드를 보여주고 설명·아래 줄 강조를 갱신
static func _zoom_show(state: Dictionary, list: Array, tg: Array, ref: WeakRef, info: Label, cells: Array) -> void:
	var i: int = state["i"]
	var code := str(list[i])
	var r0 = ref.get_ref()
	if r0:
		r0.texture = null
	ImageCache.request("res://cards/thumb/%s.webp" % code, func(t):
		var r = ref.get_ref()
		if r and r.texture == null:
			r.texture = t)
	ImageCache.request("res://cards/full/%s.webp" % code, func(t):
		var r = ref.get_ref()
		if r and str(list[state["i"]]) == code:
			r.texture = t)
	var tag := str(tg[i]) if i < tg.size() else ""
	if list.size() > 1:
		info.text = "%s%d / %d  ·  좌우로 밀거나 아래 카드를 눌러 넘기기 · 누르면 닫기" % [(tag + "  ·  ") if tag != "" else "", i + 1, list.size()]
	else:
		info.text = (tag + "  ·  " if tag != "" else "") + "누르거나 아래로 밀면 닫기"
	for k in cells.size():
		if is_instance_valid(cells[k]):
			(cells[k] as Control).modulate = Color.WHITE if k == i else Color(0.55, 0.55, 0.55)
# ───────────────────────── 버튼 ─────────────────────────

func _end_turn() -> void:
	if not UI.is_enabled(_btn_end):
		return
	var now := Time.get_ticks_msec()
	if now - _confirm_end > 2500:
		_confirm_end = now
		_err.add_theme_color_override("font_color", UI.ACCENT)
		_err.text = "한 번 더 누르면 턴을 끝냅니다."
		return
	_confirm_end = 0
	Net.input({ "type": "endTurn" })

func _concede() -> void:
	if not UI.is_enabled(_btn_concede):
		return
	var now := Time.get_ticks_msec()
	if now - _confirm_concede > 2500:
		_confirm_concede = now
		_err.add_theme_color_override("font_color", Color(1, 0.55, 0.5))
		_err.text = "한 번 더 누르면 항복합니다."
		return
	_confirm_concede = 0
	Net.input({ "type": "concede" })

# ───────────────────────── 로그 문장 ─────────────────────────

func _describe(e: Dictionary) -> String:
	var t := str(e.get("type", ""))
	var who := "플레이어 %d" % (int(e.get("player", 0)) + 1)
	match t:
		"move":
			var to: Dictionary = e["to"]
			var from: Dictionary = e["from"]
			who = "플레이어 %d" % (int(to["player"]) + 1)
			if str(from["zone"]) == "deck" and str(to["zone"]) == "hand":
				return "%s: 드로우" % who
			return ""
		"coin": return "코인: %s (%s)" % ["앞면" if bool(e["heads"]) else "뒷면", str(e.get("reason", ""))]
		"firstPlayer": return "%s 선공" % who
		"mulligan": return "%s: 멀리건" % who
		"turnStart": return "── 턴 %d: %s 차례" % [int(e["turnNumber"]), who]
		"play": return "%s: %s" % [who, str(e.get("what", ""))]
		"attack": return "%s: 기술 [%s]" % [who, str(e.get("name", ""))]
		"ability": return "%s: 특성 [%s]" % [who, str(e.get("name", ""))]
		"damage": return "  → %s %d" % ["데미지 카운터" if e.get("counters") != null and bool(e["counters"]) else "데미지", int(e["amount"])]
		"ko": return "%s의 포켓몬 기절 — 상대가 사이드 %d장" % [who, int(e["prizes"])]
		"note": return "  · " + str(e.get("text", ""))
		"gameEnd": return "게임 종료"
	return ""

# ───────────────────────── AI 연습: AI 가 한 일 ─────────────────────────

func _max_seq() -> int:
	var m := -1
	for e in Net.events_log:
		m = maxi(m, int(e.get("seq", -1)))
	return m

## 상대(AI)가 카드·기술·특성을 쓴 사건의 위치 (최근 것부터 n 개)
func _opp_actions(n: int) -> Array:
	var out: Array = []
	for i in range(Net.events_log.size() - 1, -1, -1):
		var e: Dictionary = Net.events_log[i]
		if str(e.get("type", "")) in ["play", "attack", "ability"] and int(e.get("player", -1)) != Net.seat and str(e.get("code", "")) != "":
			out.append(i)
			if out.size() >= n:
				break
	return out

## "AI: 기술 [크루얼애로] → 내 배틀 포켓몬 120 데미지, 기절" 처럼 결과까지 한 줄로
func _action_text(i: int) -> String:
	var e: Dictionary = Net.events_log[i]
	var t := str(e.get("type", ""))
	var s := "AI: "
	match t:
		"attack": s += "기술 [%s]" % str(e.get("name", ""))
		"ability": s += "특성 [%s]" % str(e.get("name", ""))
		_: s += str(e.get("what", "카드 사용"))
	var res: Array = []
	for j in range(i + 1, Net.events_log.size()):
		var x: Dictionary = Net.events_log[j]
		var xt := str(x.get("type", ""))
		if xt in ["play", "attack", "ability", "turnStart", "gameEnd"]:
			break
		var whose := "내" if int(x.get("player", -1)) == Net.seat else "AI"
		match xt:
			"damage": res.append("%s 포켓몬 %s %d" % [whose, "카운터" if bool(x.get("counters", false)) else "데미지", int(x.get("amount", 0))])
			"heal": res.append("%s 포켓몬 %d 회복" % [whose, int(x.get("amount", 0))])
			"condition":
				if bool(x.get("on", false)):
					res.append("%s 포켓몬 %s" % [whose, { "asleep": "잠듦", "paralyzed": "마비", "confused": "혼란", "poison": "독", "burn": "화상" }.get(str(x.get("cond", "")), str(x.get("cond", "")))])
			"ko": res.append("%s 포켓몬 기절" % whose)
			"switch": res.append("%s 배틀 포켓몬 교체" % whose)
	if not res.is_empty():
		s += " → " + ", ".join(res)
	return s

## 새로 들어온 AI 행동을 잠깐 크게 보여준다 (에너지 붙이기는 제외)
func _check_spot() -> void:
	var newest := -1
	for i in range(Net.events_log.size() - 1, -1, -1):
		var e: Dictionary = Net.events_log[i]
		if int(e.get("seq", -1)) <= _last_seq:
			break
		if newest < 0 and str(e.get("type", "")) in ["play", "attack", "ability"] and int(e.get("player", -1)) != Net.seat and str(e.get("what", "")) != "에너지 붙이기":
			newest = i
	# 차례가 바뀌면 크게 알림 (AI 가 아무것도 안 하고 넘긴 턴도 알 수 있게)
	var turn_ev := -1
	for i in range(Net.events_log.size() - 1, -1, -1):
		var e: Dictionary = Net.events_log[i]
		if int(e.get("seq", -1)) <= _last_seq:
			break
		if str(e.get("type", "")) == "turnStart":
			turn_ev = i
			break
	_last_seq = maxi(_last_seq, _max_seq())
	if newest >= 0:
		_show_spot(newest)
	if turn_ev >= 0:
		var te: Dictionary = Net.events_log[turn_ev]
		if int(te.player) == Net.seat:
			# 바로 앞 AI 턴에 한 일이 있었나
			var did := false
			for j in range(turn_ev - 1, -1, -1):
				var x: Dictionary = Net.events_log[j]
				var xt := str(x.get("type", ""))
				if xt == "turnStart":
					break
				if xt in ["play", "attack", "ability", "retreat"] or (xt == "switch" and int(x.get("player", -1)) != Net.seat):
					did = true
					break
			_show_banner("내 차례 (턴 %d)" % int(te.turnNumber), "" if did else "AI는 지난 턴에 아무것도 하지 않고 넘겼습니다")
		else:
			_show_banner("AI 차례 (턴 %d)" % int(te.turnNumber), "")

func _show_spot(i: int) -> void:
	var e: Dictionary = Net.events_log[i]
	if is_instance_valid(_spot):
		_spot.queue_free()
	var w := (size.x if size.x > 0 else 720.0)
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_stylebox_override("panel", UI.box(Color(0, 0, 0, 0.82), 20, 3, UI.ACCENT))
	var mm := UI.margin(14)
	mm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(mm)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 14)
	mm.add_child(row)
	var cw := w * 0.36
	var cell := _card_cell(str(e.get("code", "")), cw)
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(cell)
	var lab := UI.label(_action_text(i), 26, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, true)
	lab.custom_minimum_size.x = w * 0.42
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lab)
	box.position = Vector2(w * 0.04, UI.safe_top(self) + 120)
	add_child(box)
	_spot = box
	# 보여주는 시간: AI 속도에 맞춰 (느리면 길게, 즉시면 짧게)
	var hold := clampf(Net.ai_delay() / 1000.0 * 1.6, 0.9, 2.4)
	box.modulate.a = 0.0
	var tw := box.create_tween()
	tw.tween_property(box, "modulate:a", 1.0, 0.15)
	tw.tween_interval(hold)
	tw.tween_property(box, "modulate:a", 0.0, 0.3)
	tw.tween_callback(box.queue_free)
# ───────────────────────── 패: 위로 밀어 사용 ─────────────────────────

## 패의 카드를 위로 밀면: 할 수 있는 행동이 하나면 바로 하고, 여러 개면 골라서 보여준다
func _hand_swipe(iid: String, d: Vector2) -> void:
	if d.y > -absf(d.x):
		return   # 위쪽으로 민 것만 (옆으로 민 것은 패 넘기기)
	var moves: Array = []
	for a in _actions():
		if a.get("card") != null and str(a["card"]) == iid:
			moves.append(a)
	if moves.size() == 1:
		_send_move(moves[0])
	else:
		_selected = iid
		if moves.is_empty():
			_err.add_theme_color_override("font_color", Color(1, 0.55, 0.5))
			_err.text = "지금은 쓸 수 없는 카드입니다."
		_refresh()
var _banner: Control

## 차례 전환 알림 (화면 가운데, 누름은 통과, 잠깐 뒤 사라짐)
func _show_banner(title: String, sub: String) -> void:
	if is_instance_valid(_banner):
		_banner.queue_free()
	var w := (size.x if size.x > 0 else 720.0)
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_stylebox_override("panel", UI.box(Color(0.06, 0.09, 0.08, 0.92), 20, 3, UI.ACCENT))
	var mm := UI.margin(18)
	mm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(mm)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mm.add_child(col)
	var t := UI.label(title, 40, UI.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(t)
	if sub != "":
		var s2 := UI.label(sub, 24, UI.TEXT, HORIZONTAL_ALIGNMENT_CENTER, true)
		s2.custom_minimum_size.x = w * 0.7
		s2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(s2)
	box.custom_minimum_size.x = w * 0.8
	box.position = Vector2(w * 0.1, (size.y if size.y > 0 else 1580.0) * 0.42)
	add_child(box)
	_banner = box
	box.modulate.a = 0.0
	var tw := box.create_tween()
	tw.tween_property(box, "modulate:a", 1.0, 0.15)
	tw.tween_interval(1.6 if sub != "" else 1.0)
	tw.tween_property(box, "modulate:a", 0.0, 0.3)
	tw.tween_callback(box.queue_free)
## "고를 수 있는(쓸 수 있는) 카드만" ↔ "전체" 전환 버튼 (패와 카드 고르기 공용, 기본은 전체)
func _usable_toggle(word: String, usable: int, total: int) -> TapArea:
	var text := ("✔ %s 카드만 %d/%d" % [word, usable, total]) if _only_usable else ("%s 카드만 보기 %d/%d" % [word, usable, total])
	var b := UI.button(text, 20, _only_usable, _only_usable)
	b.tapped.connect(func():
		_only_usable = not _only_usable
		_refresh())
	return b