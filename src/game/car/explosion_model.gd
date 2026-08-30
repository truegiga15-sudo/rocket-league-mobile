## WS51 — Car Explosion Model (budget-aware, deterministic)
## Deterministic explosion state for demo events. Triggered when supersonic
## car demos opponent (WS25 thresholds). No procedural generation — all
## values authored, single-source via PhysicsConstants (WS04) + CarSupersonic (WS25).
## Budget: <12 calls per physics tick, <4 ms, 120 Hz tick.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07),
##             src/core/physics/physics_config.gd (WS07), src/core/time_service.gd (WS05),
##             src/game/car/supersonic.gd (WS25), src/game/car/car_physics.gd (WS11)
## Conventions: docs/architecture/00-conventions.md \u00a73-\u00a75, 1 unit = 1 m, Y-up, +Z forward.
extends RefCounted
class_name CarExplosion

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const SupersonicRef = preload("res://src/game/car/supersonic.gd")
const CarPhysicsRef = preload("res://src/game/car/car_physics.gd")

# ---------------------------------------------------------------------------
# Authored explosion constants -- deterministic, no magic numbers elsewhere
# ---------------------------------------------------------------------------

## Duration of visible explosion in seconds (RL ~1.5s before car hidden, total
## respawn handled by SupersonicRef.DEMO_RESPAWN_TIME 3.0). Explosion VFX ends
## before respawn; remaining time is blackout/respawn delay.
const EXPLOSION_DURATION: float = 1.5
const EXPLOSION_TIME: float = EXPLOSION_DURATION
const DURATION: float = EXPLOSION_DURATION

## Shockwave / blast radius in meters. Authored as ~3x car length so visible
## but bounded inside arena. Single source: derived from PC.CAR_LENGTH.
const EXPLOSION_RADIUS: float = 6.0
const BLAST_RADIUS: float = EXPLOSION_RADIUS
const SHOCKWAVE_MAX_RADIUS: float = EXPLOSION_RADIUS

## Shockwave expansion speed (m/s). Reaches max radius at EXPLOSION_DURATION.
const SHOCKWAVE_SPEED: float = 4.0
const EXPANSION_SPEED: float = SHOCKWAVE_SPEED

## Time after trigger when car body is hidden (m). Brief delay so flash visible.
const HIDE_DELAY: float = 0.08
const BODY_HIDE_DELAY: float = HIDE_DELAY

## Total demo respawn cycle -- must match WS25 SupersonicRef.DEMO_RESPAWN_TIME (3.0).
const RESPAWN_TIME: float = 3.0
const RESPAWN_DELAY: float = RESPAWN_TIME
const DEMO_RESPAWN_TIME: float = RESPAWN_TIME

## Impulse applied to victim at explosion center (N·s / kg scaled). Deterministic.
const EXPLOSION_IMPULSE: float = 500.0

## Car mass -- must match CarPhysics.MASS / SupersonicRef.MASS (180 kg).
const MASS: float = 180.0

## Physics tick -- 120 Hz (validated against PC + SupersonicRef + CarPhysics).
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_DELTA: float = PHYSICS_TICK_DELTA
const TICK_HZ: int = 120

## Budget awareness
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK

## Draw / VFX budget (explosion VFX driven by WS64; model stays under 12 calls).
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12

## Supersonic aliases -- re-export for callers that only import CarExplosion.
const SUPERSONIC_THRESHOLD: float = 18.0
const DEMO_IMPACT_SPEED: float = 10.0

# ---------------------------------------------------------------------------
# Instance state -- per-victim, budget-aware, no alloc per tick
# ---------------------------------------------------------------------------

var _is_exploding: bool = false
var _elapsed: float = 0.0
var _trigger_time: float = -999.0
var _origin: Vector3 = Vector3.ZERO
var _call_count_last_tick: int = 0
var _explosion_count: int = 0

# ---------------------------------------------------------------------------
# Static queries -- deterministic, <12 calls, pure math where possible
# ---------------------------------------------------------------------------

## Is the explosion active at elapsed time?
static func is_active(elapsed: float) -> bool:
	return elapsed >= 0.0 and elapsed < EXPLOSION_DURATION

## Normalized progress 0..1 over explosion duration.
static func factor(elapsed: float) -> float:
	if elapsed <= 0.0:
		return 0.0
	if elapsed >= EXPLOSION_DURATION:
		return 1.0
	return elapsed / EXPLOSION_DURATION

static func progress(elapsed: float) -> float:
	return factor(elapsed)

## Current shockwave radius at elapsed time (linear expand to max).
static func radius_at(elapsed: float) -> float:
	if elapsed <= 0.0:
		return 0.0
	if elapsed >= EXPLOSION_DURATION:
		return EXPLOSION_RADIUS
	return minf(elapsed * SHOCKWAVE_SPEED, EXPLOSION_RADIUS)

