class_name BHint
## "지금 무엇을 할 수 있나" 표시 도우미 (하스스톤식 안내, docs/ui-hearthstone-review.md 1~3번)
## 모두 보기(view)와 합법 수(actions)만 쓴다 → 앱 화면만 바꾸고 서버·엔진은 그대로

## 남은 수가 턴 종료(와 후퇴·항복)뿐인가 → [턴 종료] 강조. 강제는 안 함 (아끼는 것도 정상적인 수)
static func only_end_left(acts: Array) -> bool:
	var has_end := false
	for m in acts:
		var k := str(m.get("kind", ""))
		if k == "endTurn":
			has_end = true
		elif k != "retreat" and k != "concede":
			return false
	return has_end

## 이 포켓몬 칸으로 지금 할 수 있는 것이 있나 (기술·후퇴는 배틀 포켓몬, 특성은 그 칸)
static func slot_ready(acts: Array, sid: String, active_sid: String) -> bool:
	for m in acts:
		var k := str(m.get("kind", ""))
		if k == "ability" and str(m.get("target", "")) == sid:
			return true
		if (k == "attack" or k == "retreat") and sid == active_sid and active_sid != "":
			return true
	return false

## 손패 카드를 지금 못 쓰는 이유 (엔진 legalMoves 의 조건을 보기에서 추론). 모르면 일반 문구
static func why_unusable(v: Dictionary, seat: int, code: String) -> String:
	if v.is_empty() or str(v.get("phase", "")) != "playing":
		return "지금은 카드를 쓸 수 없습니다."
	if v.get("turnPlayer") != seat:
		return "상대 차례입니다."
	var me: Dictionary = v.players[seat]
	var fl: Dictionary = me.get("flags", {})
	var d := BData.card(code)
	var nm := str(d.get("name", ""))
	var first_turn: bool = v.get("firstPlayer") == seat and int(me.get("turns", 0)) <= 1
	var slots: Array = []
	if me.get("active") != null:
		slots.append(me.active)
	slots.append_array(me.get("bench", []))
	match str(d.get("kind", "")):
		"pokemon":
			var pk: Dictionary = d.get("pokemon", {})
			if int(pk.get("stage", 0)) == 0:
				return "벤치가 가득 찼습니다 (최대 %d마리)." % int(me.get("benchMax", 5))
			var from := str(pk.get("from", ""))
			var has_from := slots.any(func(s): return s.get("stack") != null and BData.name_of(str(s.stack[(s.stack as Array).size() - 1].code)) == from)
			if not has_from:
				return "진화시킬 [%s]이(가) 필드에 없습니다." % from
			if int(me.get("turns", 0)) <= 1:
				return "자기 첫 턴에는 진화할 수 없습니다."
			return "이번 턴에 나온 포켓몬은 다음 턴부터 진화할 수 있습니다."
		"energy":
			if bool(fl.get("energy", false)):
				return "에너지는 한 턴에 한 장만 붙일 수 있습니다. 이번 턴에 이미 붙였습니다."
			return "지금은 이 에너지를 붙일 수 없습니다 (상대 특성 등의 효과)."
		"trainer":
			var sub := str(d.get("trainer", ""))
			if sub == "tool":
				return "도구를 붙일 수 있는 포켓몬이 없습니다 (포켓몬마다 도구는 1장)."
			if sub == "item" and (me.get("effects", []) as Array).any(func(e): return str(e.get("kind", "")) == "itemLock"):
				return "상대 효과로 이번 턴에는 아이템을 쓸 수 없습니다."
			if sub == "supporter":
				if bool(fl.get("supporter", false)):
					return "서포트는 한 턴에 한 장만 쓸 수 있습니다. 이번 턴에 이미 썼습니다."
				if first_turn:
					return "선공 플레이어는 첫 턴에 서포트를 쓸 수 없습니다."
			if sub == "stadium":
				if bool(fl.get("stadium", false)):
					return "스타디움은 한 턴에 한 장만 낼 수 있습니다."
				if v.get("stadium") != null and BData.name_of(str(v.stadium.code)) == nm:
					return "같은 이름의 스타디움이 이미 나와 있습니다."
			if nm == "이상한사탕":
				if int(me.get("turns", 0)) <= 1:
					return "자기 첫 턴에는 이상한사탕을 쓸 수 없습니다."
				return "이상한사탕으로 진화시킬 포켓몬(이번 턴 전에 나온 기본 포켓몬 + 손패의 2진화)이 없습니다."
			return "지금은 사용 조건이 맞지 않습니다 (카드 설명의 조건을 확인하세요)."
	return "지금은 쓸 수 없는 카드입니다."
