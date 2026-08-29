## WS04 — Authoritative Coordinate, Units & Scale Constants
## Single source of truth for all workstreams. No magic numbers elsewhere.
## Conventions: Y-up, right-handed, +Z forward, 1 unit = 1 meter, arena centered at origin.
## Physics tick: 120 Hz (project.godot: physics/common/physics_ticks_per_second)
extends RefCounted
class_name PhysicsConstants

# ---------------------------------------------------------------------------
# Basis / Handedness
# ---------------------------------------------------------------------------
## Engine basis: Godot 4.x is right-handed, Y-up. We standardize:
##   +X = right (east), +Y = up, +Z = forward (south when facing goal).
##   Arena centered at Vector3.ZERO. Facing +Z is the default forward.
const UP := Vector3(0, 1, 0)
const FORWARD := Vector3(0, 0, 1)
const RIGHT := Vector3(1, 0, 0)

const HANDEDNESS := "right-handed"
const UP_AXIS := "Y"
const FORWARD_AXIS := "+Z"

# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------
## 1 Godot unit = 1 meter. All distances in meters, time in seconds,
## speeds in m/s, angles in radians unless suffixed _DEG.
const UNITS_PER_METER: float = 1.0
const METERS_PER_UNIT: float = 1.0

static func meters_to_units(m: float) -> float:
	return m * UNITS_PER_METER

static func units_to_meters(u: float) -> float:
	return u * METERS_PER_UNIT

# ---------------------------------------------------------------------------
# Time / Tick
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const DELTA_MIN: float = 1.0 / 240.0
const DELTA_MAX: float = 1.0 / 30.0

# ---------------------------------------------------------------------------
# Car — standard hitbox reference (Octane-like, meters)
# Sources: RL standard hitbox scaled 1:1. No procedural offsets.
# ---------------------------------------------------------------------------
const CAR_LENGTH: float = 4.2
const CAR_WIDTH: float = 2.1
const CAR_HEIGHT: float = 1.5
const CAR_HALF_EXTENTS := Vector3(2.1, 0.75, 1.05)  # half of (WIDTH, HEIGHT, LENGTH) mapped to (X,Y,Z) with Z=length
# Godot AABB helper: centered at origin, size = full extents
static func car_half_extents() -> Vector3:
	return CAR_HALF_EXTENTS
static func car_size() -> Vector3:
	return Vector3(CAR_WIDTH, CAR_HEIGHT, CAR_LENGTH)
static func car_aabb(center: Vector3 = Vector3.ZERO) -> AABB:
	return AABB(center - CAR_HALF_EXTENTS, car_size())

# ---------------------------------------------------------------------------
# Ball — meters
# ---------------------------------------------------------------------------
const BALL_DIAMETER: float = 1.82
const BALL_RADIUS: float = 0.91
const BALL_CIRCUMFERENCE: float = PI * 1.82  # ~5.7177

# ---------------------------------------------------------------------------
# Arena — meters, centered at origin on XZ plane, Y=0 is floor
# ---------------------------------------------------------------------------
const ARENA_LENGTH: float = 60.0  # Z axis (goal-to-goal)
const ARENA_WIDTH: float = 40.0   # X axis (side-to-side)
const ARENA_HEIGHT: float = 20.0  # Y axis (ceiling)
const ARENA_HALF_LENGTH: float = 30.0
const ARENA_HALF_WIDTH: float = 20.0
const ARENA_HALF_HEIGHT: float = 10.0  # half of ARENA_HEIGHT for convenience; actual ceiling at Y=20
const ARENA_SIZE := Vector3(40.0, 20.0, 60.0)  # (X=width, Y=height, Z=length)
const ARENA_HALF_SIZE := Vector3(20.0, 10.0, 30.0)

## AABB of playable volume (floor at Y=0)
static func arena_aabb() -> AABB:
	return AABB(Vector3(-ARENA_HALF_WIDTH, 0.0, -ARENA_HALF_LENGTH), ARENA_SIZE)

static func is_inside_arena(point: Vector3) -> bool:
	return (
		abs(point.x) <= ARENA_HALF_WIDTH
		and point.y >= 0.0 and point.y <= ARENA_HEIGHT
		and abs(point.z) <= ARENA_HALF_LENGTH
	)

