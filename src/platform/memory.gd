# MemoryService — WS87 Memory Budget & Low-Memory Handling
# Texture budget 350MB, low-memory callbacks, WS10 profiler-aware.
# Budget-aware: <12 Performance calls per frame via caching.
# Godot 4.x — depends on Profiler (WS10 tools/perf/profiler.gd), ConfigService optional.
# Conventions: docs/architecture/00-conventions.md §12 (budgets), scene-ownership.md §2
extends Node
class_name MemoryService

# ---------------------------------------------------------------------------
# Constants — WS10 budget: texture <350MB (367001600 bytes)
# ---------------------------------------------------------------------------
const BUDGET_TEXTURE_MB: float = 350.0
const BUDGET_TEXTURE_BYTES: int = 367001600
const BUDGET_WARNING_RATIO: float = 0.85
const BUDGET_CRITICAL_RATIO: float = 0.95
const BUDGET_WARNING_BYTES: int = int(BUDGET_TEXTURE_BYTES * 0.85)
const BUDGET_CRITICAL_BYTES: int = int(BUDGET_TEXTURE_BYTES * 0.95)
const MAX_CALLS_PER_FRAME: int = 11  # stay under 12
const LOW_MEMORY_TRIM_LEVELS: Dictionary = {
	"TRIM_MEMORY_RUNNING_MODERATE": 5,
	"TRIM_MEMORY_RUNNING_LOW": 10,
	"TRIM_MEMORY_RUNNING_CRITICAL": 15,
	"TRIM_MEMORY_UI_HIDDEN": 20,
	"TRIM_MEMORY_BACKGROUND": 40,
	"TRIM_MEMORY_MODERATE": 60,
	"TRIM_MEMORY_COMPLETE": 80,
}

# ---------------------------------------------------------------------------
# Dependencies — resolved in _ready(), optional (graceful without)
# ---------------------------------------------------------------------------
var _profiler: Node = null
var _config_service: Node = null

# ---------------------------------------------------------------------------
# State — no per-frame allocation
# ---------------------------------------------------------------------------
var _low_memory_callbacks: Array[Callable] = []
var _call_count_this_frame: int = 0
var _total_calls: int = 0
var _frame_count: int = 0
var _low_memory_count: int = 0
var _over_budget_count: int = 0
var _last_texture_bytes: int = 0
var _last_video_bytes: int = 0
var _last_texture_mb: float = 0.0
var _last_ratio: float = 0.0
var _initialized: bool = false
var _handling_low_memory: bool = false
var _last_trim_level: int = 0

# Cached sample — refreshed once per frame to keep calls <12
var _cached_sample: Dictionary = {}
var _cached_frame: int = -1

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal low_memory_warning(level: int, usage_mb: float, budget_mb: float)
signal budget_exceeded(usage_bytes: int, budget_bytes: int)
signal budget_warning(usage_bytes: int, budget_bytes: int, ratio: float)
signal memory_trimmed(level: int, usage_mb: float)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_resolve_dependencies()
	_initialized = true

func _resolve_dependencies() -> void:
	_profiler = get_node_or_null("/root/Profiler")
	_config_service = get_node_or_null("/root/ConfigService")

func _process(_delta: float) -> void:
	_call_count_this_frame = 0
	_frame_count += 1
	# Refresh cache once per frame budget-aware; track stats
	var s := sample()
	_last_texture_bytes = int(s.get("texture_mem_bytes", 0))
	_last_video_bytes = int(s.get("video_mem_bytes", 0))
	_last_texture_mb = float(s.get("texture_mem_mb", 0.0))
	_last_ratio = float(s.get("ratio", 0.0))
	if _last_texture_bytes > BUDGET_TEXTURE_BYTES:
		_over_budget_count += 1
		budget_exceeded.emit(_last_texture_bytes, BUDGET_TEXTURE_BYTES)
	elif _last_texture_bytes > BUDGET_WARNING_BYTES:
		budget_warning.emit(_last_texture_bytes, BUDGET_TEXTURE_BYTES, _last_ratio)

func _notification(what: int) -> void:
	if what == NOTIFICATION_OS_MEMORY_WARNING:
		handle_low_memory(LOW_MEMORY_TRIM_LEVELS["TRIM_MEMORY_RUNNING_CRITICAL"])

# ---------------------------------------------------------------------------
# Public API — Low-memory callbacks
# ---------------------------------------------------------------------------
## Register a callback to be invoked on low-memory / over-budget.
## Callable receives (level: int, usage_mb: float). Returns false if duplicate/invalid.
func register_low_memory_callback(cb: Callable) -> bool:
	if not cb.is_valid():
		return false
	for existing in _low_memory_callbacks:
		if existing == cb:
			return false
	_low_memory_callbacks.append(cb)
	return true

