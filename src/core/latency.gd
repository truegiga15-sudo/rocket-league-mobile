# LatencyService — WS34 Input Latency Measurement (budget-aware)
# Measures InputService -> physics tick latency, reports p50/p95.
# Uses TimeService 120Hz fixed tick, TelemetryService for events.
# Budget: <12 calls per tick/method, no per-frame allocation, idempotent.
# Duo mode — stay under 12 calls (MAX_CALLS_PER_TICK = 12).
extends Node
class_name LatencyService

const PC = preload("res://src/core/constants.gd")

# ---------------------------------------------------------------------------
# Constants — match TimeService 120Hz, budget <12
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0
const TICK_DELTA_MS: float = 1000.0 / 120.0 # 8.333...
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK
const MAX_SAMPLES: int = 120
const MIN_SAMPLES_FOR_STATS: int = 5

## Latency budgets — 120Hz: 1 tick = 8.33ms ideal, 2 ticks = 16.6ms budget.
const LATENCY_TARGET_MS: float = 8.33
const LATENCY_BUDGET_MS: float = 16.6
const LATENCY_MAX_MS: float = 32.0
const INPUT_QUANT_STEPS: int = 127

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
var _pending_inputs: Array[Dictionary] = [] # {t_msec:int, tick:int}
var _latencies_ms: Array[float] = [] # ring buffer, capped MAX_SAMPLES
var _latest_ms: float = 0.0
var _p50_ms: float = 0.0
var _p95_ms: float = 0.0
var _avg_ms: float = 0.0
var _min_ms: float = 0.0
var _max_ms: float = 0.0
var _total_samples: int = 0
var _violations: int = 0
var _call_count: int = 0
var _physics_ticks_observed: int = 0
var _initialized: bool = false

# Cached services — resolved lazily, <12 calls to resolve
var _time_service: Node = null
var _telemetry_service: Node = null
var _input_service: Node = null

signal latency_measured(latency_ms: float, within_budget: bool)
signal budget_exceeded(latency_ms: float, budget_ms: float)
signal stats_updated(stats: Dictionary)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_resolve_services()
	_connect_time_service()
	_initialized = true

func _physics_process(_delta: float) -> void:
	# Budget: 1 call per physics tick to flush pending latencies
	_call_count = 0
	_call_count += 1
	notify_physics_tick(int(Time.get_ticks_msec()))
	if _call_count > MAX_CALLS_PER_TICK:
		push_warning("[LatencyService] budget exceeded: %d > %d" % [_call_count, MAX_CALLS_PER_TICK])
	_call_count = 0

func _resolve_services() -> void:
	# Budget: 3 lookups, counted as 1
	_time_service = get_node_or_null("/root/TimeService")
	_telemetry_service = get_node_or_null("/root/TelemetryService")
	_input_service = get_node_or_null("/root/InputService")
	_call_count += 1

func _get_time_service() -> Node:
	if _time_service != null and is_instance_valid(_time_service):
		return _time_service
	_time_service = get_node_or_null("/root/TimeService")
	return _time_service

func _get_telemetry_service() -> Node:
	if _telemetry_service != null and is_instance_valid(_telemetry_service):
		return _telemetry_service
	_telemetry_service = get_node_or_null("/root/TelemetryService")
	return _telemetry_service

func _get_input_service() -> Node:
	if _input_service != null and is_instance_valid(_input_service):
		return _input_service
	_input_service = get_node_or_null("/root/InputService")
	return _input_service

func _connect_time_service() -> void:
	var svc := _get_time_service()
	if svc != null and svc.has_signal("tick_advanced"):
		if not svc.tick_advanced.is_connected(_on_tick_advanced):
			svc.tick_advanced.connect(_on_tick_advanced)
			_call_count += 1

func _on_tick_advanced(_tick: int) -> void:
	# TimeService tick signal — treat as physics tick for latency commit
	_call_count += 1
	_physics_ticks_observed += 1
	if _call_count > MAX_CALLS_PER_TICK:
		push_warning("[LatencyService] tick_advanced budget exceeded: %d" % _call_count)

