## WS16 — Jump / Double Jump (budget-aware)
## First jump + double jump, coyote time, cooldown, ground raycast.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07),
##             src/core/physics/physics_config.gd (WS07), src/core/input_service.gd (WS06),
##             src/core/time_service.gd (WS05), src/game/car/car_physics.gd (WS11)
## Conventions: docs/architecture/00-conventions.md §3-§4, 1 unit = 1 m, Y-up, +Z forward.
## Physics tick 120 Hz (project.godot: physics/common/physics_ticks_per_second).
## Input: InputService.jump / jump_just_pressed — NEVER raw Input.
## Budget: <4 ms per tick (conventions §12) — single raycast + single velocity write.
## No procedural generation — all values authored/deterministic.
extends RefCounted
class_name CarJump

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const CarPhysicsRef = preload("res://src/game/car/car_physics.gd")
const TimeServiceRef = preload("res://src/core/time_service.gd")

# ---------------------------------------------------------------------------
# Authored jump constants — single source for WS16+WS17 (dodge uses double jump)
# ---------------------------------------------------------------------------

## Initial vertical speed applied on jump (m/s). RL ~ 300 uu/s scaled to 5.8 m/s
## for 1 m = 1 unit arena; gives ~1.7 m peak height under 9.81 gravity.
## Impulse = MASS * JUMP_SPEED (1044 Ns at 180 kg).
const JUMP_SPEED: float = 5.8

## Impulse magnitude (Ns) = mass * delta-v. Uses CarPhysics.MASS for single source.
const MASS: float = 180.0
const JUMP_IMPULSE: float = 1044.0 # MASS * JUMP_SPEED = 180 * 5.8

## Double-jump window after first jump (s). RL 1.5 s — must double-jump before expiry.
const DOUBLE_JUMP_WINDOW: float = 1.5

## Cooldown between jumps (s). Prevents spam; 0.15 s = 18 ticks at 120 Hz.
const COOLDOWN: float = 0.15

## Coyote time after leaving ground where jump still allowed (s).
const COYOTE_TIME: float = 0.1

## Alias for API compat.
const COYOTE_WINDOW: float = COYOTE_TIME

## Ground raycast length past chassis bottom (m). Half-height 0.75 + 0.35 = 1.1 span.
const GROUND_RAY_LENGTH: float = 0.3

## Full ray span from car center downwards.
const GROUND_RAY_SPAN: float = 1.1

## Ground check ray offset for chassis half-height reference.
const RAY_ORIGIN_OFFSET: float = 0.0

## Physics tick rate — must be 120 Hz (validated against TimeService + CarPhysics).
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0

## Velocity threshold to consider car "on ground" without raycast (fallback).
const GROUND_VELOCITY_EPS: float = 0.05

# ---------------------------------------------------------------------------
# State — per-car instance
# ---------------------------------------------------------------------------

var _last_ground_time: float = -999.0
var _last_jump_time: float = -999.0
var _first_jump_time: float = -999.0
var _has_double_jumped: bool = false
var _is_grounded: bool = false
var _coyote_active: bool = false
var _jump_count: int = 0
var _time: float = 0.0

# ---------------------------------------------------------------------------
# InputService integration — NEVER call Input.* directly
# ---------------------------------------------------------------------------

static func _get_input_service() -> Node:
	if Engine.has_singleton("InputService"):
		return Engine.get_singleton("InputService")
	var root := Engine.get_main_loop()
	if root != null and root is SceneTree:
		var tree := root as SceneTree
		if tree.current_scene != null and tree.current_scene.has_node("/root/InputService"):
			return tree.current_scene.get_node("/root/InputService")
		if tree.root != null and tree.root.has_node("InputService"):
			return tree.root.get_node("InputService")
	return null

## Read jump just-pressed from InputService.
static func is_jump_just_pressed() -> bool:
	var svc := _get_input_service()
	if svc == null:
		return false
	if "jump_just_pressed" in svc:
		return bool(svc.jump_just_pressed)
	if "jump" in svc:
		return bool(svc.jump)
	return false

## Read jump held from InputService.
static func is_jump_held() -> bool:
	var svc := _get_input_service()
	if svc == null:
		return false
	if "jump_held" in svc:
		return bool(svc.jump_held)
	if "jump" in svc:
		return bool(svc.jump)
	return false

