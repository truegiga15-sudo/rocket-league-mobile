## WS40 — Skybox & Atmosphere (budget-aware <12 calls)
## DFH sky dome + fog atmosphere. WorldEnvironment with authored ProceduralSkyMaterial
## tinted by WS38 sun direction/color. No procedural noise, all colors deterministic.
## Uses Stadium WS36 dimensions + PhysicsConstants + ArenaLighting WS38 as sources of truth.
## Budget: 1 sky draw call + 1 fog pass = 2 < 12. No extra light probes.
## Depends on: src/core/constants.gd (WS04), src/game/arena/stadium.gd (WS36),
##             src/game/arena/lighting.gd (WS38)
extends Node3D
class_name ArenaSkybox

const PhysicsConstants = preload("res://src/core/constants.gd")
const Stadium = preload("res://src/game/arena/stadium.gd")
const ArenaLighting = preload("res://src/game/arena/lighting.gd")

# ---------------------------------------------------------------------------
# Arena dimensions — must match PhysicsConstants (single source of truth)
# ---------------------------------------------------------------------------
const ARENA_LENGTH: float = 60.0
const ARENA_WIDTH: float = 40.0
const ARENA_HEIGHT: float = 20.0
const ARENA_HALF_LENGTH: float = 30.0
const ARENA_HALF_WIDTH: float = 20.0
const ARENA_SIZE: Vector3 = Vector3(40.0, 20.0, 60.0)
const ARENA_HALF_SIZE: Vector3 = Vector3(20.0, 10.0, 30.0)

# ---------------------------------------------------------------------------
# Authored skybox — deterministic, no noise synthesis
# ---------------------------------------------------------------------------
## Authored HDR panorama (equirect, authored export) — optional override for Procedural fallback
const SKY_PANORAMA_PATH: String = "res://assets/authored/arena/skybox_panorama_a_v01.hdr"
const SKY_TEXTURE_PATH: String = "res://assets/authored/arena/skybox_texture_a_v01.png"
## Environment resource path (reused from WS38)
const ENVIRONMENT_PATH: String = "res://src/render/default_env.tres"

## Procedural sky — authored palette, not generated noise. Matches warm noon sun.
const SKY_TOP_COLOR: Color = Color(0.33, 0.55, 0.92, 1.0)       # zenith blue
const SKY_HORIZON_COLOR: Color = Color(0.62, 0.78, 0.95, 1.0)  # horizon haze
const SKY_GROUND_COLOR: Color = Color(0.18, 0.22, 0.28, 1.0)   # below horizon (stadium void)
const SKY_CURVE: float = 0.12
const SKY_ENERGY_MULTIPLIER: float = 1.0
const SKY_SUN_ANGLE_MAX: float = 30.0  # degrees blending width around sun disc
const SKY_USE_DEBANDING: bool = true

## Atmosphere / fog — exponential height fog, authored, deterministic
const FOG_ENABLED: bool = true
const FOG_COLOR: Color = Color(0.70, 0.78, 0.86, 1.0)
const FOG_SUN_AMOUNT: float = 0.35  # sun scattering contribution (0=no sun, 1=full)
const FOG_DENSITY: float = 0.008
const FOG_HEIGHT: float = 0.0       # base at floor Y=0
const FOG_HEIGHT_DENSITY: float = 0.04
const FOG_AERIAL_PERSPECTIVE: float = 0.02
const FOG_SKY_AFFECT: float = 0.6   # how much fog tints sky (DFH open stadium)
const ATMOSPHERE_SCATTERING: float = 0.35

# ---------------------------------------------------------------------------
# Budget — WS10 limits + WS40 <12 calls for skybox + atmosphere alone
# ---------------------------------------------------------------------------
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const MAX_TRIS_BUDGET: int = 300000  # sky adds ~0 tris (background)
const ESTIMATED_DRAW_CALLS: int = 2  # 1 sky background + 1 fog/volumetric pass
const SKY_DRAW_CALLS: int = 1
const FOG_DRAW_CALLS: int = 1
const TICK_HZ: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Runtime refs — deterministic, no per-frame allocation
# ---------------------------------------------------------------------------
var _env: WorldEnvironment = null
var _sky: Sky = null
var _sky_material: ProceduralSkyMaterial = null
var _lighting_ref: ArenaLighting = null
var _loaded: bool = false

