## WS74 — Goal Horn & Countdown Audio (budget-aware, deterministic)
## Goal horn on WS22 Goal.goal_scored, countdown beeps on WS58 MatchTimer.
## No procedural generation — authored clips at assets/authored/audio_goal/.
## Budget: <12 calls per tick, <4 ms, 120 Hz tick. Routes via SFX/UI buses (AudioService).
## Depends on: src/core/constants.gd (WS04), src/game/arena/goal.gd (WS22),
##             src/game/match_timer.gd (WS58)
## Conventions: docs/architecture/00-conventions.md §3-§5, §8, §12, 1 unit = 1 m, Y-up, +Z forward.
extends RefCounted
class_name GoalAudio

const PC = preload("res://src/core/constants.gd")
const GoalRef = preload("res://src/game/arena/goal.gd")
const MatchTimerRef = preload("res://src/game/match_timer.gd")

# ---------------------------------------------------------------------------
# Authored audio constants — single source for WS74
# ---------------------------------------------------------------------------

## Authored clips (deterministic, committed). No synth — authored .ogg only.
const HORN_AUDIO_PATH: String = "res://assets/authored/audio_goal/audio_goal_horn_a_v01.ogg"
const BEEP_AUDIO_PATH: String = "res://assets/authored/audio_goal/audio_countdown_beep_a_v01.ogg"
const FINAL_BEEP_PATH: String = "res://assets/authored/audio_goal/audio_countdown_final_a_v01.ogg"
const GOAL_HORN_PATH: String = HORN_AUDIO_PATH
const COUNTDOWN_BEEP_PATH: String = BEEP_AUDIO_PATH
const COUNTDOWN_FINAL_PATH: String = FINAL_BEEP_PATH
const AUTHORED_HORN_NAME: String = "audio_goal_horn_a_v01.ogg"
const AUTHORED_BEEP_NAME: String = "audio_countdown_beep_a_v01.ogg"
const AUTHORED_FINAL_NAME: String = "audio_countdown_final_a_v01.ogg"

## Audio buses — horn through SFX (stadium horn), beeps through UI (timer).
## Conventions §8: Master -> [Music, SFX, Crowd, UI].
const HORN_BUS: String = "SFX"
const BEEP_BUS: String = "UI"
const AUDIO_BUS: String = HORN_BUS
const BUS_SFX: String = "SFX"
const BUS_UI: String = "UI"

## Horn envelope — stadium horn: loud, sustained, slight pitch variance per team.
const HORN_DURATION: float = 3.0
const HORN_COOLDOWN: float = 4.0
const HORN_VOLUME_DB: float = 0.0
const HORN_VOLUME_MIN_DB: float = -2.0
const HORN_VOLUME_MAX_DB: float = 1.5
const HORN_PITCH: float = 1.0
const HORN_PITCH_TEAM_POS: float = 1.0
const HORN_PITCH_TEAM_NEG: float = 0.92
const HORN_PITCH_MIN: float = 0.90
const HORN_PITCH_MAX: float = 1.08

## Volume mapping (dB)
const VOLUME_MIN_DB: float = -80.0
const VOLUME_SILENT_DB: float = -80.0
const VOLUME_BEEP_MIN_DB: float = -10.0
const VOLUME_BEEP_MAX_DB: float = -1.0
const VOLUME_FINAL_DB: float = 0.0
const VOLUME_HORN_MIN_DB: float = -4.0
const VOLUME_HORN_MAX_DB: float = 1.5

## Pitch mapping
const PITCH_MIN: float = 0.85
const PITCH_MAX: float = 1.35
const PITCH_BEEP: float = 1.0
const PITCH_BEEP_HIGH: float = 1.35
const PITCH_FINAL: float = 1.5
const PITCH_HORN_MIN: float = 0.90
const PITCH_HORN_MAX: float = 1.08

## Countdown beeps — driven by MatchTimer ticks_remaining.
## Beep at 30s, 20s, 10s, 5s, 4s, 3s, 2s, 1s (final beep at 0 is horn-like).
const COUNTDOWN_WARN_SECONDS: float = 30.0
const BEEP_INTERVAL_NORMAL: float = 10.0  # 30,20,10
const BEEP_INTERVAL_FINAL: float = 1.0   # 5..1
const BEEP_FINAL_THRESHOLD: float = 5.0
const BEEP_DURATION: float = 0.15
const BEEP_COOLDOWN: float = 0.45

