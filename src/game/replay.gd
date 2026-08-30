## WS60 — Goal Replay: Replay Buffer + Goal Replay Camera
## Budget-aware <12 calls, deterministic, 120 Hz fixed tick.
## Uses: Goal WS22 (goal detection/volume), CameraRig WS29 (chase cam),
##       TimeService WS05 (120 Hz tick, delta clamp).
##       PhysicsConstants WS04 (arena 60x40, single source).
extends Node
class_name Replay

const PC = preload("res://src/core/constants.gd")
const TimeSvc = preload("res://src/core/time_service.gd")
const GoalRef = preload("res://src/game/arena/goal.gd")
const CameraRigRef = preload("res://src/game/camera/camera_rig.gd")

# ---------------------------------------------------------------------------
# Tick — must match TimeService + PhysicsConstants + project.godot (120 Hz)
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0
const DELTA_MIN: float = 1.0 / 240.0
const DELTA_MAX: float = 1.0 / 30.0

# ---------------------------------------------------------------------------
# Replay buffer — ring buffer of snapshot dicts, 120 Hz, budget-aware
# ---------------------------------------------------------------------------
const REPLAY_SECONDS: float = 5.0
const REPLAY_BUFFER_CAP: int = 600  # 5s * 120Hz
const REPLAY_PRE_GOAL_SECONDS: float = 3.0
const REPLAY_PRE_GOAL_TICKS: int = 360  # 3s * 120
const REPLAY_POST_GOAL_SECONDS: float = 1.0
const REPLAY_POST_GOAL_TICKS: int = 120
const REPLAY_PLAYBACK_FPS: float = 60.0
const REPLAY_CAM_LERP_SPEED: float = 4.0

# Budget
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK
const BUDGET_PHYSICS_MS: float = 4.0
const ESTIMATED_PHYSICS_MS: float = 0.3
const ESTIMATED_DRAW_CALLS: int = 0
const MAX_DRAW_CALLS: int = 12

# Goal geometry mirror (must match Goal WS22 + PhysicsConstants)
const GOAL_WIDTH: float = 7.3
const GOAL_HEIGHT: float = 2.1
const GOAL_DEPTH: float = 2.0
const ARENA_HALF_LENGTH: float = 30.0

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
enum State { IDLE, RECORDING, REPLAYING, FINISHED }

var _state: int = State.IDLE
var _buffer: Array[Dictionary] = []
var _head: int = 0
var _count: int = 0
var _tick: int = 0
var _call_count: int = 0
var _is_replaying: bool = false
var _playback_index: int = 0
var _playback_ticks: int = 0
var _playback_speed: float = 1.0
var _goal_team: int = 0
var _goal_tick: int = -1
var _goal_position: Vector3 = Vector3.ZERO
var _replay_frames: Array[Dictionary] = []

# Camera — weak ref to CameraRig WS29, configured for replay orbit
var _camera_rig: CameraRig = null
var _replay_camera_pos: Vector3 = Vector3.ZERO
var _replay_camera_target: Vector3 = Vector3.ZERO
var _replay_duration_ticks: int = 360

# World refs (optional, for auto-record)
var world: Node = null
var ball: Node3D = null
var car: Node3D = null

signal replay_started(team: int, frame_count: int)
signal replay_frame_applied(frame: Dictionary, index: int)
signal replay_finished(team: int)
signal goal_replay_requested(team: int, goal_pos: Vector3)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_buffer.resize(REPLAY_BUFFER_CAP)
	for i in REPLAY_BUFFER_CAP:
		_buffer[i] = {}
	_wire_goals()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[Replay] debug_validate: %s" % e)

func _physics_process(delta: float) -> void:
	_call_count = 0
	_call_count += 1
	if _state == State.RECORDING:
		_auto_capture()
		_call_count += 1
	elif _state == State.REPLAYING:
		tick_replay(delta)
		_call_count += 1

# ---------------------------------------------------------------------------
# Recording — ring buffer, O(1) per tick, <12 calls
# ---------------------------------------------------------------------------
func start_recording() -> void:
	_state = State.RECORDING
	_is_replaying = false
	_count = 0
	_head = 0
	_tick = 0
	_goal_tick = -1

func stop_recording() -> void:
	if _state == State.RECORDING:
		_state = State.IDLE