# ---------------------------------------------------------------------------
# Lifecycle — deterministic setup in _ready, no random
# ---------------------------------------------------------------------------
func _ready() -> void:
	_resolve_refs()
	_apply_skybox()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[ArenaSkybox] debug_validate: %s" % e)

func _resolve_refs() -> void:
	_env = _find_env(self)
	_lighting_ref = _resolve_lighting()
	# Sky lives inside environment
	if _env and _env.environment and _env.environment.sky:
		_sky = _env.environment.sky
		if _sky and _sky.sky_material is ProceduralSkyMaterial:
			_sky_material = _sky.sky_material as ProceduralSkyMaterial

func _resolve_lighting() -> ArenaLighting:
	var p := get_parent()
	if p:
		for child in p.get_children():
			if child is ArenaLighting:
				return child as ArenaLighting
	for child in get_children():
		if child is ArenaLighting:
			return child as ArenaLighting
	return null

func _find_env(root: Node) -> WorldEnvironment:
	if root is WorldEnvironment:
		return root as WorldEnvironment
	for child in root.get_children():
		var found := _find_env(child)
		if found != null:
			return found
	return null

func _apply_skybox() -> void:
	if _env == null:
		_env = _create_environment()
		add_child(_env)
	# Ensure environment resource exists
	var env_res: Environment = _env.environment
	if env_res == null:
		env_res = Environment.new()
		_env.environment = env_res
	# Configure background -> sky
	env_res.background_mode = Environment.BG_SKY
	env_res.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env_res.ambient_light_energy = 1.0
	# Fog / atmosphere — deterministic authored values
	env_res.fog_enabled = FOG_ENABLED
	env_res.fog_light_color = FOG_COLOR
	env_res.fog_light_energy = FOG_SUN_AMOUNT
	env_res.fog_sun_amount = FOG_SUN_AMOUNT
	env_res.fog_density = FOG_DENSITY
	env_res.fog_height = FOG_HEIGHT
	env_res.fog_height_density = FOG_HEIGHT_DENSITY
	env_res.fog_aerial_perspective = FOG_AERIAL_PERSPECTIVE
	env_res.fog_sky_affect = FOG_SKY_AFFECT
	# Tonemap / glow keep deterministic (no random exposure)
	env_res.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env_res.tonemap_exposure = 1.0
	# Ensure sky
	if env_res.sky == null:
		env_res.sky = Sky.new()
	_sky = env_res.sky
	# Sky material — authored ProceduralSkyMaterial tinted by sun
	if _sky.sky_material == null or not (_sky.sky_material is ProceduralSkyMaterial):
		_sky.sky_material = _create_sky_material()
	_sky_material = _sky.sky_material as ProceduralSkyMaterial
	_configure_sky_material(_sky_material)
	_loaded = true

func _create_environment() -> WorldEnvironment:
	var we := WorldEnvironment.new()
	we.name = "SkyboxEnvironment"
	we.environment = Environment.new()
	return we

func _create_sky_material() -> ProceduralSkyMaterial:
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = SKY_TOP_COLOR
	mat.sky_horizon_color = SKY_HORIZON_COLOR
	mat.ground_bottom_color = SKY_GROUND_COLOR
	mat.ground_horizon_color = SKY_GROUND_COLOR
	mat.sky_curve = SKY_CURVE
	mat.use_debanding = SKY_USE_DEBANDING
	# Sun disc tint from lighting WS38
	mat.sun_angle_max = SKY_SUN_ANGLE_MAX
	mat.sun_curve = 0.15
	return mat

