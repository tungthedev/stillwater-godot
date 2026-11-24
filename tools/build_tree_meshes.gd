extends SceneTree

# Turns the tree meshes the low tier draws (data/valley/meshes/*.bin, three.js layout) into
# compressed Godot meshes in data/trees/, so the scene loads them natively with no decode loop.
# Run after tools/export_world.mjs: godot --headless --path . -s tools/build_tree_meshes.gd
#
# Surface layout in Godot:
#   Surface 0 (opaque: trunks, inner foliage cores, mid puffs; wound CW outward for cull_back):
#     VERTEX, NORMAL         as in the game (unit-height tree)
#     UV                     (u, 1 - v): leaf atlas ships top row first, three samples it flipped
#     CUSTOM0 (RGBA float)   linear vertex colour rgb, crown.x (pocket AO, reaches 1.08)
#     CUSTOM1 (RG float)     crown.y (height in crown), crown.z (1 solid foliage, 0 bark)
#   Surface 1 (alpha-tested leaf cards, omitted on opaque-only mid0 meshes):
#     VERTEX, NORMAL         as in the game (NORMAL is spherical crown-dome blobNormal)
#     UV                     (u, 1 - v)
#     CUSTOM0 (RGBA float)   linear vertex colour rgb, crown.x (pocket AO)
#     CUSTOM1 (RGBA float)   crown.y (height in crown), geometric card face normal xyz
#     CUSTOM2 (RGBA float)   local offset from card quad centre xyz, conifer flag w (1 pine/larch)
# Float customs because COLOR is stored as 8-bit and the darkest greens sit near 0.065 linear.

const SRC := "res://data/valley"
const OUT := "res://data/trees"
# Atlas layout (fluffy.js): u [0, 0.74] leaf cards, u [0.78, 0.88] solid foliage, u [0.9, 1] bark.
const CARD_U_MAX := 0.76


func _init() -> void:
	var meshes: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SRC.path_join("meshes.json")))
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SRC.path_join("meta.json")))
	var hero_lod := "hero2" if int(meta.tiers.low.treeDetail) >= 2 else "hero1"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var built := 0
	for m in meshes.meshes:
		var lod: String = m.lod
		if lod != hero_lod and lod != "mid0" and lod != "mid1" and lod != "hero":
			continue
		var name: String = m.file.get_file().get_basename()
		# Level names in the shipped pack do not depend on the tier's hero detail.
		var out_name := name.replace("_" + hero_lod, "_hero") if lod == hero_lod else name
		var res := _build(SRC.path_join(m.file), m)
		if res.is_empty():
			quit(1)
			return
		var mesh: ArrayMesh = res.mesh
		var path := OUT.path_join(out_name + ".res")
		var err := ResourceSaver.save(mesh, path, ResourceSaver.FLAG_COMPRESS)
		if err != OK:
			printerr("save %s: %s" % [path, error_string(err)])
			quit(1)
			return
		print("%s <- %s: %d surfaces (opaque %d tris, cards %d tris; flipped bark %d/%d, solid %d/%d)" % [
			path, m.file, mesh.get_surface_count(), res.opaque_tris, res.card_tris,
			res.bark_flipped, res.bark_tris, res.solid_flipped, res.solid_tris])
		built += 1
	print("BUILD_TREE_MESHES %d meshes (hero level %s)" % [built, hero_lod])
	quit(0)


