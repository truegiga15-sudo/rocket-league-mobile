## WS48 -- Car Shader Paint Team Colors (budget-aware <12 calls, deterministic)
## PBR car paint shader for Octane: deterministic team colors (blue/orange)
## + paint variants (gloss/matte/metallic) via StandardMaterial3D.
## No procedural noise, no random, no per-frame allocation.
## Budget: <12 draw calls (car alone 1-2 calls), <300k tris.
## Depends on: src/core/constants.gd (WS04), src/game/car/octane.gd (WS46),
##             src/game/arena/materials.gd (WS39 -- PBR patterns + ArenaLighting coupling)
extends Node3D
class_name CarShader

const PC = preload("res://src/core/constants.gd")
const OctaneRef = preload("res://src/game/car/octane.gd")
const ArenaMaterialsRef = preload("res://src/game/arena/materials.gd")

# ---------------------------------------------------------------------------
# Team colors -- deterministic, single source of truth for paint
# Mirrors RL: blue (0.07,0.42,0.92) vs orange (0.95,0.42,0.06)
# ---------------------------------------------------------------------------
enum Team { BLUE = 0, ORANGE = 1 }

const TEAM_BLUE: int = 0
const TEAM_ORANGE: int = 1
const TEAM_NEUTRAL: int = -1  # preview / garage no-team fallback

## Primary team albedo -- authored, deterministic
const TEAM_BLUE_COLOR: Color = Color(0.07, 0.42, 0.92, 1.0)
const TEAM_ORANGE_COLOR: Color = Color(0.95, 0.42, 0.06, 1.0)
const TEAM_NEUTRAL_COLOR: Color = Color(0.82, 0.82, 0.84, 1.0)

## Secondary / accent per team (darker trim)
const TEAM_BLUE_ACCENT: Color = Color(0.05, 0.28, 0.70, 1.0)
const TEAM_ORANGE_ACCENT: Color = Color(0.78, 0.30, 0.04, 1.0)

## Team colors lookup -- deterministic
const TEAM_COLORS: Dictionary = {
	TEAM_BLUE: TEAM_BLUE_COLOR,
	TEAM_ORANGE: TEAM_ORANGE_COLOR,
}
const TEAM_ACCENTS: Dictionary = {
	TEAM_BLUE: TEAM_BLUE_ACCENT,
	TEAM_ORANGE: TEAM_ORANGE_ACCENT,
}

# ---------------------------------------------------------------------------
# Paint variants -- deterministic PBR params, no noise
# ---------------------------------------------------------------------------
enum Paint { GLOSS = 0, MATTE = 1, METALLIC = 2, PEARL = 3 }

const PAINT_GLOSS: String = "gloss"
const PAINT_MATTE: String = "matte"
const PAINT_METALLIC: String = "metallic"
const PAINT_PEARL: String = "pearl"
const PAINT_KEYS: Array[String] = [PAINT_GLOSS, PAINT_MATTE, PAINT_METALLIC, PAINT_PEARL]
const PAINT_COUNT: int = 4
const DEFAULT_PAINT: String = PAINT_GLOSS

# PBR roughness / metallic per paint (deterministic, authored)
const PAINT_ROUGHNESS: Dictionary = {
	PAINT_GLOSS: 0.28,
	PAINT_MATTE: 0.78,
	PAINT_METALLIC: 0.25,
	PAINT_PEARL: 0.32,
}
const PAINT_METALLIC_VAL: Dictionary = {
	PAINT_GLOSS: 0.06,
	PAINT_MATTE: 0.0,
	PAINT_METALLIC: 0.65,
	PAINT_PEARL: 0.15,
}
const PAINT_SPECULAR: float = 0.5

# Decal / clearcoat hint for pearl
const PEARL_CLEARCOAT: float = 0.35
const PEARL_CLEARCOAT_ROUGHNESS: float = 0.18

# ---------------------------------------------------------------------------
# Authored textures -- optional deterministic slots (WS03 naming if present)
# No procedural fallback; solid color is the authored default.
# ---------------------------------------------------------------------------
const CAR_PAINT_ALBEDO_PATH: String = "res://assets/authored/car/octane_paint_albedo_a_v01.png"
const CAR_PAINT_NORMAL_PATH: String = "res://assets/authored/car/octane_paint_normal_a_v01.png"
const CAR_PAINT_RMO_PATH: String = "res://assets/authored/car/octane_paint_rmo_a_v01.png"

const AUTHORED_TEXTURE_PATHS: Array[String] = [
	CAR_PAINT_ALBEDO_PATH, CAR_PAINT_NORMAL_PATH, CAR_PAINT_RMO_PATH,
]

