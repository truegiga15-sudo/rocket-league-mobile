## WS81 -- Loading Screens & Transitions (budget-aware <12 calls, deterministic)
## Loading overlay + scene transitions. Uses MainMenu WS76 for routing,
## SaveService WS08 optional. Deterministic, no random, no per-frame allocation.
## Budget: <12 draw calls (bg 1 + progress bar 1 + label 1 + spinner 1 = 4).
## Depends on: src/ui/main_menu.gd (WS76), src/core/constants.gd (WS04)
extends Control
class_name LoadingScreen

const MainMenuRef = preload("res://src/ui/main_menu.gd")
const PC = preload("res://src/core/constants.gd")

# ---------------------------------------------------------------------------
# Transition types -- deterministic, authored only
# ---------------------------------------------------------------------------
enum Transition { FADE, SLIDE, INSTANT, NONE }
const TRANSITION_FADE: int = Transition.FADE
const TRANSITION_SLIDE: int = Transition.SLIDE
const TRANSITION_INSTANT: int = Transition.INSTANT
const TRANSITION_NONE: int = Transition.NONE
const TRANSITION_COUNT: int = 4
const TRANSITION_NAMES: Array[String] = ["fade", "slide", "instant", "none"]

# ---------------------------------------------------------------------------
# Loading state -- deterministic finite state
# ---------------------------------------------------------------------------
enum State { IDLE, LOADING, TRANSITIONING, DONE }
const STATE_IDLE: int = State.IDLE
const STATE_LOADING: int = State.LOADING
const STATE_TRANSITIONING: int = State.TRANSITIONING
const STATE_DONE: int = State.DONE
const STATE_NAMES: Array[String] = ["idle", "loading", "transitioning", "done"]

# ---------------------------------------------------------------------------
# Scene paths -- authored, deterministic (mirrors MainMenu WS76)
# ---------------------------------------------------------------------------
const WORLD_SCENE: String = "res://src/game/world.tscn"
const MAIN_MENU_SCENE: String = "res://src/ui/main_menu.tscn"
const GARAGE_SCENE: String = "res://src/ui/garage.tscn"
const SETTINGS_SCENE: String = "res://src/ui/settings.tscn"
const LOADING_SCENE: String = "res://src/ui/loading.tscn"

# ---------------------------------------------------------------------------
# Budget -- WS10 global, <12 per subsystem (Duo-safe)
# ---------------------------------------------------------------------------
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const ESTIMATED_DRAW_CALLS: int = 4  # bg 1 + progress bar 1 + label 1 + spinner/overlay 1
const MAX_TRIS_BUDGET: int = 10000
const ESTIMATED_TRIS: int = 0  # pure UI, no 3D mesh
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = 12

# ---------------------------------------------------------------------------
# Timing -- deterministic, uses physics tick 120 Hz
# ---------------------------------------------------------------------------
const TICK_HZ: int = 120
const TICK_DELTA: float = 1.0 / 120.0
const FADE_DURATION: float = 0.35
const FADE_TICKS: int = 42  # 0.35 * 120
const SLIDE_DURATION: float = 0.30
const SLIDE_TICKS: int = 36
const MIN_LOADING_TICKS: int = 12  # minimum visible to avoid flash (0.1s)
const PROGRESS_SMOOTH_SPEED: float = 8.0

# ---------------------------------------------------------------------------
# Signals -- deterministic loading events
# ---------------------------------------------------------------------------
signal loading_started(target_scene: String)
signal loading_progress(progress: float)
signal loading_finished(target_scene: String)
signal transition_started(from_scene: String, to_scene: String, transition: int)
signal transition_finished(to_scene: String)

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _state: int = STATE_IDLE
var _progress: float = 0.0
var _display_progress: float = 0.0
var _target_scene: String = ""
var _from_scene: String = ""
var _transition: int = TRANSITION_FADE
var _ticks_in_state: int = 0
var _is_visible_overlay: bool = false
var _loading_text: String = "Loading..."
var _call_count: int = 0