func _build(file: String, m: Dictionary) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(file)
	var vc := int(m.vertexCount)
	var L: Dictionary = m.layout
	var pos := _f32(bytes, L.position.offset, vc * 3)
	var nrm := _f32(bytes, L.normal.offset, vc * 3)
	var uv := _f32(bytes, L.uv.offset, vc * 2)
	var col := _f32(bytes, L.color.offset, vc * 3)
	var crown := _f32(bytes, L.crown.offset, vc * 3)
	var idx := bytes.slice(int(L.index.offset), int(L.index.offset) + int(L.index.count) * 4).to_int32_array()
	if pos.size() != vc * 3 or idx.size() != int(L.index.count):
		printerr("%s: layout does not match file size" % file)
		return {}

	var op_idx := PackedInt32Array()
	var card_idx := PackedInt32Array()
	var bark_tris := 0
	var bark_flipped := 0
	var solid_tris := 0
	var solid_flipped := 0

	for t in range(0, idx.size(), 3):
		var i0 := idx[t]
		var i1 := idx[t + 1]
		var i2 := idx[t + 2]
		var is_bark := crown[i0 * 3 + 2] < 0.5 or uv[i0 * 2] > 0.895
		var is_card := not is_bark and uv[i0 * 2] <= CARD_U_MAX
		if is_card:
			card_idx.append(i0)
			card_idx.append(i1)
			card_idx.append(i2)
		else:
			var v0 := Vector3(pos[i0 * 3], pos[i0 * 3 + 1], pos[i0 * 3 + 2])
			var v1 := Vector3(pos[i1 * 3], pos[i1 * 3 + 1], pos[i1 * 3 + 2])
			var v2 := Vector3(pos[i2 * 3], pos[i2 * 3 + 1], pos[i2 * 3 + 2])
			# Godot front faces are CW: (v2 - v0).cross(v1 - v0) points in the front-face direction.
			var flip := false
			if is_bark:
				bark_tris += 1
				var navg := Vector3(
					nrm[i0 * 3] + nrm[i1 * 3] + nrm[i2 * 3],
					nrm[i0 * 3 + 1] + nrm[i1 * 3 + 1] + nrm[i2 * 3 + 1],
					nrm[i0 * 3 + 2] + nrm[i1 * 3 + 2] + nrm[i2 * 3 + 2])
				if (v2 - v0).cross(v1 - v0).dot(navg) < 0.0:
					flip = true
					bark_flipped += 1
			else:
				# Solid foliage cores and mid puffs come from three.js IcosahedronGeometry (CCW outward).
				solid_tris += 1
				flip = true
				solid_flipped += 1
			op_idx.append(i0)
			if flip:
				op_idx.append(i2)
				op_idx.append(i1)
			else:
				op_idx.append(i1)
				op_idx.append(i2)

	var mesh := ArrayMesh.new()
	var is_puff_only := card_idx.is_empty()
	var is_conifer := str(m.generator) == "fluffyPine" or str(m.generator) == "fluffyLarch"
	if not op_idx.is_empty():
		_add_opaque_surface(mesh, pos, nrm, uv, col, crown, op_idx, vc, is_puff_only)
	if not card_idx.is_empty():
		_add_card_surface(mesh, pos, nrm, uv, col, crown, card_idx, vc, is_conifer)
	return {
		"mesh": mesh,
		"opaque_tris": op_idx.size() / 3,
		"card_tris": card_idx.size() / 3,
		"bark_tris": bark_tris,
		"bark_flipped": bark_flipped,
		"solid_tris": solid_tris,
		"solid_flipped": solid_flipped,
	}


static func _add_opaque_surface(mesh: ArrayMesh, pos: PackedFloat32Array, nrm: PackedFloat32Array, uv: PackedFloat32Array,
		col: PackedFloat32Array, crown: PackedFloat32Array, src_idx: PackedInt32Array, vc: int, is_mid0: bool = false) -> void:
	var remap := PackedInt32Array()
	remap.resize(vc)
	remap.fill(-1)
	var used := PackedInt32Array()
	var idx := PackedInt32Array()
	idx.resize(src_idx.size())
	# Weld identical solid-foliage vertices on unindexed hero cores (cuts hero core vertices ~5x).
	var weld := {}
	for k in src_idx.size():
		var s := src_idx[k]
		var d := remap[s]
		if d < 0:
			var is_solid_fol := crown[s * 3 + 2] >= 0.5 and uv[s * 2] <= 0.895
			if is_solid_fol:
				var key := "%d,%d,%d" % [roundi(pos[s * 3] * 10000.0), roundi(pos[s * 3 + 1] * 10000.0), roundi(pos[s * 3 + 2] * 10000.0)]
				if weld.has(key):
					d = weld[key]
				else:
					d = used.size()
					weld[key] = d
					used.append(s)
			else:
				d = used.size()
				used.append(s)
			remap[s] = d
		idx[k] = d
	var n := used.size()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	verts.resize(n)
	norms.resize(n)
	uvs.resize(n)
	c0.resize(n * 4)
	c1.resize(n * 2)
	var solid_mask := PackedByteArray()
	solid_mask.resize(n)
	for j in n:
		var i := used[j]
		verts[j] = Vector3(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2])
		norms[j] = Vector3(nrm[i * 3], nrm[i * 3 + 1], nrm[i * 3 + 2])
		uvs[j] = Vector2(uv[i * 2], 1.0 - uv[i * 2 + 1])
		# fluffy.js boosts puff-only meshes (mid0, bush_mid1) by 1.08x colour and +0.18 coreAO;
		# undo that lift so opaque puffs match hero leaf-card crowns of the same species.
		var is_solid_fol := crown[i * 3 + 2] >= 0.5 and uv[i * 2] <= 0.895
		solid_mask[j] = 1 if is_solid_fol else 0
		var col_k := 0.89 if (is_mid0 and is_solid_fol) else 1.0
		var ao_v := maxf(0.28, crown[i * 3] - (0.16 if (is_mid0 and is_solid_fol) else 0.0))
		c0[j * 4] = col[i * 3] * col_k
		c0[j * 4 + 1] = col[i * 3 + 1] * col_k
		c0[j * 4 + 2] = col[i * 3 + 2] * col_k
		c0[j * 4 + 3] = ao_v
		c1[j * 2] = crown[i * 3 + 1]
		c1[j * 2 + 1] = crown[i * 3 + 2]
	if is_mid0:
		_shape_mid0_puffs(verts, solid_mask, idx)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_CUSTOM0] = c0
	arrays[Mesh.ARRAY_CUSTOM1] = c1
	arrays[Mesh.ARRAY_INDEX] = idx
	var fmt := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RG_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, fmt)