# ---------------------------------------------------------------------------
# Impulse helpers — MASS * JUMP_SPEED via CarPhysics
# ---------------------------------------------------------------------------

## Impulse vector for a jump (Ns). Default uses CarPhysics.MASS.
static func jump_impulse(mass: float = MASS) -> Vector3:
	return Vector3(0, mass * JUMP_SPEED, 0)

## Impulse scalar (Ns) — convenience for telemetry.
static func jump_impulse_scalar(mass: float = MASS) -> float:
	return mass * JUMP_SPEED

## Validate that MASS matches CarPhysics.MASS (single source).
static func _mass_matches_car_physics() -> bool:
	return is_equal_approx(MASS, CarPhysicsRef.MASS)

# ---------------------------------------------------------------------------
# Ground detection — raycast (budget-aware: single ray, no allocations per tick)
# ---------------------------------------------------------------------------

## Single ground raycast from car position downwards. Returns true if ground hit.
## Uses PhysicsDirectSpaceState intersect_ray when 3D world available; falls back
## to Y-height check (floor at 0) for headless/unit tests.
static func is_grounded_raycast(car: RigidBody3D, space_state: PhysicsDirectSpaceState3D = null) -> bool:
	if car == null:
		return false
	var y := car.global_position.y
	var half_h: float = PC.CAR_HALF_EXTENTS.y
	if space_state == null:
		if car.get_world_3d() != null and car.get_world_3d().direct_space_state != null:
			space_state = car.get_world_3d().direct_space_state
		else:
			return y <= half_h + GROUND_RAY_LENGTH + 0.02
	var from := car.global_position
	var to := from + Vector3(0, -(half_h + GROUND_RAY_LENGTH + 0.05), 0)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = PL.BIT_WORLD_STATIC
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.hit_from_inside = false
	var hit := space_state.intersect_ray(query)
	return not hit.is_empty()

## Non-raycast grounded check: height + velocity heuristic (for tests without physics world).
static func is_grounded_height_check(car: RigidBody3D) -> bool:
	if car == null:
		return false
	var y: float = car.global_position.y
	var half_h: float = PC.CAR_HALF_EXTENTS.y
	return y <= half_h + GROUND_RAY_LENGTH + 0.02

## Unified grounded check — prefers raycast, falls back to height.
static func is_grounded(car: RigidBody3D, space_state: PhysicsDirectSpaceState3D = null) -> bool:
	if car == null:
		return false
	if car.get_world_3d() != null and car.get_world_3d().direct_space_state != null:
		return is_grounded_raycast(car, space_state if space_state != null else car.get_world_3d().direct_space_state)
	return is_grounded_height_check(car)

# ---------------------------------------------------------------------------
# Jump eligibility
# ---------------------------------------------------------------------------

## Can perform first jump? (grounded or within coyote window, cooldown elapsed)
func can_jump(time: float = -1.0) -> bool:
	var t := _time if time < 0.0 else time
	if t - _last_jump_time < COOLDOWN:
		return false
	if _is_grounded:
		return true
	if _coyote_active and t - _last_ground_time <= COYOTE_TIME:
		return true
	return false

## Can perform double jump? (airborne, first jump done, no double yet, within window, cooldown)
func can_double_jump(time: float = -1.0) -> bool:
	var t := _time if time < 0.0 else time
	if _has_double_jumped:
		return false
	if _jump_count == 0:
		return false
	if _is_grounded:
		return false
	if t - _last_jump_time < COOLDOWN:
		return false
	if t - _first_jump_time > DOUBLE_JUMP_WINDOW:
		return false
	return true

## Unified can_jump_or_double_jump.
func can_jump_any(time: float = -1.0) -> bool:
	return can_jump(time) or can_double_jump(time)

# ---------------------------------------------------------------------------
# Jump execution — apply vertical velocity / impulse (budget-aware: single velocity write)
# ---------------------------------------------------------------------------

## Apply first jump to car. Returns true if jumped.
func do_jump(car: RigidBody3D, time: float = -1.0) -> bool:
	var t := _time if time < 0.0 else time
	if not can_jump(t):
		return false
	_apply_jump_velocity(car)
	_last_jump_time = t
	_first_jump_time = t
	_jump_count = 1
	_has_double_jumped = false
	return true

