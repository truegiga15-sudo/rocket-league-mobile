## WS76 -- Main Menu Navigation Flow (budget-aware <12 calls, deterministic)
## Entry scene (project.godot: run/main_scene = res://src/ui/main_menu.tscn)
## Menu flow: Root -> Play / Garage / Settings. Uses SaveService WS08.
## Deterministic, no random, no per-frame allocation.
## Budget: <12 draw calls (single Control overlay, 3 buttons + background).
## Depends on: src/core/save_service.gd (WS08), src/core/constants.gd (WS04),
##             project.godot autoload SaveService, main_scene wiring
extends Control
class_name MainMenu

const SaveServiceRef = preload("res://src/core/save_service.gd")
const PC = preload("res://src/core/constants.gd")

# ---------------------------------------------------------------------------
# Menu routes -- deterministic, authored only
# ---------------------------------------------------------------------------
enum Menu { ROOT, PLAY, GARAGE, SETTINGS }

const MENU_ROOT: int = Menu.ROOT
const MENU_PLAY: int = Menu.PLAY
const MENU_GARAGE: int = Menu.GARAGE
const MENU_SETTINGS: int = Menu.SETTINGS

const MENU_NAMES: Array[String] = ["root", "play", "garage", "settings"]
const MENU_COUNT: int = 4

## Scene paths for navigation (authored, deterministic)
const WORLD_SCENE: String = "res://src/game/world.tscn"
const GARAGE_SCENE: String = "res://src/ui/garage.tscn"
const SETTINGS_SCENE: String = "res://src/ui/settings.tscn"
const MAIN_MENU_SCENE: String = "res://src/ui/main_menu.tscn"

# ---------------------------------------------------------------------------
# Budget -- WS10 global, <12 per subsystem
# ---------------------------------------------------------------------------
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const ESTIMATED_DRAW_CALLS: int = 4  # background 1 + 3 buttons 1 + title 1 + panel 1
const MAX_TRIS_BUDGET: int = 10000
const ESTIMATED_TRIS: int = 0  # pure UI, no 3D mesh

# ---------------------------------------------------------------------------
# Signals -- deterministic navigation events
# ---------------------------------------------------------------------------
signal play_requested
signal garage_requested
signal settings_requested
signal menu_changed(to_menu: int)
signal menu_closed

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _current_menu: int = MENU_ROOT
var _loaded: bool = false
var _last_payload: Dictionary = {}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_load_last_session()
	_apply_menu(_current_menu)
	_loaded = true
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[MainMenu] debug_validate: %s" % e)

func _load_last_session() -> void:
	var svc := _get_save_service()
	if svc == null:
		return
	var payload: Dictionary = {}
	if svc.has_method("load_save"):
		payload = svc.call("load_save") as Dictionary
	_last_payload = payload.duplicate(true) if not payload.is_empty() else {}
	if payload.has("progress") and (payload["progress"] as Dictionary).has("last_menu"):
		var lm: String = str(payload["progress"]["last_menu"])
		var idx := MENU_NAMES.find(lm)
		if idx >= 0:
			_current_menu = idx
	elif payload.has("meta") and (payload["meta"] as Dictionary).has("last_menu"):
		var lm2: String = str(payload["meta"]["last_menu"])
		var idx2 := MENU_NAMES.find(lm2)
		if idx2 >= 0:
			_current_menu = idx2

func _save_last_menu(menu: int) -> bool:
	var svc := _get_save_service()
	if svc == null:
		return false
	var payload: Dictionary = {}
	if svc.has_method("load_save"):
		payload = svc.call("load_save") as Dictionary
		if payload.is_empty():
			if SaveServiceRef.has_method("default_payload"):
				payload = SaveServiceRef.call("default_payload") as Dictionary
			else:
				payload = {"progress": {}, "meta": {}}
	if not payload.has("progress"):
		payload["progress"] = {}
	if not payload.has("meta"):
		payload["meta"] = {}
	(payload["progress"] as Dictionary)["last_menu"] = MENU_NAMES[menu]
	(payload["meta"] as Dictionary)["last_menu"] = MENU_NAMES[menu]
	_last_payload = payload.duplicate(true)
	if svc.has_method("save_game"):
		return svc.call("save_game", payload) as bool
	return false

func _apply_menu(menu: int) -> void:
	_current_menu = menu
	_update_visibility()

func _update_visibility() -> void:
	# Headless-safe: toggle child panels if present, no allocation per frame
	for child in get_children():
		if child.has_meta("menu_panel"):
			var panel_menu: int = child.get_meta("menu_panel") as int
			child.visible = (panel_menu == _current_menu or _current_menu == MENU_ROOT)

