class_name BSlot
extends Control
## 필드의 포켓몬 한 칸: 카드 + 남은 HP(숫자·막대) + 붙은 에너지 점 + 도구 + 특수상태 + (배틀이면) 약점·저항
## sid 로 유지하는 노드 (다시 만들지 않고 set_slot 으로 갱신 → 연출에서 이동·흔들림 가능)

var sid := ""
var slot: Dictionary = {}
var face_down := false              # 뒷면(준비 단계) — HP 등 앞면 정보는 숨김
var card: BCard
var hp_shown := -1                 # 연출 중 보여주는 남은 HP (-1 = 실제 값)
var _hp_label: Label
var _hp_bar_bg: ColorRect
var _hp_bar: ColorRect
var _dots: HBoxContainer
var _badges: VBoxContainer
var _weak: Label
var _tool: Label
var _empty: Panel
var hit: TapArea                   # 빈 칸도 누를 수 있게 (카드가 없을 때 받음)

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	_empty = Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.03)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(2)
	sb.border_color = Color(1, 1, 1, 0.16)
	_empty.add_theme_stylebox_override("panel", sb)
	_empty.set_anchors_preset(Control.PRESET_FULL_RECT)
	_empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_empty)
	hit = TapArea.new()
	hit.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(hit)
	card = BCard.new()
	card.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(card)
	_hp_bar_bg = ColorRect.new()
	_hp_bar_bg.color = Color(0, 0, 0, 0.6)
	_hp_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hp_bar_bg)
	_hp_bar = ColorRect.new()
	_hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hp_bar)
	_hp_label = UI.label("", 22, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	add_child(_hp_label)
	_dots = HBoxContainer.new()
	_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dots.add_theme_constant_override("separation", 2)
	add_child(_dots)
	_badges = VBoxContainer.new()
	_badges.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badges.add_theme_constant_override("separation", 2)
	add_child(_badges)
	_weak = UI.label("", 16, Color.WHITE)
	add_child(_weak)
	_tool = UI.label("", 16, Color(0.1, 0.1, 0.1))
	add_child(_tool)
	resized.connect(_relayout)

## slot: 보기의 SlotView (null 이면 빈 칸). active: 배틀 포켓몬(약점 표시)
func set_slot(s, active := false) -> void:
	slot = s if s is Dictionary else {}
	sid = str(slot.get("sid", ""))
	var has := not slot.is_empty()
	_empty.visible = not has
	card.visible = has
	hit.visible = not has
	face_down = has and (bool(slot.get("faceDown", false)) or slot.get("stack") == null)
	var top := ""
	if has and not face_down:
		var st: Array = slot.stack
		top = str(st[st.size() - 1].code)
	card.set_card(top, size.x >= 150)
	# 특수상태: 카드 기울임 (잠듦 왼쪽, 마비 오른쪽, 혼란 뒤집힘 — 실물 카드 관례) + 배지
	var cond: Dictionary = slot.get("cond", {})
	var rot := str(cond.get("rot", ""))
	card.pivot_offset = size / 2
	card.rotation_degrees = { "asleep": -14.0, "paralyzed": 14.0, "confused": 180.0 }.get(rot, 0.0)
	for c in _badges.get_children():
		c.queue_free()
	var names := { "asleep": "잠듦", "paralyzed": "마비", "confused": "혼란" }
	if rot != "":
		_badges.add_child(_badge(names.get(rot, rot), Color(0.55, 0.3, 0.75)))
	if int(cond.get("poison", 0)) > 0:
		_badges.add_child(_badge("독" + ("×%d" % int(cond.poison) if int(cond.poison) > 1 else ""), Color(0.45, 0.2, 0.6)))
	if bool(cond.get("burn", false)):
		_badges.add_child(_badge("화상", Color(0.85, 0.35, 0.15)))
	for e in slot.get("effects", []):
		var t = { "noAttack": "기술 불가", "noRetreat": "후퇴 불가", "reduce30": "-30", "immuneBasicNonC": "기본 무효", "lockAttack": "%s 불가" % str(e.get("name", "기술")) }.get(str(e.kind))
		if t != null:
			_badges.add_child(_badge(t, Color(0.25, 0.35, 0.5)))
	# 붙은 에너지 점 (6개 넘으면 ×N) + 도구
	for c in _dots.get_children():
		c.queue_free()
	var tool_name := ""
	var energies: Array = []
	for a in (slot.get("attached") if slot.get("attached") is Array else []):
		var et := BData.energy_type(str(a.code))
		if et != "":
			energies.append(et)
		elif BData.is_tool_card(str(a.code)):
			tool_name = BData.name_of(str(a.code))
	var dot := clampf(size.x * 0.13, 12.0, 40.0)   # 큰 카드(손패 모드 배틀 포켓몬)에서도 점이 과하게 커지지 않게
	for i in mini(energies.size(), 6):
		_dots.add_child(_dot(energies[i], dot))
	if energies.size() > 6:
		_dots.add_child(UI.label("×%d" % energies.size(), int(dot * 0.9), Color.WHITE))
	_tool.text = (" ◆%s " % (tool_name if tool_name.length() <= 5 else tool_name.left(4) + "…")) if tool_name != "" else ""
	_tool.add_theme_stylebox_override("normal", UI.box(Color(0.85, 0.85, 0.9, 0.92), 6))
	_tool.visible = tool_name != ""
	# 약점·저항 (배틀 포켓몬만, 늘 보이게 — 순간만 뜨면 기억에 의존하게 됨)
	_weak.visible = false
	if active and top != "":
		var pk = BData.card(top).get("pokemon")
		if pk is Dictionary:
			var parts: Array = []
			if pk.get("weak") != null:
				parts.append("약 %s×2" % BData.TYPE_SHORT.get(str(pk.weak), str(pk.weak)))
			if pk.get("resist") != null:
				parts.append("저 %s-30" % BData.TYPE_SHORT.get(str(pk.resist), str(pk.resist)))
			if not parts.is_empty():
				_weak.text = " " + " · ".join(parts) + " "
				_weak.add_theme_stylebox_override("normal", UI.box(Color(0, 0, 0, 0.72), 6))
				_weak.visible = true
	_update_hp()
	_relayout()

func _badge(t: String, c: Color) -> Label:
	var l := UI.label(" %s " % t, clampi(int(size.x * 0.11), 14, 30), Color.WHITE)
	l.add_theme_stylebox_override("normal", UI.box(c, 6))
	return l

func _dot(t: String, d: float) -> Control:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(d, d)
	var sb := StyleBoxFlat.new()
	sb.bg_color = BData.TYPE_COLOR.get(t, Color.WHITE)
	sb.set_corner_radius_all(int(d / 2))
	sb.set_border_width_all(2)
	sb.border_color = Color(0, 0, 0, 0.7)
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p

func max_hp() -> int:
	return int(slot.hp) if slot.get("hp") != null else 0

func real_left() -> int:
	return max_hp() - int(slot.get("damage", 0))

func left_shown() -> int:
	return hp_shown if hp_shown >= 0 else real_left()

## 연출용: 보여주는 HP 를 바꾼다 (-1 = 실제 값)
func show_hp(v: int) -> void:
	hp_shown = v
	_update_hp()

func _update_hp() -> void:
	var has := slot.get("hp") != null and not slot.is_empty() and not face_down
	_hp_label.visible = has
	_hp_bar.visible = has
	_hp_bar_bg.visible = has
	if not has:
		return
	var mx := max_hp()
	var left := left_shown()
	_hp_label.text = str(maxi(0, left))
	var low := left <= mx / 3
	_hp_label.add_theme_stylebox_override("normal", UI.box(Color(0.8, 0.2, 0.18) if low else Color(0, 0, 0, 0.78), 8))
	_hp_bar.color = Color(0.9, 0.3, 0.25) if low else Color(0.35, 0.85, 0.45)
	_relayout()

func _relayout() -> void:
	var w := size.x
	var h := size.y
	card.pivot_offset = size / 2
	var fs := clampi(int(w * 0.16), 16, 56)
	_hp_label.add_theme_font_size_override("font_size", fs)
	# 세 자리 폭을 늘 덮는다: 남은 HP 가 두 자리면 카드에 인쇄된 HP 숫자 일부가 옆으로 삐져나와 "2"+"70" 처럼 보임
	_hp_label.custom_minimum_size.x = fs * 1.9
	_hp_label.size = Vector2.ZERO
	_hp_label.position = Vector2(w - _hp_label.get_minimum_size().x - 2, 2)
	var bh := maxf(5.0, h * 0.03)
	_hp_bar_bg.position = Vector2(4, h - bh - 4)
	_hp_bar_bg.size = Vector2(w - 8, bh)
	var mx := max_hp()
	var frac := clampf(float(left_shown()) / mx, 0.0, 1.0) if mx > 0 else 0.0
	_hp_bar.position = _hp_bar_bg.position
	_hp_bar.size = Vector2((w - 8) * frac, bh)
	_dots.position = Vector2(4, h - bh - 8 - _dots.get_combined_minimum_size().y)
	_badges.position = Vector2(2, fs + 10)
	_weak.add_theme_font_size_override("font_size", clampi(int(w * 0.08), 13, 26))
	_weak.size = Vector2.ZERO
	_weak.position = Vector2(2, -_weak.get_minimum_size().y - 2)
	_tool.add_theme_font_size_override("font_size", clampi(int(w * 0.09), 12, 26))
	_tool.size = Vector2.ZERO
	_tool.position = Vector2(w - _tool.get_minimum_size().x - 2, h - bh - 10 - _tool.get_minimum_size().y)

## 강조: 카드가 있으면 카드에, 빈 칸이면 빈 칸 틀에
func set_mark(kind: String) -> void:
	if card.visible:
		card.set_mark(kind)
		var esb := _empty.get_theme_stylebox("panel") as StyleBoxFlat
		esb.border_color = Color(1, 1, 1, 0.16)
	else:
		var sb := _empty.get_theme_stylebox("panel") as StyleBoxFlat
		sb.border_color = UI.ACCENT if kind == "target" else Color(1, 1, 1, 0.16)
		sb.set_border_width_all(5 if kind == "target" else 2)
		_empty_mark = kind

var _empty_mark := ""

func mark() -> String:
	return card.mark() if card.visible else _empty_mark
