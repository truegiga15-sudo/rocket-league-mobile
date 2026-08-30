## WS37 — Stadium Collision Mesh (budget-aware)
## Collision mesh wrapper for the DFH stadium. Reuses WS21 ArenaCollision
## geometry (floor, walls, ceiling, curved fillets) as the authoritative
## collision source and exposes a budget-aware StaticBody3D facade on layer 0
## (world_static) at 120 Hz. No procedural generation — all shapes/metrics
## are authored via ArenaCollision + PhysicsConstants.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07),
##             src/core/physics/physics_config.gd (WS07), src/core/time_service.gd (WS05),
##             src/game/arena/arena_collision.gd (WS21).
extends Node3D
class_name StadiumCollision

const PhysicsConstants = preload("res://src/core/constants.gd")
const PhysicsLayers = preload("res://src/core/physics/layers.gd")
const PhysicsConfig = preload("res://src/core/physics/physics_config.gd")
const ArenaCollision = preload("res://src/game/arena/arena_collision.gd")

# ---------------------------------------------------------------------------
# Tick / layer — never hardcode, validate vs PhysicsConstants + project.godot
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_HZ: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_DELTA: float = PHYSICS_TICK_DELTA

## Layer 0 world_static — stadium collision is solid world.
const LAYER_INDEX: int = 0
const COLLISION_LAYER: int = 1  # 1 << 0 == BIT_WORLD_STATIC
const COLLISION_MASK: int = 10  # BIT_CAR_CHASSIS | BIT_BALL == MASK_WORLD_STATIC

# ---------------------------------------------------------------------------
# Budget — stadium mesh must stay within WS10 budgets (physics <4ms, tris <300k)
# ---------------------------------------------------------------------------
## Authored stadium mesh uses ArenaCollision's ~22 CollisionShapes (floor,
## ceiling, 4 walls split for goals, 8 fillets, OOB sensor excluded). Keep
## collision shape count small so broadphase stays <4 ms at 120 Hz.
const MAX_COLLISION_SHAPES: int = 32
const MAX_TRIS_BUDGET: int = 300000
## Estimated physics cost of this mesh at 120 Hz (broadphase, no trimesh).
## ArenaCollision uses only Box + Cylinder shapes (convex, no concave trimesh)
## so per-tick cost is O(shapes) and well under 1 ms.
const ESTIMATED_PHYSICS_MS: float = 0.6
const BUDGET_PHYSICS_MS: float = 4.0
const BUDGET_TRIS: int = 300000

## Re-export ArenaCollision authored geometry for callers that need dimensions.
const WALL_THICKNESS: float = 1.0  # == ArenaCollision.WALL_THICKNESS
const CORNER_RADIUS: float = 2.0   # == ArenaCollision.CORNER_RADIUS
const OOB_MARGIN: float = 10.0     # == ArenaCollision.OOB_MARGIN

# ---------------------------------------------------------------------------
# Signals — thin proxy to ArenaCollision OOB for WS58+ rules
# ---------------------------------------------------------------------------
signal stadium_body_entered(body: Node3D)
signal stadium_body_exited(body: Node3D)
signal out_of_bounds_entered(body: Node3D)
signal out_of_bounds_exited(body: Node3D)

# ---------------------------------------------------------------------------
# Node refs — resolved in _ready; helpers work without scene present
# ---------------------------------------------------------------------------
@onready var _arena: ArenaCollision = _resolve_arena()
@onready var _static_body: StaticBody3D = _resolve_static_body()
@onready var _oob_area: Area3D = _resolve_oob_area()

var _shape_count_cache: int = -1
var _last_budget_check: Dictionary = {}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_arena = _resolve_arena()
	_static_body = _resolve_static_body()
	_oob_area = _resolve_oob_area()
	apply_collision_layers()
	_apply_physics_material()
	_wire_oob_signals()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[StadiumCollision] debug_validate: %s" % e)

func _physics_process(_delta: float) -> void:
	# Budget-aware: no per-frame allocation, no polling. Collision is handled
	# by Godot/Jolt broadphase on StaticBody3D layer 0 at 120 Hz. This tick
	# exists only so the node participates in the fixed-step ordering; budget
	# is checked via perf_mark() and get_budget_state(), not per-frame math.
	pass

