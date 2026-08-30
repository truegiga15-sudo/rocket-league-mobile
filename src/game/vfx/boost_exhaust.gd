## WS61 — Boost Exhaust Particles (budget-aware <12 calls, deterministic)
## GPUParticles3D exhaust driven by boost state (WS18) and car exhaust ports (WS46 Octane).
## Budget: <12 API calls per tick (single particle control, no alloc), <12 draw calls.
## Deterministic: no random — seeded offset from tick counter, all params authored.
## Depends on: src/core/constants.gd (WS04), src/core/physics/physics_config.gd (WS07),
##             src/game/car/boost.gd (WS18), src/game/car/octane.gd (WS46)
## Conventions: docs/architecture/00-conventions.md §3-§5, 1 unit=1 m, Y-up, +Z forward.
extends Node3D
class_name BoostExhaust

const PC = preload("res://src/core/constants.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const CarBoostRef = preload("res://src/game/car/boost.gd")
const OctaneRef = preload("res://src/game/car/octane.gd")

# ---------------------------------------------------------------------------
# Authored exhaust constants — single source for WS61
# ---------------------------------------------------------------------------

## Physics tick — must be 120 Hz (validated against PC, CarBoost, Octane).
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_HZ: int = 120
const TICK_DELTA: float = PHYSICS_TICK_DELTA

## Budget: max API calls per physics tick (conventions §12).
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK
const MAX_DRAW_CALLS: int = 12
const DRAW_CALL_BUDGET: int = 12

## Exhaust ports — local offsets from car origin (rear, twin exhaust).
## Car size 4.2 x 2.1 x 1.5 (WS04/WS46). Rear face at z ~ -CAR_LENGTH/2.
## Two ports spaced laterally, slightly below center, facing -Z (rearward emit).
const CAR_LENGTH: float = 4.2
const CAR_WIDTH: float = 2.1
const CAR_HEIGHT: float = 1.5
const EXHAUST_Z: float = -2.05
const EXHAUST_Y: float = 0.15
const EXHAUST_X_SPREAD: float = 0.42
const EXHAUST_OFFSET_LEFT := Vector3(-0.42, 0.15, -2.05)
const EXHAUST_OFFSET_RIGHT := Vector3(0.42, 0.15, -2.05)
const EXHAUST_OFFSETS: Array[Vector3] = [EXHAUST_OFFSET_LEFT, EXHAUST_OFFSET_RIGHT]
const EXHAUST_COUNT: int = 2
const PORT_COUNT: int = 2

## Particle params — authored, deterministic, no procedural noise.
const PARTICLE_LIFETIME: float = 0.35
const PARTICLE_EMISSION_RATE: float = 64.0
const EMISSION_RATE: float = PARTICLE_EMISSION_RATE
const PARTICLE_SPEED: float = 8.0
const EXHAUST_SPEED: float = PARTICLE_SPEED
const PARTICLE_SPREAD_DEG: float = 12.0
const PARTICLE_SIZE_MIN: float = 0.08
const PARTICLE_SIZE_MAX: float = 0.22
const PARTICLE_SCALE: float = 0.14
const PARTICLE_ALPHA_FADE: float = 0.9
const PARTICLE_GRAVITY_RATIO: float = 0.08

## Color — boost flame (RL-like: bright core + warm tail), authored.
const FLAME_CORE_COLOR: Color = Color(0.95, 0.85, 0.35, 1.0)
const FLAME_TAIL_COLOR: Color = Color(0.95, 0.45, 0.08, 0.85)
const EXHAUST_CORE_COLOR: Color = FLAME_CORE_COLOR
const EXHAUST_TAIL_COLOR: Color = FLAME_TAIL_COLOR

## Intensity curves — boost amount 0..100 maps to 0..1 emission scale, deterministic.
const MIN_BOOST_FOR_EXHAUST: float = 0.5
const INTENSITY_AT_FULL: float = 1.0
const INTENSITY_AT_HALF: float = 0.62
const FADE_OUT_TIME: float = 0.08

## Determinism seed — fixed, used for jitter without randf.
const JITTER_SEED: int = 0x61E501
const PHI: float = 1.618033988749895

# ---------------------------------------------------------------------------
# Instance state — per-car (budget-aware, no alloc per tick beyond these)
# ---------------------------------------------------------------------------

var _is_emitting: bool = false
var _intensity: float = 0.0
var _tick_count: int = 0
var _time_emitting: float = 0.0
var _call_count_last_tick: int = 0
var _particles: GPUParticles3D = null
var _left_port: Node3D = null
var _right_port: Node3D = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_ensure_ports()
	_ensure_particles()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[BoostExhaust] debug_validate: %s" % e)

func _ensure_ports() -> void:
	if _left_port == null:
		_left_port = Node3D.new()
		_left_port.name = "Exhaust_Left"
		_left_port.position = EXHAUST_OFFSET_LEFT
		add_child(_left_port)
	if _right_port == null:
		_right_port = Node3D.new()
		_right_port.name = "Exhaust_Right"
		_right_port.position = EXHAUST_OFFSET_RIGHT
		add_child(_right_port)

func _ensure_particles() -> void:
	if _particles != null:
		return
	var p := GPUParticles3D.new()
	p.name = "BoostExhaustParticles"
	p.emitting = false
	p.amount = 64
	p.lifetime = PARTICLE_LIFETIME
	p.visibility_aabb = AABB(Vector3(-1.5, -0.6, -3.5), Vector3(3.0, 1.2, 3.5))
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 0, -1)
	mat.spread = PARTICLE_SPREAD_DEG
	mat.initial_velocity_min = PARTICLE_SPEED * 0.75
	mat.initial_velocity_max = PARTICLE_SPEED * 1.25
	mat.gravity = Vector3(0, -PConfig.GRAVITY * PARTICLE_GRAVITY_RATIO, 0)
	mat.scale_min = PARTICLE_SIZE_MIN
	mat.scale_max = PARTICLE_SIZE_MAX
	mat.color = FLAME_CORE_COLOR
	p.process_material = mat
	add_child(p)
	_particles = p

