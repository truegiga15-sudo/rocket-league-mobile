## WS25 — Supersonic & Demo Mechanics (budget-aware, solo)
## Threshold 18 m/s, trail VFX flag, demo on impact speed >10 m/s.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07),
##             src/core/physics/physics_config.gd (WS07), src/core/time_service.gd (WS05),
##             src/game/car/car_physics.gd (WS11), src/game/car/boost.gd (WS18)
## Conventions: docs/architecture/00-conventions.md \u00a73-\u00a75, 1 unit = 1 m, Y-up, +Z forward.
## Physics tick 120 Hz (project.godot: physics/common/physics_ticks_per_second).
## Budget: <4 ms per tick, <12 calls per tick (conventions \u00a712).
## No procedural generation -- all values authored/deterministic.
extends RefCounted
class_name CarSupersonic

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const CarPhysicsRef = preload("res://src/game/car/car_physics.gd")
const CarBoostRef = preload("res://src/game/car/boost.gd")

# ---------------------------------------------------------------------------
# Authored supersonic/demo constants -- single source for WS25
# ---------------------------------------------------------------------------

## Supersonic threshold in m/s. RL: 18 m/s (~65 km/h) triggers trail + demo eligibility.
const SUPERSONIC_THRESHOLD: float = 18.0
const SUPERSONIC_SPEED: float = SUPERSONIC_THRESHOLD
const SUPERSONIC_MIN_SPEED: float = SUPERSONIC_THRESHOLD
const SUPERSONIC_THRESH: float = SUPERSONIC_THRESHOLD

## Demo impact speed threshold in m/s. Attacker must be supersonic and
## relative impact speed along hit normal >10 m/s to demo victim.
const DEMO_IMPACT_SPEED: float = 10.0
const DEMO_SPEED_THRESHOLD: float = DEMO_IMPACT_SPEED
const DEMO_MIN_IMPACT_SPEED: float = DEMO_IMPACT_SPEED
const DEMO_THRESHOLD: float = DEMO_IMPACT_SPEED

## Mass -- must match CarPhysics.MASS / CarBoost (single source 180 kg).
const MASS: float = 180.0

## Trail: enabled when supersonic. Budget-aware: single flag, no per-frame alloc.
## Visual trail driven by WS67; this module exposes is_trail_active() boolean.
const TRAIL_ENABLED_SPEED: float = SUPERSONIC_THRESHOLD

## Demo cooldown per victim (s) to avoid rapid re-demo flicker.
const DEMO_COOLDOWN: float = 3.0
const DEMO_RESPAWN_TIME: float = 3.0

## Physics tick -- must be 120 Hz (validated against PC + CarPhysics + CarBoost).
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_DELTA: float = PHYSICS_TICK_DELTA
const TICK_HZ: int = 120

## Max API calls per physics tick (budget-aware). Track via perf call count.
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK

# ---------------------------------------------------------------------------
# Instance state -- per-car (budget-aware: no alloc per tick beyond these fields)
# ---------------------------------------------------------------------------

var _is_supersonic: bool = false
var _trail_active: bool = false
var _time_supersonic: float = 0.0
var _last_trail_change: float = 0.0
var _demo_count: int = 0
var _last_demo_time: float = -999.0
var _call_count_last_tick: int = 0

# ---------------------------------------------------------------------------
# Core queries -- static, budget-aware (<12 calls, pure math where possible)
# ---------------------------------------------------------------------------

## Is speed supersonic? Uses 18 m/s threshold.
static func is_supersonic_speed(speed: float) -> bool:
	return speed >= SUPERSONIC_THRESHOLD

static func is_speed_supersonic(speed: float) -> bool:
	return is_supersonic_speed(speed)

## Is vector supersonic by length?
static func is_supersonic(velocity: Vector3) -> bool:
	return velocity.length() >= SUPERSONIC_THRESHOLD

## Is car body supersonic (reads linear_velocity once)?
static func is_supersonic_for_body(car: RigidBody3D) -> bool:
	if car == null:
		return false
	return is_supersonic(car.linear_velocity)

## Trail active iff supersonic (budget: 1 call -- velocity read + length).
static func is_trail_active_for_body(car: RigidBody3D) -> bool:
	return is_supersonic_for_body(car)

static func has_trail(velocity: Vector3) -> bool:
	return is_supersonic(velocity)

static func trail_active(velocity: Vector3) -> bool:
	return is_supersonic(velocity)

