extends Node

# Stillwater's walker (src/player.js) on Stillwater's frame loop (src/engine/app.js): the
# simulation steps at a fixed 60 Hz (frame time capped at 50 ms) and the camera is interpolated
# between the last two steps for the render.
#
# Feel: 2.1 m/s walk, 4.6 m/s stride (Shift), analog stick speed, grade slows uphill (x0.42..1.15,
# stops above a 0.95 grade), velocity eases in at rate 6 and out at 8, look eases at rate 18,
# eye 1.68 m above the ground eased at rate 12, head bob, idle breathing and a small roll into
# turns and strafes. Trees block (the full canonical list, as Stillwater), the valley edge turns
# the walker back at 1850 m. Trail follow (Q / Trail) walks the trail toward the summit and
# steers the view unless the player looked around in the last 3.5 s. Sit (E / Sit) sits in the
# grass, or on the nearest bench within 4 m when one is registered in `benches` (W3 adds them).
#
# Ground is the height the terrain draws (near map blended into the far map past 1828 m), so the
# eye never sinks into the rendered ground near the valley edge; Stillwater samples the near map
# only, which differs between 1828 m and the 1850 m boundary.
#
# Hooks for later slices: `colliders` (callables (pos: Vector2, ground: float) -> Vector2 for
# rocks, props, village), `benches` (dictionaries x, z, y, ry), `ground_override` (callable
# (x, z, g) -> g for the bridge), and the `step` signal (surface sounds).

signal toast(msg: String)
signal sat(on: bool, bench: bool)
signal step(speed: float)

const FIXED_DT := 1.0 / 60.0
const MAX_FRAME_DT := 0.05
const EYE := 1.68
const RADIUS := 0.35
const BOUNDARY := 1850.0

var world: RefCounted
var input: Node
var cam: Camera3D

var pos := Vector2.ZERO
var vel := Vector2.ZERO
var yaw := 0.0
var pitch := 0.0
var yaw_t := 0.0
var pitch_t := 0.0
var roll := 0.0
var eye_y := 0.0
var bob := 0.0
var last_step_sign := 1.0
var enabled := false
var sitting := {}
var sit_blend := 0.0
var _last_sit := {}
var auto_walk := false
var last_look := -10.0
var distance := 0.0
var climb := 0.0
var last_y := NAN
var speed_now := 0.0
var trail_idx := 0
var t := 0.0
var trail := PackedVector2Array()
var colliders: Array[Callable] = []
var benches: Array[Dictionary] = []
var ground_override := Callable()
var _warned_until := -1.0

# Driving the camera: off while the bench or the title camera owns it.
var drive := false
var _acc := 0.0
var _prev_pos := Vector3.ZERO
var _prev_q := Quaternion.IDENTITY
var _cur_pos := Vector3.ZERO
var _cur_q := Quaternion.IDENTITY
# Most sim steps in one frame, and the script time of this frame, for the bench and walk checks.
var prof_us := 0


func setup(w: RefCounted, input_node: Node, camera: Camera3D) -> void:
	world = w
	input = input_node
	cam = camera
	trail = world.trail_points()
	input.action.connect(_on_action)


func _ready() -> void:
	# Before terrain, trees and grass (priority 100) read the camera this frame.
	process_priority = -10


func _on_action(a: String) -> void:
	if not enabled:
		return
	if a == "autoWalk":
		auto_walk = not auto_walk
		var hint := "Following the trail · tap Trail to stop" if input.touch else "Following the trail · Q to stop"
		toast.emit(hint if auto_walk else "Free walking")
	elif a == "sit":
		toggle_sit()


func ground(x: float, z: float) -> float:
	var g: float = world.height(x, z)
	if ground_override.is_valid():
		g = ground_override.call(x, z, g)
	return g


