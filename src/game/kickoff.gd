## WS59 — Kickoff Logic & Spawn Positions
## Kickoff flow: reset ball + cars to kickoff spots, 3-2-1 countdown, GO.
## Uses: PhysicsConstants WS04 (60×40 arena), Goal WS22 (goal AABB/centers),
##       TimeService WS05 + MatchTimer WS58 (countdown), BallConfig WS19, World WS23.
## Budget-aware: <12 calls (0 draw calls, event-driven signals only, no per-frame alloc).
extends Node
class_name Kickoff

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
const TimeSvc = preload("res://src/core/time_service.gd")
const GoalRef = preload("res://src/game/arena/goal.gd")
const BallConfigRef = preload("res://src/game/ball/ball_config.gd")
const WorldRef = preload("res://src/game/world.gd")

# ---------------------------------------------------------------------------
# Arena constants — single source, no magic numbers (WS04: 60×40×20)
# ---------------------------------------------------------------------------
const ARENA_LENGTH: float = 60.0
const ARENA_WIDTH: float = 40.0
const ARENA_HEIGHT: float = 20.0
const ARENA_HALF_LENGTH: float = 30.0
const ARENA_HALF_WIDTH: float = 20.0
const BALL_RADIUS: float = 0.91

# ---------------------------------------------------------------------------
# Kickoff timing — mirrors Match Timer WS58 (3-2-1 + GO), driven by TimeService 120Hz
# ---------------------------------------------------------------------------
const COUNTDOWN_SECONDS: float = 3.0
const GO_HOLD_SECONDS: float = 0.5
const TOTAL_KICKOFF_SECONDS: float = 3.5
const COUNTDOWN_TICKS: int = 360  # 3.0s * 120
const GO_TICKS: int = 60  # 0.5s * 120
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Spawn positions — centered kickoff, symmetric for Blue (-Z) vs Orange (+Z)
# Standard RL kickoff scaled to 60×40 arena:
#   1v1: both on center line Z axis
#   2v2: adds diagonal slots
#   3v3: adds wide slots
# Y = 0.5 (car half-height on floor), yaw faces center/ball.
# ---------------------------------------------------------------------------
## Blue team spawns (negative Z, faces +Z toward ball/positive goal)
const SPAWN_BLUE_CENTER: Vector3 = Vector3(0, 0.5, -22.0)
const SPAWN_BLUE_DIAG_LEFT: Vector3 = Vector3(-6.0, 0.5, -15.0)
const SPAWN_BLUE_DIAG_RIGHT: Vector3 = Vector3(6.0, 0.5, -15.0)
const SPAWN_BLUE_WIDE_LEFT: Vector3 = Vector3(-12.0, 0.5, -10.0)
const SPAWN_BLUE_WIDE_RIGHT: Vector3 = Vector3(12.0, 0.5, -10.0)
## Orange team spawns (positive Z, faces -Z)
const SPAWN_ORANGE_CENTER: Vector3 = Vector3(0, 0.5, 22.0)
const SPAWN_ORANGE_DIAG_LEFT: Vector3 = Vector3(-6.0, 0.5, 15.0)
const SPAWN_ORANGE_DIAG_RIGHT: Vector3 = Vector3(6.0, 0.5, 15.0)
const SPAWN_ORANGE_WIDE_LEFT: Vector3 = Vector3(-12.0, 0.5, 10.0)
const SPAWN_ORANGE_WIDE_RIGHT: Vector3 = Vector3(12.0, 0.5, 10.0)

## Yaw angles (radians) — Blue faces +Z (0), Orange faces -Z (PI)
const YAW_BLUE: float = 0.0
const YAW_ORANGE: float = PI

const BALL_SPAWN: Vector3 = Vector3(0, 0.91, 0)
const BALL_SPAWN_ALT: Vector3 = Vector3(0, 2.0, 0)  # matches BallConfig.SPAWN_POSITION

# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------
enum State { IDLE, COUNTDOWN, GO, ACTIVE, GOAL_SCORED }

var _state: State = State.IDLE
var _countdown_remaining: float = 0.0
var _ticks_remaining: int = 0
var _countdown_value: int = 3  # 3,2,1,0=GO

signal kickoff_started
signal kickoff_countdown(value: int)  # 3,2,1
signal kickoff_go
signal kickoff_active
signal kickoff_complete
signal goal_scored_during_kickoff(team: int)

# ---------------------------------------------------------------------------
# World refs — optional, kickoff works standalone via static helpers too
# ---------------------------------------------------------------------------
var world: Node = null
var ball: Node3D = null
var cars: Array[Node3D] = []

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[Kickoff] debug_validate: %s" % e)

