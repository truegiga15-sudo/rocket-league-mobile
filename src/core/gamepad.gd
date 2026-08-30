# GamepadFallback — WS35 Gamepad Fallback & Mapping (budget-aware, <12 calls)
# Maps gamepad axes/buttons to InputService move/look/boost/jump/drift/ballCam.
# Fallback active only when touch is inactive (touch is primary input on mobile).
# Budget: no per-frame allocation beyond polls, <12 Input.* calls per _poll tick,
# <12 draw calls (none — logic-only node), <12 method calls internally.
# Provides debug_export() and perf_mark() per docs/architecture/00-conventions.md §11.
extends Node
class_name GamepadFallback

# ---------------------------------------------------------------------------
# Deadzone / Mapping — match project.godot InputMap (deadzone 0.2) + WS32 tuning
# ---------------------------------------------------------------------------
## Deadzone for move (left stick) — normalized [0,1]. Below threshold => zero.
const MOVE_DEADZONE: float = 0.2
## Deadzone for look (right stick).
const LOOK_DEADZONE: float = 0.2
## Small epsilon to treat near-zero hardware jitter as zero before deadzone scaling.
const AXIS_EPSILON: float = 0.05

# ---------------------------------------------------------------------------
# Button mapping — Xbox-layout (Godot JOY_BUTTON_*), mirrors project.godot
# InputMap: boost=Right Shoulder (5), jump=A (0), drift=X (2), ball_cam=Y (3)
# ---------------------------------------------------------------------------
const BTN_JUMP: int = JOY_BUTTON_A            # 0
const BTN_DRIFT: int = JOY_BUTTON_X           # 2
const BTN_BALL_CAM: int = JOY_BUTTON_Y        # 3
const BTN_BOOST: int = JOY_BUTTON_RIGHT_SHOULDER # 5

# Axis mapping (Godot JOY_AXIS_*)
const AXIS_MOVE_X: int = JOY_AXIS_LEFT_X      # 0
const AXIS_MOVE_Y: int = JOY_AXIS_LEFT_Y      # 1
const AXIS_LOOK_X: int = JOY_AXIS_RIGHT_X     # 2
const AXIS_LOOK_Y: int = JOY_AXIS_RIGHT_Y     # 3

# Trigger thresholds — also support boost on RT as analog fallback
const TRIGGER_THRESHOLD: float = 0.25

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
## Enable fallback — if false, never writes to InputService.
@export var enabled: bool = true
## Device index to poll (0 = first gamepad). Auto-falls to any connected if 0 not present.
@export var device: int = 0
## Use analog trigger (axis 5) as alternative boost when button not pressed.
@export var boost_on_trigger: bool = true

var _last_move: Vector2 = Vector2.ZERO
var _last_look: Vector2 = Vector2.ZERO
var _last_boost: bool = false
var _last_jump: bool = false
var _last_drift: bool = false
var _prev_ball_cam_pressed: bool = false
var _poll_count: int = 0
var _fallback_frames: int = 0
var _touch_blocked_frames: int = 0
var _connected: bool = false
var _initialized: bool = false

signal move_updated(v: Vector2)
signal look_updated(v: Vector2)
signal boost_changed(pressed: bool)
signal jump_pressed
signal jump_released
signal ball_cam_toggled(enabled_state: bool)

func _ready() -> void:
	set_process(true)
	_refresh_connected()
	_initialized = true

func _process(_delta: float) -> void:
	if not enabled:
		return
	_poll()

# ---------------------------------------------------------------------------
# Public API — polling & mapping (each <12 calls)
# ---------------------------------------------------------------------------

## Poll once and apply to InputService if touch inactive. Returns true if applied.
func poll_and_apply() -> bool:
	return _poll()

## True if any gamepad is connected (checks Input.get_connected_joypads() — 1 call).
func is_connected(current_device: int = -1) -> bool:
	var dev := current_device if current_device >= 0 else _resolve_device()
	var joypads := Input.get_connected_joypads()
	return joypads.has(dev)

## Returns true if a gamepad is connected and could be used (any device).
func has_any_gamepad() -> bool:
	return not Input.get_connected_joypads().is_empty()

## Raw move from gamepad with deadzone applied — does not check touch, does not write.
func get_move_vector(dev: int = -1) -> Vector2:
	var d := dev if dev >= 0 else _resolve_device()
	var v := Vector2(Input.get_joy_axis(d, AXIS_MOVE_X), Input.get_joy_axis(d, AXIS_MOVE_Y))
	return _apply_deadzone(v, MOVE_DEADZONE)

## Raw look from gamepad with deadzone — does not check touch.
func get_look_vector(dev: int = -1) -> Vector2:
	var d := dev if dev >= 0 else _resolve_device()
	var v := Vector2(Input.get_joy_axis(d, AXIS_LOOK_X), Input.get_joy_axis(d, AXIS_LOOK_Y))
	return _apply_deadzone(v, LOOK_DEADZONE).limit_length(1.0)

