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
var impacts: Array = []         # 테스트용: 충돌 기록 [{ sids, tier, synced }]
var _board_tw: Tween
var _reps: Dictionary = {}      # 이번 턴 연출 종류 -> 횟수 (반복 가속)
var _accel := 1.0               # 지금 사건의 길이 배율 (1 · 0.75 · 0.5)
var accel_log: Array = []       # 테스트용: [{ key, n, accel }]
var wr_shown: Array = []        # 테스트용: 띄운 약점·저항 표시

# ───────────────────────── 설정·등급 (docs/fx-hearthstone-review.md) ─────────────────────────

const SETTINGS_PATH := "user://fx.json"
static var shake_on := true     # 큰 피해 때 판 전체 흔들림
static var vibrate_on := true
static var _loaded := false

static func load_settings() -> void:
	if _loaded:
		return
	_loaded = true
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	if d is Dictionary:
		shake_on = bool(d.get("shake", true))
		vibrate_on = bool(d.get("vibrate", true))

static func save_settings() -> void:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({ "shake": shake_on, "vibrate": vibrate_on }))

## 피해 등급 0 소(≤30) · 1 중(40~90) · 2 대(100~190) · 3 특대(200 이상 또는 기절시키는 타격)
static func tier(amount: int, kos := false) -> int:
	if kos or amount >= 200:
		return 3
	if amount >= 100:
		return 2
	if amount >= 40:
		return 1
	return 0

## 약점이면 한 등급 위 (특대 상한)
static func tier_of(e: Dictionary, kos := false) -> int:
	var t := tier(int(e.get("amount", 0)), kos)
	if bool(e.get("weak", false)):
		t = mini(t + 1, 3)
	return t

## 숫자 아래 보조 표시: 약점 ×2 / 저항 −30
static func wr_label(e: Dictionary) -> String:
	if bool(e.get("weak", false)):
		return "약점 ×2"
	if bool(e.get("resist", false)):
		return "저항 −30"
	return ""

## 반복 가속: 한 턴에 같은 연출 3번째부터 0.75배, 5번째부터 0.5배 길이
static func accel_for(n: int) -> float:
	if n >= 5:
		return 0.5
	if n >= 3:
		return 0.75
	return 1.0

## 반복 가속 종류: 카드 사용은 무엇을 했는지까지(에너지 붙이기·서포트…), 나머지는 사건 종류
static func rep_key(e: Dictionary) -> String:
	var t := str(e.get("type", ""))
	if t == "play":
		return "play:" + str(e.get("what", ""))
	if t == "move":
		var fr = e.get("from", {})
		var to = e.get("to", {})
		if fr is Dictionary and to is Dictionary and str(fr.get("zone", "")) == "deck" and str(to.get("zone", "")) == "hand":
			return "draw"
		return ""
	if t in ["attack", "ability", "damage", "heal", "condition", "ko"]:
		return t
	return ""

func _set_accel(e: Dictionary) -> void:
	var t := str(e.get("type", ""))
	if t == "turnStart":
		_reps.clear()
	var key := rep_key(e)
	if key == "":
		_accel = 1.0
		return
	var n := int(_reps.get(key, 0)) + 1
	_reps[key] = n
	_accel = accel_for(n)
	if t == "ko" and _game_ends_after():
		_accel = 1.0     # 승부를 가르는 마지막 기절은 제 속도로
	accel_log.append({ "key": key, "n": n, "accel": _accel })

func _game_ends_after() -> bool:
	for q in queue:
		var qt := str(q.get("type", ""))
		if qt == "gameEnd":
			return true
		if qt == "turnStart":
			return false
	return false

const NUM_SIZE := [44, 54, 68, 84]
const VIBRATE_MS := [10, 15, 25, 40]
const KNOCK_PX := [8.0, 14.0, 20.0, 26.0]
const HIT_STOP := [0.0, 0.04, 0.07, 0.10]
const BOARD_SHAKE := [0.0, 0.0, 5.0, 9.0]

func _vibrate(ms: int) -> void:
	load_settings()
	if vibrate_on:
		Input.vibrate_handheld(ms)

## 이 사건 뒤 큐에 같은 칸의 기절이 있나 (그 타격은 특대)
func _kos_after(sid: String) -> bool:
	for q in queue:
		if str(q.get("type", "")) == "ko" and str(q.get("sid", "")) == sid:
			return true
		if str(q.get("type", "")) in ["turnStart", "attack"]:
			return false
	return false

func _init(s) -> void:
	screen = s

