## WS19 — Ball Configuration Helpers
## Single source of truth for ball physics tuning. All values mirror
## src/core/constants.gd (WS04) + src/core/physics/physics_config.gd (WS07)
## so downstream WS (WS20 contact, WS56 mesh, WS57 prediction) import ONE file.
## No magic numbers elsewhere — import BallConfig, never re-declare mass/friction.
extends RefCounted
class_name BallConfig

const PC = preload("res://src/core/constants.gd")
const PCfg = preload("res://src/core/physics/physics_config.gd")
const PL = preload("res://src/core/physics/layers.gd")

const BALL_DIAMETER: float = 1.82
const BALL_RADIUS: float = 0.91
const BALL_CIRCUMFERENCE: float = 5.7177
const MASS: float = 30.0
const FRICTION: float = 0.6
const RESTITUTION_WORLD: float = 0.75
const RESTITUTION_CAR: float = 0.85
const LINEAR_DAMPING: float = 0.08
const ANGULAR_DAMPING: float = 0.12
const SPAWN_POSITION: Vector3 = Vector3(0, 2, 0)
const SPAWN_LINEAR_VELOCITY: Vector3 = Vector3.ZERO
const SPAWN_ANGULAR_VELOCITY: Vector3 = Vector3.ZERO
const CCD_ENABLED: bool = true
const CCD_MOTION_THRESHOLD: float = 0.5
const SLEEP_LINEAR_THRESHOLD: float = 0.1
const SLEEP_ANGULAR_THRESHOLD: float = 0.1
const SLEEP_TIME_THRESHOLD: float = 0.5
const COLLISION_LAYER: int = 8
const COLLISION_MASK: int = 3
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0

static func spawn_position() -> Vector3:
	return SPAWN_POSITION

static func spawn_state() -> Dictionary:
	return {
		"position": SPAWN_POSITION,
		"linear_velocity": SPAWN_LINEAR_VELOCITY,
		"angular_velocity": SPAWN_ANGULAR_VELOCITY,
	}

static func mass() -> float:
	return MASS

static func radius() -> float:
	return BALL_RADIUS

static func diameter() -> float:
	return BALL_DIAMETER

static func sphere_shape() -> SphereShape3D:
	var s := SphereShape3D.new()
	s.radius = BALL_RADIUS
	return s

static func physics_material() -> PhysicsMaterial:
	var m := PhysicsMaterial.new()
	m.friction = FRICTION
	m.bounce = RESTITUTION_WORLD
	m.rough = false
	return m

static func restitution_for_layer(layer: int) -> float:
	if layer == PL.LAYER_CAR_CHASSIS:
		return RESTITUTION_CAR
	if layer == PL.LAYER_WORLD_STATIC:
		return RESTITUTION_WORLD
	return RESTITUTION_WORLD

static func friction_for_layer(_layer: int) -> float:
	return FRICTION

static func collision_layer() -> int:
	return COLLISION_LAYER

static func collision_mask() -> int:
	return COLLISION_MASK

static func layer_index() -> int:
	return PL.LAYER_BALL

static func spin_axis(angular_velocity: Vector3) -> Vector3:
	if angular_velocity.length_squared() < 0.000001:
		return Vector3.ZERO
	return angular_velocity.normalized()

static func spin_rate_rad_per_s(angular_velocity: Vector3) -> float:
	return angular_velocity.length()

static func spin_rate_rpm(angular_velocity: Vector3) -> float:
	return angular_velocity.length() * 60.0 / (2.0 * PI)

static func quantize_position(pos: Vector3) -> Vector3:
	return Vector3(round(pos.x * 1000.0) / 1000.0, round(pos.y * 1000.0) / 1000.0, round(pos.z * 1000.0) / 1000.0)

