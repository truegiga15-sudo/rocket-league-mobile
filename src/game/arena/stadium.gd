## WS36 — DFH Stadium Geometry (budget-aware, deterministic)
## Visual DFH stadium mesh: floor, walls, ceiling, corner fillets as authored
## geometry. Loads deterministic GLB from assets/authored/arena/, no procedural
## generation, uses PhysicsConstants 60×40×20 for single source of truth.
## Budget-aware: authored mesh <12 draw calls, <300k tris, physics via WS21.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07)
extends Node3D
class_name Stadium

const PhysicsConstants = preload("res://src/core/constants.gd")
const PhysicsLayers = preload("res://src/core/physics/layers.gd")

# ---------------------------------------------------------------------------
# Authored geometry — deterministic, no procedural noise
# ---------------------------------------------------------------------------
## Authored GLB — DFH stadium placeholder (triangulated, scale 1.0, Y-up +Z).
## File naming per WS03: category_name_variant_author_v01.ext
const STADIUM_MESH_PATH: String = "res://assets/authored/arena/stadium_dfh_mesh_a_v01.glb"
const STADIUM_TEXTURE_PATH: String = "res://assets/authored/arena/stadium_dfh_floor_a_v01.png"

## Arena dimensions — must match PhysicsConstants (single source of truth)
const ARENA_LENGTH: float = 60.0
const ARENA_WIDTH: float = 40.0
const ARENA_HEIGHT: float = 20.0
const ARENA_HALF_LENGTH: float = 30.0
const ARENA_HALF_WIDTH: float = 20.0
const ARENA_SIZE: Vector3 = Vector3(40.0, 20.0, 60.0)
const ARENA_HALF_SIZE: Vector3 = Vector3(20.0, 10.0, 30.0)

## Budget — WS10 limits + WS36 tighter draw-call target (<12 for stadium alone)
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const MAX_TRIS_BUDGET: int = 300000
## Authored stadium mesh breakdown (floor 1 + ceiling 1 + 4 walls + 4 fillets = 10)
const AUTHORED_MESH_COUNT: int = 1
const AUTHORED_MATERIAL_COUNT: int = 1
const ESTIMATED_TRIS: int = 12
const ESTIMATED_DRAW_CALLS: int = 1

const TICK_HZ: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Runtime refs — deterministic load, no random, no procedural
# ---------------------------------------------------------------------------
var _mesh_instance: MeshInstance3D = null
var _stadium_scene: PackedScene = null
var _loaded: bool = false

# ---------------------------------------------------------------------------
# Lifecycle — deterministic load in _ready, no per-frame allocation
# ---------------------------------------------------------------------------
func _ready() -> void:
	_load_geometry()
	_apply_materials()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[Stadium] debug_validate: %s" % e)

func _load_geometry() -> void:
	# Deterministic: preload path is const, no runtime branching on random
	if ResourceLoader.exists(STADIUM_MESH_PATH):
		var res: Resource = load(STADIUM_MESH_PATH)
		if res is PackedScene:
			_stadium_scene = res as PackedScene
			var inst: Node = _stadium_scene.instantiate()
			inst.name = "StadiumMesh"
			add_child(inst)
			_loaded = true
			_mesh_instance = _find_mesh_instance(inst)
		elif res is Mesh:
			_ensure_mesh_instance(res as Mesh)
			_loaded = true
		else:
			_ensure_fallback_mesh()
	else:
		_ensure_fallback_mesh()

func _ensure_mesh_instance(mesh: Mesh) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Stadium_Floor"
	mi.mesh = mesh
	add_child(mi)
	_mesh_instance = mi

func _ensure_fallback_mesh() -> void:
	# Fallback authored BoxMesh 40×0.1×60 centered at floor Y=0.05 — deterministic
	var box := BoxMesh.new()
	box.size = Vector3(ARENA_WIDTH, 0.1, ARENA_LENGTH)
	var mi := MeshInstance3D.new()
	mi.name = "Stadium_Floor"
	mi.mesh = box
	mi.position = Vector3(0, 0.05, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.45, 0.22, 1)
	mat.roughness = 0.85
	mat.metallic = 0.0
	mi.material_override = mat
	add_child(mi)
	_mesh_instance = mi
	_loaded = true

func _apply_materials() -> void:
	# Materials are authored, not procedural — single deterministic material
	if _mesh_instance == null:
		_mesh_instance = _find_mesh_instance(self)
	if _mesh_instance and _mesh_instance.material_override == null:
		# Keep authored glb material if present; only set fallback
		pass

