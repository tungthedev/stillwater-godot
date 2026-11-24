extends Node3D

# Slice W5: Painterly fauna — chunky grazing meadow sheep, soaring alpine birds & raptors,
# fluttering meadow butterflies, and twilight/night fireflies.
#
# Perf contract (iPhone 13 mini WebGL2):
#   - <= 4 draw calls in ANY view for all fauna combined (typically 1-3 draws):
#       1. Sheep herd (32 chunky sculpted sheep, 1 SwapMultiMesh, culled past 320 m -> 0 draws in forest/waterfall)
#       2. Soaring birds + valley raptors (38 birds, 456 tris, 1 SwapMultiMesh, hidden at night)
#       3. Meadow butterflies (48 butterflies, 288 tris, 1 SwapMultiMesh, hidden at dusk/night)
#       4. Fireflies (72 fireflies, 144 tris, 1 SwapMultiMesh, 0 draws at noon!)
#   - 100% vertex-shader animated via TIME (zero per-frame skeletons, zero per-instance GDScript).
#   - Sheep distance cull runs only when camera moves >= CULL_STEP m (0.000 ms stationary GDScript).

const SwapMultiMesh := preload("res://systems/swap_multimesh.gd")

const CULL_STEP := 6.0
const SHEEP_DIST := 320.0
const CULL_PAD := 20.0
const BIRD_COUNT := 38
const BUTTERFLY_COUNT := 48
const FIREFLY_COUNT := 72

var world: RefCounted
var sheep_mat: ShaderMaterial
var bird_mat: ShaderMaterial
var butterfly_mat: ShaderMaterial
var firefly_mat: ShaderMaterial

var _sheep_swap: RefCounted
var _bird_swap: RefCounted
var _butterfly_swap: RefCounted
var _firefly_swap: RefCounted

var _sheep_buf := PackedFloat32Array()
var _sheep_list: Array = []
var _sheep_tris := 0
var _sheep_vis := 0
var _sheep_aabb := AABB()

var _bird_tris := 0
var _bird_aabb := AABB()
var _butterfly_tris := 0
var _firefly_tris := 2

var _night_weight := 0.0
var _night_glow := 0.0
var _birds_vis := true
var _butterflies_vis := true
var _fireflies_vis := false

var _cull_pos := Vector3(1e9, 0.0, 1e9)
var _dist_scale := 1.0
var _dirty := true
var _on := true
var frozen := false

var last_draws := 0
var last_tris := 0
var load_ms := 0
var prof_us := 0


func setup(w: RefCounted) -> void:
	world = w


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	process_priority = 100
	_build_materials()
	_build_sheep()
	_build_birds()
	_build_butterflies()
	_build_fireflies()
	_sync_visibility()
	load_ms = Time.get_ticks_msec() - t0
	print("FAUNA built in %d ms: sheep=%d (%d tris/ea), birds=%d (%d tris), butterflies=%d (%d tris), fireflies=%d" % [
		load_ms, _sheep_list.size(), _sheep_tris, BIRD_COUNT, BIRD_COUNT * _bird_tris,
		BUTTERFLY_COUNT, BUTTERFLY_COUNT * _butterfly_tris, FIREFLY_COUNT])


func materials() -> Array[ShaderMaterial]:
	return [sheep_mat, bird_mat, butterfly_mat, firefly_mat]


func apply_tod(env_sys: Node) -> void:
	if env_sys == null:
		return
	_night_weight = float(env_sys.night_weight)
	_night_glow = float(env_sys.night_glow)
	# Birds & butterflies rest at night (0 draws); fireflies awaken at dusk/night (0 draws at noon!).
	_birds_vis = _night_weight < 0.72
	_butterflies_vis = float(env_sys.sun_disc_vis) > 0.25 and _night_weight < 0.25
	var ff_k := clampf((_night_glow - 0.30) / 0.55, 0.0, 1.0)
	_fireflies_vis = ff_k > 0.02
	if firefly_mat != null:
		firefly_mat.set_shader_parameter("firefly_strength", ff_k)
	_sync_visibility()


func set_on(v: bool) -> void:
	_on = v
	visible = v
	_sync_visibility()
	if not v:
		last_draws = 0
		last_tris = 0
	else:
		_dirty = true


func is_on() -> bool:
	return _on


func set_frozen(v: bool) -> void:
	frozen = v


func set_dist_scale(s: float) -> void:
	var clamped := clampf(s, 0.35, 1.0)
	if absf(clamped - _dist_scale) < 1e-4:
		return
	_dist_scale = clamped
	_dirty = true


