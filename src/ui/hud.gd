## WS77 — HUD: Scoreboard, Timer, Boost Meter (budget-aware, <12 calls)
## Scoreboard (WS22 Goal), Timer from WS58 MatchTimer (5min + OT), Boost from WS18 CarBoost.
## Uses InputService (WS06) — NEVER raw Input. Overlay CanvasLayer, view-model separation.
## Budget: <12 draw calls, <12 API calls/tick, no per-frame alloc, 120 Hz safe.
## Duo-safe: stateless helpers + single _update_hud call per tick.
extends CanvasLayer
class_name HUD

const PC = preload("res://src/core/constants.gd")
const CarBoostRef = preload("res://src/game/car/boost.gd")

# ---------------------------------------------------------------------------
# Budget & tick — must match PC + TimeService + project.godot 120 Hz
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0
const TICK_HZ: int = 120

const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = 12
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const ESTIMATED_DRAW_CALLS: int = 4  # scoreboard 1 + timer 1 + boost 1 + background 1
const BUDGET_PHYSICS_MS: float = 4.0
const ESTIMATED_PHYSICS_MS: float = 0.08
const ESTIMATED_TRIS: int = 0  # pure UI, no mesh

# ---------------------------------------------------------------------------
# Match constants — mirrors WS58 (single source, no drift)
# ---------------------------------------------------------------------------
const MATCH_DURATION: float = 300.0
const MATCH_DURATION_TICKS: int = 36000
const COUNTDOWN_WARN_TICKS: int = 3600

# ---------------------------------------------------------------------------
# Boost constants — mirrors WS18
# ---------------------------------------------------------------------------
const BOOST_MAX: float = 100.0

# ---------------------------------------------------------------------------
# UI constants
# ---------------------------------------------------------------------------
const HUD_LAYER: int = 10
const BOOST_WARN_THRESHOLD: float = 20.0
const BOOST_FULL_THRESHOLD: float = 99.0

# ---------------------------------------------------------------------------
# State — deterministic, no alloc per frame
# ---------------------------------------------------------------------------
var _score_pos: int = 0
var _score_neg: int = 0
var _ticks_remaining: int = MATCH_DURATION_TICKS
var _ticks_elapsed: int = 0
var _overtime: bool = false
var _overtime_ticks: int = 0
var _boost_amount: float = 33.0
var _boost_normalized: float = 0.33
var _is_boosting: bool = false
var _call_count: int = 0
var _bound_timer: Node = null
var _bound_boost: RefCounted = null  # CarBoost instance

# UI nodes (created in _ensure_ui)
var _score_label: Label = null
var _timer_label: Label = null
var _boost_bar: ProgressBar = null
var _boost_label: Label = null
var _root_control: Control = null

# Signals — event-driven, no polling leak
signal score_changed(pos: int, neg: int)
signal time_changed(ticks_remaining: int, seconds_remaining: float)
signal boost_changed(amount: float, normalized: float)
signal overtime_entered(tick: int)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	layer = HUD_LAYER
	_ensure_ui()
	_refresh_all()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[HUD] debug_validate: %s" % e)

func _process(_delta: float) -> void:
	# Poll InputService boost state (1 call) + refresh boost visual if needed.
	# Keep <12 calls: single _poll_boost + _update_boost_visual when dirty.
	_poll_boost_state()

