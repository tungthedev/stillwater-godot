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


func pose(stop: String) -> Dictionary:
	return meta.poses.stops[stop]


func walk_points() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in meta.walk:
		out.append(Vector2(p[0], p[1]))
	return out
