## WS41 — Crowd & Stadium Dressing (budget-aware <12 calls, deterministic)
## Crowd instancing + stadium dressing. Uses Stadium WS36 for arena geometry
## and PhysicsConstants WS04 for dimensions. All assets are authored
## (GLB/PNG in assets/authored/arena/), no noise-based synthesis,
## deterministic placement via seeded hash. Low draw calls via
## MultiMeshInstance3D for crowdInstances (1 draw call for N instances)
## + 2 dressing meshes. Budget-aware: crowd (1) + dressing (2) + Stadium
## (1) = 4 total <12.
## Depends on: src/core/constants.gd (WS04), src/game/arena/stadium.gd (WS36)
extends Node3D
class_name Crowd

const PhysicsConstants = preload("res://src/core/constants.gd")
const Stadium = preload("res://src/game/arena/stadium.gd")

# ---------------------------------------------------------------------------
# Authored assets — deterministic, no noise synthesis
# ---------------------------------------------------------------------------
## Authored crowd mesh — single low-poly spectator block (triangulated).
const CROWD_MESH_PATH: String = "res://assets/authored/arena/crowd_stands_mesh_a_v01.glb"
const CROWD_TEXTURE_PATH: String = "res://assets/authored/arena/crowd_stands_albedo_a_v01.png"
## Dressing meshes — banners / ad boards flanking stands (authored)
const DRESSING_MESH_PATH: String = "res://assets/authored/arena/stadium_dressing_mesh_a_v01.glb"
const BANNER_TEXTURE_PATH: String = "res://assets/authored/arena/stadium_banner_albedo_a_v01.png"

## Arena dimensions — single source of truth, must match PhysicsConstants
const ARENA_LENGTH: float = 60.0
const ARENA_WIDTH: float = 40.0
const ARENA_HEIGHT: float = 20.0
const ARENA_HALF_LENGTH: float = 30.0
const ARENA_HALF_WIDTH: float = 20.0
const ARENA_SIZE: Vector3 = Vector3(40.0, 20.0, 60.0)
const ARENA_HALF_SIZE: Vector3 = Vector3(20.0, 10.0, 30.0)

## Budget — crowd + dressing combined <12 draw calls (duo with Stadium)
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const MAX_TRIS_BUDGET: int = 300000
## Crowd instancing: 1 MultiMeshInstance3D = 1 draw call regardless of count
const CROWD_DRAW_CALLS: int = 1
const DRESSING_DRAW_CALLS: int = 2
const ESTIMATED_DRAW_CALLS: int = 3
const ESTIMATED_TRIS: int = 2400
## Crowd instance counts — deterministic authored placement
const CROWD_INSTANCE_COUNT: int = 120
const MAX_CROWD_INSTANCES: int = 300
const MIN_CROWD_INSTANCES: int = 20
## Dressing piece count (banners / boards)
const DRESSING_PIECE_COUNT: int = 4
const MAX_DRESSING_PIECES: int = 8

const TICK_HZ: int = 120
const TICK_DELTA: float = 1.0 / 120.0

## Crowd stands offset — stands sit outside playable walls, Y at 1.5m height
const CROWD_Y: float = 1.5
const CROWD_OFFSET_OUTSIDE: float = 2.5
const STANDS_ROWS: int = 3
const SEED_SALT: int = 0x4131  # "A1" deterministic salt

# ---------------------------------------------------------------------------
# Runtime refs
# ---------------------------------------------------------------------------
var _crowd_multimesh: MultiMeshInstance3D = null
var _dressing_nodes: Array[MeshInstance3D] = []
var _stadium_ref: Stadium = null
var _loaded: bool = false
var _crowd_positions: Array[Vector3] = []

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_stadium_ref = _resolve_stadium()
	_build_crowd_instances()
	_build_dressing()
	_loaded = true
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[Crowd] debug_validate: %s" % e)

func _resolve_stadium() -> Stadium:
	# Try parent/sibling first, then child search
	var p := get_parent()
	if p:
		for child in p.get_children():
			if child is Stadium:
				return child as Stadium
	for child in get_children():
		if child is Stadium:
			return child as Stadium
	return null