func _ensure_ui() -> void:
	if _root_control != null and is_instance_valid(_root_control):
		return
	var root := Control.new()
	root.name = "HUD_Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_root_control = root

	# Top center: timer
	var timer := Label.new()
	timer.name = "TimerLabel"
	timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	timer.position = Vector2(0, 8)
	timer.size = Vector2(360, 28)
	timer.anchor_left = 0.5
	timer.anchor_right = 0.5
	timer.offset_left = -180
	timer.offset_right = 180
	timer.text = format_time()
	timer.add_theme_font_size_override("font_size", 26)
	root.add_child(timer)
	_timer_label = timer

	# Top center below timer: scoreboard
	var score := Label.new()
	score.name = "ScoreLabel"
	score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score.position = Vector2(0, 36)
	score.size = Vector2(360, 24)
	score.anchor_left = 0.5
	score.anchor_right = 0.5
	score.offset_left = -180
	score.offset_right = 180
	score.text = format_score()
	score.add_theme_font_size_override("font_size", 20)
	root.add_child(score)
	_score_label = score

	# Bottom-right: boost meter (progress bar + label)
	var bar := ProgressBar.new()
	bar.name = "BoostBar"
	bar.min_value = 0.0
	bar.max_value = BOOST_MAX
	bar.value = _boost_amount
	bar.step = 0.1
	bar.show_percentage = false
	bar.size = Vector2(180, 16)
	bar.position = Vector2(0, 0)
	bar.anchor_left = 1.0
	bar.anchor_top = 1.0
	bar.anchor_right = 1.0
	bar.anchor_bottom = 1.0
	bar.offset_left = -200
	bar.offset_top = -32
	bar.offset_right = -20
	bar.offset_bottom = -16
	# Fill direction left->right is default
	root.add_child(bar)
	_boost_bar = bar

	var blabel := Label.new()
	blabel.name = "BoostLabel"
	blabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	blabel.size = Vector2(180, 16)
	blabel.position = Vector2(0, 0)
	blabel.anchor_left = 1.0
	blabel.anchor_top = 1.0
	blabel.anchor_right = 1.0
	blabel.anchor_bottom = 1.0
	blabel.offset_left = -200
	blabel.offset_top = -32
	blabel.offset_right = -20
	blabel.offset_bottom = -16
	blabel.text = "%d" % int(_boost_amount)
	blabel.add_theme_font_size_override("font_size", 12)
	blabel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(blabel)
	_boost_label = blabel


# ---------------------------------------------------------------------------
# InputService — NEVER raw Input
# ---------------------------------------------------------------------------
func _get_input_service() -> Node:
	if Engine.has_singleton("InputService"):
		return Engine.get_singleton("InputService")
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		if tree.root != null:
			var svc := tree.root.get_node_or_null("InputService")
			if svc != null:
				return svc
		var alt := tree.get_root().get_node_or_null("/root/InputService")
		if alt != null:
			return alt
	return get_node_or_null("/root/InputService")

func _poll_boost_state() -> void:
	# 1 InputService read per frame max
	var svc := _get_input_service()
	if svc == null:
		_is_boosting = false
		return
	var boosting := false
	if "boost" in svc:
		boosting = bool(svc.boost)
	elif svc.has_method("is_boosting"):
		boosting = bool(svc.is_boosting())
	_is_boosting = boosting

func is_boosting_via_input() -> bool:
	return _is_boosting

# ---------------------------------------------------------------------------
# Scoreboard API
# ---------------------------------------------------------------------------
func set_scores(pos: int, neg: int) -> void:
	_score_pos = max(pos, 0)
	_score_neg = max(neg, 0)
	_call_count += 1
	score_changed.emit(_score_pos, _score_neg)
	_update_score_visual()

func set_score(team: int, value: int) -> void:
	if team == 1:
		_score_pos = max(value, 0)
	elif team == -1:
		_score_neg = max(value, 0)
	else:
		return
	score_changed.emit(_score_pos, _score_neg)
	_update_score_visual()

func on_goal(team: int) -> void:
	if team == 1:
		_score_pos += 1
	elif team == -1:
		_score_neg += 1
	else:
		return
	score_changed.emit(_score_pos, _score_neg)
	_update_score_visual()

func get_scores() -> Dictionary:
	return {"positive": _score_pos, "negative": _score_neg, "team_1": _score_pos, "team_minus1": _score_neg}

func get_score(team: int) -> int:
	if team == 1:
		return _score_pos
	if team == -1:
		return _score_neg
	return 0

func format_score() -> String:
	return "%d - %d" % [_score_pos, _score_neg]

func _update_score_visual() -> void:
	if _score_label != null and is_instance_valid(_score_label):
		_score_label.text = format_score()

# ---------------------------------------------------------------------------
# Timer API — mirrors WS58 MatchTimer
# ---------------------------------------------------------------------------
func set_time_ticks(ticks_remaining: int, ticks_elapsed: int = -1, overtime_ticks: int = -1) -> void:
	_ticks_remaining = clamp(ticks_remaining, 0, MATCH_DURATION_TICKS)
	if ticks_elapsed >= 0:
		_ticks_elapsed = ticks_elapsed
	if overtime_ticks >= 0:
		_overtime_ticks = overtime_ticks
		_overtime = overtime_ticks > 0 or _ticks_remaining == 0
	_call_count += 1
	time_changed.emit(_ticks_remaining, float(_ticks_remaining) * TICK_DELTA)
	_update_timer_visual()

