class_name AiDuel
## AI 끼리 대전 (PC 확인용): 어려움 AI 대 보통 AI 를 여러 판 돌려 승률·생각 시간을 본다.
## 실행: Godot --headless --path godot -- --ai-duel <판 수> [시작 번호]
## 판마다 덱은 무작위, 자리는 번갈아 (짝수 판은 어려움이 플레이어 1).

static func run(games: int, start := 0) -> void:
	var d := LocalGame.data()
	var cat: Dictionary = d.cat
	var info: Dictionary = d.info
	var decks: Array = cat.decks
	var hard_wins := 0
	var draws := 0
	var total_usec := 0
	var total_dec := 0
	var max_usec := 0
	var by_deck := {}
	var base_wins := 0
	for g in range(start, start + games):
		var seed_rng := GRng.seedRng("%08x" % (g * 7919 + 13))
		var hard_seat := g % 2
		var dk: Array = [decks[GRng.randInt(seed_rng, decks.size())].id, decks[GRng.randInt(seed_rng, decks.size())].id]
		var seed := "%08x%08x%08x%08x" % [GRng.nextU32(seed_rng), GRng.nextU32(seed_rng), GRng.nextU32(seed_rng), GRng.nextU32(seed_rng)]
		var config := { "seed": seed, "players": [
			{ "deckId": dk[0], "cards": GMatch.buildDeck(cat, dk[0]) },
			{ "deckId": dk[1], "cards": GMatch.buildDeck(cat, dk[1]) }] }
		var m := GMatch.new(config, info)
		var hard := GHardBot.make(cat, info)
		if OS.has_environment("HARD_SAMPLES"):
			hard.samples = int(OS.get_environment("HARD_SAMPLES"))
		if OS.has_environment("HARD_OPP"):
			hard.opp_turn = OS.get_environment("HARD_OPP") == "1"
		if OS.has_environment("HARD_CANDS"):
			hard.max_cands = int(OS.get_environment("HARD_CANDS"))
		hard.budget_ms = int(OS.get_environment("HARD_BUDGET")) if OS.has_environment("HARD_BUDGET") else 0
		# 같은 판을 보통 AI 끼리 두면 그 자리가 이기는가 (덱 상성·선후공 운을 빼고 비교하려고)
		var base_win := _normal_game(config, info, cat, seed, hard_seat)
		if base_win == 1:
			base_wins += 1
		var normal := GBot.makeAiBot(cat, info.db)
		var rngs: Array = [GRng.seedRng(seed.reverse()), GRng.seedRng(seed)]
		var t0 := Time.get_ticks_msec()
		var moves := 0
		for guard in 3000:
			if m.state.phase == "ended":
				break
			var who = null
			for seat in [0, 1]:
				if GBot.botHasWork(GView.viewFor(m.state, seat, info)):
					who = seat
					break
			if who == null:
				break
			var inp
			if who == hard_seat:
				inp = hard.decide(m.state, who, rngs[who])
			else:
				inp = normal.call(GView.viewFor(m.state, who, info), rngs[who])
			if inp == null:
				break
			var r := m.submit(who, inp)
			if not r.ok:
				push_warning("판 %d: 입력 거절 (%s) %s" % [g, "어려움" if who == hard_seat else "보통", r.error.message])
				break
			moves += 1
		var res = m.state.result
		var w = res.get("winner") if res is Dictionary else null
		var outcome := "무승부/중단"
		if w != null:
			outcome = "어려움 승" if int(w) == hard_seat else "보통 승"
			if int(w) == hard_seat:
				hard_wins += 1
		else:
			draws += 1
		var hd: String = dk[hard_seat]
		if not by_deck.has(hd):
			by_deck[hd] = [0, 0]
		by_deck[hd][1] += 1
		if w != null and int(w) == hard_seat:
			by_deck[hd][0] += 1
		total_usec += hard.stats.usec
		total_dec += hard.stats.decisions
		max_usec = maxi(max_usec, hard.stats.maxUsec)
		print("[ai-duel] 판 %d: %s(어려움, P%d) vs %s → %s (보통끼리면 %s), %d수, 턴 %d, %.1fs, 생각 평균 %dms 최대 %dms (시뮬 %d)" % [g, hd, hard_seat + 1, dk[1 - hard_seat], outcome, ["패", "승", "-"][base_win if base_win >= 0 else 2], moves, m.state.turnNumber,
			(Time.get_ticks_msec() - t0) / 1000.0, hard.stats.usec / 1000 / maxi(1, hard.stats.decisions), hard.stats.maxUsec / 1000, hard.stats.sims])
	print("[ai-duel] 결과: 어려움 %d승 / %d판 (같은 판 보통끼리면 그 자리 %d승) (무승부·중단 %d), 생각 평균 %dms, 최대 %dms" % [hard_wins, games, base_wins, draws, total_usec / 1000 / maxi(1, total_dec), max_usec / 1000])
	for k in by_deck:
		print("[ai-duel]   %s: %d/%d" % [k, by_deck[k][0], by_deck[k][1]])

