extends Node
## Autoload (디버그 빌드 전용): 2초마다 FPS / 프레임 시간 / 메모리를 로그로 남긴다.
## 폰에서 `adb logcat -s godot` 로 확인. 릴리스 빌드에서는 아무것도 하지 않는다.

const INTERVAL := 2.0

var _t := 0.0
var _worst_ms := 0.0

func _ready() -> void:
	set_process(OS.is_debug_build() and OS.get_name() == "Android")

func _process(delta: float) -> void:
	_worst_ms = maxf(_worst_ms, delta * 1000.0)
	_t += delta
	if _t < INTERVAL:
		return
	_t = 0.0
	var s: Dictionary = ImageCache.stats()
	print("[perf] fps=%d worst=%.1fms static=%.1fMB tex=%.1fMB full(cached=%d alive=%d) screen=%s" % [
		Engine.get_frames_per_second(),
		_worst_ms,
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		s["cached_full"], s["alive_full"],
		str(get_viewport().get_visible_rect().size.round()),
	])
	_worst_ms = 0.0
