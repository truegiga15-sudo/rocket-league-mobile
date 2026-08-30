## WS75 — UI Menu Audio Mixer Routing (budget-aware, deterministic)
## Menu/UI sounds: hover, click/select, back, open/close, toggle, error.
## No procedural generation — authored clips at assets/authored/audio_ui/.
## Budget: <12 calls per tick, <4 ms. Routes via UI bus (AudioService).
## Buses: Master -> [Music, SFX, Crowd, UI] — conventions §8.
## Depends on: src/core/constants.gd (WS04)
## Conventions: docs/architecture/00-conventions.md §3-§5, §8, §12, 1 unit = 1 m.
extends RefCounted
class_name UIAudio

const PC = preload("res://src/core/constants.gd")

# ---------------------------------------------------------------------------
# Authored audio constants — single source for WS75
# ---------------------------------------------------------------------------

const CLICK_PATH: String = "res://assets/authored/audio_ui/audio_ui_click_a_v01.ogg"
const HOVER_PATH: String = "res://assets/authored/audio_ui/audio_ui_hover_a_v01.ogg"
const BACK_PATH: String = "res://assets/authored/audio_ui/audio_ui_back_a_v01.ogg"
const OPEN_PATH: String = "res://assets/authored/audio_ui/audio_ui_open_a_v01.ogg"
const CLOSE_PATH: String = "res://assets/authored/audio_ui/audio_ui_close_a_v01.ogg"
const ERROR_PATH: String = "res://assets/authored/audio_ui/audio_ui_error_a_v01.ogg"
const TOGGLE_PATH: String = "res://assets/authored/audio_ui/audio_ui_toggle_a_v01.ogg"
const SELECT_PATH: String = CLICK_PATH

const AUTHORED_CLICK_NAME: String = "audio_ui_click_a_v01.ogg"
const AUTHORED_HOVER_NAME: String = "audio_ui_hover_a_v01.ogg"
const AUTHORED_BACK_NAME: String = "audio_ui_back_a_v01.ogg"
const AUTHORED_OPEN_NAME: String = "audio_ui_open_a_v01.ogg"
const AUTHORED_CLOSE_NAME: String = "audio_ui_close_a_v01.ogg"
const AUTHORED_ERROR_NAME: String = "audio_ui_error_a_v01.ogg"
const AUTHORED_TOGGLE_NAME: String = "audio_ui_toggle_a_v01.ogg"

## Audio bus — all UI/Menu SFX through UI (conventions §8).
const AUDIO_BUS: String = "UI"
const BUS_UI: String = "UI"

## UI events — mirrors menu actions for audio routing.
enum UIEvent { CLICK, HOVER, BACK, OPEN, CLOSE, ERROR, TOGGLE, SELECT }
const EVENT_CLICK: int = UIEvent.CLICK
const EVENT_HOVER: int = UIEvent.HOVER
const EVENT_BACK: int = UIEvent.BACK
const EVENT_OPEN: int = UIEvent.OPEN
const EVENT_CLOSE: int = UIEvent.CLOSE
const EVENT_ERROR: int = UIEvent.ERROR
const EVENT_TOGGLE: int = UIEvent.TOGGLE
const EVENT_SELECT: int = UIEvent.SELECT

## Volume (dB) per event — UI is crisp, not loud.
const VOLUME_CLICK_DB: float = -4.0
const VOLUME_HOVER_DB: float = -12.0
const VOLUME_BACK_DB: float = -5.0
const VOLUME_OPEN_DB: float = -3.0
const VOLUME_CLOSE_DB: float = -3.0
const VOLUME_ERROR_DB: float = -2.0
const VOLUME_TOGGLE_DB: float = -6.0
const VOLUME_SELECT_DB: float = -4.0
const VOLUME_SILENT_DB: float = -80.0
const VOLUME_MIN_DB: float = -18.0
const VOLUME_MAX_DB: float = 0.0

## Pitch per event — subtle variation.
const PITCH_CLICK: float = 1.0
const PITCH_HOVER: float = 1.18
const PITCH_BACK: float = 0.88
const PITCH_OPEN: float = 1.05
const PITCH_CLOSE: float = 0.92
const PITCH_ERROR: float = 0.85
const PITCH_TOGGLE: float = 1.12
const PITCH_SELECT: float = 1.0
const PITCH_MIN: float = 0.5
const PITCH_MAX: float = 2.5

## Cooldown — prevent spam retrigger on hover/scroll.
const HOVER_COOLDOWN: float = 0.06
const CLICK_COOLDOWN: float = 0.04

## Physics tick — must be 120 Hz (validated against PC).
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
# Instance state — budget-aware (no alloc per tick beyond these fields)
# ---------------------------------------------------------------------------

