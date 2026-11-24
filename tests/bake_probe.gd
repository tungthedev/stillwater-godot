extends SceneTree

# Checks the offscreen bake that grass relies on: a canvas pass writes bytes into a SubViewport
# and a second pass texelFetches them back. Needs a real renderer (not --headless), e.g.
#   xvfb-run -a godot --path . -s tests/bake_probe.gd
# It settles: byte-exact RGBA8 (no sRGB decode, alpha written unblended), how canvas FRAGCOORD
# rows map to texelFetch rows, and that a later partial bake (other texels discarded) leaves
# the untouched texels alone. Exit code 1 on any mismatch.

const W := 8
const H := 4

const WRITE := """
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

const READ := """
shader_type canvas_item;
render_mode blend_disabled;
uniform sampler2D src : filter_nearest;
void fragment() {
	COLOR = texelFetch(src, ivec2(FRAGCOORD.xy), 0);
}
"""


func _vp(code: String) -> Array:
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
	root.add_child(vp)
	return [vp, m]


func _init() -> void:
	var a := _vp(WRITE)
	var b := _vp(READ)
	var va: SubViewport = a[0]
	var vb: SubViewport = b[0]
	b[1].set_shader_parameter("src", va.get_texture())
	await process_frame
	va.render_target_update_mode = SubViewport.UPDATE_ONCE
	vb.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var same_frame := _check(va, vb, -1, "same frame")
	# Partial re-bake of column 3 only, then read again.
	a[1].set_shader_parameter("only_x", 3)
	va.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	vb.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var partial := _check(va, vb, 3, "partial")
	print("BAKE_PROBE %s" % ("PASS" if same_frame and partial else "FAIL"))
	quit(0 if same_frame and partial else 1)


func _check(va: SubViewport, vb: SubViewport, patched_x: int, tag: String) -> bool:
	var ia := va.get_texture().get_image()
	var ib := vb.get_texture().get_image()
	ia.convert(Image.FORMAT_RGBA8)
	ib.convert(Image.FORMAT_RGBA8)
	# Image row of the texel written at FRAGCOORD.y = 0 (the readback may flip).
	var a_row0 := -1
	for r in H:
		if ia.get_data()[(r * W) * 4 + 1] == 2:
			a_row0 = r
	var ok := a_row0 >= 0
	var exact := true
	for y in H:
		for x in W:
			var r := y if a_row0 == 0 else H - 1 - y
			var k := (r * W + x) * 4
			var d := ia.get_data()
			var want_b: int = 200 if x == patched_x else (128 if (x + y) % 2 == 0 else 254)
			if d[k] != x + 1 or d[k + 1] != y * 60 + 2 or d[k + 2] != want_b or d[k + 3] != 37 + x * 20:
				exact = false
				if ok:
					print("  %s A mismatch at frag (%d,%d): %d %d %d %d" % [tag, x, y, d[k], d[k + 1], d[k + 2], d[k + 3]])
	var same := ia.get_data() == ib.get_data()
	var flipped := false
	if not same:
		var f := ib.duplicate()
		f.flip_y()
		flipped = f.get_data() == ia.get_data()
	print("%s: A byte-exact=%s readback_row_of_frag0=%d  B==A %s, B==flip(A) %s" % [tag, exact, a_row0, same, flipped])
	if not (same or flipped):
		print("  B row bytes: ", Array(ib.get_data().slice(0, W * 4)))
	return ok and exact and (same or flipped)
