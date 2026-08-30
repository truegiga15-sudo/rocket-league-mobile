## WS15 — Steering, Drift & Handbrake (budget-aware, solo)
## Steering curve (angle vs speed), drift/handbrake modifies friction, yaw torque.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07),
##             src/core/physics/physics_config.gd (WS07), src/core/time_service.gd (WS05),
##             src/core/input_service.gd (WS06) -> InputService.drift + move.x,
##             src/game/car/suspension.gd (WS12), src/game/car/friction.gd (WS13),
##             src/game/car/engine.gd (WS14), src/game/car/car_physics.gd (WS11)
## Conventions: docs/architecture/00-conventions.md §3-§4, 1 unit = 1 m, Y-up, +Z forward.
## Physics tick 120 Hz, raycasts via PhysicsLayers, budget <4 ms (<12 calls).
## No procedural generation — all values authored/deterministic. No raw Input.*.
extends RefCounted
class_name CarSteering

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const SuspensionRef = preload("res://src/game/car/suspension.gd")
const FrictionRef = preload("res://src/game/car/friction.gd")
const EngineRef = preload("res://src/game/car/engine.gd")

# ---------------------------------------------------------------------------
# Time / tick — 120 Hz fixed (must match Suspension + Friction + Engine + TimeService)
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Physics layers — never hardcode numbers, always via PhysicsLayers (§4)
# ---------------------------------------------------------------------------
static func get_steering_mask() -> int:
	return PL.MASK_WHEELS

static func get_steering_layer() -> int:
	return PL.BIT_WHEELS

# ---------------------------------------------------------------------------
# Authored steering constants — single source for WS15
# ---------------------------------------------------------------------------

## Max steering angle at low speed (rad). ~0.58 rad = 33 deg (RL-like front wheel max).
const MAX_STEER_ANGLE: float = 0.58
const MAX_STEER_ANGLE_DEG: float = 33.2

## Minimum steering angle at max speed (rad). ~0.12 rad = 6.9 deg — barely steer at 28 m/s.
const MIN_STEER_ANGLE: float = 0.12

## Steering goes via curve scaled by speed. Curve maps speed_ratio (speed / MAX_SPEED_FORWARD) -> steer factor 0..1.
## At 0 speed factor 1.0 (full angle), at 1.0 speed factor ~0.21 (MIN/MAX).
const STEERING_CURVE: Array[Vector2] = [
	Vector2(0.00, 1.00),
	Vector2(0.15, 0.92),
	Vector2(0.30, 0.78),
	Vector2(0.50, 0.55),
	Vector2(0.70, 0.36),
	Vector2(0.85, 0.26),
	Vector2(1.00, 0.21),
	Vector2(1.20, 0.18),
]

## Steering response rate (exponential lerp, 1/s). Higher = snappier wheel turn.
const STEER_RESPONSE_RATE: float = 14.0
## Return-to-center rate when input released (1/s) — faster centering.
const STEER_RETURN_RATE: float = 18.0
## Deadzone on move.x before steering engages (InputService already has 0.1, extra here is small).
const STEER_DEADZONE: float = 0.05

## Drift / handbrake — modifies lateral friction and adds yaw torque.
## When drift held, lateral grip reduced so car slides; longitudinal mostly preserved.
const DRIFT_LATERAL_GRIP_SCALE: float = 0.32
const DRIFT_LATERAL_GRIP_SCALE_MIN: float = 0.22
const DRIFT_LONGITUDINAL_GRIP_SCALE: float = 0.92
## Drift yaw torque — additional angular impulse while drifting (Nm per tick scaling).
const DRIFT_YAW_TORQUE: float = 1800.0
## Drift steering bonus — extra steer angle while drifting (rad).
const DRIFT_STEER_BONUS: float = 0.18
## Drift requires minimum speed (m/s) to engage — prevents spinning in place.
const DRIFT_MIN_SPEED: float = 1.5
## Drift steering lerp rate while handbrake held.
const DRIFT_RESPONSE_RATE: float = 10.0

