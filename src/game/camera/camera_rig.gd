# CameraRig — WS29 Camera Follow Algorithm
# Follows a target (car) with spring-arm collision, stiffness/lag smoothing,
# FOV handling, and orbit via InputService.look (Vector2 normalized [-1,1]).
# Godot 4.x — uses TimeService delta clamp + InputService abstraction per WS06.
# Dependencies: InputService (WS06), TimeService (WS05), PhysicsConstants (WS04)
extends Node3D
class_name CameraRig

# ---------------------------------------------------------------------------
# Exports — tuned for Rocket League chase cam (meters, degrees, units)
# ---------------------------------------------------------------------------
## Node to follow (typically car chassis RigidBody3D). Set via inspector or set_target().
@export var target_path: NodePath

## Spring stiffness — higher = tighter follow (exponential smoothing rate). 5..20 typical.
@export_range(0.1, 50.0, 0.1) var stiffness: float = 8.0

## Lag time constant (seconds) — additional smoothing. 0 = no extra lag, 0.15 = noticeable weight.
@export_range(0.0, 1.0, 0.01) var lag: float = 0.15

## Base vertical field of view in degrees.
@export_range(30.0, 120.0, 0.5) var fov: float = 75.0:
	set(v):
		fov = clamp(v, 30.0, 120.0)
		_current_fov = fov
		_apply_fov()

## FOV when boosting (lerped toward while InputService.boost held).
@export_range(30.0, 120.0, 0.5) var boost_fov: float = 85.0

## Speed of FOV transition (1/s).
@export_range(0.5, 20.0, 0.1) var fov_transition_speed: float = 5.0

## Follow distance behind target (meters, Godot units = meters).
@export_range(2.0, 30.0, 0.1) var follow_distance: float = 10.0:
	set(v):
		follow_distance = v
		_sync_spring_arm()

## Height offset above target origin (meters).
@export_range(0.5, 10.0, 0.1) var follow_height: float = 3.5

## Look sensitivity — degrees per second at full deflection [-1,1].
@export_range(10.0, 360.0, 1.0) var yaw_sensitivity_deg: float = 90.0
@export_range(10.0, 180.0, 1.0) var pitch_sensitivity_deg: float = 60.0

## Pitch limits (degrees) to avoid flipping.
@export_range(-89.0, 0.0, 1.0) var pitch_min_deg: float = -20.0
@export_range(0.0, 89.0, 1.0) var pitch_max_deg: float = 30.0

## SpringArm length — kept in sync with follow_distance.
@export_range(1.0, 30.0, 0.1) var spring_length: float = 10.0:
	set(v):
		spring_length = v
		_sync_spring_arm()

## SpringArm collision margin.
@export_range(0.01, 1.0, 0.01) var spring_margin: float = 0.4:
	set(v):
		spring_margin = v
		_sync_spring_arm()

## Sensitivity multiplier applied to InputService.look vector.
@export_range(0.1, 3.0, 0.05) var look_sensitivity: float = 1.0

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------
var _target: Node3D = null
var _yaw_deg: float = 0.0
var _pitch_deg: float = 10.0
var _current_fov: float = 75.0
var _spring_arm: SpringArm3D = null
var _camera: Camera3D = null
var _initialized: bool = false

# Exposed for tests / telemetry
var _last_look: Vector2 = Vector2.ZERO
var _last_alpha: float = 0.0

func _ready() -> void:
	_current_fov = fov
	_resolve_target()
	_cache_nodes()
	_sync_spring_arm()
	_apply_fov()
	_yaw_deg = rotation_degrees.y
	_pitch_deg = clamp(rotation_degrees.x, pitch_min_deg, pitch_max_deg)
	_initialized = true

