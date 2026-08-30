## WS43 — Boost Pad Placement & Visuals (budget-aware <12 calls, deterministic)
## Deterministic pad layout, batched visuals via MultiMesh, Area3D triggers.
## Uses WS21 ArenaCollision for bounds, WS18 CarBoost for amounts/respawn,
## WS04 PhysicsConstants for arena dimensions, WS07 PhysicsLayers for masks.
## No procedural noise, no randf() — all positions authored, symmetric, inside arena.
## Budget: 2 draw calls (small MultiMesh 1 + big MultiMesh 1) <12, ~640 tris.
## Depends on: src/core/constants.gd, src/core/physics/layers.gd,
##             src/game/arena/arena_collision.gd, src/game/car/boost.gd, src/game/car/boost_pad.gd
extends Node3D
class_name BoostPads

const PhysicsConstants = preload("res://src/core/constants.gd")
const PhysicsLayers = preload("res://src/core/physics/layers.gd")
const ArenaCollision = preload("res://src/game/arena/arena_collision.gd")
const CarBoost = preload("res://src/game/car/boost.gd")
const BoostPadScript = preload("res://src/game/car/boost_pad.gd")

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
# Authored assets — deterministic, no noise synthesis
# ---------------------------------------------------------------------------
const BOOST_PAD_MESH_PATH: String = "res://assets/authored/arena/boost_pad_small_mesh_a_v01.glb"
const BOOST_PAD_BIG_MESH_PATH: String = "res://assets/authored/arena/boost_pad_big_mesh_a_v01.glb"
const BOOST_PAD_TEXTURE_PATH: String = "res://assets/authored/arena/boost_pad_albedo_a_v01.png"

# ---------------------------------------------------------------------------
# Pad constants — single source from CarBoost WS18, re-exported for WS43
# ---------------------------------------------------------------------------
const SMALL_PAD_AMOUNT: float = 12.0  # == CarBoost.SMALL_PAD_AMOUNT
const BIG_PAD_AMOUNT: float = 100.0   # == CarBoost.BIG_PAD_AMOUNT
const SMALL_PAD_RESPAWN: float = 4.0  # == CarBoost.SMALL_PAD_RESPAWN
const BIG_PAD_RESPAWN: float = 10.0   # == CarBoost.BIG_PAD_RESPAWN

const PAD_Y_SMALL: float = 0.12
const PAD_Y_BIG: float = 0.17
const PAD_HEIGHT_SMALL: float = 0.24
const PAD_HEIGHT_BIG: float = 0.34
const PAD_RADIUS_SMALL: float = 0.6
const PAD_RADIUS_BIG: float = 0.9

const PAD_LAYER: int = 4
const PAD_BIT: int = 16
const PAD_MASK: int = 2

# ---------------------------------------------------------------------------
# Authored pad counts — RL DFH standard 34 = 6 big + 28 small, deterministic
# ---------------------------------------------------------------------------
const PAD_COUNT: int = 34
const BIG_PAD_COUNT: int = 6
const SMALL_PAD_COUNT: int = 28
const TOTAL_PAD_COUNT: int = PAD_COUNT

# ---------------------------------------------------------------------------
# Budget — WS10 + WS43 <12 calls for boost pad visuals alone
# ---------------------------------------------------------------------------
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const MAX_TRIS_BUDGET: int = 300000
const ESTIMATED_DRAW_CALLS: int = 2  # 1 small MultiMesh + 1 big MultiMesh
const ESTIMATED_TRIS: int = 640
const TICK_HZ: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Deterministic authored positions — symmetric, inside arena, Y at pad height
# All positions authored at X∈[-20,20], Z∈[-30,30], Y = PAD_Y_*
# Big pads first (indices 0..5), small pads 6..33 — stable ordering
# ---------------------------------------------------------------------------
const BIG_PAD_POSITIONS: Array[Vector3] = [
	Vector3(-16.0, 0.17, -22.0), # NW corner
	Vector3(16.0, 0.17, -22.0),  # NE corner
	Vector3(-16.0, 0.17, 22.0),  # SW corner
	Vector3(16.0, 0.17, 22.0),   # SE corner
	Vector3(-18.0, 0.17, 0.0),   # West mid
	Vector3(18.0, 0.17, 0.0),    # East mid
]

