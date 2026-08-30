# TouchJoystick — WS26 Touch Joystick (movement)
# Left 35% screen area, 120dp radius, 12dp deadzone.
# Outputs normalized Vector2 [-1,1] to InputService.set_touch_move via deadzone rescaling.
# Knob visual follows finger within radius, snaps to center on release.
# Provides debug_export() and perf_mark() per 00-conventions.md §11.
extends Control
class_name TouchJoystick

# ---------------------------------------------------------------------------
# Tunables — match docs/architecture/00-conventions.md §5 + touch_layout.json
# ---------------------------------------------------------------------------
## Joystick deflection radius in dp (density-independent pixels).
@export var radius_dp: float = 120.0
## Inner deadzone in dp — deflection below this is zero.
@export var deadzone_dp: float = 12.0
## Left screen percentage that owns this joystick (touch filtering).
@export var left_area_percent: float = 35.0
## Opacity when idle vs active (visual feedback).
@export var opacity_idle: float = 0.45
@export var opacity_active: float = 0.85
## Snap-back speed on release (ms to center visually; logical resets immediately).
@export var return_to_center_ms: float = 120.0

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
var _active_touch_id: int = -1
var _center: Vector2 = Vector2.ZERO
var _current: Vector2 = Vector2.ZERO
var _active: bool = false
var _dragging: bool = false
var _radius_px: float = 120.0
var _deadzone_px: float = 12.0
var _knob: Control = null
var _background: Control = null
var _perf_samples: int = 0
var _last_output: Vector2 = Vector2.ZERO
var _initialized: bool = false

# Signals for HUD/testing
signal joystick_moved(value: Vector2, active: bool)
signal joystick_released

func _ready() -> void:
	_update_metrics()
	_cache_nodes()
	_center = _compute_center()
	# Ensure we receive touch input even without focus
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Clip knob updates to center
	_reset_visual()
	modulate.a = opacity_idle
	_initialized = true
	# Keep updated on resize/orientation
	notification(NOTIFICATION_RESIZED)
	# Ensure Control covers left 35% if parent hasn't sized us — size is driven by scene anchors
	if size.x == 0 or size.y == 0:
		# Fallback: parent viewport size
		var vp := get_viewport_rect().size
		if vp.x > 0:
			size = Vector2(vp.x * left_area_percent / 100.0, vp.y)
	_center = _compute_center()
	_reset_visual()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_metrics()
		_center = _compute_center()
		_reset_visual()

func _cache_nodes() -> void:
	_background = get_node_or_null("TextureRect_Background") as Control
	if _background == null:
		_background = get_node_or_null("Panel_Background") as Control
	if _background == null:
		for c in get_children():
			if c.name.contains("Background"):
				_background = c as Control
				break
	_knob = get_node_or_null("TextureRect_Knob") as Control
	if _knob == null:
		_knob = get_node_or_null("Control_Knob") as Control
	if _knob == null:
		for c in get_children():
			if c.name.contains("Knob"):
				_knob = c as Control
				break

func _update_metrics() -> void:
	var scale := _get_dp_scale()
	_radius_px = radius_dp * scale
	_deadzone_px = deadzone_dp * scale
	# Guard against zero
	if _radius_px < 1.0:
		_radius_px = radius_dp
	if _deadzone_px < 0.0:
		_deadzone_px = 0.0
	if _deadzone_px >= _radius_px:
		_deadzone_px = _radius_px * 0.1

func _get_dp_scale() -> float:
	# dp = px * 160 / dpi ; px = dp * dpi / 160
	# Fallback to 1.0 when dpi unavailable (editor/desktop).
	var dpi: float = 0.0
	if DisplayServer.get_screen_count() > 0:
		var s_dpi := DisplayServer.screen_get_dpi(0)
		if s_dpi > 0:
			dpi = float(s_dpi)
	if dpi <= 0.0:
		# Try OS fallback or viewport scaling
		dpi = 160.0
	return dpi / 160.0

func _compute_center() -> Vector2:
	# Center of the joystick visual — middle of this Control's rect.
	# For left 35% area, this is near left-center per touch_layout.json anchor left_center.
	if size.x > 0 and size.y > 0:
		return size * 0.5
	var vp := get_viewport_rect().size
	if vp.x > 0:
		return Vector2(vp.x * left_area_percent / 100.0 * 0.5, vp.y * 0.5)
	return Vector2(_radius_px, _radius_px)

func _gui_input(event: InputEvent) -> void:
	# Only handle touches inside left 35% of screen
	var vp_size := get_viewport_rect().size
	var left_boundary_px: float = vp_size.x * left_area_percent / 100.0 if vp_size.x > 0 else size.x

	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		var in_left_area := touch.position.x <= left_boundary_px
		# Also allow if this Control's global rect contains point (scene anchored left 35%)
		var global_rect := get_global_rect()
		if global_rect.has_point(touch.position):
			in_left_area = true

		if touch.pressed:
			if _active_touch_id == -1 and in_left_area:
				_active_touch_id = touch.index
				_dragging = true
				_active = true
				_center = _local_center_for_touch(touch.position)
				modulate.a = opacity_active
				_update_joystick(touch.position)
				accept_event()
		else:
			if touch.index == _active_touch_id:
				_release()
				accept_event()

	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index == _active_touch_id and _dragging:
			_update_joystick(drag.position)
			accept_event()

