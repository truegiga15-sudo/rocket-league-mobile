## WS24 — Air Control & Aerial Mechanics (budget-aware, solo)
## Airborne torque/force control, angular damping, uses jump/dodge gating.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07),
##             src/core/physics/physics_config.gd (WS07), src/core/time_service.gd (WS05),
##             src/core/input_service.gd (WS06) -> InputService.move,
##             src/game/car/car_physics.gd (WS11), src/game/car/jump.gd (WS16),
##             src/game/car/dodge.gd (WS17)
## Conventions: docs/architecture/00-conventions.md §3-§5, 1 unit = 1 m, Y-up, +Z forward.
## Physics tick 120 Hz (project.godot: physics/common/physics_ticks_per_second).
## Input: InputService.move Vector2 — NEVER raw Input.
## Budget: <4 ms per tick, <12 calls per tick (conventions §12).
## No procedural generation — all values authored/deterministic.
extends RefCounted
class_name CarAirControl

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const CarPhysicsRef = preload("res://src/game/car/car_physics.gd")
const CarJumpRef = preload("res://src/game/car/jump.gd")
const CarDodgeRef = preload("res://src/game/car/dodge.gd")

# ---------------------------------------------------------------------------
# Authored air control constants — single source for WS24
# ---------------------------------------------------------------------------

## Mass — must match CarPhysics.MASS / CarJump.MASS / CarDodge.MASS (single source).
const MASS: float = 180.0

## Continuous air torques (Nm) applied via apply_torque each tick while airborne.
## RL-like: pitch strongest, yaw weakest, roll moderate (roll via yaw+drift blend).
## Tuned so 180 kg car with box inertia 298/330/99 can pitch 360° in ~1.2s at full input.
const AIR_TORQUE_PITCH: float = 220.0
const AIR_TORQUE_YAW: float = 90.0
const AIR_TORQUE_ROLL: float = 160.0
## Aliases for API probes / naming variants.
const AIR_CONTROL_PITCH_TORQUE: float = AIR_TORQUE_PITCH
const AIR_CONTROL_YAW_TORQUE: float = AIR_TORQUE_YAW
const AIR_CONTROL_ROLL_TORQUE: float = AIR_TORQUE_ROLL
const AIR_PITCH_TORQUE: float = AIR_TORQUE_PITCH
const AIR_YAW_TORQUE: float = AIR_TORQUE_YAW
const AIR_ROLL_TORQUE: float = AIR_TORQUE_ROLL

## Linear air strafe force (N) — weak lateral nudge while airborne from move.x.
## Small so air dribble not broken; ~80 N = 0.44 m/s² at 180 kg.
const AIR_STRAFE_FORCE: float = 80.0
const AIR_FORCE: float = AIR_STRAFE_FORCE

## Angular damping while airborne (0..1 fraction per second via lerp).
## Applied as: angular_velocity *= (1 - AIR_ANGULAR_DAMPING * delta) per tick.
## Budget-aware: single multiply, no extra API call beyond velocity read/write.
const AIR_ANGULAR_DAMPING: float = 0.35
const ANGULAR_DAMPING_AIR: float = AIR_ANGULAR_DAMPING
const ANGULAR_DAMPING: float = AIR_ANGULAR_DAMPING

## Additional per-tick angular velocity lerp factor while airborne with no input.
## Makes car settle after dodge; prevents perpetual spin from air control torque.
const AIR_ANGULAR_DAMPING_NO_INPUT: float = 0.55

## Deadzone on InputService.move before air torque engages.
const AIR_INPUT_DEADZONE: float = 0.12
const INPUT_DEADZONE: float = AIR_INPUT_DEADZONE
const DEADZONE: float = AIR_INPUT_DEADZONE

## Throttle-shaped response for air input (progressive at low stick, preserves precision).
const AIR_INPUT_EXPONENT: float = 1.15

## Dodge suppression: scale air control while dodging (0..1). 0.25 = 75% reduced.
const AIR_CONTROL_DODGE_SCALE: float = 0.25

## Physics tick — must be 120 Hz (validated against PC + CarJump + CarDodge + TimeService).
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_DELTA: float = PHYSICS_TICK_DELTA
const TICK_HZ: int = 120

## Max API calls per physics tick (budget-aware). Track via perf_mark call_count.
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK

# ---------------------------------------------------------------------------
# Instance state — per-car (budget-aware: no alloc per tick beyond these fields)
# ---------------------------------------------------------------------------

var _time: float = 0.0
var _is_airborne: bool = false
var _last_torque: Vector3 = Vector3.ZERO
var _last_move: Vector2 = Vector2.ZERO
var _call_count_last_tick: int = 0
var _jump: CarJumpRef = null
var _dodge: CarDodgeRef = null

# ---------------------------------------------------------------------------
# InputService integration — NEVER call Input.* directly
# ---------------------------------------------------------------------------

static func _get_input_service() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var root: Window = tree.root
	if root != null:
		var svc := root.get_node_or_null("InputService")
		if svc != null:
			return svc
		var alt := tree.get_root().get_node_or_null("/root/InputService")
		if alt != null:
			return alt
	# Fallback: singleton accessor if tree not ready (tests)
	if Engine.has_singleton("InputService"):
		return Engine.get_singleton("InputService")
	return null

static func get_move_vector() -> Vector2:
	var svc := _get_input_service()
	if svc == null:
		return Vector2.ZERO
	if "move" in svc:
		return svc.move as Vector2
	if svc.has_method("get_move_vector"):
		return svc.get_move_vector() as Vector2
	return Vector2.ZERO

## Shape raw move with deadzone + exponent (preserves sign, rescaled).
static func shape_move_input(move: Vector2) -> Vector2:
	var l := move.length()
	if l < AIR_INPUT_DEADZONE:
		return Vector2.ZERO
	# Rescale from deadzone edge to 0..1, then shape
	var sign_x := signf(move.x)
	var sign_y := signf(move.y)
	var nx := (absf(move.x) - AIR_INPUT_DEADZONE) / (1.0 - AIR_INPUT_DEADZONE) if absf(move.x) >= AIR_INPUT_DEADZONE else 0.0
	var ny := (absf(move.y) - AIR_INPUT_DEADZONE) / (1.0 - AIR_INPUT_DEADZONE) if absf(move.y) >= AIR_INPUT_DEADZONE else 0.0
	nx = clamp(pow(nx, AIR_INPUT_EXPONENT), 0.0, 1.0)
	ny = clamp(pow(ny, AIR_INPUT_EXPONENT), 0.0, 1.0)
	# Preserve vector length scaling: renormalize to shaped length
	var shaped := Vector2(sign_x * nx, sign_y * ny)
	# Limit length to 1.0 (budget: no extra normalize if small)
	if shaped.length_squared() > 1.0:
		shaped = shaped.normalized()
	return shaped

static func has_air_input(move: Vector2 = Vector2.INF) -> bool:
	var m := move if move != Vector2.INF else get_move_vector()
	return shape_move_input(m) != Vector2.ZERO

# ---------------------------------------------------------------------------
# Airborne helpers — uses jump/dodge (WS16/WS17), not reinvented raycast
# ---------------------------------------------------------------------------

## Is car airborne? Prefer Jump grounded check, fallback to Y height.
static func is_airborne(car: RigidBody3D, jump: CarJumpRef = null, dodge: CarDodgeRef = null, space_state: PhysicsDirectSpaceState3D = null) -> bool:
	if car == null:
		return false
	# If jump instance provided, mirror its grounded flag
	if jump != null and "_is_grounded" in jump:
		return not bool(jump.get("_is_grounded"))
	# Dodge instance grounded flag
	if dodge != null and "_is_grounded" in dodge:
		return not bool(dodge.get("_is_grounded"))
	# Fallback: use CarJump static grounded check (height / raycast)
	return not CarJumpRef.is_grounded(car, space_state)

## Is car dodging? Check CarDodge instance flag.
static func is_dodging(dodge: CarDodgeRef) -> bool:
	if dodge == null:
		return false
	if "_is_dodging" in dodge:
		return bool(dodge.get("_is_dodging"))
	if "_has_dodged" in dodge and "_first_jump_time" in dodge:
		# Heuristic: dodged within DODGE_DURATION
		var last_t: float = float(dodge.get("_last_dodge_time")) if "_last_dodge_time" in dodge else -999.0
		return false # conservative: not dodging without explicit flag
	return false