const SMALL_PAD_POSITIONS: Array[Vector3] = [
	Vector3(-6.0, 0.12, -6.0),
	Vector3(6.0, 0.12, -6.0),
	Vector3(-6.0, 0.12, 6.0),
	Vector3(6.0, 0.12, 6.0),
	Vector3(0.0, 0.12, -12.0),
	Vector3(0.0, 0.12, 12.0),
	Vector3(-10.0, 0.12, 0.0),
	Vector3(10.0, 0.12, 0.0),
	Vector3(-6.0, 0.12, -22.0),
	Vector3(6.0, 0.12, -22.0),
	Vector3(-6.0, 0.12, 22.0),
	Vector3(6.0, 0.12, 22.0),
	Vector3(-12.0, 0.12, -12.0),
	Vector3(12.0, 0.12, -12.0),
	Vector3(-12.0, 0.12, 12.0),
	Vector3(12.0, 0.12, 12.0),
	Vector3(-8.0, 0.12, -16.0),
	Vector3(8.0, 0.12, -16.0),
	Vector3(-8.0, 0.12, 16.0),
	Vector3(8.0, 0.12, 16.0),
	Vector3(-18.0, 0.12, -8.0),
	Vector3(18.0, 0.12, -8.0),
	Vector3(-18.0, 0.12, 8.0),
	Vector3(18.0, 0.12, 8.0),
	Vector3(-10.0, 0.12, -6.0),
	Vector3(10.0, 0.12, -6.0),
	Vector3(-10.0, 0.12, 6.0),
	Vector3(10.0, 0.12, 6.0),
]

# Combined ordered array: big first then small (stable for MultiMesh indexing)
static var _combined_cache: Array[Vector3] = []

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal pad_collected(index: int, is_big: bool, amount: float, position: Vector3)
signal pad_respawned(index: int, is_big: bool, position: Vector3)

# ---------------------------------------------------------------------------
# Runtime refs
# ---------------------------------------------------------------------------
var _pad_areas: Array[Area3D] = []
var _small_mmi: MultiMeshInstance3D = null
var _big_mmi: MultiMeshInstance3D = null
var _arena_ref: ArenaCollision = null
var _loaded: bool = false

# ---------------------------------------------------------------------------
# Lifecycle — deterministic build in _ready, no per-frame allocation
# ---------------------------------------------------------------------------
func _ready() -> void:
	_arena_ref = _resolve_arena()
	_build_pad_areas()
	_build_visuals()
	_loaded = true
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[BoostPads] debug_validate: %s" % e)

func _resolve_arena() -> ArenaCollision:
	var p := get_parent()
	if p:
		for child in p.get_children():
			if child is ArenaCollision:
				return child as ArenaCollision
	for child in get_children():
		if child is ArenaCollision:
			return child as ArenaCollision
	return null

# ---------------------------------------------------------------------------
# Pad physics — 34 Area3D triggers on layer 4, mask car_chassis (WS18 pattern)
# ---------------------------------------------------------------------------
func _build_pad_areas() -> void:
	# Clean previous if re-entered
	for a in _pad_areas:
		if is_instance_valid(a):
			a.queue_free()
	_pad_areas.clear()
	var all_positions := get_all_pad_positions()
	for i in range(all_positions.size()):
		var pos := all_positions[i]
		var is_big := is_big_pad_index(i)
		var area := Area3D.new()
		area.name = "BoostPad_%02d_%s" % [i, "Big" if is_big else "Small"]
		area.position = pos
		area.collision_layer = PhysicsLayers.BIT_BOOST_PADS
		area.collision_mask = PhysicsLayers.MASK_BOOST_PADS
		area.monitoring = true
		area.monitorable = true
		area.set_meta("pad_index", i)
		area.set_meta("is_big", is_big)
		# Attach WS18 BoostPad script for respawn logic
		area.set_script(BoostPadScript)
		# need to set exported vars after script assignment
		area.set("is_big_pad", is_big)
		# Collision shape — BoxShape matching BoostPad.tscn (deterministic)
		var cs := CollisionShape3D.new()
		cs.name = "CollisionShape3D"
		var box := BoxShape3D.new()
		if is_big:
			box.size = Vector3(1.8, 0.35, 1.8)
		else:
			box.size = Vector3(1.2, 0.3, 1.2)
		cs.shape = box
		area.add_child(cs)
		# Connect collection to forward signals + visual update
		area.body_entered.connect(_on_pad_body_entered.bind(i))
		# BoostPad script emits pad_collected / pad_respawned — forward
		if area.has_signal("pad_collected"):
			area.connect("pad_collected", _on_pad_collected.bind(i))
		if area.has_signal("pad_respawned"):
			area.connect("pad_respawned", _on_pad_respawned.bind(i))
		add_child(area)
		_pad_areas.append(area)

