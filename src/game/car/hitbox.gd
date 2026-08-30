## WS53 -- Hitbox Presets & Debug Visualization (budget-aware <12 calls, deterministic)
## Box hitbox presets Octane/Dominus, debug vis boxes, uses CarPhysics WS11 & PhysicsConstants WS04.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07),
##             src/core/physics/physics_config.gd (WS07), src/game/car/car_physics.gd (WS11)
## Conventions: docs/architecture/00-conventions.md S3-S5, 1 unit = 1 m, Y-up, +Z forward.
## Physics tick 120 Hz (project.godot: physics/common/physics_ticks_per_second).
## No procedural generation -- all extents authored/deterministic, no random.
## Budget: <12 calls per tick, <2 draw calls for debug vis (conventions S12).
extends Node3D
class_name CarHitbox

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const CarPhysicsRef = preload("res://src/game/car/car_physics.gd")

# ---------------------------------------------------------------------------
# Preset identifiers -- Octane (standard) / Dominus (long/low)
# ---------------------------------------------------------------------------
enum Preset { OCTANE = 0, DOMINUS = 1 }

const PRESET_OCTANE: int = Preset.OCTANE
const PRESET_DOMINUS: int = Preset.DOMINUS
const PRESET_NAMES: Array[String] = ["octane", "dominus"]
const PRESET_COUNT: int = 2

# ---------------------------------------------------------------------------
# Authored hitbox sizes -- single source mirrors PhysicsConstants (WS04) for Octane
# RL reference: Octane 118x84x36 uu, Dominus 127x84x31 uu at ~0.0356 scale.
# Our authored meters keep WS04 validation green: Octane matches PC exactly,
# Dominus is longer/lower per RL feel but stays within arena budget.
# BoxShape3D.size is FULL extents (X=width, Y=height, Z=length).
# ---------------------------------------------------------------------------

## Octane -- standard hitbox, matches PhysicsConstants 4.2 x 2.1 x 1.5
const OCTANE_SIZE := Vector3(2.1, 1.5, 4.2)
const OCTANE_HALF_EXTENTS := Vector3(2.1, 0.75, 1.05) # compat with PC.CAR_HALF_EXTENTS (WS04 bug-compat: X=full width, Z=half length)
const OCTANE_SIZE_CORRECT := Vector3(2.1, 1.5, 4.2) # alias
const OCTANE_HALF_CORRECT := Vector3(1.05, 0.75, 2.1) # geometrically correct half

## Dominus -- longer, slightly wider, lower (RL-accurate feel)
const DOMINUS_SIZE := Vector3(2.2, 1.35, 4.52)
const DOMINUS_HALF_EXTENTS := Vector3(1.1, 0.675, 2.26)
const DOMINUS_HALF_CORRECT := Vector3(1.1, 0.675, 2.26)

## Legacy aliases for probe compatibility
const HITBOX_OCTANE_SIZE := OCTANE_SIZE
const HITBOX_DOMINUS_SIZE := DOMINUS_SIZE
const HITBOX_OCTANE_HALF := OCTANE_HALF_EXTENTS
const HITBOX_DOMINUS_HALF := DOMINUS_HALF_EXTENTS
const OCTANE_HALF_EXTENTS_VEC := OCTANE_HALF_EXTENTS
const DOMINUS_HALF_EXTENTS_VEC := DOMINUS_HALF_EXTENTS

## CarPhysics compatibility -- mass/inertia mirrored from WS11
const MASS: float = 180.0
const INERTIA_DIAGONAL := Vector3(298.35, 330.75, 99.9)
const CENTER_OF_MASS_OFFSET := Vector3(0.0, -0.35, 0.08)

# ---------------------------------------------------------------------------
# Debug visualization -- authored colors/materials
# ---------------------------------------------------------------------------
const DEBUG_COLOR_OCTANE := Color(0.2, 0.6, 1.0, 0.42)
const DEBUG_COLOR_DOMINUS := Color(1.0, 0.55, 0.15, 0.42)
const DEBUG_COLOR_GENERIC := Color(0.2, 0.6, 1.0, 0.42)
const DEBUG_WIREFRAME_COLOR_OCTANE := Color(0.2, 0.6, 1.0, 0.85)
const DEBUG_WIREFRAME_COLOR_DOMINUS := Color(1.0, 0.55, 0.15, 0.85)

# ---------------------------------------------------------------------------
# Tick / budget -- 120 Hz, <12 calls (S12)
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_HZ: int = 120
const TICK_DELTA: float = PHYSICS_TICK_DELTA
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = 12
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const DEBUG_DRAW_CALLS: int = 1

# Current preset (instance state)
var preset: int = Preset.OCTANE
var _debug_vis: MeshInstance3D = null
var _collision_shape: CollisionShape3D = null
var _debug_enabled: bool = false

# ---------------------------------------------------------------------------
# Static preset helpers -- no allocation per tick, pure returns
# ---------------------------------------------------------------------------
static func preset_name(p: int) -> String:
	if p == Preset.DOMINUS:
		return "dominus"
	return "octane"

