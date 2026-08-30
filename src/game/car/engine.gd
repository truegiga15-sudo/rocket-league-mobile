## WS14 — Engine Power Curve & Throttle
## Power curve, throttle response, max speed, acceleration, torque curve.
## Integrates with InputService.move (WS06) and CarPhysics (WS11).
## Conventions: docs/architecture/00-conventions.md §3-§4, 1 unit = 1 m, Y-up, +Z forward.
## Physics tick 120 Hz (src/core/constants.gd, src/core/time_service.gd).
## No procedural generation — all values authored/deterministic.
extends RefCounted
class_name CarEngine

const PC = preload("res://src/core/constants.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")

# ---------------------------------------------------------------------------
# Authored engine constants — single source for WS14+WS18 (boost)
# ---------------------------------------------------------------------------

## Max ground speed forward without boost (m/s).
const MAX_SPEED_FORWARD: float = 28.0
## Max ground speed in reverse (m/s)
const MAX_SPEED_REVERSE: float = 16.0
## Max speed with boost active (m/s).
const MAX_SPEED_BOOST: float = 36.0
## Alias for API compat
const MAX_SPEED: float = MAX_SPEED_FORWARD

## Peak wheel drive force at 0 speed, full throttle (Newtons).
const PEAK_DRIVE_FORCE: float = 3600.0
## Peak reverse drive force (N)
const PEAK_REVERSE_FORCE: float = 2700.0
## Alias
const MAX_ACCELERATION_FORCE: float = PEAK_DRIVE_FORCE
## Acceleration in m/s2 at low speed
const MAX_ACCELERATION: float = PEAK_DRIVE_FORCE / 180.0

## Throttle response rates (1/s)
const THROTTLE_RESPONSE_RATE: float = 12.0
const THROTTLE_BRAKE_RATE: float = 16.0
const THROTTLE_DEADZONE: float = 0.02
const STOP_SPEED_THRESHOLD: float = 0.05

# ---------------------------------------------------------------------------
# Torque curve — speed_ratio -> torque_factor linear-interpolated
# ---------------------------------------------------------------------------
const TORQUE_CURVE: Array[Vector2] = [
	Vector2(0.0, 1.00),
	Vector2(0.15, 0.98),
	Vector2(0.30, 0.92),
	Vector2(0.50, 0.78),
	Vector2(0.65, 0.62),
	Vector2(0.80, 0.42),
	Vector2(0.90, 0.28),
	Vector2(1.00, 0.08),
	Vector2(1.15, 0.00),
]

# ---------------------------------------------------------------------------
# Power curve — throttle 0..1 -> power factor 0..1
# ---------------------------------------------------------------------------
const POWER_CURVE: Array[Vector2] = [
	Vector2(0.00, 0.00),
	Vector2(0.10, 0.04),
	Vector2(0.25, 0.22),
	Vector2(0.40, 0.42),
	Vector2(0.60, 0.66),
	Vector2(0.80, 0.86),
	Vector2(1.00, 1.00),
]

# ---------------------------------------------------------------------------
# Instance state
# ---------------------------------------------------------------------------
var _current_throttle: float = 0.0
var _current_speed: float = 0.0
var _throttle_target: float = 0.0

# ---------------------------------------------------------------------------
# InputService integration — NEVER call Input.* directly
# ---------------------------------------------------------------------------
static func throttle_from_move_vector(move: Vector2) -> float:
	var t := -move.y
	if absf(t) < THROTTLE_DEADZONE:
		return 0.0
	return clamp(t, -1.0, 1.0)

static func get_throttle_from_input_service() -> float:
	var svc := _get_input_service()
	if svc == null:
		return 0.0
	var mv: Vector2 = Vector2.ZERO
	if "move" in svc:
		mv = svc.move as Vector2
	elif svc.has_method("get_move_vector"):
		mv = svc.get_move_vector() as Vector2
	return throttle_from_move_vector(mv)

static func get_move_vector_from_service() -> Vector2:
	var svc := _get_input_service()
	if svc == null:
		return Vector2.ZERO
	if "move" in svc:
		return svc.move as Vector2
	if svc.has_method("get_move_vector"):
		return svc.get_move_vector() as Vector2
	return Vector2.ZERO

static func _get_input_service() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var root: Window = tree.root
	if root == null:
		return null
	var svc := root.get_node_or_null("InputService")
	if svc != null:
		return svc
	var alt := tree.get_root().get_node_or_null("/root/InputService")
	return alt

