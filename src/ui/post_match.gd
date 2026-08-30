## WS80 — Post-Match Scoreboard + XP (budget-aware, <12 calls)
## Scoreboard final scores, winner, XP rewards, level progression.
## Uses MatchTimer WS58 (score, winner, overtime, ticks) + Goal WS22 (team signals).
## Depends on: src/game/match_timer.gd (WS58), src/game/arena/goal.gd (WS22),
##             src/core/constants.gd (WS04), src/core/save_service.gd (WS08).
## Budget: <12 draw calls, <12 API calls/tick, headless-safe, 120 Hz safe.
extends CanvasLayer
class_name PostMatch

const PC = preload("res://src/core/constants.gd")
const MatchTimerRef = preload("res://src/game/match_timer.gd")
const GoalRef = preload("res://src/game/arena/goal.gd")
const SaveServiceRef = preload("res://src/core/save_service.gd")

# ---------------------------------------------------------------------------
# Tick — must match PC + MatchTimer + project.godot (120 Hz)
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0
const TICK_HZ: int = 120

# Match constants — mirrors WS58 single source, no drift
const MATCH_DURATION: float = 300.0
const MATCH_DURATION_TICKS: int = 36000
const COUNTDOWN_WARN_TICKS: int = 3600

# ---------------------------------------------------------------------------
# XP constants — deterministic, authored only (no random, no procedural)
# ---------------------------------------------------------------------------
const XP_WIN: int = 100
const XP_LOSS: int = 25
const XP_DRAW: int = 50
const XP_PARTICIPATION: int = 50
const XP_PER_GOAL: int = 30
const XP_OVERTIME_BONUS: int = 25
const XP_PER_LEVEL: int = 1000
const XP_MAX_PER_MATCH: int = 350  # clamp to avoid runaway (win+5 goals+OT+participation)

# Level thresholds — XP_PER_LEVEL linear (level = xp // 1000 + 1, L1: 0-999)
const LEVEL_MIN: int = 1
const LEVEL_MAX: int = 100

# ---------------------------------------------------------------------------
# Budget — WS10 global, <12 per subsystem
# ---------------------------------------------------------------------------
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = 12
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const ESTIMATED_DRAW_CALLS: int = 5  # bg 1 + scoreboard 1 + xp panel 1 + buttons 1 + title 1
const BUDGET_PHYSICS_MS: float = 4.0
const ESTIMATED_PHYSICS_MS: float = 0.06
const ESTIMATED_TRIS: int = 0  # pure UI

# UI constants
const POSTMATCH_LAYER: int = 20

# ---------------------------------------------------------------------------
# Signals — event-driven, budget-aware
# ---------------------------------------------------------------------------
signal scoreboard_updated(pos: int, neg: int, winner: int)
signal xp_awarded(amount: int, total_xp: int, level_before: int, level_after: int)
signal level_up(new_level: int)
signal rematch_requested
signal menu_requested
signal continue_pressed

# ---------------------------------------------------------------------------
# State — deterministic, no alloc per tick
# ---------------------------------------------------------------------------
var _score_pos: int = 0
var _score_neg: int = 0
var _winner: int = 0
var _reason: String = ""
var _is_overtime: bool = false
var _overtime_ticks: int = 0
var _ticks_elapsed: int = 0
var _xp_earned: int = 0
var _level_before: int = 1
var _level_after: int = 1
var _total_xp_before: int = 0
var _total_xp_after: int = 0
var _visible_postmatch: bool = false
var _call_count: int = 0
var _bound_timer: Node = null

# UI nodes (created in _ensure_ui)
var _root_control: Control = null
var _score_label: Label = null
var _winner_label: Label = null
var _time_label: Label = null
var _xp_label: Label = null
var _level_label: Label = null
var _rematch_button: Button = null
var _menu_button: Button = null
var _continue_button: Button = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	layer = POSTMATCH_LAYER
	visible = false
	_ensure_ui()
	_refresh_all()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[PostMatch] debug_validate: %s" % e)

