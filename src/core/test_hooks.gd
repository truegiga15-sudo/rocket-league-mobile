# TestHooks — WS09 Deterministic Replay & Test Hooks
# Autoload singleton: TestHooks
# Provides deterministic RNG, fixed-tick control, input recording/replay,
# and state injection for regression and critic harness.
# Complements TelemetryService (logs replay events) and InputService (provides raw inputs).
# Depends on WS02 (Project Structure). No downstream imports.
extends Node

const REPLAY_PATH: String = "user://replay.json"
const REPLAY_VERSION: int = 1
const MAX_RECORDED_FRAMES: int = 7200

var _deterministic: bool = false
var _seed: int = 1337
var _recording: bool = false
var _replaying: bool = false
var _replay_index: int = 0
var _recorded: Array[Dictionary] = []
var _replay_data: Array[Dictionary] = []
var _fixed_delta: float = -1.0
var _tick_count: int = 0

signal replay_started(frame_count: int)
signal replay_finished
signal replay_step_applied(frame: Dictionary, index: int)
signal deterministic_changed(enabled: bool, p_seed: int)
signal recording_started
signal recording_stopped(frame_count: int)

func _ready() -> void:
	pass

func _process(_delta: float) -> void:
	if _recording:
		_capture_frame()
	elif _replaying:
		_apply_replay_step()

func enable_deterministic(p_seed: int = 1337, p_fixed_delta: float = -1.0) -> void:
	_seed = p_seed
	_deterministic = true
	_fixed_delta = p_fixed_delta
	seed(_seed)
	if _fixed_delta > 0.0:
		Engine.physics_ticks_per_second = int(round(1.0 / _fixed_delta))
	_log_event("deterministic_enabled", {"seed": _seed, "fixed_delta": _fixed_delta})
	deterministic_changed.emit(true, _seed)

func disable_deterministic() -> void:
	_deterministic = false
	_fixed_delta = -1.0
	Engine.physics_ticks_per_second = 120
	_log_event("deterministic_disabled", {})
	deterministic_changed.emit(false, _seed)

func is_deterministic() -> bool:
	return _deterministic

func get_seed() -> int:
	return _seed

func set_seed(p_seed: int) -> void:
	_seed = p_seed
	seed(_seed)

func get_fixed_delta() -> float:
	return _fixed_delta

func set_fixed_delta(v: float) -> void:
	_fixed_delta = v

func enable_test_mode(p_seed: int = 1337) -> void:
	enable_deterministic(p_seed)

func disable_test_mode() -> void:
	disable_deterministic()

func is_test_mode() -> bool:
	return _deterministic

func start_recording(clear_existing: bool = true) -> void:
	if clear_existing:
		_recorded.clear()
		_tick_count = 0
	_recording = true
	_replaying = false
	recording_started.emit()
	_log_event("replay_recording_started", {"seed": _seed, "deterministic": _deterministic})

func stop_recording() -> Array[Dictionary]:
	_recording = false
	_log_event("replay_recording_stopped", {"frames": _recorded.size()})
	recording_stopped.emit(_recorded.size())
	return _recorded.duplicate(true)

func is_recording() -> bool:
	return _recording

func get_recorded_inputs() -> Array[Dictionary]:
	return _recorded.duplicate(true)

func get_recorded_frames() -> Array[Dictionary]:
	return get_recorded_inputs()

func clear_recording() -> void:
	_recorded.clear()
	_tick_count = 0

func save_replay(path: String = REPLAY_PATH) -> bool:
	var envelope := {
		"version": REPLAY_VERSION,
		"seed": _seed,
		"deterministic": _deterministic,
		"fixed_delta": _fixed_delta,
		"created_unix": int(Time.get_unix_time_from_system()),
		"frame_count": _recorded.size(),
		"frames": _recorded.duplicate(true),
	}
	var text := JSON.stringify(envelope, "\t")
	if text == "":
		push_warning("[TestHooks] save_replay JSON.stringify failed")
		return false
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa == null:
		push_warning("[TestHooks] save_replay cannot open %s: %d" % [path, FileAccess.get_open_error()])
		return false
	fa.store_string(text)
	fa.flush()
	_log_event("replay_saved", {"path": path, "frames": _recorded.size()})
	return true

func load_replay(path: String = REPLAY_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "reason": "missing", "frames": []}
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return {"ok": false, "reason": "open_failed", "frames": []}
	var parsed: Variant = JSON.parse_string(fa.get_as_text())
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "reason": "parse_failed", "frames": []}
	var env: Dictionary = parsed as Dictionary
	var frames: Array = env.get("frames", [])
	var version: int = int(env.get("version", 0))
	if version != REPLAY_VERSION:
		push_warning("[TestHooks] replay version %d != %d — attempting compat load" % [version, REPLAY_VERSION])
	var out: Array[Dictionary] = []
	for f in frames:
		if typeof(f) == TYPE_DICTIONARY:
			out.append(f as Dictionary)
	_recorded = out.duplicate(true)
	_seed = int(env.get("seed", _seed))
	_log_event("replay_loaded", {"path": path, "frames": _recorded.size(), "version": version})
	return {"ok": true, "frames": out, "seed": _seed, "version": version, "envelope": env}

func start_replay(frames: Array = []) -> bool:
	var source: Array[Dictionary] = []
	if frames.is_empty():
		source = _recorded.duplicate(true)
	else:
		for f in frames:
			if typeof(f) == TYPE_DICTIONARY:
				source.append(f as Dictionary)
	if source.is_empty():
		push_warning("[TestHooks] start_replay called with empty frames — aborting")
		return false
	_replay_data = source
	_replay_index = 0
	_replaying = true
	_recording = false
	_tick_count = 0
	seed(_seed)
	replay_started.emit(_replay_data.size())
	_log_event("replay_started", {"frames": _replay_data.size(), "seed": _seed})
	return true

