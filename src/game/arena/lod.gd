## WS45 — Environment LOD & Culling (budget-aware <12 calls, deterministic)
## LOD groups + frustum culling for arena dressing. Uses Stadium WS36 geometry
## and PhysicsConstants WS04 (60×40×20) as single source of truth.
## No procedural noise, no random — deterministic distance thresholds and
## stable frustum tests. Budget-aware: combined arena draw calls stay <12
## after culling; LOD itself adds 0 draw calls (visibility toggling only).
## Depends on: src/core/constants.gd (WS04), src/game/arena/stadium.gd (WS36),
##             tools/perf/budget.json + profiler.gd (WS10)
extends Node3D
class_name ArenaLOD

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
# LOD levels — deterministic, distance-based
# ---------------------------------------------------------------------------
enum LODLevel {
	HIGH = 0,    # full detail, close
	MEDIUM = 1,  # reduced tris / simpler material
	LOW = 2,     # billboard / lowest poly
	CULLED = 3,  # not rendered (frustum or distance)
}

const LOD_COUNT: int = 4

## Distance thresholds in meters from camera to object center.
## Determined from arena half-diagonal ~36m; tuned so near half is HIGH,
## far half is MEDIUM, outside arena is LOW/CULLED. Deterministic.
const LOD_DISTANCE_HIGH: float = 15.0
const LOD_DISTANCE_MEDIUM: float = 35.0
const LOD_DISTANCE_LOW: float = 60.0
const LOD_THRESHOLDS: Array[float] = [15.0, 35.0, 60.0]

## Frustum margin in meters — small expansion avoids flicker at edges.
const FRUSTUM_MARGIN: float = 1.0
## Max cull distance — beyond this always CULLED regardless of frustum.
const MAX_CULL_DISTANCE: float = 70.0

# ---------------------------------------------------------------------------
# LOD groups — arena environment groups sharing a budget
# ---------------------------------------------------------------------------
enum LODGroup {
	STADIUM = 0,
	CROWD = 1,
	DRESSING = 2,
	GOALS = 3,
}

const GROUP_COUNT: int = 4
const GROUP_NAMES: Array[String] = ["stadium", "crowd", "dressing", "goals"]

## Per-group authored AABBs (centered at group centroid, size approximates
## visible bounds). Used for frustum AABB test when Camera3D available.
## Centers outside arena for crowd/dressing (stands sit at ±22.5, ±32).
const GROUP_CENTERS: Array[Vector3] = [
	Vector3(0.0, 2.0, 0.0),        # STADIUM — arena center, low Y
	Vector3(0.0, 2.5, 0.0),        # CROWD — average stands height
	Vector3(0.0, 4.0, 0.0),        # DRESSING — banners at 4m
	Vector3(0.0, 1.05, 0.0),       # GOALS — between the two goals
]
const GROUP_EXTENTS: Array[Vector3] = [
	Vector3(20.0, 10.0, 30.0),     # STADIUM — half arena
	Vector3(22.5, 4.0, 32.5),      # CROWD — stands ring
	Vector3(21.0, 4.0, 31.0),      # DRESSING — banners ring
	Vector3(6.0, 2.0, 30.0),       # GOALS — spans both goal lines
]