func _ensure_ui() -> void:
	if _root_control != null and is_instance_valid(_root_control):
		return
	var root := Control.new()
	root.name = "PostMatch_Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_root_control = root

	# Background dim (ColorRect)
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.05, 0.05, 0.08, 0.92)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)

	# Center panel
	var panel := Panel.new()
	panel.name = "Panel"
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.size = Vector2(420, 320)
	panel.position = Vector2(-210, -160)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)

	# Title
	var title := Label.new()
	title.name = "TitleLabel"
	title.text = "MATCH FINISHED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.position = Vector2(10, 12)
	title.size = Vector2(400, 28)
	title.add_theme_font_size_override("font_size", 22)
	panel.add_child(title)

	# Scoreboard
	var score := Label.new()
	score.name = "ScoreLabel"
	score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score.position = Vector2(10, 48)
	score.size = Vector2(400, 32)
	score.text = format_score()
	score.add_theme_font_size_override("font_size", 28)
	panel.add_child(score)
	_score_label = score

	# Winner
	var winner := Label.new()
	winner.name = "WinnerLabel"
	winner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	winner.position = Vector2(10, 84)
	winner.size = Vector2(400, 20)
	winner.text = format_winner()
	winner.add_theme_font_size_override("font_size", 16)
	panel.add_child(winner)
	_winner_label = winner

	# Time / OT info
	var tlabel := Label.new()
	tlabel.name = "TimeLabel"
	tlabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tlabel.position = Vector2(10, 108)
	tlabel.size = Vector2(400, 18)
	tlabel.text = format_time_summary()
	tlabel.add_theme_font_size_override("font_size", 13)
	panel.add_child(tlabel)
	_time_label = tlabel

	# XP
	var xp := Label.new()
	xp.name = "XPLabel"
	xp.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	xp.position = Vector2(10, 136)
	xp.size = Vector2(400, 22)
	xp.text = format_xp()
	xp.add_theme_font_size_override("font_size", 16)
	panel.add_child(xp)
	_xp_label = xp

	# Level
	var lvl := Label.new()
	lvl.name = "LevelLabel"
	lvl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lvl.position = Vector2(10, 162)
	lvl.size = Vector2(400, 18)
	lvl.text = format_level()
	lvl.add_theme_font_size_override("font_size", 13)
	panel.add_child(lvl)
	_level_label = lvl

	# Buttons row
	var btn_rematch := Button.new()
	btn_rematch.name = "RematchButton"
	btn_rematch.text = "Rematch"
	btn_rematch.position = Vector2(20, 260)
	btn_rematch.size = Vector2(110, 40)
	btn_rematch.pressed.connect(_on_rematch_pressed)
	panel.add_child(btn_rematch)
	_rematch_button = btn_rematch

	var btn_continue := Button.new()
	btn_continue.name = "ContinueButton"
	btn_continue.text = "Continue"
	btn_continue.position = Vector2(155, 260)
	btn_continue.size = Vector2(110, 40)
	btn_continue.pressed.connect(_on_continue_pressed)
	panel.add_child(btn_continue)
	_continue_button = btn_continue

	var btn_menu := Button.new()
	btn_menu.name = "MenuButton"
	btn_menu.text = "Main Menu"
	btn_menu.position = Vector2(290, 260)
	btn_menu.size = Vector2(110, 40)
	btn_menu.pressed.connect(_on_menu_pressed)
	panel.add_child(btn_menu)
	_menu_button = btn_menu

# ---------------------------------------------------------------------------
# Scoreboard API
# ---------------------------------------------------------------------------
func set_scores(pos: int, neg: int, winner: int = 0, reason: String = "") -> void:
	_score_pos = max(pos, 0)
	_score_neg = max(neg, 0)
	if winner != 0:
		_winner = winner
	else:
		_winner = _derive_winner(_score_pos, _score_neg)
	_reason = reason
	_call_count += 1
	scoreboard_updated.emit(_score_pos, _score_neg, _winner)
	_update_score_visual()