## Alias constants for API compat (some consumers probe these names)
const STEER_ANGLE_MAX: float = MAX_STEER_ANGLE
const STEER_ANGLE_MIN: float = MIN_STEER_ANGLE
const DRIFT_GRIP_SCALE: float = DRIFT_LATERAL_GRIP_SCALE

# ---------------------------------------------------------------------------
# Instance state (budget-aware: no alloc per tick beyond these fields)
# ---------------------------------------------------------------------------
var _current_steer_angle: float = 0.0
var _target_steer_angle: float = 0.0
var _is_drifting: bool = false
var _drift_time: float = 0.0
var _last_speed: float = 0.0

# ---------------------------------------------------------------------------
# InputService integration — NEVER call Input.* directly
# ---------------------------------------------------------------------------
static func steer_input_from_move_vector(move: Vector2) -> float:
	# move.x: -1 left, +1 right. Apply small deadzone, preserve sign.
	var x := clamp(move.x, -1.0, 1.0)
	if absf(x) < STEER_DEADZONE:
		return 0.0
	# Rescale from deadzone edge to 0..1
	var sign_val := signf(x)
	var mag := (absf(x) - STEER_DEADZONE) / (1.0 - STEER_DEADZONE)
	return clamp(sign_val * mag, -1.0, 1.0)

static func get_steer_input_from_service() -> float:
	var svc := _get_input_service()
	if svc == null:
		return 0.0
	var mv: Vector2 = Vector2.ZERO
	if "move" in svc:
		mv = svc.move as Vector2
	elif svc.has_method("get_move_vector"):
		mv = svc.get_move_vector() as Vector2
	return steer_input_from_move_vector(mv)

static func is_drift_from_service() -> bool:
	var svc := _get_input_service()
	if svc == null:
		return false
	if "drift" in svc:
		return bool(svc.drift)
	if svc.has_method("is_drifting"):
		return svc.is_drifting() as bool
	return false

static func get_inputs_from_service() -> Dictionary:
	return {"steer": get_steer_input_from_service(), "drift": is_drift_from_service()}

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
# Curve sampling (authored, deterministic, no alloc per call)
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

## Steering factor 0..1 for a given absolute speed (m/s).
static func steering_factor_for_speed(speed_abs: float) -> float:
	var max_s := EngineRef.MAX_SPEED_FORWARD
	if max_s <= 0.0:
		return 1.0
	var ratio := clamp(speed_abs / max_s, 0.0, 1.30)
	return clamp(_sample_curve(STEERING_CURVE, ratio), 0.15, 1.0)

## Max steer angle (rad) available at a given speed.
static func max_steer_angle_for_speed(speed_abs: float) -> float:
	var factor := steering_factor_for_speed(speed_abs)
	# Lerp between MIN and MAX by factor (factor 1 => MAX, factor 0.21 => ~MIN)
	# Our curve already encodes MIN/MAX ratio, so just scale MAX:
	return MAX_STEER_ANGLE * factor

## Target steer angle (rad) for raw input -1..1 at a given speed.
static func steer_angle_for_input(steer_input: float, speed_abs: float, is_drifting: bool = false) -> float:
	var clamped := clamp(steer_input, -1.0, 1.0)
	if absf(clamped) < 0.001:
		return 0.0
	var max_ang := max_steer_angle_for_speed(speed_abs)
	# Non-linear input response (slightly progressive at low steer) for fine control.
	var shaped := signf(clamped) * pow(absf(clamped), 0.92)
	var angle := shaped * max_ang
	if is_drifting and absf(speed_abs) >= DRIFT_MIN_SPEED:
		angle += signf(clamped) * DRIFT_STEER_BONUS * min(absf(clamped), 1.0) * 0.5
		# Clamp drift bonus so max doesn't exceed ~0.76 rad (~43 deg)
		angle = clamp(angle, -MAX_STEER_ANGLE - DRIFT_STEER_BONUS, MAX_STEER_ANGLE + DRIFT_STEER_BONUS)
	return angle