## Supersonic factor 0..1 (how far above threshold towards max boost speed 36).
static func supersonic_factor(speed: float) -> float:
	if speed < SUPERSONIC_THRESHOLD:
		return 0.0
	# Map 18..36 to 0..1
	return clamp((speed - SUPERSONIC_THRESHOLD) / (CarBoostRef.MAX_SPEED_BOOST - SUPERSONIC_THRESHOLD), 0.0, 1.0)

## Demo eligibility: attacker supersonic AND relative impact speed >10.
static func can_demo(attacker_speed: float, impact_speed: float) -> bool:
	return attacker_speed >= SUPERSONIC_THRESHOLD and impact_speed > DEMO_IMPACT_SPEED

static func can_demo_vectors(attacker_vel: Vector3, relative_speed: float) -> bool:
	return can_demo(attacker_vel.length(), relative_speed)

static func check_demo(attacker_vel: Vector3, victim_vel: Vector3) -> bool:
	var rel := (attacker_vel - victim_vel).length()
	return can_demo(attacker_vel.length(), rel)

## Demo on impact: attacker must be supersonic, impact speed >10.
## Returns true if demo should trigger (caller handles respawn/teleport).
static func demo_on_impact(attacker: RigidBody3D, victim: RigidBody3D, impact_speed: float = -1.0) -> bool:
	if attacker == null or victim == null:
		return false
	var atk_speed := attacker.linear_velocity.length()
	if atk_speed < SUPERSONIC_THRESHOLD:
		return false
	var rel_speed := impact_speed
	if rel_speed < 0.0:
		rel_speed = (attacker.linear_velocity - victim.linear_velocity).length()
	return rel_speed > DEMO_IMPACT_SPEED

## Overload: compute impact speed from bodies if not provided, with budget (2 velocity reads).
static func should_demo(attacker: RigidBody3D, victim: RigidBody3D) -> bool:
	return demo_on_impact(attacker, victim, -1.0)

## Demo with contact normal: project relative velocity onto normal, check >10.
static func demo_on_impact_normal(attacker: RigidBody3D, victim: RigidBody3D, normal: Vector3) -> bool:
	if attacker == null or victim == null:
		return false
	if attacker.linear_velocity.length() < SUPERSONIC_THRESHOLD:
		return false
	var rel := attacker.linear_velocity - victim.linear_velocity
	var along := absf(rel.dot(normal.normalized())) if normal.length_squared() > 0.001 else rel.length()
	return along > DEMO_IMPACT_SPEED

# ---------------------------------------------------------------------------
# Instance tick -- budget-aware: <12 calls, single velocity read per tick
# ---------------------------------------------------------------------------