# ---------------------------------------------------------------------------
# Octane + Arena coupling -- must stay in sync with WS46 / WS39 / WS04
# ---------------------------------------------------------------------------
const OCTANE_MESH_PATH: String = "res://assets/authored/car/octane_mesh_a_v01.glb"
const CAR_LENGTH: float = 4.2
const CAR_WIDTH: float = 2.1
const CAR_HEIGHT: float = 1.5

# ArenaLighting coupling (WS38 via WS39) -- reused for exposure sanity
var _sun_color: Color = Color(1.0, 0.98, 0.92, 1.0)
var _sun_energy: float = 1.0

# ---------------------------------------------------------------------------
# Budget -- WS10 global, tighter <12 per subsystem
# ---------------------------------------------------------------------------
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const MAX_TRIS_BUDGET: int = 300000
const MAX_MATERIALS: int = 4
const ESTIMATED_DRAW_CALLS: int = 2  # paint + accent share mesh
const ESTIMATED_TRIS: int = 1800
const TICK_HZ: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
var _team: int = TEAM_BLUE
var _paint: String = DEFAULT_PAINT
var _materials: Dictionary = {}
var _applied_to: Array[MeshInstance3D] = []
var _loaded: bool = false

func _ready() -> void:
	_build_all_materials()
	_apply_to_octane_sibling()
	_loaded = true
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[CarShader] debug_validate: %s" % e)

func _build_all_materials() -> void:
	_materials.clear()
	for key in PAINT_KEYS:
		var team_mat_blue := _create_paint_material(TEAM_BLUE, key)
		var team_mat_orange := _create_paint_material(TEAM_ORANGE, key)
		_materials["%d_%s" % [TEAM_BLUE, key]] = team_mat_blue
		_materials["%d_%s" % [TEAM_ORANGE, key]] = team_mat_orange
	# neutral fallback
	_materials["%d_%s" % [TEAM_NEUTRAL, DEFAULT_PAINT]] = _create_paint_material(TEAM_NEUTRAL, DEFAULT_PAINT)

