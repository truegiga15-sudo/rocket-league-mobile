## WS73 — Crowd Stadium Ambience (budget-aware, deterministic)
## Crowd loop driven by arena/stadium state (WS36 Stadium, WS41 Crowd, WS22 Goal).
## No procedural generation — authored loop at assets/authored/audio_crowd/.
## Budget: <12 calls per tick, <4 ms, 120 Hz tick. Routes via Crowd bus (AudioService).
## Depends on: src/core/constants.gd (WS04), src/game/arena/stadium.gd (WS36)
## Conventions: docs/architecture/00-conventions.md §3-§5, §8, §12, 1 unit = 1 m, Y-up, +Z forward.
extends RefCounted
class_name CrowdAudio

const PC = preload("res://src/core/constants.gd")
const StadiumRef = preload("res://src/game/arena/stadium.gd")

# ---------------------------------------------------------------------------
# Authored audio constants — single source for WS73
# ---------------------------------------------------------------------------

## Authored crowd loop + cheer one-shot (deterministic, committed).
const CROWD_LOOP_PATH: String = "res://assets/authored/audio_crowd/audio_crowd_loop_a_v01.ogg"
const CHEER_AUDIO_PATH: String = "res://assets/authored/audio_crowd/audio_crowd_cheer_a_v01.ogg"
const AUDIO_PATH: String = CROWD_LOOP_PATH
const AUTHORED_LOOP_NAME: String = "audio_crowd_loop_a_v01.ogg"
const AUTHORED_CHEER_NAME: String = "audio_crowd_cheer_a_v01.ogg"

## Audio bus — crowd ambience through Crowd (conventions §8: Master -> [Music, SFX, Crowd, UI]).
const AUDIO_BUS: String = "Crowd"
const BUS_CROWD: String = "Crowd"

## Volume mapping (dB): intensity 0..1 -> dB. Crowd is ambient, quieter than SFX.
const VOLUME_MIN_DB: float = -24.0
const VOLUME_MAX_DB: float = -4.0
const VOLUME_SILENT_DB: float = -80.0
const VOLUME_IDLE_DB: float = -14.0
const VOLUME_CHEER_MIN_DB: float = -10.0
const VOLUME_CHEER_MAX_DB: float = -1.0
const CROWD_VOLUME_RANGE_DB: float = VOLUME_MAX_DB - VOLUME_MIN_DB  # 20 dB

## Pitch mapping: crowd murmur pitch variation is subtle (prevents phasing).
const PITCH_MIN: float = 0.94
const PITCH_MAX: float = 1.08
const PITCH_IDLE: float = 1.0
const PITCH_CHEER_MIN: float = 0.98
const PITCH_CHEER_MAX: float = 1.18

## Arena dimensions — must match Stadium WS36 + PC WS04 (single source of truth).
const ARENA_LENGTH: float = 60.0
const ARENA_WIDTH: float = 40.0
const ARENA_HEIGHT: float = 20.0
const ARENA_HALF_LENGTH: float = 30.0
const ARENA_HALF_WIDTH: float = 20.0
const ARENA_SIZE: Vector3 = Vector3(40.0, 20.0, 60.0)
const ARENA_HALF_SIZE: Vector3 = Vector3(20.0, 10.0, 30.0)

## Intensity model — game events drive crowd energy.
## Base idle 0.35, ball near goal raises to 0.7, goal scored spikes to 1.0.
const INTENSITY_IDLE: float = 0.35
const INTENSITY_MURMUR: float = 0.35
const INTENSITY_RISING: float = 0.65
const INTENSITY_CHEER: float = 1.0
const INTENSITY_MIN: float = 0.0
const INTENSITY_MAX: float = 1.0

## Goal reaction — cheer duration and cooldown (s).
const CHEER_DURATION: float = 2.2
const CHEER_COOLDOWN: float = 3.0
const GOAL_PROXIMITY_THRESHOLD: float = 10.0  # m from goal center

## Smoothing — attack/release rates (1/s) for crowd volume cross-fade.
const AUDIO_ATTACK_RATE: float = 1.8
const AUDIO_RELEASE_RATE: float = 0.9
const SMOOTH_ATTACK: float = AUDIO_ATTACK_RATE
const SMOOTH_RELEASE: float = AUDIO_RELEASE_RATE