func _sync_visibility() -> void:
	if _sheep_swap != null:
		_sheep_swap.set_visible(_on and _sheep_vis > 0)
	if _bird_swap != null:
		_bird_swap.set_visible(_on and _birds_vis)
	if _butterfly_swap != null:
		_butterfly_swap.set_visible(_on and _butterflies_vis)
	if _firefly_swap != null:
		_firefly_swap.set_visible(_on and _fireflies_vis)


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	if not frozen and _on:
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			update_cull(cam, false)
	prof_us = Time.get_ticks_usec() - t0


func update_cull(cam: Camera3D, force: bool = false) -> void:
	if not _on:
		return
	var cp := cam.global_position
	if not force and not _dirty and cp.distance_squared_to(_cull_pos) < CULL_STEP * CULL_STEP:
		return
	_cull_pos = cp
	_dirty = false
	_cull_sheep(cp)


func count_drawn(cam: Camera3D) -> void:
	if not _on:
		last_draws = 0
		last_tris = 0
		return
	var planes := cam.get_frustum()
	var draws := 0
	var tris := 0
	if _sheep_vis > 0 and _aabb_in_frustum(_sheep_aabb, planes):
		draws += 1
		tris += _sheep_vis * _sheep_tris
	if _birds_vis and _aabb_in_frustum(_bird_aabb, planes):
		draws += 1
		tris += BIRD_COUNT * _bird_tris
	if _butterflies_vis:
		draws += 1
		tris += BUTTERFLY_COUNT * _butterfly_tris
	if _fireflies_vis:
		draws += 1
		tris += FIREFLY_COUNT * _firefly_tris
	last_draws = draws
	last_tris = tris


static func _aabb_in_frustum(aabb: AABB, planes: Array[Plane]) -> bool:
	var p0 := aabb.position
	var p1 := aabb.position + aabb.size
	for pl in planes:
		var n := pl.normal
		var px := p0.x if n.x >= 0.0 else p1.x
		var py := p0.y if n.y >= 0.0 else p1.y
		var pz := p0.z if n.z >= 0.0 else p1.z
		if pl.distance_to(Vector3(px, py, pz)) > 0.0:
			return false
	return true


# Player collision against grazing sheep (matching animals.js Herd.collide).
func collide(pos: Vector2, _ground_y: float) -> Vector2:
	const PLAYER_R := 0.35
	for e in _sheep_list:
		var sx := float(e[0])
		var sz := float(e[2])
		var rr := 0.55 * float(e[12]) + PLAYER_R
		var dx := pos.x - sx
		var dz := pos.y - sz
		if absf(dx) > rr or absf(dz) > rr:
			continue
		var d2 := dx * dx + dz * dz
		if d2 < rr * rr and d2 > 1e-8:
			var inv_d := rr / sqrt(d2)
			pos = Vector2(sx + dx * inv_d, sz + dz * inv_d)
	return pos


func _build_materials() -> void:
	sheep_mat = ShaderMaterial.new()
	sheep_mat.shader = load("res://shaders/sheep_painted.gdshader")
	sheep_mat.render_priority = -1
	sheep_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	sheep_mat.set_shader_parameter("noise_tex", world.noise_tex)
	sheep_mat.set_shader_parameter("water_level", world.water_level)

	bird_mat = ShaderMaterial.new()
	bird_mat.shader = load("res://shaders/bird_painted.gdshader")
	bird_mat.render_priority = -1
	bird_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	bird_mat.set_shader_parameter("noise_tex", world.noise_tex)
	bird_mat.set_shader_parameter("water_level", world.water_level)

	butterfly_mat = ShaderMaterial.new()
	butterfly_mat.shader = load("res://shaders/butterfly_painted.gdshader")
	butterfly_mat.render_priority = -1
	butterfly_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	butterfly_mat.set_shader_parameter("noise_tex", world.noise_tex)
	butterfly_mat.set_shader_parameter("near_tex", world.texture("near"))
	butterfly_mat.set_shader_parameter("biome_tex", world.texture("biome"))
	butterfly_mat.set_shader_parameter("near_size", world.near_size)
	butterfly_mat.set_shader_parameter("near_min", world.near_min)
	butterfly_mat.set_shader_parameter("near_step", world.near_step)
	butterfly_mat.set_shader_parameter("water_level", world.water_level)

	firefly_mat = ShaderMaterial.new()
	firefly_mat.shader = load("res://shaders/firefly.gdshader")
	firefly_mat.render_priority = 3
	firefly_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	firefly_mat.set_shader_parameter("noise_tex", world.noise_tex)
	firefly_mat.set_shader_parameter("near_tex", world.texture("near"))
	firefly_mat.set_shader_parameter("near_size", world.near_size)
	firefly_mat.set_shader_parameter("near_min", world.near_min)
	firefly_mat.set_shader_parameter("near_step", world.near_step)
	firefly_mat.set_shader_parameter("water_level", world.water_level)
	firefly_mat.set_shader_parameter("firefly_strength", 0.0)