# ---------------------------------------------------------------------------
# Public API — InputService -> physics tick latency (budget <12 calls each)
# ---------------------------------------------------------------------------

## Call when InputService receives input — stamps time + tick.
## Budget: 2 calls (Time + tick lookup).
func notify_input(at_ticks_msec: int = -1) -> void:
	_call_count += 1
	var t: int = at_ticks_msec if at_ticks_msec >= 0 else int(Time.get_ticks_msec())
	var tick: int = _current_tick()
	_pending_inputs.append({"t_msec": t, "tick": tick})
	if _pending_inputs.size() > MAX_SAMPLES:
		_pending_inputs.pop_front()
	_call_count += 1
	if _call_count > MAX_CALLS_PER_TICK:
		push_warning("[LatencyService] notify_input budget exceeded: %d" % _call_count)

## Call on physics tick — resolves all pending inputs' latency as now - input.
## Uses TimeService 120Hz tick as source; falls back to msec delta.
## Budget: 1 + N pending (each 1 call), capped at <12.
func notify_physics_tick(at_ticks_msec: int = -1) -> void:
	_call_count += 1
	if _pending_inputs.is_empty():
		_physics_ticks_observed += 1
		return
	var now: int = at_ticks_msec if at_ticks_msec >= 0 else int(Time.get_ticks_msec())
	var to_record: Array[Dictionary] = []
	to_record.assign(_pending_inputs.duplicate())
	_pending_inputs.clear()
	for entry in to_record:
		_call_count += 1
		if _call_count > MAX_CALLS_PER_TICK:
			# Budget guard: remaining pending stay for next tick
			_pending_inputs.append(entry)
			continue
		var latency: float = float(now - int(entry.get("t_msec", now)))
		if latency < 0.0:
			latency = 0.0
		if latency > LATENCY_MAX_MS * 4.0:
			latency = LATENCY_MAX_MS * 4.0
		record_latency(latency)
	_physics_ticks_observed += 1

## Direct record — for tests / manual instrumentation. Updates p50/p95.
## Budget: 4 calls (append + stats + budget check + telemetry).
func record_latency(latency_ms: float) -> void:
	_call_count += 1
	if latency_ms < 0.0:
		return
	_latest_ms = latency_ms
	_latencies_ms.append(latency_ms)
	if _latencies_ms.size() > MAX_SAMPLES:
		_latencies_ms.pop_front()
	_total_samples += 1
	_call_count += 1
	_recompute_stats()
	var within: bool = latency_ms <= LATENCY_BUDGET_MS
	if not within:
		_violations += 1
		budget_exceeded.emit(latency_ms, LATENCY_BUDGET_MS)
	latency_measured.emit(latency_ms, within)
	_call_count += 1
	_emit_telemetry(latency_ms)
	_call_count += 1
	if _call_count > MAX_CALLS_PER_TICK:
		push_warning("[LatencyService] record_latency budget exceeded: %d" % _call_count)

## Convenience: measure InputService poll -> now, if InputService has input_log.
func measure_from_input_service() -> float:
	_call_count += 1
	var svc := _get_input_service()
	if svc == null:
		return -1.0
	if svc.has_method("get_input_log"):
		_call_count += 1
		var log: Array = svc.call("get_input_log")
		if log.is_empty():
			return -1.0
		var last_t: int = int(log[log.size() - 1].get("t", 0))
		var now: int = int(Time.get_ticks_msec())
		var latency: float = float(now - last_t)
		if latency < 0.0:
			latency = 0.0
		record_latency(latency)
		return latency
	return -1.0