# ---------------------------------------------------------------------------
# Public API — kickoff flow
# ---------------------------------------------------------------------------

## Start kickoff: reset positions, begin 3-2-1 countdown.
func start_kickoff() -> void:
	reset_positions()
	_state = State.COUNTDOWN
	_countdown_remaining = COUNTDOWN_SECONDS
	_ticks_remaining = COUNTDOWN_TICKS
	_countdown_value = 3
	kickoff_started.emit()
	kickoff_countdown.emit(3)
	# Wire goal signals if world available
	_wire_goal_signals()

## Advance kickoff by delta (call from World/TimeService or _process).
## Returns true when kickoff becomes ACTIVE (GO finished).
func advance(delta: float) -> bool:
	if _state == State.IDLE or _state == State.ACTIVE or _state == State.GOAL_SCORED:
		return false
	if _state == State.COUNTDOWN:
		_countdown_remaining -= delta
		_ticks_remaining -= 1
		var new_value: int = int(ceil(_countdown_remaining))
		if new_value != _countdown_value and new_value >= 1:
			_countdown_value = new_value
			kickoff_countdown.emit(_countdown_value)
		if _countdown_remaining <= 0.0:
			_state = State.GO
			_countdown_remaining = GO_HOLD_SECONDS
			_ticks_remaining = GO_TICKS
			kickoff_go.emit()
		return false
	if _state == State.GO:
		_countdown_remaining -= delta
		_ticks_remaining -= 1
		if _countdown_remaining <= 0.0:
			_state = State.ACTIVE
			kickoff_active.emit()
			kickoff_complete.emit()
			return true
		return false
	return false

## Advance by fixed ticks (deterministic, 120Hz). Prefer for replay/net.
func advance_ticks(ticks: int = 1) -> bool:
	var became_active := false
	for i in ticks:
		if advance(TICK_DELTA):
			became_active = true
			break
	return became_active

## Reset ball + cars to kickoff spawns (no countdown).
func reset_positions() -> void:
	# Ball
	if ball != null:
		ball.global_position = BALL_SPAWN
		if ball is RigidBody3D:
			var rb := ball as RigidBody3D
			rb.linear_velocity = Vector3.ZERO
			rb.angular_velocity = Vector3.ZERO
		elif ball.has_method("reset_to_spawn"):
			ball.call("reset_to_spawn")
	elif world != null and world.has_method("get_node"):
		var b: Node = world.get_node_or_null("Ball")
		if b is Node3D:
			(b as Node3D).global_position = BALL_SPAWN

	# Cars — assign spawns by team
	for idx in cars.size():
		var car: Node3D = cars[idx]
		var entry := spawn_for_index(idx, cars.size())
		car.global_position = entry["position"]
		car.rotation.y = entry["yaw"]
		if car is RigidBody3D:
			var rb2 := car as RigidBody3D
			rb2.linear_velocity = Vector3.ZERO
			rb2.angular_velocity = Vector3.ZERO
		if car.has_method("reset_to_spawn"):
			car.call("reset_to_spawn")

## Force ACTIVE (skip countdown) — for testing / free-play WS90.
func skip_to_active() -> void:
	_state = State.ACTIVE
	kickoff_active.emit()
	kickoff_complete.emit()

func get_state() -> State:
	return _state

func is_countdown() -> bool:
	return _state == State.COUNTDOWN

func is_active() -> bool:
	return _state == State.ACTIVE

func is_kickoff_locked() -> bool:
	return _state == State.COUNTDOWN or _state == State.GO

func get_countdown_value() -> int:
	return _countdown_value

func get_countdown_remaining() -> float:
	return _countdown_remaining

# ---------------------------------------------------------------------------
# Static spawn helpers — pure functions, no scene required
# ---------------------------------------------------------------------------

## Ball kickoff position (center, on floor).
static func ball_spawn() -> Vector3:
	return BALL_SPAWN

## Ball spawn alias matching BallConfig.
static func ball_spawn_position() -> Vector3:
	return BALL_SPAWN

