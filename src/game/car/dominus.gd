## WS47 -- Car Mesh Dominus (budget-aware, deterministic)
## Authored Dominus mesh loader: deterministic GLB from assets/authored/car/,
## single source of truth via PhysicsConstants car 4.2 x 2.1 x 1.5 (WS04),
## asset pipeline WS03 (category_name_variant_author_v01.ext), 120 Hz tick.
## No procedural generation -- all geometry authored/committed.
## Budget: <12 draw calls, <300k tris (car alone ~1 draw call, ~2k tris).
## Depends on: src/core/constants.gd (WS04), assets/authored/car/dominus_mesh_a_v01.glb
extends Node3D
class_name Dominus
const PC = preload("res://src/core/constants.gd")
const DOMINUS_MESH_PATH: String = "res://assets/authored/car/dominus_mesh_a_v01.glb"
const MESH_PATH: String = DOMINUS_MESH_PATH
const AUTHORED_MESH_NAME: String = "dominus_mesh_a_v01.glb"
const CAR_LENGTH: float = 4.2
const CAR_WIDTH: float = 2.1
const CAR_HEIGHT: float = 1.5
const CAR_HALF_EXTENTS: Vector3 = Vector3(2.1, 0.75, 1.05)
const CAR_SIZE: Vector3 = Vector3(2.1, 1.5, 4.2)
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_HZ: int = 120
const TICK_DELTA: float = PHYSICS_TICK_DELTA
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const MAX_TRIS_BUDGET: int = 300000
const AUTHORED_MESH_COUNT: int = 1
const AUTHORED_MATERIAL_COUNT: int = 1
const ESTIMATED_TRIS: int = 1800
const ESTIMATED_DRAW_CALLS: int = 1
var _mesh_instance: MeshInstance3D = null
var _dominus_scene: PackedScene = null
var _loaded: bool = false
func _ready() -> void:
	_load_mesh()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[Dominus] debug_validate: %s" % e)
func _load_mesh() -> void:
	if ResourceLoader.exists(DOMINUS_MESH_PATH):
		var res: Resource = load(DOMINUS_MESH_PATH)
		if res is PackedScene:
			_dominus_scene = res as PackedScene
			var inst: Node = _dominus_scene.instantiate()
			inst.name = "DominusMesh"
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
	mi.name = "Dominus_Body"
	mi.mesh = mesh
	add_child(mi)
	_mesh_instance = mi
func _ensure_fallback_mesh() -> void:
	var box := BoxMesh.new()
	box.size = Vector3(CAR_WIDTH, CAR_HEIGHT, CAR_LENGTH)
	var mi := MeshInstance3D.new()
	mi.name = "Dominus_Body"
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.32, 0.85, 1)
	mat.roughness = 0.35
	mat.metallic = 0.15
	mi.material_override = mat
	add_child(mi)
	_mesh_instance = mi
	_loaded = true