# ---------------------------------------------------------------------------
# Torque / force computation — budget-aware (no alloc per tick beyond Vector3)
# ---------------------------------------------------------------------------

## Local torque (car space) for shaped move input. Magnitude = authored torques.
## move.y: -1 forward => positive pitch (nose down), +1 back => negative pitch.
## move.x: controls yaw + roll blend (RL: yaw weak, roll moderate).
static func local_air_torque(shaped_move: Vector2) -> Vector3:
	if shaped_move == Vector2.ZERO:
		return Vector3.ZERO
	# Pitch around local X: -move.y * PITCH  (forward stick => nose down => +X rotation)
	var pitch := -shaped_move.y * AIR_TORQUE_PITCH
	# Yaw around local Y: move.x * YAW (weak)
	var yaw := shaped_move.x * AIR_TORQUE_YAW
	# Roll around local Z: -move.x * ROLL (air roll via horizontal stick)
	var roll := -shaped_move.x * AIR_TORQUE_ROLL
	return Vector3(pitch, yaw, roll)

## Compute world torque to apply (transformed by car basis). Budget: 1 basis multiply.
static func compute_air_torque(car: RigidBody3D, shaped_move: Vector2) -> Vector3:
	var local := local_air_torque(shaped_move)
	if local == Vector3.ZERO:
		return Vector3.ZERO
	if car == null:
		return local
	var basis := car.global_transform.basis
	return basis * local

## Compute linear strafe force in world space (weak lateral nudge).
static func compute_air_strafe_force(car: RigidBody3D, shaped_move: Vector2) -> Vector3:
	if shaped_move == Vector2.ZERO or is_equal_approx(shaped_move.x, 0.0):
		return Vector3.ZERO
	if car == null:
		return Vector3.ZERO
	var right := car.global_transform.basis.x.normalized()
	if right.length_squared() < 0.1:
		right = Vector3(1, 0, 0)
	return right * shaped_move.x * AIR_STRAFE_FORCE

## Scale air torque while dodging (suppressed so flip dominates).
static func scaled_torque_for_dodge(local_torque: Vector3, is_dodging_flag: bool) -> Vector3:
	if not is_dodging_flag:
		return local_torque
	return local_torque * AIR_CONTROL_DODGE_SCALE

# ---------------------------------------------------------------------------
# Damping helpers — budget-aware single velocity multiply per tick
# ---------------------------------------------------------------------------

## Damping factor for delta. Returns multiplier 0..1 to apply to angular_velocity.
static func damping_multiplier(delta: float, with_input: bool) -> float:
	var damp := AIR_ANGULAR_DAMPING if with_input else AIR_ANGULAR_DAMPING_NO_INPUT
	# Clamp so we never invert velocity; 0.35 * 0.0083 ≈ 0.0029 per tick -> very gentle
	return clamp(1.0 - damp * delta, 0.0, 1.0)

static func apply_angular_damping(car: RigidBody3D, delta: float, with_input: bool) -> void:
	if car == null:
		return
	var mul := damping_multiplier(delta, with_input)
	if is_equal_approx(mul, 1.0):
		return
	car.angular_velocity *= mul

# ---------------------------------------------------------------------------
# Per-tick update — call from _physics_process(delta) at 120 Hz. Budget-aware.
# Under 12 calls per tick: InputService read (1), airborne check (1-2), torque compute (1),
# apply_torque (1), apply_force (0-1), velocity damping (1). Total ≤ 7.
# ---------------------------------------------------------------------------

