## WS69 — Engine & Acceleration Audio (budget-aware, deterministic)
## Engine loop driven by WS14 CarEngine throttle, RPM-mapped pitch.
## No procedural generation — authored loop at assets/authored/audio_engine/audio_engine_loop_a_v01.ogg
## Budget: <12 calls per tick, <4 ms, 120 Hz tick. Routes via SFX bus (AudioService).
## Depends on: src/core/constants.gd (WS04), src/game/car/engine.gd (WS14)
## Conventions: docs/architecture/00-conventions.md §3-§5, §8, §12, 1 unit = 1 m, Y-up, +Z forward.
extends RefCounted
class_name EngineAudio

const PC = preload("res://src/core/constants.gd")
const EngineRef = preload("res://src/game/car/engine.gd")

# ---------------------------------------------------------------------------
# Authored audio constants — single source for WS69
# ---------------------------------------------------------------------------

## Authored engine loop asset (deterministic, committed).
const ENGINE_AUDIO_PATH: String = "res://assets/authored/audio_engine/audio_engine_loop_a_v01.ogg"
const AUDIO_PATH: String = ENGINE_AUDIO_PATH
const AUTHORED_AUDIO_NAME: String = "audio_engine_loop_a_v01.ogg"

## Audio bus — all engine SFX through SFX (conventions §8: Master -> [Music, SFX, Crowd, UI]).
const AUDIO_BUS: String = "SFX"
const BUS_SFX: String = "SFX"

## Pitch mapping: idle -> max engine speed maps pitch_scale 0.85 -> 1.8
const PITCH_IDLE: float = 0.85
const PITCH_MAX: float = 1.8
const PITCH_REVERSE_FACTOR: float = 0.92
const PITCH_BOOST_BIAS: float = 0.12

## Volume mapping (dB): linear 0..1 -> dB via linear_to_db, clamped.
const VOLUME_MIN_DB: float = -18.0
const VOLUME_MAX_DB: float = 0.0
const VOLUME_IDLE_DB: float = -10.0
const VOLUME_THROTTLE_GAIN_DB: float = 8.0

## RPM model — authored idle/max RPM for pitch interpolation (no procedural synth).
const RPM_IDLE: float = 900.0
const RPM_MAX: float = 6500.0
const RPM_REDLINE: float = 7000.0

## Throttle smoothing — attack/release rates (1/s) for audio pitch/volume lerp.
const AUDIO_ATTACK_RATE: float = 10.0
const AUDIO_RELEASE_RATE: float = 6.0
const SMOOTH_ATTACK: float = AUDIO_ATTACK_RATE
const SMOOTH_RELEASE: float = AUDIO_RELEASE_RATE

## Deadzone — reuse EngineRef deadzone so audio silence matches drive deadzone.
const THROTTLE_DEADZONE: float = 0.02

## Physics tick — must be 120 Hz (validated against PC + EngineRef).
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_DELTA: float = PHYSICS_TICK_DELTA
const TICK_HZ: int = 120

## Budget awareness — <12 calls per tick (conventions §12).
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK
const MAX_AUDIO_CALLS: int = MAX_CALLS_PER_TICK
const DRAW_CALL_BUDGET: int = 12

# ---------------------------------------------------------------------------
# Instance state — per-car, budget-aware (no alloc per tick beyond these fields)
# ---------------------------------------------------------------------------

var _pitch: float = PITCH_IDLE
var _volume_db: float = VOLUME_IDLE_DB
var _rpm: float = RPM_IDLE
var _throttle_smoothed: float = 0.0
var _call_count_last_tick: int = 0
var _is_playing: bool = false

# ---------------------------------------------------------------------------
# Core mapping — static, pure math, budget-aware (no AudioService call)
# ---------------------------------------------------------------------------

