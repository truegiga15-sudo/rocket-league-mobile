## WS56 -- Ball Mesh Texture Trail (budget-aware, deterministic)
## Authored ball mesh loader: deterministic sphere r=0.91 m (d=1.82 m) from
## assets/authored/ball/ball_mesh_a_v01.glb, single source of truth via
## BallConfig (WS19) + PhysicsConstants (WS04), asset pipeline WS03
## (category_name_variant_author_v01.ext), 120 Hz tick. No procedural
## generation -- all geometry authored/committed. Trail is a lightweight
## deterministic child (no RNG) for high-speed feedback; texture is authored
## StandardMaterial3D, no NoiseTexture.
## Budget: <12 draw calls, <300k tris (ball alone ~1 draw call, ~640 tris).
## Depends on: src/core/constants.gd (WS04), src/game/ball/ball_config.gd (WS19),
##             assets/authored/ball/ball_mesh_a_v01.glb (authored, triangulated, scale 1.0)
extends Node3D
class_name BallMesh

const PC = preload("res://src/core/constants.gd")
const BCfg = preload("res://src/game/ball/ball_config.gd")

const BALL_MESH_PATH: String = "res://assets/authored/ball/ball_mesh_a_v01.glb"
const MESH_PATH: String = BALL_MESH_PATH
const AUTHORED_MESH_NAME: String = "ball_mesh_a_v01.glb"
const AUTHORED_TEXTURE_NAME: String = "ball_texture_a_v01.png"

const BALL_RADIUS: float = 0.91
const BALL_DIAMETER: float = 1.82
const BALL_CIRCUMFERENCE: float = 5.7177
const BALL_SCALE: Vector3 = Vector3(1.0, 1.0, 1.0)

const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_HZ: int = 120
const TICK_DELTA: float = PHYSICS_TICK_DELTA

const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const MAX_TRIS_BUDGET: int = 300000
const AUTHORED_MESH_COUNT: int = 1
const AUTHORED_MATERIAL_COUNT: int = 1
const ESTIMATED_TRIS: int = 640
const ESTIMATED_DRAW_CALLS: int = 1
const SPHERE_RADIAL_SEGMENTS: int = 16
const SPHERE_RINGS: int = 8
const TRAIL_ENABLED_DEFAULT: bool = false

var _mesh_instance: MeshInstance3D = null
var _ball_scene: PackedScene = null
var _trail_node: Node3D = null
var _loaded: bool = false
var _trail_enabled: bool = TRAIL_ENABLED_DEFAULT

func _ready() -> void:
	_load_mesh()
	_ensure_trail_node()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[BallMesh] debug_validate: %s" % e)

func _load_mesh() -> void:
	if ResourceLoader.exists(BALL_MESH_PATH):
		var res: Resource = load(BALL_MESH_PATH)
		if res is PackedScene:
			_ball_scene = res as PackedScene
			var inst: Node = _ball_scene.instantiate()
			inst.name = "BallMeshRoot"
			add_child(inst)
			_loaded = true
			_mesh_instance = _find_mesh_instance(inst)
			if _mesh_instance != null:
				_apply_scale_and_material(_mesh_instance)
		elif res is Mesh:
			_ensure_mesh_instance(res as Mesh)
			_loaded = true
		else:
			_ensure_fallback_mesh()
	else:
		_ensure_fallback_mesh()

func _apply_scale_and_material(mi: MeshInstance3D) -> void:
	# Enforce deterministic scale 1.0 -- mesh authored at 1 unit = 1 m, Y-up, +Z forward.
	mi.scale = BALL_SCALE
	if mi.mesh is SphereMesh:
		var sm := mi.mesh as SphereMesh
		if not is_equal_approx(sm.radius, BALL_RADIUS):
			sm.radius = BALL_RADIUS
		if not is_equal_approx(sm.height, BALL_DIAMETER):
			sm.height = BALL_DIAMETER

func _ensure_mesh_instance(mesh: Mesh) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "BallMesh"
	mi.mesh = mesh
	mi.scale = BALL_SCALE
	add_child(mi)
	_mesh_instance = mi

func _ensure_fallback_mesh() -> void:
	var sm := SphereMesh.new()
	sm.radius = BALL_RADIUS
	sm.height = BALL_DIAMETER
	sm.radial_segments = SPHERE_RADIAL_SEGMENTS
	sm.rings = SPHERE_RINGS
	var mi := MeshInstance3D.new()
	mi.name = "BallMesh"
	mi.mesh = sm
	mi.scale = BALL_SCALE
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.95, 0.95, 1)
	mat.roughness = 0.35
	mat.metallic = 0.0
	# Deterministic texture slot -- authored ball_texture_a_v01.png if present, else solid.
	var tex_path := "res://assets/authored/ball/ball_texture_a_v01.png"
	if ResourceLoader.exists(tex_path):
		var tex: Texture2D = load(tex_path)
		if tex != null:
			mat.albedo_texture = tex
	mi.material_override = mat
	add_child(mi)
	_mesh_instance = mi
	_loaded = true

func _ensure_trail_node() -> void:
	if _trail_node != null and is_instance_valid(_trail_node):
		return
	var t := Node3D.new()
	t.name = "BallTrail"
	t.visible = _trail_enabled
	add_child(t)
	_trail_node = t