## Shorthand: move.x + speed -> steer angle.
static func steer_angle_for_move_vector(move: Vector2, speed_abs: float, is_drifting: bool = false) -> float:
	var inp := steer_input_from_move_vector(move)
	return steer_angle_for_input(inp, speed_abs, is_drifting)

# ---------------------------------------------------------------------------
# Drift / handbrake — modifies friction
# ---------------------------------------------------------------------------
## Whether drift is effective (held + above min speed + has lateral input).
static func is_drift_active(is_drift_held: bool, speed_abs: float, steer_input_abs: float = 0.0) -> bool:
	if not is_drift_held:
		return false
	if speed_abs < DRIFT_MIN_SPEED:
		return false
	# Require some steering or lateral slip to count as active drift (avoid straight-line handbrake slide confusion).
	# Allow straight-line drift if speed > 8 m/s (RL allows straight drift initiation at speed).
	if absf(steer_input_abs) < 0.08 and speed_abs < 8.0:
		return false
	return true

## Lateral grip scale while drifting: 0.22..0.32 depending on steer and speed.
static func drift_lateral_grip_scale(speed_abs: float, steer_input_abs: float = 0.5) -> float:
	# At higher steer, more slide (lower grip). At higher speed, slightly lower grip.
	var speed_t := clamp(speed_abs / EngineRef.MAX_SPEED_FORWARD, 0.0, 1.0)
	var steer_t := clamp(absf(steer_input_abs), 0.0, 1.0)
	var base := DRIFT_LATERAL_GRIP_SCALE
	# Map steer 0..1 -> grip 0.32..0.22
	var steer_blend := lerp(base, DRIFT_LATERAL_GRIP_SCALE_MIN, steer_t * 0.7)
	# Speed slightly reduces grip further
	steer_blend *= lerp(1.0, 0.88, speed_t * 0.5)
	return clamp(steer_blend, DRIFT_LATERAL_GRIP_SCALE_MIN, DRIFT_LATERAL_GRIP_SCALE)

static func drift_longitudinal_grip_scale() -> float:
	return DRIFT_LONGITUDINAL_GRIP_SCALE

## Drift yaw torque (Nm) to apply while drifting: proportional to steer * speed * lateral grip loss.
static func drift_yaw_torque(steer_input: float, speed_abs: float, is_drift_held: bool) -> float:
	if not is_drift_held or speed_abs < DRIFT_MIN_SPEED:
		return 0.0
	var clamped := clamp(steer_input, -1.0, 1.0)
	var speed_factor := clamp(speed_abs / 12.0, 0.0, 1.6)
	return clamped * DRIFT_YAW_TORQUE * speed_factor * 0.55

## Friction modifier pair for WS13 integration. Returns Dictionary {lateral_scale, longitudinal_scale, is_drifting}.
static func friction_modifier(is_drift_held: bool, speed_abs: float, steer_input: float = 0.0) -> Dictionary:
	var active := is_drift_active(is_drift_held, speed_abs, absf(steer_input))
	if not active:
		return {"lateral_scale": 1.0, "longitudinal_scale": 1.0, "is_drifting": false, "grip": 1.0}
	var lat := drift_lateral_grip_scale(speed_abs, absf(steer_input))
	var lon := drift_longitudinal_grip_scale()
	return {"lateral_scale": lat, "longitudinal_scale": lon, "is_drifting": true, "grip": lat}

## Apply drift-modified friction scales via TireFriction helper (optional convenience).
static func apply_friction_modifier_to_forces(forces: Array[Vector3], modifier: Dictionary) -> Array[Vector3]:
	var scale: float = float(modifier.get("lateral_scale", 1.0))
	if is_equal_approx(scale, 1.0):
		return forces
	# Caller would normally multiply lateral components; this is a placeholder that returns scaled copy.
	# Real integration: FrictionRef.compute_forces returns world forces; lateral component is along chassis right.
	# We conservatively scale entire force by blended scale (lateral dominates so approximate is fine; budget <12 calls).
	var blended := lerp(1.0, scale, 0.85)
	var out: Array[Vector3] = []
	out.resize(forces.size())
	for i in range(forces.size()):
		out[i] = forces[i] * blended
	return out

