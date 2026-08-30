## WS72 — Boost Audio start/loop/end (budget-aware, deterministic)
## Boost loop driven by WS18 CarBoost boosting state + amount + duration.
## No procedural generation — authored clips at assets/authored/audio_boost/
## Budget: <12 calls per tick, <4 ms, 120 Hz tick. Routes via SFX bus (AudioService).
## Depends on: src/core/constants.gd (WS04), src/game/car/boost.gd (WS18),
##             src/game/car/engine.gd (WS14)
## Conventions: docs/architecture/00-conventions.md §3-§5, §8, §12, 1 unit = 1 m, Y-up, +Z forward.
extends RefCounted
class_name BoostAudio

const PC = preload("res://src/core/constants.gd")
const CarBoostRef = preload("res://src/game/car/boost.gd")
const EngineRef = preload("res://src/game/car/engine.gd")

# ---------------------------------------------------------------------------
# Authored audio constants — single source for WS72
# ---------------------------------------------------------------------------

## Authored clips (deterministic, committed). No synth — authored .ogg only.
const BOOST_START_PATH: String = "res://assets/authored/audio_boost/audio_boost_start_a_v01.ogg"
const BOOST_LOOP_PATH: String = "res://assets/authored/audio_boost/audio_boost_loop_a_v01.ogg"
const BOOST_END_PATH: String = "res://assets/authored/audio_boost/audio_boost_end_a_v01.ogg"
const START_AUDIO_PATH: String = BOOST_START_PATH
const LOOP_AUDIO_PATH: String = BOOST_LOOP_PATH
const END_AUDIO_PATH: String = BOOST_END_PATH
const AUDIO_PATH: String = BOOST_LOOP_PATH
const AUTHORED_START_NAME: String = "audio_boost_start_a_v01.ogg"
const AUTHORED_LOOP_NAME: String = "audio_boost_loop_a_v01.ogg"
const AUTHORED_END_NAME: String = "audio_boost_end_a_v01.ogg"

## Audio bus — all boost SFX through SFX (conventions §8: Master -> [Music, SFX, Crowd, UI]).
const AUDIO_BUS: String = "SFX"
const BUS_SFX: String = "SFX"

## Boost states — mirrors WS18 boost lifecycle for audio transitions.
enum BoostAudioState { IDLE, START, LOOP, END }
const STATE_IDLE: int = BoostAudioState.IDLE
const STATE_START: int = BoostAudioState.START
const STATE_LOOP: int = BoostAudioState.LOOP
const STATE_END: int = BoostAudioState.END

## Volume mapping (dB): boosting -> audible, silent -> -80.
const VOLUME_MIN_DB: float = -12.0
const VOLUME_MAX_DB: float = 0.0
const VOLUME_SILENT_DB: float = -80.0
const VOLUME_START_DB: float = -2.0
const VOLUME_END_DB: float = -6.0

## Pitch mapping: start -> bright, loop -> steady, end -> falling.
const PITCH_START: float = 1.15
const PITCH_LOOP_MIN: float = 0.98
const PITCH_LOOP_MAX: float = 1.08
const PITCH_END: float = 0.88
const PITCH_MIN: float = 0.88
const PITCH_MAX: float = 1.15

## Timing — transitions between start/loop/end (s).
const START_DURATION: float = 0.18
const END_DURATION: float = 0.22
const FADE_IN_TIME: float = 0.08
const FADE_OUT_TIME: float = 0.14

## Smoothing — attack/release rates (1/s) for volume/pitch lerp.
const AUDIO_ATTACK_RATE: float = 16.0
const AUDIO_RELEASE_RATE: float = 10.0
const SMOOTH_ATTACK: float = AUDIO_ATTACK_RATE
const SMOOTH_RELEASE: float = AUDIO_RELEASE_RATE

## Boost amount thresholds — must match WS18 CarBoost for consistency.
const MIN_BOOST_TO_ACTIVATE: float = 0.5  # CarBoostRef.MIN_BOOST_TO_ACTIVATE

## Physics tick — must be 120 Hz (validated against PC + CarBoostRef).
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

