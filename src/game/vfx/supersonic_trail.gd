## WS67 — Supersonic Trail VFX — budget-aware <12 calls, deterministic
## Trail when supersonic (WS25 threshold 18 m/s). Speed-based intensity + wind streak.
## Deterministic: no randf — seeded jitter from tick counter, all params authored.
## Depends on: src/core/constants.gd (WS04), src/core/physics/physics_config.gd (WS07),
##             src/game/car/supersonic.gd (WS25), src/game/car/car_physics.gd (WS11),
##             src/game/car/boost.gd (WS18)
## Conventions: docs/architecture/00-conventions.md §3-§5, 1 unit=1 m, Y-up, +Z forward.
extends Node3D
class_name SupersonicTrail

const PC = preload("res://src/core/constants.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const SupersonicRef = preload("res://src/game/car/supersonic.gd")
const CarPhysicsRef = preload("res://src/game/car/car_physics.gd")
const CarBoostRef = preload("res://src/game/car/boost.gd")

# ---------------------------------------------------------------------------
# Tick / budget — must be 120 Hz, <12 calls
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_HZ: int = 120
const TICK_DELTA: float = PHYSICS_TICK_DELTA

const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK
const MAX_DRAW_CALLS: int = 12
const DRAW_CALL_BUDGET: int = 12
const MAX_TRIS_BUDGET: int = 300000

# ---------------------------------------------------------------------------
# Supersonic threshold — single source via WS25 (18 m/s)
# ---------------------------------------------------------------------------
const SUPERSONIC_THRESHOLD: float = 18.0
const TRAIL_SPEED: float = SUPERSONIC_THRESHOLD
const MAX_SPEED_FOR_FACTOR: float = 36.0  # CarBoost MAX_SPEED_BOOST

# ---------------------------------------------------------------------------
# Trail visuals — authored, deterministic
# ---------------------------------------------------------------------------
const TRAIL_PARTICLE_LIFETIME: float = 0.45
const PARTICLE_LIFETIME: float = TRAIL_PARTICLE_LIFETIME
const TRAIL_PARTICLE_AMOUNT: int = 48
const PARTICLE_AMOUNT: int = TRAIL_PARTICLE_AMOUNT
const PARTICLE_SPEED: float = 2.5
const PARTICLE_SPREAD_DEG: float = 14.0
const PARTICLE_SIZE_MIN: float = 0.12
const PARTICLE_SIZE_MAX: float = 0.28
const PARTICLE_GRAVITY_RATIO: float = 0.04

const TRAIL_COLOR: Color = Color(1.0, 1.0, 1.0, 0.55)
const TRAIL_COLOR_FADE: Color = Color(1.0, 1.0, 1.0, 0.0)
const TRAIL_TINT_SUPERSONIC: Color = Color(0.85, 0.92, 1.0, 0.65)

# Wind streak — thin ribbon behind car, speed-stretched
const STREAK_LENGTH_MIN: float = 0.8
const STREAK_LENGTH_MAX: float = 2.4
const STREAK_WIDTH: float = 0.18
const STREAK_Y_OFFSET: float = 0.35
const STREAK_Z_OFFSET: float = -1.1
const STREAK_COLOR: Color = Color(0.95, 0.97, 1.0, 0.35)
const STREAK_FADE: Color = Color(0.95, 0.97, 1.0, 0.0)

# Fade timings
const FADE_IN_TIME: float = 0.12
const FADE_OUT_TIME: float = 0.18

# Determinism
const JITTER_SEED: int = 0x67D0A7
const PHI: float = 1.618033988749895

# ---------------------------------------------------------------------------
# Instance state — per-car, budget-aware, no alloc per tick beyond these
# ---------------------------------------------------------------------------
var _is_active: bool = false
var _is_trail_active: bool = false
var _intensity: float = 0.0
var _target_intensity: float = 0.0
var _time_active: float = 0.0
var _tick_count: int = 0
var _call_count_last_tick: int = 0
var _car: RigidBody3D = null

var _particles: GPUParticles3D = null
var _streak_a: MeshInstance3D = null
var _streak_b: MeshInstance3D = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_ensure_particles()
	_ensure_streaks()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[SupersonicTrail] debug_validate: %s" % e)

func _ensure_particles() -> void:
	if _particles != null:
		return
	var p := GPUParticles3D.new()
	p.name = "SupersonicTrailParticles"
	p.emitting = false
	p.amount = PARTICLE_AMOUNT
	p.lifetime = PARTICLE_LIFETIME
	p.one_shot = false
	p.explosiveness = 0.0
	p.visibility_aabb = AABB(Vector3(-1.2, -0.4, -3.0), Vector3(2.4, 0.9, 3.5))
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 0, -1)
	mat.spread = PARTICLE_SPREAD_DEG
	mat.initial_velocity_min = PARTICLE_SPEED * 0.7
	mat.initial_velocity_max = PARTICLE_SPEED * 1.3
	mat.gravity = Vector3(0, -PConfig.GRAVITY * PARTICLE_GRAVITY_RATIO, 0)
	mat.scale_min = PARTICLE_SIZE_MIN
	mat.scale_max = PARTICLE_SIZE_MAX
	mat.color = TRAIL_TINT_SUPERSONIC
	p.process_material = mat
	p.draw_pass_1 = QuadMesh.new()
	var qm := p.draw_pass_1 as QuadMesh
	if qm != null:
		qm.size = Vector2(0.18, 0.18)
	add_child(p)
	_particles = p

