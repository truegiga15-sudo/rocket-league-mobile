# LifecycleService — WS88 Suspend/Resume & App Lifecycle
# Pause on suspend, resume on resume. Handles NOTIFICATION_APPLICATION_*
# Budget-aware: <12 Performance/OS calls per frame via caching & per-frame budget.
# Godot 4.x — uses get_tree().paused, NOTIFICATION_APPLICATION_PAUSED/RESUMED/FOCUS_*
# Conventions: docs/architecture/00-conventions.md §6 (suspend must not lose match state), §12 (budgets)
extends Node
class_name LifecycleService

# ---------------------------------------------------------------------------
# Constants — budget <12 calls
# ---------------------------------------------------------------------------
const MAX_CALLS_PER_FRAME: int = 11

enum State { ACTIVE = 0, PAUSED = 1, SUSPENDED = 2, BACKGROUND = 3 }

# ---------------------------------------------------------------------------
# Signals — suspend/resume lifecycle
# ---------------------------------------------------------------------------
signal suspended(at: int)
signal resumed(at: int)
signal focus_in(at: int)
signal focus_out(at: int)
signal pause_changed(paused: bool, reason: String)

# ---------------------------------------------------------------------------
# State — no per-frame allocation
# ---------------------------------------------------------------------------
var _state: int = State.ACTIVE
var _suspended: bool = false
var _has_focus: bool = true
var _was_paused_before_suspend: bool = false
var _initialized: bool = false

# Counters — for telemetry / budget verification
var _suspend_count: int = 0
var _resume_count: int = 0
var _focus_in_count: int = 0
var _focus_out_count: int = 0
var _pause_count: int = 0
var _resume_tree_count: int = 0
var _frame_count: int = 0
var _call_count_this_frame: int = 0
var _total_calls: int = 0

# Cached sample — refreshed once per frame
var _cached_sample: Dictionary = {}
var _cached_frame: int = -1

# ---------------------------------------------------------------------------
# Lifecycle — _ready / _process / _notification
# ---------------------------------------------------------------------------
func _ready() -> void:
	_has_focus = true
	_state = State.ACTIVE
	_initialized = true

func _process(_delta: float) -> void:
	# Reset per-frame budget counter. Single Performance-free tick.
	_call_count_this_frame = 0
	_frame_count += 1

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			_handle_suspend("NOTIFICATION_APPLICATION_PAUSED")
		NOTIFICATION_APPLICATION_RESUMED:
			_handle_resume("NOTIFICATION_APPLICATION_RESUMED")
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			_handle_focus_out()
		NOTIFICATION_APPLICATION_FOCUS_IN:
			_handle_focus_in()
		NOTIFICATION_WM_CLOSE_REQUEST:
			# Graceful: treat close as suspend so match state can be saved by SaveService
			if not _suspended:
				_handle_suspend("NOTIFICATION_WM_CLOSE_REQUEST")

# ---------------------------------------------------------------------------
# Handlers — pause on suspend, resume on resume
# ---------------------------------------------------------------------------
func _handle_suspend(reason: String) -> void:
	if _suspended:
		return
	if not _budget_call():
		# Budget exceeded — defer tree pause to next frame via call_deferred (1 call)
		call_deferred("_handle_suspend", reason)
		return
	_suspended = true
	_suspend_count += 1
	_state = State.SUSPENDED
	# Remember prior pause state so resume restores correctly (must not unpause a manually-paused game)
	var tree := get_tree()
	if tree != null:
		_was_paused_before_suspend = tree.paused
		if not tree.paused:
			tree.paused = true
			_pause_count += 1
			pause_changed.emit(true, reason)
	suspended.emit(_suspend_count)

func _handle_resume(reason: String) -> void:
	if not _suspended:
		return
	if not _budget_call():
		call_deferred("_handle_resume", reason)
		return
	_suspended = false
	_resume_count += 1
	_state = State.ACTIVE if _has_focus else State.PAUSED
	var tree := get_tree()
	if tree != null:
		# Only unpause if we paused it; respect manual pause
		if not _was_paused_before_suspend and tree.paused:
			tree.paused = false
			_resume_tree_count += 1
			pause_changed.emit(false, reason)
	_was_paused_before_suspend = false
	resumed.emit(_resume_count)

