## WS50 -- Decals Texture Authoring (budget-aware <12 calls, deterministic)
## Authored decal overlay system for Octane: deterministic decal textures
## stacked on CarShader WS48 paint. No procedural, no random, no per-frame alloc.
## Budget: <12 draw calls (decals add 0-1 extra material layer), <300k tris.
## Depends on: src/core/constants.gd (WS04), src/game/car/octane.gd (WS46),
##             src/game/car/car_shader.gd (WS48), src/game/arena/materials.gd (WS39)
extends Node3D
class_name CarDecals

const PC = preload("res://src/core/constants.gd")
const OctaneRef = preload("res://src/game/car/octane.gd")
const CarShaderRef = preload("res://src/game/car/car_shader.gd")
const ArenaMaterialsRef = preload("res://src/game/arena/materials.gd")

# ---------------------------------------------------------------------------
# Decal catalog -- deterministic, authored textures only
# ---------------------------------------------------------------------------
const DECAL_NONE: String = "none"
const DECAL_STRIPES: String = "stripes"
const DECAL_FLAMES: String = "flames"
const DECAL_LIGHTNING: String = "lightning"
const DECAL_WINGS: String = "wings"

const DECAL_KEYS: Array[String] = [DECAL_NONE, DECAL_STRIPES, DECAL_FLAMES, DECAL_LIGHTNING, DECAL_WINGS]
const DECAL_COUNT: int = 5
const DEFAULT_DECAL: String = DECAL_NONE

# Authored decal textures -- WS03 naming: category_name_variant_author_v01.ext
# Solid-color fallback when file missing; never procedural.
const DECAL_STRIPES_PATH: String = "res://assets/authored/car/decal_stripes_a_v01.png"
const DECAL_FLAMES_PATH: String = "res://assets/authored/car/decal_flames_a_v01.png"
const DECAL_LIGHTNING_PATH: String = "res://assets/authored/car/decal_lightning_a_v01.png"
const DECAL_WINGS_PATH: String = "res://assets/authored/car/decal_wings_a_v01.png"

const DECAL_TEXTURE_PATHS: Dictionary = {
	DECAL_NONE: "",
	DECAL_STRIPES: DECAL_STRIPES_PATH,
	DECAL_FLAMES: DECAL_FLAMES_PATH,
	DECAL_LIGHTNING: DECAL_LIGHTNING_PATH,
	DECAL_WINGS: DECAL_WINGS_PATH,
}

const AUTHORED_TEXTURE_PATHS: Array[String] = [
	DECAL_STRIPES_PATH, DECAL_FLAMES_PATH, DECAL_LIGHTNING_PATH, DECAL_WINGS_PATH,
]

# CarShader paint textures reused (for validation / budget accounting, not duplication)
const CAR_PAINT_ALBEDO_PATH: String = CarShaderRef.CAR_PAINT_ALBEDO_PATH
const CAR_PAINT_NORMAL_PATH: String = CarShaderRef.CAR_PAINT_NORMAL_PATH

# ---------------------------------------------------------------------------
# Octane + CarShader coupling -- must stay in sync with WS46 / WS48 / WS04
# ---------------------------------------------------------------------------
const OCTANE_MESH_PATH: String = "res://assets/authored/car/octane_mesh_a_v01.glb"
const CAR_LENGTH: float = 4.2
const CAR_WIDTH: float = 2.1
const CAR_HEIGHT: float = 1.5

# Decal UV/tint defaults -- deterministic, authored placement
const DECAL_TINT_OPACITY: float = 1.0
const DECAL_UV_SCALE: Vector2 = Vector2(1.0, 1.0)
const DECAL_UV_OFFSET: Vector2 = Vector2(0.0, 0.0)

