extends Node
## Autoload: 텍스처 비동기 로딩 + 캐시
## request(path, callback) → 로딩이 끝나면 callback(texture) 호출 (이미 있으면 즉시)
## 썸네일은 계속 보관, 큰 이미지는 최근 MAX_FULL 장만 강하게 보관(LRU).
## 캐시에서 빠진 이미지는 화면에서 쓰고 있지 않으면 바로 해제된다.

const MAX_FULL := 8

var _cache := {}          # path -> Texture2D (강한 참조)
var _weak := {}           # path -> WeakRef (아직 누가 쓰고 있으면 다시 불러오지 않고 재사용)
var _pending := {}        # path -> Array[Callable]
var _full_order: Array[String] = []

func request(path: String, callback: Callable) -> void:
	if path == "":
		return
	var tex := _lookup(path)
	if tex:
		callback.call(tex)
		return
	if _pending.has(path):
		_pending[path].append(callback)
		return
	var err := ResourceLoader.load_threaded_request(path, "Texture2D", true)
	if err != OK:
		push_warning("이미지 로딩 실패: %s (%s)" % [path, error_string(err)])
		return
	_pending[path] = [callback]
	set_process(true)

func get_cached(path: String) -> Texture2D:
	return _lookup(path)

## 미리 불러오기 (콜백 없음)
func preload_path(path: String) -> void:
	request(path, func(_t): pass)

## 큰 이미지 캐시를 keep 장까지 줄인다 (카드 보기 화면을 닫을 때 호출)
func trim(keep := 2) -> void:
	while _full_order.size() > keep:
		_cache.erase(_full_order.pop_front())

## 썸네일 캐시 비우기 (덱 목록 화면을 떠날 때 호출). 다시 들어오면 작아서 금방 다시 불러온다.
func trim_thumbs() -> void:
	for p in _cache.keys():
		if p.contains("/thumb/"):
			_cache.erase(p)

## 디버그용: 캐시에 있는 큰 이미지 수 / 실제로 메모리에 살아있는 큰 이미지 수
func stats() -> Dictionary:
	var alive := 0
	for p in _weak:
		if p.contains("/full/") and _weak[p].get_ref() != null:
			alive += 1
	return { "cached_full": _full_order.size(), "alive_full": alive }

func _lookup(path: String) -> Texture2D:
	if _cache.has(path):
		_touch(path)
		return _cache[path]
	var w: WeakRef = _weak.get(path)
	if w:
		var t: Texture2D = w.get_ref()
		if t:
			_store(path, t)
			return t
		_weak.erase(path)
	return null

func _store(path: String, tex: Texture2D) -> void:
	_cache[path] = tex
	_weak[path] = weakref(tex)
	_touch(path)

func _ready() -> void:
	set_process(false)

func _process(_delta: float) -> void:
	for path in _pending.keys():
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		var callbacks: Array = _pending[path]
		_pending.erase(path)
		if status != ResourceLoader.THREAD_LOAD_LOADED:
			push_warning("이미지 로딩 실패: " + path)
			continue
		var tex: Texture2D = ResourceLoader.load_threaded_get(path)
		_store(path, tex)
		for cb in callbacks:
			if cb.is_valid():
				cb.call(tex)
		callbacks.clear()
	if _pending.is_empty():
		set_process(false)

func _touch(path: String) -> void:
	if not path.contains("/full/"):
		return
	_full_order.erase(path)
	_full_order.append(path)
	while _full_order.size() > MAX_FULL:
		_cache.erase(_full_order.pop_front())
