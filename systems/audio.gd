extends Node

# Slice W5: Procedural ambient soundscape & surface-aware footsteps driver.
#
# Drives window.__swAudio (web/shell.html, ported from Stillwater src/audio.js) on Web, where all
# DSP runs natively on the browser audio thread (0.000 ms main-thread per-frame DSP cost).
# Strictly obeys iOS Safari autoplay: never starts audio until the first user gesture unlocks it.
# Polls spatial proximity (lake, stream, waterfall, altitude, forest, TOD weights) at 4 Hz so
# GDScript overhead stays near-zero.

const UPDATE_PERIOD := 0.25

var world: RefCounted
var env_sys: Node
var _cam: Camera3D

var _stream_pts := PackedVector2Array()
var _lake_xz := Vector2.ZERO
var _lake_r := 260.0
var _has_lake := false
var _falls_xz := Vector2.ZERO
var _has_falls := false

var _on := true
var _muted := false
var _started := false
var _is_game := false
var _timer := 0.0
var frozen := false
var prof_us := 0


func setup(w: RefCounted, e: Node, is_game: bool) -> void:
	world = w
	env_sys = e
	_is_game = is_game


func _ready() -> void:
	process_priority = 110
	var lake: Dictionary = world.lake_info()
	if not lake.is_empty():
		_lake_xz = Vector2(float(lake.x), float(lake.z))
		_lake_r = float(lake.get("rx", 260.0))
		_has_lake = true
	var wf: Dictionary = world.waterfall_info()
	if not wf.is_empty():
		var pc: Array = wf.poolCenter
		_falls_xz = Vector2(float(pc[0]), float(pc[2]))
		_has_falls = true
	# Thin stream polyline (~80 pts) so 4 Hz nearest-stream check takes < 4 us.
	var sp: PackedVector2Array = world.stream_points()
	for i in range(0, sp.size(), 8):
		_stream_pts.append(sp[i])
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__swAudio && window.__swAudio.setArmed(%s);" % ("true" if (_is_game and _on) else "false"))


func set_on(v: bool) -> void:
	_on = v
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__swAudio && (window.__swAudio.setEnabled(%s), window.__swAudio.setArmed(%s));" % [
			"true" if _on else "false", "true" if (_is_game and _on) else "false"])


func is_on() -> bool:
	return _on


func set_frozen(v: bool) -> void:
	frozen = v


func unlock() -> void:
	if not _on:
		return
	if OS.has_feature("web"):
		_started = bool(JavaScriptBridge.eval("window.__swAudio ? window.__swAudio.unlock() : false"))
	else:
		_started = true


func is_started() -> bool:
	if OS.has_feature("web"):
		_started = bool(JavaScriptBridge.eval("!!(window.__swAudio && window.__swAudio.started)"))
	return _started


func set_muted(m: bool) -> void:
	_muted = m
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__swAudio && window.__swAudio.setMuted(%s);" % ("true" if _muted else "false"))


func toggle_mute() -> bool:
	set_muted(not _muted)
	return _muted


func is_muted() -> bool:
	return _muted


func on_step(pos: Vector2, ground_y: float, intensity: float) -> void:
	if not _on or _muted or not OS.has_feature("web"):
		return
	if not _started and not is_started():
		return
	var surf := "grass"
	if ground_y < world.water_level + 0.15:
		surf = "water"
	elif world.trail_at(pos.x, pos.y) > 0.22:
		surf = "gravel"
	elif ground_y > 290.0:
		surf = "rock"
	JavaScriptBridge.eval("window.__swAudio && window.__swAudio.footstep('%s', %.3f);" % [surf, intensity])


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	if not frozen and _on and _is_game:
		_timer += delta
		if _timer >= UPDATE_PERIOD:
			_timer = 0.0
			_push_spatial()
	prof_us = Time.get_ticks_usec() - t0


func _push_spatial() -> void:
	if not OS.has_feature("web"):
		return
	if not _started:
		_started = bool(JavaScriptBridge.eval("!!(window.__swAudio && window.__swAudio.started)"))
		if not _started:
			return
	if _cam == null or not is_instance_valid(_cam):
		var vp := get_viewport()
		if vp != null:
			_cam = vp.get_camera_3d()
		if _cam == null:
			return
	var cp := _cam.global_position
	var rx := _cam.global_basis.x
	var right_xz := Vector2(rx.x, rx.z)
	if right_xz.length_squared() > 1e-4:
		right_xz = right_xz.normalized()
	else:
		right_xz = Vector2.RIGHT
	var p2 := Vector2(cp.x, cp.z)

	var bio: Dictionary = world.biome_at(cp.x, cp.z)
	var forest := float(bio.get("forest", 0.0))
	var alt := clampf((cp.y - world.water_level) / 420.0, 0.0, 1.0)
	var wind := 0.24 + (0.25 * float(env_sys.mist_weight) if env_sys != null else 0.0)

	var lake_near := 0.0
	if _has_lake:
		var dl := maxf(0.0, p2.distance_to(_lake_xz) - _lake_r)
		lake_near = clampf(1.0 - dl / 140.0, 0.0, 1.0)
		lake_near *= lake_near

	var stream_near := 0.0
	var stream_pan := 0.0
	if not _stream_pts.is_empty():
		var best_d2 := 1e18
		var best_pt := Vector2.ZERO
		for pt in _stream_pts:
			var d2 := p2.distance_squared_to(pt)
			if d2 < best_d2:
				best_d2 = d2
				best_pt = pt
		var ds := sqrt(best_d2)
		stream_near = clampf(1.0 - ds / 55.0, 0.0, 1.0)
		stream_near *= stream_near
		if ds > 1.0 and stream_near > 0.01:
			stream_pan = right_xz.dot((best_pt - p2) / ds)

	var falls_near := 0.0
	var falls_pan := 0.0
	if _has_falls:
		var df := p2.distance_to(_falls_xz)
		falls_near = clampf(1.0 - df / 220.0, 0.0, 1.0)
		falls_near *= falls_near
		if df > 1.0 and falls_near > 0.01:
			falls_pan = right_xz.dot((_falls_xz - p2) / df)

	var night_w := float(env_sys.night_weight) if env_sys != null else 0.0
	var day_w := clampf(1.0 - night_w * 1.4, 0.0, 1.0)
	JavaScriptBridge.eval("window.__swAudio && window.__swAudio.update(%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f);" % [
		wind, forest, lake_near, stream_near, stream_pan, falls_near, falls_pan, day_w, night_w, alt])