func _cache_nodes() -> void:
	_spring_arm = get_node_or_null("SpringArm3D_SpringArm") as SpringArm3D
	if _spring_arm == null:
		_spring_arm = get_node_or_null("SpringArm") as SpringArm3D
	if _spring_arm == null:
		for c in get_children():
			if c is SpringArm3D:
				_spring_arm = c
				break
	_camera = null
	if _spring_arm != null:
		_camera = _spring_arm.get_node_or_null("Camera3D_Camera") as Camera3D
		if _camera == null:
			_camera = _spring_arm.get_node_or_null("Camera") as Camera3D
		if _camera == null:
			for c in _spring_arm.get_children():
				if c is Camera3D:
					_camera = c
					break
	else:
		for c in get_children():
			if c is Camera3D:
				_camera = c
				break
	if _camera == null:
		_camera = _find_camera_recursive(self)

func _find_camera_recursive(n: Node) -> Camera3D:
	for c in n.get_children():
		if c is Camera3D:
			return c
		var r := _find_camera_recursive(c)
		if r != null:
			return r
	return null

func _resolve_target() -> void:
	if target_path != NodePath("") and has_node(target_path):
		_target = get_node(target_path) as Node3D
	else:
		_target = null

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
func set_target(node: Node3D) -> void:
	_target = node
	if node != null:
		target_path = get_path_to(node)
	else:
		target_path = NodePath("")

func get_target() -> Node3D:
	return _target

func get_look_vector() -> Vector2:
	return _get_look_input()

func get_yaw_deg() -> float:
	return _yaw_deg

func get_pitch_deg() -> float:
	return _pitch_deg

func set_yaw_pitch(yaw_deg: float, pitch_deg: float) -> void:
	_yaw_deg = fmod(yaw_deg, 360.0)
	_pitch_deg = clamp(pitch_deg, pitch_min_deg, pitch_max_deg)

func get_fov_value() -> float:
	return _current_fov

func set_fov_value(v: float) -> void:
	fov = clamp(v, 30.0, 120.0)

func get_spring_arm() -> SpringArm3D:
	return _spring_arm

func get_camera() -> Camera3D:
	return _camera

func reset_orientation() -> void:
	_yaw_deg = 0.0
	_pitch_deg = 10.0

# ---------------------------------------------------------------------------
# Telemetry (§11)
# ---------------------------------------------------------------------------
func debug_export() -> Dictionary:
	return {
		"stiffness": stiffness,
		"lag": lag,
		"fov": fov,
		"current_fov": _current_fov,
		"boost_fov": boost_fov,
		"follow_distance": follow_distance,
		"follow_height": follow_height,
		"spring_length": spring_length,
		"spring_margin": spring_margin,
		"yaw_deg": _yaw_deg,
		"pitch_deg": _pitch_deg,
		"look": _last_look,
		"target": str(target_path) if _target == null else _target.name,
		"has_target": _target != null,
		"initialized": _initialized,
	}

func perf_mark() -> Dictionary:
	return {
		"yaw_deg": _yaw_deg,
		"pitch_deg": _pitch_deg,
		"current_fov": _current_fov,
		"alpha": _last_alpha,
	}

# ---------------------------------------------------------------------------
# Per-frame update
# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	var dt := _clamped_delta(delta)
	_update_look(dt)
	_update_follow(dt)
	_update_fov(dt)

func _physics_process(_delta: float) -> void:
	if _spring_arm != null and _target != null:
		_sync_spring_arm()

# ---------------------------------------------------------------------------
# Look input — reads InputService.look Vector2 normalized [-1,1]
# ---------------------------------------------------------------------------
func _get_look_input() -> Vector2:
	var look := Vector2.ZERO
	var svc := get_node_or_null("/root/InputService")
	if svc != null and "look" in svc:
		look = svc.look as Vector2
		if svc.has_method("get_look_vector"):
			var alt = svc.get_look_vector()
			if alt is Vector2:
				look = alt
	return look.limit_length(1.0)

