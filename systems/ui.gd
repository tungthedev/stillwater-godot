extends CanvasLayer

# Perf readout plus big tap targets so each cost can be switched off on the phone and compared.

var env_sys: Node
var grass_sys: Node
var bench_sys: Node
var cam: Camera3D
var terrain_sys: Node
var label: Label
var scales := [1.0, 0.75, 0.5]
var scale_i := 0
var btn_scale: Button
var btn_shadow: Button
var btn_grass: Button
var btn_pose: Button


func setup(env_node: Node, grass_node: Node, bench_node: Node, cam_node: Camera3D, terrain_node: Node) -> void:
	env_sys = env_node
	grass_sys = grass_node
	bench_sys = bench_node
	cam = cam_node
	terrain_sys = terrain_node


func _ready() -> void:
	label = Label.new()
	label.position = Vector2(12, 12)
	label.add_theme_font_size_override("font_size", 30)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 6)
	add_child(label)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	row.offset_top = -120
	row.offset_bottom = -24
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	btn_scale = _button(row, _on_scale)
	btn_shadow = _button(row, _on_shadow)
	btn_grass = _button(row, _on_grass)
	btn_pose = _button(row, _on_pose)
	add_child(row)
	_refresh_buttons()
	# Screenshots for look checks hide the overlay: ?noui on Web, `-- --no-ui` on desktop.
	visible = not _hidden_by_request()


static func _hidden_by_request() -> bool:
	if OS.has_feature("web"):
		return bool(JavaScriptBridge.eval("new URLSearchParams(location.search).has('noui')"))
	return OS.get_cmdline_user_args().has("--no-ui")


func _button(row: HBoxContainer, cb: Callable) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 88)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 24)
	b.pressed.connect(cb)
	row.add_child(b)
	return b


func _on_scale() -> void:
	scale_i = (scale_i + 1) % scales.size()
	get_viewport().scaling_3d_scale = scales[scale_i]
	_refresh_buttons()


func _on_shadow() -> void:
	env_sys.sun.shadow_enabled = not env_sys.sun.shadow_enabled
	_refresh_buttons()


func _on_grass() -> void:
	grass_sys.set_on(not grass_sys.is_on())
	_refresh_buttons()


func _on_pose() -> void:
	cam.next_mode()
	_refresh_buttons()


func _refresh_buttons() -> void:
	btn_scale.text = "Res %d%%" % int(scales[scale_i] * 100.0)
	btn_shadow.text = "Shadow " + ("on" if env_sys.sun.shadow_enabled else "off")
	btn_grass.text = "Grass " + ("on" if grass_sys.is_on() else "off")
	btn_pose.text = "Pose " + cam.mode()


func _process(_delta: float) -> void:
	var px: Vector2 = Vector2(DisplayServer.window_get_size()) * float(scales[scale_i])
	label.text = "%d fps\n%d x %d px 3D\n%d draws · %.2f M tris\nterrain %.2f M tris · %d nodes" % [
		Engine.get_frames_per_second(), px.x, px.y, bench_sys.last_draws, bench_sys.last_prims / 1.0e6,
		terrain_sys.last_tris / 1.0e6, terrain_sys.last_nodes]
