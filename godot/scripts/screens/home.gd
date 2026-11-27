class_name HomeScreen
extends Control
## 첫 화면 (아래 탭: 홈 / 덱 / 대전)
##  홈: 큰 제목 + 대표 덱 카드 + 주 행동 [AI와 연습] + [덱 둘러보기] + 화면 테마
##  대전 (battle_tab): 대전 방법 세 가지 — AI와 연습(주 행동) / 폰끼리 대전 / PC 게임판에 참가

var battle_tab := false

func _init(p_battle_tab := false) -> void:
	battle_tab = p_battle_tab

func _ready() -> void:
	var col := Lay.page(self)
	col.add_child(UI.label("대전" if battle_tab else "포켓카드", 52))
	if DeckData.load_error != "":
		col.add_child(Lay.wrap("데이터 오류: " + DeckData.load_error, 26, UI.BAD))
		Lay.tabs(self, "대전" if battle_tab else "홈")
		return
	if battle_tab:
		_build_battle(col)
	else:
		_build_home(col)
	Lay.tabs(self, "대전" if battle_tab else "홈")

# ───────────── 홈 ─────────────

func _build_home(col: VBoxContainer) -> void:
	col.add_child(Lay.wrap("2026 코리안리그 우승 덱으로 카드를 보고 대전합니다.", 24, UI.TEXT_DIM))
	var recent := _recent_deck()
	var d: Dictionary = recent if not recent.is_empty() else DeckData.decks[0]
	col.add_child(_featured(d, not recent.is_empty()))
	var solo := _button(col, "AI와 연습 이어하기" if HomeScreen.has_saved_game() else "AI와 연습", true, start_solo)
	solo.set_meta("home", "solo")
	var browse := _button(col, "덱 둘러보기", false, func(): Lay.open_tab("덱"))
	browse.set_meta("home", "decks")
	col.add_child(_theme_card())

## 대표 덱: 최근에 연습한 덱 (없으면 첫 덱). 누르면 덱 카드 목록
func _featured(d: Dictionary, recent: bool) -> Control:
	var c := Lay.tap_card(Lay.deck_tint(d), 22)
	var tap: TapArea = c[0]
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 22)
	(c[1] as VBoxContainer).add_child(row)
	row.add_child(Lay.cover(d, 190, -4, true))
	var info := VBoxContainer.new()
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_theme_constant_override("separation", 10)
	var tag := UI.chip("최근에 쓴 덱" if recent else "추천 덱", UI.ACCENT)
	tag.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	info.add_child(tag)
	info.add_child(Lay.wrap(str(d["name"]), 38, UI.ACCENT))
	info.add_child(Lay.wrap(DeckListScreen.short_note(str(d["note"])), 21, UI.TEXT_DIM))
	info.add_child(Lay.kind_chips(d))
	row.add_child(info)
	tap.set_meta("deck", str(d["id"]))
	tap.tapped.connect(func(): Nav.push(DeckDetailScreen.new(d)))
	return tap

## 화면 테마: 기기 설정 / 밝게 / 어둡게 (바꾸면 화면을 새 색으로 다시 만든다)
func _theme_card() -> Control:
	var c := Lay.card(UI.PANEL, 20)
	var col: VBoxContainer = c[1]
	col.add_child(UI.label("화면", 28, UI.ACCENT))
	col.add_child(Lay.wrap("기기 설정은 폰의 다크 모드를 따릅니다.", 20, UI.TEXT_DIM))
	var pick := func(mode: String):
		if mode == UI.theme_mode:
			return
		UI.set_theme(mode)
		Nav.restart(HomeScreen.new())
	var seg := Lay.segmented(UI.THEMES, UI.theme_mode, pick, 24)
	seg.set_meta("theme", true)
	col.add_child(seg)
	return c[0]

## 최근에 AI 연습에 쓴 내 덱 (이 폰 저장 파일), 없으면 {}
static func _recent_deck() -> Dictionary:
	if not FileAccess.file_exists(LocalGame.SAVE_PATH):
		return {}
	var f := FileAccess.open(LocalGame.SAVE_PATH, FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text()) if f else null
	if not (d is Dictionary):
		return {}
	var id := str(d.get("myDeck", ""))
	for deck in DeckData.decks:
		if str(deck["id"]) == id:
			return deck
	return {}

## 끝나지 않은 AI 연습이 저장되어 있나 (있으면 이어서 시작)
static func has_saved_game() -> bool:
	if not FileAccess.file_exists(LocalGame.SAVE_PATH):
		return false
	var f := FileAccess.open(LocalGame.SAVE_PATH, FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text()) if f else null
	return d is Dictionary and d.get("log") is Dictionary

# ───────────── 대전 ─────────────

func _build_battle(col: VBoxContainer) -> void:
	col.add_child(Lay.wrap("대전 방법을 고르세요.", 24, UI.TEXT_DIM))
	var solo := _mode(col, "AI와 연습 이어하기" if HomeScreen.has_saved_game() else "AI와 연습", "서버 없이 이 폰 안에서 AI와 1:1. 하던 게임은 앱을 껐다 켜도 이어집니다.", true, start_solo)
	solo.set_meta("home", "solo")
	var duel := _mode(col, "폰끼리 대전", "같은 Wi-Fi(또는 한 폰의 핫스팟)에 있는 두 폰이 1:1. 한 폰이 방을 만들고 다른 폰이 들어갑니다.", false, func(): Nav.push(JoinScreen.new(false, true)))
	duel.set_meta("home", "phone")
	var join := _mode(col, "PC 게임판에 참가", "PC에서 연 게임판(npm run server)과 같은 Wi-Fi에서 대전합니다. 큰 화면은 PC에.", false, func(): Nav.push(JoinScreen.new()))
	join.set_meta("home", "join")

## 대전 방법 한 칸: 버튼 + 설명
func _mode(col: VBoxContainer, title: String, desc: String, primary: bool, action: Callable) -> TapArea:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var b := UI.button(title, 30 if primary else 28, primary, primary)
	(b.get_meta("panel") as Control).set_anchors_preset(Control.PRESET_FULL_RECT)
	b.tapped.connect(action)
	box.add_child(b)
	var l := Lay.wrap(desc, 20, UI.TEXT_DIM)
	box.add_child(l)
	col.add_child(box)
	return b

# ───────────── 공통 ─────────────

func _button(col: VBoxContainer, text: String, primary: bool, action: Callable) -> TapArea:
	var b := UI.button(text, 30 if primary else 28, primary, primary)
	(b.get_meta("panel") as Control).set_anchors_preset(Control.PRESET_FULL_RECT)
	b.tapped.connect(action)
	col.add_child(b)
	return b

## AI와 연습 시작 (서버 없이 이 폰 안의 규칙 엔진). deck_id 를 주면 그 덱을 골라 둔다
static func start_solo(deck_id := "") -> void:
	Net.start_offline()
	if deck_id != "":
		Net.send({ "t": "chooseDeck", "deckId": deck_id, "prints": DeckData.choices_for(deck_id) })
	Nav.push(LobbyScreen.new())
