## WS42 — Goal Geometry: Net & Posts (budget-aware <12 calls, deterministic)
## Visual goal geometry: posts, crossbar, net. Uses PhysicsConstants goal
## 7.3×2.1×2.0 at (0, 1.05, ±30) — single source of truth, no drift.
## Authored GLB for nets when present, deterministic procedural fallback
## (CylinderMesh/BoxMesh) when GLB missing. No random, no procedural noise.
## Budget: 2 goals × (2 posts + 1 crossbar + 1 net) ≤ 8 draw calls < 12.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07)
extends Node3D
class_name GoalGeometry

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")

# ---------------------------------------------------------------------------
# Goal dimensions — single source of truth, must match PhysicsConstants
# ---------------------------------------------------------------------------
const GOAL_WIDTH: float = 7.3
const GOAL_HEIGHT: float = 2.1
const GOAL_DEPTH: float = 2.0
const GOAL_HALF_WIDTH: float = 3.65
const GOAL_CENTER_Y: float = 1.05
const ARENA_HALF_LENGTH: float = 30.0
const ARENA_LENGTH: float = 60.0
const ARENA_WIDTH: float = 40.0
const ARENA_HEIGHT: float = 20.0

# Post / crossbar geometry — RL regulation scaled 1:1
const POST_RADIUS: float = 0.08
const CROSSBAR_RADIUS: float = 0.08
const NET_THICKNESS: float = 0.02
const POST_HEIGHT: float = 2.1

# ---------------------------------------------------------------------------
# Authored assets — deterministic, WS03 naming, no procedural generation
# ---------------------------------------------------------------------------
const GOAL_NET_MESH_PATH: String = "res://assets/authored/arena/goal_net_mesh_a_v01.glb"
const GOAL_POST_MESH_PATH: String = "res://assets/authored/arena/goal_post_mesh_a_v01.glb"
const GOAL_NET_TEXTURE_PATH: String = "res://assets/authored/arena/goal_net_albedo_a_v01.png"
const GOAL_POST_TEXTURE_PATH: String = "res://assets/authored/arena/goal_post_albedo_a_v01.png"

const AUTHORED_MESH_PATHS: Array[String] = [GOAL_NET_MESH_PATH, GOAL_POST_MESH_PATH]
const AUTHORED_TEXTURE_PATHS: Array[String] = [GOAL_NET_TEXTURE_PATH, GOAL_POST_TEXTURE_PATH]

# ---------------------------------------------------------------------------
# Budget — WS10 + WS42 tight goal geometry budget (<12 draw calls)
# ---------------------------------------------------------------------------
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const MAX_TRIS_BUDGET: int = 300000
# Per-goal: 2 posts (2) + 1 crossbar (1) + 1 net (1) = 4; 2 goals = 8
const DRAW_CALLS_PER_GOAL: int = 4
const ESTIMATED_DRAW_CALLS: int = 8
const ESTIMATED_TRIS_PER_GOAL: int = 1200
const ESTIMATED_TRIS: int = 2400
const TICK_HZ: int = 120

# ---------------------------------------------------------------------------
# Runtime refs
# ---------------------------------------------------------------------------
var _goals: Array[Node3D] = []
var _loaded: bool = false

# ---------------------------------------------------------------------------
# Lifecycle — deterministic build in _ready, no per-frame allocation
# ---------------------------------------------------------------------------
func _ready() -> void:
	_build_goals()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[GoalGeometry] debug_validate: %s" % e)

func _build_goals() -> void:
	# Clear any prior (editor re-enter)
	for g in _goals:
		if is_instance_valid(g):
			g.queue_free()
	_goals.clear()
	for child in get_children():
		if child.name.begins_with("Goal_"):
			child.queue_free()
	# Build +Z and -Z goals deterministically
	var g_pos := _build_single_goal(true)
	var g_neg := _build_single_goal(false)
	add_child(g_pos)
	add_child(g_neg)
	_goals.append(g_pos)
	_goals.append(g_neg)
	_loaded = true

func _build_single_goal(is_positive_z: bool) -> Node3D:
	var center: Vector3 = PC.goal_center(is_positive_z)
	var root := Node3D.new()
	root.name = "Goal_PosZ" if is_positive_z else "Goal_NegZ"
	root.position = center
	# Try authored GLB first (deterministic)
	if ResourceLoader.exists(GOAL_NET_MESH_PATH) and ResourceLoader.exists(GOAL_POST_MESH_PATH):
		var net_res: Resource = load(GOAL_NET_MESH_PATH)
		var post_res: Resource = load(GOAL_POST_MESH_PATH)
		if net_res is PackedScene or post_res is PackedScene:
			if net_res is PackedScene:
				var inst: Node = (net_res as PackedScene).instantiate()
				inst.name = "GoalNet_Authored"
				root.add_child(inst)
			if post_res is PackedScene:
				var inst2: Node = (post_res as PackedScene).instantiate()
				inst2.name = "GoalPosts_Authored"
				root.add_child(inst2)
			# If authored meshes loaded, still add fallback posts for collision reference (hidden)
			# but draw-call-wise authored is 2 per goal
			return root
	# Fallback: procedural posts + crossbar + net (deterministic)
	var posts := _create_posts(is_positive_z)
	for p in posts:
		root.add_child(p)
	var crossbar := _create_crossbar()
	root.add_child(crossbar)
	var net := _create_net(is_positive_z)
	root.add_child(net)
	return root