func record_frame(snapshot: Dictionary) -> void:
	_call_count += 1
	var entry := {
		"tick": _tick,
		"time": float(_tick) * TICK_DELTA,
		"ball_pos": snapshot.get("ball_position", snapshot.get("ball_pos", Vector3.ZERO)),
		"ball_vel": snapshot.get("ball_velocity", snapshot.get("ball_vel", Vector3.ZERO)),
		"ball_ang": snapshot.get("ball_angular", snapshot.get("ball_ang", Vector3.ZERO)),
		"car_pos": snapshot.get("car_position", snapshot.get("car_pos", Vector3.ZERO)),
		"car_vel": snapshot.get("car_velocity", snapshot.get("car_vel", Vector3.ZERO)),
		"car_yaw": snapshot.get("car_yaw", 0.0),
		"ball_cam": snapshot.get("ball_cam", false),
	}
	_buffer[_head] = entry
	_head = (_head + 1) % REPLAY_BUFFER_CAP
	if _count < REPLAY_BUFFER_CAP:
		_count += 1
	_tick += 1

func _auto_capture() -> void:
	var snap := _build_auto_snapshot()
	if snap.is_empty():
		_tick += 1
		return
	record_frame(snap)

func _build_auto_snapshot() -> Dictionary:
	var d := {}
	if ball != null and is_instance_valid(ball):
		d["ball_pos"] = ball.global_position
		if ball is RigidBody3D:
			var rb := ball as RigidBody3D
			d["ball_vel"] = rb.linear_velocity
			d["ball_ang"] = rb.angular_velocity
	if car != null and is_instance_valid(car):
		d["car_pos"] = car.global_position
		if car is RigidBody3D:
			var rb2 := car as RigidBody3D
			d["car_vel"] = rb2.linear_velocity
		d["car_yaw"] = car.rotation.y if car is Node3D else 0.0
	if d.is_empty():
		return {}
	return d

func get_buffer_count() -> int:
	return _count

func get_buffer_cap() -> int:
	return REPLAY_BUFFER_CAP

func get_recorded_frames(count: int = -1) -> Array[Dictionary]:
	if _count == 0:
		return []
	var n := _count if count < 0 else mini(count, _count)
	var out: Array[Dictionary] = []
	out.resize(n)
	var start := (_head - _count + REPLAY_BUFFER_CAP) % REPLAY_BUFFER_CAP
	for i in n:
		var idx := (start + _count - n + i) % REPLAY_BUFFER_CAP
		out[i] = _buffer[idx].duplicate()
	return out

func get_last_frames(n: int) -> Array[Dictionary]:
	return get_recorded_frames(n)

func clear_buffer() -> void:
	_count = 0
	_head = 0
	_tick = 0
	_replay_frames.clear()

# ---------------------------------------------------------------------------
# Goal integration — WS22
# ---------------------------------------------------------------------------
func _wire_goals() -> void:
	if world != null:
		for key in ["goal_positive", "goal_negative"]:
			var g: Node = world.get(key) if key in world else null
			if g != null and g.has_signal("goal_scored"):
				if not (g as Goal).goal_scored.is_connected(_on_goal_scored):
					(g as Goal).goal_scored.connect(_on_goal_scored)
		if world.has_signal("goal_scored"):
			if not world.goal_scored.is_connected(_on_goal_scored):
				world.goal_scored.connect(_on_goal_scored)
	var parent := get_parent()
	if parent != null:
		for child in parent.get_children():
			if child is Goal:
				var gg := child as Goal
				if not gg.goal_scored.is_connected(_on_goal_scored):
					gg.goal_scored.connect(_on_goal_scored)

func _on_goal_scored(team: int) -> void:
	_goal_team = team
	_goal_tick = _tick
	_goal_position = PC.goal_center(team > 0)
	goal_replay_requested.emit(team, _goal_position)
	if _state == State.RECORDING:
		_trigger_replay(team)

func _trigger_replay(team: int) -> void:
	var frames := get_last_frames(REPLAY_PRE_GOAL_TICKS)
	_replay_frames = frames
	_state = State.REPLAYING
	_is_replaying = true
	_playback_index = 0
	_playback_ticks = 0
	_replay_duration_ticks = frames.size()
	_setup_replay_camera(team)
	replay_started.emit(team, frames.size())

func start_replay(team: int, pre_goal_ticks: int = REPLAY_PRE_GOAL_TICKS) -> bool:
	if _count == 0:
		return false
	_goal_team = team
	_replay_frames = get_last_frames(pre_goal_ticks)
	if _replay_frames.is_empty():
		return false
	_state = State.REPLAYING
	_is_replaying = true
	_playback_index = 0
	_playback_ticks = 0
	_replay_duration_ticks = _replay_frames.size()
	_setup_replay_camera(team)
	replay_started.emit(team, _replay_frames.size())
	return true