# ---------------------------------------------------------------------------
# Steering response (exponential lerp — frame-rate independent, 120Hz)
# ---------------------------------------------------------------------------
static func apply_steer_response(current: float, target: float, delta: float, is_returning: bool = false) -> float:
	var clamped_target := clamp(target, -MAX_STEER_ANGLE - DRIFT_STEER_BONUS, MAX_STEER_ANGLE + DRIFT_STEER_BONUS)
	if is_equal_approx(current, clamped_target):
		return clamped_target
	var rate := STEER_RETURN_RATE if is_returning and absf(clamped_target) < absf(current) else STEER_RESPONSE_RATE
	# Drift uses slightly slower lerp when actively drifting (more slide, less snap)
	# Caller can pass drift-adjusted rate if needed via DRIFT_RESPONSE_RATE externally.
	var alpha := 1.0 - exp(-rate * delta)
	return lerp(current, clamped_target, alpha)

static func steer_response(current: float, target: float, delta: float) -> float:
	var is_returning := absf(target) < absf(current)
	return apply_steer_response(current, target, delta, is_returning)

# ---------------------------------------------------------------------------
# Integration helpers — apply steering to CarPhysics RigidBody3D
# ---------------------------------------------------------------------------
## Compute current target angle from InputService + car speed, update instance lerp, return current angle.
func update(delta: float, speed_abs_override: float = NAN, steer_override: float = NAN, drift_override: Variant = null) -> float:
	var steer_in: float = steer_override if not is_nan(steer_override) else get_steer_input_from_service()
	var drifting: bool = drift_override if drift_override != null else is_drift_from_service()
	var speed_abs: float = speed_abs_override
	if is_nan(speed_abs):
		speed_abs = _last_speed
	_is_drifting = is_drift_active(drifting, speed_abs, absf(steer_in))
	_target_steer_angle = steer_angle_for_input(steer_in, speed_abs, _is_drifting)
	if _is_drifting:
		_drift_time += delta
	else:
		_drift_time = 0.0
	var is_returning := is_zero_approx(_target_steer_angle) and not is_zero_approx(_current_steer_angle)
	var rate := DRIFT_RESPONSE_RATE if _is_drifting else (STEER_RETURN_RATE if is_returning else STEER_RESPONSE_RATE)
	var alpha := 1.0 - exp(-rate * delta)
	_current_steer_angle = lerp(_current_steer_angle, _target_steer_angle, alpha)
	_last_speed = speed_abs
	return _current_steer_angle

## Poll InputService and update (convenience).
func poll_input_and_update(delta: float, speed_abs: float) -> float:
	_last_speed = speed_abs
	return update(delta, speed_abs)