# ---------------------------------------------------------------------------
# Curve sampling
# ---------------------------------------------------------------------------
static func _sample_curve(curve: Array[Vector2], x: float) -> float:
	if curve.is_empty():
		return 0.0
	if x <= curve[0].x:
		return curve[0].y
	if x >= curve[curve.size() - 1].x:
		return curve[curve.size() - 1].y
	for i in range(curve.size() - 1):
		var a := curve[i]
		var b := curve[i + 1]
		if x >= a.x and x <= b.x:
			var span := b.x - a.x
			if span <= 0.0:
				return a.y
			var t := (x - a.x) / span
			return lerp(a.y, b.y, t)
	return curve[curve.size() - 1].y

static func torque_factor_for_speed(speed_abs: float, is_reverse: bool = false, is_boosting: bool = false) -> float:
	var max_s := MAX_SPEED_REVERSE if is_reverse else (MAX_SPEED_BOOST if is_boosting else MAX_SPEED_FORWARD)
	if max_s <= 0.0:
		return 0.0
	var ratio := speed_abs / max_s
	return clamp(_sample_curve(TORQUE_CURVE, ratio), 0.0, 1.0)

static func power_factor_for_throttle(throttle_abs: float) -> float:
	var t := clamp(absf(throttle_abs), 0.0, 1.0)
	return clamp(_sample_curve(POWER_CURVE, t), 0.0, 1.0)

static func combined_factor(throttle: float, speed_abs: float, is_reverse: bool = false, is_boosting: bool = false) -> float:
	var p := power_factor_for_throttle(throttle)
	var tor := torque_factor_for_speed(speed_abs, is_reverse, is_boosting)
	return p * tor

# ---------------------------------------------------------------------------
# Throttle response
# ---------------------------------------------------------------------------
static func apply_throttle_response(current: float, target: float, delta: float) -> float:
	var clamped_target := clamp(target, -1.0, 1.0)
	if is_equal_approx(current, clamped_target):
		return clamped_target
	var is_braking := (absf(clamped_target) < absf(current)) or (signf(clamped_target) != signf(current) and clamped_target != 0.0)
	var rate := THROTTLE_BRAKE_RATE if is_braking else THROTTLE_RESPONSE_RATE
	var alpha := 1.0 - exp(-rate * delta)
	return lerp(current, clamped_target, alpha)

static func throttle_response(current: float, target: float, delta: float) -> float:
	return apply_throttle_response(current, target, delta)

# ---------------------------------------------------------------------------
# Max speed & acceleration
# ---------------------------------------------------------------------------
static func clamp_speed(speed: float, is_boosting: bool = false) -> float:
	if speed >= 0.0:
		var lim := MAX_SPEED_BOOST if is_boosting else MAX_SPEED_FORWARD
		return min(speed, lim)
	else:
		return max(speed, -MAX_SPEED_REVERSE)

static func is_at_speed_limiter(speed: float, throttle: float, is_boosting: bool = false) -> bool:
	if throttle > 0.05 and speed >= (MAX_SPEED_BOOST if is_boosting else MAX_SPEED_FORWARD) - 0.01:
		return true
	if throttle < -0.05 and speed <= -MAX_SPEED_REVERSE + 0.01:
		return true
	return false

static func compute_drive_force(throttle: float, speed: float, is_boosting: bool = false) -> float:
	var t := clamp(throttle, -1.0, 1.0)
	if absf(t) < THROTTLE_DEADZONE:
		return 0.0
	var speed_abs := absf(speed)
	var is_reverse_throttle := t < 0.0
	var moving_reverse := speed < -STOP_SPEED_THRESHOLD
	var moving_forward := speed > STOP_SPEED_THRESHOLD
	if (is_reverse_throttle and moving_forward) or (t > 0.0 and moving_reverse):
		var brake_power := power_factor_for_throttle(t)
		var peak := PEAK_REVERSE_FORCE if is_reverse_throttle else PEAK_DRIVE_FORCE
		return signf(t) * peak * brake_power * 1.15
	var is_rev := is_reverse_throttle
	var tor := torque_factor_for_speed(speed_abs, is_rev, is_boosting)
	var pow_f := power_factor_for_throttle(t)
	var peak_force := PEAK_REVERSE_FORCE if is_rev else PEAK_DRIVE_FORCE
	var force := signf(t) * peak_force * pow_f * tor
	if is_at_speed_limiter(speed, t, is_boosting):
		if (t > 0.0 and speed > 0.0) or (t < 0.0 and speed < 0.0):
			var lim := (MAX_SPEED_BOOST if is_boosting else MAX_SPEED_FORWARD) if t > 0.0 else MAX_SPEED_REVERSE
			var over := (speed_abs - lim * 0.97) / (lim * 0.03)
			force *= clamp(1.0 - over, 0.0, 1.0)
			if speed_abs >= lim:
				force = min(force, 0.0) if t > 0.0 else max(force, 0.0)
	return force