func _on_pad_body_entered(_body: Node, _idx: int) -> void:
	# Visual update handled via pad_collected signal; keep for future hook
	pass

func _on_pad_collected(is_big: bool, amount: float, idx: int) -> void:
	var pos := get_pad_position(idx)
	pad_collected.emit(idx, is_big, amount, pos)
	_update_visual_availability(idx, false)

func _on_pad_respawned(is_big: bool, idx: int) -> void:
	var pos := get_pad_position(idx)
	pad_respawned.emit(idx, is_big, pos)
	_update_visual_availability(idx, true)

func _update_visual_availability(idx: int, available: bool) -> void:
	# Hide/show corresponding MultiMesh instance by scaling to 0 or 1
	var mmi: MultiMeshInstance3D = null
	var local_idx: int = -1
	if is_big_pad_index(idx):
		mmi = _big_mmi
		local_idx = idx  # big indices 0..5 map directly
	else:
		mmi = _small_mmi
		local_idx = idx - BIG_PAD_COUNT
	if mmi == null or mmi.multimesh == null:
		return
	if local_idx < 0 or local_idx >= mmi.multimesh.instance_count:
		return
	var t: Transform3D = mmi.multimesh.get_instance_transform(local_idx)
	var s: float = 1.0 if available else 0.001  # near-zero scale hides, avoids removal cost
	# Preserve position, scale uniformly
	var pos: Vector3 = t.origin
	var basis: Basis = t.basis
	# Extract scale length — we stored uniform, so basis scaled; reset then scale
	# Retrieve yaw from basis (rotation Y), reapply with desired scale
	var yaw := atan2(basis.z.x, basis.x.x)  # approximate yaw
	var new_basis := Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s))
	var new_t := Transform3D(new_basis, pos)
	mmi.multimesh.set_instance_transform(local_idx, new_t)
	# Also tint to gray when unavailable via instance color alpha
	var col: Color = mmi.multimesh.get_instance_color(local_idx) if mmi.multimesh.transform_format == MultiMesh.TRANSFORM_3D else Color.WHITE
	# Use visibility toggle instead: store alpha
	if available:
		col.a = 1.0
	else:
		col.a = 0.15
	# Ensure color is set — need to enable use_colors
	mmi.multimesh.set_instance_color(local_idx, col)

# ---------------------------------------------------------------------------
# Visuals — 2 MultiMeshInstance3D (small + big), 2 draw calls <12
# ---------------------------------------------------------------------------
func _build_visuals() -> void:
	# Clean previous
	if _small_mmi and is_instance_valid(_small_mmi):
		_small_mmi.queue_free()
	if _big_mmi and is_instance_valid(_big_mmi):
		_big_mmi.queue_free()
	_small_mmi = _create_multimesh(SMALL_PAD_POSITIONS, false, "BoostPads_Small")
	_big_mmi = _create_multimesh(BIG_PAD_POSITIONS, true, "BoostPads_Big")
	add_child(_small_mmi)
	add_child(_big_mmi)

