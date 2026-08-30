## WS71 — Ball Hit & Bounce Audio (budget-aware, deterministic)
## Ball impact audio driven by WS20 BallContact impulse and WS19 BallConfig.
## No procedural generation — authored clips at assets/authored/audio_ball/.
## Budget: <12 calls per tick, <4 ms, 120 Hz tick. Routes via SFX bus (AudioService).
## Depends on: src/core/constants.gd (WS04), src/core/physics/physics_config.gd (WS07),
##             src/game/ball/ball_config.gd (WS19), src/game/ball/contact.gd (WS20),
##             src/game/ball/ball_physics.gd (WS19 — ball_hit signal)
## Conventions: docs/architecture/00-conventions.md \u00a73-\u00a75, \u00a78, \u00a712, 1 unit = 1 m, Y-up, +Z forward.
extends RefCounted
class_name BallAudio

const PC = preload("res://src/core/constants.gd")
const PCfg = preload("res://src/core/physics/physics_config.gd")
const BCfg = preload("res://src/game/ball/ball_config.gd")
const BallContactRef = preload("res://src/game/ball/contact.gd")
const BallPhysicsRef = preload("res://src/game/ball/ball_physics.gd")

# ---------------------------------------------------------------------------
# Authored audio constants — single source for WS71
# ---------------------------------------------------------------------------

## Authored clips (deterministic, committed). No synth — authored .ogg only.
const HIT_AUDIO_PATH: String = "res://assets/authored/audio_ball/audio_ball_hit_a_v01.ogg"
const BOUNCE_AUDIO_PATH: String = "res://assets/authored/audio_ball/audio_ball_bounce_a_v01.ogg"
const AUDIO_HIT_PATH: String = HIT_AUDIO_PATH
const AUDIO_BOUNCE_PATH: String = BOUNCE_AUDIO_PATH
const AUTHORED_HIT_NAME: String = "audio_ball_hit_a_v01.ogg"
const AUTHORED_BOUNCE_NAME: String = "audio_ball_bounce_a_v01.ogg"

## Audio bus — all ball SFX through SFX (conventions \u00a78: Master -> [Music, SFX, Crowd, UI]).
const AUDIO_BUS: String = "SFX"
const BUS_SFX: String = "SFX"

## Hit intensity mapping — impulse magnitude (Ns) -> 0..1 intensity.
## Uses WS20 BallContact thresholds so audio silence matches VFX silence.
const MIN_IMPULSE_FOR_AUDIO: float = 80.0
const MAX_IMPULSE_REF: float = 9000.0
const MIN_IMPULSE_REF: float = 80.0
const INTENSITY_AT_MIN: float = 0.25
const INTENSITY_AT_MAX: float = 1.0

## Bounce mapping — speed normal component (m/s) -> 0..1 intensity.
const MIN_BOUNCE_SPEED: float = 1.0
const MAX_BOUNCE_SPEED: float = 20.0
const BOUNCE_INTENSITY_AT_MIN: float = 0.15
const BOUNCE_INTENSITY_AT_MAX: float = 1.0

## Pitch mapping — downtime pitch scales with intensity.
const PITCH_HIT_MIN: float = 0.92
const PITCH_HIT_MAX: float = 1.35
const PITCH_BOUNCE_MIN: float = 0.85
const PITCH_BOUNCE_MAX: float = 1.25

## Volume mapping (dB): intensity 0..1 -> dB via linear_to_db, clamped.
const VOLUME_MIN_DB: float = -18.0
const VOLUME_MAX_DB: float = 2.0
const VOLUME_HIT_MIN_DB: float = -14.0
const VOLUME_HIT_MAX_DB: float = 0.0
const VOLUME_BOUNCE_MIN_DB: float = -16.0
const VOLUME_BOUNCE_MAX_DB: float = -1.0

## Cooldown — prevent machine-gun retrigger on rolling/settling contacts.
const HIT_COOLDOWN: float = 0.06
const BOUNCE_COOLDOWN: float = 0.08
const ROLLING_COOLDOWN: float = 0.12

