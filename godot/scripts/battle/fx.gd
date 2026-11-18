class_name BFx
extends Node
## 연출 큐: 새 사건(Net.events_log)을 순서대로 재생한다.
## - 상태(view)는 이미 최종값. 아직 재생 안 된 데미지·회복만큼 HP 를 덜/더 보여주고(pending_hp), 재생하면서 맞춘다.
## - 기절한 포켓몬 칸은 기절 연출이 끝날 때까지 남겨 둔다(hold).
## - 속도: AI 속도에 따름 (느리게·보통 1×, 빠르게 2×, 즉시 = 연출 없이 바로). 재생 중 화면을 누르면 나머지를 건너뜀.
## - 손패 모드(서버 대전)는 최소 연출: 차례 배너, 상대 행동 한 줄 알림, 진동 (큰 연출은 웹 게임판).

signal idle

var screen                      # BattleScreen
var queue: Array = []
var playing := false
var skipping := false
var last_seq := -1
var pending_hp: Dictionary = {} # sid -> 아직 안 보여준 데미지(+)/회복(-)
var hold: Dictionary = {}       # sid -> true : 기절 연출 전까지 남겨 둘 칸
var counts: Dictionary = {}     # 사건 종류 -> 재생 수 (테스트용)
var catcher: TapArea            # 재생 중 누르면 건너뛰기

func _init(s) -> void:
	screen = s

func speed() -> float:
	if not Net.solo:
		return 1.0
	var d := Net.ai_delay()
	return 0.0 if d <= 0 else (2.0 if d <= 300 else 1.0)

func busy() -> bool:
	return playing or not queue.is_empty()

## 들어오기 전 사건은 다시 재생하지 않는다
func start_from_now() -> void:
	for e in Net.events_log:
		last_seq = maxi(last_seq, int(e.get("seq", -1)))

## 새 사건을 큐에 넣는다 (상태가 바뀐 뒤 = view 가 새 것일 때 부른다)
func feed() -> void:
	var fresh: Array = []
	for e in Net.events_log:
		var sq := int(e.get("seq", -1))
		if sq > last_seq:
			fresh.append(e)
			last_seq = sq
	for e in fresh:
		match str(e.get("type", "")):
			"damage":
				pending_hp[str(e.sid)] = int(pending_hp.get(str(e.sid), 0)) + int(e.amount)
			"heal":
				pending_hp[str(e.sid)] = int(pending_hp.get(str(e.sid), 0)) - int(e.amount)
			"ko":
				if e.get("sid") != null:
					hold[str(e.sid)] = true
	queue.append_array(fresh)
	if speed() <= 0.0:
		_flush_instant()
	elif not playing and not queue.is_empty():
		_run()

func _flush_instant() -> void:
	for e in queue:
		_count(e)
	queue.clear()
	pending_hp.clear()
	var had := not hold.is_empty()
	hold.clear()
	if had:
		screen._refresh()

func _count(e: Dictionary) -> void:
	var t := str(e.get("type", ""))
	counts[t] = int(counts.get(t, 0)) + 1

func skip() -> void:
	skipping = true

func _wait(sec: float) -> void:
	if skipping or sec <= 0.0:
		return
	await get_tree().create_timer(sec / speed()).timeout

func _run() -> void:
	playing = true
	Net.fx_busy = true
	_show_catcher(true)
	while not queue.is_empty():
		var e: Dictionary = queue.pop_front()
		_count(e)
		if skipping or not is_instance_valid(screen):
			_apply_now(e)
			continue
		if screen.mode == "table":
			await _play_table(e)
		else:
			await _play_hand(e)
	skipping = false
	playing = false
	Net.fx_busy = false
	_show_catcher(false)
	pending_hp.clear()
	hold.clear()
	if is_instance_valid(screen):
		screen._refresh()
	idle.emit()

## 건너뛸 때: 화면 상태만 맞춘다
func _apply_now(e: Dictionary) -> void:
	match str(e.get("type", "")):
		"damage", "heal":
			var sid := str(e.sid)
			pending_hp[sid] = int(pending_hp.get(sid, 0)) - (int(e.amount) if e.type == "damage" else -int(e.amount))
			_update_hp(sid)
		"ko":
			_release(str(e.get("sid", "")))