# ---------------------------------------------------------------------------
# Static queries — deterministic, budget-aware (0 allocations, pure math)
# ---------------------------------------------------------------------------

static func get_exhaust_offsets() -> Array[Vector3]:
	return EXHAUST_OFFSETS.duplicate()

static func exhaust_offsets_for_car(car: Node3D) -> Array[Vector3]:
	if car == null:
		return EXHAUST_OFFSETS.duplicate()
	var b: Basis = car.global_transform.basis
	var arr: Array[Vector3] = []
	for off in EXHAUST_OFFSETS:
		arr.append(car.global_position + b * off)
	return arr

static func is_exhaust_active(boost_amount: float, is_boost_pressed: bool) -> bool:
	return is_boost_pressed and boost_amount > MIN_BOOST_FOR_EXHAUST

static func is_active_for_boost(boost: CarBoostRef) -> bool:
	if boost == null:
		return false
	return boost.has_boost() and boost.is_boosting()

static func compute_intensity(boost_amount: float, is_boosting: bool) -> float:
	if not is_boosting or boost_amount <= 0.0:
		return 0.0
	var t := clamp(boost_amount / CarBoostRef.MAX_BOOST, 0.0, 1.0)
	if t < 0.5:
		return lerpf(0.0, INTENSITY_AT_HALF, t / 0.5)
	return lerpf(INTENSITY_AT_HALF, INTENSITY_AT_FULL, (t - 0.5) / 0.5)

static func compute_jitter(tick: int, port_index: int) -> Vector3:
	var s := float(tick + port_index * 137 + JITTER_SEED)
	var jx := sin(s * PHI) * 0.02
	var jy := sin(s * PHI * 0.97 + 1.1) * 0.015
	var jz := sin(s * PHI * 1.13 + 2.3) * 0.01
	return Vector3(jx, jy, jz)

static func should_emit(boost_amount: float, is_pressed: bool, _car_speed: float = 0.0) -> bool:
	return is_exhaust_active(boost_amount, is_pressed)

# ---------------------------------------------------------------------------
# Per-tick update — budget-aware (<12 calls), deterministic
# ---------------------------------------------------------------------------