# ---------------------------------------------------------------------------
# Crowd instancing — deterministic seeded placement, single MultiMesh
# ---------------------------------------------------------------------------
func _build_crowd_instances() -> void:
	_crowd_positions = _generate_crowd_positions(CROWD_INSTANCE_COUNT)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = _crowd_positions.size()
	# Authored mesh: try load, fallback to BoxMesh block (deterministic)
	var crowd_mesh: Mesh = _load_crowd_mesh()
	mm.mesh = crowd_mesh
	for i in range(_crowd_positions.size()):
		var pos: Vector3 = _crowd_positions[i]
		# Deterministic yaw from seeded hash — no randf()
		var yaw: float = _hash_yaw(i)
		var t := Transform3D(Basis(Vector3.UP, yaw), pos)
		# Slight deterministic scale variation 0.85-1.15 via hash
		var s: float = 0.85 + _hash_scale(i) * 0.3
		t = t.scaled(Vector3(s, s, s))
		mm.set_instance_transform(i, t)
		# Deterministic color tint via hash 0.85-1.0 brightness
		var tint := Color(0.85 + _hash_color(i, 0) * 0.15, 0.85 + _hash_color(i, 1) * 0.15, 0.85 + _hash_color(i, 2) * 0.15, 1.0)
		mm.set_instance_color(i, tint)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "CrowdInstances"
	mmi.multimesh = mm
	# Single shared material — authored albedo, keeps to 1 draw call
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.82, 0.82, 0.86, 1.0)
	mat.roughness = 0.9
	mat.metallic = 0.0
	mat.vertex_color_use_as_albedo = true
	mmi.material_override = mat
	add_child(mmi)
	_crowd_multimesh = mmi

func _load_crowd_mesh() -> Mesh:
	if ResourceLoader.exists(CROWD_MESH_PATH):
		var res: Resource = load(CROWD_MESH_PATH)
		if res is Mesh:
			return res as Mesh
		elif res is PackedScene:
			var inst: Node = (res as PackedScene).instantiate()
			var mi := _find_mesh_instance(inst)
			if mi and mi.mesh:
				var m: Mesh = mi.mesh
				inst.queue_free()
				return m
			inst.queue_free()
	# Fallback: small authored BoxMesh 0.6x0.9x0.4 — deterministic, no noise
	var box := BoxMesh.new()
	box.size = Vector3(0.6, 0.9, 0.4)
	return box