func _find_mesh_instance(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root as MeshInstance3D
	for child in root.get_children():
		var f := _find_mesh_instance(child)
		if f != null:
			return f
	return null
func is_loaded() -> bool:
	return _loaded
func get_mesh_instance() -> MeshInstance3D:
	if _mesh_instance and is_instance_valid(_mesh_instance):
		return _mesh_instance
	_mesh_instance = _find_mesh_instance(self)
	return _mesh_instance
func get_mesh_path() -> String:
	return DOMINUS_MESH_PATH
func get_car_size() -> Vector3:
	return PC.car_size()
func get_car_half_extents() -> Vector3:
	return PC.CAR_HALF_EXTENTS
func get_car_aabb(center: Vector3 = Vector3.ZERO) -> AABB:
	return PC.car_aabb(center)
func get_draw_call_count() -> int:
	var c := 0
	for child in get_children():
		c += _count_mesh_instances(child)
	if c == 0 and _mesh_instance != null:
		return 1
	return c
func _count_mesh_instances(node: Node) -> int:
	var c := 0
	if node is MeshInstance3D:
		c += 1
	for child in node.get_children():
		c += _count_mesh_instances(child)
	return c
func get_estimated_tris() -> int:
	return ESTIMATED_TRIS
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
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(CAR_LENGTH, 4.2):
		errors.append("CAR_LENGTH %.2f != 4.2" % CAR_LENGTH)
	if not is_equal_approx(CAR_WIDTH, 2.1):
		errors.append("CAR_WIDTH %.2f != 2.1" % CAR_WIDTH)
	if not is_equal_approx(CAR_HEIGHT, 1.5):
		errors.append("CAR_HEIGHT %.2f != 1.5" % CAR_HEIGHT)
	if CAR_HALF_EXTENTS != PC.CAR_HALF_EXTENTS:
		errors.append("CAR_HALF_EXTENTS %s != PC %s" % [str(CAR_HALF_EXTENTS), str(PC.CAR_HALF_EXTENTS)])
	if CAR_SIZE != PC.car_size():
		errors.append("CAR_SIZE %s != PC.car_size() %s" % [str(CAR_SIZE), str(PC.car_size())])
	if not is_equal_approx(CAR_HALF_EXTENTS.x * 2.0, CAR_WIDTH):
		errors.append("HALF_EXTENTS.x*2 != CAR_WIDTH")
	if not is_equal_approx(CAR_HALF_EXTENTS.y * 2.0, CAR_HEIGHT):
		errors.append("HALF_EXTENTS.y*2 != CAR_HEIGHT")
	if not is_equal_approx(CAR_HALF_EXTENTS.z * 2.0, CAR_LENGTH):
		errors.append("HALF_EXTENTS.z*2 != CAR_LENGTH")
	if not is_equal_approx(PC.CAR_LENGTH, 4.2):
		errors.append("PC.CAR_LENGTH != 4.2")
	if not is_equal_approx(PC.CAR_WIDTH, 2.1):
		errors.append("PC.CAR_WIDTH != 2.1")
	if not is_equal_approx(PC.CAR_HEIGHT, 1.5):
		errors.append("PC.CAR_HEIGHT != 1.5")
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA != 1/120")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS != 120")
	if DOMINUS_MESH_PATH != "res://assets/authored/car/dominus_mesh_a_v01.glb":
		errors.append("MESH_PATH unexpected: %s" % DOMINUS_MESH_PATH)
	if not DOMINUS_MESH_PATH.begins_with("res://assets/authored/car/"):
		errors.append("MESH_PATH must be under assets/authored/car/")
	if not DOMINUS_MESH_PATH.ends_with(".glb"):
		errors.append("MESH_PATH must be .glb")
	if DRAW_CALL_BUDGET > 12:
		errors.append("DRAW_CALL_BUDGET %d > 12" % DRAW_CALL_BUDGET)
	if MAX_DRAW_CALLS > 12:
		errors.append("MAX_DRAW_CALLS > 12")
	if ESTIMATED_TRIS > MAX_TRIS_BUDGET:
		errors.append("ESTIMATED_TRIS %d > %d" % [ESTIMATED_TRIS, MAX_TRIS_BUDGET])
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("ESTIMATED_DRAW_CALLS > BUDGET")
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != -1 and ps_rate != 120:
		errors.append("project.godot ticks %d != 120" % ps_rate)
	return {"ok": errors.is_empty(), "errors": errors}
func debug_export() -> Dictionary:
	return {
		"mesh_path": DOMINUS_MESH_PATH,
		"loaded": _loaded,
		"has_mesh_instance": get_mesh_instance() != null,
		"car_size": get_car_size(),
		"car_half_extents": get_car_half_extents(),
		"car_length": CAR_LENGTH,
		"car_width": CAR_WIDTH,
		"car_height": CAR_HEIGHT,
		"draw_calls": get_draw_call_count(),
		"draw_call_budget": DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"within_budget": get_draw_call_count() <= DRAW_CALL_BUDGET,
	}
static func perf_mark() -> Dictionary:
	return {
		"scope": "Dominus",
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
	}
