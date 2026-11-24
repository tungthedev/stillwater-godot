extends Node

# Stillwater's input (src/engine/input.js with the game bindings of src/game/session.js), on
# Godot events. Units are CSS pixels: main.gd sets the window's content scale to the device pixel
# ratio, so event positions on Web and Stillwater's sensitivities and stick radius line up.
#
# - Keyboard: WASD / arrows move, Shift holds `stride`, Q `autoWalk`, E `sit`, H `toggleHud`,
#   Esc `pause`, G `dev` (Godot's perf panel, in place of Stillwater's debug HUD key).
# - Mouse: look while the pointer is captured (session requests capture on click).
# - Touch: a finger that starts on the left half is a floating stick at its start point; one on
#   the right half drags the view. Touches that start on a GUI control never get here: Godot's GUI
#   takes them (Stillwater's isControlTarget rule). Positions are tracked per finger, because
#   Godot's drag `relative` is wrong while two fingers move.
# Everything is gated like input.js: nothing moves unless the session is active and not paused;
# actions listed in ALLOW_WHILE_PAUSED still fire while paused.

signal action(name: String)
signal stick_changed(state: Dictionary)
signal mode_changed(touch: bool)

const MOUSE_SENS := 0.0021
const TOUCH_LOOK_SENS := 0.0055
const STICK_RADIUS := 52.0
const STICK_DEADZONE := 0.08

const MOVE_KEYS := {
	"forward": [KEY_W, KEY_UP],
	"back": [KEY_S, KEY_DOWN],
	"left": [KEY_A, KEY_LEFT],
	"right": [KEY_D, KEY_RIGHT],
}
# Physical key -> [action, fires on key repeat].
const KEY_ACTIONS := {
	KEY_ESCAPE: ["pause", false],
	KEY_Q: ["autoWalk", true],
	KEY_E: ["sit", true],
	KEY_H: ["toggleHud", true],
	KEY_G: ["dev", false],
}
const HOLD_KEYS := {KEY_SHIFT: "stride"}
const ALLOW_WHILE_PAUSED: Array[String] = ["pause", "autoWalk", "sit", "toggleHud", "dev"]
# `dev` works on the title screen too: the perf panel is not part of the game.
const ALWAYS: Array[String] = ["dev"]

var active := false
var paused := false
var touch := false
var ios := false

var _keys := {}
var _holds := {}
var _look := Vector2.ZERO
var _move_id := -1
var _origin := Vector2.ZERO
var _stick := Vector2.ZERO
var _look_id := -1
var _look_last := Vector2.ZERO
var _last_touch_ms := -100000
var _landscape := false
var _js_clear_cb: Variant = null


func _ready() -> void:
	if OS.has_feature("web"):
		touch = bool(JavaScriptBridge.eval("(() => { try { if (matchMedia('(pointer: coarse)').matches) return true; } catch (e) {} return (navigator.maxTouchPoints || 0) > 0 || 'ontouchstart' in window; })()"))
		ios = bool(JavaScriptBridge.eval("/iPad|iPhone|iPod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && (navigator.maxTouchPoints || 0) > 1)"))
		touch = touch or ios
		_install_web_touch_hooks()
	var vs := get_viewport().get_visible_rect().size
	_landscape = vs.x > vs.y
	get_tree().root.size_changed.connect(_on_resize)


# Guard against lost touchend on iOS Safari (system gestures, edge/home-bar swipes, hardware
# screenshots, app switches): clear touches on touchcancel, visibilitychange/pagehide/blur, and
# whenever the DOM reports zero fingers remaining on the glass after Godot processes touchend.
func _install_web_touch_hooks() -> void:
	_js_clear_cb = JavaScriptBridge.create_callback(_on_js_clear)
	var win := JavaScriptBridge.get_interface("window")
	if win == null:
		return
	win.__swOnTouchClear = _js_clear_cb
	JavaScriptBridge.eval("""(() => {
		window.__swTouchCount = 0;
		if (window.__swTouchHooked) return;
		window.__swTouchHooked = true;
		const fire = (why) => { if (window.__swOnTouchClear) window.__swOnTouchClear(why); };
		const track = (e) => { window.__swTouchCount = e.touches ? e.touches.length : 0; };
		window.addEventListener('touchstart', track, { passive: true, capture: true });
		window.addEventListener('touchmove', track, { passive: true, capture: true });
		window.addEventListener('touchend', (e) => {
			track(e);
			if (window.__swTouchCount === 0) fire('touchend0');
		}, { passive: true });
		window.addEventListener('touchcancel', (e) => {
			track(e);
			fire('touchcancel');
		}, { passive: true, capture: true });
		document.addEventListener('visibilitychange', () => {
			if (document.hidden) { window.__swTouchCount = 0; fire('hidden'); }
		});
		window.addEventListener('pagehide', () => { window.__swTouchCount = 0; fire('pagehide'); });
		window.addEventListener('blur', () => { window.__swTouchCount = 0; fire('blur'); });
	})()""")


func _on_js_clear(args: Array) -> void:
	var why := str(args[0]) if not args.is_empty() else ""
	if why == "touchend0":
		call_deferred("_clear_if_no_touches")
	else:
		clear()


func _clear_if_no_touches() -> void:
	if (_move_id >= 0 or _look_id >= 0) and int(JavaScriptBridge.eval("window.__swTouchCount || 0")) == 0:
		clear()


