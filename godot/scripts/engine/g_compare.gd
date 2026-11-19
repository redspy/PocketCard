class_name GCompare
## 엔진 비교 실행기: scripts/engine-compare.ts 가 TS 엔진으로 기록한 판들을 GDScript 엔진으로 다시 돌려
## 입력마다 상태·이벤트·보기 지문과 AI 가 고른 입력이 같은지 확인한다.
## 실행: Godot --headless --path godot -- --engine-compare <기록 파일>

## 정규화 문자열 (scripts/engine-compare.ts 의 canon 과 같은 규칙)
static func canon(v) -> String:
	match typeof(v):
		TYPE_NIL: return "null"
		TYPE_BOOL: return "true" if v else "false"
		TYPE_INT: return str(v)
		TYPE_FLOAT: return str(int(v)) if v == floorf(v) else "F%s" % str(v)
		TYPE_STRING, TYPE_STRING_NAME:
			return "\"%s\"" % String(v).replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")
		TYPE_ARRAY:
			var parts: Array = []
			for x in v:
				parts.append(canon(x))
			return "[%s]" % ",".join(parts)
		TYPE_DICTIONARY:
			var keys: Array = []
			for k in v:
				if v[k] != null:
					keys.append(str(k))
			keys.sort()
			var parts: Array = []
			for k in keys:
				parts.append("%s:%s" % [canon(k), canon(v[k])])
			return "{%s}" % ",".join(parts)
	return "\"?%s\"" % str(v)

static func _load_json(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return GCore.intify(JSON.parse_string(f.get_as_text()))

## 같은지 비교. full 기록(긴 문자열)이면 처음 다른 곳을 보여준다
static func _diff(expected: String, got_canon: String) -> String:
	if expected.length() == 32:
		return "" if got_canon.md5_text() == expected else "지문 다름"
	if expected == got_canon:
		return ""
	var i := 0
	while i < mini(expected.length(), got_canon.length()) and expected[i] == got_canon[i]:
		i += 1
	var a := maxi(0, i - 160)
	return "위치 %d\n    TS : …%s\n    GD : …%s" % [i, expected.substr(a, 320), got_canon.substr(a, 320)]

static func run(path: String) -> int:
	var data = _load_json(path)
	if data == null:
		print("[compare] 기록 파일을 읽지 못함: %s" % path)
		return 2
	var raw = _load_json("res://data/decks.json")
	# --all-decks: playable: false 덱(대전 준비 중)도 카탈로그에 넣는다
	if data.get("allDecks") == true:
		for d in raw.decks:
			d.erase("playable")
	var rules = _load_json("res://data/rules.json")
	var cat := GMatch.buildCatalog(raw)
	var info := { "basics": cat.basics, "db": rules.cards }
	var problems: Array = []
	var total := 0
	var t0 := Time.get_ticks_msec()
	for gi in data.games.size():
		var g: Dictionary = data.games[gi]
		var config := { "seed": g.seed, "players": [
			{ "deckId": g.decks[0], "cards": GMatch.buildDeck(cat, g.decks[0]) },
			{ "deckId": g.decks[1], "cards": GMatch.buildDeck(cat, g.decks[1]) }] }
		var m := GMatch.new(config, info)
		var where := "판 %d (%s vs %s, 시드 %s)" % [gi, g.decks[0], g.decks[1], g.seed]
		var d := _diff(g.init.state, canon(m.state))
		if d != "":
			problems.append("%s 시작 상태: %s" % [where, d])
			continue
		d = _diff(g.init.events, canon(m.lastEvents))
		if d != "":
			problems.append("%s 시작 이벤트: %s" % [where, d])
			continue
		var ai: Callable = (func(v, r): return GBot.randomBot(v, r)) if g.get("bot") == "random" else GBot.makeAiBot(cat, info.db)
		var seed_str: String = g.seed
		var rev := ""
		for i in range(seed_str.length() - 1, -1, -1):
			rev += seed_str[i]
		var rng := GRng.seedRng(rev)
		var bot_bad := false
		for si in g.steps.size():
			var st: Dictionary = g.steps[si]
			total += 1
			var seat: int = st.seat
			var view := GView.viewFor(m.state, seat, info)
			d = _diff(st.view, canon(view))
			if d != "":
				problems.append("%s 입력 %d 보기(플레이어 %d): %s" % [where, si, seat + 1, d])
				break
			var mine = ai.call(view.duplicate(true), rng)
			if not bot_bad and canon(mine) != canon(st.input):
				bot_bad = true
				problems.append("%s 입력 %d AI 선택 다름\n    TS : %s\n    GD : %s" % [where, si, canon(st.input), canon(mine)])
			var r := m.submit(seat, st.input)
			if not r.ok:
				problems.append("%s 입력 %d 거절: %s %s (입력 %s)" % [where, si, r.error.code, r.error.message, canon(st.input)])
				break
			d = _diff(st.state, canon(m.state))
			if d != "":
				problems.append("%s 입력 %d 상태 (입력 %s): %s" % [where, si, canon(st.input), d])
				break
			d = _diff(st.events, canon(r.events))
			if d != "":
				problems.append("%s 입력 %d 이벤트 (입력 %s): %s" % [where, si, canon(st.input), d])
				break
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	if problems.is_empty():
		print("[compare] 결과: 일치 — %d판, 입력 %d개 (%.1f초)" % [data.games.size(), total, secs])
		return 0
	print("[compare] 결과: 불일치 %d곳 — %d판, 입력 %d개 (%.1f초)" % [problems.size(), data.games.size(), total, secs])
	for p in problems.slice(0, 12):
		print("[compare] " + str(p).replace("\n", "\n[compare] "))
	return 1
