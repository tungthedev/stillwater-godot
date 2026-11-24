extends CanvasLayer

# Stillwater's interface (index.html styles, src/ui.js), in Godot controls. One unit is one CSS
# pixel (main.gd sets the content scale to the device pixel ratio), so the sizes below are
# Stillwater's CSS values, including its phone (width <= 600) and short-landscape (height <= 460)
# rules. Safe-area insets come from the page (web/shell.html #safe).
#
# Parts: title (name, line, begin, key pill), HUD (compass with place markers, stats, place
# card, prompt, toast), touch controls (floating stick, pause, Trail / Sit), pause sheet. Only the
# controls that work today are shown: Lamp, Time, music and the hour keys come with day and night.

signal start_pressed
signal resume_pressed
signal button(action: String)

const INK := Color(0.957, 0.925, 0.867)
const DIM := Color(0.957, 0.925, 0.867, 0.62)
const POI_COL := Color(1.0, 0.847, 0.604)
const SERIF := "res://fonts/cormorant-garamond-latin.woff2"
const SERIF_I := "res://fonts/cormorant-garamond-italic-latin.woff2"
const SANS := "res://fonts/inter-latin.woff2"
const SPAN := PI * 0.85

var touch := false
var safe := Vector4.ZERO  # top, right, bottom, left
var vs := Vector2(390, 844)

var fade_rect: ColorRect
var title: Control
var title_bg: TextureRect
var title_box: VBoxContainer
var h1: Label
var sub: Label
var begin: Label
var keys_pill: PanelContainer
var keys_flow: HFlowContainer
var hud: Control
var compass: Control
var marks: Array[Dictionary] = []
var poi_marks := {}
var stats: VBoxContainer
var st_alt: Label
var st_clock: Label
var st_walk: Label
var place_box: VBoxContainer
var place_n: Label
var place_d: Label
var place_line: ColorRect
var prompt: Label
var toast_l: Label
var touch_layer: Control
var stick: Panel
var knob: Panel
var pause_btn: Button
var actions_grid: GridContainer
var btn := {}
var paused_layer: Control
var paused_box: VBoxContainer
var paused_h: Label
var paused_keys: VBoxContainer
var resume_btn: Button
var dev_btn: Button

var _fonts := {}
var _tweens := {}
var _toast_until := -1.0
var _place_until := -1.0
var _prompt_text := ""
var _breathe := 0.0
var _hud_on := true
var _hud_live := false
var _btn_key := []
var blockers: Array[Control] = []
var _touch_btns := {}
var _touch_fire_ms := {}


func _ready() -> void:
	layer = 5
	_read_safe()
	fade_rect = ColorRect.new()
	fade_rect.color = Color(0, 0, 0, 1)
	fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(fade_rect)
	_build_hud()
	_build_touch()
	_build_title()
	_build_paused()
	get_tree().root.size_changed.connect(_layout)
	_layout()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_touch_btns.clear()


# Direct ScreenTouch hit-testing for every on-screen game button across all touch indices.
# Godot only emulates mouse events for the first touch, so a second finger tapping a button
# while another thumb holds the stick would otherwise miss Button.pressed and fall through to
# look/stick input. Touch-emulated mouse clicks on these buttons are suppressed in _guard_button
# so finger 0 never fires a button twice while desktop mouse clicks keep using Button.pressed.
func _input(e: InputEvent) -> void:
	if e is InputEventScreenTouch:
		if e.pressed:
			if _is_blocked(e.position):
				return
			for entry in _active_touch_buttons():
				var b: Button = entry.btn
				if b.is_visible_in_tree() and b.get_global_rect().has_point(e.position):
					_touch_btns[e.index] = entry
					get_viewport().set_input_as_handled()
					return
		elif _touch_btns.has(e.index):
			var entry: Dictionary = _touch_btns[e.index]
			_touch_btns.erase(e.index)
			get_viewport().set_input_as_handled()
			var b: Button = entry.btn
			if not e.canceled and b.is_visible_in_tree() and b.get_global_rect().grow(16.0).has_point(e.position):
				_touch_fire_ms[b] = Time.get_ticks_msec()
				entry.cb.call()
	elif e is InputEventScreenDrag and _touch_btns.has(e.index):
		get_viewport().set_input_as_handled()


func _is_blocked(pos: Vector2) -> bool:
	for c in blockers:
		if c == null or not c.is_visible_in_tree():
			continue
		var p := c.get_parent()
		if p is CanvasLayer and not (p as CanvasLayer).visible:
			continue
		if c.get_global_rect().has_point(pos):
			return true
	return false


