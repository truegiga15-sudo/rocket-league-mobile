# BallCam — WS31 Ball Cam vs Car Cam Toggle
# Toggle ballCam via InputService.ballCam, lerps camera target between car and ball.
# Uses CameraRig (WS29) as follow rig — BallCam drives its effective target/look.
# Godot 4.x — 120 Hz fixed tick via TimeService delta clamp, budget-aware (<12 calls).
# Dependencies: InputService (WS06), TimeService (WS05), CameraRig (WS29), PhysicsConstants (WS04)
extends Node3D
class_name BallCam

# ---------------------------------------------------------------------------
# Exports — tuned for RL chase cam (meters, seconds)
# ---------------------------------------------------------------------------

## Car node to track (typically CarPhysics RigidBody3D). Set via inspector or set_car().
@export var car_path: NodePath

## Ball node to track (typically BallPhysics RigidBody3D). Set via inspector or set_ball().
@export var ball_path: NodePath

## Camera rig to drive (WS29). If set, BallCam updates rig orientation/target each frame.
@export var camera_rig_path: NodePath

## Lerp speed (1/s) — exponential smoothing rate. 3..10 typical. Higher = snappier toggle.
@export_range(1.0, 20.0, 0.1) var lerp_speed: float = 6.0

## Height bias added to look target (meters, Y-up). Keeps ball slightly above center.
@export_range(0.0, 5.0, 0.1) var height_offset: float = 0.6

## When ball cam disabled, distance ahead of car to look (meters, +car forward).
@export_range(1.0, 20.0, 0.1) var car_forward_distance: float = 8.0

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------
var _car: Node3D = null
var _ball: Node3D = null
var _rig: CameraRig = null

## 0.0 = Car Cam, 1.0 = Ball Cam. Smoothed via lerp_speed.
var _weight: float = 1.0
var _target_weight: float = 1.0
var _initialized: bool = false

# Exposed for tests / telemetry — budget <12 calls
var _last_dt: float = 0.0
var _last_ball_cam: bool = true
var _call_count: int = 0

signal toggled(enabled: bool)

func _ready() -> void:
	_resolve_refs()
	_weight = 1.0 if _get_input_ball_cam() else 0.0
	_target_weight = _weight
	_last_ball_cam = _target_weight > 0.5
	_initialized = true
	# Connect to InputService signal if available
	var svc := get_node_or_null("/root/InputService")
	if svc != null and svc.has_signal("ball_cam_toggled"):
		if not svc.ball_cam_toggled.is_connected(_on_input_toggled):
			svc.ball_cam_toggled.connect(_on_input_toggled)

func _resolve_refs() -> void:
	if car_path != NodePath("") and has_node(car_path):
		_car = get_node(car_path) as Node3D
	if ball_path != NodePath("") and has_node(ball_path):
		_ball = get_node(ball_path) as Node3D
	if camera_rig_path != NodePath("") and has_node(camera_rig_path):
		_rig = get_node(camera_rig_path) as CameraRig
	# Fallback: search children/parent for rig if path not set
	if _rig == null:
		_rig = get_node_or_null("../Node3D_CameraRig") as CameraRig
	if _rig == null:
		_rig = get_node_or_null("../CameraRig") as CameraRig
	if _rig == null:
		for c in get_children():
			if c is CameraRig:
				_rig = c
				break
	if _rig == null and get_parent() != null:
		for c in get_parent().get_children():
			if c is CameraRig:
				_rig = c
				break

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
func set_car(node: Node3D) -> void:
	_car = node
	if node != null:
		car_path = get_path_to(node)
	else:
		car_path = NodePath("")

func set_ball(node: Node3D) -> void:
	_ball = node
	if node != null:
		ball_path = get_path_to(node)
	else:
		ball_path = NodePath("")

func set_camera_rig(rig: CameraRig) -> void:
	_rig = rig
	if rig != null:
		camera_rig_path = get_path_to(rig)
	else:
		camera_rig_path = NodePath("")

func get_car() -> Node3D:
	return _car

func get_ball() -> Node3D:
	return _ball

func get_camera_rig() -> CameraRig:
	return _rig

func is_ball_cam_enabled() -> bool:
	return _get_input_ball_cam()

func get_weight() -> float:
	return _weight

func get_target_weight() -> float:
	return _target_weight

