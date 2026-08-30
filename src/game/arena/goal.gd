## WS22 — Goal Detection (Area3D sensor, layer 5)
## Detects ball entering goal volume 7.3×2.1×2.0 at (0, 1.05, ±30).
## Uses WS21 ArenaCollision + WS04 PhysicsConstants + WS07 PhysicsLayers.
## Budget-aware: event-driven Area3D overlap + static AABB check; no per-frame polling.
extends Area3D
class_name Goal

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
const ArenaCollision = preload("res://src/game/arena/arena_collision.gd")

# ---------------------------------------------------------------------------
# Goal geometry — mirrors PhysicsConstants (single source of truth, no drift)
# ---------------------------------------------------------------------------
const GOAL_WIDTH: float = 7.3
const GOAL_HEIGHT: float = 2.1
const GOAL_DEPTH: float = 2.0
const GOAL_CENTER_Y: float = 1.05
const GOAL_HALF_WIDTH: float = 3.65

## Which goal this instance represents. true = +Z (north), false = -Z (south).
## Two instances should be placed at z = ±30 in the scene.
@export var is_positive_z: bool = true

## Emitted when ball enters this goal volume.
## team: +1 for +Z goal scored (ball in +Z), -1 for -Z goal. Consumers map to team.
signal goal_scored(team: int)
signal goal_entered(team: int, ball_position: Vector3)
signal ball_entered_goal(body: Node3D, team: int)

# ---------------------------------------------------------------------------
# Lifecycle — configure Area3D sensor on layer 5 (sensors)
# ---------------------------------------------------------------------------
func _ready() -> void:
	_configure_physics()
	_ensure_box_shape()
	# Wire Area3D overlap; safe to connect multiple times guard
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[Goal] debug_validate: %s" % e)

func _configure_physics() -> void:
	collision_layer = PL.BIT_SENSORS  # 32 — layer 5
	collision_mask = PL.MASK_SENSORS  # 10 — detects ball + car_chassis (ball is authoritative)
	monitoring = true
	monitorable = true
	# Position this sensor at its goal center so an untransformed BoxShape works
	position = PC.goal_center(is_positive_z)

func _ensure_box_shape() -> void:
	for child in get_children():
		if child is CollisionShape3D:
			var cs := child as CollisionShape3D
			if cs.shape is BoxShape3D:
				var b := cs.shape as BoxShape3D
				if not is_equal_approx(b.size.x, GOAL_WIDTH) or not is_equal_approx(b.size.y, GOAL_HEIGHT) or not is_equal_approx(b.size.z, GOAL_DEPTH):
					b.size = Vector3(GOAL_WIDTH, GOAL_HEIGHT, GOAL_DEPTH)
			else:
					var nb := BoxShape3D.new()
					nb.size = Vector3(GOAL_WIDTH, GOAL_HEIGHT, GOAL_DEPTH)
					cs.shape = nb
			return
	# No CollisionShape3D — create one
	var cs_new := CollisionShape3D.new()
	cs_new.name = "GoalShape"
	var box := BoxShape3D.new()
	box.size = Vector3(GOAL_WIDTH, GOAL_HEIGHT, GOAL_DEPTH)
	cs_new.shape = box
	add_child(cs_new)

# ---------------------------------------------------------------------------
# Overlap callback — filter to ball only, emit goal_scored
# ---------------------------------------------------------------------------
func _on_body_entered(body: Node) -> void:
	if body == null:
		return
	# Only balls score — accept group, class, or layer
	var is_ball := false
	if body.is_in_group("ball") or body.is_in_group("ball_physics"):
		is_ball = true
	elif body is RigidBody3D:
		var rb := body as RigidBody3D
		if (rb.collision_layer & PL.BIT_BALL) != 0:
			is_ball = true
		elif body.has_method("get_radius") or body.get_class() == "RigidBody3D":
			# Fallback: check node name contains Ball
			if "Ball" in body.name:
				is_ball = true
	if not is_ball:
		return
	# Geometric guard — body position must actually be inside this goal's AABB
	var pos: Vector3
	if body is Node3D:
		pos = (body as Node3D).global_position
	else:
		return
	if not is_goal_for(pos, is_positive_z):
		return
	var team := 1 if is_positive_z else -1
	goal_scored.emit(team)
	goal_entered.emit(team, pos)
	ball_entered_goal.emit(body as Node3D, team)

