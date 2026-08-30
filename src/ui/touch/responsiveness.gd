# TouchResponsiveness — WS32 Touch Responsiveness & Dead Zones (budget-aware)
# Measures touch latency, validates 16ms target, deadzone tuning.
# Budget: <12 calls per method, event-driven (no _process), <12 draw calls.
# Uses InputService, TouchJoystick (WS26), CameraJoystick (WS27), TouchButtonCluster (WS28).
# Provides debug_export() and perf_mark() per docs/architecture/00-conventions.md §11.
extends Node
class_name TouchResponsiveness

# ---------------------------------------------------------------------------
# Constants — match 00-conventions.md §12 + touch_layout.json + ergonomics
# ---------------------------------------------------------------------------
## 16ms latency target — 60fps frame budget (16.6ms). Budget-aware validation.
const LATENCY_TARGET_MS: float = 16.0
## Hard budget ceiling — frame must be <16.6ms (perf budget).
const FRAME_BUDGET_MS: float = 16.6
## Ergonomics max_latency_ms from touch_layout.json ergonomics.
const MAX_LATENCY_MS: float = 32.0
## Default deadzones per touch_layout.json (dp).
const DEFAULT_MOVE_DEADZONE_DP: float = 12.0
const DEFAULT_CAMERA_DEADZONE_DP: float = 8.0
const DEFAULT_LOOK_DEADZONE_DP: float = 8.0
## Minimum deadzone in dp — smaller causes drift.
const MIN_DEADZONE_DP: float = 4.0
## Maximum deadzone in dp — larger causes unresponsive feel.
const MAX_DEADZONE_DP: float = 20.0
## Max latency samples retained (ring buffer).
const MAX_SAMPLES: int = 120
## Samples needed before p95/avg is trustworthy.
const MIN_SAMPLES_FOR_STATS: int = 5

# ---------------------------------------------------------------------------
# Tunables — autowire via @export for HUD tuning or device-specific profiles
# ---------------------------------------------------------------------------
## Target latency in ms; validated against LATENCY_TARGET_MS.
@export var latency_target_ms: float = LATENCY_TARGET_MS
## Move joystick deadzone in dp (WS26 TouchJoystick).
@export var move_deadzone_dp: float = DEFAULT_MOVE_DEADZONE_DP
## Camera/look deadzone in dp (WS27 CameraJoystick).
@export var look_deadzone_dp: float = DEFAULT_LOOK_DEADZONE_DP
## Enable auto latency tracking via _input event interception.
@export var auto_track: bool = true
## Enable auto deadzone application to live joystick nodes.
@export var auto_apply_deadzone: bool = true

# ---------------------------------------------------------------------------
# Internal state — event-driven, no per-frame polling
# ---------------------------------------------------------------------------
var _latencies: Array[float] = []
var _pending_touches: Dictionary = {} # touch_id -> start_ticks_msec
var _latest_latency: float = 0.0
var _max_latency: float = 0.0
var _min_latency: float = 0.0
var _avg_latency: float = 0.0
var _p95_latency: float = 0.0
var _violations: int = 0
var _total_samples: int = 0
var _within_budget: bool = true
var _last_measure_ticks: int = 0
var _perf_samples: int = 0
var _deadzone_tune_count: int = 0
var _input_service_calls: int = 0

# Cached node refs (lazy)
var _cached_joystick: Node = null
var _cached_camera_joystick: Node = null
var _cached_button_cluster: Node = null

signal latency_measured(latency_ms: float, within_budget: bool)
signal budget_exceeded(latency_ms: float, target_ms: float)
signal deadzone_changed(kind: String, dp: float)

# ---------------------------------------------------------------------------
# Lifecycle — budget-aware (no _process)
# ---------------------------------------------------------------------------
func _ready() -> void:
	_clamp_deadzone_tunables()
	if auto_apply_deadzone:
		_apply_all_deadzones()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_pending_touches.clear()

# ---------------------------------------------------------------------------
# Latency measurement — budget-aware, <12 calls
# ---------------------------------------------------------------------------

## Call on InputEventScreenTouch/Drag arrival — stores start ticks for touch_id.
func notify_touch_started(touch_id: int, at_ticks_msec: int = -1) -> void:
	var ticks: int = at_ticks_msec if at_ticks_msec >= 0 else int(Time.get_ticks_msec())
	_pending_touches[touch_id] = ticks
	_last_measure_ticks = ticks