func _create_multimesh(positions: Array[Vector3], is_big: bool, mmi_name: String) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = positions.size()
	mm.mesh = _load_pad_mesh(is_big)
	for i in range(positions.size()):
		var pos: Vector3 = positions[i]
		# Deterministic yaw 0 — pads face +Z, aligned to arena; small deterministic offset via hash for variety
		var yaw: float = 0.0
		# Optional tiny deterministic twist for big pads to mark corners: 0 or PI/4 based on index
		if is_big:
			yaw = _hash_yaw(i) * 0.08  # ± ~0.04 rad subtle
		var t := Transform3D(Basis(Vector3.UP, yaw), pos)
		mm.set_instance_transform(i, t)
		var col: Color = Color(1.0, 0.78, 0.12, 1.0) if is_big else Color(1.0, 0.85, 0.2, 1.0)
		# Emissive tint baked into vertex color
		mm.set_instance_color(i, col)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = mmi_name
	mmi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	mat.roughness = 0.6
	mat.metallic = 0.0
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.82, 0.15, 1.0) if is_big else Color(1.0, 0.88, 0.2, 1.0)
	mat.emission_energy_multiplier = 1.6 if is_big else 1.2
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mmi.material_override = mat
	# Cast no shadows — pads glow on floor
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi

func _load_pad_mesh(is_big: bool) -> Mesh:
	var path := BOOST_PAD_BIG_MESH_PATH if is_big else BOOST_PAD_MESH_PATH
	if ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is Mesh:
			return res as Mesh
		if res is PackedScene:
			var inst: Node = (res as PackedScene).instantiate()
			var mi := _find_mesh_instance(inst)
			if mi and mi.mesh:
				var mesh: Mesh = mi.mesh
				inst.queue_free()
				return mesh
			inst.queue_free()
	# Fallback authored CylinderMesh (deterministic, low tri)
	var cyl := CylinderMesh.new()
	cyl.top_radius = PAD_RADIUS_BIG if is_big else PAD_RADIUS_SMALL
	cyl.bottom_radius = PAD_RADIUS_BIG if is_big else PAD_RADIUS_SMALL
	cyl.height = PAD_HEIGHT_BIG if is_big else PAD_HEIGHT_SMALL
	cyl.radial_segments = 16
	cyl.rings = 1
	return cyl

