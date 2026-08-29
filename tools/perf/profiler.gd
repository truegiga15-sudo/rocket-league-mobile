## tools/perf/profiler.gd — WS10 Performance Budgets & Profiling Harness
## Autoload singleton (add to project.godot [autoload] Profiler="*res://tools/perf/profiler.gd")
## Logs frame time, physics time, draw calls, tris, memory via Performance singleton
## and writes CSV + human-readable lines to user://perf.log
## Exposes debug_export() and perf_mark() per docs/architecture/00-conventions.md §11
extends Node

# ── Budget thresholds (mirrors tools/perf/budget.json) ────────────────
const BUDGET_DRAW_CALLS := 120
const BUDGET_TRIS := 300000
const BUDGET_TEXTURE_MEM_MB := 350.0
const BUDGET_TEXTURE_MEM_BYTES := 367001600
const BUDGET_PHYSICS_MS := 4.0
const BUDGET_FRAME_MS := 16.6

const LOG_PATH := "user://perf.log"
const FLUSH_INTERVAL := 1.0
const CSV_HEADER := "timestamp,frame_ms,physics_ms,fps,draw_calls,tris,texture_mem_mb,video_mem_mb,static_mem_mb,over_budget"

var _elapsed := 0.0
var _frame_count := 0
var _log_file: FileAccess = null
var _over_budget_count := 0
var _last_sample := {}
var latest := {}

func _ready() -> void:
	_log_file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if _log_file == null:
		push_warning("[Profiler] cannot open %s: %s" % [LOG_PATH, FileAccess.get_open_error()])
		return
	_log_file.store_line("# perf.log — WS10 profiler — started %s" % Time.get_datetime_string_from_system())
	_log_file.store_line("# " + CSV_HEADER)
	_log_file.flush()
	print("[Profiler] logging to %s" % LOG_PATH)

func _exit_tree() -> void:
	if _log_file != null:
		_log_file.store_line("# stopped frames=%d over_budget=%d" % [_frame_count, _over_budget_count])
		_log_file.flush()
		_log_file = null

func _process(delta: float) -> void:
	_frame_count += 1
	_elapsed += delta
	var s := _sample(delta)
	latest = s
	var violations := _check_budgets(s)
	if not violations.is_empty():
		_over_budget_count += 1
		if fmod(_elapsed, 1.0) < delta * 1.5:
			push_warning("[Profiler] BUDGET EXCEEDED: %s | %s" % [",".join(violations), _format_sample(s)])
	if _log_file != null:
		_log_file.store_line(_to_csv(s, violations))
		if fmod(_elapsed, FLUSH_INTERVAL) < delta:
			_log_file.flush()
	_last_sample = s

func _physics_process(_delta: float) -> void:
	pass

func _sample(delta: float) -> Dictionary:
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var proc_s := Performance.get_monitor(Performance.TIME_PROCESS)
	var phys_s := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	var frame_ms := delta * 1000.0
	if proc_s > 0.0 or phys_s > 0.0:
		frame_ms = (proc_s + phys_s) * 1000.0
		if frame_ms < 0.01:
			frame_ms = delta * 1000.0
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var tris := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var tex_bytes := int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))
	var vid_bytes := int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	var static_bytes := int(Performance.get_monitor(Performance.MEMORY_STATIC))
	return {
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"frame_ms": frame_ms,
		"physics_ms": phys_s * 1000.0,
		"fps": fps,
		"draw_calls": draw_calls,
		"tris": tris,
		"texture_mem_bytes": tex_bytes,
		"texture_mem_mb": tex_bytes / 1048576.0,
		"video_mem_bytes": vid_bytes,
		"video_mem_mb": vid_bytes / 1048576.0,
		"static_mem_bytes": static_bytes,
		"static_mem_mb": static_bytes / 1048576.0,
		"delta": delta,
	}

func _check_budgets(s: Dictionary) -> Array:
	var v: Array = []
	if s["draw_calls"] > BUDGET_DRAW_CALLS:
		v.append("draw_calls %d > %d" % [s["draw_calls"], BUDGET_DRAW_CALLS])
	if s["tris"] > BUDGET_TRIS:
		v.append("tris %d > %d" % [s["tris"], BUDGET_TRIS])
	var mem_bytes: int = s["texture_mem_bytes"] if s["texture_mem_bytes"] > 0 else s["video_mem_bytes"]
	var mem_mb: float = mem_bytes / 1048576.0
	if mem_bytes > BUDGET_TEXTURE_MEM_BYTES:
		v.append("texture_mem %.1fMB > %.0fMB" % [mem_mb, BUDGET_TEXTURE_MEM_MB])
	if s["physics_ms"] > BUDGET_PHYSICS_MS:
		v.append("physics %.2fms > %.1fms" % [s["physics_ms"], BUDGET_PHYSICS_MS])
	if s["frame_ms"] > BUDGET_FRAME_MS:
		v.append("frame %.2fms > %.1fms" % [s["frame_ms"], BUDGET_FRAME_MS])
	return v

