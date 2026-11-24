extends RefCounted

# Loads data/valley/web/ (written by tools/export_web.mjs): the only world files the scene reads,
# on desktop and on Web alike. Heights are integer codes in PNG channels, decoded natively, so
# loading does no per-texel GDScript work. Rules are in data/valley/web/meta.json.
#
# The GPU samples the same bytes with texelFetch and does the bilinear filter itself, because
# float-linear filtering is not guaranteed on iOS and hardware-filtered byte splits are not exact.

const SKY_LUT_W := 192
const SKY_LUT_H := 108

var dir := ""
var meta: Dictionary
var near_img: Image
var far_img: Image
var biome_img: Image
var noise_img: Image
var noise_tex: ImageTexture
var sky_lut_tex: ImageTexture
var near_bytes: PackedByteArray
var far_bytes: PackedByteArray
var biome_bytes: PackedByteArray

var near_res := 0
var near_size := 0.0
var near_min := 0.0
var near_step := 0.0
var far_res := 0
var far_size := 0.0
var far_min := 0.0
var far_step := 0.0
var biome_res := 0
var blend_start := 0.0
var blend_end := 0.0
var water_level := 0.0
# Tree colliders (meta.colliders): the whole file, read in place by collide_trees.
var col_bytes := PackedByteArray()
var col_grid := 0
var col_cell := 32.0
var col_origin := 0.0
var col_recs := 0


func load_dir(path: String = "res://data/valley/web") -> bool:
	dir = path
	var text := FileAccess.get_file_as_string(dir.path_join("meta.json"))
	if text.is_empty():
		push_error("compact_world: cannot read %s" % dir.path_join("meta.json"))
		return false
	meta = JSON.parse_string(text)
	near_res = int(meta.near.res)
	near_size = float(meta.near.size)
	near_min = float(meta.near.min)
	near_step = float(meta.near.step)
	far_res = int(meta.far.res)
	far_size = float(meta.far.size)
	far_min = float(meta.far.min)
	far_step = float(meta.far.step)
	biome_res = int(meta.biome.res)
	blend_start = float(meta.blendStart)
	blend_end = float(meta.blendEnd)
	water_level = float(meta.waterLevel)
	near_img = _png(meta.near.file, Image.FORMAT_RGB8, near_res)
	far_img = _png(meta.far.file, Image.FORMAT_RGB8, far_res)
	biome_img = _png(meta.biome.file, Image.FORMAT_RGB8, biome_res)
	noise_img = _png(meta.noise.file, Image.FORMAT_RGBA8, int(meta.noise.res))
	if near_img == null or far_img == null or biome_img == null or noise_img == null:
		return false
	noise_img.generate_mipmaps()
	noise_tex = ImageTexture.create_from_image(noise_img)
	var lut := _sky_lut()
	if lut == null:
		return false
	sky_lut_tex = ImageTexture.create_from_image(lut)
	near_bytes = near_img.get_data()
	far_bytes = far_img.get_data()
	biome_bytes = biome_img.get_data()
	if meta.has("colliders"):
		col_bytes = FileAccess.get_file_as_bytes(dir.path_join(meta.colliders.file))
		col_grid = int(meta.colliders.grid)
		col_cell = float(meta.colliders.cell)
		col_origin = float(meta.colliders.origin)
		col_recs = (col_grid * col_grid + 1) * 4
		if col_bytes.size() != col_recs + int(meta.colliders.count) * 5:
			push_error("compact_world: %s is %d bytes, expected %d" % [meta.colliders.file, col_bytes.size(), col_recs + int(meta.colliders.count) * 5])
			col_bytes = PackedByteArray()
	return true


# Stillwater's sky-view LUT at hour 16 (tools/shoot_stillwater.mjs reads it back from the game):
# 192 x 108 half-float RGB, row 0 at v = 0, sampled with Stillwater's w_lutUV.
func _sky_lut() -> Image:
	var path := "res://data/sky/sky_lut_16h.rgbh"
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() != SKY_LUT_W * SKY_LUT_H * 6:
		push_error("compact_world: %s is %d bytes, expected %d" % [path, bytes.size(), SKY_LUT_W * SKY_LUT_H * 6])
		return null
	return Image.create_from_data(SKY_LUT_W, SKY_LUT_H, false, Image.FORMAT_RGBH, bytes)


func _png(file: String, fmt: int, res: int) -> Image:
	var bytes := FileAccess.get_file_as_bytes(dir.path_join(file))
	var img := Image.new()
	if bytes.is_empty() or img.load_png_from_buffer(bytes) != OK:
		push_error("compact_world: cannot decode %s" % dir.path_join(file))
		return null
	if img.get_format() != fmt or img.get_width() != res or img.get_height() != res:
		push_error("compact_world: %s is %dx%d format %d, expected %dx%d format %d" % [
			file, img.get_width(), img.get_height(), img.get_format(), res, res, fmt])
		return null
	return img


