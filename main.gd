extends Node3D

# Builds the whole test scene in code so the project stays plain text.
# The camera walks a fixed loop and prints one BENCH line after the timed window.

const SIZE := 1024.0
const RES := 256
const WATER_Y := -6.0

const GRASS_AREA := 384.0
const GRASS_CHUNK := 32.0
const GRASS_PER_CHUNK := 2500
const GRASS_RANGE := 70.0

const TREE_COUNT := 20000
const TREE_TILE := 128.0
const TREE_NEAR := 160.0
const TREE_FAR := 600.0

const WARMUP := 3.0
const WINDOW := 20.0
const PATH_R := 150.0
const SPEED := 3.0

var noise := FastNoiseLite.new()
var cam: Camera3D
var label: Label
var t := 0.0
var frame_ms: Array[float] = []
var draws_max := 0
var prims_max := 0
var reported := false
var sun: DirectionalLight3D
var grass_nodes: Array[MultiMeshInstance3D] = []
var scales := [1.0, 0.75, 0.5]
var scale_i := 0
var btn_scale: Button
var btn_shadow: Button
var btn_grass: Button


func height_at(x: float, z: float) -> float:
	return noise.get_noise_2d(x, z) * 45.0 + noise.get_noise_2d(x * 5.0, z * 5.0) * 2.5


func _ready() -> void:
	noise.seed = 7
	noise.frequency = 0.0025
	noise.fractal_octaves = 4
	var t0 := Time.get_ticks_msec()
	_build_environment()
	_build_terrain()
	_build_water()
	_build_grass()
	_build_trees()
	_build_ui()
	cam = Camera3D.new()
	cam.far = 1500.0
	cam.fov = 70.0
	add_child(cam)
	print("BUILD scene_ms=%d" % (Time.get_ticks_msec() - t0))


func _build_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.52, 0.82)
	sky_mat.sky_horizon_color = Color(0.78, 0.84, 0.9)
	sky_mat.ground_horizon_color = Color(0.6, 0.66, 0.6)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_density = 0.0015
	env.fog_light_color = Color(0.75, 0.82, 0.9)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35.0, -40.0, 0.0)
	sun.light_color = Color(1.0, 0.93, 0.8)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80.0
	add_child(sun)


func _build_terrain() -> void:
	var n := RES + 1
	var step := SIZE / RES
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	verts.resize(n * n)
	norms.resize(n * n)
	cols.resize(n * n)
	for j in n:
		for i in n:
			var x := -SIZE * 0.5 + i * step
			var z := -SIZE * 0.5 + j * step
			var y := height_at(x, z)
			var nx := height_at(x - step, z) - height_at(x + step, z)
			var nz := height_at(x, z - step) - height_at(x, z + step)
			var nrm := Vector3(nx, 2.0 * step, nz).normalized()
			var k := j * n + i
			verts[k] = Vector3(x, y, z)
			norms[k] = nrm
			var grass := Color(0.24, 0.38, 0.13)
			var rock := Color(0.45, 0.42, 0.38)
			var shore := Color(0.55, 0.5, 0.38)
			var c := grass.lerp(rock, clampf((1.0 - nrm.y) * 4.0, 0.0, 1.0))
			if y < WATER_Y + 1.5:
				c = shore
			cols[k] = c
	var idx := PackedInt32Array()
	idx.resize(RES * RES * 6)
	var w := 0
	for j in RES:
		for i in RES:
			var a := j * n + i
			idx[w] = a; idx[w + 1] = a + 1; idx[w + 2] = a + n
			idx[w + 3] = a + 1; idx[w + 4] = a + n + 1; idx[w + 5] = a + n
			w += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)


func _build_water() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(SIZE, SIZE)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.32, 0.4, 0.82)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.08
	mat.metallic = 0.3
	plane.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.position.y = WATER_Y
	add_child(mi)


func _blade_mesh() -> ArrayMesh:
	var w := 0.05
	var verts := PackedVector3Array([
		Vector3(-w, 0, 0), Vector3(w, 0, 0),
		Vector3(-w * 0.6, 0.35, 0), Vector3(w * 0.6, 0.35, 0),
		Vector3(0, 0.7, 0)])
	var idx := PackedInt32Array([0, 2, 1, 1, 2, 3, 2, 4, 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://grass.gdshader")
	mesh.surface_set_material(0, mat)
	return mesh


func _build_grass() -> void:
	var blade := _blade_mesh()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var chunks := int(GRASS_AREA / GRASS_CHUNK)
	for cj in chunks:
		for ci in chunks:
			var x0 := -GRASS_AREA * 0.5 + ci * GRASS_CHUNK
			var z0 := -GRASS_AREA * 0.5 + cj * GRASS_CHUNK
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = blade
			mm.instance_count = GRASS_PER_CHUNK
			var used := 0
			for k in GRASS_PER_CHUNK:
				var x := x0 + rng.randf() * GRASS_CHUNK
				var z := z0 + rng.randf() * GRASS_CHUNK
				var y := height_at(x, z)
				if y < WATER_Y + 1.0:
					continue
				var s := rng.randf_range(0.7, 1.4)
				var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
				mm.set_instance_transform(used, Transform3D(basis, Vector3(x, y, z)))
				used += 1
			mm.visible_instance_count = used
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.visibility_range_end = GRASS_RANGE
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mmi)
			grass_nodes.append(mmi)


func _tree_mesh(segments: int, rings: int) -> CylinderMesh:
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 2.4
	cone.height = 10.0
	cone.radial_segments = segments
	cone.rings = rings
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.13, 0.26, 0.12)
	mat.roughness = 0.9
	cone.material = mat
	return cone


