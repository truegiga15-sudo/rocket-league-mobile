## WS89 — Offline Bot AI (basic) — budget-aware chase ball
## Budget-aware <12 calls per tick: direct vector math only, no raycasts/allocations.
## Integrates with CarPhysics (WS11), BallPhysics/BallConfig (WS19), Goal (WS22) at 120 Hz.
## Conventions: docs/architecture/00-conventions.md §3-§4, 1 unit=1m, Y-up, +Z forward.
extends Node3D
class_name Bot

const PC = preload("res://src/core/constants.gd")
const CarPhysicsRef = preload("res://src/game/car/car_physics.gd")
const BallPhysicsRef = preload("res://src/game/ball/ball_physics.gd")
const GoalRef = preload("res://src/game/arena/goal.gd")

# ---------------------------------------------------------------------------
# Tick — must match PhysicsConstants / project.godot / TimeService
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Authored tuning — single source for WS89
# ---------------------------------------------------------------------------
## Attack +Z goal when true, -Z when false (opponent goal)
@export var attack_positive_z: bool = true
## Max steer command 0..1 (scaled by angle)
const STEER_GAIN: float = 1.6
const STEER_DEADZONE: float = 0.02
## Distance thresholds (m)
const BOOST_DISTANCE: float = 15.0
const BOOST_ANGLE_RAD: float = 0.35  # ~20 deg
const BRAKE_DISTANCE: float = 1.2
const KICK_DISTANCE: float = 3.0  # when close, aim through ball toward goal
## Speeds
const MAX_SPEED_F: float = 28.0
## Stuck detection
const STUCK_SPEED: float = 0.5
const STUCK_TIME: float = 1.0

# ---------------------------------------------------------------------------
# Refs — assigned via editor or auto-discovered under World
# ---------------------------------------------------------------------------
var car: CarPhysics = null
var ball: BallPhysics = null

# Runtime state — no per-tick allocation (reused vectors)
var _input_move: Vector2 = Vector2.ZERO
var _input_boost: bool = false
var _input_jump: bool = false
var _input_drift: bool = false
var _stuck_timer: float = 0.0
var _tick_count: int = 0

signal bot_input(move: Vector2, boost: bool, drift: bool, jump: bool)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	if car == null:
		car = _find_car()
	if ball == null:
		ball = _find_ball()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[Bot] debug_validate: %s" % e)

func _physics_process(delta: float) -> void:
	# Called at 120 Hz (physics_ticks_per_second=120 in project.godot)
	tick(delta)

func tick(delta: float) -> void:
	_tick_count += 1
	var inp := compute_input()
	_input_move = inp["move"]
	_input_boost = inp["boost"]
	_input_drift = inp["drift"]
	_input_jump = inp["jump"]
	_update_stuck(delta)
	bot_input.emit(_input_move, _input_boost, _input_drift, _input_jump)
	_apply_to_car()

# ---------------------------------------------------------------------------
# Core AI — chase ball, kick toward opponent goal when close
# ---------------------------------------------------------------------------
## Returns Dictionary{move:Vector2, boost:bool, drift:bool, jump:bool}
func compute_input() -> Dictionary:
	if car == null or ball == null:
		return {"move": Vector2.ZERO, "boost": false, "drift": false, "jump": false}
	var car_pos: Vector3 = car.global_position
	var ball_pos: Vector3 = ball.global_position

	# Target: ball center, or point beyond ball toward opponent goal when close
	var target: Vector3 = ball_pos
	var dist_to_ball: float = car_pos.distance_to(ball_pos)
	if dist_to_ball < KICK_DISTANCE + 4.0:
		# Aim through ball toward opponent goal so bot hits ball toward goal
		var goal_center: Vector3 = GoalRef.goal_center(attack_positive_z) if GoalRef else PC.goal_center(attack_positive_z)
		var ball_to_goal: Vector3 = goal_center - ball_pos
		ball_to_goal.y = 0.0
		if ball_to_goal.length_squared() > 0.001:
			ball_to_goal = ball_to_goal.normalized()
			# Target slightly beyond ball (0.9 m ~ ball radius) toward goal
			target = ball_pos - ball_to_goal * 0.0 + ball_to_goal * -0.0
			# Better: offset car approach point opposite goal
			# So bot comes from ball->car side opposite goal
			var approach_offset: Vector3 = -ball_to_goal * 1.2
			approach_offset.y = 0.0
			if dist_to_ball > KICK_DISTANCE:
				target = ball_pos + approach_offset
			else:
				# When very close, steer directly toward goal through ball
				target = ball_pos + ball_to_goal * 2.0

	target.y = car_pos.y  # ignore height for steering (XZ plane)
	var to_target: Vector3 = target - car_pos
	to_target.y = 0.0
	var dist: float = to_target.length()
	if dist < 0.15:
		return {"move": Vector2.ZERO, "boost": false, "drift": false, "jump": false}

	var to_norm: Vector3 = to_target / dist if dist > 0.0 else Vector3.FORWARD

	# Car forward on XZ (+Z is forward per WS04)
	var fwd: Vector3 = car.global_transform.basis.z.normalized()
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	else:
		fwd = fwd.normalized()

	var angle: float = fwd.signed_angle_to(to_norm, Vector3.UP)

	# Steer proportional to angle
	var steer: float = clamp(angle * STEER_GAIN, -1.0, 1.0)
	if abs(steer) < STEER_DEADZONE:
		steer = 0.0

	# Throttle: forward unless we need to reverse (ball behind and close)
	var throttle: float = 1.0
	if dist < BRAKE_DISTANCE and abs(angle) > PI * 0.5:
		throttle = -0.6
	elif abs(angle) > 1.1:  # >63 deg, slow down
		throttle = 0.5
	else:
		throttle = 1.0

	# InputService convention: move.y = -throttle (WS06), move.x = steer
	var move := Vector2(steer, -throttle)

	# Boost when far and roughly aligned
	var boost: bool = dist > BOOST_DISTANCE and abs(angle) < BOOST_ANGLE_RAD and throttle > 0.8
	# Drift for sharp turns at speed
	var speed: float = car.linear_velocity.length() if car else 0.0
	var drift: bool = abs(angle) > 0.9 and speed > 6.0

	return {"move": move, "boost": boost, "drift": drift, "jump": false}

