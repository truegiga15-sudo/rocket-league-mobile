# CameraShake — WS30 Camera Shake & Impact Feedback
# Budget-aware trauma shake on ball hit, goals, demos. Intensity curve + decay.
# Uses CameraRig (WS29) + BallCam (WS31), 120Hz fixed tick via TimeService.
# Godot 4.x — <12 calls per tick, frame-rate independent.
# Dependencies: CameraRig (WS29), BallCam (WS31), TimeService (WS05), PhysicsConstants (WS04)
extends Node3D
class_name CameraShake

const PC = preload("res://src/core/constants.gd")

# ---------------------------------------------------------------------------
# Constants — authored, single source for WS30
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK

## Max shake offset in meters (camera local). RL feel: subtle, not nauseating.
const MAX_OFFSET: float = 0.35
## Max roll in degrees added to camera during shake.
const MAX_ROLL_DEG: float = 1.8
## Max pitch/yaw nudge in degrees.
const MAX_PITCH_DEG: float = 1.2
const MAX_YAW_DEG: float = 1.2

## Intensity presets (trauma 0..1) — before curve scaling.
const INTENSITY_BALL_HIT: float = 0.45
const INTENSITY_GOAL: float = 1.0
const INTENSITY_DEMO: float = 0.85
const INTENSITY_BOOST_IMPACT: float = 0.3

## Trauma decay rate (1/s) — exponential decay, higher = faster settle.
const DEFAULT_DECAY_RATE: float = 6.0
## Duration presets (seconds) — how long trauma stays above 1% without decay re-trigger.
const DURATION_BALL_HIT: float = 0.28
const DURATION_GOAL: float = 0.85
const DURATION_DEMO: float = 0.6

## Frequency (Hz) for perlin-ish shake. Different axes at multiples to avoid repetition.
const FREQ_X: float = 23.0
const FREQ_Y: float = 17.0
const FREQ_Z: float = 29.0
const FREQ_ROLL: float = 13.0

## Impulse scaling — ball hit intensity scales with impulse mag. 9000 max from WS20.
const IMPULSE_REF_MAX: float = 9000.0
const IMPULSE_REF_MIN: float = 120.0

# ---------------------------------------------------------------------------
# Exports — tuned for RL mobile chase cam, inspector-visible
# ---------------------------------------------------------------------------
## Camera rig to shake (WS29). If set, shake offsets its Camera3D.
@export var camera_rig_path: NodePath
## BallCam (WS31) — optional, used to scale shake when ball-cam active.
@export var ball_cam_path: NodePath

## Maximum positional offset (meters). Clamped 0.05..1.0.
@export_range(0.05, 1.0, 0.01) var max_offset: float = MAX_OFFSET
## Maximum roll in degrees.
@export_range(0.1, 5.0, 0.1) var max_roll_deg: float = MAX_ROLL_DEG
## Trauma decay rate (1/s). 2..15 typical. Higher = shorter shake.
@export_range(2.0, 15.0, 0.1) var decay_rate: float = DEFAULT_DECAY_RATE
## Frequency multiplier (0.5..2.0) — scales all axes.
@export_range(0.5, 2.0, 0.05) var frequency_scale: float = 1.0
## Global intensity multiplier (0..2). For accessibility / settings.
@export_range(0.0, 2.0, 0.05) var intensity_scale: float = 1.0
## Enable haptics on shake triggers (calls Haptics singleton if available).
@export var enable_haptics: bool = true
## Disable shake entirely (e.g. for low-motion accessibility).
@export var shake_enabled: bool = true

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------
var _rig: CameraRig = null
var _ball_cam: Node = null
var _camera: Camera3D = null
var _camera_base_pos: Vector3 = Vector3.ZERO
var _camera_base_rot: Vector3 = Vector3.ZERO
var _has_base: bool = false

## Trauma 0..1 — drives intensity_curve. Decays exponentially each tick.
var _trauma: float = 0.0
## Remaining shake time (s) — legacy curve helper, decays with trauma.
var _time: float = 0.0
var _duration: float = 0.0
var _initialized: bool = false

# Telemetry / budget
var _call_count: int = 0
var _last_offset: Vector3 = Vector3.ZERO
var _last_roll_deg: float = 0.0
var _last_intensity: float = 0.0
var _shake_count: int = 0

signal shake_triggered(kind: String, intensity: float)
signal shake_finished

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_resolve_refs()
	_cache_camera()
	_initialized = true

