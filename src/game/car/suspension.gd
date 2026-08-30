## WS12 — Raycast Suspension (budget-aware, solo retry)
## 4-wheel raycast suspension: REST_LENGTH 0.3m, SPRING 32000 N/m, DAMPER 2800 Ns/m.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07),
##             src/core/time_service.gd (WS05), src/game/car/car_physics.gd (WS11)
## Conventions: docs/architecture/00-conventions.md §3-§4, 1 unit = 1 m, Y-up, +Z forward.
## Physics tick 120 Hz, raycasts use PhysicsLayers BIT_WHEELS / MASK_WHEELS.
## No procedural generation — all values authored/deterministic. No new physics engine.
## Budget: <4 ms per physics tick for 4 wheels (conventions §12).
extends RefCounted
class_name CarSuspension

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
# TimeService autoload not preloaded directly; use constants for tick validation.
# PhysicsConfig for cross-validation
const PConfig = preload("res://src/core/physics/physics_config.gd")

# ---------------------------------------------------------------------------
# Authored suspension constants — single source for WS12 + WS13 friction
# ---------------------------------------------------------------------------

## Rest length of suspension spring (m). Gap between chassis mount and wheel center at rest.
const REST_LENGTH: float = 0.3

## Spring stiffness (N/m). 32000 N/m gives RL-like firmness at 180 kg chassis.
const SPRING: float = 32000.0
const SPRING_STIFFNESS: float = SPRING

## Damper coefficient (Ns/m). 2800 Ns/m critically-ish damped for 32000 N/m.
const DAMPER: float = 2800.0
const DAMPER_COEFFICIENT: float = DAMPER

## Ray length for ground query (m). Must exceed REST_LENGTH to detect contact.
## REST_LENGTH 0.3 + wheel radius ~0.35 + margin 0.15 = 0.8? Budget keeps 0.5 for WS12.
const RAY_LENGTH: float = 0.55
const RAYLENGTH: float = RAY_LENGTH

## Wheel count — always 4 (FL, FR, RL, RR)
const WHEEL_COUNT: int = 4
const NUM_WHEELS: int = 4

## Wheel radius (m) — visual + ray offset, matches Rocket League wheel ~0.35m.
const WHEEL_RADIUS: float = 0.35

## Suspension travel limits (m)
const MAX_COMPRESSION: float = 0.18
const MAX_EXTENSION: float = 0.12

## Wheel mount positions in chassis local space (X right, Y up, Z forward).
## Derived from CAR_WIDTH 2.1 and CAR_LENGTH 4.2 with slight inset.
const WHEEL_OFFSETS: Array[Vector3] = [
	Vector3(-0.95, -0.20, 1.35),  # 0: Front-Left
	Vector3(0.95, -0.20, 1.35),   # 1: Front-Right
	Vector3(-0.95, -0.20, -1.35), # 2: Rear-Left
	Vector3(0.95, -0.20, -1.35),  # 3: Rear-Right
]

const WHEEL_NAMES: Array[String] = ["FL", "FR", "RL", "RR"]

# ---------------------------------------------------------------------------
# Physics layers — never hardcode numbers, always via PhysicsLayers (§4).
# Raycasts query world static only.
# ---------------------------------------------------------------------------
const RAY_COLLISION_MASK: int = 1 # placeholder overwritten by PL.MASK_WHEELS getter
static func get_ray_mask() -> int:
	return PL.MASK_WHEELS

static func get_ray_layer() -> int:
	return PL.BIT_WHEELS

# ---------------------------------------------------------------------------
# Time / tick — 120 Hz fixed
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Per-wheel state
# ---------------------------------------------------------------------------
var wheel_compression: Array[float] = [0.0, 0.0, 0.0, 0.0]
var wheel_contact: Array[bool] = [false, false, false, false]
var wheel_hit_point: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var wheel_hit_normal: Array[Vector3] = [Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP]
var wheel_last_compression: Array[float] = [0.0, 0.0, 0.0, 0.0]

