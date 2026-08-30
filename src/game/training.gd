## WS90 — Training Free Play Mode (budget-aware, <12 calls)
## Free Play: reset ball/car via World WS23, no match timer, no goals.
## Uses: PhysicsConstants WS04 (arena/ball/car), World WS23 (reset_world,
##       car/ball refs, 120 Hz), BallConfig WS19, CarPhysics WS11.
## Budget: 0 draw calls, event-driven signals only, no per-frame alloc.
extends Node
class_name Training

const PC = preload("res://src/core/constants.gd")
const WorldRef = preload("res://src/game/world.gd")
const BallConfigRef = preload("res://src/game/ball/ball_config.gd")
const CarPhysicsRef = preload("res://src/game/car/car_physics.gd")

# ---------------------------------------------------------------------------
# Tick — must match PhysicsConstants / World / project.godot
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Arena — single source from PhysicsConstants (60×40×20, floor Y=0)
# ---------------------------------------------------------------------------
const ARENA_LENGTH: float = 60.0
const ARENA_WIDTH: float = 40.0
const ARENA_HEIGHT: float = 20.0
const ARENA_HALF_LENGTH: float = 30.0
const ARENA_HALF_WIDTH: float = 20.0

# ---------------------------------------------------------------------------
# Spawn defaults
# ---------------------------------------------------------------------------
const BALL_SPAWN: Vector3 = Vector3(0, 0.91, 0)
const BALL_SPAWN_ALT: Vector3 = Vector3(0, 2.0, 0)
const CAR_SPAWN_OFFSET: Vector3 = Vector3(0, 0, -10.0)

# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------
const MAX_CALLS_PER_FRAME: int = 12
const ESTIMATED_MS_PER_RESET: float = 0.05

enum State { INACTIVE, FREE_PLAY }

var _state: State = State.INACTIVE
var _world: World = null
var _is_free_play: bool = false

signal training_started
signal training_ended
signal ball_reset(position: Vector3)
signal car_reset(position: Vector3)
signal training_reset

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_world = _find_world()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[Training] debug_validate: %s" % e)

func _find_world() -> World:
	var n := get_node_or_null("/root/World")
	if n is World:
		return n as World
	var parent := get_parent()
	if parent is World:
		return parent as World
	for child in get_children():
		if child is World:
			return child as World
	return null

func bind_world(world: World) -> void:
	_world = world

# ---------------------------------------------------------------------------
# Free play — no timer, ball/car reset on demand
# ---------------------------------------------------------------------------
func start_free_play() -> void:
	_state = State.FREE_PLAY
	_is_free_play = true
	reset_all()
	training_started.emit()

func end_free_play() -> void:
	_state = State.INACTIVE
	_is_free_play = false
	training_ended.emit()

func is_free_play() -> bool:
	return _is_free_play and _state == State.FREE_PLAY

func reset_ball(pos: Vector3 = BALL_SPAWN_ALT) -> void:
	var clamped := PC.clamp_to_arena(pos)
	if _world and _world.ball and _world.ball.has_method("reset_state"):
		_world.ball.reset_state(clamped, Vector3.ZERO, Vector3.ZERO)
	elif _world and _world.ball and _world.ball.has_method("reset_to_spawn"):
		_world.ball.reset_to_spawn()
		if clamped != BallConfigRef.SPAWN_POSITION:
			_world.ball.global_position = clamped
	ball_reset.emit(clamped)

func reset_car(pos: Vector3 = Vector3.INF) -> void:
	var target: Vector3 = pos
	if pos == Vector3.INF:
		target = CarPhysicsRef.get_spawn_position() + CAR_SPAWN_OFFSET if CarPhysicsRef.has_method("get_spawn_position") else Vector3(0, 1.05, -10.0)
	else:
		target = PC.clamp_to_arena(pos)
	if _world and _world.car and _world.car.has_method("reset_to_position"):
		_world.car.reset_to_position(target)
	elif _world and _world.car and _world.car.has_method("reset_to_spawn"):
		_world.car.reset_to_spawn()
		if target != CarPhysicsRef.get_spawn_position():
			_world.car.global_position = target
			_world.car.global_rotation = Vector3.ZERO
	car_reset.emit(target)

func reset_all() -> void:
	if _world and _world.has_method("reset_world"):
		_world.reset_world()
		# Place car slightly behind ball for free-play start
		if _world.car:
			var offset_pos: Vector3 = CarPhysicsRef.get_spawn_position() + CAR_SPAWN_OFFSET
			if _world.car.has_method("reset_to_position"):
				_world.car.reset_to_position(offset_pos)
	else:
		reset_ball()
		reset_car()
	training_reset.emit()

# ---------------------------------------------------------------------------
# Validation / telemetry (conventions S11)
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA mismatch")
	if not is_equal_approx(ARENA_LENGTH, PC.ARENA_LENGTH):
		errors.append("ARENA_LENGTH %.1f != PC %.1f" % [ARENA_LENGTH, PC.ARENA_LENGTH])
	if not is_equal_approx(ARENA_WIDTH, PC.ARENA_WIDTH):
		errors.append("ARENA_WIDTH %.1f != PC %.1f" % [ARENA_WIDTH, PC.ARENA_WIDTH])
	if not is_equal_approx(ARENA_HEIGHT, PC.ARENA_HEIGHT):
		errors.append("ARENA_HEIGHT mismatch")
	if not is_equal_approx(ARENA_HALF_LENGTH, PC.ARENA_HALF_LENGTH):
		errors.append("ARENA_HALF_LENGTH mismatch")
	if not is_equal_approx(ARENA_HALF_WIDTH, PC.ARENA_HALF_WIDTH):
		errors.append("ARENA_HALF_WIDTH mismatch")
	if not is_equal_approx(BALL_SPAWN_ALT.y, BallConfigRef.SPAWN_POSITION.y):
		errors.append("BALL_SPAWN_ALT.y %.2f != BallConfig %.2f" % [BALL_SPAWN_ALT.y, BallConfigRef.SPAWN_POSITION.y])
	if MAX_CALLS_PER_FRAME > 12:
		errors.append("MAX_CALLS_PER_FRAME exceeds budget 12")
	var wv := WorldRef.debug_validate()
	if not wv["ok"]:
		for e in wv["errors"]:
			errors.append("World: " + str(e))
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"state": _state,
		"is_free_play": _is_free_play,
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"tick_delta": TICK_DELTA,
		"has_world": _world != null,
		"has_ball": _world != null and _world.ball != null,
		"has_car": _world != null and _world.car != null,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "Training", "tick_hz": PHYSICS_TICKS_PER_SECOND, "budget_calls": MAX_CALLS_PER_FRAME}
