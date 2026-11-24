extends RefCounted

# An instanced draw whose instance data is rewritten every frame, kept in two MultiMeshes on the
# same mesh that take turns: each push fills the other one and hides the idle one. Hidden rather
# than given zero instances, because the renderer's primitive count (the bench's tris) counts a
# zero-instance multimesh as one instance.
#
# Why not one MultiMesh: Godot's GLES3 renderer disables the instance attributes after every
# multimesh draw and re-enables them with the same buffer before the next. Chrome's ANGLE then
# keeps drawing the instance data from the first frames, however the buffer is re-uploaded
# (seen on ANGLE Vulkan, Intel UHD 730; tools/gl_stale_instances.html reproduces it in plain
# WebGL2). Pointing the attribute at a different buffer each frame makes it read the new data.
# Buffers written once (trees, clouds) are not affected.

var mms: Array[MultiMesh] = []
var mmis: Array[MultiMeshInstance3D] = []
var _cur := 0
var _on := true


func _init(parent: Node, mesh: Mesh, capacity: int, aabb: AABB) -> void:
	for i in 2:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = capacity
		mm.visible_instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.custom_aabb = aabb
		mmi.visible = i == 0
		parent.add_child(mmi)
		mms.append(mm)
		mmis.append(mmi)


# buf holds instance_count instances in MultiMesh.buffer layout; the first count are drawn.
func push(buf: PackedFloat32Array, count: int) -> void:
	_cur = 1 - _cur
	mms[_cur].buffer = buf
	mms[_cur].visible_instance_count = count
	mmis[_cur].visible = _on
	mmis[1 - _cur].visible = false


func set_mesh(mesh: Mesh) -> void:
	for mm in mms:
		mm.mesh = mesh


func set_visible(on: bool) -> void:
	_on = on
	mmis[_cur].visible = on
	mmis[1 - _cur].visible = false
