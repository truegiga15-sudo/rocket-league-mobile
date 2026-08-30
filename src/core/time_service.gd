# TimeService — WS05 Time Step & Determinism
# Godot 4.x autoload singleton. Fixed 120 Hz physics tick, delta clamp [1/240,1/30],
# accumulator-based fixed-step simulation, and determinism helpers.
# Conventions: docs/architecture/00-conventions.md §3, src/core/constants.gd §Time/Tick
# Determinism: src/core/determinism.md
extends Node
class_name TimeServiceClass

const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0
const DELTA_MIN: float = 1.0 / 240.0
const DELTA_MAX: float = 1.0 / 30.0
const MAX_TICKS_PER_FRAME: int = 4
const INPUT_QUANT_STEPS: int = 127

var _accumulator: float = 0.0
var _tick_count: int = 0
var _total_time: float = 0.0
var _last_raw_delta: float = 0.0
var _last_clamped_delta: float = 0.0
var _frame_count: int = 0
var _min_seen_clamped: float = 1.0
var _max_seen_clamped: float = 0.0

signal tick_advanced(tick: int)
signal accumulator_updated(accumulator: float)

func _ready() -> void:
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 120))
	if ps_rate != PHYSICS_TICKS_PER_SECOND:
		push_warning("[TimeService] physics_ticks_per_second=%d != expected %d — fix project.godot" % [ps_rate, PHYSICS_TICKS_PER_SECOND])

static func clamp_delta(delta: float) -> float:
	return clamp(delta, DELTA_MIN, DELTA_MAX)

static func clamp_frame_delta(delta: float) -> float:
	return clamp_delta(delta)

static func get_fixed_delta() -> float:
	return TICK_DELTA

static func quantize_axis(value: float, steps: int = INPUT_QUANT_STEPS) -> int:
	var clamped := clamp(value, -1.0, 1.0)
	return int(round(clamped * float(steps)))

static func dequantize_axis(q: int, steps: int = INPUT_QUANT_STEPS) -> float:
	var clamped_q := clamp(q, -steps, steps)
	return float(clamped_q) / float(steps)

static func quantize_vector2(v: Vector2, steps: int = INPUT_QUANT_STEPS) -> Vector2i:
	return Vector2i(quantize_axis(v.x, steps), quantize_axis(v.y, steps))

static func dequantize_vector2(q: Vector2i, steps: int = INPUT_QUANT_STEPS) -> Vector2:
	return Vector2(dequantize_axis(q.x, steps), dequantize_axis(q.y, steps))

static func quantize_input(move: Vector2, look: Vector2, boost: bool, jump: bool, drift: bool, ball_cam: bool) -> Dictionary:
	var q_move := quantize_vector2(move)
	var q_look := quantize_vector2(look)
	return {"move_x": q_move.x, "move_y": q_move.y, "look_x": q_look.x, "look_y": q_look.y, "boost": 1 if boost else 0, "jump": 1 if jump else 0, "drift": 1 if drift else 0, "ball_cam": 1 if ball_cam else 0}

static func dequantize_input(entry: Dictionary) -> Dictionary:
	return {"move": dequantize_vector2(Vector2i(int(entry.get("move_x", 0)), int(entry.get("move_y", 0)))), "look": dequantize_vector2(Vector2i(int(entry.get("look_x", 0)), int(entry.get("look_y", 0)))), "boost": bool(int(entry.get("boost", 0))), "jump": bool(int(entry.get("jump", 0))), "drift": bool(int(entry.get("drift", 0))), "ball_cam": bool(int(entry.get("ball_cam", 0)))}

func advance(delta: float) -> int:
	_last_raw_delta = delta
	var clamped := clamp_delta(delta)
	_last_clamped_delta = clamped
	_accumulator += clamped
	_frame_count += 1
	if clamped < _min_seen_clamped: _min_seen_clamped = clamped
	if clamped > _max_seen_clamped: _max_seen_clamped = clamped
	var ticks: int = int(floor(_accumulator / TICK_DELTA))
	if ticks > MAX_TICKS_PER_FRAME:
		var dropped := ticks - MAX_TICKS_PER_FRAME
		_accumulator -= float(dropped) * TICK_DELTA
		ticks = MAX_TICKS_PER_FRAME
		push_warning("[TimeService] clamped %d excess ticks (delta=%.4f)" % [dropped, delta])
	for i in ticks:
		_accumulator -= TICK_DELTA
		if _accumulator < 0.0 and _accumulator > -0.000001: _accumulator = 0.0
		_tick_count += 1
		_total_time += TICK_DELTA
		tick_advanced.emit(_tick_count)
	if ticks > 0: accumulator_updated.emit(_accumulator)
	return ticks