func unregister_low_memory_callback(cb: Callable) -> void:
	var idx := _low_memory_callbacks.find(cb)
	if idx != -1:
		_low_memory_callbacks.remove_at(idx)

func clear_low_memory_callbacks() -> void:
	_low_memory_callbacks.clear()

func get_registered_callback_count() -> int:
	return _low_memory_callbacks.size()

func has_low_memory_callback(cb: Callable) -> bool:
	return _low_memory_callbacks.find(cb) != -1

## Handle low-memory event. Budget-aware: re-entrancy guard, invokes callbacks.
## level: Android TRIM_MEMORY_* or 0 for generic OS warning.
func handle_low_memory(level: int = 0) -> void:
	if _handling_low_memory:
		return
	_handling_low_memory = true
	_low_memory_count += 1
	_last_trim_level = level
	var usage_mb := get_texture_mem_mb()
	low_memory_warning.emit(level, usage_mb, BUDGET_TEXTURE_MB)
	memory_trimmed.emit(level, usage_mb)
	# Invoke callbacks — budget-aware: invalidate bad callables, catch errors
	var to_remove: Array[int] = []
	for i in range(_low_memory_callbacks.size()):
		var cb: Callable = _low_memory_callbacks[i]
		if not cb.is_valid():
			to_remove.append(i)
			continue
		# Call with level + usage; tolerate 0/1/2-arg callables
		var result = null
		if cb.get_argument_count() == 0:
			result = cb.call()
		elif cb.get_argument_count() == 1:
			result = cb.call(level)
		else:
			result = cb.call(level, usage_mb)
		# Callable may return error; ignore but don't crash
		if result is Dictionary and result.has("error"):
			push_warning("[MemoryService] callback error: %s" % str(result["error"]))
	# Remove invalid in reverse
	to_remove.reverse()
	for idx in to_remove:
		_low_memory_callbacks.remove_at(idx)
	# Notify profiler if available
	if _profiler and _profiler.has_method("perf_mark"):
		_profiler.perf_mark("low_memory level=%d usage=%.1fMB" % [level, usage_mb])
	_handling_low_memory = false

## Compatibility alias for Android trim callbacks.
func on_trim_memory(level: int) -> void:
	handle_low_memory(level)

func get_low_memory_count() -> int:
	return _low_memory_count

func get_last_trim_level() -> int:
	return _last_trim_level

func is_handling_low_memory() -> bool:
	return _handling_low_memory

# ---------------------------------------------------------------------------
# Memory budget — budget-aware accessors
# ---------------------------------------------------------------------------
func get_texture_mem_bytes() -> int:
	return _last_texture_bytes

func get_texture_mem_mb() -> float:
	return _last_texture_mb

func get_video_mem_bytes() -> int:
	return _last_video_bytes

func get_video_mem_mb() -> float:
	return _last_video_bytes / 1048576.0

func get_budget_bytes() -> int:
	return BUDGET_TEXTURE_BYTES

func get_budget_mb() -> float:
	return BUDGET_TEXTURE_MB

func get_usage_ratio() -> float:
	return _last_ratio

func is_over_budget() -> bool:
	return _last_texture_bytes > BUDGET_TEXTURE_BYTES

func is_near_budget(threshold: float = BUDGET_WARNING_RATIO) -> bool:
	return _last_ratio >= threshold

func is_warning_level() -> bool:
	return _last_texture_bytes > BUDGET_WARNING_BYTES

func is_critical_level() -> bool:
	return _last_texture_bytes > BUDGET_CRITICAL_BYTES

func get_over_budget_count() -> int:
	return _over_budget_count

## Check budget and return structured result. Uses cached sample (0 extra calls if cached).
func check_budget() -> Dictionary:
	var s := sample()
	var usage: int = int(s.get("texture_mem_bytes", 0))
	if usage == 0:
		usage = int(s.get("video_mem_bytes", 0))
	var ratio: float = usage / float(BUDGET_TEXTURE_BYTES) if BUDGET_TEXTURE_BYTES > 0 else 0.0
	var over: bool = usage > BUDGET_TEXTURE_BYTES
	var warning: bool = usage > BUDGET_WARNING_BYTES
	return {
		"usage_bytes": usage,
		"usage_mb": usage / 1048576.0,
		"budget_bytes": BUDGET_TEXTURE_BYTES,
		"budget_mb": BUDGET_TEXTURE_MB,
		"ratio": ratio,
		"over_budget": over,
		"warning": warning,
		"critical": usage > BUDGET_CRITICAL_BYTES,
	}