# ---------------------------------------------------------------------------
# Budget -- WS10 global, tighter <12 per subsystem
# ---------------------------------------------------------------------------
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const MAX_TRIS_BUDGET: int = 300000
const MAX_MATERIALS: int = 6  # 4 paints + decal variants within 12
const MAX_DECAL_TEXTURES: int = 4
const ESTIMATED_DRAW_CALLS: int = 1  # decals overlapped on same mesh, no extra pass (decal is texture swap)
const ESTIMATED_TRIS: int = 0  # decals reuse car mesh tris, no added geometry
const TICK_HZ: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
var _decal: String = DEFAULT_DECAL
var _team: int = CarShaderRef.TEAM_BLUE
var _paint: String = CarShaderRef.DEFAULT_PAINT
var _materials: Dictionary = {}
var _loaded: bool = false
var _car_shader: CarShaderRef = null

func _ready() -> void:
	_resolve_car_shader()
	_build_all_materials()
	_apply_to_octane_sibling()
	_loaded = true
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[CarDecals] debug_validate: %s" % e)

func _resolve_car_shader() -> CarShaderRef:
	var p := get_parent()
	if p:
		for child in p.get_children():
			if child is CarShaderRef:
				return child as CarShaderRef
		if p is CarShaderRef:
			return p as CarShaderRef
	for child in get_children():
		if child is CarShaderRef:
			return child as CarShaderRef
	# check sibling Octane -> parent may have CarShader
	if p:
		for child in p.get_children():
			if child is CarShaderRef:
				_car_shader = child as CarShaderRef
				return _car_shader
	return null

func _apply_to_octane_sibling() -> void:
	var oct := _resolve_octane()
	if oct and oct.has_method("get_mesh_instance"):
		var mi: MeshInstance3D = oct.get_mesh_instance()
		if mi and is_instance_valid(mi):
			apply_to_mesh(mi, _team, _paint, _decal)

func _resolve_octane() -> OctaneRef:
	var p := get_parent()
	if p:
		for child in p.get_children():
			if child is OctaneRef:
				return child as OctaneRef
		if p is OctaneRef:
			return p as OctaneRef
	for child in get_children():
		if child is OctaneRef:
			return child as OctaneRef
	return null

func _build_all_materials() -> void:
	_materials.clear()
	# Prebuild: each team + paint + decal combo uses CarShader base + decal texture
	# To keep within MAX_MATERIALS, we lazy-build via get_material; prebuild only default decal none + each decal for BLUE/gloss
	for decal in DECAL_KEYS:
		var key := "%d_%s_%s" % [CarShaderRef.TEAM_BLUE, CarShaderRef.DEFAULT_PAINT, decal]
		_materials[key] = _create_decal_material(CarShaderRef.TEAM_BLUE, CarShaderRef.DEFAULT_PAINT, decal)

func _create_decal_material(team: int, paint: String, decal: String) -> StandardMaterial3D:
	# Start from CarShader paint material params (deterministic, no duplication of logic)
	var base_rough: float = CarShaderRef.PAINT_ROUGHNESS.get(paint, CarShaderRef.PAINT_ROUGHNESS[CarShaderRef.DEFAULT_PAINT]) as float
	var base_metal: float = CarShaderRef.PAINT_METALLIC_VAL.get(paint, CarShaderRef.PAINT_METALLIC_VAL[CarShaderRef.DEFAULT_PAINT]) as float
	var m := StandardMaterial3D.new()
	m.resource_name = "Octane_Decal_%d_%s_%s" % [team, paint, decal]
	m.albedo_color = CarShaderRef.team_color_static(team)
	m.roughness = base_rough
	m.metallic = base_metal
	m.metallic_specular = CarShaderRef.PAINT_SPECULAR
	m.cull_mode = BaseMaterial3D.CULL_BACK
	m.ao_enabled = false
	# Authored decal texture overlay -- deterministic detail/secondary
	var decal_path: String = DECAL_TEXTURE_PATHS.get(decal, "") as String
	if decal != DECAL_NONE and decal_path != "" and ResourceLoader.exists(decal_path):
		var t: Texture2D = load(decal_path)
		if t:
			m.albedo_texture = t
			m.uv1_scale = DECAL_UV_SCALE
			m.uv1_offset = DECAL_UV_OFFSET
	elif decal == DECAL_NONE:
		# none keeps base paint albedo texture if present
		if ResourceLoader.exists(CAR_PAINT_ALBEDO_PATH):
			var tb: Texture2D = load(CAR_PAINT_ALBEDO_PATH)
			if tb:
				m.albedo_texture = tb
	else:
		# authored file not yet committed -- fall back to solid team color (deterministic, no noise)
		pass
	# Paint normal/RMO still applied if authored
	if ResourceLoader.exists(CAR_PAINT_NORMAL_PATH):
		var tn: Texture2D = load(CAR_PAINT_NORMAL_PATH)
		if tn:
			m.normal_enabled = true
			m.normal_texture = tn
	return m