func _resolve_refs() -> void:
	if camera_rig_path != NodePath("") and has_node(camera_rig_path):
		_rig = get_node(camera_rig_path) as CameraRig
	if ball_cam_path != NodePath("") and has_node(ball_cam_path):
		_ball_cam = get_node(ball_cam_path)
	# Fallbacks: search parent / children for rig like BallCam does
	if _rig == null:
		_rig = get_node_or_null("../Node3D_CameraRig") as CameraRig
	if _rig == null:
		_rig = get_node_or_null("../CameraRig") as CameraRig
	if _rig == null:
		for c in get_children():
			if c is CameraRig:
				_rig = c
				break
	if _rig == null and get_parent() != null:
		for c in get_parent().get_children():
			if c is CameraRig:
				_rig = c
				break
	# BallCam fallback
	if _ball_cam == null:
		_ball_cam = get_node_or_null("../BallCam") as Node
	if _ball_cam == null:
		for c in get_children():
			if "BallCam" in c.get_class() or c.has_method("get_weight"):
				_ball_cam = c
				break

func _cache_camera() -> void:
	_camera = null
	_has_base = false
	if _rig != null:
		_camera = _rig.get_camera()
		if _camera == null:
			_camera = _rig.get_node_or_null("SpringArm3D_SpringArm/Camera3D_Camera") as Camera3D
	if _camera == null:
		_camera = get_node_or_null("Camera3D") as Camera3D
		if _camera == null:
			for c in get_children():
				if c is Camera3D:
					_camera = c
					break
	if _camera != null:
		_camera_base_pos = _camera.position
		_camera_base_rot = _camera.rotation_degrees
		_has_base = true
	else:
		# Try to find any Camera3D recursively
		var found := _find_camera_recursive(self)
		if found != null:
			_camera = found
			_camera_base_pos = _camera.position
			_camera_base_rot = _camera.rotation_degrees
			_has_base = true
		if _camera == null and _rig != null:
			var rcam := _find_camera_recursive(_rig)
			if rcam != null:
				_camera = rcam
				_camera_base_pos = _camera.position
				_camera_base_rot = _camera.rotation_degrees
				_has_base = true

func _find_camera_recursive(n: Node) -> Camera3D:
	for c in n.get_children():
		if c is Camera3D:
			return c
		var r := _find_camera_recursive(c)
		if r != null:
			return r
	return null

# ---------------------------------------------------------------------------
# Public API — triggers (budget-aware, each is 1-2 calls)
# ---------------------------------------------------------------------------
func set_camera_rig(rig: CameraRig) -> void:
	_rig = rig
	if rig != null:
		camera_rig_path = get_path_to(rig)
	else:
		camera_rig_path = NodePath("")
	_cache_camera()

func get_camera_rig() -> CameraRig:
	return _rig

func get_camera() -> Camera3D:
	if _camera == null:
		_cache_camera()
	return _camera

## Core trigger — add trauma (0..1) clamped, extend duration. Additive but capped at 1.
func trigger_shake(intensity: float, duration: float = 0.3) -> void:
	if not shake_enabled:
		return
	var t := clamp(intensity * intensity_scale, 0.0, 1.0)
	# Additive trauma with cap — stronger hits stack but not above 1
	_trauma = clamp(max(_trauma, t) + t * 0.15, 0.0, 1.0)
	# Keep longest remaining duration
	_duration = max(_duration, max(duration, 0.05))
	_time = _duration
	_shake_count += 1
	_call_count += 1
	shake_triggered.emit("generic", t)
	_do_haptics_for_intensity(t)

## Shake on ball hit — scales with impulse magnitude.
func trigger_ball_hit(impulse: Vector3, contact_point: Vector3 = Vector3.ZERO) -> void:
	var mag := impulse.length()
	# Map impulse mag -> 0..1 via smoothstep between min and max ref
	var scaled := _scale_impulse(mag)
	var intensity := INTENSITY_BALL_HIT * (0.5 + 0.5 * scaled)
	trigger_shake(intensity, DURATION_BALL_HIT)
	shake_triggered.emit("ball_hit", intensity)

## Compatibility alias — some callers pass only impulse.
func on_ball_hit(impulse: Vector3, contact_point: Vector3 = Vector3.ZERO) -> void:
	trigger_ball_hit(impulse, contact_point)

## Shake on goal — strongest, longest.
func trigger_goal(team: int = 0) -> void:
	trigger_shake(INTENSITY_GOAL, DURATION_GOAL)
	shake_triggered.emit("goal", INTENSITY_GOAL)
	_do_haptics_goal()