func _show_catcher(on: bool) -> void:
	if not is_instance_valid(screen):
		return
	if catcher == null:
		catcher = TapArea.new()
		catcher.set_anchors_preset(Control.PRESET_FULL_RECT)
		catcher.mouse_filter = Control.MOUSE_FILTER_STOP
		catcher.tapped.connect(skip)
		screen.fx_layer.add_child(catcher)
	# 상대 차례 연출만 막고 건너뛰게 (내 행동 연출은 짧고 바로 다음 조작 가능)
	catcher.visible = on and screen.mode == "table" and not screen._my_turn()

# ───────────────────────── 도우미 ─────────────────────────

func _node(sid: String) -> Control:
	return screen.slots.get(sid)

func _update_hp(sid: String) -> void:
	var n = _node(sid)
	if n == null:
		return
	var pend := int(pending_hp.get(sid, 0))
	n.show_hp(clampi(n.real_left() + pend, 0, n.max_hp()) if pend != 0 else -1)

func _release(sid: String) -> void:
	hold.erase(sid)
	pending_hp.erase(sid)
	screen._refresh()

func _who(e: Dictionary) -> String:
	return "나" if int(e.get("player", -1)) == Net.seat else "AI"

## 가운데 큰 카드 + 설명 (카드 사용·특성)
func _big_card(code: String, caption: String, sec: float) -> void:
	var W: float = screen.size.x
	var w := W * 0.42
	var box := Control.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.fx_layer.add_child(box)
	var c := BCard.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.size = Vector2(w, w * UI.CARD_RATIO)
	c.set_card(code, true)
	c.position = Vector2((W - w) / 2, screen.size.y * 0.5 - c.size.y * 0.62)
	c.pivot_offset = c.size / 2
	box.add_child(c)
	var lab := UI.label(caption, 26, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, true)
	lab.add_theme_stylebox_override("normal", UI.box(Color(0, 0, 0, 0.82), 12))
	lab.size = Vector2(W * 0.86, 0)
	lab.position = Vector2(W * 0.07, c.position.y + c.size.y + 10)
	box.add_child(lab)
	c.scale = Vector2(0.6, 0.6)
	box.modulate.a = 0.0
	var tw := box.create_tween().set_parallel(true)
	tw.tween_property(box, "modulate:a", 1.0, 0.12 / speed())
	tw.tween_property(c, "scale", Vector2.ONE, 0.18 / speed()).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	await _wait(sec)
	if is_instance_valid(box):
		var tw2 := box.create_tween()
		tw2.tween_property(box, "modulate:a", 0.0, 0.15 / speed())
		await _wait(0.15)
		box.queue_free()

## 글자 띠 (가운데)
func _banner(text: String, sub: String, sec: float, color := UI.ACCENT) -> void:
	var W: float = screen.size.x
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", UI.box(Color(0.05, 0.08, 0.07, 0.94), 20, 3, color))
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(col)
	col.add_child(UI.label(text, 38, color, HORIZONTAL_ALIGNMENT_CENTER))
	if sub != "":
		var s2 := UI.label(sub, 22, UI.TEXT, HORIZONTAL_ALIGNMENT_CENTER, true)
		s2.custom_minimum_size.x = W * 0.7
		col.add_child(s2)
	p.custom_minimum_size.x = W * 0.8
	p.position = Vector2(W * 0.1, screen.size.y * 0.42)
	screen.fx_layer.add_child(p)
	p.modulate.a = 0.0
	var tw := p.create_tween()
	tw.tween_property(p, "modulate:a", 1.0, 0.12 / speed())
	await _wait(sec)
	if is_instance_valid(p):
		p.queue_free()

## 숫자 튀어오름 (데미지 빨강, 회복 초록)
func _number(sid: String, text: String, color: Color) -> void:
	var n = _node(sid)
	if n == null:
		return
	var lab := UI.label(text, 54, color, HORIZONTAL_ALIGNMENT_CENTER)
	lab.add_theme_color_override("font_outline_color", Color.BLACK)
	lab.add_theme_constant_override("outline_size", 10)
	lab.size = Vector2(n.size.x + 80, 0)
	lab.position = n.position + Vector2(-40, n.size.y * 0.3)
	screen.fx_layer.add_child(lab)
	var tw := lab.create_tween().set_parallel(true)
	tw.tween_property(lab, "position:y", lab.position.y - 70, 0.6 / speed()).set_ease(Tween.EASE_OUT)
	tw.tween_property(lab, "modulate:a", 0.0, 0.6 / speed()).set_delay(0.3 / speed())
	tw.chain().tween_callback(lab.queue_free)