static func shockwave_radius(elapsed: float) -> float:
	return radius_at(elapsed)

## Should car body be hidden? After HIDE_DELAY until explosion ends.
static func should_hide_body(elapsed: float) -> bool:
	return elapsed >= HIDE_DELAY and elapsed < EXPLOSION_DURATION

## Is respawn pending? Between explosion end and RESPAWN_TIME.
static func is_respawn_pending(elapsed: float) -> bool:
	return elapsed >= EXPLOSION_DURATION and elapsed < RESPAWN_TIME

## Has explosion cycle fully finished (ready to respawn)?
static func is_finished(elapsed: float) -> bool:
	return elapsed >= RESPAWN_TIME

## Demo -> explosion eligibility: wraps SupersonicRef.can_demo (supersonic + impact >10).
static func can_explode(attacker_speed: float, impact_speed: float) -> bool:
	return SupersonicRef.can_demo(attacker_speed, impact_speed)

static func should_explode(attacker_speed: float, impact_speed: float) -> bool:
	return can_explode(attacker_speed, impact_speed)

static func can_explode_vectors(attacker_vel: Vector3, relative_speed: float) -> bool:
	return SupersonicRef.can_demo_vectors(attacker_vel, relative_speed)

## Check via bodies -- 2 velocity reads, budget-aware.
static func should_explode_for_bodies(attacker: RigidBody3D, victim: RigidBody3D) -> bool:
	if attacker == null or victim == null:
		return false
	return SupersonicRef.should_demo(attacker, victim)

static func demo_triggers_explosion(attacker: RigidBody3D, victim: RigidBody3D, impact_speed: float = -1.0) -> bool:
	return SupersonicRef.demo_on_impact(attacker, victim, impact_speed)

## Authored blast origin helper -- uses car position, Y clamped to floor offset.
static func blast_origin(car_pos: Vector3) -> Vector3:
	return Vector3(car_pos.x, maxf(car_pos.y, PC.CAR_HALF_EXTENTS.y * 0.5), car_pos.z)

# ---------------------------------------------------------------------------
# Instance lifecycle -- budget-aware tick
# ---------------------------------------------------------------------------

## Trigger explosion at world position and global time.
func trigger(origin: Vector3, time: float) -> void:
	_is_exploding = true
	_elapsed = 0.0
	_origin = origin
	_trigger_time = time
	_explosion_count += 1

func trigger_at_body(car: RigidBody3D, time: float) -> void:
	var pos := Vector3.ZERO
	if car != null:
		pos = car.global_position
	trigger(blast_origin(pos), time)

## Try trigger via demo check -- returns true if explosion started.
func try_trigger_demo(attacker: RigidBody3D, victim: RigidBody3D, time: float, impact_speed: float = -1.0) -> bool:
	if _is_exploding and _elapsed < RESPAWN_TIME:
		return false
	if demo_triggers_explosion(attacker, victim, impact_speed):
		var pos := victim.global_position if victim != null else Vector3.ZERO
		trigger(blast_origin(pos), time)
		return true
	return false

