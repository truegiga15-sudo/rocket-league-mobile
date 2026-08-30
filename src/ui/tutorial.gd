# WS82 Onboarding Tutorial Hints — budget-aware <12 calls, solo retry
# Steps: MOVE (joystick WS26) -> BOOST (button cluster WS28) -> JUMP (WS28) -> BALL_CAM (camera WS29/ball_cam)
# Uses: TouchJoystick WS26, TouchButtonCluster WS28, HUD WS77, BallCam.
# Solo offline tutorial overlay. Event-driven, no _process polling. Retries on failure.
# Provides debug_export() and perf_mark() per 00-conventions.md §11.
extends Control
class_name Tutorial

# ---------------------------------------------------------------------------
# Steps — linear solo flow
# ---------------------------------------------------------------------------
enum Step {
	MOVE = 0,
	BOOST = 1,
	JUMP = 2,
	BALL_CAM = 3,
	COMPLETE = 4,
}

const STEP_HINTS: Dictionary = {
	Step.MOVE: "Move: Drag the left joystick to drive",
	Step.BOOST: "Boost: Hold BOOST to go faster",
	Step.JUMP: "Jump: Tap JUMP to hop",
	Step.BALL_CAM: "Ball Cam: Tap the camera button to toggle ball cam",
	Step.COMPLETE: "Nice! Tutorial complete",
}

const SAVE_KEY: String = "tutorial_completed_v1"

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
## Auto-advance when condition met (if false, requires explicit tap to continue)
@export var auto_advance: bool = true
## Minimum hold/move duration to count as completed (seconds)
@export var move_hold_seconds: float = 0.6
## Boost hold duration to count
@export var boost_hold_seconds: float = 0.4
## Hint fade duration
@export var hint_fade_ms: float = 200.0
## Allow skipping tutorial
@export var allow_skip: bool = true
## Highlight opacity
@export var highlight_alpha: float = 0.25

# ---------------------------------------------------------------------------
# Internal state — event-driven, no per-frame cost
# ---------------------------------------------------------------------------
var _current_step: Step = Step.MOVE
var _completed: bool = false
var _skipped: bool = false
var _initialized: bool = false
var _perf_samples: int = 0
var _step_started_at: float = 0.0
var _move_accum: float = 0.0
var _boost_accum: float = 0.0

# Cached refs (optional — works without them via signals)
var _joystick: Control = null
var _button_cluster: Control = null
var _ball_cam: Node = null
var _hud: Control = null
var _hint_label: Label = null
var _highlight: Control = null
var _skip_button: BaseButton = null

signal step_completed(step: Step)
signal tutorial_completed(success: bool)
signal tutorial_skipped

func _ready() -> void:
	_cache_nodes()
	_bind_signals()
	_load_progress()
	if _completed:
		_current_step = Step.COMPLETE
		_apply_step_visual(Step.COMPLETE)
	else:
		_current_step = Step.MOVE
		_show_step(_current_step)
	_initialized = true
	_perf_samples += 1
	notification(NOTIFICATION_RESIZED)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_position_hints()

# ---------------------------------------------------------------------------
# Node cache — tolerant to scene variations / tests
# ---------------------------------------------------------------------------
func _cache_nodes() -> void:
	_joystick = get_node_or_null("TouchJoystick") as Control
	if _joystick == null:
		_joystick = get_node_or_null("%TouchJoystick") as Control
	if _joystick == null and get_tree() != null:
		_joystick = get_tree().root.find_child("TouchJoystick", true, false) as Control
	_button_cluster = get_node_or_null("TouchButtonCluster") as Control
	if _button_cluster == null:
		_button_cluster = get_node_or_null("%TouchButtonCluster") as Control
	if _button_cluster == null and get_tree() != null:
		_button_cluster = get_tree().root.find_child("TouchButtonCluster", true, false) as Control
	if get_tree() != null:
		_ball_cam = get_tree().root.find_child("BallCam", true, false)
		if _ball_cam == null:
			_ball_cam = get_tree().root.find_child("CameraRig", true, false)
	_hud = get_node_or_null("HUD") as Control
	if _hud == null and get_tree() != null:
		_hud = get_tree().root.find_child("HUD", true, false)
		if _hud == null:
			_hud = get_tree().root.find_child("Hud", true, false)
	_hint_label = get_node_or_null("HintLabel") as Label
	if _hint_label == null:
		_hint_label = Label.new()
		_hint_label.name = "HintLabel"
		_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_hint_label.add_theme_font_size_override("font_size", 22)
		add_child(_hint_label)
	_highlight = get_node_or_null("Highlight") as Control
	if _highlight == null:
		_highlight = ColorRect.new()
		_highlight.name = "Highlight"
		_highlight.color = Color(1, 0.92, 0.2, highlight_alpha)
		_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_highlight.visible = false
		add_child(_highlight)
		move_child(_highlight, 0)
	_skip_button = get_node_or_null("SkipButton") as BaseButton
	if _skip_button == null:
		var btn := Button.new()
		btn.name = "SkipButton"
		btn.text = "Skip"
		btn.visible = allow_skip
		btn.size = Vector2(96, 36)
		add_child(btn)
		_skip_button = btn
	_position_hints()
	_apply_step_visual(_current_step)

