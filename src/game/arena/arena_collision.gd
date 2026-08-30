## WS21 — Arena Collision Geometry & Curved Walls
## Static arena collision: floor, walls, ceiling, curved fillets (MeshInstance + CollisionShape)
## plus out-of-bounds sensor (Area3D, layer 5) and inside-arena helpers.
## Depends on WS07 (PhysicsLayers, PhysicsConfig) and WS04 (PhysicsConstants).
## All dimensions meters, arena centered at origin, Y-up, right-handed.
extends Node3D
class_name ArenaCollision

const PhysicsConstants = preload("res://src/core/constants.gd")
const PhysicsLayers = preload("res://src/core/physics/layers.gd")
const PhysicsConfig = preload("res://src/core/physics/physics_config.gd")

# ---------------------------------------------------------------------------
# Authored geometry — deterministic, no procedural noise
# ---------------------------------------------------------------------------
## Wall thickness (m) — inset outside playable volume so inner face aligns to arena bounds.
const WALL_THICKNESS: float = 1.0
## Corner / fillet radius for smooth ball roll (floor-to-wall quarter-pipe).
const CORNER_RADIUS: float = 2.0
## Out-of-bounds sensor margin beyond arena AABB (m).
const OOB_MARGIN: float = 10.0
## Visual wall height — matches ARENA_HEIGHT (20 m) so ceiling is at Y=20.
const WALL_HEIGHT: float = 20.0  # == PhysicsConstants.ARENA_HEIGHT

# Signals for sensor integration (WS22, WS37 downstream)
signal out_of_bounds_entered(body: Node3D)
signal out_of_bounds_exited(body: Node3D)
signal body_entered_oob(body: Node3D)
signal body_exited_oob(body: Node3D)

# Node references (optional — helpers work without scene)
@onready var _static_body: StaticBody3D = get_node_or_null("ArenaStatic") as StaticBody3D
@onready var _oob_area: Area3D = get_node_or_null("OutOfBounds") as Area3D

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	# Wire OOB sensor signals if present in scene
	if _oob_area:
		if not _oob_area.body_entered.is_connected(_on_oob_entered):
			_oob_area.body_entered.connect(_on_oob_entered)
		if not _oob_area.body_exited.is_connected(_on_oob_exited):
			_oob_area.body_exited.connect(_on_oob_exited)
		# Ensure sensor is on correct layer/mask (defensive)
		_oob_area.collision_layer = PhysicsLayers.BIT_SENSORS
		_oob_area.collision_mask = PhysicsLayers.MASK_SENSORS
		_oob_area.monitoring = true
		_oob_area.monitorable = true
	if _static_body:
		_static_body.collision_layer = PhysicsLayers.BIT_WORLD_STATIC
		_static_body.collision_mask = PhysicsLayers.MASK_WORLD_STATIC
		# Defensive: apply physics material if not already set via .tscn
		if _static_body.physics_material_override == null:
			var mat := PhysicsMaterial.new()
			mat.friction = PhysicsConfig.FRICTION_WORLD_BALL
			mat.bounce = PhysicsConfig.RESTITUTION_WORLD_BALL
			_static_body.physics_material_override = mat


# ---------------------------------------------------------------------------
# Arena helpers — always use PhysicsConstants; never hardcode 60x40x20 elsewhere
# ---------------------------------------------------------------------------

## True if point is inside the playable arena volume (including boundary).
## Delegates to PhysicsConstants.is_inside_arena for single source of truth.
static func is_inside_arena(point: Vector3) -> bool:
	return PhysicsConstants.is_inside_arena(point)

## True if point is outside the playable volume.
static func is_out_of_bounds(point: Vector3) -> bool:
	return not is_inside_arena(point)

## Clamp a world point to the playable arena volume.
static func clamp_to_arena(point: Vector3) -> Vector3:
	return PhysicsConstants.clamp_to_arena(point)

## AABB of the playable arena volume (floor at Y=0, size 40x20x60).
static func get_arena_aabb() -> AABB:
	return PhysicsConstants.arena_aabb()

## AABB of the out-of-bounds sensor (arena AABB expanded by OOB_MARGIN).
## Used for sensor sizing and debug visualization.
static func get_oob_aabb() -> AABB:
	var aabb := get_arena_aabb()
	# Expand horizontally and vertically by margin; keep floor at -margin below
	return AABB(
		aabb.position - Vector3(OOB_MARGIN, OOB_MARGIN, OOB_MARGIN),
		aabb.size + Vector3(OOB_MARGIN * 2.0, OOB_MARGIN * 2.0, OOB_MARGIN * 2.0)
	)

## Closest point on the inner arena surface (useful for spawn/respawn).
static func closest_point_on_boundary(point: Vector3) -> Vector3:
	return clamp_to_arena(point)

## Returns dictionary with arena dimensions for UI/debug.
static func arena_dimensions() -> Dictionary:
	return {
		"length": PhysicsConstants.ARENA_LENGTH,
		"width": PhysicsConstants.ARENA_WIDTH,
		"height": PhysicsConstants.ARENA_HEIGHT,
		"half_length": PhysicsConstants.ARENA_HALF_LENGTH,
		"half_width": PhysicsConstants.ARENA_HALF_WIDTH,
		"half_height": PhysicsConstants.ARENA_HALF_HEIGHT,
		"size": PhysicsConstants.ARENA_SIZE,
		"half_size": PhysicsConstants.ARENA_HALF_SIZE,
		"wall_thickness": WALL_THICKNESS,
		"corner_radius": CORNER_RADIUS,
		"oob_margin": OOB_MARGIN,
	}

