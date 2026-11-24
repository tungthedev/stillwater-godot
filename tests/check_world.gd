extends SceneTree

# Headless cross-check of world/world_data.gd against values computed by Stillwater itself
# (samples.json, poses.json and per-tier counts in meta.json, written by tools/export_world.mjs).
# Run: godot --headless --path . -s tests/check_world.gd   (exit code 1 on any failure)

const WorldData := preload("res://world/world_data.gd")
# Both sides do double maths on the same float32 grids, so real agreement is ~1e-9 m;
# anything near this limit means an indexing or half-texel bug, not rounding.
const HEIGHT_TOL := 1e-4
const VALUE_TOL := 1e-5

var failures := 0


func _init() -> void:
	var t0 := Time.get_ticks_msec()
	var w := WorldData.new()
	if not w.load_dir("res://data/valley"):
		_fail("load_dir failed or sizes do not match meta")
		_finish()
		return
	print("loaded %s (hash %s, stillwater %s) in %d ms: %d trees, %d rocks, %d trail points" % [
		w.dir, w.meta.worldHash, str(w.meta.stillwaterCommit).substr(0, 7), Time.get_ticks_msec() - t0,
		w.tree_count, w.rock_count, w.trail_points.size()])

	var samples: Array = JSON.parse_string(FileAccess.get_file_as_string("res://data/valley/samples.json")).samples
	var err_near := 0.0
	var err_far := 0.0
	var err_render := 0.0
	var err_other := 0.0
	for s in samples:
		var x: float = s.x
		var z: float = s.z
		var en := absf(w.height_near(x, z) - float(s.h))
		var ef := absf(w.height_far(x, z) - float(s.hFar))
		var er := absf(w.height(x, z) - float(s.hRender))
		err_near = maxf(err_near, en)
		err_far = maxf(err_far, ef)
		err_render = maxf(err_render, er)
		if en > HEIGHT_TOL or ef > HEIGHT_TOL or er > HEIGHT_TOL:
			_fail("height mismatch at %s (%.2f, %.2f): near %.6f far %.6f render %.6f m" % [s.label, x, z, en, ef, er])
		var b := w.biome_at(x, z)
		var eo := maxf(absf(w.trail_at(x, z) - float(s.trail)), maxf(absf(b.forest - float(s.forest)),
			maxf(absf(b.flowers - float(s.flowers)), absf(b.meadow - float(s.meadow)))))
		err_other = maxf(err_other, eo)
		if eo > VALUE_TOL:
			_fail("trail/biome mismatch at %s: %.6f" % [s.label, eo])
	print("heights: %d samples, max error near %s m, far %s m, render blend %s m" % [samples.size(), _sci(err_near), _sci(err_far), _sci(err_render)])
	print("trail mask + biome: max error %s" % _sci(err_other))

	# The far grid must line up with the near one, not just match itself. Its 16 m texels miss
	# steep detail, so judge the mean over a grid; a flipped or shifted grid is off by ~100 m.
	var sum_nf := 0.0
	var max_nf := 0.0
	var n_nf := 0
	for gz in range(-1800, 1801, 90):
		for gx in range(-1800, 1801, 90):
			var d := absf(w.height_near(gx + 0.5, gz + 0.5) - w.height_far(gx + 0.5, gz + 0.5))
			sum_nf += d
			max_nf = maxf(max_nf, d)
			n_nf += 1
	var mean_nf := sum_nf / n_nf
	print("near vs far grid inside valley: mean %.2f m, max %.2f m over %d points" % [mean_nf, max_nf, n_nf])
	if mean_nf > 5.0:
		_fail("near and far grids disagree by %.2f m on average inside the valley" % mean_nf)

	for tier_name in ["low", "medium", "high", "ultra"]:
		var t: Dictionary = w.tier(tier_name)
		var trees := w.select_by_rank(float(t.trees)).size()
		var rocks := w.select_rocks_by_rank(float(t.rocks)).size()
		var ok: bool = trees == int(t.expectedTrees) and rocks == int(t.expectedRocks)
		print("tier %s: trees density %.2f -> %d (js %d), rocks %.2f -> %d (js %d) %s" % [
			tier_name, t.trees, trees, int(t.expectedTrees), t.rocks, rocks, int(t.expectedRocks), "ok" if ok else "MISMATCH"])
		if not ok:
			_fail("rank selection count differs on tier %s" % tier_name)

	for stop in ["trailhead", "forest"]:
		var p: Dictionary = w.pose(stop)
		var pos: Array = p.position
		var eye: float = w.height_near(pos[0], pos[2]) + float(w.poses.eyeHeight)
		var e := absf(eye - float(pos[1]))
		print("pose %s: (%.2f, %.2f, %.2f) yaw %.4f pitch %.3f, eye error %s m" % [stop, pos[0], pos[1], pos[2], p.yaw, p.pitch, _sci(e)])
		if e > HEIGHT_TOL:
			_fail("pose %s eye height differs by %.6f m" % [stop, e])
		# Godot's default Euler order is YXZ like three.js, so (pitch, yaw, 0) must aim at lookAt.
		var fwd := -Basis.from_euler(Vector3(p.pitch, p.yaw, 0.0)).z
		var look: Array = p.lookAt
		var want := (Vector3(look[0], look[1], look[2]) - Vector3(pos[0], pos[1], pos[2])).normalized()
		var ea := fwd.distance_to(want)
		print("pose %s: Godot camera forward vs lookAt error %s" % [stop, _sci(ea)])
		if ea > 1e-5:
			_fail("pose %s rotation does not aim at lookAt in Godot" % stop)

	# Every tree: y was set by the game as near height - 0.25 (bush 0.15), which ties x, y, z and
	# kind together and catches a wrong planar stride.
	var worst_y := 0.0
	for i in w.tree_count:
		var sink := 0.15 if w.tree_kind[i] == 3 else 0.25
		worst_y = maxf(worst_y, absf(w.tree_y[i] - (w.height_near(w.tree_x[i], w.tree_z[i]) - sink)))
	print("tree y vs height_near - sink: max %s m over %d trees" % [_sci(worst_y), w.tree_count])
	if worst_y > 1e-3:
		_fail("tree y does not follow the height grid (%.6f m)" % worst_y)

	var probes: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/valley/samples.json"))
	var worst_probe := 0.0
	for t in probes.treeProbes:
		var i: int = t.i
		var tint: Color = w.tree_tint[i]
		var got := [w.tree_x[i], w.tree_y[i], w.tree_z[i], w.tree_s[i], w.tree_rot[i], w.tree_sx[i], tint.r, tint.g, tint.b]
		var want := [t.x, t.y, t.z, t.s, t.rot, t.sx, t.tint[0], t.tint[1], t.tint[2]]
		for k in got.size():
			worst_probe = maxf(worst_probe, absf(float(got[k]) - float(want[k])) / maxf(1.0, absf(float(want[k]))))
		if w.tree_kind[i] != int(t.v) or w.tree_salt[i] != int(t.salt) or w.tree_rank[i] != int(float(t.rank) * 65536.0):
			_fail("tree probe %d kind/salt/rank differs" % i)
	for r in probes.rockProbes:
		var i: int = r.i
		var got := [w.rock_x[i], w.rock_y[i], w.rock_z[i], w.rock_s[i], w.rock_rot[i], w.rock_tilt_x[i], w.rock_tilt_z[i]]
		var want := [r.x, r.y, r.z, r.s, r.rot, r.tilt[0], r.tilt[1]]
		for k in got.size():
			worst_probe = maxf(worst_probe, absf(float(got[k]) - float(want[k])) / maxf(1.0, absf(float(want[k]))))
		if w.rock_kind[i] != int(r.v) or w.rock_rank[i] != int(float(r.rank) * 65536.0):
			_fail("rock probe %d kind/rank differs" % i)
	print("placement probes: %d trees, %d rocks, max relative error %s (float32 storage)" % [
		probes.treeProbes.size(), probes.rockProbes.size(), _sci(worst_probe)])
	if worst_probe > 1e-6:
		_fail("placement probe fields differ (%s)" % _sci(worst_probe))

	var mesh_files := 0
	for m in w.meshes.meshes:
		var bytes := FileAccess.get_file_as_bytes("res://data/valley".path_join(m.file))
		var expect: int = int(m.layout.index.offset) + int(m.layout.index.count) * 4
		if bytes.size() != expect:
			_fail("mesh %s is %d bytes, layout says %d" % [m.file, bytes.size(), expect])
		mesh_files += 1
	print("meshes: %d files match their layout" % mesh_files)
	_finish()


static func _sci(v: float) -> String:
	return String.num_scientific(v)


func _fail(msg: String) -> void:
	failures += 1
	printerr("FAIL: " + msg)


func _finish() -> void:
	print("CHECK_WORLD %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(0 if failures == 0 else 1)
