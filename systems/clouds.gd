extends Node3D

# Stillwater's painterly cumulus banks (src/world/clouds.js) at the `low` tier: clouds 12,
# cloudDetail 1. Same seeded layout (mulberry32(2026)), so every puff sits where the game puts it:
# each puff is an instance of a unit icosphere that the shader inflates with noise, flattens at
# the cluster base and shades with the hour-16 daytime terms.
#
# Instance transform: origin = puff centre in the world, basis y.y = puff radius, basis x.y =
# seed (full float); custom = cluster (x, top, z, base), which only steers the dome normal, so its
# half precision is enough. The drift starts at 0 and moves a few metres a minute, so it is left
# out; the wrap into the 28 km tile is applied once here.

const VegScatter := preload("res://world/veg_scatter.gd")
const COUNT := 12
const DETAIL := 1
const WRAP := 28000.0

var world: RefCounted
var mat: ShaderMaterial
var mmi: MultiMeshInstance3D
var puffs := 0
var tris := 0


func setup(w: RefCounted) -> void:
	world = w


func _ready() -> void:
	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/clouds.gdshader")
	mat.set_shader_parameter("noise_tex", world.noise_tex)
	mat.set_shader_parameter("sky_lut", world.sky_lut_tex)
	var mesh := _icosphere(DETAIL)
	mesh.surface_set_material(0, mat)
	var list := _puffs(COUNT)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = list.size()
	var buf := PackedFloat32Array()
	buf.resize(list.size() * 16)
	for i in list.size():
		var p: Array = list[i]
		var cx := fposmod(float(p[4]) + WRAP * 0.5, WRAP) - WRAP * 0.5
		var cz := fposmod(float(p[6]) + WRAP * 0.5, WRAP) - WRAP * 0.5
		var o := i * 16
		buf[o] = 1.0
		buf[o + 3] = cx + float(p[0])
		buf[o + 4] = float(p[8])
		buf[o + 5] = float(p[3])
		buf[o + 7] = float(p[1])
		buf[o + 10] = 1.0
		buf[o + 11] = cz + float(p[2])
		buf[o + 12] = cx
		buf[o + 13] = float(p[5])
		buf[o + 14] = cz
		buf[o + 15] = float(p[7])
	mm.buffer = buf
	mm.custom_aabb = AABB(Vector3(-20000, 0, -20000), Vector3(40000, 12000, 40000))
	mmi = MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	puffs = list.size()
	tris = puffs * (mesh.surface_get_array_index_len(0) / 3)


func materials() -> Array[ShaderMaterial]:
	return [mat]