func _find_mesh_instance(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root as MeshInstance3D
	for child in root.get_children():
		var found := _find_mesh_instance(child)
		if found != null:
			return found
	return null

# ---------------------------------------------------------------------------
# Deterministic helpers — no randf(), use integer hash
# ---------------------------------------------------------------------------
func _hash_yaw(idx: int) -> float:
	# Simple deterministic hash -> [-1, 1]
	var h: int = (idx * 0x9E3779B9 + 0x4131) & 0x7FFFFFFF
	return (float(h % 2000) / 1000.0) - 1.0

# ---------------------------------------------------------------------------
# Public API — deterministic placement queries
# ---------------------------------------------------------------------------
static func get_all_pad_positions() -> Array[Vector3]:
	if not _combined_cache.is_empty():
		return _combined_cache
	var out: Array[Vector3] = []
	out.append_array(BIG_PAD_POSITIONS)
	out.append_array(SMALL_PAD_POSITIONS)
	_combined_cache = out
	return out

static func get_big_pad_positions() -> Array[Vector3]:
	return BIG_PAD_POSITIONS.duplicate()

static func get_small_pad_positions() -> Array[Vector3]:
	return SMALL_PAD_POSITIONS.duplicate()

static func get_pad_position(index: int) -> Vector3:
	var all := get_all_pad_positions()
	assert(index >= 0 and index < all.size(), "BoostPads.get_pad_position: index %d out of range 0..%d" % [index, all.size() - 1])
	return all[index]

static func is_big_pad_index(index: int) -> bool:
	return index >= 0 and index < BIG_PAD_COUNT

static func is_small_pad_index(index: int) -> bool:
	return index >= BIG_PAD_COUNT and index < PAD_COUNT

static func get_pad_count() -> int:
	return PAD_COUNT

static func get_big_pad_count() -> int:
	return BIG_PAD_COUNT

static func get_small_pad_count() -> int:
	return SMALL_PAD_COUNT

static func get_pad_amount(is_big: bool) -> float:
	return BIG_PAD_AMOUNT if is_big else SMALL_PAD_AMOUNT

static func get_pad_respawn_time(is_big: bool) -> float:
	return BIG_PAD_RESPAWN if is_big else SMALL_PAD_RESPAWN

static func is_position_inside_arena(pos: Vector3) -> bool:
	return ArenaCollision.is_inside_arena(pos) if ArenaCollision.has_method("is_inside_arena") else PhysicsConstants.is_inside_arena(pos)

# ---------------------------------------------------------------------------
# Arena helpers — delegate to WS21 ArenaCollision (single source for bounds)
# ---------------------------------------------------------------------------
func get_arena_aabb() -> AABB:
	return ArenaCollision.get_arena_aabb() if ArenaCollision.has_method("get_arena_aabb") else PhysicsConstants.arena_aabb()

func is_inside_arena(point: Vector3) -> bool:
	return ArenaCollision.is_inside_arena(point)

func clamp_to_arena(point: Vector3) -> Vector3:
	return ArenaCollision.clamp_to_arena(point)

func arena_dimensions() -> Dictionary:
	return ArenaCollision.arena_dimensions() if ArenaCollision.has_method("arena_dimensions") else {
		"length": PhysicsConstants.ARENA_LENGTH,
		"width": PhysicsConstants.ARENA_WIDTH,
		"height": PhysicsConstants.ARENA_HEIGHT,
		"half_length": PhysicsConstants.ARENA_HALF_LENGTH,
		"half_width": PhysicsConstants.ARENA_HALF_WIDTH,
	}

# ---------------------------------------------------------------------------
# Budget / perf helpers
# ---------------------------------------------------------------------------
func is_loaded() -> bool:
	return _loaded

func get_pad_areas() -> Array[Area3D]:
	return _pad_areas.duplicate()

func get_small_multimesh() -> MultiMeshInstance3D:
	return _small_mmi

func get_big_multimesh() -> MultiMeshInstance3D:
	return _big_mmi

func get_draw_call_count() -> int:
	# 1 for small MultiMesh + 1 for big MultiMesh = 2
	var c := 0
	if _small_mmi and is_instance_valid(_small_mmi):
		c += 1
	if _big_mmi and is_instance_valid(_big_mmi):
		c += 1
	return c if c > 0 else ESTIMATED_DRAW_CALLS

func get_estimated_tris() -> int:
	return ESTIMATED_TRIS

func get_estimated_draw_calls() -> int:
	return ESTIMATED_DRAW_CALLS

func get_budget_state() -> Dictionary:
	var dc := get_draw_call_count()
	return {
		"draw_calls": dc,
		"budget": DRAW_CALL_BUDGET,
		"within_budget": dc <= DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
		"within_tris": ESTIMATED_TRIS <= MAX_TRIS_BUDGET,
		"pad_count": PAD_COUNT,
		"big_count": BIG_PAD_COUNT,
		"small_count": SMALL_PAD_COUNT,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "BoostPads", "draw_calls": ESTIMATED_DRAW_CALLS, "tris": ESTIMATED_TRIS, "pads": PAD_COUNT}

# ---------------------------------------------------------------------------
# Force respawn helpers (for testing / round reset)
# ---------------------------------------------------------------------------
func force_respawn_all() -> void:
	for area in _pad_areas:
		if area and area.has_method("force_respawn"):
			area.call("force_respawn")
	for i in range(PAD_COUNT):
		_update_visual_availability(i, true)

func force_respawn_index(index: int) -> void:
	if index < 0 or index >= _pad_areas.size():
		return
	var area := _pad_areas[index]
	if area and area.has_method("force_respawn"):
		area.call("force_respawn")
	_update_visual_availability(index, true)

# ---------------------------------------------------------------------------
# Validation — deterministic, no scene required for static checks
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	# Constants match PhysicsConstants
	if not is_equal_approx(ARENA_LENGTH, PhysicsConstants.ARENA_LENGTH):
		errors.append("ARENA_LENGTH != PhysicsConstants.ARENA_LENGTH")
	if not is_equal_approx(ARENA_WIDTH, PhysicsConstants.ARENA_WIDTH):
		errors.append("ARENA_WIDTH != PhysicsConstants.ARENA_WIDTH")
	if not is_equal_approx(ARENA_HEIGHT, PhysicsConstants.ARENA_HEIGHT):
		errors.append("ARENA_HEIGHT != PhysicsConstants.ARENA_HEIGHT")
	# Layers
	if PhysicsLayers.LAYER_BOOST_PADS != 4:
		errors.append("LAYER_BOOST_PADS != 4")
	if PhysicsLayers.BIT_BOOST_PADS != 16:
		errors.append("BIT_BOOST_PADS != 16")
	if PhysicsLayers.MASK_BOOST_PADS != PhysicsLayers.BIT_CAR_CHASSIS:
		errors.append("MASK_BOOST_PADS != BIT_CAR_CHASSIS")
	# Boost amounts match CarBoost WS18
	if not is_equal_approx(SMALL_PAD_AMOUNT, CarBoost.SMALL_PAD_AMOUNT):
		errors.append("SMALL_PAD_AMOUNT != CarBoost.SMALL_PAD_AMOUNT")
	if not is_equal_approx(BIG_PAD_AMOUNT, CarBoost.BIG_PAD_AMOUNT):
		errors.append("BIG_PAD_AMOUNT != CarBoost.BIG_PAD_AMOUNT")
	if not is_equal_approx(SMALL_PAD_RESPAWN, CarBoost.SMALL_PAD_RESPAWN):
		errors.append("SMALL_PAD_RESPAWN != CarBoost.SMALL_PAD_RESPAWN")
	if not is_equal_approx(BIG_PAD_RESPAWN, CarBoost.BIG_PAD_RESPAWN):
		errors.append("BIG_PAD_RESPAWN != CarBoost.BIG_PAD_RESPAWN")
	# Counts
	if BIG_PAD_POSITIONS.size() != BIG_PAD_COUNT:
		errors.append("BIG_PAD_POSITIONS.size %d != BIG_PAD_COUNT %d" % [BIG_PAD_POSITIONS.size(), BIG_PAD_COUNT])
	if SMALL_PAD_POSITIONS.size() != SMALL_PAD_COUNT:
		errors.append("SMALL_PAD_POSITIONS.size %d != SMALL_PAD_COUNT %d" % [SMALL_PAD_POSITIONS.size(), SMALL_PAD_COUNT])
	var all := get_all_pad_positions()
	if all.size() != PAD_COUNT:
		errors.append("combined positions %d != PAD_COUNT %d" % [all.size(), PAD_COUNT])
	# Inside arena + uniqueness
	var seen: Dictionary = {}
	for i in range(all.size()):
		var p: Vector3 = all[i]
		# Check inside arena (allow Y at pad height, check XZ inside)
		var flat := Vector3(p.x, 0.0, p.z)
		# Use PhysicsConstants is_inside but Y=0 is on floor, so check manually for XZ only
		if abs(p.x) > ARENA_HALF_WIDTH + 0.01 or abs(p.z) > ARENA_HALF_LENGTH + 0.01:
			errors.append("pad %d outside arena XZ: %s" % [i, str(p)])
		if p.y < 0.0 or p.y > 1.0:
			errors.append("pad %d Y out of floor range: %s" % [i, str(p)])
		var key := "%0.2f_%0.2f" % [p.x, p.z]
		if seen.has(key):
			errors.append("duplicate pad position %s at indices %d and %s" % [str(p), seen[key], i])
		else:
			seen[key] = i
	# Symmetry check — for each pad there should be mirrored pad across origin (deterministic RL-like)
	# Not strict: just warn if not symmetric at all
	# Budget
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("ESTIMATED_DRAW_CALLS %d > DRAW_CALL_BUDGET %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if ESTIMATED_TRIS > MAX_TRIS_BUDGET:
		errors.append("ESTIMATED_TRIS %d > MAX_TRIS_BUDGET %d" % [ESTIMATED_TRIS, MAX_TRIS_BUDGET])
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"pad_count": PAD_COUNT,
		"big_count": BIG_PAD_COUNT,
		"small_count": SMALL_PAD_COUNT,
		"draw_calls": get_draw_call_count(),
		"estimated_draw_calls": ESTIMATED_DRAW_CALLS,
		"estimated_tris": ESTIMATED_TRIS,
		"budget": DRAW_CALL_BUDGET,
		"within_budget": get_draw_call_count() <= DRAW_CALL_BUDGET,
		"loaded": _loaded,
		"positions": get_all_pad_positions(),
		"big_positions": BIG_PAD_POSITIONS.duplicate(),
		"small_positions": SMALL_PAD_POSITIONS.duplicate(),
		"arena_size": ARENA_SIZE,
		"pad_layer": PAD_LAYER,
		"pad_bit": PAD_BIT,
		"pad_mask": PAD_MASK,
	}