## Collision layer bit for the static arena body (layer 0 -> bit 1).
static func static_collision_layer() -> int:
	return PhysicsLayers.BIT_WORLD_STATIC

## Collision mask for the static arena body (collides with car_chassis | ball).
static func static_collision_mask() -> int:
	return PhysicsLayers.MASK_WORLD_STATIC

## Collision layer bit for the out-of-bounds sensor (layer 5 -> bit 32).
static func oob_collision_layer() -> int:
	return PhysicsLayers.BIT_SENSORS

## Collision mask for the out-of-bounds sensor (detects ball + car_chassis).
static func oob_collision_mask() -> int:
	return PhysicsLayers.MASK_SENSORS

# ---------------------------------------------------------------------------
# Instance helpers — operate on this node's sensor state
# ---------------------------------------------------------------------------

## Check if a body/node is currently overlapping the OOB sensor.
func is_body_out_of_bounds(body: Node) -> bool:
	if _oob_area == null:
		# Fallback to geometric test if no Area3D present
		if body is Node3D:
			return is_out_of_bounds((body as Node3D).global_position)
		return false
	return _oob_area.has_overlapping_bodies() and body in _oob_area.get_overlapping_bodies()

## Force-update collision layers from code (e.g. after scene reload).
func apply_collision_layers() -> void:
	if _static_body:
		_static_body.collision_layer = PhysicsLayers.BIT_WORLD_STATIC
		_static_body.collision_mask = PhysicsLayers.MASK_WORLD_STATIC
	if _oob_area:
		_oob_area.collision_layer = PhysicsLayers.BIT_SENSORS
		_oob_area.collision_mask = PhysicsLayers.MASK_SENSORS

# ---------------------------------------------------------------------------
# Sensor callbacks
# ---------------------------------------------------------------------------
func _on_oob_entered(body: Node3D) -> void:
	# Body entered the OOB detection volume — this is the extended arena box.
	# For true out-of-bounds (outside playable), double-check geometry.
	# Emit for WS37/WS58 downstream.
	out_of_bounds_entered.emit(body)
	body_entered_oob.emit(body)

func _on_oob_exited(body: Node3D) -> void:
	out_of_bounds_exited.emit(body)
	body_exited_oob.emit(body)

# ---------------------------------------------------------------------------
# Debug / telemetry (conventions §11)
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(PhysicsConstants.ARENA_LENGTH, 60.0):
		errors.append("ARENA_LENGTH != 60.0")
	if not is_equal_approx(PhysicsConstants.ARENA_WIDTH, 40.0):
		errors.append("ARENA_WIDTH != 40.0")
	if not is_equal_approx(PhysicsConstants.ARENA_HEIGHT, 20.0):
		errors.append("ARENA_HEIGHT != 20.0")
	if WALL_THICKNESS <= 0.0 or WALL_THICKNESS > 5.0:
		errors.append("WALL_THICKNESS out of sane range (0,5]")
	if CORNER_RADIUS <= 0.0 or CORNER_RADIUS > 5.0:
		errors.append("CORNER_RADIUS out of sane range (0,5]")
	if OOB_MARGIN < 1.0:
		errors.append("OOB_MARGIN < 1.0")
	# Origin must be inside
	if not is_inside_arena(Vector3.ZERO):
		errors.append("origin should be inside arena")
	# Point clearly outside must be out of bounds
	if not is_out_of_bounds(Vector3(25.0, 1.0, 35.0)):
		errors.append("(25,1,35) should be out of bounds")
	# Layer sanity
	if PhysicsLayers.BIT_WORLD_STATIC != 1:
		errors.append("BIT_WORLD_STATIC != 1")
	if PhysicsLayers.BIT_SENSORS != 32:
		errors.append("BIT_SENSORS != 32")
	if PhysicsLayers.MASK_SENSORS != (PhysicsLayers.BIT_BALL | PhysicsLayers.BIT_CAR_CHASSIS):
		errors.append("MASK_SENSORS mismatch")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"arena": arena_dimensions(),
		"aabb": get_arena_aabb(),
		"oob_aabb": get_oob_aabb(),
		"layers": {
			"static_layer": static_collision_layer(),
			"static_mask": static_collision_mask(),
			"static_mask_names": PhysicsLayers.mask_to_names(static_collision_mask()),
			"oob_layer": oob_collision_layer(),
			"oob_mask": oob_collision_mask(),
			"oob_mask_names": PhysicsLayers.mask_to_names(oob_collision_mask()),
		},
		"corner_radius": CORNER_RADIUS,
		"wall_thickness": WALL_THICKNESS,
		"oob_margin": OOB_MARGIN,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "ArenaCollision", "arena_size": PhysicsConstants.ARENA_SIZE, "oob_margin": OOB_MARGIN}

func get_debug_state() -> Dictionary:
	var base := debug_export()
	base["has_static_body"] = _static_body != null
	base["has_oob_area"] = _oob_area != null
	if _oob_area:
		base["oob_overlapping"] = _oob_area.get_overlapping_bodies().size()
	return base