# ---------- 1. Chunky Painted Sheep (1 SwapMultiMesh, ~320 tris/sheep) ----------
func _build_sheep() -> void:
	var finfo: Dictionary = world.fauna_info()
	if not finfo.has("sheep"):
		return
	var slist: Array = finfo.sheep
	if slist.is_empty():
		return
	for s in slist:
		var x := float(s[0])
		var y := float(s[1])
		var z := float(s[2])
		var yaw := float(s[3])
		var pitch := float(s[4])
		var roll := float(s[5])
		var sx := float(s[6])
		var sy := float(s[7])
		var sz := float(s[8])
		var graze := float(s[9])
		var walk := float(s[10])
		var phase := float(s[11])
		var coat := float(s[12])
		var b := Basis.from_euler(Vector3(pitch, yaw, roll), EULER_ORDER_YXZ).scaled(Vector3(sx, sy, sz))
		_sheep_list.append([
			x, y, z,
			b.x.x, b.y.x, b.z.x,
			b.x.y, b.y.y, b.z.y,
			b.x.z, b.y.z, b.z.z,
			sy, graze, walk, phase, coat,
		])
	var mesh := _build_sheep_mesh()
	var cap := maxi(1, _sheep_list.size())
	_sheep_buf.resize(cap * 16)
	var big := AABB(Vector3(-2500, -200, -2500), Vector3(5000, 2000, 5000))
	_sheep_swap = SwapMultiMesh.new(self, mesh, cap, big)
	_sheep_swap.set_visible(false)


func _cull_sheep(cp: Vector3) -> void:
	if _sheep_swap == null or _sheep_list.is_empty():
		return
	var vis := 0
	var aabb := AABB()
	var has_box := false
	var max_d := SHEEP_DIST * _dist_scale + CULL_PAD
	var max_d2 := max_d * max_d
	for e in _sheep_list:
		var ex := float(e[0])
		var ey := float(e[1])
		var ez := float(e[2])
		var dx := ex - cp.x
		var dy := ey - cp.y
		var dz := ez - cp.z
		if dx * dx + dy * dy + dz * dz > max_d2:
			continue
		var o := vis * 16
		_sheep_buf[o + 0] = float(e[3]);  _sheep_buf[o + 1] = float(e[4]);  _sheep_buf[o + 2] = float(e[5]);  _sheep_buf[o + 3] = ex
		_sheep_buf[o + 4] = float(e[6]);  _sheep_buf[o + 5] = float(e[7]);  _sheep_buf[o + 6] = float(e[8]);  _sheep_buf[o + 7] = ey
		_sheep_buf[o + 8] = float(e[9]);  _sheep_buf[o + 9] = float(e[10]); _sheep_buf[o + 10] = float(e[11]); _sheep_buf[o + 11] = ez
		_sheep_buf[o + 12] = float(e[13]) # graze
		_sheep_buf[o + 13] = float(e[14]) # walk
		_sheep_buf[o + 14] = float(e[15]) # phase
		_sheep_buf[o + 15] = float(e[16]) # coat_idx
		var r := float(e[12]) * 1.4
		var b := AABB(Vector3(ex - r, ey - 0.3, ez - r), Vector3(r * 2.0, r * 2.2, r * 2.0))
		aabb = b if not has_box else aabb.merge(b)
		has_box = true
		vis += 1
	_sheep_vis = vis
	_sheep_aabb = aabb
	if vis > 0:
		_sheep_swap.push(_sheep_buf, vis)
		_sheep_swap.set_visible(_on)
		for mmi: MultiMeshInstance3D in _sheep_swap.mmis:
			mmi.custom_aabb = aabb
	else:
		_sheep_swap.set_visible(false)