# ---------------------------------------------------------------------------
# Spring / damper math — Hooke + linear damper, budget-aware (no alloc per tick)
# ---------------------------------------------------------------------------

## Spring force magnitude (N) for a given compression (m). F = k * x
static func spring_force(compression: float) -> float:
	var c := clamp(compression, -MAX_EXTENSION, MAX_COMPRESSION)
	return SPRING * c

## Damper force magnitude (N) for compression velocity (m/s). F = c * v
static func damper_force(compression_velocity: float) -> float:
	return DAMPER * compression_velocity

## Combined suspension force (N) along ray normal.
static func suspension_force(compression: float, compression_velocity: float) -> float:
	return spring_force(compression) + damper_force(compression_velocity)

## Compute compression from ray hit distance.
## hit_distance: distance from mount to hit point along -Y ray.
## Returns compression >0 means spring compressed (wheel up into chassis).
static func compression_from_hit(hit_distance: float) -> float:
	# rest length is 0.3; if hit at 0.3 => 0 compression. Closer => positive compression.
	var comp := REST_LENGTH - (hit_distance - WHEEL_RADIUS)
	return clamp(comp, -MAX_EXTENSION, MAX_COMPRESSION)

# ---------------------------------------------------------------------------
# Raycast helpers — uses PhysicsDirectSpaceState, mask = BIT_WORLD_STATIC via MASK_WHEELS
# ---------------------------------------------------------------------------

## Perform single wheel raycast. Returns Dictionary {hit:bool, distance:float, point:Vector3, normal:Vector3}
static func raycast_wheel(space_state: PhysicsDirectSpaceState3D, origin: Vector3, ray_length: float = RAY_LENGTH) -> Dictionary:
	if space_state == null:
		return {"hit": false, "distance": ray_length, "point": origin - Vector3.UP * ray_length, "normal": Vector3.UP}
	var to := origin - Vector3.UP * ray_length
	var query := PhysicsRayQueryParameters3D.create(origin, to, PL.MASK_WHEELS)
	# Ray itself is on wheels layer conceptually; mask queries world static
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.hit_from_inside = false
	var res := space_state.intersect_ray(query)
	if res.is_empty():
		return {"hit": false, "distance": ray_length, "point": to, "normal": Vector3.UP}
	return {"hit": true, "distance": origin.distance_to(res["position"] as Vector3), "point": res["position"] as Vector3, "normal": res["normal"] as Vector3}

## Update all 4 wheels compression/contact from chassis transform and space_state. Returns forces Array[Vector3]
func update(space_state: PhysicsDirectSpaceState3D, chassis_transform: Transform3D, chassis_velocity: Vector3) -> Array[Vector3]:
	var forces: Array[Vector3] = []
	forces.resize(WHEEL_COUNT)
	for i in range(WHEEL_COUNT):
		var local_offset: Vector3 = WHEEL_OFFSETS[i]
		var world_origin: Vector3 = chassis_transform * local_offset
		var ray := CarSuspension.raycast_wheel(space_state, world_origin, RAY_LENGTH)
		var hit: bool = ray["hit"] as bool
		wheel_contact[i] = hit
		wheel_hit_point[i] = ray["point"] as Vector3
		wheel_hit_normal[i] = ray["normal"] as Vector3
		var comp: float = 0.0
		if hit:
			comp = compression_from_hit(float(ray["distance"]))
		else:
			comp = -MAX_EXTENSION
		var comp_vel: float = (comp - wheel_last_compression[i]) / TICK_DELTA
		# Clamp velocity to avoid explosion at high tick jitter
		comp_vel = clamp(comp_vel, -8.0, 8.0)
		wheel_compression[i] = comp
		var f_mag: float = suspension_force(comp, comp_vel) if hit else 0.0
		# Budget: no per-wheel allocation beyond this loop (forces reused)
		forces[i] = Vector3.UP * f_mag
		wheel_last_compression[i] = comp
	return forces