## Physics tick — must be 120 Hz (validated against PC).
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_DELTA: float = PHYSICS_TICK_DELTA
const TICK_HZ: int = 120

## Budget awareness — <12 calls per tick (conventions §12, duo with Stadium).
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK
const MAX_AUDIO_CALLS: int = MAX_CALLS_PER_TICK
const DRAW_CALL_BUDGET: int = 12

# ---------------------------------------------------------------------------
# Instance state — per-arena, budget-aware (no alloc per tick beyond these fields)
# ---------------------------------------------------------------------------

var _intensity: float = INTENSITY_IDLE
var _intensity_smoothed: float = INTENSITY_IDLE
var _intensity_target: float = INTENSITY_IDLE
var _volume_db: float = VOLUME_IDLE_DB
var _pitch: float = PITCH_IDLE
var _is_playing: bool = false
var _call_count_last_tick: int = 0
var _time_since_goal: float = 999.0
var _cheer_remaining: float = 0.0
var _cheer_cooldown_remaining: float = 0.0
var _goal_scored_count: int = 0

# ---------------------------------------------------------------------------
# Core mapping — static, pure math, budget-aware (no AudioService call)
# ---------------------------------------------------------------------------

static func intensity_for_distance_to_goal(ball_pos: Vector3) -> float:
	# Distance to nearest goal center (0, 1.05, ±30) -> intensity 0.35..0.75
	var d_pos := ball_pos.distance_to(PC.goal_center(true))
	var d_neg := ball_pos.distance_to(PC.goal_center(false))
	var d := min(d_pos, d_neg)
	if d > 25.0:
		return INTENSITY_IDLE
	# Within 25m, lerp rising toward goal
	var t := clamp((25.0 - d) / (25.0 - GOAL_PROXIMITY_THRESHOLD), 0.0, 1.0)
	return lerp(INTENSITY_IDLE, INTENSITY_RISING, t)

static func intensity_for_ball_speed(ball_speed: float, distance_to_goal: float = 999.0) -> float:
	# Fast ball near goal = anticipation bump
	var base := INTENSITY_IDLE
	if distance_to_goal < GOAL_PROXIMITY_THRESHOLD:
		base = INTENSITY_RISING
	var speed_t := clamp(ball_speed / 18.0, 0.0, 1.0)
	return clamp(lerp(base, INTENSITY_RISING, speed_t * 0.35), INTENSITY_MIN, INTENSITY_MAX)

static func crow_intensity(game_state: Dictionary) -> float:
	# Unified: game_state may have ball_pos:Vector3, ball_speed:float, is_goal_scored:bool
	if game_state.get("is_goal_scored", false):
		return INTENSITY_CHEER
	var ball_pos: Vector3 = game_state.get("ball_pos", Vector3.ZERO)
	var ball_speed: float = float(game_state.get("ball_speed", 0.0))
	var dist := 999.0
	if ball_pos != Vector3.ZERO or game_state.has("ball_pos"):
		var d1 := ball_pos.distance_to(PC.goal_center(true))
		var d2 := ball_pos.distance_to(PC.goal_center(false))
		dist = min(d1, d2)
	if dist < GOAL_PROXIMITY_THRESHOLD:
		return intensity_for_ball_speed(ball_speed, dist)
	return intensity_for_distance_to_goal(ball_pos) if game_state.has("ball_pos") else INTENSITY_IDLE

static func volume_db_for_intensity(intensity: float) -> float:
	var i := clamp(intensity, 0.0, 1.0)
	if i < 0.02:
		return VOLUME_SILENT_DB
	return clamp(VOLUME_MIN_DB + i * CROWD_VOLUME_RANGE_DB, VOLUME_MIN_DB, VOLUME_MAX_DB)

static func pitch_for_intensity(intensity: float) -> float:
	var i := clamp(intensity, 0.0, 1.0)
	return clamp(lerp(PITCH_MIN, PITCH_MAX, i), 0.5, 2.5)

