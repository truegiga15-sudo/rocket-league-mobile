## WS58 — Match Timer & Overtime Rules (budget-aware, <12 calls)
## 5-minute countdown, overtime sudden-death, 120 Hz fixed tick.
## Depends on: src/core/constants.gd (WS04), src/core/time_service.gd (WS05),
##             src/game/arena/goal.gd (WS22).
## Budget: <12 API calls per tick, <4 ms, deterministic, no per-frame alloc.
extends Node
class_name MatchTimer

const PC = preload("res://src/core/constants.gd")
const TimeSvc = preload("res://src/core/time_service.gd")
const GoalRef = preload("res://src/game/arena/goal.gd")

# ---------------------------------------------------------------------------
# Tick — must match PhysicsConstants + TimeService + project.godot (120 Hz)
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0
const TICK_HZ: int = 120
const DELTA_MIN: float = 1.0 / 240.0
const DELTA_MAX: float = 1.0 / 30.0

# ---------------------------------------------------------------------------
# Match constants — single source of truth for WS58
# ---------------------------------------------------------------------------
const MATCH_DURATION: float = 300.0  # 5 minutes in seconds
const MATCH_DURATION_TICKS: int = 36000  # 300 * 120
const OVERTIME_DURATION_UNLIMITED: bool = true  # sudden-death, no fixed cap
const MAX_OVERTIME_TICKS: int = 36000  # soft cap 5 min OT for telemetry only
const COUNTDOWN_WARN_SECONDS: float = 30.0
const COUNTDOWN_WARN_TICKS: int = 3600  # 30 * 120

# Budget
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK
const BUDGET_PHYSICS_MS: float = 4.0
const ESTIMATED_PHYSICS_MS: float = 0.05
const ESTIMATED_DRAW_CALLS: int = 0

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
enum State { IDLE, RUNNING, OVERTIME, FINISHED }

var _state: int = State.IDLE
var _ticks_remaining: int = MATCH_DURATION_TICKS
var _ticks_elapsed: int = 0
var _overtime_ticks: int = 0
var _score_positive: int = 0  # goals in +Z (team +1)
var _score_negative: int = 0  # goals in -Z (team -1)
var _is_paused: bool = false
var _call_count: int = 0

# Signals — budget-aware: event-driven, no polling
signal time_updated(remaining_ticks: int, remaining_seconds: float)
signal tick_advanced(tick: int, remaining_seconds: float)
signal goal_scored(team: int, score_pos: int, score_neg: int)
signal overtime_started(tick: int)
signal match_ended(winner: int, score_pos: int, score_neg: int, reason: String)
signal countdown_warning(seconds_remaining: float)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[MatchTimer] debug_validate: %s" % e)

func _physics_process(_delta: float) -> void:
	if _state == State.RUNNING or _state == State.OVERTIME:
		if not _is_paused:
			tick()

# ---------------------------------------------------------------------------
# Core tick — call once per physics tick (120 Hz). Budget: <12 calls.
# ---------------------------------------------------------------------------
func tick() -> void:
	_call_count = 0
	if _is_paused:
		return
	if _state != State.RUNNING and _state != State.OVERTIME:
		return

	_call_count += 1  # state check
	if _state == State.RUNNING:
		_ticks_remaining -= 1
		_ticks_elapsed += 1
		_call_count += 1
		if _ticks_remaining <= 0:
			_ticks_remaining = 0
			_handle_time_expired()
		else:
			if _ticks_remaining == COUNTDOWN_WARN_TICKS:
				countdown_warning.emit(float(_ticks_remaining) * TICK_DELTA)
			time_updated.emit(_ticks_remaining, float(_ticks_remaining) * TICK_DELTA)
			tick_advanced.emit(_ticks_elapsed, float(_ticks_remaining) * TICK_DELTA)
	elif _state == State.OVERTIME:
		_overtime_ticks += 1
		_ticks_elapsed += 1
		_call_count += 1
		time_updated.emit(0, 0.0)
		tick_advanced.emit(_ticks_elapsed, 0.0)

func _handle_time_expired() -> void:
	_call_count += 1
	if _score_positive == _score_negative:
		# Tied — enter overtime (RL overtime: clock at 0:00 + overtime flag, next goal wins)
		_state = State.OVERTIME
		_overtime_ticks = 0
		overtime_started.emit(_ticks_elapsed)
		time_updated.emit(0, 0.0)
	else:
		# Winner decided
		var winner := 1 if _score_positive > _score_negative else -1
		_state = State.FINISHED
		match_ended.emit(winner, _score_positive, _score_negative, "time_expired")