var _call_count_last_tick: int = 0
var _time_since_hover: float = 999.0
var _time_since_click: float = 999.0
var _last_event: int = -1

# ---------------------------------------------------------------------------
# Core mapping — static, pure math, budget-aware (no AudioService call)
# ---------------------------------------------------------------------------

static func path_for_event(event: int) -> String:
	match event:
		UIEvent.CLICK, UIEvent.SELECT: return CLICK_PATH
		UIEvent.HOVER: return HOVER_PATH
		UIEvent.BACK: return BACK_PATH
		UIEvent.OPEN: return OPEN_PATH
		UIEvent.CLOSE: return CLOSE_PATH
		UIEvent.ERROR: return ERROR_PATH
		UIEvent.TOGGLE: return TOGGLE_PATH
		_: return CLICK_PATH

static func volume_db_for_event(event: int) -> float:
	match event:
		UIEvent.CLICK, UIEvent.SELECT: return VOLUME_CLICK_DB
		UIEvent.HOVER: return VOLUME_HOVER_DB
		UIEvent.BACK: return VOLUME_BACK_DB
		UIEvent.OPEN: return VOLUME_OPEN_DB
		UIEvent.CLOSE: return VOLUME_CLOSE_DB
		UIEvent.ERROR: return VOLUME_ERROR_DB
		UIEvent.TOGGLE: return VOLUME_TOGGLE_DB
		_: return VOLUME_CLICK_DB

static func pitch_for_event(event: int) -> float:
	match event:
		UIEvent.CLICK, UIEvent.SELECT: return PITCH_CLICK
		UIEvent.HOVER: return PITCH_HOVER
		UIEvent.BACK: return PITCH_BACK
		UIEvent.OPEN: return PITCH_OPEN
		UIEvent.CLOSE: return PITCH_CLOSE
		UIEvent.ERROR: return PITCH_ERROR
		UIEvent.TOGGLE: return PITCH_TOGGLE
		_: return PITCH_CLICK

static func audio_params_for_event(event: int) -> Dictionary:
	return {
		"play": true, "event": event, "path": path_for_event(event),
		"volume_db": volume_db_for_event(event), "pitch": pitch_for_event(event),
		"pitch_scale": pitch_for_event(event), "bus": AUDIO_BUS,
	}

static func should_play(event: int, time_since_hover: float, time_since_click: float) -> bool:
	if event == UIEvent.HOVER and time_since_hover < HOVER_COOLDOWN:
		return false
	if (event == UIEvent.CLICK or event == UIEvent.SELECT) and time_since_click < CLICK_COOLDOWN:
		return false
	return true

static func event_name(event: int) -> String:
	match event:
		UIEvent.CLICK: return "click"
		UIEvent.HOVER: return "hover"
		UIEvent.BACK: return "back"
		UIEvent.OPEN: return "open"
		UIEvent.CLOSE: return "close"
		UIEvent.ERROR: return "error"
		UIEvent.TOGGLE: return "toggle"
		UIEvent.SELECT: return "select"
		_: return "unknown"

# ---------------------------------------------------------------------------
# Instance update
# ---------------------------------------------------------------------------

func tick(delta: float) -> void:
	_call_count_last_tick = 0
	_time_since_hover += delta
	_time_since_click += delta