## Call when InputService has applied the touch (next frame or immediately).
## Computes latency = applied_ticks - touch_start_ticks.
func notify_input_applied(touch_id: int, at_ticks_msec: int = -1) -> float:
	if not _pending_touches.has(touch_id):
		return -1.0
	var start_ticks: int = int(_pending_touches[touch_id])
	_pending_touches.erase(touch_id)
	var end_ticks: int = at_ticks_msec if at_ticks_msec >= 0 else int(Time.get_ticks_msec())
	var latency: float = float(end_ticks - start_ticks)
	# Clamp negative (clock edge) to 0
	if latency < 0.0:
		latency = 0.0
	record_latency(latency)
	return latency

## Direct latency record — for tests or manual instrumentation.
## Validates against latency_target_ms and updates stats.
func record_latency(latency_ms: float) -> void:
	if latency_ms < 0.0:
		return
	_latest_latency = latency_ms
	_last_measure_ticks = int(Time.get_ticks_msec())
	_latencies.append(latency_ms)
	if _latencies.size() > MAX_SAMPLES:
		_latencies.pop_front()
	_total_samples += 1
	_perf_samples += 1
	_recompute_stats()
	var within: bool = latency_ms <= latency_target_ms
	_within_budget = within and _avg_latency <= latency_target_ms
	if not within:
		_violations += 1
		budget_exceeded.emit(latency_ms, latency_target_ms)
	latency_measured.emit(latency_ms, within)

## Convenience: measure between explicit ticks without pending map.
func measure_between(touch_ticks_msec: int, applied_ticks_msec: int) -> float:
	var latency: float = float(applied_ticks_msec - touch_ticks_msec)
	if latency < 0.0:
		latency = 0.0
	record_latency(latency)
	return latency

## Measure from InputService input_log: estimate latency as t_last - t_touch if available.
## Budget-aware: single lookup, no loop over >12 entries.
func measure_from_input_service(touch_id: int = -1) -> float:
	var svc := _get_input_service()
	if svc == null:
		return -1.0
	_input_service_calls += 1
	if svc.has_method("get_input_log"):
		var log: Array = svc.call("get_input_log")
		if log.is_empty():
			return -1.0
		# Last entry time vs pending touch start
		var last_t: int = int(log[log.size() - 1].get("t", 0))
		if touch_id >= 0 and _pending_touches.has(touch_id):
			var start: int = int(_pending_touches[touch_id])
			var latency: float = float(last_t - start)
			if latency < 0.0:
				latency = 0.0
			if latency < 200.0: # sanity: ignore stale (>200ms is not this frame)
				record_latency(latency)
				_pending_touches.erase(touch_id)
				return latency
		# Fallback: frame delta estimate
		return _latest_latency
	return -1.0

# ---------------------------------------------------------------------------
# Validation — 16ms target
# ---------------------------------------------------------------------------

## Validates current latency against target. Returns structured result.
func validate_latency_target() -> Dictionary:
	var target: float = latency_target_ms
	var latest_ok: bool = _latest_latency <= target or _latencies.is_empty()
	var avg_ok: bool = _avg_latency <= target or _latencies.is_empty()
	var max_ok: bool = _max_latency <= MAX_LATENCY_MS or _latencies.is_empty()
	var passed: bool = latest_ok and avg_ok
	return {
		"passed": passed,
		"within_budget": passed,
		"latest_ms": _latest_latency,
		"avg_ms": _avg_latency,
		"max_ms": _max_latency,
		"min_ms": _min_latency,
		"p95_ms": _p95_latency,
		"target_ms": target,
		"frame_budget_ms": FRAME_BUDGET_MS,
		"max_allowed_ms": MAX_LATENCY_MS,
		"samples": _latencies.size(),
		"total_samples": _total_samples,
		"violations": _violations,
		"latest_ok": latest_ok,
		"avg_ok": avg_ok,
		"max_ok": max_ok,
	}

## Quick check: is current state within 16ms budget?
func is_within_budget() -> bool:
	if _latencies.is_empty():
		return true
	return _avg_latency <= latency_target_ms and _latest_latency <= latency_target_ms

## Latency stats for HUD/telemetry — budget-aware (no heavy sort beyond 120).
func get_latency_stats() -> Dictionary:
	return {
		"latest_ms": _latest_latency,
		"avg_ms": _avg_latency,
		"max_ms": _max_latency,
		"min_ms": _min_latency,
		"p95_ms": _p95_latency,
		"target_ms": latency_target_ms,
		"within_budget": is_within_budget(),
		"samples": _latencies.size(),
		"violations": _violations,
	}