func _build_sheep_mesh() -> ArrayMesh:
	var mb := _MB.new()
	var WOOL := Color(0.95, 0.93, 0.87)
	var WOOL_HI := Color(0.99, 0.98, 0.94)
	var WOOL_SH := Color(0.84, 0.81, 0.75)
	var FACE := Color(0.18, 0.16, 0.15)
	var MUZZLE := Color(0.26, 0.22, 0.20)
	var EAR := Color(0.21, 0.18, 0.17)
	var LEG := Color(0.20, 0.18, 0.17)
	var HOOF := Color(0.11, 0.10, 0.09)
	var EYE := Color(0.98, 0.98, 0.95)

	# Chunky cloud-like wool torso built from smooth-shaded overlapping rounded icosphere puffs (part = 0).
	mb.ico_smooth(Vector3(0.0, 0.72, 0.0), Vector3(0.44, 0.36, 0.58), WOOL, 0.0)
	mb.ico_smooth(Vector3(0.0, 0.86, 0.06), Vector3(0.36, 0.24, 0.42), WOOL_HI, 0.0)
	mb.ico_smooth(Vector3(0.22, 0.74, 0.12), Vector3(0.26, 0.24, 0.30), WOOL, 0.0)
	mb.ico_smooth(Vector3(-0.22, 0.74, 0.12), Vector3(0.26, 0.24, 0.30), WOOL, 0.0)
	mb.ico_smooth(Vector3(0.20, 0.70, -0.22), Vector3(0.25, 0.24, 0.28), WOOL_SH, 0.0)
	mb.ico_smooth(Vector3(-0.20, 0.70, -0.22), Vector3(0.25, 0.24, 0.28), WOOL_SH, 0.0)
	mb.ico_smooth(Vector3(0.0, 0.80, 0.34), Vector3(0.26, 0.24, 0.24), WOOL_HI, 0.0) # fluffy chest/neck ruff
	mb.ico_smooth(Vector3(0.0, 0.68, -0.38), Vector3(0.32, 0.28, 0.26), WOOL, 0.0)    # rump puff

	# Head, fluffy wool forelock, tapered muzzle, floppy ears & bright eye dots (part = 1).
	mb.ico_smooth(Vector3(0.0, 0.84, 0.60), Vector3(0.17, 0.18, 0.24), FACE, 1.0)
	mb.ico_smooth(Vector3(0.0, 0.77, 0.76), Vector3(0.11, 0.11, 0.15), MUZZLE, 1.0)
	mb.ico_smooth(Vector3(0.0, 0.99, 0.56), Vector3(0.15, 0.11, 0.16), WOOL_HI, 1.0)  # wool crown tuft
	for s: float in [-1.0, 1.0]:
		mb.box(Vector3(0.18, 0.06, 0.10), Vector3(s * 0.20, 0.86, 0.55), Vector3(0.0, -s * 0.22, -s * 0.42), EAR, 1.0)
		mb.box(Vector3(0.045, 0.045, 0.045), Vector3(s * 0.135, 0.88, 0.68), Vector3.ZERO, EYE, 1.0)

	# 4 sturdy tapered charcoal legs extending slightly below y=0 (y=-0.06) so hooves never float on slopes (part = 2).
	for lx: float in [-0.21, 0.21]:
		for lz: float in [-0.30, 0.28]:
			mb.cyl(0.068, 0.052, 0.52, 6, Vector3(lx, 0.24, lz), Vector3.ZERO, LEG, 2.0)
			mb.cyl(0.056, 0.062, 0.10, 6, Vector3(lx, 0.01, lz), Vector3.ZERO, HOOF, 2.0)

	# Stubby wool bobtail (part = 3).
	mb.ico(Vector3(0.0, 0.68, -0.58), Vector3(0.11, 0.11, 0.14), WOOL_HI, 3.0)

	_sheep_tris = mb.tri_count
	return mb.finish(sheep_mat)


