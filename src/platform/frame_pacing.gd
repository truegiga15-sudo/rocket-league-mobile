# FramePacingService — WS86 Frame Pacing & 60fps Lock
# 60fps vsync lock, 16.6ms frame budget, TimeService 120Hz integration (2 ticks/frame),
# WS10 profiler-aware. Budget-aware: <12 Performance calls per frame via caching.
# Godot 4.x — depends on TimeService (WS05), Profiler (WS10), ConfigService (WS08).
# Conventions: docs/architecture/00-conventions.md §3 (120Hz), §12 (budgets)
extends Node
class_name FramePacingService

# ---------------------------------------------------------------------------
# Constants — 60fps lock, TimeService 120Hz
# ---------------------------------------------------------------------------
const TARGET_FPS: int = 60
const TARGET_FRAME_TIME_S: float = 1.0 / 60.0
const TARGET_FRAME_TIME_MS: float = 16.666666
const BUDGET_FRAME_MS: float = 16.6
const BUDGET_PHYSICS_MS: float = 4.0
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICKS_PER_RENDER_FRAME: int = 2  # 120 / 60 = 2 physics ticks per 60fps frame
const HITCH_THRESHOLD_MS: float = 33.3  # 2x frame budget = hitch
const MAX_CALLS_PER_FRAME: int = 11  # stay under 12

# Vsync modes — mirrors DisplayServer.VSyncMode for testability
enum VSyncMode { DISABLED = 0, ENABLED = 1, ADAPTIVE = 2, MAILBOX = 3 }

# ---------------------------------------------------------------------------
# Dependencies — resolved in _ready(), optional (graceful without)
# ---------------------------------------------------------------------------
var _time_service: Node = null
var _profiler: Node = null
var _config_service: Node = null

# ---------------------------------------------------------------------------
# State — no per-frame allocation
# ---------------------------------------------------------------------------
var _vsync_enabled: bool = true
var _target_fps: int = TARGET_FPS
var _frame_count: int = 0
var _hitch_count: int = 0
var _over_budget_count: int = 0
var _call_count_this_frame: int = 0
var _total_calls: int = 0
var _last_frame_ms: float = 0.0
var _smoothed_frame_ms: float = TARGET_FRAME_TIME_MS
var _min_frame_ms: float = 999.0
var _max_frame_ms: float = 0.0
var _last_fps: float = 60.0
var _initialized: bool = false

# Cached sample — refreshed once per frame to keep calls <12
var _cached_sample: Dictionary = {}
var _cached_frame: int = -1

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal frame_budget_exceeded(frame_ms: float, budget_ms: float)
signal hitch_detected(frame_ms: float)
signal vsync_changed(enabled: bool)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_resolve_dependencies()
	apply_60fps_lock()
	_initialized = true

func _resolve_dependencies() -> void:
	_time_service = get_node_or_null("/root/TimeService")
	if _time_service == null:
		_time_service = get_node_or_null("/root/TimeServiceClass")
	_profiler = get_node_or_null("/root/Profiler")
	_config_service = get_node_or_null("/root/ConfigService")

func _process(delta: float) -> void:
	# Reset per-frame call budget
	_call_count_this_frame = 0
	_frame_count += 1

	# Use delta for frame timing (one delta read = 0 calls)
	var frame_ms := delta * 1000.0
	_last_frame_ms = frame_ms

	# Smoothed (exponential moving average, alpha=0.1)
	_smoothed_frame_ms = _smoothed_frame_ms * 0.9 + frame_ms * 0.1

	if frame_ms < _min_frame_ms:
		_min_frame_ms = frame_ms
	if frame_ms > _max_frame_ms:
		_max_frame_ms = frame_ms

	# Over-budget & hitch detection — no extra Performance calls, uses delta only
	if frame_ms > BUDGET_FRAME_MS:
		_over_budget_count += 1
		frame_budget_exceeded.emit(frame_ms, BUDGET_FRAME_MS)
	if frame_ms > HITCH_THRESHOLD_MS:
		_hitch_count += 1
		hitch_detected.emit(frame_ms)