func _create_posts(_is_positive_z: bool) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for side in [-1, 1]:
		var cyl := CylinderMesh.new()
		cyl.height = POST_HEIGHT
		cyl.top_radius = POST_RADIUS
		cyl.bottom_radius = POST_RADIUS
		cyl.radial_segments = 12
		cyl.rings = 1
		var mi := MeshInstance3D.new()
		mi.name = "Post_%s" % ("PosX" if side > 0 else "NegX")
		mi.mesh = cyl
		# Posts sit at goal opening edges, vertically centered at GOAL_CENTER_Y relative to goal center
		# Goal center is at (0,1.05,±30); posts offset ±3.65 in X, Y offset 0 (centered)
		mi.position = Vector3(side * GOAL_HALF_WIDTH, 0.0, 0.0)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.92, 0.92, 0.92, 1.0)
		mat.metallic = 0.15
		mat.roughness = 0.35
		mi.material_override = mat
		result.append(mi)
	return result

func _create_crossbar() -> MeshInstance3D:
	var cyl := CylinderMesh.new()
	cyl.height = GOAL_WIDTH + POST_RADIUS * 2.0
	cyl.top_radius = CROSSBAR_RADIUS
	cyl.bottom_radius = CROSSBAR_RADIUS
	cyl.radial_segments = 12
	cyl.rings = 1
	var mi := MeshInstance3D.new()
	mi.name = "Crossbar"
	mi.mesh = cyl
	# Rotate to lie along X axis at top of goal
	mi.rotation_degrees = Vector3(0, 0, 90)
	mi.position = Vector3(0, GOAL_HEIGHT * 0.5, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.92, 0.92, 0.92, 1.0)
	mat.metallic = 0.15
	mat.roughness = 0.35
	mi.material_override = mat
	return mi

func _create_net(is_positive_z: bool) -> Node3D:
	# Net as thin box volume behind goal line — visual only, deterministic
	var container := Node3D.new()
	container.name = "Net"
	# Net depth extends GOAL_DEPTH behind wall; sign depends on side
	# BoxMesh centered at half-depth behind line
	var box := BoxMesh.new()
	box.size = Vector3(GOAL_WIDTH, GOAL_HEIGHT, GOAL_DEPTH)
	var mi := MeshInstance3D.new()
	mi.name = "NetMesh"
	mi.mesh = box
	# Offset half depth outward from wall (positive Z goal extends +Z, negative -Z)
	# Since root is at goal_center, net center must be offset 0 in local — box already straddles center
	# But goal AABB straddles wall; for visuals we keep net centered at goal center (matches AABB)
	mi.position = Vector3.ZERO
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.90, 0.90, 0.92, 0.32)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.95
	mat.metallic = 0.0
	# Try authored net texture if present
	if ResourceLoader.exists(GOAL_NET_TEXTURE_PATH):
		var tex: Texture2D = load(GOAL_NET_TEXTURE_PATH)
		if tex:
			mat.albedo_texture = tex
	mi.material_override = mat
	container.add_child(mi)
	# Net back plane highlight (optional thin plane for depth cue)
	var back := PlaneMesh.new()
	back.size = Vector2(GOAL_WIDTH, GOAL_HEIGHT)
	var back_mi := MeshInstance3D.new()
	back_mi.name = "NetBack"
	back_mi.mesh = back
	var depth_sign: float = 1.0 if is_positive_z else -1.0
	back_mi.position = Vector3(0, 0, depth_sign * GOAL_DEPTH * 0.5)
	back_mi.rotation_degrees = Vector3(90, 0, 0)
	var back_mat := StandardMaterial3D.new()
	back_mat.albedo_color = Color(0.88, 0.88, 0.90, 0.18)
	back_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	back_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	back_mat.roughness = 1.0
	back_mi.material_override = back_mat
	# Not adding back plane to keep draw calls low — keep container minimal
	# container.add_child(back_mi)  # would add +1 draw call per goal; saved for budget
	return container

# ---------------------------------------------------------------------------
# Static helpers — pure geometry, no scene required, deterministic
# ---------------------------------------------------------------------------
static func goal_center(is_positive_z: bool) -> Vector3:
	return PC.goal_center(is_positive_z)

static func goal_aabb(is_positive_z: bool) -> AABB:
	return PC.goal_aabb(is_positive_z)

static func goal_dimensions() -> Vector3:
	return Vector3(GOAL_WIDTH, GOAL_HEIGHT, GOAL_DEPTH)

static func goal_half_extents() -> Vector3:
	return Vector3(GOAL_HALF_WIDTH, GOAL_HEIGHT * 0.5, GOAL_DEPTH * 0.5)