func notify_event(event: int) -> Dictionary:
	_call_count_last_tick += 1
	if not UIAudio.should_play(event, _time_since_hover, _time_since_click):
		return {"play": false, "reason": "cooldown", "event": event, "event_name": UIAudio.event_name(event)}
	if event == UIEvent.HOVER:
		_time_since_hover = 0.0
	if event == UIEvent.CLICK or event == UIEvent.SELECT:
		_time_since_click = 0.0
	_last_event = event
	var params := UIAudio.audio_params_for_event(event)
	if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
		push_warning("[UIAudio] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
	return params

func notify_click() -> Dictionary:
	return notify_event(UIEvent.CLICK)

func notify_hover() -> Dictionary:
	return notify_event(UIEvent.HOVER)

func notify_back() -> Dictionary:
	return notify_event(UIEvent.BACK)

func get_call_count() -> int:
	return _call_count_last_tick

func reset() -> void:
	_call_count_last_tick = 0
	_time_since_hover = 999.0
	_time_since_click = 999.0
	_last_event = -1

# ---------------------------------------------------------------------------
# Attachment helper — attach UI audio to a Control/CanvasLayer (non-positional)
# ---------------------------------------------------------------------------

static func create_player(event: int = UIEvent.CLICK) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = "UIAudio_%s" % UIAudio.event_name(event)
	player.bus = AUDIO_BUS
	player.pitch_scale = UIAudio.pitch_for_event(event)
	player.volume_db = VOLUME_SILENT_DB
	player.autoplay = false
	var path := UIAudio.path_for_event(event)
	if ResourceLoader.exists(path):
		var stream: Resource = load(path)
		if stream is AudioStream:
			player.stream = stream as AudioStream
	return player

static func attach_to_control(control_node: Control) -> Dictionary:
	if control_node == null:
		return {"click": create_player(UIEvent.CLICK), "hover": create_player(UIEvent.HOVER)}
	var out: Dictionary = {}
	for ev in [UIEvent.CLICK, UIEvent.HOVER, UIEvent.BACK]:
		var nm := "UIAudio_%s" % UIAudio.event_name(ev)
		var existing := control_node.get_node_or_null(nm) as AudioStreamPlayer
		if existing == null:
			existing = create_player(ev)
			control_node.add_child(existing)
		out[UIAudio.event_name(ev)] = existing
	return out

static func apply_to_player(player: AudioStreamPlayer, pitch: float, volume_db: float, play_now: bool = true) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.pitch_scale = clamp(pitch, PITCH_MIN, PITCH_MAX)
	player.volume_db = clamp(volume_db, VOLUME_SILENT_DB, 6.0)
	if play_now:
		player.stop()
		player.play()

static func get_click_path() -> String:
	return CLICK_PATH

# ---------------------------------------------------------------------------
# Validation & telemetry — conventions §11 — budget-aware (<4ms)
# ---------------------------------------------------------------------------

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA != 1/120")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if MAX_CALLS_PER_TICK != 12:
		errors.append("MAX_CALLS_PER_TICK %d != 12" % MAX_CALLS_PER_TICK)
	if BUDGET_CALLS != 12:
		errors.append("BUDGET_CALLS %d != 12" % BUDGET_CALLS)
	if AUDIO_BUS != "UI":
		errors.append("AUDIO_BUS %s != UI" % AUDIO_BUS)
	for p in [CLICK_PATH, HOVER_PATH, BACK_PATH, OPEN_PATH, CLOSE_PATH, ERROR_PATH, TOGGLE_PATH]:
		if not p.begins_with("res://assets/authored/audio_ui/"):
			errors.append("path %s must be under assets/authored/audio_ui/" % p)
		if not p.ends_with(".ogg"):
			errors.append("path %s must be .ogg" % p)
	if HOVER_COOLDOWN <= 0.0 or CLICK_COOLDOWN <= 0.0:
		errors.append("cooldowns must be >0")
	var v := volume_db_for_event(UIEvent.CLICK)
	if not is_equal_approx(v, VOLUME_CLICK_DB):
		errors.append("volume click mismatch")
	var pit := pitch_for_event(UIEvent.HOVER)
	if not is_equal_approx(pit, PITCH_HOVER):
		errors.append("pitch hover mismatch %.3f != %.3f" % [pit, PITCH_HOVER])
	var params := audio_params_for_event(UIEvent.BACK)
	if params["bus"] != "UI":
		errors.append("params bus != UI")
	if params["path"] != BACK_PATH:
		errors.append("params path != BACK_PATH")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_validate_static() -> Dictionary:
	return debug_validate()

static func debug_export() -> Dictionary:
	return {
		"click_path": CLICK_PATH, "hover_path": HOVER_PATH, "back_path": BACK_PATH,
		"open_path": OPEN_PATH, "close_path": CLOSE_PATH, "error_path": ERROR_PATH,
		"toggle_path": TOGGLE_PATH, "audio_bus": AUDIO_BUS,
		"volume_click_db": VOLUME_CLICK_DB, "volume_hover_db": VOLUME_HOVER_DB,
		"pitch_click": PITCH_CLICK, "pitch_hover": PITCH_HOVER,
		"hover_cooldown": HOVER_COOLDOWN, "click_cooldown": CLICK_COOLDOWN,
		"physics_ticks": PHYSICS_TICKS_PER_SECOND, "budget_calls": BUDGET_CALLS,
	}

func debug_export_instance() -> Dictionary:
	var d := UIAudio.debug_export()
	d["call_count"] = _call_count_last_tick
	d["last_event"] = _last_event
	return d

static func perf_mark() -> Dictionary:
	return {"scope": "UIAudio", "budget_calls": BUDGET_CALLS, "max_calls": MAX_CALLS_PER_TICK, "tick_hz": TICK_HZ, "bus": AUDIO_BUS}

func perf_mark_instance() -> Dictionary:
	return {"scope": "UIAudio", "calls_last_tick": _call_count_last_tick, "budget": MAX_CALLS_PER_TICK, "budget_ok": _call_count_last_tick <= MAX_CALLS_PER_TICK}

static func perf_budget() -> Dictionary:
	return {"max_calls_per_tick": MAX_CALLS_PER_TICK, "tick_hz": TICK_HZ, "budget_ms": 4.0}
