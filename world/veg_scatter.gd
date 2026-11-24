extends RefCounted

# Stillwater's fixed per-tile vegetation scatter (src/world/grassTiles.js generateTileScatter,
# tileFlipBits; mulberry32 from src/world/biome.js), so every root lands where Stillwater puts it.
# JS works on 32-bit integers (Math.imul, >>>, | 0); GDScript ints are 64-bit, so every step masks
# to 32 bits and imul splits one factor to stay inside 64 bits. tests/check_world.gd compares the
# result with data/valley/veg_fixture.json, written from Stillwater's own code.

const M32 := 0xFFFFFFFF


static func imul(a: int, b: int) -> int:
	a &= M32
	b &= M32
	var lo := (a & 0xFFFF) * b
	var hi := ((a >> 16) * b) & 0xFFFF
	return (lo + (hi << 16)) & M32


# mulberry32 step; state is a one-element array so callers share it by reference.
static func rnd_next(state: PackedInt64Array) -> float:
	var a := (state[0] + 0x6d2b79f5) & M32
	state[0] = a
	var t := imul(a ^ (a >> 15), 1 | a)
	t = ((t + imul(t ^ (t >> 7), 61 | t)) & M32) ^ t
	return float((t ^ (t >> 14)) & M32) / 4294967296.0


# Clumped scatter in [0, size)^2, shuffled so any prefix of ranks covers the tile evenly; always
# generated at the layout's maxCount so a root depends only on its rank, never on the tier.
# Returns { local: PackedFloat32Array (x, z per rank), rnd: PackedFloat32Array (4 per rank),
# packed: PackedInt64Array (Stillwater's 4 uint32 words per rank, for the fixture check) }.
static func generate(count: int, size: float, seed: int) -> Dictionary:
	var rng := PackedInt64Array([seed & M32])
	# Float32 like Stillwater's Float32Arrays: values round to float32 before they are quantised.
	var raw_x := PackedFloat32Array()
	var raw_z := PackedFloat32Array()
	var raw_r := PackedFloat32Array()
	raw_x.resize(count)
	raw_z.resize(count)
	raw_r.resize(count * 4)
	var side := int(ceil(sqrt(float(count))))
	var cell := size / side
	for i in count:
		var ox: float
		var oz: float
		if i % 5 != 0:
			var gx := i % side
			var gz := i / side
			var cx := (gx + 0.5 + (rnd_next(rng) - 0.5) * 1.9) * cell
			var cz := (gz + 0.5 + (rnd_next(rng) - 0.5) * 1.9) * cell
			var ang := rnd_next(rng) * PI * 2.0
			var rad := sqrt(rnd_next(rng)) * cell * 0.85
			ox = fmod(fmod(cx + cos(ang) * rad, size) + size, size)
			oz = fmod(fmod(cz + sin(ang) * rad, size) + size, size)
		else:
			ox = rnd_next(rng) * size
			oz = rnd_next(rng) * size
		raw_x[i] = ox
		raw_z[i] = oz
		for k in 4:
			raw_r[i * 4 + k] = rnd_next(rng)
	var order := PackedInt32Array()
	order.resize(count)
	for i in count:
		order[i] = i
	for i in range(count - 1, 0, -1):
		var j := int(floor(rnd_next(rng) * (i + 1)))
		var tmp := order[i]
		order[i] = order[j]
		order[j] = tmp
	var local := PackedFloat32Array()
	var rnd := PackedFloat32Array()
	var packed := PackedInt64Array()
	local.resize(count * 2)
	rnd.resize(count * 4)
	packed.resize(count * 4)
	for i in count:
		var src := order[i]
		var ux := _q16(raw_x[src] / size)
		var uz := _q16(raw_z[src] / size)
		var r := [_q16(raw_r[src * 4]), _q16(raw_r[src * 4 + 1]), _q16(raw_r[src * 4 + 2]), _q16(raw_r[src * 4 + 3])]
		local[i * 2] = ux / 65535.0 * size
		local[i * 2 + 1] = uz / 65535.0 * size
		for k in 4:
			rnd[i * 4 + k] = r[k] / 65535.0
		packed[i * 4] = ux | (uz << 16)
		packed[i * 4 + 1] = r[0] | (r[1] << 16)
		packed[i * 4 + 2] = r[2] | (r[3] << 16)
		packed[i * 4 + 3] = 0
	return {"local": local, "rnd": rnd, "packed": packed}