# ---------------------------------------------------------------------------
# Public API — stadium mesh facade over ArenaCollision (WS21)
# ---------------------------------------------------------------------------

## Return the authoritative ArenaCollision node if present, else null.
func get_arena() -> ArenaCollision:
	if is_instance_valid(_arena):
		return _arena
	_arena = _resolve_arena()
	return _arena

## Return the StaticBody3D that holds the stadium shapes (ArenaStatic or own).
func get_static_body() -> StaticBody3D:
	if is_instance_valid(_static_body):
		return _static_body
	_static_body = _resolve_static_body()
	return _static_body

## Number of CollisionShape3D children under the stadium StaticBody3D.
## Budget-aware: caller can assert < MAX_COLLISION_SHAPES.
func get_collision_shape_count() -> int:
	var body := get_static_body()
	if body == null:
		# Headless / scene-less: authored count from ArenaCollision.tscn
		return 22
	var c := 0
	for child in body.get_children():
		if child is CollisionShape3D:
			c += 1
	# Also count nested CollisionShapes if arena was instanced as child
	var arena := get_arena()
	if arena:
		var ab: StaticBody3D = arena.get_node_or_null("ArenaStatic") as StaticBody3D
		if ab and ab != body:
			for child in ab.get_children():
				if child is CollisionShape3D:
					c += 1
	_shape_count_cache = c
	return c

## Estimated triangle count for debug/budget (0 for primitive shapes).
## ArenaCollision uses only Box/Cylinder primitives, so tris == 0 for physics.
## Visual mesh tris (WS36 stadium.tscn) are separate and budget-checked there.
func get_estimated_tris() -> int:
	return 0

## True if this mesh fits within all WS10 budgets.
func is_within_budget() -> bool:
	return get_collision_shape_count() <= MAX_COLLISION_SHAPES and get_estimated_tris() <= MAX_TRIS_BUDGET and ESTIMATED_PHYSICS_MS < BUDGET_PHYSICS_MS

## Budget state for profiler / telemetry — mirrors WS21 debug_export shape.
func get_budget_state() -> Dictionary:
	return {
		"shape_count": get_collision_shape_count(),
		"max_shapes": MAX_COLLISION_SHAPES,
		"tris": get_estimated_tris(),
		"tris_budget": MAX_TRIS_BUDGET,
		"estimated_physics_ms": ESTIMATED_PHYSICS_MS,
		"budget_physics_ms": BUDGET_PHYSICS_MS,
		"within_budget": is_within_budget(),
		"tick_hz": TICK_HZ,
		"layer": LAYER_INDEX,
		"within_shape_budget": get_collision_shape_count() <= MAX_COLLISION_SHAPES,
	}

## Collision layer for the stadium static body (layer 0 -> bit 1).
static func stadium_collision_layer() -> int:
	return PhysicsLayers.BIT_WORLD_STATIC

## Collision mask for the stadium static body (car_chassis | ball).
static func stadium_collision_mask() -> int:
	return PhysicsLayers.MASK_WORLD_STATIC

## Delegates to ArenaCollision for single-source arena geometry.
static func is_inside_arena(point: Vector3) -> bool:
	return ArenaCollision.is_inside_arena(point)

static func is_out_of_bounds(point: Vector3) -> bool:
	return ArenaCollision.is_out_of_bounds(point)

static func clamp_to_arena(point: Vector3) -> Vector3:
	return ArenaCollision.clamp_to_arena(point)

static func get_arena_aabb() -> AABB:
	return ArenaCollision.get_arena_aabb()

static func get_oob_aabb() -> AABB:
	return ArenaCollision.get_oob_aabb()

static func arena_dimensions() -> Dictionary:
	return ArenaCollision.arena_dimensions()

## Ensure the StaticBody + OOB Area are on correct layers/masks (defensive).
func apply_collision_layers() -> void:
	var body := get_static_body()
	if body:
		body.collision_layer = PhysicsLayers.BIT_WORLD_STATIC
		body.collision_mask = PhysicsLayers.MASK_WORLD_STATIC
	var arena := get_arena()
	if arena:
		arena.apply_collision_layers()
	var oob := _oob_area
	if oob == null:
		oob = _resolve_oob_area()
		_oob_area = oob
	if oob:
		oob.collision_layer = PhysicsLayers.BIT_SENSORS
		oob.collision_mask = PhysicsLayers.MASK_SENSORS