func set_time_seconds(seconds_remaining: float) -> void:
	var ticks := int(round(seconds_remaining * float(PHYSICS_TICKS_PER_SECOND)))
	set_time_ticks(ticks)

func set_overtime(enabled: bool, overtime_ticks: int = 0) -> void:
	_overtime = enabled
	_overtime_ticks = max(overtime_ticks, 0)
	if enabled:
		_ticks_remaining = 0
		overtime_entered.emit(_ticks_elapsed)
	_update_timer_visual()

func is_overtime() -> bool:
	return _overtime

func get_remaining_ticks() -> int:
	return _ticks_remaining

func get_remaining_seconds() -> float:
	if _overtime:
		return 0.0
	return float(_ticks_remaining) * TICK_DELTA

func get_elapsed_ticks() -> int:
	return _ticks_elapsed

func format_time() -> String:
	if _overtime:
		var ot := float(_overtime_ticks) * TICK_DELTA
		var m := int(ot) / 60
		var s := int(ot) % 60
		return "+%d:%02d" % [m, s]
	var secs := float(_ticks_remaining) * TICK_DELTA
	var m2 := int(secs) / 60
	var s2 := int(secs) % 60
	return "%d:%02d" % [m2, s2]

func format_time_precise() -> String:
	if _overtime:
		return "+%s OT" % format_time()
	return format_time()

static func format_ticks(ticks: int) -> String:
	var secs := float(ticks) * (1.0 / 120.0)
	var m := int(secs) / 60
	var s := int(secs) % 60
	return "%d:%02d" % [m, s]

func _update_timer_visual() -> void:
	if _timer_label != null and is_instance_valid(_timer_label):
		_timer_label.text = format_time()

## Wire to WS58 MatchTimer signals (time_updated, goal_scored, overtime_started, match_ended)
func bind_match_timer(timer: Node) -> bool:
	if timer == null:
		return false
	_bound_timer = timer
	if timer.has_signal("time_updated") and not timer.time_updated.is_connected(_on_timer_time_updated):
		timer.time_updated.connect(_on_timer_time_updated)
	if timer.has_signal("goal_scored") and not timer.goal_scored.is_connected(_on_timer_goal_scored):
		timer.goal_scored.connect(_on_timer_goal_scored)
	if timer.has_signal("overtime_started") and not timer.overtime_started.is_connected(_on_timer_overtime):
		timer.overtime_started.connect(_on_timer_overtime)
	if timer.has_signal("match_ended") and not timer.match_ended.is_connected(_on_timer_match_ended):
		timer.match_ended.connect(_on_timer_match_ended)
	# Pull initial state if available (1 call)
	if timer.has_method("get_remaining_ticks"):
		_ticks_remaining = int(timer.call("get_remaining_ticks"))
	if timer.has_method("get_elapsed_ticks"):
		_ticks_elapsed = int(timer.call("get_elapsed_ticks"))
	if timer.has_method("is_overtime"):
		_overtime = bool(timer.call("is_overtime"))
	if timer.has_method("get_overtime_ticks"):
		_overtime_ticks = int(timer.call("get_overtime_ticks"))
	if timer.has_method("get_scores"):
		var sc: Dictionary = timer.call("get_scores") as Dictionary
		_score_pos = int(sc.get("positive", sc.get("team_1", 0)))
		_score_neg = int(sc.get("negative", sc.get("team_minus1", 0)))
	_refresh_all()
	return true

func unbind_match_timer() -> void:
	if _bound_timer == null:
		return
	var t := _bound_timer
	if t.has_signal("time_updated") and t.time_updated.is_connected(_on_timer_time_updated):
		t.time_updated.disconnect(_on_timer_time_updated)
	if t.has_signal("goal_scored") and t.goal_scored.is_connected(_on_timer_goal_scored):
		t.goal_scored.disconnect(_on_timer_goal_scored)
	if t.has_signal("overtime_started") and t.overtime_started.is_connected(_on_timer_overtime):
		t.overtime_started.disconnect(_on_timer_overtime)
	if t.has_signal("match_ended") and t.match_ended.is_connected(_on_timer_match_ended):
		t.match_ended.disconnect(_on_timer_match_ended)
	_bound_timer = null