func place_at_start() -> void:
	var a := trail[2]
	var b := trail[14]
	pos = a
	vel = Vector2.ZERO
	yaw = atan2(-(b.x - a.x), -(b.y - a.y))
	yaw_t = yaw
	pitch = -0.02
	pitch_t = pitch
	eye_y = world.height(a.x, a.y) + EYE
	trail_idx = 0


func nearest_bench() -> Dictionary:
	var best := {}
	var bd := 1e9
	for b in benches:
		var d := Vector2(b.x - pos.x, b.z - pos.y).length()
		if d < bd:
			bd = d
			best = b
	return best if bd < 4.0 else {}


func toggle_sit() -> void:
	if not sitting.is_empty():
		sitting = {}
		sat.emit(false, false)
		return
	var b := nearest_bench()
	if not b.is_empty():
		sitting = {"x": b.x, "z": b.z, "y": b.y + 0.72, "yaw": atan2(-sin(b.ry), -cos(b.ry)), "bench": true}
	else:
		sitting = {"x": pos.x, "z": pos.y, "y": ground(pos.x, pos.y) + 0.95, "yaw": yaw, "bench": false}
	yaw_t = sitting.yaw
	pitch_t = -0.05
	sat.emit(true, sitting.bench)


# Snap the interpolation to the current state (after a teleport such as the start placement).
func snap() -> void:
	_acc = 0.0
	_sim_camera()
	_prev_pos = _cur_pos
	_prev_q = _cur_q
	_apply(1.0)


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	if drive:
		_acc += minf(MAX_FRAME_DT, delta)
		while _acc >= FIXED_DT:
			_prev_pos = _cur_pos
			_prev_q = _cur_q
			sim_step(FIXED_DT)
			_acc -= FIXED_DT
		_apply(_acc / FIXED_DT)
	prof_us = Time.get_ticks_usec() - t0


func _apply(alpha: float) -> void:
	cam.position = _prev_pos.lerp(_cur_pos, alpha)
	cam.quaternion = _prev_q.slerp(_cur_q, alpha)


