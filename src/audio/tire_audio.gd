## WS70 — Tire Skid & Impact Audio (budget-aware, deterministic)
## Skid loop driven by WS13 TireFriction slip angle/ratio + speed/grounded.
## Impact one-shot driven by landing vertical velocity / wheel normal load.
## No procedural generation — authored loops at assets/authored/audio_tire/
## Budget: <12 calls per tick, <4 ms, 120 Hz tick. Routes via SFX bus (AudioService).
## Depends on: src/core/constants.gd (WS04), src/game/car/friction.gd (WS13),
##             src/game/car/suspension.gd (WS12), src/game/car/engine.gd (WS14)
## Conventions: docs/architecture/00-conventions.md §3-§5, §8, §12, 1 unit = 1 m, Y-up, +Z forward.
extends RefCounted
class_name TireAudio

const PC = preload("res://src/core/constants.gd")
const FrictionRef = preload("res://src/game/car/friction.gd")
const SuspensionRef = preload("res://src/game/car/suspension.gd")
const EngineRef = preload("res://src/game/car/engine.gd")

# ---------------------------------------------------------------------------
# Authored audio constants — single source for WS70
# ---------------------------------------------------------------------------

## Authored skid loop asset (deterministic, committed).
const SKID_AUDIO_PATH: String = "res://assets/authored/audio_tire/audio_tire_skid_a_v01.ogg"
const IMPACT_AUDIO_PATH: String = "res://assets/authored/audio_tire/audio_tire_impact_a_v01.ogg"
const AUDIO_PATH: String = SKID_AUDIO_PATH
const AUTHORED_SKID_NAME: String = "audio_tire_skid_a_v01.ogg"
const AUTHORED_IMPACT_NAME: String = "audio_tire_impact_a_v01.ogg"

## Audio bus — all tire SFX through SFX (conventions §8: Master -> [Music, SFX, Crowd, UI]).
const AUDIO_BUS: String = "SFX"
const BUS_SFX: String = "SFX"

## Skid volume mapping (dB): 0 intensity -> silent, 1.0 -> max. Uses linear_to_db style clamp.
const VOLUME_MIN_DB: float = -30.0
const VOLUME_MAX_DB: float = -2.0
const VOLUME_SILENT_DB: float = -80.0
const SKID_VOLUME_RANGE_DB: float = VOLUME_MAX_DB - VOLUME_MIN_DB  # 28 dB

## Skid pitch mapping: low intensity -> 0.85, high -> 1.35. Speed adds slight bias.
const PITCH_MIN: float = 0.85
const PITCH_MAX: float = 1.35
const PITCH_SPEED_BIAS: float = 0.12

## Impact volume (dB): soft -> -18, hard -> 0.
const IMPACT_VOLUME_MIN_DB: float = -18.0
const IMPACT_VOLUME_MAX_DB: float = 0.0
const IMPACT_PITCH_MIN: float = 0.9
const IMPACT_PITCH_MAX: float = 1.25

## Friction thresholds — must match WS13 Friction + WS62 TireSmoke for consistency.
const SLIP_ANGLE_PEAK_RAD: float = 0.21  # FrictionRef.SLIP_ANGLE_PEAK_RAD
const SLIP_RATIO_PEAK: float = 0.15  # FrictionRef.SLIP_RATIO_PEAK
const LATERAL_THRESHOLD_RAD: float = 0.147  # 0.7 * 0.21
const LONGITUDINAL_THRESHOLD: float = 0.105  # 0.7 * 0.15
const DRIFT_SLIP_ANGLE_RAD: float = SLIP_ANGLE_PEAK_RAD
const DRIFT_SLIP_RATIO: float = SLIP_RATIO_PEAK
const SKID_SPEED_MIN: float = 2.5  # m/s — below this no audible skid (parked)
const IMPACT_SPEED_MIN: float = 1.5  # m/s vertical for impact
const IMPACT_SPEED_FULL: float = 8.0  # m/s vertical for max impact volume

## Smoothing — attack/release rates (1/s) for skid volume/pitch lerp.
const AUDIO_ATTACK_RATE: float = 14.0
const AUDIO_RELEASE_RATE: float = 8.0
const SMOOTH_ATTACK: float = AUDIO_ATTACK_RATE
const SMOOTH_RELEASE: float = AUDIO_RELEASE_RATE
const SKID_FADE_TIME: float = 0.12  # seconds to fade when drift stops

