## WS68 — Environmental Dust Motes — budget-aware <12 calls, deterministic
## Volumetric dust motes drifting in arena volume, lit by stadium (WS36).
## Budget: <12 API calls/tick, <12 draw calls, 120 Hz fixed tick.
## Deterministic: no randf — seeded drift from tick counter, all params authored.
## Depends on: src/core/constants.gd (WS04), src/core/physics/physics_config.gd (WS07),
##             src/game/arena/stadium.gd (WS36), src/game/arena/arena_collision.gd (WS21)
## Conventions: docs/architecture/00-conventions.md §3-§5, 1 unit=1 m, Y-up, +Z forward.
extends Node3D
class_name Dust

const PC = preload("res://src/core/constants.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const StadiumRef = preload("res://src/game/arena/stadium.gd")

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
# Arena / stadium — single source via PhysicsConstants + Stadium WS36
# ---------------------------------------------------------------------------
const ARENA_LENGTH: float = 60.0
const ARENA_WIDTH: float = 40.0
const ARENA_HEIGHT: float = 20.0
const ARENA_HALF_LENGTH: float = 30.0
const ARENA_HALF_WIDTH: float = 20.0
const ARENA_SIZE: Vector3 = Vector3(40.0, 20.0, 60.0)
const ARENA_HALF_SIZE: Vector3 = Vector3(20.0, 10.0, 30.0)
const ARENA_VOLUME: float = 48000.0

# Stadium authored mesh reference — WS36
const STADIUM_MESH_PATH: String = "res://assets/authored/arena/stadium_dfh_mesh_a_v01.glb"

# ---------------------------------------------------------------------------
# Dust motes — authored volumetric particles, budget-aware
# ---------------------------------------------------------------------------
const DUST_AMOUNT: int = 64
const PARTICLE_AMOUNT: int = DUST_AMOUNT
const DUST_LIFETIME: float = 8.0
const PARTICLE_LIFETIME: float = DUST_LIFETIME
const DUST_SPEED: float = 0.22
const PARTICLE_SPEED: float = DUST_SPEED
const DUST_SPREAD_DEG: float = 180.0
const PARTICLE_SPREAD_DEG: float = DUST_SPREAD_DEG
const DUST_SIZE_MIN: float = 0.025
const DUST_SIZE_MAX: float = 0.075
const PARTICLE_SIZE_MIN: float = DUST_SIZE_MIN
const PARTICLE_SIZE_MAX: float = DUST_SIZE_MAX
const DUST_GRAVITY_RATIO: float = 0.0
const DUST_ALPHA: float = 0.18
const DUST_COLOR: Color = Color(0.92, 0.88, 0.82, 0.18)
const DUST_COLOR_FADE: Color = Color(0.92, 0.88, 0.82, 0.0)
const DUST_LIT_COLOR: Color = Color(0.96, 0.93, 0.86, 0.22)
const DUST_EMISSION_BOX: Vector3 = Vector3(40.0, 18.0, 60.0)

# Drift — slow authored cross-breeze, deterministic
const DRIFT_SPEED_X: float = 0.08
const DRIFT_SPEED_Z: float = -0.05
const DRIFT_AMPLITUDE_Y: float = 0.04
const DRIFT_FREQUENCY: float = 0.35
const DRIFT_TURBULENCE: float = 0.02

# Density — budget LOD, fewer motes when far / low setting
const DENSITY_FULL: float = 1.0
const DENSITY_LOW: float = 0.4
const DENSITY_MIN_VISIBLE: float = 0.08
const VISIBILITY_FALLOFF_DIST: float = 35.0
const FADE_NEAR_DIST: float = 2.0

# Determinism
const JITTER_SEED: int = 0x68D057
const PHI: float = 1.618033988749895

# ---------------------------------------------------------------------------
# Instance state — budget-aware, no alloc per tick beyond these
# ---------------------------------------------------------------------------
var _enabled: bool = true
var _density: float = DENSITY_FULL
var _tick_count: int = 0
var _call_count_last_tick: int = 0
var _stadium: Node3D = null
var _particles: GPUParticles3D = null
var _wind_offset: Vector3 = Vector3.ZERO

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_ensure_particles()
	_try_bind_stadium()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[Dust] debug_validate: %s" % e)

func _ensure_particles() -> void:
	if _particles != null:
		return
	var p := GPUParticles3D.new()
	p.name = "DustMotes"
	p.emitting = _enabled
	p.amount = PARTICLE_AMOUNT
	p.lifetime = PARTICLE_LIFETIME
	p.one_shot = false
	p.explosiveness = 0.0
	p.visibility_aabb = AABB(Vector3(-ARENA_HALF_WIDTH, 0.0, -ARENA_HALF_LENGTH), ARENA_SIZE)
	p.amount_ratio = _density
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(DRIFT_SPEED_X, 0.0, DRIFT_SPEED_Z).normalized() if Vector3(DRIFT_SPEED_X, 0.0, DRIFT_SPEED_Z).length_squared() > 0.001 else Vector3(0, 0, 1)
	mat.spread = PARTICLE_SPREAD_DEG
	mat.initial_velocity_min = PARTICLE_SPEED * 0.4
	mat.initial_velocity_max = PARTICLE_SPEED * 1.1
	mat.gravity = Vector3(0, -PConfig.GRAVITY * DUST_GRAVITY_RATIO, 0) if PConfig != null else Vector3.ZERO
	mat.scale_min = PARTICLE_SIZE_MIN
	mat.scale_max = PARTICLE_SIZE_MAX
	mat.color = DUST_COLOR
	var scale_curve := CurveTexture.new()
	mat.scale_curve = scale_curve
	p.process_material = mat
	var qm := QuadMesh.new()
	qm.size = Vector2(0.06, 0.06)
	p.draw_pass_1 = qm
	p.position = Vector3(0, ARENA_HEIGHT * 0.48, 0)
	add_child(p)
	_particles = p

func _try_bind_stadium() -> void:
	if _stadium != null:
		return
	var parent := get_parent()
	if parent != null:
		var s := parent.find_child("Stadium", true, false)
		if s != null:
			_stadium = s as Node3D
			return
	var tree := get_tree()
	if tree != null:
		var nodes := tree.get_nodes_in_group("stadium")
		if nodes.size() > 0:
			_stadium = nodes[0] as Node3D

## Bind to explicit Stadium node (preferred). Budget: 1 ref store.
func bind_stadium(stadium: Node3D) -> void:
	_stadium = stadium

## Enable/disable motes without freeing. Budget: 1 call.
func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	if _particles != null:
		_particles.emitting = enabled
		_particles.visible = enabled

func is_enabled() -> bool:
	return _enabled

## Density 0..1 — scales amount_ratio. Budget: 1 call (clamped, no alloc).
func set_density(density: float) -> void:
	_density = clamp(density, 0.0, 1.0)
	if _particles != null:
		_particles.amount_ratio = _density

func get_density() -> float:
	return _density

func _physics_process(delta: float) -> void:
	_call_count_last_tick = 0
	_tick_count += 1
	_call_count_last_tick += 1
	if not _enabled:
		if _particles != null and _particles.emitting:
			_particles.emitting = false
			_call_count_last_tick += 1
		return
	_wind_offset.x += DRIFT_SPEED_X * delta
	_wind_offset.z += DRIFT_SPEED_Z * delta
	_wind_offset.y = sin(float(_tick_count) * TICK_DELTA * DRIFT_FREQUENCY) * DRIFT_AMPLITUDE_Y
	_call_count_last_tick += 1
	if _particles != null:
		var j := compute_jitter(_tick_count, 0)
		_particles.position = Vector3(0, ARENA_HEIGHT * 0.48, 0) + _wind_offset * 0.12 + j
		_call_count_last_tick += 1
		if not _particles.emitting:
			_particles.emitting = true
			_call_count_last_tick += 1
	if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
		push_warning("[Dust] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
		_call_count_last_tick = MAX_CALLS_PER_TICK

# ---------------------------------------------------------------------------
# Static queries — deterministic, budget-aware
# ---------------------------------------------------------------------------
static func is_inside_arena(point: Vector3) -> bool:
	return PC.is_inside_arena(point) if PC != null else (abs(point.x) <= 20.0 and point.y >= 0.0 and point.y <= 20.0 and abs(point.z) <= 30.0)

static func arena_volume() -> float:
	return ARENA_VOLUME

static func dust_density_for_quality(quality: String) -> float:
	match quality:
		"low":
			return DENSITY_LOW
		"medium":
			return 0.7
		"high":
			return DENSITY_FULL
		_:
			return DENSITY_FULL

static func alpha_for_distance(dist: float) -> float:
	if dist <= FADE_NEAR_DIST:
		return DUST_ALPHA
	if dist >= VISIBILITY_FALLOFF_DIST:
		return 0.0
	var t := (dist - FADE_NEAR_DIST) / (VISIBILITY_FALLOFF_DIST - FADE_NEAR_DIST)
	return lerp(DUST_ALPHA, 0.0, clamp(t, 0.0, 1.0))

static func drift_at(tick: int) -> Vector3:
	var t := float(tick) * TICK_DELTA
	return Vector3(
		DRIFT_SPEED_X * t + sin(t * PHI) * DRIFT_TURBULENCE,
		sin(t * DRIFT_FREQUENCY) * DRIFT_AMPLITUDE_Y,
		DRIFT_SPEED_Z * t + cos(t * PHI * 0.73) * DRIFT_TURBULENCE
	)

static func compute_jitter(tick: int, index: int) -> Vector3:
	var s := float(tick + index * 137 + JITTER_SEED)
	var jx := sin(s * PHI) * 0.015
	var jy := sin(s * PHI * 0.97 + 1.1) * 0.010
	var jz := sin(s * PHI * 1.13 + 2.4) * 0.015
	return Vector3(jx, jy, jz)

static func emission_aabb() -> AABB:
	return AABB(Vector3(-ARENA_HALF_WIDTH, 0.0, -ARENA_HALF_LENGTH), ARENA_SIZE)

static func is_dust_visible(density: float, distance: float) -> bool:
	if density < DENSITY_MIN_VISIBLE:
		return false
	return alpha_for_distance(distance) > 0.01

# ---------------------------------------------------------------------------
# Budget / validation
# ---------------------------------------------------------------------------
func get_particle_count() -> int:
	return PARTICLE_AMOUNT

func get_draw_call_count() -> int:
	return 1 if _particles != null and _particles.visible and _enabled else 0

func get_budget_state() -> Dictionary:
	var dc := get_draw_call_count()
	return {
		"draw_calls": dc,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": dc <= DRAW_CALL_BUDGET,
		"calls_last_tick": _call_count_last_tick,
		"call_budget": MAX_CALLS_PER_TICK,
		"within_call_budget": _call_count_last_tick <= MAX_CALLS_PER_TICK,
		"density": _density,
		"enabled": _enabled,
	}

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PARTICLE_AMOUNT > 128:
		errors.append("PARTICLE_AMOUNT %d > 128 budget" % PARTICLE_AMOUNT)
	if PARTICLE_LIFETIME <= 0.0:
		errors.append("PARTICLE_LIFETIME <= 0")
	if DUST_ALPHA < 0.0 or DUST_ALPHA > 1.0:
		errors.append("DUST_ALPHA out of 0..1")
	if not is_equal_approx(ARENA_LENGTH, PC.ARENA_LENGTH) if PC != null else not is_equal_approx(ARENA_LENGTH, 60.0):
		errors.append("ARENA_LENGTH mismatch vs PhysicsConstants")
	if not is_equal_approx(ARENA_WIDTH, PC.ARENA_WIDTH) if PC != null else not is_equal_approx(ARENA_WIDTH, 40.0):
		errors.append("ARENA_WIDTH mismatch")
	if not is_equal_approx(ARENA_HEIGHT, PC.ARENA_HEIGHT) if PC != null else not is_equal_approx(ARENA_HEIGHT, 20.0):
		errors.append("ARENA_HEIGHT mismatch")
	if DRAW_CALL_BUDGET != 12:
		errors.append("DRAW_CALL_BUDGET != 12")
	if MAX_CALLS_PER_TICK != 12:
		errors.append("MAX_CALLS_PER_TICK != 12")
	return {"ok": errors.is_empty(), "errors": errors}