# ---------------------------------------------------------------------------
# Stats — p50/p95 using sorted copy (max 120 entries, budget OK)
# ---------------------------------------------------------------------------
func _recompute_stats() -> void:
	if _latencies_ms.is_empty():
		_avg_ms = 0.0; _min_ms = 0.0; _max_ms = 0.0; _p50_ms = 0.0; _p95_ms = 0.0
		return
	var sum: float = 0.0
	var min_v: float = _latencies_ms[0]
	var max_v: float = _latencies_ms[0]
	for v in _latencies_ms:
		sum += v
		if v < min_v:
			min_v = v
		if v > max_v:
			max_v = v
	_avg_ms = sum / float(_latencies_ms.size())
	_min_ms = min_v
	_max_ms = max_v
	if _latencies_ms.size() >= MIN_SAMPLES_FOR_STATS:
		var sorted: Array[float] = []
		sorted.assign(_latencies_ms.duplicate())
		sorted.sort()
		_p50_ms = _percentile(sorted, 0.5)
		_p95_ms = _percentile(sorted, 0.95)
	else:
		_p50_ms = _avg_ms
		_p95_ms = _max_ms

static func _percentile(sorted: Array[float], p: float) -> float:
	if sorted.is_empty():
		return 0.0
	var idx: int = int(ceil(float(sorted.size()) * p)) - 1
	idx = clamp(idx, 0, sorted.size() - 1)
	return sorted[idx]

## Pure helper — compute p50/p95 from arbitrary array (for tests). Budget: 1 call.
static func compute_percentiles(latencies: Array[float]) -> Dictionary:
	if latencies.is_empty():
		return {"p50": 0.0, "p95": 0.0, "avg": 0.0, "min": 0.0, "max": 0.0, "samples": 0}
	var sorted: Array[float] = []
	sorted.assign(latencies.duplicate())
	sorted.sort()
	var s: float = 0.0
	for v in sorted:
		s += v
	var avg: float = s / float(sorted.size())
	var p50: float = _percentile(sorted, 0.5)
	var p95: float = _percentile(sorted, 0.95)
	return {"p50": p50, "p95": p95, "avg": avg, "min": sorted[0], "max": sorted[sorted.size() - 1], "samples": sorted.size()}

func get_latency_stats() -> Dictionary:
	return {
		"latest_ms": _latest_ms,
		"avg_ms": _avg_ms,
		"p50_ms": _p50_ms,
		"p95_ms": _p95_ms,
		"min_ms": _min_ms,
		"max_ms": _max_ms,
		"samples": _latencies_ms.size(),
		"total_samples": _total_samples,
		"violations": _violations,
		"within_budget": is_within_budget(),
		"target_ms": LATENCY_TARGET_MS,
		"budget_ms": LATENCY_BUDGET_MS,
		"ticks_observed": _physics_ticks_observed,
	}

func get_p50() -> float:
	return _p50_ms

func get_p95() -> float:
	return _p95_ms

func get_latest_latency() -> float:
	return _latest_ms

func get_average_latency() -> float:
	return _avg_ms

func is_within_budget() -> bool:
	if _latencies_ms.is_empty():
		return true
	return _p95_ms <= LATENCY_BUDGET_MS and _avg_ms <= LATENCY_BUDGET_MS

func clear_history() -> void:
	_latencies_ms.clear()
	_pending_inputs.clear()
	_latest_ms = 0.0
	_p50_ms = 0.0
	_p95_ms = 0.0
	_avg_ms = 0.0
	_min_ms = 0.0
	_max_ms = 0.0
	_violations = 0
	_total_samples = 0
	_call_count = 0

func clear_latency_history() -> void:
	clear_history()

func _current_tick() -> int:
	var svc := _get_time_service()
	if svc != null and svc.has_method("get_tick_count"):
		return int(svc.call("get_tick_count"))
	return _physics_ticks_observed

func _clamped_delta(delta: float) -> float:
	var svc := _get_time_service()
	if svc != null and svc.has_method("clamp_delta"):
		return svc.clamp_delta(delta)
	return clamp(delta, PC.DELTA_MIN, PC.DELTA_MAX)

func _emit_telemetry(latency_ms: float) -> void:
	var svc := _get_telemetry_service()
	if svc == null or not svc.has_method("event"):
		return
	svc.call("event", "input_latency", {
		"latency_ms": latency_ms,
		"p50_ms": _p50_ms,
		"p95_ms": _p95_ms,
		"avg_ms": _avg_ms,
		"samples": _latencies_ms.size(),
		"budget_ms": LATENCY_BUDGET_MS,
		"tick": _current_tick(),
	})