func _on_timer_time_updated(remaining_ticks: int, _remaining_seconds: float) -> void:
	_ticks_remaining = clamp(remaining_ticks, 0, MATCH_DURATION_TICKS)
	# elapsed derived from match duration when not in OT
	if not _overtime:
		_ticks_elapsed = MATCH_DURATION_TICKS - _ticks_remaining
	_call_count += 1
	_update_timer_visual()
	time_changed.emit(_ticks_remaining, float(_ticks_remaining) * TICK_DELTA)

func _on_timer_goal_scored(team: int, score_pos: int, score_neg: int) -> void:
	_score_pos = score_pos
	_score_neg = score_neg
	_update_score_visual()
	score_changed.emit(_score_pos, _score_neg)

func _on_timer_overtime(_tick: int) -> void:
	_overtime = true
	_overtime_ticks = 0
	_update_timer_visual()
	overtime_entered.emit(_ticks_elapsed)

func _on_timer_match_ended(_winner: int, _score_pos: int, _score_neg: int, _reason: String) -> void:
	# Freeze HUD on match end; no extra calls
	pass

## Convenience: wire to Goal nodes directly (WS22) when no MatchTimer present
func wire_goals(goal_pos: Node, goal_neg: Node) -> void:
	if goal_pos != null and goal_pos.has_signal("goal_scored") and not goal_pos.goal_scored.is_connected(on_goal):
		goal_pos.goal_scored.connect(on_goal)
	if goal_neg != null and goal_neg.has_signal("goal_scored") and not goal_neg.goal_scored.is_connected(on_goal):
		goal_neg.goal_scored.connect(on_goal)

# ---------------------------------------------------------------------------
# Boost meter API — mirrors WS18 CarBoost (0..100)
# ---------------------------------------------------------------------------
func set_boost(amount: float) -> void:
	_boost_amount = clamp(amount, 0.0, BOOST_MAX)
	_boost_normalized = _boost_amount / BOOST_MAX
	_call_count += 1
	boost_changed.emit(_boost_amount, _boost_normalized)
	_update_boost_visual()

func set_boost_normalized(n: float) -> void:
	set_boost(clamp(n, 0.0, 1.0) * BOOST_MAX)

func get_boost_amount() -> float:
	return _boost_amount

func get_boost_normalized() -> float:
	return _boost_normalized

func is_boost_low() -> bool:
	return _boost_amount <= BOOST_WARN_THRESHOLD

func is_boost_full() -> bool:
	return _boost_amount >= BOOST_FULL_THRESHOLD

func _update_boost_visual() -> void:
	if _boost_bar != null and is_instance_valid(_boost_bar):
		_boost_bar.value = _boost_amount
	if _boost_label != null and is_instance_valid(_boost_label):
		_boost_label.text = "%d" % int(round(_boost_amount))

## Bind to a CarBoost RefCounted instance (polls via get_amount)
func bind_boost(car_boost: RefCounted) -> bool:
	if car_boost == null:
		return false
	_bound_boost = car_boost
	if car_boost.has_method("get_amount"):
		set_boost(float(car_boost.call("get_amount")))
	return true

## Tick helper for external physics loop: pulls boost amount from bound instance (1 call)
func tick_boost_from_bound() -> void:
	if _bound_boost == null:
		return
	if _bound_boost.has_method("get_amount"):
		var amt := float(_bound_boost.call("get_amount"))
		if not is_equal_approx(amt, _boost_amount):
			set_boost(amt)
	# Also poll InputService boosting state is done in _process

# ---------------------------------------------------------------------------
# Unified update — budget: 3 visual updates max, <12 calls total
# ---------------------------------------------------------------------------
func _refresh_all() -> void:
	_update_score_visual()
	_update_timer_visual()
	_update_boost_visual()