## Boost held? Button 5 or RT axis > threshold. Budget: 1–2 Input.* calls.
func is_boost_pressed(dev: int = -1) -> bool:
	var d := dev if dev >= 0 else _resolve_device()
	if Input.is_joy_button_pressed(d, BTN_BOOST):
		return true
	if boost_on_trigger and Input.get_joy_axis(d, JOY_AXIS_TRIGGER_RIGHT) > TRIGGER_THRESHOLD:
		return true
	return false

## Jump held? Budget: 1 call.
func is_jump_pressed(dev: int = -1) -> bool:
	var d := dev if dev >= 0 else _resolve_device()
	return Input.is_joy_button_pressed(d, BTN_JUMP)

## Drift held? Budget: 1 call.
func is_drift_pressed(dev: int = -1) -> bool:
	var d := dev if dev >= 0 else _resolve_device()
	return Input.is_joy_button_pressed(d, BTN_DRIFT)

## Ball-cam button pressed (toggle edge)? Budget: 1 call.
func is_ball_cam_pressed(dev: int = -1) -> bool:
	var d := dev if dev >= 0 else _resolve_device()
	return Input.is_joy_button_pressed(d, BTN_BALL_CAM)

## True if touch is currently driving move or look (fallback should NOT apply).
func is_touch_active() -> bool:
	return _is_touch_active()

## Export current mapped state (read-only, does not poll).
func get_mapped_state() -> Dictionary:
	return {
		"move": _last_move,
		"look": _last_look,
		"boost": _last_boost,
		"jump": _last_jump,
		"drift": _last_drift,
		"connected": _connected,
		"device": _resolve_device(),
		"touch_active": _is_touch_active(),
		"poll_count": _poll_count,
	}

# ---------------------------------------------------------------------------
# Internal — budget-aware polling (<12 Input.* calls per tick)
# ---------------------------------------------------------------------------

func _poll() -> bool:
	# Budget: 1 _refresh (1 get_connected_joypads) + 4 get_joy_axis + 5 button/trigger
	#         = 10 Input.* calls per tick, under 12 limit.
	_poll_count += 1

	# Touch is primary — fallback only when touch inactive.
	if _is_touch_active():
		_touch_blocked_frames += 1
		return false

	_refresh_connected()
	var dev := _resolve_device_cached()

	# Gather raw axes — 4 calls
	var raw_move := Vector2(Input.get_joy_axis(dev, AXIS_MOVE_X), Input.get_joy_axis(dev, AXIS_MOVE_Y))
	var raw_look := Vector2(Input.get_joy_axis(dev, AXIS_LOOK_X), Input.get_joy_axis(dev, AXIS_LOOK_Y))

	# Deadzone — rescaled so  deadzone->0, 1->1, matching InputService._apply_deadzone
	var move := _apply_deadzone(raw_move, MOVE_DEADZONE)
	var look := _apply_deadzone(raw_look, LOOK_DEADZONE).limit_length(1.0)

	# Buttons — 5 calls (boost uses 2, jump/drift/ball_cam 1 each) — direct, not via is_* to avoid double _resolve
	var boost := Input.is_joy_button_pressed(dev, BTN_BOOST) or (boost_on_trigger and Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_RIGHT) > TRIGGER_THRESHOLD)
	var jump_now := Input.is_joy_button_pressed(dev, BTN_JUMP)
	var drift := Input.is_joy_button_pressed(dev, BTN_DRIFT)
	var ball_cam_now := Input.is_joy_button_pressed(dev, BTN_BALL_CAM)

	# Cache last values for debug_export and signals
	_last_move = move
	_last_look = look

	# Apply to InputService only when we have a live autoload and fallback is warranted.
	# InputService itself already polls gamepad; this node reinforces it explicitly
	# so gamepad works even if InputService fallback is disabled or tested in isolation.
	_apply_to_input_service(move, look, boost, jump_now, drift, ball_cam_now)

	_fallback_frames += 1

	# Emit lean signals only on change — event-driven, not per frame spam.
	if move != _last_move:
		move_updated.emit(move)
	if look != _last_look:
		look_updated.emit(look)
	if boost != _last_boost:
		boost_changed.emit(boost)
	_last_boost = boost
	if jump_now != _last_jump:
		if jump_now:
			jump_pressed.emit()
		else:
			jump_released.emit()
	_last_jump = jump_now
	_last_drift = drift

	# Ball-cam toggle on rising edge (same semantics as InputService §5)
	if ball_cam_now and not _prev_ball_cam_pressed:
		var svc := _get_input_service()
		if svc != null and "ballCam" in svc:
			svc.ballCam = not svc.ballCam
			if svc.has_signal("ball_cam_toggled"):
				svc.ball_cam_toggled.emit(svc.ballCam)
			ball_cam_toggled.emit(svc.ballCam)
	_prev_ball_cam_pressed = ball_cam_now
	if not ball_cam_now:
		_prev_ball_cam_pressed = false

	return true