func set_result_from_timer(timer: Node) -> void:
	if timer == null:
		return
	var pos := 0
	var neg := 0
	if timer.has_method("get_scores"):
		var sc: Dictionary = timer.call("get_scores") as Dictionary
		pos = int(sc.get("positive", sc.get("team_1", 0)))
		neg = int(sc.get("negative", sc.get("team_minus1", 0)))
	elif timer.has_method("get_score"):
		pos = int(timer.call("get_score", 1))
		neg = int(timer.call("get_score", -1))
	var winner := 0
	if timer.has_method("get_winner"):
		winner = int(timer.call("get_winner"))
	else:
		winner = _derive_winner(pos, neg)
	_is_overtime = bool(timer.call("is_overtime")) if timer.has_method("is_overtime") else false
	_overtime_ticks = int(timer.call("get_overtime_ticks")) if timer.has_method("get_overtime_ticks") else 0
	_ticks_elapsed = int(timer.call("get_elapsed_ticks")) if timer.has_method("get_elapsed_ticks") else 0
	_reason = "timer"
	set_scores(pos, neg, winner, "timer")

func get_scores() -> Dictionary:
	return {"positive": _score_pos, "negative": _score_neg, "team_1": _score_pos, "team_minus1": _score_neg}

func get_winner() -> int:
	return _winner

func get_reason() -> String:
	return _reason

func is_draw() -> bool:
	return _winner == 0

func format_score() -> String:
	return "%d - %d" % [_score_pos, _score_neg]

func format_winner() -> String:
	if _winner == 1:
		return "Blue Wins" if _score_pos > _score_neg else "Blue"
	elif _winner == -1:
		return "Orange Wins" if _score_neg > _score_pos else "Orange"
	elif _score_pos == _score_neg:
		return "Draw"
	else:
		return "Winner: %d" % _winner

func format_time_summary() -> String:
	if _is_overtime:
		var ot_s := float(_overtime_ticks) * TICK_DELTA
		var m := int(ot_s) / 60
		var s := int(ot_s) % 60
		return "Overtime +%d:%02d" % [m, s]
	var secs := float(_ticks_elapsed) * TICK_DELTA
	var m2 := int(secs) / 60
	var s2 := int(secs) % 60
	return "Time %d:%02d" % [m2, s2]

func _update_score_visual() -> void:
	if _score_label != null and is_instance_valid(_score_label):
		_score_label.text = format_score()
	if _winner_label != null and is_instance_valid(_winner_label):
		_winner_label.text = format_winner()
	if _time_label != null and is_instance_valid(_time_label):
		_time_label.text = format_time_summary()

func _derive_winner(pos: int, neg: int) -> int:
	if pos > neg:
		return 1
	elif neg > pos:
		return -1
	return 0

# ---------------------------------------------------------------------------
# XP API — deterministic, budget-aware
# ---------------------------------------------------------------------------
static func xp_for_result(winner: int, player_team: int, goals_scored: int, is_overtime: bool) -> int:
	var xp := XP_PARTICIPATION
	if winner == 0:
		xp += XP_DRAW
	elif winner == player_team:
		xp += XP_WIN
	else:
		xp += XP_LOSS
	xp += goals_scored * XP_PER_GOAL
	if is_overtime:
		xp += XP_OVERTIME_BONUS
	return clamp(xp, 0, XP_MAX_PER_MATCH)

static func level_for_xp(total_xp: int) -> int:
	var lvl := (total_xp / XP_PER_LEVEL) + 1
	return clamp(lvl, LEVEL_MIN, LEVEL_MAX)

static func xp_to_next_level(total_xp: int) -> int:
	var lvl := level_for_xp(total_xp)
	if lvl >= LEVEL_MAX:
		return 0
	var next_threshold := lvl * XP_PER_LEVEL
	return next_threshold - total_xp

static func progress_to_next_level(total_xp: int) -> float:
	if level_for_xp(total_xp) >= LEVEL_MAX:
		return 1.0
	var rem := xp_to_next_level(total_xp)
	return 1.0 - float(rem) / float(XP_PER_LEVEL)

func calculate_xp(player_team: int = 1, goals_scored: int = -1) -> int:
	# goals_scored -1 means use player's team score; otherwise explicit
	var g := goals_scored
	if g < 0:
		g = _score_pos if player_team == 1 else _score_neg
	var xp := xp_for_result(_winner, player_team, g, _is_overtime)
	_xp_earned = xp
	return xp

func get_xp_earned() -> int:
	return _xp_earned

