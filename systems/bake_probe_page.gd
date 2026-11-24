extends Node

# ?probe=bake: on-device self-test for the grass bake pipeline in the real WebGL2 renderer.
# Runs:
#   1. same_frame: RGBA8 SubViewport write (blend_disabled, transparent_bg, alpha < 1) + canvas texelFetch
#   2. partial:    CLEAR_MODE_NEVER + discard partial column update leaves prior texels untouched
#   3. vtx_fetch:  3D spatial vertex shader texelFetch of all 4 channels from an RGBA8 SubViewport
#   4. tile_h_n:   real grass tile near the trailhead baked via systems/grass.gd; height & normal vs CPU
#   5. tile_tall:  real trailhead tile density, tallness, alpha bytes and non-premultiplied RGB check
# Shows a single-screen phone-readable summary and publishes window.__probe.

const Flags := preload("res://systems/flags.gd")
const VegScatter := preload("res://world/veg_scatter.gd")

const W := 8
const H := 4
const H_SPAN := 64.0
const TALL_MAX := 2.2

const WRITE_SHADER := """
shader_type canvas_item;
render_mode blend_disabled;
uniform int only_x = -1;
void fragment() {
	ivec2 p = ivec2(FRAGCOORD.xy);
	if (only_x >= 0 && p.x != only_x) discard;
	float b = only_x >= 0 ? 200.0 : ((p.x + p.y) % 2 == 0 ? 128.0 : 254.0);
	COLOR = vec4(float(p.x + 1), float(p.y * 60 + 2), b, float(37 + p.x * 20)) / 255.0;
}
"""

const READ_SHADER := """
shader_type canvas_item;
render_mode blend_disabled;
uniform sampler2D src : filter_nearest;
void fragment() {
	COLOR = texelFetch(src, ivec2(FRAGCOORD.xy), 0);
}
"""

const VTX_FETCH_SHADER := """
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled;
#include "res://shaders/stillwater.gdshaderinc"
uniform sampler2D src : filter_nearest;
varying vec3 v_out;
void vertex() {
	vec4 v = texelFetch(src, ivec2(3, 2), 0);
	v_out = UV.x < 0.5 ? v.rgb : vec3(v.a, v.a, v.a);
}
void fragment() {
	ALBEDO = godot_out(v_out);
}
"""

var world: RefCounted
var build_id := ""
var _box: VBoxContainer
var _title_l: Label


func setup(w: RefCounted, build: String) -> void:
	world = w
	build_id = build


func _ready() -> void:
	_build_ui()
	_run.call_deferred()


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.08, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	var safe := _read_safe()
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_top", int(maxf(14.0, safe.x + 6.0)))
	margin.add_theme_constant_override("margin_right", int(maxf(12.0, safe.y + 6.0)))
	margin.add_theme_constant_override("margin_bottom", int(maxf(14.0, safe.z + 6.0)))
	margin.add_theme_constant_override("margin_left", int(maxf(12.0, safe.w + 6.0)))
	layer.add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	_box = VBoxContainer.new()
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_box)
	_title_l = _line("BAKE PROBE  RUNNING... (%s)" % build_id, 17, Color(0.96, 0.92, 0.7))
	_box.add_child(_title_l)


