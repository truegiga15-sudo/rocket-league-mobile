## WS49 -- Wheels (budget-aware <12 calls, deterministic, solo retry 2)
## 4 wheel meshes at suspension positions: uses WS12 CarSuspension.WHEEL_OFFSETS,
## WS46 Octane / WS47 Dominus car size 4.2x2.1x1.5 (WS04 PhysicsConstants), 120 Hz tick.
## No procedural generation -- authored CylinderMesh with deterministic dimensions,
## no random, no per-frame allocation. Budget: 4 draw calls <12, ~768 tris.
## Depends on: src/core/constants.gd (WS04), src/game/car/suspension.gd (WS12),
##             src/game/car/octane.gd (WS46), src/game/car/dominus.gd (WS47)
extends Node3D
class_name Wheels

const PC = preload("res://src/core/constants.gd")
const SuspensionRef = preload("res://src/game/car/suspension.gd")
const OctaneRef = preload("res://src/game/car/octane.gd")
const DominusRef = preload("res://src/game/car/dominus.gd")

# ---------------------------------------------------------------------------
# Authored car size -- single source via PhysicsConstants (WS04), mirrored from Octane/Dominus
# ---------------------------------------------------------------------------
const CAR_LENGTH: float = 4.2
const CAR_WIDTH: float = 2.1
const CAR_HEIGHT: float = 1.5
const CAR_HALF_EXTENTS: Vector3 = Vector3(2.1, 0.75, 1.05)
const CAR_SIZE: Vector3 = Vector3(2.1, 1.5, 4.2)

# ---------------------------------------------------------------------------
# Wheel geometry -- deterministic, authored, matches Suspension.WHEEL_RADIUS
# ---------------------------------------------------------------------------
const WHEEL_COUNT: int = 4
const NUM_WHEELS: int = 4
const WHEEL_RADIUS: float = 0.35
const WHEEL_WIDTH: float = 0.28
const WHEEL_RADIUS_SUSPENSION: float = 0.35  # must match SuspensionRef.WHEEL_RADIUS

## Wheel local positions in chassis space -- single source is Suspension.WHEEL_OFFSETS (WS12)
## Duplicated here for validation + fallback when SuspensionRef not loaded in tool context.
const WHEEL_OFFSETS: Array[Vector3] = [
	Vector3(-0.95, -0.20, 1.35),  # 0: Front-Left
	Vector3(0.95, -0.20, 1.35),   # 1: Front-Right
	Vector3(-0.95, -0.20, -1.35), # 2: Rear-Left
	Vector3(0.95, -0.20, -1.35),  # 3: Rear-Right
]
const WHEEL_NAMES: Array[String] = ["FL", "FR", "RL", "RR"]
const WHEEL_NODE_NAMES: Array[String] = ["Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR"]

# ---------------------------------------------------------------------------
# Mesh -- authored deterministic, no procedural noise
# ---------------------------------------------------------------------------
const WHEEL_MESH_PATH: String = "res://assets/authored/car/wheel_mesh_a_v01.glb"
const MESH_PATH: String = WHEEL_MESH_PATH
const AUTHORED_MESH_NAME: String = "wheel_mesh_a_v01.glb"

# ---------------------------------------------------------------------------
# Budget & tick -- <12 draw calls (4 wheels = 4 calls), 120 Hz
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_HZ: int = 120
const TICK_DELTA: float = PHYSICS_TICK_DELTA
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const MAX_TRIS_BUDGET: int = 300000
const ESTIMATED_TRIS_PER_WHEEL: int = 192
const ESTIMATED_TRIS: int = 768  # 4 * 192
const ESTIMATED_DRAW_CALLS: int = 4
const AUTHORED_MESH_COUNT: int = 4
const AUTHORED_MATERIAL_COUNT: int = 1

var _wheel_meshes: Array[MeshInstance3D] = []
var _loaded: bool = false
var _steer_angle: float = 0.0
var _roll_angle: Array[float] = [0.0, 0.0, 0.0, 0.0]

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_build_wheels()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[Wheels] debug_validate: %s" % e)

