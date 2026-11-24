extends Node3D

# Painterly water (W2): Stillwater Lake, alpine stream + plunge pool, and hero waterfall.
# Built once from world data (data/valley/web/meta.json + near heightmap):
#   1. Lake (opaque, render_priority = -1, no discard): 20 m grid clipped tightly to wet cells.
#   2. Stream + plunge pool (opaque, render_priority = -1, no discard): merged into one mesh,
#      with outer skirt vertices tucked into carved banks so depth-test cuts a clean shore.
#   3. Waterfall curtains + base splash crown (cutout discard, render_priority = 1): 1 mesh.
# Total: <= 3 draw calls, ~7-8k triangles, zero alpha blending, zero per-frame GDScript work.

const LAKE_CELL := 20.0
const LAKE_WET_MARGIN := 0.35

var world: RefCounted
var lake_mat: ShaderMaterial
var stream_mat: ShaderMaterial
var falls_mat: ShaderMaterial
var lake_mi: MeshInstance3D
var stream_mi: MeshInstance3D
var falls_mi: MeshInstance3D

var lake_tris := 0
var stream_tris := 0
var falls_tris := 0
var tris := 0
var last_tris := 0
var last_draws := 0
var _on := true
var prof_us := 0


func setup(w: RefCounted) -> void:
	world = w


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	_build_materials()
	_build_lake()
	_build_stream_and_pool()
	_build_waterfall()
	_sync_counts()
	print("WATER built in %d ms: lake=%d tris, stream+pool=%d tris, waterfall=%d tris (total %d tris, %d draws)" % [
		Time.get_ticks_msec() - t0, lake_tris, stream_tris, falls_tris, tris, last_draws])


func _build_materials() -> void:
	lake_mat = ShaderMaterial.new()
	lake_mat.shader = load("res://shaders/water_lake.gdshader")
	# Opaque no-discard material: render_priority = -1 ahead of discard surfaces for Apple TBDR HSR.
	lake_mat.render_priority = -1
	_bind_world_uniforms(lake_mat)

	stream_mat = ShaderMaterial.new()
	stream_mat.shader = load("res://shaders/water_stream.gdshader")
	stream_mat.render_priority = -1
	_bind_world_uniforms(stream_mat)

	falls_mat = ShaderMaterial.new()
	falls_mat.shader = load("res://shaders/water_waterfall.gdshader")
	# Cutout discard material: render_priority = 1 strictly after -1 opaque draws.
	falls_mat.render_priority = 1
	falls_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	falls_mat.set_shader_parameter("noise_tex", world.noise_tex)
	falls_mat.set_shader_parameter("water_level", world.water_level)

	var wf: Dictionary = world.waterfall_info()
	if not wf.is_empty():
		var pc: Array = wf.poolCenter
		var ip: Array = wf.impactPt
		stream_mat.set_shader_parameter("pool_center", Vector3(float(pc[0]), float(pc[1]), float(pc[2])))
		stream_mat.set_shader_parameter("impact_pt", Vector3(float(ip[0]), float(ip[1]), float(ip[2])))
		stream_mat.set_shader_parameter("pool_radius", 14.0)
		falls_mat.set_shader_parameter("drop_height", maxf(10.0, float(wf.yTop) - float(pc[1])))


func _bind_world_uniforms(m: ShaderMaterial) -> void:
	m.set_shader_parameter("sky_lut", world.sky_lut_tex)
	m.set_shader_parameter("noise_tex", world.noise_tex)
	m.set_shader_parameter("near_tex", world.texture("near"))
	m.set_shader_parameter("far_tex", world.texture("far"))
	m.set_shader_parameter("biome_tex", world.texture("biome"))
	m.set_shader_parameter("near_size", world.near_size)
	m.set_shader_parameter("near_min", world.near_min)
	m.set_shader_parameter("near_step", world.near_step)
	m.set_shader_parameter("far_size", world.far_size)
	m.set_shader_parameter("far_min", world.far_min)
	m.set_shader_parameter("far_step", world.far_step)
	m.set_shader_parameter("water_level", world.water_level)


func materials() -> Array[ShaderMaterial]:
	return [lake_mat, stream_mat, falls_mat]


func set_on(v: bool) -> void:
	_on = v
	visible = v
	_sync_counts()


func is_on() -> bool:
	return _on