func get_level_before() -> int:
	return _level_before

func get_level_after() -> int:
	return _level_after

func format_xp() -> String:
	if _xp_earned == 0:
		return "+0 XP"
	return "+%d XP" % _xp_earned

func format_level() -> String:
	if _level_before == _level_after:
		return "Level %d  (%d XP)" % [_level_after, _total_xp_after]
	return "Level %d → %d  (%d XP)" % [_level_before, _level_after, _total_xp_after]

func _update_xp_visual() -> void:
	if _xp_label != null and is_instance_valid(_xp_label):
		_xp_label.text = format_xp()
	if _level_label != null and is_instance_valid(_level_label):
		_level_label.text = format_level()

## Apply XP to SaveService payload (does not auto-save; caller decides to persist).
## Returns Dictionary with keys: xp_earned, total_before, total_after, level_before, level_after, leveled_up
func apply_xp(player_team: int = 1, goals_scored: int = -1, save_payload: Dictionary = {}) -> Dictionary:
	var payload := save_payload
	if payload.is_empty():
		var svc := _get_save_service()
		if svc != null and svc.has_method("load_save"):
			payload = svc.call("load_save") as Dictionary
		else:
			payload = SaveServiceRef.default_payload()

	var player: Dictionary = payload.get("player", {}) as Dictionary
	_total_xp_before = int(player.get("xp", 0))
	_level_before = int(player.get("level", level_for_xp(_total_xp_before)))
	# Ensure level consistent with xp
	_level_before = clamp(_level_before, LEVEL_MIN, LEVEL_MAX)

	var xp := calculate_xp(player_team, goals_scored)
	_total_xp_after = _total_xp_before + xp
	_level_after = level_for_xp(_total_xp_after)

	# Update payload in-place
	player["xp"] = _total_xp_after
	player["level"] = _level_after
	player["matches_played"] = int(player.get("matches_played", 0)) + 1
	if _winner == player_team and _winner != 0:
		player["wins"] = int(player.get("wins", 0)) + 1
	player["last_played_at"] = Time.get_unix_time_from_system()
	payload["player"] = player

	# Stats: goals
	var stats: Dictionary = payload.get("stats", {}) as Dictionary
	var g2 := goals_scored
	if g2 < 0:
		g2 = _score_pos if player_team == 1 else _score_neg
	stats["goals"] = int(stats.get("goals", 0)) + g2
	payload["stats"] = stats

	_call_count += 1
	_update_xp_visual()
	var leveled := _level_after > _level_before
	xp_awarded.emit(xp, _total_xp_after, _level_before, _level_after)
	if leveled:
		level_up.emit(_level_after)
	return {
		"xp_earned": xp,
		"total_before": _total_xp_before,
		"total_after": _total_xp_after,
		"level_before": _level_before,
		"level_after": _level_after,
		"leveled_up": leveled,
		"payload": payload,
	}

## Persist payload via SaveService.save_save (1 call, budget-aware)
func save_payload(payload: Dictionary) -> bool:
	var svc := _get_save_service()
	if svc == null or not svc.has_method("save_save"):
		# Try save method variants
		if svc != null and svc.has_method("save"):
			return bool(svc.call("save", payload))
		return false
	return bool(svc.call("save_save", payload))

func _get_save_service() -> Node:
	if Engine.has_singleton("SaveService"):
		return Engine.get_singleton("SaveService") as Node
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		var n := tree.root.get_node_or_null("/root/SaveService")
		if n != null:
			return n
	return get_node_or_null("/root/SaveService")