func _shake(n: Control) -> void:
	if n == null:
		return
	var base: Vector2 = n.get_meta("target_pos", n.position)
	_pos_tween(n, func(tw: Tween):
		for k in 4:
			tw.tween_property(n, "position", base + Vector2(10 if k % 2 == 0 else -10, 0), 0.04 / speed())
		tw.tween_property(n, "position", base, 0.04 / speed()))

## 칸 위치 연출은 화면의 이동과 같은 자리(meta pos_tw)를 써서 겹치지 않게
func _pos_tween(n: Control, build: Callable) -> void:
	var old = n.get_meta("pos_tw") if n.has_meta("pos_tw") else null
	if old is Tween and (old as Tween).is_valid():
		(old as Tween).kill()
		n.position = n.get_meta("target_pos", n.position)
	var tw := n.create_tween()
	build.call(tw)
	tw.tween_callback(func(): n.position = n.get_meta("target_pos", n.position))
	n.set_meta("pos_tw", tw)

func _fly(code: String, from: Rect2, to: Rect2, sec: float) -> void:
	var c := BCard.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.set_card(code)
	c.position = from.position
	c.size = from.size
	screen.fx_layer.add_child(c)
	var tw := c.create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(c, "position", to.position, sec / speed())
	tw.tween_property(c, "size", to.size, sec / speed())
	tw.chain().tween_callback(c.queue_free)
	await _wait(sec)

# ───────────────────────── 탁자 모드 연출 ─────────────────────────

func _play_table(e: Dictionary) -> void:
	var L: Dictionary = screen.L
	var mine := int(e.get("player", -1)) == Net.seat
	match str(e.get("type", "")):
		"move":
			var fr: Dictionary = e.from
			var to: Dictionary = e.to
			if str(fr.zone) == "deck" and str(to.zone) == "hand":
				var side := "my" if int(to.player) == Net.seat else "opp"
				var dk: Rect2 = L[side + "_deck"]
				var dest: Rect2 = Rect2(L.hand.position + Vector2(L.hand.size.x / 2 - 40, 20), Vector2(80, 112)) if side == "my" else Rect2(L.opp_hand.position + Vector2(60, 0), Vector2(30, 42))
				await _fly("", dk, dest, 0.22)
		"play":
			if str(e.get("what", "")) == "에너지 붙이기" and mine:
				await _wait(0.1)
				return
			await _big_card(str(e.code), "%s: %s — %s" % [_who(e), BData.name_of(str(e.code)), str(e.get("what", ""))], 0.35 if mine else 0.7)
		"ability":
			await _big_card(str(e.code), "%s: 특성 [%s]" % [_who(e), str(e.get("name", ""))], 0.4 if mine else 0.75)
		"attack":
			var p: Dictionary = Net.view.players[int(e.player)]
			var act = p.get("active")
			var n = _node(str(act.sid)) if act != null else null
			_banner("기술 [%s]" % str(e.get("name", "")), "%s: %s" % [_who(e), BData.name_of(str(e.code))], 0.6, UI.ACCENT if mine else Color(0.95, 0.45, 0.4))
			if n != null:
				var base: Vector2 = n.get_meta("target_pos", n.position)
				var dir := Vector2(0, -60 if mine else 60)
				_pos_tween(n, func(tw: Tween):
					tw.tween_property(n, "position", base + dir, 0.14 / speed()).set_ease(Tween.EASE_OUT)
					tw.tween_property(n, "position", base, 0.18 / speed()))
			await _wait(0.45)
		"damage":
			var sid := str(e.sid)
			pending_hp[sid] = int(pending_hp.get(sid, 0)) - int(e.amount)
			_update_hp(sid)
			_number(sid, "-%d" % int(e.amount), Color(1, 0.35, 0.3))
			_shake(_node(sid))
			Input.vibrate_handheld(15)
			await _wait(0.4)
		"heal":
			var sid2 := str(e.sid)
			pending_hp[sid2] = int(pending_hp.get(sid2, 0)) + int(e.amount)
			_update_hp(sid2)
			_number(sid2, "+%d" % int(e.amount), Color(0.4, 1, 0.5))
			await _wait(0.35)
		"condition":
			var n2 = _node(str(e.sid))
			if n2 != null and bool(e.get("on", false)):
				n2.pivot_offset = n2.size / 2
				var tw2 := n2.create_tween()
				tw2.tween_property(n2, "scale", Vector2(1.12, 1.12), 0.1 / speed())
				tw2.tween_property(n2, "scale", Vector2.ONE, 0.12 / speed())
			await _wait(0.25)
		"ko":
			var sid3 := str(e.get("sid", ""))
			var n3 = _node(sid3)
			Input.vibrate_handheld(30)
			if n3 != null:
				var side3 := "my" if int(e.player) == Net.seat else "opp"
				var dis: Rect2 = L[side3 + "_discard"]
				var old3 = n3.get_meta("pos_tw") if n3.has_meta("pos_tw") else null
				if old3 is Tween and (old3 as Tween).is_valid():
					(old3 as Tween).kill()
				var tw3 := n3.create_tween().set_parallel(true)
				tw3.tween_property(n3, "modulate", Color(0.4, 0.4, 0.4, 1), 0.2 / speed())
				tw3.chain().tween_property(n3, "position", dis.position, 0.35 / speed()).set_trans(Tween.TRANS_CUBIC)
				tw3.parallel().tween_property(n3, "scale", Vector2(0.5, 0.5), 0.35 / speed())
				n3.set_meta("pos_tw", tw3)
				_banner("기절!", "%s의 %s — 사이드 %d장" % [_who(e), BData.name_of(str(e.code)), int(e.prizes)], 0.6, Color(0.95, 0.45, 0.4))
				await _wait(0.6)
				if is_instance_valid(n3):
					n3.scale = Vector2.ONE
					n3.modulate = Color.WHITE
			_release(sid3)
		"coin":
			await _coin(e)
		"turnStart":
			var my_turn := int(e.player) == Net.seat
			await _banner("내 차례" if my_turn else "AI 차례", "턴 %d" % int(e.turnNumber), 0.7)
		"shuffle":
			await _wait(0.05)
		_:
			pass

