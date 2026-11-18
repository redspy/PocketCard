class_name TapArea
extends Control
## 스크롤과 충돌하지 않는 탭 감지 + 눌림 애니메이션 + 길게 누르기 + 스와이프.
## - 탭: 손가락이 거의 움직이지 않고 뗐을 때 (길게 누르기가 이미 발동했으면 탭이 아님)
## - 길게 누르기: LONG_PRESS 초 동안 움직이지 않고 누르고 있으면 (진동 한 번) — 앱 전체에서 "크게 보기"
## - 스와이프: 빠르게 SWIPE_MIN 이상 밀었다 뗐을 때 방향(Vector2)을 알림
## 손가락이 움직이면(드래그) 탭으로 치지 않아 ScrollContainer 의 관성 스크롤이 그대로 동작한다.

signal tapped
signal long_pressed
signal swiped(delta: Vector2)

const MOVE_TOLERANCE := 18.0
const PRESS_SCALE := 0.96
const LONG_PRESS := 0.45
const SWIPE_MIN := 90.0
const SWIPE_MAX_TIME := 0.6

var press_target: Control   # 눌림 효과를 줄 노드 (기본: 자기 자신)
var _press_pos := Vector2.ZERO
var _pressing := false
var _tracking := false      # 스와이프 판정용 (움직여도 뗄 때까지 유지)
var _press_time := 0.0
var _press_token := 0
var _long_fired := false
var _tw: Tween

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS

func _ready() -> void:
	if press_target == null:
		press_target = self
	resized.connect(_on_resized)
	for c in get_children():
		if c is Control:
			c.minimum_size_changed.connect(update_minimum_size)
	update_minimum_size()

## 자식 중 가장 큰 최소 크기를 따라가도록 (부모 컨테이너가 높이를 제대로 잡게)
func _get_minimum_size() -> Vector2:
	var s := Vector2.ZERO
	for c in get_children():
		if c is Control and c.visible and not (c as Control).top_level:
			s = s.max((c as Control).get_combined_minimum_size())
	return s

func _on_resized() -> void:
	press_target.pivot_offset = press_target.size / 2

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressing = true
			_tracking = true
			_long_fired = false
			_press_pos = event.global_position
			_press_time = Time.get_ticks_msec() / 1000.0
			_animate(PRESS_SCALE, 0.08)
			_wait_long_press()
		else:
			var was_pressing := _pressing
			_pressing = false
			_press_token += 1
			if was_pressing:
				_animate(1.0, 0.16)
			if _long_fired:
				_long_fired = false
				_tracking = false
				return
			var delta: Vector2 = event.global_position - _press_pos
			if was_pressing and delta.length() <= MOVE_TOLERANCE:
				tapped.emit()
			elif _tracking and delta.length() >= SWIPE_MIN and Time.get_ticks_msec() / 1000.0 - _press_time <= SWIPE_MAX_TIME:
				swiped.emit(delta)
			_tracking = false
	elif event is InputEventMouseMotion and _pressing:
		if event.global_position.distance_to(_press_pos) > MOVE_TOLERANCE:
			_pressing = false
			_press_token += 1
			_animate(1.0, 0.16)

func _wait_long_press() -> void:
	_press_token += 1
	var token := _press_token
	if not is_inside_tree():
		return
	await get_tree().create_timer(LONG_PRESS).timeout
	if token != _press_token or not _pressing or not is_inside_tree():
		return
	if long_pressed.get_connections().is_empty():
		return   # 길게 누르기를 쓰지 않는 곳: 그대로 두면 뗄 때 탭
	_long_fired = true
	_pressing = false
	_animate(1.0, 0.16)
	Input.vibrate_handheld(25)
	long_pressed.emit()

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _pressing:
		_pressing = false
		_press_token += 1
		_animate(1.0, 0.16)

func _animate(to: float, dur: float) -> void:
	if not is_inside_tree():
		return
	if _tw:
		_tw.kill()
	press_target.pivot_offset = press_target.size / 2
	_tw = create_tween().set_trans(Tween.TRANS_BACK if to == 1.0 else Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tw.tween_property(press_target, "scale", Vector2(to, to), dur)