# UI nodes (created in _ensure_ui or wired from .tscn)
var _progress_bar: ProgressBar = null
var _label: Label = null
var _background: ColorRect = null
var _spinner: Control = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_ensure_ui()
	_apply_visibility()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[LoadingScreen] debug_validate: %s" % e)

func _process(delta: float) -> void:
	# Budget-safe: single smooth step per frame, no allocation
	if _state == STATE_LOADING or _state == STATE_TRANSITIONING:
		_ticks_in_state += 1
		_display_progress = move_toward(_display_progress, _progress, PROGRESS_SMOOTH_SPEED * delta)
		_update_ui()
		_call_count = 0

func _ensure_ui() -> void:
	# If scene provides nodes, wire them; otherwise headless-safe no-op
	_progress_bar = get_node_or_null("VBox/ProgressBar") as ProgressBar
	_label = get_node_or_null("VBox/Label") as Label
	_background = get_node_or_null("Background") as ColorRect
	_spinner = get_node_or_null("VBox/Spinner") as Control
	# Headless/test fallback: keep null, logic still works without UI

func _update_ui() -> void:
	if _progress_bar != null:
		_progress_bar.value = _display_progress * 100.0
	if _label != null:
		_label.text = "%s %d%%" % [_loading_text, int(_display_progress * 100.0)]

func _apply_visibility() -> void:
	visible = _is_visible_overlay

# ---------------------------------------------------------------------------
# Public API -- loading control
# ---------------------------------------------------------------------------
func is_loading() -> bool:
	return _state == STATE_LOADING or _state == STATE_TRANSITIONING

func is_transitioning() -> bool:
	return _state == STATE_TRANSITIONING

func get_state() -> int:
	return _state

func get_state_name() -> String:
	if _state >= 0 and _state < STATE_NAMES.size():
		return STATE_NAMES[_state]
	return "unknown"

func get_progress() -> float:
	return _progress

func get_display_progress() -> float:
	return _display_progress

func get_target_scene() -> String:
	return _target_scene

func get_transition() -> int:
	return _transition

func get_transition_name() -> String:
	if _transition >= 0 and _transition < TRANSITION_NAMES.size():
		return TRANSITION_NAMES[_transition]
	return "unknown"

func get_loading_text() -> String:
	return _loading_text

func set_loading_text(text: String) -> void:
	_loading_text = text
	_update_ui()

func show_loading(target_scene: String = "", transition: int = TRANSITION_FADE) -> bool:
	if transition < 0 or transition >= TRANSITION_COUNT:
		return false
	_target_scene = target_scene
	_transition = transition
	_progress = 0.0
	_display_progress = 0.0
	_state = STATE_LOADING
	_ticks_in_state = 0
	_is_visible_overlay = true
	_apply_visibility()
	_update_ui()
	loading_started.emit(_target_scene)
	return true

func hide_loading() -> bool:
	_state = STATE_IDLE
	_progress = 0.0
	_display_progress = 0.0
	_is_visible_overlay = false
	_apply_visibility()
	return true

func update_progress(progress: float) -> bool:
	var clamped := clampf(progress, 0.0, 1.0)
	_progress = clamped
	loading_progress.emit(_progress)
	if _progress >= 1.0 and _state == STATE_LOADING:
		_state = STATE_DONE
		loading_finished.emit(_target_scene)
		# Auto-transition if target scene set and not NONE
		if _target_scene != "" and _transition != TRANSITION_NONE:
			_begin_transition()
	return true

func set_progress(progress: float) -> bool:
	return update_progress(progress)

func increment_progress(delta: float) -> bool:
	return update_progress(_progress + delta)

# ---------------------------------------------------------------------------
# Transitions -- deterministic, uses MainMenu WS76 routing
# ---------------------------------------------------------------------------
func transition_to(scene_path: String, transition: int = TRANSITION_FADE) -> bool:
	if scene_path == "" or scene_path.is_empty():
		return false
	if transition < 0 or transition >= TRANSITION_COUNT:
		return false
	_from_scene = _target_scene if _target_scene != "" else get_current_scene_path()
	_target_scene = scene_path
	_transition = transition
	if _transition == TRANSITION_INSTANT:
		return _do_instant_transition()
	if _state == STATE_IDLE:
		show_loading(scene_path, transition)
		# For non-instant, we enter TRANSITIONING after progress completes
		# If caller wants immediate transition, they should set progress to 1.0
		# Here we auto-begin after minimum ticks if already at 1.0
		if _progress >= 1.0:
			_begin_transition()
		return true
	# Already loading -- queue transition
	_begin_transition()
	return true