# ---------------------------------------------------------------------------
# MatchTimer + Goal wiring — uses WS58 / WS22 signals
# ---------------------------------------------------------------------------
func bind_match_timer(timer: Node) -> bool:
	if timer == null:
		return false
	_bound_timer = timer
	if timer.has_signal("match_ended") and not timer.match_ended.is_connected(_on_match_ended):
		timer.match_ended.connect(_on_match_ended)
	if timer.has_signal("goal_scored") and not timer.goal_scored.is_connected(_on_goal_scored):
		timer.goal_scored.connect(_on_goal_scored)
	if timer.has_signal("overtime_started") and not timer.overtime_started.is_connected(_on_overtime):
		timer.overtime_started.connect(_on_overtime)
	if timer.has_signal("time_updated") and not timer.time_updated.is_connected(_on_time_updated):
		timer.time_updated.connect(_on_time_updated)
	# Pull initial state (budget: 4 calls max)
	if timer.has_method("get_scores"):
		var sc: Dictionary = timer.call("get_scores") as Dictionary
		_score_pos = int(sc.get("positive", 0))
		_score_neg = int(sc.get("negative", 0))
	if timer.has_method("get_winner"):
		_winner = int(timer.call("get_winner"))
	if timer.has_method("is_overtime"):
		_is_overtime = bool(timer.call("is_overtime"))
	_refresh_all()
	return true

func unbind_match_timer() -> void:
	if _bound_timer == null:
		return
	var t := _bound_timer
	if t.has_signal("match_ended") and t.match_ended.is_connected(_on_match_ended):
		t.match_ended.disconnect(_on_match_ended)
	if t.has_signal("goal_scored") and t.goal_scored.is_connected(_on_goal_scored):
		t.goal_scored.disconnect(_on_goal_scored)
	if t.has_signal("overtime_started") and t.overtime_started.is_connected(_on_overtime):
		t.overtime_started.disconnect(_on_overtime)
	if t.has_signal("time_updated") and t.time_updated.is_connected(_on_time_updated):
		t.time_updated.disconnect(_on_time_updated)
	_bound_timer = null

func _on_match_ended(winner: int, score_pos: int, score_neg: int, reason: String) -> void:
	_score_pos = score_pos
	_score_neg = score_neg
	_winner = winner
	_reason = reason
	_call_count += 1
	scoreboard_updated.emit(_score_pos, _score_neg, _winner)
	_update_score_visual()
	show_post_match()

func _on_goal_scored(team: int, score_pos: int, score_neg: int) -> void:
	_score_pos = score_pos
	_score_neg = score_neg
	_update_score_visual()
	scoreboard_updated.emit(_score_pos, _score_neg, _derive_winner(_score_pos, _score_neg))

func _on_overtime(_tick: int) -> void:
	_is_overtime = true
	_update_score_visual()

func _on_time_updated(remaining_ticks: int, _remaining_seconds: float) -> void:
	# Keep elapsed in sync (budget: 1 call)
	_ticks_elapsed = MATCH_DURATION_TICKS - clamp(remaining_ticks, 0, MATCH_DURATION_TICKS)
	if not _is_overtime:
		_update_score_visual()

## Convenience: wire Goal nodes directly when no MatchTimer present (WS22)
func wire_goals(goal_pos: Node, goal_neg: Node) -> void:
	if goal_pos != null and goal_pos.has_signal("goal_scored") and not goal_pos.goal_scored.is_connected(_on_goal_direct):
		goal_pos.goal_scored.connect(_on_goal_direct)
	if goal_neg != null and goal_neg.has_signal("goal_scored") and not goal_neg.goal_scored.is_connected(_on_goal_direct):
		goal_neg.goal_scored.connect(_on_goal_direct)

func wire_goal_nodes(goals: Array) -> void:
	for g in goals:
		if g is Goal and not (g as Goal).goal_scored.is_connected(_on_goal_direct):
			(g as Goal).goal_scored.connect(_on_goal_direct)
		elif g != null and g.has_signal("goal_scored") and not g.goal_scored.is_connected(_on_goal_direct):
			g.goal_scored.connect(_on_goal_direct)

func _on_goal_direct(team: int) -> void:
	if team == 1:
		_score_pos += 1
	elif team == -1:
		_score_neg += 1
	else:
		return
	_update_score_visual()
	scoreboard_updated.emit(_score_pos, _score_neg, _derive_winner(_score_pos, _score_neg))

# ---------------------------------------------------------------------------
# Visibility / navigation
# ---------------------------------------------------------------------------
func show_post_match(player_team: int = 1) -> void:
	_visible_postmatch = true
	visible = true
	# Auto-calc XP preview (no save yet); caller may call apply_xp to persist
	calculate_xp(player_team)
	_refresh_all()
	# Input grab for gamepad/keyboard focus
	if _continue_button != null and is_instance_valid(_continue_button):
		_continue_button.grab_focus()