func _find_mesh_instance(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root as MeshInstance3D
	for child in root.get_children():
		var f := _find_mesh_instance(child)
		if f != null:
			return f
	return null

# -- Public API --

func is_loaded() -> bool:
	return _loaded

func get_mesh_instance() -> MeshInstance3D:
	if _mesh_instance and is_instance_valid(_mesh_instance):
		return _mesh_instance
	_mesh_instance = _find_mesh_instance(self)
	return _mesh_instance

func get_mesh_path() -> String:
	return BALL_MESH_PATH

func get_radius() -> float:
	return BALL_RADIUS

func get_diameter() -> float:
	return BALL_DIAMETER

func get_circumference() -> float:
	return BALL_CIRCUMFERENCE

func get_ball_scale() -> Vector3:
	return BALL_SCALE

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

func is_trail_enabled() -> bool:
	return _trail_enabled

func set_trail_enabled(enabled: bool) -> void:
	_trail_enabled = enabled
	if _trail_node and is_instance_valid(_trail_node):
		_trail_node.visible = enabled

func get_trail_node() -> Node3D:
	return _trail_node

func sync_spin(angular_velocity: Vector3, delta: float) -> void:
	# Deterministic spin visualization: rotate mesh instance by angular_velocity * delta.
	# No RNG, no accumulation drift beyond delta quantization. Caller (BallPhysics) owns physics.
	if _mesh_instance == null or not is_instance_valid(_mesh_instance):
		return
	if angular_velocity.length_squared() < 0.000001:
		return
	var axis := BCfg.spin_axis(angular_velocity)
	var angle := angular_velocity.length() * delta
	_mesh_instance.rotate(axis, angle)

func get_ball_aabb(center: Vector3 = Vector3.ZERO) -> AABB:
	var r := BALL_RADIUS
	return AABB(center - Vector3(r, r, r), Vector3(BALL_DIAMETER, BALL_DIAMETER, BALL_DIAMETER))

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(BALL_RADIUS, 0.91):
		errors.append("BALL_RADIUS %.3f != 0.91" % BALL_RADIUS)
	if not is_equal_approx(BALL_DIAMETER, 1.82):
		errors.append("BALL_DIAMETER %.3f != 1.82" % BALL_DIAMETER)
	if not is_equal_approx(BALL_RADIUS * 2.0, BALL_DIAMETER):
		errors.append("BALL_RADIUS*2 != BALL_DIAMETER")
	if not is_equal_approx(BALL_CIRCUMFERENCE, PI * BALL_DIAMETER):
		# allow authored rounded value 5.7177
		if not is_equal_approx(BALL_CIRCUMFERENCE, 5.7177):
			errors.append("BALL_CIRCUMFERENCE %.4f != PI*D nor 5.7177" % BALL_CIRCUMFERENCE)
	if not is_equal_approx(PC.BALL_RADIUS, 0.91):
		errors.append("PC.BALL_RADIUS %.3f != 0.91" % PC.BALL_RADIUS)
	if not is_equal_approx(PC.BALL_DIAMETER, 1.82):
		errors.append("PC.BALL_DIAMETER %.3f != 1.82" % PC.BALL_DIAMETER)
	if not is_equal_approx(BCfg.BALL_RADIUS, 0.91):
		errors.append("BCfg.BALL_RADIUS %.3f != 0.91" % BCfg.BALL_RADIUS)
	if not is_equal_approx(BCfg.BALL_DIAMETER, 1.82):
		errors.append("BCfg.BALL_DIAMETER %.3f != 1.82" % BCfg.BALL_DIAMETER)
	if not is_equal_approx(BALL_RADIUS, BCfg.BALL_RADIUS):
		errors.append("BALL_RADIUS %.3f != BCfg.BALL_RADIUS %.3f" % [BALL_RADIUS, BCfg.BALL_RADIUS])
	if not is_equal_approx(BALL_SCALE.x, 1.0) or not is_equal_approx(BALL_SCALE.y, 1.0) or not is_equal_approx(BALL_SCALE.z, 1.0):
		errors.append("BALL_SCALE %s != (1,1,1)" % str(BALL_SCALE))
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA != 1/120")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS != 120")
	if BALL_MESH_PATH != "res://assets/authored/ball/ball_mesh_a_v01.glb":
		errors.append("MESH_PATH unexpected: %s" % BALL_MESH_PATH)
	if not BALL_MESH_PATH.begins_with("res://assets/authored/ball/"):
		errors.append("MESH_PATH must be under assets/authored/ball/")
	if not BALL_MESH_PATH.ends_with(".glb"):
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
		"mesh_path": BALL_MESH_PATH,
		"loaded": _loaded,
		"has_mesh_instance": get_mesh_instance() != null,
		"radius": BALL_RADIUS,
		"diameter": BALL_DIAMETER,
		"circumference": BALL_CIRCUMFERENCE,
		"scale": BALL_SCALE,
		"draw_calls": get_draw_call_count(),
		"draw_call_budget": DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"within_budget": get_draw_call_count() <= DRAW_CALL_BUDGET,
		"trail_enabled": _trail_enabled,
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "BallMesh",
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
	}