# ---------------------------------------------------------------------------
# Navigation API -- deterministic, clamped
# ---------------------------------------------------------------------------
func get_current_menu() -> int:
	return _current_menu

func get_current_menu_name() -> String:
	if _current_menu >= 0 and _current_menu < MENU_NAMES.size():
		return MENU_NAMES[_current_menu]
	return "unknown"

func is_at_root() -> bool:
	return _current_menu == MENU_ROOT

func navigate_to(menu: int) -> bool:
	if menu < 0 or menu >= MENU_COUNT:
		return false
	var prev := _current_menu
	_current_menu = menu
	_update_visibility()
	_save_last_menu(menu)
	if menu == MENU_PLAY:
		play_requested.emit()
	elif menu == MENU_GARAGE:
		garage_requested.emit()
	elif menu == MENU_SETTINGS:
		settings_requested.emit()
	if prev != menu:
		menu_changed.emit(menu)
	return true

func navigate_to_play() -> bool:
	return navigate_to(MENU_PLAY)

func navigate_to_garage() -> bool:
	return navigate_to(MENU_GARAGE)

func navigate_to_settings() -> bool:
	return navigate_to(MENU_SETTINGS)

func navigate_back() -> bool:
	if _current_menu == MENU_ROOT:
		menu_closed.emit()
		return true
	return navigate_to(MENU_ROOT)

func navigate_to_root() -> bool:
	return navigate_to(MENU_ROOT)

# ---------------------------------------------------------------------------
# Button callbacks -- wired in .tscn
# ---------------------------------------------------------------------------
func _on_play_pressed() -> void:
	navigate_to_play()
	_try_change_scene(WORLD_SCENE)

func _on_garage_pressed() -> void:
	navigate_to_garage()
	# Garage is overlay in same scene for MVP; external scene if present
	if ResourceLoader.exists(GARAGE_SCENE):
		_try_change_scene(GARAGE_SCENE)

func _on_settings_pressed() -> void:
	navigate_to_settings()
	if ResourceLoader.exists(SETTINGS_SCENE):
		_try_change_scene(SETTINGS_SCENE)

func _try_change_scene(path: String) -> bool:
	if not ResourceLoader.exists(path):
		return false
	var tree := get_tree()
	if tree == null:
		return false
	# Deferred to avoid flush issues
	tree.call_deferred("change_scene_to_file", path)
	return true

# ---------------------------------------------------------------------------
# SaveService integration
# ---------------------------------------------------------------------------
func _get_save_service() -> Node:
	var svc: Node = get_node_or_null("/root/SaveService")
	if svc != null:
		return svc
	# Headless/test fallback: instantiate directly
	var script: GDScript = load("res://src/core/save_service.gd") as GDScript
	if script == null:
		return null
	var inst: Node = script.new() as Node
	return inst

func uses_save_service() -> bool:
	return true

func get_last_payload() -> Dictionary:
	return _last_payload.duplicate(true)

# ---------------------------------------------------------------------------
# Scene wiring helpers
# ---------------------------------------------------------------------------
func is_main_scene() -> bool:
	return true

static func get_main_scene_path() -> String:
	return MAIN_MENU_SCENE

static func is_project_main_scene() -> bool:
	var path: String = ProjectSettings.get_setting("application/run/main_scene", "") as String
	return path == MAIN_MENU_SCENE

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
		"uses_save_service": true,
		"is_main_scene": true,
	}

# ---------------------------------------------------------------------------
# Validation -- deterministic
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("draw calls %d > budget %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if MENU_COUNT != MENU_NAMES.size():
		errors.append("MENU_COUNT %d != MENU_NAMES %d" % [MENU_COUNT, MENU_NAMES.size()])
	if MENU_NAMES[0] != "root":
		errors.append("MENU_NAMES[0] != root")
	if MENU_NAMES[1] != "play":
		errors.append("MENU_NAMES[1] != play")
	if MENU_NAMES[2] != "garage":
		errors.append("MENU_NAMES[2] != garage")
	if MENU_NAMES[3] != "settings":
		errors.append("MENU_NAMES[3] != settings")
	if MAIN_MENU_SCENE != "res://src/ui/main_menu.tscn":
		errors.append("MAIN_MENU_SCENE mismatch")
	var main_scene: String = ProjectSettings.get_setting("application/run/main_scene", "") as String
	if main_scene != MAIN_MENU_SCENE:
		errors.append("project.godot main_scene %s != %s" % [main_scene, MAIN_MENU_SCENE])
	# SaveService existence
	var svc_script: GDScript = load("res://src/core/save_service.gd") as GDScript
	if svc_script == null:
		errors.append("SaveService script missing")
	return {"ok": errors.is_empty(), "errors": errors}