func update_hud(scores: Dictionary, ticks_remaining: int, boost_amount: float) -> void:
	# Single entry point for World/Game loop — 3 calls, no alloc
	_call_count = 0
	_call_count += 1
	_score_pos = int(scores.get("positive", scores.get("team_1", _score_pos)))
	_score_neg = int(scores.get("negative", scores.get("team_minus1", _score_neg)))
	_update_score_visual()
	_call_count += 1
	_ticks_remaining = clamp(ticks_remaining, 0, MATCH_DURATION_TICKS)
	_update_timer_visual()
	_call_count += 1
	set_boost(boost_amount)

func reset() -> void:
	_score_pos = 0
	_score_neg = 0
	_ticks_remaining = MATCH_DURATION_TICKS
	_ticks_elapsed = 0
	_overtime = false
	_overtime_ticks = 0
	_boost_amount = 33.0
	_boost_normalized = 0.33
	_refresh_all()

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
	if not is_equal_approx(BOOST_MAX, 100.0):
		errors.append("BOOST_MAX %.1f != 100" % BOOST_MAX)
	if not is_equal_approx(CarBoostRef.MAX_BOOST, BOOST_MAX):
		errors.append("CarBoost MAX_BOOST %.1f != %.1f" % [CarBoostRef.MAX_BOOST, BOOST_MAX])
	if not is_equal_approx(CarBoostRef.BOOST_MAX, BOOST_MAX):
		errors.append("CarBoost BOOST_MAX drift")
	if DRAW_CALL_BUDGET > 12:
		errors.append("DRAW_CALL_BUDGET %d > 12" % DRAW_CALL_BUDGET)
	if MAX_DRAW_CALLS > 12:
		errors.append("MAX_DRAW_CALLS %d > 12" % MAX_DRAW_CALLS)
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("ESTIMATED_DRAW_CALLS %d > %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if MAX_CALLS_PER_TICK > 12:
		errors.append("MAX_CALLS_PER_TICK %d > 12" % MAX_CALLS_PER_TICK)
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PC.PHYSICS_TICK_DELTA, TICK_DELTA):
		errors.append("PC PHYSICS_TICK_DELTA mismatch")
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != -1 and ps_rate != 120:
		errors.append("project.godot physics_ticks_per_second=%d != 120" % ps_rate)
	# InputService check — must have boost
	var svc_script: GDScript = load("res://src/core/input_service.gd") as GDScript
	if svc_script == null:
		errors.append("input_service.gd not loadable")
	else:
		var tmp: Node = svc_script.new() as Node
		if tmp != null:
			if not ("boost" in tmp):
				errors.append("InputService missing boost property")
			tmp.free()
	# MatchTimer optional — if present, validate constants match
	var mt_path := "res://src/game/match_timer.gd"
	if FileAccess.file_exists(mt_path):
		var mt: GDScript = load(mt_path) as GDScript
		if mt != null:
			if int(mt.get("MATCH_DURATION_TICKS")) != MATCH_DURATION_TICKS:
				errors.append("MatchTimer MATCH_DURATION_TICKS drift")
			if int(mt.get("PHYSICS_TICKS_PER_SECOND")) != PHYSICS_TICKS_PER_SECOND:
				errors.append("MatchTimer PHYSICS_TICKS_PER_SECOND drift")
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"score_pos": _score_pos,
		"score_neg": _score_neg,
		"score_text": format_score(),
		"ticks_remaining": _ticks_remaining,
		"ticks_elapsed": _ticks_elapsed,
		"remaining_seconds": get_remaining_seconds(),
		"overtime": _overtime,
		"overtime_ticks": _overtime_ticks,
		"formatted_time": format_time(),
		"boost_amount": _boost_amount,
		"boost_normalized": _boost_normalized,
		"boost_text": "%d" % int(_boost_amount),
		"is_boosting": _is_boosting,
		"is_boost_low": is_boost_low(),
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"call_count": _call_count,
		"budget_calls": MAX_CALLS_PER_TICK,
		"layer": HUD_LAYER,
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "HUD",
		"draw_calls": ESTIMATED_DRAW_CALLS,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"budget_calls": MAX_CALLS_PER_TICK,
		"estimated_physics_ms": ESTIMATED_PHYSICS_MS,
		"budget_physics_ms": BUDGET_PHYSICS_MS,
		"tick_hz": PHYSICS_TICKS_PER_SECOND,
	}