func _near_code(i: int) -> int:
	return near_bytes[i * 3] | (near_bytes[i * 3 + 1] << 8)


func _far_code(i: int) -> int:
	return far_bytes[i * 3] | (far_bytes[i * 3 + 1] << 8) | (far_bytes[i * 3 + 2] << 16)


# Same texel-centre bilinear and edge clamp as world_data._bilinear (HeightField._sample).
static func _cell(res: int, size: float, x: float, z: float) -> Vector4:
	var fx := clampf((x / size + 0.5) * res - 0.5, 0.0, res - 1.001)
	var fz := clampf((z / size + 0.5) * res - 0.5, 0.0, res - 1.001)
	var ix := floorf(fx)
	var iz := floorf(fz)
	return Vector4(ix, iz, fx - ix, fz - iz)


func height_near(x: float, z: float) -> float:
	var c := _cell(near_res, near_size, x, z)
	var i := int(c.y) * near_res + int(c.x)
	var a := _near_code(i)
	var b := _near_code(i + 1)
	var d := _near_code(i + near_res)
	var e := _near_code(i + near_res + 1)
	return near_min + near_step * ((a * (1.0 - c.z) + b * c.z) * (1.0 - c.w) + (d * (1.0 - c.z) + e * c.z) * c.w)


func height_far(x: float, z: float) -> float:
	var c := _cell(far_res, far_size, x, z)
	var i := int(c.y) * far_res + int(c.x)
	var a := _far_code(i)
	var b := _far_code(i + 1)
	var d := _far_code(i + far_res)
	var e := _far_code(i + far_res + 1)
	return far_min + far_step * ((a * (1.0 - c.z) + b * c.z) * (1.0 - c.w) + (d * (1.0 - c.z) + e * c.z) * c.w)


func near_blend(x: float, z: float) -> float:
	return smoothstep(blend_start, blend_end, maxf(absf(x), absf(z)))


# Rendered height (GPU rule); gameplay height is height_near, as in Stillwater.
func height(x: float, z: float) -> float:
	var t := near_blend(x, z)
	if t <= 0.0:
		return height_near(x, z)
	if t >= 1.0:
		return height_far(x, z)
	return lerpf(height_near(x, z), height_far(x, z), t)


# Placeholder systems (test grass) call this.
func height_at(x: float, z: float) -> float:
	return height_near(x, z)


func trail_raw(x: float, z: float) -> float:
	var c := _cell(near_res, near_size, x, z)
	var i := int(c.y) * near_res + int(c.x)
	return (_mask(i) * (1.0 - c.z) + _mask(i + 1) * c.z) * (1.0 - c.w) \
		+ (_mask(i + near_res) * (1.0 - c.z) + _mask(i + near_res + 1) * c.z) * c.w


func _mask(k: int) -> float:
	return (near_bytes[k * 3 + 2] - 128) / 127.0


func trail_at(x: float, z: float) -> float:
	return absf(trail_raw(x, z))


func biome_at(x: float, z: float) -> Dictionary:
	var ix := clampi(int(floor((x / near_size + 0.5) * biome_res)), 0, biome_res - 1)
	var iz := clampi(int(floor((z / near_size + 0.5) * biome_res)), 0, biome_res - 1)
	var k := (iz * biome_res + ix) * 3
	return {"forest": biome_bytes[k] / 255.0, "flowers": biome_bytes[k + 1] / 255.0, "meadow": biome_bytes[k + 2] / 255.0}


# GPU copies of the near / far height maps and the biome map, made once and shared by every
# system that samples the world on the GPU.
var _tex := {}


func texture(which: String) -> ImageTexture:
	if not _tex.has(which):
		var img: Image = {"near": near_img, "far": far_img, "biome": biome_img}[which]
		_tex[which] = ImageTexture.create_from_image(img)
	return _tex[which]


