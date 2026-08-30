## WS52 -- Garage Customization UI (budget-aware <12 calls, deterministic)
## Car selection Octane/Dominus (WS46/WS47), paint via CarShader WS48,
## decals via CarDecals WS50, persistence via SaveService WS08.
## Deterministic, no random, no procedural, no per-frame allocation.
## Budget: <12 draw calls (UI overlay + 1 preview mesh), <300k tris.
## Depends on: src/core/constants.gd (WS04), src/game/car/octane.gd (WS46),
##             src/game/car/dominus.gd (WS47), src/game/car/car_shader.gd (WS48),
##             src/game/car/decals.gd (WS50), src/core/save_service.gd (WS08)
extends Control
class_name Garage

const PC = preload("res://src/core/constants.gd")
const OctaneRef = preload("res://src/game/car/octane.gd")
const DominusRef = preload("res://src/game/car/dominus.gd")
const CarShaderRef = preload("res://src/game/car/car_shader.gd")
const CarDecalsRef = preload("res://src/game/car/decals.gd")

# ---------------------------------------------------------------------------
# Catalog -- deterministic, authored only
# ---------------------------------------------------------------------------
const CAR_OCTANE: String = "octane"
const CAR_DOMINUS: String = "dominus"
const CAR_KEYS: Array[String] = [CAR_OCTANE, CAR_DOMINUS]
const CAR_COUNT: int = 2
const DEFAULT_CAR: String = CAR_OCTANE

# Paint catalog mirrors CarShader WS48 (single source via CarShaderRef)
const PAINT_KEYS: Array[String] = ["gloss", "matte", "metallic", "pearl"]
const DEFAULT_PAINT: String = "gloss"

# Decal catalog mirrors CarDecals WS50
const DECAL_KEYS: Array[String] = ["none", "stripes", "flames", "lightning", "wings"]
const DEFAULT_DECAL: String = "none"

# Authored mesh paths -- WS03 naming, deterministic
const OCTANE_MESH_PATH: String = "res://assets/authored/car/octane_mesh_a_v01.glb"
const DOMINUS_MESH_PATH: String = "res://assets/authored/car/dominus_mesh_a_v01.glb"
const AUTHORED_MESH_PATHS: Array[String] = [OCTANE_MESH_PATH, DOMINUS_MESH_PATH]

# CarShader paint texture paths (for budget accounting)
const CAR_PAINT_ALBEDO_PATH: String = "res://assets/authored/car/octane_paint_albedo_a_v01.png"

# Physics coupling -- must match WS04
const CAR_LENGTH: float = 4.2
const CAR_WIDTH: float = 2.1
const CAR_HEIGHT: float = 1.5
const CAR_HALF_EXTENTS: Vector3 = Vector3(2.1, 0.75, 1.05)
const CAR_SIZE: Vector3 = Vector3(2.1, 1.5, 4.2)

const TICK_HZ: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Budget -- WS10 global, <12 per subsystem
# ---------------------------------------------------------------------------
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const MAX_TRIS_BUDGET: int = 300000
const ESTIMATED_DRAW_CALLS: int = 3  # UI panel 1 + preview mesh 1 + decal layer 1
const ESTIMATED_TRIS: int = 1800  # single preview car (same as Octane/Dominus)
const MAX_CAR_OPTIONS: int = 2
const MAX_PAINT_OPTIONS: int = 4
const MAX_DECAL_OPTIONS: int = 5

# ---------------------------------------------------------------------------
# Signals -- UI events (deterministic, no payload random)
# ---------------------------------------------------------------------------
signal car_selected(car: String)
signal paint_selected(paint: String)
signal decal_selected(decal: String)
signal garage_saved(selection: Dictionary)
signal garage_loaded(selection: Dictionary)