# Seats any detached mid0 puff snugly onto its nearest neighbour (eliminating floating conifer
# apex discs or isolated clumps on every species), reshapes squashed apex pancakes into soft
# rounded tips, and adds watertight multi-lobe radial scalloping at zero extra geometry cost.
static func _shape_mid0_puffs(verts: PackedVector3Array, solid_mask: PackedByteArray, idx: PackedInt32Array) -> void:
	var n := verts.size()
	var adj: Array = []
	adj.resize(n)
	for i in n:
		adj[i] = []
	for t in range(0, idx.size(), 3):
		var a := idx[t]
		var b := idx[t + 1]
		var c := idx[t + 2]
		if solid_mask[a] == 0 or solid_mask[b] == 0 or solid_mask[c] == 0:
			continue
		(adj[a] as Array).append(b)
		(adj[a] as Array).append(c)
		(adj[b] as Array).append(a)
		(adj[b] as Array).append(c)
		(adj[c] as Array).append(a)
		(adj[c] as Array).append(b)
	var seen := PackedByteArray()
	seen.resize(n)
	var comps: Array = []
	var centers: Array[Vector3] = []
	var radii: Array[Vector3] = []
	for i in n:
		if solid_mask[i] == 0 or seen[i] != 0 or (adj[i] as Array).is_empty():
			continue
		var comp := PackedInt32Array()
		var queue: Array[int] = [i]
		seen[i] = 1
		var bmin := verts[i]
		var bmax := verts[i]
		while not queue.is_empty():
			var u: int = queue.pop_back()
			comp.append(u)
			var p := verts[u]
			bmin = Vector3(minf(bmin.x, p.x), minf(bmin.y, p.y), minf(bmin.z, p.z))
			bmax = Vector3(maxf(bmax.x, p.x), maxf(bmax.y, p.y), maxf(bmax.z, p.z))
			for w in (adj[u] as Array):
				var wi: int = w
				if seen[wi] == 0:
					seen[wi] = 1
					queue.append(wi)
		comps.append(comp)
		centers.append((bmin + bmax) * 0.5)
		var r := (bmax - bmin) * 0.5
		radii.append(Vector3(maxf(r.x, 0.01), maxf(r.y, 0.01), maxf(r.z, 0.01)))

	var pc := comps.size()
	if pc <= 1:
		return
	var top_i := 0
	var second_y := -INF
	for i in pc:
		if centers[i].y > centers[top_i].y:
			top_i = i
	for i in pc:
		if i != top_i and centers[i].y > second_y:
			second_y = centers[i].y

	# 1. Seat detached/barely-touching puffs into their nearest neighbour; taper squashed apexes.
	for i in pc:
		var best_d := INF
		var best_j := -1
		var ci := centers[i]
		var ri := radii[i]
		for j in pc:
			if j == i:
				continue
			var cj := centers[j]
			var rj := radii[j]
			var dx := (ci.x - cj.x) / (ri.x + rj.x)
			var dy := (ci.y - cj.y) / (ri.y + rj.y)
			var dz := (ci.z - cj.z) / (ri.z + rj.z)
			var d := sqrt(dx * dx + dy * dy + dz * dz)
			if d < best_d:
				best_d = d
				best_j = j
		var comp: PackedInt32Array = comps[i]
		if best_j >= 0 and best_d > 0.74:
			var shift := (centers[best_j] - ci) * (1.0 - 0.66 / best_d)
			for vi in comp:
				verts[vi] += shift
			centers[i] = ci + shift
			ci = centers[i]
		if i == top_i and ri.y < ri.x * 0.80 and ci.y > second_y + 0.04:
			var new_ry := ri.y * 1.42
			var drop := ri.y * 0.22
			for vi in comp:
				var dv := verts[vi] - ci
				var ny := dv.y * 1.42
				var top_t := clampf(ny / maxf(new_ry, 0.01), 0.0, 1.0)
				var taper := 1.0 - 0.34 * top_t
				verts[vi] = Vector3(ci.x + dv.x * taper, ci.y + ny - drop, ci.z + dv.z * taper)
			centers[i] = Vector3(ci.x, ci.y - drop, ci.z)
			radii[i] = Vector3(ri.x, new_ry, ri.z)

	# 2. Watertight radial multi-lobe scalloping (preserves smooth crown-dome normals).
	for i in pc:
		var comp: PackedInt32Array = comps[i]
		var ci := centers[i]
		var p_seed := float(i) * 2.137 + ci.x * 11.3 + ci.y * 7.9 + ci.z * 13.7
		for vi in comp:
			var dv := verts[vi] - ci
			var dl := dv.length()
			if dl < 1e-5:
				continue
			var dir := dv / dl
			var lobe := sin(dir.x * 5.2 + dir.y * 4.7 + p_seed) * 0.55 \
				+ cos(dir.z * 6.3 - dir.x * 3.9 + p_seed * 1.7) * 0.45
			verts[vi] = ci + dv * (1.0 + lobe * 0.14)