# clouds.js _buildGeo: [x, y, z, r, cluster x, top, cluster z, base, seed] per puff.
static func _puffs(count: int) -> Array:
	var st := PackedInt64Array([2026])
	var rnd := func() -> float: return VegScatter.rnd_next(st)
	var out := []
	for c in count:
		var arch := c % 3
		var ang: float = (float(c) / count) * PI * 2.0 + (rnd.call() - 0.5) * 0.24
		var dist: float = (8800.0 + rnd.call() * 5200.0) if arch == 1 else ((6800.0 + rnd.call() * 6400.0) if arch == 2 else (7600.0 + rnd.call() * 5400.0))
		var cx := cos(ang) * dist - 200.0
		var cz := sin(ang) * dist - 150.0
		var base: float = (2350.0 + rnd.call() * 650.0) if arch == 0 else ((3450.0 + rnd.call() * 950.0) if arch == 1 else (2650.0 + rnd.call() * 1650.0))
		var w: float = (1950.0 + rnd.call() * 1950.0) if arch == 0 else ((2900.0 + rnd.call() * 2100.0) if arch == 1 else (950.0 + rnd.call() * 850.0))
		var hgt: float = w * (0.38 + rnd.call() * 0.18) if arch == 0 else (w * (0.13 + rnd.call() * 0.08) if arch == 1 else w * (0.24 + rnd.call() * 0.14))
		var n: int = (14 + int(floor(w / 75.0))) if arch == 2 else (22 + int(floor(w / 38.0)))
		var top := base + hgt
		var tang: float = ang + PI * 0.5 + (rnd.call() - 0.5) * 0.45
		var ct := cos(tang)
		var st2 := sin(tang)
		for i in n:
			var a: float = rnd.call() * PI * 2.0
			var rr: float = sqrt(rnd.call()) * 0.84
			var long_ax := 0.64 if arch == 1 else 0.50
			var depth_ax := 0.16 if arch == 1 else 0.25
			var lx := cos(a) * rr * w * long_ax
			var lz := sin(a) * rr * w * depth_ax
			var x := lx * ct - lz * st2
			var z := lx * st2 + lz * ct
			var dome := sqrt(maxf(0.0, 1.0 - rr * rr))
			var puff_scale := 0.28 if arch == 1 else (0.42 if arch == 2 else 0.46)
			var r: float = (0.13 + 0.18 * dome + rnd.call() * 0.055) * w * puff_scale
			var y: float = base + r * (0.22 if arch == 1 else 0.32) + pow(dome, 0.72 if arch == 0 else 1.0) * hgt * (0.30 + 0.70 * rnd.call())
			out.append([x, y, z, r, cx, top, cz, base, rnd.call() * 10.0])
	for spec in [[-2.74, 7200.0, 7400.0, 2400.0], [-1.70, 7400.0, 6950.0, 2450.0]]:
		var ang_w: float = spec[0]
		var dist_w: float = spec[1]
		var base_w: float = spec[2]
		var w_w: float = spec[3]
		var cx := cos(ang_w) * dist_w - 200.0
		var cz := sin(ang_w) * dist_w - 150.0
		var hgt := w_w * 0.36
		var top := base_w + hgt
		var tang := ang_w + PI * 0.5
		var ct := cos(tang)
		var st2 := sin(tang)
		for i in 42:
			var a: float = rnd.call() * PI * 2.0
			var rr: float = sqrt(rnd.call()) * 0.82
			var lx := cos(a) * rr * w_w * 0.50
			var lz := sin(a) * rr * w_w * 0.24
			var x := lx * ct - lz * st2
			var z := lx * st2 + lz * ct
			var dome := sqrt(maxf(0.0, 1.0 - rr * rr))
			var r: float = (0.16 + 0.18 * dome + rnd.call() * 0.05) * w_w * 0.45
			var y: float = base_w + r * 0.32 + pow(dome, 0.85) * hgt * (0.34 + 0.66 * rnd.call())
			out.append([x, y, z, r, cx, top, cz, base_w, rnd.call() * 10.0])
	return out


# three.js IcosahedronGeometry(1, detail): each face split into (detail + 1)^2 triangles, every
# vertex pushed onto the unit sphere. Indexed here; the shader only needs the positions.
static func _icosphere(detail: int) -> ArrayMesh:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var base := [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	var faces := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4],
		[11, 10, 2], [10, 7, 6], [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	var verts := PackedVector3Array()
	var lookup := {}
	var idx := PackedInt32Array()
	var vid := func(p: Vector3) -> int:
		var q := p.normalized()
		var key := Vector3i(roundi(q.x * 1e5), roundi(q.y * 1e5), roundi(q.z * 1e5))
		if not lookup.has(key):
			lookup[key] = verts.size()
			verts.append(q)
		return lookup[key]
	var cols := detail + 1
	for f in faces:
		var a: Vector3 = base[f[0]]
		var b: Vector3 = base[f[1]]
		var c: Vector3 = base[f[2]]
		# Barycentric grid on the flat face, as three subdivides before projecting.
		var grid := []
		for i in cols + 1:
			var row := []
			var aj := a.lerp(c, float(i) / cols)
			var bj := b.lerp(c, float(i) / cols)
			var rows := cols - i
			for j in rows + 1:
				row.append(aj if rows == 0 else aj.lerp(bj, float(j) / rows))
			grid.append(row)
		for i in cols:
			for j in 2 * (cols - i) - 1:
				var k := j / 2
				var tri: Array
				if j % 2 == 0:
					tri = [grid[i][k + 1], grid[i + 1][k], grid[i][k]]
				else:
					tri = [grid[i][k + 1], grid[i + 1][k + 1], grid[i + 1][k]]
				var p0: Vector3 = tri[0]
				var p1: Vector3 = tri[1]
				var p2: Vector3 = tri[2]
				# Godot's front faces wind clockwise seen from outside.
				if (p1 - p0).cross(p2 - p0).dot(p0 + p1 + p2) > 0.0:
					var tmp := p1
					p1 = p2
					p2 = tmp
				idx.append_array([vid.call(p0), vid.call(p1), vid.call(p2)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