static func compute_acceleration(throttle: float, speed: float, mass: float = 180.0, is_boosting: bool = false) -> float:
	if mass <= 0.0:
		return 0.0
	var f := compute_drive_force(throttle, speed, is_boosting)
	return f / mass

static func predict_speed(current_speed: float, throttle: float, delta: float, is_boosting: bool = false, mass: float = 180.0) -> float:
	var acc := compute_acceleration(throttle, current_speed, mass, is_boosting)
	var next := current_speed + acc * delta
	return clamp_speed(next, is_boosting)

# ---------------------------------------------------------------------------
# Integration helpers — apply to CarPhysics RigidBody3D
# ---------------------------------------------------------------------------
static func apply_to_car(car: RigidBody3D, delta: float, throttle_arg: float = NAN, is_boosting: bool = false) -> Vector3:
	var throttle: float = throttle_arg
	if is_nan(throttle):
		throttle = get_throttle_from_input_service()
	if not is_boosting:
		var svc := _get_input_service()
		if svc != null and "boost" in svc:
			is_boosting = bool(svc.boost)
		elif svc != null and svc.has_method("is_boosting"):
			is_boosting = svc.is_boosting()
	var fwd := car.global_transform.basis.z.normalized()
	if fwd.length_squared() < 0.5:
		fwd = Vector3(0, 0, 1)
	var vel: Vector3 = car.linear_velocity
	var speed_fwd := vel.dot(fwd)
	var force_mag := compute_drive_force(throttle, speed_fwd, is_boosting)
	var force_vec := fwd * force_mag
	car.apply_central_force(force_vec)
	var clamped := clamp_speed(speed_fwd, is_boosting)
	if not is_equal_approx(speed_fwd, clamped):
		var excess := speed_fwd - clamped
		var correction := fwd * (-excess * car.mass * 8.0 * delta)
		car.apply_central_force(correction)
	return force_vec

# ---------------------------------------------------------------------------
# Instance wrappers
# ---------------------------------------------------------------------------
func set_throttle_target(target: float) -> void:
	_throttle_target = clamp(target, -1.0, 1.0)

func update(delta: float, throttle_target_override: float = NAN) -> float:
	if not is_nan(throttle_target_override):
		_throttle_target = clamp(throttle_target_override, -1.0, 1.0)
	_current_throttle = CarEngine.apply_throttle_response(_current_throttle, _throttle_target, delta)
	return _current_throttle

func poll_input_and_update(delta: float) -> float:
	var t := CarEngine.get_throttle_from_input_service()
	_throttle_target = t
	_current_throttle = CarEngine.apply_throttle_response(_current_throttle, _throttle_target, delta)
	return _current_throttle

func get_current_throttle() -> float:
	return _current_throttle

func get_target_throttle() -> float:
	return _throttle_target

func reset() -> void:
	_current_throttle = 0.0
	_throttle_target = 0.0
	_current_speed = 0.0

func process_car(car: RigidBody3D, delta: float) -> Vector3:
	var t := poll_input_and_update(delta)
	var svc := CarEngine._get_input_service()
	var boosting := false
	if svc != null and "boost" in svc:
		boosting = bool(svc.boost)
	elif svc != null and svc.has_method("is_boosting"):
		boosting = svc.is_boosting()
	return CarEngine.apply_to_car(car, delta, t, boosting)

