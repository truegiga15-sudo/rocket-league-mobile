## WS11 — Car Chassis Physics & Mass Distribution
## RigidBody3D chassis, 180 kg, box inertia, low center of mass, arena-center spawn.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07),
##             src/core/physics/physics_config.gd (WS07), src/core/time_service.gd (WS05)
## Conventions: docs/architecture/00-conventions.md §3-§4, 1 unit = 1 m, Y-up, +Z forward.
## No procedural generation — all values authored/deterministic. No new physics engine.
extends RigidBody3D
class_name CarPhysics

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")

# ---------------------------------------------------------------------------
# Authored chassis constants — single source for downstream WS (suspension etc.)
# ---------------------------------------------------------------------------

## Chassis mass in kg. Authored at RL ratio (car 180 kg vs ball 30 kg keeps impulse sane).
## Must match PhysicsConfig.MASS_CAR — validated in debug_validate().
const MASS: float = 180.0

## Box inertia for a solid cuboid 1/12*m*(h²+l²) etc., using PhysicsConstants car size.
## Precomputed for CAR_WIDTH=2.1, CAR_HEIGHT=1.5, CAR_LENGTH=4.2 at 180 kg.
##   Ix = 1/12*m*(h²+l²) ≈ 298.35, Iy ≈ 330.75, Iz ≈ 99.90
const INERTIA_DIAGONAL := Vector3(298.35, 330.75, 99.9)

## Mass distribution: center of mass offset in local body space.
## Y negative = low CoM for roll stability (prevents easy rollover, RL-like feel).
## Z small positive = slight forward bias (engine/front weight).
const CENTER_OF_MASS_OFFSET := Vector3(0.0, -0.35, 0.08)
const CENTER_OF_MASS_OFFSET_LOW_Y: float = -0.35

## Ground clearance added to half-height when spawning at arena center.
const SPAWN_CLEARANCE: float = 0.3

## Spawn position: arena center on XZ (0,0) with Y = half-height + clearance.
static func get_spawn_position() -> Vector3:
	return Vector3(0.0, PC.CAR_HALF_EXTENTS.y + SPAWN_CLEARANCE, 0.0)

const SPAWN_ARENA_CENTER := Vector3.ZERO

# ---------------------------------------------------------------------------
# Physics layers — never hardcode numbers, always via PhysicsLayers (§4).
# ---------------------------------------------------------------------------
const LAYER_INDEX: int = 1

# ---------------------------------------------------------------------------
# Damping — from PhysicsConfig
# ---------------------------------------------------------------------------
const LINEAR_DAMPING: float = 0.15
const ANGULAR_DAMPING: float = 0.35

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	configure_physics()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[CarPhysics] debug_validate: %s" % e)

func _physics_process(_delta: float) -> void:
	pass

## Configure RigidBody3D properties to authored spec. Idempotent.
func configure_physics() -> void:
	mass = MASS
	inertia = INERTIA_DIAGONAL
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = CENTER_OF_MASS_OFFSET
	collision_layer = PL.BIT_CAR_CHASSIS
	collision_mask = PL.MASK_CAR_CHASSIS
	linear_damp = LINEAR_DAMPING
	angular_damp = ANGULAR_DAMPING
	physics_material_override = _make_physics_material()
	continuous_cd = false
	lock_rotation = false
	freeze = false
	can_sleep = true
	sleeping = false
	custom_integrator = false
	gravity_scale = 1.0
	if global_position == Vector3.ZERO:
		global_position = get_spawn_position()
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO

func _make_physics_material() -> PhysicsMaterial:
	var mat := PhysicsMaterial.new()
	mat.friction = PConfig.FRICTION_WORLD_CAR
	mat.bounce = PConfig.RESTITUTION_WORLD_CAR
	return mat

## Reset to spawn pose (arena center + clearance), zero velocities.
func reset_to_spawn() -> void:
	global_position = get_spawn_position()
	global_rotation = Vector3.ZERO
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	sleeping = false

## Reset to arbitrary arena position (clamped inside arena via PhysicsConstants).
func reset_to_position(pos: Vector3) -> void:
	global_position = PC.clamp_to_arena(pos)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	sleeping = false

