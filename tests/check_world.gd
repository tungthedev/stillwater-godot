extends SceneTree

# Headless cross-check of world/world_data.gd against values computed by Stillwater itself
# (samples.json, poses.json and per-tier counts in meta.json, written by tools/export_world.mjs).
# Run: godot --headless --path . -s tests/check_world.gd   (exit code 1 on any failure)

const WorldData := preload("res://world/world_data.gd")
# Both sides do double maths on the same float32 grids, so real agreement is ~1e-9 m;
# anything near this limit means an indexing or half-texel bug, not rounding.
const HEIGHT_TOL := 1e-4
const VALUE_TOL := 1e-5
const CompactWorld := preload("res://world/compact_world.gd")
const VegScatter := preload("res://world/veg_scatter.gd")
const COMPACT_HEIGHT_TOL := 0.02

var failures := 0
# A runtime script error aborts a function without failing the run; this proves it finished.
var veg_checked := false


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

	_check_compact(samples, w)
	_check_veg_scatter()

	var mesh_files := 0
	for m in w.meshes.meshes:
		var bytes := FileAccess.get_file_as_bytes("res://data/valley".path_join(m.file))
		var expect: int = int(m.layout.index.offset) + int(m.layout.index.count) * 4
		if bytes.size() != expect:
			_fail("mesh %s is %d bytes, layout says %d" % [m.file, bytes.size(), expect])
		mesh_files += 1
	print("meshes: %d files match their layout" % mesh_files)
	_finish()


# The compact web pack (what the scene loads) against Stillwater's own sample values and the
# full float grids. Heights are quantised (near 8.7 mm steps, far 3 cm), the trail mask to 1/127.
func _check_compact(samples: Array, w: RefCounted) -> void:
	var c := CompactWorld.new()
	if not c.load_dir("res://data/valley/web"):
		_fail("compact pack failed to load")
		return
	if str(c.meta.worldHash) != str(w.meta.worldHash):
		_fail("compact pack is from world %s, full export is %s" % [c.meta.worldHash, w.meta.worldHash])
	var e_near := 0.0
	var e_far := 0.0
	var e_render := 0.0
	var e_trail := 0.0
	var e_biome := 0.0
	for s in samples:
		var x: float = s.x
		var z: float = s.z
		e_near = maxf(e_near, absf(c.height_near(x, z) - float(s.h)))
		e_far = maxf(e_far, absf(c.height_far(x, z) - float(s.hFar)))
		e_render = maxf(e_render, absf(c.height(x, z) - float(s.hRender)))
		e_trail = maxf(e_trail, absf(c.trail_at(x, z) - float(s.trail)))
		var b := c.biome_at(x, z)
		e_biome = maxf(e_biome, maxf(absf(b.flowers - float(s.flowers)), absf(b.meadow - float(s.meadow))))
	# Dense grid over both maps, so a wrong byte order or row flip anywhere shows up.
	var g_near := 0.0
	var g_far := 0.0
	for gz in range(-2040, 2041, 37):
		for gx in range(-2040, 2041, 41):
			g_near = maxf(g_near, absf(c.height_near(gx, gz) - w.height_near(gx, gz)))
	for gz in range(-16380, 16381, 331):
		for gx in range(-16380, 16381, 347):
			g_far = maxf(g_far, absf(c.height_far(gx, gz) - w.height_far(gx, gz)))
	print("compact pack: samples max error near %.4f m, far %.4f m, render %.4f m, trail %.4f, biome %.4f; grid near %.4f m, far %.4f m" % [
		e_near, e_far, e_render, e_trail, e_biome, g_near, g_far])
	if maxf(maxf(e_near, e_far), maxf(e_render, maxf(g_near, g_far))) > COMPACT_HEIGHT_TOL:
		_fail("compact heights differ by more than %.2f m" % COMPACT_HEIGHT_TOL)
	if e_trail > 0.5 / 127.0 + 1e-4:
		_fail("compact trail mask differs by %.5f" % e_trail)
	if e_biome > 0.5 / 255.0:
		_fail("compact biome differs by %.5f" % e_biome)
	if c.biome_bytes != w.biome_rgb:
		_fail("compact biome bytes differ from biome_rgb.u8")
	_check_compact_trees(c, w)
	for stop in ["trailhead", "forest"]:
		var p: Dictionary = c.pose(stop)
		var e := absf(c.height_near(p.position[0], p.position[2]) + float(c.meta.poses.eyeHeight) - float(p.position[1]))
		if e > COMPACT_HEIGHT_TOL:
			_fail("compact pose %s eye height differs by %.4f m" % [stop, e])


# The shipped tree pack against the full float32 placements: same subset as the game's rank
# selection, index for index; quantisation inside its bounds; every tree on the rendered ground.
const TREE_XZ_TOL := 0.02
const TREE_GROUND_TOL := 0.02


