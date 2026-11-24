extends RefCounted

# Loads the valley exported by tools/export_world.mjs and answers the same queries as
# Stillwater's WorldData. Layouts and sampling rules are spelled out in data/valley/meta.json.
#
# Two height functions on purpose: the game's CPU height (player eye, tree y) reads only the
# near map, while the GPU terrain blends near into far over 1828-2028 m. They agree inside the
# walkable valley and differ in the blend band, which the player can reach (boundary 1850).

var dir := ""
var meta: Dictionary
var paths: Dictionary
var extras: Dictionary
var poses: Dictionary
var meshes: Dictionary

var near: PackedFloat32Array
var far: PackedFloat32Array
var trail_mask: PackedFloat32Array
var near_res := 0
var near_size := 0.0
var far_res := 0
var far_size := 0.0
var blend_start := 0.0
var blend_end := 0.0

var biome_rgb: PackedByteArray
var biome_forest: PackedFloat32Array
var biome_res := 0

# Trees: planar arrays, one entry per canonical placement.
var tree_count := 0
var tree_x: PackedFloat32Array
var tree_y: PackedFloat32Array
var tree_z: PackedFloat32Array
var tree_s: PackedFloat32Array
var tree_rot: PackedFloat32Array
var tree_sx: PackedFloat32Array
var tree_tint: PackedColorArray
var tree_rank: PackedInt32Array
var tree_kind: PackedByteArray
var tree_salt: PackedByteArray

var rock_count := 0
var rock_x: PackedFloat32Array
var rock_y: PackedFloat32Array
var rock_z: PackedFloat32Array
var rock_s: PackedFloat32Array
var rock_rot: PackedFloat32Array
var rock_tilt_x: PackedFloat32Array
var rock_tilt_z: PackedFloat32Array
var rock_rank: PackedInt32Array
var rock_kind: PackedByteArray

var trail_points: PackedVector2Array
var stream_points: PackedVector2Array


func load_dir(path: String = "res://data/valley") -> bool:
	dir = path
	meta = _json("meta.json")
	if meta.is_empty():
		return false
	paths = _json("paths.json")
	extras = _json("extras.json")
	poses = _json("poses.json")
	meshes = _json("meshes.json")

	near_res = int(meta.near.res)
	near_size = float(meta.near.size)
	far_res = int(meta.far.res)
	far_size = float(meta.far.size)
	blend_start = float(meta.heightRules.blendStart)
	blend_end = float(meta.heightRules.blendEnd)
	near = _bytes(meta.near.file).to_float32_array()
	far = _bytes(meta.far.file).to_float32_array()
	var mask_i16 := _bytes(meta.trailMask.file)
	trail_mask.resize(mask_i16.size() / 2)
	var mask_scale := 1.0 / 32767.0
	for i in trail_mask.size():
		trail_mask[i] = mask_i16.decode_s16(i * 2) * mask_scale

	biome_res = int(meta.biome.res)
	biome_rgb = _bytes(meta.biome.rgb.file)
	biome_forest = _bytes(meta.biome.forest.file).to_float32_array()

	tree_count = int(meta.trees.count)
	var tf := _bytes(meta.trees.file).to_float32_array()
	var n := tree_count
	tree_x = tf.slice(0, n)
	tree_y = tf.slice(n, n * 2)
	tree_z = tf.slice(n * 2, n * 3)
	tree_s = tf.slice(n * 3, n * 4)
	tree_rot = tf.slice(n * 4, n * 5)
	tree_sx = tf.slice(n * 5, n * 6)
	tree_tint.resize(n)
	for i in n:
		tree_tint[i] = Color(tf[n * 6 + i], tf[n * 7 + i], tf[n * 8 + i])
	tree_rank = _u16(meta.trees.rank.file)
	tree_kind = _bytes(meta.trees.kind.file)
	tree_salt = _bytes(meta.trees.salt.file)

	rock_count = int(meta.rocks.count)
	var rf := _bytes(meta.rocks.file).to_float32_array()
	var m := rock_count
	rock_x = rf.slice(0, m)
	rock_y = rf.slice(m, m * 2)
	rock_z = rf.slice(m * 2, m * 3)
	rock_s = rf.slice(m * 3, m * 4)
	rock_rot = rf.slice(m * 4, m * 5)
	rock_tilt_x = rf.slice(m * 5, m * 6)
	rock_tilt_z = rf.slice(m * 6, m * 7)
	rock_rank = _u16(meta.rocks.rank.file)
	rock_kind = _bytes(meta.rocks.kind.file)

	trail_points = _points(paths.trail.points)
	if paths.stream != null:
		stream_points = _points(paths.stream.points)
	return near.size() == near_res * near_res and far.size() == far_res * far_res \
		and tree_rank.size() == tree_count and rock_rank.size() == rock_count