func start_replay_from_file(path: String = REPLAY_PATH) -> bool:
	var res := load_replay(path)
	if not bool(res.get("ok", false)):
		return false
	var frames: Array = res.get("frames", []) as Array
	return start_replay(frames)

func stop_replay() -> void:
	if not _replaying:
		return
	_replaying = false
	_replay_index = 0
	replay_finished.emit()
	_log_event("replay_finished", {"applied": _tick_count})

func is_replaying() -> bool:
	return _replaying

func get_replay_progress() -> Dictionary:
	var total: int = _replay_data.size()
	return {
		"index": _replay_index,
		"total": total,
		"remaining": maxi(0, total - _replay_index),
		"fraction": float(_replay_index) / float(maxi(1, total)),
		"tick_count": _tick_count,
	}

func peek_next_frame() -> Dictionary:
	if _replay_index < _replay_data.size():
		return _replay_data[_replay_index].duplicate(true)
	return {}

func step_replay() -> Dictionary:
	if not _replaying or _replay_index >= _replay_data.size():
		if _replaying and _replay_index >= _replay_data.size():
			stop_replay()
		return {}
	var frame: Dictionary = _replay_data[_replay_index].duplicate(true)
	_replay_index += 1
	_tick_count += 1
	_apply_input_frame(frame)
	replay_step_applied.emit(frame, _replay_index - 1)
	if _replay_index >= _replay_data.size():
		stop_replay()
	return frame

func inject_input(frame: Dictionary) -> void:
	_apply_input_frame(frame)
	_log_event("input_injected", frame)

func quantize_input(v: Vector2, steps: int = 100) -> Vector2:
	return Vector2(
		round(v.x * steps) / float(steps),
		round(v.y * steps) / float(steps)
	).limit_length(1.0)

func deterministic_randf() -> float:
	return randf()

func deterministic_randi_range(from: int, to: int) -> int:
	return randi_range(from, to)

func debug_export() -> Dictionary:
	return {
		"deterministic": _deterministic,
		"seed": _seed,
		"fixed_delta": _fixed_delta,
		"recording": _recording,
		"replaying": _replaying,
		"replay_index": _replay_index,
		"recorded_frames": _recorded.size(),
		"replay_frames": _replay_data.size(),
		"tick_count": _tick_count,
		"replay_path": REPLAY_PATH,
		"replay_version": REPLAY_VERSION,
	}

func perf_mark(_label: String = "") -> Dictionary:
	return {
		"deterministic": _deterministic,
		"recorded_frames": _recorded.size(),
		"replay_frames": _replay_data.size(),
		"tick_count": _tick_count,
	}

func perf_mark_label(label: String) -> Dictionary:
	return perf_mark(label)

func _capture_frame() -> void:
	var frame := _read_current_input_frame()
	_recorded.append(frame)
	_tick_count += 1
	if _recorded.size() > MAX_RECORDED_FRAMES:
		_recorded.pop_front()

func _read_current_input_frame() -> Dictionary:
	var move := Vector2.ZERO
	var look := Vector2.ZERO
	var boost := false
	var jump := false
	var drift := false
	var ballCam: bool = true
	var svc := _get_input_service()
	if svc != null:
		move = svc.get("move") if svc.get("move") != null else Vector2.ZERO
		look = svc.get("look") if svc.get("look") != null else Vector2.ZERO
		boost = bool(svc.get("boost")) if svc.get("boost") != null else false
		jump = bool(svc.get("jump")) if svc.get("jump") != null else false
		drift = bool(svc.get("drift")) if svc.get("drift") != null else false
		ballCam = bool(svc.get("ballCam")) if svc.get("ballCam") != null else true
		if _deterministic:
			move = quantize_input(move)
			look = quantize_input(look)
	return {
		"ticks_msec": Time.get_ticks_msec(),
		"frame": Engine.get_process_frames(),
		"tick": _tick_count,
		"move": move,
		"look": look,
		"boost": boost,
		"jump": jump,
		"drift": drift,
		"ballCam": ballCam,
	}

func _apply_replay_step() -> void:
	if _replay_index < _replay_data.size():
		var frame: Dictionary = _replay_data[_replay_index].duplicate(true)
		_replay_index += 1
		_tick_count += 1
		_apply_input_frame(frame)
		replay_step_applied.emit(frame, _replay_index - 1)
		if _replay_index >= _replay_data.size():
			stop_replay()

func _apply_input_frame(frame: Dictionary) -> void:
	var svc := _get_input_service()
	if svc == null:
		return
	if frame.has("move"):
		var mv: Variant = frame["move"]
		if mv is Vector2:
			svc.set("move", mv)
	if frame.has("look"):
		var lk: Variant = frame["look"]
		if lk is Vector2:
			svc.set("look", lk)
	for key in ["boost", "jump", "drift", "ballCam"]:
		if frame.has(key):
			svc.set(key, frame[key])

func _get_input_service() -> Node:
	if has_node("/root/InputService"):
		return get_node("/root/InputService")
	return null

func _log_event(event_name: String, payload: Dictionary) -> void:
	var tel := _get_telemetry()
	if tel != null and tel.has_method("event"):
		tel.event(event_name, payload)

func _get_telemetry() -> Node:
	if has_node("/root/TelemetryService"):
		return get_node("/root/TelemetryService")
	return null