# WorldData.collideTrees: push a walker of `radius` out of every non-bush tree trunk (s * 0.03 +
# radius) in the 3 x 3 cells around it, in place. Trees are the full canonical list, as in
# Stillwater on every tier, so at `low` some trunks that block are not drawn.
func collide_trees(pos: Vector2, radius: float) -> Vector2:
	if col_bytes.is_empty():
		return pos
	# Max tree scale in colliders.bin is 255 / 8 = 31.875 m, so max trunk radius is 0.96 m + radius.
	var pad := 1.0 + radius
	var gx0 := maxi(0, floori((pos.x - pad - col_origin) / col_cell))
	var gx1 := mini(col_grid - 1, floori((pos.x + pad - col_origin) / col_cell))
	var gz0 := maxi(0, floori((pos.y - pad - col_origin) / col_cell))
	var gz1 := mini(col_grid - 1, floori((pos.y + pad - col_origin) / col_cell))
	for gz in range(gz0, gz1 + 1):
		var row := gz * col_grid
		for gx in range(gx0, gx1 + 1):
			var c := row + gx
			var a := col_bytes.decode_u32(c * 4)
			var b := col_bytes.decode_u32(c * 4 + 4)
			for k in range(a, b):
				var o := col_recs + k * 5
				var tx := col_bytes.decode_u16(o) / 16.0 + col_origin
				var tz := col_bytes.decode_u16(o + 2) / 16.0 + col_origin
				var tr := col_bytes[o + 4] * (0.03 / 8.0) + radius
				var ex := pos.x - tx
				var ez := pos.y - tz
				if absf(ex) >= tr or absf(ez) >= tr:
					continue
				var d2 := ex * ex + ez * ez
				if d2 < tr * tr and d2 > 1e-8:
					var inv_d := tr / sqrt(d2)
					pos = Vector2(tx + ex * inv_d, tz + ez * inv_d)
	return pos


# The full trail (meta.game.trail), for walking and trail following.
func trail_points() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in meta.game.trail:
		out.append(Vector2(p[0], p[1]))
	return out


func pose(stop: String) -> Dictionary:
	return meta.poses.stops[stop]


func has_pose(stop: String) -> bool:
	return meta.poses.stops.has(stop)


func lake_info() -> Dictionary:
	if meta.has("water") and meta.water.has("lake"):
		return meta.water.lake
	if meta.has("game") and meta.game.has("lake"):
		return meta.game.lake
	return {}


func stream_points() -> PackedVector2Array:
	var out := PackedVector2Array()
	if meta.has("water") and meta.water.stream != null:
		for p in meta.water.stream.points:
			out.append(Vector2(p[0], p[1]))
	return out


func stream_brink() -> int:
	if meta.has("water") and meta.water.stream != null and meta.water.stream.brink != null:
		return int(meta.water.stream.brink)
	return -1


func waterfall_info() -> Dictionary:
	if meta.has("water") and meta.water.waterfall != null:
		return meta.water.waterfall
	return {}


func props_info() -> Dictionary:
	if meta.has("props") and meta.props is Dictionary:
		return meta.props
	return {}


func undergrowth_info() -> Dictionary:
	if meta.has("undergrowth") and meta.undergrowth is Dictionary:
		return meta.undergrowth
	return {}


func fauna_info() -> Dictionary:
	if meta.has("fauna") and meta.fauna is Dictionary:
		return meta.fauna
	return {}


# Loads data/valley/web/mushrooms.bin: 9 float32 values per mushroom
# [x, y, z, scale, stem_h, cap_r, tilt, rot, is_golden].
func load_mushrooms() -> Dictionary:
	var ug := undergrowth_info()
	if not ug.has("mushrooms"):
		return {}
	var mm: Dictionary = ug.mushrooms
	var n := int(mm.count)
	var bytes := FileAccess.get_file_as_bytes(dir.path_join(mm.file))
	if bytes.size() != n * 36:
		push_error("compact_world: %s is %d bytes, expected %d" % [mm.file, bytes.size(), n * 36])
		return {}
	var vals := bytes.to_float32_array()
	var x := PackedFloat32Array()
	var y := PackedFloat32Array()
	var z := PackedFloat32Array()
	var sc := PackedFloat32Array()
	var sh := PackedFloat32Array()
	var cr := PackedFloat32Array()
	var tilt := PackedFloat32Array()
	var rot := PackedFloat32Array()
	var golden := PackedByteArray()
	x.resize(n); y.resize(n); z.resize(n)
	sc.resize(n); sh.resize(n); cr.resize(n)
	tilt.resize(n); rot.resize(n); golden.resize(n)
	for i in n:
		var o := i * 9
		x[i] = vals[o]
		y[i] = vals[o + 1]
		z[i] = vals[o + 2]
		sc[i] = vals[o + 3]
		sh[i] = vals[o + 4]
		cr[i] = vals[o + 5]
		tilt[i] = vals[o + 6]
		rot[i] = vals[o + 7]
		golden[i] = 1 if vals[o + 8] > 0.5 else 0
	return {
		"count": n,
		"x": x, "y": y, "z": z,
		"sc": sc, "sh": sh, "cap_r": cr,
		"tilt": tilt, "rot": rot, "golden": golden,
	}