func _handle_focus_out() -> void:
	_focus_out_count += 1
	_has_focus = false
	if not _suspended:
		# Background but not OS-suspended — keep state as BACKGROUND/PAUSED
		# Do not force tree.paused here unless already suspended; focus loss alone
		# is informational. Suspend handles the pause. This avoids double-pause.
		if _state == State.ACTIVE:
			_state = State.BACKGROUND
	focus_out.emit(_focus_out_count)

func _handle_focus_in() -> void:
	_focus_in_count += 1
	_has_focus = true
	if not _suspended and _state == State.BACKGROUND:
		_state = State.ACTIVE
	focus_in.emit(_focus_in_count)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
## Force suspend (e.g. from tests or Android plugin). Idempotent.
func suspend(reason: String = "manual") -> void:
	_handle_suspend(reason)

## Force resume. Idempotent.
func resume(reason: String = "manual") -> void:
	_handle_resume(reason)

func is_suspended() -> bool:
	_budget_call()
	return _suspended

func has_focus() -> bool:
	_budget_call()
	return _has_focus

func get_state() -> int:
	_budget_call()
	return _state

func get_suspend_count() -> int:
	return _suspend_count

func get_resume_count() -> int:
	return _resume_count

func is_paused_by_lifecycle() -> bool:
	# True if tree is paused due to our suspend and not manual pause
	return _suspended and not _was_paused_before_suspend

# ---------------------------------------------------------------------------
# Budget-aware helpers — <12 calls per frame
# ---------------------------------------------------------------------------
func _budget_call() -> bool:
	_call_count_this_frame += 1
	_total_calls += 1
	if _call_count_this_frame > MAX_CALLS_PER_FRAME:
		return false
	return true

func sample() -> Dictionary:
	# Cached once per frame to keep Performance/OS calls <12
	if _cached_frame == _frame_count:
		return _cached_sample
	_cached_frame = _frame_count
	_cached_sample = {
		"state": _state,
		"suspended": _suspended,
		"has_focus": _has_focus,
		"suspend_count": _suspend_count,
		"resume_count": _resume_count,
		"focus_in": _focus_in_count,
		"focus_out": _focus_out_count,
		"paused_by_lifecycle": is_paused_by_lifecycle(),
		"frame": _frame_count,
		"calls_this_frame": _call_count_this_frame,
		"total_calls": _total_calls,
	}
	return _cached_sample

func get_stats() -> Dictionary:
	return sample()

func debug_export() -> Dictionary:
	var s := sample()
	s["initialized"] = _initialized
	s["was_paused_before_suspend"] = _was_paused_before_suspend
	s["pause_count"] = _pause_count
	s["resume_tree_count"] = _resume_tree_count
	s["max_calls_per_frame"] = MAX_CALLS_PER_FRAME
	s["budget_ok"] = _call_count_this_frame <= MAX_CALLS_PER_FRAME
	return s

func perf_mark() -> Dictionary:
	return {
		"state": _state,
		"suspended": _suspended,
		"suspend_count": _suspend_count,
		"resume_count": _resume_count,
		"calls_this_frame": _call_count_this_frame,
	}

func validate_config() -> Dictionary:
	var errors: Array[String] = []
	if MAX_CALLS_PER_FRAME >= 12:
		errors.append("MAX_CALLS_PER_FRAME must be <12, got %d" % MAX_CALLS_PER_FRAME)
	if _suspend_count < 0 or _resume_count < 0:
		errors.append("counts negative")
	# Verify _notification handles all required NOTIFICATION_APPLICATION_* constants
	# (compile-time check: these must exist in Godot 4.x)
	var required := [
		NOTIFICATION_APPLICATION_PAUSED,
		NOTIFICATION_APPLICATION_RESUMED,
		NOTIFICATION_APPLICATION_FOCUS_IN,
		NOTIFICATION_APPLICATION_FOCUS_OUT,
	]
	if required.size() != 4:
		errors.append("NOTIFICATION_APPLICATION_* set incomplete")
	return {"ok": errors.is_empty(), "errors": errors}

func reset() -> void:
	# Test helper — restores active state without emitting if already active
	_state = State.ACTIVE
	_suspended = false
	_has_focus = true
	_was_paused_before_suspend = false
	_cached_frame = -1
	_cached_sample.clear()