# ---------------------------------------------------------------------------
# Public API -- deterministic, no random
# ---------------------------------------------------------------------------
func is_loaded() -> bool:
	return _loaded

func get_decal() -> String:
	return _decal

func get_team() -> int:
	return _team

func get_paint() -> String:
	return _paint

func set_decal(decal: String) -> void:
	if not DECAL_KEYS.has(decal):
		decal = DEFAULT_DECAL
	_decal = decal

func set_team(team: int) -> void:
	if team != CarShaderRef.TEAM_BLUE and team != CarShaderRef.TEAM_ORANGE and team != CarShaderRef.TEAM_NEUTRAL:
		team = CarShaderRef.TEAM_BLUE
	_team = team

func set_paint(paint: String) -> void:
	if not CarShaderRef.PAINT_KEYS.has(paint):
		paint = CarShaderRef.DEFAULT_PAINT
	_paint = paint

func configure(team: int, paint: String, decal: String) -> void:
	set_team(team)
	set_paint(paint)
	set_decal(decal)

func get_decal_keys() -> Array[String]:
	return DECAL_KEYS.duplicate()

func get_authored_texture_paths() -> Array[String]:
	return AUTHORED_TEXTURE_PATHS.duplicate()

func get_decal_texture_path(decal: String) -> String:
	return DECAL_TEXTURE_PATHS.get(decal, "") as String

static func decal_is_valid(decal: String) -> bool:
	return DECAL_KEYS.has(decal)

func uses_car_shader() -> bool:
	return true

func uses_octane() -> bool:
	return true

func get_octane_mesh_path() -> String:
	return OctaneRef.OCTANE_MESH_PATH

func get_car_size() -> Vector3:
	return PC.car_size()

func get_car_half_extents() -> Vector3:
	return PC.CAR_HALF_EXTENTS

func get_material(team: int, paint: String, decal: String) -> StandardMaterial3D:
	if not DECAL_KEYS.has(decal):
		decal = DEFAULT_DECAL
	if not CarShaderRef.PAINT_KEYS.has(paint):
		paint = CarShaderRef.DEFAULT_PAINT
	var key := "%d_%s_%s" % [team, paint, decal]
	if _materials.has(key):
		return _materials[key] as StandardMaterial3D
	var m := _create_decal_material(team, paint, decal)
	_materials[key] = m
	return m

func get_all_materials() -> Dictionary:
	return _materials.duplicate()

func get_material_count() -> int:
	return _materials.size()

func apply_to_mesh(mi: MeshInstance3D, team: int, paint: String, decal: String) -> bool:
	if mi == null or not is_instance_valid(mi):
		return false
	if not DECAL_KEYS.has(decal):
		decal = DEFAULT_DECAL
	var mat := get_material(team, paint, decal)
	if mat == null:
		return false
	mi.material_override = mat
	_team = team
	_paint = paint
	_decal = decal
	return true

func apply_to_octane(octane: OctaneRef, team: int, paint: String, decal: String) -> bool:
	if octane == null or not is_instance_valid(octane):
		return false
	var mi: MeshInstance3D = octane.get_mesh_instance() if octane.has_method("get_mesh_instance") else null
	if mi == null:
		mi = _find_mesh_instance(octane)
	if mi == null:
		return false
	return apply_to_mesh(mi, team, paint, decal)

