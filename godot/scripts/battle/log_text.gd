class_name BLog
## 사건(event) → 로그 한 줄 (내 시점: "나"/"상대"로). 화면 로그 시트·상대 행동 알림에서 쓴다.

static func who(seat_v, me: int) -> String:
	if seat_v == null:
		return ""
	return "나" if int(seat_v) == me else "상대"

static func line(e: Dictionary, me: int) -> String:
	var t := str(e.get("type", ""))
	var w := who(e.get("player"), me)
	var code := str(e.get("code", ""))
	var nm := BData.name_of(code) if code != "" else ""
	match t:
		"move":
			var to: Dictionary = e.to
			var from: Dictionary = e.from
			if str(from.zone) == "deck" and str(to.zone) == "hand":
				return "%s: 카드 1장 뽑음" % who(to.player, me)
			return ""
		"coin": return "코인 %s — %s" % ["앞면" if bool(e.heads) else "뒷면", str(e.get("reason", ""))]
		"firstPlayer": return "%s 선공" % w
		"mulligan": return "%s: 멀리건 (%d번째)" % [w, int(e.get("count", 1))]
		"turnStart": return "── 턴 %d · %s 차례" % [int(e.turnNumber), w]
		"play": return "%s: %s — %s" % [w, nm, str(e.get("what", ""))]
		"attack": return "%s: %s 기술 [%s]" % [w, nm, str(e.get("name", ""))]
		"ability": return "%s: %s 특성 [%s]" % [w, nm, str(e.get("name", ""))]
		"damage": return "   → %s 포켓몬 %s %d" % [w, "카운터" if bool(e.get("counters", false)) else "데미지", int(e.amount)]
		"heal": return "   → %s 포켓몬 %d 회복" % [w, int(e.amount)]
		"condition":
			if bool(e.get("on", false)):
				return "   → %s 포켓몬 %s" % [w, { "asleep": "잠듦", "paralyzed": "마비", "confused": "혼란", "poison": "독", "burn": "화상", "burned": "화상" }.get(str(e.cond), str(e.cond))]
			return "   → %s 포켓몬 %s 회복" % [w, { "asleep": "잠듦", "paralyzed": "마비", "burned": "화상" }.get(str(e.cond), str(e.cond))]
		"ko": return "☠ %s의 %s 기절 — 상대가 사이드 %d장" % [w, nm, int(e.prizes)]
		"switch": return "   → %s 배틀 포켓몬 교체" % w
		"note": return "   · " + str(e.get("text", ""))
		"gameEnd": return "게임 종료"
	return ""

## 최근 줄들 (최신이 위)
static func recent(events: Array, me: int, n := 200) -> Array:
	var out: Array = []
	for i in range(events.size() - 1, -1, -1):
		var l := line(events[i], me)
		if l != "":
			out.append(l)
			if out.size() >= n:
				break
	return out