## Apply double jump to car. Returns true if double-jumped.
func do_double_jump(car: RigidBody3D, time: float = -1.0) -> bool:
	var t := _time if time < 0.0 else time
	if not can_double_jump(t):
		return false
	_apply_jump_velocity(car)
	_last_jump_time = t
	_has_double_jumped = true
	_jump_count = 2
	return true

## Try jump then double jump in one call. Returns 0 none, 1 first, 2 double.
func try_jump(car: RigidBody3D, time: float = -1.0) -> int:
	var t := _time if time < 0.0 else time
	if do_jump(car, t):
		return 1
	if do_double_jump(car, t):
		return 2
	return 0

static func _apply_jump_velocity(car: RigidBody3D) -> void:
	if car == null:
		return
	# Budget-aware: single velocity write, impulse-equivalent (MASS * JUMP_SPEED)
	# Using velocity set preserves XZ, matches RL behavior. Impulse alternative:
	# car.apply_central_impulse(Vector3(0, CarPhysicsRef.MASS * JUMP_SPEED, 0))
	var v := car.linear_velocity
	v.y = JUMP_SPEED
	car.linear_velocity = v

## Apply impulse variant (uses CarPhysics.MASS * JUMP_SPEED via apply_central_impulse).
static func apply_jump_impulse(car: RigidBody3D) -> void:
	if car == null:
		return
	car.apply_central_impulse(jump_impulse(CarPhysicsRef.MASS))

# ---------------------------------------------------------------------------
# Per-tick update — call from _physics_process(delta) at 120 Hz
# ---------------------------------------------------------------------------

## Update grounded state and timers, poll InputService.jump if auto_jump enabled.
## When auto_jump=false (default) just updates timers; caller handles try_jump on input.
func update(delta: float, car: RigidBody3D, auto_poll_input: bool = false, space_state: PhysicsDirectSpaceState3D = null) -> void:
	_time += delta
	var grounded := is_grounded(car, space_state)
	_update_grounded(grounded, _time)
	if auto_poll_input and is_jump_just_pressed():
		try_jump(car, _time)

func _update_grounded(grounded: bool, t: float) -> void:
	if grounded:
		_last_ground_time = t
		_is_grounded = true
		_coyote_active = true
		if t - _last_jump_time > COOLDOWN:
			_has_double_jumped = false
			_jump_count = 0
			_first_jump_time = -999.0
	else:
		if _is_grounded:
			_is_grounded = false
		if t - _last_ground_time > COYOTE_TIME:
			_coyote_active = false
		if _jump_count == 1 and t - _first_jump_time > DOUBLE_JUMP_WINDOW:
			_has_double_jumped = true

## Direct grounded override for tests/determinism harness.
func set_grounded(grounded: bool, t: float = -1.0) -> void:
	var tt := _time if t < 0.0 else t
	_update_grounded(grounded, tt)

func reset() -> void:
	_last_ground_time = -999.0
	_last_jump_time = -999.0
	_first_jump_time = -999.0
	_has_double_jumped = false
	_is_grounded = false
	_coyote_active = false
	_jump_count = 0
	_time = 0.0

# ---------------------------------------------------------------------------
# Process car helper — reads InputService.jump and applies jump if pressed
# ---------------------------------------------------------------------------

## Poll InputService.jump and apply jump to car. Returns 0/1/2 as try_jump.
func process_car(car: RigidBody3D, delta: float, space_state: PhysicsDirectSpaceState3D = null) -> int:
	_time += delta
	var grounded := is_grounded(car, space_state)
	_update_grounded(grounded, _time)
	if is_jump_just_pressed():
		return try_jump(car, _time)
	return 0