static func quantize_velocity(vel: Vector3) -> Vector3:
	return Vector3(round(vel.x * 1000.0) / 1000.0, round(vel.y * 1000.0) / 1000.0, round(vel.z * 1000.0) / 1000.0)

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(BALL_DIAMETER, PC.BALL_DIAMETER):
		errors.append("BALL_DIAMETER %.3f != PC.BALL_DIAMETER %.3f" % [BALL_DIAMETER, PC.BALL_DIAMETER])
	if not is_equal_approx(BALL_RADIUS * 2.0, BALL_DIAMETER):
		errors.append("BALL_RADIUS*2 != BALL_DIAMETER")
	if not is_equal_approx(BALL_RADIUS, PC.BALL_RADIUS):
		errors.append("BALL_RADIUS != PC.BALL_RADIUS")
	if MASS <= 0.0:
		errors.append("MASS must be > 0")
	if not is_equal_approx(MASS, PCfg.MASS_BALL):
		errors.append("MASS %.1f != PCfg.MASS_BALL %.1f" % [MASS, PCfg.MASS_BALL])
	if FRICTION < 0.0 or FRICTION > 1.5:
		errors.append("FRICTION out of sane range [0,1.5]")
	if not is_equal_approx(FRICTION, PCfg.FRICTION_WORLD_BALL):
		errors.append("FRICTION != PCfg.FRICTION_WORLD_BALL")
	if RESTITUTION_WORLD < 0.0 or RESTITUTION_WORLD > 1.0:
		errors.append("RESTITUTION_WORLD out of [0,1]")
	if RESTITUTION_CAR < 0.0 or RESTITUTION_CAR > 1.0:
		errors.append("RESTITUTION_CAR out of [0,1]")
	if not is_equal_approx(RESTITUTION_WORLD, PCfg.RESTITUTION_WORLD_BALL):
		errors.append("RESTITUTION_WORLD != PCfg.RESTITUTION_WORLD_BALL")
	if not is_equal_approx(RESTITUTION_CAR, PCfg.RESTITUTION_CAR_BALL):
		errors.append("RESTITUTION_CAR != PCfg.RESTITUTION_CAR_BALL")
	if not is_equal_approx(LINEAR_DAMPING, PCfg.LINEAR_DAMPING_BALL):
		errors.append("LINEAR_DAMPING != PCfg.LINEAR_DAMPING_BALL")
	if not is_equal_approx(ANGULAR_DAMPING, PCfg.ANGULAR_DAMPING_BALL):
		errors.append("ANGULAR_DAMPING != PCfg.ANGULAR_DAMPING_BALL")
	if COLLISION_LAYER != PL.BIT_BALL:
		errors.append("COLLISION_LAYER != PL.BIT_BALL")
	if COLLISION_MASK != PL.MASK_BALL:
		errors.append("COLLISION_MASK != PL.MASK_BALL")
	if SPAWN_POSITION != Vector3(0, 2, 0):
		errors.append("SPAWN_POSITION != (0,2,0)")
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND != 120")
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA != 1/120")
	if PL.LAYER_BALL != 3:
		errors.append("PL.LAYER_BALL != 3 (ball must be layer 3)")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"ball_diameter": BALL_DIAMETER,
		"ball_radius": BALL_RADIUS,
		"mass": MASS,
		"friction": FRICTION,
		"restitution_world": RESTITUTION_WORLD,
		"restitution_car": RESTITUTION_CAR,
		"linear_damping": LINEAR_DAMPING,
		"angular_damping": ANGULAR_DAMPING,
		"spawn_position": SPAWN_POSITION,
		"spawn_linear_velocity": SPAWN_LINEAR_VELOCITY,
		"spawn_angular_velocity": SPAWN_ANGULAR_VELOCITY,
		"ccd_enabled": CCD_ENABLED,
		"ccd_motion_threshold": CCD_MOTION_THRESHOLD,
		"sleep_linear_threshold": SLEEP_LINEAR_THRESHOLD,
		"sleep_angular_threshold": SLEEP_ANGULAR_THRESHOLD,
		"sleep_time_threshold": SLEEP_TIME_THRESHOLD,
		"collision_layer": COLLISION_LAYER,
		"collision_mask": COLLISION_MASK,
		"layer_index": PL.LAYER_BALL,
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"physics_tick_delta": PHYSICS_TICK_DELTA,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "BallConfig", "mass": MASS, "layer": PL.LAYER_BALL, "tick_hz": PHYSICS_TICKS_PER_SECOND}