func speed() -> float:
	if not Net.solo:
		return 1.0
	var d := Net.ai_delay()
	var base := 0.0 if d <= 0 else (2.0 if d <= 300 else 1.0)
	return base / _accel if base > 0.0 else 0.0

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
		_set_accel(e)
		if screen.mode == "table":
			await _play_table(e)
		else:
			await _play_hand(e)
	_accel = 1.0
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

## 숫자: 칸 가운데에서 튀어나와(0.5→1.25→1.0배) 멈춰 읽히고(0.4초) 살짝 떠오르며 사라짐. 크기는 등급별
func _number(sid: String, text: String, color: Color, t := 1, sub := "") -> void:
	var n = _node(sid)
	if n == null:
		return
	var fs: int = NUM_SIZE[clampi(t, 0, 3)]
	var lab := UI.label(text, fs, color, HORIZONTAL_ALIGNMENT_CENTER)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lab.add_theme_color_override("font_outline_color", Color.BLACK)
	lab.add_theme_constant_override("outline_size", 8 + t * 2)
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lab.size = Vector2(n.size.x + 120, fs * 1.5)
	var base: Vector2 = n.get_meta("target_pos", n.position)
	lab.position = base + Vector2(-60, n.size.y * 0.42 - lab.size.y / 2)
	lab.pivot_offset = lab.size / 2
	if t <= 1:
		lab.rotation_degrees = randf_range(-4.0, 4.0)
	lab.scale = Vector2(0.5, 0.5)
	lab.set_meta("fx_number", text)
	if sub != "":
		# 약점·저항: 숫자 바로 아래 작은 띠 (숫자와 함께 튀고 사라짐). 약점은 금색, 저항은 회청색
		var weak := sub.begins_with("약점")
		var sc := Color(1, 0.82, 0.3) if weak else Color(0.7, 0.8, 0.9)
		var sl := UI.label(sub, 26, sc, HORIZONTAL_ALIGNMENT_CENTER)
		sl.add_theme_stylebox_override("normal", UI.box(Color(0.05, 0.05, 0.05, 0.85), 8, 2, sc))
		sl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ms := sl.get_combined_minimum_size()
		sl.size = ms
		sl.position = Vector2((lab.size.x - ms.x) / 2, lab.size.y - 6)
		sl.set_meta("fx_wr", sub)
		lab.add_child(sl)
		lab.set_meta("fx_wr", sub)
	screen.fx_layer.add_child(lab)
	var sp := speed()
	var tw := lab.create_tween()
	tw.tween_property(lab, "scale", Vector2(1.25, 1.25), 0.08 / sp).set_ease(Tween.EASE_OUT)
	tw.tween_property(lab, "scale", Vector2.ONE, 0.10 / sp)
	tw.tween_interval(0.40 / sp)
	tw.tween_property(lab, "position:y", lab.position.y - 24, 0.22 / sp).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(lab, "modulate:a", 0.0, 0.22 / sp)
	tw.tween_callback(lab.queue_free)

## 맞은 칸: 히트 스톱 동안 정지 → 공격 방향으로 밀림 → 튕기며 복귀 → 감쇠 흔들림
func _knock(n: Control, dir: Vector2, t: int, stop: float) -> void:
	if n == null:
		return
	var base: Vector2 = n.get_meta("target_pos", n.position)
	var sp := speed()
	var k: float = KNOCK_PX[clampi(t, 0, 3)]
	_pos_tween(n, func(tw: Tween):
		if stop > 0.0:
			tw.tween_interval(stop / sp)
		tw.tween_property(n, "position", base + dir * k, 0.05 / sp).set_ease(Tween.EASE_OUT)
		tw.tween_property(n, "position", base, 0.18 / sp).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		for a in [0.5, 0.3, 0.15]:
			tw.tween_property(n, "position", base + Vector2(k * a * (1 if randf() < 0.5 else -1), 0), 0.04 / sp)
		tw.tween_property(n, "position", base, 0.04 / sp))

## 하얀 번쩍임 (칸 위에 흰 사각형)
func _flash(n: Control) -> void:
	if n == null:
		return
	var r := ColorRect.new()
	r.color = Color(1, 1, 1, 0.7)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.position = n.get_meta("target_pos", n.position)
	r.size = n.size
	screen.fx_layer.add_child(r)
	var tw := r.create_tween()
	tw.tween_property(r, "color:a", 0.0, 0.12 / speed())
	tw.tween_callback(r.queue_free)