# ---------------------------------------------------------------------------
# Validation & telemetry — conventions §11
# ---------------------------------------------------------------------------

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(JUMP_SPEED, 5.8):
		errors.append("JUMP_SPEED %.3f != 5.8" % JUMP_SPEED)
	if JUMP_SPEED <= 0.0:
		errors.append("JUMP_SPEED must be > 0")
	if not is_equal_approx(JUMP_IMPULSE, MASS * JUMP_SPEED):
		errors.append("JUMP_IMPULSE %.1f != MASS*JUMP_SPEED %.1f" % [JUMP_IMPULSE, MASS * JUMP_SPEED])
	if not is_equal_approx(MASS, CarPhysicsRef.MASS):
		errors.append("MASS %.1f != CarPhysics.MASS %.1f" % [MASS, CarPhysicsRef.MASS])
	if not is_equal_approx(DOUBLE_JUMP_WINDOW, 1.5):
		errors.append("DOUBLE_JUMP_WINDOW %.3f != 1.5" % DOUBLE_JUMP_WINDOW)
	if DOUBLE_JUMP_WINDOW <= 0.0:
		errors.append("DOUBLE_JUMP_WINDOW must be > 0")
	if not is_equal_approx(COOLDOWN, 0.15):
		errors.append("COOLDOWN %.3f != 0.15" % COOLDOWN)
	if COOLDOWN < 0.0:
		errors.append("COOLDOWN must be >= 0")
	if not is_equal_approx(COYOTE_TIME, 0.1):
		errors.append("COYOTE_TIME %.3f != 0.1" % COYOTE_TIME)
	if COYOTE_TIME < 0.0 or COYOTE_TIME > 0.3:
		errors.append("COYOTE_TIME %.3f outside [0,0.3]" % COYOTE_TIME)
	if GROUND_RAY_LENGTH <= 0.0:
		errors.append("GROUND_RAY_LENGTH must be > 0")
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA mismatch")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PC.PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PC PHYSICS_TICK_DELTA mismatch")
	if TimeServiceRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("TimeService PHYSICS_TICKS_PER_SECOND %d != 120" % TimeServiceRef.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TimeServiceRef.TICK_DELTA, 1.0 / 120.0):
		errors.append("TimeService TICK_DELTA mismatch")
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != -1 and ps_rate != 120:
		errors.append("project.godot ticks %d != 120" % ps_rate)
	var j := CarJump.new()
	j._time = 0.0
	j._is_grounded = true
	j._last_ground_time = 0.0
	if not j.can_jump(0.2):
		errors.append("can_jump should be true when grounded and cooldown elapsed")
	j._last_jump_time = 0.0
	if j.can_jump(0.05):
		errors.append("can_jump should be false within COOLDOWN")
	var jc := CarJump.new()
	jc._time = 0.2
	jc._is_grounded = false
	jc._last_ground_time = 0.15
	jc._coyote_active = true
	jc._last_jump_time = -999.0
	if not jc.can_jump(0.2):
		errors.append("coyote jump should be allowed within COYOTE_TIME")
	if jc.can_jump(0.3):
		errors.append("coyote jump should be denied after COYOTE_TIME")
	var jd := CarJump.new()
	jd._time = 1.0
	jd._is_grounded = false
	jd._jump_count = 1
	jd._first_jump_time = 0.0
	jd._last_jump_time = 0.0
	jd._has_double_jumped = false
	if not jd.can_double_jump(1.0):
		errors.append("double jump should be allowed within window")
	if jd.can_double_jump(2.0):
		errors.append("double jump should be denied after DOUBLE_JUMP_WINDOW")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"jump_speed": JUMP_SPEED,
		"jump_impulse": JUMP_IMPULSE,
		"mass": MASS,
		"double_jump_window": DOUBLE_JUMP_WINDOW,
		"cooldown": COOLDOWN,
		"coyote_time": COYOTE_TIME,
		"coyote_window": COYOTE_WINDOW,
		"ground_ray_length": GROUND_RAY_LENGTH,
		"ground_ray_span": GROUND_RAY_SPAN,
		"physics_tick_hz": PHYSICS_TICKS_PER_SECOND,
		"physics_tick_delta": PHYSICS_TICK_DELTA,
	}

func debug_export_instance() -> Dictionary:
	var d := CarJump.debug_export()
	d["is_grounded"] = _is_grounded
	d["coyote_active"] = _coyote_active
	d["has_double_jumped"] = _has_double_jumped
	d["jump_count"] = _jump_count
	d["time"] = _time
	d["last_ground_time"] = _last_ground_time
	d["last_jump_time"] = _last_jump_time
	d["first_jump_time"] = _first_jump_time
	return d

static func perf_mark() -> Dictionary:
	return {"scope": "CarJump", "tick_hz": PHYSICS_TICKS_PER_SECOND, "jump_speed": JUMP_SPEED, "impulse": JUMP_IMPULSE}

func perf_mark_instance() -> Dictionary:
	return {"scope": "CarJump", "tick_hz": PHYSICS_TICKS_PER_SECOND, "grounded": _is_grounded, "jump_count": _jump_count}