# ---------------------------------------------------------------------------
# Profiler WS10 integration — budget-aware sampling (<12 calls)
# ---------------------------------------------------------------------------
## Sample memory metrics. Cached per-frame so repeated calls cost 0 Performance queries.
## At most 4 Performance.get_monitor calls per cache refresh (under 12).
func sample() -> Dictionary:
	if _cached_frame == _frame_count and not _cached_sample.is_empty():
		return _cached_sample.duplicate()
	if _call_count_this_frame >= MAX_CALLS_PER_FRAME:
		if not _cached_sample.is_empty():
			return _cached_sample.duplicate()
		return _fallback_sample()
	_cached_sample = _do_sample()
	_cached_frame = _frame_count
	return _cached_sample.duplicate()

func _do_sample() -> Dictionary:
	# Prefer profiler if available — use its latest to avoid duplicate Performance calls
	if _profiler and not _profiler.get("latest") == null:
		var latest = _profiler.get("latest")
		if latest is Dictionary and not latest.is_empty():
			var tex_b: int = int(latest.get("texture_mem_bytes", 0))
			var vid_b: int = int(latest.get("video_mem_bytes", 0))
			# If profiler has valid data, use it (0 extra calls)
			if tex_b > 0 or vid_b > 0:
				var mb: float = tex_b / 1048576.0 if tex_b > 0 else vid_b / 1048576.0
				var eff: int = tex_b if tex_b > 0 else vid_b
				return {
					"texture_mem_bytes": tex_b,
					"texture_mem_mb": tex_b / 1048576.0,
					"video_mem_bytes": vid_b,
					"video_mem_mb": vid_b / 1048576.0,
					"ratio": eff / float(BUDGET_TEXTURE_BYTES) if BUDGET_TEXTURE_BYTES > 0 else 0.0,
					"budget_bytes": BUDGET_TEXTURE_BYTES,
					"budget_mb": BUDGET_TEXTURE_MB,
					"over_budget": eff > BUDGET_TEXTURE_BYTES,
					"warning": eff > BUDGET_WARNING_BYTES,
					"source": "profiler",
				}
	# Fallback: direct Performance queries — 4 calls
	var tex_bytes := int(_perf(Performance.RENDER_TEXTURE_MEM_USED))
	var vid_bytes := int(_perf(Performance.RENDER_VIDEO_MEM_USED))
	var static_bytes := int(_perf(Performance.MEMORY_STATIC))
	var obj_count := int(_perf(Performance.OBJECT_COUNT))
	var eff_bytes: int = tex_bytes if tex_bytes > 0 else vid_bytes
	var ratio: float = eff_bytes / float(BUDGET_TEXTURE_BYTES) if BUDGET_TEXTURE_BYTES > 0 else 0.0
	return {
		"texture_mem_bytes": tex_bytes,
		"texture_mem_mb": tex_bytes / 1048576.0,
		"video_mem_bytes": vid_bytes,
		"video_mem_mb": vid_bytes / 1048576.0,
		"static_mem_bytes": static_bytes,
		"static_mem_mb": static_bytes / 1048576.0,
		"object_count": obj_count,
		"ratio": ratio,
		"budget_bytes": BUDGET_TEXTURE_BYTES,
		"budget_mb": BUDGET_TEXTURE_MB,
		"over_budget": eff_bytes > BUDGET_TEXTURE_BYTES,
		"warning": eff_bytes > BUDGET_WARNING_BYTES,
		"source": "performance",
	}

func _fallback_sample() -> Dictionary:
	var eff: int = _last_texture_bytes if _last_texture_bytes > 0 else _last_video_bytes
	return {
		"texture_mem_bytes": _last_texture_bytes,
		"texture_mem_mb": _last_texture_mb,
		"video_mem_bytes": _last_video_bytes,
		"video_mem_mb": _last_video_bytes / 1048576.0,
		"ratio": _last_ratio,
		"budget_bytes": BUDGET_TEXTURE_BYTES,
		"budget_mb": BUDGET_TEXTURE_MB,
		"over_budget": eff > BUDGET_TEXTURE_BYTES,
		"warning": eff > BUDGET_WARNING_BYTES,
		"cached": true,
		"source": "fallback",
	}

## Single Performance monitor call with budget enforcement.
func _perf(monitor: int) -> float:
	if _call_count_this_frame >= MAX_CALLS_PER_FRAME:
		return 0.0
	_call_count_this_frame += 1
	_total_calls += 1
	return Performance.get_monitor(monitor)

## Check budgets via Profiler thresholds if available, else local.
func check_budgets() -> Array:
	var s := sample()
	var v: Array = []
	var eff: int = int(s.get("texture_mem_bytes", 0))
	if eff == 0:
		eff = int(s.get("video_mem_bytes", 0))
	if eff > BUDGET_TEXTURE_BYTES:
		v.append("texture_mem %.1fMB > %.0fMB" % [eff / 1048576.0, BUDGET_TEXTURE_MB])
	return v