# ---------------------------------------------------------------------------
# Public API — 60fps lock / vsync
# ---------------------------------------------------------------------------
## Apply 60fps vsync lock: DisplayServer vsync + Engine.max_fps.
## Idempotent, safe on headless, <3 calls.
func apply_60fps_lock() -> void:
	_apply_vsync(true)
	_apply_fps_limit(TARGET_FPS)

## Enable or disable vsync. Updates DisplayServer and emits signal.
func set_vsync_enabled(enabled: bool) -> void:
	if _vsync_enabled == enabled:
		return
	_apply_vsync(enabled)
	vsync_changed.emit(enabled)

func is_vsync_enabled() -> bool:
	return _vsync_enabled

func get_target_fps() -> int:
	return _target_fps

func get_target_frame_time_ms() -> float:
	return TARGET_FRAME_TIME_MS

func get_target_frame_time_s() -> float:
	return TARGET_FRAME_TIME_S

func get_ticks_per_frame() -> int:
	return TICKS_PER_RENDER_FRAME

func _apply_vsync(enabled: bool) -> void:
	_vsync_enabled = enabled
	# Guard: headless / unsupported
	if DisplayServer.get_name() == "headless":
		return
	# Single DisplayServer call
	var mode: int = DisplayServer.VSYNC_ENABLED if enabled else DisplayServer.VSYNC_DISABLED
	DisplayServer.window_set_vsync_mode(mode)

func _apply_fps_limit(fps: int) -> void:
	_target_fps = fps
	Engine.max_fps = fps

## Set target FPS. Clamped to allowed values. 0 = unlimited (vsync only).
func set_target_fps(fps: int) -> void:
	var clamped := _clamp_fps(fps)
	if clamped == _target_fps:
		return
	_apply_fps_limit(clamped)
	# Re-apply vsync to keep consistent state
	_apply_vsync(_vsync_enabled)

func _clamp_fps(fps: int) -> int:
	if fps == 0:
		return 0
	var allowed: Array[int] = [30, 60, 90, 120, 144]
	var best := TARGET_FPS
	var best_d := abs(fps - best)
	for a in allowed:
		var d := abs(fps - a)
		if d < best_d:
			best_d = d
			best = a
	return best

# ---------------------------------------------------------------------------
# Frame timing — budget-aware accessors
# ---------------------------------------------------------------------------
func get_last_frame_ms() -> float:
	return _last_frame_ms

func get_smoothed_frame_ms() -> float:
	return _smoothed_frame_ms

func get_last_fps() -> float:
	# Derived from smoothed ms — no Performance call
	if _smoothed_frame_ms > 0.01:
		return 1000.0 / _smoothed_frame_ms
	return _last_fps

func is_over_budget() -> bool:
	return _last_frame_ms > BUDGET_FRAME_MS

func is_hitching() -> bool:
	return _last_frame_ms > HITCH_THRESHOLD_MS

func get_frame_count() -> int:
	return _frame_count

func get_hitch_count() -> int:
	return _hitch_count

func get_over_budget_count() -> int:
	return _over_budget_count

func get_min_frame_ms() -> float:
	return _min_frame_ms if _frame_count > 0 else 0.0

func get_max_frame_ms() -> float:
	return _max_frame_ms

# ---------------------------------------------------------------------------
# TimeService 120Hz integration
# ---------------------------------------------------------------------------
## Returns physics alpha for interpolation (0..1). Uses TimeService if available.
func get_physics_alpha() -> float:
	if _time_service and _time_service.has_method("get_alpha"):
		return _time_service.get_alpha()
	return 0.0