static func _add_card_surface(mesh: ArrayMesh, pos: PackedFloat32Array, nrm: PackedFloat32Array, uv: PackedFloat32Array,
		col: PackedFloat32Array, crown: PackedFloat32Array, src_idx: PackedInt32Array, vc: int, is_conifer: bool = false) -> void:
	# Compute exact geometric face normal and local corner offset from quad centre for each card.
	# fluffy.js emits every leaf card as 4 unique vertices (b..b+3) and 2 triangles (b,b+1,b+2), (b+1,b+3,b+2).
	var face_n := PackedVector3Array()
	var card_off := PackedVector3Array()
	face_n.resize(vc)
	card_off.resize(vc)
	for t in range(0, src_idx.size(), 6):
		var a := src_idx[t]
		var b := src_idx[t + 1]
		var c := src_idx[t + 2]
		var d := src_idx[t + 4] if t + 5 < src_idx.size() else c
		var va := Vector3(pos[a * 3], pos[a * 3 + 1], pos[a * 3 + 2])
		var vb := Vector3(pos[b * 3], pos[b * 3 + 1], pos[b * 3 + 2])
		var vc_p := Vector3(pos[c * 3], pos[c * 3 + 1], pos[c * 3 + 2])
		var vd := Vector3(pos[d * 3], pos[d * 3 + 1], pos[d * 3 + 2])
		var fn := (vb - va).cross(vc_p - va)
		var fn_len := fn.length()
		fn = fn / fn_len if fn_len > 1e-6 else Vector3.UP
		var ctr := (va + vb + vc_p + vd) * 0.25
		for vi in [a, b, c, d]:
			var vp := Vector3(pos[vi * 3], pos[vi * 3 + 1], pos[vi * 3 + 2])
			face_n[vi] = fn
			card_off[vi] = vp - ctr

	var remap := PackedInt32Array()
	remap.resize(vc)
	remap.fill(-1)
	var used := PackedInt32Array()
	var idx := PackedInt32Array()
	idx.resize(src_idx.size())
	for k in src_idx.size():
		var s := src_idx[k]
		var d := remap[s]
		if d < 0:
			d = used.size()
			remap[s] = d
			used.append(s)
		idx[k] = d
	var n := used.size()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	var c2 := PackedFloat32Array()
	verts.resize(n)
	norms.resize(n)
	uvs.resize(n)
	c0.resize(n * 4)
	c1.resize(n * 4)
	c2.resize(n * 4)
	var con_w := 1.0 if is_conifer else 0.0
	for j in n:
		var i := used[j]
		verts[j] = Vector3(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2])
		norms[j] = Vector3(nrm[i * 3], nrm[i * 3 + 1], nrm[i * 3 + 2])
		uvs[j] = Vector2(uv[i * 2], 1.0 - uv[i * 2 + 1])
		c0[j * 4] = col[i * 3]
		c0[j * 4 + 1] = col[i * 3 + 1]
		c0[j * 4 + 2] = col[i * 3 + 2]
		c0[j * 4 + 3] = crown[i * 3]
		var fn := face_n[i]
		c1[j * 4] = crown[i * 3 + 1]
		c1[j * 4 + 1] = fn.x
		c1[j * 4 + 2] = fn.y
		c1[j * 4 + 3] = fn.z
		var off := card_off[i]
		c2[j * 4] = off.x
		c2[j * 4 + 1] = off.y
		c2[j * 4 + 2] = off.z
		c2[j * 4 + 3] = con_w
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_CUSTOM0] = c0
	arrays[Mesh.ARRAY_CUSTOM1] = c1
	arrays[Mesh.ARRAY_CUSTOM2] = c2
	arrays[Mesh.ARRAY_INDEX] = idx
	var fmt := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, fmt)


static func _f32(bytes: PackedByteArray, offset: int, count: int) -> PackedFloat32Array:
	return bytes.slice(offset, offset + count * 4).to_float32_array()
