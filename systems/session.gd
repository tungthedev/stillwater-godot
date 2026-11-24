extends Node

# Stillwater's session (src/game/session.js): title -> transition -> play, pause, place
# discovery and the HUD feed.
#
# - title: the camera circles the lake 38 m up (titleCam) while the title fades in; a click or
#   tap anywhere starts. On desktop that click also captures the mouse (pointer lock).
# - transition: the title and the scene fade out; once dark the walker is placed at the start
#   (trail point 2 facing point 14). 2.3 s after the start press, play begins and the scene
#   fades back in; 4 s later the hint toast shows.
# - play: the walker drives the camera. Desktop pauses when the pointer lock is lost (Esc), on the
#   transition only, so a browser that refuses the lock still plays; touch pauses with the pause
#   button. The pause sheet resumes on a click or tap (desktop asks for the lock again).
# - place discovery: entering a place's radius the first time shows its card.
# The sim freezes while paused, as Stillwater's loop does.
#
# `interactables` is the list W3 fills (benches the walker can sit on, later more kinds); the
# player reads benches from it.

const Flags := preload("res://systems/flags.gd")
const TITLE_FADE_IN := 0.9
const FADE_OUT := 2.2
const START_DELAY := 2.3
const HINT_DELAY := 4.0

var world: RefCounted
var input: Node
var player: Node
var hud: CanvasLayer
var cam: Camera3D
var walk_cam: Node
var bench_sys: Node
var dev_toggle: Callable

var mode := "title"
var paused := false
var fade := 0.0
var fade_target := 1.0
var t := 0.0
var visited := {}
var pois: Array = []
var hours := 16.0
var interactables: Array[Dictionary] = []
var _start_at := -1.0
var _hint_at := -1.0
var _was_captured := false
var _placed := false
var _suspended := false
var prof_us := 0


func setup(nodes: Dictionary) -> void:
	world = nodes.world
	input = nodes.input
	player = nodes.player
	hud = nodes.hud
	cam = nodes.cam
	walk_cam = nodes.walk_cam
	bench_sys = nodes.bench
	dev_toggle = nodes.dev_toggle
	pois = world.meta.game.pois
	hours = nodes.hours


func _ready() -> void:
	process_priority = -20
	walk_cam.external = true
	hud.set_touch_mode(input.touch)
	input.mode_changed.connect(hud.set_touch_mode)
	input.stick_changed.connect(hud.set_stick)
	input.action.connect(_on_action)
	hud.button.connect(func(a: String) -> void: input.trigger(a) if a != "dev" else dev_toggle.call())
	hud.start_pressed.connect(start_game)
	hud.resume_pressed.connect(_resume)
	player.toast.connect(hud.toast)
	player.sat.connect(func(on: bool, bench: bool) -> void:
		hud.set_prompt("")
		if on:
			hud.toast("You sit. The day moves on without you." if bench else "You sit in the grass for a while."))
	player.place_at_start()
	_sync_input()
	hud.show_title()


func _sync_input() -> void:
	input.set_active(mode == "play")
	input.set_paused(paused)


func _can_lock() -> bool:
	return not input.touch and not input.ios


func start_game() -> void:
	if mode != "title":
		return
	mode = "transition"
	_sync_input()
	fade_target = 0.0
	hud.hide_title()
	_start_at = t + START_DELAY
	if _can_lock():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func set_paused(v: bool) -> void:
	paused = v
	player.paused = v
	_sync_input()
	hud.set_paused(v)


func _resume() -> void:
	if not paused:
		return
	set_paused(false)
	if _can_lock():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_action(a: String) -> void:
	match a:
		"pause":
			if mode != "play":
				return
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			set_paused(true)
		"toggleHud":
			if mode == "play":
				hud.toggle_hud()
		"dev":
			dev_toggle.call()


# A click on the play surface (no control took it) asks for the pointer lock again.
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.device != InputEvent.DEVICE_ID_EMULATION:
		if mode == "play" and not paused and _can_lock() and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	hud.prof_us = 0
	_tick(delta)
	prof_us = maxi(0, (Time.get_ticks_usec() - t0) - hud.prof_us)