# One fixed step of player.js update().
func sim_step(dt: float) -> void:
	t += dt
	if enabled:
		var look: Vector2 = input.consume_look()
		if look != Vector2.ZERO:
			yaw_t -= look.x
			pitch_t = clampf(pitch_t - look.y, -1.45, 1.45)
			last_look = t
	var sm := 1.0 - exp(-dt * 18.0)
	yaw += (yaw_t - yaw) * sm
	pitch += (pitch_t - pitch) * sm

	var mv: Vector2 = input.get_move() if (sitting.is_empty() and enabled) else Vector2.ZERO
	var fwd := mv.y
	var side := mv.x
	var move_mag := minf(1.0, mv.length())
	var jog: bool = enabled and input.is_held("stride")
	var dir := Vector2.ZERO
	var sy := sin(yaw)
	var cy := cos(yaw)
	var following := auto_walk and sitting.is_empty() and move_mag == 0.0
	if following:
		dir = _follow_trail(dt)
	elif move_mag > 0.0:
		dir = Vector2(-sy * fwd + cy * side, -cy * fwd - sy * side).normalized()
	var g0 := ground(pos.x, pos.y)
	var analog := 1.0 if following else move_mag
	var speed := (4.6 if jog else 2.1) * (analog if analog > 0.0 else 1.0)
	var moving := dir != Vector2.ZERO
	if moving:
		var ahead := ground(pos.x + dir.x * 1.5, pos.y + dir.y * 1.5)
		var grade := (ahead - g0) / 1.5
		speed *= clampf(1.0 - grade * 1.3, 0.42, 1.15)
		if grade > 0.95:
			speed = 0.0
		if ahead < world.water_level - 0.85:
			speed = 0.0
		if g0 < world.water_level:
			speed *= 0.55
	var target := dir * speed
	vel = vel.lerp(target, 1.0 - exp(-dt * (6.0 if moving else 8.0)))
	if sitting.is_empty():
		pos += vel * dt
		pos = world.collide_trees(pos, RADIUS)
		for c in colliders:
			pos = c.call(pos, g0)
		var e := maxf(absf(pos.x), absf(pos.y))
		if e > BOUNDARY:
			pos *= BOUNDARY / e
			if t > _warned_until:
				_warned_until = t + 8.0
				toast.emit("The mountains turn you gently back")
	var sp := vel.length()
	speed_now = sp
	distance += sp * dt
	var g := ground(pos.x, pos.y)
	if not is_nan(last_y) and g > last_y:
		climb += g - last_y
	last_y = g

	var stride := 1.25 if jog else 0.78
	bob += sp * dt / stride * PI
	var bob_amp := minf(1.0, sp / 2.0) * (0.055 if jog else 0.035)
	var bob_y := -absf(sin(bob)) * bob_amp * 1.4 + bob_amp * 0.7
	var bob_x := sin(bob) * bob_amp * 0.6
	var step_sign := signf(sin(bob))
	if step_sign != last_step_sign and sp > 0.5:
		step.emit(minf(1.2, sp / 2.2))
	last_step_sign = step_sign
	var breath := sin(t * 1.6) * 0.008 * (1.0 - minf(1.0, sp))

	var eye_target := g + EYE
	eye_y += (eye_target - eye_y) * (1.0 - exp(-dt * 12.0))
	if absf(eye_target - eye_y) > 3.0:
		eye_y = eye_target

	sit_blend += ((0.0 if sitting.is_empty() else 1.0) - sit_blend) * (1.0 - exp(-dt * 2.2))
	var p := Vector3(pos.x, eye_y + bob_y + breath, pos.y)
	if not sitting.is_empty() or sit_blend > 0.001:
		var s := sitting if not sitting.is_empty() else _last_sit
		if not s.is_empty():
			_last_sit = s
			p = p.lerp(Vector3(s.x, s.y, s.z), sit_blend)
			if not sitting.is_empty():
				pos += (Vector2(s.x, s.z) - pos) * 0.02
	var turn := yaw_t - yaw
	roll += (-side * 0.012 - turn * 0.05 - roll) * (1.0 - exp(-dt * 4.0))
	_cur_pos = Vector3(p.x + cos(yaw) * bob_x, p.y, p.z - sin(yaw) * bob_x)
	_cur_q = Basis.from_euler(Vector3(pitch + bob_y * 0.15, yaw, roll), EULER_ORDER_YXZ).get_rotation_quaternion()


# The camera pose of the current state without stepping (used by snap).
func _sim_camera() -> void:
	_cur_pos = Vector3(pos.x, eye_y, pos.y)
	_cur_q = Basis.from_euler(Vector3(pitch, yaw, roll), EULER_ORDER_YXZ).get_rotation_quaternion()


func _follow_trail(dt: float) -> Vector2:
	var n := trail.size()
	var bi := trail_idx
	var bd := 1e18
	for i in range(maxi(0, trail_idx - 40), mini(n, trail_idx + 60)):
		var d := trail[i].distance_squared_to(pos)
		if d < bd:
			bd = d
			bi = i
	if bd > 400.0:
		for i in n:
			var d := trail[i].distance_squared_to(pos)
			if d < bd:
				bd = d
				bi = i
	trail_idx = bi
	var ti := mini(n - 1, bi + 4)
	if bi >= n - 3:
		auto_walk = false
		toast.emit("You have reached the summit")
	var to := trail[ti] - pos
	var dir := to / maxf(to.length(), 1e-6) if to.length() > 0.0 else Vector2(0.0, -1.0)
	if t - last_look > 3.5:
		var desired := atan2(-dir.x, -dir.y)
		var d := desired - yaw_t
		d = atan2(sin(d), cos(d))
		yaw_t += d * (1.0 - exp(-dt * 1.2))
		pitch_t += (-0.04 - pitch_t) * (1.0 - exp(-dt * 0.8))
	return dir