func _local_center_for_touch(global_pos: Vector2) -> Vector2:
	# Follow-finger behavior clamped within radius: center snaps to initial touch but knob stays near
	# For "follow_finger_within_radius" per touch_layout.json:
	# Use Control center as origin; touch offset relative to that center.
	# Alternatively, if style is "fixed center", just return computed center.
	# We implement fixed center (stable) + visual clamp — touch_layout.json allows either.
	return _compute_center()

func _update_joystick(global_pos: Vector2) -> void:
	var local_pos: Vector2 = global_pos - get_global_position()
	# Handle scale/anchors — convert global to local via Control transform
	# Simpler: if global_rect used, local = global - global_position
	var offset: Vector2 = local_pos - _center
	var dist: float = offset.length()
	var raw: Vector2 = Vector2.ZERO
	if dist > 0.001:
		var clamped_dist: float = min(dist, _radius_px)
		var dir: Vector2 = offset / dist
		raw = dir * (clamped_dist / _radius_px)

	# Deadzone rescaling — per touch_layout.json joystick behavior
	var out: Vector2 = _apply_deadzone_rescale(raw)
	_current = out
	_last_output = out
	_active = true
	_perf_samples += 1

	# Update knob visual — position knob at rescaled offset within radius
	_update_knob_visual(offset, dist)

	# Output to InputService (WS06 abstraction)
	_push_to_input_service(out, true)
	joystick_moved.emit(out, true)

func _apply_deadzone_rescale(raw: Vector2) -> Vector2:
	var l: float = raw.length()
	if l < 0.0001:
		return Vector2.ZERO
	var deadzone_norm: float = _deadzone_px / _radius_px if _radius_px > 0 else 0.1
	deadzone_norm = clamp(deadzone_norm, 0.0, 0.9)
	if l < deadzone_norm:
		return Vector2.ZERO
	# Rescale [deadzone, 1] -> [0, 1]
	var scaled: float = (l - deadzone_norm) / (1.0 - deadzone_norm)
	scaled = clamp(scaled, 0.0, 1.0)
	return raw.normalized() * scaled

func _update_knob_visual(offset: Vector2, dist: float) -> void:
	if _knob == null:
		_cache_nodes()
		if _knob == null:
			return
	var knob_pos: Vector2 = _center
	if dist > 0.001:
		var clamped: float = min(dist, _radius_px)
		knob_pos = _center + offset.normalized() * clamped
		# Knob node is centered at its position; adjust for its own size
		var knob_half: Vector2 = _knob.size * 0.5 if _knob.size.x > 0 else Vector2.ZERO
		_knob.position = knob_pos - knob_half
	else:
		var knob_half2: Vector2 = _knob.size * 0.5 if _knob.size.x > 0 else Vector2.ZERO
		_knob.position = _center - knob_half2

func _reset_visual() -> void:
	if _knob == null:
		_cache_nodes()
	if _knob != null:
		var half: Vector2 = _knob.size * 0.5 if _knob.size.x > 0 else Vector2(24, 24)
		_knob.position = _center - half
		_knob.modulate.a = 1.0
	if _background != null:
		_background.modulate.a = 1.0

func _release() -> void:
	_dragging = false
	_active_touch_id = -1
	_current = Vector2.ZERO
	_last_output = Vector2.ZERO
	_active = false
	modulate.a = opacity_idle
	_reset_visual()
	_push_to_input_service(Vector2.ZERO, false)
	joystick_released.emit()

func _push_to_input_service(v: Vector2, active: bool) -> void:
	# WS06 InputService singleton — prefer autoload, fallback to root node lookup
	var svc: Node = null
	if Engine.has_singleton("InputService"):
		svc = Engine.get_singleton("InputService")
	# Autoloads are children of root
	if svc == null and get_tree() != null:
		svc = get_tree().root.get_node_or_null("InputService")
	if svc != null and svc.has_method("set_touch_move"):
		svc.call("set_touch_move", v, active)
	else:
		# No InputService in test/editor — store locally only
		pass

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
func get_move_vector() -> Vector2:
	return _current

func is_active() -> bool:
	return _active

func get_radius_dp() -> float:
	return radius_dp

func get_deadzone_dp() -> float:
	return deadzone_dp

# ---------------------------------------------------------------------------
# Telemetry hooks — per 00-conventions.md §11
# ---------------------------------------------------------------------------
func debug_export() -> Dictionary:
	return {
		"active": _active,
		"dragging": _dragging,
		"touch_id": _active_touch_id,
		"center": _center,
		"current": _current,
		"last_output": _last_output,
		"radius_dp": radius_dp,
		"deadzone_dp": deadzone_dp,
		"radius_px": _radius_px,
		"deadzone_px": _deadzone_px,
		"opacity_idle": opacity_idle,
		"opacity_active": opacity_active,
	}

func perf_mark() -> Dictionary:
	_perf_samples += 1
	return {
		"samples": _perf_samples,
		"active": _active,
		"radius_px": _radius_px,
	}