func _to_csv(s: Dictionary, violations: Array) -> String:
	var over := ";".join(violations) if not violations.is_empty() else ""
	return "%0.3f,%0.3f,%0.3f,%0.1f,%d,%d,%0.2f,%0.2f,%0.2f,\"%s\"" % [
		s["timestamp"], s["frame_ms"], s["physics_ms"], s["fps"],
		s["draw_calls"], s["tris"], s["texture_mem_mb"], s["video_mem_mb"],
		s["static_mem_mb"], over
	]

func _format_sample(s: Dictionary) -> String:
	return "frame=%.2fms phys=%.2fms fps=%.0f dc=%d tris=%d tex=%.1fMB vid=%.1fMB" % [
		s["frame_ms"], s["physics_ms"], s["fps"], s["draw_calls"], s["tris"],
		s["texture_mem_mb"], s["video_mem_mb"]
	]

func perf_mark(label: String) -> Dictionary:
	var s := _sample(get_process_delta_time())
	s["label"] = label
	if _log_file != null:
		_log_file.store_line("# MARK %s %s" % [label, _format_sample(s)])
		_log_file.flush()
	return s

func debug_export() -> Dictionary:
	return {
		"latest": latest.duplicate() if not latest.is_empty() else _sample(get_process_delta_time()),
		"budgets": {
			"draw_calls": BUDGET_DRAW_CALLS,
			"tris": BUDGET_TRIS,
			"texture_mem_mb": BUDGET_TEXTURE_MEM_MB,
			"physics_ms": BUDGET_PHYSICS_MS,
			"frame_ms": BUDGET_FRAME_MS,
		},
		"over_budget_count": _over_budget_count,
		"frame_count": _frame_count,
		"log_path": LOG_PATH,
	}

func check_budgets_now() -> Array:
	var s := _sample(get_process_delta_time())
	return _check_budgets(s)

func check_budgets_from_file(budget_path: String = "res://tools/perf/budget.json") -> Dictionary:
	var result := {"violations": [], "sample": {}, "budgets": {}}
	if not FileAccess.file_exists(budget_path):
		result["violations"].append("budget file missing: %s" % budget_path)
		return result
	var f := FileAccess.open(budget_path, FileAccess.READ)
	var json := JSON.new()
	var err := json.parse(f.get_as_text())
	if err != OK:
		result["violations"].append("budget.json parse error: %s" % json.get_error_message())
		return result
	var data: Dictionary = json.data
	result["budgets"] = data.get("budgets", {})
	var s := _sample(get_process_delta_time())
	result["sample"] = s
	if s["draw_calls"] > int(result["budgets"].get("draw_calls", {}).get("max", BUDGET_DRAW_CALLS)):
		result["violations"].append("draw_calls %d > %d" % [s["draw_calls"], BUDGET_DRAW_CALLS])
	if s["tris"] > int(result["budgets"].get("tris", {}).get("max", BUDGET_TRIS)):
		result["violations"].append("tris %d > %d" % [s["tris"], BUDGET_TRIS])
	var tex_max: int = int(result["budgets"].get("texture_mem_mb", {}).get("bytes_max", BUDGET_TEXTURE_MEM_BYTES))
	if tex_max == 0:
		tex_max = int(result["budgets"].get("texture_mem_mb", {}).get("max", BUDGET_TEXTURE_MEM_MB)) * 1048576
	var mem_bytes: int = s["texture_mem_bytes"] if s["texture_mem_bytes"] > 0 else s["video_mem_bytes"]
	if mem_bytes > tex_max:
		result["violations"].append("texture_mem %d > %d" % [mem_bytes, tex_max])
	var phys_max: float = float(result["budgets"].get("physics_ms", {}).get("max", BUDGET_PHYSICS_MS))
	if s["physics_ms"] > phys_max:
		result["violations"].append("physics %.2fms > %.1fms" % [s["physics_ms"], phys_max])
	var frame_max: float = float(result["budgets"].get("frame_ms", {}).get("max", BUDGET_FRAME_MS))
	if s["frame_ms"] > frame_max:
		result["violations"].append("frame %.2fms > %.1fms" % [s["frame_ms"], frame_max])
	return result