static func rpm_for_throttle_speed(throttle: float, speed_ratio: float) -> float:
	var t := clamp(absf(throttle), 0.0, 1.0)
	var r := clamp(speed_ratio, 0.0, 1.15)
	var blend := t * 0.6 + r * 0.4
	return lerp(RPM_IDLE, RPM_MAX, clamp(blend, 0.0, 1.0))

static func pitch_for_rpm(rpm: float) -> float:
	var norm := clamp((rpm - RPM_IDLE) / (RPM_MAX - RPM_IDLE), 0.0, 1.0)
	return lerp(PITCH_IDLE, PITCH_MAX, norm)

static func pitch_for_speed(throttle: float, speed_abs: float, is_reverse: bool = false, is_boosting: bool = false) -> float:
	var max_s := EngineRef.MAX_SPEED_REVERSE if is_reverse else (EngineRef.MAX_SPEED_BOOST if is_boosting else EngineRef.MAX_SPEED_FORWARD)
	if max_s <= 0.0:
		return PITCH_IDLE
	var ratio := clamp(speed_abs / max_s, 0.0, 1.15)
	var rpm := rpm_for_throttle_speed(throttle, ratio)
	var p := pitch_for_rpm(rpm)
	if is_reverse:
		p *= PITCH_REVERSE_FACTOR
	if is_boosting:
		p += PITCH_BOOST_BIAS * clamp(absf(throttle), 0.0, 1.0)
	return clamp(p, PITCH_IDLE * 0.9, PITCH_MAX + 0.2)

## Alias: pitch derived directly from throttle WS14 + speed, used by attach helpers.
static func pitch_for_throttle(throttle: float, speed_abs: float = 0.0, is_reverse: bool = false, is_boosting: bool = false) -> float:
	return pitch_for_speed(throttle, speed_abs, is_reverse, is_boosting)

static func volume_db_for_throttle(throttle: float) -> float:
	var t := clamp(absf(throttle), 0.0, 1.0)
	if t < THROTTLE_DEADZONE:
		return VOLUME_IDLE_DB
	return clamp(VOLUME_IDLE_DB + t * VOLUME_THROTTLE_GAIN_DB, VOLUME_MIN_DB, VOLUME_MAX_DB)

static func audio_params(throttle: float, speed_abs: float, is_reverse: bool = false, is_boosting: bool = false) -> Dictionary:
	var pitch := pitch_for_speed(throttle, speed_abs, is_reverse, is_boosting)
	var vol := volume_db_for_throttle(throttle)
	var rpm := rpm_for_throttle_speed(throttle, clamp(speed_abs / EngineRef.MAX_SPEED_FORWARD, 0.0, 1.15) if EngineRef.MAX_SPEED_FORWARD > 0 else 0.0)
	return {"pitch": pitch, "pitch_scale": pitch, "volume_db": vol, "rpm": rpm, "bus": AUDIO_BUS}

static func smooth_pitch(current: float, target: float, delta: float, is_attacking: bool = true) -> float:
	var rate := AUDIO_ATTACK_RATE if is_attacking else AUDIO_RELEASE_RATE
	var alpha := 1.0 - exp(-rate * delta)
	return lerp(current, target, alpha)

# ---------------------------------------------------------------------------
# Instance update — call once per physics tick (<12 calls)
# ---------------------------------------------------------------------------

func update(throttle: float, speed_abs: float, delta: float, is_reverse: bool = false, is_boosting: bool = false) -> Dictionary:
	_call_count_last_tick = 1
	var t := clamp(throttle, -1.0, 1.0)
	var target_pitch := EngineAudio.pitch_for_speed(t, speed_abs, is_reverse, is_boosting)
	var is_attacking := target_pitch > _pitch
	_pitch = EngineAudio.smooth_pitch(_pitch, target_pitch, delta, is_attacking)
	_volume_db = EngineAudio.volume_db_for_throttle(t)
	var ratio := clamp(speed_abs / EngineRef.MAX_SPEED_FORWARD, 0.0, 1.15) if EngineRef.MAX_SPEED_FORWARD > 0 else 0.0
	_rpm = EngineAudio.rpm_for_throttle_speed(t, ratio)
	var rate := AUDIO_ATTACK_RATE if absf(t) > absf(_throttle_smoothed) else AUDIO_RELEASE_RATE
	var alpha := 1.0 - exp(-rate * delta)
	_throttle_smoothed = lerp(_throttle_smoothed, t, alpha)
	return {"pitch": _pitch, "pitch_scale": _pitch, "volume_db": _volume_db, "rpm": _rpm, "throttle_smoothed": _throttle_smoothed, "bus": AUDIO_BUS}

