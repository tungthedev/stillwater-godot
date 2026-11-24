extends Node3D

# Stillwater's meadow grass and wildflowers at the `low` tier (src/world/grass.js,
# src/world/grassTiles.js, src/engine/quality.js).
#
# Same tile scheme as the game: a fixed world grid (grass 8 m, flowers 12 m tiles), the same
# per-plant scatter on every tile (world/veg_scatter.gd, bit-exact with Stillwater, mirrored per
# tile), and the tier draws the first N ranks. Every tile whose box touches the ring around the
# camera gets an atlas slot; its static per-blade fields (height, density, normal, tallness, yaw,
# colour) are baked once on the GPU when it enters, then the blade shaders read them per vertex.
# Grass tiles nearer than 16 m draw 1664 four-segment blades (7 triangles), the rest 1024
# two-segment ones (3 triangles, wider); near-only blades fade out before a tile switches.
#
# Godot difference: Stillwater draws one mesh per tile; here all near tiles are one instanced draw
# (a tile is an instance of a mesh holding all its blades), likewise far tiles and flowers, culled
# per tile on the CPU. Triangles are the same; draw calls drop from one per tile to three.
#
# The bake renders into a SubViewport (RGBA8; tests/bake_probe.gd checks the round trip is
# byte-exact). A tile is drawn from the frame after its bake.

const VegScatter := preload("res://world/veg_scatter.gd")
const SwapMultiMesh := preload("res://systems/swap_multimesh.gd")

# quality.js low: grassRadius 30, grassNear 1664, grassFar 1024, grassNearLod 16,
# grassFarWidthScale 1.32, flowers 576 (flower radius min(34, 0.75 * grassRadius)).
# Layouts (tile size, slot width, max count, seed) are grass.js GRASS_LAYOUT / FLOWER_LAYOUT.
const GRASS := {
	"tile": 8.0, "slot_w": 64, "max_count": 2432, "seed": 1337, "fields": 3,
	"radius": 30.0, "near": 1664, "far": 1024, "near_lod": 16.0, "far_width": 1.32,
	"near_tris": 7, "far_tris": 3, "verts_near": 9, "verts_far": 5,
	# Tile box padding (grass.js boundsPad) and the empty test: ground entirely under water - 1 m.
	"pad_xz": 1.8, "pad_down": 0.6, "pad_up": 2.5, "empty_below": -1.0,
}
const FLOWERS := {
	"tile": 12.0, "slot_w": 32, "max_count": 1440, "seed": 4242, "fields": 2,
	"radius": 22.5, "near": 576, "far": 576, "near_lod": INF, "far_width": 1.0,
	"near_tris": 4, "far_tris": 4,
	"pad_xz": 0.9, "pad_down": 0.5, "pad_up": 2.0, "empty_below": 0.2,
}
# Height in the atlas is 16 bits over 64 m above this much under the tile's lowest sample.
const BASE_DROP := 4.0

var world: RefCounted
var grass: Ring
var flowers: Ring
var _on := true
var _frame := 0
var last_tris := 0
var last_draws := 0
var density := 1.0
var prof_us := 0
var push_us := 0


func setup(w: RefCounted) -> void:
	world = w


func _ready() -> void:
	process_priority = 100
	var t0 := Time.get_ticks_msec()
	grass = Ring.new(self, GRASS, "res://shaders/grass_bake.gdshader", "res://shaders/grass.gdshader", _grass_meshes())
	grass.draw_mat.set_shader_parameter("lod_start", maxf(8.0, GRASS.near_lod - 6.0))
	grass.draw_mat.set_shader_parameter("lod_end", GRASS.near_lod)
	grass.draw_mat.set_shader_parameter("far_count", float(GRASS.far))
	grass.draw_mat.set_shader_parameter("far_width_scale", GRASS.far_width)
	var fm := _flower_mesh()
	flowers = Ring.new(self, FLOWERS, "res://shaders/flower_bake.gdshader", "res://shaders/flower.gdshader", [fm, fm])
	print("GRASS built in %d ms: grass atlas %s, flower atlas %s" % [Time.get_ticks_msec() - t0, grass.vp.size, flowers.vp.size])


func materials() -> Array[ShaderMaterial]:
	return [grass.draw_mat, flowers.draw_mat]