# ---------------------------------------------------------------------------
# Goal integration — call from World/Goal goal_scored signal (WS22)
# ---------------------------------------------------------------------------
func on_goal(team: int) -> void:
	if _state == State.FINISHED:
		return
	if team == 1:
		_score_positive += 1
	elif team == -1:
		_score_negative += 1
	else:
		return
	_call_count += 1
	goal_scored.emit(team, _score_positive, _score_negative)

	# In overtime, any goal ends the match immediately (sudden death)
	if _state == State.OVERTIME:
		var winner := team
		_state = State.FINISHED
		match_ended.emit(winner, _score_positive, _score_negative, "overtime_goal")

## Convenience: wire to Goal nodes directly
func wire_goals(goal_pos: Goal, goal_neg: Goal) -> void:
	if goal_pos and not goal_pos.goal_scored.is_connected(on_goal):
		goal_pos.goal_scored.connect(on_goal)
	if goal_neg and not goal_neg.goal_scored.is_connected(on_goal):
		goal_neg.goal_scored.connect(on_goal)

func wire_goal_nodes(goals: Array) -> void:
	for g in goals:
		if g is Goal and not (g as Goal).goal_scored.is_connected(on_goal):
			(g as Goal).goal_scored.connect(on_goal)

# ---------------------------------------------------------------------------
# Control
# ---------------------------------------------------------------------------
func start() -> void:
	_state = State.RUNNING
	_ticks_remaining = MATCH_DURATION_TICKS
	_ticks_elapsed = 0
	_overtime_ticks = 0
	_is_paused = false
	_score_positive = 0
	_score_negative = 0
	time_updated.emit(_ticks_remaining, float(_ticks_remaining) * TICK_DELTA)

func reset() -> void:
	_state = State.IDLE
	_ticks_remaining = MATCH_DURATION_TICKS
	_ticks_elapsed = 0
	_overtime_ticks = 0
	_is_paused = false
	_score_positive = 0
	_score_negative = 0

func pause() -> void:
	_is_paused = true

func resume() -> void:
	_is_paused = false

func finish(winner: int = 0, reason: String = "manual") -> void:
	if _state == State.FINISHED:
		return
	_state = State.FINISHED
	match_ended.emit(winner, _score_positive, _score_negative, reason)

# ---------------------------------------------------------------------------
# Queries — no side effects, budget-free
# ---------------------------------------------------------------------------
func get_remaining_ticks() -> int:
	return _ticks_remaining

func get_remaining_seconds() -> float:
	if _state == State.OVERTIME:
		return 0.0
	return float(_ticks_remaining) * TICK_DELTA

func get_elapsed_ticks() -> int:
	return _ticks_elapsed

func get_elapsed_seconds() -> float:
	return float(_ticks_elapsed) * TICK_DELTA

func get_overtime_ticks() -> int:
	return _overtime_ticks

func get_overtime_seconds() -> float:
	return float(_overtime_ticks) * TICK_DELTA

func is_overtime() -> bool:
	return _state == State.OVERTIME

func is_finished() -> bool:
	return _state == State.FINISHED

func is_running() -> bool:
	return _state == State.RUNNING or _state == State.OVERTIME

func is_paused() -> bool:
	return _is_paused

func get_state() -> int:
	return _state

func get_state_name() -> String:
	match _state:
		State.IDLE: return "idle"
		State.RUNNING: return "running"
		State.OVERTIME: return "overtime"
		State.FINISHED: return "finished"
		_: return "unknown"

func get_score(team: int) -> int:
	if team == 1:
		return _score_positive
	elif team == -1:
		return _score_negative
	return 0

func get_scores() -> Dictionary:
	return {"positive": _score_positive, "negative": _score_negative, "team_1": _score_positive, "team_minus1": _score_negative}

func is_tied() -> bool:
	return _score_positive == _score_negative

func get_winner() -> int:
	if _score_positive > _score_negative:
		return 1
	elif _score_negative > _score_positive:
		return -1
	return 0

func format_time() -> String:
	if _state == State.OVERTIME:
		var ot := float(_overtime_ticks) * TICK_DELTA
		var m := int(ot) / 60
		var s := int(ot) % 60
		return "+%d:%02d" % [m, s]
	var secs := _ticks_remaining * TICK_DELTA
	var m2 := int(secs) / 60
	var s2 := int(secs) % 60
	return "%d:%02d" % [m2, s2]

func format_time_precise() -> String:
	if _state == State.OVERTIME:
		return "+%s OT" % format_time()
	return format_time()

static func format_ticks(ticks: int) -> String:
	var secs := float(ticks) * TICK_DELTA
	var m := int(secs) / 60
	var s := int(secs) % 60
	return "%d:%02d" % [m, s]

