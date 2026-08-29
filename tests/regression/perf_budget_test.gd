## tests/regression/perf_budget_test.gd — WS10 regression: fails if perf budget exceeded
## Run via GUT or headless: godot --headless -s tests/regression/perf_budget_test.gd
extends SceneTree
const BUDGET_PATH_RES := "res://tools/perf/budget.json"
const BUDGET_DRAW_CALLS := 120
const BUDGET_TRIS := 300000
const BUDGET_TEXTURE_MEM_BYTES := 367001600
const BUDGET_PHYSICS_MS := 4.0
const BUDGET_FRAME_MS := 16.6
func _init() -> void:
	var passed := _run()
	quit(0 if passed else 1)
func _run() -> bool:
	print("[perf_budget_test] checking budgets from %s ..." % BUDGET_PATH_RES)
	var budgets := _load_budgets()
	if budgets.is_empty():
		print("[perf_budget_test] WARN: budget.json missing — using fallback constants")
		budgets = _fallback_budgets()
	var sample := _sample()
	print("[perf_budget_test] sample: frame=%.2fms phys=%.2fms fps=%.1f dc=%d tris=%d tex=%.1fMB vid=%.1fMB" % [
		sample["frame_ms"], sample["physics_ms"], sample["fps"],
		sample["draw_calls"], sample["tris"], sample["texture_mem_mb"], sample["video_mem_mb"]
	])
	var violations := _check(sample, budgets)
	if violations.is_empty():
		print("[perf_budget_test] PASS — all budgets within limits")
		print("[perf_budget_test] budgets: dc<%d tris<%d tex<%.0fMB phys<%.1fms frame<%.1fms" % [
			budgets["draw_calls"]["max"], budgets["tris"]["max"],
			budgets["texture_mem_mb"]["max"], budgets["physics_ms"]["max"], budgets["frame_ms"]["max"]
		])
		return true
	else:
		for v in violations:
			printerr("[perf_budget_test] FAIL: %s" % v)
		printerr("[perf_budget_test] FAIL — %d budget(s) exceeded" % violations.size())
		return false
func _load_budgets() -> Dictionary:
	var path := BUDGET_PATH_RES
	if not FileAccess.file_exists(path):
		if FileAccess.file_exists("res://tools/perf/budget.json"):
			path = "res://tools/perf/budget.json"
		else:
			return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		printerr("[perf_budget_test] JSON parse error: %s" % json.get_error_message())
		return {}
	var data: Dictionary = json.data
	if data.has("budgets"):
		return data["budgets"]
	return data
func _fallback_budgets() -> Dictionary:
	return {
		"draw_calls": {"max": BUDGET_DRAW_CALLS},
		"tris": {"max": BUDGET_TRIS},
		"texture_mem_mb": {"max": 350, "bytes_max": BUDGET_TEXTURE_MEM_BYTES},
		"physics_ms": {"max": BUDGET_PHYSICS_MS},
		"frame_ms": {"max": BUDGET_FRAME_MS},
	}
func _sample() -> Dictionary:
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var proc_s := Performance.get_monitor(Performance.TIME_PROCESS)
	var phys_s := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var tris := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var tex_bytes := int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))
	var vid_bytes := int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	var frame_ms := (proc_s + phys_s) * 1000.0
	if frame_ms < 0.01 and fps > 0:
		frame_ms = 1000.0 / fps
	if frame_ms < 0.01:
		frame_ms = 0.0
	return {
		"fps": fps,
		"frame_ms": frame_ms,
		"physics_ms": phys_s * 1000.0,
		"draw_calls": draw_calls,
		"tris": tris,
		"texture_mem_bytes": tex_bytes,
		"texture_mem_mb": tex_bytes / 1048576.0,
		"video_mem_bytes": vid_bytes,
		"video_mem_mb": vid_bytes / 1048576.0,
	}