func on_goal_scored(team: int = 0) -> void:
	trigger_goal(team)

## Shake on demo — attacker must be supersonic victim destroyed.
func trigger_demo(attacker_speed: float = 18.0, impact_speed: float = 10.0) -> void:
	var s := clamp(attacker_speed / 18.0, 0.0, 2.0)
	var i := clamp(impact_speed / 10.0, 0.0, 2.0)
	var intensity := INTENSITY_DEMO * clamp(0.6 + 0.4 * min(s, i), 0.0, 1.0)
	trigger_shake(intensity, DURATION_DEMO)
	shake_triggered.emit("demo", intensity)
	_do_haptics_demo()

func on_demo(attacker: Node3D = null, victim: Node3D = null) -> void:
	var atk_speed := 18.0
	if attacker != null and attacker is RigidBody3D:
		atk_speed = (attacker as RigidBody3D).linear_velocity.length()
	trigger_demo(atk_speed, 12.0)

## Generic impact — e.g. wall hit, supersonic bump.
func trigger_impact(intensity: float, duration: float = 0.2) -> void:
	trigger_shake(intensity, duration)

func is_shaking() -> bool:
	return _trauma > 0.001

func get_trauma() -> float:
	return _trauma

func get_intensity() -> float:
	return _last_intensity

func get_offset() -> Vector3:
	return _last_offset

func reset_shake() -> void:
	_trauma = 0.0
	_time = 0.0
	_duration = 0.0
	_last_offset = Vector3.ZERO
	_last_roll_deg = 0.0
	_last_intensity = 0.0
	_apply_to_camera(Vector3.ZERO, 0.0, 0.0, 0.0)

# ---------------------------------------------------------------------------
# Intensity curve — trauma squared with exponential decay, frame-rate independent
# ---------------------------------------------------------------------------
## Pure curve: trauma^p * (1 - t) envelope * scale. p=2 gives strong falloff for small trauma.
static func intensity_curve(trauma: float, t_ratio: float = 0.0) -> float:
	var tr := clamp(trauma, 0.0, 1.0)
	# Square trauma so small hits are much weaker (RL feel)
	var base := tr * tr
	# Optional envelope: if t_ratio provided (0..1 elapsed/duration), lerp out
	if t_ratio > 0.001:
		base *= clamp(1.0 - t_ratio, 0.0, 1.0)
	return clamp(base, 0.0, 1.0)

## Decay trauma exponentially: trauma * exp(-rate * dt). Budget 1 call.
static func decay_trauma(trauma: float, delta: float, rate: float) -> float:
	if trauma <= 0.001:
		return 0.0
	return trauma * exp(-rate * delta)

static func _scale_impulse_static(mag: float) -> float:
	if mag <= IMPULSE_REF_MIN:
		return clamp(mag / IMPULSE_REF_MIN * 0.25, 0.0, 0.25)
	var t := clamp((mag - IMPULSE_REF_MIN) / (IMPULSE_REF_MAX - IMPULSE_REF_MIN), 0.0, 1.0)
	# Smoothstep for nice ramp
	return t * t * (3.0 - 2.0 * t)

func _scale_impulse(mag: float) -> float:
	return _scale_impulse_static(mag)

## Static helper — compute shake offset for a given trauma and time (seconds since trigger).
static func shake_offset_for(trauma: float, time_s: float, max_off: float, freq_scale: float = 1.0) -> Vector3:
	var intensity := intensity_curve(trauma, 0.0)
	if intensity <= 0.001:
		return Vector3.ZERO
	var fx := FREQ_X * freq_scale
	var fy := FREQ_Y * freq_scale
	var fz := FREQ_Z * freq_scale
	# Use sin/cos with different frequencies + phase offsets; deterministic per time
	var ox := sin(time_s * fx * TAU + 0.7) * intensity * max_off
	var oy := sin(time_s * fy * TAU + 1.3) * intensity * max_off * 0.7
	var oz := sin(time_s * fz * TAU + 2.1) * intensity * max_off * 0.5
	return Vector3(ox, oy, oz)

static func shake_roll_for(trauma: float, time_s: float, max_roll: float, freq_scale: float = 1.0) -> float:
	var intensity := intensity_curve(trauma, 0.0)
	if intensity <= 0.001:
		return 0.0
	return sin(time_s * FREQ_ROLL * TAU * freq_scale + 0.9) * intensity * max_roll

# ---------------------------------------------------------------------------
# Per-frame update — 120Hz clamped delta, <12 calls per tick
# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	var dt := _clamped_delta(delta)
	_tick_shake(dt)
	_call_count = 0