func has_stick() -> bool:
	return _move_id >= 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		clear()


func _on_resize() -> void:
	var vs := get_viewport().get_visible_rect().size
	var l := vs.x > vs.y
	if l != _landscape:
		_landscape = l
		clear()


func set_active(v: bool) -> void:
	if active == v:
		return
	active = v
	if not active:
		clear()


func set_paused(v: bool) -> void:
	if paused == v:
		return
	paused = v
	if paused:
		clear()


func clear() -> void:
	_keys.clear()
	_holds.clear()
	_look = Vector2.ZERO
	var had_stick := _move_id >= 0
	_move_id = -1
	_stick = Vector2.ZERO
	_look_id = -1
	if had_stick:
		stick_changed.emit({"active": false})


func _set_touch(v: bool) -> void:
	if touch != v:
		touch = v
		mode_changed.emit(v)


func can_dispatch(name: String) -> bool:
	if name in ALWAYS:
		return true
	if not active:
		return false
	return not paused or name in ALLOW_WHILE_PAUSED


# On-screen buttons and anything else that fires an action directly.
func trigger(name: String) -> void:
	if can_dispatch(name):
		action.emit(name)


# Mode switching sees every event, including ones the GUI takes.
func _input(e: InputEvent) -> void:
	if e is InputEventScreenTouch:
		_last_touch_ms = Time.get_ticks_msec()
		_set_touch(true)
	elif e is InputEventMouseButton and e.pressed and e.device != InputEvent.DEVICE_ID_EMULATION:
		if not ios and Time.get_ticks_msec() - _last_touch_ms > 800:
			_set_touch(false)
	elif e is InputEventKey:
		_key(e)
	elif e is InputEventMouseMotion and e.device != InputEvent.DEVICE_ID_EMULATION:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and active and not paused:
			_look += e.relative * MOUSE_SENS


func _key(e: InputEventKey) -> void:
	var code := e.physical_keycode
	if e.pressed:
		if KEY_ACTIONS.has(code):
			var a: Array = KEY_ACTIONS[code]
			if can_dispatch(a[0]) and (not e.echo or a[1]):
				action.emit(a[0])
		if not active or paused:
			return
		_keys[code] = true
	else:
		_keys.erase(code)


# Touches on the play surface: only those no GUI control took.
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventScreenTouch:
		if e.pressed:
			if not active or paused:
				return
			var half := get_viewport().get_visible_rect().size.x * 0.5
			if e.position.x < half:
				# Always reclaim the stick on a new left-half press so a lost release on iOS
				# cannot lock out future stick input.
				_move_id = e.index
				_origin = e.position
				_stick = Vector2.ZERO
				stick_changed.emit({"active": true, "origin": _origin, "offset": Vector2.ZERO})
			else:
				_look_id = e.index
				_look_last = e.position
		else:
			if e.index == _move_id:
				_move_id = -1
				_stick = Vector2.ZERO
				stick_changed.emit({"active": false})
			elif e.index == _look_id:
				_look_id = -1
	elif e is InputEventScreenDrag:
		if not active or paused:
			return
		if e.index == _move_id:
			var v := stick_vector(e.position - _origin)
			_stick = Vector2(v.x, v.y)
			stick_changed.emit({"active": true, "origin": _origin, "offset": Vector2(v.z, v.w)})
		elif e.index == _look_id:
			_look += (e.position - _look_last) * TOUCH_LOOK_SENS
			_look_last = e.position


# input.js computeStickVector: (x right, y forward) after the dead zone, and the knob offset.
static func stick_vector(raw: Vector2) -> Vector4:
	var dist := raw.length()
	if dist <= 1e-6:
		return Vector4.ZERO
	var clamped := minf(dist, STICK_RADIUS)
	var off := raw * (clamped / dist)
	var norm := clamped / STICK_RADIUS
	if norm <= STICK_DEADZONE:
		return Vector4(0.0, 0.0, off.x, off.y)
	var mag := (norm - STICK_DEADZONE) / (1.0 - STICK_DEADZONE)
	return Vector4(raw.x / dist * mag, -raw.y / dist * mag, off.x, off.y)


func _any(codes: Array) -> bool:
	for c in codes:
		if _keys.has(c):
			return true
	return false


# Move axes, x right and y forward, each clamped to [-1, 1].
func get_move() -> Vector2:
	if not active or paused:
		return Vector2.ZERO
	var m := Vector2.ZERO
	if _any(MOVE_KEYS.forward):
		m.y += 1.0
	if _any(MOVE_KEYS.back):
		m.y -= 1.0
	if _any(MOVE_KEYS.left):
		m.x -= 1.0
	if _any(MOVE_KEYS.right):
		m.x += 1.0
	if _move_id >= 0:
		m += _stick
	return m.clamp(Vector2(-1.0, -1.0), Vector2(1.0, 1.0))


# Look in radians since the last call (x yaw, y pitch; positive = right / down).
func consume_look() -> Vector2:
	var l := _look
	_look = Vector2.ZERO
	return l


func is_held(name: String) -> bool:
	if not active or paused:
		return false
	if _holds.get(name, false):
		return true
	for code in HOLD_KEYS:
		if HOLD_KEYS[code] == name and _keys.has(code):
			return true
	return false


# Holdable on-screen buttons (none yet; Stillwater's Time button arrives with day and night).
func set_hold(name: String, held: bool) -> void:
	if held and (not active or paused):
		return
	_holds[name] = held