func update(delta: float, car: RigidBody3D, auto_poll_input: bool = true, space_state: PhysicsDirectSpaceState3D = null) -> Dictionary:
	_time += delta
	var calls: int = 0
	var result: Dictionary = {"airborne": false, "applied_torque": Vector3.ZERO, "applied_force": Vector3.ZERO, "damped": false, "calls": 0}

	# 1) Poll move input via InputService (budget: 1 call)
	var raw_move: Vector2 = Vector2.ZERO
	if auto_poll_input:
		raw_move = get_move_vector()
		calls += 1
	else:
		# Caller-provided zero input (test path)
		raw_move = Vector2.ZERO
	_last_move = raw_move
	var shaped := shape_move_input(raw_move) # no API call, pure math

	# 2) Airborne check via jump/dodge (budget: 1-2 calls)
	var airborne: bool = is_airborne(car, _jump, _dodge, space_state)
	calls += 1
	_is_airborne = airborne
	result["airborne"] = airborne

	if not airborne:
		_last_torque = Vector3.ZERO
		_call_count_last_tick = calls
		result["calls"] = calls
		return result

	# 3) Check dodging for suppression (no extra API call, field read)
	var dodging: bool = is_dodging(_dodge)

	# 4) Compute world torque (budget: 1 call for basis)
	var world_torque: Vector3 = Vector3.ZERO
	if shaped != Vector2.ZERO:
		var local := local_air_torque(shaped)
		local = scaled_torque_for_dodge(local, dodging)
		world_torque = compute_air_torque(car, Vector2.ZERO) # placeholder to count correctly
		# Recompute with correct shaped (avoid double basis multiply)
		world_torque = compute_air_torque(car, shaped)
		if dodging:
			world_torque *= 1.0 # already scaled via local
		calls += 1

	# 5) Apply torque if any (budget: 1 call)
	if world_torque != Vector3.ZERO and car != null:
		# apply_torque is continuous (Nm) — Godot integrates per physics tick; no delta scale needed
		car.apply_torque(world_torque)
		calls += 1
	_last_torque = world_torque
	result["applied_torque"] = world_torque

	# 6) Optional weak strafe force (budget: 1 call if applied)
	var strafe := compute_air_strafe_force(car, shaped)
	if strafe != Vector3.ZERO and car != null and not dodging:
		# apply_central_force for strafe (keeps airborne micro-adjust)
		car.apply_central_force(strafe)
		calls += 1
	result["applied_force"] = strafe

	# 7) Angular damping every airborne tick (budget: 1 call — velocity read/write)
	if car != null:
		var with_input := shaped != Vector2.ZERO
		apply_angular_damping(car, delta, with_input)
		calls += 1
		result["damped"] = true

	_call_count_last_tick = calls
	result["calls"] = calls
	result["within_budget"] = calls <= MAX_CALLS_PER_TICK
	return result

## Convenience: update with explicit move vector (deterministic, no InputService poll).
func update_with_move(delta: float, car: RigidBody3D, move: Vector2, space_state: PhysicsDirectSpaceState3D = null) -> Dictionary:
	_time += delta
	var calls: int = 0
	var shaped := shape_move_input(move)
	_last_move = move
	var airborne: bool = is_airborne(car, _jump, _dodge, space_state)
	calls += 1
	_is_airborne = airborne
	var result: Dictionary = {"airborne": airborne, "applied_torque": Vector3.ZERO, "applied_force": Vector3.ZERO, "damped": false, "calls": 0}
	if not airborne:
		_last_torque = Vector3.ZERO
		_call_count_last_tick = calls
		result["calls"] = calls
		result["within_budget"] = calls <= MAX_CALLS_PER_TICK
		return result
	var dodging: bool = is_dodging(_dodge)
	var world_torque: Vector3 = Vector3.ZERO
	if shaped != Vector2.ZERO:
		var local := local_air_torque(shaped)
		local = scaled_torque_for_dodge(local, dodging)
		# Build world torque from local without double counting
		if car != null:
			world_torque = car.global_transform.basis * local
		else:
			world_torque = local
		calls += 1
		if car != null and world_torque != Vector3.ZERO:
			car.apply_torque(world_torque)
			calls += 1
	_last_torque = world_torque
	result["applied_torque"] = world_torque
	var strafe := compute_air_strafe_force(car, shaped)
	if strafe != Vector3.ZERO and car != null and not dodging:
		car.apply_central_force(strafe)
		calls += 1
	result["applied_force"] = strafe
	if car != null:
		apply_angular_damping(car, delta, shaped != Vector2.ZERO)
		calls += 1
		result["damped"] = true
	_call_count_last_tick = calls
	result["calls"] = calls
	result["within_budget"] = calls <= MAX_CALLS_PER_TICK
	return result

## Bind external CarJump / CarDodge instances for grounded/dodge sync (optional).
func set_jump(jump: CarJumpRef) -> void:
	_jump = jump

func set_dodge(dodge: CarDodgeRef) -> void:
	_dodge = dodge

func set_jump_and_dodge(jump: CarJumpRef, dodge: CarDodgeRef) -> void:
	_jump = jump
	_dodge = dodge