# Math.round on a non-negative value: half rounds up.
static func _q16(u: float) -> int:
	return clampi(int(floor(u * 65535.0 + 0.5)), 0, 65535)


# Per-tile mirror bits that break cross-tile repetition without moving roots.
static func flip_bits(tx: int, tz: int) -> Vector2i:
	var h := (imul(tx, 374761393) ^ imul(tz, 668265263)) & M32
	return Vector2i((h >> 16) & 1, (h >> 17) & 1)


# Painted grass scatter: tight clumps of `clump_k` blades fanning outward from shared roots
# placed on a shuffled jittered grid. Ranks are interleaved by blade-within-clump
# (rank = j * clumps + c), so rank 0..clumps-1 holds blade 0 of every clump (the clump centre
# sampled by grass_bake_painted.gdshader) and any mid-distance prefix (e.g. 1 of 4 blades)
# keeps every clump represented with no bare gaps.
static func generate_painted(count: int, size: float, seed: int, clump_k: int = 5) -> Dictionary:
	var clumps := maxi(1, count / clump_k)
	var total := clumps * clump_k
	var rng := PackedInt64Array([(seed ^ 0x517cc1b7) & M32])
	var side := int(ceil(sqrt(float(clumps))))
	var cell := size / side
	var c_x := PackedFloat32Array()
	var c_z := PackedFloat32Array()
	c_x.resize(clumps)
	c_z.resize(clumps)
	for c in clumps:
		var gx := c % side
		var gz := c / side
		var ox := (gx + 0.5 + (rnd_next(rng) - 0.5) * 0.94) * cell
		var oz := (gz + 0.5 + (rnd_next(rng) - 0.5) * 0.94) * cell
		c_x[c] = fmod(fmod(ox, size) + size, size)
		c_z[c] = fmod(fmod(oz, size) + size, size)
	var order := PackedInt32Array()
	order.resize(clumps)
	for c in clumps:
		order[c] = c
	for i in range(clumps - 1, 0, -1):
		var j := int(floor(rnd_next(rng) * (i + 1)))
		var tmp := order[i]
		order[i] = order[j]
		order[j] = tmp
	var local := PackedFloat32Array()
	var rnd := PackedFloat32Array()
	var packed := PackedInt64Array()
	local.resize(total * 2)
	rnd.resize(total * 4)
	packed.resize(total * 4)
	for ci in clumps:
		var src := order[ci]
		var ax := c_x[src]
		var az := c_z[src]
		var a0 := rnd_next(rng) * TAU
		var cr := 0.08 + rnd_next(rng) * 0.15
		var clump_w := rnd_next(rng)
		for j in clump_k:
			var ang: float
			var rad: float
			if j == 0:
				ang = a0 + (rnd_next(rng) - 0.5) * 0.45
				rad = cr * 0.18
			else:
				ang = a0 + float(j) * (TAU / clump_k) + (rnd_next(rng) - 0.5) * 0.75
				rad = cr * (0.45 + 0.55 * rnd_next(rng))
			var ox := fmod(fmod(ax + cos(ang) * rad, size) + size, size)
			var oz := fmod(fmod(az + sin(ang) * rad, size) + size, size)
			var r0 := rnd_next(rng)
			var r1 := rnd_next(rng)
			var r2 := fmod(fmod(ang / TAU, 1.0) + 1.0, 1.0)
			var r3 := clump_w
			var rank := j * clumps + ci
			var ux := _q16(ox / size)
			var uz := _q16(oz / size)
			var q0 := _q16(r0)
			var q1 := _q16(r1)
			var q2 := _q16(r2)
			var q3 := _q16(r3)
			local[rank * 2] = ux / 65535.0 * size
			local[rank * 2 + 1] = uz / 65535.0 * size
			rnd[rank * 4] = q0 / 65535.0
			rnd[rank * 4 + 1] = q1 / 65535.0
			rnd[rank * 4 + 2] = q2 / 65535.0
			rnd[rank * 4 + 3] = q3 / 65535.0
			packed[rank * 4] = ux | (uz << 16)
			packed[rank * 4 + 1] = q0 | (q1 << 16)
			packed[rank * 4 + 2] = q2 | (q3 << 16)
			packed[rank * 4 + 3] = 0
	return {"local": local, "rnd": rnd, "packed": packed, "clumps": clumps}