## Physics tick — must be 120 Hz (validated against PC + GoalRef + MatchTimerRef).
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_DELTA: float = PHYSICS_TICK_DELTA
const TICK_HZ: int = 120

## Budget awareness — <12 calls per tick (conventions §12).
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK
const MAX_AUDIO_CALLS: int = MAX_CALLS_PER_TICK
const DRAW_CALL_BUDGET: int = 12

## Goal geometry — single source via GoalRef/PC (WS22/WS04), duplicated for validation.
const GOAL_WIDTH: float = 7.3
const GOAL_HEIGHT: float = 2.1
const GOAL_DEPTH: float = 2.0
const GOAL_CENTER_Y: float = 1.05

## MatchTimer — single source via MatchTimerRef (WS58).
const MATCH_DURATION: float = 300.0
const MATCH_DURATION_TICKS: int = 36000

# ---------------------------------------------------------------------------
# Instance state — per-arena/match, budget-aware (no alloc per tick beyond fields)
# ---------------------------------------------------------------------------

var _horn_remaining: float = 0.0
var _horn_cooldown: float = 0.0
var _beep_cooldown: float = 0.0
var _last_beep_second: int = -1
var _horn_play_count: int = 0
var _beep_play_count: int = 0
var _call_count_last_tick: int = 0
var _is_playing_horn: bool = false
var _last_team: int = 0
var _pitch_horn: float = HORN_PITCH
var _volume_horn_db: float = VOLUME_SILENT_DB
var _pitch_beep: float = PITCH_BEEP
var _volume_beep_db: float = VOLUME_SILENT_DB

# ---------------------------------------------------------------------------
# Core mapping — static, pure math, budget-aware (no AudioService call)
# ---------------------------------------------------------------------------

static func pitch_for_team(team: int) -> float:
	if team == 1:
		return HORN_PITCH_TEAM_POS
	elif team == -1:
		return HORN_PITCH_TEAM_NEG
	return HORN_PITCH

static func volume_db_for_horn(_team: int = 0) -> float:
	return HORN_VOLUME_DB

static func pitch_for_beep(seconds_remaining: float) -> float:
	if seconds_remaining <= 1.0:
		return PITCH_FINAL
	if seconds_remaining <= BEEP_FINAL_THRESHOLD:
		return PITCH_BEEP_HIGH
	return PITCH_BEEP

static func volume_db_for_beep(seconds_remaining: float) -> float:
	if seconds_remaining <= 1.0:
		return VOLUME_FINAL_DB
	if seconds_remaining <= BEEP_FINAL_THRESHOLD:
		return VOLUME_BEEP_MAX_DB
	return VOLUME_BEEP_MIN_DB

static func should_beep(ticks_remaining: int, last_beep_second: int, beep_cooldown: float) -> bool:
	if beep_cooldown > 0.0:
		return false
	var secs: int = int(ceil(float(ticks_remaining) * TICK_DELTA))
	if secs > int(COUNTDOWN_WARN_SECONDS):
		return false
	if secs == last_beep_second:
		return false
	if secs > int(BEEP_FINAL_THRESHOLD):
		# Beep only at 30, 20, 10
		if secs == 30 or secs == 20 or secs == 10:
			return true
		return false
	if secs >= 0 and secs <= int(BEEP_FINAL_THRESHOLD):
		return true
	return false

static func beep_path_for_second(seconds_remaining: float) -> String:
	if seconds_remaining <= 1.0:
		return FINAL_BEEP_PATH
	return BEEP_AUDIO_PATH

static func beep_bus_for_second(_seconds_remaining: float) -> String:
	return BEEP_BUS

static func should_play_horn(team: int, horn_cooldown: float) -> bool:
	if team != 1 and team != -1:
		return false
	if horn_cooldown > 0.0:
		return false
	return true

## Full audio params for horn — returns dict for AudioService. Budget: 1 call.
static func audio_params_for_horn(team: int) -> Dictionary:
	if team != 1 and team != -1:
		return {"play": false, "reason": "invalid_team", "team": team}
	var pitch := pitch_for_team(team)
	var vol := volume_db_for_horn(team)
	return {"play": true, "team": team, "pitch": pitch, "pitch_scale": pitch, "volume_db": vol, "bus": HORN_BUS, "path": HORN_AUDIO_PATH, "duration": HORN_DURATION}