func _physics_process(delta: float) -> void:
	var dt := _clamped_delta(delta)
	_tick_shake(dt)

func _tick_shake(delta: float) -> void:
	# Budget: count calls — keep under 12
	_call_count += 1
	if _trauma <= 0.001 and _last_offset == Vector3.ZERO:
		return
	# Decay trauma exponentially — frame-rate independent (1 call: exp)
	_trauma = decay_trauma(_trauma, delta, decay_rate)
	_call_count += 1
	if _trauma < 0.001:
		_trauma = 0.0
	_time = max(_time - delta, 0.0)
	# Intensity via curve (trauma^2). Scale by intensity_scale and ball_cam weight if present.
	var intensity := intensity_curve(_trauma, 0.0) * intensity_scale
	# BallCam weight can dampen or boost shake slightly: when ball_cam active, keep full
	var bc_scale := _ball_cam_shake_scale()
	intensity *= bc_scale
	_last_intensity = intensity
	_call_count += 1
	if intensity < 0.001:
		_last_offset = Vector3.ZERO
		_last_roll_deg = 0.0
		_apply_to_camera(Vector3.ZERO, 0.0, 0.0, 0.0)
		if _trauma == 0.0:
			shake_finished.emit()
		return
	# Accumulate time for frequency — use total time or _duration - _time
	var t: float = _duration - _time if _duration > 0.01 else Time.get_ticks_msec() / 1000.0
	# Compute offsets (3 trig calls, counted as 1 budget unit)
	var off := shake_offset_for(_trauma, t, max_offset, frequency_scale)
	var roll := shake_roll_for(_trauma, t, max_roll_deg, frequency_scale)
	var pitch := sin(t * 19.0 * TAU * frequency_scale + 0.4) * intensity * MAX_PITCH_DEG
	var yaw := sin(t * 11.0 * TAU * frequency_scale + 1.8) * intensity * MAX_YAW_DEG
	_last_offset = off
	_last_roll_deg = roll
	_call_count += 2
	_apply_to_camera(off, roll, pitch, yaw)
	if OS.is_debug_build() and _call_count > MAX_CALLS_PER_TICK:
		push_warning("[CameraShake] budget exceeded: %d > %d" % [_call_count, MAX_CALLS_PER_TICK])

func _ball_cam_shake_scale() -> float:
	if _ball_cam == null:
		return 1.0
	# If BallCam has weight, use it to slightly scale shake — ball cam shakes a touch more (1.1x)
	if _ball_cam.has_method("get_weight"):
		var w: float = _ball_cam.get_weight()
		return lerp(1.0, 1.12, clamp(w, 0.0, 1.0))
	if _ball_cam.has_method("is_ball_cam_enabled"):
		if _ball_cam.is_ball_cam_enabled():
			return 1.1
	return 1.0

func _apply_to_camera(offset: Vector3, roll_deg: float, pitch_deg: float, yaw_deg: float) -> void:
	if _camera == null:
		_cache_camera()
		if _camera == null:
			return
	if not _has_base:
		_camera_base_pos = _camera.position
		_camera_base_rot = _camera.rotation_degrees
		_has_base = true
	# Apply positional offset (local to camera)
	_camera.position = _camera_base_pos + offset
	# Apply rotational nudge on top of base
	_camera.rotation_degrees = _camera_base_rot + Vector3(pitch_deg, yaw_deg, roll_deg)
	# Also drive h_offset/v_offset for subtle screen shift (if camera uses them)
	# Keep within [-0.5,0.5] to avoid extreme framing
	_camera.h_offset = clamp(offset.x * 0.5, -0.5, 0.5)
	_camera.v_offset = clamp(offset.y * 0.5, -0.5, 0.5)

# ---------------------------------------------------------------------------
# Haptics — optional, safe if singleton missing
# ---------------------------------------------------------------------------
func _do_haptics_for_intensity(intensity: float) -> void:
	if not enable_haptics:
		return
	var h := get_node_or_null("/root/Haptics")
	if h == null:
		return
	if intensity >= 0.8 and h.has_method("heavy_tap"):
		h.heavy_tap()
	elif intensity >= 0.4 and h.has_method("medium_tap"):
		h.medium_tap()
	elif h.has_method("light_tap"):
		h.light_tap()