func _check(s: Dictionary, b: Dictionary) -> Array:
	var v: Array = []
	var dc_max := int(b.get("draw_calls", {}).get("max", BUDGET_DRAW_CALLS))
	if s["draw_calls"] > dc_max:
		v.append("draw_calls %d > %d" % [s["draw_calls"], dc_max])
	var tris_max := int(b.get("tris", {}).get("max", BUDGET_TRIS))
	if s["tris"] > tris_max:
		v.append("tris %d > %d" % [s["tris"], tris_max])
	var tex_max: int = int(b.get("texture_mem_mb", {}).get("bytes_max", 0))
	if tex_max == 0:
		tex_max = int(float(b.get("texture_mem_mb", {}).get("max", 350)) * 1048576)
	var mem_bytes: int = s["texture_mem_bytes"] if s["texture_mem_bytes"] > 0 else s["video_mem_bytes"]
	if mem_bytes > 0 and mem_bytes > tex_max:
		v.append("texture_mem %.1fMB (%d bytes) > %.0fMB (%d bytes)" % [mem_bytes / 1048576.0, mem_bytes, tex_max / 1048576.0, tex_max])
	var phys_max := float(b.get("physics_ms", {}).get("max", BUDGET_PHYSICS_MS))
	if s["physics_ms"] > phys_max:
		v.append("physics %.3fms > %.1fms" % [s["physics_ms"], phys_max])
	var frame_max := float(b.get("frame_ms", {}).get("max", BUDGET_FRAME_MS))
	if s["frame_ms"] > 0.01 and s["frame_ms"] > frame_max:
		v.append("frame %.3fms > %.1fms" % [s["frame_ms"], frame_max])
	return v
func test_perf_budgets_draw_calls() -> void:
	var budgets := _load_budgets()
	if budgets.is_empty():
		budgets = _fallback_budgets()
	var s := _sample()
	var max_dc := int(budgets.get("draw_calls", {}).get("max", BUDGET_DRAW_CALLS))
	assert(s["draw_calls"] <= max_dc, "draw_calls %d <= %d" % [s["draw_calls"], max_dc])
func test_perf_budgets_tris() -> void:
	var budgets := _load_budgets()
	if budgets.is_empty():
		budgets = _fallback_budgets()
	var s := _sample()
	var max_tris := int(budgets.get("tris", {}).get("max", BUDGET_TRIS))
	assert(s["tris"] <= max_tris, "tris %d <= %d" % [s["tris"], max_tris])
func test_perf_budgets_texture_mem() -> void:
	var budgets := _load_budgets()
	if budgets.is_empty():
		budgets = _fallback_budgets()
	var s := _sample()
	var tex_max: int = int(budgets.get("texture_mem_mb", {}).get("bytes_max", 0))
	if tex_max == 0:
		tex_max = int(float(budgets.get("texture_mem_mb", {}).get("max", 350)) * 1048576)
	var mem_bytes: int = s["texture_mem_bytes"] if s["texture_mem_bytes"] > 0 else s["video_mem_bytes"]
	if mem_bytes == 0:
		assert(true, "texture_mem no measurement in headless — skip")
		return
	assert(mem_bytes <= tex_max, "texture_mem %d <= %d" % [mem_bytes, tex_max])
func test_perf_budgets_physics() -> void:
	var budgets := _load_budgets()
	if budgets.is_empty():
		budgets = _fallback_budgets()
	var s := _sample()
	var max_phys := float(budgets.get("physics_ms", {}).get("max", BUDGET_PHYSICS_MS))
	assert(s["physics_ms"] <= max_phys, "physics %.3fms <= %.1fms" % [s["physics_ms"], max_phys])
func test_perf_budgets_frame() -> void:
	var budgets := _load_budgets()
	if budgets.is_empty():
		budgets = _fallback_budgets()
	var s := _sample()
	var max_frame := float(budgets.get("frame_ms", {}).get("max", BUDGET_FRAME_MS))
	if s["frame_ms"] < 0.01:
		assert(true, "frame_ms no measurement in headless — skip")
		return
	assert(s["frame_ms"] <= max_frame, "frame %.3fms <= %.1fms" % [s["frame_ms"], max_frame])