## Physics tick — must be 120 Hz (validated against PC + BCfg + BallContactRef).
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_DELTA: float = PHYSICS_TICK_DELTA
const TICK_HZ: int = 120

## Budget awareness — <12 calls per tick (conventions \u00a712).
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK
const MAX_AUDIO_CALLS: int = MAX_CALLS_PER_TICK
const DRAW_CALL_BUDGET: int = 12

## Ball geometry — single source via BCfg (WS19). Duplicated as const for validation.
const BALL_RADIUS: float = 0.91
const BALL_DIAMETER: float = 1.82

# ---------------------------------------------------------------------------
# Instance state — per-ball, budget-aware (no alloc per tick beyond these fields)
# ---------------------------------------------------------------------------

var _pitch_hit: float = 1.0
var _pitch_bounce: float = 1.0
var _volume_hit_db: float = VOLUME_HIT_MIN_DB
var _volume_bounce_db: float = VOLUME_BOUNCE_MIN_DB
var _call_count_last_tick: int = 0
var _time_since_hit: float = 999.0
var _time_since_bounce: float = 999.0
var _last_impulse_mag: float = 0.0
var _last_bounce_speed: float = 0.0

# ---------------------------------------------------------------------------
# Core mapping — static, pure math, budget-aware (no AudioService call)
# ---------------------------------------------------------------------------

## Hit intensity 0..1 from impulse magnitude. Budget: 1 clamp + 1 lerp.
static func intensity_for_impulse(impulse_mag: float) -> float:
	if impulse_mag < MIN_IMPULSE_FOR_AUDIO:
		return 0.0
	var t := clamp((impulse_mag - MIN_IMPULSE_REF) / (MAX_IMPULSE_REF - MIN_IMPULSE_REF), 0.0, 1.0)
	# sqrt gives more resolution at low end (light taps audible)
	var curved := sqrt(t)
	return lerp(INTENSITY_AT_MIN, INTENSITY_AT_MAX, curved)

## Bounce intensity 0..1 from bounce speed (normal component).
static func intensity_for_bounce_speed(speed: float) -> float:
	if speed < MIN_BOUNCE_SPEED:
		return 0.0
	var t := clamp((speed - MIN_BOUNCE_SPEED) / (MAX_BOUNCE_SPEED - MIN_BOUNCE_SPEED), 0.0, 1.0)
	var curved := sqrt(t)
	return lerp(BOUNCE_INTENSITY_AT_MIN, BOUNCE_INTENSITY_AT_MAX, curved)

static func pitch_for_hit_intensity(intensity: float) -> float:
	var t := clamp(intensity, 0.0, 1.0)
	return lerp(PITCH_HIT_MIN, PITCH_HIT_MAX, t)

static func pitch_for_bounce_intensity(intensity: float) -> float:
	var t := clamp(intensity, 0.0, 1.0)
	return lerp(PITCH_BOUNCE_MIN, PITCH_BOUNCE_MAX, t)

static func volume_db_for_hit_intensity(intensity: float) -> float:
	if intensity <= 0.0:
		return VOLUME_MIN_DB
	var t := clamp(intensity, 0.0, 1.0)
	return lerp(VOLUME_HIT_MIN_DB, VOLUME_HIT_MAX_DB, t)

static func volume_db_for_bounce_intensity(intensity: float) -> float:
	if intensity <= 0.0:
		return VOLUME_MIN_DB
	var t := clamp(intensity, 0.0, 1.0)
	return lerp(VOLUME_BOUNCE_MIN_DB, VOLUME_BOUNCE_MAX_DB, t)

## Convenience: impulse magnitude -> pitch/volume in one call.
static func pitch_for_impulse(impulse_mag: float) -> float:
	return pitch_for_hit_intensity(intensity_for_impulse(impulse_mag))

static func volume_db_for_impulse(impulse_mag: float) -> float:
	return volume_db_for_hit_intensity(intensity_for_impulse(impulse_mag))