func is_replaying() -> bool:
	return _is_replaying and _state == State.REPLAYING

func get_playback_progress() -> float:
	if _replay_duration_ticks == 0:
		return 0.0
	return clamp(float(_playback_index) / float(maxi(1, _replay_duration_ticks)), 0.0, 1.0)

# ---------------------------------------------------------------------------
# Replay tick — called at 120 Hz or via _physics_process, <12 calls
# ---------------------------------------------------------------------------
func tick_replay(delta: float) -> void:
	if not _is_replaying:
		return
	_call_count += 1
	if _replay_frames.is_empty():
		_finish_replay()
		return
	var idx := _playback_index
	if idx >= _replay_frames.size():
		_finish_replay()
		return
	var frame: Dictionary = _replay_frames[idx]
	_apply_frame(frame)
	replay_frame_applied.emit(frame, idx)
	_update_replay_camera(delta, frame)
	_playback_index += 1
	_playback_ticks += 1
	if _playback_index >= _replay_frames.size():
		_finish_replay()

func _apply_frame(frame: Dictionary) -> void:
	if ball != null and is_instance_valid(ball):
		var bp: Vector3 = frame.get("ball_pos", Vector3.ZERO)
		ball.global_position = bp
		if ball is RigidBody3D:
			var rb := ball as RigidBody3D
			rb.linear_velocity = frame.get("ball_vel", Vector3.ZERO)
			rb.angular_velocity = frame.get("ball_ang", Vector3.ZERO)
	if car != null and is_instance_valid(car):
		var cp: Vector3 = frame.get("car_pos", Vector3.ZERO)
		car.global_position = cp
		if car is RigidBody3D:
			var rb2 := car as RigidBody3D
			rb2.linear_velocity = frame.get("car_vel", Vector3.ZERO)
		if frame.has("car_yaw"):
			car.rotation.y = float(frame["car_yaw"])

func _finish_replay() -> void:
	_is_replaying = false
	_state = State.FINISHED
	var team := _goal_team
	replay_finished.emit(team)
	_restore_camera()

func stop_replay() -> void:
	if _is_replaying:
		_finish_replay()

func skip_replay() -> void:
	stop_replay()

# ---------------------------------------------------------------------------
# Goal Replay Camera — uses CameraRig WS29
# ---------------------------------------------------------------------------
func bind_camera_rig(rig: CameraRig) -> void:
	_camera_rig = rig

func _setup_replay_camera(team: int) -> void:
	var goal_pos := PC.goal_center(team > 0)
	var ball_traj: Vector3 = Vector3.ZERO
	if not _replay_frames.is_empty():
		ball_traj = _replay_frames[_replay_frames.size() - 1].get("ball_pos", goal_pos)
	var dir := (goal_pos - ball_traj).normalized()
	if dir.length_squared() < 0.01:
		dir = Vector3(0, 0, -1 if team > 0 else 1)
	_replay_camera_target = ball_traj
	_replay_camera_pos = goal_pos - dir * 12.0 + Vector3(0, 6.0, 0)
	if _camera_rig != null:
		_camera_rig.follow_distance = 10.0
		_camera_rig.follow_height = 4.0
		_camera_rig.stiffness = 6.0
		_camera_rig.lag = 0.12

func _update_replay_camera(delta: float, frame: Dictionary) -> void:
	var ball_pos: Vector3 = frame.get("ball_pos", _replay_camera_target)
	_replay_camera_target = _replay_camera_target.lerp(ball_pos, clamp(REPLAY_CAM_LERP_SPEED * delta, 0.0, 1.0))
	var desired := _replay_camera_pos.lerp(ball_pos + Vector3(0, 4.0, 0) - (ball_pos - _replay_camera_pos).normalized() * 2.0, 0.08)
	_replay_camera_pos = desired
	if _camera_rig != null:
		var dt := clamp(delta, DELTA_MIN, DELTA_MAX)
		_camera_rig.global_position = _camera_rig.global_position.lerp(_replay_camera_pos, clamp(5.0 * dt, 0.0, 1.0))
		if ball_pos != Vector3.ZERO:
			var dir := (ball_pos - _camera_rig.global_position).normalized()
			if dir.length_squared() > 0.001:
				var basis := Basis.looking_at(-dir, Vector3.UP)
				_camera_rig.global_transform.basis = _camera_rig.global_transform.basis.slerp(basis, clamp(4.0 * dt, 0.0, 1.0))