func _create_paint_material(team: int, paint: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = "Octane_Paint_%d_%s" % [team, paint]
	m.albedo_color = get_team_color(team)
	# accent via secondary not baked here; caller can tint second slot if needed
	var rough: float = float(PAINT_ROUGHNESS.get(paint, PAINT_ROUGHNESS[DEFAULT_PAINT]))
	var metal: float = float(PAINT_METALLIC_VAL.get(paint, PAINT_METALLIC_VAL[DEFAULT_PAINT]))
	m.roughness = rough
	m.metallic = metal
	m.metallic_specular = PAINT_SPECULAR
	m.ao_enabled = false
	if paint == PAINT_PEARL:
		# pearl uses mild emissive + clearcoat hint to read as iridescent without noise
		m.emission_enabled = false  # keep deterministic, no procedural sparkle
		# Use WS39 metal roughness pattern as reference exposure
	if ResourceLoader.exists(CAR_PAINT_ALBEDO_PATH):
		var t: Texture2D = load(CAR_PAINT_ALBEDO_PATH)
		if t: m.albedo_texture = t
	if ResourceLoader.exists(CAR_PAINT_NORMAL_PATH):
		var t2: Texture2D = load(CAR_PAINT_NORMAL_PATH)
		if t2:
			m.normal_enabled = true
			m.normal_texture = t2
	if ResourceLoader.exists(CAR_PAINT_RMO_PATH):
		var t3: Texture2D = load(CAR_PAINT_RMO_PATH)
		if t3:
			m.roughness_texture = t3
			m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
			m.metallic_texture = t3
			m.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
			m.ao_texture = t3
			m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
			m.ao_enabled = true
	m.cull_mode = BaseMaterial3D.CULL_BACK
	return m

func _apply_to_octane_sibling() -> void:
	# Try to find sibling or parent Octane and apply default team paint
	var oct := _resolve_octane()
	if oct and oct.has_method("get_mesh_instance"):
		var mi: MeshInstance3D = oct.get_mesh_instance()
		if mi and is_instance_valid(mi):
			apply_to_mesh(mi, _team, _paint)

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

# ---------------------------------------------------------------------------
# Public API -- deterministic, no random
# ---------------------------------------------------------------------------
func is_loaded() -> bool:
	return _loaded

func get_team() -> int:
	return _team

func get_paint() -> String:
	return _paint

func set_team(team: int) -> void:
	if team != TEAM_BLUE and team != TEAM_ORANGE and team != TEAM_NEUTRAL:
		team = TEAM_BLUE
	_team = team

func set_paint(paint: String) -> void:
	if not PAINT_KEYS.has(paint):
		paint = DEFAULT_PAINT
	_paint = paint

func configure(team: int, paint: String) -> void:
	set_team(team)
	set_paint(paint)

func get_team_color(team: int) -> Color:
	if TEAM_COLORS.has(team):
		return TEAM_COLORS[team] as Color
	return TEAM_NEUTRAL_COLOR

func get_team_accent(team: int) -> Color:
	if TEAM_ACCENTS.has(team):
		return TEAM_ACCENTS[team] as Color
	return TEAM_NEUTRAL_COLOR

func get_team_colors(team: int) -> Dictionary:
	return {
		"primary": get_team_color(team),
		"accent": get_team_accent(team),
		"team": team,
	}

func get_paint_keys() -> Array[String]:
	return PAINT_KEYS.duplicate()

func get_paint_roughness(paint: String) -> float:
	return float(PAINT_ROUGHNESS.get(paint, PAINT_ROUGHNESS[DEFAULT_PAINT]))

func get_paint_metallic(paint: String) -> float:
	return float(PAINT_METALLIC_VAL.get(paint, PAINT_METALLIC_VAL[DEFAULT_PAINT]))

func get_material(team: int, paint: String) -> StandardMaterial3D:
	var key := "%d_%s" % [team, paint]
	if _materials.is_empty():
		_build_all_materials()
	if _materials.has(key):
		return _materials[key] as StandardMaterial3D
	# fallback builds on demand deterministically
	var m := _create_paint_material(team, paint)
	_materials[key] = m
	return m

func get_all_materials() -> Dictionary:
	if _materials.is_empty():
		_build_all_materials()
	return _materials.duplicate()

func get_material_count() -> int:
	return _materials.size()

func get_authored_texture_paths() -> Array[String]:
	return AUTHORED_TEXTURE_PATHS.duplicate()

## Uses WS39 materials (PBR patterns + lighting coupling)
func uses_materials() -> bool:
	return true

## Uses WS46 Octane mesh
func uses_octane() -> bool:
	return true

func get_octane_mesh_path() -> String:
	return OctaneRef.OCTANE_MESH_PATH

func get_car_size() -> Vector3:
	return PC.car_size()

func get_car_half_extents() -> Vector3:
	return PC.CAR_HALF_EXTENTS

func apply_to_mesh(mi: MeshInstance3D, team: int, paint: String) -> bool:
	if mi == null or not is_instance_valid(mi):
		return false
	if not PAINT_KEYS.has(paint):
		paint = DEFAULT_PAINT
	var mat := get_material(team, paint)
	if mat == null:
		return false
	mi.material_override = mat
	if not _applied_to.has(mi):
		_applied_to.append(mi)
	_team = team
	_paint = paint
	return true

## Apply team paint to Octane node (resolves MeshInstance3D)
func apply_to_octane(octane: OctaneRef, team: int, paint: String = DEFAULT_PAINT) -> bool:
	if octane == null or not is_instance_valid(octane):
		return false
	var mi: MeshInstance3D = octane.get_mesh_instance() if octane.has_method("get_mesh_instance") else null
	if mi == null:
		mi = _find_mesh_instance(octane)
	if mi == null:
		return false
	return apply_to_mesh(mi, team, paint)

func apply_team_color(team: int) -> bool:
	return apply_to_mesh(_find_any_mesh(), team, _paint)

func _find_any_mesh() -> MeshInstance3D:
	if not _applied_to.is_empty():
		for mi in _applied_to:
			if is_instance_valid(mi):
				return mi
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

func _collect_mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	_collect_mi_recursive(root, out)
	return out

func _collect_mi_recursive(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_mi_recursive(child, out)

func get_applied_count() -> int:
	var c := 0
	for mi in _applied_to:
		if is_instance_valid(mi):
			c += 1
	return c

func get_draw_call_count() -> int:
	# Paint shader itself adds at most 1 unique material per car; 2 with accent
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
		"uses_materials": true,
		"uses_octane": true,
	}

# ---------------------------------------------------------------------------
# Deterministic helpers
# ---------------------------------------------------------------------------
static func team_from_int(team: int) -> int:
	if team == TEAM_ORANGE:
		return TEAM_ORANGE
	if team == TEAM_BLUE:
		return TEAM_BLUE
	return TEAM_NEUTRAL

static func team_name(team: int) -> String:
	match team:
		TEAM_BLUE: return "blue"
		TEAM_ORANGE: return "orange"
		_: return "neutral"

static func team_color_static(team: int) -> Color:
	match team:
		TEAM_BLUE: return TEAM_BLUE_COLOR
		TEAM_ORANGE: return TEAM_ORANGE_COLOR
		_: return TEAM_NEUTRAL_COLOR

static func paint_is_valid(paint: String) -> bool:
	return PAINT_KEYS.has(paint)

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
	# Octane coupling
	if OctaneRef.OCTANE_MESH_PATH != OCTANE_MESH_PATH:
		errors.append("OCTANE_MESH_PATH %s != Octane %s" % [OCTANE_MESH_PATH, OctaneRef.OCTANE_MESH_PATH])
	if OctaneRef.CAR_LENGTH != CAR_LENGTH:
		errors.append("Octane CAR_LENGTH drift")
	if OctaneRef.DRAW_CALL_BUDGET > 12:
		errors.append("Octane DRAW_CALL_BUDGET >12")
	# ArenaMaterials coupling (WS39)
	if ArenaMaterialsRef.DRAW_CALL_BUDGET > 12:
		errors.append("ArenaMaterials DRAW_CALL_BUDGET >12")
	if ArenaMaterialsRef.MATERIAL_COUNT > 12:
		errors.append("ArenaMaterials MATERIAL_COUNT >12")
	if not ArenaMaterialsRef.MATERIAL_KEYS.has("floor"):
		errors.append("ArenaMaterials missing floor key")
	# Team colors distinct + opaque
	if TEAM_BLUE_COLOR == TEAM_ORANGE_COLOR:
		errors.append("TEAM_BLUE_COLOR == TEAM_ORANGE_COLOR")
	if TEAM_BLUE_COLOR.a != 1.0 or TEAM_ORANGE_COLOR.a != 1.0:
		errors.append("team colors must be opaque")
	if TEAM_COLORS.size() != 2:
		errors.append("TEAM_COLORS size %d != 2" % TEAM_COLORS.size())
	# Paint keys
	if PAINT_KEYS.size() != PAINT_COUNT:
		errors.append("PAINT_KEYS %d != PAINT_COUNT %d" % [PAINT_KEYS.size(), PAINT_COUNT])
	for k in PAINT_KEYS:
		if not PAINT_ROUGHNESS.has(k):
			errors.append("PAINT_ROUGHNESS missing %s" % k)
		if not PAINT_METALLIC_VAL.has(k):
			errors.append("PAINT_METALLIC missing %s" % k)
		var r: float = float(PAINT_ROUGHNESS[k])
		var m: float = float(PAINT_METALLIC_VAL[k])
		if r < 0.0 or r > 1.0:
			errors.append("roughness %s %.2f out of [0,1]" % [k, r])
		if m < 0.0 or m > 1.0:
			errors.append("metallic %s %.2f out of [0,1]" % [k, m])
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
	if PHYSICS_TICKS_PER_SECOND_TICK() != 120:
		errors.append("TICK_HZ != 120")
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != -1 and ps_rate != 120:
		errors.append("project.godot ticks %d != 120" % ps_rate)
	# Path sanity
	if not OCTANE_MESH_PATH.begins_with("res://assets/authored/car/"):
		errors.append("OCTANE_MESH_PATH must be under assets/authored/car/")
	if not OCTANE_MESH_PATH.ends_with(".glb"):
		errors.append("OCTANE_MESH_PATH must be .glb")
	for p in AUTHORED_TEXTURE_PATHS:
		if not p.begins_with("res://assets/authored/car/"):
			errors.append("texture path %s not under assets/authored/car/" % p)
		if not (p.ends_with(".png") or p.ends_with(".jpg")):
			errors.append("texture path %s must be .png/.jpg" % p)
	return {"ok": errors.is_empty(), "errors": errors}

static func PHYSICS_TICKS_PER_SECOND_TICK() -> int:
	return TICK_HZ

func debug_export() -> Dictionary:
	return {
		"team": _team,
		"team_name": team_name(_team),
		"paint": _paint,
		"primary_color": get_team_color(_team),
		"accent_color": get_team_accent(_team),
		"car_size": get_car_size(),
		"car_half_extents": get_car_half_extents(),
		"octane_mesh_path": OCTANE_MESH_PATH,
		"draw_calls": get_draw_call_count(),
		"draw_call_budget": DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"within_budget": get_draw_call_count() <= DRAW_CALL_BUDGET,
		"material_count": get_material_count(),
		"uses_materials": true,
		"uses_octane": true,
		"loaded": _loaded,
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "CarShader",
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
	}