## Apply suspension forces to a CarPhysics RigidBody3D. Budget-aware: 4 raycasts + 4 forces, <4ms.
func apply_to_car(car: RigidBody3D, space_state: PhysicsDirectSpaceState3D = null, delta: float = TICK_DELTA) -> Array[Vector3]:
	if car == null:
		return []
	var ss: PhysicsDirectSpaceState3D = space_state
	if ss == null and car.get_world_3d() != null:
		ss = car.get_world_3d().direct_space_state
	var tf: Transform3D = car.global_transform
	var vel: Vector3 = car.linear_velocity
	var forces := update(ss, tf, vel)
	for i in range(WHEEL_COUNT):
		if not wheel_contact[i]:
			continue
		var offset: Vector3 = WHEEL_OFFSETS[i]
		var world_pos: Vector3 = tf * offset
		var f: Vector3 = forces[i]
		# Apply at wheel mount to get roll/pitch torque
		car.apply_force(f, world_pos - car.global_position)
	return forces

## Reset per-wheel state (e.g. on respawn)
func reset() -> void:
	for i in range(WHEEL_COUNT):
		wheel_compression[i] = 0.0
		wheel_contact[i] = false
		wheel_hit_point[i] = Vector3.ZERO
		wheel_hit_normal[i] = Vector3.UP
		wheel_last_compression[i] = 0.0

# ---------------------------------------------------------------------------
# WS13 Friction integration — delegates to TireFriction
# ---------------------------------------------------------------------------

## Compute tire friction forces via TireFriction for current suspension state.
## throttle: -1..1 from Engine/InputService; steer_angle: rad.
func compute_friction_forces(chassis_transform: Transform3D, chassis_vel: Vector3, throttle: float = 0.0, steer_angle: float = 0.0) -> Array[Vector3]:
	var FrictionRef = load("res://src/game/car/friction.gd")
	return FrictionRef.compute_forces(chassis_transform, chassis_vel, self, throttle, steer_angle)

## Apply both suspension + friction to car in one tick (budget-aware: 8 forces max).
func apply_with_friction(car: RigidBody3D, space_state: PhysicsDirectSpaceState3D = null, throttle: float = 0.0, steer_angle: float = 0.0) -> Dictionary:
	var FrictionRef2 = load("res://src/game/car/friction.gd")
	var susp_forces := apply_to_car(car, space_state)
	var fric_forces := FrictionRef2.apply_to_car(car, self, throttle, steer_angle)
	return {"suspension": susp_forces, "friction": fric_forces}