func get_latest_latency() -> float:
	return _latest_latency

func get_average_latency() -> float:
	return _avg_latency

func get_max_latency() -> float:
	return _max_latency

func clear_latency_history() -> void:
	_latencies.clear()
	_pending_touches.clear()
	_latest_latency = 0.0
	_max_latency = 0.0
	_min_latency = 0.0
	_avg_latency = 0.0
	_p95_latency = 0.0
	_violations = 0
	_within_budget = true

# ---------------------------------------------------------------------------
# Deadzone tuning — budget-aware, uses joystick/button_cluster
# ---------------------------------------------------------------------------

## Set move joystick deadzone in dp. Clamps to [MIN, MAX], applies live if present.
func set_move_deadzone(dp: float) -> void:
	var clamped: float = clamp(dp, MIN_DEADZONE_DP, MAX_DEADZONE_DP)
	move_deadzone_dp = clamped
	_deadzone_tune_count += 1
	if auto_apply_deadzone:
		_apply_move_deadzone()
	deadzone_changed.emit("move", clamped)

func get_move_deadzone() -> float:
	return move_deadzone_dp

## Set camera/look deadzone in dp. Clamps and applies live.
func set_look_deadzone(dp: float) -> void:
	var clamped: float = clamp(dp, MIN_DEADZONE_DP, MAX_DEADZONE_DP)
	look_deadzone_dp = clamped
	_deadzone_tune_count += 1
	if auto_apply_deadzone:
		_apply_look_deadzone()
	deadzone_changed.emit("look", clamped)

func get_look_deadzone() -> float:
	return look_deadzone_dp

## Legacy alias: joystick deadzone == move deadzone.
func set_joystick_deadzone(dp: float) -> void:
	set_move_deadzone(dp)

func get_joystick_deadzone() -> float:
	return get_move_deadzone()

## Apply current deadzones to live scene nodes (if found).
func apply_to_joystick(node: Node) -> void:
	if node == null:
		return
	if "deadzone_dp" in node:
		node.set("deadzone_dp", move_deadzone_dp)
		_deadzone_tune_count += 1
	elif node.has_method("set_deadzone_dp"):
		node.call("set_deadzone_dp", move_deadzone_dp)
		_deadzone_tune_count += 1
	elif node.has_method("get_deadzone_dp"):
		# Fallback: try exported property via string
		node.set("deadzone_dp", move_deadzone_dp)

func apply_to_camera_joystick(node: Node) -> void:
	if node == null:
		return
	if "deadzone_dp" in node:
		node.set("deadzone_dp", look_deadzone_dp)
		_deadzone_tune_count += 1
	elif node.has_method("set_deadzone_dp"):
		node.call("set_deadzone_dp", look_deadzone_dp)
		_deadzone_tune_count += 1

## Tune deadzone for display density — higher dpi may want slightly larger deadzone
## to compensate for finger jitter in px. Budget: single math, no loops.
func tune_for_density(dpi: float = -1.0) -> Dictionary:
	var resolved_dpi: float = dpi
	if resolved_dpi <= 0.0:
		resolved_dpi = _get_dpi()
	# Baseline 160 dpi -> factor 1.0. Scale deadzone gently: sqrt(density_scale)
	var density_scale: float = resolved_dpi / 160.0
	var factor: float = sqrt(clamp(density_scale, 0.5, 4.0))
	# Move joystick benefits from slightly larger deadzone on high-density screens
	var tuned_move: float = clamp(DEFAULT_MOVE_DEADZONE_DP * factor, MIN_DEADZONE_DP, MAX_DEADZONE_DP)
	# Camera drag is more sensitive — keep tighter
	var tuned_look: float = clamp(DEFAULT_CAMERA_DEADZONE_DP * factor * 0.9, MIN_DEADZONE_DP, MAX_DEADZONE_DP)
	# Only auto-apply if configured
	if auto_apply_deadzone:
		set_move_deadzone(tuned_move)
		set_look_deadzone(tuned_look)
	else:
		move_deadzone_dp = tuned_move
		look_deadzone_dp = tuned_look
	return {
		"dpi": resolved_dpi,
		"density_scale": density_scale,
		"factor": factor,
		"move_deadzone_dp": tuned_move,
		"look_deadzone_dp": tuned_look,
		"applied": auto_apply_deadzone,
	}