## Apply steering yaw torque to a CarPhysics body. Budget-aware: single torque impulse, <4ms.
## steer_angle: current steer (rad), speed: forward speed (m/s), is_drifting: drift active.
static func apply_to_car(car: RigidBody3D, delta: float, steer_angle_arg: float = NAN, speed_override: float = NAN, drift_held_arg: Variant = null) -> Dictionary:
	if car == null:
		return {"steer_angle": 0.0, "yaw_torque": 0.0, "friction_modifier": {"lateral_scale": 1.0, "longitudinal_scale": 1.0}}
	var steer_angle: float = steer_angle_arg
	var speed_abs: float = speed_override
	var drift_held: bool = false
	if drift_held_arg != null:
		drift_held = bool(drift_held_arg)
	else:
		drift_held = is_drift_from_service()
	# Resolve speed from car velocity if not provided
	if is_nan(speed_abs):
		var vel: Vector3 = Vector3.ZERO
		if "linear_velocity" in car:
			vel = car.linear_velocity as Vector3
		var fwd := car.global_transform.basis.z.normalized()
		if fwd.length_squared() < 0.1:
			fwd = Vector3(0, 0, 1)
		var fwd_speed: float = vel.dot(fwd)
		speed_abs = absf(fwd_speed)
	if is_nan(steer_angle):
		var inp := get_steer_input_from_service()
		var active := is_drift_active(drift_held, speed_abs, absf(inp))
		steer_angle = steer_angle_for_input(inp, speed_abs, active)
	var mod := friction_modifier(drift_held, speed_abs, steer_angle / max(MAX_STEER_ANGLE, 0.1))
	# Yaw torque: steer creates yaw; drift amplifies with extra torque.
	var base_yaw := steer_angle * 4200.0 * clamp(speed_abs / 10.0, 0.15, 1.4)
	var drift_torque: float = 0.0
	if bool(mod.get("is_drifting", false)):
		# Estimate steer_input from angle for drift torque
		var approx_input := clamp(steer_angle / MAX_STEER_ANGLE, -1.0, 1.0)
		drift_torque = drift_yaw_torque(approx_input, speed_abs, drift_held)
	var total_yaw := base_yaw + drift_torque
	# Apply as torque impulse (scaled by delta to keep frame-rate independent at 120Hz)
	if car.has_method("apply_torque_impulse"):
		car.apply_torque_impulse(Vector3(0, total_yaw * delta, 0))
	else:
		car.apply_torque(Vector3(0, total_yaw, 0))
	return {"steer_angle": steer_angle, "yaw_torque": total_yaw, "friction_modifier": mod, "is_drifting": bool(mod.get("is_drifting", false))}

## Combined suspension + friction + steering tick helper.
func process_car(car: RigidBody3D, suspension: Variant, delta: float) -> Dictionary:
	if car == null:
		return {"steer_angle": _current_steer_angle, "is_drifting": _is_drifting}
	var vel: Vector3 = Vector3.ZERO
	if "linear_velocity" in car:
		vel = car.linear_velocity as Vector3
	var fwd := car.global_transform.basis.z.normalized()
	if fwd.length_squared() < 0.1:
		fwd = Vector3(0, 0, 1)
	var speed := absf(vel.dot(fwd))
	var ang := update(delta, speed)
	var applied := CarSteering.apply_to_car(car, delta, ang, speed, _is_drifting)
	return applied

func get_current_steer_angle() -> float:
	return _current_steer_angle

func get_target_steer_angle() -> float:
	return _target_steer_angle

func is_drifting() -> bool:
	return _is_drifting

func get_drift_time() -> float:
	return _drift_time

func reset() -> void:
	_current_steer_angle = 0.0
	_target_steer_angle = 0.0
	_is_drifting = false
	_drift_time = 0.0
	_last_speed = 0.0