static func cheer_volume_db(intensity: float) -> float:
	var i := clamp(intensity, 0.0, 1.0)
	return clamp(lerp(VOLUME_CHEER_MIN_DB, VOLUME_CHEER_MAX_DB, i), -40.0, 6.0)

static func cheer_pitch(intensity: float) -> float:
	var i := clamp(intensity, 0.0, 1.0)
	return clamp(lerp(PITCH_CHEER_MIN, PITCH_CHEER_MAX, i), 0.5, 2.5)

static func audio_params_for_intensity(intensity: float) -> Dictionary:
	var i := clamp(intensity, INTENSITY_MIN, INTENSITY_MAX)
	var vol := volume_db_for_intensity(i)
	var pitch := pitch_for_intensity(i)
	return {"intensity": i, "volume_db": vol, "pitch": pitch, "pitch_scale": pitch, "bus": AUDIO_BUS}

static func audio_params_for_state(game_state: Dictionary) -> Dictionary:
	var inten := crow_intensity(game_state)
	return audio_params_for_intensity(inten)

static func audio_params_for_ball(ball_pos: Vector3, ball_speed: float = 0.0) -> Dictionary:
	var d1 := ball_pos.distance_to(PC.goal_center(true))
	var d2 := ball_pos.distance_to(PC.goal_center(false))
	var dist := min(d1, d2)
	var inten: float = intensity_for_ball_speed(ball_speed, dist) if dist < GOAL_PROXIMITY_THRESHOLD else intensity_for_distance_to_goal(ball_pos)
	return audio_params_for_intensity(inten)

static func should_cheer(goal_scored: bool, cheer_cooldown_remaining: float) -> bool:
	if not goal_scored:
		return false
	if cheer_cooldown_remaining > 0.0:
		return false
	return true

static func smooth_value(current: float, target: float, delta: float, is_attacking: bool = true) -> float:
	var rate := AUDIO_ATTACK_RATE if is_attacking else AUDIO_RELEASE_RATE
	var alpha := 1.0 - exp(-rate * delta)
	return lerp(current, target, alpha)

# ---------------------------------------------------------------------------
# Instance update — call once per physics tick (<12 calls)
# ---------------------------------------------------------------------------