func get_pitch() -> float:
	return _pitch

func get_volume_db() -> float:
	return _volume_db

func get_rpm() -> float:
	return _rpm

func is_playing() -> bool:
	return _is_playing

func set_playing(v: bool) -> void:
	_is_playing = v

func reset() -> void:
	_pitch = PITCH_IDLE
	_volume_db = VOLUME_IDLE_DB
	_rpm = RPM_IDLE
	_throttle_smoothed = 0.0
	_is_playing = false
	_call_count_last_tick = 0

# ---------------------------------------------------------------------------
# Attachment helper — attach engine audio to car node (Node3D)
# ---------------------------------------------------------------------------

static func create_player(car_node: Node = null) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.name = "EngineAudio"
	player.bus = AUDIO_BUS
	player.pitch_scale = PITCH_IDLE
	player.volume_db = VOLUME_IDLE_DB
	player.autoplay = false
	player.max_distance = 40.0
	player.unit_size = 6.0
	if ResourceLoader.exists(ENGINE_AUDIO_PATH):
		var stream: Resource = load(ENGINE_AUDIO_PATH)
		if stream is AudioStream:
			player.stream = stream as AudioStream
	return player

static func attach_to_car(car_node: Node3D) -> AudioStreamPlayer3D:
	if car_node == null:
		return create_player(null)
	var existing := car_node.get_node_or_null("EngineAudio") as AudioStreamPlayer3D
	if existing != null:
		return existing
	# Also check legacy CarAudio node for compat
	var legacy := car_node.get_node_or_null("CarEngineAudio") as AudioStreamPlayer3D
	if legacy != null:
		return legacy
	var p := create_player(car_node)
	car_node.add_child(p)
	return p