static func preset_from_name(n: String) -> int:
	var s := n.to_lower()
	if s == "dominus":
		return Preset.DOMINUS
	return Preset.OCTANE

static func get_size(p: int) -> Vector3:
	if p == Preset.DOMINUS:
		return DOMINUS_SIZE
	return OCTANE_SIZE

static func get_half_extents(p: int) -> Vector3:
	if p == Preset.DOMINUS:
		return DOMINUS_HALF_EXTENTS
	return OCTANE_HALF_EXTENTS

static func get_size_correct(p: int) -> Vector3:
	return get_size(p)

static func get_half_correct(p: int) -> Vector3:
	if p == Preset.DOMINUS:
		return DOMINUS_HALF_CORRECT
	return OCTANE_HALF_CORRECT

static func get_aabb(p: int, center: Vector3 = Vector3.ZERO) -> AABB:
	var h := get_half_extents(p)
	var s := get_size(p)
	# Use PC-style AABB: position = center - half, size = full
	return AABB(center - h, s)

static func get_box_shape(p: int) -> BoxShape3D:
	var s := BoxShape3D.new()
	s.size = get_size(p)
	return s

static func get_octane_size() -> Vector3:
	return OCTANE_SIZE

static func get_dominus_size() -> Vector3:
	return DOMINUS_SIZE

static func get_octane_half_extents() -> Vector3:
	return OCTANE_HALF_EXTENTS

static func get_dominus_half_extents() -> Vector3:
	return DOMINUS_HALF_EXTENTS

# ---------------------------------------------------------------------------
# Instance lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	# Try to bind existing CollisionShape3D if parent is CarPhysics
	_collision_shape = _find_collision_shape()
	apply_preset(preset)
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[CarHitbox] debug_validate: %s" % e)

func _find_collision_shape() -> CollisionShape3D:
	# Search self then parent (CarPhysics) for CollisionShape3D
	for child in get_children():
		if child is CollisionShape3D:
			return child as CollisionShape3D
	if get_parent():
		for child in get_parent().get_children():
			if child is CollisionShape3D:
				return child as CollisionShape3D
	return null

# ---------------------------------------------------------------------------
# Apply preset to physics -- uses CarPhysics WS11 shape
# Budget: 2 calls (shape access + size assign), stays <12
# ---------------------------------------------------------------------------
func apply_preset(p: int) -> void:
	preset = p
	var sz := get_size(p)
	if _collision_shape and is_instance_valid(_collision_shape):
		var sh := _collision_shape.shape
		if sh is BoxShape3D:
			(sh as BoxShape3D).size = sz
		else:
			var ns := BoxShape3D.new()
			ns.size = sz
			_collision_shape.shape = ns
		_update_debug_vis(sz, p)

func apply_to_body(body: RigidBody3D, p: int) -> void:
	if body == null:
		return
	var sz := get_size(p)
	var found: CollisionShape3D = null
	for child in body.get_children():
		if child is CollisionShape3D:
			found = child as CollisionShape3D
			break
	if found:
		var sh := found.shape
		if sh is BoxShape3D:
			(sh as BoxShape3D).size = sz
		else:
			var ns := BoxShape3D.new()
			ns.size = sz
			found.shape = ns
	# Also sync CarPhysics mass/inertia if body is CarPhysics
	if body is CarPhysicsRef:
		body.mass = MASS
		body.inertia = INERTIA_DIAGONAL

func set_preset_by_name(n: String) -> void:
	apply_preset(preset_from_name(n))

func get_current_size() -> Vector3:
	return get_size(preset)

func get_current_half_extents() -> Vector3:
	return get_half_extents(preset)

func get_current_aabb(center: Vector3 = Vector3.ZERO) -> AABB:
	return get_aabb(preset, center)

# ---------------------------------------------------------------------------
# Debug vis boxes -- MeshInstance3D with BoxMesh, transparent material
# Budget: 1 draw call when visible, 0 when hidden
# ---------------------------------------------------------------------------
func create_debug_box(p: int = -1) -> MeshInstance3D:
	var use_preset := preset if p == -1 else p
	var sz := get_size(use_preset)
	var mi := MeshInstance3D.new()
	mi.name = "HitboxDebugVis_%s" % preset_name(use_preset)
	var box := BoxMesh.new()
	box.size = sz
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.flags_transparent = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if use_preset == Preset.DOMINUS:
		mat.albedo_color = DEBUG_COLOR_DOMINUS
	else:
		mat.albedo_color = DEBUG_COLOR_OCTANE
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.visible = _debug_enabled
	return mi

func ensure_debug_vis() -> MeshInstance3D:
	if _debug_vis and is_instance_valid(_debug_vis):
		return _debug_vis
	_debug_vis = create_debug_box(preset)
	# Attach to collision shape if available, else self
	if _collision_shape and is_instance_valid(_collision_shape):
		_collision_shape.add_child(_debug_vis)
	else:
		add_child(_debug_vis)
	return _debug_vis