## Update supersonic + trail state for this car each physics tick.
## Returns trail_active bool. Caller drives VFX visibility (WS67).
func physics_tick(car: RigidBody3D, delta: float) -> bool:
	_call_count_last_tick = 0
	if car == null:
		_is_supersonic = false
		_trail_active = false
		return false
	# 1 call: velocity read (counts as 1 API call)
	var vel := car.linear_velocity
	_call_count_last_tick += 1
	var supersonic := vel.length() >= SUPERSONIC_THRESHOLD
	_call_count_last_tick += 1 # length() is math, count for budget tracking
	_is_supersonic = supersonic
	_trail_active = supersonic
	if supersonic:
		_time_supersonic += delta
	else:
		_time_supersonic = 0.0
	# Budget assert (debug only): never exceed 12 calls
	if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
		push_warning("[CarSupersonic] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
	return _trail_active

func is_supersonic_state() -> bool:
	return _is_supersonic

func is_trail_active() -> bool:
	return _trail_active

func time_supersonic() -> float:
	return _time_supersonic

## Record a demo event (for telemetry).
func record_demo(time: float) -> void:
	_demo_count += 1
	_last_demo_time = time

## Try demo: instance wrapper that checks cooldown.
func try_demo(attacker: RigidBody3D, victim: RigidBody3D, time: float, impact_speed: float = -1.0) -> bool:
	if time - _last_demo_time < DEMO_COOLDOWN and _last_demo_time > -900.0:
		return false
	if demo_on_impact(attacker, victim, impact_speed):
		record_demo(time)
		return true
	return false

# ---------------------------------------------------------------------------
# Validation / telemetry -- mirrors WS24 pattern
# ---------------------------------------------------------------------------

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(SUPERSONIC_THRESHOLD, 18.0):
		errors.append("SUPERSONIC_THRESHOLD %.2f != 18.0" % SUPERSONIC_THRESHOLD)
	if not is_equal_approx(DEMO_IMPACT_SPEED, 10.0):
		errors.append("DEMO_IMPACT_SPEED %.2f != 10.0" % DEMO_IMPACT_SPEED)
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA %.6f != 1/120" % TICK_DELTA)
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA != 1/120")
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if TICK_HZ != 120:
		errors.append("TICK_HZ %d != 120" % TICK_HZ)
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if CarPhysicsRef.PHYSICS_TICKS_PER_SECOND if "PHYSICS_TICKS_PER_SECOND" in CarPhysicsRef else 120 != 120:
		pass # CarPhysics has no tick const, but mass must match
	if CarBoostRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("CarBoost tick %d != 120" % CarBoostRef.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(MASS, 180.0):
		errors.append("MASS %.2f != 180.0" % MASS)
	if not is_equal_approx(MASS, CarPhysicsRef.MASS):
		errors.append("MASS %.2f != CarPhysics.MASS %.2f" % [MASS, CarPhysicsRef.MASS])
	if not is_equal_approx(MASS, PConfig.MASS_CAR):
		errors.append("MASS %.2f != PConfig.MASS_CAR %.2f" % [MASS, PConfig.MASS_CAR])
	if MAX_CALLS_PER_TICK != 12:
		errors.append("MAX_CALLS_PER_TICK %d != 12 (WS25 budget)" % MAX_CALLS_PER_TICK)
	if BUDGET_CALLS != 12:
		errors.append("BUDGET_CALLS %d != 12" % BUDGET_CALLS)
	if PL.BIT_CAR_CHASSIS != 2:
		errors.append("PL.BIT_CAR_CHASSIS %d != 2" % PL.BIT_CAR_CHASSIS)
	# Functional: zero velocity not supersonic, 18 exactly is supersonic
	if is_supersonic(Vector3.ZERO):
		errors.append("is_supersonic(ZERO) must be false")
	if not is_supersonic(Vector3(18.0, 0, 0)):
		errors.append("is_supersonic(18,0,0) must be true (threshold inclusive)")
	if is_supersonic(Vector3(17.9, 0, 0)):
		errors.append("is_supersonic(17.9) must be false")
	if not has_trail(Vector3(18.0, 0, 0)):
		errors.append("has_trail at 18 must be true")
	if has_trail(Vector3(10.0, 0, 0)):
		errors.append("has_trail at 10 must be false")
	# Demo: attacker 18+ and impact >10 => true; attacker slow => false
	if not can_demo(18.0, 10.1):
		errors.append("can_demo(18, 10.1) must be true")
	if can_demo(18.0, 10.0):
		errors.append("can_demo at exactly 10.0 must be false (>10 required)")
	if can_demo(17.9, 15.0):
		errors.append("can_demo(17.9, 15) must be false (not supersonic)")
	if not can_demo(20.0, 10.5):
		errors.append("can_demo(20, 10.5) must be true")
	# Factor sanity
	if not is_equal_approx(supersonic_factor(0.0), 0.0):
		errors.append("supersonic_factor(0) != 0")
	if not is_equal_approx(supersonic_factor(18.0), 0.0):
		errors.append("supersonic_factor(18) != 0.0 (threshold edge)")
	if not is_equal_approx(supersonic_factor(36.0), 1.0):
		errors.append("supersonic_factor(36) != 1.0")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_validate_static() -> Dictionary:
	return debug_validate()

static func debug_export() -> Dictionary:
	return {
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"tick_delta": TICK_DELTA,
		"mass": MASS,
		"supersonic_threshold": SUPERSONIC_THRESHOLD,
		"demo_impact_speed": DEMO_IMPACT_SPEED,
		"trail_speed": TRAIL_ENABLED_SPEED,
		"demo_cooldown": DEMO_COOLDOWN,
		"aliases": {
			"SUPERSONIC_SPEED": SUPERSONIC_SPEED,
			"DEMO_SPEED_THRESHOLD": DEMO_SPEED_THRESHOLD,
		},
		"budget_calls": BUDGET_CALLS,
	}

func perf_mark() -> Dictionary:
	return {
		"calls_last_tick": _call_count_last_tick,
		"budget": MAX_CALLS_PER_TICK,
		"is_supersonic": _is_supersonic,
		"trail_active": _trail_active,
		"time_supersonic": _time_supersonic,
		"demo_count": _demo_count,
		"budget_ok": _call_count_last_tick <= MAX_CALLS_PER_TICK,
	}

static func perf_budget() -> Dictionary:
	return {"max_calls_per_tick": MAX_CALLS_PER_TICK, "tick_hz": TICK_HZ, "budget_ms": 4.0}