## 코인 던지기: 원판이 몇 번 뒤집힌 뒤 결과
func _coin(e: Dictionary) -> void:
	var W: float = screen.size.x
	var heads := bool(e.heads)
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.fx_layer.add_child(root)
	var d := 150.0
	var disc := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = UI.ACCENT
	sb.set_corner_radius_all(int(d / 2))
	sb.set_border_width_all(6)
	sb.border_color = Color(0.55, 0.4, 0.1)
	disc.add_theme_stylebox_override("panel", sb)
	disc.size = Vector2(d, d)
	disc.position = Vector2((W - d) / 2, screen.size.y * 0.4)
	disc.pivot_offset = disc.size / 2
	disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(disc)
	var face := UI.label("?", 64, Color(0.25, 0.18, 0.05), HORIZONTAL_ALIGNMENT_CENTER)
	face.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	face.size = disc.size
	disc.add_child(face)
	var cap := UI.label(str(e.get("reason", "")), 24, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, true)
	cap.add_theme_stylebox_override("normal", UI.box(Color(0, 0, 0, 0.8), 12))
	cap.size = Vector2(W * 0.8, 0)
	cap.position = Vector2(W * 0.1, disc.position.y + d + 16)
	root.add_child(cap)
	if not skipping:
		var tw := disc.create_tween()
		for k in 3:
			tw.tween_property(disc, "scale:x", 0.05, 0.08 / speed())
			tw.tween_property(disc, "scale:x", 1.0, 0.08 / speed())
		await _wait(0.5)
	face.text = "앞" if heads else "뒤"
	sb.bg_color = UI.ACCENT if heads else Color(0.7, 0.72, 0.76)
	cap.text = "%s — %s" % ["앞면" if heads else "뒷면", str(e.get("reason", ""))]
	await _wait(0.6)
	root.queue_free()

# ───────────────────────── 손패 모드 (서버 대전): 최소 연출 ─────────────────────────

func _play_hand(e: Dictionary) -> void:
	var mine := int(e.get("player", -1)) == Net.seat
	match str(e.get("type", "")):
		"turnStart":
			await _banner("내 차례" if mine else "상대 차례", "턴 %d" % int(e.turnNumber), 0.7)
		"play", "attack", "ability":
			if not mine:
				var l := BLog.line(e, Net.seat)
				screen.notify(l)
		"damage":
			if int(e.player) == Net.seat:
				Input.vibrate_handheld(15)
		"ko":
			if int(e.player) == Net.seat:
				Input.vibrate_handheld(30)
				screen.notify(BLog.line(e, Net.seat))
		_:
			pass