# ---------------------------------------------------------------------------
# Validation & telemetry — conventions §11 — budget-aware (<4ms physics)
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if MAX_SPEED_FORWARD <= 0.0:
		errors.append("MAX_SPEED_FORWARD must be > 0")
	if MAX_SPEED_REVERSE <= 0.0:
		errors.append("MAX_SPEED_REVERSE must be > 0")
	if MAX_SPEED_BOOST <= MAX_SPEED_FORWARD:
		errors.append("MAX_SPEED_BOOST must be > MAX_SPEED_FORWARD")
	if PEAK_DRIVE_FORCE <= 0.0:
		errors.append("PEAK_DRIVE_FORCE must be > 0")
	if PEAK_REVERSE_FORCE <= 0.0:
		errors.append("PEAK_REVERSE_FORCE must be > 0")
	if THROTTLE_RESPONSE_RATE <= 0.0:
		errors.append("THROTTLE_RESPONSE_RATE must be > 0")
	if THROTTLE_BRAKE_RATE <= 0.0:
		errors.append("THROTTLE_BRAKE_RATE must be > 0")
	if TORQUE_CURVE.size() < 2:
		errors.append("TORQUE_CURVE needs >=2 points")
	if POWER_CURVE.size() < 2:
		errors.append("POWER_CURVE needs >=2 points")
	for i in range(TORQUE_CURVE.size() - 1):
		if TORQUE_CURVE[i].x >= TORQUE_CURVE[i + 1].x:
			errors.append("TORQUE_CURVE x not strictly increasing at %d" % i)
		if TORQUE_CURVE[i].y < -0.01:
			errors.append("TORQUE_CURVE y negative at %d" % i)
	for i in range(POWER_CURVE.size() - 1):
		if POWER_CURVE[i].x >= POWER_CURVE[i + 1].x:
			errors.append("POWER_CURVE x not strictly increasing at %d" % i)
		if POWER_CURVE[i].y < -0.01 or POWER_CURVE[i].y > 1.01:
			errors.append("POWER_CURVE y out of [0,1] at %d" % i)
	if POWER_CURVE[0].x != 0.0 or not is_equal_approx(POWER_CURVE[0].y, 0.0):
		errors.append("POWER_CURVE must start at (0,0)")
	if not is_equal_approx(POWER_CURVE[POWER_CURVE.size() - 1].x, 1.0) or not is_equal_approx(POWER_CURVE[POWER_CURVE.size() - 1].y, 1.0):
		errors.append("POWER_CURVE must end at (1,1)")
	if TORQUE_CURVE[0].y < 0.99:
		errors.append("TORQUE_CURVE must start near 1.0 at 0 speed")
	if TORQUE_CURVE[TORQUE_CURVE.size() - 1].y != 0.0:
		errors.append("TORQUE_CURVE must end at 0.0")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND != 120")
	if not is_equal_approx(PC.PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA mismatch")
	var probe_fwd := throttle_from_move_vector(Vector2(0, -1))
	if not is_equal_approx(probe_fwd, 1.0):
		errors.append("throttle_from_move_vector forward != 1.0")
	var probe_rev := throttle_from_move_vector(Vector2(0, 1))
	if not is_equal_approx(probe_rev, -1.0):
		errors.append("throttle_from_move_vector reverse != -1.0")
	var probe_zero := throttle_from_move_vector(Vector2.ZERO)
	if not is_equal_approx(probe_zero, 0.0):
		errors.append("throttle_from_move_vector ZERO != 0")
	var f0 := compute_drive_force(1.0, 0.0)
	if f0 <= 0.0:
		errors.append("compute_drive_force(1,0) must be >0")
	var f_at_max := compute_drive_force(1.0, MAX_SPEED_FORWARD)
	if f_at_max > PEAK_DRIVE_FORCE * 0.15:
		errors.append("drive force at max speed should be near 0")
	var f_brake := compute_drive_force(-1.0, 10.0)
	if f_brake >= 0.0:
		errors.append("braking force must be <0")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"max_speed_forward": MAX_SPEED_FORWARD,
		"max_speed_reverse": MAX_SPEED_REVERSE,
		"max_speed_boost": MAX_SPEED_BOOST,
		"max_speed": MAX_SPEED,
		"peak_drive_force": PEAK_DRIVE_FORCE,
		"peak_reverse_force": PEAK_REVERSE_FORCE,
		"max_acceleration": MAX_ACCELERATION,
		"max_acceleration_force": MAX_ACCELERATION_FORCE,
		"throttle_response_rate": THROTTLE_RESPONSE_RATE,
		"throttle_brake_rate": THROTTLE_BRAKE_RATE,
		"throttle_deadzone": THROTTLE_DEADZONE,
		"torque_curve": TORQUE_CURVE,
		"power_curve": POWER_CURVE,
		"physics_tick_hz": PC.PHYSICS_TICKS_PER_SECOND,
		"physics_tick_delta": PC.PHYSICS_TICK_DELTA,
	}

func debug_export_instance() -> Dictionary:
	var d := CarEngine.debug_export()
	d["current_throttle"] = _current_throttle
	d["throttle_target"] = _throttle_target
	d["current_speed"] = _current_speed
	return d

static func perf_mark() -> Dictionary:
	return {"scope": "CarEngine", "max_speed": MAX_SPEED_FORWARD, "tick_hz": PC.PHYSICS_TICKS_PER_SECOND}

func perf_mark_instance() -> Dictionary:
	return {"scope": "CarEngine", "throttle": _current_throttle, "tick_hz": PC.PHYSICS_TICKS_PER_SECOND}