## 판 전체 흔들림 (대·특대만, 설정에서 끌 수 있음). 끝나면 반드시 제자리
func _board_shake(px: float) -> void:
	load_settings()
	if px <= 0.0 or not shake_on or screen.mode != "table":
		return
	var b: Control = screen.board
	if _board_tw and _board_tw.is_valid():
		_board_tw.kill()
	b.position = Vector2.ZERO
	var sp := speed()
	_board_tw = b.create_tween()
	for a in [1.0, -0.7, 0.45, -0.25]:
		_board_tw.tween_property(b, "position", Vector2(px * a, px * a * 0.4), 0.05 / sp)
	_board_tw.tween_property(b, "position", Vector2.ZERO, 0.05 / sp)

## 충돌: 피해 사건들을 한 순간에 (HP·숫자·번쩍임·밀림·진동·판 흔들림)
func _impact(evs: Array, stop: float, synced: bool) -> void:
	var top := 0
	var sids: Array = []
	for e in evs:
		var sid := str(e.sid)
		var amt := int(e.amount)
		var t := tier_of(e, _kos_after(sid))
		top = maxi(top, t)
		pending_hp[sid] = int(pending_hp.get(sid, 0)) - amt
		_update_hp(sid)
		var wr := wr_label(e)
		_number(sid, "-%d" % amt, Color(1, 0.35, 0.3), t, wr)
		if wr != "":
			wr_shown.append(wr)
		var n := _node(sid)
		_flash(n)
		var away := Vector2(0, 1) if int(e.player) == Net.seat else Vector2(0, -1)   # 내 칸은 아래로, 상대 칸은 위로
		_knock(n, away, t, stop)
		sids.append(sid)
	_vibrate(VIBRATE_MS[top])
	_board_shake(BOARD_SHAKE[top])
	impacts.append({ "sids": sids, "tier": top, "synced": synced })

## 칸 위 작은 이름표 (기술 이름·기절). 기다리지 않음
func _tag(n: Control, text: String, color: Color, sec: float) -> void:
	if n == null or not is_instance_valid(screen):
		return
	var lab := UI.label(text, 24, color, HORIZONTAL_ALIGNMENT_CENTER)
	lab.add_theme_stylebox_override("normal", UI.box(Color(0.05, 0.08, 0.07, 0.92), 10, 2, color))
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lab.set_meta("fx_tag", text)
	screen.fx_layer.add_child(lab)
	var ms := lab.get_combined_minimum_size()
	lab.size = ms
	var base: Vector2 = n.get_meta("target_pos", n.position)
	var x := clampf(base.x + n.size.x / 2 - ms.x / 2, 6, screen.size.x - ms.x - 6)
	# 내 칸은 위(가운데 띠 쪽), 상대 칸은 아래(가운데 띠 쪽) — 벤치 줄을 가리지 않게
	var below: bool = base.y + n.size.y / 2 < screen.size.y * 0.42
	var y: float = (base.y + n.size.y + 8) if below else (base.y - ms.y - 30)
	lab.position = Vector2(x, clampf(y, 4, screen.size.y - ms.y - 4))
	lab.modulate.a = 0.0
	var sp := speed()
	var tw := lab.create_tween()
	tw.tween_property(lab, "modulate:a", 1.0, 0.08 / sp)
	tw.tween_interval(sec / sp)
	tw.tween_property(lab, "modulate:a", 0.0, 0.15 / sp)
	tw.tween_callback(lab.queue_free)

## 기술: 칸 위 기술 이름 → 예비(반대쪽 14px) → 빠른 돌진(80px) → 닿는 순간 뒤따르는 피해를 한꺼번에(충돌) → 멈춤 → 느린 복귀
func _attack(e: Dictionary, mine: bool) -> void:
	var p: Dictionary = Net.view.players[int(e.player)]
	var act = p.get("active")
	var n = _node(str(act.sid)) if act != null else null
	# 바로 뒤따르는 이 기술의 피해 사건들 (중간에 코인 등 다른 사건이 있으면 따로 재생)
	var hits: Array = []
	while not queue.is_empty() and str(queue[0].get("type", "")) == "damage":
		var d: Dictionary = queue.pop_front()
		_count(d)
		hits.append(d)
	var top := 0
	for h in hits:
		top = maxi(top, tier_of(h, _kos_after(str(h.sid))))
	var stop: float = HIT_STOP[top]
	var color: Color = UI.ACCENT if mine else Color(0.95, 0.45, 0.4)
	_tag(n, ("" if mine else "AI · ") + "기술 [%s]" % str(e.get("name", "")), color, 0.9)
	var state := { "hit": hits.is_empty() }
	var hit_now := func():
		if not state.hit:
			state.hit = true
			if skipping:
				for h in hits:
					_apply_now(h)
			else:
				_impact(hits, stop, true)
	if n != null and not skipping:
		var base: Vector2 = n.get_meta("target_pos", n.position)
		var dir := Vector2(0, -1 if mine else 1)
		var sp := speed()
		n.pivot_offset = n.size / 2
		_pos_tween(n, func(tw: Tween):
			tw.tween_property(n, "position", base - dir * 14, 0.10 / sp).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			tw.tween_property(n, "position", base + dir * 80, 0.09 / sp).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
			tw.parallel().tween_property(n, "scale", Vector2(1.06, 1.06), 0.09 / sp)
			tw.tween_callback(hit_now)
			if stop > 0.0:
				tw.tween_interval(stop / sp)
			tw.tween_property(n, "position", base, 0.24 / sp).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tw.parallel().tween_property(n, "scale", Vector2.ONE, 0.24 / sp))
		await _wait(0.19)
	hit_now.call()    # 칸이 없거나 건너뛰는 중이면 바로 (트윈 콜백은 한 번만 실제로 실행됨)
	if is_instance_valid(n):
		n.scale = Vector2.ONE if skipping else n.scale
	await _wait(stop + (0.55 if not hits.is_empty() else 0.3))

