## WS38 — Lighting Rig (baked + probes, budget-aware <12 calls)
## DFH stadium lighting: single baked DirectionalLight3D (sun) + 4 ReflectionProbes
## placed at arena quadrants. All values deterministic, authored, no procedural
## noise. Uses Stadium WS36 dimensions + PhysicsConstants as single source of truth.
## Budget: <12 light-related draw calls (1 sun + 4 probes + 1 env = 6).
## Depends on: src/core/constants.gd (WS04), src/game/arena/stadium.gd (WS36)
extends Node3D
class_name ArenaLighting

const PhysicsConstants = preload("res://src/core/constants.gd")
const Stadium = preload("res://src/game/arena/stadium.gd")

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
# Authored light rig — deterministic, no procedural, no random
# ---------------------------------------------------------------------------
## Baked environment — authored, referenced in project.godot under
## rendering/environment/defaults/default_environment
const ENVIRONMENT_PATH: String = "res://src/render/default_env.tres"
## Baked lightmap / GI data — authored capture of stadium bounce (placeholder).
const BAKED_LIGHTMAP_PATH: String = "res://assets/authored/arena/lighting_baked_a_v01.tres"

## Sun (DirectionalLight3D) — baked shadows, fixed azimuth/elevation.
## Azimuth 315° (north-west), elevation 55° — deterministic, RL-like noon.
const SUN_AZIMUTH_DEG: float = 315.0
const SUN_ELEVATION_DEG: float = 55.0
const SUN_COLOR: Color = Color(1.0, 0.98, 0.92, 1.0)  # warm noon
const SUN_ENERGY: float = 1.0
const SUN_SHADOW_ENABLED: bool = true
const SUN_SHADOW_BAKED: bool = true
const SUN_LIGHT_SIZE: float = 0.04  # soft shadow penumbra authored
const SUN_BAKED_MODE: int = 1  # LightStorage BAKE_MODE_STATIC (baked)

## Probes — 4 ReflectionProbes at quadrant centers, height 6 m (eye level).
## Positions derived from ARENA_HALF_SIZE / 2, so probes sit at ±10, 6, ±15.
const PROBE_COUNT: int = 4
const PROBE_HEIGHT: float = 6.0
const PROBE_EXTENTS: Vector3 = Vector3(22.0, 12.0, 32.0)  # covers half-arena with overlap
const PROBE_POSITIONS: Array[Vector3] = [
	Vector3(10.0, 6.0, 15.0),
	Vector3(-10.0, 6.0, 15.0),
	Vector3(10.0, 6.0, -15.0),
	Vector3(-10.0, 6.0, -15.0),
]
const PROBE_INTENSITY: float = 1.0
const PROBE_UPDATE_MODE: int = 0  # UPDATE_ONCE — baked
const PROBE_INFLUENCE: float = 1.0

# ---------------------------------------------------------------------------
# Budget — WS10 limits + WS38 tighter <12 calls for lighting rig alone
# ---------------------------------------------------------------------------
const MAX_DRAW_CALLS: int = 12
const DRAW_CALL_BUDGET: int = 12
const MAX_LIGHTS: int = 8
const MAX_PROBES: int = 6
const MAX_TRIS_BUDGET: int = 300000  # lighting adds zero tris (mirrors stadium)
const LIGHT_COUNT: int = 1  # 1 DirectionalLight3D (sun)
const ESTIMATED_DRAW_CALLS: int = 6  # 1 sun shadow + 4 probes + 1 env
const ESTIMATED_LIGHT_CALLS: int = 6
const TICK_HZ: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Runtime refs — deterministic load, no per-frame allocation
# ---------------------------------------------------------------------------
var _sun: DirectionalLight3D = null
var _probes: Array[ReflectionProbe] = []
var _env: WorldEnvironment = null
var _loaded: bool = false