## Physics tick — must be 120 Hz (validated against PC + FrictionRef).
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_DELTA: float = PHYSICS_TICK_DELTA
const TICK_HZ: int = 120

## Budget awareness — <12 calls per tick (conventions §12).
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK
const MAX_AUDIO_CALLS: int = MAX_CALLS_PER_TICK
const DRAW_CALL_BUDGET: int = 12

## Wheel geometry — mirrors Suspension.WHEEL_OFFSETS / Friction.
const WHEEL_COUNT: int = 4
const NUM_WHEELS: int = 4
const WHEEL_RADIUS: float = 0.35

## Impact cooldown to avoid spam (s).
const IMPACT_COOLDOWN: float = 0.14

# ---------------------------------------------------------------------------
# Instance state — per-car, budget-aware (no alloc per tick beyond these fields)
# ---------------------------------------------------------------------------

var _skid_intensity: float = 0.0
var _skid_intensity_smoothed: float = 0.0
var _volume_db: float = VOLUME_SILENT_DB
var _pitch: float = PITCH_MIN
var _is_skidding: bool = false
var _impact_cooldown_remaining: float = 0.0
var _call_count_last_tick: int = 0
var _is_playing: bool = false
var _tick_count: int = 0

# ---------------------------------------------------------------------------
# Core mapping — static, pure math, budget-aware (no AudioService call)
# ---------------------------------------------------------------------------

static func is_skid_slip(slip_angle_rad: float, slip_ratio: float) -> bool:
	return absf(slip_angle_rad) > LATERAL_THRESHOLD_RAD or absf(slip_ratio) > LONGITUDINAL_THRESHOLD

static func skid_factor(slip_angle_rad: float, slip_ratio: float) -> float:
	var lat := clamp(absf(slip_angle_rad) / SLIP_ANGLE_PEAK_RAD, 0.0, 1.5)
	var lon := clamp(absf(slip_ratio) / SLIP_RATIO_PEAK, 0.0, 1.5)
	return clamp(max(lat, lon), 0.0, 1.0)

static func compute_skid_intensity(slip_angle_rad: float, slip_ratio: float, speed: float, grounded: bool) -> float:
	if not grounded:
		return 0.0
	if speed < SKID_SPEED_MIN:
		return 0.0
	if not is_skid_slip(slip_angle_rad, slip_ratio):
		return 0.0
	var f := skid_factor(slip_angle_rad, slip_ratio)
	var speed_t := clamp((speed - SKID_SPEED_MIN) / 5.0, 0.0, 1.0)
	var speed_scale := lerpf(0.35, 1.0, speed_t)
	return clamp(f * speed_scale, 0.0, 1.0)

static func is_skidding(slip_angle_rad: float, slip_ratio: float, speed: float, grounded: bool) -> bool:
	return compute_skid_intensity(slip_angle_rad, slip_ratio, speed, grounded) > 0.05

static func skid_volume_db(intensity: float) -> float:
	var i := clamp(intensity, 0.0, 1.0)
	if i < 0.05:
		return VOLUME_SILENT_DB
	return clamp(VOLUME_MIN_DB + i * SKID_VOLUME_RANGE_DB, VOLUME_MIN_DB, VOLUME_MAX_DB)

static func skid_pitch(intensity: float, speed: float = 0.0) -> float:
	var i := clamp(intensity, 0.0, 1.0)
	var base := lerp(PITCH_MIN, PITCH_MAX, i)
	var speed_bias := clamp(speed / EngineRef.MAX_SPEED_FORWARD, 0.0, 1.0) * PITCH_SPEED_BIAS if EngineRef.MAX_SPEED_FORWARD > 0 else 0.0
	return clamp(base + speed_bias, 0.5, 2.5)

static func impact_intensity(vertical_speed: float, normal_load: float = FrictionRef.NOMINAL_LOAD) -> float:
	var v := absf(vertical_speed)
	if v < IMPACT_SPEED_MIN:
		return 0.0
	var t := clamp((v - IMPACT_SPEED_MIN) / (IMPACT_SPEED_FULL - IMPACT_SPEED_MIN), 0.0, 1.0)
	var load_scale := clamp(normal_load / FrictionRef.NOMINAL_LOAD, 0.5, 2.0)
	# Load slightly boosts impact (heavier landing louder)
	return clamp(t * lerpf(0.8, 1.0, clamp((load_scale - 0.5) / 1.5, 0.0, 1.0)), 0.0, 1.0)