## Returns spawn {position, yaw} for car index in a match of total_cars.
## Layout: 0=Blue center, 1=Orange center, 2=Blue diag, 3=Orange diag, etc.
static func spawn_for_index(index: int, total: int = 2) -> Dictionary:
	var t := total if total > 0 else 2
	# 1v1
	if t <= 2:
		if index == 0:
			return {"position": SPAWN_BLUE_CENTER, "yaw": YAW_BLUE, "team": -1}
		else:
			return {"position": SPAWN_ORANGE_CENTER, "yaw": YAW_ORANGE, "team": 1}
	# 2v2
	if t <= 4:
		match index:
			0: return {"position": SPAWN_BLUE_CENTER, "yaw": YAW_BLUE, "team": -1}
			1: return {"position": SPAWN_ORANGE_CENTER, "yaw": YAW_ORANGE, "team": 1}
			2: return {"position": SPAWN_BLUE_DIAG_LEFT, "yaw": YAW_BLUE, "team": -1}
			3: return {"position": SPAWN_ORANGE_DIAG_RIGHT, "yaw": YAW_ORANGE, "team": 1}
			_: return {"position": SPAWN_BLUE_CENTER, "yaw": YAW_BLUE, "team": -1}
	# 3v3 (and up, cycle)
	match index % 6:
		0: return {"position": SPAWN_BLUE_CENTER, "yaw": YAW_BLUE, "team": -1}
		1: return {"position": SPAWN_ORANGE_CENTER, "yaw": YAW_ORANGE, "team": 1}
		2: return {"position": SPAWN_BLUE_DIAG_LEFT, "yaw": YAW_BLUE, "team": -1}
		3: return {"position": SPAWN_ORANGE_DIAG_RIGHT, "yaw": YAW_ORANGE, "team": 1}
		4: return {"position": SPAWN_BLUE_DIAG_RIGHT, "yaw": YAW_BLUE, "team": -1}
		5: return {"position": SPAWN_ORANGE_DIAG_LEFT, "yaw": YAW_ORANGE, "team": 1}
		_: return {"position": SPAWN_BLUE_CENTER, "yaw": YAW_BLUE, "team": -1}

## All kickoff spawns for a given team count. Returns Array[Dictionary].
static func all_spawns(team_size: int = 1) -> Array[Dictionary]:
	var total := team_size * 2
	var out: Array[Dictionary] = []
	for i in total:
		out.append(spawn_for_index(i, total))
	return out

## Blue team spawns only.
static func blue_spawns(team_size: int = 1) -> Array[Vector3]:
	var all := all_spawns(team_size)
	var res: Array[Vector3] = []
	for e in all:
		if int(e["team"]) == -1:
			res.append(e["position"] as Vector3)
	return res

## Orange team spawns only.
static func orange_spawns(team_size: int = 1) -> Array[Vector3]:
	var all := all_spawns(team_size)
	var res: Array[Vector3] = []
	for e in all:
		if int(e["team"]) == 1:
			res.append(e["position"] as Vector3)
	return res

## True if position is within kickoff spawn tolerance of any kickoff spot.
static func is_kickoff_position(pos: Vector3, tolerance: float = 0.5) -> bool:
	var spawns: Array[Vector3] = [
		SPAWN_BLUE_CENTER, SPAWN_ORANGE_CENTER,
		SPAWN_BLUE_DIAG_LEFT, SPAWN_BLUE_DIAG_RIGHT,
		SPAWN_ORANGE_DIAG_LEFT, SPAWN_ORANGE_DIAG_RIGHT,
		SPAWN_BLUE_WIDE_LEFT, SPAWN_BLUE_WIDE_RIGHT,
		SPAWN_ORANGE_WIDE_LEFT, SPAWN_ORANGE_WIDE_RIGHT,
		BALL_SPAWN
	]
	for s in spawns:
		if pos.distance_to(s) <= tolerance:
			return true
	return false

## Clamp a spawn to arena bounds (uses WS04 constants).
static func clamp_to_arena(pos: Vector3) -> Vector3:
	return PC.clamp_to_arena(pos)

# ---------------------------------------------------------------------------
# Goal / timer integration (WS22 + WS58)
# ---------------------------------------------------------------------------

func _wire_goal_signals() -> void:
	if world == null:
		return
	# Connect to World.goal_scored if available
	if world.has_signal("goal_scored"):
		if not world.goal_scored.is_connected(_on_goal_scored):
			world.goal_scored.connect(_on_goal_scored)
	# Also try direct Goal nodes
	for conn_name in ["goal_positive", "goal_negative"]:
		var g: Node = world.get(conn_name) if conn_name in world else null
		if g != null and g.has_signal("goal_scored"):
			var sig: Signal = g.get("goal_scored") as Signal
			if not sig.is_connected(_on_goal_scored):
				sig.connect(_on_goal_scored)

func _on_goal_scored(team: int) -> void:
	_state = State.GOAL_SCORED
	goal_scored_during_kickoff.emit(team)