# ---------- 2. Soaring Alpine Birds & Raptors (1 SwapMultiMesh, 456 tris, 0 GDScript) ----------
func _build_birds() -> void:
	var mesh := _build_bird_mesh()
	var finfo: Dictionary = world.fauna_info()
	var pinfo: Dictionary = world.props_info()
	var lake: Dictionary = world.lake_info()

	# Anchor flocks above the trailhead/cottage, open meadow, pasture, lake basin, and waterfall valley.
	var anchors: Array[Vector3] = []
	if pinfo.has("house"):
		var H: Dictionary = pinfo.house
		anchors.append(Vector3(float(H.x) - 18.0, float(H.y) + 22.0, float(H.z) - 24.0))
	if world.has_pose("meadow"):
		var mp: Array = world.pose("meadow").position
		anchors.append(Vector3(float(mp[0]) - 28.0, float(mp[1]) + 15.0, float(mp[2]) - 36.0))
	if finfo.has("sheep") and not finfo.sheep.is_empty():
		var sh0: Array = finfo.sheep[0]
		anchors.append(Vector3(float(sh0[0]), float(sh0[1]) + 20.0, float(sh0[2])))
	if not lake.is_empty():
		anchors.append(Vector3(float(lake.x), world.water_level + 34.0, float(lake.z)))
	var wf: Dictionary = world.waterfall_info()
	if not wf.is_empty():
		var pc: Array = wf.poolCenter
		anchors.append(Vector3(float(pc[0]), float(pc[1]) + 40.0, float(pc[2])))
	if anchors.is_empty():
		anchors.append(Vector3(0.0, 80.0, 0.0))

	var rng := RandomNumberGenerator.new()
	rng.seed = 909
	var buf := PackedFloat32Array()
	buf.resize(BIRD_COUNT * 16)
	var aabb := AABB()
	var has_aabb := false
	for i in BIRD_COUNT:
		var is_raptor := i >= BIRD_COUNT - 2
		var base_c: Vector3 = anchors[i % anchors.size()]
		var cx := base_c.x + (rng.randf() - 0.5) * (90.0 if is_raptor else 65.0)
		var cy := base_c.y + (26.0 if is_raptor else (rng.randf() - 0.3) * 18.0)
		var cz := base_c.z + (rng.randf() - 0.5) * (90.0 if is_raptor else 65.0)
		var rx := (75.0 + rng.randf() * 45.0) if is_raptor else (22.0 + rng.randf() * 34.0)
		var rz := (60.0 + rng.randf() * 40.0) if is_raptor else (18.0 + rng.randf() * 28.0)
		var y_amp := 4.5 if is_raptor else (1.8 + rng.randf() * 3.2)
		var speed := (0.11 + rng.randf() * 0.04) if is_raptor else (0.24 + rng.randf() * 0.16)
		if i % 2 == 1:
			speed = -speed
		var tilt := rng.randf() * TAU
		var sc := (1.85 + rng.randf() * 0.35) if is_raptor else (0.72 + rng.randf() * 0.34)
		var phase := rng.randf() * TAU
		var flap_f := (4.8 if is_raptor else (8.5 + rng.randf() * 3.2))
		var soar_r := (0.78 if is_raptor else 0.42)
		var o := i * 16
		buf[o + 0] = rx;    buf[o + 1] = speed; buf[o + 2] = tilt; buf[o + 3] = cx
		buf[o + 4] = y_amp; buf[o + 5] = rz;    buf[o + 6] = 0.0;  buf[o + 7] = cy
		buf[o + 8] = 0.0;   buf[o + 9] = 0.0;   buf[o + 10] = sc;  buf[o + 11] = cz
		buf[o + 12] = phase
		buf[o + 13] = flap_f
		buf[o + 14] = soar_r
		buf[o + 15] = 1.0 if is_raptor else 0.0
		var rmax := maxf(rx, rz) + 8.0
		var b := AABB(Vector3(cx - rmax, cy - y_amp - 6.0, cz - rmax), Vector3(rmax * 2.0, (y_amp + 6.0) * 2.0, rmax * 2.0))
		aabb = b if not has_aabb else aabb.merge(b)
		has_aabb = true
	_bird_aabb = aabb
	_bird_swap = SwapMultiMesh.new(self, mesh, BIRD_COUNT, aabb)
	_bird_swap.push(buf, BIRD_COUNT)