# Port of HeightField._sample: texel centres, edge clamp at res - 1.001.
static func _bilinear(arr: PackedFloat32Array, res: int, size: float, x: float, z: float) -> float:
	var fx := clampf((x / size + 0.5) * res - 0.5, 0.0, res - 1.001)
	var fz := clampf((z / size + 0.5) * res - 0.5, 0.0, res - 1.001)
	var ix := int(floor(fx))
	var iz := int(floor(fz))
	var tx := fx - ix
	var tz := fz - iz
	var i := iz * res + ix
	return (arr[i] * (1.0 - tx) + arr[i + 1] * tx) * (1.0 - tz) + (arr[i + res] * (1.0 - tx) + arr[i + res + 1] * tx) * tz


# Gameplay height, identical to WorldData.height.
func height_near(x: float, z: float) -> float:
	return _bilinear(near, near_res, near_size, x, z)


func height_far(x: float, z: float) -> float:
	return _bilinear(far, far_res, far_size, x, z)


func near_blend(x: float, z: float) -> float:
	return smoothstep(blend_start, blend_end, maxf(absf(x), absf(z)))


# Rendered terrain height, identical to w_height in Stillwater's GLSL.
func height(x: float, z: float) -> float:
	var t := near_blend(x, z)
	if t <= 0.0:
		return height_near(x, z)
	if t >= 1.0:
		return height_far(x, z)
	return lerpf(height_near(x, z), height_far(x, z), t)


func trail_at(x: float, z: float) -> float:
	return absf(_bilinear(trail_mask, near_res, near_size, x, z))


func is_path(x: float, z: float) -> bool:
	return _bilinear(trail_mask, near_res, near_size, x, z) > 0.4


# Nearest texel, as createBiomeData's idxAt.
func biome_at(x: float, z: float) -> Dictionary:
	var ix := clampi(int(floor((x / near_size + 0.5) * biome_res)), 0, biome_res - 1)
	var iz := clampi(int(floor((z / near_size + 0.5) * biome_res)), 0, biome_res - 1)
	var k := iz * biome_res + ix
	return {
		"forest": biome_forest[k],
		"flowers": biome_rgb[k * 3 + 1] / 255.0,
		"meadow": biome_rgb[k * 3 + 2] / 255.0,
	}


# Same subset as selectByRank(items, density): rank = u16 / 65536, keep rank < density.
static func _select(ranks: PackedInt32Array, density: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	if density <= 0.0:
		return out
	var all := density >= 1.0
	var limit := density * 65536.0
	for i in ranks.size():
		if all or ranks[i] < limit:
			out.append(i)
	return out


func select_by_rank(density: float) -> PackedInt32Array:
	return _select(tree_rank, density)


func select_rocks_by_rank(density: float) -> PackedInt32Array:
	return _select(rock_rank, density)


func tier(name: String) -> Dictionary:
	return meta.tiers[name]


func pose(stop: String) -> Dictionary:
	return poses.stops[stop]


func _json(file: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(dir.path_join(file))
	if text.is_empty():
		push_error("world_data: cannot read %s" % dir.path_join(file))
		return {}
	var data = JSON.parse_string(text)
	return data if data is Dictionary else {}


func _bytes(file: String) -> PackedByteArray:
	var b := FileAccess.get_file_as_bytes(dir.path_join(file))
	if b.is_empty():
		push_error("world_data: cannot read %s" % dir.path_join(file))
	return b


func _u16(file: String) -> PackedInt32Array:
	var b := _bytes(file)
	var out := PackedInt32Array()
	out.resize(b.size() / 2)
	for i in out.size():
		out[i] = b.decode_u16(i * 2)
	return out


static func _points(list: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(list.size())
	for i in list.size():
		out[i] = Vector2(list[i][0], list[i][1])
	return out