func _position_hints() -> void:
	var vp := get_viewport_rect().size
	if vp.x <= 0 or vp.y <= 0:
		return
	if _hint_label != null:
		_hint_label.size = Vector2(vp.x * 0.8, 44)
		_hint_label.position = Vector2(vp.x * 0.1, vp.y * 0.12)
	if _skip_button != null:
		_skip_button.position = Vector2(vp.x - 108, 12)

func _bind_signals() -> void:
	if _joystick != null and _joystick.has_signal("joystick_moved"):
		if not _joystick.is_connected("joystick_moved", _on_joystick_moved):
			_joystick.connect("joystick_moved", _on_joystick_moved)
		if _joystick.has_signal("joystick_released") and not _joystick.is_connected("joystick_released", _on_joystick_released):
			_joystick.connect("joystick_released", _on_joystick_released)
	if _button_cluster != null:
		if _button_cluster.has_signal("boost_state_changed") and not _button_cluster.is_connected("boost_state_changed", _on_boost_changed):
			_button_cluster.connect("boost_state_changed", _on_boost_changed)
		if _button_cluster.has_signal("jump_state_changed") and not _button_cluster.is_connected("jump_state_changed", _on_jump_changed):
			_button_cluster.connect("jump_state_changed", _on_jump_changed)
	if _ball_cam != null and _ball_cam.has_signal("ball_cam_toggled"):
		if not _ball_cam.is_connected("ball_cam_toggled", _on_ball_cam_toggled):
			_ball_cam.connect("ball_cam_toggled", _on_ball_cam_toggled)
	if _skip_button != null and _skip_button.has_signal("pressed"):
		if not _skip_button.is_connected("pressed", _on_skip_pressed):
			_skip_button.connect("pressed", _on_skip_pressed)
	if _hud != null and _hud.has_signal("ball_cam_requested"):
		if not _hud.is_connected("ball_cam_requested", _on_ball_cam_toggled_generic):
			_hud.connect("ball_cam_requested", _on_ball_cam_toggled_generic)

# ---------------------------------------------------------------------------
# Step display
# ---------------------------------------------------------------------------
func _show_step(step: Step) -> void:
	_current_step = step
	_step_started_at = Time.get_ticks_msec() / 1000.0
	_move_accum = 0.0
	_boost_accum = 0.0
	_apply_step_visual(step)
	_perf_samples += 1

func _apply_step_visual(step: Step) -> void:
	var hint: String = STEP_HINTS.get(step, "")
	if _hint_label != null:
		_hint_label.text = hint
		_hint_label.visible = step != Step.COMPLETE or not _completed
	if _highlight != null:
		_highlight.visible = step != Step.COMPLETE
		if step != Step.COMPLETE:
			_position_highlight_for(step)
		else:
			_highlight.visible = false
	if _skip_button != null:
		_skip_button.visible = allow_skip and step != Step.COMPLETE
	if _hud != null and _hud.has_method("set_tutorial_highlight"):
		_hud.call("set_tutorial_highlight", step)

func _position_highlight_for(step: Step) -> void:
	if _highlight == null:
		return
	var vp := get_viewport_rect().size
	match step:
		Step.MOVE:
			_highlight.position = Vector2(12, vp.y * 0.35)
			_highlight.size = Vector2(vp.x * 0.32, vp.y * 0.4)
		Step.BOOST:
			_highlight.position = Vector2(vp.x - 140, vp.y - 140)
			_highlight.size = Vector2(100, 100)
		Step.JUMP:
			_highlight.position = Vector2(vp.x - 230, vp.y - 130)
			_highlight.size = Vector2(90, 90)
		Step.BALL_CAM:
			_highlight.position = Vector2(vp.x - 180, 60)
			_highlight.size = Vector2(120, 48)
		_:
			_highlight.visible = false

# ---------------------------------------------------------------------------
# Event handlers — all advancement is event-driven
# ---------------------------------------------------------------------------
func _on_joystick_moved(value: Vector2, active: bool) -> void:
	if _completed or _current_step != Step.MOVE:
		return
	if active and value.length() > 0.35:
		_move_accum += 0.08
		if _move_accum >= move_hold_seconds or value.length() > 0.7:
			_advance()
	else:
		_move_accum = max(0.0, _move_accum - 0.02)

func _on_joystick_released() -> void:
	pass

func _on_boost_changed(pressed: bool) -> void:
	if _completed or _current_step != Step.BOOST:
		return
	if pressed:
		_boost_accum += 0.1
		if _boost_accum >= boost_hold_seconds:
			_advance()
	else:
		if _boost_accum > 0.15:
			_advance()

func _on_jump_changed(pressed: bool) -> void:
	if _completed or _current_step != Step.JUMP:
		return
	if pressed:
		_advance()