func apply_decal(decal: String) -> bool:
	var mi := _find_any_mesh()
	if mi == null:
		return false
	return apply_to_mesh(mi, _team, _paint, decal)

func _find_any_mesh() -> MeshInstance3D:
	var oct := _resolve_octane()
	if oct:
		var mi: MeshInstance3D = oct.get_mesh_instance() if oct.has_method("get_mesh_instance") else null
		if mi and is_instance_valid(mi):
			return mi
		mi = _find_mesh_instance(oct)
		if mi:
			return mi
	return _find_mesh_instance(self)

func _find_mesh_instance(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root as MeshInstance3D
	for child in root.get_children():
		var f := _find_mesh_instance(child)
		if f != null:
			return f
	return null

func get_draw_call_count() -> int:
	return 1

func get_estimated_draw_calls() -> int:
	return ESTIMATED_DRAW_CALLS

func get_estimated_tris() -> int:
	return ESTIMATED_TRIS

func get_budget_state() -> Dictionary:
	return {
		"material_count": get_material_count(),
		"max_materials": MAX_MATERIALS,
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": ESTIMATED_DRAW_CALLS <= DRAW_CALL_BUDGET,
		"max_draw_calls": MAX_DRAW_CALLS,
		"estimated_tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
		"texture_count": AUTHORED_TEXTURE_PATHS.size(),
		"max_decal_textures": MAX_DECAL_TEXTURES,
		"uses_car_shader": true,
		"uses_octane": true,
	}

# ---------------------------------------------------------------------------
# Deterministic helpers
# ---------------------------------------------------------------------------
static func team_name(team: int) -> String:
	return CarShaderRef.team_name(team)

static func paint_is_valid(paint: String) -> bool:
	return CarShaderRef.paint_is_valid(paint)

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
	if not is_equal_approx(CAR_WIDTH, 2.1):
		errors.append("CAR_WIDTH drift")
	if not is_equal_approx(CAR_HEIGHT, 1.5):
		errors.append("CAR_HEIGHT drift")
	if CAR_LENGTH != PC.CAR_LENGTH:
		errors.append("CAR_LENGTH != PC.CAR_LENGTH")
	if not is_equal_approx(PC.CAR_HALF_EXTENTS.x * 2.0, PC.CAR_WIDTH):
		errors.append("PC CAR_HALF_EXTENTS.x*2 != CAR_WIDTH")
	# Octane coupling WS46
	if OctaneRef.OCTANE_MESH_PATH != OCTANE_MESH_PATH:
		errors.append("OCTANE_MESH_PATH %s != Octane %s" % [OCTANE_MESH_PATH, OctaneRef.OCTANE_MESH_PATH])
	if OctaneRef.CAR_LENGTH != CAR_LENGTH:
		errors.append("Octane CAR_LENGTH drift")
	if OctaneRef.DRAW_CALL_BUDGET > 12:
		errors.append("Octane DRAW_CALL_BUDGET >12")
	# CarShader coupling WS48
	if CarShaderRef.OCTANE_MESH_PATH != OCTANE_MESH_PATH:
		errors.append("CarShader OCTANE_MESH_PATH %s != %s" % [CarShaderRef.OCTANE_MESH_PATH, OCTANE_MESH_PATH])
	if CarShaderRef.CAR_LENGTH != CAR_LENGTH:
		errors.append("CarShader CAR_LENGTH drift")
	if CarShaderRef.DRAW_CALL_BUDGET > 12:
		errors.append("CarShader DRAW_CALL_BUDGET >12")
	if CarShaderRef.PAINT_COUNT != 4:
		errors.append("CarShader PAINT_COUNT %d != 4" % CarShaderRef.PAINT_COUNT)
	if not CarShaderRef.PAINT_KEYS.has("gloss"):
		errors.append("CarShader missing gloss")
	if CarShaderRef.TEAM_BLUE != 0 or CarShaderRef.TEAM_ORANGE != 1:
		errors.append("CarShader TEAM enum drift")
	if CarShaderRef.TEAM_BLUE_COLOR == CarShaderRef.TEAM_ORANGE_COLOR:
		errors.append("CarShader team colors identical")
	# ArenaMaterials coupling WS39
	if ArenaMaterialsRef.DRAW_CALL_BUDGET > 12:
		errors.append("ArenaMaterials DRAW_CALL_BUDGET >12")
	if ArenaMaterialsRef.MATERIAL_COUNT > 12:
		errors.append("ArenaMaterials MATERIAL_COUNT >12")
	# Decal catalog
	if DECAL_KEYS.size() != DECAL_COUNT:
		errors.append("DECAL_KEYS %d != DECAL_COUNT %d" % [DECAL_KEYS.size(), DECAL_COUNT])
	if not DECAL_KEYS.has(DECAL_NONE):
		errors.append("DECAL_KEYS missing none")
	if DECAL_TEXTURE_PATHS.size() != DECAL_COUNT:
		errors.append("DECAL_TEXTURE_PATHS %d != DECAL_COUNT %d" % [DECAL_TEXTURE_PATHS.size(), DECAL_COUNT])
	if AUTHORED_TEXTURE_PATHS.size() != MAX_DECAL_TEXTURES:
		errors.append("AUTHORED_TEXTURE_PATHS %d != MAX_DECAL_TEXTURES %d" % [AUTHORED_TEXTURE_PATHS.size(), MAX_DECAL_TEXTURES])
	for d in DECAL_KEYS:
		if not DECAL_TEXTURE_PATHS.has(d):
			errors.append("DECAL_TEXTURE_PATHS missing %s" % d)
	# Path sanity -- WS03
	if not OCTANE_MESH_PATH.begins_with("res://assets/authored/car/"):
		errors.append("OCTANE_MESH_PATH must be under assets/authored/car/")
	if not OCTANE_MESH_PATH.ends_with(".glb"):
		errors.append("OCTANE_MESH_PATH must be .glb")
	for p in AUTHORED_TEXTURE_PATHS:
		if not p.begins_with("res://assets/authored/car/"):
			errors.append("texture path %s not under assets/authored/car/" % p)
		if not (p.ends_with(".png") or p.ends_with(".jpg")):
			errors.append("texture path %s must be .png/.jpg" % p)
		if not p.contains("_a_v01."):
			errors.append("texture path %s must be WS03 _a_v01" % p)
	# Budget
	if DRAW_CALL_BUDGET > 12:
		errors.append("DRAW_CALL_BUDGET %d > 12" % DRAW_CALL_BUDGET)
	if MAX_DRAW_CALLS > 12:
		errors.append("MAX_DRAW_CALLS > 12")
	if MAX_MATERIALS > 12:
		errors.append("MAX_MATERIALS %d > 12" % MAX_MATERIALS)
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("ESTIMATED_DRAW_CALLS %d > %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if ESTIMATED_TRIS > MAX_TRIS_BUDGET:
		errors.append("ESTIMATED_TRIS %d > %d" % [ESTIMATED_TRIS, MAX_TRIS_BUDGET])
	if TICK_HZ != 120:
		errors.append("TICK_HZ != 120")
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA != 1/120")
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != -1 and ps_rate != 120:
		errors.append("project.godot ticks %d != 120" % ps_rate)
	return {"ok": errors.is_empty(), "errors": errors}

static func PHYSICS_TICKS_PER_SECOND_TICK() -> int:
	return TICK_HZ

func debug_export() -> Dictionary:
	return {
		"decal": _decal,
		"team": _team,
		"team_name": team_name(_team),
		"paint": _paint,
		"loaded": _loaded,
		"material_count": get_material_count(),
		"car_size": get_car_size(),
		"car_half_extents": get_car_half_extents(),
		"draw_calls": get_draw_call_count(),
		"draw_call_budget": DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"within_budget": get_draw_call_count() <= DRAW_CALL_BUDGET,
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "CarDecals",
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
	}