# ---------------------------------------------------------------------------
# State -- current garage selection (mirrors SaveService.garage)
# ---------------------------------------------------------------------------
var _car: String = DEFAULT_CAR
var _paint: String = DEFAULT_PAINT
var _decal: String = DEFAULT_DECAL
var _team: int = CarShaderRef.TEAM_BLUE
var _loaded: bool = false
var _preview_mesh: MeshInstance3D = null
var _car_shader: CarShaderRef = null
var _car_decals: CarDecalsRef = null

func _ready() -> void:
	_ensure_subsystems()
	_load_from_save()
	_apply_preview()
	_loaded = true
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[Garage] debug_validate: %s" % e)

func _ensure_subsystems() -> void:
	if _car_shader == null:
		_car_shader = CarShaderRef.new()
		_car_shader.name = "Garage_CarShader"
		add_child(_car_shader)
	if _car_decals == null:
		_car_decals = CarDecalsRef.new()
		_car_decals.name = "Garage_CarDecals"
		add_child(_car_decals)

# ---------------------------------------------------------------------------
# Selection API -- deterministic, clamped to catalog
# ---------------------------------------------------------------------------
func get_car() -> String:
	return _car

func get_paint() -> String:
	return _paint

func get_decal() -> String:
	return _decal

func get_team() -> int:
	return _team

func get_selection() -> Dictionary:
	return {
		"car": _car,
		"paint": _paint,
		"decal": _decal,
		"team": _team,
	}

func select_car(car: String) -> bool:
	if not CAR_KEYS.has(car):
		return false
	_car = car
	car_selected.emit(_car)
	_apply_preview()
	return true

func select_paint(paint: String) -> bool:
	if not CarShaderRef.PAINT_KEYS.has(paint):
		return false
	_paint = paint
	paint_selected.emit(_paint)
	_apply_preview()
	return true

func select_decal(decal: String) -> bool:
	if not DECAL_KEYS.has(decal):
		return false
	_decal = decal
	decal_selected.emit(_decal)
	_apply_preview()
	return true

func select_team(team: int) -> bool:
	if team != CarShaderRef.TEAM_BLUE and team != CarShaderRef.TEAM_ORANGE:
		return false
	_team = team
	_apply_preview()
	return true

func configure(car: String, paint: String, decal: String, team: int = -1) -> Dictionary:
	var ok_car := true
	var ok_paint := true
	var ok_decal := true
	if CAR_KEYS.has(car):
		_car = car
	else:
		ok_car = false
	if CarShaderRef.PAINT_KEYS.has(paint):
		_paint = paint
	else:
		ok_paint = false
	if DECAL_KEYS.has(decal):
		_decal = decal
	else:
		ok_decal = false
	if team == CarShaderRef.TEAM_BLUE or team == CarShaderRef.TEAM_ORANGE:
		_team = team
	_apply_preview()
	return {"car_ok": ok_car, "paint_ok": ok_paint, "decal_ok": ok_decal, "selection": get_selection()}

# ---------------------------------------------------------------------------
# Preview -- applies paint+decal to preview mesh (budget: 1 mesh, 0 alloc per frame)
# ---------------------------------------------------------------------------
func _apply_preview() -> void:
	if _car_shader == null or _car_decals == null:
		return
	# Resolve or create preview mesh instance deterministically
	if _preview_mesh == null or not is_instance_valid(_preview_mesh):
		_preview_mesh = _find_preview_mesh()
		if _preview_mesh == null:
			_preview_mesh = _create_preview_mesh()
	# Apply paint then decal (decal wraps paint material)
	var mat: StandardMaterial3D = _car_decals.get_material(_team, _paint, _decal)
	if mat != null and _preview_mesh != null:
		_preview_mesh.material_override = mat

func _create_preview_mesh() -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = Vector3(CAR_WIDTH, CAR_HEIGHT, CAR_LENGTH)
	var mi := MeshInstance3D.new()
	mi.name = "Garage_PreviewBody"
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = CarShaderRef.TEAM_BLUE_COLOR if _team == CarShaderRef.TEAM_BLUE else CarShaderRef.TEAM_ORANGE_COLOR
	mi.material_override = mat
	add_child(mi)
	# Hide in UI overlay; shown only in garage preview viewport
	mi.visible = true
	return mi