## Programmatic toggle — flips InputService.ballCam and updates local weight target.
func toggle() -> bool:
	var svc := get_node_or_null("/root/InputService")
	var cur := _get_input_ball_cam()
	var nxt := not cur
	_set_input_ball_cam(nxt)
	_target_weight = 1.0 if nxt else 0.0
	_last_ball_cam = nxt
	toggled.emit(nxt)
	# Haptics feedback if available
	var haptics := get_node_or_null("/root/Haptics")
	if haptics != null and haptics.has_method("on_ball_cam_toggle"):
		haptics.on_ball_cam_toggle()
	return nxt

func set_enabled(enabled: bool) -> void:
	_set_input_ball_cam(enabled)
	_target_weight = 1.0 if enabled else 0.0
	if _last_ball_cam != enabled:
		_last_ball_cam = enabled
		toggled.emit(enabled)

## Immediate snapshot of blended look target (lerped between car-ahead and ball).
func get_effective_target_position() -> Vector3:
	if _car == null and _ball == null:
		return global_position
	if _car == null:
		return _ball.global_position + Vector3(0, height_offset, 0) if _ball else global_position
	if _ball == null:
		return _car_forward_target(_car)
	# Both present — lerp by current weight
	var car_tgt := _car_forward_target(_car)
	var ball_tgt := _ball.global_position + Vector3(0, height_offset * 0.5, 0)
	return car_tgt.lerp(ball_tgt, clamp(_weight, 0.0, 1.0))

## Static helper — lerp between two positions (budget-aware, pure math, 1 call).
static func blended_position(car_pos: Vector3, ball_pos: Vector3, weight: float) -> Vector3:
	return car_pos.lerp(ball_pos, clamp(weight, 0.0, 1.0))

## Static helper — exponential lerp weight (120 Hz independent, 1 call).
static func weight_lerp(current: float, target: float, delta: float, speed: float) -> float:
	if speed <= 0.0:
		return target
	var alpha := 1.0 - exp(-speed * delta)
	return lerp(current, target, clamp(alpha, 0.0, 1.0))

# ---------------------------------------------------------------------------
# Per-frame update — 120 Hz clamped delta, <12 calls per tick
# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	var dt := _clamped_delta(delta)
	_last_dt = dt
	_update_weight(dt)
	_update_rig(dt)
	_call_count = 0

func _physics_process(delta: float) -> void:
	# Physics tick also updates for determinism (120 Hz). Budget: <12 calls.
	var dt := _clamped_delta(delta)
	_update_weight(dt)
	_update_rig(dt)

func _update_weight(delta: float) -> void:
	# 1) read InputService.ballCam  2) compute target  3) exp lerp
	var ball_cam_now := _get_input_ball_cam()
	_target_weight = 1.0 if ball_cam_now else 0.0
	# Emit toggled if changed outside our toggle() (e.g. InputService hardware poll)
	if ball_cam_now != _last_ball_cam:
		_last_ball_cam = ball_cam_now
		toggled.emit(ball_cam_now)
	_weight = weight_lerp(_weight, _target_weight, delta, lerp_speed)

func _update_rig(_delta: float) -> void:
	if _rig == null or _car == null:
		# Still update our own position as blended target for rig-less use
		if _car != null or _ball != null:
			global_position = get_effective_target_position()
		return
	# Drive rig: when ball cam (weight ~1) look at ball, else look ahead of car
	var target_pos := get_effective_target_position()
	global_position = target_pos
	# If weight > 0.5, orient rig yaw/pitch toward ball from car; else restore car-forward
	if _ball != null and _weight > 0.01:
		var car_pos: Vector3 = _car.global_position
		var ball_pos: Vector3 = _ball.global_position
		# Desired yaw toward ball (XZ plane), pitch toward ball height
		var dir := ball_pos - car_pos
		var yaw := atan2(dir.x, dir.z)
		var horiz := Vector2(dir.x, dir.z).length()
		var pitch := atan2(dir.y, max(horiz, 0.1))
		var yaw_deg := rad_to_deg(yaw)
		var pitch_deg := clamp(rad_to_deg(pitch), _rig.pitch_min_deg, _rig.pitch_max_deg)
		# Lerp rig orientation by weight so Car Cam keeps rig's own yaw, Ball Cam snaps to ball
		var cur_yaw := _rig.get_yaw_deg()
		var cur_pitch := _rig.get_pitch_deg()
		var blended_yaw := lerp(cur_yaw, yaw_deg, clamp(_weight, 0.0, 1.0))
		var blended_pitch := lerp(cur_pitch, pitch_deg, clamp(_weight, 0.0, 1.0))
		# Only override when ball cam is dominant; blend avoids snap
		if _weight > 0.5:
			_rig.set_yaw_pitch(blended_yaw, blended_pitch)

