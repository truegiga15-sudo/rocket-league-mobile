## WS23 — World Physics Integration (120 Hz Fixed Integrator)
## Central fixed-timestep world: owns car/ball/arena refs, steps via TimeService.
## Depends on: src/core/time_service.gd (WS05), src/core/constants.gd (WS04),
##             src/core/physics/physics_config.gd + layers.gd (WS07),
##             src/game/car/car_physics.gd (WS11), src/game/ball/ball_physics.gd (WS19),
##             src/game/arena/arena_collision.gd (WS21), src/game/arena/goal.gd (WS22).
## Budget-aware: accumulator + MAX_TICKS_PER_FRAME, no per-frame allocation.
extends Node3D
class_name World

const PC = preload("res://src/core/constants.gd")
const TimeSvc = preload("res://src/core/time_service.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const PL = preload("res://src/core/physics/layers.gd")
const CarPhysicsRef = preload("res://src/game/car/car_physics.gd")
const BallPhysicsRef = preload("res://src/game/ball/ball_physics.gd")
const ArenaCollisionRef = preload("res://src/game/arena/arena_collision.gd")
const GoalRef = preload("res://src/game/arena/goal.gd")

# ---------------------------------------------------------------------------
# Fixed tick — must match TimeService + PhysicsConstants + project.godot
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0
const DELTA_MIN: float = 1.0 / 240.0
const DELTA_MAX: float = 1.0 / 30.0
const MAX_TICKS_PER_FRAME: int = 4

var _accumulator: float = 0.0
var _tick_count: int = 0
var _total_time: float = 0.0
var _frame_count: int = 0

# World actors — assigned via editor or auto-discovered in _ready
var car: CarPhysics = null
var ball: BallPhysics = null
var arena: ArenaCollision = null
var goal_positive: Goal = null
var goal_negative: Goal = null

var _time_service: Node = null

signal world_ticked(tick: int, delta: float)
signal world_stepped(ticks: int)
signal goal_scored(team: int)

func _ready() -> void:
	_time_service = get_node_or_null("/root/TimeService")
	if car == null:
		car = _find_car()
	if ball == null:
		ball = _find_ball()
	if arena == null:
		arena = _find_arena()
	if goal_positive == null or goal_negative == null:
		_find_goals()
	_wire_goals()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[World] debug_validate: %s" % e)

func _find_car() -> CarPhysics:
	var n := get_node_or_null("Car")
	if n is CarPhysics:
		return n as CarPhysics
	for child in get_children():
		if child is CarPhysics:
			return child as CarPhysics
	return null

func _find_ball() -> BallPhysics:
	var n := get_node_or_null("Ball")
	if n is BallPhysics:
		return n as BallPhysics
	for child in get_children():
		if child is BallPhysics:
			return child as BallPhysics
	return null

func _find_arena() -> ArenaCollision:
	var n := get_node_or_null("Arena")
	if n is ArenaCollision:
		return n as ArenaCollision
	for child in get_children():
		if child is ArenaCollision:
			return child as ArenaCollision
	return null

func _find_goals() -> void:
	for child in get_children():
		if child is Goal:
			var g := child as Goal
			if g.is_positive_z and goal_positive == null:
				goal_positive = g
			elif not g.is_positive_z and goal_negative == null:
				goal_negative = g
	if arena:
		for child in arena.get_children():
			if child is Goal:
				var g2 := child as Goal
				if g2.is_positive_z and goal_positive == null:
					goal_positive = g2
				elif not g2.is_positive_z and goal_negative == null:
					goal_negative = g2

func _wire_goals() -> void:
	for g in [goal_positive, goal_negative]:
		if g and not g.goal_scored.is_connected(_on_goal_scored):
			g.goal_scored.connect(_on_goal_scored)

func _on_goal_scored(team: int) -> void:
	goal_scored.emit(team)

# ---------------------------------------------------------------------------
# Fixed-step integrator — mirrors TimeService accumulator, 120 Hz, clamp [1/240,1/30]
# ---------------------------------------------------------------------------

## Advance world by frame delta. Returns ticks consumed. Deterministic 120 Hz.
func step_world(delta: float) -> int:
	var clamped := clamp(delta, DELTA_MIN, DELTA_MAX)
	_accumulator += clamped
	_frame_count += 1
	var ticks := int(floor(_accumulator / TICK_DELTA))
	if ticks > MAX_TICKS_PER_FRAME:
		var dropped := ticks - MAX_TICKS_PER_FRAME
		_accumulator -= float(dropped) * TICK_DELTA
		ticks = MAX_TICKS_PER_FRAME
		push_warning("[World] clamped %d excess ticks (delta=%.4f)" % [dropped, delta])
	for i in ticks:
		_accumulator -= TICK_DELTA
		if _accumulator < 0.0 and _accumulator > -0.000001:
			_accumulator = 0.0
		_tick_count += 1
		_total_time += TICK_DELTA
		_tick(TICK_DELTA)
		world_ticked.emit(_tick_count, TICK_DELTA)
	if ticks > 0:
		world_stepped.emit(ticks)
	return ticks

## Alias kept for TimeService parity
func step(delta: float) -> int:
	return step_world(delta)

## Single fixed tick — hook for world subsystems (goal check, OOB, etc.)
func _tick(delta: float) -> void:
	# Ball/goal polling fallback (Area3D is authoritative; this is geometric guard)
	if ball:
		var pos := ball.global_position
		if ArenaCollisionRef.is_out_of_bounds(pos):
			pass
		var st := GoalRef.scoring_team(pos)
		if st != 0:
			goal_scored.emit(st)

## Delegate to TimeService when available, else use local accumulator.
func step_with_time_service(delta: float) -> int:
	if _time_service and _time_service.has_method("advance"):
		var ticks: int = _time_service.advance(delta)
		for i in ticks:
			_tick_count += 1
			_total_time += TICK_DELTA
			_tick(TICK_DELTA)
			world_ticked.emit(_tick_count, TICK_DELTA)
		if ticks > 0:
			world_stepped.emit(ticks)
		return ticks
	return step_world(delta)

func _physics_process(delta: float) -> void:
	# Godot already ticks at 120 Hz; keep world in sync without double-step.
	# When running headless/test, caller drives step_world explicitly.
	pass

# ---------------------------------------------------------------------------
# State / lifecycle
# ---------------------------------------------------------------------------
func reset_world() -> void:
	_accumulator = 0.0
	_tick_count = 0
	_total_time = 0.0
	_frame_count = 0
	if car and car.has_method("reset_to_spawn"):
		car.reset_to_spawn()
	if ball and ball.has_method("reset_to_spawn"):
		ball.reset_to_spawn()

func get_tick_count() -> int:
	return _tick_count

func get_total_time() -> float:
	return _total_time

func get_accumulator() -> float:
	return _accumulator

func get_alpha() -> float:
	return clamp(_accumulator / TICK_DELTA, 0.0, 1.0)

func get_fixed_delta() -> float:
	return TICK_DELTA

# ---------------------------------------------------------------------------
# Validation / telemetry (conventions S11)
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA %.8f != 1/120" % TICK_DELTA)
	if not is_equal_approx(DELTA_MIN, 1.0 / 240.0):
		errors.append("DELTA_MIN != 1/240")
	if not is_equal_approx(DELTA_MAX, 1.0 / 30.0):
		errors.append("DELTA_MAX != 1/30")
	if not is_equal_approx(DELTA_MIN * 2.0, TICK_DELTA):
		errors.append("DELTA_MIN*2 != TICK_DELTA")
	if not is_equal_approx(DELTA_MAX / 4.0, TICK_DELTA):
		errors.append("DELTA_MAX/4 != TICK_DELTA")
	if TimeSvc.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("TimeService PHYSICS_TICKS_PER_SECOND %d != 120" % TimeSvc.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TimeSvc.TICK_DELTA, TICK_DELTA):
		errors.append("TimeService TICK_DELTA mismatch")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PhysicsConstants PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PC.PHYSICS_TICK_DELTA, TICK_DELTA):
		errors.append("PhysicsConstants TICK_DELTA mismatch")
	if PConfig.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PhysicsConfig PHYSICS_TICKS != 120")
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != -1 and ps_rate != 120:
		errors.append("project.godot physics_ticks_per_second=%d != 120" % ps_rate)
	var v_car := CarPhysicsRef.debug_validate_static()
	if not v_car["ok"]:
		for e in v_car["errors"]:
			errors.append("CarPhysics: " + str(e))
	var v_ball_cfg = preload("res://src/game/ball/ball_config.gd").debug_validate()
	if not v_ball_cfg["ok"]:
		for e in v_ball_cfg["errors"]:
			errors.append("BallConfig: " + str(e))
	var v_arena := ArenaCollisionRef.debug_validate()
	if not v_arena["ok"]:
		for e in v_arena["errors"]:
			errors.append("ArenaCollision: " + str(e))
	var v_goal := GoalRef.debug_validate()
	if not v_goal["ok"]:
		for e in v_goal["errors"]:
			errors.append("Goal: " + str(e))
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"tick_delta": TICK_DELTA,
		"delta_min": DELTA_MIN,
		"delta_max": DELTA_MAX,
		"max_ticks_per_frame": MAX_TICKS_PER_FRAME,
		"accumulator": _accumulator,
		"alpha": get_alpha(),
		"tick_count": _tick_count,
		"total_time": _total_time,
		"frame_count": _frame_count,
		"has_car": car != null,
		"has_ball": ball != null,
		"has_arena": arena != null,
		"has_goals": goal_positive != null and goal_negative != null,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "World", "tick_hz": PHYSICS_TICKS_PER_SECOND, "tick_delta": TICK_DELTA}