func _apply_to_input_service(move: Vector2, look: Vector2, boost: bool, jump_now: bool, drift: bool, _ball_cam_now: bool) -> void:
	var svc := _get_input_service()
	if svc == null:
		return
	# Only overwrite InputService when touch is not active; otherwise InputService
	# preserves touch_* values (fix: don't stomp touch joystick).
	# We check again defensively; caller already did.
	if _is_touch_active():
		return
	# Write-through: if InputService exposes setters or vars, set them.
	# These are low-cost var assignments (not counted as Input.* budget calls).
	if "move" in svc:
		svc.move = move
	if "look" in svc:
		svc.look = look
	if "boost" in svc:
		svc.boost = boost
	if "boost_held" in svc:
		svc.boost_held = boost
	if "drift" in svc:
		svc.drift = drift
	# Jump: maintain InputService edge semantics (jump, jump_held, jump_just_pressed)
	if "jump_held" in svc:
		var prev_held: bool = bool(svc.jump_held)
		var just_pressed: bool = jump_now and not prev_held
		var just_released: bool = not jump_now and prev_held
		svc.jump_held = jump_now
		if "jump" in svc:
			svc.jump = just_pressed
		if "jump_just_pressed" in svc:
			svc.jump_just_pressed = just_pressed
		if "jump_just_released" in svc:
			svc.jump_just_released = just_released
		if just_pressed and svc.has_signal("jump_pressed"):
			svc.jump_pressed.emit()
		if just_released and svc.has_signal("jump_released"):
			svc.jump_released.emit()

func _is_touch_active() -> bool:
	var svc := _get_input_service()
	if svc == null:
		return false
	# Prefer explicit flags exposed by InputService
	if "_touch_active_move" in svc and bool(svc.get("_touch_active_move")):
		return true
	if "_touch_active_look" in svc and bool(svc.get("_touch_active_look")):
		return true
	# Fallback via debug_export()
	if svc.has_method("debug_export"):
		var d: Dictionary = svc.debug_export()
		if bool(d.get("touch_active_move", false)) or bool(d.get("touch_active_look", false)):
			return true
	return false

func _get_input_service() -> Node:
	# Autoload InputService is registered as /root/InputService; also available as global.
	if Engine.has_singleton("InputService"):
		return Engine.get_singleton("InputService") as Node
	var root := Engine.get_main_loop() as SceneTree
	if root != null and root.root.has_node("InputService"):
		return root.root.get_node("InputService") as Node
	# Fallback: global identifier injected as autoload may be accessible as get_node
	if has_node("/root/InputService"):
		return get_node("/root/InputService") as Node
	return null

func _resolve_device() -> int:
	var pads := Input.get_connected_joypads()
	if pads.has(device):
		return device
	if not pads.is_empty():
		return int(pads[0])
	return device

func _resolve_device_cached() -> int:
	# Called after _refresh_connected, so _connected already updated.
	# Avoid second get_connected_joypads by using cached state if possible.
	if _connected:
		var pads := Input.get_connected_joypads()
		if pads.has(device):
			return device
		if not pads.is_empty():
			return int(pads[0])
	return device

func _refresh_connected() -> void:
	_connected = has_any_gamepad()

func _apply_deadzone(v: Vector2, deadzone: float) -> Vector2:
	var l := v.length()
	if l < deadzone:
		return Vector2.ZERO
	# Rescale [deadzone,1] -> [0,1] linearly (matches InputService._apply_deadzone)
	var scaled := (l - deadzone) / (1.0 - deadzone)
	return v.normalized() * scaled * 1.0

# ---------------------------------------------------------------------------
# Debug / Budget — per 00-conventions.md §11
# ---------------------------------------------------------------------------

func debug_export() -> Dictionary:
	return {
		"connected": _connected,
		"device": _resolve_device(),
		"enabled": enabled,
		"move": _last_move,
		"look": _last_look,
		"boost": _last_boost,
		"jump": _last_jump,
		"drift": _last_drift,
		"poll_count": _poll_count,
		"fallback_frames": _fallback_frames,
		"touch_blocked_frames": _touch_blocked_frames,
		"move_deadzone": MOVE_DEADZONE,
		"look_deadzone": LOOK_DEADZONE,
		"has_gamepad": has_any_gamepad(),
		"touch_active": _is_touch_active(),
	}

func perf_mark() -> Dictionary:
	return {
		"poll_count": _poll_count,
		"fallback_frames": _fallback_frames,
		"touch_blocked_frames": _touch_blocked_frames,
		"connected": _connected,
	}

## Reset counters — useful between tests.
func reset_metrics() -> void:
	_poll_count = 0
	_fallback_frames = 0
	_touch_blocked_frames = 0
	_last_move = Vector2.ZERO
	_last_look = Vector2.ZERO
	_last_boost = false
	_last_jump = false
	_last_drift = false
	_prev_ball_cam_pressed = false