var _state: int = BoostAudioState.IDLE
var _prev_boosting: bool = false
var _state_time: float = 0.0
var _volume_db: float = VOLUME_SILENT_DB
var _pitch: float = PITCH_LOOP_MIN
var _call_count_last_tick: int = 0
var _is_playing: bool = false
var _tick_count: int = 0

# ---------------------------------------------------------------------------
# Core mapping — static, pure math, budget-aware (no AudioService call)
# ---------------------------------------------------------------------------

static func state_name(s: int) -> String:
	match s:
		BoostAudioState.IDLE: return "IDLE"
		BoostAudioState.START: return "START"
		BoostAudioState.LOOP: return "LOOP"
		BoostAudioState.END: return "END"
		_: return "UNKNOWN"

static func is_boosting_state(s: int) -> bool:
	return s == BoostAudioState.START or s == BoostAudioState.LOOP

static func volume_for_state(state: int, t_in_state: float = 0.0, amount_norm: float = 1.0) -> float:
	var a := clamp(amount_norm, 0.0, 1.0)
	match state:
		BoostAudioState.IDLE:
			return VOLUME_SILENT_DB
		BoostAudioState.START:
			# quick fade in during start
			var fade := clamp(t_in_state / FADE_IN_TIME, 0.0, 1.0) if FADE_IN_TIME > 0 else 1.0
			return lerp(VOLUME_SILENT_DB, VOLUME_START_DB + a * 1.0, fade)
		BoostAudioState.LOOP:
			return lerp(VOLUME_MIN_DB, VOLUME_MAX_DB, clamp(a, 0.0, 1.0))
		BoostAudioState.END:
			var fade_out := 1.0 - clamp(t_in_state / FADE_OUT_TIME, 0.0, 1.0) if FADE_OUT_TIME > 0 else 0.0
			return lerp(VOLUME_SILENT_DB, VOLUME_END_DB, max(fade_out, 0.0))
		_:
			return VOLUME_SILENT_DB

static func pitch_for_state(state: int, t_in_state: float = 0.0, amount_norm: float = 1.0) -> float:
	match state:
		BoostAudioState.IDLE:
			return PITCH_LOOP_MIN
		BoostAudioState.START:
			return PITCH_START
		BoostAudioState.LOOP:
			# slight pitch rise with boost amount (full tank = brighter)
			return lerp(PITCH_LOOP_MIN, PITCH_LOOP_MAX, clamp(amount_norm, 0.0, 1.0))
		BoostAudioState.END:
			# pitch falls during tail
			var t := clamp(t_in_state / END_DURATION, 0.0, 1.0) if END_DURATION > 0 else 1.0
			return lerp(PITCH_LOOP_MIN, PITCH_END, t)
		_:
			return PITCH_LOOP_MIN

static func next_state(current: int, is_boosting: bool, t_in_state: float, boost_amount: float = 10.0) -> int:
	var has_boost := boost_amount > MIN_BOOST_TO_ACTIVATE
	match current:
		BoostAudioState.IDLE:
			if is_boosting and has_boost:
				return BoostAudioState.START
			return BoostAudioState.IDLE
		BoostAudioState.START:
			if not is_boosting or not has_boost:
				return BoostAudioState.END
			if t_in_state >= START_DURATION:
				return BoostAudioState.LOOP
			return BoostAudioState.START
		BoostAudioState.LOOP:
			if not is_boosting or not has_boost:
				return BoostAudioState.END
			return BoostAudioState.LOOP
		BoostAudioState.END:
			if is_boosting and has_boost:
				return BoostAudioState.START
			if t_in_state >= END_DURATION:
				return BoostAudioState.IDLE
			return BoostAudioState.END
		_:
			return BoostAudioState.IDLE

static func audio_params_for_state(state: int, t_in_state: float = 0.0, amount_norm: float = 1.0) -> Dictionary:
	var vol := volume_for_state(state, t_in_state, amount_norm)
	var pit := pitch_for_state(state, t_in_state, amount_norm)
	var playing := state != BoostAudioState.IDLE
	return {"state": state, "state_name": state_name(state), "volume_db": vol, "pitch": pit, "pitch_scale": pit, "bus": AUDIO_BUS, "is_playing": playing, "is_boosting_audio": is_boosting_state(state)}

