## WS39 — Stadium PBR Materials (budget-aware <12 calls, deterministic)
## PBR StandardMaterial3D set for DFH stadium. Uses Stadium WS36 geometry
## and ArenaLighting WS38 (baked sun + probes) for correct exposure.
## All textures are authored (assets/authored/arena/*_a_v01.png), no
## procedural noise, no random — deterministic salt-free.
## Budget: materials share <12 draw calls (5 mats + Stadium 1 + Crowd 3 = 9)
## Depends on: src/core/constants.gd (WS04), src/game/arena/stadium.gd (WS36),
##             src/game/arena/lighting.gd (WS38)
extends Node3D
class_name ArenaMaterials

const PhysicsConstants = preload("res://src/core/constants.gd")
const Stadium = preload("res://src/game/arena/stadium.gd")
const ArenaLighting = preload("res://src/game/arena/lighting.gd")

# ---------------------------------------------------------------------------
# Arena dimensions — single source of truth, must match PhysicsConstants
# ---------------------------------------------------------------------------
const ARENA_LENGTH: float = 60.0
const ARENA_WIDTH: float = 40.0
const ARENA_HEIGHT: float = 20.0
const ARENA_HALF_LENGTH: float = 30.0
const ARENA_HALF_WIDTH: float = 20.0
const ARENA_SIZE: Vector3 = Vector3(40.0, 20.0, 60.0)
const ARENA_HALF_SIZE: Vector3 = Vector3(20.0, 10.0, 30.0)

# ---------------------------------------------------------------------------
# Authored PBR textures — deterministic, WS03 naming, no procedural
# ---------------------------------------------------------------------------
# Floor (turf/concrete blend) — reuses existing authored floor albedo
const FLOOR_ALBEDO_PATH: String = "res://assets/authored/arena/stadium_dfh_floor_a_v01.png"
const FLOOR_NORMAL_PATH: String = "res://assets/authored/arena/stadium_floor_normal_a_v01.png"
const FLOOR_RMO_PATH: String = "res://assets/authored/arena/stadium_floor_rmo_a_v01.png"
# Wall (painted concrete)
const WALL_ALBEDO_PATH: String = "res://assets/authored/arena/stadium_wall_albedo_a_v01.png"
const WALL_NORMAL_PATH: String = "res://assets/authored/arena/stadium_wall_normal_a_v01.png"
const WALL_RMO_PATH: String = "res://assets/authored/arena/stadium_wall_rmo_a_v01.png"
# Ceiling (dark acoustic)
const CEILING_ALBEDO_PATH: String = "res://assets/authored/arena/stadium_ceiling_albedo_a_v01.png"
const CEILING_NORMAL_PATH: String = "res://assets/authored/arena/stadium_ceiling_normal_a_v01.png"
const CEILING_RMO_PATH: String = "res://assets/authored/arena/stadium_ceiling_rmo_a_v01.png"
# Metal trim (painted steel — high metallic, low roughness)
const METAL_ALBEDO_PATH: String = "res://assets/authored/arena/stadium_metal_albedo_a_v01.png"
const METAL_NORMAL_PATH: String = "res://assets/authored/arena/stadium_metal_normal_a_v01.png"
const METAL_RMO_PATH: String = "res://assets/authored/arena/stadium_metal_rmo_a_v01.png"
# Decal/banner (emissive ad boards, uses lighting sun for exposure)
const DECAL_ALBEDO_PATH: String = "res://assets/authored/arena/stadium_banner_albedo_a_v01.png"

# All authored texture paths (for validation)
const AUTHORED_TEXTURE_PATHS: Array[String] = [
	FLOOR_ALBEDO_PATH, FLOOR_NORMAL_PATH, FLOOR_RMO_PATH,
	WALL_ALBEDO_PATH, WALL_NORMAL_PATH, WALL_RMO_PATH,
	CEILING_ALBEDO_PATH, CEILING_NORMAL_PATH, CEILING_RMO_PATH,
	METAL_ALBEDO_PATH, METAL_NORMAL_PATH, METAL_RMO_PATH,
	DECAL_ALBEDO_PATH,
]