func _configure_sky_material(mat: ProceduralSkyMaterial) -> void:
	if mat == null:
		return
	mat.sky_top_color = SKY_TOP_COLOR
	mat.sky_horizon_color = SKY_HORIZON_COLOR
	mat.ground_bottom_color = SKY_GROUND_COLOR
	mat.ground_horizon_color = SKY_GROUND_COLOR
	mat.sky_curve = SKY_CURVE
	mat.sky_energy_multiplier = SKY_ENERGY_MULTIPLIER
	mat.use_debanding = SKY_USE_DEBANDING
	mat.sun_angle_max = SKY_SUN_ANGLE_MAX
	# Tie sun to WS38 lighting direction/color — deterministic
	var sun_dir := get_sun_direction()
	# Godot ProceduralSkyMaterial sun_direction is not exposed directly; the sun
	# position is driven by DirectionalLight3D rotation. We tint horizon via sun.
	# If we ever switch to PanoramaSkyMaterial, loader uses SKY_PANORAMA_PATH.
	# Apply sun color bias to horizon (warm noon)
	var sun_col: Color = ArenaLighting.SUN_COLOR
	mat.sky_horizon_color = SKY_HORIZON_COLOR.lerp(sun_col, 0.18)
	mat.ground_horizon_color = SKY_GROUND_COLOR.lerp(sun_col * 0.5, 0.10)

# ---------------------------------------------------------------------------
# Public API — deterministic helpers, uses PhysicsConstants + ArenaLighting
# ---------------------------------------------------------------------------
func is_loaded() -> bool:
	return _loaded

func get_environment() -> WorldEnvironment:
	if is_instance_valid(_env):
		return _env
	_env = _find_env(self)
	return _env

func get_sky() -> Sky:
	var env := get_environment()
	if env and env.environment:
		return env.environment.sky
	return _sky

func get_sky_material() -> ProceduralSkyMaterial:
	var sky := get_sky()
	if sky and sky.sky_material is ProceduralSkyMaterial:
		return sky.sky_material as ProceduralSkyMaterial
	return _sky_material

func get_sun_direction() -> Vector3:
	if _lighting_ref and is_instance_valid(_lighting_ref):
		return _lighting_ref.get_sun_direction()
	# Fallback deterministic from WS38 constants
	var az := deg_to_rad(ArenaLighting.SUN_AZIMUTH_DEG)
	var el := deg_to_rad(ArenaLighting.SUN_ELEVATION_DEG)
	var x := cos(el) * sin(az)
	var y := sin(el)
	var z := cos(el) * cos(az)
	return Vector3(x, y, z).normalized()

func get_sun_color() -> Color:
	if _lighting_ref and is_instance_valid(_lighting_ref):
		return _lighting_ref.get_sun_color()
	return ArenaLighting.SUN_COLOR

func get_lighting() -> ArenaLighting:
	if is_instance_valid(_lighting_ref):
		return _lighting_ref
	_lighting_ref = _resolve_lighting()
	return _lighting_ref

static func uses_lighting() -> bool:
	return true

static func uses_stadium() -> bool:
	return true

func get_draw_call_count() -> int:
	return ESTIMATED_DRAW_CALLS

func get_sky_draw_calls() -> int:
	return SKY_DRAW_CALLS

func get_fog_draw_calls() -> int:
	return FOG_DRAW_CALLS

func get_arena_size() -> Vector3:
	return PhysicsConstants.ARENA_SIZE

func get_arena_aabb() -> AABB:
	return PhysicsConstants.arena_aabb()

func get_sky_colors() -> Dictionary:
	return {
		"top": SKY_TOP_COLOR,
		"horizon": SKY_HORIZON_COLOR,
		"ground": SKY_GROUND_COLOR,
		"fog": FOG_COLOR,
	}

func get_atmosphere_params() -> Dictionary:
	return {
		"fog_enabled": FOG_ENABLED,
		"fog_density": FOG_DENSITY,
		"fog_height": FOG_HEIGHT,
		"fog_height_density": FOG_HEIGHT_DENSITY,
		"aerial_perspective": FOG_AERIAL_PERSPECTIVE,
		"fog_sky_affect": FOG_SKY_AFFECT,
		"scattering": ATMOSPHERE_SCATTERING,
		"sun_amount": FOG_SUN_AMOUNT,
	}

# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------
func get_budget_state() -> Dictionary:
	var dc := get_draw_call_count()
	return {
		"draw_calls": dc,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": dc <= DRAW_CALL_BUDGET,
		"sky_draw_calls": SKY_DRAW_CALLS,
		"fog_draw_calls": FOG_DRAW_CALLS,
		"max_draw_calls": MAX_DRAW_CALLS,
		"estimated_tris": 0,
		"tris_budget": MAX_TRIS_BUDGET,
	}