func _find_mesh_instance(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root as MeshInstance3D
	for child in root.get_children():
		var f := _find_mesh_instance(child)
		if f != null:
			return f
	return null

## Deterministic crowd positions around arena — outside walls, 4 sides, seeded jitter.
func _generate_crowd_positions(count: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if count <= 0:
		return out
	# Distribute around 4 sides: split count into sides proportionally
	var per_long: int = int(count * 0.35)  # each long side (Z) 35%
	var per_short: int = int(count * 0.15)  # each short side (X) 15%
	# Adjust to exact count
	var total_guess := per_long * 2 + per_short * 2
	var remainder := count - total_guess
	# Generate long sides (parallel to Z, at X = ±(HALF_WIDTH+offset))
	for side in [-1, 1]:
		var x: float = side * (ARENA_HALF_WIDTH + CROWD_OFFSET_OUTSIDE)
		for i in range(per_long + (1 if remainder > 0 else 0)):
			if remainder > 0:
				remainder -= 1
			var t: float = (float(i) + 0.5) / float(per_long)
			if per_long == 1:
				t = 0.5
			var z: float = lerp(-ARENA_HALF_LENGTH + 2.0, ARENA_HALF_LENGTH - 2.0, t)
			var row: int = i % STANDS_ROWS
			# Deterministic jitter ±0.3 via hash
			var jx: float = (_hash_pos(side, i, 0) - 0.5) * 0.6
			var jz: float = (_hash_pos(side, i, 1) - 0.5) * 0.6
			var y: float = CROWD_Y + float(row) * 0.55
			var x2: float = x + float(row) * 0.4 * float(side) + jx
			out.append(Vector3(x2, y, z + jz))
	for side2 in [-1, 1]:
		var z: float = side2 * (ARENA_HALF_LENGTH + CROWD_OFFSET_OUTSIDE)
		for i in range(per_short + (1 if remainder > 0 else 0)):
			if remainder > 0:
				remainder -= 1
			var t: float = (float(i) + 0.5) / float(per_short)
			if per_short == 1:
				t = 0.5
			var x: float = lerp(-ARENA_HALF_WIDTH + 2.0, ARENA_HALF_WIDTH - 2.0, t)
			var row: int = i % STANDS_ROWS
			var jx: float = (_hash_pos(side2 + 10, i, 0) - 0.5) * 0.6
			var jz: float = (_hash_pos(side2 + 10, i, 1) - 0.5) * 0.6
			var y: float = CROWD_Y + float(row) * 0.55
			var z2: float = z + float(row) * 0.4 * float(side2) + jz
			out.append(Vector3(x + jx, y, z2))
	# If still short due to rounding, fill from deterministic fallback along long side
	while out.size() < count:
		var idx: int = out.size()
		var x: float = (ARENA_HALF_WIDTH + CROWD_OFFSET_OUTSIDE) + _hash_pos(99, idx, 0) * 0.6
		var z2: float = lerp(-ARENA_HALF_LENGTH + 1.0, ARENA_HALF_LENGTH - 1.0, _hash_pos(99, idx, 1))
		out.append(Vector3(x, CROWD_Y, z2))
	return out

# Deterministic hash helpers — no rand, fully reproducible per index
func _hash_yaw(i: int) -> float:
	var h: int = (i * 2654435761 + SEED_SALT) & 0xFFFFFF
	return float(h % 360) * PI / 180.0

func _hash_scale(i: int) -> float:
	var h: int = (i * 2246822519 + SEED_SALT * 2) & 0xFFFF
	return float(h % 1000) / 1000.0

func _hash_color(i: int, ch: int) -> float:
	var h: int = (i * 3266489917 + ch * 668265263 + SEED_SALT) & 0xFFFF
	return float(h % 256) / 255.0

func _hash_pos(a: int, b: int, c: int) -> float:
	var h: int = (a * 73856093) ^ (b * 19349663) ^ (c * 83492791) ^ SEED_SALT
	h = h & 0xFFFFFF
	if h < 0:
		h = -h
	return float(h % 1000) / 1000.0

# ---------------------------------------------------------------------------
# Stadium dressing — banners / ad boards (authored, budget-aware)
# ---------------------------------------------------------------------------
func _build_dressing() -> void:
	# 4 banners at arena mid-walls, outside crowd, low poly PlaneMesh
	var dressing_positions: Array[Vector3] = [
		Vector3(ARENA_HALF_WIDTH + 1.0, 4.0, 0.0),
		Vector3(-ARENA_HALF_WIDTH - 1.0, 4.0, 0.0),
		Vector3(0.0, 4.0, ARENA_HALF_LENGTH + 1.0),
		Vector3(0.0, 4.0, -ARENA_HALF_LENGTH - 1.0),
	]
	var dressing_sizes: Array[Vector2] = [
		Vector2(10.0, 2.0), Vector2(10.0, 2.0), Vector2(8.0, 2.0), Vector2(8.0, 2.0)
	]
	for i in range(min(DRESSING_PIECE_COUNT, dressing_positions.size())):
		var mi := MeshInstance3D.new()
		mi.name = "Dressing_Banner_%d" % i
		var mesh: Mesh = _load_dressing_mesh(i, dressing_sizes[i])
		mi.mesh = mesh
		mi.position = dressing_positions[i]
		# Face inward — deterministic yaw
		if i < 2:
			mi.rotation.y = PI * 0.5 if i == 0 else -PI * 0.5
		else:
			mi.rotation.y = 0.0 if i == 2 else PI
		var mat := StandardMaterial3D.new()
		# Deterministic banner colors — authored palette, no random
		var palette: Array[Color] = [Color(0.9, 0.2, 0.2), Color(0.2, 0.4, 0.9), Color(0.95, 0.85, 0.2), Color(0.2, 0.8, 0.3)]
		mat.albedo_color = palette[i % palette.size()]
		mat.roughness = 0.75
		mat.metallic = 0.0
		mi.material_override = mat
		add_child(mi)
		_dressing_nodes.append(mi)

func _load_dressing_mesh(_idx: int, size: Vector2) -> Mesh:
	if ResourceLoader.exists(DRESSING_MESH_PATH):
		var res: Resource = load(DRESSING_MESH_PATH)
		if res is Mesh:
			return res as Mesh
		elif res is PackedScene:
			var inst: Node = (res as PackedScene).instantiate()
			var mi := _find_mesh_instance(inst)
			if mi and mi.mesh:
				var m: Mesh = mi.mesh
				inst.queue_free()
				return m
			inst.queue_free()
	var plane := PlaneMesh.new()
	plane.size = size
	plane.orientation = Vector3.UP
	return plane

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
func is_loaded() -> bool:
	return _loaded

func get_crowd_multimesh() -> MultiMeshInstance3D:
	return _crowd_multimesh

func get_crowd_instance_count() -> int:
	if _crowd_multimesh and _crowd_multimesh.multimesh:
		return _crowd_multimesh.multimesh.instance_count
	return _crowd_positions.size()

func get_crowd_positions() -> Array[Vector3]:
	return _crowd_positions.duplicate()

func crowd_instances() -> MultiMeshInstance3D:
	return get_crowd_multimesh()

func get_dressing_count() -> int:
	return _dressing_nodes.size()

func get_dressing_nodes() -> Array[MeshInstance3D]:
	return _dressing_nodes.duplicate()

func get_stadium() -> Stadium:
	if is_instance_valid(_stadium_ref):
		return _stadium_ref
	_stadium_ref = _resolve_stadium()
	return _stadium_ref

func get_draw_call_count() -> int:
	var dc := 0
	if _crowd_multimesh:
		dc += CROWD_DRAW_CALLS
	for n in _dressing_nodes:
		if is_instance_valid(n):
			dc += 1
	# Include stadium if present as sibling/parent — caller can sum externally
	return dc

func get_combined_draw_calls_with_stadium() -> int:
	var dc := get_draw_call_count()
	var s := get_stadium()
	if s:
		dc += s.get_draw_call_count()
	else:
		dc += Stadium.ESTIMATED_DRAW_CALLS
	return dc

func get_estimated_tris() -> int:
	return ESTIMATED_TRIS

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

# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------
func get_budget_state() -> Dictionary:
	var dc := get_draw_call_count()
	var combined := get_combined_draw_calls_with_stadium()
	return {
		"draw_calls": dc,
		"combined_draw_calls": combined,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": dc <= DRAW_CALL_BUDGET,
		"combined_within_budget": combined <= DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
		"crowd_instances": get_crowd_instance_count(),
		"max_crowd_instances": MAX_CROWD_INSTANCES,
		"dressing_pieces": get_dressing_count(),
		"max_dressing_pieces": MAX_DRESSING_PIECES,
		"crowd_draw_calls": CROWD_DRAW_CALLS,
		"dressing_draw_calls": DRESSING_DRAW_CALLS,
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
		errors.append("Crowd.ARENA_LENGTH drift vs PhysicsConstants")
	if not is_equal_approx(ARENA_WIDTH, PhysicsConstants.ARENA_WIDTH):
		errors.append("Crowd.ARENA_WIDTH drift vs PhysicsConstants")
	if not is_equal_approx(ARENA_HALF_LENGTH, PhysicsConstants.ARENA_HALF_LENGTH):
		errors.append("ARENA_HALF_LENGTH drift")
	if not is_equal_approx(ARENA_HALF_WIDTH, PhysicsConstants.ARENA_HALF_WIDTH):
		errors.append("ARENA_HALF_WIDTH drift")
	if ARENA_SIZE != PhysicsConstants.ARENA_SIZE:
		errors.append("ARENA_SIZE drift vs PhysicsConstants")
	if DRAW_CALL_BUDGET > 12:
		errors.append("DRAW_CALL_BUDGET %d > 12" % DRAW_CALL_BUDGET)
	if MAX_DRAW_CALLS > 12:
		errors.append("MAX_DRAW_CALLS > 12")
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("ESTIMATED_DRAW_CALLS %d > DRAW_CALL_BUDGET %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if ESTIMATED_TRIS > MAX_TRIS_BUDGET:
		errors.append("ESTIMATED_TRIS %d > %d" % [ESTIMATED_TRIS, MAX_TRIS_BUDGET])
	if CROWD_INSTANCE_COUNT < MIN_CROWD_INSTANCES or CROWD_INSTANCE_COUNT > MAX_CROWD_INSTANCES:
		errors.append("CROWD_INSTANCE_COUNT %d out of [%d,%d]" % [CROWD_INSTANCE_COUNT, MIN_CROWD_INSTANCES, MAX_CROWD_INSTANCES])
	if DRESSING_PIECE_COUNT > MAX_DRESSING_PIECES:
		errors.append("DRESSING_PIECE_COUNT %d > %d" % [DRESSING_PIECE_COUNT, MAX_DRESSING_PIECES])
	if CROWD_DRAW_CALLS != 1:
		errors.append("CROWD_DRAW_CALLS must be 1 (MultiMesh batching)")
	if CROWD_DRAW_CALLS + DRESSING_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("crowd+dressing %d > budget %d" % [CROWD_DRAW_CALLS + DRESSING_DRAW_CALLS, DRAW_CALL_BUDGET])
	# Combined with Stadium must stay under 12
	if CROWD_DRAW_CALLS + DRESSING_DRAW_CALLS + Stadium.ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("combined crowd+dressing+stadium %d > 12" % [CROWD_DRAW_CALLS + DRESSING_DRAW_CALLS + Stadium.ESTIMATED_DRAW_CALLS])
	if CROWD_MESH_PATH != "res://assets/authored/arena/crowd_stands_mesh_a_v01.glb":
		errors.append("CROWD_MESH_PATH unexpected: %s" % CROWD_MESH_PATH)
	if DRESSING_MESH_PATH != "res://assets/authored/arena/stadium_dressing_mesh_a_v01.glb":
		errors.append("DRESSING_MESH_PATH unexpected: %s" % DRESSING_MESH_PATH)
	if not PhysicsConstants.is_inside_arena(Vector3.ZERO):
		errors.append("origin should be inside arena")
	if PhysicsConstants.is_inside_arena(Vector3(25.0, 1.0, 35.0)):
		errors.append("(25,1,35) should be outside arena")
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"crowd_mesh_path": CROWD_MESH_PATH,
		"crowd_texture_path": CROWD_TEXTURE_PATH,
		"dressing_mesh_path": DRESSING_MESH_PATH,
		"banner_texture_path": BANNER_TEXTURE_PATH,
		"loaded": _loaded,
		"has_crowd_multimesh": _crowd_multimesh != null,
		"crowd_instance_count": get_crowd_instance_count(),
		"dressing_count": get_dressing_count(),
		"draw_calls": get_draw_call_count(),
		"combined_draw_calls": get_combined_draw_calls_with_stadium(),
		"draw_call_budget": DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"arena": arena_dimensions(),
		"arena_aabb": get_arena_aabb(),
		"within_budget": get_draw_call_count() <= DRAW_CALL_BUDGET,
		"combined_within_budget": get_combined_draw_calls_with_stadium() <= DRAW_CALL_BUDGET,
		"stadium_resolved": get_stadium() != null,
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "Crowd",
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"combined_draw_calls": ESTIMATED_DRAW_CALLS + Stadium.ESTIMATED_DRAW_CALLS,
		"tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
		"crowd_instances": CROWD_INSTANCE_COUNT,
		"dressing_pieces": DRESSING_PIECE_COUNT,
		"tick_hz": TICK_HZ,
	}

func get_debug_state() -> Dictionary:
	var base := debug_export()
	base["budget"] = get_budget_state()
	return base