func _build_bird_mesh() -> ArrayMesh:
	var mb := _MB.new()
	var BODY := Color(0.18, 0.21, 0.28)
	var WING_IN := Color(0.20, 0.24, 0.33)
	var WING_TIP := Color(0.13, 0.15, 0.22)
	var TAIL := Color(0.16, 0.19, 0.25)

	# Sleek chunky gull/swift silhouette (12 triangles): diamond body, swept inner+outer wings, forked tail.
	# Body keel (+Z forward).
	mb.tri_double(Vector3(0.0, 0.04, 0.52), Vector3(-0.14, 0.0, 0.02), Vector3(0.14, 0.0, 0.02), Vector3.UP, BODY, 1.0)
	mb.tri_double(Vector3(0.0, 0.02, -0.45), Vector3(0.12, 0.0, 0.02), Vector3(-0.12, 0.0, 0.02), Vector3.UP, BODY, 1.0)
	# Inner & swept outer wings (left & right).
	for s: float in [-1.0, 1.0]:
		mb.tri_double(Vector3(s * 0.10, 0.02, 0.24), Vector3(s * 0.10, 0.0, -0.14), Vector3(s * 0.56, 0.05, 0.10), Vector3.UP, WING_IN, 1.0)
		mb.tri_double(Vector3(s * 0.10, 0.0, -0.14), Vector3(s * 0.52, 0.02, -0.16), Vector3(s * 0.56, 0.05, 0.10), Vector3.UP, WING_IN, 1.0)
		mb.tri_double(Vector3(s * 0.56, 0.05, 0.10), Vector3(s * 0.52, 0.02, -0.16), Vector3(s * 1.12, 0.01, -0.22), Vector3.UP, WING_TIP, 1.0)
	# Forked tail fan.
	mb.tri_double(Vector3(0.0, 0.02, -0.34), Vector3(-0.18, 0.01, -0.62), Vector3(0.0, 0.01, -0.50), Vector3.UP, TAIL, 1.0)
	mb.tri_double(Vector3(0.0, 0.02, -0.34), Vector3(0.0, 0.01, -0.50), Vector3(0.18, 0.01, -0.62), Vector3.UP, TAIL, 1.0)

	# Use single-sided mesh with cull_disabled in shader (divide count by 2: use push_single).
	_bird_tris = mb.tri_count
	return mb.finish(bird_mat)


# ---------- 3. Meadow Butterflies (1 SwapMultiMesh, 288 tris, 0 GDScript) ----------
func _build_butterflies() -> void:
	var mb := _MB.new()
	var BRIGHT := Color(1.0, 1.0, 1.0)
	var TIP := Color(0.84, 0.78, 0.72)
	var BODY := Color(0.18, 0.16, 0.15)
	# Sculpted forewing + hindwing pair per side + tiny thorax (6 triangles, single-sided w/ cull_disabled).
	for s: float in [-1.0, 1.0]:
		mb.tri_single(Vector3(0.0, 0.0, 0.25), Vector3(s * 0.95, 0.06, 0.65), Vector3(s * 0.78, 0.02, -0.12), Vector3.UP, BRIGHT, 1.0)
		mb.tri_single(Vector3(0.0, 0.0, 0.18), Vector3(s * 0.78, 0.02, -0.12), Vector3(0.0, 0.0, -0.35), Vector3.UP, BRIGHT, 1.0)
		mb.tri_single(Vector3(0.0, 0.0, -0.05), Vector3(s * 0.62, 0.01, -0.15), Vector3(s * 0.36, 0.0, -0.68), Vector3.UP, TIP, 1.0)
	_butterfly_tris = mb.tri_count
	var mesh := mb.finish(butterfly_mat)

	var huge := AABB(Vector3(-20000, -2000, -20000), Vector3(40000, 8000, 40000))
	_butterfly_swap = SwapMultiMesh.new(self, mesh, BUTTERFLY_COUNT, huge)
	var buf := PackedFloat32Array()
	buf.resize(BUTTERFLY_COUNT * 16)
	var rng := RandomNumberGenerator.new()
	rng.seed = 414
	for i in BUTTERFLY_COUNT:
		var o := i * 16
		buf[o + 0] = 1.0; buf[o + 1] = 0.0; buf[o + 2] = 0.0; buf[o + 3] = 0.0
		buf[o + 4] = 0.0; buf[o + 5] = 1.0; buf[o + 6] = 0.0; buf[o + 7] = 0.0
		buf[o + 8] = 0.0; buf[o + 9] = 0.0; buf[o + 10] = 1.0; buf[o + 11] = 0.0
		buf[o + 12] = rng.randf()
		buf[o + 13] = rng.randf()
		buf[o + 14] = rng.randf()
		buf[o + 15] = rng.randf()
	_butterfly_swap.push(buf, BUTTERFLY_COUNT)