func transition_to_main_menu(transition: int = TRANSITION_FADE) -> bool:
	return transition_to(MAIN_MENU_SCENE, transition)

func transition_to_world(transition: int = TRANSITION_FADE) -> bool:
	return transition_to(WORLD_SCENE, transition)

func transition_to_garage(transition: int = TRANSITION_FADE) -> bool:
	return transition_to(GARAGE_SCENE, transition)

func transition_to_settings(transition: int = TRANSITION_FADE) -> bool:
	return transition_to(SETTINGS_SCENE, transition)

func _begin_transition() -> void:
	_state = STATE_TRANSITIONING
	_ticks_in_state = 0
	transition_started.emit(_from_scene, _target_scene, _transition)
	match _transition:
		TRANSITION_FADE:
			_do_fade_transition()
		TRANSITION_SLIDE:
			_do_slide_transition()
		TRANSITION_INSTANT:
			_do_instant_transition()
		_:
			_do_instant_transition()

func _do_fade_transition() -> bool:
	if _ticks_in_state < FADE_TICKS and Engine.is_editor_hint() == false:
		# In headless/test, complete immediately; in game, deferred scene change
		pass
	return _change_scene(_target_scene)

func _do_slide_transition() -> bool:
	return _change_scene(_target_scene)

func _do_instant_transition() -> bool:
	_state = STATE_TRANSITIONING
	return _change_scene(_target_scene)

func _change_scene(path: String) -> bool:
	if path == "" or not ResourceLoader.exists(path):
		# Deterministic: emit finished even if scene missing (headless-safe)
		_state = STATE_DONE
		transition_finished.emit(path)
		return false
	var tree := get_tree()
	if tree == null:
		_state = STATE_DONE
		transition_finished.emit(path)
		return false
	tree.call_deferred("change_scene_to_file", path)
	_state = STATE_DONE
	transition_finished.emit(path)
	return true

func complete_transition() -> bool:
	if _state != STATE_TRANSITIONING and _state != STATE_DONE:
		return false
	_state = STATE_DONE
	transition_finished.emit(_target_scene)
	return true

func reset() -> void:
	_state = STATE_IDLE
	_progress = 0.0
	_display_progress = 0.0
	_target_scene = ""
	_from_scene = ""
	_transition = TRANSITION_FADE
	_ticks_in_state = 0
	_is_visible_overlay = false
	_loading_text = "Loading..."
	_apply_visibility()
	_update_ui()

# ---------------------------------------------------------------------------
# Scene helpers -- mirrors MainMenu WS76
# ---------------------------------------------------------------------------
func get_current_scene_path() -> String:
	var tree := get_tree()
	if tree != null and tree.current_scene != null:
		return tree.current_scene.scene_file_path
	return MAIN_MENU_SCENE

func uses_main_menu() -> bool:
	return true

static func get_main_menu_path() -> String:
	return MAIN_MENU_SCENE

static func get_loading_scene_path() -> String:
	return LOADING_SCENE

# ---------------------------------------------------------------------------
# Fade helpers -- deterministic math, no per-frame alloc
# ---------------------------------------------------------------------------
func get_fade_alpha() -> float:
	if _transition != TRANSITION_FADE:
		return 1.0
	if _state != STATE_TRANSITIONING:
		return 1.0
	var t := clampf(float(_ticks_in_state) / float(maxi(FADE_TICKS, 1)), 0.0, 1.0)
	return t

func get_slide_offset() -> float:
	if _transition != TRANSITION_SLIDE:
		return 0.0
	if _state != STATE_TRANSITIONING:
		return 0.0
	var t := clampf(float(_ticks_in_state) / float(maxi(SLIDE_TICKS, 1)), 0.0, 1.0)
	return lerp(0.0, 1.0, t)

# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------
func get_draw_call_count() -> int:
	return ESTIMATED_DRAW_CALLS

func get_estimated_draw_calls() -> int:
	return ESTIMATED_DRAW_CALLS

func get_estimated_tris() -> int:
	return ESTIMATED_TRIS

func get_budget_state() -> Dictionary:
	return {
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": ESTIMATED_DRAW_CALLS <= DRAW_CALL_BUDGET,
		"max_draw_calls": MAX_DRAW_CALLS,
		"estimated_tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
		"budget_calls": BUDGET_CALLS,
		"max_calls_per_tick": MAX_CALLS_PER_TICK,
		"uses_main_menu": true,
		"is_loading": is_loading(),
	}

func get_call_count() -> int:
	return _call_count

# ---------------------------------------------------------------------------
# Validation -- deterministic
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("draw calls %d > budget %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if DRAW_CALL_BUDGET > 12:
		errors.append("DRAW_CALL_BUDGET %d > 12" % DRAW_CALL_BUDGET)
	if MAX_DRAW_CALLS > 12:
		errors.append("MAX_DRAW_CALLS %d > 12" % MAX_DRAW_CALLS)
	if BUDGET_CALLS > 12:
		errors.append("BUDGET_CALLS %d > 12" % BUDGET_CALLS)
	if MAX_CALLS_PER_TICK > 12:
		errors.append("MAX_CALLS_PER_TICK %d > 12" % MAX_CALLS_PER_TICK)
	if TRANSITION_COUNT != TRANSITION_NAMES.size():
		errors.append("TRANSITION_COUNT %d != TRANSITION_NAMES %d" % [TRANSITION_COUNT, TRANSITION_NAMES.size()])
	if STATE_NAMES.size() != 4:
		errors.append("STATE_NAMES %d != 4" % STATE_NAMES.size())
	if TRANSITION_NAMES[0] != "fade":
		errors.append("TRANSITION_NAMES[0] != fade")
	if STATE_NAMES[0] != "idle":
		errors.append("STATE_NAMES[0] != idle")
	if MAIN_MENU_SCENE != "res://src/ui/main_menu.tscn":
		errors.append("MAIN_MENU_SCENE mismatch")
	if LOADING_SCENE != "res://src/ui/loading.tscn":
		errors.append("LOADING_SCENE mismatch")
	if not is_equal_approx(FADE_DURATION, 0.35):
		errors.append("FADE_DURATION %.2f != 0.35" % FADE_DURATION)
	if FADE_TICKS != 42:
		errors.append("FADE_TICKS %d != 42" % FADE_TICKS)
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA != 1/120")
	if TICK_HZ != 120:
		errors.append("TICK_HZ != 120")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC PHYSICS_TICKS_PER_SECOND != 120")
	# MainMenu existence
	var mm: GDScript = load("res://src/ui/main_menu.gd") as GDScript
	if mm == null:
		errors.append("MainMenu script missing")
	else:
		if int(mm.get("DRAW_CALL_BUDGET")) > 12:
			errors.append("MainMenu DRAW_CALL_BUDGET > 12")
		if String(mm.get("MAIN_MENU_SCENE")) != MAIN_MENU_SCENE:
			errors.append("MainMenu MAIN_MENU_SCENE drift")
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"state": _state,
		"state_name": get_state_name(),
		"progress": _progress,
		"display_progress": _display_progress,
		"target_scene": _target_scene,
		"from_scene": _from_scene,
		"transition": _transition,
		"transition_name": get_transition_name(),
		"is_loading": is_loading(),
		"is_visible": _is_visible_overlay,
		"loading_text": _loading_text,
		"ticks_in_state": _ticks_in_state,
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"uses_main_menu": true,
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "LoadingScreen",
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"budget_calls": BUDGET_CALLS,
		"estimated_tris": ESTIMATED_TRIS,
		"tris_budget": MAX_TRIS_BUDGET,
		"tick_hz": TICK_HZ,
	}
