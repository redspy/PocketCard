class_name BData
## 인쇄 코드 → 카드 규칙 데이터 (앱에 들어 있는 rules.json). 화면 표시용 (HP·타입·약점·에너지 색 등)

static var _idx: Dictionary = {}

const TYPE_COLOR := {
	"G": Color(0.36, 0.72, 0.33), "R": Color(0.92, 0.36, 0.25), "W": Color(0.27, 0.58, 0.93), "L": Color(0.98, 0.82, 0.22),
	"P": Color(0.66, 0.42, 0.85), "F": Color(0.78, 0.5, 0.28), "D": Color(0.3, 0.3, 0.38), "M": Color(0.62, 0.66, 0.7),
	"N": Color(0.78, 0.66, 0.25), "C": Color(0.92, 0.92, 0.9), "*": Color(1, 1, 1),
}
const TYPE_SHORT := { "G": "풀", "R": "불", "W": "물", "L": "번", "P": "초", "F": "격", "D": "악", "M": "강", "N": "드", "C": "무" }

static func card(code: String) -> Dictionary:
	if _idx.is_empty():
		var d := LocalGame.data()
		_idx = GBot.codeIndex(d.cat, d.info.db)
	return _idx.get(code, {})

static func name_of(code: String) -> String:
	return str(card(code).get("name", code))

## 에너지 카드가 주는 색 (기본 에너지 = 타입, 특수 에너지 = "*")
static func energy_type(code: String) -> String:
	var d := card(code)
	if d.get("kind") != "energy":
		return ""
	var e = d.get("energy")
	if e is Dictionary and e.get("basic") and e.get("type") != null:
		return str(e.type)
	return "*"

static func is_tool_card(code: String) -> bool:
	return card(code).get("kind") == "trainer"