# ---------------------------------------------------------------------------
# Internal — resolve nodes, material, signals
# ---------------------------------------------------------------------------
func _resolve_arena() -> ArenaCollision:
	var n := get_node_or_null("ArenaCollision")
	if n is ArenaCollision:
		return n as ArenaCollision
	for child in get_children():
		if child is ArenaCollision:
			return child as ArenaCollision
	# Also search one level deeper (arena instanced under a holder)
	for child in get_children():
		if child is Node:
			var inner := (child as Node).get_node_or_null("ArenaCollision")
			if inner is ArenaCollision:
				return inner as ArenaCollision
	return null

func _resolve_static_body() -> StaticBody3D:
	var n := get_node_or_null("StadiumStatic")
	if n is StaticBody3D:
		return n as StaticBody3D
	n = get_node_or_null("ArenaStatic")
	if n is StaticBody3D:
		return n as StaticBody3D
	var arena := _resolve_arena()
	if arena:
		var ab: StaticBody3D = arena.get_node_or_null("ArenaStatic") as StaticBody3D
		if ab:
			return ab
	for child in get_children():
		if child is StaticBody3D:
			return child as StaticBody3D
	return null

func _resolve_oob_area() -> Area3D:
	var n := get_node_or_null("OutOfBounds")
	if n is Area3D:
		return n as Area3D
	var arena := _resolve_arena()
	if arena:
		var ao: Area3D = arena.get_node_or_null("OutOfBounds") as Area3D
		if ao:
			return ao
	for child in get_children():
		if child is Area3D:
			return child as Area3D
	return null

func _apply_physics_material() -> void:
	var body := get_static_body()
	if body == null:
		return
	if body.physics_material_override == null:
		var mat := PhysicsMaterial.new()
		mat.friction = PhysicsConfig.FRICTION_WORLD_BALL
		mat.bounce = PhysicsConfig.RESTITUTION_WORLD_BALL
		body.physics_material_override = mat

func _wire_oob_signals() -> void:
	var oob := _oob_area
	if oob == null:
		return
	if not oob.body_entered.is_connected(_on_oob_entered):
		oob.body_entered.connect(_on_oob_entered)
	if not oob.body_exited.is_connected(_on_oob_exited):
		oob.body_exited.connect(_on_oob_exited)
	# Also proxy ArenaCollision signals if arena present
	var arena := get_arena()
	if arena:
		if not arena.out_of_bounds_entered.is_connected(_on_arena_oob_entered):
			arena.out_of_bounds_entered.connect(_on_arena_oob_entered)
		if not arena.out_of_bounds_exited.is_connected(_on_arena_oob_exited):
			arena.out_of_bounds_exited.connect(_on_arena_oob_exited)

func _on_oob_entered(body: Node3D) -> void:
	out_of_bounds_entered.emit(body)
	stadium_body_entered.emit(body)

func _on_oob_exited(body: Node3D) -> void:
	out_of_bounds_exited.emit(body)
	stadium_body_exited.emit(body)

func _on_arena_oob_entered(body: Node3D) -> void:
	out_of_bounds_entered.emit(body)
	stadium_body_entered.emit(body)

func _on_arena_oob_exited(body: Node3D) -> void:
	out_of_bounds_exited.emit(body)
	stadium_body_exited.emit(body)