func _sync_counts() -> void:
	tris = lake_tris + stream_tris + falls_tris
	if _on:
		last_tris = tris
		last_draws = (1 if lake_tris > 0 else 0) + (1 if stream_tris > 0 else 0) + (1 if falls_tris > 0 else 0)
	else:
		last_tris = 0
		last_draws = 0


# ---------- 1. Clipped Lake Mesh (opaque, 1 draw call) ----------
func _build_lake() -> void:
	var L: Dictionary = world.lake_info()
	if L.is_empty():
		return
	var lx := float(L.x)
	var lz := float(L.z)
	var rx := float(L.rx)
	var rz := float(L.rz)
	var wl: float = world.water_level
	var x0 := floorf((lx - rx * 1.7) / LAKE_CELL) * LAKE_CELL
	var z0 := floorf((lz - rz * 1.7) / LAKE_CELL) * LAKE_CELL
	var nx := int(ceilf((rx * 3.4) / LAKE_CELL)) + 1
	var nz := int(ceilf((rz * 3.4) / LAKE_CELL)) + 1

	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	var vmap := {}
	var vid := func(ix: int, iz: int) -> int:
		var key := iz * 10000 + ix
		if vmap.has(key):
			return int(vmap[key])
		var id := verts.size()
		vmap[key] = id
		verts.append(Vector3(x0 + float(ix) * LAKE_CELL, wl, z0 + float(iz) * LAKE_CELL))
		return id

	for iz in nz:
		var cz := z0 + float(iz) * LAKE_CELL
		for ix in nx:
			var cx := x0 + float(ix) * LAKE_CELL
			var wet := false
			for sy in 5:
				var sz := cz + LAKE_CELL * (float(sy) * 0.25)
				for sx in 5:
					if world.height_near(cx + LAKE_CELL * (float(sx) * 0.25), sz) <= wl + LAKE_WET_MARGIN:
						wet = true
						break
				if wet:
					break
			if not wet:
				continue
			var a: int = vid.call(ix, iz)
			var b: int = vid.call(ix + 1, iz)
			var c: int = vid.call(ix, iz + 1)
			var d: int = vid.call(ix + 1, iz + 1)
			# Clockwise viewed from +Y (Godot front face).
			idx.append_array([a, b, d, a, d, c])

	if idx.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, lake_mat)
	lake_mi = MeshInstance3D.new()
	lake_mi.name = "lake"
	lake_mi.mesh = mesh
	lake_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(lake_mi)
	lake_tris = idx.size() / 3