## Expected physics ticks for the last frame's delta (normally 2 at 60fps).
func ticks_for_last_frame() -> int:
	if _time_service and _time_service.has_method("ticks_for_delta"):
		return _time_service.ticks_for_delta(_last_frame_ms / 1000.0)
	# Fallback: derive from frame_ms
	return int(floor((_last_frame_ms / 1000.0) / PHYSICS_TICK_DELTA))

## Validate vsync + TimeService + budget alignment.
func validate_config() -> Dictionary:
	var errors: Array[String] = []
	if _target_fps != TARGET_FPS and _target_fps != 0:
		errors.append("target_fps %d != %d (60fps lock)" % [_target_fps, TARGET_FPS])
	if not is_equal_approx(TARGET_FRAME_TIME_S, 1.0 / 60.0):
		errors.append("TARGET_FRAME_TIME_S != 1/60")
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA != 1/120")
	if TICKS_PER_RENDER_FRAME != PHYSICS_TICKS_PER_SECOND / TARGET_FPS:
		errors.append("TICKS_PER_RENDER_FRAME != 120/60")
	if not is_equal_approx(BUDGET_FRAME_MS, 16.6):
		errors.append("BUDGET_FRAME_MS != 16.6")
	if Engine.max_fps != 0 and Engine.max_fps != _target_fps:
		errors.append("Engine.max_fps %d != target %d" % [Engine.max_fps, _target_fps])
	# TimeService check
	if _time_service == null:
		errors.append("TimeService not found (/root/TimeService)")
	elif _time_service.has_method("validate_config"):
		var r: Dictionary = _time_service.validate_config()
		if not bool(r.get("ok", true)):
			errors.append("TimeService validate failed: %s" % str(r.get("errors", [])))
	# ProjectSettings physics tick must be 120
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != PHYSICS_TICKS_PER_SECOND:
		errors.append("project.godot physics_ticks_per_second=%d != %d" % [ps_rate, PHYSICS_TICKS_PER_SECOND])
	return {"ok": errors.is_empty(), "errors": errors}

# ---------------------------------------------------------------------------
# Profiler WS10 integration — budget-aware sampling (<12 calls)
# ---------------------------------------------------------------------------
## Sample frame metrics. Cached per-frame so repeated calls cost 0 Performance queries.
## At most 7 Performance.get_monitor calls per cache refresh (under 12).
func sample() -> Dictionary:
	# Return cached if same frame
	if _cached_frame == _frame_count and not _cached_sample.is_empty():
		return _cached_sample.duplicate()
	if _call_count_this_frame >= MAX_CALLS_PER_FRAME:
		# Budget exhausted — return cached or delta-derived fallback
		if not _cached_sample.is_empty():
			return _cached_sample.duplicate()
		return _fallback_sample()
	_cached_sample = _do_sample()
	_cached_frame = _frame_count
	return _cached_sample.duplicate()