static func pitch_for_bounce_speed(speed: float) -> float:
	return pitch_for_bounce_intensity(intensity_for_bounce_speed(speed))

static func volume_db_for_bounce_speed(speed: float) -> float:
	return volume_db_for_bounce_intensity(intensity_for_bounce_speed(speed))

## Full audio params for a hit (impulse vector) — returns dict for AudioService.
## Budget: 1 call (intensity) + 2 lerps. No node access.
static func audio_params_for_hit(impulse: Vector3) -> Dictionary:
	var mag := impulse.length()
	if mag < MIN_IMPULSE_FOR_AUDIO:
		return {"play": false, "intensity": 0.0, "pitch": PITCH_HIT_MIN, "pitch_scale": PITCH_HIT_MIN, "volume_db": VOLUME_MIN_DB, "bus": AUDIO_BUS, "impulse_mag": mag}
	var intensity := intensity_for_impulse(mag)
	var pitch := pitch_for_hit_intensity(intensity)
	var vol := volume_db_for_hit_intensity(intensity)
	return {"play": true, "intensity": intensity, "pitch": pitch, "pitch_scale": pitch, "volume_db": vol, "bus": AUDIO_BUS, "impulse_mag": mag}

## Full audio params for a bounce (speed normal). Budget: 1 call.
static func audio_params_for_bounce(bounce_speed: float) -> Dictionary:
	var intensity := intensity_for_bounce_speed(bounce_speed)
	if intensity <= 0.0:
		return {"play": false, "intensity": 0.0, "pitch": PITCH_BOUNCE_MIN, "pitch_scale": PITCH_BOUNCE_MIN, "volume_db": VOLUME_MIN_DB, "bus": AUDIO_BUS, "bounce_speed": bounce_speed}
	var pitch := pitch_for_bounce_intensity(intensity)
	var vol := volume_db_for_bounce_intensity(intensity)
	return {"play": true, "intensity": intensity, "pitch": pitch, "pitch_scale": pitch, "volume_db": vol, "bus": AUDIO_BUS, "bounce_speed": bounce_speed}

## Vector form for bounce: de-dup bounce audio if velocity change is small.
static func audio_params_for_bounce_vector(velocity_before: Vector3, velocity_after: Vector3, normal: Vector3) -> Dictionary:
	var n := normal.normalized()
	if n.length_squared() < 0.5:
		return audio_params_for_bounce(velocity_after.length() * 0.2)
	var vn_before := absf(velocity_before.dot(n))
	var vn_after := absf(velocity_after.dot(n))
	var speed := max(vn_before, vn_after)
	# scale by restitution for world bounce consistency
	return audio_params_for_bounce(speed)

static func should_play_hit(impulse_mag: float, time_since_last_hit: float) -> bool:
	if impulse_mag < MIN_IMPULSE_FOR_AUDIO:
		return false
	if time_since_last_hit < HIT_COOLDOWN:
		return false
	return true

static func should_play_bounce(bounce_speed: float, time_since_last_bounce: float) -> bool:
	if bounce_speed < MIN_BOUNCE_SPEED:
		return false
	if time_since_last_bounce < BOUNCE_COOLDOWN:
		return false
	return true

# ---------------------------------------------------------------------------
# Instance update — call once per physics tick (<12 calls)
# ---------------------------------------------------------------------------

func tick(delta: float) -> void:
	_call_count_last_tick = 1
	_time_since_hit += delta
	_time_since_bounce += delta

func notify_hit(impulse: Vector3, _contact_point: Vector3 = Vector3.ZERO) -> Dictionary:
	var mag := impulse.length()
	_last_impulse_mag = mag
	if not BallAudio.should_play_hit(mag, _time_since_hit):
		return {"play": false, "reason": "cooldown_or_below_threshold", "impulse_mag": mag}
	var params := BallAudio.audio_params_for_hit(impulse)
	_pitch_hit = params["pitch"]
	_volume_hit_db = params["volume_db"]
	_time_since_hit = 0.0
	_call_count_last_tick += 1
	return params