# ---------- 4. Twilight & Night Fireflies (1 SwapMultiMesh, 144 tris, 0 draws at noon) ----------
func _build_fireflies() -> void:
	var pv := PackedVector3Array([
		Vector3(-1.0, -1.0, 0.0), Vector3(1.0, -1.0, 0.0),
		Vector3(-1.0, 1.0, 0.0), Vector3(1.0, 1.0, 0.0),
	])
	var idx := PackedInt32Array([0, 1, 2, 1, 3, 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pv
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, firefly_mat)

	var huge := AABB(Vector3(-20000, -2000, -20000), Vector3(40000, 8000, 40000))
	_firefly_swap = SwapMultiMesh.new(self, mesh, FIREFLY_COUNT, huge)
	var buf := PackedFloat32Array()
	buf.resize(FIREFLY_COUNT * 16)
	var rng := RandomNumberGenerator.new()
	rng.seed = 616
	for i in FIREFLY_COUNT:
		var o := i * 16
		buf[o + 0] = 1.0; buf[o + 1] = 0.0; buf[o + 2] = 0.0; buf[o + 3] = 0.0
		buf[o + 4] = 0.0; buf[o + 5] = 1.0; buf[o + 6] = 0.0; buf[o + 7] = 0.0
		buf[o + 8] = 0.0; buf[o + 9] = 0.0; buf[o + 10] = 1.0; buf[o + 11] = 0.0
		buf[o + 12] = rng.randf()
		buf[o + 13] = rng.randf()
		buf[o + 14] = rng.randf()
		buf[o + 15] = rng.randf()
	_firefly_swap.push(buf, FIREFLY_COUNT)
	_firefly_swap.set_visible(false)


# ---------- Compact winding-safe vertex-colored mesh builder (CUSTOM0 float RGBA) ----------
class _MB:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	var tri_count := 0

	func _push_tri(v0: Vector3, v1: Vector3, v2: Vector3, n: Vector3, c: Color) -> void:
		var wn := n.normalized() if n.length_squared() > 1e-8 else Vector3.UP
		var flip := (v2 - v0).cross(v1 - v0).dot(wn) < 0.0
		var base := pos.size()
		if flip:
			pos.append_array([v0, v2, v1])
		else:
			pos.append_array([v0, v1, v2])
		nrm.append_array([wn, wn, wn])
		col.append_array([c, c, c])
		idx.append_array([base, base + 1, base + 2])
		tri_count += 1

	func tri_single(v0: Vector3, v1: Vector3, v2: Vector3, n: Vector3, rgb: Color, a: float) -> void:
		_push_tri(v0, v1, v2, n, Color(rgb.r, rgb.g, rgb.b, a))

	func tri_double(v0: Vector3, v1: Vector3, v2: Vector3, n: Vector3, rgb: Color, a: float) -> void:
		# Single-sided emission for cull_disabled materials (half the triangle count!).
		_push_tri(v0, v1, v2, n, Color(rgb.r, rgb.g, rgb.b, a))

	func _push_quad(a: Vector3, b: Vector3, c_pt: Vector3, d: Vector3, n: Vector3, c: Color) -> void:
		_push_tri(a, b, c_pt, n, c)
		_push_tri(a, c_pt, d, n, c)

	func box(size: Vector3, center: Vector3, euler: Vector3, rgb: Color, part: float) -> void:
		var b := Basis.from_euler(euler, EULER_ORDER_YXZ)
		var hx := size.x * 0.5; var hy := size.y * 0.5; var hz := size.z * 0.5
		var c := Color(rgb.r, rgb.g, rgb.b, part)
		var p: Array[Vector3] = [
			center + b * Vector3(-hx, -hy, -hz), center + b * Vector3(hx, -hy, -hz),
			center + b * Vector3(hx, hy, -hz),   center + b * Vector3(-hx, hy, -hz),
			center + b * Vector3(-hx, -hy, hz),  center + b * Vector3(hx, -hy, hz),
			center + b * Vector3(hx, hy, hz),    center + b * Vector3(-hx, hy, hz),
		]
		var faces := [
			[4, 5, 6, 7, b * Vector3(0, 0, 1)], [1, 0, 3, 2, b * Vector3(0, 0, -1)],
			[5, 1, 2, 6, b * Vector3(1, 0, 0)], [0, 4, 7, 3, b * Vector3(-1, 0, 0)],
			[7, 6, 2, 3, b * Vector3(0, 1, 0)], [0, 1, 5, 4, b * Vector3(0, -1, 0)],
		]
		for f in faces:
			_push_quad(p[f[0]], p[f[1]], p[f[2]], p[f[3]], f[4], c)

	func cyl(r_top: float, r_bot: float, h: float, segs: int, center: Vector3, euler: Vector3, rgb: Color, part: float) -> void:
		var b := Basis.from_euler(euler, EULER_ORDER_YXZ)
		var hy := h * 0.5
		var c := Color(rgb.r, rgb.g, rgb.b, part)
		var top_c := center + b * Vector3(0.0, hy, 0.0)
		var bot_c := center + b * Vector3(0.0, -hy, 0.0)
		var nt := b * Vector3.UP
		var nb := b * Vector3.DOWN
		for i in segs:
			var a0 := float(i) / float(segs) * TAU
			var a1 := float(i + 1) / float(segs) * TAU
			var c0 := cos(a0); var s0 := sin(a0)
			var c1 := cos(a1); var s1 := sin(a1)
			var t0 := center + b * Vector3(c0 * r_top, hy, s0 * r_top)
			var t1 := center + b * Vector3(c1 * r_top, hy, s1 * r_top)
			var b0 := center + b * Vector3(c0 * r_bot, -hy, s0 * r_bot)
			var b1 := center + b * Vector3(c1 * r_bot, -hy, s1 * r_bot)
			var ns := (b * Vector3(c0 + c1, 0.0, s0 + s1)).normalized()
			_push_quad(b0, b1, t1, t0, ns, c)
			_push_tri(top_c, t0, t1, nt, c)
			_push_tri(bot_c, b1, b0, nb, c)

	func ico_smooth(center: Vector3, scale: Vector3, rgb: Color, part: float) -> void:
		var t := (1.0 + sqrt(5.0)) * 0.5
		var v: Array[Vector3] = [
			Vector3(-1, t, 0).normalized(), Vector3(1, t, 0).normalized(),
			Vector3(-1, -t, 0).normalized(), Vector3(1, -t, 0).normalized(),
			Vector3(0, -1, t).normalized(), Vector3(0, 1, t).normalized(),
			Vector3(0, -1, -t).normalized(), Vector3(0, 1, -t).normalized(),
			Vector3(t, 0, -1).normalized(), Vector3(t, 0, 1).normalized(),
			Vector3(-t, 0, -1).normalized(), Vector3(-t, 0, 1).normalized(),
		]
		var faces := [
			[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
			[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
			[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
			[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
		]
		var c := Color(rgb.r, rgb.g, rgb.b, part)
		for f in faces:
			var n0 := v[f[0]]
			var n1 := v[f[1]]
			var n2 := v[f[2]]
			var p0 := center + n0 * scale
			var p1 := center + n1 * scale
			var p2 := center + n2 * scale
			var fn := (n0 + n1 + n2).normalized()
			var flip := (p2 - p0).cross(p1 - p0).dot(fn) < 0.0
			var base := pos.size()
			if flip:
				pos.append_array([p0, p2, p1])
				nrm.append_array([n0, n2, n1])
			else:
				pos.append_array([p0, p1, p2])
				nrm.append_array([n0, n1, n2])
			col.append_array([c, c, c])
			idx.append_array([base, base + 1, base + 2])
			tri_count += 1

	func ico(center: Vector3, scale: Vector3, rgb: Color, part: float) -> void:
		var t := (1.0 + sqrt(5.0)) * 0.5
		var v: Array[Vector3] = [
			Vector3(-1, t, 0).normalized(), Vector3(1, t, 0).normalized(),
			Vector3(-1, -t, 0).normalized(), Vector3(1, -t, 0).normalized(),
			Vector3(0, -1, t).normalized(), Vector3(0, 1, t).normalized(),
			Vector3(0, -1, -t).normalized(), Vector3(0, 1, -t).normalized(),
			Vector3(t, 0, -1).normalized(), Vector3(t, 0, 1).normalized(),
			Vector3(-t, 0, -1).normalized(), Vector3(-t, 0, 1).normalized(),
		]
		var faces := [
			[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
			[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
			[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
			[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
		]
		var c := Color(rgb.r, rgb.g, rgb.b, part)
		for f in faces:
			var p0 := center + v[f[0]] * scale
			var p1 := center + v[f[1]] * scale
			var p2 := center + v[f[2]] * scale
			var fn := (v[f[0]] + v[f[1]] + v[f[2]]).normalized()
			_push_tri(p0, p1, p2, fn, c)

	func finish(mat: Material) -> ArrayMesh:
		var custom0 := PackedFloat32Array()
		custom0.resize(col.size() * 4)
		for i in col.size():
			var c := col[i]
			var o := i * 4
			custom0[o] = c.r
			custom0[o + 1] = c.g
			custom0[o + 2] = c.b
			custom0[o + 3] = c.a
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_NORMAL] = nrm
		arrays[Mesh.ARRAY_CUSTOM0] = custom0
		arrays[Mesh.ARRAY_INDEX] = idx
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		m.surface_set_material(0, mat)
		return m