# ---------------------------------------------------------------------------
# Goal — RL standard scaled 1:1 (meters), centered on each end wall
# ---------------------------------------------------------------------------
const GOAL_WIDTH: float = 7.3   # X opening
const GOAL_HEIGHT: float = 2.1  # Y opening
const GOAL_DEPTH: float = 2.0   # Z depth behind goal line
const GOAL_HALF_WIDTH: float = 3.65

## Goal centers on the arena walls (X=0, Y=GOAL_HEIGHT/2, Z=±HALF_LENGTH)
const GOAL_CENTER_Y: float = 1.05

static func goal_center(is_positive_z: bool) -> Vector3:
	var z := ARENA_HALF_LENGTH if is_positive_z else -ARENA_HALF_LENGTH
	return Vector3(0.0, GOAL_CENTER_Y, z)

static func goal_aabb(is_positive_z: bool) -> AABB:
	var center := goal_center(is_positive_z)
	# AABB from (center - half_size) with size (width, height, depth)
	var half := Vector3(GOAL_HALF_WIDTH, GOAL_HEIGHT * 0.5, GOAL_DEPTH * 0.5)
	var pos := center - half
	# extend depth outward from wall; for +Z goal depth is +Z, for -Z goal depth is -Z
	# Our AABB straddles the wall so detection works either side
	return AABB(pos, Vector3(GOAL_WIDTH, GOAL_HEIGHT, GOAL_DEPTH))

static func is_inside_goal(point: Vector3, is_positive_z: bool) -> bool:
	var aabb := goal_aabb(is_positive_z)
	return aabb.has_point(point)

# ---------------------------------------------------------------------------
# Conversion helpers — world <-> arena-local, grid, etc.
# ---------------------------------------------------------------------------
## Clamp a world position to the playable arena volume
static func clamp_to_arena(point: Vector3) -> Vector3:
	return Vector3(
		clamp(point.x, -ARENA_HALF_WIDTH, ARENA_HALF_WIDTH),
		clamp(point.y, 0.0, ARENA_HEIGHT),
		clamp(point.z, -ARENA_HALF_LENGTH, ARENA_HALF_LENGTH)
	)

## Normalize a world XZ position to UV in [0,1] (arena floor projection)
static func world_to_arena_uv(point: Vector3) -> Vector2:
	return Vector2(
		(point.x + ARENA_HALF_WIDTH) / ARENA_WIDTH,
		(point.z + ARENA_HALF_LENGTH) / ARENA_LENGTH
	)

static func arena_uv_to_world(uv: Vector2, y: float = 0.0) -> Vector3:
	return Vector3(
		uv.x * ARENA_WIDTH - ARENA_HALF_WIDTH,
		y,
		uv.y * ARENA_LENGTH - ARENA_HALF_LENGTH
	)

# ---------------------------------------------------------------------------
# Debug / validation — called by coordinate_test.gd
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(BALL_RADIUS * 2.0, BALL_DIAMETER):
		errors.append("BALL_RADIUS*2 != BALL_DIAMETER")
	if not is_equal_approx(CAR_HALF_EXTENTS.x * 2.0, CAR_WIDTH):
		errors.append("CAR_HALF_EXTENTS.x*2 != CAR_WIDTH")
	if not is_equal_approx(CAR_HALF_EXTENTS.y * 2.0, CAR_HEIGHT):
		errors.append("CAR_HALF_EXTENTS.y*2 != CAR_HEIGHT")
	if not is_equal_approx(CAR_HALF_EXTENTS.z * 2.0, CAR_LENGTH):
		errors.append("CAR_HALF_EXTENTS.z*2 != CAR_LENGTH")
	if not is_equal_approx(ARENA_HALF_WIDTH * 2.0, ARENA_WIDTH):
		errors.append("ARENA_HALF_WIDTH*2 != ARENA_WIDTH")
	if not is_equal_approx(ARENA_HALF_LENGTH * 2.0, ARENA_LENGTH):
		errors.append("ARENA_HALF_LENGTH*2 != ARENA_LENGTH")
	if GOAL_WIDTH > ARENA_WIDTH:
		errors.append("GOAL_WIDTH exceeds ARENA_WIDTH")
	if GOAL_HEIGHT > ARENA_HEIGHT:
		errors.append("GOAL_HEIGHT exceeds ARENA_HEIGHT")
	return {"ok": errors.is_empty(), "errors": errors}