func _car_forward_target(car: Node3D) -> Vector3:
	var fwd := -car.global_transform.basis.z.normalized()
	if fwd.length_squared() < 0.001:
		fwd = Vector3.FORWARD
	return car.global_position + fwd * car_forward_distance + Vector3(0, height_offset, 0)

# ---------------------------------------------------------------------------
# InputService access — supports both ballCam (spec) and ball_cam (Godot style)
# ---------------------------------------------------------------------------
func _get_input_ball_cam() -> bool:
	var svc := get_node_or_null("/root/InputService")
	if svc != null:
		if "ballCam" in svc:
			return bool(svc.ballCam)
		if "ball_cam" in svc:
			return bool(svc.ball_cam)
		if svc.has_method("is_ball_cam_enabled"):
			return svc.is_ball_cam_enabled()
	return _last_ball_cam

func _set_input_ball_cam(v: bool) -> void:
	var svc := get_node_or_null("/root/InputService")
	if svc != null:
		if "ballCam" in svc:
			svc.ballCam = v
		if "ball_cam" in svc:
			svc.ball_cam = v

func _on_input_toggled(enabled: bool) -> void:
	_target_weight = 1.0 if enabled else 0.0
	if _last_ball_cam != enabled:
		_last_ball_cam = enabled
		toggled.emit(enabled)

func _clamped_delta(delta: float) -> float:
	var svc := get_node_or_null("/root/TimeService")
	if svc != null and svc.has_method("clamp_delta"):
		return svc.clamp_delta(delta)
	var pc := preload("res://src/core/constants.gd")
	if pc != null:
		return clamp(delta, pc.DELTA_MIN, pc.DELTA_MAX)
	return clamp(delta, 1.0 / 240.0, 1.0 / 30.0)

# ---------------------------------------------------------------------------
# Telemetry §11 — debug_export / perf_mark / validate (§12 budget <12 calls)
# ---------------------------------------------------------------------------
func debug_export() -> Dictionary:
	return {
		"car": str(car_path) if _car == null else _car.name,
		"ball": str(ball_path) if _ball == null else _ball.name,
		"has_car": _car != null,
		"has_ball": _ball != null,
		"has_rig": _rig != null,
		"weight": _weight,
		"target_weight": _target_weight,
		"ball_cam_enabled": _get_input_ball_cam(),
		"lerp_speed": lerp_speed,
		"height_offset": height_offset,
		"car_forward_distance": car_forward_distance,
		"effective_target": get_effective_target_position(),
		"last_dt": _last_dt,
		"initialized": _initialized,
	}

func perf_mark() -> Dictionary:
	return {
		"weight": _weight,
		"target_weight": _target_weight,
		"ball_cam": _last_ball_cam,
		"lerp_speed": lerp_speed,
		"alpha": 1.0 - exp(-lerp_speed * _last_dt) if _last_dt > 0 else 0.0,
	}

func validate_config() -> Dictionary:
	var errors: Array[String] = []
	if lerp_speed <= 0.0 or lerp_speed > 50.0:
		errors.append("lerp_speed %.2f outside (0,50]" % lerp_speed)
	if height_offset < 0.0 or height_offset > 10.0:
		errors.append("height_offset %.2f outside [0,10]" % height_offset)
	if car_forward_distance < 0.0 or car_forward_distance > 30.0:
		errors.append("car_forward_distance %.2f outside [0,30]" % car_forward_distance)
	if _weight < -0.01 or _weight > 1.01:
		errors.append("weight %.3f outside [0,1]" % _weight)
	var pc := preload("res://src/core/constants.gd")
	if pc.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS %d != 120" % pc.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(pc.DELTA_MIN, 1.0 / 240.0):
		errors.append("DELTA_MIN %.6f != 1/240" % pc.DELTA_MIN)
	if not is_equal_approx(pc.DELTA_MAX, 1.0 / 30.0):
		errors.append("DELTA_MAX %.6f != 1/30" % pc.DELTA_MAX)
	if not _initialized:
		errors.append("not initialized (_ready not called)")
	return {"ok": errors.is_empty(), "errors": errors}