func notify_bounce(bounce_speed: float) -> Dictionary:
	_last_bounce_speed = bounce_speed
	if not BallAudio.should_play_bounce(bounce_speed, _time_since_bounce):
		return {"play": false, "reason": "cooldown_or_below_threshold", "bounce_speed": bounce_speed}
	var params := BallAudio.audio_params_for_bounce(bounce_speed)
	_pitch_bounce = params["pitch"]
	_volume_bounce_db = params["volume_db"]
	_time_since_bounce = 0.0
	_call_count_last_tick += 1
	return params

func notify_bounce_vector(velocity_before: Vector3, velocity_after: Vector3, normal: Vector3) -> Dictionary:
	var n := normal.normalized()
	var speed := 0.0
	if n.length_squared() >= 0.5:
		speed = max(absf(velocity_before.dot(n)), absf(velocity_after.dot(n)))
	else:
		speed = (velocity_after - velocity_before).length() * 0.5
	return notify_bounce(speed)

func get_pitch_hit() -> float:
	return _pitch_hit

func get_pitch_bounce() -> float:
	return _pitch_bounce

func get_volume_hit_db() -> float:
	return _volume_hit_db

func get_volume_bounce_db() -> float:
	return _volume_bounce_db

func reset() -> void:
	_pitch_hit = 1.0
	_pitch_bounce = 1.0
	_volume_hit_db = VOLUME_HIT_MIN_DB
	_volume_bounce_db = VOLUME_BOUNCE_MIN_DB
	_time_since_hit = 999.0
	_time_since_bounce = 999.0
	_last_impulse_mag = 0.0
	_last_bounce_speed = 0.0
	_call_count_last_tick = 0

# ---------------------------------------------------------------------------
# Attachment helper — attach ball audio players to BallPhysics node (Node3D)
# ---------------------------------------------------------------------------

static func create_hit_player(ball_node: Node = null) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.name = "BallHitAudio"
	player.bus = AUDIO_BUS
	player.pitch_scale = 1.0
	player.volume_db = VOLUME_MIN_DB
	player.autoplay = false
	player.max_distance = 45.0
	player.unit_size = 8.0
	if ResourceLoader.exists(HIT_AUDIO_PATH):
		var stream: Resource = load(HIT_AUDIO_PATH)
		if stream is AudioStream:
			player.stream = stream as AudioStream
	return player

static func create_bounce_player(ball_node: Node = null) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.name = "BallBounceAudio"
	player.bus = AUDIO_BUS
	player.pitch_scale = 1.0
	player.volume_db = VOLUME_MIN_DB
	player.autoplay = false
	player.max_distance = 45.0
	player.unit_size = 8.0
	if ResourceLoader.exists(BOUNCE_AUDIO_PATH):
		var stream: Resource = load(BOUNCE_AUDIO_PATH)
		if stream is AudioStream:
			player.stream = stream as AudioStream
	return player

static func attach_to_ball(ball_node: Node3D) -> Dictionary:
	if ball_node == null:
		return {"hit": create_hit_player(null), "bounce": create_bounce_player(null)}
	var hit := ball_node.get_node_or_null("BallHitAudio") as AudioStreamPlayer3D
	if hit == null:
		hit = create_hit_player(ball_node)
		ball_node.add_child(hit)
	var bounce := ball_node.get_node_or_null("BallBounceAudio") as AudioStreamPlayer3D
	if bounce == null:
		bounce = create_bounce_player(ball_node)
		ball_node.add_child(bounce)
	# Wire to BallPhysics.ball_hit signal if present (WS19) — caller should connect audio handler
	return {"hit": hit, "bounce": bounce}

static func apply_to_player(player: AudioStreamPlayer3D, pitch: float, volume_db: float, play_now: bool = true) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.pitch_scale = clamp(pitch, 0.5, 2.5)
	player.volume_db = clamp(volume_db, -40.0, 6.0)
	if play_now and not player.playing:
		player.play()

static func get_hit_audio_path() -> String:
	return HIT_AUDIO_PATH