static func audio_params(is_boosting: bool, boost_amount: float, t_in_state: float = 0.0, current_state: int = BoostAudioState.IDLE) -> Dictionary:
	var norm := clamp(boost_amount / CarBoostRef.MAX_BOOST, 0.0, 1.0) if CarBoostRef.MAX_BOOST > 0 else 0.0
	var st := next_state(current_state, is_boosting, t_in_state, boost_amount)
	# if IDLE and boosting, next is START — use that for params
	var use_state := st if st != BoostAudioState.IDLE or is_boosting else current_state
	if current_state == BoostAudioState.IDLE and is_boosting:
		use_state = st
	elif current_state != BoostAudioState.IDLE:
		use_state = st
	else:
		use_state = current_state
		if is_boosting and boost_amount > MIN_BOOST_TO_ACTIVATE:
			use_state = BoostAudioState.START
	return audio_params_for_state(use_state, t_in_state, norm)

static func smooth_value(current: float, target: float, delta: float, is_attacking: bool = true) -> float:
	var rate := AUDIO_ATTACK_RATE if is_attacking else AUDIO_RELEASE_RATE
	var alpha := 1.0 - exp(-rate * delta)
	return lerp(current, target, alpha)

# ---------------------------------------------------------------------------
# Instance update — call once per physics tick (<12 calls)
# ---------------------------------------------------------------------------