func _update_look(delta: float) -> void:
	var look := _get_look_input()
	_last_look = look
	look *= look_sensitivity
	_yaw_deg -= look.x * yaw_sensitivity_deg * delta
	_pitch_deg += look.y * pitch_sensitivity_deg * delta
	_pitch_deg = clamp(_pitch_deg, pitch_min_deg, pitch_max_deg)
	_yaw_deg = fmod(_yaw_deg + 540.0, 360.0) - 180.0

# ---------------------------------------------------------------------------
# Follow algorithm — stiffness + lag smoothing (frame-rate independent)
# ---------------------------------------------------------------------------
func _update_follow(delta: float) -> void:
	if _target == null:
		if target_path != NodePath("") and has_node(target_path):
			_resolve_target()
		if _target == null:
			return

	var target_pos: Vector3 = _target.global_position
	var desired_pos := _compute_desired_position(target_pos)

	var alpha: float = 0.0
	if lag > 0.001:
		var alpha_lag := 1.0 - exp(-delta / lag)
		var stiffness_scale := clamp(stiffness / 8.0, 0.2, 4.0)
		alpha = clamp(alpha_lag * stiffness_scale, 0.0, 1.0)
	else:
		alpha = 1.0 - exp(-stiffness * delta)
		alpha = clamp(alpha, 0.0, 1.0)
	_last_alpha = alpha

	global_position = global_position.lerp(desired_pos, alpha)

	var look_target := target_pos + Vector3(0, follow_height * 0.3, 0)
	var dir := (look_target - global_position)
	if dir.length_squared() > 0.001:
		var desired_basis := Basis.looking_at(-dir.normalized(), Vector3.UP)
		var rot_alpha := clamp(alpha * 1.2, 0.0, 1.0)
		global_transform.basis = global_transform.basis.slerp(desired_basis, rot_alpha)
	rotation_degrees.y = lerp(rotation_degrees.y, _yaw_deg, clamp(alpha * 1.5, 0.0, 1.0))
	rotation_degrees.x = lerp(rotation_degrees.x, _pitch_deg, clamp(alpha * 1.5, 0.0, 1.0))
	rotation_degrees.z = 0.0

func _compute_desired_position(target_pos: Vector3) -> Vector3:
	var yaw_rad := deg_to_rad(_yaw_deg)
	var pitch_rad := deg_to_rad(_pitch_deg)
	var offset := Vector3.ZERO
	offset.x = sin(yaw_rad) * follow_distance
	offset.z = cos(yaw_rad) * follow_distance
	offset.y = follow_height + sin(pitch_rad) * (follow_distance * 0.35)
	return target_pos + offset

# ---------------------------------------------------------------------------
# FOV handling
# ---------------------------------------------------------------------------
func _update_fov(delta: float) -> void:
	var is_boosting := false
	var svc := get_node_or_null("/root/InputService")
	if svc != null and "boost" in svc:
		is_boosting = bool(svc.boost)
		if svc.has_method("is_boosting"):
			is_boosting = svc.is_boosting()
	var target_fov := boost_fov if is_boosting else fov
	_current_fov = lerp(_current_fov, target_fov, clamp(fov_transition_speed * delta, 0.0, 1.0))
	_apply_fov()

func _apply_fov() -> void:
	if _camera != null:
		_camera.fov = _current_fov
	else:
		_cache_nodes()
		if _camera != null:
			_camera.fov = _current_fov

func _sync_spring_arm() -> void:
	if _spring_arm == null:
		return
	_spring_arm.spring_length = spring_length
	_spring_arm.margin = spring_margin
	_spring_arm.collision_mask = 1

func _clamped_delta(delta: float) -> float:
	var svc := get_node_or_null("/root/TimeService")
	if svc != null and svc.has_method("clamp_delta"):
		return svc.clamp_delta(delta)
	var pc := preload("res://src/core/constants.gd")
	if pc != null:
		return clamp(delta, pc.DELTA_MIN, pc.DELTA_MAX)
	return clamp(delta, 1.0 / 240.0, 1.0 / 30.0)