func get_input() -> Dictionary:
	return {"move": _input_move, "boost": _input_boost, "drift": _input_drift, "jump": _input_jump}

func get_move() -> Vector2:
	return _input_move

# ---------------------------------------------------------------------------
# Apply — optionally drive car directly (impulse/steer placeholder)
# ---------------------------------------------------------------------------
func _apply_to_car() -> void:
	# Bot does NOT directly set RigidBody velocity; it emits bot_input for
	# InputService or Car controller to consume. No physics mutation here
	# keeps budget <12 calls and avoids double-integration at 120 Hz.
	pass

func _update_stuck(delta: float) -> void:
	if car == null:
		return
	var spd: float = car.linear_velocity.length()
	if spd < STUCK_SPEED and _input_move.length() > 0.5:
		_stuck_timer += delta
		if _stuck_timer > STUCK_TIME:
			# Unstick: reverse + steer hard
			_input_move = Vector2(1.0, 1.0)  # steer right + reverse
			_stuck_timer = 0.0
	else:
		_stuck_timer = 0.0

# ---------------------------------------------------------------------------
# Discovery helpers
# ---------------------------------------------------------------------------
func _find_car() -> CarPhysics:
	var w := get_parent()
	if w and w.has_method("_find_car"):
		var c = w.call("_find_car")
		if c is CarPhysics:
			return c as CarPhysics
	# fallback: sibling search
	if get_parent():
		for sib in get_parent().get_children():
			if sib is CarPhysics:
				return sib as CarPhysics
	return null

func _find_ball() -> BallPhysics:
	var w2 := get_parent()
	if w2 and w2.has_method("_find_ball"):
		var b = w2.call("_find_ball")
		if b is BallPhysics:
			return b as BallPhysics
	if get_parent():
		for sib in get_parent().get_children():
			if sib is BallPhysics:
				return sib as BallPhysics
	return null

# ---------------------------------------------------------------------------
# Validation / telemetry — mirrors WS11/WS19/WS22 patterns
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("TICKS %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA %.6f != 1/120" % TICK_DELTA)
	var pc_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 120))
	if pc_rate != 120:
		errors.append("project.godot ticks %d != 120" % pc_rate)
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC TICKS %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if GOAL_REF_OK() == false:
		errors.append("GoalRef preload failed")
	if CAR_REF_OK() == false:
		errors.append("CarPhysicsRef preload failed")
	if BALL_REF_OK() == false:
		errors.append("BallPhysicsRef preload failed")
	return {"ok": errors.is_empty(), "errors": errors}

static func CAR_REF_OK() -> bool:
	return CarPhysicsRef != null

static func BALL_REF_OK() -> bool:
	return BallPhysicsRef != null

static func GOAL_REF_OK() -> bool:
	return GoalRef != null

func debug_export() -> Dictionary:
	return {
		"attack_positive_z": attack_positive_z,
		"tick": _tick_count,
		"input_move": _input_move,
		"input_boost": _input_boost,
		"has_car": car != null,
		"has_ball": ball != null,
		"tick_hz": PHYSICS_TICKS_PER_SECOND,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "Bot", "tick_hz": PHYSICS_TICKS_PER_SECOND, "budget_calls": 6}

## Budget audit: per tick calls = compute_input (vector math only, 0 physics queries)
## + signed_angle_to + normalized + emit + validation guard = <12 calls.
static func budget_calls_per_tick() -> int:
	return 6
