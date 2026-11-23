class_name DeckSelectScreen
extends Control
## 덱 선택 화면: 덱마다 대표 카드가 크게 보이는 카드형 버튼

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = UI.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.scroll_deadzone = 12
	add_child(scroll)

	var m := UI.margin(28)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_theme_constant_override("margin_top", int(UI.safe_top(self)) + 36)
	m.add_theme_constant_override("margin_bottom", int(UI.safe_bottom(self)) + 28)
	scroll.add_child(m)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 28)
	m.add_child(col)

	col.add_child(UI.label("덱 뷰어", 52, UI.TEXT))
	col.add_child(UI.label("2026 코리안리그 우승 덱", 26, UI.TEXT_DIM))

	# 대전: PC 게임판에 참가
	var join := UI.wide(UI.button("⚔  게임 참가 (PC 게임판과 대전)", 32, true, true), HORIZONTAL_ALIGNMENT_LEFT)
	join.tapped.connect(func(): Nav.push(JoinScreen.new()))
	col.add_child(join)
	# 연습: 게임판 없이 폰 한 대로 서버 AI 와 대전
	# 연습: 서버·게임판 없이 이 폰 안에서 AI 와 대전 (규칙 엔진이 앱에 들어 있음)
	var solo := UI.wide(UI.button("🤖  AI와 연습 (서버 없이 이 폰에서)", 30, true), HORIZONTAL_ALIGNMENT_LEFT)
	solo.tapped.connect(func():
		Net.start_offline()
		Nav.push(LobbyScreen.new()))
	col.add_child(solo)
	# 폰끼리: 서버·게임판 없이 같은 Wi-Fi(또는 핫스팟)의 두 폰이 1:1 대전 (한 폰이 방장)
	var duel := UI.wide(UI.button("📱  폰끼리 대전 (서버 없이)", 30, true), HORIZONTAL_ALIGNMENT_LEFT)
	duel.tapped.connect(func(): Nav.push(JoinScreen.new(false, true)))
	col.add_child(duel)

	if DeckData.load_error != "":
		col.add_child(UI.label("데이터 오류: " + DeckData.load_error, 26, Color(1, 0.5, 0.5), HORIZONTAL_ALIGNMENT_LEFT, true))
		return

	var i := 0
	for d in DeckData.decks:
		var item := _deck_item(d)
		col.add_child(item)
		# 등장 애니메이션 (아래에서 살짝 떠오르며)
		item.modulate.a = 0.0
		var tw := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_interval(0.08 + i * 0.09)
		tw.tween_property(item, "modulate:a", 1.0, 0.35)
		i += 1

func _deck_item(d: Dictionary) -> Control:
	var tap := TapArea.new()

	var card_panel := UI.panel(UI.PANEL, 28)
	card_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	card_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tap.add_child(card_panel)
	tap.press_target = card_panel

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := UI.margin(22)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(row)
	card_panel.add_child(m)

	# 대표 카드 (살짝 기울여서)
	var cover_holder := Control.new()
	cover_holder.custom_minimum_size = Vector2(220, 307)
	cover_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cover := TextureRect.new()
	cover.size = Vector2(220, 307)
	cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cover.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	cover.pivot_offset = cover.size / 2
	cover.rotation = deg_to_rad(-4)
	cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cover_holder.add_child(cover)
	row.add_child(cover_holder)
	var cover_card := DeckData.card_by_code(d, d["cover"])
	if not cover_card.is_empty():
		ImageCache.request(cover_card["full"], func(t): cover.texture = t)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_theme_constant_override("separation", 12)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(info)

	info.add_child(UI.label(d["name"], 42, UI.ACCENT))
	var note := UI.label(_short_note(d["note"]), 22, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, true)
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(note)
	info.add_child(UI.label("%d장" % int(d["total"]), 30, UI.TEXT))
	var chips := HFlowContainer.new()
	chips.add_theme_constant_override("h_separation", 8)
	chips.add_theme_constant_override("v_separation", 8)
	chips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for kind in ["pokemon", "trainer", "energy"]:
		chips.add_child(UI.chip("%s %d" % [DeckData.KIND_LABEL[kind], int(d["counts"][kind])], UI.KIND_COLOR[kind]))
	info.add_child(chips)

	tap.tapped.connect(func(): Nav.push(DeckDetailScreen.new(d)))
	return tap

func _short_note(note: String) -> String:
	# "2026 코리안리그 시즌1 시니어 우승 (덱 코드 ...)" → 괄호 앞까지
	var i := note.find(" (")
	return note.substr(0, i) if i > 0 else note