static func impact_volume_db(intensity: float) -> float:
	var i := clamp(intensity, 0.0, 1.0)
	if i < 0.05:
		return VOLUME_SILENT_DB
	return clamp(IMPACT_VOLUME_MIN_DB + i * (IMPACT_VOLUME_MAX_DB - IMPACT_VOLUME_MIN_DB), IMPACT_VOLUME_MIN_DB, IMPACT_VOLUME_MAX_DB)

static func impact_pitch(intensity: float) -> float:
	var i := clamp(intensity, 0.0, 1.0)
	return clamp(lerp(IMPACT_PITCH_MIN, IMPACT_PITCH_MAX, i), 0.5, 2.5)

static func audio_params_for_skid(slip_angle_rad: float, slip_ratio: float, speed: float, grounded: bool) -> Dictionary:
	var inten := compute_skid_intensity(slip_angle_rad, slip_ratio, speed, grounded)
	var vol := skid_volume_db(inten)
	var pitch := skid_pitch(inten, speed)
	return {"intensity": inten, "volume_db": vol, "pitch": pitch, "pitch_scale": pitch, "bus": AUDIO_BUS, "is_skidding": inten > 0.05}

static func audio_params_for_impact(vertical_speed: float, normal_load: float = FrictionRef.NOMINAL_LOAD) -> Dictionary:
	var inten := impact_intensity(vertical_speed, normal_load)
	var vol := impact_volume_db(inten)
	var pitch := impact_pitch(inten)
	return {"intensity": inten, "volume_db": vol, "pitch": pitch, "pitch_scale": pitch, "bus": AUDIO_BUS, "should_play": inten > 0.05}

static func evaluate_wheels(chassis_vel: Vector3, chassis_transform: Transform3D, suspension, throttle: float = 0.0, steer_angle: float = 0.0) -> Dictionary:
	var intensities: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var speed := chassis_vel.length()
	var fwd: Vector3 = -chassis_transform.basis.z.normalized()
	var right: Vector3 = chassis_transform.basis.x.normalized()
	var v_fwd: float = chassis_vel.dot(fwd)
	var v_lat: float = chassis_vel.dot(right)
	var base_angle: float = FrictionRef.slip_angle(v_lat, v_fwd)
	var base_ratio: float = FrictionRef.slip_ratio_from_throttle(throttle, speed)
	for i in range(WHEEL_COUNT):
		var grounded: bool = true
		if suspension != null and i < suspension.wheel_contact.size():
			grounded = suspension.wheel_contact[i]
		var is_front: bool = i < 2
		var slip_a: float = base_angle + (steer_angle if is_front else 0.0)
		var slip_r: float = base_ratio * (1.2 if not is_front else 1.0)
		intensities[i] = compute_skid_intensity(slip_a, slip_r, speed, grounded)
	var any_skid := false
	var max_i := 0.0
	for v in intensities:
		if v > 0.05:
			any_skid = true
		if v > max_i:
			max_i = v
	return {"intensities": intensities, "any_skid": any_skid, "max_intensity": max_i, "any_drift": any_skid}

static func tick_skid_state(slip_angles: Array[float], slip_ratios: Array[float], speed: float, grounded: Array[bool], delta: float, prev_intensity: float) -> Dictionary:
	var max_i := 0.0
	var any := false
	for i in range(min(slip_angles.size(), slip_ratios.size())):
		var g: bool = grounded[i] if i < grounded.size() else true
		var inten := compute_skid_intensity(float(slip_angles[i]), float(slip_ratios[i]), speed, g)
		if inten > max_i:
			max_i = inten
		if inten > 0.05:
			any = true
	var inten_out: float = max_i if any else max(prev_intensity - delta / SKID_FADE_TIME, 0.0)
	return {"is_skidding": inten_out > 0.05, "intensity": inten_out, "any_skid": any, "max_intensity": max_i, "volume_db": skid_volume_db(inten_out), "pitch": skid_pitch(inten_out, speed)}

static func smooth_value(current: float, target: float, delta: float, is_attacking: bool = true) -> float:
	var rate := AUDIO_ATTACK_RATE if is_attacking else AUDIO_RELEASE_RATE
	var alpha := 1.0 - exp(-rate * delta)
	return lerp(current, target, alpha)

# ---------------------------------------------------------------------------
# Instance update — call once per physics tick (<12 calls)
# ---------------------------------------------------------------------------