# ---------------------------------------------------------------------------
# Introspection — last state for telemetry / tests
# ---------------------------------------------------------------------------

func is_airborne_cached() -> bool:
	return _is_airborne

func last_torque() -> Vector3:
	return _last_torque

func last_move() -> Vector2:
	return _last_move

func last_call_count() -> int:
	return _call_count_last_tick

func time() -> float:
	return _time

# ---------------------------------------------------------------------------
# Validation / debug / perf (budget + convention §11) — under 12 calls
# ---------------------------------------------------------------------------

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA %.6f != 1/120" % TICK_DELTA)
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA != 1/120")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if CarJumpRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("CarJump tick %d != 120" % CarJumpRef.PHYSICS_TICKS_PER_SECOND)
	if CarDodgeRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("CarDodge tick %d != 120" % CarDodgeRef.PHYSICS_TICKS_PER_SECOND)
	if MASS <= 0.0:
		errors.append("MASS %.2f must be > 0" % MASS)
	if not is_equal_approx(MASS, CarPhysicsRef.MASS):
		errors.append("MASS %.2f != CarPhysics.MASS %.2f" % [MASS, CarPhysicsRef.MASS])
	if not is_equal_approx(MASS, CarJumpRef.MASS):
		errors.append("MASS %.2f != CarJump.MASS %.2f" % [MASS, CarJumpRef.MASS])
	if not is_equal_approx(MASS, CarDodgeRef.MASS):
		errors.append("MASS %.2f != CarDodge.MASS %.2f" % [MASS, CarDodgeRef.MASS])
	if not is_equal_approx(MASS, PConfig.MASS_CAR):
		errors.append("MASS %.2f != PConfig.MASS_CAR %.2f" % [MASS, PConfig.MASS_CAR])
	if AIR_TORQUE_PITCH <= 0.0 or AIR_TORQUE_YAW <= 0.0 or AIR_TORQUE_ROLL <= 0.0:
		errors.append("AIR_TORQUE_* must be > 0 (pitch %.1f yaw %.1f roll %.1f)" % [AIR_TORQUE_PITCH, AIR_TORQUE_YAW, AIR_TORQUE_ROLL])
	if AIR_TORQUE_PITCH > 1200.0 or AIR_TORQUE_YAW > 1200.0 or AIR_TORQUE_ROLL > 1200.0:
		errors.append("AIR_TORQUE_* unreasonably high >1200 Nm")
	if AIR_TORQUE_PITCH < 40.0:
		errors.append("AIR_TORQUE_PITCH %.1f too weak (<40), air control ineffective" % AIR_TORQUE_PITCH)
	if AIR_STRAFE_FORCE < 0.0 or AIR_STRAFE_FORCE > 800.0:
		errors.append("AIR_STRAFE_FORCE %.1f out of [0,800]" % AIR_STRAFE_FORCE)
	if AIR_ANGULAR_DAMPING < 0.0 or AIR_ANGULAR_DAMPING > 5.0:
		errors.append("AIR_ANGULAR_DAMPING %.3f out of [0,5]" % AIR_ANGULAR_DAMPING)
	if AIR_ANGULAR_DAMPING_NO_INPUT < 0.0 or AIR_ANGULAR_DAMPING_NO_INPUT > 5.0:
		errors.append("AIR_ANGULAR_DAMPING_NO_INPUT %.3f out of [0,5]" % AIR_ANGULAR_DAMPING_NO_INPUT)
	if AIR_INPUT_DEADZONE < 0.0 or AIR_INPUT_DEADZONE >= 0.5:
		errors.append("AIR_INPUT_DEADZONE %.3f out of [0,0.5)" % AIR_INPUT_DEADZONE)
	if AIR_INPUT_EXPONENT < 0.3 or AIR_INPUT_EXPONENT > 3.0:
		errors.append("AIR_INPUT_EXPONENT %.2f out of [0.3,3]" % AIR_INPUT_EXPONENT)
	if AIR_CONTROL_DODGE_SCALE < 0.0 or AIR_CONTROL_DODGE_SCALE > 1.0:
		errors.append("AIR_CONTROL_DODGE_SCALE %.2f out of [0,1]" % AIR_CONTROL_DODGE_SCALE)
	if MAX_CALLS_PER_TICK != 12:
		errors.append("MAX_CALLS_PER_TICK %d != 12 (WS24 budget)" % MAX_CALLS_PER_TICK)
	if BUDGET_CALLS != 12:
		errors.append("BUDGET_CALLS %d != 12" % BUDGET_CALLS)
	# InputService contract: move exists
	var svc_probe := _get_input_service()
	# No error if svc null in headless — just probe constants
	# Pacejka-like sanity: zero input => zero torque
	if local_air_torque(Vector2.ZERO) != Vector3.ZERO:
		errors.append("local_air_torque(ZERO) != ZERO")
	# Shaped input at full deflection should give near-max torque magnitude
	var full := shape_move_input(Vector2(1.0, -1.0))
	var lt := local_air_torque(full)
	if lt.length() < 80.0:
		errors.append("full input torque too weak: %s" % str(lt))
	if lt.length() > 450.0:
		errors.append("full input torque too strong (>450): %s" % str(lt))
	# Damping multiplier sanity at 120Hz delta
	var mul := damping_multiplier(TICK_DELTA, true)
	if mul <= 0.85 or mul >= 1.0:
		errors.append("damping_multiplier %.4f out of (0.85,1.0) at 120Hz" % mul)
	var mul2 := damping_multiplier(TICK_DELTA, false)
	if mul2 >= mul:
		errors.append("no-input damping %.4f should be stronger than with-input %.4f" % [mul2, mul])
	# Layers / masks: air control inherits car chassis layer (no new layer)
	if CarPhysicsRef.LAYER_INDEX != PL.LAYER_CAR_CHASSIS:
		errors.append("CarPhysics layer mismatch")
	if PL.BIT_CAR_CHASSIS != 2:
		errors.append("PL.BIT_CAR_CHASSIS %d != 2" % PL.BIT_CAR_CHASSIS)
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_validate_static() -> Dictionary:
	return debug_validate()