func _build_trees() -> void:
	var near_mesh := _tree_mesh(10, 2)
	var far_mesh := _tree_mesh(5, 0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var tiles := int(SIZE / TREE_TILE)
	var per_tile := TREE_COUNT / (tiles * tiles)
	for tj in tiles:
		for ti in tiles:
			var x0 := -SIZE * 0.5 + ti * TREE_TILE
			var z0 := -SIZE * 0.5 + tj * TREE_TILE
			var xforms: Array[Transform3D] = []
			for k in per_tile:
				var x := x0 + rng.randf() * TREE_TILE
				var z := z0 + rng.randf() * TREE_TILE
				var y := height_at(x, z)
				if y < WATER_Y + 2.0:
					continue
				var s := rng.randf_range(0.7, 1.5)
				var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
				xforms.append(Transform3D(basis, Vector3(x, y + 5.0 * s, z)))
			_add_tree_layer(near_mesh, xforms, 0.0, TREE_NEAR, true)
			_add_tree_layer(far_mesh, xforms, TREE_NEAR, TREE_FAR, false)


func _add_tree_layer(mesh: Mesh, xforms: Array[Transform3D], begin: float, end: float, shadows: bool) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for k in xforms.size():
		mm.set_instance_transform(k, xforms[k])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.visibility_range_begin = begin
	mmi.visibility_range_end = end
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	label = Label.new()
	label.position = Vector2(12, 12)
	label.add_theme_font_size_override("font_size", 34)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 6)
	layer.add_child(label)
	# Big tap targets so each cost can be switched off on the phone and compared.
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	row.offset_top = -120
	row.offset_bottom = -24
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	btn_scale = _button(row, _on_scale)
	btn_shadow = _button(row, _on_shadow)
	btn_grass = _button(row, _on_grass)
	layer.add_child(row)
	add_child(layer)
	_refresh_buttons()


func _button(row: HBoxContainer, cb: Callable) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 88)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 26)
	b.pressed.connect(cb)
	row.add_child(b)
	return b


func _on_scale() -> void:
	scale_i = (scale_i + 1) % scales.size()
	get_viewport().scaling_3d_scale = scales[scale_i]
	_refresh_buttons()


func _on_shadow() -> void:
	sun.shadow_enabled = not sun.shadow_enabled
	_refresh_buttons()


func _on_grass() -> void:
	var on := not grass_nodes[0].visible
	for g in grass_nodes:
		g.visible = on
	_refresh_buttons()


func _refresh_buttons() -> void:
	btn_scale.text = "Res %d%%" % int(scales[scale_i] * 100.0)
	btn_shadow.text = "Shadow " + ("on" if sun.shadow_enabled else "off")
	btn_grass.text = "Grass " + ("on" if grass_nodes[0].visible else "off")


func _process(delta: float) -> void:
	t += delta
	var a := t * SPEED / PATH_R
	var p := Vector3(cos(a) * PATH_R, 0.0, sin(a) * PATH_R)
	p.y = maxf(height_at(p.x, p.z), WATER_Y) + 1.7
	var ahead := Vector3(cos(a + 0.05) * PATH_R, 0.0, sin(a + 0.05) * PATH_R)
	ahead.y = p.y - 0.4
	cam.look_at_from_position(p, ahead, Vector3.UP)

	var draws := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var prims := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	if t > WARMUP and t < WARMUP + WINDOW:
		frame_ms.append(delta * 1000.0)
		draws_max = maxi(draws_max, draws)
		prims_max = maxi(prims_max, prims)
	elif t >= WARMUP + WINDOW and not reported:
		reported = true
		_report()
	var px: Vector2 = Vector2(DisplayServer.window_get_size()) * float(scales[scale_i])
	label.text = "%d fps\n%d x %d px 3D\n%d draws · %.2f M tris" % [Engine.get_frames_per_second(), px.x, px.y, draws, prims / 1.0e6]


func _report() -> void:
	var sorted := frame_ms.duplicate()
	sorted.sort()
	var total := 0.0
	for v in frame_ms:
		total += v
	var avg := total / maxf(1.0, frame_ms.size())
	var p50: float = sorted[int(sorted.size() * 0.5)]
	var p95: float = sorted[int(sorted.size() * 0.95)]
	var line := "BENCH frames=%d avg_fps=%.1f p50_ms=%.1f p95_ms=%.1f max_draws=%d max_tris=%d" % [
		frame_ms.size(), 1000.0 / avg, p50, p95, draws_max, prims_max]
	print(line)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__bench = %s;" % JSON.stringify(line))