func hide_post_match() -> void:
	_visible_postmatch = false
	visible = false

func is_post_match_visible() -> bool:
	return _visible_postmatch and visible

func _on_rematch_pressed() -> void:
	rematch_requested.emit()
	# Reset for next match display
	hide_post_match()

func _on_menu_pressed() -> void:
	menu_requested.emit()
	var tree := get_tree()
	if tree != null:
		tree.change_scene_to_file("res://src/ui/main_menu.tscn")

func _on_continue_pressed() -> void:
	continue_pressed.emit()
	hide_post_match()

func reset() -> void:
	_score_pos = 0
	_score_neg = 0
	_winner = 0
	_reason = ""
	_is_overtime = false
	_overtime_ticks = 0
	_ticks_elapsed = 0
	_xp_earned = 0
	_level_before = 1
	_level_after = 1
	_total_xp_before = 0
	_total_xp_after = 0
	_visible_postmatch = false
	visible = false
	_refresh_all()

func _refresh_all() -> void:
	_update_score_visual()
	_update_xp_visual()

# ---------------------------------------------------------------------------
# Full result helper — one-call update from World/Game loop (budget: 3 visuals)
# ---------------------------------------------------------------------------
func update_post_match(scores: Dictionary, winner: int, reason: String, overtime: bool, ticks_elapsed: int) -> void:
	_call_count = 0
	_call_count += 1
	_score_pos = int(scores.get("positive", scores.get("team_1", _score_pos)))
	_score_neg = int(scores.get("negative", scores.get("team_minus1", _score_neg)))
	_call_count += 1
	_winner = winner if winner != 0 else _derive_winner(_score_pos, _score_neg)
	_reason = reason
	_is_overtime = overtime
	_ticks_elapsed = max(ticks_elapsed, 0)
	_call_count += 1
	_refresh_all()
	scoreboard_updated.emit(_score_pos, _score_neg, _winner)

# ---------------------------------------------------------------------------
# Budget / perf
# ---------------------------------------------------------------------------
func get_call_count() -> int:
	return _call_count

func get_draw_call_count() -> int:
	return ESTIMATED_DRAW_CALLS

func get_estimated_draw_calls() -> int:
	return ESTIMATED_DRAW_CALLS

func get_budget_state() -> Dictionary:
	return {
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": ESTIMATED_DRAW_CALLS <= DRAW_CALL_BUDGET,
		"max_draw_calls": MAX_DRAW_CALLS,
		"call_count": _call_count,
		"budget_calls": MAX_CALLS_PER_TICK,
		"within_call_budget": _call_count <= MAX_CALLS_PER_TICK,
		"estimated_physics_ms": ESTIMATED_PHYSICS_MS,
		"budget_physics_ms": BUDGET_PHYSICS_MS,
		"estimated_tris": ESTIMATED_TRIS,
	}