# ---------------------------------------------------------------------------
# Static helpers — pure AABB tests, no scene required
# ---------------------------------------------------------------------------

## True if ball_position is inside EITHER goal volume (7.3×2.1×2.0 at 0,1.05,±30).
static func is_goal(ball_position: Vector3) -> bool:
	return PC.is_inside_goal(ball_position, true) or PC.is_inside_goal(ball_position, false)

## True if ball_position is inside the specific goal (positive_z selects +Z at z=30).
static func is_goal_for(ball_position: Vector3, positive_z: bool) -> bool:
	return PC.is_inside_goal(ball_position, positive_z)

## Alias kept for WS21-style naming.
static func is_goal_at(ball_position: Vector3, positive_z: bool) -> bool:
	return is_goal_for(ball_position, positive_z)

## Returns +1 if ball in +Z goal, -1 if in -Z goal, 0 if not in any goal.
static func scoring_team(ball_position: Vector3) -> int:
	if PC.is_inside_goal(ball_position, true):
		return 1
	if PC.is_inside_goal(ball_position, false):
		return -1
	return 0

## Alias — which side scored.
static func team_for_goal(ball_position: Vector3) -> int:
	return scoring_team(ball_position)

## AABB of the requested goal volume (straddles wall, depth 2 m).
static func goal_aabb(positive_z: bool) -> AABB:
	return PC.goal_aabb(positive_z)

## Alias to PhysicsConstants.goal_center.
static func goal_center(positive_z: bool) -> Vector3:
	return PC.goal_center(positive_z)

## Collision layer bit for goal sensors (layer 5 -> 32).
static func goal_collision_layer() -> int:
	return PL.BIT_SENSORS

## Collision mask for goal sensors (detects ball + car_chassis).
static func goal_collision_mask() -> int:
	return PL.MASK_SENSORS

# ---------------------------------------------------------------------------
# Instance convenience wrappers
# ---------------------------------------------------------------------------
func check_ball_position(ball_position: Vector3) -> bool:
	return is_goal_for(ball_position, is_positive_z)

func is_ball_in_goal(ball_position: Vector3) -> bool:
	return check_ball_position(ball_position)

# ---------------------------------------------------------------------------
# Validation / telemetry — mirrors WS21/WS07 patterns
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(GOAL_WIDTH, PC.GOAL_WIDTH):
		errors.append("GOAL_WIDTH drift vs PhysicsConstants")
	if not is_equal_approx(GOAL_HEIGHT, PC.GOAL_HEIGHT):
		errors.append("GOAL_HEIGHT drift vs PhysicsConstants")
	if not is_equal_approx(GOAL_DEPTH, PC.GOAL_DEPTH):
		errors.append("GOAL_DEPTH drift vs PhysicsConstants")
	if not is_equal_approx(GOAL_CENTER_Y, PC.GOAL_CENTER_Y):
		errors.append("GOAL_CENTER_Y drift vs PhysicsConstants")
	if PL.LAYER_SENSORS != 5:
		errors.append("LAYER_SENSORS != 5")
	if PL.BIT_SENSORS != 32:
		errors.append("BIT_SENSORS != 32")
	if PL.MASK_SENSORS != (PL.BIT_BALL | PL.BIT_CAR_CHASSIS):
		errors.append("MASK_SENSORS != BIT_BALL|BIT_CAR_CHASSIS")
	# AABB sanity: center must be 0,1.05,±30
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
		errors.append("center should be inside goal")
	if PC.is_inside_goal(Vector3(10, 1.05, 30.0), true):
		errors.append("far X should be outside goal")
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"is_positive_z": is_positive_z,
		"position": position,
		"goal_center": PC.goal_center(is_positive_z),
		"goal_aabb": PC.goal_aabb(is_positive_z),
		"collision_layer": collision_layer,
		"collision_mask": collision_mask,
		"monitoring": monitoring,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "Goal", "layer": PL.LAYER_SENSORS, "bit": PL.BIT_SENSORS, "tick_hz": PC.PHYSICS_TICKS_PER_SECOND}