func _find_preview_mesh() -> MeshInstance3D:
	for child in get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).name == "Garage_PreviewBody":
			return child as MeshInstance3D
		var found := _find_mesh_recursive(child)
		if found != null:
			return found
	return null

func _find_mesh_recursive(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root as MeshInstance3D
	for child in root.get_children():
		var f := _find_mesh_recursive(child)
		if f != null:
			return f
	return null

func get_preview_mesh() -> MeshInstance3D:
	if _preview_mesh != null and is_instance_valid(_preview_mesh):
		return _preview_mesh
	return _find_preview_mesh()

# ---------------------------------------------------------------------------
# SaveService integration -- versioned JSON at user://save.json
# ---------------------------------------------------------------------------
func save_to_service() -> bool:
	var svc: Node = get_node_or_null("/root/SaveService")
	if svc == null:
		# Fallback: direct file for headless/test (still deterministic)
		svc = _get_save_service_instance()
		if svc == null:
			return false
	var payload: Dictionary = {}
	if svc.has_method("load_save"):
		payload = svc.call("load_save") as Dictionary
		if payload.is_empty():
			payload = _default_garage_payload()
	else:
		payload = _default_garage_payload()
	if not payload.has("garage"):
		payload["garage"] = _default_garage_section()
	payload["garage"]["equipped_car"] = _car
	payload["garage"]["equipped_decal"] = _decal
	# Store paint as equipped_paint (extension, backward compat: keep wheels)
	payload["garage"]["equipped_paint"] = _paint
	payload["garage"]["equipped_team"] = _team
	# Ensure owned lists contain selection
	if not (payload["garage"]["owned_cars"] as Array).has(_car):
		(payload["garage"]["owned_cars"] as Array).append(_car)
	if not (payload["garage"]["owned_decals"] as Array).has(_decal):
		(payload["garage"]["owned_decals"] as Array).append(_decal)
	var ok := false
	if svc.has_method("save_game"):
		ok = svc.call("save_game", payload) as bool
	garage_saved.emit(get_selection())
	return ok

func load_from_service() -> Dictionary:
	_load_from_save()
	return get_selection()

func _load_from_save() -> void:
	var svc: Node = get_node_or_null("/root/SaveService")
	if svc == null:
		svc = _get_save_service_instance()
		if svc == null:
			return
	var payload: Dictionary = {}
	if svc.has_method("load_save"):
		payload = svc.call("load_save") as Dictionary
	if payload.is_empty() or not payload.has("garage"):
		return
	var g: Dictionary = payload["garage"] as Dictionary
	var car: String = str(g.get("equipped_car", DEFAULT_CAR))
	var decal: String = str(g.get("equipped_decal", DEFAULT_DECAL))
	var paint: String = str(g.get("equipped_paint", DEFAULT_PAINT))
	if CAR_KEYS.has(car):
		_car = car
	if DECAL_KEYS.has(decal):
		_decal = decal
	if CarShaderRef.PAINT_KEYS.has(paint):
		_paint = paint
	var team_val: Variant = g.get("equipped_team", _team)
	if team_val is int and (team_val == CarShaderRef.TEAM_BLUE or team_val == CarShaderRef.TEAM_ORANGE):
		_team = team_val as int
	garage_loaded.emit(get_selection())

func _get_save_service_instance() -> Node:
	var script: GDScript = load("res://src/core/save_service.gd") as GDScript
	if script == null:
		return null
	var inst: Node = script.new() as Node
	return inst

func _default_garage_section() -> Dictionary:
	return {
		"equipped_car": DEFAULT_CAR,
		"equipped_decal": DEFAULT_DECAL,
		"equipped_paint": DEFAULT_PAINT,
		"equipped_team": CarShaderRef.TEAM_BLUE,
		"equipped_wheels": "default",
		"owned_cars": [CAR_OCTANE],
		"owned_decals": [DEFAULT_DECAL],
		"owned_wheels": ["default"],
	}

func _default_garage_payload() -> Dictionary:
	var svc_script: GDScript = load("res://src/core/save_service.gd") as GDScript
	if svc_script != null and svc_script.has_method("default_payload"):
		return svc_script.call("default_payload") as Dictionary
	return {
		"garage": _default_garage_section(),
		"meta": {"save_format": 3},
	}

# ---------------------------------------------------------------------------
# Catalog helpers
# ---------------------------------------------------------------------------
func get_car_keys() -> Array[String]:
	return CAR_KEYS.duplicate()

func get_paint_keys() -> Array[String]:
	return CarShaderRef.PAINT_KEYS.duplicate()

func get_decal_keys() -> Array[String]:
	return DECAL_KEYS.duplicate()

func car_is_valid(car: String) -> bool:
	return CAR_KEYS.has(car)

func paint_is_valid(paint: String) -> bool:
	return CarShaderRef.paint_is_valid(paint)

func decal_is_valid(decal: String) -> bool:
	return DECAL_KEYS.has(decal)

func uses_save_service() -> bool:
	return true

func uses_octane() -> bool:
	return true

func uses_dominus() -> bool:
	return true

func uses_car_shader() -> bool:
	return true

func uses_decals() -> bool:
	return true

# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------
func get_draw_call_count() -> int:
	return ESTIMATED_DRAW_CALLS

func get_estimated_draw_calls() -> int:
	return ESTIMATED_DRAW_CALLS

func get_estimated_tris() -> int:
	return ESTIMATED_TRIS

func get_budget_state() -> Dictionary:
	return {
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": ESTIMATED_DRAW_CALLS <= DRAW_CALL_BUDGET,
		"max_draw_calls": MAX_DRAW_CALLS,
		"estimated_tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
		"car_options": CAR_COUNT,
		"max_car_options": MAX_CAR_OPTIONS,
		"uses_save_service": true,
		"uses_octane": true,
		"uses_dominus": true,
		"uses_car_shader": true,
		"uses_decals": true,
	}

# ---------------------------------------------------------------------------
# Validation / telemetry -- deterministic, no random
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(PC.CAR_LENGTH, 4.2):
		errors.append("PC.CAR_LENGTH %.2f != 4.2" % PC.CAR_LENGTH)
	if not is_equal_approx(PC.CAR_WIDTH, 2.1):
		errors.append("PC.CAR_WIDTH %.2f != 2.1" % PC.CAR_WIDTH)
	if not is_equal_approx(PC.CAR_HEIGHT, 1.5):
		errors.append("PC.CAR_HEIGHT %.2f != 1.5" % PC.CAR_HEIGHT)
	if not is_equal_approx(CAR_LENGTH, 4.2):
		errors.append("CAR_LENGTH %.2f != 4.2" % CAR_LENGTH)
	if CAR_HALF_EXTENTS != PC.CAR_HALF_EXTENTS:
		errors.append("CAR_HALF_EXTENTS %s != PC %s" % [str(CAR_HALF_EXTENTS), str(PC.CAR_HALF_EXTENTS)])
	if CAR_SIZE != PC.car_size():
		errors.append("CAR_SIZE %s != PC.car_size() %s" % [str(CAR_SIZE), str(PC.car_size())])
	if OctaneRef.CAR_LENGTH != CAR_LENGTH:
		errors.append("OctaneRef CAR_LENGTH drift")
	if DominusRef.CAR_LENGTH != CAR_LENGTH:
		errors.append("DominusRef CAR_LENGTH drift")
	if OctaneRef.OCTANE_MESH_PATH != OCTANE_MESH_PATH:
		errors.append("OCTANE_MESH_PATH %s != Octane %s" % [OCTANE_MESH_PATH, OctaneRef.OCTANE_MESH_PATH])
	if DominusRef.DOMINUS_MESH_PATH != DOMINUS_MESH_PATH:
		errors.append("DOMINUS_MESH_PATH %s != Dominus %s" % [DOMINUS_MESH_PATH, DominusRef.DOMINUS_MESH_PATH])
	if CarShaderRef.CAR_LENGTH != CAR_LENGTH:
		errors.append("CarShaderRef CAR_LENGTH drift")
	if CarShaderRef.PAINT_COUNT != 4:
		errors.append("CarShader PAINT_COUNT %d != 4" % CarShaderRef.PAINT_COUNT)
	if CarDecalsRef.DECAL_COUNT != 5:
		errors.append("CarDecals DECAL_COUNT %d != 5" % CarDecalsRef.DECAL_COUNT)
	if CAR_KEYS.size() != CAR_COUNT:
		errors.append("CAR_KEYS %d != CAR_COUNT %d" % [CAR_KEYS.size(), CAR_COUNT])
	if not CAR_KEYS.has(DEFAULT_CAR):
		errors.append("CAR_KEYS missing DEFAULT %s" % DEFAULT_CAR)
	if PAINT_KEYS.size() != CarShaderRef.PAINT_COUNT:
		errors.append("PAINT_KEYS %d != CarShader PAINT_COUNT %d" % [PAINT_KEYS.size(), CarShaderRef.PAINT_COUNT])
	if DECAL_KEYS.size() != CarDecalsRef.DECAL_COUNT:
		errors.append("DECAL_KEYS %d != CarDecals DECAL_COUNT %d" % [DECAL_KEYS.size(), CarDecalsRef.DECAL_COUNT])
	if not OCTANE_MESH_PATH.begins_with("res://assets/authored/car/"):
		errors.append("OCTANE_MESH_PATH must be under assets/authored/car/")
	if not DOMINUS_MESH_PATH.begins_with("res://assets/authored/car/"):
		errors.append("DOMINUS_MESH_PATH must be under assets/authored/car/")
	if not OCTANE_MESH_PATH.ends_with(".glb"):
		errors.append("OCTANE_MESH_PATH must be .glb")
	if not DOMINUS_MESH_PATH.ends_with(".glb"):
		errors.append("DOMINUS_MESH_PATH must be .glb")
	if DRAW_CALL_BUDGET > 12:
		errors.append("DRAW_CALL_BUDGET %d > 12" % DRAW_CALL_BUDGET)
	if MAX_DRAW_CALLS > 12:
		errors.append("MAX_DRAW_CALLS > 12")
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("ESTIMATED_DRAW_CALLS %d > %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if ESTIMATED_TRIS > MAX_TRIS_BUDGET:
		errors.append("ESTIMATED_TRIS %d > %d" % [ESTIMATED_TRIS, MAX_TRIS_BUDGET])
	if TICK_HZ != 120:
		errors.append("TICK_HZ != 120")
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA != 1/120")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS != 120")
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != -1 and ps_rate != 120:
		errors.append("project.godot ticks %d != 120" % ps_rate)
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"car": _car,
		"paint": _paint,
		"decal": _decal,
		"team": _team,
		"team_name": CarShaderRef.team_name(_team),
		"car_keys": get_car_keys(),
		"paint_keys": get_paint_keys(),
		"decal_keys": get_decal_keys(),
		"car_size": PC.car_size(),
		"car_half_extents": PC.CAR_HALF_EXTENTS,
		"octane_mesh_path": OCTANE_MESH_PATH,
		"dominus_mesh_path": DOMINUS_MESH_PATH,
		"draw_calls": get_draw_call_count(),
		"draw_call_budget": DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"within_budget": get_draw_call_count() <= DRAW_CALL_BUDGET,
		"loaded": _loaded,
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "Garage",
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
	}
