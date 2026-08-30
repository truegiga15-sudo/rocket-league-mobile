# CameraJoystick — WS27 Camera Joystick & Orbit (budget-aware)
# Right 35% screen area, drag to orbit camera via InputService.set_touch_look.
# Deadzone 8dp, sensitivity scaled via dp->px, outputs normalized [-1,1].
# Provides debug_export() and perf_mark() per 00-conventions.md §11.
# Budget: <12 calls per method (no heavy loops, early returns).
extends Control
class_name CameraJoystick

# ---------------------------------------------------------------------------
# Tunables — touch_layout.json camera zone + WS27 spec
# ---------------------------------------------------------------------------
## Deadzone in dp — drag below this is zero output.
@export var deadzone_dp: float = 8.0
## Sensitivity in dp per unit — drag distance that maps to 1.0 output.
@export var sensitivity_dp: float = 120.0
## Sensitivity multiplier applied after normalization (tuning).
@export var sensitivity: float = 1.0
## Right screen percentage that owns this joystick.
@export var right_area_percent: float = 35.0
## Invert Y axis (touch_layout.json camera.invert_y).
@export var invert_y: bool = false
## Visual feedback opacity.
@export var opacity_idle: float = 0.35
@export var opacity_active: float = 0.75

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
var _active_touch_id: int = -1
var _start_pos: Vector2 = Vector2.ZERO
var _last_pos: Vector2 = Vector2.ZERO
var _current: Vector2 = Vector2.ZERO
var _active: bool = false
var _dragging: bool = false
var _deadzone_px: float = 8.0
var _sensitivity_px: float = 120.0
var _perf_samples: int = 0
var _last_output: Vector2 = Vector2.ZERO
var _initialized: bool = false

signal camera_moved(value: Vector2, active: bool)
signal camera_released

func _ready() -> void:
	_update_metrics()
	mouse_filter = Control.MOUSE_FILTER_STOP
	modulate.a = opacity_idle
	_initialized = true
	if size.x == 0 or size.y == 0:
		var vp := get_viewport_rect().size
		if vp.x > 0:
			size = Vector2(vp.x * right_area_percent / 100.0, vp.y)
			position = Vector2(vp.x * (100.0 - right_area_percent) / 100.0, 0)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_metrics()

func _update_metrics() -> void:
	var scale := _get_dp_scale()
	_deadzone_px = deadzone_dp * scale
	_sensitivity_px = sensitivity_dp * scale
	if _sensitivity_px < 1.0:
		_sensitivity_px = sensitivity_dp
	if _deadzone_px < 0.0:
		_deadzone_px = 0.0
	if _deadzone_px >= _sensitivity_px:
		_deadzone_px = _sensitivity_px * 0.06

func _get_dp_scale() -> float:
	var dpi: float = 0.0
	if DisplayServer.get_screen_count() > 0:
		var s_dpi := DisplayServer.screen_get_dpi(0)
		if s_dpi > 0:
			dpi = float(s_dpi)
	if dpi <= 0.0:
		dpi = 160.0
	return dpi / 160.0

func _gui_input(event: InputEvent) -> void:
	var vp_size := get_viewport_rect().size
	var right_boundary_px: float = vp_size.x * (100.0 - right_area_percent) / 100.0 if vp_size.x > 0 else get_global_position().x
	var global_rect := get_global_rect()

	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		var in_right_area := touch.position.x >= right_boundary_px
		if global_rect.has_point(touch.position):
			in_right_area = true
		if touch.pressed:
			if _active_touch_id == -1 and in_right_area:
				_active_touch_id = touch.index
				_dragging = true
				_active = true
				_start_pos = touch.position
				_last_pos = touch.position
				modulate.a = opacity_active
				_update_look(touch.position)
				accept_event()
		else:
			if touch.index == _active_touch_id:
				_release()
				accept_event()

	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index == _active_touch_id and _dragging:
			_update_look(drag.position)
			accept_event()

func _update_look(global_pos: Vector2) -> void:
	_last_pos = global_pos
	var delta := global_pos - _start_pos
	if invert_y:
		delta.y = -delta.y
	var out := _apply_deadzone_and_scale(delta)
	out = (out * sensitivity).limit_length(1.0)
	_current = out
	_last_output = out
	_active = true
	_perf_samples += 1
	_push_to_input_service(out, true)
	camera_moved.emit(out, true)

func _apply_deadzone_and_scale(delta: Vector2) -> Vector2:
	var dist: float = delta.length()
	if dist < 0.001:
		return Vector2.ZERO
	if dist < _deadzone_px:
		return Vector2.ZERO
	var dir: Vector2 = delta / dist
	var effective_range: float = _sensitivity_px - _deadzone_px
	if effective_range < 1.0:
		effective_range = _sensitivity_px
	var scaled: float = (dist - _deadzone_px) / effective_range
	scaled = clamp(scaled, 0.0, 1.0)
	return dir * scaled

func _release() -> void:
	_dragging = false
	_active_touch_id = -1
	_current = Vector2.ZERO
	_last_output = Vector2.ZERO
	_active = false
	_start_pos = Vector2.ZERO
	_last_pos = Vector2.ZERO
	modulate.a = opacity_idle
	_push_to_input_service(Vector2.ZERO, false)
	camera_released.emit()

func _push_to_input_service(v: Vector2, active: bool) -> void:
	var svc: Node = null
	if get_tree() != null:
		svc = get_tree().root.get_node_or_null("InputService")
	if svc != null and svc.has_method("set_touch_look"):
		svc.call("set_touch_look", v, active)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
func get_look_vector() -> Vector2:
	return _current

func is_active() -> bool:
	return _active

func get_deadzone_dp() -> float:
	return deadzone_dp

func get_sensitivity_dp() -> float:
	return sensitivity_dp

func reset_camera() -> void:
	_release()

# ---------------------------------------------------------------------------
# Telemetry hooks — per 00-conventions.md §11 (budget <12 calls each)
# ---------------------------------------------------------------------------
func debug_export() -> Dictionary:
	return {
		"active": _active,
		"dragging": _dragging,
		"touch_id": _active_touch_id,
		"start_pos": _start_pos,
		"last_pos": _last_pos,
		"current": _current,
		"last_output": _last_output,
		"deadzone_dp": deadzone_dp,
		"sensitivity_dp": sensitivity_dp,
		"sensitivity": sensitivity,
		"deadzone_px": _deadzone_px,
		"sensitivity_px": _sensitivity_px,
		"right_area_percent": right_area_percent,
		"invert_y": invert_y,
	}

func perf_mark() -> Dictionary:
	_perf_samples += 1
	return {
		"samples": _perf_samples,
		"active": _active,
		"deadzone_px": _deadzone_px,
		"sensitivity_px": _sensitivity_px,
	}