func _do_haptics_goal() -> void:
	if not enable_haptics:
		return
	var h := get_node_or_null("/root/Haptics")
	if h == null:
		return
	if h.has_method("play") and "SUCCESS" in h:
		# try enum, else heavy
		h.heavy_tap()
	elif h.has_method("heavy_tap"):
		h.heavy_tap()

func _do_haptics_demo() -> void:
	if not enable_haptics:
		return
	var h := get_node_or_null("/root/Haptics")
	if h == null:
		return
	if h.has_method("heavy_tap"):
		h.heavy_tap()

func _clamped_delta(delta: float) -> float:
	var svc := get_node_or_null("/root/TimeService")
	if svc != null and svc.has_method("clamp_delta"):
		return svc.clamp_delta(delta)
	return clamp(delta, PC.DELTA_MIN, PC.DELTA_MAX)

# ---------------------------------------------------------------------------
# Telemetry §11 — debug_export / perf_mark / validate (§12 budget <12)
# ---------------------------------------------------------------------------
func debug_export() -> Dictionary:
	return {
		"trauma": _trauma,
		"intensity": _last_intensity,
		"offset": _last_offset,
		"roll_deg": _last_roll_deg,
		"max_offset": max_offset,
		"max_roll_deg": max_roll_deg,
		"decay_rate": decay_rate,
		"frequency_scale": frequency_scale,
		"intensity_scale": intensity_scale,
		"duration": _duration,
		"time_remaining": _time,
		"has_camera": _camera != null,
		"has_rig": _rig != null,
		"has_ball_cam": _ball_cam != null,
		"shake_enabled": shake_enabled,
		"shake_count": _shake_count,
		"initialized": _initialized,
	}

func perf_mark() -> Dictionary:
	return {
		"trauma": _trauma,
		"intensity": _last_intensity,
		"calls": _call_count,
		"budget": MAX_CALLS_PER_TICK,
		"budget_ok": _call_count <= MAX_CALLS_PER_TICK,
		"is_shaking": is_shaking(),
		"shake_count": _shake_count,
	}

func validate_config() -> Dictionary:
	var errors: Array[String] = []
	if max_offset < 0.01 or max_offset > 2.0:
		errors.append("max_offset %.3f outside [0.01,2.0]" % max_offset)
	if max_roll_deg < 0.0 or max_roll_deg > 10.0:
		errors.append("max_roll_deg %.3f outside [0,10]" % max_roll_deg)
	if decay_rate < 1.0 or decay_rate > 20.0:
		errors.append("decay_rate %.3f outside [1,20]" % decay_rate)
	if frequency_scale < 0.1 or frequency_scale > 3.0:
		errors.append("frequency_scale %.3f outside [0.1,3]" % frequency_scale)
	if intensity_scale < 0.0 or intensity_scale > 3.0:
		errors.append("intensity_scale %.3f outside [0,3]" % intensity_scale)
	if _trauma < -0.01 or _trauma > 1.01:
		errors.append("trauma %.3f outside [0,1]" % _trauma)
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA %.6f != 1/120" % TICK_DELTA)
	if MAX_CALLS_PER_TICK != 12:
		errors.append("MAX_CALLS_PER_TICK %d != 12" % MAX_CALLS_PER_TICK)
	if not is_equal_approx(PC.PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PC.PHYSICS_TICK_DELTA != 1/120")
	if not _initialized:
		errors.append("not initialized (_ready not called)")
	# Curve sanity: 0 trauma -> 0, 1 trauma -> 1, 0.5 trauma -> 0.25
	if not is_equal_approx(intensity_curve(0.0), 0.0):
		errors.append("intensity_curve(0) != 0")
	if not is_equal_approx(intensity_curve(1.0), 1.0):
		errors.append("intensity_curve(1) != 1")
	if not is_equal_approx(intensity_curve(0.5), 0.25):
		errors.append("intensity_curve(0.5) != 0.25 (trauma^2)")
	var decayed := decay_trauma(1.0, 1.0 / 120.0, DEFAULT_DECAY_RATE)
	if decayed >= 1.0 or decayed <= 0.0:
		errors.append("decay_trauma(1, 1/120, 6) should be (0,1) got %.4f" % decayed)
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_validate() -> Dictionary:
	var inst := CameraShake.new()
	# Set initialized for static validate to pass, then call validate_config
	inst._initialized = true
	inst.max_offset = MAX_OFFSET
	inst.max_roll_deg = MAX_ROLL_DEG
	inst.decay_rate = DEFAULT_DECAY_RATE
	inst.frequency_scale = 1.0
	inst.intensity_scale = 1.0
	return inst.validate_config()