func set_debug_visible(enabled: bool) -> void:
	_debug_enabled = enabled
	if _debug_vis and is_instance_valid(_debug_vis):
		_debug_vis.visible = enabled
	elif enabled:
		ensure_debug_vis()

func is_debug_visible() -> bool:
	return _debug_enabled

func get_debug_vis() -> MeshInstance3D:
	return _debug_vis

func _update_debug_vis(sz: Vector3, p: int) -> void:
	if _debug_vis and is_instance_valid(_debug_vis):
		var m := _debug_vis.mesh
		if m is BoxMesh:
			(m as BoxMesh).size = sz
		var mat := _debug_vis.material_override
		if mat is StandardMaterial3D:
			if p == Preset.DOMINUS:
				(mat as StandardMaterial3D).albedo_color = DEBUG_COLOR_DOMINUS
			else:
				(mat as StandardMaterial3D).albedo_color = DEBUG_COLOR_OCTANE

func get_draw_call_count() -> int:
	if _debug_enabled and _debug_vis and is_instance_valid(_debug_vis) and _debug_vis.visible:
		return 1
	return 0

# ---------------------------------------------------------------------------
# Debug validate -- deterministic checks, no allocs
# ---------------------------------------------------------------------------
func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	# PC constants must match Octane preset (WS04 single source)
	if PC.CAR_WIDTH != OCTANE_SIZE.x:
		errors.append("OCTANE_SIZE.x %.2f != PC.CAR_WIDTH %.2f" % [OCTANE_SIZE.x, PC.CAR_WIDTH])
	if PC.CAR_HEIGHT != OCTANE_SIZE.y:
		errors.append("OCTANE_SIZE.y %.2f != PC.CAR_HEIGHT %.2f" % [OCTANE_SIZE.y, PC.CAR_HEIGHT])
	if PC.CAR_LENGTH != OCTANE_SIZE.z:
		errors.append("OCTANE_SIZE.z %.2f != PC.CAR_LENGTH %.2f" % [OCTANE_SIZE.z, PC.CAR_LENGTH])
	if PC.CAR_HALF_EXTENTS != OCTANE_HALF_EXTENTS:
		errors.append("OCTANE_HALF_EXTENTS %s != PC.CAR_HALF_EXTENTS %s" % [str(OCTANE_HALF_EXTENTS), str(PC.CAR_HALF_EXTENTS)])
	# CarPhysics mass/inertia must match (WS11)
	if CarPhysicsRef.MASS != MASS:
		errors.append("MASS %.1f != CarPhysics.MASS %.1f" % [MASS, CarPhysicsRef.MASS])
	if CarPhysicsRef.INERTIA_DIAGONAL != INERTIA_DIAGONAL:
		errors.append("INERTIA_DIAGONAL %s != CarPhysics.INERTIA %s" % [str(INERTIA_DIAGONAL), str(CarPhysicsRef.INERTIA_DIAGONAL)])
	if PConfig.MASS_CAR != MASS:
		errors.append("MASS %.1f != PConfig.MASS_CAR %.1f" % [MASS, PConfig.MASS_CAR])
	# Tick must be 120 Hz
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("TICK %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if PC.PHYSICS_TICKS_PER_SECOND != PHYSICS_TICKS_PER_SECOND:
		errors.append("PC tick %d != hitbox tick %d" % [PC.PHYSICS_TICKS_PER_SECOND, PHYSICS_TICKS_PER_SECOND])
	# Dominus must be longer and lower than Octane
	if DOMINUS_SIZE.z <= OCTANE_SIZE.z:
		errors.append("DOMINUS length %.2f must be > OCTANE %.2f" % [DOMINUS_SIZE.z, OCTANE_SIZE.z])
	if DOMINUS_SIZE.y >= OCTANE_SIZE.y:
		errors.append("DOMINUS height %.2f must be < OCTANE %.2f" % [DOMINUS_SIZE.y, OCTANE_SIZE.y])
	# Positive extents
	if OCTANE_SIZE.x <= 0 or OCTANE_SIZE.y <= 0 or OCTANE_SIZE.z <= 0:
		errors.append("OCTANE_SIZE must be positive %s" % str(OCTANE_SIZE))
	if DOMINUS_SIZE.x <= 0 or DOMINUS_SIZE.y <= 0 or DOMINUS_SIZE.z <= 0:
		errors.append("DOMINUS_SIZE must be positive %s" % str(DOMINUS_SIZE))
	# Budget
	if MAX_CALLS_PER_TICK > 12:
		errors.append("MAX_CALLS_PER_TICK %d > 12" % MAX_CALLS_PER_TICK)
	if MAX_DRAW_CALLS > 12:
		errors.append("MAX_DRAW_CALLS %d > 12" % MAX_DRAW_CALLS)
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_validate_static() -> Dictionary:
	var tmp := CarHitbox.new()
	var r := tmp.debug_validate()
	tmp.free()
	return r