# ---------- 2. Stream Ribbon + Plunge Pool (opaque, 1 draw call) ----------
func _build_stream_and_pool() -> void:
	var pts: PackedVector2Array = world.stream_points()
	if pts.size() < 4:
		return
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var idx := PackedInt32Array()

	var wf: Dictionary = world.waterfall_info()
	var brink: int = world.stream_brink()
	var has_wf := not wf.is_empty()
	var pool_c := Vector3.ZERO
	var wf_u := Vector2.RIGHT
	var pool_y := 0.0
	var foot_idx := -1
	if has_wf:
		var pc: Array = wf.poolCenter
		pool_c = Vector3(float(pc[0]), float(pc[1]), float(pc[2]))
		# Seat plunge pool snugly inside the carved basin so its downstream lip flows flush into
		# the carved stream channel without forming a raised wall.
		pool_y = minf(pool_c.y, world.height_near(pool_c.x, pool_c.z) + 0.95)
		wf_u = Vector2(float(wf.ux), float(wf.uz)).normalized()
		foot_idx = int(wf.footIdx)

	# Stream ribbon segments: upstream (0 .. brink - 2) and downstream (pool outflow .. lake mouth).
	var segments: Array[Vector2i] = []
	if has_wf and brink > 4:
		segments.append(Vector2i(0, maxi(1, brink - 2)))
		var down_start := mini(pts.size() - 2, maxi(brink + 10, foot_idx + 4))
		segments.append(Vector2i(down_start, pts.size() - 1))
	else:
		segments.append(Vector2i(0, pts.size() - 1))

	var n := pts.size()
	var wl: float = world.water_level
	const CROSS: Array[float] = [-1.0, -0.58, 0.0, 0.58, 1.0]

	var dist_acc := 0.0
	var prev_pt := pts[0]
	for seg in segments:
		var seg_base := verts.size()
		var rows := 0
		for i in range(seg.x, seg.y + 1):
			var p := pts[i]
			if i > 0:
				dist_acc += p.distance_to(prev_pt)
			prev_pt = p
			var j := mini(n - 1, i + 1)
			var k := maxi(0, i - 1)
			var tangent := pts[j] - pts[k]
			var tl := maxf(tangent.length(), 1e-4)
			var sx := -tangent.y / tl
			var sz := tangent.x / tl
			var h_k: float = world.height_near(pts[k].x, pts[k].y)
			var h_j: float = world.height_near(pts[j].x, pts[j].y)
			var grade := maxf(0.0, (h_k - h_j) / tl)
			var steep := clampf(grade * 1.6, 0.0, 1.0)
			var frac := float(i) / float(n)
			var w := (2.2 + 1.6 * frac + minf(2.2, grade * 3.0)) * (0.88 + 0.24 * (sin(float(i) * 0.08) * 0.5 + 0.5))

			var hc: float = world.height_near(p.x, p.y)
			var y_center := hc + 0.38
			# Blend smoothly out of the plunge pool over the outflow threshold.
			if has_wf and i >= foot_idx:
				var dp := Vector2(p.x - pool_c.x, p.y - pool_c.z).length()
				if dp < 14.0:
					var bk := clampf((14.0 - dp) / 6.0, 0.0, 1.0)
					y_center = lerpf(y_center, pool_y, bk * bk * (3.0 - 2.0 * bk))
			# Glide gently under the lake plane at the mouth so there is zero z-fighting or step.
			if hc < wl + 0.45:
				var lake_t := clampf((wl + 0.45 - hc) / 0.9, 0.0, 1.0)
				y_center = lerpf(y_center, wl - 0.06, lake_t)

			var y_row: Array[float] = [0.0, 0.0, y_center, 0.0, 0.0]
			for ci in [1, 3]:
				var s: float = CROSS[ci]
				var px := p.x + sx * w * s
				var pz := p.y + sz * w * s
				var gh: float = world.height_near(px, pz)
				# Stay flat into rising banks; cap slightly above downhill banks to prevent vertical walls.
				y_row[ci] = minf(y_center, gh + 0.38)
			for ci in [0, 4]:
				var s: float = CROSS[ci]
				var inner_y: float = y_row[1] if ci == 0 else y_row[3]
				var px := p.x + sx * w * s
				var pz := p.y + sz * w * s
				var gh: float = world.height_near(px, pz)
				# Tuck outer skirt below terrain so opaque depth-test cuts a clean bank line.
				y_row[ci] = minf(inner_y - 0.05, gh - 0.32)

			for ci in 5:
				var s: float = CROSS[ci]
				var px := p.x + sx * w * s
				var pz := p.y + sz * w * s
				verts.append(Vector3(px, y_row[ci], pz))
				uvs.append(Vector2(s, dist_acc))
				uv2s.append(Vector2(steep, 0.0))
			if rows > 0:
				var b0 := seg_base + (rows - 1) * 5
				var b1 := seg_base + rows * 5
				for c in 4:
					# Clockwise viewed from +Y: +row is tangent (e.g. +X), +col is side (+Z).
					idx.append_array([b0 + c, b1 + c, b0 + c + 1, b0 + c + 1, b1 + c, b1 + c + 1])
			rows += 1

	# Plunge pool disc at waterfall base (merged into same opaque draw call, UV2.y = 1.0).
	if has_wf:
		var rings := 5
		var segs := 32
		var pool_r := 14.0
		var center_i := verts.size()
		verts.append(Vector3(pool_c.x, pool_y, pool_c.z))
		uvs.append(Vector2(0.0, 0.0))
		uv2s.append(Vector2(0.0, 1.0))
		for r_i in range(1, rings + 1):
			var rn := float(r_i) / float(rings)
			var rad := pool_r * rn
			for s_i in segs:
				var ang := float(s_i) / float(segs) * TAU
				var dx := cos(ang)
				var dz := sin(ang)
				var px := pool_c.x + dx * rad
				var pz := pool_c.z + dz * rad
				var gh: float = world.height_near(px, pz)
				var down_k := clampf(dx * wf_u.x + dz * wf_u.y, 0.0, 1.0)
				var py := pool_y
				# Downstream outflow slopes smoothly into the carved river channel (never a dam wall).
				if down_k > 0.20 and rn > 0.45:
					var out_t := clampf((rn - 0.45) / 0.55, 0.0, 1.0) * smoothstep(0.20, 0.78, down_k)
					py = lerpf(pool_y, minf(pool_y, gh + 0.34), out_t)
				# Outer skirt tucks below terrain on flanks/back so nothing ever floats.
				if r_i == rings:
					py = minf(py, gh + 0.24) if down_k > 0.60 else minf(py, gh - 0.35)
				verts.append(Vector3(px, py, pz))
				uvs.append(Vector2(rn, 0.0))
				uv2s.append(Vector2(0.0, 1.0))
		# Inner fan (CW from +Y: angle goes from +X toward +Z which is CW when viewed from +Y).
		var ring0 := center_i + 1
		for s_i in segs:
			var nxt := (s_i + 1) % segs
			idx.append_array([center_i, ring0 + s_i, ring0 + nxt])
		for r_i in range(1, rings):
			var a0 := center_i + 1 + (r_i - 1) * segs
			var a1 := center_i + 1 + r_i * segs
			for s_i in segs:
				var nxt := (s_i + 1) % segs
				idx.append_array([a0 + s_i, a1 + s_i, a1 + nxt, a0 + s_i, a1 + nxt, a0 + nxt])

	if idx.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, stream_mat)
	stream_mi = MeshInstance3D.new()
	stream_mi.name = "stream_pool"
	stream_mi.mesh = mesh
	stream_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(stream_mi)
	stream_tris = idx.size() / 3