func update(is_boosting: bool, boost_amount: float, delta: float) -> Dictionary:
	_call_count_last_tick = 1
	_tick_count += 1
	var prev_state := _state
	# advance state time
	_state_time += delta
	var nxt := BoostAudio.next_state(_state, is_boosting, _state_time, boost_amount)
	if nxt != _state:
		_state = nxt
		_state_time = 0.0
	var norm := clamp(boost_amount / CarBoostRef.MAX_BOOST, 0.0, 1.0) if CarBoostRef.MAX_BOOST > 0 else 0.0
	var target_vol := BoostAudio.volume_for_state(_state, _state_time, norm)
	var target_pitch := BoostAudio.pitch_for_state(_state, _state_time, norm)
	var is_attacking := target_vol > _volume_db
	# smooth volume (audible change), pitch snaps faster on START
	if _state == BoostAudioState.START:
		_pitch = target_pitch
	else:
		_pitch = BoostAudio.smooth_value(_pitch, target_pitch, delta, is_attacking)
	_volume_db = BoostAudio.smooth_value(_volume_db, target_vol, delta, is_attacking)
	# clamp immediate silence when idle fully faded
	if _state == BoostAudioState.IDLE:
		_volume_db = VOLUME_SILENT_DB
		_pitch = PITCH_LOOP_MIN
	_is_playing = BoostAudio.is_boosting_state(_state)
	_prev_boosting = is_boosting
	_call_count_last_tick += 2
	if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
		push_warning("[BoostAudio] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
	return {"state": _state, "state_name": BoostAudio.state_name(_state), "prev_state": prev_state, "volume_db": _volume_db, "pitch": _pitch, "pitch_scale": _pitch, "bus": AUDIO_BUS, "is_playing": _is_playing, "is_boosting": is_boosting, "t_in_state": _state_time, "transitioned": prev_state != _state}

func physics_tick(car: RigidBody3D, boost: RefCounted, delta: float) -> Dictionary:
	_call_count_last_tick = 1
	_tick_count += 1
	var is_boosting := false
	var amount: float = 0.0
	if boost != null and boost.has_method("is_boosting"):
		is_boosting = bool(boost.is_boosting())
		_call_count_last_tick += 1
	if boost != null and boost.has_method("get_amount"):
		amount = float(boost.get_amount())
		_call_count_last_tick += 1
	elif boost != null and "amount" in boost:
		amount = float(boost.amount)
	# fallback: read InputService if boost null
	if boost == null:
		is_boosting = CarBoostRef.is_boost_pressed()
		_call_count_last_tick += 1
	return update(is_boosting, amount, delta)

func get_state() -> int:
	return _state

func get_state_name() -> String:
	return BoostAudio.state_name(_state)

func is_playing() -> bool:
	return _is_playing

func set_playing(v: bool) -> void:
	_is_playing = v

func get_volume_db() -> float:
	return _volume_db

func get_pitch() -> float:
	return _pitch

func get_call_count() -> int:
	return _call_count_last_tick

func reset() -> void:
	_state = BoostAudioState.IDLE
	_prev_boosting = false
	_state_time = 0.0
	_volume_db = VOLUME_SILENT_DB
	_pitch = PITCH_LOOP_MIN
	_is_playing = false
	_call_count_last_tick = 0

# ---------------------------------------------------------------------------
# Attachment helper — attach boost audio players to car node (Node3D)
# ---------------------------------------------------------------------------

static func create_start_player(_car_node: Node = null) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.name = "BoostStartAudio"
	player.bus = AUDIO_BUS
	player.pitch_scale = PITCH_START
	player.volume_db = VOLUME_SILENT_DB
	player.autoplay = false
	player.max_distance = 40.0
	player.unit_size = 6.0
	if ResourceLoader.exists(BOOST_START_PATH):
		var stream: Resource = load(BOOST_START_PATH)
		if stream is AudioStream:
			player.stream = stream as AudioStream
	return player

static func create_loop_player(_car_node: Node = null) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.name = "BoostAudio"
	player.bus = AUDIO_BUS
	player.pitch_scale = PITCH_LOOP_MIN
	player.volume_db = VOLUME_SILENT_DB
	player.autoplay = false
	player.max_distance = 40.0
	player.unit_size = 6.0
	if ResourceLoader.exists(BOOST_LOOP_PATH):
		var stream: Resource = load(BOOST_LOOP_PATH)
		if stream is AudioStream:
			player.stream = stream as AudioStream
	return player

static func create_end_player(_car_node: Node = null) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.name = "BoostEndAudio"
	player.bus = AUDIO_BUS
	player.pitch_scale = PITCH_END
	player.volume_db = VOLUME_SILENT_DB
	player.autoplay = false
	player.max_distance = 40.0
	player.unit_size = 6.0
	if ResourceLoader.exists(BOOST_END_PATH):
		var stream: Resource = load(BOOST_END_PATH)
		if stream is AudioStream:
			player.stream = stream as AudioStream
	return player

static func create_player(car_node: Node = null) -> AudioStreamPlayer3D:
	return create_loop_player(car_node)

static func attach_to_car(car_node: Node3D) -> Dictionary:
	if car_node == null:
		return {"start": create_start_player(null), "loop": create_loop_player(null), "end": create_end_player(null)}
	var start_p := car_node.get_node_or_null("BoostStartAudio") as AudioStreamPlayer3D
	if start_p == null:
		start_p = create_start_player(car_node)
		car_node.add_child(start_p)
	var loop_p := car_node.get_node_or_null("BoostAudio") as AudioStreamPlayer3D
	if loop_p == null:
		loop_p = create_loop_player(car_node)
		car_node.add_child(loop_p)
	var end_p := car_node.get_node_or_null("BoostEndAudio") as AudioStreamPlayer3D
	if end_p == null:
		end_p = create_end_player(car_node)
		car_node.add_child(end_p)
	return {"start": start_p, "loop": loop_p, "end": end_p}

static func apply_to_players(players: Dictionary, state: int, pitch: float, volume_db: float) -> void:
	var loop_p: AudioStreamPlayer3D = players.get("loop", null) as AudioStreamPlayer3D
	var start_p: AudioStreamPlayer3D = players.get("start", null) as AudioStreamPlayer3D
	var end_p: AudioStreamPlayer3D = players.get("end", null) as AudioStreamPlayer3D
	match state:
		BoostAudioState.IDLE:
			if loop_p != null and is_instance_valid(loop_p) and loop_p.playing:
				loop_p.stop()
			if start_p != null and is_instance_valid(start_p) and start_p.playing:
				start_p.stop()
		BoostAudioState.START:
			if start_p != null and is_instance_valid(start_p):
				start_p.pitch_scale = clamp(pitch, 0.5, 2.5)
				start_p.volume_db = clamp(volume_db, -40.0, 6.0)
				if not start_p.playing:
					start_p.play()
			if loop_p != null and is_instance_valid(loop_p):
				loop_p.pitch_scale = clamp(lerp(PITCH_LOOP_MIN, PITCH_LOOP_MAX, 0.5), 0.5, 2.5)
				loop_p.volume_db = clamp(volume_db - 6.0, -40.0, 6.0)
				if not loop_p.playing:
					loop_p.play()
		BoostAudioState.LOOP:
			if start_p != null and is_instance_valid(start_p) and start_p.playing:
				start_p.stop()
			if loop_p != null and is_instance_valid(loop_p):
				loop_p.pitch_scale = clamp(pitch, 0.5, 2.5)
				loop_p.volume_db = clamp(volume_db, -40.0, 6.0)
				if not loop_p.playing:
					loop_p.play()
		BoostAudioState.END:
			if loop_p != null and is_instance_valid(loop_p) and loop_p.playing:
				loop_p.stop()
			if end_p != null and is_instance_valid(end_p):
				end_p.pitch_scale = clamp(pitch, 0.5, 2.5)
				end_p.volume_db = clamp(volume_db, -40.0, 6.0)
				if not end_p.playing:
					end_p.play()

static func apply_to_player(player: AudioStreamPlayer3D, pitch: float, volume_db: float, is_boosting: bool = true) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.pitch_scale = clamp(pitch, 0.5, 2.5)
	player.volume_db = clamp(volume_db, -80.0, 6.0)
	if is_boosting:
		if not player.playing:
			player.play()
	else:
		if player.playing:
			player.stop()

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
	if CarBoostRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("CarBoost PHYSICS_TICKS_PER_SECOND %d != 120" % CarBoostRef.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(CarBoostRef.MAX_BOOST, 100.0):
		errors.append("CarBoost MAX_BOOST %.1f != 100.0" % CarBoostRef.MAX_BOOST)
	if not is_equal_approx(MIN_BOOST_TO_ACTIVATE, CarBoostRef.MIN_BOOST_TO_ACTIVATE):
		errors.append("MIN_BOOST_TO_ACTIVATE %.2f != CarBoost %.2f" % [MIN_BOOST_TO_ACTIVATE, CarBoostRef.MIN_BOOST_TO_ACTIVATE])
	if MAX_CALLS_PER_TICK != 12:
		errors.append("MAX_CALLS_PER_TICK %d != 12" % MAX_CALLS_PER_TICK)
	if BUDGET_CALLS != 12:
		errors.append("BUDGET_CALLS %d != 12" % BUDGET_CALLS)
	if AUDIO_BUS != "SFX":
		errors.append("AUDIO_BUS %s != SFX" % AUDIO_BUS)
	if not BOOST_START_PATH.begins_with("res://assets/authored/audio_boost/"):
		errors.append("BOOST_START_PATH must be under assets/authored/audio_boost/")
	if not BOOST_LOOP_PATH.begins_with("res://assets/authored/audio_boost/"):
		errors.append("BOOST_LOOP_PATH must be under assets/authored/audio_boost/")
	if not BOOST_END_PATH.begins_with("res://assets/authored/audio_boost/"):
		errors.append("BOOST_END_PATH must be under assets/authored/audio_boost/")
	if not BOOST_START_PATH.ends_with(".ogg"):
		errors.append("BOOST_START_PATH must be .ogg")
	if not BOOST_LOOP_PATH.ends_with(".ogg"):
		errors.append("BOOST_LOOP_PATH must be .ogg")
	if not BOOST_END_PATH.ends_with(".ogg"):
		errors.append("BOOST_END_PATH must be .ogg")
	if PITCH_MIN >= PITCH_MAX:
		errors.append("PITCH_MIN >= PITCH_MAX")
	if VOLUME_MIN_DB >= VOLUME_MAX_DB:
		errors.append("VOLUME_MIN_DB >= VOLUME_MAX_DB")
	if START_DURATION <= 0.0 or END_DURATION <= 0.0:
		errors.append("START/END durations must be >0")
	# functional checks
	var vol_idle := volume_for_state(BoostAudioState.IDLE)
	if not is_equal_approx(vol_idle, VOLUME_SILENT_DB):
		errors.append("volume IDLE %.1f != silent" % vol_idle)
	var vol_loop := volume_for_state(BoostAudioState.LOOP, 0.0, 1.0)
	if not is_equal_approx(vol_loop, VOLUME_MAX_DB):
		errors.append("volume LOOP full %.1f != max" % vol_loop)
	var pit_start := pitch_for_state(BoostAudioState.START)
	if not is_equal_approx(pit_start, PITCH_START):
		errors.append("pitch START %.3f != PITCH_START" % pit_start)
	var s0 := next_state(BoostAudioState.IDLE, true, 0.0, 10.0)
	if s0 != BoostAudioState.START:
		errors.append("IDLE+boosting should -> START got %s" % state_name(s0))
	var s1 := next_state(BoostAudioState.START, true, START_DURATION + 0.01, 10.0)
	if s1 != BoostAudioState.LOOP:
		errors.append("START after duration should -> LOOP got %s" % state_name(s1))
	var s2 := next_state(BoostAudioState.LOOP, false, 0.0, 10.0)
	if s2 != BoostAudioState.END:
		errors.append("LOOP+not boosting should -> END got %s" % state_name(s2))
	var s3 := next_state(BoostAudioState.END, false, END_DURATION + 0.01, 0.0)
	if s3 != BoostAudioState.IDLE:
		errors.append("END after duration should -> IDLE got %s" % state_name(s3))
	var s_empty := next_state(BoostAudioState.LOOP, true, 0.0, 0.0)
	if s_empty != BoostAudioState.END:
		errors.append("LOOP with empty boost should -> END")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_validate_static() -> Dictionary:
	return debug_validate()

static func debug_export() -> Dictionary:
	return {
		"start_audio_path": BOOST_START_PATH,
		"loop_audio_path": BOOST_LOOP_PATH,
		"end_audio_path": BOOST_END_PATH,
		"audio_path": AUDIO_PATH,
		"audio_bus": AUDIO_BUS,
		"pitch_start": PITCH_START,
		"pitch_loop_min": PITCH_LOOP_MIN,
		"pitch_loop_max": PITCH_LOOP_MAX,
		"pitch_end": PITCH_END,
		"volume_min_db": VOLUME_MIN_DB,
		"volume_max_db": VOLUME_MAX_DB,
		"start_duration": START_DURATION,
		"end_duration": END_DURATION,
		"physics_ticks": PHYSICS_TICKS_PER_SECOND,
		"budget_calls": BUDGET_CALLS,
	}

func debug_export_instance() -> Dictionary:
	var d := BoostAudio.debug_export()
	d["state"] = _state
	d["state_name"] = BoostAudio.state_name(_state)
	d["volume_db"] = _volume_db
	d["pitch"] = _pitch
	d["is_playing"] = _is_playing
	d["t_in_state"] = _state_time
	return d

static func perf_mark() -> Dictionary:
	return {"scope": "BoostAudio", "budget_calls": BUDGET_CALLS, "max_calls": MAX_CALLS_PER_TICK, "tick_hz": TICK_HZ, "bus": AUDIO_BUS}

func perf_mark_instance() -> Dictionary:
	return {"scope": "BoostAudio", "calls_last_tick": _call_count_last_tick, "budget": MAX_CALLS_PER_TICK, "state": _state, "budget_ok": _call_count_last_tick <= MAX_CALLS_PER_TICK}

static func perf_budget() -> Dictionary:
	return {"max_calls_per_tick": MAX_CALLS_PER_TICK, "tick_hz": TICK_HZ, "budget_ms": 4.0}