static func apply_to_player(player: AudioStreamPlayer3D, pitch: float, volume_db: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.pitch_scale = clamp(pitch, 0.5, 2.5)
	player.volume_db = clamp(volume_db, -40.0, 6.0)
	if not player.playing:
		player.play()

static func get_engine_max_speed() -> float:
	return EngineRef.MAX_SPEED_FORWARD

# ---------------------------------------------------------------------------
# WS14 integration — throttle -> pitch/RPM convenience (reads InputService via CarEngine)
# ---------------------------------------------------------------------------

static func pitch_from_input_service(speed_abs: float = 0.0, is_boosting: bool = false) -> float:
	var t := EngineRef.get_throttle_from_input_service()
	var is_rev := t < 0.0
	return pitch_for_speed(t, speed_abs, is_rev, is_boosting)

static func rpm_from_input_service(speed_abs: float = 0.0) -> float:
	var t := EngineRef.get_throttle_from_input_service()
	var ratio := clamp(speed_abs / EngineRef.MAX_SPEED_FORWARD, 0.0, 1.15) if EngineRef.MAX_SPEED_FORWARD > 0 else 0.0
	return rpm_for_throttle_speed(t, ratio)

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
	if EngineRef.MAX_SPEED_FORWARD != 28.0:
		errors.append("Engine MAX_SPEED_FORWARD %.1f != 28.0" % EngineRef.MAX_SPEED_FORWARD)
	if MAX_CALLS_PER_TICK != 12:
		errors.append("MAX_CALLS_PER_TICK %d != 12" % MAX_CALLS_PER_TICK)
	if BUDGET_CALLS != 12:
		errors.append("BUDGET_CALLS %d != 12" % BUDGET_CALLS)
	if AUDIO_BUS != "SFX":
		errors.append("AUDIO_BUS %s != SFX" % AUDIO_BUS)
	if not ENGINE_AUDIO_PATH.begins_with("res://assets/authored/audio_engine/"):
		errors.append("ENGINE_AUDIO_PATH must be under assets/authored/audio_engine/")
	if not ENGINE_AUDIO_PATH.ends_with(".ogg"):
		errors.append("ENGINE_AUDIO_PATH must be .ogg")
	if PITCH_IDLE >= PITCH_MAX:
		errors.append("PITCH_IDLE >= PITCH_MAX")
	if VOLUME_MIN_DB >= VOLUME_MAX_DB:
		errors.append("VOLUME_MIN_DB >= VOLUME_MAX_DB")
	if RPM_IDLE >= RPM_MAX:
		errors.append("RPM_IDLE >= RPM_MAX")
	if RPM_MAX >= RPM_REDLINE:
		errors.append("RPM_MAX must be < REDLINE")
	var p_idle := pitch_for_speed(0.0, 0.0)
	if not is_equal_approx(p_idle, PITCH_IDLE):
		errors.append("pitch_for_speed(0,0) %.3f != PITCH_IDLE" % p_idle)
	var p_full := pitch_for_speed(1.0, 28.0)
	if p_full <= PITCH_IDLE:
		errors.append("pitch full must be > idle")
	var v_idle := volume_db_for_throttle(0.0)
	if not is_equal_approx(v_idle, VOLUME_IDLE_DB):
		errors.append("volume 0 != idle")
	var v_full := volume_db_for_throttle(1.0)
	if v_full <= v_idle:
		errors.append("volume full must be > idle")
	var rpm_idle := rpm_for_throttle_speed(0.0, 0.0)
	if not is_equal_approx(rpm_idle, RPM_IDLE):
		errors.append("rpm 0 != idle")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_validate_static() -> Dictionary:
	return debug_validate()

static func debug_export() -> Dictionary:
	return {
		"engine_audio_path": ENGINE_AUDIO_PATH,
		"audio_path": AUDIO_PATH,
		"audio_bus": AUDIO_BUS,
		"pitch_idle": PITCH_IDLE,
		"pitch_max": PITCH_MAX,
		"volume_idle_db": VOLUME_IDLE_DB,
		"volume_min_db": VOLUME_MIN_DB,
		"volume_max_db": VOLUME_MAX_DB,
		"rpm_idle": RPM_IDLE,
		"rpm_max": RPM_MAX,
		"rpm_redline": RPM_REDLINE,
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"tick_delta": TICK_DELTA,
		"budget_calls": BUDGET_CALLS,
		"engine_max_speed": EngineRef.MAX_SPEED_FORWARD,
	}

func debug_export_instance() -> Dictionary:
	var d := EngineAudio.debug_export()
	d["pitch"] = _pitch
	d["volume_db"] = _volume_db
	d["rpm"] = _rpm
	d["throttle_smoothed"] = _throttle_smoothed
	d["is_playing"] = _is_playing
	return d

static func perf_mark() -> Dictionary:
	return {"scope": "EngineAudio", "budget_calls": BUDGET_CALLS, "max_calls": MAX_CALLS_PER_TICK, "tick_hz": TICK_HZ, "bus": AUDIO_BUS}

func perf_mark_instance() -> Dictionary:
	return {"scope": "EngineAudio", "calls_last_tick": _call_count_last_tick, "budget": MAX_CALLS_PER_TICK, "pitch": _pitch, "volume_db": _volume_db, "budget_ok": _call_count_last_tick <= MAX_CALLS_PER_TICK}

static func perf_budget() -> Dictionary:
	return {"max_calls_per_tick": MAX_CALLS_PER_TICK, "tick_hz": TICK_HZ, "budget_ms": 4.0}
