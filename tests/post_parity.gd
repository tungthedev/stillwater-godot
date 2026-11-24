extends SceneTree

# The post chain must not change the look apart from its effects: with bloom, FXAA, sharpen, grain
# and the sun veil zeroed, a frame graded in the composite (post on) must match the same frame
# graded by the objects (post off) at both bench poses. They differ only where the upscale meets an
# edge (post off upscales graded colour, post on upscales HDR), so the check is on the mean.
# Needs a GPU context: xvfb-run -a godot --path . --rendering-driver opengl3 --resolution 675x1130 -s tests/post_parity.gd

const MEAN_MAX := 1.5 / 255.0


func _init() -> void:
	var main: Node = load("res://main.tscn").instantiate()
	root.add_child(main)
	for i in 5:
		await process_frame
	var post: Node = main.get_node("post")
	var cam: Camera3D = post.scene_vp.get_node("camera")
	var ui: CanvasLayer = main.get_node("ui")
	ui.visible = false
	post.set_effects(false)
	# Wind sway reads shader TIME; freeze it so both frames show the same blades.
	Engine.time_scale = 0.0
	var ok := true
	for stop in ["trailhead", "forest"]:
		cam.set_mode(cam.MODES.find(stop))
		post.set_on(true)
		var on_img := await _frame()
		post.set_on(false)
		var off_img := await _frame()
		var dump := OS.get_environment("PARITY_DUMP")
		if dump != "":
			on_img.save_png(dump.path_join("parity_%s_on.png" % stop))
			off_img.save_png(dump.path_join("parity_%s_off.png" % stop))
		var d := _diff(on_img, off_img)
		var pass_: bool = d.mean <= MEAN_MAX
		ok = ok and pass_
		print("parity %s: mean %.2f/255, p99 %.1f/255, max %.1f/255 over %d px %s" % [stop, d.mean * 255.0, d.p99 * 255.0, d.max * 255.0, d.n, "ok" if pass_ else "DIFF"])
	print("POST_PARITY %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _frame() -> Image:
	# Grass tiles bake over a few frames after a pose change.
	for i in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


static func _diff(a: Image, b: Image) -> Dictionary:
	var w := a.get_width()
	var h := a.get_height()
	var vals := PackedFloat32Array()
	var total := 0.0
	var mx := 0.0
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var v := (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			vals.append(v)
			total += v
			mx = maxf(mx, v)
	vals.sort()
	return {"mean": total / vals.size(), "p99": vals[int(vals.size() * 0.99)], "max": mx, "n": vals.size()}