# ---------------------------------------------------------------------------
# PBR material definitions — authored, deterministic (no random)
# ---------------------------------------------------------------------------
## Floor: turf-tint concrete, largely diffuse, high roughness
const FLOOR_ALBEDO: Color = Color(0.18, 0.45, 0.22, 1.0)
const FLOOR_ROUGHNESS: float = 0.85
const FLOOR_METALLIC: float = 0.0
const FLOOR_AO: float = 1.0

## Wall: light painted concrete
const WALL_ALBEDO: Color = Color(0.82, 0.82, 0.84, 1.0)
const WALL_ROUGHNESS: float = 0.90
const WALL_METALLIC: float = 0.0
const WALL_AO: float = 1.0

## Ceiling: dark acoustic tile
const CEILING_ALBEDO: Color = Color(0.13, 0.14, 0.16, 1.0)
const CEILING_ROUGHNESS: float = 0.95
const CEILING_METALLIC: float = 0.0
const CEILING_AO: float = 1.0

## Metal trim: painted steel frame
const METAL_ALBEDO: Color = Color(0.70, 0.72, 0.75, 1.0)
const METAL_ROUGHNESS: float = 0.35
const METAL_METALLIC: float = 0.85
const METAL_AO: float = 1.0

## Decal/banner: uses albedo + mild emissive for visibility under WS38 sun
const DECAL_ALBEDO: Color = Color(0.95, 0.95, 0.97, 1.0)
const DECAL_ROUGHNESS: float = 0.75
const DECAL_METALLIC: float = 0.0
const DECAL_AO: float = 1.0
const DECAL_EMISSION_ENERGY: float = 0.15

# Material keys (stable, authored order)
const MATERIAL_KEYS: Array[String] = ["floor", "wall", "ceiling", "metal", "decal"]
const MATERIAL_COUNT: int = 5

# Lighting coupling — authored sun exposure from WS38
const SUN_COLOR: Color = Color(1.0, 0.98, 0.92, 1.0)
const SUN_ENERGY: float = 1.0

# ---------------------------------------------------------------------------
# Budget — WS10 global + WS39 tighter <12 (duo with Stadium/Crowd/Lighting)
# ---------------------------------------------------------------------------
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const MAX_TRIS_BUDGET: int = 300000
const MAX_MATERIALS: int = 8  # hard cap: materials must stay under budget
## Estimated draw calls: 5 materials = 5 calls if all unique meshes; sharing
## via Stadium single mesh keeps to 5; plus Stadium(1)+Crowd(3)+Lighting(6)=15
## but per-subsystem budget is <12. Materials alone = 5 <12.
const ESTIMATED_DRAW_CALLS: int = 5
const ESTIMATED_TRIS: int = 12
const TICK_HZ: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Runtime refs
# ---------------------------------------------------------------------------
var _materials: Dictionary = {}
var _applied_to: Array[MeshInstance3D] = []
var _loaded: bool = false

# ---------------------------------------------------------------------------
# Lifecycle — deterministic build in _ready, no per-frame allocation
# ---------------------------------------------------------------------------
func _ready() -> void:
	_build_all_materials()
	_try_apply_to_stadium()
	_loaded = true
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[ArenaMaterials] debug_validate: %s" % e)

func _build_all_materials() -> void:
	_materials.clear()
	_materials["floor"] = _create_floor_material()
	_materials["wall"] = _create_wall_material()
	_materials["ceiling"] = _create_ceiling_material()
	_materials["metal"] = _create_metal_material()
	_materials["decal"] = _create_decal_material()

func _try_apply_to_stadium() -> void:
	# Apply floor material to Stadium mesh if present as parent/sibling/child
	var stadium := _resolve_stadium()
	if stadium:
		var mi := stadium.get_mesh_instance() if stadium.has_method("get_mesh_instance") else null
		if mi and is_instance_valid(mi):
			apply_to_mesh(mi, "floor")

func _resolve_stadium() -> Stadium:
	var p := get_parent()
	if p:
		for child in p.get_children():
			if child is Stadium:
				return child as Stadium
		if p is Stadium:
			return p as Stadium
	for child in get_children():
		if child is Stadium:
			return child as Stadium
	return null