# ---------------------------------------------------------------------------
# Validation & telemetry — conventions §11 — budget-aware (<4ms, <12 calls)
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA %.6f != 1/120" % TICK_DELTA)
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC PHYSICS_TICKS %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if PConfig.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PConfig TICKS %d != 120" % PConfig.PHYSICS_TICKS_PER_SECOND)
	if SuspensionRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("Suspension tick %d != 120" % SuspensionRef.PHYSICS_TICKS_PER_SECOND)
	if FrictionRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("Friction tick %d != 120" % FrictionRef.PHYSICS_TICKS_PER_SECOND)
	if PL.BIT_WHEELS != 4:
		errors.append("BIT_WHEELS %d != 4" % PL.BIT_WHEELS)
	if PL.MASK_WHEELS != PL.BIT_WORLD_STATIC:
		errors.append("MASK_WHEELS %d != BIT_WORLD_STATIC %d" % [PL.MASK_WHEELS, PL.BIT_WORLD_STATIC])
	if get_steering_mask() != PL.MASK_WHEELS:
		errors.append("get_steering_mask != PL.MASK_WHEELS")
	if MAX_STEER_ANGLE <= 0.0 or MAX_STEER_ANGLE > 1.2:
		errors.append("MAX_STEER_ANGLE %.3f out of (0,1.2]" % MAX_STEER_ANGLE)
	if MIN_STEER_ANGLE <= 0.0 or MIN_STEER_ANGLE >= MAX_STEER_ANGLE:
		errors.append("MIN_STEER_ANGLE %.3f must be in (0, MAX %.3f)" % [MIN_STEER_ANGLE, MAX_STEER_ANGLE])
	if STEERING_CURVE.size() < 2:
		errors.append("STEERING_CURVE needs >=2 points")
	for i in range(STEERING_CURVE.size() - 1):
		if STEERING_CURVE[i].x >= STEERING_CURVE[i + 1].x:
			errors.append("STEERING_CURVE x not strictly increasing at %d" % i)
		if STEERING_CURVE[i].y < 0.0 or STEERING_CURVE[i].y > 1.05:
			errors.append("STEERING_CURVE y out of [0,1.05] at %d" % i)
	if not is_equal_approx(STEERING_CURVE[0].y, 1.0):
		errors.append("STEERING_CURVE must start at y=1.0")
	if STEERING_CURVE[STEERING_CURVE.size() - 1].y < 0.15 or STEERING_CURVE[STEERING_CURVE.size() - 1].y > 0.35:
		errors.append("STEERING_CURVE end y %.3f outside [0.15,0.35]" % STEERING_CURVE[STEERING_CURVE.size() - 1].y)
	if STEER_RESPONSE_RATE <= 0.0 or STEER_RETURN_RATE <= 0.0:
		errors.append("steer response rates must be >0")
	if DRIFT_LATERAL_GRIP_SCALE <= 0.0 or DRIFT_LATERAL_GRIP_SCALE >= 1.0:
		errors.append("DRIFT_LATERAL_GRIP_SCALE %.3f must be in (0,1)" % DRIFT_LATERAL_GRIP_SCALE)
	if DRIFT_LATERAL_GRIP_SCALE_MIN <= 0.0 or DRIFT_LATERAL_GRIP_SCALE_MIN >= DRIFT_LATERAL_GRIP_SCALE:
		errors.append("DRIFT_LATERAL_GRIP_SCALE_MIN must be < DRIFT_LATERAL_GRIP_SCALE")
	if DRIFT_LONGITUDINAL_GRIP_SCALE <= 0.0 or DRIFT_LONGITUDINAL_GRIP_SCALE > 1.0:
		errors.append("DRIFT_LONGITUDINAL_GRIP_SCALE out of (0,1]")
	if DRIFT_YAW_TORQUE <= 0.0:
		errors.append("DRIFT_YAW_TORQUE must be >0")
	if DRIFT_MIN_SPEED < 0.0:
		errors.append("DRIFT_MIN_SPEED <0")
	# Curve sanity
	var fac0 := steering_factor_for_speed(0.0)
	if not is_equal_approx(fac0, 1.0):
		errors.append("steering_factor_for_speed(0) %.3f != 1.0" % fac0)
	var fac_max := steering_factor_for_speed(EngineRef.MAX_SPEED_FORWARD)
	if fac_max < 0.18 or fac_max > 0.30:
		errors.append("steering_factor at max speed %.3f outside [0.18,0.30]" % fac_max)
	var ang0 := steer_angle_for_input(1.0, 0.0)
	if not is_equal_approx(ang0, MAX_STEER_ANGLE):
		errors.append("steer_angle_for_input(1,0) %.3f != MAX %.3f" % [ang0, MAX_STEER_ANGLE])
	var ang_high := steer_angle_for_input(1.0, EngineRef.MAX_SPEED_FORWARD)
	if ang_high >= ang0:
		errors.append("steer at high speed %.3f should be < low speed %.3f" % [ang_high, ang0])
	# InputService integration probe
	var probe_left := steer_input_from_move_vector(Vector2(-1, 0))
	if not is_equal_approx(probe_left, -1.0):
		errors.append("steer_input_from_move_vector left != -1")
	var probe_right := steer_input_from_move_vector(Vector2(1, 0))
	if not is_equal_approx(probe_right, 1.0):
		errors.append("steer_input_from_move_vector right != 1")
	var probe_zero := steer_input_from_move_vector(Vector2.ZERO)
	if not is_equal_approx(probe_zero, 0.0):
		errors.append("steer_input_from_move_vector ZERO != 0")
	# Drift friction modifier sanity
	var mod_off := friction_modifier(false, 10.0, 0.5)
	if not is_equal_approx(float(mod_off["lateral_scale"]), 1.0):
		errors.append("friction_modifier off lateral !=1")
	var mod_on := friction_modifier(true, 10.0, 0.8)
	if bool(mod_on["is_drifting"]) != true:
		errors.append("friction_modifier on should be drifting at speed 10 steer 0.8")
	if float(mod_on["lateral_scale"]) >= 1.0:
		errors.append("drift lateral_scale should be <1")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"max_steer_angle": MAX_STEER_ANGLE,
		"max_steer_angle_deg": MAX_STEER_ANGLE_DEG,
		"min_steer_angle": MIN_STEER_ANGLE,
		"steer_angle_max": STEER_ANGLE_MAX,
		"steer_angle_min": STEER_ANGLE_MIN,
		"steering_curve": STEERING_CURVE,
		"steer_response_rate": STEER_RESPONSE_RATE,
		"steer_return_rate": STEER_RETURN_RATE,
		"steer_deadzone": STEER_DEADZONE,
		"drift_lateral_grip_scale": DRIFT_LATERAL_GRIP_SCALE,
		"drift_lateral_grip_scale_min": DRIFT_LATERAL_GRIP_SCALE_MIN,
		"drift_longitudinal_grip_scale": DRIFT_LONGITUDINAL_GRIP_SCALE,
		"drift_grip_scale": DRIFT_GRIP_SCALE,
		"drift_yaw_torque": DRIFT_YAW_TORQUE,
		"drift_steer_bonus": DRIFT_STEER_BONUS,
		"drift_min_speed": DRIFT_MIN_SPEED,
		"drift_response_rate": DRIFT_RESPONSE_RATE,
		"physics_tick_hz": PHYSICS_TICKS_PER_SECOND,
		"physics_tick_delta": TICK_DELTA,
		"tick_hz": PC.PHYSICS_TICKS_PER_SECOND,
		"ray_mask": get_steering_mask(),
		"ray_layer": get_steering_layer(),
		"suspension_rest_length": SuspensionRef.REST_LENGTH,
		"friction_lateral_D": FrictionRef.LATERAL_D,
		"engine_max_speed": EngineRef.MAX_SPEED_FORWARD,
	}