func _build_wheels() -> void:
	if _loaded:
		return
	# Clear any existing
	for c in get_children():
		if c is MeshInstance3D and c.name.begins_with("Wheel_"):
			remove_child(c)
			c.queue_free()
	_wheel_meshes.clear()
	var authored_scene: PackedScene = null
	if ResourceLoader.exists(WHEEL_MESH_PATH):
		var res: Resource = load(WHEEL_MESH_PATH)
		if res is PackedScene:
			authored_scene = res as PackedScene
	# Build 4 wheels at suspension positions (WS12 single source)
	var offsets: Array[Vector3] = get_wheel_offsets()
	for i in range(WHEEL_COUNT):
		var mi: MeshInstance3D
		if authored_scene != null:
			var inst: Node = authored_scene.instantiate()
			# Find mesh instance inside authored scene
			var found := _find_mesh_instance(inst)
			if found != null:
				mi = MeshInstance3D.new()
				mi.mesh = found.mesh
				if found.material_override != null:
					mi.material_override = found.material_override
				inst.queue_free()
			else:
				# Fallback: use root if it contains mesh
				mi = _create_cylinder_wheel()
				inst.queue_free()
		else:
			mi = _create_cylinder_wheel()
		mi.name = WHEEL_NODE_NAMES[i]
		mi.position = offsets[i]
		# Cylinder axis is Y by default; rotate so axle is along X (wheel rolls on Z)
		mi.rotation_degrees = Vector3(0, 0, 90)
		add_child(mi)
		_wheel_meshes.append(mi)
	_loaded = true

func _create_cylinder_wheel() -> MeshInstance3D:
	var cyl := CylinderMesh.new()
	cyl.top_radius = WHEEL_RADIUS
	cyl.bottom_radius = WHEEL_RADIUS
	cyl.height = WHEEL_WIDTH
	cyl.radial_segments = 16
	cyl.rings = 1
	cyl.cap_top = true
	cyl.cap_bottom = true
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.08, 0.08, 0.08, 1.0)
	mat.roughness = 0.85
	mat.metallic = 0.05
	mi.material_override = mat
	return mi