func _check_compact_trees(c: RefCounted, w: RefCounted) -> void:
	var tm: Dictionary = c.meta.trees
	if str(tm.worldHash) != str(w.meta.worldHash):
		_fail("tree pack is from world %s, full export is %s" % [tm.worldHash, w.meta.worldHash])
	var t: Dictionary = c.load_trees()
	if t.is_empty():
		_fail("tree pack failed to load")
		return
	var tier: Dictionary = w.tier(str(tm.tier))
	var want: PackedInt32Array = w.select_by_rank(float(tier.trees))
	if int(t.count) != want.size() or int(t.count) != int(tier.expectedTrees):
		_fail("tree pack holds %d trees, %s tier selects %d (expected %d)" % [t.count, tm.tier, want.size(), int(tier.expectedTrees)])
		return
	var d: Dictionary = tm.decode
	var e_xz := 0.0
	var e_s := 0.0
	var e_rot := 0.0
	var e_sx := 0.0
	var e_tint := 0.0
	var e_ground := 0.0
	var e_game_y := 0.0
	var band := 0
	var e_band := 0.0
	var kind_bad := 0
	var tk: float = float(t.tint_max) / 255.0
	for j in want.size():
		var i := want[j]
		e_xz = maxf(e_xz, Vector2(t.x[j] - w.tree_x[i], t.z[j] - w.tree_z[i]).length())
		e_s = maxf(e_s, absf(t.s[j] - w.tree_s[i]))
		e_rot = maxf(e_rot, absf(angle_difference(t.rot[j], w.tree_rot[i])))
		e_sx = maxf(e_sx, absf(t.sx[j] - w.tree_sx[i]))
		var tint: Color = w.tree_tint[i]
		e_tint = maxf(e_tint, maxf(absf(t.tint[j * 3] * tk - tint.r), maxf(absf(t.tint[j * 3 + 1] * tk - tint.g), absf(t.tint[j * 3 + 2] * tk - tint.b))))
		if t.kind[j] != w.tree_kind[i]:
			kind_bad += 1
		# y must be the rendered ground (Godot's own height function on the shipped pack) - sink.
		var sink := 0.15 if w.tree_kind[i] == 3 else 0.25
		e_ground = maxf(e_ground, absf(t.y[j] - (c.height(t.x[j], t.z[j]) - sink)))
		if maxf(absf(w.tree_x[i]), absf(w.tree_z[i])) > c.blend_start:
			band += 1
			e_band = maxf(e_band, absf(t.y[j] - w.tree_y[i]))
		else:
			e_game_y = maxf(e_game_y, absf(t.y[j] - w.tree_y[i]))
	print("tree pack: %d trees (%s tier, same indices as select_by_rank), max error xz %.4f m, s %.4f, rot %.5f rad, sx %.5f, tint %.4f, kind mismatches %d" % [
		want.size(), tm.tier, e_xz, e_s, e_rot, e_sx, e_tint, kind_bad])
	print("tree pack ground: y vs rendered height - sink max %.4f m; vs game y outside the blend band %.4f m; %d trees in the band differ from the game's near-only y by up to %.2f m" % [
		e_ground, e_game_y, band, e_band])
	if e_xz > TREE_XZ_TOL:
		_fail("tree pack moves a tree %.4f m horizontally" % e_xz)
	if e_ground > TREE_GROUND_TOL or e_game_y > TREE_GROUND_TOL:
		_fail("tree pack ground contact off by %.4f m (game y outside the band %.4f m)" % [e_ground, e_game_y])
	if e_s > float(d.sMax) / 65535.0 or e_sx > 1.0 / 65535.0 or e_rot > TAU / 65536.0 or e_tint > float(d.tintMax) / 255.0 * 0.5 + 1e-4:
		_fail("tree pack scale/rotation/tint quantisation error too large")
	if kind_bad > 0:
		_fail("tree pack kinds differ for %d trees" % kind_bad)


# Grass and flower roots and randoms, every rank, against Stillwater's own generateTileScatter.
func _check_veg_scatter() -> void:
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/valley/veg_fixture.json"))
	for kind in ["grass", "flowers"]:
		var L: Dictionary = fx[kind]
		var got: Dictionary = VegScatter.generate(int(L.maxCount), float(L.tileSize), int(L.seed))
		var gp: PackedInt64Array = got.packed
		var want: Array = L.packed
		var bad := 0
		for k in want.size():
			if gp[k] != int(want[k]):
				bad += 1
		print("%s scatter: %d ranks, %d of %d packed words differ from Stillwater" % [kind, int(L.maxCount), bad, want.size()])
		if bad > 0 or gp.size() != want.size():
			_fail("%s scatter differs from Stillwater in %d words" % [kind, bad])
	var flip_bad := 0
	for f in fx.flips:
		var b := VegScatter.flip_bits(int(f.tx), int(f.tz))
		if b.x != int(f.flipX) or b.y != int(f.flipZ):
			flip_bad += 1
	print("tile mirror bits: %d of %d differ" % [flip_bad, fx.flips.size()])
	if flip_bad > 0:
		_fail("tile mirror bits differ for %d tiles" % flip_bad)
	veg_checked = true


static func _sci(v: float) -> String:
	return String.num_scientific(v)


func _fail(msg: String) -> void:
	failures += 1
	printerr("FAIL: " + msg)


func _finish() -> void:
	if not veg_checked:
		_fail("vegetation scatter check did not run to the end")
	print("CHECK_WORLD %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(0 if failures == 0 else 1)