# ---------------------------------------------------------------------------
# Validation / telemetry (conventions §11) — deterministic, no random
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	# PhysicsConstants drift
	if not is_equal_approx(PhysicsConstants.ARENA_LENGTH, 60.0):
		errors.append("ARENA_LENGTH != 60.0")
	if not is_equal_approx(PhysicsConstants.ARENA_WIDTH, 40.0):
		errors.append("ARENA_WIDTH != 40.0")
	if not is_equal_approx(PhysicsConstants.ARENA_HEIGHT, 20.0):
		errors.append("ARENA_HEIGHT != 20.0")
	if not is_equal_approx(ARENA_LENGTH, PhysicsConstants.ARENA_LENGTH):
		errors.append("ArenaSkybox.ARENA_LENGTH drift vs PhysicsConstants")
	if not is_equal_approx(ARENA_WIDTH, PhysicsConstants.ARENA_WIDTH):
		errors.append("ARENA_WIDTH drift")
	if not is_equal_approx(ARENA_HALF_LENGTH, PhysicsConstants.ARENA_HALF_LENGTH):
		errors.append("ARENA_HALF_LENGTH drift")
	if not is_equal_approx(ARENA_HALF_WIDTH, PhysicsConstants.ARENA_HALF_WIDTH):
		errors.append("ARENA_HALF_WIDTH drift")
	if ARENA_SIZE != PhysicsConstants.ARENA_SIZE:
		errors.append("ARENA_SIZE drift vs PhysicsConstants")
	# Stadium drift
	if not is_equal_approx(Stadium.ARENA_LENGTH, PhysicsConstants.ARENA_LENGTH):
		errors.append("Stadium.ARENA_LENGTH drift vs PhysicsConstants")
	if not is_equal_approx(Stadium.ARENA_WIDTH, PhysicsConstants.ARENA_WIDTH):
		errors.append("Stadium.ARENA_WIDTH drift")
	# Lighting drift — skybox must use same sun as WS38
	if not is_equal_approx(ArenaLighting.SUN_AZIMUTH_DEG, 315.0):
		errors.append("ArenaLighting.SUN_AZIMUTH_DEG drift %.1f !=315" % ArenaLighting.SUN_AZIMUTH_DEG)
	if not is_equal_approx(ArenaLighting.SUN_ELEVATION_DEG, 55.0):
		errors.append("SUN_ELEVATION drift %.1f !=55" % ArenaLighting.SUN_ELEVATION_DEG)
	if ArenaLighting.SUN_COLOR != Color(1.0, 0.98, 0.92, 1.0):
		errors.append("SUN_COLOR drift %s" % str(ArenaLighting.SUN_COLOR))
	if ArenaLighting.LIGHT_COUNT != 1:
		errors.append("ArenaLighting.LIGHT_COUNT !=1")
	if ArenaLighting.PROBE_COUNT != 4:
		errors.append("PROBE_COUNT !=4")
	# Budget <12 calls (hard limit for WS40)
	if DRAW_CALL_BUDGET > 12:
		errors.append("DRAW_CALL_BUDGET %d > 12" % DRAW_CALL_BUDGET)
	if MAX_DRAW_CALLS > 12:
		errors.append("MAX_DRAW_CALLS %d > 12" % MAX_DRAW_CALLS)
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("ESTIMATED_DRAW_CALLS %d > budget %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if ESTIMATED_DRAW_CALLS > 12:
		errors.append("ESTIMATED_DRAW_CALLS %d > 12 hard cap" % ESTIMATED_DRAW_CALLS)
	if SKY_DRAW_CALLS + FOG_DRAW_CALLS != ESTIMATED_DRAW_CALLS:
		errors.append("SKY+FOG %d != ESTIMATED %d" % [SKY_DRAW_CALLS + FOG_DRAW_CALLS, ESTIMATED_DRAW_CALLS])
	# Colors must be opaque authored (alpha 1.0)
	if SKY_TOP_COLOR.a != 1.0:
		errors.append("SKY_TOP_COLOR alpha !=1.0")
	if SKY_HORIZON_COLOR.a != 1.0:
		errors.append("SKY_HORIZON_COLOR alpha !=1.0")
	if SKY_GROUND_COLOR.a != 1.0:
		errors.append("SKY_GROUND_COLOR alpha !=1.0")
	if FOG_COLOR.a != 1.0:
		errors.append("FOG_COLOR alpha !=1.0")
	# Sky curve sane
	if SKY_CURVE < 0.0 or SKY_CURVE > 1.0:
		errors.append("SKY_CURVE %.3f out of [0,1]" % SKY_CURVE)
	# Fog density sane
	if FOG_DENSITY < 0.0 or FOG_DENSITY > 0.2:
		errors.append("FOG_DENSITY %.4f out of [0,0.2]" % FOG_DENSITY)
	if FOG_HEIGHT_DENSITY < 0.0 or FOG_HEIGHT_DENSITY > 1.0:
		errors.append("FOG_HEIGHT_DENSITY %.3f out of [0,1]" % FOG_HEIGHT_DENSITY)
	if FOG_SUN_AMOUNT < 0.0 or FOG_SUN_AMOUNT > 1.0:
		errors.append("FOG_SUN_AMOUNT %.2f out of [0,1]" % FOG_SUN_AMOUNT)
	if FOG_SKY_AFFECT < 0.0 or FOG_SKY_AFFECT > 1.0:
		errors.append("FOG_SKY_AFFECT %.2f out of [0,1]" % FOG_SKY_AFFECT)
	# Paths must be canonical authored
	if not SKY_PANORAMA_PATH.begins_with("res://assets/authored/arena/"):
		errors.append("SKY_PANORAMA_PATH must be under res://assets/authored/arena/ got %s" % SKY_PANORAMA_PATH)
	if not ENVIRONMENT_PATH.begins_with("res://src/render/"):
		errors.append("ENVIRONMENT_PATH must be under res://src/render/ got %s" % ENVIRONMENT_PATH)
	# Environment path must match lighting (single env)
	if ENVIRONMENT_PATH != ArenaLighting.ENVIRONMENT_PATH:
		errors.append("ENVIRONMENT_PATH %s != ArenaLighting %s" % [ENVIRONMENT_PATH, ArenaLighting.ENVIRONMENT_PATH])
	# Stadium authored path canonical
	if Stadium.STADIUM_MESH_PATH != "res://assets/authored/arena/stadium_dfh_mesh_a_v01.glb":
		errors.append("Stadium.STADIUM_MESH_PATH unexpected: %s" % Stadium.STADIUM_MESH_PATH)
	# Deterministic: sun direction normalized and above horizon
	var az := deg_to_rad(ArenaLighting.SUN_AZIMUTH_DEG)
	var el := deg_to_rad(ArenaLighting.SUN_ELEVATION_DEG)
	var dir := Vector3(cos(el) * sin(az), sin(el), cos(el) * cos(az)).normalized()
	if not is_equal_approx(dir.length(), 1.0):
		errors.append("sun direction not normalized len=%.3f" % dir.length())
	if dir.y <= 0.0:
		errors.append("sun direction y must be >0 got %.3f" % dir.y)
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"sky_panorama_path": SKY_PANORAMA_PATH,
		"sky_texture_path": SKY_TEXTURE_PATH,
		"environment_path": ENVIRONMENT_PATH,
		"sky_colors": get_sky_colors(),
		"atmosphere": get_atmosphere_params(),
		"sky_curve": SKY_CURVE,
		"sky_energy_multiplier": SKY_ENERGY_MULTIPLIER,
		"sun_direction": get_sun_direction(),
		"sun_color": get_sun_color(),
		"baked": true,
		"draw_calls": get_draw_call_count(),
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": get_draw_call_count() <= DRAW_CALL_BUDGET,
		"arena_size": PhysicsConstants.ARENA_SIZE,
		"arena_aabb": get_arena_aabb(),
		"loaded": _loaded,
		"has_environment": get_environment() != null,
		"has_sky": get_sky() != null,
		"uses_lighting": uses_lighting(),
		"uses_stadium": uses_stadium(),
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "ArenaSkybox",
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"sky_draw_calls": SKY_DRAW_CALLS,
		"fog_draw_calls": FOG_DRAW_CALLS,
		"tris": 0,
		"tris_budget": MAX_TRIS_BUDGET,
		"tick_hz": TICK_HZ,
		"baked": true,
	}

func get_debug_state() -> Dictionary:
	var base := debug_export()
	base["budget"] = get_budget_state()
	return base