func _find_mesh_instance(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root as MeshInstance3D
	for child in root.get_children():
		var f := _find_mesh_instance(child)
		if f != null:
			return f
	return null

# ---------------------------------------------------------------------------
# Public API -- suspension positions (WS12) + deterministic control
# ---------------------------------------------------------------------------
func get_wheel_offsets() -> Array[Vector3]:
	# Single source: SuspensionRef.WHEEL_OFFSETS (WS12). Fallback to local if unavailable.
	if SuspensionRef != null and "WHEEL_OFFSETS" in SuspensionRef:
		var s_offsets: Array[Vector3] = SuspensionRef.WHEEL_OFFSETS
		if s_offsets.size() == WHEEL_COUNT:
			return s_offsets.duplicate()
	return WHEEL_OFFSETS.duplicate()

func get_wheel_positions() -> Array[Vector3]:
	return get_wheel_offsets()

func get_wheel_count() -> int:
	return WHEEL_COUNT

func get_wheel_radius() -> float:
	return WHEEL_RADIUS

func get_wheel_width() -> float:
	return WHEEL_WIDTH

func get_wheel_meshes() -> Array[MeshInstance3D]:
	# Return valid meshes only (filter freed)
	var out: Array[MeshInstance3D] = []
	for m in _wheel_meshes:
		if m != null and is_instance_valid(m):
			out.append(m)
	# Fallback scan if array empty but children exist
	if out.is_empty():
		for c in get_children():
			if c is MeshInstance3D and (c.name as String).begins_with("Wheel_"):
				out.append(c as MeshInstance3D)
	return out

func get_wheel_mesh(idx: int) -> MeshInstance3D:
	var all := get_wheel_meshes()
	if idx >= 0 and idx < all.size():
		return all[idx]
	return null

func is_loaded() -> bool:
	return _loaded

func get_car_size() -> Vector3:
	return PC.car_size()

func get_car_half_extents() -> Vector3:
	return PC.CAR_HALF_EXTENTS

func get_car_aabb(center: Vector3 = Vector3.ZERO) -> AABB:
	return PC.car_aabb(center)

func get_draw_call_count() -> int:
	return get_wheel_meshes().size()

func get_estimated_tris() -> int:
	return ESTIMATED_TRIS

func get_budget_state() -> Dictionary:
	var dc := get_draw_call_count()
	# If not yet built, report estimated
	if dc == 0:
		dc = ESTIMATED_DRAW_CALLS
	return {
		"draw_calls": dc,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": dc <= DRAW_CALL_BUDGET,
		"estimated_tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
		"mesh_count": dc,
		"max_meshes": DRAW_CALL_BUDGET,
	}

## Deterministic steer: front wheels (0,1) yaw, rear fixed. No random.
func set_steer_angle(angle_rad: float) -> void:
	_steer_angle = clamp(angle_rad, -0.6, 0.6)
	var meshes := get_wheel_meshes()
	for i in range(min(2, meshes.size())):
		# Preserve roll + add steer yaw
		var base_roll := _roll_angle[i] if i < _roll_angle.size() else 0.0
		meshes[i].rotation = Vector3(0, _steer_angle, PI * 0.5 + base_roll)

func get_steer_angle() -> float:
	return _steer_angle

## Deterministic roll animation (distance -> angle). No time dependency beyond input distance.
func update_roll(distance_m: float) -> void:
	if WHEEL_RADIUS <= 0.0:
		return
	var delta_angle := distance_m / WHEEL_RADIUS
	for i in range(WHEEL_COUNT):
		_roll_angle[i] += delta_angle
		_roll_angle[i] = fmod(_roll_angle[i], TAU)
	var meshes := get_wheel_meshes()
	for i in range(meshes.size()):
		var is_front := i < 2
		var yaw := _steer_angle if is_front else 0.0
		meshes[i].rotation = Vector3(_roll_angle[i], yaw, PI * 0.5)

func get_roll_angles() -> Array[float]:
	return _roll_angle.duplicate()

# ---------------------------------------------------------------------------
# Validation -- deterministic, no I/O, mirrors Octane/Dominus pattern
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	# PhysicsConstants single source 4.2 x 2.1 x 1.5
	if not is_equal_approx(CAR_LENGTH, 4.2):
		errors.append("CAR_LENGTH %.2f != 4.2" % CAR_LENGTH)
	if not is_equal_approx(CAR_WIDTH, 2.1):
		errors.append("CAR_WIDTH %.2f != 2.1" % CAR_WIDTH)
	if not is_equal_approx(CAR_HEIGHT, 1.5):
		errors.append("CAR_HEIGHT %.2f != 1.5" % CAR_HEIGHT)
	if CAR_HALF_EXTENTS != PC.CAR_HALF_EXTENTS:
		errors.append("CAR_HALF_EXTENTS %s != PC %s" % [str(CAR_HALF_EXTENTS), str(PC.CAR_HALF_EXTENTS)])
	if CAR_SIZE != PC.car_size():
		errors.append("CAR_SIZE %s != PC.car_size() %s" % [str(CAR_SIZE), str(PC.car_size())])
	if not is_equal_approx(CAR_HALF_EXTENTS.x * 2.0, CAR_WIDTH):
		errors.append("HALF_EXTENTS.x*2 != CAR_WIDTH")
	if not is_equal_approx(CAR_HALF_EXTENTS.y * 2.0, CAR_HEIGHT):
		errors.append("HALF_EXTENTS.y*2 != CAR_HEIGHT")
	if not is_equal_approx(CAR_HALF_EXTENTS.z * 2.0, CAR_LENGTH):
		errors.append("HALF_EXTENTS.z*2 != CAR_LENGTH")
	if not is_equal_approx(PC.CAR_LENGTH, 4.2):
		errors.append("PC.CAR_LENGTH != 4.2")
	if not is_equal_approx(PC.CAR_WIDTH, 2.1):
		errors.append("PC.CAR_WIDTH != 2.1")
	if not is_equal_approx(PC.CAR_HEIGHT, 1.5):
		errors.append("PC.CAR_HEIGHT != 1.5")
	# Cross-check Octane/Dominus WS46/47 constants match
	if not is_equal_approx(OctaneRef.CAR_LENGTH, 4.2):
		errors.append("Octane.CAR_LENGTH != 4.2")
	if not is_equal_approx(DominusRef.CAR_LENGTH, 4.2):
		errors.append("Dominus.CAR_LENGTH != 4.2")
	if OctaneRef.CAR_HALF_EXTENTS != PC.CAR_HALF_EXTENTS:
		errors.append("Octane half extents != PC")
	if DominusRef.CAR_HALF_EXTENTS != PC.CAR_HALF_EXTENTS:
		errors.append("Dominus half extents != PC")
	# Suspension WS12 positions
	if WHEEL_COUNT != 4:
		errors.append("WHEEL_COUNT %d != 4" % WHEEL_COUNT)
	if WHEEL_OFFSETS.size() != 4:
		errors.append("WHEEL_OFFSETS size %d != 4" % WHEEL_OFFSETS.size())
	if WHEEL_NAMES.size() != 4:
		errors.append("WHEEL_NAMES size != 4")
	if WHEEL_NODE_NAMES.size() != 4:
		errors.append("WHEEL_NODE_NAMES size != 4")
	if not is_equal_approx(WHEEL_RADIUS, 0.35):
		errors.append("WHEEL_RADIUS %.2f != 0.35 (Suspension)" % WHEEL_RADIUS)
	if SuspensionRef != null:
		if not is_equal_approx(SuspensionRef.WHEEL_RADIUS, 0.35):
			errors.append("Suspension.WHEEL_RADIUS != 0.35")
		if SuspensionRef.WHEEL_OFFSETS.size() != 4:
			errors.append("Suspension.WHEEL_OFFSETS size != 4")
		else:
			for i in range(4):
				if WHEEL_OFFSETS[i] != SuspensionRef.WHEEL_OFFSETS[i]:
					errors.append("WHEEL_OFFSETS[%d] %s != Suspension %s" % [i, str(WHEEL_OFFSETS[i]), str(SuspensionRef.WHEEL_OFFSETS[i])])
		if not is_equal_approx(SuspensionRef.REST_LENGTH, 0.3):
			errors.append("Suspension.REST_LENGTH != 0.3")
	# Budget <12 calls
	if DRAW_CALL_BUDGET > 12:
		errors.append("DRAW_CALL_BUDGET %d > 12" % DRAW_CALL_BUDGET)
	if MAX_DRAW_CALLS > 12:
		errors.append("MAX_DRAW_CALLS > 12")
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("ESTIMATED_DRAW_CALLS %d > BUDGET %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if ESTIMATED_DRAW_CALLS != 4:
		errors.append("ESTIMATED_DRAW_CALLS %d != 4" % ESTIMATED_DRAW_CALLS)
	if ESTIMATED_TRIS > MAX_TRIS_BUDGET:
		errors.append("ESTIMATED_TRIS %d > %d" % [ESTIMATED_TRIS, MAX_TRIS_BUDGET])
	# Tick 120 Hz
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA != 1/120")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS != 120")
	# Mesh path conventions WS03
	if not WHEEL_MESH_PATH.begins_with("res://assets/authored/car/"):
		errors.append("MESH_PATH must be under assets/authored/car/")
	if not WHEEL_MESH_PATH.ends_with(".glb"):
		errors.append("MESH_PATH must be .glb")
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != -1 and ps_rate != 120:
		errors.append("project.godot ticks %d != 120" % ps_rate)
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"wheel_count": WHEEL_COUNT,
		"wheel_radius": WHEEL_RADIUS,
		"wheel_width": WHEEL_WIDTH,
		"wheel_offsets": WHEEL_OFFSETS.duplicate(),
		"car_size": CAR_SIZE,
		"car_half_extents": CAR_HALF_EXTENTS,
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"budget": DRAW_CALL_BUDGET,
		"within_budget": ESTIMATED_DRAW_CALLS <= DRAW_CALL_BUDGET,
	}

func perf_mark() -> Dictionary:
	return {
		"draw_calls": get_draw_call_count(),
		"estimated_tris": ESTIMATED_TRIS,
		"within_budget": get_draw_call_count() <= DRAW_CALL_BUDGET,
	}