# Density lever: every tile draws the first round(f * N) ranks, as a lower Stillwater tier does
# (grassNear / grassFar / flowers). The bake keeps all of the tier's ranks.
func set_density(f: float) -> void:
	if is_equal_approx(f, density):
		return
	density = f
	var sc: Dictionary = VegScatter.generate(GRASS.max_count, GRASS.tile, GRASS.seed)
	var n_near := maxi(1, roundi(GRASS.near * f))
	var n_far := maxi(1, roundi(GRASS.far * f))
	grass.set_meshes(_blade_mesh(sc, n_near, 4), _blade_mesh(sc, n_far, 2), n_near, n_far)
	grass.draw_mat.set_shader_parameter("far_count", float(n_far))
	var fm := _flower_mesh(maxi(1, roundi(FLOWERS.near * f)))
	flowers.set_meshes(fm, fm, maxi(1, roundi(FLOWERS.near * f)), maxi(1, roundi(FLOWERS.far * f)))


func is_on() -> bool:
	return _on


func set_on(on: bool) -> void:
	_on = on
	for r in [grass, flowers]:
		r.draw_n.set_visible(on)
		r.draw_f.set_visible(on)
	if not on:
		last_tris = 0
		last_draws = 0


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	var cam := get_viewport().get_camera_3d()
	push_us = 0
	if _on and cam != null:
		_frame += 1
		update_rings(cam, false)
	prof_us = Time.get_ticks_usec() - t0


# assume_baked: count tiles as drawable without waiting for a bake (headless budget test).
func update_rings(cam: Camera3D, assume_baked: bool) -> void:
	var planes := cam.get_frustum()
	var p := cam.global_position
	var cxz := Vector2(p.x, p.z)
	# The walker stands under the camera, so blades part around the camera's feet as in the game.
	grass.draw_mat.set_shader_parameter("cam_xz", cxz)
	grass.draw_mat.set_shader_parameter("player_xz", cxz)
	flowers.draw_mat.set_shader_parameter("cam_xz", cxz)
	grass.update(p, planes, _frame, assume_baked)
	flowers.update(p, planes, _frame, assume_baked)
	last_tris = grass.last_tris + flowers.last_tris
	last_draws = grass.last_draws + flowers.last_draws
	push_us = grass.push_us + flowers.push_us


# Stillwater's bladeGeometry(segs) for every rank below `count`, merged into one tile mesh.
func _grass_meshes() -> Array[ArrayMesh]:
	var sc: Dictionary = VegScatter.generate(GRASS.max_count, GRASS.tile, GRASS.seed)
	return [_blade_mesh(sc, GRASS.near, 4), _blade_mesh(sc, GRASS.far, 2)]


func _blade_mesh(sc: Dictionary, count: int, segs: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	var idx := PackedInt32Array()
	var local: PackedFloat32Array = sc.local
	var rnd: PackedFloat32Array = sc.rnd
	var per := segs * 2 + 1
	for b in count:
		var base := b * per
		for i in segs:
			var y := float(i) / segs
			verts.append(Vector3(-0.5, y, 0.0))
			verts.append(Vector3(0.5, y, 0.0))
		verts.append(Vector3(0.0, 1.0, 0.0))
		for v in per:
			c0.append_array([local[b * 2], local[b * 2 + 1], float(b), 0.0])
			c1.append_array([rnd[b * 4], rnd[b * 4 + 1], rnd[b * 4 + 2], rnd[b * 4 + 3]])
		for i in segs - 1:
			var a := base + i * 2
			idx.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
		var t := base + (segs - 1) * 2
		idx.append_array([t, t + 1, base + segs * 2])
	return _mesh(verts, PackedVector2Array(), c0, c1, idx)


# Stillwater's flowerGeometry: a stem quad (part 0) and a head quad (part 1) per rank.
func _flower_mesh(count: int = FLOWERS.near) -> ArrayMesh:
	var sc: Dictionary = VegScatter.generate(FLOWERS.max_count, FLOWERS.tile, FLOWERS.seed)
	var local: PackedFloat32Array = sc.local
	var rnd: PackedFloat32Array = sc.rnd
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	var idx := PackedInt32Array()
	var quad_uv := [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]
	for b in count:
		var base := b * 8
		verts.append_array([Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(-0.5, 1, 0), Vector3(0.5, 1, 0)])
		verts.append_array([Vector3(-0.5, 1, -0.5), Vector3(0.5, 1, -0.5), Vector3(-0.5, 1, 0.5), Vector3(0.5, 1, 0.5)])
		for v in 8:
			uvs.append(quad_uv[v % 4])
			c0.append_array([local[b * 2], local[b * 2 + 1], float(b), 0.0 if v < 4 else 1.0])
			c1.append_array([rnd[b * 4], rnd[b * 4 + 1], rnd[b * 4 + 2], rnd[b * 4 + 3]])
		idx.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
		idx.append_array([base + 4, base + 6, base + 5, base + 5, base + 6, base + 7])
	return _mesh(verts, uvs, c0, c1, idx)


func _mesh(verts: PackedVector3Array, uvs: PackedVector2Array, c0: PackedFloat32Array, c1: PackedFloat32Array, idx: PackedInt32Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	if not uvs.is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_CUSTOM0] = c0
	arrays[Mesh.ARRAY_CUSTOM1] = c1
	arrays[Mesh.ARRAY_INDEX] = idx
	var fmt := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, fmt)
	# Blades are placed by the shader; tiles are culled on the CPU.
	mesh.custom_aabb = AABB(Vector3(-1.0e5, -1.0e4, -1.0e5), Vector3(2.0e5, 2.0e4, 2.0e5))
	return mesh