func _restore_camera() -> void:
	if _camera_rig != null:
		_camera_rig.stiffness = 8.0
		_camera_rig.lag = 0.15
		_camera_rig.follow_distance = 10.0
		_camera_rig.follow_height = 3.5

func get_replay_camera_state() -> Dictionary:
	return {
		"pos": _replay_camera_pos,
		"target": _replay_camera_target,
		"progress": get_playback_progress(),
		"is_replaying": is_replaying(),
	}

# ---------------------------------------------------------------------------
# Budget / validation
# ---------------------------------------------------------------------------
func get_call_count() -> int:
	return _call_count

static func max_calls_per_tick() -> int:
	return MAX_CALLS_PER_TICK

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA %.8f != 1/120" % TICK_DELTA)
	if not is_equal_approx(DELTA_MIN, 1.0 / 240.0):
		errors.append("DELTA_MIN != 1/240")
	if not is_equal_approx(DELTA_MAX, 1.0 / 30.0):
		errors.append("DELTA_MAX != 1/30")
	if REPLAY_BUFFER_CAP != int(REPLAY_SECONDS * float(PHYSICS_TICKS_PER_SECOND)):
		errors.append("REPLAY_BUFFER_CAP %d != REPLAY_SECONDS * 120" % REPLAY_BUFFER_CAP)
	if REPLAY_PRE_GOAL_TICKS != int(REPLAY_PRE_GOAL_SECONDS * float(PHYSICS_TICKS_PER_SECOND)):
		errors.append("REPLAY_PRE_GOAL_TICKS mismatch")
	if REPLAY_POST_GOAL_TICKS != int(REPLAY_POST_GOAL_SECONDS * float(PHYSICS_TICKS_PER_SECOND)):
		errors.append("REPLAY_POST_GOAL_TICKS mismatch")
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
	var v_goal := GoalRef.debug_validate()
	if not v_goal["ok"]:
		for e in v_goal["errors"]:
			errors.append("Goal: %s" % str(e))
	if not is_equal_approx(GOAL_WIDTH, GoalRef.GOAL_WIDTH):
		errors.append("GOAL_WIDTH %.2f != Goal.GOAL_WIDTH %.2f" % [GOAL_WIDTH, GoalRef.GOAL_WIDTH])
	if not is_equal_approx(GOAL_HEIGHT, GoalRef.GOAL_HEIGHT):
		errors.append("GOAL_HEIGHT %.2f != Goal.GOAL_HEIGHT %.2f" % [GOAL_HEIGHT, GoalRef.GOAL_HEIGHT])
	if not is_equal_approx(GOAL_DEPTH, GoalRef.GOAL_DEPTH):
		errors.append("GOAL_DEPTH %.2f != Goal.GOAL_DEPTH %.2f" % [GOAL_DEPTH, GoalRef.GOAL_DEPTH])
	if not is_equal_approx(GOAL_WIDTH, PC.GOAL_WIDTH):
		errors.append("GOAL_WIDTH drift vs PhysicsConstants")
	if not is_equal_approx(ARENA_HALF_LENGTH, PC.ARENA_HALF_LENGTH):
		errors.append("ARENA_HALF_LENGTH drift")
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"state": _state,
		"is_replaying": is_replaying(),
		"tick": _tick,
		"buffer_count": _count,
		"buffer_cap": REPLAY_BUFFER_CAP,
		"goal_team": _goal_team,
		"goal_tick": _goal_tick,
		"playback_index": _playback_index,
		"playback_progress": get_playback_progress(),
		"call_count": _call_count,
		"budget_calls": BUDGET_CALLS,
		"replay_seconds": REPLAY_SECONDS,
		"pre_goal_ticks": REPLAY_PRE_GOAL_TICKS,
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "Replay",
		"tick_hz": PHYSICS_TICKS_PER_SECOND,
		"tick_delta": TICK_DELTA,
		"budget_calls": MAX_CALLS_PER_TICK,
		"estimated_physics_ms": ESTIMATED_PHYSICS_MS,
		"budget_physics_ms": BUDGET_PHYSICS_MS,
		"estimated_draw_calls": ESTIMATED_DRAW_CALLS,
		"budget_draw_calls": MAX_DRAW_CALLS,
		"buffer_cap": REPLAY_BUFFER_CAP,
	}

func describe() -> String:
	return "Replay 120Hz buf=%d/%d replay=%s team=%d" % [_count, REPLAY_BUFFER_CAP, str(is_replaying()), _goal_team]