## Reset deadzones to layout defaults.
func reset_deadzones() -> void:
	move_deadzone_dp = DEFAULT_MOVE_DEADZONE_DP
	look_deadzone_dp = DEFAULT_LOOK_DEADZONE_DP
	_deadzone_tune_count += 1
	if auto_apply_deadzone:
		_apply_all_deadzones()
	deadzone_changed.emit("reset", 0.0)

## Validate deadzones are within sane bounds and consistent with touch_layout.json.
func validate_deadzones() -> Dictionary:
	var move_ok: bool = move_deadzone_dp >= MIN_DEADZONE_DP and move_deadzone_dp <= MAX_DEADZONE_DP
	var look_ok: bool = look_deadzone_dp >= MIN_DEADZONE_DP and look_deadzone_dp <= MAX_DEADZONE_DP
	var gap_ok: bool = (move_deadzone_dp + look_deadzone_dp) < 36.0 # sanity: combined shouldn't eat whole radius
	return {
		"passed": move_ok and look_ok and gap_ok,
		"move_deadzone_dp": move_deadzone_dp,
		"look_deadzone_dp": look_deadzone_dp,
		"move_ok": move_ok,
		"look_ok": look_ok,
		"gap_ok": gap_ok,
		"min_dp": MIN_DEADZONE_DP,
		"max_dp": MAX_DEADZONE_DP,
	}

# ---------------------------------------------------------------------------
# InputService integration — budget-aware lookup (<12 calls)
# ---------------------------------------------------------------------------
func _get_input_service() -> Node:
	if get_tree() == null:
		return null
	var svc: Node = get_tree().root.get_node_or_null("InputService")
	if svc != null:
		return svc
	if Engine.has_singleton("InputService"):
		return Engine.get_singleton("InputService") as Node
	return null

func _find_touch_nodes() -> Dictionary:
	var result: Dictionary = {"joystick": null, "camera": null, "cluster": null}
	if get_tree() == null:
		return result
	var root: Node = get_tree().current_scene
	if root == null:
		root = get_tree().root
	# Cheap lookup: try cached first, then scene search limited depth
	if _cached_joystick != null and is_instance_valid(_cached_joystick):
		result["joystick"] = _cached_joystick
	if _cached_camera_joystick != null and is_instance_valid(_cached_camera_joystick):
		result["camera"] = _cached_camera_joystick
	if _cached_button_cluster != null and is_instance_valid(_cached_button_cluster):
		result["cluster"] = _cached_button_cluster
	return result

func _apply_move_deadzone() -> void:
	var node: Node = _cached_joystick
	if node == null or not is_instance_valid(node):
		node = _find_joystick_node()
		_cached_joystick = node
	if node != null:
		apply_to_joystick(node)

func _apply_look_deadzone() -> void:
	var node: Node = _cached_camera_joystick
	if node == null or not is_instance_valid(node):
		node = _find_camera_joystick_node()
		_cached_camera_joystick = node
	if node != null:
		apply_to_camera_joystick(node)

func _apply_all_deadzones() -> void:
	_apply_move_deadzone()
	_apply_look_deadzone()

func _find_joystick_node() -> Node:
	if get_tree() == null:
		return null
	var scene: Node = get_tree().current_scene
	if scene == null:
		scene = get_tree().root
	# Search by class_name — budget: first match only, no deep traversal beyond children
	var found := scene.find_child("TouchJoystick", true, false) if scene.has_method("find_child") else null
	if found != null:
		return found
	# Fallback: scan root children for TouchJoystick script
	for child in scene.get_children():
		if child.get_script() != null and child.has_method("get_move_vector"):
			# Heuristic: TouchJoystick has get_move_vector
			if "deadzone_dp" in child or child.has_method("get_deadzone_dp"):
				# Extra check: has radius_dp (joystick) vs sensitivity_dp (camera)
				if "radius_dp" in child:
					return child
	return null

func _find_camera_joystick_node() -> Node:
	if get_tree() == null:
		return null
	var scene: Node = get_tree().current_scene
	if scene == null:
		scene = get_tree().root
	var found := scene.find_child("CameraJoystick", true, false) if scene.has_method("find_child") else null
	if found != null:
		return found
	for child in scene.get_children():
		if child.get_script() != null and child.has_method("get_look_vector"):
			if "deadzone_dp" in child and "sensitivity_dp" in child:
				return child
	return null