static func get_bounce_audio_path() -> String:
	return BOUNCE_AUDIO_PATH

# ---------------------------------------------------------------------------
# Validation & telemetry — conventions \u00a711 — budget-aware (<4ms physics)
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
	if not is_equal_approx(BALL_RADIUS, BCfg.BALL_RADIUS):
		errors.append("BALL_RADIUS %.3f != BCfg.BALL_RADIUS %.3f" % [BALL_RADIUS, BCfg.BALL_RADIUS])
	if not is_equal_approx(BALL_DIAMETER, BCfg.BALL_DIAMETER):
		errors.append("BALL_DIAMETER %.3f != BCfg.BALL_DIAMETER" % [BALL_DIAMETER, BCfg.BALL_DIAMETER])
	if not is_equal_approx(float(BALL_RADIUS * 2.0), BALL_DIAMETER):
		errors.append("BALL_RADIUS*2 != BALL_DIAMETER")
	if not is_equal_approx(BCfg.MASS, PCfg.MASS_BALL):
		errors.append("BCfg.MASS %.1f != PCfg.MASS_BALL %.1f" % [BCfg.MASS, PCfg.MASS_BALL])
	if not is_equal_approx(BallContactRef.MASS_BALL, BCfg.MASS):
		errors.append("BallContact MASS_BALL %.1f != BCfg.MASS %.1f" % [BallContactRef.MASS_BALL, BCfg.MASS])
	if not is_equal_approx(BallContactRef.RESTITUTION, BCfg.RESTITUTION_CAR):
		errors.append("BallContact RESTITUTION %.2f != BCfg.RESTITUTION_CAR %.2f" % [BallContactRef.RESTITUTION, BCfg.RESTITUTION_CAR])
	if not is_equal_approx(PC.BALL_RADIUS, BALL_RADIUS):
		errors.append("PC.BALL_RADIUS %.3f != BALL_RADIUS %.3f" % [PC.BALL_RADIUS, BALL_RADIUS])
	if MAX_CALLS_PER_TICK != 12:
		errors.append("MAX_CALLS_PER_TICK %d != 12" % MAX_CALLS_PER_TICK)
	if BUDGET_CALLS != 12:
		errors.append("BUDGET_CALLS %d != 12" % BUDGET_CALLS)
	if AUDIO_BUS != "SFX":
		errors.append("AUDIO_BUS %s != SFX" % AUDIO_BUS)
	if not HIT_AUDIO_PATH.begins_with("res://assets/authored/audio_ball/"):
		errors.append("HIT_AUDIO_PATH must be under assets/authored/audio_ball/")
	if not BOUNCE_AUDIO_PATH.begins_with("res://assets/authored/audio_ball/"):
		errors.append("BOUNCE_AUDIO_PATH must be under assets/authored/audio_ball/")
	if not HIT_AUDIO_PATH.ends_with(".ogg"):
		errors.append("HIT_AUDIO_PATH must be .ogg")
	if not BOUNCE_AUDIO_PATH.ends_with(".ogg"):
		errors.append("BOUNCE_AUDIO_PATH must be .ogg")
	if PITCH_HIT_MIN >= PITCH_HIT_MAX:
		errors.append("PITCH_HIT_MIN >= PITCH_HIT_MAX")
	if PITCH_BOUNCE_MIN >= PITCH_BOUNCE_MAX:
		errors.append("PITCH_BOUNCE_MIN >= PITCH_BOUNCE_MAX")
	if VOLUME_MIN_DB >= VOLUME_MAX_DB:
		errors.append("VOLUME_MIN_DB >= VOLUME_MAX_DB")
	if MIN_IMPULSE_FOR_AUDIO < BallContactRef.MIN_IMPACT_SPEED:
		errors.append("MIN_IMPULSE_FOR_AUDIO below MIN_IMPACT_SPEED")
	if not is_equal_approx(MIN_IMPULSE_FOR_AUDIO, 80.0):
		errors.append("MIN_IMPULSE_FOR_AUDIO %.1f != 80.0 (VFX parity)" % MIN_IMPULSE_FOR_AUDIO)
	if HIT_COOLDOWN <= 0.0 or BOUNCE_COOLDOWN <= 0.0:
		errors.append("cooldowns must be >0")
	var i0 := intensity_for_impulse(0.0)
	if not is_equal_approx(i0, 0.0):
		errors.append("intensity 0 must be 0 got %.3f" % i0)
	var i_min := intensity_for_impulse(MIN_IMPULSE_FOR_AUDIO)
	if not is_equal_approx(i_min, INTENSITY_AT_MIN):
		errors.append("intensity at min %.3f != %.3f" % [i_min, INTENSITY_AT_MIN])
	var i_max := intensity_for_impulse(MAX_IMPULSE_REF)
	if not is_equal_approx(i_max, INTENSITY_AT_MAX):
		errors.append("intensity at max %.3f != %.3f" % [i_max, INTENSITY_AT_MAX])
	var b0 := intensity_for_bounce_speed(0.0)
	if not is_equal_approx(b0, 0.0):
		errors.append("bounce intensity 0 must be 0")
	var p_hit := pitch_for_impulse(MIN_IMPULSE_FOR_AUDIO)
	if p_hit < PITCH_HIT_MIN - 0.001 or p_hit > PITCH_HIT_MAX + 0.001:
		errors.append("pitch_for_impulse out of range")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_validate_static() -> Dictionary:
	return debug_validate()

