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
			if nm == "일격 에너지":
				return "일격 에너지는 '일격' 포켓몬에게만 붙일 수 있습니다."
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
			# 카드에 적힌 사용 조건 (공식 덱 레시피 카드)
			var lost_n: int = (me.get("lost", []) as Array).size()
			var opp_prizes: int = (v.players[1 - seat].get("prizes", []) as Array).filter(func(x): return bool(x)).size()
			var hand_n := int(me.get("handCount", 0))
			match nm:
				"미라주게이트":
					if lost_n < 7:
						return "로스트존에 카드가 7장 이상 있어야 합니다 (지금 %d장)." % lost_n
				"배틀VIP패스":
					if int(me.get("turns", 0)) != 1:
						return "자신의 첫 번째 차례에만 쓸 수 있습니다."
				"민화의 대접":
					if hand_n >= 6:
						return "패가 이 카드를 포함해 6장 이상이면 쓸 수 없습니다 (지금 %d장)." % hand_n
				"원규":
					if opp_prizes > 3:
						return "상대의 남은 사이드가 3장 이하일 때만 쓸 수 있습니다 (지금 %d장)." % opp_prizes
				"교체카트":
					return "배틀 포켓몬이 기본 포켓몬이고 벤치 포켓몬이 있어야 합니다."
				"친구수첩":
					return "트래쉬에 서포트가 없습니다."
				"세레나":
					return "트래쉬할 패도, 끌어낼 상대 벤치의 포켓몬 V 도 없습니다."
				"모란":
					return "패로 되돌릴 기본 포켓몬이 없습니다 (필드에 포켓몬이 2마리 이상 있어야 합니다)."
				"퀵볼", "로스트스위퍼":
					return "패에 이 카드 말고 다른 카드가 1장 이상 있어야 합니다 (로스트스위퍼는 도구·스타디움도 필요)."
			return "지금은 사용 조건이 맞지 않습니다 (카드 설명의 조건을 확인하세요)."
	return "지금은 쓸 수 없는 카드입니다."

## 특성을 지금 못 쓰는 이유 (조건이 있는 특성만, 모르면 "") — 말풍선이 안 열리는 내 포켓몬을 눌렀을 때 안내
static func ability_unusable(ability_name: String, is_active: bool) -> String:
	match ability_name:
		"이상한 꼬리":
			if not is_active:
				return "특성 [이상한 꼬리]: 배틀 포켓몬일 때만 쓸 수 있습니다."
		"플라잉엔트리", "루미너스사인", "래피드 버니어":
			return "특성 [%s]: 버튼으로 쓰는 특성이 아닙니다. 자기 차례에 패에서 벤치로 낼 때 쓸지 물어봅니다 (덱에서 벤치로 나오면 못 씀)." % ability_name
		"연옥 지배", "보석 찾기", "다크시그널":
			return "특성 [%s]: 버튼으로 쓰는 특성이 아닙니다. 자기 차례에 이 포켓몬으로 진화할 때 쓸지 물어봅니다." % ability_name
	return ""