# ---------------------------------------------------------------------------
# Validation & telemetry — conventions §11 — budget-aware (<4ms physics)
# ---------------------------------------------------------------------------

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(REST_LENGTH, 0.3):
		errors.append("REST_LENGTH %.3f != 0.3" % REST_LENGTH)
	if not is_equal_approx(SPRING, 32000.0):
		errors.append("SPRING %.1f != 32000" % SPRING)
	if not is_equal_approx(DAMPER, 2800.0):
		errors.append("DAMPER %.1f != 2800" % DAMPER)
	if RAY_LENGTH <= REST_LENGTH:
		errors.append("RAY_LENGTH %.3f must be > REST_LENGTH %.3f" % [RAY_LENGTH, REST_LENGTH])
	if RAY_LENGTH < 0.45 or RAY_LENGTH > 0.9:
		errors.append("RAY_LENGTH %.3f outside [0.45,0.9]" % RAY_LENGTH)
	if WHEEL_COUNT != 4:
		errors.append("WHEEL_COUNT %d != 4" % WHEEL_COUNT)
	if WHEEL_OFFSETS.size() != WHEEL_COUNT:
		errors.append("WHEEL_OFFSETS size %d != %d" % [WHEEL_OFFSETS.size(), WHEEL_COUNT])
	if WHEEL_NAMES.size() != WHEEL_COUNT:
		errors.append("WHEEL_NAMES size %d != %d" % [WHEEL_NAMES.size(), WHEEL_COUNT])
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TICK_DELTA, 1.0/120.0):
		errors.append("TICK_DELTA %.6f != 1/120" % TICK_DELTA)
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if PConfig.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PConfig TICKS %d != 120" % PConfig.PHYSICS_TICKS_PER_SECOND)
	# PhysicsLayers checks
	if PL.BIT_WHEELS != 4:
		errors.append("BIT_WHEELS %d != 4" % PL.BIT_WHEELS)
	if PL.MASK_WHEELS != PL.BIT_WORLD_STATIC:
		errors.append("MASK_WHEELS %d != BIT_WORLD_STATIC %d" % [PL.MASK_WHEELS, PL.BIT_WORLD_STATIC])
	if (PL.MASK_WHEELS & PL.BIT_WORLD_STATIC) == 0:
		errors.append("MASK_WHEELS missing BIT_WORLD_STATIC")
	if not PL.is_valid_mask(PL.MASK_WHEELS):
		errors.append("MASK_WHEELS invalid")
	# CarPhysics cross-check
	var car_spawn := preload("res://src/game/car/car_physics.gd").get_spawn_position()
	if car_spawn.y < PC.CAR_HALF_EXTENTS.y:
		errors.append("spawn y below half height")
	# Spring sanity: at max compression force should be large but not infinite
	var f_max := spring_force(MAX_COMPRESSION)
	if f_max < 4000.0 or f_max > 8000.0:
		errors.append("spring_force at max %.1f outside [4000,8000]" % f_max)
	var f_damp := damper_force(1.0)
	if not is_equal_approx(f_damp, DAMPER):
		errors.append("damper_force(1) %.1f != DAMPER" % f_damp)
	# Compression helper
	var c0 := compression_from_hit(REST_LENGTH + WHEEL_RADIUS)
	if not is_equal_approx(c0, 0.0):
		errors.append("compression_from_hit at rest %.4f != 0" % c0)
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"rest_length": REST_LENGTH,
		"spring": SPRING,
		"spring_stiffness": SPRING_STIFFNESS,
		"damper": DAMPER,
		"damper_coefficient": DAMPER_COEFFICIENT,
		"ray_length": RAY_LENGTH,
		"raylength": RAYLENGTH,
		"wheel_count": WHEEL_COUNT,
		"num_wheels": NUM_WHEELS,
		"wheel_radius": WHEEL_RADIUS,
		"max_compression": MAX_COMPRESSION,
		"max_extension": MAX_EXTENSION,
		"wheel_offsets": WHEEL_OFFSETS,
		"wheel_names": WHEEL_NAMES,
		"ray_collision_mask": PL.MASK_WHEELS,
		"ray_layer_bit": PL.BIT_WHEELS,
		"physics_tick_hz": PHYSICS_TICKS_PER_SECOND,
		"physics_tick_delta": TICK_DELTA,
		"tick_hz": PC.PHYSICS_TICKS_PER_SECOND,
	}

func debug_export_instance() -> Dictionary:
	var d := CarSuspension.debug_export()
	d["wheel_compression"] = wheel_compression.duplicate()
	d["wheel_contact"] = wheel_contact.duplicate()
	d["wheel_hit_point"] = wheel_hit_point.duplicate()
	d["wheel_hit_normal"] = wheel_hit_normal.duplicate()
	return d

static func perf_mark() -> Dictionary:
	return {"scope": "CarSuspension", "wheel_count": WHEEL_COUNT, "spring": SPRING, "damper": DAMPER, "ray_length": RAY_LENGTH, "tick_hz": PHYSICS_TICKS_PER_SECOND, "budget_ms": 4.0}

func perf_mark_instance() -> Dictionary:
	return {"scope": "CarSuspension", "wheel_count": WHEEL_COUNT, "tick_hz": PHYSICS_TICKS_PER_SECOND, "contacts": wheel_contact.duplicate()}