# Loads data/valley/web/rocks.bin: 10 float32 values per rock
# [x, y, z, sx, sy, sz, rot, tilt_x, tilt_z, kind_flags].
func load_rocks() -> Dictionary:
	if not meta.has("rocks"):
		return {}
	var rm: Dictionary = meta.rocks
	var n := int(rm.count)
	var bytes := FileAccess.get_file_as_bytes(dir.path_join(rm.file))
	if bytes.size() != n * 40:
		push_error("compact_world: %s is %d bytes, expected %d" % [rm.file, bytes.size(), n * 40])
		return {}
	var vals := bytes.to_float32_array()
	var x := PackedFloat32Array()
	var y := PackedFloat32Array()
	var z := PackedFloat32Array()
	var sx := PackedFloat32Array()
	var sy := PackedFloat32Array()
	var sz := PackedFloat32Array()
	var rot := PackedFloat32Array()
	var tx := PackedFloat32Array()
	var tz := PackedFloat32Array()
	var kind := PackedByteArray()
	var is_prop := PackedByteArray()
	x.resize(n); y.resize(n); z.resize(n)
	sx.resize(n); sy.resize(n); sz.resize(n)
	rot.resize(n); tx.resize(n); tz.resize(n)
	kind.resize(n); is_prop.resize(n)
	for i in n:
		var o := i * 10
		x[i] = vals[o]
		y[i] = vals[o + 1]
		z[i] = vals[o + 2]
		sx[i] = vals[o + 3]
		sy[i] = vals[o + 4]
		sz[i] = vals[o + 5]
		rot[i] = vals[o + 6]
		tx[i] = vals[o + 7]
		tz[i] = vals[o + 8]
		var kf := int(vals[o + 9])
		kind[i] = kf & 3
		is_prop[i] = (kf >> 4) & 1
	return {
		"count": n,
		"canonical_count": int(rm.canonicalCount),
		"x": x, "y": y, "z": z,
		"sx": sx, "sy": sy, "sz": sz,
		"rot": rot, "tilt_x": tx, "tilt_z": tz,
		"kind": kind, "is_prop": is_prop,
	}


func load_signpost_tex() -> ImageTexture:
	if not meta.has("signpostTex"):
		return null
	var sm: Dictionary = meta.signpostTex
	var bytes := FileAccess.get_file_as_bytes(dir.path_join(sm.file))
	var img := Image.new()
	if bytes.is_empty() or img.load_png_from_buffer(bytes) != OK:
		push_error("compact_world: cannot decode %s" % dir.path_join(sm.file))
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func walk_points() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in meta.walk:
		out.append(Vector2(p[0], p[1]))
	return out


# The tree pack (meta.trees, written by tools/export_web.mjs): the tier's rank subset in
# canonical order. Returns planar arrays x, y, z, s, rot, sx (PackedFloat32Array), tint (rgb
# bytes, value = byte / 255 * tint_max) and kind (bytes), or an empty Dictionary on error.
func load_trees() -> Dictionary:
	var tm: Dictionary = meta.trees
	var bytes := FileAccess.get_file_as_bytes(dir.path_join(tm.file))
	var n := int(tm.count)
	if bytes.size() != n * 19:
		push_error("compact_world: %s is %d bytes, expected %d" % [tm.file, bytes.size(), n * 19])
		return {}
	var d: Dictionary = tm.decode
	var wsize := float(d.world)
	var k24 := wsize / float(d.q24)
	var half := wsize * 0.5
	var out := {
		"count": n,
		"x": _u24(bytes, 0, n, k24, half),
		"y": _u24(bytes, n * 3, n, k24, half),
		"z": _u24(bytes, n * 6, n, k24, half),
		"s": _u16(bytes, n * 9, n, float(d.sMax) / 65535.0, 0.0),
		"rot": _u16(bytes, n * 11, n, TAU / 65536.0, 0.0),
		"sx": _u16(bytes, n * 13, n, 1.0 / 65535.0, float(d.sxMin)),
		"tint": bytes.slice(n * 15, n * 18),
		"tint_max": float(d.tintMax),
		"kind": bytes.slice(n * 18, n * 19),
		"rank": PackedInt32Array(),
	}
	if tm.has("rankFile"):
		var rb := FileAccess.get_file_as_bytes(dir.path_join(tm.rankFile))
		if rb.size() == n * 2:
			out.rank = _u16_raw(rb, n)
		else:
			push_error("compact_world: %s is %d bytes, expected %d" % [tm.rankFile, rb.size(), n * 2])
	return out


static func _u16_raw(bytes: PackedByteArray, n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(n)
	for i in n:
		out[i] = bytes.decode_u16(i * 2)
	return out


static func _u24(bytes: PackedByteArray, o: int, n: int, k: float, half: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var b := o + i * 3
		out[i] = (bytes[b] | (bytes[b + 1] << 8) | (bytes[b + 2] << 16)) * k - half
	return out


static func _u16(bytes: PackedByteArray, o: int, n: int, k: float, base: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = base + bytes.decode_u16(o + i * 2) * k
	return out