func debug_export_instance() -> Dictionary:
	var d := CarSteering.debug_export()
	d["current_steer_angle"] = _current_steer_angle
	d["target_steer_angle"] = _target_steer_angle
	d["is_drifting"] = _is_drifting
	d["drift_time"] = _drift_time
	d["last_speed"] = _last_speed
	return d

static func perf_mark() -> Dictionary:
	var t0 := Time.get_ticks_usec()
	for i in range(12):
		var _a := steering_factor_for_speed(float(i) * 2.5)
		var _b := steer_angle_for_input(0.7, float(i) * 2.5, i % 2 == 0)
		var _c := friction_modifier(i % 2 == 0, float(i) * 3.0, 0.5)
	var dt := float(Time.get_ticks_usec() - t0) / 1000.0
	return {"scope": "CarSteering", "steer_12x_ms": dt, "budget_ms": 4.0, "within_budget": dt < 4.0, "ticks_per_second": PHYSICS_TICKS_PER_SECOND, "max_steer_angle": MAX_STEER_ANGLE, "calls": 12}

func perf_mark_instance() -> Dictionary:
	return {"scope": "CarSteering", "current_angle": _current_steer_angle, "is_drifting": _is_drifting, "tick_hz": PHYSICS_TICKS_PER_SECOND, "budget_ms": 4.0}