## 기절(동시 기절은 한 묶음, 0.06초씩 어긋나게): 떨림 + 회색·0.92배 → 트래쉬로 0.5배·반투명 → 칸 위 "기절" 이름표
func _kos(group: Array) -> void:
	var L: Dictionary = screen.L
	_vibrate(30)
	var sp := speed()
	var k := 0
	for e in group:
		var sid := str(e.get("sid", ""))
		var n = _node(sid)
		if n == null:
			continue
		var side := "my" if int(e.player) == Net.seat else "opp"
		var dis: Rect2 = L[side + "_discard"]
		_tag(n, "기절 · %s %d장" % ["상대가 사이드" if side == "my" else "사이드", int(e.prizes)], Color(0.95, 0.45, 0.4), 0.7)
		var old = n.get_meta("pos_tw") if n.has_meta("pos_tw") else null
		if old is Tween and (old as Tween).is_valid():
			(old as Tween).kill()
		var base: Vector2 = n.get_meta("target_pos", n.position)
		n.position = base
		n.pivot_offset = n.size / 2
		var tw := n.create_tween()
		if k > 0:
			tw.tween_interval(0.06 * k / sp)
		for a in [1, -1, 1]:
			tw.tween_property(n, "position", base + Vector2(6 * a, 0), 0.04 / sp)
		tw.tween_property(n, "position", base, 0.04 / sp)
		tw.parallel().tween_property(n, "modulate", Color(0.45, 0.45, 0.45, 1), 0.16 / sp)
		tw.parallel().tween_property(n, "scale", Vector2(0.92, 0.92), 0.16 / sp)
		tw.tween_property(n, "position", dis.position, 0.30 / sp).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		tw.parallel().tween_property(n, "scale", Vector2(0.5, 0.5), 0.30 / sp)
		tw.parallel().tween_property(n, "modulate:a", 0.6, 0.30 / sp)
		n.set_meta("pos_tw", tw)
		k += 1
	await _wait(0.1 + 0.16 + 0.30 + 0.06 * maxi(k - 1, 0) + 0.15)
	for e in group:
		var sid := str(e.get("sid", ""))
		var n = _node(sid)
		if is_instance_valid(n):
			n.scale = Vector2.ONE
			n.modulate = Color.WHITE
		_release(sid)

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
			await _attack(e, mine)
		"damage":
			_impact([e], HIT_STOP[tier_of(e, _kos_after(str(e.sid)))], false)
			await _wait(0.5)
		"heal":
			var sid2 := str(e.sid)
			pending_hp[sid2] = int(pending_hp.get(sid2, 0)) + int(e.amount)
			_update_hp(sid2)
			_number(sid2, "+%d" % int(e.amount), Color(0.4, 1, 0.5), 0)
			var n4 = _node(sid2)
			if n4 != null:
				n4.pivot_offset = n4.size / 2
				var tw4: Tween = n4.create_tween()
				tw4.tween_property(n4, "scale", Vector2(1.05, 1.05), 0.1 / speed())
				tw4.tween_property(n4, "scale", Vector2.ONE, 0.1 / speed())
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
			var group := [e]
			while not queue.is_empty() and str(queue[0].get("type", "")) == "ko":
				var nx: Dictionary = queue.pop_front()
				_count(nx)
				group.append(nx)
			await _kos(group)
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
				_vibrate(VIBRATE_MS[tier_of(e, _kos_after(str(e.sid)))])
		"ko":
			if int(e.player) == Net.seat:
				_vibrate(30)
				screen.notify(BLog.line(e, Net.seat))
		_:
			pass