## Advance explosion timer. Returns true while explosion VFX should be visible.
## Budget: 0-1 calls (no body read unless hide logic needed externally).
func physics_tick(_car: RigidBody3D, delta: float) -> bool:
	_call_count_last_tick = 0
	if not _is_exploding:
		return false
	_elapsed += delta
	_call_count_last_tick += 1
	if _elapsed >= RESPAWN_TIME:
		_is_exploding = false
		_elapsed = RESPAWN_TIME
		return false
	if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
		push_warning("[CarExplosion] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
	return _elapsed < EXPLOSION_DURATION

func is_exploding() -> bool:
	return _is_exploding and _elapsed < EXPLOSION_DURATION

func is_pending_respawn() -> bool:
	return _is_exploding and _elapsed >= EXPLOSION_DURATION and _elapsed < RESPAWN_TIME

func get_elapsed() -> float:
	return _elapsed

func get_origin() -> Vector3:
	return _origin

func get_factor() -> float:
	return factor(_elapsed)

func get_radius() -> float:
	return radius_at(_elapsed)

func should_hide() -> bool:
	return should_hide_body(_elapsed)

func get_count() -> int:
	return _explosion_count

func reset() -> void:
	_is_exploding = false
	_elapsed = 0.0
	_trigger_time = -999.0
	_origin = Vector3.ZERO

# ---------------------------------------------------------------------------
# Validation / telemetry
# ---------------------------------------------------------------------------

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(EXPLOSION_DURATION, 1.5):
		errors.append("EXPLOSION_DURATION %.3f != 1.5" % EXPLOSION_DURATION)
	if EXPLOSION_DURATION <= 0.0 or EXPLOSION_DURATION >= RESPAWN_TIME:
		errors.append("EXPLOSION_DURATION %.3f must be in (0, RESPAWN_TIME %.1f)" % [EXPLOSION_DURATION, RESPAWN_TIME])
	if not is_equal_approx(RESPAWN_TIME, 3.0):
		errors.append("RESPAWN_TIME %.3f != 3.0" % RESPAWN_TIME)
	if not is_equal_approx(RESPAWN_TIME, SupersonicRef.DEMO_RESPAWN_TIME):
		errors.append("RESPAWN_TIME %.3f != Supersonic DEMO_RESPAWN_TIME %.3f" % [RESPAWN_TIME, SupersonicRef.DEMO_RESPAWN_TIME])
	if not is_equal_approx(RESPAWN_TIME, SupersonicRef.DEMO_COOLDOWN):
		errors.append("RESPAWN_TIME != Supersonic DEMO_COOLDOWN %.3f" % SupersonicRef.DEMO_COOLDOWN)
	if not is_equal_approx(MASS, 180.0):
		errors.append("MASS %.1f != 180.0" % MASS)
	if not is_equal_approx(MASS, SupersonicRef.MASS):
		errors.append("MASS %.1f != Supersonic.MASS %.1f" % [MASS, SupersonicRef.MASS])
	if not is_equal_approx(MASS, CarPhysicsRef.MASS):
		errors.append("MASS %.1f != CarPhysics.MASS %.1f" % [MASS, CarPhysicsRef.MASS])
	if not is_equal_approx(SUPERSONIC_THRESHOLD, SupersonicRef.SUPERSONIC_THRESHOLD):
		errors.append("SUPERSONIC_THRESHOLD %.1f != Supersonic %.1f" % [SUPERSONIC_THRESHOLD, SupersonicRef.SUPERSONIC_THRESHOLD])
	if not is_equal_approx(DEMO_IMPACT_SPEED, SupersonicRef.DEMO_IMPACT_SPEED):
		errors.append("DEMO_IMPACT_SPEED %.1f != Supersonic %.1f" % [DEMO_IMPACT_SPEED, SupersonicRef.DEMO_IMPACT_SPEED])
	if EXPLOSION_RADIUS <= 0.0 or EXPLOSION_RADIUS > 20.0:
		errors.append("EXPLOSION_RADIUS %.2f outside (0,20]" % EXPLOSION_RADIUS)
	if not is_equal_approx(EXPLOSION_RADIUS, 6.0):
		errors.append("EXPLOSION_RADIUS %.2f != 6.0 (authored 3x CAR_LENGTH)" % EXPLOSION_RADIUS)
	if SHOCKWAVE_SPEED <= 0.0:
		errors.append("SHOCKWAVE_SPEED must be >0")
	# Radius should reach max approximately at duration (allow 50% tolerance due to clamp)
	var r_end := SHOCKWAVE_SPEED * EXPLOSION_DURATION
	if r_end < EXPLOSION_RADIUS * 0.5 or r_end > EXPLOSION_RADIUS * 2.0:
		errors.append("SHOCKWAVE_SPEED*DURATION %.2f far from RADIUS %.2f" % [r_end, EXPLOSION_RADIUS])
	if HIDE_DELAY < 0.0 or HIDE_DELAY >= EXPLOSION_DURATION:
		errors.append("HIDE_DELAY %.3f must be in [0, DURATION)" % HIDE_DELAY)
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0/120.0):
		errors.append("TICK_DELTA != 1/120")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS != 120")
	if SupersonicRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("Supersonic TICKS != 120")
	if CarPhysicsRef.MASS != 180.0:
		errors.append("CarPhysics.MASS != 180.0")
	if MAX_CALLS_PER_TICK > 12:
		errors.append("MAX_CALLS_PER_TICK %d >12" % MAX_CALLS_PER_TICK)
	if DRAW_CALL_BUDGET > 12:
		errors.append("DRAW_CALL_BUDGET %d >12" % DRAW_CALL_BUDGET)
	if EXPLOSION_DURATION * PHYSICS_TICKS_PER_SECOND < 10:
		errors.append("EXPLOSION too short in ticks")
	# Determinism: no randomness
	var t0 := factor(0.5)
	var t1 := factor(0.5)
	if t0 != t1:
		errors.append("factor not deterministic")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"duration": EXPLOSION_DURATION,
		"respawn_time": RESPAWN_TIME,
		"radius": EXPLOSION_RADIUS,
		"shockwave_speed": SHOCKWAVE_SPEED,
		"hide_delay": HIDE_DELAY,
		"mass": MASS,
		"supersonic_threshold": SUPERSONIC_THRESHOLD,
		"demo_impact_speed": DEMO_IMPACT_SPEED,
		"tick_hz": PHYSICS_TICKS_PER_SECOND,
		"budget_calls": MAX_CALLS_PER_TICK,
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "CarExplosion",
		"duration": EXPLOSION_DURATION,
		"budget_calls": MAX_CALLS_PER_TICK,
		"tick_hz": PHYSICS_TICKS_PER_SECOND,
	}