## Static helper: check if ball at center is valid kickoff (not in goal).
static func is_valid_kickoff_ball(pos: Vector3 = BALL_SPAWN) -> bool:
	# Ball must NOT be inside either goal (WS22)
	if GoalRef.is_goal(pos):
		return false
	# Must be inside arena (WS04)
	if not PC.is_inside_arena(pos):
		return false
	return true

# ---------------------------------------------------------------------------
# Validation / telemetry
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	# Arena constants must match PhysicsConstants
	if not is_equal_approx(ARENA_LENGTH, PC.ARENA_LENGTH):
		errors.append("ARENA_LENGTH %.2f != PC %.2f" % [ARENA_LENGTH, PC.ARENA_LENGTH])
	if not is_equal_approx(ARENA_WIDTH, PC.ARENA_WIDTH):
		errors.append("ARENA_WIDTH %.2f != PC %.2f" % [ARENA_WIDTH, PC.ARENA_WIDTH])
	if not is_equal_approx(ARENA_HALF_LENGTH, PC.ARENA_HALF_LENGTH):
		errors.append("ARENA_HALF_LENGTH drift")
	if not is_equal_approx(ARENA_HALF_WIDTH, PC.ARENA_HALF_WIDTH):
		errors.append("ARENA_HALF_WIDTH drift")
	if not is_equal_approx(ARENA_LENGTH, 60.0):
		errors.append("ARENA_LENGTH != 60.0")
	if not is_equal_approx(ARENA_WIDTH, 40.0):
		errors.append("ARENA_WIDTH != 40.0")
	if not is_equal_approx(BALL_RADIUS, PC.BALL_RADIUS):
		errors.append("BALL_RADIUS %.2f != PC %.2f" % [BALL_RADIUS, PC.BALL_RADIUS])
	# Ball spawn must be valid kickoff
	if not is_valid_kickoff_ball(BALL_SPAWN):
		errors.append("BALL_SPAWN not valid kickoff (in goal or outside arena)")
	if GoalRef.is_goal(BALL_SPAWN):
		errors.append("BALL_SPAWN inside goal")
	# Car spawns inside arena and not inside goals
	var test_spawns: Array[Vector3] = [
		SPAWN_BLUE_CENTER, SPAWN_ORANGE_CENTER,
		SPAWN_BLUE_DIAG_LEFT, SPAWN_BLUE_DIAG_RIGHT,
		SPAWN_ORANGE_DIAG_LEFT, SPAWN_ORANGE_DIAG_RIGHT
	]
	for s in test_spawns:
		if not PC.is_inside_arena(s):
			errors.append("spawn %s outside arena" % str(s))
		if GoalRef.is_goal(s):
			errors.append("spawn %s inside goal" % str(s))
	# Symmetry: blue/orange mirrored on Z
	if not is_equal_approx(SPAWN_BLUE_CENTER.z, -SPAWN_ORANGE_CENTER.z):
		errors.append("center spawns not Z-symmetric")
	if not is_equal_approx(SPAWN_BLUE_DIAG_LEFT.x, SPAWN_ORANGE_DIAG_LEFT.x):
		errors.append("diag left X not mirrored")
	# Timing
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND != 120")
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA != 1/120")
	if COUNTDOWN_TICKS != 360:
		errors.append("COUNTDOWN_TICKS != 360")
	if GO_TICKS != 60:
		errors.append("GO_TICKS != 60")
	if not is_equal_approx(COUNTDOWN_SECONDS, 3.0):
		errors.append("COUNTDOWN_SECONDS != 3.0")
	# TimeService match
	if TimeSvc.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("TimeService tick != 120")
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"state": _state,
		"countdown_remaining": _countdown_remaining,
		"countdown_value": _countdown_value,
		"ticks_remaining": _ticks_remaining,
		"ball_spawn": BALL_SPAWN,
		"blue_center": SPAWN_BLUE_CENTER,
		"orange_center": SPAWN_ORANGE_CENTER,
		"arena": Vector2(ARENA_WIDTH, ARENA_LENGTH),
		"locked": is_kickoff_locked(),
	}

static func perf_mark() -> Dictionary:
	return {"scope": "Kickoff", "tick_hz": PHYSICS_TICKS_PER_SECOND, "draw_calls": 0, "budget_draw_calls": 12}

## One-liner for logs.
static func describe_kickoff() -> String:
	return "Kickoff 60x40 arena ball=%s blue=%s orange=%s countdown=%.1fs" % [str(BALL_SPAWN), str(SPAWN_BLUE_CENTER), str(SPAWN_ORANGE_CENTER), COUNTDOWN_SECONDS]