func _do_sample() -> Dictionary:
	# 7 calls total — under 12 budget
	var fps := _perf(Performance.TIME_FPS)
	var proc_s := _perf(Performance.TIME_PROCESS)
	var phys_s := _perf(Performance.TIME_PHYSICS_PROCESS)
	var draw_calls := int(_perf(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var tris := int(_perf(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var tex_bytes := int(_perf(Performance.RENDER_TEXTURE_MEM_USED))
	var vid_bytes := int(_perf(Performance.RENDER_VIDEO_MEM_USED))

	var frame_ms := _last_frame_ms
	# Prefer Performance composite if available and sane
	if proc_s > 0.0 or phys_s > 0.0:
		var composite_ms := (proc_s + phys_s) * 1000.0
		if composite_ms >= 0.5 and composite_ms < 200.0:
			frame_ms = composite_ms
	elif fps > 1.0:
		var fps_ms := 1000.0 / fps
		if fps_ms > 0.5 and fps_ms < 200.0 and frame_ms < 0.5:
			frame_ms = fps_ms

	_last_fps = fps if fps > 0 else _last_fps

	return {
		"frame_ms": frame_ms,
		"physics_ms": phys_s * 1000.0,
		"fps": fps,
		"draw_calls": draw_calls,
		"tris": tris,
		"texture_mem_bytes": tex_bytes,
		"video_mem_bytes": vid_bytes,
		"target_frame_ms": TARGET_FRAME_TIME_MS,
		"budget_frame_ms": BUDGET_FRAME_MS,
		"over_budget": frame_ms > BUDGET_FRAME_MS,
		"smoothed_ms": _smoothed_frame_ms,
		"vsync": _vsync_enabled,
		"target_fps": _target_fps,
	}

func _fallback_sample() -> Dictionary:
	return {
		"frame_ms": _last_frame_ms,
		"physics_ms": 0.0,
		"fps": get_last_fps(),
		"draw_calls": 0,
		"tris": 0,
		"texture_mem_bytes": 0,
		"video_mem_bytes": 0,
		"target_frame_ms": TARGET_FRAME_TIME_MS,
		"budget_frame_ms": BUDGET_FRAME_MS,
		"over_budget": is_over_budget(),
		"smoothed_ms": _smoothed_frame_ms,
		"vsync": _vsync_enabled,
		"target_fps": _target_fps,
		"cached": true,
	}

## Single Performance monitor call with budget enforcement.
func _perf(monitor: int) -> float:
	if _call_count_this_frame >= MAX_CALLS_PER_FRAME:
		return 0.0
	_call_count_this_frame += 1
	_total_calls += 1
	return Performance.get_monitor(monitor)

## Check budgets now using WS10 thresholds (no extra calls if sample cached).
func check_budgets() -> Array:
	var s := sample()
	var v: Array = []
	if s["frame_ms"] > BUDGET_FRAME_MS:
		v.append("frame %.2fms > %.1fms" % [s["frame_ms"], BUDGET_FRAME_MS])
	if s["physics_ms"] > BUDGET_PHYSICS_MS:
		v.append("physics %.2fms > %.1fms" % [s["physics_ms"], BUDGET_PHYSICS_MS])
	return v

# ---------------------------------------------------------------------------
# Debug / telemetry — 00-conventions.md §11
# ---------------------------------------------------------------------------
func debug_export() -> Dictionary:
	return {
		"target_fps": TARGET_FPS,
		"target_frame_ms": TARGET_FRAME_TIME_MS,
		"budget_frame_ms": BUDGET_FRAME_MS,
		"budget_physics_ms": BUDGET_PHYSICS_MS,
		"ticks_per_frame": TICKS_PER_RENDER_FRAME,
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"vsync_enabled": _vsync_enabled,
		"engine_max_fps": Engine.max_fps,
		"frame_count": _frame_count,
		"hitch_count": _hitch_count,
		"over_budget_count": _over_budget_count,
		"last_frame_ms": _last_frame_ms,
		"smoothed_ms": _smoothed_frame_ms,
		"min_ms": get_min_frame_ms(),
		"max_ms": _max_frame_ms,
		"last_fps": get_last_fps(),
		"physics_alpha": get_physics_alpha(),
		"total_perf_calls": _total_calls,
		"initialized": _initialized,
	}

func perf_mark() -> Dictionary:
	var s := sample()
	return {
		"frame_ms": s["frame_ms"],
		"physics_ms": s["physics_ms"],
		"fps": s["fps"],
		"over_budget": s["over_budget"],
		"hitch": s["frame_ms"] > HITCH_THRESHOLD_MS,
		"calls_this_frame": _call_count_this_frame,
		"total_calls": _total_calls,
		"frame_count": _frame_count,
	}

## Reset counters (e.g., after loading screen).
func reset_stats() -> void:
	_frame_count = 0
	_hitch_count = 0
	_over_budget_count = 0
	_min_frame_ms = 999.0
	_max_frame_ms = 0.0
	_smoothed_frame_ms = TARGET_FRAME_TIME_MS
	_total_calls = 0
	_call_count_this_frame = 0
	_cached_sample = {}
	_cached_frame = -1