# ---------------------------------------------------------------------------
# Budget enforcement actions — invoked by callbacks or directly
# ---------------------------------------------------------------------------
## Suggest texture quality reduction. Returns suggested scale 0.5..1.0.
func suggested_texture_scale() -> float:
	if is_critical_level():
		return 0.5
	if is_warning_level():
		return 0.75
	if is_near_budget():
		return 0.9
	return 1.0

## Attempt to free unused resources — call when low memory.
func trim_memory(level: int = 0) -> void:
	handle_low_memory(level)

# ---------------------------------------------------------------------------
# Debug / telemetry — 00-conventions.md §11
# ---------------------------------------------------------------------------
func debug_export() -> Dictionary:
	return {
		"budget_mb": BUDGET_TEXTURE_MB,
		"budget_bytes": BUDGET_TEXTURE_BYTES,
		"warning_bytes": BUDGET_WARNING_BYTES,
		"critical_bytes": BUDGET_CRITICAL_BYTES,
		"last_texture_bytes": _last_texture_bytes,
		"last_texture_mb": _last_texture_mb,
		"last_video_bytes": _last_video_bytes,
		"last_ratio": _last_ratio,
		"over_budget": is_over_budget(),
		"warning": is_warning_level(),
		"critical": is_critical_level(),
		"over_budget_count": _over_budget_count,
		"low_memory_count": _low_memory_count,
		"last_trim_level": _last_trim_level,
		"callback_count": _low_memory_callbacks.size(),
		"frame_count": _frame_count,
		"total_perf_calls": _total_calls,
		"initialized": _initialized,
		"has_profiler": _profiler != null,
	}

func perf_mark(label: String = "memory") -> Dictionary:
	var s := sample()
	var out := {
		"label": label,
		"texture_mb": s.get("texture_mem_mb", 0.0),
		"video_mb": s.get("video_mem_mb", 0.0),
		"ratio": s.get("ratio", 0.0),
		"over_budget": s.get("over_budget", false),
		"calls_this_frame": _call_count_this_frame,
		"total_calls": _total_calls,
		"frame_count": _frame_count,
	}
	if _profiler and _profiler.has_method("perf_mark"):
		_profiler.perf_mark("%s tex=%.1fMB ratio=%.2f" % [label, out["texture_mb"], out["ratio"]])
	return out

## Reset counters (e.g., after loading screen).
func reset_stats() -> void:
	_frame_count = 0
	_low_memory_count = 0
	_over_budget_count = 0
	_last_texture_bytes = 0
	_last_video_bytes = 0
	_last_texture_mb = 0.0
	_last_ratio = 0.0
	_total_calls = 0
	_call_count_this_frame = 0
	_cached_sample = {}
	_cached_frame = -1
	_last_trim_level = 0
	_handling_low_memory = false

func validate_config() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(BUDGET_TEXTURE_MB, 350.0):
		errors.append("BUDGET_TEXTURE_MB %.1f != 350.0" % BUDGET_TEXTURE_MB)
	if BUDGET_TEXTURE_BYTES != 367001600:
		errors.append("BUDGET_TEXTURE_BYTES %d != 367001600" % BUDGET_TEXTURE_BYTES)
	if BUDGET_WARNING_BYTES != int(BUDGET_TEXTURE_BYTES * BUDGET_WARNING_RATIO):
		errors.append("BUDGET_WARNING_BYTES mismatch")
	if BUDGET_CRITICAL_BYTES != int(BUDGET_TEXTURE_BYTES * BUDGET_CRITICAL_RATIO):
		errors.append("BUDGET_CRITICAL_BYTES mismatch")
	if MAX_CALLS_PER_FRAME >= 12:
		errors.append("MAX_CALLS_PER_FRAME %d must be <12" % MAX_CALLS_PER_FRAME)
	# budget.json cross-check
	var budget_path := "res://tools/perf/budget.json"
	if FileAccess.file_exists(budget_path):
		var f := FileAccess.open(budget_path, FileAccess.READ)
		if f != null:
			var json := JSON.new()
			if json.parse(f.get_as_text()) == OK:
				var data: Dictionary = json.data
				var b: Dictionary = data.get("budgets", {})
				var tex: Dictionary = b.get("texture_mem_mb", {})
				var max_mb: float = float(tex.get("max", 0))
				var bytes_max: int = int(tex.get("bytes_max", 0))
				if not is_equal_approx(max_mb, BUDGET_TEXTURE_MB):
					errors.append("budget.json texture max %.1f != %.1f" % [max_mb, BUDGET_TEXTURE_MB])
				if bytes_max != 0 and bytes_max != BUDGET_TEXTURE_BYTES:
					errors.append("budget.json bytes_max %d != %d" % [bytes_max, BUDGET_TEXTURE_BYTES])
	return {"ok": errors.is_empty(), "errors": errors}