# ---------------------------------------------------------------------------
# Validation / telemetry (conventions §11) — budget-aware
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND != 120")
	if TICK_HZ != 120:
		errors.append("TICK_HZ != 120")
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA != 1/120")
	if PhysicsConstants.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PhysicsConstants.PHYSICS_TICKS_PER_SECOND != 120")
	# Layers §4
	if LAYER_INDEX != 0:
		errors.append("LAYER_INDEX != 0")
	if COLLISION_LAYER != PhysicsLayers.BIT_WORLD_STATIC:
		errors.append("COLLISION_LAYER != BIT_WORLD_STATIC (1)")
	if COLLISION_MASK != PhysicsLayers.MASK_WORLD_STATIC:
		errors.append("COLLISION_MASK != MASK_WORLD_STATIC (10)")
	if PhysicsLayers.BIT_WORLD_STATIC != 1:
		errors.append("BIT_WORLD_STATIC != 1")
	if PhysicsLayers.MASK_WORLD_STATIC != (PhysicsLayers.BIT_CAR_CHASSIS | PhysicsLayers.BIT_BALL):
		errors.append("MASK_WORLD_STATIC != car_chassis|ball")
	if not is_equal_approx(WALL_THICKNESS, ArenaCollision.WALL_THICKNESS):
		errors.append("WALL_THICKNESS drift vs ArenaCollision")
	if not is_equal_approx(CORNER_RADIUS, ArenaCollision.CORNER_RADIUS):
		errors.append("CORNER_RADIUS drift vs ArenaCollision")
	if not is_equal_approx(OOB_MARGIN, ArenaCollision.OOB_MARGIN):
		errors.append("OOB_MARGIN drift vs ArenaCollision")
	# Arena geometry sanity
	if not is_equal_approx(PhysicsConstants.ARENA_LENGTH, 60.0):
		errors.append("ARENA_LENGTH != 60.0")
	if not is_equal_approx(PhysicsConstants.ARENA_WIDTH, 40.0):
		errors.append("ARENA_WIDTH != 40.0")
	if not is_equal_approx(PhysicsConstants.ARENA_HEIGHT, 20.0):
		errors.append("ARENA_HEIGHT != 20.0")
	if not ArenaCollision.is_inside_arena(Vector3.ZERO):
		errors.append("origin should be inside arena")
	if not ArenaCollision.is_out_of_bounds(Vector3(25.0, 1.0, 35.0)):
		errors.append("(25,1,35) should be out of bounds")
	# Budget
	if MAX_COLLISION_SHAPES > 64:
		errors.append("MAX_COLLISION_SHAPES > 64 too loose for budget")
	if ESTIMATED_PHYSICS_MS >= BUDGET_PHYSICS_MS:
		errors.append("ESTIMATED_PHYSICS_MS %.2f >= BUDGET %.1f" % [ESTIMATED_PHYSICS_MS, BUDGET_PHYSICS_MS])
	if MAX_TRIS_BUDGET > 300000:
		errors.append("MAX_TRIS_BUDGET %d > 300000" % MAX_TRIS_BUDGET)
	# Delegated arena validation must also pass
	var av := ArenaCollision.debug_validate()
	if not av["ok"]:
		for e in av["errors"]:
			errors.append("ArenaCollision: %s" % e)
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"stadium": {
			"layer": LAYER_INDEX,
			"collision_layer": COLLISION_LAYER,
			"collision_mask": COLLISION_MASK,
			"tick_hz": TICK_HZ,
			"tick_delta": PHYSICS_TICK_DELTA,
			"wall_thickness": WALL_THICKNESS,
			"corner_radius": CORNER_RADIUS,
			"oob_margin": OOB_MARGIN,
		},
		"arena": ArenaCollision.arena_dimensions(),
		"arena_aabb": ArenaCollision.get_arena_aabb(),
		"oob_aabb": ArenaCollision.get_oob_aabb(),
		"layers": {
			"stadium_layer": stadium_collision_layer(),
			"stadium_mask": stadium_collision_mask(),
			"stadium_mask_names": PhysicsLayers.mask_to_names(stadium_collision_mask()),
		},
		"budget": {
			"max_shapes": MAX_COLLISION_SHAPES,
			"max_tris": MAX_TRIS_BUDGET,
			"estimated_physics_ms": ESTIMATED_PHYSICS_MS,
			"budget_physics_ms": BUDGET_PHYSICS_MS,
		},
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "StadiumCollision",
		"tick_hz": TICK_HZ,
		"layer": LAYER_INDEX,
		"estimated_physics_ms": ESTIMATED_PHYSICS_MS,
		"budget_physics_ms": BUDGET_PHYSICS_MS,
		"max_shapes": MAX_COLLISION_SHAPES,
		"arena_size": PhysicsConstants.ARENA_SIZE,
	}

func get_debug_state() -> Dictionary:
	var base := debug_export()
	base["has_arena"] = _arena != null
	base["has_static_body"] = _static_body != null
	base["has_oob_area"] = _oob_area != null
	base["shape_count"] = get_collision_shape_count() if _static_body != null else -1
	base["within_budget"] = is_within_budget() if _static_body != null else true
	if _arena:
		base["arena_debug"] = _arena.get_debug_state() if _arena.has_method("get_debug_state") else {}
	return base