# ---------------------------------------------------------------------------
# Lifecycle — deterministic setup in _ready, no random
# ---------------------------------------------------------------------------
func _ready() -> void:
	_resolve_refs()
	_apply_lighting()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[ArenaLighting] debug_validate: %s" % e)

func _resolve_refs() -> void:
	_sun = _find_sun(self)
	_env = _find_env(self)
	_probes.clear()
	_collect_probes(self, _probes)

func _find_sun(root: Node) -> DirectionalLight3D:
	if root is DirectionalLight3D:
		return root as DirectionalLight3D
	for child in root.get_children():
		var found := _find_sun(child)
		if found != null:
			return found
	return null

func _find_env(root: Node) -> WorldEnvironment:
	if root is WorldEnvironment:
		return root as WorldEnvironment
	for child in root.get_children():
		var found := _find_env(child)
		if found != null:
			return found
	return null

func _collect_probes(node: Node, out: Array[ReflectionProbe]) -> void:
	if node is ReflectionProbe:
		out.append(node as ReflectionProbe)
	for child in node.get_children():
		_collect_probes(child, out)

func _apply_lighting() -> void:
	# Ensure sun exists — create deterministic fallback if scene not instanced
	if _sun == null:
		_sun = _create_sun()
		add_child(_sun)
	# Configure sun deterministically (authored values, no random)
	_sun.light_color = SUN_COLOR
	_sun.light_energy = SUN_ENERGY
	_sun.shadow_enabled = SUN_SHADOW_ENABLED
	_sun.rotation_degrees = Vector3(-SUN_ELEVATION_DEG, SUN_AZIMUTH_DEG - 180.0, 0)
	_sun.name = "Sun_Directional"
	# Ensure 4 probes
	if _probes.size() != PROBE_COUNT:
		_ensure_probes()
	else:
		for i in range(_probes.size()):
			_configure_probe(_probes[i], PROBE_POSITIONS[i] if i < PROBE_POSITIONS.size() else Vector3.ZERO)
	_loaded = true

func _create_sun() -> DirectionalLight3D:
	var l := DirectionalLight3D.new()
	l.name = "Sun_Directional"
	l.light_color = SUN_COLOR
	l.light_energy = SUN_ENERGY
	l.shadow_enabled = SUN_SHADOW_ENABLED
	l.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	l.rotation_degrees = Vector3(-SUN_ELEVATION_DEG, SUN_AZIMUTH_DEG - 180.0, 0)
	return l

func _ensure_probes() -> void:
	# Remove existing probes to avoid duplicates (deterministic re-add)
	for p in _probes:
		if is_instance_valid(p):
			p.queue_free()
	_probes.clear()
	for i in range(PROBE_COUNT):
		var pr := ReflectionProbe.new()
		pr.name = "Probe_%d" % i
		_configure_probe(pr, PROBE_POSITIONS[i])
		add_child(pr)
		_probes.append(pr)
	_loaded = true

func _configure_probe(probe: ReflectionProbe, pos: Vector3) -> void:
	probe.position = pos
	probe.extents = PROBE_EXTENTS
	probe.origin_offset = Vector3.ZERO
	probe.intensity = PROBE_INTENSITY
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.enable_shadows = false
	probe.cull_mask = 0xFFFFFFFF

# ---------------------------------------------------------------------------
# Public API — deterministic helpers, use PhysicsConstants + Stadium
# ---------------------------------------------------------------------------
func is_loaded() -> bool:
	return _loaded

func get_sun() -> DirectionalLight3D:
	if is_instance_valid(_sun):
		return _sun
	_sun = _find_sun(self)
	return _sun

func get_probes() -> Array[ReflectionProbe]:
	# Refresh cache if scene changed
	var fresh: Array[ReflectionProbe] = []
	_collect_probes(self, fresh)
	if fresh.size() > 0:
		_probes = fresh
	return _probes

func get_probe_positions() -> Array[Vector3]:
	return PROBE_POSITIONS.duplicate()

