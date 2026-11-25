extends Camera3D

# Bench poses from data/valley/web/meta.json (the same ones Stillwater's bench and capture use)
# plus Stillwater's bench walk (src/dev/bench.js): from the trailhead along the real trail at
# 2.0 m/s, eye 1.68 m above the ground, pitch -0.04, looking 8 m ahead.
# Pick the start mode with ?pose=<mode> on Web or
# `-- --pose=<mode>` on desktop; the UI's Pose button cycles them.

signal mode_changed(mode: String)

const MODES: Array[String] = ["trailhead", "forest", "walk"]
const WALK_SPEED := 2.0
const WALK_PITCH := -0.04
const LOOK_AHEAD := 8.0

var world: RefCounted
# The game (systems/session.gd) owns the camera; the bench takes it back while it runs.
var external := false
var mode_i := 0
var pose_override := ""
var t := 0.0
var walk_pts := PackedVector2Array()
var walk_dist := PackedFloat32Array()
var _walk_i := 1
var _treepop := false
var _tp_seq := -1


func setup(w: RefCounted) -> void:
	world = w


func _ready() -> void:
	var p: Dictionary = world.meta.poses
	fov = float(p.fovVerticalDeg)
	near = float(p.near)
	far = float(p.far)
	keep_aspect = Camera3D.KEEP_HEIGHT
	walk_pts = world.walk_points()
	walk_dist.resize(walk_pts.size())
	var acc := 0.0
	for i in walk_pts.size():
		if i > 0:
			acc += walk_pts[i].distance_to(walk_pts[i - 1])
		walk_dist[i] = acc
	var want := start_mode()
	if want != "" and MODES.find(want) < 0 and world.has_pose(want):
		set_pose_name(want)
	else:
		set_mode(maxi(0, MODES.find(want)))
	if OS.has_feature("web"):
		_treepop = bool(JavaScriptBridge.eval("new URLSearchParams(location.search).has('treepop')"))


static func start_mode() -> String:
	if OS.has_feature("web"):
		var v = JavaScriptBridge.eval("new URLSearchParams(location.search).get('pose') || ''")
		return str(v) if v != null else ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pose="):
			return a.substr(7)
	return ""


# Look checks only: ?pitch=<rad> / `-- --pitch=<rad>` tilts a bench pose like Stillwater's
# capture `&pitch=`, e.g. a close-up of the grass at the trailhead.
static func _pitch_override() -> String:
	if OS.has_feature("web"):
		var v = JavaScriptBridge.eval("new URLSearchParams(location.search).get('pitch') || ''")
		return str(v) if v != null else ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pitch="):
			return a.substr(8)
	return ""


func mode() -> String:
	return pose_override if pose_override != "" else MODES[mode_i]


func next_mode() -> void:
	set_mode((mode_i + 1) % MODES.size())


func set_pose_name(pose_name: String) -> void:
	var idx := MODES.find(pose_name)
	if idx >= 0:
		set_mode(idx)
		return
	pose_override = pose_name
	t = 0.0
	var s: Dictionary = world.pose(pose_name)
	position = Vector3(s.position[0], s.position[1], s.position[2])
	var pitch_over := _pitch_override()
	rotation = Vector3(float(s.pitch) if pitch_over.is_empty() else float(pitch_over), float(s.yaw), 0.0)
	mode_changed.emit(mode())


func set_mode(i: int) -> void:
	pose_override = ""
	mode_i = i
	t = 0.0
	if mode() != "walk":
		var s: Dictionary = world.pose(mode())
		position = Vector3(s.position[0], s.position[1], s.position[2])
		var pitch_over := _pitch_override()
		rotation = Vector3(float(s.pitch) if pitch_over.is_empty() else float(pitch_over), float(s.yaw), 0.0)
	else:
		_walk_i = 1
		_walk_to(0.0)
	mode_changed.emit(mode())


# Script time of this frame's _process, for the bench.
var prof_us := 0


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_tick(delta)
	prof_us = Time.get_ticks_usec() - t0


func _tick(delta: float) -> void:
	if _treepop and OS.has_feature("web"):
		var raw = JavaScriptBridge.eval("window.__tpCmd ? JSON.stringify(window.__tpCmd) : ''")
		if raw != null and str(raw) != "":
			var cmd = JSON.parse_string(str(raw))
			if cmd is Dictionary and int(cmd.get("seq", -1)) != _tp_seq:
				_tp_seq = int(cmd["seq"])
				var px_c: float = float(cmd["x"])
				var pz_c: float = float(cmd["z"])
				var py_c: float = float(cmd["y"]) if cmd.has("y") else (float(world.height_near(px_c, pz_c)) + float(world.meta.poses.eyeHeight))
				position = Vector3(px_c, py_c, pz_c)
				rotation = Vector3(float(cmd["pitch"]), float(cmd["yaw"]), 0.0)
				set_meta("tp_seq", _tp_seq)
		return
	if external:
		return
	if mode() == "walk":
		t += delta
		_walk_to(fmod(t * WALK_SPEED, walk_dist[walk_dist.size() - 1] - LOOK_AHEAD))


func _walk_to(s: float) -> void:
	var p := _at(s)
	var ahead := _at(s + LOOK_AHEAD)
	var eye := float(world.meta.poses.eyeHeight)
	position = Vector3(p.x, world.height_near(p.x, p.y) + eye, p.y)
	var d := ahead - p
	# three.js / Godot yaw: forward is -Z rotated by yaw about +Y.
	rotation = Vector3(WALK_PITCH, atan2(-d.x, -d.y), 0.0)


func _at(s: float) -> Vector2:
	var n := walk_pts.size()
	var i := _walk_i
	if i >= n or walk_dist[i - 1] > s:
		i = clampi(walk_dist.bsearch(s), 1, n - 1)
	else:
		while i < n - 1 and walk_dist[i] < s:
			i += 1
	_walk_i = i
	var span := walk_dist[i] - walk_dist[i - 1]
	var f := clampf((s - walk_dist[i - 1]) / maxf(span, 1e-3), 0.0, 1.0)
	return walk_pts[i - 1].lerp(walk_pts[i], f)