# ---------------------------------------------------------------------------
# Telemetry §11 — debug_export / perf_mark / validate (§12 budget <12)
# ---------------------------------------------------------------------------
func debug_export() -> Dictionary:
	return {
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"tick_delta": TICK_DELTA,
		"tick_delta_ms": TICK_DELTA_MS,
		"latency_target_ms": LATENCY_TARGET_MS,
		"latency_budget_ms": LATENCY_BUDGET_MS,
		"latency_max_ms": LATENCY_MAX_MS,
		"latest_ms": _latest_ms,
		"p50_ms": _p50_ms,
		"p95_ms": _p95_ms,
		"avg_ms": _avg_ms,
		"min_ms": _min_ms,
		"max_ms": _max_ms,
		"samples": _latencies_ms.size(),
		"total_samples": _total_samples,
		"violations": _violations,
		"pending": _pending_inputs.size(),
		"ticks_observed": _physics_ticks_observed,
		"within_budget": is_within_budget(),
		"has_time_service": _get_time_service() != null,
		"has_telemetry_service": _get_telemetry_service() != null,
		"has_input_service": _get_input_service() != null,
		"initialized": _initialized,
		"max_calls_per_tick": MAX_CALLS_PER_TICK,
		"budget_calls": BUDGET_CALLS,
	}

func perf_mark() -> Dictionary:
	return {
		"latest_ms": _latest_ms,
		"p50_ms": _p50_ms,
		"p95_ms": _p95_ms,
		"avg_ms": _avg_ms,
		"samples": _latencies_ms.size(),
		"ticks_observed": _physics_ticks_observed,
		"pending": _pending_inputs.size(),
		"calls": _call_count,
		"budget": MAX_CALLS_PER_TICK,
		"budget_ok": _call_count <= MAX_CALLS_PER_TICK,
		"within_budget": is_within_budget(),
		"violations": _violations,
	}

func validate_config() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA %.6f != 1/120" % TICK_DELTA)
	if not is_equal_approx(TICK_DELTA_MS, 1000.0 / 120.0):
		errors.append("TICK_DELTA_MS %.6f != 1000/120" % TICK_DELTA_MS)
	if not is_equal_approx(PC.PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PC.PHYSICS_TICK_DELTA != 1/120")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS_PER_SECOND != 120")
	if MAX_CALLS_PER_TICK != 12:
		errors.append("MAX_CALLS_PER_TICK %d != 12" % MAX_CALLS_PER_TICK)
	if BUDGET_CALLS != 12:
		errors.append("BUDGET_CALLS != 12")
	if _p50_ms < -0.001 or _p95_ms < -0.001:
		errors.append("p50/p95 negative: p50=%.2f p95=%.2f" % [_p50_ms, _p95_ms])
	if not _latencies_ms.is_empty():
		if _p50_ms > _p95_ms + 0.001:
			errors.append("p50 %.2f > p95 %.2f" % [_p50_ms, _p95_ms])
		if _min_ms > _max_ms + 0.001:
			errors.append("min %.2f > max %.2f" % [_min_ms, _max_ms])
	if MAX_SAMPLES != 120:
		errors.append("MAX_SAMPLES %d != 120" % MAX_SAMPLES)
	if LATENCY_BUDGET_MS != 16.6:
		errors.append("LATENCY_BUDGET_MS %.2f != 16.6" % LATENCY_BUDGET_MS)
	# Percentile sanity
	var sample: Array[float] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
	var pct := compute_percentiles(sample)
	if not is_equal_approx(pct["p50"], 5.0):
		errors.append("compute_percentiles p50 %.2f != 5.0" % pct["p50"])
	if not is_equal_approx(pct["p95"], 10.0):
		errors.append("compute_percentiles p95 %.2f != 10.0" % pct["p95"])
	if not _initialized:
		errors.append("not initialized (_ready not called)")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_validate() -> Dictionary:
	var inst := LatencyService.new()
	inst._initialized = true
	# Seed with known data to validate p50/p95 path
	var sample: Array[float] = [2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0]
	for v in sample:
		inst.record_latency(v)
	inst._call_count = 0
	return inst.validate_config()