# ---------------------------------------------------------------------------
# Budget — WS10 limits + WS45 tighter <12 calls
# ---------------------------------------------------------------------------
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const MAX_TRIS_BUDGET: int = 300000
## LOD itself adds 0 draw calls (only toggles visibility). Managed groups:
## stadium 1 + crowd 1 + dressing 2 + goals 4 (fallback) = 8 peak, <12.
## When culled/LOD, active calls drop to 3-6.
const ESTIMATED_DRAW_CALLS_HIGH: int = 8
const ESTIMATED_DRAW_CALLS_MEDIUM: int = 6
const ESTIMATED_DRAW_CALLS_LOW: int = 3
const ESTIMATED_DRAW_CALLS: int = 8
const ESTIMATED_TRIS_HIGH: int = 4800
const ESTIMATED_TRIS_LOW: int = 1200
const ESTIMATED_TRIS: int = 4800
const TICK_HZ: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Runtime state — deterministic, no per-frame allocation beyond temp dict
# ---------------------------------------------------------------------------
var _camera: Camera3D = null
var _group_lods: Array[int] = [LODLevel.HIGH, LODLevel.HIGH, LODLevel.HIGH, LODLevel.HIGH]
var _group_visible: Array[bool] = [true, true, true, true]
var _group_nodes: Array[Node] = []
var _last_camera_pos: Vector3 = Vector3.ZERO
var _last_update_msec: int = 0
var _update_count: int = 0
var _culled_count: int = 0

# ---------------------------------------------------------------------------
# Lifecycle — deterministic setup, no random
# ---------------------------------------------------------------------------
func _ready() -> void:
	_resolve_camera()
	_resolve_groups()
	_last_camera_pos = _camera_global_pos()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[ArenaLOD] debug_validate: %s" % e)

func _resolve_camera() -> void:
	_camera = get_viewport().get_camera_3d() if is_inside_tree() else null
	if _camera == null:
		_camera = _find_camera(get_tree().current_scene if get_tree() else self)

func _find_camera(root: Node) -> Camera3D:
	if root == null:
		return null
	if root is Camera3D:
		return root as Camera3D
	for child in root.get_children():
		var found := _find_camera(child)
		if found != null:
			return found
	return null

func _resolve_groups() -> void:
	_group_nodes.clear()
	# Try to find sibling arena nodes by class — deterministic order matches GROUP enum
	var parent := get_parent()
	var search_root: Node = parent if parent != null else self
	# Stadium
	var stadium := _find_by_class(search_root, "Stadium")
	_group_nodes.append(stadium)
	# Crowd
	var crowd := _find_by_class(search_root, "Crowd")
	_group_nodes.append(crowd)
	# Dressing is part of Crowd; keep placeholder for group accounting
	_group_nodes.append(crowd)
	# Goals
	var goals := _find_by_class(search_root, "GoalGeometry")
	_group_nodes.append(goals)
	while _group_nodes.size() < GROUP_COUNT:
		_group_nodes.append(null)

func _find_by_class(root: Node, cls_name: String) -> Node:
	if root.get_script() != null:
		# Heuristic: check class_name string via get_class or script resource path
		if root.get_class() == cls_name or (root.has_method("get_draw_call_count") and cls_name in str(root.get_script())):
			return root
	# Fallback: name prefix
	if root.name.begins_with(cls_name) or root.name.begins_with(cls_name.substr(0, 4)):
		return root
	for child in root.get_children():
		var f := _find_by_class(child, cls_name)
		if f != null:
			return f
	return null

func _camera_global_pos() -> Vector3:
	if _camera != null and is_instance_valid(_camera):
		return _camera.global_position
	# Deterministic fallback: arena center elevated (spectator view)
	return Vector3(0.0, 12.0, 18.0)

# ---------------------------------------------------------------------------
# Core LOD + frustum logic — deterministic, no random, no allocation in hot path
# ---------------------------------------------------------------------------

## Deterministic LOD from distance — pure function, no side effects.
static func lod_for_distance(distance: float) -> int:
	if distance < LOD_DISTANCE_HIGH:
		return LODLevel.HIGH
	elif distance < LOD_DISTANCE_MEDIUM:
		return LODLevel.MEDIUM
	elif distance < LOD_DISTANCE_LOW:
		return LODLevel.LOW
	else:
		return LODLevel.CULLED

## Overload with explicit thresholds — deterministic.
static func lod_for_distance_thresholds(distance: float, thresholds: Array[float]) -> int:
	for i in range(thresholds.size()):
		if distance < thresholds[i]:
			return i
	return LODLevel.CULLED