# ---------- 3. Waterfall Curtains + Base Splash Crown (cutout, 1 draw call) ----------
func _build_waterfall() -> void:
	var wf: Dictionary = world.waterfall_info()
	if wf.is_empty():
		return
	var bx := float(wf.bx)
	var bz := float(wf.bz)
	var ux := float(wf.ux)
	var uz := float(wf.uz)
	var lx := -uz
	var lz := ux
	var y_top := float(wf.yTop)
	var d_lip := float(wf.dLip)
	var d_toe := float(wf.dToe)
	var land_dist := float(wf.landDist)
	var pc: Array = wf.poolCenter
	var pool_y := minf(float(pc[1]), world.height_near(float(pc[0]), float(pc[2])) + 0.95)
	var ip: Array = wf.impactPt
	var imp_x := float(ip[0])
	var imp_z := float(ip[2])

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var idx := PackedInt32Array()

	var prof_h := func(d: float, lat: float) -> float:
		return world.height_near(bx + ux * d + lx * lat, bz + uz * d + lz * lat)

	var cliff_clear := func(y: float, lat: float) -> float:
		var max_d := d_lip - 1.0
		var d := d_lip - 2.0
		while d <= d_toe + 6.0:
			var hc: float = maxf(prof_h.call(d, lat), maxf(prof_h.call(d, lat - 2.5), prof_h.call(d, lat + 2.5)))
			if hc > y - 0.6:
				max_d = d
			d += 0.75
		return max_d

	# Three braided curtains seated cleanly inside the carved cliff notch (never poking above the skyline).
	var specs := [
		[minf(y_top - 2.2, float(prof_h.call(d_lip - 1.5, -2.4)) - 1.4), pool_y - 0.8, 11.0, -2.4, d_lip - 1.0, land_dist, 28, 14, 0.44],
		[minf(y_top - 2.4, float(prof_h.call(d_lip - 1.5, 2.6)) - 1.4), pool_y - 0.8, 4.6, 2.6, d_lip - 0.6, land_dist - 0.4, 24, 10, 0.58],
		[minf(y_top - 3.2, float(prof_h.call(d_lip - 1.5, 7.6)) - 1.8), pool_y - 0.8, 5.0, 7.6, d_lip + 0.2, land_dist - 0.6, 22, 10, 0.52],
	]
	for sp in specs:
		var yt: float = sp[0]
		var yb: float = sp[1]
		var width: float = sp[2]
		var lat_off: float = sp[3]
		var d_start: float = sp[4]
		var d_end: float = sp[5]
		var rows: int = int(sp[6])
		var cols: int = int(sp[7])
		var bounce_s: float = sp[8]
		var base_v := verts.size()
		for r in rows + 1:
			var s := float(r) / float(rows)
			var lip := minf(1.0, s / 0.22)
			var curl_back := pow(maxf(1.0 - lip, 0.0), 1.85) * 4.2
			var drop_frac := 0.06 * lip * lip * lip if lip < 1.0 else (0.06 + 0.94 * pow(maxf((s - 0.22) / 0.78, 0.0), 1.28))
			var y := yt - 0.15 * (1.0 - lip) - (yt - yb) * drop_frac
			var out_d := d_start - curl_back + (d_end - d_start) * (0.28 * lip + 0.72 * pow(maxf(s, 0.0), 0.86))
			var bd := (s - bounce_s) / 0.11
			var bounce := exp(-bd * bd) * 2.1 if bounce_s > 0.0 else 0.0
			out_d += bounce
			if s > 0.14:
				out_d = maxf(out_d, float(cliff_clear.call(y, lat_off)) + 1.6)
			var w := width * (0.58 + 0.66 * s + 0.16 * bounce)
			for c in cols + 1:
				var t := float(c) / float(cols) - 0.5
				var lip_curve := (1.0 - lip) * (0.25 * cos(t * PI) - 1.0)
				var braid := (cos(t * PI) * (1.25 + bounce * 0.75) + 0.35 * cos(t * PI * 5.0) + 0.16 * sin(t * PI * 9.0 + s * 4.0)) * (0.20 + 0.80 * lip)
				var px := bx + ux * (out_d + braid) + lx * (lat_off + t * w)
				var pz := bz + uz * (out_d + braid) + lz * (lat_off + t * w)
				var vy := y + lip_curve
				# Keep the top overflow lip strictly below the cliff crest directly behind it so
				# the cascade emerges from the rock notch and never pokes above the skyline.
				if s < 0.32:
					var cliff_crest: float = world.height_near(px - ux * 2.5, pz - uz * 2.5) - 1.2
					var clamp_k := 1.0 - smoothstep(0.14, 0.32, s)
					vy = lerpf(vy, minf(vy, cliff_crest), clamp_k)
				verts.append(Vector3(px, vy, pz))
				uvs.append(Vector2(t * 2.0, s))
				uv2s.append(Vector2(0.0, 0.0))
		for r in rows:
			for c in cols:
				var a := base_v + r * (cols + 1) + c
				var b := a + 1
				var cc := a + cols + 1
				var d := cc + 1
				idx.append_array([a, cc, b, b, cc, d])

	# Sculpted cel-shaded whitewater splash billows hugging the cascade impact (UV2.x = 1.0).
	var b_segs := 28
	for bs in [[8.8, 2.8, 3.2, 2.3, 0.4], [10.0, 3.8, 1.8, 1.4, 2.1]]:
		var rad_x: float = bs[0]
		var rad_z: float = bs[1]
		var h_min: float = bs[2]
		var h_amp: float = bs[3]
		var fwd_off: float = bs[4]
		var base_i := verts.size()
		for i in b_segs + 1:
			var f := float(i) / float(b_segs)
			var ang := (f - 0.5) * PI * 1.18
			var ox := sin(ang) * rad_x
			var oz := cos(ang) * rad_z
			var bx0 := imp_x + lx * ox + ux * (oz + fwd_off)
			var bz0 := imp_z + lz * ox + uz * (oz + fwd_off)
			var h_crest := h_min + cos(ang * 1.3) * h_amp + sin(f * PI * 11.0) * 0.65
			verts.append(Vector3(bx0, pool_y - 0.5, bz0))
			verts.append(Vector3(bx0 + ux * 1.5, pool_y + h_crest, bz0 + uz * 1.5))
			uvs.append(Vector2(f, 0.0))
			uvs.append(Vector2(f, 1.0))
			uv2s.append(Vector2(1.0, 0.0))
			uv2s.append(Vector2(1.0, 0.0))
			if i < b_segs:
				var b := base_i + i * 2
				idx.append_array([b, b + 1, b + 2, b + 1, b + 3, b + 2])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, falls_mat)
	falls_mi = MeshInstance3D.new()
	falls_mi.name = "waterfall"
	falls_mi.mesh = mesh
	falls_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(falls_mi)
	falls_tris = idx.size() / 3