func update(slip_angle_rad: float, slip_ratio: float, speed: float, grounded: bool, delta: float) -> Dictionary:
	_call_count_last_tick = 1
	_tick_count += 1
	if _impact_cooldown_remaining > 0.0:
		_impact_cooldown_remaining = max(_impact_cooldown_remaining - delta, 0.0)
	var target := TireAudio.compute_skid_intensity(slip_angle_rad, slip_ratio, speed, grounded)
	var is_attacking := target > _skid_intensity_smoothed
	_skid_intensity_smoothed = TireAudio.smooth_value(_skid_intensity_smoothed, target, delta, is_attacking)
	_skid_intensity = target
	_is_skidding = _skid_intensity_smoothed > 0.05
	_volume_db = TireAudio.skid_volume_db(_skid_intensity_smoothed)
	_pitch = TireAudio.skid_pitch(_skid_intensity_smoothed, speed)
	return {"intensity": _skid_intensity_smoothed, "raw_intensity": _skid_intensity, "volume_db": _volume_db, "pitch": _pitch, "pitch_scale": _pitch, "is_skidding": _is_skidding, "bus": AUDIO_BUS}

func physics_tick(car: RigidBody3D, suspension, throttle: float, steer_angle: float, delta: float) -> Dictionary:
	_call_count_last_tick = 0
	_tick_count += 1
	if _impact_cooldown_remaining > 0.0:
		_impact_cooldown_remaining = max(_impact_cooldown_remaining - delta, 0.0)
	if car == null:
		_skid_intensity = max(_skid_intensity - delta / SKID_FADE_TIME, 0.0)
		_skid_intensity_smoothed = max(_skid_intensity_smoothed - delta / SKID_FADE_TIME, 0.0)
		_is_skidding = _skid_intensity_smoothed > 0.05
		_volume_db = TireAudio.skid_volume_db(_skid_intensity_smoothed)
		_pitch = TireAudio.skid_pitch(_skid_intensity_smoothed, 0.0)
		_call_count_last_tick = 2
		return {"intensity": _skid_intensity_smoothed, "volume_db": _volume_db, "pitch": _pitch, "is_skidding": _is_skidding}
	var vel: Vector3 = car.linear_velocity
	var tr: Transform3D = car.global_transform
	var speed: float = vel.length()
	_call_count_last_tick += 2
	var eval_result := TireAudio.evaluate_wheels(vel, tr, suspension, throttle, steer_angle)
	_call_count_last_tick += 1
	var max_inten: float = eval_result["max_intensity"] as float
	var any_skid: bool = eval_result["any_skid"] as bool
	var target: float = max_inten if any_skid else 0.0
	var is_attacking := target > _skid_intensity_smoothed
	_skid_intensity_smoothed = TireAudio.smooth_value(_skid_intensity_smoothed, target, delta, is_attacking)
	_skid_intensity = max_inten
	_is_skidding = _skid_intensity_smoothed > 0.05
	_volume_db = TireAudio.skid_volume_db(_skid_intensity_smoothed)
	_pitch = TireAudio.skid_pitch(_skid_intensity_smoothed, speed)
	_call_count_last_tick += 3
	if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
		push_warning("[TireAudio] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
	return {"intensity": _skid_intensity_smoothed, "raw_intensity": _skid_intensity, "volume_db": _volume_db, "pitch": _pitch, "pitch_scale": _pitch, "is_skidding": _is_skidding, "bus": AUDIO_BUS, "any_skid": any_skid}

func trigger_impact(vertical_speed: float, normal_load: float = FrictionRef.NOMINAL_LOAD) -> Dictionary:
	if _impact_cooldown_remaining > 0.0:
		return {"played": false, "cooldown": _impact_cooldown_remaining, "intensity": 0.0}
	var params := TireAudio.audio_params_for_impact(vertical_speed, normal_load)
	var should: bool = params["should_play"] as bool
	if not should:
		return {"played": false, "intensity": params["intensity"] as float, "volume_db": params["volume_db"] as float}
	_impact_cooldown_remaining = IMPACT_COOLDOWN
	return {"played": true, "intensity": params["intensity"] as float, "volume_db": params["volume_db"] as float, "pitch": params["pitch"] as float, "pitch_scale": params["pitch"] as float, "bus": AUDIO_BUS}

func get_skid_intensity() -> float:
	return _skid_intensity_smoothed

func get_volume_db() -> float:
	return _volume_db

func get_pitch() -> float:
	return _pitch

func is_skidding_now() -> bool:
	return _is_skidding

func is_playing() -> bool:
	return _is_playing

func set_playing(v: bool) -> void:
	_is_playing = v

func reset() -> void:
	_skid_intensity = 0.0
	_skid_intensity_smoothed = 0.0
	_volume_db = VOLUME_SILENT_DB
	_pitch = PITCH_MIN
	_is_skidding = false
	_impact_cooldown_remaining = 0.0
	_is_playing = false
	_call_count_last_tick = 0

func get_call_count() -> int:
	return _call_count_last_tick

# ---------------------------------------------------------------------------
# Attachment helper — attach tire audio to car node (Node3D)
# ---------------------------------------------------------------------------

static func create_player(car_node: Node = null) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.name = "TireAudio"
	player.bus = AUDIO_BUS
	player.pitch_scale = PITCH_MIN
	player.volume_db = VOLUME_SILENT_DB
	player.autoplay = false
	player.max_distance = 30.0
	player.unit_size = 4.0
	if ResourceLoader.exists(SKID_AUDIO_PATH):
		var stream: Resource = load(SKID_AUDIO_PATH)
		if stream is AudioStream:
			player.stream = stream as AudioStream
	return player

static func create_impact_player(car_node: Node = null) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.name = "TireImpactAudio"
	player.bus = AUDIO_BUS
	player.pitch_scale = IMPACT_PITCH_MIN
	player.volume_db = VOLUME_SILENT_DB
	player.autoplay = false
	player.max_distance = 35.0
	player.unit_size = 5.0
	if ResourceLoader.exists(IMPACT_AUDIO_PATH):
		var stream: Resource = load(IMPACT_AUDIO_PATH)
		if stream is AudioStream:
			player.stream = stream as AudioStream
	return player

static func attach_to_car(car_node: Node3D) -> AudioStreamPlayer3D:
	if car_node == null:
		return create_player(null)
	var existing := car_node.get_node_or_null("TireAudio") as AudioStreamPlayer3D
	if existing != null:
		return existing
	var p := create_player(car_node)
	car_node.add_child(p)
	return p

static func attach_impact_to_car(car_node: Node3D) -> AudioStreamPlayer3D:
	if car_node == null:
		return create_impact_player(null)
	var existing := car_node.get_node_or_null("TireImpactAudio") as AudioStreamPlayer3D
	if existing != null:
		return existing
	var p := create_impact_player(car_node)
	car_node.add_child(p)
	return p

static func apply_to_player(player: AudioStreamPlayer3D, pitch: float, volume_db: float, is_skidding: bool = true) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.pitch_scale = clamp(pitch, 0.5, 2.5)
	player.volume_db = clamp(volume_db, -80.0, 6.0)
	if is_skidding:
		if not player.playing:
			player.play()
	else:
		if player.playing:
			player.stop()

static func apply_impact_to_player(player: AudioStreamPlayer3D, pitch: float, volume_db: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.pitch_scale = clamp(pitch, 0.5, 2.5)
	player.volume_db = clamp(volume_db, -40.0, 6.0)
	if not player.playing:
		player.play()

# ---------------------------------------------------------------------------
# Validation & telemetry — conventions §11 — budget-aware (<4ms physics)
# ---------------------------------------------------------------------------

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA != 1/120")
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA != 1/120")
	if TICK_HZ != 120:
		errors.append("TICK_HZ %d != 120" % TICK_HZ)
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(FrictionRef.SLIP_ANGLE_PEAK_RAD, SLIP_ANGLE_PEAK_RAD):
		errors.append("SLIP_ANGLE_PEAK_RAD %.3f != Friction %.3f" % [SLIP_ANGLE_PEAK_RAD, FrictionRef.SLIP_ANGLE_PEAK_RAD])
	if not is_equal_approx(FrictionRef.SLIP_RATIO_PEAK, SLIP_RATIO_PEAK):
		errors.append("SLIP_RATIO_PEAK %.3f != Friction %.3f" % [SLIP_RATIO_PEAK, FrictionRef.SLIP_RATIO_PEAK])
	if MAX_CALLS_PER_TICK != 12:
		errors.append("MAX_CALLS_PER_TICK %d != 12" % MAX_CALLS_PER_TICK)
	if BUDGET_CALLS != 12:
		errors.append("BUDGET_CALLS %d != 12" % BUDGET_CALLS)
	if AUDIO_BUS != "SFX":
		errors.append("AUDIO_BUS %s != SFX" % AUDIO_BUS)
	if not SKID_AUDIO_PATH.begins_with("res://assets/authored/audio_tire/"):
		errors.append("SKID_AUDIO_PATH must be under assets/authored/audio_tire/")
	if not SKID_AUDIO_PATH.ends_with(".ogg"):
		errors.append("SKID_AUDIO_PATH must be .ogg")
	if not IMPACT_AUDIO_PATH.begins_with("res://assets/authored/audio_tire/"):
		errors.append("IMPACT_AUDIO_PATH must be under assets/authored/audio_tire/")
	if not IMPACT_AUDIO_PATH.ends_with(".ogg"):
		errors.append("IMPACT_AUDIO_PATH must be .ogg")
	if PITCH_MIN >= PITCH_MAX:
		errors.append("PITCH_MIN >= PITCH_MAX")
	if VOLUME_MIN_DB >= VOLUME_MAX_DB:
		errors.append("VOLUME_MIN_DB >= VOLUME_MAX_DB")
	if not is_equal_approx(LATERAL_THRESHOLD_RAD, 0.147):
		errors.append("LATERAL_THRESHOLD_RAD %.3f != 0.147" % LATERAL_THRESHOLD_RAD)
	if not is_equal_approx(LONGITUDINAL_THRESHOLD, 0.105):
		errors.append("LONGITUDINAL_THRESHOLD %.3f != 0.105" % LONGITUDINAL_THRESHOLD)
	# functional checks
	var vol_silent := skid_volume_db(0.0)
	if not is_equal_approx(vol_silent, VOLUME_SILENT_DB):
		errors.append("skid_volume_db(0) %.1f != silent" % vol_silent)
	var vol_full := skid_volume_db(1.0)
	if not is_equal_approx(vol_full, VOLUME_MAX_DB):
		errors.append("skid_volume_db(1) %.1f != max" % vol_full)
	var p_low := skid_pitch(0.0, 0.0)
	if not is_equal_approx(p_low, PITCH_MIN):
		errors.append("skid_pitch(0) %.3f != PITCH_MIN" % p_low)
	var p_high := skid_pitch(1.0, 0.0)
	if not is_equal_approx(p_high, PITCH_MAX):
		errors.append("skid_pitch(1) %.3f != PITCH_MAX" % p_high)
	var i_low := compute_skid_intensity(0.0, 0.0, 10.0, true)
	if not is_equal_approx(i_low, 0.0):
		errors.append("compute_skid(0,0) should be 0")
	var i_air := compute_skid_intensity(0.5, 0.5, 10.0, false)
	if not is_equal_approx(i_air, 0.0):
		errors.append("compute_skid airborne should be 0")
	var i_slow := compute_skid_intensity(0.5, 0.5, 0.0, true)
	if not is_equal_approx(i_slow, 0.0):
		errors.append("compute_skid slow should be 0")
	var i_drift := compute_skid_intensity(0.5, 0.0, 10.0, true)
	if i_drift <= 0.05:
		errors.append("compute_skid drift should be >0.05 got %.3f" % i_drift)
	var imp_low := impact_intensity(0.0)
	if not is_equal_approx(imp_low, 0.0):
		errors.append("impact 0 should be 0")
	var imp_high := impact_intensity(10.0, FrictionRef.NOMINAL_LOAD)
	if imp_high < 0.9:
		errors.append("impact 10 should be ~1 got %.3f" % imp_high)
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_validate_static() -> Dictionary:
	return debug_validate()

static func debug_export() -> Dictionary:
	return {
		"skid_audio_path": SKID_AUDIO_PATH,
		"impact_audio_path": IMPACT_AUDIO_PATH,
		"audio_path": AUDIO_PATH,
		"audio_bus": AUDIO_BUS,
		"pitch_min": PITCH_MIN,
		"pitch_max": PITCH_MAX,
		"volume_min_db": VOLUME_MIN_DB,
		"volume_max_db": VOLUME_MAX_DB,
		"slip_angle_peak": SLIP_ANGLE_PEAK_RAD,
		"slip_ratio_peak": SLIP_RATIO_PEAK,
		"lateral_threshold": LATERAL_THRESHOLD_RAD,
		"longitudinal_threshold": LONGITUDINAL_THRESHOLD,
		"physics_ticks": PHYSICS_TICKS_PER_SECOND,
		"budget_calls": BUDGET_CALLS,
	}

static func perf_mark() -> Dictionary:
	return {"budget_calls": BUDGET_CALLS, "max_calls_per_tick": MAX_CALLS_PER_TICK, "tick_hz": TICK_HZ, "tick_delta": TICK_DELTA}