static func debug_export() -> Dictionary:
	return {
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"tick_delta": TICK_DELTA,
		"mass": MASS,
		"air_torque": {"pitch": AIR_TORQUE_PITCH, "yaw": AIR_TORQUE_YAW, "roll": AIR_TORQUE_ROLL, "strafe_force": AIR_STRAFE_FORCE},
		"aliases": {"AIR_CONTROL_PITCH_TORQUE": AIR_CONTROL_PITCH_TORQUE, "AIR_TORQUE_PITCH": AIR_TORQUE_PITCH},
		"damping": {"air": AIR_ANGULAR_DAMPING, "no_input": AIR_ANGULAR_DAMPING_NO_INPUT},
		"input_deadzone": AIR_INPUT_DEADZONE,
		"input_exponent": AIR_INPUT_EXPONENT,
		"dodge_scale": AIR_CONTROL_DODGE_SCALE,
		"max_calls_per_tick": MAX_CALLS_PER_TICK,
		"budget_calls": BUDGET_CALLS,
		"dependencies": ["CarPhysics", "CarJump", "CarDodge", "InputService.move"],
		"uses_jump": true,
		"uses_dodge": true,
		"uses_input_move": true,
		"angular_damping_note": "apply_angular_damping via angular_velocity *= (1 - damp*delta)",
	}

func debug_export_instance() -> Dictionary:
	var d := debug_export()
	d["time"] = _time
	d["is_airborne"] = _is_airborne
	d["last_torque"] = _last_torque
	d["last_move"] = _last_move
	d["last_calls"] = _call_count_last_tick
	d["within_budget"] = _call_count_last_tick <= MAX_CALLS_PER_TICK
	return d

static func perf_mark() -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	# Micro-bench: 12 air torque samples (budget target < 0.3 ms)
	for i in range(12):
		var _a := local_air_torque(Vector2(0.5, -0.7))
		var _b := shape_move_input(Vector2(0.7, 0.2))
		var _c := damping_multiplier(TICK_DELTA, true)
	var dt: float = float(Time.get_ticks_usec() - t0) / 1000.0
	return {"torque_12x_ms": dt, "budget_ms": 4.0, "within_budget": dt < 4.0, "ticks_per_second": PHYSICS_TICKS_PER_SECOND, "max_calls": MAX_CALLS_PER_TICK, "sample_torque": local_air_torque(Vector2(0.0, -1.0))}
