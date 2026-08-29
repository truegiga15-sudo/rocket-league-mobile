# InputService — Autoload singleton (WS06)
# Abstraction layer: game code reads move/look/boost/jump/drift/ballCam here.
# NEVER call Input.* directly from gameplay code; route through this service.
# Sources: touch -> set_touch_*(), gamepad/keyboard -> _poll_hardware().
# Touch layout defined in res://src/core/input/touch_layout.json
extends Node

# ---------------------------------------------------------------------------
# Public API — required by docs/architecture/00-conventions.md §5
# ---------------------------------------------------------------------------
## Left-stick / WASD / touch joystick — normalized [-1,1] each axis.
var move: Vector2 = Vector2.ZERO
## Right-stick / mouse / touch camera drag — normalized [-1,1].
var look: Vector2 = Vector2.ZERO
## Boost held?
var boost: bool = false
## Jump pressed this frame (use jump_held for hold).
var jump: bool = false
## Drift / handbrake held?
var drift: bool = false
## Ball-cam enabled? Toggle with ballCam input.
## NOTE: Godot style prefers snake_case (ball_cam); ballCam kept for spec compat.
var ballCam: bool = true
var ball_cam: bool:
	get: return ballCam
	set(v): ballCam = v

var jump_held: bool = false
var jump_just_pressed: bool = false
var jump_just_released: bool = false
var boost_held: bool = false

const MOVE_DEADZONE: float = 0.1
const LOOK_DEADZONE: float = 0.1
const LOOK_SENSITIVITY: float = 1.0

var _touch_move: Vector2 = Vector2.ZERO
var _touch_look: Vector2 = Vector2.ZERO
var _touch_boost: bool = false
var _touch_jump: bool = false
var _touch_drift: bool = false
var _touch_active_move: bool = false
var _touch_active_look: bool = false
var _prev_ball_cam_pressed: bool = false
var _input_log: Array[Dictionary] = []
const MAX_LOG: int = 600

signal ball_cam_toggled(enabled: bool)
signal jump_pressed
signal jump_released

func _ready() -> void:
	_ensure_input_map()
	set_process(true)

func _process(_delta: float) -> void:
	_poll()
	_log_input()

func set_touch_move(v: Vector2, active: bool) -> void:
	_touch_move = v.limit_length(1.0)
	_touch_active_move = active
	if not active:
		_touch_move = Vector2.ZERO

func set_touch_look(v: Vector2, active: bool) -> void:
	_touch_look = v.limit_length(1.0)
	_touch_active_look = active
	if not active:
		_touch_look = Vector2.ZERO

func set_touch_boost(pressed: bool) -> void:
	_touch_boost = pressed

func set_touch_jump(pressed: bool) -> void:
	_touch_jump = pressed

func set_touch_drift(pressed: bool) -> void:
	_touch_drift = pressed

func reset_touch() -> void:
	_touch_move = Vector2.ZERO
	_touch_look = Vector2.ZERO
	_touch_boost = false
	_touch_jump = false
	_touch_drift = false
	_touch_active_move = false
	_touch_active_look = false