## Full audio params for countdown beep. Budget: 1 call.
static func audio_params_for_beep(seconds_remaining: float) -> Dictionary:
	if seconds_remaining < 0.0 or seconds_remaining > COUNTDOWN_WARN_SECONDS:
		return {"play": false, "reason": "outside_window", "seconds_remaining": seconds_remaining}
	# Gate: only valid beep seconds
	var secs_i: int = int(seconds_remaining)
	var is_valid: bool = false
	if seconds_remaining > BEEP_FINAL_THRESHOLD:
		is_valid = (secs_i == 30 or secs_i == 20 or secs_i == 10)
	else:
		is_valid = (secs_i >= 0 and secs_i <= 5)
	if not is_valid:
		return {"play": false, "reason": "not_beep_second", "seconds_remaining": seconds_remaining}
	var pitch := pitch_for_beep(seconds_remaining)
	var vol := volume_db_for_beep(seconds_remaining)
	var path := beep_path_for_second(seconds_remaining)
	var is_final := seconds_remaining <= 1.0
	return {"play": true, "seconds_remaining": seconds_remaining, "pitch": pitch, "pitch_scale": pitch, "volume_db": vol, "bus": BEEP_BUS, "path": path, "is_final": is_final}

static func audio_params_for_ticks(ticks_remaining: int) -> Dictionary:
	var secs := float(ticks_remaining) * TICK_DELTA
	return audio_params_for_beep(secs)

# ---------------------------------------------------------------------------
# Instance update — call once per physics tick (<12 calls)
# ---------------------------------------------------------------------------