## Frustum test — uses Camera3D.is_position_in_frustum when available,
## otherwise falls back to deterministic dot-product cone test.
## Pure deterministic: same inputs → same bool.
func is_in_frustum(world_pos: Vector3, cam: Camera3D = null) -> bool:
	var c: Camera3D = cam if cam != null else _camera
	if c != null and is_instance_valid(c):
		# Godot 4.x has is_position_in_frustum on Camera3D
		if c.has_method("is_position_in_frustum"):
			return c.is_position_in_frustum(world_pos)
		# Fallback via frustum planes: get_frustum returns Array[Plane]
		if c.has_method("get_frustum"):
			var planes: Array = c.get_frustum()
			for p in planes:
				if p is Plane:
					var plane: Plane = p as Plane
					if plane.distance_to(world_pos) < -FRUSTUM_MARGIN:
						return false
			return true
	# Deterministic fallback without camera: cone test from _last_camera_pos
	return _is_in_frustum_fallback(world_pos, _last_camera_pos)

func _is_in_frustum_fallback(pos: Vector3, cam_pos: Vector3) -> bool:
	# Deterministic: assume 70° FOV looking at origin, cull only far behind camera
	var to_point: Vector3 = pos - cam_pos
	var dist := to_point.length()
	if dist > MAX_CULL_DISTANCE:
		return false
	var cam_forward := (Vector3.ZERO - cam_pos).normalized() if cam_pos.length() > 0.01 else Vector3(0, 0, -1)
	var dir := to_point.normalized() if dist > 0.001 else cam_forward
	# cos(70°/2) ≈ 0.819 — outside this cone is culled in fallback
	if dir.dot(cam_forward) < 0.2:
		# Behind camera — culled
		return false
	return true

## AABB frustum test — deterministic, uses is_in_frustum on 8 corners
## (conservative: visible if any corner passes).
func is_aabb_in_frustum(aabb: AABB, cam: Camera3D = null) -> bool:
	var c: Camera3D = cam if cam != null else _camera
	if c != null and is_instance_valid(c) and c.has_method("is_position_in_frustum"):
		# Test center first (fast path)
		if c.is_position_in_frustum(aabb.get_center()):
			return true
		# Test corners — if any corner visible, AABB is visible
		var corners: Array[Vector3] = _aabb_corners(aabb)
		for corner in corners:
			if c.is_position_in_frustum(corner):
				return true
		return false
	# Fallback: distance + cone on center
	return is_in_frustum(aabb.get_center(), cam)

static func _aabb_corners(aabb: AABB) -> Array[Vector3]:
	var p: Vector3 = aabb.position
	var s: Vector3 = aabb.size
	return [
		p,
		p + Vector3(s.x, 0, 0),
		p + Vector3(0, s.y, 0),
		p + Vector3(0, 0, s.z),
		p + Vector3(s.x, s.y, 0),
		p + Vector3(s.x, 0, s.z),
		p + Vector3(0, s.y, s.z),
		p + s,
	]

## Main update — call from _process or via camera signal. Deterministic:
## same camera pos → same LOD/visibility, no random, no timing dependence.
func update_lod(camera: Camera3D = null) -> Dictionary:
	var cam: Camera3D = camera if camera != null else _camera
	if cam == null or not is_instance_valid(cam):
		_resolve_camera()
		cam = _camera
	var cam_pos: Vector3 = cam.global_position if cam != null and is_instance_valid(cam) else _last_camera_pos
	_last_camera_pos = cam_pos
	_last_update_msec = Time.get_ticks_msec()
	_update_count += 1
	_culled_count = 0
	var result: Dictionary = {}
	for g in range(GROUP_COUNT):
		var center: Vector3 = GROUP_CENTERS[g]
		var dist: float = cam_pos.distance_to(center)
		var lod: int = lod_for_distance(dist)
		# Frustum culling overrides distance LOD (distance-culled stays culled)
		if lod != LODLevel.CULLED:
			var ext: Vector3 = GROUP_EXTENTS[g]
			var aabb := AABB(center - ext, ext * 2.0)
			if not is_aabb_in_frustum(aabb, cam):
				lod = LODLevel.CULLED
		_group_lods[g] = lod
		var vis: bool = lod != LODLevel.CULLED
		_group_visible[g] = vis
		if not vis:
			_culled_count += 1
		_apply_group_visibility(g, lod)
		result[GROUP_NAMES[g]] = {"lod": lod, "lod_name": lod_name(lod), "visible": vis, "distance": dist}
	result["culled_count"] = _culled_count
	result["active_count"] = GROUP_COUNT - _culled_count
	result["camera_pos"] = cam_pos
	result["update_count"] = _update_count
	return result