# ---------------------------------------------------------------------------
# Inertia helpers
# ---------------------------------------------------------------------------

static func compute_box_inertia(mass_val: float, size: Vector3) -> Vector3:
	var w := size.x
	var h := size.y
	var l := size.z
	var ix := (mass_val / 12.0) * (h * h + l * l)
	var iy := (mass_val / 12.0) * (w * w + l * l)
	var iz := (mass_val / 12.0) * (w * w + h * h)
	return Vector3(ix, iy, iz)

static func expected_inertia() -> Vector3:
	return compute_box_inertia(MASS, PC.car_size())

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

static func debug_validate_static() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(MASS, 180.0):
		errors.append("MASS %.2f != 180.0 kg" % MASS)
	if not is_equal_approx(MASS, PConfig.MASS_CAR):
		errors.append("MASS %.2f != PhysicsConfig.MASS_CAR %.2f" % [MASS, PConfig.MASS_CAR])
	if MASS <= 0.0:
		errors.append("MASS must be > 0")
	if INERTIA_DIAGONAL.x <= 0.0 or INERTIA_DIAGONAL.y <= 0.0 or INERTIA_DIAGONAL.z <= 0.0:
		errors.append("INERTIA_DIAGONAL must be > 0: %s" % str(INERTIA_DIAGONAL))
	var expected := compute_box_inertia(MASS, PC.car_size())
	for axis in ["x", "y", "z"]:
		var actual: float = INERTIA_DIAGONAL[axis]
		var exp: float = expected[axis]
		if exp > 0.0 and abs(actual - exp) / exp > 0.05:
			errors.append("INERTIA_DIAGONAL.%s %.2f deviates >5%% from box %.2f (size=%s)" % [axis, actual, exp, str(PC.car_size())])
	if CENTER_OF_MASS_OFFSET.y >= 0.0:
		errors.append("CENTER_OF_MASS_OFFSET.y %.3f must be < 0 (low CoM)" % CENTER_OF_MASS_OFFSET.y)
	if CENTER_OF_MASS_OFFSET.y < -1.0 or CENTER_OF_MASS_OFFSET.y > 0.0:
		errors.append("CENTER_OF_MASS_OFFSET.y %.3f outside [-1,0)" % CENTER_OF_MASS_OFFSET.y)
	if not is_equal_approx(CENTER_OF_MASS_OFFSET.x, 0.0):
		errors.append("CENTER_OF_MASS_OFFSET.x %.3f must be 0" % CENTER_OF_MASS_OFFSET.x)
	if LAYER_INDEX != PL.LAYER_CAR_CHASSIS:
		errors.append("LAYER_INDEX %d != LAYER_CAR_CHASSIS %d" % [LAYER_INDEX, PL.LAYER_CAR_CHASSIS])
	var bit: int = PL.BIT_CAR_CHASSIS
	var mask: int = PL.MASK_CAR_CHASSIS
	if bit != (1 << PL.LAYER_CAR_CHASSIS):
		errors.append("BIT %d != 1<<%d" % [bit, PL.LAYER_CAR_CHASSIS])
	if bit != 2:
		errors.append("BIT %d != 2 (layer 1)" % bit)
	if (mask & PL.BIT_WORLD_STATIC) == 0:
		errors.append("MASK missing BIT_WORLD_STATIC")
	if (mask & PL.BIT_BALL) == 0:
		errors.append("MASK missing BIT_BALL")
	if (mask & PL.BIT_BOOST_PADS) != 0:
		errors.append("MASK must not include BIT_BOOST_PADS")
	if (mask & PL.BIT_SENSORS) != 0:
		errors.append("MASK must not include BIT_SENSORS")
	if not PL.is_valid_mask(mask):
		errors.append("MASK %d invalid" % mask)
	var spawn := get_spawn_position()
	if not is_equal_approx(spawn.x, 0.0) or not is_equal_approx(spawn.z, 0.0):
		errors.append("spawn XZ must be (0,0), got %s" % str(spawn))
	var expected_y := PC.CAR_HALF_EXTENTS.y + SPAWN_CLEARANCE
	if not is_equal_approx(spawn.y, expected_y):
		errors.append("spawn.y %.3f != half_y %.3f + clearance %.3f" % [spawn.y, PC.CAR_HALF_EXTENTS.y, SPAWN_CLEARANCE])
	if spawn.y < PC.CAR_HALF_EXTENTS.y:
		errors.append("spawn Y %.3f < half-height %.3f" % [spawn.y, PC.CAR_HALF_EXTENTS.y])
	if not PC.is_inside_arena(spawn):
		errors.append("spawn %s outside arena %s" % [str(spawn), str(PC.arena_aabb())])
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if PConfig.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PConfig TICKS %d != 120" % PConfig.PHYSICS_TICKS_PER_SECOND)
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != -1 and ps_rate != 120:
		errors.append("project.godot ticks %d != 120" % ps_rate)
	if not is_equal_approx(PC.PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA %.6f != 1/120" % PC.PHYSICS_TICK_DELTA)
	if not is_equal_approx(LINEAR_DAMPING, PConfig.LINEAR_DAMPING_CAR):
		errors.append("LINEAR_DAMPING %.3f != PConfig %.3f" % [LINEAR_DAMPING, PConfig.LINEAR_DAMPING_CAR])
	if not is_equal_approx(ANGULAR_DAMPING, PConfig.ANGULAR_DAMPING_CAR):
		errors.append("ANGULAR_DAMPING %.3f != PConfig %.3f" % [ANGULAR_DAMPING, PConfig.ANGULAR_DAMPING_CAR])
	return {"ok": errors.is_empty(), "errors": errors}

func debug_validate() -> Dictionary:
	var base := debug_validate_static()
	var errors: Array[String] = []
	for e in base["errors"]:
		errors.append(e)
	if not is_equal_approx(mass, MASS):
		errors.append("live mass %.2f != MASS %.2f" % [mass, MASS])
	if collision_layer != PL.BIT_CAR_CHASSIS:
		errors.append("live layer %d != BIT %d" % [collision_layer, PL.BIT_CAR_CHASSIS])
	if collision_mask != PL.MASK_CAR_CHASSIS:
		errors.append("live mask %d != MASK %d" % [collision_mask, PL.MASK_CAR_CHASSIS])
	if center_of_mass_mode != RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM:
		errors.append("center_of_mass_mode != CUSTOM")
	if not center_of_mass.is_equal_approx(CENTER_OF_MASS_OFFSET):
		errors.append("live CoM %s != offset %s" % [str(center_of_mass), str(CENTER_OF_MASS_OFFSET)])
	return {"ok": errors.is_empty(), "errors": errors}

# ---------------------------------------------------------------------------
# Telemetry / perf — conventions §11
# ---------------------------------------------------------------------------

static func debug_export_static() -> Dictionary:
	return {
		"mass": MASS,
		"inertia_diagonal": INERTIA_DIAGONAL,
		"center_of_mass_offset": CENTER_OF_MASS_OFFSET,
		"spawn_position": get_spawn_position(),
		"spawn_clearance": SPAWN_CLEARANCE,
		"collision_layer": PL.BIT_CAR_CHASSIS,
		"collision_mask": PL.MASK_CAR_CHASSIS,
		"layer_index": PL.LAYER_CAR_CHASSIS,
		"linear_damping": LINEAR_DAMPING,
		"angular_damping": ANGULAR_DAMPING,
		"physics_tick_hz": PC.PHYSICS_TICKS_PER_SECOND,
		"physics_tick_delta": PC.PHYSICS_TICK_DELTA,
		"car_size": PC.car_size(),
		"car_half_extents": PC.CAR_HALF_EXTENTS,
	}

func debug_export() -> Dictionary:
	var d := debug_export_static()
	d["live_position"] = global_position
	d["live_mass"] = mass
	d["live_inertia"] = inertia
	d["live_center_of_mass"] = center_of_mass
	d["live_collision_layer"] = collision_layer
	d["live_collision_mask"] = collision_mask
	return d

static func perf_mark_static() -> Dictionary:
	return {"scope": "CarPhysics", "mass": MASS, "tick_hz": PC.PHYSICS_TICKS_PER_SECOND}

func perf_mark() -> Dictionary:
	return {"scope": "CarPhysics", "mass": mass, "tick_hz": PC.PHYSICS_TICKS_PER_SECOND, "position": global_position}