func _active_touch_buttons() -> Array[Dictionary]:
	if not visible:
		return []
	if paused_layer.is_visible_in_tree():
		return [
			{"btn": dev_btn, "cb": func() -> void: button.emit("dev")},
			{"btn": resume_btn, "cb": func() -> void: resume_pressed.emit()},
		]
	if title.mouse_filter == Control.MOUSE_FILTER_STOP:
		return []
	if touch_layer.is_visible_in_tree():
		var out: Array[Dictionary] = [{"btn": pause_btn, "cb": func() -> void: button.emit("pause")}]
		for act in btn:
			var a: String = act
			out.append({"btn": btn[a], "cb": func() -> void: button.emit(a)})
		return out
	return []


func _guard_button(b: Button) -> void:
	b.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton:
			if e.device == InputEvent.DEVICE_ID_EMULATION or Time.get_ticks_msec() - int(_touch_fire_ms.get(b, -10000)) < 500:
				b.accept_event())


# ---------- fonts ----------

# A font at a CSS weight with CSS letter-spacing (em) at a pixel size.
func _font(path: String, weight: int, size: float, spacing_em: float) -> FontVariation:
	var key := "%s|%d|%d|%d" % [path, weight, roundi(size), roundi(spacing_em * 1000.0)]
	if _fonts.has(key):
		return _fonts[key]
	var f := FontVariation.new()
	f.base_font = load(path)
	f.variation_opentype = {"wght": weight}
	f.spacing_glyph = roundi(spacing_em * size)
	_fonts[key] = f
	return f


func _style(l: Control, path: String, weight: int, size: float, spacing_em: float, col: Color, shadow := 0.0) -> void:
	l.add_theme_font_override("font", _font(path, weight, size, spacing_em))
	l.add_theme_font_size_override("font_size", roundi(size))
	l.add_theme_color_override("font_color", col)
	if shadow > 0.0:
		# CSS text-shadow is a wide soft blur; Godot's shadow has no blur, so a faint, slightly
		# grown copy stands in for it.
		l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, shadow * 0.22))
		l.add_theme_constant_override("shadow_offset_x", 0)
		l.add_theme_constant_override("shadow_offset_y", 2)
		l.add_theme_constant_override("shadow_outline_size", 5)


func _label(text := "") -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func _box(bg: Color, border: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1 if border.a > 0.0 else 0)
	sb.set_corner_radius_all(radius)
	sb.anti_aliasing = true
	return sb


# CSS opacity transition on a control.
func _fade(c: CanvasItem, to: float, secs: float) -> void:
	if _tweens.has(c) and _tweens[c].is_valid():
		_tweens[c].kill()
	if secs <= 0.0:
		c.modulate.a = to
		return
	var tw := create_tween()
	tw.tween_property(c, "modulate:a", to, secs).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tweens[c] = tw


func _read_safe() -> void:
	if not OS.has_feature("web"):
		return
	var s = JavaScriptBridge.eval("(() => { const e = document.getElementById('safe'); if (!e) return '0,0,0,0'; const c = getComputedStyle(e); return [c.paddingTop, c.paddingRight, c.paddingBottom, c.paddingLeft].map(parseFloat).join(','); })()")
	var p := str(s).split(",")
	if p.size() == 4:
		safe = Vector4(float(p[0]), float(p[1]), float(p[2]), float(p[3]))


# ---------- title ----------