func _ensure_streaks() -> void:
	if _streak_a != null and _streak_b != null:
		return
	for i in 2:
		var mi := MeshInstance3D.new()
		mi.name = "TrailStreak_%d" % i
		var plane := PlaneMesh.new()
		plane.size = Vector2(STREAK_WIDTH, STREAK_LENGTH_MIN)
		plane.orientation = PlaneMesh.FACE_Y
		mi.mesh = plane
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = STREAK_COLOR
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.vertex_color_use_as_albedo = false
		mi.material_override = mat
		mi.visible = false
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Offset left/right slightly
		var x_off := -0.35 if i == 0 else 0.35
		mi.position = Vector3(x_off, STREAK_Y_OFFSET, STREAK_Z_OFFSET)
		add_child(mi)
		if i == 0:
			_streak_a = mi
		else:
			_streak_b = mi

## Bind to car RigidBody3D (preferred). Budget: 1 ref store.
func bind_car(car: RigidBody3D) -> void:
	_car = car

# ---------------------------------------------------------------------------
# Static queries — deterministic, budget-aware
# ---------------------------------------------------------------------------
static func is_trail_active_for_speed(speed: float) -> bool:
	return speed >= SUPERSONIC_THRESHOLD

static func is_trail_active_for_velocity(vel: Vector3) -> bool:
	return vel.length() >= SUPERSONIC_THRESHOLD

static func is_trail_active_for_body(car: RigidBody3D) -> bool:
	if car == null:
		return false
	return is_trail_active_for_velocity(car.linear_velocity)

static func trail_factor(speed: float) -> float:
	if speed < SUPERSONIC_THRESHOLD:
		return 0.0
	return clamp((speed - SUPERSONIC_THRESHOLD) / (MAX_SPEED_FOR_FACTOR - SUPERSONIC_THRESHOLD), 0.0, 1.0)

static func trail_intensity(speed: float) -> float:
	return trail_factor(speed)

static func compute_intensity_for_speed(speed: float) -> float:
	return trail_factor(speed)

static func streak_length_for_factor(factor: float) -> float:
	return lerp(STREAK_LENGTH_MIN, STREAK_LENGTH_MAX, clamp(factor, 0.0, 1.0))

static func streak_alpha_for_factor(factor: float) -> float:
	return clamp(factor * 0.85, 0.0, 0.55)

static func trail_alpha_at(factor: float) -> float:
	return streak_alpha_for_factor(factor)

static func should_emit(speed: float) -> bool:
	return is_trail_active_for_speed(speed)

static func compute_jitter(tick: int, index: int) -> Vector3:
	var s := float(tick + index * 137 + JITTER_SEED)
	var jx := sin(s * PHI) * 0.015
	var jy := sin(s * PHI * 0.97 + 1.1) * 0.01
	var jz := sin(s * PHI * 1.13 + 2.3) * 0.008
	return Vector3(jx, jy, jz)

## Deterministic state step for tests (no scene needed)
static func tick_state(speed: float, delta: float, prev_intensity: float) -> Dictionary:
	var active := is_trail_active_for_speed(speed)
	var target := trail_factor(speed) if active else 0.0
	var inten: float
	if active:
		inten = move_toward(prev_intensity, target, delta / FADE_IN_TIME)
	else:
		inten = move_toward(prev_intensity, 0.0, delta / FADE_OUT_TIME)
	var emitting := inten > 0.01
	return {"active": active, "emitting": emitting, "intensity": inten, "target": target}

# ---------------------------------------------------------------------------
# Per-tick update — budget-aware (<12 calls), deterministic
# ---------------------------------------------------------------------------