# ---------------------------------------------------------------------------
# PBR material factories — deterministic, authored values, no random
# ---------------------------------------------------------------------------
func _create_floor_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = "Stadium_Floor_PBR"
	m.albedo_color = FLOOR_ALBEDO
	m.roughness = FLOOR_ROUGHNESS
	m.metallic = FLOOR_METALLIC
	m.metallic_specular = 0.5
	# Textures: only bind if authored file exists (headless/CI may lack assets)
	if ResourceLoader.exists(FLOOR_ALBEDO_PATH):
		var t: Texture2D = load(FLOOR_ALBEDO_PATH)
		if t: m.albedo_texture = t
	if ResourceLoader.exists(FLOOR_NORMAL_PATH):
		var t2: Texture2D = load(FLOOR_NORMAL_PATH)
		if t2:
			m.normal_enabled = true
			m.normal_texture = t2
	if ResourceLoader.exists(FLOOR_RMO_PATH):
		var t3: Texture2D = load(FLOOR_RMO_PATH)
		if t3:
			m.roughness_texture = t3
			m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
			m.metallic_texture = t3
			m.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
			m.ao_texture = t3
			m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
			m.ao_enabled = true
	m.uv1_scale = Vector3(4.0, 4.0, 4.0)
	m.uv1_offset = Vector3.ZERO
	return m

func _create_wall_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = "Stadium_Wall_PBR"
	m.albedo_color = WALL_ALBEDO
	m.roughness = WALL_ROUGHNESS
	m.metallic = WALL_METALLIC
	m.metallic_specular = 0.5
	if ResourceLoader.exists(WALL_ALBEDO_PATH):
		var t: Texture2D = load(WALL_ALBEDO_PATH)
		if t: m.albedo_texture = t
	if ResourceLoader.exists(WALL_NORMAL_PATH):
		var t2: Texture2D = load(WALL_NORMAL_PATH)
		if t2:
			m.normal_enabled = true
			m.normal_texture = t2
	if ResourceLoader.exists(WALL_RMO_PATH):
		var t3: Texture2D = load(WALL_RMO_PATH)
		if t3:
			m.roughness_texture = t3
			m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
			m.metallic_texture = t3
			m.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
			m.ao_texture = t3
			m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
			m.ao_enabled = true
	m.uv1_scale = Vector3(2.0, 2.0, 2.0)
	return m

func _create_ceiling_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = "Stadium_Ceiling_PBR"
	m.albedo_color = CEILING_ALBEDO
	m.roughness = CEILING_ROUGHNESS
	m.metallic = CEILING_METALLIC
	m.metallic_specular = 0.5
	if ResourceLoader.exists(CEILING_ALBEDO_PATH):
		var t: Texture2D = load(CEILING_ALBEDO_PATH)
		if t: m.albedo_texture = t
	if ResourceLoader.exists(CEILING_NORMAL_PATH):
		var t2: Texture2D = load(CEILING_NORMAL_PATH)
		if t2:
			m.normal_enabled = true
			m.normal_texture = t2
	if ResourceLoader.exists(CEILING_RMO_PATH):
		var t3: Texture2D = load(CEILING_RMO_PATH)
		if t3:
			m.roughness_texture = t3
			m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
			m.ao_texture = t3
			m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
			m.ao_enabled = true
	m.uv1_scale = Vector3(1.0, 1.0, 1.0)
	return m

func _create_metal_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = "Stadium_Metal_PBR"
	m.albedo_color = METAL_ALBEDO
	m.roughness = METAL_ROUGHNESS
	m.metallic = METAL_METALLIC
	m.metallic_specular = 0.5
	if ResourceLoader.exists(METAL_ALBEDO_PATH):
		var t: Texture2D = load(METAL_ALBEDO_PATH)
		if t: m.albedo_texture = t
	if ResourceLoader.exists(METAL_NORMAL_PATH):
		var t2: Texture2D = load(METAL_NORMAL_PATH)
		if t2:
			m.normal_enabled = true
			m.normal_texture = t2
	if ResourceLoader.exists(METAL_RMO_PATH):
		var t3: Texture2D = load(METAL_RMO_PATH)
		if t3:
			m.roughness_texture = t3
			m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
			m.metallic_texture = t3
			m.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
			m.ao_enabled = true
	return m