func ticks_for_delta(delta: float) -> int:
	var clamped := clamp_delta(delta)
	var acc := _accumulator + clamped
	var ticks := int(floor(acc / TICK_DELTA))
	return clamp(ticks, 0, MAX_TICKS_PER_FRAME)

func consume_tick() -> bool:
	if _accumulator >= TICK_DELTA - 0.0000001:
		_accumulator -= TICK_DELTA
		if _accumulator < 0.0: _accumulator = 0.0
		_tick_count += 1
		_total_time += TICK_DELTA
		tick_advanced.emit(_tick_count)
		return true
	return false

func get_alpha() -> float: return clamp(_accumulator / TICK_DELTA, 0.0, 1.0)
func get_accumulator() -> float: return _accumulator
func get_tick_count() -> int: return _tick_count
func get_total_time() -> float: return _total_time
func get_last_clamped_delta() -> float: return _last_clamped_delta
func get_frame_count() -> int: return _frame_count
func reset() -> void:
	_accumulator = 0.0; _tick_count = 0; _total_time = 0.0; _last_raw_delta = 0.0; _last_clamped_delta = 0.0; _frame_count = 0; _min_seen_clamped = 1.0; _max_seen_clamped = 0.0

func validate_config() -> Dictionary:
	var errors: Array[String] = []
	var pc := preload("res://src/core/constants.gd")
	if PHYSICS_TICKS_PER_SECOND != pc.PHYSICS_TICKS_PER_SECOND: errors.append("TICKS_PER_SECOND mismatch with PhysicsConstants")
	if not is_equal_approx(TICK_DELTA, pc.PHYSICS_TICK_DELTA): errors.append("TICK_DELTA mismatch")
	if not is_equal_approx(DELTA_MIN, pc.DELTA_MIN): errors.append("DELTA_MIN mismatch")
	if not is_equal_approx(DELTA_MAX, pc.DELTA_MAX): errors.append("DELTA_MAX mismatch")
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0): errors.append("TICK_DELTA != 1/120")
	if not is_equal_approx(DELTA_MIN, 1.0 / 240.0): errors.append("DELTA_MIN != 1/240")
	if not is_equal_approx(DELTA_MAX, 1.0 / 30.0): errors.append("DELTA_MAX != 1/30")
	if DELTA_MIN >= DELTA_MAX: errors.append("DELTA_MIN >= DELTA_MAX")
	if not is_equal_approx(DELTA_MIN * 2.0, TICK_DELTA): errors.append("DELTA_MIN*2 != TICK_DELTA")
	if not is_equal_approx(DELTA_MAX / 4.0, TICK_DELTA): errors.append("DELTA_MAX/4 != TICK_DELTA")
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != PHYSICS_TICKS_PER_SECOND: errors.append("project.godot physics_ticks_per_second=%d != %d" % [ps_rate, PHYSICS_TICKS_PER_SECOND])
	if _accumulator < -0.0001 or _accumulator >= TICK_DELTA + 0.0001: errors.append("accumulator out of [0, TICK_DELTA): %.6f" % _accumulator)
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND, "tick_delta": TICK_DELTA, "delta_min": DELTA_MIN, "delta_max": DELTA_MAX, "max_ticks_per_frame": MAX_TICKS_PER_FRAME, "accumulator": _accumulator, "alpha": get_alpha(), "tick_count": _tick_count, "total_time": _total_time, "last_raw_delta": _last_raw_delta, "last_clamped_delta": _last_clamped_delta, "frame_count": _frame_count, "min_seen_clamped": _min_seen_clamped if _frame_count > 0 else 0.0, "max_seen_clamped": _max_seen_clamped, "is_fixed_timestep": true, "input_quant_steps": INPUT_QUANT_STEPS}

func perf_mark() -> Dictionary:
	return {"tick_count": _tick_count, "accumulator_ms": _accumulator * 1000.0, "frame_count": _frame_count, "alpha": get_alpha()}