func _tick(delta: float) -> void:
	# The bench owns the camera while it runs; the walk resumes where it was afterwards.
	if bench_sys.running != _suspended:
		_suspended = bench_sys.running
		walk_cam.external = not _suspended
		player.drive = not _suspended and _placed
		input.set_active(mode == "play" and not _suspended)
		hud.visible = not _suspended
		if not _suspended and _placed:
			player.snap()
	if _suspended:
		return
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if _was_captured and not captured and mode == "play" and not input.touch and not input.ios:
		set_paused(true)
	_was_captured = captured
	if paused:
		return
	var dt := minf(delta, 0.05)
	t += dt
	fade += (fade_target - fade) * (1.0 - exp(-dt * (TITLE_FADE_IN if fade_target > fade else FADE_OUT)))
	var tf := Time.get_ticks_usec()
	hud.set_fade(fade)
	hud.prof_us += Time.get_ticks_usec() - tf
	if mode == "title" or (mode == "transition" and not _placed):
		_title_cam(t)
	if mode == "transition" and fade_target == 0.0 and fade < 0.02 and not _placed:
		_placed = true
		player.place_at_start()
		_dev_spawn()
		player.drive = true
		player.snap()
	if mode == "transition" and t >= _start_at:
		mode = "play"
		player.enabled = true
		_sync_input()
		fade_target = 1.0
		hud.show_hud(true)
		_hint_at = t + HINT_DELAY
	if _hint_at > 0.0 and t >= _hint_at:
		_hint_at = -1.0
		hud.toast("Left side walks · Right side looks" if input.touch else "Q follows the trail · E to sit and rest")
	player.benches = _benches()
	if mode == "play":
		_check_pois()
	var p: Vector2 = player.pos
	var th := Time.get_ticks_usec()
	hud.update({
		"yaw": player.yaw, "altitude": world.height(cam.position.x, cam.position.z), "hours": hours,
		"distance": player.distance, "climb": player.climb, "pois": pois, "pos": p,
		"bench": player.sitting.is_empty() and not player.nearest_bench().is_empty(),
		"sitting": not player.sitting.is_empty(), "auto_walk": player.auto_walk,
	})
	hud.prof_us += Time.get_ticks_usec() - th


# Checks only: ?spawn=x,z,yaw starts the walk elsewhere (tools/free_walk_check.mjs legs).
func _dev_spawn() -> void:
	var v := Flags.value("spawn")
	if v == "":
		return
	var p := v.split(",")
	player.pos = Vector2(float(p[0]), float(p[1]))
	if p.size() > 2:
		player.yaw = float(p[2])
		player.yaw_t = player.yaw
	player.eye_y = world.height(player.pos.x, player.pos.y) + player.EYE
	player.trail_idx = 0


func _benches() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for it in interactables:
		if it.get("kind", "") == "bench":
			out.append(it)
	return out


func _check_pois() -> void:
	for p in pois:
		if visited.has(p.name):
			continue
		if Vector2(p.x - player.pos.x, p.z - player.pos.y).length() < float(p.r):
			visited[p.name] = true
			hud.place(p.name, p.sub)


# session.js titleCam: orbit the lake, look between the summit and the lake.
func _title_cam(tt: float) -> void:
	var lake: Dictionary = world.meta.game.lake
	var summit: Dictionary = world.meta.game.summit
	var a := 0.25 + tt * 0.012
	var x: float = lake.x + cos(a) * 520.0
	var z: float = lake.z + sin(a) * 420.0
	var g: float = world.height(x, z)
	var y := maxf(g, world.water_level) + 38.0 + sin(tt * 0.05) * 6.0
	var tx: float = summit.x * 0.6 + lake.x * 0.4
	var tz: float = summit.z * 0.6 + lake.z * 0.4
	var ty: float = world.height(tx, tz) + 40.0
	cam.position = Vector3(x, y, z)
	cam.look_at(Vector3(tx, ty, tz), Vector3.UP)