# One plant type: tile ring, atlas slots, bake viewport, near/far instanced draws.
class Ring:
	var cfg: Dictionary
	var world: RefCounted
	var tile: float
	var radius: float
	var cols := 0
	var rows := 0
	var capacity := 0
	var slot_h := 0
	var slots: Array[Dictionary] = []
	var by_key := {}
	var slot_img: Image
	var slot_tex: ImageTexture
	var slot_dirty_tex := false
	var vp: SubViewport
	var bake_mat: ShaderMaterial
	var draw_mat: ShaderMaterial
	var draw_n: SwapMultiMesh
	var draw_f: SwapMultiMesh
	var buf_near := PackedFloat32Array()
	var buf_far := PackedFloat32Array()
	var near_vis := 0
	var far_vis := 0
	var last_tris := 0
	var last_draws := 0
	var total_bakes := 0
	var draw_near := 0
	var draw_far := 0
	var push_us := 0

	func _init(owner: Node3D, c: Dictionary, bake_shader: String, draw_shader: String, meshes: Array) -> void:
		cfg = c
		draw_near = cfg.near
		draw_far = cfg.far
		world = owner.world
		tile = cfg.tile
		radius = cfg.radius
		_atlas_grid(1.3)
		slot_h = int(ceil(float(cfg.near) / cfg.slot_w))
		var sc: Dictionary = VegScatter.generate(cfg.max_count, tile, cfg.seed)
		var simg := Image.create(cfg.near, 2, false, Image.FORMAT_RGBAF)
		var local: PackedFloat32Array = sc.local
		var rnd: PackedFloat32Array = sc.rnd
		for i in int(cfg.near):
			simg.set_pixel(i, 0, Color(local[i * 2], local[i * 2 + 1], 0.0, 0.0))
			simg.set_pixel(i, 1, Color(rnd[i * 4], rnd[i * 4 + 1], rnd[i * 4 + 2], rnd[i * 4 + 3]))
		slot_img = Image.create(capacity, 1, false, Image.FORMAT_RGBAF)
		slot_tex = ImageTexture.create_from_image(slot_img)
		for s in capacity:
			slots.append({"i": s, "key": null, "sx": (s % cols) * int(cfg.slot_w) * int(cfg.fields), "sy": (s / cols) * slot_h,
				"ox": 0.0, "oz": 0.0, "flips": 0, "base": 0.0, "box": AABB(), "empty": false,
				"baking": false, "bake_frame": 0, "ready": false})

		vp = SubViewport.new()
		vp.size = Vector2i(cols * int(cfg.slot_w) * int(cfg.fields), rows * slot_h)
		vp.transparent_bg = true
		vp.disable_3d = true
		vp.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var rect := ColorRect.new()
		rect.size = Vector2(vp.size)
		bake_mat = ShaderMaterial.new()
		bake_mat.shader = load(bake_shader)
		for k in ["near", "far", "biome"]:
			bake_mat.set_shader_parameter(k + "_tex", world.texture(k))
		bake_mat.set_shader_parameter("noise_tex", world.noise_tex)
		for k in ["near_size", "near_min", "near_step", "far_size", "far_min", "far_step", "water_level"]:
			bake_mat.set_shader_parameter(k, world.get(k))
		bake_mat.set_shader_parameter("slot_tex", slot_tex)
		bake_mat.set_shader_parameter("scatter_tex", ImageTexture.create_from_image(simg))
		bake_mat.set_shader_parameter("slot_cols", cols)
		bake_mat.set_shader_parameter("slot_w", int(cfg.slot_w))
		bake_mat.set_shader_parameter("slot_h", slot_h)
		bake_mat.set_shader_parameter("fields", int(cfg.fields))
		bake_mat.set_shader_parameter("tile_size", tile)
		rect.material = bake_mat
		vp.add_child(rect)
		owner.add_child(vp)

		draw_mat = ShaderMaterial.new()
		draw_mat.shader = load(draw_shader)
		draw_mat.set_shader_parameter("atlas", vp.get_texture())
		draw_mat.set_shader_parameter("noise_tex", world.noise_tex)
		draw_mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
		draw_mat.set_shader_parameter("water_level", world.water_level)
		draw_mat.set_shader_parameter("tile_size", tile)
		draw_mat.set_shader_parameter("slot_w", int(cfg.slot_w))
		draw_mat.set_shader_parameter("radius", radius)
		buf_near.resize(capacity * 16)
		buf_far.resize(capacity * 16)
		draw_n = _swap(owner, meshes[0])
		draw_f = _swap(owner, meshes[1])

	func set_meshes(near_mesh: ArrayMesh, far_mesh: ArrayMesh, n_near: int, n_far: int) -> void:
		near_mesh.surface_set_material(0, draw_mat)
		far_mesh.surface_set_material(0, draw_mat)
		draw_n.set_mesh(near_mesh)
		draw_f.set_mesh(far_mesh)
		draw_near = n_near
		draw_far = n_far

	func _swap(owner: Node3D, mesh: ArrayMesh) -> SwapMultiMesh:
		mesh.surface_set_material(0, draw_mat)
		return SwapMultiMesh.new(owner, mesh, capacity, AABB(Vector3(-1.0e5, -1.0e4, -1.0e5), Vector3(2.0e5, 2.0e4, 2.0e5)))

	# grassTiles.js computeAtlasGrid: the ring plus LRU headroom.
	func _atlas_grid(margin: float) -> void:
		var max_span := int(ceil(radius * 2.0 / tile)) + 2
		var approx := int(ceil(PI * pow(radius / tile + 1.1, 2.0)))
		var needed := maxi(9, mini(max_span * max_span, int(ceil(approx * margin))))
		cols = int(ceil(sqrt(float(needed))))
		rows = int(ceil(float(needed) / cols))
		capacity = cols * rows

	func update(cam: Vector3, planes: Array[Plane], frame: int, assume_baked: bool) -> void:
		# Slots baked during the previous frame's draw are now readable.
		for s in slots:
			if s.baking and frame > s.bake_frame:
				s.baking = false
				s.ready = true
				_write_slot(s)
		var tiles := _ring(cam.x, cam.z)
		var active := {}
		for t in tiles:
			active[t.key] = true
		var bake_any := false
		for t in tiles:
			if by_key.has(t.key):
				continue
			var s := _evict(active, cam.x, cam.z)
			if s.key != null:
				by_key.erase(s.key)
			_assign(s, t)
			by_key[t.key] = s
			if not s.empty:
				s.ready = assume_baked
				s.baking = not assume_baked
				s.bake_frame = frame
				bake_any = bake_any or s.baking
			_write_slot(s)
		if bake_any:
			vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		if slot_dirty_tex:
			slot_tex.update(slot_img)
			slot_dirty_tex = false
		near_vis = 0
		far_vis = 0
		for t in tiles:
			var s: Dictionary = by_key[t.key]
			if s.empty or not s.ready or not _box_visible(s.box, planes):
				continue
			var near: bool = t.d2 < cfg.near_lod * cfg.near_lod
			if near:
				_put(true, near_vis, s)
				near_vis += 1
			else:
				_put(false, far_vis, s)
				far_vis += 1
		var tp := Time.get_ticks_usec()
		draw_n.push(buf_near, near_vis)
		draw_f.push(buf_far, far_vis)
		push_us = Time.get_ticks_usec() - tp
		last_tris = near_vis * draw_near * int(cfg.near_tris) + far_vis * draw_far * int(cfg.far_tris)
		last_draws = (1 if near_vis > 0 else 0) + (1 if far_vis > 0 else 0)

	# One instance: identity basis moved to (tile origin x, base height, tile origin z); custom =
	# (slot x, y, mirror bits). The base rides in the transform because MultiMesh custom data is
	# stored at half precision in this renderer (0.125 m steps at 140 m), the transform in full.
	# Writes the member arrays by name: a packed array held in a local may be a copy.
	func _put(near: bool, i: int, s: Dictionary) -> void:
		var vals := [1.0, 0.0, 0.0, s.ox, 0.0, 1.0, 0.0, s.base, 0.0, 0.0, 1.0, s.oz, float(s.sx), float(s.sy), float(s.flips), 0.0]
		var k := i * 16
		for j in 16:
			if near:
				buf_near[k + j] = vals[j]
			else:
				buf_far[k + j] = vals[j]

	# grassTiles.js selectTileRing: tiles whose box touches the circle, nearest centre first.
	func _ring(cx: float, cz: float) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		var r2 := radius * radius
		for tz in range(int(floor((cz - radius) / tile)), int(floor((cz + radius) / tile)) + 1):
			for tx in range(int(floor((cx - radius) / tile)), int(floor((cx + radius) / tile)) + 1):
				var x0 := tx * tile
				var z0 := tz * tile
				var dx := maxf(maxf(x0 - cx, 0.0), cx - (x0 + tile))
				var dz := maxf(maxf(z0 - cz, 0.0), cz - (z0 + tile))
				var d2 := dx * dx + dz * dz
				if d2 > r2:
					continue
				var ex := x0 + tile * 0.5 - cx
				var ez := z0 + tile * 0.5 - cz
				out.append({"key": Vector2i(tx, tz), "tx": tx, "tz": tz, "d2": d2, "c2": ex * ex + ez * ez})
		out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.c2 < b.c2)
		return out

	# grassTiles.js _pickEvictSlot: a free slot, else the farthest one outside the ring.
	func _evict(active: Dictionary, cx: float, cz: float) -> Dictionary:
		var best: Dictionary = {}
		var best_d := -1.0
		for s in slots:
			if s.key == null:
				return s
			if active.has(s.key):
				continue
			var d := Vector2(s.ox + tile * 0.5 - cx, s.oz + tile * 0.5 - cz).length_squared()
			if d > best_d:
				best_d = d
				best = s
		return best

	func _assign(s: Dictionary, t: Dictionary) -> void:
		var tx: int = t.tx
		var tz: int = t.tz
		var f := VegScatter.flip_bits(tx, tz)
		s.key = t.key
		s.ox = tx * tile
		s.oz = tz * tile
		s.flips = f.x | (f.y << 1)
		# grassTiles.js computeTileBounds: 5 x 5 ground samples.
		var lo := INF
		var hi := -INF
		for iz in 5:
			for ix in 5:
				var y: float = world.height(s.ox + ix * tile * 0.25, s.oz + iz * tile * 0.25)
				lo = minf(lo, y)
				hi = maxf(hi, y)
		s.base = lo - BASE_DROP
		s.box = AABB(Vector3(s.ox - cfg.pad_xz, lo - cfg.pad_down, s.oz - cfg.pad_xz),
			Vector3(tile + 2.0 * cfg.pad_xz, hi - lo + cfg.pad_down + cfg.pad_up, tile + 2.0 * cfg.pad_xz))
		s.empty = hi < world.water_level + cfg.empty_below
		s.ready = false
		s.baking = false

	func _write_slot(s: Dictionary) -> void:
		var i: int = s.i
		var flags: int = s.flips | (4 if s.baking else 0)
		slot_img.set_pixel(i, 0, Color(s.ox, s.oz, float(flags), s.base))
		slot_dirty_tex = true

	# Frustum planes point outward: a box is out when its corner deepest along a plane's normal
	# is still in front of that plane.
	func _box_visible(b: AABB, planes: Array[Plane]) -> bool:
		for p in planes:
			var n := p.normal
			var c := Vector3(b.position.x if n.x > 0.0 else b.end.x, b.position.y if n.y > 0.0 else b.end.y, b.position.z if n.z > 0.0 else b.end.z)
			if n.dot(c) - p.d > 0.0:
				return false
		return true