func _on_ball_cam_toggled(_enabled: bool = false) -> void:
	if _completed or _current_step != Step.BALL_CAM:
		return
	_advance()

func _on_ball_cam_toggled_generic() -> void:
	_on_ball_cam_toggled(true)

func _on_skip_pressed() -> void:
	skip_tutorial()

func _unhandled_input(event: InputEvent) -> void:
	if _completed:
		return
	match _current_step:
		Step.MOVE:
			if event is InputEventJoypadMotion or event is InputEventKey:
				if Input.get_vector("move_left", "move_right", "move_forward", "move_back").length() > 0.3:
					_on_joystick_moved(Vector2(0.6, 0), true)
		Step.BOOST:
			if event.is_action_pressed("boost"):
				_on_boost_changed(true)
		Step.JUMP:
			if event.is_action_pressed("jump"):
				_on_jump_changed(true)
		Step.BALL_CAM:
			if event.is_action_pressed("ball_cam_toggle") or event.is_action_pressed("toggle_ball_cam"):
				_on_ball_cam_toggled(true)

# ---------------------------------------------------------------------------
# Progression
# ---------------------------------------------------------------------------
func _advance() -> void:
	var finished_step: Step = _current_step
	emit_signal("step_completed", finished_step)
	_perf_samples += 1
	var next := int(_current_step) + 1
	if next >= Step.COMPLETE:
		_complete_tutorial()
	else:
		_show_step(next as Step)

func _complete_tutorial() -> void:
	_current_step = Step.COMPLETE
	_completed = true
	_apply_step_visual(Step.COMPLETE)
	_save_progress()
	emit_signal("tutorial_completed", true)
	if _hint_label != null:
		_hint_label.text = STEP_HINTS[Step.COMPLETE]
		if hint_fade_ms > 0:
			await get_tree().create_timer(hint_fade_ms / 1000.0 * 3.0).timeout
			_hint_label.visible = false
		if _skip_button != null:
			_skip_button.visible = false

func skip_tutorial() -> void:
	if _completed:
		return
	_skipped = true
	_completed = true
	_current_step = Step.COMPLETE
	_apply_step_visual(Step.COMPLETE)
	if _hint_label != null:
		_hint_label.visible = false
	if _highlight != null:
		_highlight.visible = false
	emit_signal("tutorial_skipped")
	emit_signal("tutorial_completed", false)
	_save_progress()

func reset_tutorial() -> void:
	_completed = false
	_skipped = false
	_current_step = Step.MOVE
	_clear_save()
	_show_step(Step.MOVE)
	if _hint_label != null:
		_hint_label.visible = true

# ---------------------------------------------------------------------------
# Persistence — SaveService WS08 / ConfigService fallback, else ConfigFile
# ---------------------------------------------------------------------------
func _save_progress() -> void:
	var svc: Node = _get_save_service()
	if svc != null and svc.has_method("set_value"):
		svc.call("set_value", SAVE_KEY, true)
		if svc.has_method("save_now"):
			svc.call("save_now")
		return
	var cfg := ConfigFile.new()
	var path := "user://tutorial.cfg"
	cfg.load(path)
	cfg.set_value("tutorial", "completed", true)
	cfg.save(path)

func _load_progress() -> void:
	var svc: Node = _get_save_service()
	if svc != null and svc.has_method("get_value"):
		var v = svc.call("get_value", SAVE_KEY, false)
		_completed = bool(v)
		return
	var cfg := ConfigFile.new()
	if cfg.load("user://tutorial.cfg") == OK:
		_completed = bool(cfg.get_value("tutorial", "completed", false))

func _clear_save() -> void:
	var svc: Node = _get_save_service()
	if svc != null and svc.has_method("set_value"):
		svc.call("set_value", SAVE_KEY, false)
		return
	var cfg := ConfigFile.new()
	cfg.load("user://tutorial.cfg")
	cfg.set_value("tutorial", "completed", false)
	cfg.save("user://tutorial.cfg")

func _get_save_service() -> Node:
	if get_tree() == null:
		return null
	var svc: Node = get_tree().root.get_node_or_null("SaveService")
	if svc != null:
		return svc
	svc = get_tree().root.get_node_or_null("ConfigService")
	return svc

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
func get_current_step() -> Step:
	return _current_step

func is_completed() -> bool:
	return _completed

func is_skipped() -> bool:
	return _skipped

func get_hint_for(step: Step) -> String:
	return STEP_HINTS.get(step, "")

func retry() -> void:
	reset_tutorial()

# ---------------------------------------------------------------------------
# Telemetry — per 00-conventions.md §11
# ---------------------------------------------------------------------------
func debug_export() -> Dictionary:
	return {
		"current_step": _current_step,
		"step_name": STEP_HINTS.get(_current_step, ""),
		"completed": _completed,
		"skipped": _skipped,
		"move_accum": _move_accum,
		"boost_accum": _boost_accum,
		"initialized": _initialized,
	}

func perf_mark() -> Dictionary:
	_perf_samples += 1
	return {
		"samples": _perf_samples,
		"step": _current_step,
		"completed": _completed,
	}