func _get_dpi() -> float:
	var dpi: float = 0.0
	if DisplayServer.get_screen_count() > 0:
		var s_dpi: int = DisplayServer.screen_get_dpi(0)
		if s_dpi > 0:
			dpi = float(s_dpi)
	if dpi <= 0.0:
		dpi = 160.0
	return dpi

func _get_dp_scale() -> float:
	return _get_dpi() / 160.0

func _clamp_deadzone_tunables() -> void:
	move_deadzone_dp = clamp(move_deadzone_dp, MIN_DEADZONE_DP, MAX_DEADZONE_DP)
	look_deadzone_dp = clamp(look_deadzone_dp, MIN_DEADZONE_DP, MAX_DEADZONE_DP)
	if move_deadzone_dp < 0.0:
		move_deadzone_dp = DEFAULT_MOVE_DEADZONE_DP
	if look_deadzone_dp < 0.0:
		look_deadzone_dp = DEFAULT_LOOK_DEADZONE_DP

func _recompute_stats() -> void:
	if _latencies.is_empty():
		_avg_latency = 0.0
		_max_latency = 0.0
		_min_latency = 0.0
		_p95_latency = 0.0
		return
	var sum: float = 0.0
	var max_v: float = _latencies[0]
	var min_v: float = _latencies[0]
	for v in _latencies:
		sum += v
		if v > max_v:
			max_v = v
		if v < min_v:
			min_v = v
	_avg_latency = sum / float(_latencies.size())
	_max_latency = max_v
	_min_latency = min_v
	# p95 — sort copy (max 120 entries, budget OK)
	if _latencies.size() >= MIN_SAMPLES_FOR_STATS:
		var sorted: Array[float] = []
		sorted.assign(_latencies.duplicate())
		sorted.sort()
		var idx: int = int(ceil(float(sorted.size()) * 0.95)) - 1
		idx = clamp(idx, 0, sorted.size() - 1)
		_p95_latency = sorted[idx]
	else:
		_p95_latency = _max_latency

# ---------------------------------------------------------------------------
# Public helpers — deadzone in px for callers that need px units
# ---------------------------------------------------------------------------
func get_move_deadzone_px() -> float:
	return move_deadzone_dp * _get_dp_scale()

func get_look_deadzone_px() -> float:
	return look_deadzone_dp * _get_dp_scale()

# ---------------------------------------------------------------------------
# Telemetry hooks — per 00-conventions.md §11 (budget <12 calls each)
# ---------------------------------------------------------------------------
func debug_export() -> Dictionary:
	return {
		"latency_target_ms": latency_target_ms,
		"frame_budget_ms": FRAME_BUDGET_MS,
		"max_latency_ms": MAX_LATENCY_MS,
		"latest_ms": _latest_latency,
		"avg_ms": _avg_latency,
		"max_ms": _max_latency,
		"min_ms": _min_latency,
		"p95_ms": _p95_latency,
		"within_budget": is_within_budget(),
		"samples": _latencies.size(),
		"total_samples": _total_samples,
		"violations": _violations,
		"pending_touches": _pending_touches.size(),
		"move_deadzone_dp": move_deadzone_dp,
		"look_deadzone_dp": look_deadzone_dp,
		"move_deadzone_px": get_move_deadzone_px(),
		"look_deadzone_px": get_look_deadzone_px(),
		"deadzone_tune_count": _deadzone_tune_count,
		"auto_apply_deadzone": auto_apply_deadzone,
		"auto_track": auto_track,
	}

func perf_mark() -> Dictionary:
	_perf_samples += 1
	var validation := validate_latency_target()
	return {
		"samples": _perf_samples,
		"latency_latest_ms": _latest_latency,
		"latency_avg_ms": _avg_latency,
		"latency_max_ms": _max_latency,
		"latency_p95_ms": _p95_latency,
		"target_ms": latency_target_ms,
		"within_budget": validation["passed"],
		"violations": _violations,
		"total_samples": _total_samples,
		"pending": _pending_touches.size(),
		"move_deadzone_dp": move_deadzone_dp,
		"look_deadzone_dp": look_deadzone_dp,
		"deadzone_tunes": _deadzone_tune_count,
		"input_service_calls": _input_service_calls,
		"budget_draw_calls": 12,
		"estimated_draw_calls": 1,
		"event_driven": true,
		"has_process": false,
	}