static func debug_export() -> Dictionary:
	return {
		"hit_audio_path": HIT_AUDIO_PATH,
		"bounce_audio_path": BOUNCE_AUDIO_PATH,
		"audio_bus": AUDIO_BUS,
		"min_impulse": MIN_IMPULSE_FOR_AUDIO,
		"max_impulse_ref": MAX_IMPULSE_REF,
		"min_bounce_speed": MIN_BOUNCE_SPEED,
		"max_bounce_speed": MAX_BOUNCE_SPEED,
		"pitch_hit_min": PITCH_HIT_MIN,
		"pitch_hit_max": PITCH_HIT_MAX,
		"pitch_bounce_min": PITCH_BOUNCE_MIN,
		"pitch_bounce_max": PITCH_BOUNCE_MAX,
		"volume_hit_min_db": VOLUME_HIT_MIN_DB,
		"volume_hit_max_db": VOLUME_HIT_MAX_DB,
		"hit_cooldown": HIT_COOLDOWN,
		"bounce_cooldown": BOUNCE_COOLDOWN,
		"ball_radius": BALL_RADIUS,
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"tick_delta": TICK_DELTA,
		"budget_calls": BUDGET_CALLS,
	}

func debug_export_instance() -> Dictionary:
	var d := BallAudio.debug_export()
	d["pitch_hit"] = _pitch_hit
	d["pitch_bounce"] = _pitch_bounce
	d["volume_hit_db"] = _volume_hit_db
	d["volume_bounce_db"] = _volume_bounce_db
	d["time_since_hit"] = _time_since_hit
	d["time_since_bounce"] = _time_since_bounce
	d["last_impulse_mag"] = _last_impulse_mag
	d["last_bounce_speed"] = _last_bounce_speed
	return d

static func perf_mark() -> Dictionary:
	return {"scope": "BallAudio", "budget_calls": BUDGET_CALLS, "max_calls": MAX_CALLS_PER_TICK, "tick_hz": TICK_HZ, "bus": AUDIO_BUS}

func perf_mark_instance() -> Dictionary:
	return {"scope": "BallAudio", "calls_last_tick": _call_count_last_tick, "budget": MAX_CALLS_PER_TICK, "pitch_hit": _pitch_hit, "pitch_bounce": _pitch_bounce, "budget_ok": _call_count_last_tick <= MAX_CALLS_PER_TICK}

static func perf_budget() -> Dictionary:
	return {"max_calls_per_tick": MAX_CALLS_PER_TICK, "tick_hz": TICK_HZ, "budget_ms": 4.0}