func update(ball_pos: Vector3, ball_speed: float, delta: float, goal_scored: bool = false) -> Dictionary:
	_call_count_last_tick = 1
	_time_since_goal += delta
	if _cheer_remaining > 0.0:
		_cheer_remaining = max(_cheer_remaining - delta, 0.0)
	if _cheer_cooldown_remaining > 0.0:
		_cheer_cooldown_remaining = max(_cheer_cooldown_remaining - delta, 0.0)

	var target: float
	if goal_scored and CrowdAudio.should_cheer(true, _cheer_cooldown_remaining):
		target = INTENSITY_CHEER
		_cheer_remaining = CHEER_DURATION
		_cheer_cooldown_remaining = CHEER_COOLDOWN
		_time_since_goal = 0.0
		_goal_scored_count += 1
	elif _cheer_remaining > 0.0:
		target = INTENSITY_CHEER
	else:
		var d1 := ball_pos.distance_to(PC.goal_center(true))
		var d2 := ball_pos.distance_to(PC.goal_center(false))
		var dist := min(d1, d2)
		if dist < GOAL_PROXIMITY_THRESHOLD:
			target = CrowdAudio.intensity_for_ball_speed(ball_speed, dist)
		else:
			target = CrowdAudio.intensity_for_distance_to_goal(ball_pos)
		# Decay from cheer peak over cooldown
		if _time_since_goal < CHEER_COOLDOWN:
			var t := clamp(_time_since_goal / CHEER_COOLDOWN, 0.0, 1.0)
			target = lerp(INTENSITY_CHEER, target, t)

	_intensity_target = target
	var is_attacking := target > _intensity_smoothed
	_intensity_smoothed = CrowdAudio.smooth_value(_intensity_smoothed, target, delta, is_attacking)
	_intensity = target
	_volume_db = CrowdAudio.volume_db_for_intensity(_intensity_smoothed)
	_pitch = CrowdAudio.pitch_for_intensity(_intensity_smoothed)

	_call_count_last_tick += 3
	if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
		push_warning("[CrowdAudio] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
	return {"intensity": _intensity_smoothed, "target": _intensity_target, "volume_db": _volume_db, "pitch": _pitch, "pitch_scale": _pitch, "bus": AUDIO_BUS, "is_cheering": _cheer_remaining > 0.0, "time_since_goal": _time_since_goal}

func notify_goal(team: int = 0) -> Dictionary:
	if _cheer_cooldown_remaining > 0.0:
		return {"played": false, "cooldown": _cheer_cooldown_remaining, "intensity": _intensity_smoothed}
	_cheer_remaining = CHEER_DURATION
	_cheer_cooldown_remaining = CHEER_COOLDOWN
	_time_since_goal = 0.0
	_goal_scored_count += 1
	_intensity = INTENSITY_CHEER
	# cheer params for one-shot player
	var vol := CrowdAudio.cheer_volume_db(INTENSITY_CHEER)
	var pitch := CrowdAudio.cheer_pitch(INTENSITY_CHEER)
	return {"played": true, "intensity": INTENSITY_CHEER, "volume_db": vol, "pitch": pitch, "pitch_scale": pitch, "bus": AUDIO_BUS, "duration": CHEER_DURATION, "team": team}

func get_intensity() -> float:
	return _intensity_smoothed

func get_volume_db() -> float:
	return _volume_db

func get_pitch() -> float:
	return _pitch

func is_cheering() -> bool:
	return _cheer_remaining > 0.0

func is_playing() -> bool:
	return _is_playing

func set_playing(v: bool) -> void:
	_is_playing = v

func get_call_count() -> int:
	return _call_count_last_tick

func reset() -> void:
	_intensity = INTENSITY_IDLE
	_intensity_smoothed = INTENSITY_IDLE
	_intensity_target = INTENSITY_IDLE
	_volume_db = VOLUME_IDLE_DB
	_pitch = PITCH_IDLE
	_is_playing = false
	_call_count_last_tick = 0
	_time_since_goal = 999.0
	_cheer_remaining = 0.0
	_cheer_cooldown_remaining = 0.0

# ---------------------------------------------------------------------------
# Attachment helper — attach crowd audio to stadium/arena node (Node3D)
# ---------------------------------------------------------------------------

static func create_player(stadium_node: Node = null) -> AudioStreamPlayer:
	# Crowd is non-positional ambient — use AudioStreamPlayer (2D) on Crowd bus
	var player := AudioStreamPlayer.new()
	player.name = "CrowdAudio"
	player.bus = AUDIO_BUS
	player.pitch_scale = PITCH_IDLE
	player.volume_db = VOLUME_IDLE_DB
	player.autoplay = false
	if ResourceLoader.exists(CROWD_LOOP_PATH):
		var stream: Resource = load(CROWD_LOOP_PATH)
		if stream is AudioStream:
			player.stream = stream as AudioStream
	return player

static func create_cheer_player(stadium_node: Node = null) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = "CrowdCheerAudio"
	player.bus = AUDIO_BUS
	player.pitch_scale = PITCH_CHEER_MIN
	player.volume_db = VOLUME_SILENT_DB
	player.autoplay = false
	if ResourceLoader.exists(CHEER_AUDIO_PATH):
		var stream: Resource = load(CHEER_AUDIO_PATH)
		if stream is AudioStream:
			player.stream = stream as AudioStream
	return player

static func attach_to_stadium(stadium_node: Node3D) -> AudioStreamPlayer:
	if stadium_node == null:
		return create_player(null)
	var existing := stadium_node.get_node_or_null("CrowdAudio") as AudioStreamPlayer
	if existing != null:
		return existing
	var p := create_player(stadium_node)
	stadium_node.add_child(p)
	return p

static func attach_cheer_to_stadium(stadium_node: Node3D) -> AudioStreamPlayer:
	if stadium_node == null:
		return create_cheer_player(null)
	var existing := stadium_node.get_node_or_null("CrowdCheerAudio") as AudioStreamPlayer
	if existing != null:
		return existing
	var p := create_cheer_player(stadium_node)
	stadium_node.add_child(p)
	return p

static func attach_to_arena(arena_node: Node3D) -> AudioStreamPlayer:
	return attach_to_stadium(arena_node)

static func apply_to_player(player: AudioStreamPlayer, pitch: float, volume_db: float, is_loop: bool = true) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.pitch_scale = clamp(pitch, 0.5, 2.5)
	player.volume_db = clamp(volume_db, -80.0, 6.0)
	if is_loop and not player.playing:
		player.play()

static func apply_cheer_to_player(player: AudioStreamPlayer, pitch: float, volume_db: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.pitch_scale = clamp(pitch, 0.5, 2.5)
	player.volume_db = clamp(volume_db, -40.0, 6.0)
	# Restart cheer one-shot
	player.stop()
	player.play()

static func get_crowd_loop_path() -> String:
	return CROWD_LOOP_PATH

static func get_cheer_path() -> String:
	return CHEER_AUDIO_PATH

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
	if not is_equal_approx(ARENA_LENGTH, PC.ARENA_LENGTH):
		errors.append("ARENA_LENGTH %.1f != PC %.1f" % [ARENA_LENGTH, PC.ARENA_LENGTH])
	if not is_equal_approx(ARENA_WIDTH, PC.ARENA_WIDTH):
		errors.append("ARENA_WIDTH %.1f != PC %.1f" % [ARENA_WIDTH, PC.ARENA_WIDTH])
	if not is_equal_approx(ARENA_HEIGHT, PC.ARENA_HEIGHT):
		errors.append("ARENA_HEIGHT %.1f != PC %.1f" % [ARENA_HEIGHT, PC.ARENA_HEIGHT])
	if not is_equal_approx(ARENA_LENGTH, StadiumRef.ARENA_LENGTH):
		errors.append("ARENA_LENGTH %.1f != StadiumRef %.1f" % [ARENA_LENGTH, StadiumRef.ARENA_LENGTH])
	if not is_equal_approx(ARENA_WIDTH, StadiumRef.ARENA_WIDTH):
		errors.append("ARENA_WIDTH %.1f != StadiumRef %.1f" % [ARENA_WIDTH, StadiumRef.ARENA_WIDTH])
	if ARENA_SIZE != PC.ARENA_SIZE:
		errors.append("ARENA_SIZE %s != PC %s" % [str(ARENA_SIZE), str(PC.ARENA_SIZE)])
	if DRAW_CALL_BUDGET != 12:
		errors.append("DRAW_CALL_BUDGET %d != 12" % DRAW_CALL_BUDGET)
	if MAX_CALLS_PER_TICK != 12:
		errors.append("MAX_CALLS_PER_TICK %d != 12" % MAX_CALLS_PER_TICK)
	if BUDGET_CALLS != 12:
		errors.append("BUDGET_CALLS %d != 12" % BUDGET_CALLS)
	if AUDIO_BUS != "Crowd":
		errors.append("AUDIO_BUS %s != Crowd" % AUDIO_BUS)
	if not CROWD_LOOP_PATH.begins_with("res://assets/authored/audio_crowd/"):
		errors.append("CROWD_LOOP_PATH must be under assets/authored/audio_crowd/")
	if not CROWD_LOOP_PATH.ends_with(".ogg"):
		errors.append("CROWD_LOOP_PATH must be .ogg")
	if not CHEER_AUDIO_PATH.begins_with("res://assets/authored/audio_crowd/"):
		errors.append("CHEER_AUDIO_PATH must be under assets/authored/audio_crowd/")
	if not CHEER_AUDIO_PATH.ends_with(".ogg"):
		errors.append("CHEER_AUDIO_PATH must be .ogg")
	if PITCH_MIN >= PITCH_MAX:
		errors.append("PITCH_MIN >= PITCH_MAX")
	if VOLUME_MIN_DB >= VOLUME_MAX_DB:
		errors.append("VOLUME_MIN_DB >= VOLUME_MAX_DB")
	if INTENSITY_IDLE < 0.0 or INTENSITY_IDLE > 1.0:
		errors.append("INTENSITY_IDLE out of 0..1")
	if CHEER_DURATION <= 0.0 or CHEER_COOLDOWN <= 0.0:
		errors.append("cheer durations must be >0")
	# functional checks
	var vol_idle := volume_db_for_intensity(INTENSITY_IDLE)
	if vol_idle < VOLUME_MIN_DB - 0.01 or vol_idle > VOLUME_MAX_DB + 0.01:
		errors.append("volume idle %.1f out of range" % vol_idle)
	var vol_silent := volume_db_for_intensity(0.0)
	if not is_equal_approx(vol_silent, VOLUME_SILENT_DB):
		errors.append("volume 0 should be silent got %.1f" % vol_silent)
	var vol_full := volume_db_for_intensity(1.0)
	if not is_equal_approx(vol_full, VOLUME_MAX_DB):
		errors.append("volume 1 %.1f != VOLUME_MAX_DB %.1f" % [vol_full, VOLUME_MAX_DB])
	var p_low := pitch_for_intensity(0.0)
	if not is_equal_approx(p_low, PITCH_MIN):
		errors.append("pitch 0 %.3f != PITCH_MIN %.3f" % [p_low, PITCH_MIN])
	var p_high := pitch_for_intensity(1.0)
	if not is_equal_approx(p_high, PITCH_MAX):
		errors.append("pitch 1 %.3f != PITCH_MAX %.3f" % [p_high, PITCH_MAX])
	var i_far := intensity_for_distance_to_goal(Vector3.ZERO)
	if i_far < INTENSITY_IDLE - 0.01 or i_far > INTENSITY_RISING + 0.01:
		errors.append("intensity center %.3f out of idle..rising" % i_far)
	var i_goal := intensity_for_distance_to_goal(PC.goal_center(true))
	if not is_equal_approx(i_goal, INTENSITY_RISING):
		errors.append("intensity at goal %.3f != rising %.3f" % [i_goal, INTENSITY_RISING])
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_validate_static() -> Dictionary:
	return debug_validate()

static func debug_export() -> Dictionary:
	return {
		"crowd_loop_path": CROWD_LOOP_PATH,
		"cheer_path": CHEER_AUDIO_PATH,
		"audio_path": AUDIO_PATH,
		"audio_bus": AUDIO_BUS,
		"pitch_min": PITCH_MIN,
		"pitch_max": PITCH_MAX,
		"pitch_idle": PITCH_IDLE,
		"volume_min_db": VOLUME_MIN_DB,
		"volume_max_db": VOLUME_MAX_DB,
		"volume_idle_db": VOLUME_IDLE_DB,
		"intensity_idle": INTENSITY_IDLE,
		"intensity_rising": INTENSITY_RISING,
		"intensity_cheer": INTENSITY_CHEER,
		"cheer_duration": CHEER_DURATION,
		"cheer_cooldown": CHEER_COOLDOWN,
		"arena_size": ARENA_SIZE,
		"physics_ticks": PHYSICS_TICKS_PER_SECOND,
		"budget_calls": BUDGET_CALLS,
		"tick_hz": TICK_HZ,
	}

func debug_export_instance() -> Dictionary:
	var d := CrowdAudio.debug_export()
	d["intensity"] = _intensity_smoothed
	d["target"] = _intensity_target
	d["volume_db"] = _volume_db
	d["pitch"] = _pitch
	d["is_cheering"] = _cheer_remaining > 0.0
	d["cheer_remaining"] = _cheer_remaining
	d["time_since_goal"] = _time_since_goal
	d["goal_count"] = _goal_scored_count
	return d

static func perf_mark() -> Dictionary:
	return {"scope": "CrowdAudio", "budget_calls": BUDGET_CALLS, "max_calls": MAX_CALLS_PER_TICK, "tick_hz": TICK_HZ, "bus": AUDIO_BUS}

func perf_mark_instance() -> Dictionary:
	return {"scope": "CrowdAudio", "calls_last_tick": _call_count_last_tick, "budget": MAX_CALLS_PER_TICK, "intensity": _intensity_smoothed, "volume_db": _volume_db, "budget_ok": _call_count_last_tick <= MAX_CALLS_PER_TICK}

static func perf_budget() -> Dictionary:
	return {"max_calls_per_tick": MAX_CALLS_PER_TICK, "tick_hz": TICK_HZ, "budget_ms": 4.0}