## 같은 설정으로 보통 AI 끼리: seat 가 이기면 1, 지면 0, 무승부·중단 -1
static func _normal_game(config: Dictionary, info: Dictionary, cat: Dictionary, seed: String, seat: int) -> int:
	var m := GMatch.new(config, info)
	var bots: Array = [GBot.makeAiBot(cat, info.db), GBot.makeAiBot(cat, info.db)]
	var rngs: Array = [GRng.seedRng(seed.reverse()), GRng.seedRng(seed)]
	for guard in 3000:
		if m.state.phase == "ended":
			break
		var who = GHardBot._actor(m.state)
		if who == null:
			break
		var inp = bots[who].call(GView.viewFor(m.state, who, info), rngs[who])
		if inp == null or not m.submit(who, inp).ok:
			break
	var res = m.state.result
	var w = res.get("winner") if res is Dictionary else null
	return -1 if w == null else (1 if int(w) == seat else 0)

## 서버 없는 AI 연습(LocalGame)을 어려움으로 한 판: 내 자리는 보통 AI 가 대신 두고, AI 는 다른 스레드에서 생각 → 끝까지 가는지
## 실행: Godot --headless --path godot -- --offline-hard-test
static func offline_test(host: Node) -> int:
	var lg := LocalGame.new()
	var got := { "view": {}, "lobby": {}, "errors": [] }
	lg.deliver = func(m: Dictionary):
		match str(m.get("t", "")):
			"state": got.view = m.view
			"lobby": got.lobby = m.lobby
			"error": got.errors.append(m.message)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LocalGame.SAVE_PATH))
	host.add_child(lg)
	lg.start()
	var d := LocalGame.data()
	lg.handle({ "t": "aiLevel", "level": "hard" })
	lg.handle({ "t": "aiSpeed", "ms": 0 })
	var di: Array = (OS.get_environment("OFFLINE_DECKS") if OS.has_environment("OFFLINE_DECKS") else "0,1").split(",")
	lg.handle({ "t": "chooseDeck", "deckId": d.cat.decks[int(di[0])].id })
	lg.handle({ "t": "aiDeck", "deckId": d.cat.decks[int(di[1])].id })
	lg.handle({ "t": "ready", "ready": true })
	var me := GBot.makeAiBot(d.cat, d.info.db)
	var rng := GRng.seedRng("1234abcd")
	var t0 := Time.get_ticks_msec()
	var frames := 0
	var max_frame := 0
	var last := Time.get_ticks_usec()
	while Time.get_ticks_msec() - t0 < 600000:
		await host.get_tree().process_frame
		frames += 1
		var now := Time.get_ticks_usec()
		max_frame = maxi(max_frame, now - last)
		last = now
		var v: Dictionary = got.view
		if OS.has_environment("DUEL_DEBUG") and frames % 2000 == 0:
			var th = lg._think
			print("[offline-hard] 디버그: 프레임 %d, ai_wait %.2f, think %s, 요청 %s, 차례 %s, phase %s" % [frames, lg._ai_wait, "없음" if th == null else "task=%d done=%s ver=%d res=%s" % [th.task, th.done(), th.version, str(th.result)],
				str(lg.match_.state.requests.map(func(r): return [r.player, r.kind]) if lg.match_ != null else []), str(v.get("turnPlayer")), str(v.get("phase"))])
		if v.is_empty():
			continue
		if v.get("result") != null:
			break
		if GBot.botHasWork(v):
			var inp = me.call(v, rng)
			if inp != null:
				lg.handle({ "t": "input", "input": inp })
	var v: Dictionary = got.view
	var ok: bool = v.get("result") != null and got.lobby.get("aiLevel") == "hard"
	print("[offline-hard] %s: 결과 %s, 턴 %d, %.1fs, 프레임 %d개 (가장 긴 프레임 %dms), AI 생각 %d번 평균 %dms, 오류 %s" % ["통과" if ok else "실패", str(v.get("result")), int(v.get("turnNumber", 0)),
		(Time.get_ticks_msec() - t0) / 1000.0, frames, max_frame / 1000, lg._hard.stats.decisions, lg._hard.stats.usec / 1000 / maxi(1, lg._hard.stats.decisions), str(got.errors)])
	lg.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LocalGame.SAVE_PATH))
	return 0 if ok else 1