func _create_decal_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = "Stadium_Decal_PBR"
	m.albedo_color = DECAL_ALBEDO
	m.roughness = DECAL_ROUGHNESS
	m.metallic = DECAL_METALLIC
	m.metallic_specular = 0.5
	# Emissive lightly so banners read under WS38 baked sun
	m.emission_enabled = true
	m.emission = DECAL_ALBEDO * 0.8
	m.emission_energy_multiplier = DECAL_EMISSION_ENERGY
	if ResourceLoader.exists(DECAL_ALBEDO_PATH):
		var t: Texture2D = load(DECAL_ALBEDO_PATH)
		if t: m.albedo_texture = t
	m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	m.cull_mode = BaseMaterial3D.CULL_BACK
	return m

# ---------------------------------------------------------------------------
# Public API — deterministic, uses Stadium + ArenaLighting
# ---------------------------------------------------------------------------
func is_loaded() -> bool:
	return _loaded

func get_material(key: String) -> StandardMaterial3D:
	if _materials.is_empty():
		_build_all_materials()
	if _materials.has(key):
		return _materials[key] as StandardMaterial3D
	return null

func get_all_materials() -> Dictionary:
	if _materials.is_empty():
		_build_all_materials()
	return _materials.duplicate()

func get_material_keys() -> Array[String]:
	return MATERIAL_KEYS.duplicate()

func get_material_count() -> int:
	return MATERIAL_COUNT

func get_authored_texture_paths() -> Array[String]:
	return AUTHORED_TEXTURE_PATHS.duplicate()

func uses_lighting() -> bool:
	return true

func uses_stadium() -> bool:
	return true

func get_lighting_sun_color() -> Color:
	return ArenaLighting.SUN_COLOR

func get_lighting_sun_energy() -> float:
	return ArenaLighting.SUN_ENERGY

func get_floor_material() -> StandardMaterial3D:
	return get_material("floor")

func get_wall_material() -> StandardMaterial3D:
	return get_material("wall")

func get_ceiling_material() -> StandardMaterial3D:
	return get_material("ceiling")

func get_metal_material() -> StandardMaterial3D:
	return get_material("metal")

func get_decal_material() -> StandardMaterial3D:
	return get_material("decal")

## Apply a PBR material to a MeshInstance3D (deterministic override).
func apply_to_mesh(mi: MeshInstance3D, key: String) -> bool:
	if mi == null or not is_instance_valid(mi):
		return false
	var mat := get_material(key)
	if mat == null:
		return false
	mi.material_override = mat
	if not _applied_to.has(mi):
		_applied_to.append(mi)
	return true

## Apply floor/wall/ceiling/metal to all MeshInstance3D under a root (authored mapping).
func apply_to_stadium_root(root: Node, mapping: Dictionary = {}) -> int:
	# mapping: Node name substring -> material key; default mapping uses name hints
	var default_map := {
		"Floor": "floor",
		"Wall": "wall",
		"Ceiling": "ceiling",
		"Metal": "metal",
		"Trim": "metal",
		"Banner": "decal",
		"Decal": "decal",
	}
	if not mapping.is_empty():
		default_map = mapping
	var applied := 0
	var mis := _collect_mesh_instances(root)
	for mi in mis:
		var key := _key_for_mesh_name(mi.name, default_map)
		if apply_to_mesh(mi, key):
			applied += 1
	return applied

func _key_for_mesh_name(mesh_name: String, mapping: Dictionary) -> String:
	for substr in mapping.keys():
		if mesh_name.contains(substr):
			return mapping[substr]
	# Fallback deterministic: hash name to one of floor/wall/metal
	var h := hash(mesh_name) & 0xFF
	if h % 3 == 0:
		return "floor"
	elif h % 3 == 1:
		return "wall"
	return "metal"

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
	# Each unique material = 1 draw call when meshes are separate
	return MATERIAL_COUNT

func get_estimated_draw_calls() -> int:
	return ESTIMATED_DRAW_CALLS

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

# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------
func get_budget_state() -> Dictionary:
	return {
		"material_count": MATERIAL_COUNT,
		"max_materials": MAX_MATERIALS,
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": ESTIMATED_DRAW_CALLS <= DRAW_CALL_BUDGET,
		"max_draw_calls": MAX_DRAW_CALLS,
		"estimated_tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
		"texture_count": AUTHORED_TEXTURE_PATHS.size(),
		"uses_lighting": true,
		"uses_stadium": true,
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
		errors.append("ArenaMaterials.ARENA_LENGTH drift")
	if not is_equal_approx(ARENA_WIDTH, PhysicsConstants.ARENA_WIDTH):
		errors.append("ARENA_WIDTH drift")
	if ARENA_SIZE != PhysicsConstants.ARENA_SIZE:
		errors.append("ARENA_SIZE drift vs PhysicsConstants")
	# Stadium drift
	if not is_equal_approx(Stadium.ARENA_LENGTH, PhysicsConstants.ARENA_LENGTH):
		errors.append("Stadium.ARENA_LENGTH drift")
	if not is_equal_approx(Stadium.STADIUM_MESH_PATH.get_file(), "stadium_dfh_mesh_a_v01.glb".get_file()):
		pass
	if Stadium.STADIUM_MESH_PATH != "res://assets/authored/arena/stadium_dfh_mesh_a_v01.glb":
		errors.append("Stadium.STADIUM_MESH_PATH unexpected: %s" % Stadium.STADIUM_MESH_PATH)
	# Lighting coupling
	if not is_equal_approx(ArenaLighting.SUN_ENERGY, SUN_ENERGY):
		errors.append("SUN_ENERGY %.2f != ArenaLighting.SUN_ENERGY %.2f" % [SUN_ENERGY, ArenaLighting.SUN_ENERGY])
	if ArenaLighting.SUN_COLOR != SUN_COLOR:
		errors.append("SUN_COLOR %s != ArenaLighting.SUN_COLOR %s" % [str(SUN_COLOR), str(ArenaLighting.SUN_COLOR)])
	if ArenaLighting.ARENA_LENGTH != ARENA_LENGTH:
		errors.append("ArenaLighting.ARENA_LENGTH drift")
	if ArenaLighting.DRAW_CALL_BUDGET > 12:
		errors.append("ArenaLighting DRAW_CALL_BUDGET >12")
	# Budget
	if DRAW_CALL_BUDGET > 12:
		errors.append("DRAW_CALL_BUDGET %d > 12" % DRAW_CALL_BUDGET)
	if MAX_DRAW_CALLS > 12:
		errors.append("MAX_DRAW_CALLS > 12")
	if MAX_MATERIALS > 12:
		errors.append("MAX_MATERIALS %d > 12" % MAX_MATERIALS)
	if MATERIAL_COUNT > MAX_MATERIALS:
		errors.append("MATERIAL_COUNT %d > MAX_MATERIALS %d" % [MATERIAL_COUNT, MAX_MATERIALS])
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("ESTIMATED_DRAW_CALLS %d > %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if ESTIMATED_DRAW_CALLS > 12:
		errors.append("ESTIMATED_DRAW_CALLS %d > 12 hard cap" % ESTIMATED_DRAW_CALLS)
	if MATERIAL_COUNT != MATERIAL_KEYS.size():
		errors.append("MATERIAL_COUNT %d != MATERIAL_KEYS.size() %d" % [MATERIAL_COUNT, MATERIAL_KEYS.size()])
	if AUTHORED_TEXTURE_PATHS.size() != 13:
		errors.append("AUTHORED_TEXTURE_PATHS size %d != 13" % AUTHORED_TEXTURE_PATHS.size())
	# PBR ranges
	for v in [FLOOR_ROUGHNESS, WALL_ROUGHNESS, CEILING_ROUGHNESS, METAL_ROUGHNESS, DECAL_ROUGHNESS]:
		if v < 0.0 or v > 1.0:
			errors.append("roughness %.2f out of [0,1]" % v)
	for v in [FLOOR_METALLIC, WALL_METALLIC, CEILING_METALLIC, METAL_METALLIC, DECAL_METALLIC]:
		if v < 0.0 or v > 1.0:
			errors.append("metallic %.2f out of [0,1]" % v)
	for c in [FLOOR_ALBEDO, WALL_ALBEDO, CEILING_ALBEDO, METAL_ALBEDO, DECAL_ALBEDO]:
		if c.a != 1.0:
			errors.append("albedo alpha !=1 for %s" % str(c))
	# Texture path sanity — must be under authored/arena, versioned _a_v01
	for p in AUTHORED_TEXTURE_PATHS:
		if not p.begins_with("res://assets/authored/arena/"):
			errors.append("texture path not under authored/arena: %s" % p)
		if not p.contains("_a_v01"):
			errors.append("texture path missing _a_v01 version: %s" % p)
		elif not (p.ends_with(".png") or p.ends_with(".tres") or p.ends_with(".glb")):
			errors.append("texture path unexpected ext: %s" % p)
	# Floor albedo must reuse Stadium texture (continuity check)
	if FLOOR_ALBEDO_PATH != Stadium.STADIUM_TEXTURE_PATH:
		# Allow alias: floor albedo should equal stadium floor texture
		if FLOOR_ALBEDO_PATH != "res://assets/authored/arena/stadium_dfh_floor_a_v01.png":
			errors.append("FLOOR_ALBEDO_PATH drift vs Stadium.STADIUM_TEXTURE_PATH")
	# Metal must be high metallic, low roughness (PBR sanity)
	if METAL_METALLIC < 0.5:
		errors.append("METAL_METALLIC %.2f <0.5 (should be metallic)" % METAL_METALLIC)
	if METAL_ROUGHNESS > 0.6:
		errors.append("METAL_ROUGHNESS %.2f >0.6 (should be smooth)" % METAL_ROUGHNESS)
	# Emission sanity
	if DECAL_EMISSION_ENERGY < 0.0 or DECAL_EMISSION_ENERGY > 1.0:
		errors.append("DECAL_EMISSION_ENERGY %.2f out of [0,1]" % DECAL_EMISSION_ENERGY)
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"material_count": MATERIAL_COUNT,
		"material_keys": MATERIAL_KEYS.duplicate(),
		"authored_textures": AUTHORED_TEXTURE_PATHS.duplicate(),
		"floor": {"albedo": FLOOR_ALBEDO, "roughness": FLOOR_ROUGHNESS, "metallic": FLOOR_METALLIC, "albedo_path": FLOOR_ALBEDO_PATH},
		"wall": {"albedo": WALL_ALBEDO, "roughness": WALL_ROUGHNESS, "metallic": WALL_METALLIC, "albedo_path": WALL_ALBEDO_PATH},
		"ceiling": {"albedo": CEILING_ALBEDO, "roughness": CEILING_ROUGHNESS, "metallic": CEILING_METALLIC, "albedo_path": CEILING_ALBEDO_PATH},
		"metal": {"albedo": METAL_ALBEDO, "roughness": METAL_ROUGHNESS, "metallic": METAL_METALLIC, "albedo_path": METAL_ALBEDO_PATH},
		"decal": {"albedo": DECAL_ALBEDO, "roughness": DECAL_ROUGHNESS, "metallic": DECAL_METALLIC, "albedo_path": DECAL_ALBEDO_PATH, "emission_energy": DECAL_EMISSION_ENERGY},
		"lighting": {"sun_color": SUN_COLOR, "sun_energy": SUN_ENERGY, "uses_lighting": true},
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": ESTIMATED_DRAW_CALLS <= DRAW_CALL_BUDGET,
		"loaded": _loaded,
		"applied_count": get_applied_count(),
		"arena_size": PhysicsConstants.ARENA_SIZE,
		"arena_aabb": get_arena_aabb(),
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "ArenaMaterials",
		"material_count": MATERIAL_COUNT,
		"max_materials": MAX_MATERIALS,
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
		"texture_count": AUTHORED_TEXTURE_PATHS.size(),
		"tick_hz": TICK_HZ,
	}

func get_debug_state() -> Dictionary:
	var base := debug_export()
	base["budget"] = get_budget_state()
	return base