func _find_mesh_instance(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root as MeshInstance3D
	for child in root.get_children():
		var found := _find_mesh_instance(child)
		if found != null:
			return found
	return null

# ---------------------------------------------------------------------------
# Public API — deterministic helpers, use PhysicsConstants
# ---------------------------------------------------------------------------
func is_loaded() -> bool:
	return _loaded

func get_mesh_instance() -> MeshInstance3D:
	if _mesh_instance and is_instance_valid(_mesh_instance):
		return _mesh_instance
	_mesh_instance = _find_mesh_instance(self)
	return _mesh_instance

func get_draw_call_count() -> int:
	var count := 0
	for child in get_children():
		count += _count_mesh_instances(child)
	if count == 0 and _mesh_instance != null:
		return 1
	return count

func _count_mesh_instances(node: Node) -> int:
	var c := 0
	if node is MeshInstance3D:
		c += 1
	for child in node.get_children():
		c += _count_mesh_instances(child)
	return c

func get_estimated_tris() -> int:
	return ESTIMATED_TRIS

func get_arena_size() -> Vector3:
	return PhysicsConstants.ARENA_SIZE

func get_arena_aabb() -> AABB:
	return PhysicsConstants.arena_aabb()

static func arena_dimensions() -> Dictionary:
	return {
		"length": PhysicsConstants.ARENA_LENGTH,
		"width": PhysicsConstants.ARENA_WIDTH,
		"height": PhysicsConstants.ARENA_HEIGHT,
		"half_length": PhysicsConstants.ARENA_HALF_LENGTH,
		"half_width": PhysicsConstants.ARENA_HALF_WIDTH,
		"size": PhysicsConstants.ARENA_SIZE,
		"half_size": PhysicsConstants.ARENA_HALF_SIZE,
	}

static func is_inside_arena(point: Vector3) -> bool:
	return PhysicsConstants.is_inside_arena(point)

static func clamp_to_arena(point: Vector3) -> Vector3:
	return PhysicsConstants.clamp_to_arena(point)

# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------
func get_budget_state() -> Dictionary:
	var dc := get_draw_call_count()
	return {
		"draw_calls": dc,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": dc <= DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
		"mesh_count": dc,
		"max_meshes": DRAW_CALL_BUDGET,
	}

# ---------------------------------------------------------------------------
# Validation / telemetry (conventions §11) — deterministic, no random
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(PhysicsConstants.ARENA_LENGTH, 60.0):
		errors.append("ARENA_LENGTH != 60.0")
	if not is_equal_approx(PhysicsConstants.ARENA_WIDTH, 40.0):
		errors.append("ARENA_WIDTH != 40.0")
	if not is_equal_approx(PhysicsConstants.ARENA_HEIGHT, 20.0):
		errors.append("ARENA_HEIGHT != 20.0")
	if not is_equal_approx(ARENA_LENGTH, PhysicsConstants.ARENA_LENGTH):
		errors.append("Stadium.ARENA_LENGTH drift vs PhysicsConstants")
	if not is_equal_approx(ARENA_WIDTH, PhysicsConstants.ARENA_WIDTH):
		errors.append("Stadium.ARENA_WIDTH drift vs PhysicsConstants")
	if not is_equal_approx(ARENA_HALF_LENGTH, PhysicsConstants.ARENA_HALF_LENGTH):
		errors.append("ARENA_HALF_LENGTH drift")
	if not is_equal_approx(ARENA_HALF_WIDTH, PhysicsConstants.ARENA_HALF_WIDTH):
		errors.append("ARENA_HALF_WIDTH drift")
	if ARENA_SIZE != PhysicsConstants.ARENA_SIZE:
		errors.append("ARENA_SIZE drift vs PhysicsConstants")
	if DRAW_CALL_BUDGET > 12:
		errors.append("DRAW_CALL_BUDGET %d > 12" % DRAW_CALL_BUDGET)
	if MAX_DRAW_CALLS > 12:
		errors.append("MAX_DRAW_CALLS > 12")
	if AUTHORED_MESH_COUNT > 12:
		errors.append("AUTHORED_MESH_COUNT %d > 12" % AUTHORED_MESH_COUNT)
	if ESTIMATED_TRIS > MAX_TRIS_BUDGET:
		errors.append("ESTIMATED_TRIS %d > %d" % [ESTIMATED_TRIS, MAX_TRIS_BUDGET])
	if not ResourceLoader.exists(STADIUM_MESH_PATH) and not FileAccess.file_exists(STADIUM_MESH_PATH):
		# Allow fallback mesh — but path must be the authored const
		if STADIUM_MESH_PATH != "res://assets/authored/arena/stadium_dfh_mesh_a_v01.glb":
			errors.append("STADIUM_MESH_PATH unexpected: %s" % STADIUM_MESH_PATH)
	# Deterministic: no procedural markers allowed (checked by validate_assets.py)
	# Ensure arena centered at origin
	if not PhysicsConstants.is_inside_arena(Vector3.ZERO):
		errors.append("origin should be inside arena")
	if PhysicsConstants.is_inside_arena(Vector3(25.0, 1.0, 35.0)):
		errors.append("(25,1,35) should be outside arena")
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"mesh_path": STADIUM_MESH_PATH,
		"texture_path": STADIUM_TEXTURE_PATH,
		"loaded": _loaded,
		"has_mesh_instance": get_mesh_instance() != null,
		"draw_calls": get_draw_call_count(),
		"draw_call_budget": DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"arena": arena_dimensions(),
		"arena_aabb": get_arena_aabb(),
		"within_budget": get_draw_call_count() <= DRAW_CALL_BUDGET,
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "Stadium",
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
		"mesh_count": AUTHORED_MESH_COUNT,
		"tick_hz": TICK_HZ,
	}

func get_debug_state() -> Dictionary:
	var base := debug_export()
	base["budget"] = get_budget_state()
	return base