func _apply_group_visibility(group: int, lod: int) -> void:
	if group < 0 or group >= _group_nodes.size():
		return
	var node: Node = _group_nodes[group]
	if node == null or not is_instance_valid(node):
		return
	var vis: bool = lod != LODLevel.CULLED
	# Toggle visibility deterministically — Node3D.visible
	if node is Node3D:
		(node as Node3D).visible = vis
	elif node.has_method("set_visible"):
		node.set_visible(vis)
	# For LOW lod, we could swap material/visibility of detail children
	# Keep deterministic: LOW still visible but could reduce detail externally
	# Crowd: LOW hides dressing children separately if needed — not forced here

static func lod_name(lod: int) -> String:
	match lod:
		LODLevel.HIGH: return "high"
		LODLevel.MEDIUM: return "medium"
		LODLevel.LOW: return "low"
		LODLevel.CULLED: return "culled"
		_: return "unknown"

# ---------------------------------------------------------------------------
# Public API — deterministic helpers, use PhysicsConstants
# ---------------------------------------------------------------------------
func get_camera() -> Camera3D:
	if _camera != null and is_instance_valid(_camera):
		return _camera
	_resolve_camera()
	return _camera

func get_group_lod(group: int) -> int:
	if group < 0 or group >= _group_lods.size():
		return LODLevel.CULLED
	return _group_lods[group]

func get_group_visible(group: int) -> bool:
	if group < 0 or group >= _group_visible.size():
		return false
	return _group_visible[group]

func get_group_lods() -> Array[int]:
	return _group_lods.duplicate()

func get_group_visibility() -> Array[bool]:
	return _group_visible.duplicate()

func get_culled_count() -> int:
	return _culled_count

func get_active_count() -> int:
	return GROUP_COUNT - _culled_count

func get_update_count() -> int:
	return _update_count

func get_last_camera_pos() -> Vector3:
	return _last_camera_pos

func get_draw_call_count() -> int:
	# LOD manager itself: 0 draw calls. Active groups determine cost.
	var active := get_active_count()
	# Estimate: high groups cost more; use current LOD mix
	var cost := 0
	for g in range(GROUP_COUNT):
		if not _group_visible[g]:
			continue
		match _group_lods[g]:
			LODLevel.HIGH: cost += 2
			LODLevel.MEDIUM: cost += 1
			LODLevel.LOW: cost += 1
			_: pass
	# Clamp to realistic peak
	if cost == 0 and active > 0:
		cost = active
	return mini(cost, ESTIMATED_DRAW_CALLS_HIGH)

func get_estimated_draw_calls() -> int:
	return ESTIMATED_DRAW_CALLS

func get_estimated_tris() -> int:
	var culled_ratio: float = float(_culled_count) / float(GROUP_COUNT) if GROUP_COUNT > 0 else 0.0
	return int(ESTIMATED_TRIS_HIGH * (1.0 - culled_ratio * 0.7))

func get_arena_aabb() -> AABB:
	return PhysicsConstants.arena_aabb()

func get_arena_size() -> Vector3:
	return PhysicsConstants.ARENA_SIZE

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

static func lod_thresholds() -> Array[float]:
	return LOD_THRESHOLDS.duplicate()

# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------
func get_budget_state() -> Dictionary:
	var dc := get_draw_call_count()
	var active := get_active_count()
	return {
		"draw_calls": dc,
		"estimated_draw_calls_high": ESTIMATED_DRAW_CALLS_HIGH,
		"estimated_draw_calls_low": ESTIMATED_DRAW_CALLS_LOW,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": dc <= DRAW_CALL_BUDGET,
		"estimated_tris": get_estimated_tris(),
		"tris_budget": MAX_TRIS_BUDGET,
		"active_groups": active,
		"culled_groups": _culled_count,
		"group_count": GROUP_COUNT,
		"max_draw_calls": MAX_DRAW_CALLS,
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
		errors.append("ArenaLOD.ARENA_LENGTH drift vs PhysicsConstants")
	if not is_equal_approx(ARENA_WIDTH, PhysicsConstants.ARENA_WIDTH):
		errors.append("ArenaLOD.ARENA_WIDTH drift vs PhysicsConstants")
	if not is_equal_approx(ARENA_HALF_LENGTH, PhysicsConstants.ARENA_HALF_LENGTH):
		errors.append("ARENA_HALF_LENGTH drift")
	if not is_equal_approx(ARENA_HALF_WIDTH, PhysicsConstants.ARENA_HALF_WIDTH):
		errors.append("ARENA_HALF_WIDTH drift")
	if ARENA_SIZE != PhysicsConstants.ARENA_SIZE:
		errors.append("ARENA_SIZE drift vs PhysicsConstants")
	if not is_equal_approx(Stadium.ARENA_LENGTH, PhysicsConstants.ARENA_LENGTH):
		errors.append("Stadium.ARENA_LENGTH drift vs PhysicsConstants")
	if DRAW_CALL_BUDGET > 12:
		errors.append("DRAW_CALL_BUDGET %d > 12" % DRAW_CALL_BUDGET)
	if MAX_DRAW_CALLS > 12:
		errors.append("MAX_DRAW_CALLS %d > 12" % MAX_DRAW_CALLS)
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("ESTIMATED_DRAW_CALLS %d > DRAW_CALL_BUDGET %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if ESTIMATED_DRAW_CALLS_HIGH > DRAW_CALL_BUDGET:
		errors.append("ESTIMATED_DRAW_CALLS_HIGH %d > 12" % ESTIMATED_DRAW_CALLS_HIGH)
	if ESTIMATED_TRIS > MAX_TRIS_BUDGET:
		errors.append("ESTIMATED_TRIS %d > %d" % [ESTIMATED_TRIS, MAX_TRIS_BUDGET])
	if ESTIMATED_TRIS_HIGH > MAX_TRIS_BUDGET:
		errors.append("ESTIMATED_TRIS_HIGH %d > %d" % [ESTIMATED_TRIS_HIGH, MAX_TRIS_BUDGET])
	if LOD_THRESHOLDS.size() != 3:
		errors.append("LOD_THRESHOLDS size %d != 3" % LOD_THRESHOLDS.size())
	if not is_equal_approx(LOD_DISTANCE_HIGH, 15.0):
		errors.append("LOD_DISTANCE_HIGH != 15.0")
	if not is_equal_approx(LOD_DISTANCE_MEDIUM, 35.0):
		errors.append("LOD_DISTANCE_MEDIUM != 35.0")
	if not is_equal_approx(LOD_DISTANCE_LOW, 60.0):
		errors.append("LOD_DISTANCE_LOW != 60.0")
	if LOD_THRESHOLDS[0] >= LOD_THRESHOLDS[1] or LOD_THRESHOLDS[1] >= LOD_THRESHOLDS[2]:
		errors.append("LOD_THRESHOLDS not strictly increasing: %s" % str(LOD_THRESHOLDS))
	if MAX_CULL_DISTANCE <= LOD_DISTANCE_LOW:
		errors.append("MAX_CULL_DISTANCE %.1f must be > LOD_DISTANCE_LOW %.1f" % [MAX_CULL_DISTANCE, LOD_DISTANCE_LOW])
	if GROUP_COUNT != 4:
		errors.append("GROUP_COUNT %d != 4" % GROUP_COUNT)
	if GROUP_NAMES.size() != GROUP_COUNT:
		errors.append("GROUP_NAMES size != GROUP_COUNT")
	if GROUP_CENTERS.size() != GROUP_COUNT:
		errors.append("GROUP_CENTERS size != GROUP_COUNT")
	if GROUP_EXTENTS.size() != GROUP_COUNT:
		errors.append("GROUP_EXTENTS size != GROUP_COUNT")
	if not is_equal_approx(FRUSTUM_MARGIN, 1.0):
		errors.append("FRUSTUM_MARGIN != 1.0")
	# Deterministic LOD checks
	if lod_for_distance(0.0) != LODLevel.HIGH:
		errors.append("lod_for_distance(0) != HIGH")
	if lod_for_distance(14.9) != LODLevel.HIGH:
		errors.append("lod_for_distance(14.9) != HIGH")
	if lod_for_distance(15.0) != LODLevel.MEDIUM:
		errors.append("lod_for_distance(15.0) != MEDIUM")
	if lod_for_distance(34.9) != LODLevel.MEDIUM:
		errors.append("lod_for_distance(34.9) != MEDIUM")
	if lod_for_distance(35.0) != LODLevel.LOW:
		errors.append("lod_for_distance(35) != LOW")
	if lod_for_distance(59.9) != LODLevel.LOW:
		errors.append("lod_for_distance(59.9) != LOW")
	if lod_for_distance(60.0) != LODLevel.CULLED:
		errors.append("lod_for_distance(60) != CULLED")
	if lod_for_distance(100.0) != LODLevel.CULLED:
		errors.append("lod_for_distance(100) != CULLED")
	if not PhysicsConstants.is_inside_arena(Vector3.ZERO):
		errors.append("origin should be inside arena")
	if PhysicsConstants.is_inside_arena(Vector3(25.0, 1.0, 35.0)):
		errors.append("(25,1,35) should be outside arena")
	if Stadium.STADIUM_MESH_PATH != "res://assets/authored/arena/stadium_dfh_mesh_a_v01.glb":
		errors.append("Stadium.STADIUM_MESH_PATH unexpected: %s" % Stadium.STADIUM_MESH_PATH)
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"arena": arena_dimensions(),
		"arena_aabb": get_arena_aabb(),
		"lod_thresholds": LOD_THRESHOLDS.duplicate(),
		"lod_distances": {"high": LOD_DISTANCE_HIGH, "medium": LOD_DISTANCE_MEDIUM, "low": LOD_DISTANCE_LOW, "cull": MAX_CULL_DISTANCE},
		"frustum_margin": FRUSTUM_MARGIN,
		"groups": {
			"count": GROUP_COUNT,
			"names": GROUP_NAMES.duplicate(),
			"centers": GROUP_CENTERS.duplicate(),
			"extents": GROUP_EXTENTS.duplicate(),
			"lods": get_group_lods(),
			"visible": get_group_visibility(),
			"culled_count": _culled_count,
			"active_count": get_active_count(),
		},
		"camera_pos": _last_camera_pos,
		"update_count": _update_count,
		"draw_calls": get_draw_call_count(),
		"estimated_draw_calls": ESTIMATED_DRAW_CALLS,
		"estimated_tris": get_estimated_tris(),
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": get_draw_call_count() <= DRAW_CALL_BUDGET,
		"has_camera": get_camera() != null,
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "ArenaLOD",
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
		"groups": GROUP_COUNT,
		"lod_levels": LOD_COUNT,
		"tick_hz": TICK_HZ,
		"uses_perf_budget": "WS10",
	}

func get_debug_state() -> Dictionary:
	var base := debug_export()
	base["budget"] = get_budget_state()
	return base