# ---------------------------------------------------------------------------
# Serialization
# ---------------------------------------------------------------------------
func get_state_dict() -> Dictionary:
	return {
		"state": _state,
		"state_name": get_state_name(),
		"ticks_remaining": _ticks_remaining,
		"ticks_elapsed": _ticks_elapsed,
		"overtime_ticks": _overtime_ticks,
		"score_positive": _score_positive,
		"score_negative": _score_negative,
		"is_paused": _is_paused,
	}

func set_state_dict(d: Dictionary) -> void:
	_state = int(d.get("state", State.IDLE))
	_ticks_remaining = int(d.get("ticks_remaining", MATCH_DURATION_TICKS))
	_ticks_elapsed = int(d.get("ticks_elapsed", 0))
	_overtime_ticks = int(d.get("overtime_ticks", 0))
	_score_positive = int(d.get("score_positive", 0))
	_score_negative = int(d.get("score_negative", 0))
	_is_paused = bool(d.get("is_paused", false))

# ---------------------------------------------------------------------------
# Validation / telemetry (conventions §11)
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if TICK_HZ != 120:
		errors.append("TICK_HZ != 120")
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA %.8f != 1/120" % TICK_DELTA)
	if not is_equal_approx(DELTA_MIN, 1.0 / 240.0):
		errors.append("DELTA_MIN != 1/240")
	if not is_equal_approx(DELTA_MAX, 1.0 / 30.0):
		errors.append("DELTA_MAX != 1/30")
	if not is_equal_approx(MATCH_DURATION, 300.0):
		errors.append("MATCH_DURATION %.2f != 300.0" % MATCH_DURATION)
	if MATCH_DURATION_TICKS != 36000:
		errors.append("MATCH_DURATION_TICKS %d != 36000" % MATCH_DURATION_TICKS)
	if MATCH_DURATION_TICKS != int(MATCH_DURATION * float(PHYSICS_TICKS_PER_SECOND)):
		errors.append("MATCH_DURATION_TICKS != MATCH_DURATION * TICKS_PER_SECOND")
	if COUNTDOWN_WARN_TICKS != int(COUNTDOWN_WARN_SECONDS * float(PHYSICS_TICKS_PER_SECOND)):
		errors.append("COUNTDOWN_WARN_TICKS mismatch")
	if MAX_CALLS_PER_TICK > 12:
		errors.append("MAX_CALLS_PER_TICK %d > 12" % MAX_CALLS_PER_TICK)
	if TimeSvc.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("TimeService PHYSICS_TICKS_PER_SECOND %d != 120" % TimeSvc.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TimeSvc.TICK_DELTA, TICK_DELTA):
		errors.append("TimeService TICK_DELTA mismatch")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PhysicsConstants PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PC.PHYSICS_TICK_DELTA, TICK_DELTA):
		errors.append("PhysicsConstants TICK_DELTA mismatch")
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != -1 and ps_rate != 120:
		errors.append("project.godot physics_ticks_per_second=%d != 120" % ps_rate)
	# Goal cross-check
	var v_goal := GoalRef.debug_validate()
	if not v_goal["ok"]:
		for e in v_goal["errors"]:
			errors.append("Goal: %s" % str(e))
	if GoalRef.GOAL_WIDTH != PC.GOAL_WIDTH:
		errors.append("Goal GOAL_WIDTH drift vs PhysicsConstants")
	if GoalRef.GOAL_HEIGHT != PC.GOAL_HEIGHT:
		errors.append("Goal GOAL_HEIGHT drift vs PhysicsConstants")
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"match_duration": MATCH_DURATION,
		"match_duration_ticks": MATCH_DURATION_TICKS,
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"tick_delta": TICK_DELTA,
		"state": _state,
		"state_name": get_state_name(),
		"ticks_remaining": _ticks_remaining,
		"remaining_seconds": get_remaining_seconds(),
		"ticks_elapsed": _ticks_elapsed,
		"elapsed_seconds": get_elapsed_seconds(),
		"overtime_ticks": _overtime_ticks,
		"overtime_seconds": get_overtime_seconds(),
		"is_overtime": is_overtime(),
		"is_finished": is_finished(),
		"is_paused": _is_paused,
		"score_positive": _score_positive,
		"score_negative": _score_negative,
		"is_tied": is_tied(),
		"formatted": format_time(),
		"call_count": _call_count,
		"budget_calls": MAX_CALLS_PER_TICK,
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "MatchTimer",
		"tick_hz": PHYSICS_TICKS_PER_SECOND,
		"tick_delta": TICK_DELTA,
		"budget_calls": MAX_CALLS_PER_TICK,
		"estimated_physics_ms": ESTIMATED_PHYSICS_MS,
		"budget_physics_ms": BUDGET_PHYSICS_MS,
		"estimated_draw_calls": ESTIMATED_DRAW_CALLS,
	}

func get_call_count() -> int:
	return _call_count