func _build_title() -> void:
	title = Control.new()
	title.set_anchors_preset(Control.PRESET_FULL_RECT)
	title.mouse_filter = Control.MOUSE_FILTER_STOP
	title.gui_input.connect(_on_title_input)
	title.modulate.a = 0.0
	add_child(title)
	# radial-gradient(ellipse 60% 50% at 14% 92%, rgba(6,14,26,.68), .38 at 48%, 0 at 78%)
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.48, 0.78])
	g.colors = PackedColorArray([Color(0.024, 0.055, 0.102, 0.68), Color(0.024, 0.055, 0.102, 0.38), Color(0.024, 0.055, 0.102, 0.0)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = 256
	gt.height = 256
	title_bg = TextureRect.new()
	title_bg.texture = gt
	title_bg.stretch_mode = TextureRect.STRETCH_SCALE
	title_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	title_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_child(title_bg)
	title_box = VBoxContainer.new()
	title_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_box.add_theme_constant_override("separation", 0)
	title.add_child(title_box)
	h1 = _label("STILLWATER")
	sub = _label("a slow walk into the high country")
	begin = _label()
	keys_pill = PanelContainer.new()
	keys_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	keys_pill.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	keys_flow = HFlowContainer.new()
	keys_flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	keys_flow.add_theme_constant_override("h_separation", 0)
	keys_flow.add_theme_constant_override("v_separation", 2)
	keys_pill.add_child(keys_flow)
	for c in [h1, sub, _spacer(), begin, _spacer(), keys_pill]:
		title_box.add_child(c)


func _spacer() -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _on_title_input(e: InputEvent) -> void:
	if (e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT) or (e is InputEventScreenTouch and not e.pressed):
		title.accept_event()
		start_pressed.emit()


func show_title() -> void:
	_fade(title, 1.0, 2.5)


func hide_title() -> void:
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade(title, 0.0, 2.5)


# Key pill: chips (key names in a bordered box) and plain words, like the <b> tags of index.html.
func _set_keys(parts: Array, phone: bool) -> void:
	for c in keys_flow.get_children():
		c.queue_free()
	var fs := 10.5
	for p in parts:
		var chip: bool = p[0]
		var l := _label(p[1])
		if chip:
			var pc := PanelContainer.new()
			pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var sb := _box(Color(1, 1, 1, 0.08), Color(0.957, 0.925, 0.867, 0.34), 4)
			sb.content_margin_left = 6
			sb.content_margin_right = 6
			sb.content_margin_top = 0
			sb.content_margin_bottom = 0
			pc.add_theme_stylebox_override("panel", sb)
			_style(l, SANS, 500, fs, 0.08, Color(1.0, 0.98, 0.94, 0.95))
			pc.add_child(l)
			pc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			keys_flow.add_child(pc)
			keys_flow.add_child(_gap(6))
		else:
			_style(l, SANS, 400, fs, 0.08, Color(0.957, 0.925, 0.867, 0.84))
			keys_flow.add_child(l)
			keys_flow.add_child(_gap(10 if not phone else 8))


func _gap(w: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(w, 0)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# ---------- HUD ----------

func _build_hud() -> void:
	hud = Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.modulate.a = 0.0
	add_child(hud)
	compass = Control.new()
	compass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	compass.clip_contents = true
	hud.add_child(compass)
	var card := {0: "N", 45: "NE", 90: "E", 135: "SE", 180: "S", 225: "SW", 270: "W", 315: "NW"}
	for d in range(0, 360, 15):
		var c: Control
		if card.has(d):
			var l := _label(card[d])
			var major: bool = d % 90 == 0
			_style(l, SANS, 500 if major else 400, 11, 0.2, INK if major else DIM)
			l.position.y = 4
			c = l
		else:
			var r := ColorRect.new()
			r.color = Color(0.957, 0.925, 0.867, 0.35)
			r.size = Vector2(1, 6)
			r.position.y = 8
			r.mouse_filter = Control.MOUSE_FILTER_IGNORE
			c = r
		compass.add_child(c)
		marks.append({"node": c, "bearing": deg_to_rad(d)})
	var centre := ColorRect.new()
	centre.color = INK
	centre.size = Vector2(1, 4)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.name = "centre"
	compass.add_child(centre)

	# Plain labels, only re-set when their text changes (a rich text label re-parses every time).
	stats = VBoxContainer.new()
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 0)
	st_alt = _label()
	st_clock = _label()
	st_walk = _label()
	row.add_child(st_alt)
	row.add_child(st_clock)
	stats.add_child(row)
	stats.add_child(st_walk)
	hud.add_child(stats)

	place_box = VBoxContainer.new()
	place_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	place_box.modulate.a = 0.0
	place_n = _label()
	place_n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	place_n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	place_d = _label()
	place_d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	place_d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var line_row := CenterContainer.new()
	line_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line_row.custom_minimum_size = Vector2(0, 19)
	place_line = ColorRect.new()
	place_line.color = Color(0.957, 0.925, 0.867, 0.5)
	place_line.custom_minimum_size = Vector2(0, 1)
	place_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line_row.add_child(place_line)
	place_box.add_child(place_n)
	place_box.add_child(place_d)
	place_box.add_child(line_row)
	hud.add_child(place_box)

	prompt = _label()
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.modulate.a = 0.0
	hud.add_child(prompt)
	toast_l = _label()
	toast_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_l.modulate.a = 0.0
	hud.add_child(toast_l)


func show_hud(on: bool) -> void:
	_hud_live = on
	_fade(hud, 1.0 if on and _hud_on else 0.0, 1.2)
	touch_layer.visible = on and touch
	if not on:
		_touch_btns.clear()


# H: photo mode.
func toggle_hud() -> void:
	_hud_on = not _hud_on
	_fade(hud, 1.0 if _hud_on and _hud_live else 0.0, 0.0)


# ---------- touch controls ----------

func _build_touch() -> void:
	touch_layer = Control.new()
	touch_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	touch_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	touch_layer.visible = false
	hud.add_child(touch_layer)
	stick = Panel.new()
	stick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stick.size = Vector2(104, 104)
	stick.add_theme_stylebox_override("panel", _box(Color(0.039, 0.071, 0.11, 0.24), Color(0.957, 0.925, 0.867, 0.38), 52))
	stick.modulate.a = 0.0
	knob = Panel.new()
	knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	knob.size = Vector2(42, 42)
	var ks := _box(Color(0.957, 0.925, 0.867, 0.72), Color(1.0, 0.98, 0.94, 0.88), 21)
	ks.shadow_color = Color(0, 0, 0, 0.35)
	ks.shadow_size = 5
	ks.shadow_offset = Vector2(0, 2)
	knob.add_theme_stylebox_override("panel", ks)
	stick.add_child(knob)
	touch_layer.add_child(stick)
	pause_btn = _tbtn("", "pause")
	pause_btn.custom_minimum_size = Vector2(44, 44)
	pause_btn.size = Vector2(44, 44)
	for x in [16.0, 24.0]:
		var bar := ColorRect.new()
		bar.color = INK
		bar.size = Vector2(4, 13)
		bar.position = Vector2(x, 15.5)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pause_btn.add_child(bar)
	touch_layer.add_child(pause_btn)
	actions_grid = GridContainer.new()
	actions_grid.columns = 2
	actions_grid.add_theme_constant_override("h_separation", 8)
	actions_grid.add_theme_constant_override("v_separation", 8)
	actions_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for pair in [["Trail", "autoWalk"], ["Sit", "sit"]]:
		var b := _tbtn(pair[0].to_upper(), pair[1])
		b.custom_minimum_size = Vector2(64, 44)
		actions_grid.add_child(b)
		btn[pair[1]] = b
	touch_layer.add_child(actions_grid)


# A .tbtn: pill, blurred dark glass, 11 px Inter 500 caps. `on` and `hint` states as in the CSS.
func _tbtn(text: String, act: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.add_theme_font_override("font", _font(SANS, 500, 11, 0.14))
	b.add_theme_font_size_override("font_size", 11)
	_tbtn_state(b, false, false)
	_guard_button(b)
	b.pressed.connect(func() -> void: button.emit(act))
	return b


func _tbtn_state(b: Button, on: bool, hint: bool) -> void:
	var base := _box(Color(0.957, 0.925, 0.867, 0.88) if on else Color(0.039, 0.071, 0.11, 0.42),
		Color(1.0, 0.98, 0.94, 0.95) if on else (Color(1.0, 0.847, 0.604, 0.75) if hint else Color(0.957, 0.925, 0.867, 0.24)), 22)
	base.content_margin_left = 13
	base.content_margin_right = 13
	if hint:
		base.shadow_color = Color(1.0, 0.847, 0.604, 0.28)
		base.shadow_size = 12
	var pressed := base.duplicate()
	pressed.bg_color = Color(0.957, 0.925, 0.867, 0.24) if not on else base.bg_color
	for st in ["normal", "hover", "focus", "disabled"]:
		b.add_theme_stylebox_override(st, base)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover_pressed", pressed)
	var fc := Color(0.043, 0.067, 0.094) if on else INK
	for st in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, fc)


func set_stick(state: Dictionary) -> void:
	if not state.active:
		_fade(stick, 0.0, 0.14)
		knob.position = (stick.size - knob.size) * 0.5
		return
	if stick.modulate.a < 1.0 and not (_tweens.has(stick) and _tweens[stick].is_running()):
		_fade(stick, 1.0, 0.14)
	stick.position = state.origin - stick.size * 0.5
	knob.position = (stick.size - knob.size) * 0.5 + state.offset


# ---------- pause ----------

func _build_paused() -> void:
	paused_layer = ColorRect.new()
	var blur := ShaderMaterial.new()
	blur.shader = load("res://shaders/ui_blur.gdshader")
	paused_layer.material = blur
	paused_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	paused_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	paused_layer.gui_input.connect(_on_paused_input)
	paused_layer.visible = false
	add_child(paused_layer)
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	paused_layer.add_child(cc)
	paused_box = VBoxContainer.new()
	paused_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	paused_box.alignment = BoxContainer.ALIGNMENT_CENTER
	cc.add_child(paused_box)
	paused_h = _label("PAUSED")
	paused_h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	paused_keys = VBoxContainer.new()
	paused_keys.mouse_filter = Control.MOUSE_FILTER_IGNORE
	paused_keys.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	resume_btn = Button.new()
	resume_btn.focus_mode = Control.FOCUS_NONE
	resume_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_guard_button(resume_btn)
	resume_btn.pressed.connect(func() -> void: resume_pressed.emit())
	dev_btn = Button.new()
	dev_btn.text = "PERF · BENCH"
	dev_btn.focus_mode = Control.FOCUS_NONE
	dev_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	dev_btn.add_theme_font_override("font", _font(SANS, 400, 11, 0.3))
	dev_btn.add_theme_font_size_override("font_size", 11)
	var dsb := _box(Color(0, 0, 0, 0), Color(0.957, 0.925, 0.867, 0.2), 3)
	dsb.content_margin_left = 10
	dsb.content_margin_right = 10
	dsb.content_margin_top = 6
	dsb.content_margin_bottom = 6
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		dev_btn.add_theme_stylebox_override(st, dsb)
	for st in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		dev_btn.add_theme_color_override(st, DIM)
	_guard_button(dev_btn)
	dev_btn.pressed.connect(func() -> void: button.emit("dev"))
	for c in [paused_h, _spacer(), paused_keys, _spacer(), dev_btn, _spacer(), resume_btn]:
		paused_box.add_child(c)


func _on_paused_input(e: InputEvent) -> void:
	if (e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT) or (e is InputEventScreenTouch and not e.pressed):
		paused_layer.accept_event()
		resume_pressed.emit()


func set_paused(on: bool) -> void:
	paused_layer.visible = on
	_touch_btns.clear()


func _set_paused_keys(lines: Array) -> void:
	for c in paused_keys.get_children():
		c.queue_free()
	var short := vs.y <= 460
	for line in lines:
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override("separation", 0)
		for p in line:
			var l := _label(p[1] + " " if p[0] else p[1])
			if p[0]:
				_style(l, SANS, 500, 11 if short else 12, 0.06, INK)
				l.custom_minimum_size = Vector2(64, 0)
			else:
				_style(l, SANS, 400, 11 if short else 12, 0.06, DIM)
			row.add_child(l)
		row.custom_minimum_size = Vector2(0, (11 if short else 12) * (1.65 if short else 2.1))
		paused_keys.add_child(row)


# ---------- layout ----------

func set_touch_mode(on: bool) -> void:
	touch = on
	touch_layer.visible = _hud_live and touch
	_layout()


func _layout() -> void:
	vs = get_viewport().get_visible_rect().size
	_read_safe()
	var phone := vs.x <= 600
	var short := vs.y <= 460
	# Title
	var pad_l: float
	var pad_r: float
	var pad_b: float
	var h1_size: float
	var h1_sp := 0.18
	var sub_size: float
	var begin_size := 12.0
	var begin_sp := 0.42
	var begin_mt := 34.0
	var keys_mt := 18.0
	if short:
		pad_l = maxf(24, safe.w)
		pad_r = maxf(24, safe.y)
		pad_b = maxf(18, 12 + safe.z)
		h1_size = clampf(vs.x * 0.075, 34, 68)
		sub_size = clampf(vs.x * 0.02, 18, 26)
		begin_mt = 16
		keys_mt = 10
	elif phone:
		pad_l = maxf(20, safe.w)
		pad_r = maxf(20, safe.y)
		pad_b = maxf(28, 20 + safe.z)
		h1_size = clampf(vs.x * 0.10, 32, 52)
		h1_sp = 0.12
		sub_size = 17
		begin_size = 11
		begin_sp = 0.28
		begin_mt = 24
	else:
		pad_l = maxf(vs.x * 0.07, safe.w)
		pad_r = maxf(vs.x * 0.07, safe.y)
		pad_b = maxf(vs.y * 0.055, 20 + safe.z)
		h1_size = clampf(vs.x * 0.09, 56, 138)
		sub_size = clampf(vs.x * 0.02, 18, 26)
	if phone and short:
		h1_size = clampf(vs.x * 0.10, 32, 52)
	_style(h1, SERIF, 300, h1_size, h1_sp, INK, 0.42)
	_style(sub, SERIF_I, 400, sub_size, 0.04, Color(0.973, 0.949, 0.902, 0.92), 0.68)
	sub.custom_minimum_size.y = 0
	_style(begin, SANS, 400, begin_size, begin_sp, Color(1.0, 0.98, 0.94, 0.96), 0.75)
	begin.text = ("tap anywhere to begin" if touch else "click anywhere to begin").to_upper()
	title_box.get_child(2).custom_minimum_size = Vector2(0, begin_mt)
	title_box.get_child(4).custom_minimum_size = Vector2(0, keys_mt)
	var pill := _box(Color(0.039, 0.071, 0.11, 0.34), Color(0.957, 0.925, 0.867, 0.14), 14 if phone else 999)
	pill.content_margin_left = 12 if phone else 13
	pill.content_margin_right = 12 if phone else 13
	pill.content_margin_top = 8 if phone else 4
	pill.content_margin_bottom = 8 if phone else 4
	keys_pill.add_theme_stylebox_override("panel", pill)
	if touch:
		_set_keys([[true, "Left"], [false, "drag to walk"], [true, "Right"], [false, "drag to look"], [true, "Buttons"], [false, "trail · sit"]], phone)
	else:
		_set_keys([[true, "WASD"], [false, "walk"], [true, "Shift"], [false, "stride"], [true, "Q"], [false, "follow the trail"], [true, "E"], [false, "sit & rest"], [true, "H"], [false, "hide hud"]], phone)
	var box_w := vs.x - pad_l - pad_r
	keys_flow.custom_minimum_size = Vector2(0, 0)
	keys_pill.custom_minimum_size = Vector2(0, 0)
	title_box.position = Vector2(pad_l, 0)
	title_box.size = Vector2(box_w, 0)
	keys_pill.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	keys_flow.custom_minimum_size.x = minf(box_w - 26, _keys_natural_width())
	title_box.reset_size()
	title_box.size.x = box_w
	_place_title_box.call_deferred(pad_b)
	title_bg.position = Vector2(0.14 * vs.x - 0.6 * vs.x, 0.92 * vs.y - 0.5 * vs.y)
	title_bg.size = Vector2(1.2 * vs.x, 1.0 * vs.y)

	# Compass: top max(22, 12 + safe), width min(420, vw - 128 - safe sides)
	var cw := minf(420.0, vs.x - 128.0 - safe.w - safe.y)
	compass.size = Vector2(cw, 28)
	compass.position = Vector2((vs.x - cw) * 0.5, maxf(22, 12 + safe.x))
	compass.get_node("centre").position = Vector2(cw * 0.5, 0)
	# Stats
	var st_size := 10.0 if phone else 11.0
	var st_sp := 0.1 if phone else 0.14
	_style(st_alt, SANS, 400, st_size, st_sp, INK)
	_style(st_clock, SANS, 400, st_size, st_sp, DIM)
	_style(st_walk, SANS, 400, st_size, st_sp, DIM)
	stats.add_theme_constant_override("separation", roundi(st_size * (0.7 if phone else 0.9)) - 4)
	if st_alt.text == "":
		st_alt.text = "0 M"
		st_clock.text = "  ·  00:00"
		st_walk.text = "0.00 KM WALKED  ·  0 M CLIMBED"
	stats.reset_size()
	stats.position = Vector2(maxf(14, 10 + safe.w) if phone else maxf(28, 16 + safe.w),
		vs.y - (maxf(22, 14 + safe.z) if phone else maxf(26, 14 + safe.z)) - stats.get_combined_minimum_size().y)
	# Place card at 30vh
	place_box.position = Vector2(maxf(16, safe.w), vs.y * 0.30)
	place_box.size = Vector2(vs.x - maxf(16, safe.w) - maxf(16, safe.y), 0)
	_style(place_n, SERIF, 300, clampf(vs.x * 0.044, 30, 64), 0.16, INK, 0.35)
	_style(place_d, SERIF_I, 400, clampf(vs.x * 0.016, 15, 22), 0.0, DIM, 0.4)
	place_d.add_theme_constant_override("line_spacing", 0)
	# Prompt and toast
	_style(prompt, SANS, 400, 11 if touch else 12, 0.2 if touch else 0.3, INK, 0.5)
	_style(toast_l, SERIF_I, 400, 16 if phone else 19, 0.0, INK, 0.55)
	toast_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if phone else TextServer.AUTOWRAP_OFF
	_place_bottom_text()
	# Touch controls
	pause_btn.position = Vector2(vs.x - maxf(14, 10 + safe.y) - 44, maxf(14, 10 + safe.x))
	actions_grid.reset_size()
	_place_actions.call_deferred()
	knob.position = (stick.size - knob.size) * 0.5
	# Pause sheet
	_style(paused_h, SERIF, 300, 28 if short else 42, 0.24 if short else 0.3, INK)
	paused_box.get_child(1).custom_minimum_size = Vector2(0, 12 if short else 26)
	paused_box.get_child(3).custom_minimum_size = Vector2(0, 12 if short else 26)
	paused_box.get_child(5).custom_minimum_size = Vector2(0, 12 if short else 22)
	if touch:
		_set_paused_keys([
			[[true, "Left side"], [false, "drag thumb to walk"]],
			[[true, "Right side"], [false, "drag to look around"]],
			[[true, "Trail"], [false, "follow the path · "], [true, "Sit"], [false, "rest a while"]],
		])
	else:
		_set_paused_keys([
			[[true, "WASD"], [false, "walk · "], [true, "Shift"], [false, "longer stride"]],
			[[true, "Q"], [false, "follow the trail automatically"]],
			[[true, "E"], [false, "sit down for a while"]],
			[[true, "H"], [false, "hide hud · "], [true, "G"], [false, "perf panel"]],
		])
	resume_btn.text = ("tap to continue" if touch else "click to continue").to_upper()
	resume_btn.add_theme_font_override("font", _font(SANS, 400, 11, 0.3))
	resume_btn.add_theme_font_size_override("font_size", 11)
	var rsb := _box(Color(0.957, 0.925, 0.867, 0.12) if touch else Color(0, 0, 0, 0), Color(0.957, 0.925, 0.867, 0.34) if touch else Color(0, 0, 0, 0), 22)
	rsb.content_margin_left = 26 if touch else 14
	rsb.content_margin_right = 26 if touch else 14
	rsb.content_margin_top = 12 if touch else 6
	rsb.content_margin_bottom = 12 if touch else 6
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		resume_btn.add_theme_stylebox_override(st, rsb)
	for st in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		resume_btn.add_theme_color_override(st, INK if touch else DIM)


func _keys_natural_width() -> float:
	var w := 0.0
	for c in keys_flow.get_children():
		if c.is_queued_for_deletion():
			continue
		w += (c as Control).get_combined_minimum_size().x
	return w


func _place_title_box(pad_b: float) -> void:
	title_box.reset_size()
	title_box.size.x = vs.x - title_box.position.x * 2.0 if vs.x > 600 else vs.x - title_box.position.x - maxf(20, safe.y)
	title_box.position.y = vs.y - pad_b - title_box.get_combined_minimum_size().y


func _place_actions() -> void:
	actions_grid.reset_size()
	var s := actions_grid.get_combined_minimum_size()
	actions_grid.position = Vector2(vs.x - maxf(14, 10 + safe.y) - s.x, vs.y - maxf(36, 24 + safe.z) - s.y)


func _place_bottom_text() -> void:
	var short := vs.y <= 460
	var side := 16.0 + maxf(safe.w, safe.y)
	toast_l.size = Vector2(vs.x - side * 2.0, 0)
	toast_l.position.x = side
	prompt.size = Vector2(vs.x - 32.0, 0)
	prompt.position.x = 16
	var toast_h := toast_l.get_combined_minimum_size().y
	var prompt_h := prompt.get_combined_minimum_size().y
	if touch and short:
		toast_l.position.y = maxf(56, 46 + safe.x)
		prompt.position.y = maxf(84, 74 + safe.x)
	elif touch:
		toast_l.position.y = vs.y - maxf(152, 140 + safe.z) - toast_h
		prompt.position.y = vs.y - maxf(188, 176 + safe.z) - prompt_h
	else:
		toast_l.position.y = vs.y * 0.91 - toast_h
		prompt.position.y = vs.y * 0.84 - prompt_h


# ---------- per-frame ----------

func toast(msg: String) -> void:
	toast_l.text = msg
	toast_l.reset_size()
	_place_bottom_text()
	_fade(toast_l, 1.0, 1.0)
	_toast_until = Time.get_ticks_msec() / 1000.0 + 3.2


func set_prompt(msg: String) -> void:
	if msg == _prompt_text:
		return
	_prompt_text = msg
	if msg != "":
		prompt.text = msg.to_upper()
		_place_bottom_text()
	_fade(prompt, 0.9 if msg != "" else 0.0, 0.8)


func place(n: String, d: String) -> void:
	place_n.text = n.to_upper()
	place_d.text = d
	_fade(place_box, 1.0, 2.4)
	place_line.custom_minimum_size.x = 0
	var tw := create_tween()
	tw.tween_property(place_line, "custom_minimum_size:x", 120.0, 3.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_place_until = Time.get_ticks_msec() / 1000.0 + 7.0


func set_fade(f: float) -> void:
	fade_rect.color.a = 1.0 - clampf(f, 0.0, 1.0)
	fade_rect.visible = fade_rect.color.a > 0.002


func clock(h: float) -> String:
	var hh := floori(h)
	return "%02d:%02d" % [hh, floori((h - hh) * 60.0)]


# s: yaw, altitude, hours, distance, climb, pois, pos (Vector2), bench, sitting, auto_walk
func update(s: Dictionary) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if _toast_until > 0.0 and now > _toast_until:
		_toast_until = -1.0
		_fade(toast_l, 0.0, 1.0)
	if _place_until > 0.0 and now > _place_until:
		_place_until = -1.0
		_fade(place_box, 0.0, 2.4)
	if title.modulate.a > 0.0:
		_breathe += get_process_delta_time()
		begin.modulate.a = lerpf(0.82, 1.0, 0.5 - 0.5 * cos(_breathe / 3.6 * TAU))
	if not _hud_live:
		return
	var heading: float = -s.yaw
	var w := compass.size.x
	for m in marks:
		_place_mark(m.node, m.bearing, heading, w, 1.0)
	for p in s.pois:
		var node: Control = poi_marks.get(p.name)
		if node == null:
			node = ColorRect.new()
			(node as ColorRect).color = POI_COL
			node.size = Vector2(5, 5)
			node.pivot_offset = Vector2(2.5, 2.5)
			node.rotation = PI / 4.0
			node.position.y = 19
			node.mouse_filter = Control.MOUSE_FILTER_IGNORE
			compass.add_child(node)
			poi_marks[p.name] = node
		var dx: float = p.x - s.pos.x
		var dz: float = p.z - s.pos.y
		var d := sqrt(dx * dx + dz * dz)
		var a := 0.0 if d < p.r else minf(1.0, 0.35 + 400.0 / (d + 200.0))
		_place_mark(node, atan2(dx, -dz), heading, w, a)
	_set_text(st_alt, "%d M" % roundi(s.altitude))
	_set_text(st_clock, "  ·  " + clock(s.hours))
	_set_text(st_walk, "%.2f KM WALKED  ·  %d M CLIMBED" % [s.distance / 1000.0, roundi(s.climb)])
	if touch:
		var key := [s.sitting, not s.sitting and s.bench, s.auto_walk]
		if key != _btn_key:
			_btn_key = key
			_tbtn_state(btn.sit, s.sitting, not s.sitting and s.bench)
			btn.sit.text = "STAND" if s.sitting else "SIT"
			_tbtn_state(btn.autoWalk, s.auto_walk, false)
			_place_actions.call_deferred()
		set_prompt("Tap Stand" if s.sitting else ("Tap Sit to rest" if s.bench else ""))
	else:
		set_prompt("E · stand up" if s.sitting else ("E · sit and rest" if s.bench else ""))


static func _set_text(l: Label, t: String) -> void:
	if l.text != t:
		l.text = t


# The compass strip is masked to transparent over its outer quarters, like the CSS mask-image.
func _place_mark(c: Control, bearing: float, heading: float, w: float, alpha: float) -> void:
	var rel := bearing - heading
	rel = atan2(sin(rel), cos(rel))
	if absf(rel) > SPAN * 0.5:
		c.visible = false
		return
	c.visible = true
	var x := w * 0.5 + rel / SPAN * w
	c.position.x = x - c.size.x * 0.5
	var edge := minf(x, w - x) / (w * 0.25)
	c.modulate.a = clampf(edge, 0.0, 1.0) * alpha