## Drive exhaust from CarBoost + car. Returns emitting bool.
## Budget: 1 boost amount read, 1 emitting set.
func physics_tick(car: RigidBody3D, boost: CarBoostRef, delta: float) -> bool:
	_call_count_last_tick = 0
	_tick_count += 1
	var should := false
	var intensity := 0.0
	if boost != null:
		should = boost.is_boosting() and boost.get_amount() > MIN_BOOST_FOR_EXHAUST
		_call_count_last_tick += 2
		if should:
			intensity = compute_intensity(boost.get_amount(), true)
			_call_count_last_tick += 1
	else:
		should = false
	_intensity = intensity if should else max(_intensity - delta / FADE_OUT_TIME, 0.0)
	_call_count_last_tick += 1
	_is_emitting = should or _intensity > 0.01
	if _is_emitting:
		_time_emitting += delta
	else:
		_time_emitting = 0.0
	if _particles != null:
		_particles.emitting = _is_emitting
		_particles.amount_ratio = clamp(_intensity, 0.0, 1.0) if _is_emitting else 0.0
		if _left_port != null:
			_left_port.position = EXHAUST_OFFSET_LEFT + compute_jitter(_tick_count, 0)
		if _right_port != null:
			_right_port.position = EXHAUST_OFFSET_RIGHT + compute_jitter(_tick_count, 1)
		_call_count_last_tick += 3
	if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
		push_warning("[BoostExhaust] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
	return _is_emitting

static func tick_exhaust_state(boost_amount: float, is_pressed: bool, delta: float, prev_intensity: float) -> Dictionary:
	var active := is_exhaust_active(boost_amount, is_pressed)
	var inten := compute_intensity(boost_amount, active) if active else max(prev_intensity - delta / FADE_OUT_TIME, 0.0)
	return {"emitting": active or inten > 0.01, "intensity": inten, "active": active}

func is_emitting() -> bool:
	return _is_emitting

func get_intensity() -> float:
	return _intensity

func time_emitting() -> float:
	return _time_emitting

func get_call_count_last_tick() -> int:
	return _call_count_last_tick

func get_particle_node() -> GPUParticles3D:
	return _particles

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
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if CarBoostRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("CarBoost tick %d != 120" % CarBoostRef.PHYSICS_TICKS_PER_SECOND)
	if OctaneRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("Octane tick %d != 120" % OctaneRef.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(CAR_LENGTH, PC.CAR_LENGTH):
		errors.append("CAR_LENGTH %.2f != PC.CAR_LENGTH %.2f" % [CAR_LENGTH, PC.CAR_LENGTH])
	if not is_equal_approx(CAR_LENGTH, OctaneRef.CAR_LENGTH):
		errors.append("CAR_LENGTH %.2f != Octane.CAR_LENGTH %.2f" % [CAR_LENGTH, OctaneRef.CAR_LENGTH])
	if EXHAUST_COUNT != 2:
		errors.append("EXHAUST_COUNT %d != 2" % EXHAUST_COUNT)
	if EXHAUST_OFFSETS.size() != 2:
		errors.append("EXHAUST_OFFSETS size %d != 2" % EXHAUST_OFFSETS.size())
	if not is_equal_approx(EXHAUST_Z, -2.05):
		errors.append("EXHAUST_Z %.2f != -2.05 (rear)" % EXHAUST_Z)
	if not is_equal_approx(MIN_BOOST_FOR_EXHAUST, CarBoostRef.MIN_BOOST_TO_ACTIVATE):
		errors.append("MIN_BOOST_FOR_EXHAUST %.2f != CarBoost.MIN_BOOST_TO_ACTIVATE %.2f" % [MIN_BOOST_FOR_EXHAUST, CarBoostRef.MIN_BOOST_TO_ACTIVATE])
	if not is_equal_approx(PARTICLE_LIFETIME, 0.35):
		errors.append("PARTICLE_LIFETIME must be 0.35, got %.3f" % PARTICLE_LIFETIME)
	if PARTICLE_EMISSION_RATE <= 0.0:
		errors.append("PARTICLE_EMISSION_RATE must be >0")
	if MAX_DRAW_CALLS != 12:
		errors.append("MAX_DRAW_CALLS %d != 12" % MAX_DRAW_CALLS)
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"is_emitting": _is_emitting,
		"intensity": _intensity,
		"time_emitting": _time_emitting,
		"tick_count": _tick_count,
		"calls_last_tick": _call_count_last_tick,
		"offsets": EXHAUST_OFFSETS,
	}

static func perf_mark() -> Dictionary:
	return {"max_calls_per_tick": MAX_CALLS_PER_TICK, "budget_calls": BUDGET_CALLS, "max_draw_calls": MAX_DRAW_CALLS}
