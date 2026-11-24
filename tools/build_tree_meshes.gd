extends SceneTree

# Turns the tree meshes the low tier draws (data/valley/meshes/*.bin, three.js layout) into
# compressed Godot meshes in data/trees/, so the scene loads them natively with no decode loop.
# Run after tools/export_world.mjs: godot --headless --path . -s tools/build_tree_meshes.gd
#
# Vertex layout in Godot:
#   VERTEX, NORMAL         as in the game (unit-height tree)
#   UV                     (u, 1 - v): the leaf atlas ships top row first, three samples it flipped
#   CUSTOM0 (RGBA float)   linear vertex colour rgb, crown.x (pocket AO, reaches 1.08)
#   CUSTOM1 (RG float)     crown.y (height in crown), crown.z (1 leaf card, 0 bark)
# Float customs because COLOR is stored as 8-bit and the darkest greens sit near 0.065 linear.

const SRC := "res://data/valley"
const OUT := "res://data/trees"


func _init() -> void:
	var meshes: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SRC.path_join("meshes.json")))
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SRC.path_join("meta.json")))
	var hero_lod := "hero2" if int(meta.tiers.low.treeDetail) >= 2 else "hero1"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var built := 0
	for m in meshes.meshes:
		var lod: String = m.lod
		if lod != hero_lod and lod != "mid" and lod != "hero":
			continue
		var name: String = m.file.get_file().get_basename()
		# Level names in the shipped pack do not depend on the tier's hero detail.
		var out_name := name.replace("_" + hero_lod, "_hero") if lod == hero_lod else name
		var mesh := _build(SRC.path_join(m.file), m)
		if mesh == null:
			quit(1)
			return
		var path := OUT.path_join(out_name + ".res")
		var err := ResourceSaver.save(mesh, path, ResourceSaver.FLAG_COMPRESS)
		if err != OK:
			printerr("save %s: %s" % [path, error_string(err)])
			quit(1)
			return
		print("%s <- %s: %d vertices, %d triangles" % [path, m.file, int(m.vertexCount), int(m.triangleCount)])
		built += 1
	print("BUILD_TREE_MESHES %d meshes (hero level %s)" % [built, hero_lod])
	quit(0)


func _build(file: String, m: Dictionary) -> ArrayMesh:
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
		return null
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	verts.resize(vc)
	norms.resize(vc)
	uvs.resize(vc)
	c0.resize(vc * 4)
	c1.resize(vc * 2)
	for i in vc:
		verts[i] = Vector3(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2])
		norms[i] = Vector3(nrm[i * 3], nrm[i * 3 + 1], nrm[i * 3 + 2])
		uvs[i] = Vector2(uv[i * 2], 1.0 - uv[i * 2 + 1])
		c0[i * 4] = col[i * 3]
		c0[i * 4 + 1] = col[i * 3 + 1]
		c0[i * 4 + 2] = col[i * 3 + 2]
		c0[i * 4 + 3] = crown[i * 3]
		c1[i * 2] = crown[i * 3 + 1]
		c1[i * 2 + 1] = crown[i * 3 + 2]
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
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, fmt)
	return mesh


static func _f32(bytes: PackedByteArray, offset: int, count: int) -> PackedFloat32Array:
	return bytes.slice(offset, offset + count * 4).to_float32_array()