func _line(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _read_safe() -> Vector4:
	if not OS.has_feature("web"):
		return Vector4.ZERO
	var s = JavaScriptBridge.eval("(() => { const e = document.getElementById('safe'); if (!e) return '0,0,0,0'; const c = getComputedStyle(e); return [c.paddingTop, c.paddingRight, c.paddingBottom, c.paddingLeft].map(parseFloat).join(','); })()")
	var p := str(s).split(",")
	return Vector4(float(p[0]), float(p[1]), float(p[2]), float(p[3])) if p.size() == 4 else Vector4.ZERO


func _gl_caps() -> Dictionary:
	if not OS.has_feature("web"):
		return {"float_linear": true, "color_float": true, "color_half": true, "vtx_tex_units": -1}
	var raw = JavaScriptBridge.eval("JSON.stringify((() => { const gl = document.createElement('canvas').getContext('webgl2'); if (!gl) return {}; return { float_linear: !!gl.getExtension('OES_texture_float_linear'), color_float: !!gl.getExtension('EXT_color_buffer_float'), color_half: !!gl.getExtension('EXT_color_buffer_half_float'), vtx_tex_units: gl.getParameter(gl.MAX_VERTEX_TEXTURE_IMAGE_UNITS) }; })())")
	var parsed = JSON.parse_string(str(raw))
	return parsed if parsed is Dictionary else {}


func _make_2d_vp(code: String) -> Array:
	var vp := SubViewport.new()
	vp.size = Vector2i(W, H)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var r := ColorRect.new()
	r.size = Vector2(W, H)
	var m := ShaderMaterial.new()
	m.shader = Shader.new()
	m.shader.code = code
	r.material = m
	vp.add_child(r)
	add_child(vp)
	return [vp, m]


func _run() -> void:
	var a := _make_2d_vp(WRITE_SHADER)
	var b := _make_2d_vp(READ_SHADER)
	var va: SubViewport = a[0]
	var vb: SubViewport = b[0]
	b[1].set_shader_parameter("src", va.get_texture())
	await get_tree().process_frame
	va.render_target_update_mode = SubViewport.UPDATE_ONCE
	vb.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var c_same := _check_2d(va, vb, -1)

	a[1].set_shader_parameter("only_x", 3)
	va.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	vb.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var c_partial := _check_2d(va, vb, 3)

	var c_vtx := await _check_vertex_fetch(va)
	var c_tile := await _check_grass_tile(int(c_same.readback_row0))

	var checks: Array[Dictionary] = [
		{"name": "same_frame", "pass": c_same.pass, "summary": c_same.summary, "mismatches": c_same.mismatches},
		{"name": "partial", "pass": c_partial.pass, "summary": c_partial.summary, "mismatches": c_partial.mismatches},
		{"name": "vtx_fetch", "pass": c_vtx.pass, "summary": c_vtx.summary, "mismatches": c_vtx.mismatches},
		{"name": "tile_h_n", "pass": c_tile.h_pass, "summary": c_tile.h_summary, "mismatches": c_tile.h_mismatches},
		{"name": "tile_tall", "pass": c_tile.t_pass, "summary": c_tile.t_summary, "mismatches": c_tile.t_mismatches},
	]
	var all_pass := true
	for ch in checks:
		if not ch.pass:
			all_pass = false

	var result := {
		"probe": "bake",
		"build": build_id,
		"pass": all_pass,
		"gpu": Flags.gpu_name(),
		"ua": Flags.user_agent(),
		"dpr": Flags.device_pixel_ratio(),
		"gl": _gl_caps(),
		"checks": checks,
		"detail": {"same_frame": c_same, "partial": c_partial, "vtx_fetch": c_vtx, "tile": c_tile},
	}
	_render_result(result)
	var json := JSON.stringify(result)
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__probe = %s;" % json)
	print("PROBE %s" % json)


func _check_2d(va: SubViewport, vb: SubViewport, patched_x: int) -> Dictionary:
	var ia := va.get_texture().get_image()
	var ib := vb.get_texture().get_image()
	ia.convert(Image.FORMAT_RGBA8)
	ib.convert(Image.FORMAT_RGBA8)
	var da := ia.get_data()
	var db := ib.get_data()
	var a_row0 := -1
	for r in H:
		if da[(r * W) * 4 + 1] == 2:
			a_row0 = r
			break
	var mismatches: Array = []
	var a_exact := a_row0 >= 0
	for y in H:
		for x in W:
			var r := y if a_row0 == 0 else (H - 1 - y if a_row0 > 0 else y)
			var k := (r * W + x) * 4
			var want_b: int = 200 if x == patched_x else (128 if (x + y) % 2 == 0 else 254)
			var exp := [x + 1, y * 60 + 2, want_b, 37 + x * 20]
			var got := [da[k], da[k + 1], da[k + 2], da[k + 3]]
			if got != exp:
				a_exact = false
				if mismatches.size() < 4:
					mismatches.append({"where": "A(%d,%d)" % [x, y], "exp": exp, "got": got})
	var b_eq_a := da == db
	var b_eq_flip := false
	if not b_eq_a:
		var f := ib.duplicate()
		f.flip_y()
		b_eq_flip = f.get_data() == da
		for y in H:
			for x in W:
				var k := (y * W + x) * 4
				var ea := [da[k], da[k + 1], da[k + 2], da[k + 3]]
				var eb := [db[k], db[k + 1], db[k + 2], db[k + 3]]
				if ea != eb and mismatches.size() < 4:
					mismatches.append({"where": "B(%d,%d)" % [x, y], "exp": ea, "got": eb})
	var ok := a_row0 >= 0 and a_exact and b_eq_a
	var summary := "exact=%s row0=%d B==A=%s flip=%s" % [str(a_exact), a_row0, str(b_eq_a), str(b_eq_flip)]
	return {"pass": ok, "a_exact": a_exact, "readback_row0": a_row0, "b_eq_a": b_eq_a, "b_eq_flip": b_eq_flip, "summary": summary, "mismatches": mismatches}


func _check_vertex_fetch(va: SubViewport) -> Dictionary:
	var vp := SubViewport.new()
	vp.size = Vector2i(16, 16)
	vp.own_world_3d = true
	vp.use_hdr_2d = false
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.0
	cam.position = Vector3(0, 0, 2)
	vp.add_child(cam)
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array([
		Vector3(-1, -1, 0), Vector3(0, -1, 0), Vector3(-1, 1, 0), Vector3(0, 1, 0),
		Vector3(0, -1, 0), Vector3(1, -1, 0), Vector3(0, 1, 0), Vector3(1, 1, 0),
	])
	var uvs := PackedVector2Array([
		Vector2(0, 0), Vector2(0, 0), Vector2(0, 0), Vector2(0, 0),
		Vector2(1, 0), Vector2(1, 0), Vector2(1, 0), Vector2(1, 0),
	])
	var idx := PackedInt32Array([0, 1, 2, 1, 3, 2, 4, 5, 6, 5, 7, 6])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = VTX_FETCH_SHADER
	mat.set_shader_parameter("src", va.get_texture())
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	vp.add_child(mi)
	add_child(vp)
	await get_tree().process_frame
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	var left := img.get_pixel(4, 8)
	var right := img.get_pixel(12, 8)
	var got := [left.r8, left.g8, left.b8, right.r8]
	# Texel (3, 2) after partial patch on x=3: (3+1, 2*60+2, 200, 37+3*20) = (4, 122, 200, 97).
	var exp := [4, 122, 200, 97]
	var max_diff := 0
	for i in 4:
		max_diff = maxi(max_diff, absi(got[i] - exp[i]))
	var ok := max_diff <= 3
	var mismatches: Array = []
	if not ok:
		mismatches.append({"where": "vtx(3,2)", "exp": exp, "got": got})
	return {"pass": ok, "exp": exp, "got": got, "max_diff": max_diff, "summary": "texel(3,2) got=%s exp=%s" % [str(got), str(exp)], "mismatches": mismatches}


func _check_grass_tile(a_row0: int) -> Dictionary:
	var vp := SubViewport.new()
	vp.size = Vector2i(16, 16)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var p: Dictionary = world.pose("trailhead")
	var px0 := float(p.position[0])
	var py0 := float(p.position[1])
	var pz0 := float(p.position[2])
	var cam := Camera3D.new()
	cam.position = Vector3(px0, py0, pz0)
	cam.rotation = Vector3(float(p.pitch), float(p.yaw), 0.0)
	vp.add_child(cam)
	var grass_sys := Node3D.new()
	grass_sys.name = "grass_probe"
	grass_sys.set_script(load("res://systems/grass.gd"))
	grass_sys.setup(world)
	vp.add_child(grass_sys)

	var tx := floori(px0 / 8.0)
	var tz := floori(pz0 / 8.0)
	var key := Vector2i(tx, tz)
	var slot: Dictionary = {}
	for _i in 40:
		await get_tree().process_frame
		if grass_sys.grass.by_key.has(key):
			var s: Dictionary = grass_sys.grass.by_key[key]
			if s.ready:
				slot = s
				break
	if slot.is_empty():
		return {
			"h_pass": false, "h_summary": "tile %s never ready" % str(key), "h_mismatches": [],
			"t_pass": false, "t_summary": "tile %s never ready" % str(key), "t_mismatches": [],
		}
	await RenderingServer.frame_post_draw
	var img: Image = grass_sys.grass.vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	var iw := img.get_width()
	var ih := img.get_height()
	var flip_y := a_row0 > 0

	var sc: Dictionary = VegScatter.generate(grass_sys.GRASS.max_count, grass_sys.GRASS.tile, grass_sys.GRASS.seed)
	var local: PackedFloat32Array = sc.local
	var n_blades: int = int(grass_sys.GRASS.near)
	var slot_w: int = int(grass_sys.GRASS.slot_w)
	var sx: int = int(slot.sx)
	var sy: int = int(slot.sy)
	var flips: int = int(slot.flips)
	var base_h: float = float(slot.base)
	var ox: float = float(slot.ox)
	var oz: float = float(slot.oz)

	var max_h_err := 0.0
	var max_n_err := 0.0
	var nonzero_b0 := 0
	var dens_ok := 0
	var tall_ok := 0
	var tall_sum := 0.0
	var tall_max := 0.0
	var a0_min := 255
	var a0_max := 0
	var yaw_min := 255
	var yaw_max := 0
	var a2_min := 255
	var a2_max := 0
	var a0_zero_n := 0
	var a0_zero_rgb_nz := 0
	var h_mismatches: Array = []
	var t_mismatches: Array = []

	for rank in n_blades:
		var px := sx + (rank % slot_w)
		var py := sy + (rank / slot_w)
		var ry := (ih - 1 - py) if flip_y else py
		var k0 := (ry * iw + px) * 4
		var k1 := (ry * iw + px + slot_w) * 4
		var k2 := (ry * iw + px + slot_w * 2) * 4
		var b0: Array[int] = [data[k0], data[k0 + 1], data[k0 + 2], data[k0 + 3]]
		var b1: Array[int] = [data[k1], data[k1 + 1], data[k1 + 2], data[k1 + 3]]
		var b2: Array[int] = [data[k2], data[k2 + 1], data[k2 + 2], data[k2 + 3]]
		if b0[0] != 0 or b0[1] != 0 or b0[2] != 0:
			nonzero_b0 += 1
		if b0[3] == 0:
			a0_zero_n += 1
			if b0[0] > 0 or b0[1] > 0 or b0[2] > 0:
				a0_zero_rgb_nz += 1
		var lx := local[rank * 2]
		var lz := local[rank * 2 + 1]
		if (flips & 1) != 0:
			lx = 8.0 - lx
		if (flips & 2) != 0:
			lz = 8.0 - lz
		var wx := ox + lx
		var wz := oz + lz
		var cpu_h: float = world.height(wx, wz)
		var gpu_h: float = base_h + (float(b0[0]) + float(b0[1]) * 256.0) / 65535.0 * H_SPAN
		var h_err := absf(gpu_h - cpu_h)
		max_h_err = maxf(max_h_err, h_err)
		if h_err > 0.05 and h_mismatches.size() < 4:
			var eq := clampi(int(floor((cpu_h - base_h) / H_SPAN * 65535.0 + 0.5)), 0, 65535)
			h_mismatches.append({"where": "r%d" % rank, "exp": [eq & 255, (eq >> 8) & 255], "got": [b0[0], b0[1]], "h_err": snappedf(h_err, 0.001)})
		var hx0: float = world.height(wx - 1.0, wz)
		var hx1: float = world.height(wx + 1.0, wz)
		var hz0: float = world.height(wx, wz - 1.0)
		var hz1: float = world.height(wx, wz + 1.0)
		var cn := Vector3(hx0 - hx1, 2.0, hz0 - hz1).normalized()
		var gnx: float = float(b1[0]) / 255.0 * 2.0 - 1.0
		var gnz: float = float(b1[1]) / 255.0 * 2.0 - 1.0
		max_n_err = maxf(max_n_err, maxf(absf(gnx - cn.x), absf(gnz - cn.z)))
		var dens: float = float(b0[2]) / 255.0
		var tall: float = float(b1[2]) / 255.0 * TALL_MAX
		if dens > 0.1:
			dens_ok += 1
			if tall > 0.1:
				tall_ok += 1
				tall_sum += tall
				tall_max = maxf(tall_max, tall)
			elif t_mismatches.size() < 4:
				t_mismatches.append({"where": "r%d" % rank, "exp": "tall>0.1", "got": b1})
		a0_min = mini(a0_min, b0[3])
		a0_max = maxi(a0_max, b0[3])
		yaw_min = mini(yaw_min, b1[3])
		yaw_max = maxi(yaw_max, b1[3])
		a2_min = mini(a2_min, b2[3])
		a2_max = maxi(a2_max, b2[3])

	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var tall_mean := tall_sum / maxf(float(tall_ok), 1.0)
	var premul_ok := a0_zero_n == 0 or a0_zero_rgb_nz > 0
	var h_pass := nonzero_b0 > 0 and max_h_err < 0.05 and max_n_err < 0.05
	var t_pass := dens_ok >= 400 and tall_ok >= 400 and tall_max > 0.4 and (yaw_max - yaw_min) > 200 and a0_max <= 7 and premul_ok
	if not t_pass and t_mismatches.is_empty():
		var k0 := ((ih - 1 - sy) if flip_y else sy) * iw * 4 + sx * 4
		t_mismatches.append({"where": "r0_b0", "exp": "nz", "got": [data[k0], data[k0 + 1], data[k0 + 2], data[k0 + 3]]})
	return {
		"tile": [tx, tz], "slot": [sx, sy], "base": snappedf(base_h, 0.001),
		"h_pass": h_pass, "max_h_err": snappedf(max_h_err, 0.0001), "max_n_err": snappedf(max_n_err, 0.0001),
		"nonzero_b0": nonzero_b0, "h_mismatches": h_mismatches,
		"h_summary": "tile(%d,%d) max_h=%.4fm max_n=%.4f nz=%d/%d" % [tx, tz, max_h_err, max_n_err, nonzero_b0, n_blades],
		"t_pass": t_pass, "dens_ok": dens_ok, "tall_ok": tall_ok,
		"tall_mean": snappedf(tall_mean, 0.001), "tall_max": snappedf(tall_max, 0.001),
		"a0_range": [a0_min, a0_max], "yaw_range": [yaw_min, yaw_max], "a2_range": [a2_min, a2_max],
		"a0_zero_rgb_nz": [a0_zero_rgb_nz, a0_zero_n], "t_mismatches": t_mismatches,
		"t_summary": "dens=%d tall=%d mean=%.2fm max=%.2fm a0=%d..%d yaw=%d..%d a0rgb=%d/%d" % [
			dens_ok, tall_ok, tall_mean, tall_max, a0_min, a0_max, yaw_min, yaw_max, a0_zero_rgb_nz, a0_zero_n],
	}


func _render_result(r: Dictionary) -> void:
	var ok: bool = r.pass
	_title_l.text = "BAKE PROBE  %s  (%s)" % ["PASS" if ok else "FAIL", r.build]
	_title_l.add_theme_color_override("font_color", Color(0.45, 0.96, 0.55) if ok else Color(1.0, 0.45, 0.4))
	for ch in r.checks:
		var pass_c: bool = ch.pass
		var col := Color(0.55, 0.95, 0.6) if pass_c else Color(1.0, 0.5, 0.45)
		_box.add_child(_line("[%s] %s: %s" % ["PASS" if pass_c else "FAIL", ch.name, ch.summary], 13, col))
		for m in ch.mismatches.slice(0, 3):
			_box.add_child(_line("   %s exp=%s got=%s" % [str(m.where), str(m.exp), str(m.got)], 11, Color(1.0, 0.78, 0.6)))
	var gl: Dictionary = r.gl
	_box.add_child(_line("GL: float_lin=%s col_f=%s col_h=%s vtx_tex=%s dpr=%s" % [
		str(gl.get("float_linear", "?")), str(gl.get("color_float", "?")), str(gl.get("color_half", "?")),
		str(gl.get("vtx_tex_units", "?")), str(r.dpr)], 12, Color(0.78, 0.85, 0.96)))
	_box.add_child(_line("GPU: %s" % str(r.gpu), 12, Color(0.88, 0.9, 0.94)))
	_box.add_child(_line("UA: %s" % str(r.ua), 11, Color(0.68, 0.72, 0.78)))