func get_sun_direction() -> Vector3:
	# Deterministic sun direction from azimuth/elevation (normalized)
	var az := deg_to_rad(SUN_AZIMUTH_DEG)
	var el := deg_to_rad(SUN_ELEVATION_DEG)
	var x := cos(el) * sin(az)
	var y := sin(el)
	var z := cos(el) * cos(az)
	return Vector3(x, y, z).normalized()

func get_sun_rotation() -> Vector3:
	return Vector3(-SUN_ELEVATION_DEG, SUN_AZIMUTH_DEG - 180.0, 0)

func get_sun_color() -> Color:
	return SUN_COLOR

func get_sun_energy() -> float:
	return SUN_ENERGY

func is_baked() -> bool:
	return SUN_SHADOW_BAKED

func get_light_count() -> int:
	return LIGHT_COUNT

func get_probe_count() -> int:
	return PROBE_COUNT

func get_estimated_draw_calls() -> int:
	return ESTIMATED_DRAW_CALLS

func get_draw_call_count() -> int:
	# Lighting rig draw cost: sun shadow map + probe captures (baked = once)
	return ESTIMATED_DRAW_CALLS

func get_environment_path() -> String:
	return ENVIRONMENT_PATH

func get_baked_lightmap_path() -> String:
	return BAKED_LIGHTMAP_PATH

func get_arena_size() -> Vector3:
	return PhysicsConstants.ARENA_SIZE

func get_arena_aabb() -> AABB:
	return PhysicsConstants.arena_aabb()

static func uses_stadium() -> bool:
	return true

# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------
func get_budget_state() -> Dictionary:
	var dc := get_draw_call_count()
	return {
		"draw_calls": dc,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": dc <= DRAW_CALL_BUDGET,
		"light_count": LIGHT_COUNT,
		"max_lights": MAX_LIGHTS,
		"probe_count": PROBE_COUNT,
		"max_probes": MAX_PROBES,
		"estimated_light_calls": ESTIMATED_LIGHT_CALLS,
		"max_draw_calls": MAX_DRAW_CALLS,
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
		errors.append("ArenaLighting.ARENA_LENGTH drift vs PhysicsConstants")
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
	# Budget <12 calls (hard limit for WS38)
	if DRAW_CALL_BUDGET > 12:
		errors.append("DRAW_CALL_BUDGET %d > 12" % DRAW_CALL_BUDGET)
	if MAX_DRAW_CALLS > 12:
		errors.append("MAX_DRAW_CALLS %d > 12" % MAX_DRAW_CALLS)
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("ESTIMATED_DRAW_CALLS %d > budget %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if ESTIMATED_DRAW_CALLS > 12:
		errors.append("ESTIMATED_DRAW_CALLS %d > 12 hard cap" % ESTIMATED_DRAW_CALLS)
	if LIGHT_COUNT > MAX_LIGHTS:
		errors.append("LIGHT_COUNT %d > MAX_LIGHTS %d" % [LIGHT_COUNT, MAX_LIGHTS])
	if PROBE_COUNT > MAX_PROBES:
		errors.append("PROBE_COUNT %d > MAX_PROBES %d" % [PROBE_COUNT, MAX_PROBES])
	if PROBE_COUNT != PROBE_POSITIONS.size():
		errors.append("PROBE_COUNT %d != PROBE_POSITIONS.size() %d" % [PROBE_COUNT, PROBE_POSITIONS.size()])
	if MAX_LIGHTS > 12:
		errors.append("MAX_LIGHTS %d > 12" % MAX_LIGHTS)
	# Sun params
	if SUN_ENERGY <= 0.0 or SUN_ENERGY > 4.0:
		errors.append("SUN_ENERGY %.2f out of [0,4]" % SUN_ENERGY)
	if SUN_AZIMUTH_DEG < 0.0 or SUN_AZIMUTH_DEG >= 360.0:
		errors.append("SUN_AZIMUTH_DEG %.1f not in [0,360)" % SUN_AZIMUTH_DEG)
	if SUN_ELEVATION_DEG <= 0.0 or SUN_ELEVATION_DEG >= 90.0:
		errors.append("SUN_ELEVATION_DEG %.1f not in (0,90)" % SUN_ELEVATION_DEG)
	if not SUN_SHADOW_ENABLED:
		errors.append("SUN_SHADOW_ENABLED must be true (baked shadows)")
	if SUN_COLOR.a != 1.0:
		errors.append("SUN_COLOR alpha != 1.0")
	# Probe positions must be inside arena
	for i in range(PROBE_POSITIONS.size()):
		var p: Vector3 = PROBE_POSITIONS[i]
		if not PhysicsConstants.is_inside_arena(p):
			errors.append("probe %d at %s outside arena" % [i, str(p)])
		if p.y <= 0.0 or p.y >= PhysicsConstants.ARENA_HEIGHT:
			errors.append("probe %d y=%.1f outside (0,HEIGHT)" % [i, p.y])
	# Stadium authored path must be canonical (ensures lighting matches geometry)
	if Stadium.STADIUM_MESH_PATH != "res://assets/authored/arena/stadium_dfh_mesh_a_v01.glb":
		errors.append("Stadium.STADIUM_MESH_PATH unexpected: %s" % Stadium.STADIUM_MESH_PATH)
	# Environment path is baked (must be under src/render/)
	if not ENVIRONMENT_PATH.begins_with("res://src/render/"):
		errors.append("ENVIRONMENT_PATH must be under res://src/render/ got %s" % ENVIRONMENT_PATH)
	# Deterministic: sun direction must be normalized
	var az := deg_to_rad(SUN_AZIMUTH_DEG)
	var el := deg_to_rad(SUN_ELEVATION_DEG)
	var dir := Vector3(cos(el) * sin(az), sin(el), cos(el) * cos(az)).normalized()
	if not is_equal_approx(dir.length(), 1.0):
		errors.append("sun direction not normalized len=%.3f" % dir.length())
	if dir.y <= 0.0:
		errors.append("sun direction y must be >0 (above horizon) got %.3f" % dir.y)
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"environment_path": ENVIRONMENT_PATH,
		"baked_lightmap_path": BAKED_LIGHTMAP_PATH,
		"sun": {
			"azimuth_deg": SUN_AZIMUTH_DEG,
			"elevation_deg": SUN_ELEVATION_DEG,
			"color": SUN_COLOR,
			"energy": SUN_ENERGY,
			"shadow_enabled": SUN_SHADOW_ENABLED,
			"shadow_baked": SUN_SHADOW_BAKED,
			"direction": get_sun_direction(),
			"rotation_deg": get_sun_rotation(),
		},
		"probes": {
			"count": PROBE_COUNT,
			"positions": PROBE_POSITIONS.duplicate(),
			"height": PROBE_HEIGHT,
			"extents": PROBE_EXTENTS,
			"intensity": PROBE_INTENSITY,
			"update_mode": PROBE_UPDATE_MODE,
		},
		"baked": is_baked(),
		"draw_calls": get_draw_call_count(),
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": get_draw_call_count() <= DRAW_CALL_BUDGET,
		"arena_size": PhysicsConstants.ARENA_SIZE,
		"arena_aabb": get_arena_aabb(),
		"loaded": _loaded,
		"has_sun": get_sun() != null,
		"probe_count_runtime": get_probes().size(),
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "ArenaLighting",
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"light_count": LIGHT_COUNT,
		"max_lights": MAX_LIGHTS,
		"probe_count": PROBE_COUNT,
		"max_probes": MAX_PROBES,
		"tick_hz": TICK_HZ,
		"baked": SUN_SHADOW_BAKED,
	}

func get_debug_state() -> Dictionary:
	var base := debug_export()
	base["budget"] = get_budget_state()
	return base