func _poll() -> void:
	var hw_move := Vector2.ZERO
	if InputMap.has_action("move_left") and InputMap.has_action("move_right"):
		hw_move = Input.get_vector("move_left", "move_right", "move_up", "move_forward")
		if hw_move == Vector2.ZERO:
			hw_move = _poll_move_fallback()
	else:
		hw_move = _poll_move_fallback()
	hw_move = _apply_deadzone(hw_move, MOVE_DEADZONE)
	var final_move: Vector2 = _touch_move if _touch_active_move else hw_move
	move = final_move
	var hw_look := Vector2.ZERO
	hw_look.x = Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
	hw_look.y = Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
	if InputMap.has_action("look_left"):
		hw_look.x += Input.get_action_strength("look_right") - Input.get_action_strength("look_left")
	if InputMap.has_action("look_up"):
		hw_look.y += Input.get_action_strength("look_down") - Input.get_action_strength("look_up")
	hw_look = _apply_deadzone(hw_look, LOOK_DEADZONE)
	hw_look *= LOOK_SENSITIVITY
	hw_look = hw_look.limit_length(1.0)
	var final_look: Vector2 = _touch_look if _touch_active_look else hw_look
	look = final_look
	var hw_boost := Input.is_action_pressed("boost") if InputMap.has_action("boost") else Input.is_key_pressed(KEY_SHIFT) or Input.is_joy_button_pressed(0, JOY_BUTTON_RIGHT_SHOULDER)
	var hw_jump := Input.is_action_pressed("jump") if InputMap.has_action("jump") else Input.is_key_pressed(KEY_SPACE) or Input.is_joy_button_pressed(0, JOY_BUTTON_A)
	var hw_drift := Input.is_action_pressed("drift") if InputMap.has_action("drift") else Input.is_key_pressed(KEY_CTRL) or Input.is_joy_button_pressed(0, JOY_BUTTON_X)
	var hw_ball_cam := Input.is_action_pressed("ball_cam") if InputMap.has_action("ball_cam") else Input.is_key_pressed(KEY_F) or Input.is_joy_button_pressed(0, JOY_BUTTON_Y)
	boost = hw_boost or _touch_boost
	boost_held = boost
	var jump_now: bool = hw_jump or _touch_jump
	jump_just_pressed = jump_now and not jump_held
	jump_just_released = not jump_now and jump_held
	jump_held = jump_now
	jump = jump_just_pressed
	if jump_just_pressed:
		jump_pressed.emit()
	if jump_just_released:
		jump_released.emit()
	drift = hw_drift or _touch_drift
	var ball_cam_now: bool = hw_ball_cam
	if ball_cam_now and not _prev_ball_cam_pressed:
		ballCam = not ballCam
		ball_cam_toggled.emit(ballCam)
	_prev_ball_cam_pressed = ball_cam_now

func _poll_move_fallback() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		v.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		v.y += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		v.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		v.x += 1.0
	var lx := Input.get_joy_axis(0, JOY_AXIS_LEFT_X)
	var ly := Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)
	if absf(lx) > 0.05 or absf(ly) > 0.05:
		v = Vector2(lx, ly)
		if v.length() > 1.0:
			v = v.normalized()
	return v.limit_length(1.0)

func _apply_deadzone(v: Vector2, deadzone: float) -> Vector2:
	var l := v.length()
	if l < deadzone:
		return Vector2.ZERO
	var scaled := (l - deadzone) / (1.0 - deadzone)
	return v.normalized() * scaled * 1.0

func _ensure_input_map() -> void:
	var needed := {
		"move_left": KEY_A,
		"move_right": KEY_D,
		"move_up": KEY_W,
		"move_forward": KEY_S,
		"boost": KEY_SHIFT,
		"jump": KEY_SPACE,
		"drift": KEY_CTRL,
		"ball_cam": KEY_F,
		"look_left": KEY_Q,
		"look_right": KEY_E,
	}
	for action in needed.keys():
		if not InputMap.has_action(action):
			InputMap.add_action(action)

func debug_export() -> Dictionary:
	return {
		"move": move,
		"look": look,
		"boost": boost,
		"jump": jump,
		"jump_held": jump_held,
		"drift": drift,
		"ballCam": ballCam,
		"touch_active_move": _touch_active_move,
		"touch_active_look": _touch_active_look,
	}

func perf_mark() -> Dictionary:
	return {"input_log_size": _input_log.size()}

func get_input_log() -> Array[Dictionary]:
	return _input_log.duplicate()

func clear_input_log() -> void:
	_input_log.clear()

func _log_input() -> void:
	var entry := {
		"t": Time.get_ticks_msec(),
		"move": move,
		"look": look,
		"boost": boost,
		"jump": jump,
		"drift": drift,
		"ballCam": ballCam,
	}
	_input_log.append(entry)
	if _input_log.size() > MAX_LOG:
		_input_log.pop_front()

func get_move_vector() -> Vector2:
	return move

func get_look_vector() -> Vector2:
	return look

func is_boosting() -> bool:
	return boost

func is_drifting() -> bool:
	return drift