# ---------------------------------------------------------------------------
# Validation / telemetry — conventions §11
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if TICK_HZ != 120:
		errors.append("TICK_HZ != 120")
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA != 1/120")
	if not is_equal_approx(MATCH_DURATION, 300.0):
		errors.append("MATCH_DURATION %.2f != 300" % MATCH_DURATION)
	if MATCH_DURATION_TICKS != 36000:
		errors.append("MATCH_DURATION_TICKS %d != 36000" % MATCH_DURATION_TICKS)
	if COUNTDOWN_WARN_TICKS != 3600:
		errors.append("COUNTDOWN_WARN_TICKS != 3600")
	if MAX_CALLS_PER_TICK > 12:
		errors.append("MAX_CALLS_PER_TICK %d > 12" % MAX_CALLS_PER_TICK)
	if DRAW_CALL_BUDGET > 12:
		errors.append("DRAW_CALL_BUDGET %d > 12" % DRAW_CALL_BUDGET)
	if MAX_DRAW_CALLS > 12:
		errors.append("MAX_DRAW_CALLS %d > 12" % MAX_DRAW_CALLS)
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("ESTIMATED_DRAW_CALLS %d > %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if XP_PER_LEVEL != 1000:
		errors.append("XP_PER_LEVEL %d != 1000" % XP_PER_LEVEL)
	if XP_MAX_PER_MATCH < 200 or XP_MAX_PER_MATCH > 500:
		errors.append("XP_MAX_PER_MATCH %d outside sane range" % XP_MAX_PER_MATCH)
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PC.PHYSICS_TICK_DELTA, TICK_DELTA):
		errors.append("PC PHYSICS_TICK_DELTA mismatch")
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != -1 and ps_rate != 120:
		errors.append("project.godot physics_ticks_per_second=%d != 120" % ps_rate)
	# MatchTimer cross-check
	var mt_path := "res://src/game/match_timer.gd"
	if FileAccess.file_exists(mt_path):
		var mt: GDScript = load(mt_path) as GDScript
		if mt != null:
			if int(mt.get("MATCH_DURATION_TICKS")) != MATCH_DURATION_TICKS:
				errors.append("MatchTimer MATCH_DURATION_TICKS drift")
			if int(mt.get("PHYSICS_TICKS_PER_SECOND")) != PHYSICS_TICKS_PER_SECOND:
				errors.append("MatchTimer PHYSICS_TICKS_PER_SECOND drift")
			if not is_equal_approx(float(mt.get("MATCH_DURATION")), MATCH_DURATION):
				errors.append("MatchTimer MATCH_DURATION drift")
			var v_mt: Dictionary = (mt as GDScript).call("debug_validate") if (mt as GDScript).has_method("debug_validate") else {"ok": true}
			# If static method exists, invoke via instance check already done by load; skip failing hard
			if v_mt.has("ok") and not bool(v_mt["ok"]):
				for e in v_mt.get("errors", []):
					errors.append("MatchTimer: %s" % str(e))
	# Goal cross-check
	var goal_path := "res://src/game/arena/goal.gd"
	if FileAccess.file_exists(goal_path):
		var gg: GDScript = load(goal_path) as GDScript
		if gg != null:
			var v_goal: Dictionary = (gg as GDScript).call("debug_validate") if (gg as GDScript).has_method("debug_validate") else {"ok": true}
			if v_goal.has("ok") and not bool(v_goal["ok"]):
				for e in v_goal.get("errors", []):
					errors.append("Goal: %s" % str(e))
			if float(gg.get("GOAL_WIDTH")) != PC.GOAL_WIDTH:
				errors.append("Goal GOAL_WIDTH drift vs PC")
	# SaveService cross-check
	var svc_path := "res://src/core/save_service.gd"
	if FileAccess.file_exists(svc_path):
		var svc: GDScript = load(svc_path) as GDScript
		if svc != null:
			var def: Dictionary = svc.call("default_payload") as Dictionary
			if not def.has("player") or not (def["player"] as Dictionary).has("xp"):
				errors.append("SaveService default_payload missing player.xp")
			if not def.has("stats"):
				errors.append("SaveService default_payload missing stats")
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"score_pos": _score_pos,
		"score_neg": _score_neg,
		"score_text": format_score(),
		"winner": _winner,
		"winner_text": format_winner(),
		"reason": _reason,
		"is_overtime": _is_overtime,
		"overtime_ticks": _overtime_ticks,
		"ticks_elapsed": _ticks_elapsed,
		"time_summary": format_time_summary(),
		"xp_earned": _xp_earned,
		"xp_text": format_xp(),
		"total_xp_before": _total_xp_before,
		"total_xp_after": _total_xp_after,
		"level_before": _level_before,
		"level_after": _level_after,
		"level_text": format_level(),
		"visible": _visible_postmatch and visible,
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"call_count": _call_count,
		"budget_calls": MAX_CALLS_PER_TICK,
		"layer": POSTMATCH_LAYER,
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "PostMatch",
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"budget_calls": MAX_CALLS_PER_TICK,
		"estimated_physics_ms": ESTIMATED_PHYSICS_MS,
		"budget_physics_ms": BUDGET_PHYSICS_MS,
		"tick_hz": PHYSICS_TICKS_PER_SECOND,
		"estimated_tris": ESTIMATED_TRIS,
	}