func tick(delta: float, ticks_remaining: int = -1) -> Dictionary:
	_call_count_last_tick = 1
	if _horn_remaining > 0.0:
		_horn_remaining = max(_horn_remaining - delta, 0.0)
		if _horn_remaining <= 0.0:
			_is_playing_horn = false
	if _horn_cooldown > 0.0:
		_horn_cooldown = max(_horn_cooldown - delta, 0.0)
	if _beep_cooldown > 0.0:
		_beep_cooldown = max(_beep_cooldown - delta, 0.0)

	# Countdown beep handling if ticks provided and match is running
	if ticks_remaining >= 0:
		_call_count_last_tick += 1
		if GoalAudio.should_beep(ticks_remaining, _last_beep_second, _beep_cooldown):
			var secs_f := float(ticks_remaining) * TICK_DELTA
			var secs_i := int(ceil(secs_f))
			var params := GoalAudio.audio_params_for_beep(float(secs_i))
			if params["play"]:
				_last_beep_second = secs_i
				_beep_cooldown = BEEP_COOLDOWN
				_pitch_beep = params["pitch"]
				_volume_beep_db = params["volume_db"]
				_beep_play_count += 1
				_call_count_last_tick += 1
				return {"horn_playing": _is_playing_horn, "horn_remaining": _horn_remaining, "beep": params, "ticks_remaining": ticks_remaining}

	if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
		push_warning("[GoalAudio] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
	return {"horn_playing": _is_playing_horn, "horn_remaining": _horn_remaining, "ticks_remaining": ticks_remaining}

func notify_goal(team: int) -> Dictionary:
	if not GoalAudio.should_play_horn(team, _horn_cooldown):
		return {"play": false, "reason": "cooldown_or_invalid", "team": team, "cooldown": _horn_cooldown}
	var params := GoalAudio.audio_params_for_horn(team)
	_pitch_horn = params["pitch"]
	_volume_horn_db = params["volume_db"]
	_horn_remaining = HORN_DURATION
	_horn_cooldown = HORN_COOLDOWN
	_is_playing_horn = true
	_last_team = team
	_horn_play_count += 1
	_call_count_last_tick += 1
	return params

func notify_goal_scored(team: int) -> Dictionary:
	return notify_goal(team)

func on_goal(team: int) -> void:
	var _r := notify_goal(team)

func notify_countdown_beep(ticks_remaining: int) -> Dictionary:
	if not GoalAudio.should_beep(ticks_remaining, _last_beep_second, _beep_cooldown):
		return {"play": false, "reason": "cooldown_or_not_beep_second", "ticks_remaining": ticks_remaining}
	var secs_i := int(ceil(float(ticks_remaining) * TICK_DELTA))
	var params := GoalAudio.audio_params_for_beep(float(secs_i))
	if params["play"]:
		_last_beep_second = secs_i
		_beep_cooldown = BEEP_COOLDOWN
		_pitch_beep = params["pitch"]
		_volume_beep_db = params["volume_db"]
		_beep_play_count += 1
		_call_count_last_tick += 1
	return params

func reset() -> void:
	_horn_remaining = 0.0
	_horn_cooldown = 0.0
	_beep_cooldown = 0.0
	_last_beep_second = -1
	_horn_play_count = 0
	_beep_play_count = 0
	_call_count_last_tick = 0
	_is_playing_horn = false
	_last_team = 0
	_pitch_horn = HORN_PITCH
	_volume_horn_db = VOLUME_SILENT_DB
	_pitch_beep = PITCH_BEEP
	_volume_beep_db = VOLUME_SILENT_DB

func get_horn_remaining() -> float:
	return _horn_remaining

func is_horn_playing() -> bool:
	return _is_playing_horn

func get_pitch_horn() -> float:
	return _pitch_horn

func get_volume_horn_db() -> float:
	return _volume_horn_db

func get_pitch_beep() -> float:
	return _pitch_beep

func get_volume_beep_db() -> float:
	return _volume_beep_db

func get_call_count() -> int:
	return _call_count_last_tick

func get_horn_play_count() -> int:
	return _horn_play_count

func get_beep_play_count() -> int:
	return _beep_play_count

# ---------------------------------------------------------------------------
# Wiring helpers — connect to Goal (WS22) + MatchTimer (WS58) signals
# ---------------------------------------------------------------------------

func wire_goals(goal_pos: Goal, goal_neg: Goal) -> void:
	if goal_pos != null and not goal_pos.goal_scored.is_connected(on_goal):
		goal_pos.goal_scored.connect(on_goal)
	if goal_neg != null and not goal_neg.goal_scored.is_connected(on_goal):
		goal_neg.goal_scored.connect(on_goal)

func wire_goal_nodes(goals: Array) -> void:
	for g in goals:
		if g is Goal and not (g as Goal).goal_scored.is_connected(on_goal):
			(g as Goal).goal_scored.connect(on_goal)

func wire_match_timer(timer: MatchTimer) -> void:
	if timer == null:
		return
	if not timer.goal_scored.is_connected(on_goal):
		timer.goal_scored.connect(on_goal)
	if not timer.countdown_warning.is_connected(_on_countdown_warning):
		timer.countdown_warning.connect(_on_countdown_warning)
	if not timer.time_updated.is_connected(_on_time_updated):
		timer.time_updated.connect(_on_time_updated)

func _on_countdown_warning(_seconds_remaining: float) -> void:
	# Initial 30s warning — prime beep state so next tick fires
	_last_beep_second = -1

func _on_time_updated(ticks_remaining: int, _seconds: float) -> void:
	# Event-driven beep trigger — budget: 1 should_beep check
	if ticks_remaining < 0:
		return
	var _r := notify_countdown_beep(ticks_remaining)

# ---------------------------------------------------------------------------
# Attachment helper — attach goal audio players to arena/world node
# ---------------------------------------------------------------------------

static func create_horn_player(arena_node: Node = null) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = "GoalHornAudio"
	player.bus = HORN_BUS
	player.pitch_scale = HORN_PITCH
	player.volume_db = VOLUME_SILENT_DB
	player.autoplay = false
	if ResourceLoader.exists(HORN_AUDIO_PATH):
		var stream: Resource = load(HORN_AUDIO_PATH)
		if stream is AudioStream:
			player.stream = stream as AudioStream
	return player

static func create_beep_player(arena_node: Node = null) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = "CountdownBeepAudio"
	player.bus = BEEP_BUS
	player.pitch_scale = PITCH_BEEP
	player.volume_db = VOLUME_SILENT_DB
	player.autoplay = false
	if ResourceLoader.exists(BEEP_AUDIO_PATH):
		var stream: Resource = load(BEEP_AUDIO_PATH)
		if stream is AudioStream:
			player.stream = stream as AudioStream
	return player

static func create_players(arena_node: Node = null) -> Dictionary:
	return {"horn": create_horn_player(arena_node), "beep": create_beep_player(arena_node)}

static func attach_to_arena(arena_node: Node) -> Dictionary:
	if arena_node == null:
		return create_players(null)
	var horn := arena_node.get_node_or_null("GoalHornAudio") as AudioStreamPlayer
	if horn == null:
		horn = create_horn_player(arena_node)
		arena_node.add_child(horn)
	var beep := arena_node.get_node_or_null("CountdownBeepAudio") as AudioStreamPlayer
	if beep == null:
		beep = create_beep_player(arena_node)
		arena_node.add_child(beep)
	return {"horn": horn, "beep": beep}

static func attach_to_world(world_node: Node) -> Dictionary:
	return attach_to_arena(world_node as Node)

static func apply_horn_to_player(player: AudioStreamPlayer, pitch: float, volume_db: float, play_now: bool = true) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.pitch_scale = clamp(pitch, 0.5, 2.5)
	player.volume_db = clamp(volume_db, -40.0, 6.0)
	player.bus = HORN_BUS
	if play_now:
		player.stop()
		player.play()

static func apply_beep_to_player(player: AudioStreamPlayer, pitch: float, volume_db: float, play_now: bool = true) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.pitch_scale = clamp(pitch, 0.5, 2.5)
	player.volume_db = clamp(volume_db, -40.0, 6.0)
	player.bus = BEEP_BUS
	if play_now:
		player.stop()
		player.play()

static func apply_to_player(player: AudioStreamPlayer, pitch: float, volume_db: float, play_now: bool = true) -> void:
	apply_horn_to_player(player, pitch, volume_db, play_now)

static func get_horn_path() -> String:
	return HORN_AUDIO_PATH

static func get_beep_path() -> String:
	return BEEP_AUDIO_PATH

static func get_final_beep_path() -> String:
	return FINAL_BEEP_PATH

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
	if not is_equal_approx(GOAL_WIDTH, GoalRef.GOAL_WIDTH):
		errors.append("GOAL_WIDTH %.2f != GoalRef %.2f" % [GOAL_WIDTH, GoalRef.GOAL_WIDTH])
	if not is_equal_approx(GOAL_HEIGHT, GoalRef.GOAL_HEIGHT):
		errors.append("GOAL_HEIGHT %.2f != GoalRef %.2f" % [GOAL_HEIGHT, GoalRef.GOAL_HEIGHT])
	if not is_equal_approx(GOAL_DEPTH, GoalRef.GOAL_DEPTH):
		errors.append("GOAL_DEPTH %.2f != GoalRef %.2f" % [GOAL_DEPTH, GoalRef.GOAL_DEPTH])
	if not is_equal_approx(GOAL_CENTER_Y, GoalRef.GOAL_CENTER_Y):
		errors.append("GOAL_CENTER_Y %.2f != GoalRef %.2f" % [GOAL_CENTER_Y, GoalRef.GOAL_CENTER_Y])
	if not is_equal_approx(GOAL_WIDTH, PC.GOAL_WIDTH):
		errors.append("GOAL_WIDTH %.2f != PC.GOAL_WIDTH %.2f" % [GOAL_WIDTH, PC.GOAL_WIDTH])
	if not is_equal_approx(MATCH_DURATION, MatchTimerRef.MATCH_DURATION):
		errors.append("MATCH_DURATION %.1f != MatchTimerRef %.1f" % [MATCH_DURATION, MatchTimerRef.MATCH_DURATION])
	if MATCH_DURATION_TICKS != MatchTimerRef.MATCH_DURATION_TICKS:
		errors.append("MATCH_DURATION_TICKS %d != MatchTimerRef %d" % [MATCH_DURATION_TICKS, MatchTimerRef.MATCH_DURATION_TICKS])
	if not is_equal_approx(COUNTDOWN_WARN_SECONDS, MatchTimerRef.COUNTDOWN_WARN_SECONDS):
		errors.append("COUNTDOWN_WARN_SECONDS %.1f != MatchTimerRef %.1f" % [COUNTDOWN_WARN_SECONDS, MatchTimerRef.COUNTDOWN_WARN_SECONDS])
	if MAX_CALLS_PER_TICK != 12:
		errors.append("MAX_CALLS_PER_TICK %d != 12" % MAX_CALLS_PER_TICK)
	if BUDGET_CALLS != 12:
		errors.append("BUDGET_CALLS %d != 12" % BUDGET_CALLS)
	if HORN_BUS != "SFX":
		errors.append("HORN_BUS %s != SFX" % HORN_BUS)
	if BEEP_BUS != "UI":
		errors.append("BEEP_BUS %s != UI" % BEEP_BUS)
	if not HORN_AUDIO_PATH.begins_with("res://assets/authored/audio_goal/"):
		errors.append("HORN_AUDIO_PATH must be under assets/authored/audio_goal/")
	if not BEEP_AUDIO_PATH.begins_with("res://assets/authored/audio_goal/"):
		errors.append("BEEP_AUDIO_PATH must be under assets/authored/audio_goal/")
	if not FINAL_BEEP_PATH.begins_with("res://assets/authored/audio_goal/"):
		errors.append("FINAL_BEEP_PATH must be under assets/authored/audio_goal/")
	if not HORN_AUDIO_PATH.ends_with(".ogg"):
		errors.append("HORN_AUDIO_PATH must be .ogg")
	if not BEEP_AUDIO_PATH.ends_with(".ogg"):
		errors.append("BEEP_AUDIO_PATH must be .ogg")
	if not FINAL_BEEP_PATH.ends_with(".ogg"):
		errors.append("FINAL_BEEP_PATH must be .ogg")
	if HORN_DURATION <= 0.0 or HORN_DURATION > 5.0:
		errors.append("HORN_DURATION %.1f out of range (0,5]" % HORN_DURATION)
	if HORN_COOLDOWN < HORN_DURATION:
		errors.append("HORN_COOLDOWN %.1f < HORN_DURATION %.1f" % [HORN_COOLDOWN, HORN_DURATION])
	if BEEP_COOLDOWN <= 0.0:
		errors.append("BEEP_COOLDOWN must be >0")
	if PITCH_HORN_MIN >= PITCH_HORN_MAX:
		errors.append("PITCH_HORN_MIN >= PITCH_HORN_MAX")
	if VOLUME_MIN_DB >= VOLUME_BEEP_MAX_DB:
		errors.append("VOLUME_MIN_DB >= VOLUME_BEEP_MAX_DB")
	# Functional checks
	var p_pos := pitch_for_team(1)
	if not is_equal_approx(p_pos, HORN_PITCH_TEAM_POS):
		errors.append("pitch_for_team(1) %.2f != %.2f" % [p_pos, HORN_PITCH_TEAM_POS])
	var p_neg := pitch_for_team(-1)
	if not is_equal_approx(p_neg, HORN_PITCH_TEAM_NEG):
		errors.append("pitch_for_team(-1) %.2f != %.2f" % [p_neg, HORN_PITCH_TEAM_NEG])
	var horn_params := audio_params_for_horn(1)
	if not horn_params["play"]:
		errors.append("audio_params_for_horn(1) should play")
	var horn_bad := audio_params_for_horn(0)
	if horn_bad["play"]:
		errors.append("audio_params_for_horn(0) should not play")
	var beep30 := audio_params_for_beep(30.0)
	if not beep30["play"]:
		errors.append("beep 30s should play")
	var beep15 := audio_params_for_beep(15.0)
	if beep15["play"]:
		errors.append("beep 15s should not play")
	var beep3 := audio_params_for_beep(3.0)
	if not beep3["play"]:
		errors.append("beep 3s should play")
	var beep0 := audio_params_for_beep(0.0)
	if not beep0["play"]:
		errors.append("beep 0s should play")
	if not beep0["is_final"]:
		errors.append("beep 0s should be final")
	var sb30 := should_beep(3600, -1, 0.0)  # 30*120
	if not sb30:
		errors.append("should_beep 30s (3600 ticks) true expected")
	var sb15 := should_beep(1800, -1, 0.0)  # 15*120
	if sb15:
		errors.append("should_beep 15s should be false")
	var sh := should_play_horn(1, 0.0)
	if not sh:
		errors.append("should_play_horn(1,0) true expected")
	var sh_cd := should_play_horn(1, 1.0)
	if sh_cd:
		errors.append("should_play_horn during cooldown should be false")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_validate_static() -> Dictionary:
	return debug_validate()

static func debug_export() -> Dictionary:
	return {
		"horn_path": HORN_AUDIO_PATH,
		"beep_path": BEEP_AUDIO_PATH,
		"final_path": FINAL_BEEP_PATH,
		"horn_bus": HORN_BUS,
		"beep_bus": BEEP_BUS,
		"horn_duration": HORN_DURATION,
		"horn_cooldown": HORN_COOLDOWN,
		"beep_cooldown": BEEP_COOLDOWN,
		"match_duration": MATCH_DURATION,
		"match_duration_ticks": MATCH_DURATION_TICKS,
		"countdown_warn_seconds": COUNTDOWN_WARN_SECONDS,
		"tick_hz": TICK_HZ,
		"goal_width": GOAL_WIDTH,
		"goal_height": GOAL_HEIGHT,
		"goal_depth": GOAL_DEPTH,
		"budget_calls": BUDGET_CALLS,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "GoalAudio", "horn_bus": HORN_BUS, "beep_bus": BEEP_BUS, "tick_hz": TICK_HZ, "budget_calls": BUDGET_CALLS}