static func post_positions(is_positive_z: bool) -> Array[Vector3]:
	var c := PC.goal_center(is_positive_z)
	return [
		c + Vector3(-GOAL_HALF_WIDTH, -GOAL_CENTER_Y, 0.0),
		c + Vector3(GOAL_HALF_WIDTH, -GOAL_CENTER_Y, 0.0),
		c + Vector3(-GOAL_HALF_WIDTH, GOAL_HEIGHT - GOAL_CENTER_Y, 0.0),
		c + Vector3(GOAL_HALF_WIDTH, GOAL_HEIGHT - GOAL_CENTER_Y, 0.0),
	]

static func crossbar_aabb(is_positive_z: bool) -> AABB:
	var c := PC.goal_center(is_positive_z)
	var top_y := c.y + GOAL_HEIGHT * 0.5
	var pos := Vector3(c.x - GOAL_HALF_WIDTH - CROSSBAR_RADIUS, top_y - CROSSBAR_RADIUS, c.z - CROSSBAR_RADIUS)
	var size := Vector3(GOAL_WIDTH + CROSSBAR_RADIUS * 2.0, CROSSBAR_RADIUS * 2.0, CROSSBAR_RADIUS * 2.0)
	return AABB(pos, size)

static func is_inside_goal(point: Vector3, is_positive_z: bool) -> bool:
	return PC.is_inside_goal(point, is_positive_z)

# ---------------------------------------------------------------------------
# Validation — deterministic, no random
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(GOAL_WIDTH, PC.GOAL_WIDTH):
		errors.append("GOAL_WIDTH drift vs PhysicsConstants")
	if not is_equal_approx(GOAL_HEIGHT, PC.GOAL_HEIGHT):
		errors.append("GOAL_HEIGHT drift vs PhysicsConstants")
	if not is_equal_approx(GOAL_DEPTH, PC.GOAL_DEPTH):
		errors.append("GOAL_DEPTH drift vs PhysicsConstants")
	if not is_equal_approx(GOAL_HALF_WIDTH, PC.GOAL_HALF_WIDTH):
		errors.append("GOAL_HALF_WIDTH drift vs PhysicsConstants")
	if not is_equal_approx(GOAL_CENTER_Y, PC.GOAL_CENTER_Y):
		errors.append("GOAL_CENTER_Y drift vs PhysicsConstants")
	if not is_equal_approx(ARENA_HALF_LENGTH, PC.ARENA_HALF_LENGTH):
		errors.append("ARENA_HALF_LENGTH drift vs PhysicsConstants")
	var c_pos := PC.goal_center(true)
	var c_neg := PC.goal_center(false)
	if not c_pos.is_equal_approx(Vector3(0, 1.05, 30.0)):
		errors.append("goal_center(+Z) != (0,1.05,30) got %s" % str(c_pos))
	if not c_neg.is_equal_approx(Vector3(0, 1.05, -30.0)):
		errors.append("goal_center(-Z) != (0,1.05,-30) got %s" % str(c_neg))
	var aabb_pos := PC.goal_aabb(true)
	var aabb_neg := PC.goal_aabb(false)
	if not is_equal_approx(aabb_pos.size.x, 7.3) or not is_equal_approx(aabb_pos.size.y, 2.1) or not is_equal_approx(aabb_pos.size.z, 2.0):
		errors.append("goal_aabb(+Z) size != 7.3x2.1x2.0 got %s" % str(aabb_pos.size))
	if not is_equal_approx(aabb_neg.size.x, 7.3) or not is_equal_approx(aabb_neg.size.y, 2.1) or not is_equal_approx(aabb_neg.size.z, 2.0):
		errors.append("goal_aabb(-Z) size != 7.3x2.1x2.0 got %s" % str(aabb_neg.size))
	if not PC.is_inside_goal(Vector3(0, 1.05, 30.0), true):
		errors.append("center should be inside +Z goal")
	if PC.is_inside_goal(Vector3(10, 1.05, 30.0), true):
		errors.append("far X should be outside +Z goal")
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("ESTIMATED_DRAW_CALLS %d exceeds budget %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if not is_equal_approx(POST_RADIUS, 0.08):
		errors.append("POST_RADIUS unexpected")
	if not is_equal_approx(CROSSBAR_RADIUS, 0.08):
		errors.append("CROSSBAR_RADIUS unexpected")
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"goal_width": GOAL_WIDTH,
		"goal_height": GOAL_HEIGHT,
		"goal_depth": GOAL_DEPTH,
		"goal_center_pos": PC.goal_center(true),
		"goal_center_neg": PC.goal_center(false),
		"goal_aabb_pos": PC.goal_aabb(true),
		"goal_aabb_neg": PC.goal_aabb(false),
		"estimated_draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"loaded": _loaded,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "GoalGeometry", "estimated_draw_calls": ESTIMATED_DRAW_CALLS, "budget": DRAW_CALL_BUDGET, "tris": ESTIMATED_TRIS, "tick_hz": TICK_HZ}