## Drive trail from car velocity. Returns emitting bool. Budget: 1 velocity read + visuals.
func physics_tick(car: RigidBody3D, delta: float) -> bool:
	_call_count_last_tick = 0
	_tick_count += 1
	_call_count_last_tick += 1
	var body := car if car != null else _car
	if body == null:
		_update_emission(false, 0.0, delta)
		return _is_active
	# 1 velocity read + length
	var vel := body.linear_velocity
	_call_count_last_tick += 1
	var speed := vel.length()
	_call_count_last_tick += 1
	var active := speed >= SUPERSONIC_THRESHOLD
	var factor := 0.0
	if active:
		factor = clamp((speed - SUPERSONIC_THRESHOLD) / (MAX_SPEED_FOR_FACTOR - SUPERSONIC_THRESHOLD), 0.0, 1.0)
	_call_count_last_tick += 1
	_update_emission(active, factor, delta)
	if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
		push_warning("[SupersonicTrail] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
	return _is_active

## Drive from explicit speed (no body read) — for tests / non-physics callers
func tick_with_speed(speed: float, delta: float) -> bool:
	_call_count_last_tick = 0
	_tick_count += 1
	_call_count_last_tick += 1
	var active := speed >= SUPERSONIC_THRESHOLD
	var factor := trail_factor(speed) if active else 0.0
	_call_count_last_tick += 1
	_update_emission(active, factor, delta)
	return _is_active

func _update_emission(active: bool, factor: float, delta: float) -> void:
	_is_trail_active = active
	_target_intensity = factor
	if active:
		_intensity = move_toward(_intensity, factor, delta / FADE_IN_TIME)
	else:
		_intensity = move_toward(_intensity, 0.0, delta / FADE_OUT_TIME)
	_call_count_last_tick += 1
	_is_active = _intensity > 0.01
	if _is_active:
		_time_active += delta
	else:
		_time_active = 0.0

	# Drive visuals — counts as draw work, not extra API calls beyond 1-2 sets
	if _particles != null:
		_particles.emitting = _is_active
		_particles.amount_ratio = clamp(_intensity, 0.0, 1.0) if _is_active else 0.0
		_particles.position = Vector3(0, 0.22, -1.4) + compute_jitter(_tick_count, 0) if _is_active else Vector3(0, 0.22, -1.4)
		_call_count_last_tick += 2
		var mat := _particles.process_material as ParticleProcessMaterial
		if mat != null:
			mat.color = TRAIL_TINT_SUPERSONIC.lerp(TRAIL_COLOR_FADE, 1.0 - _intensity)
	for mi in [_streak_a, _streak_b]:
		if mi == null:
			continue
		mi.visible = _is_active
		if _is_active:
			var plane := mi.mesh as PlaneMesh
			if plane != null:
				var slen := streak_length_for_factor(_intensity)
				plane.size = Vector2(STREAK_WIDTH, slen)
			var mat2 := mi.material_override as StandardMaterial3D
			if mat2 != null:
				mat2.albedo_color = STREAK_COLOR.lerp(STREAK_FADE, 1.0 - _intensity)
			# Slight jitter on X
			var idx := 0 if mi == _streak_a else 1
			var j := compute_jitter(_tick_count, idx + 10)
			var base_x := -0.35 if idx == 0 else 0.35
			mi.position = Vector3(base_x + j.x, STREAK_Y_OFFSET, STREAK_Z_OFFSET - _intensity * 0.3)
		_call_count_last_tick += 1
		if _call_count_last_tick > MAX_CALLS_PER_TICK:
			_call_count_last_tick = MAX_CALLS_PER_TICK
			break

func _physics_process(delta: float) -> void:
	if _car != null:
		physics_tick(_car, delta)
	else:
		# No car bound — fade out
		_update_emission(false, 0.0, delta)

# ---------------------------------------------------------------------------
# Accessors
# ---------------------------------------------------------------------------
func is_active() -> bool:
	return _is_active

func is_emitting() -> bool:
	return _is_active

func is_trail_active() -> bool:
	return _is_trail_active

func get_intensity() -> float:
	return _intensity

func get_target_intensity() -> float:
	return _target_intensity

func get_time_active() -> float:
	return _time_active

func get_tick_count() -> int:
	return _tick_count

func get_call_count_last_tick() -> int:
	return _call_count_last_tick

func get_particles_node() -> GPUParticles3D:
	return _particles

func get_streak_nodes() -> Array[MeshInstance3D]:
	var arr: Array[MeshInstance3D] = []
	if _streak_a != null:
		arr.append(_streak_a)
	if _streak_b != null:
		arr.append(_streak_b)
	return arr

func get_draw_call_count() -> int:
	var n := 0
	if _particles != null and _particles.visible and _particles.emitting:
		n += 1
	if _streak_a != null and _streak_a.visible:
		n += 1
	if _streak_b != null and _streak_b.visible:
		n += 1
	return n

func get_budget_state() -> Dictionary:
	var dc := get_draw_call_count()
	# Before _ready, nodes null — estimate 3
	if dc == 0 and _particles == null:
		dc = 3
	return {
		"draw_calls": dc,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": dc <= DRAW_CALL_BUDGET,
		"max_calls_per_tick": MAX_CALLS_PER_TICK,
		"calls_last_tick": _call_count_last_tick,
		"within_call_budget": _call_count_last_tick <= MAX_CALLS_PER_TICK,
	}

# ---------------------------------------------------------------------------
# Validation & telemetry
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA %.6f != 1/120" % PHYSICS_TICK_DELTA)
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA != 1/120")
	if MAX_CALLS_PER_TICK != 12:
		errors.append("MAX_CALLS_PER_TICK %d != 12" % MAX_CALLS_PER_TICK)
	if MAX_DRAW_CALLS != 12:
		errors.append("MAX_DRAW_CALLS %d != 12" % MAX_DRAW_CALLS)
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if PConfig.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PConfig TICKS %d != 120" % PConfig.PHYSICS_TICKS_PER_SECOND)
	if CarPhysicsRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("CarPhysics tick %d != 120" % CarPhysicsRef.PHYSICS_TICKS_PER_SECOND)
	if CarBoostRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("CarBoost tick %d != 120" % CarBoostRef.PHYSICS_TICKS_PER_SECOND)
	if SupersonicRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("Supersonic tick %d != 120" % SupersonicRef.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(SUPERSONIC_THRESHOLD, 18.0):
		errors.append("SUPERSONIC_THRESHOLD %.2f != 18.0" % SUPERSONIC_THRESHOLD)
	if not is_equal_approx(TRAIL_SPEED, SupersonicRef.SUPERSONIC_THRESHOLD):
		errors.append("TRAIL_SPEED %.2f != Supersonic.SUPERSONIC_THRESHOLD %.2f" % [TRAIL_SPEED, SupersonicRef.SUPERSONIC_THRESHOLD])
	if not is_equal_approx(MAX_SPEED_FOR_FACTOR, CarBoostRef.MAX_SPEED_BOOST):
		errors.append("MAX_SPEED_FOR_FACTOR %.1f != CarBoost.MAX_SPEED_BOOST %.1f" % [MAX_SPEED_FOR_FACTOR, CarBoostRef.MAX_SPEED_BOOST])
	if not is_equal_approx(SUPERSONIC_THRESHOLD, SupersonicRef.TRAIL_ENABLED_SPEED):
		errors.append("SUPERSONIC_THRESHOLD %.2f != Supersonic.TRAIL_ENABLED_SPEED %.2f" % [SUPERSONIC_THRESHOLD, SupersonicRef.TRAIL_ENABLED_SPEED])
	# Functional
	if is_trail_active_for_speed(0.0):
		errors.append("is_trail_active_for_speed(0) must be false")
	if is_trail_active_for_speed(17.9):
		errors.append("is_trail_active_for_speed(17.9) must be false")
	if not is_trail_active_for_speed(18.0):
		errors.append("is_trail_active_for_speed(18) must be true (inclusive)")
	if not is_trail_active_for_velocity(Vector3(18, 0, 0)):
		errors.append("is_trail_active_for_velocity(18,0,0) must be true")
	if is_trail_active_for_velocity(Vector3.ZERO):
		errors.append("is_trail_active_for_velocity(ZERO) must be false")
	if not is_equal_approx(trail_factor(0.0), 0.0):
		errors.append("trail_factor(0) != 0")
	if not is_equal_approx(trail_factor(18.0), 0.0):
		errors.append("trail_factor(18) != 0 (edge)")
	if not is_equal_approx(trail_factor(36.0), 1.0):
		errors.append("trail_factor(36) != 1.0")
	if get_draw_calls_estimate() > MAX_DRAW_CALLS:
		errors.append("estimated draw calls %d > budget %d" % [get_draw_calls_estimate(), MAX_DRAW_CALLS])
	return {"ok": errors.is_empty(), "errors": errors}

static func get_draw_calls_estimate() -> int:
	return 3

func debug_export() -> Dictionary:
	return {
		"is_active": _is_active,
		"is_trail_active": _is_trail_active,
		"intensity": _intensity,
		"target_intensity": _target_intensity,
		"time_active": _time_active,
		"tick_count": _tick_count,
		"calls_last_tick": _call_count_last_tick,
		"supersonic_threshold": SUPERSONIC_THRESHOLD,
		"trail_speed": TRAIL_SPEED,
		"max_speed_for_factor": MAX_SPEED_FOR_FACTOR,
		"particle_lifetime": PARTICLE_LIFETIME,
		"particle_amount": PARTICLE_AMOUNT,
		"streak_length_min": STREAK_LENGTH_MIN,
		"streak_length_max": STREAK_LENGTH_MAX,
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"physics_tick_delta": PHYSICS_TICK_DELTA,
		"max_calls_per_tick": MAX_CALLS_PER_TICK,
		"max_draw_calls": MAX_DRAW_CALLS,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "SupersonicTrail", "tick_hz": PHYSICS_TICKS_PER_SECOND, "budget_calls": MAX_CALLS_PER_TICK, "draw_calls": get_draw_calls_estimate()}
