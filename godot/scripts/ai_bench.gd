class_name AiBench
## 엔진 단계별 시간 (어려움 AI 최적화용): 보통 AI 끼리 한 판 두며 viewFor / _aiMove / applyInput / 상태 복사 시간을 잰다.
## 실행: Godot --headless --path godot -- --ai-bench

static func run() -> void:
	var d := LocalGame.data()
	var cat: Dictionary = d.cat
	var info: Dictionary = d.info
	var bc := GBot.codeIndex(cat, info.db)
	var t := { "view": 0, "viewNoCopy": 0, "move": 0, "apply": 0, "dup": 0, "legal": 0 }
	var n := 0
	for g in 3:
		var seed := "%08x%08x%08x%08x" % [g + 1, g * 77 + 5, 99, 1234]
		var dk: Array = [cat.decks[g % cat.decks.size()].id, cat.decks[(g + 3) % cat.decks.size()].id]
		var m := GMatch.new({ "seed": seed, "players": [
			{ "deckId": dk[0], "cards": GMatch.buildDeck(cat, dk[0]) },
			{ "deckId": dk[1], "cards": GMatch.buildDeck(cat, dk[1]) }] }, info)
		var sts: Array = [{ "counted": { "turn": -1, "version": -1, "seat": -1, "n": 0 } }, { "counted": { "turn": -1, "version": -1, "seat": -1, "n": 0 } }]
		var rng := GRng.seedRng(seed)
		for guard in 2000:
			if m.state.phase == "ended":
				break
			var who = GHardBot._actor(m.state)
			if who == null:
				break
			var t0 := Time.get_ticks_usec()
			var v := GView.viewFor(m.state, who, info)
			var t1 := Time.get_ticks_usec()
			GView.viewFor(m.state, who, info, false)
			t.viewNoCopy += Time.get_ticks_usec() - t1
			t1 = Time.get_ticks_usec()
			var inp = GBot._aiMove(bc, sts[who], v, rng)
			var t2 := Time.get_ticks_usec()
			var r := m.submit(who, inp)
			var t3 := Time.get_ticks_usec()
			var _c = m.state.duplicate(true)
			var t4 := Time.get_ticks_usec()
			GEngine.legalMoves(m.state, who, info)
			var t5 := Time.get_ticks_usec()
			t.view += t1 - t0
			t.move += t2 - t1
			t.apply += t3 - t2
			t.dup += t4 - t3
			t.legal += t5 - t4
			n += 1
			if not r.ok:
				break
	for k in t:
		print("[ai-bench] %s: 평균 %dus" % [k, t[k] / maxi(1, n)])
	print("[ai-bench] 단계 %d" % n)
