# Touch Button Cluster — WS28 Boost/Jump/Drift (budget-aware, <12 calls)
# Bottom-right triangle cluster per touch_layout.json action_cluster.
# Boost 72dp (hold, bottom-right -12,-12), Jump 64dp (tap, -92,-12), Drift 56dp (hold, -12,-92)
# Gap 8dp, min target 56dp, safe padding 12dp. Outputs to InputService.set_touch_boost/jump/drift.
# Haptics via Haptics autoload. Budget-aware: no _process, event-driven only, <12 draw calls.
# Provides debug_export() and perf_mark() per 00-conventions.md §11.
extends Control
class_name TouchButtonCluster

# ---------------------------------------------------------------------------
# Tunables — match touch_layout.json action_cluster
# ---------------------------------------------------------------------------
@export var boost_size_dp: float = 72.0
@export var jump_size_dp: float = 64.0
@export var drift_size_dp: float = 56.0
@export var gap_dp: float = 8.0
@export var min_target_dp: float = 56.0
@export var safe_padding_dp: float = 12.0
@export var opacity_idle: float = 0.85
@export var opacity_pressed: float = 1.0

# ---------------------------------------------------------------------------
# Internal state — event-driven, no per-frame polling
# ---------------------------------------------------------------------------
var _boost_pressed: bool = false
var _jump_pressed: bool = false
var _drift_pressed: bool = false

# touch_index -> "boost"|"jump"|"drift"
var _touch_owners: Dictionary = {}
# button -> touch_index (reverse, for release without search)
var _button_touch: Dictionary = {"boost": -1, "jump": -1, "drift": -1}

var _boost_rect: Rect2 = Rect2()
var _jump_rect: Rect2 = Rect2()
var _drift_rect: Rect2 = Rect2()
var _scale: float = 1.0
var _perf_samples: int = 0
var _haptics_calls: int = 0
var _input_calls: int = 0
var _initialized: bool = false

# Cached node refs for visual feedback (optional, not required for logic)
var _btn_boost: Control = null
var _btn_jump: Control = null
var _btn_drift: Control = null

signal boost_state_changed(pressed: bool)
signal jump_state_changed(pressed: bool)
signal drift_state_changed(pressed: bool)

func _ready() -> void:
	_update_metrics()
	_cache_nodes()
	_layout_buttons()
	mouse_filter = Control.MOUSE_FILTER_STOP
	_apply_visuals()
	_initialized = true
	notification(NOTIFICATION_RESIZED)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_metrics()
		_layout_buttons()
		_apply_visuals()

func _cache_nodes() -> void:
	_btn_boost = get_node_or_null("Button_Boost") as Control
	if _btn_boost == null:
		_btn_boost = get_node_or_null("TextureButton_Boost") as Control
	if _btn_boost == null:
		for c in get_children():
			if c.name.to_lower().contains("boost"):
				_btn_boost = c as Control
				break
	_btn_jump = get_node_or_null("Button_Jump") as Control
	if _btn_jump == null:
		_btn_jump = get_node_or_null("TextureButton_Jump") as Control
	if _btn_jump == null:
		for c in get_children():
			if c.name.to_lower().contains("jump"):
				_btn_jump = c as Control
				break
	_btn_drift = get_node_or_null("Button_Drift") as Control
	if _btn_drift == null:
		_btn_drift = get_node_or_null("TextureButton_Drift") as Control
	if _btn_drift == null:
		for c in get_children():
			if c.name.to_lower().contains("drift"):
				_btn_drift = c as Control
				break

func _get_dp_scale() -> float:
	var dpi: float = 0.0
	if DisplayServer.get_screen_count() > 0:
		var s_dpi := DisplayServer.screen_get_dpi(0)
		if s_dpi > 0:
			dpi = float(s_dpi)
	if dpi <= 0.0:
		dpi = 160.0
	return dpi / 160.0

func _update_metrics() -> void:
	_scale = _get_dp_scale()
	if _scale <= 0.0:
		_scale = 1.0
	if boost_size_dp < min_target_dp:
		boost_size_dp = min_target_dp
	if jump_size_dp < min_target_dp:
		jump_size_dp = min_target_dp
	if drift_size_dp < min_target_dp:
		drift_size_dp = min_target_dp
	if gap_dp < 8.0:
		gap_dp = 8.0

func _layout_buttons() -> void:
	var pad_px: float = safe_padding_dp * _scale
	var gap_px: float = gap_dp * _scale
	var boost_px: float = boost_size_dp * _scale
	var jump_px: float = jump_size_dp * _scale
	var drift_px: float = drift_size_dp * _scale
	var avail_w: float = size.x if size.x > 0 else get_viewport_rect().size.x * 0.35
	var avail_h: float = size.y if size.y > 0 else get_viewport_rect().size.y * 0.5
	if avail_w <= 0:
		avail_w = 400
	if avail_h <= 0:
		avail_h = 300
	var base_w: float = size.x if size.x > 0 else avail_w
	var base_h: float = size.y if size.y > 0 else avail_h
	var boost_pos := Vector2(base_w - pad_px - boost_px, base_h - pad_px - boost_px)
	var jump_pos := Vector2(boost_pos.x - gap_px - jump_px, base_h - pad_px - jump_px)
	var drift_pos := Vector2(base_w - pad_px - drift_px, boost_pos.y - gap_px - drift_px)
	if jump_pos.x < 0:
		jump_pos.x = max(0.0, boost_pos.x - gap_px - jump_px)
	if drift_pos.y < 0:
		drift_pos.y = max(0.0, boost_pos.y - gap_px - drift_px)
	_boost_rect = Rect2(boost_pos, Vector2(boost_px, boost_px))
	_jump_rect = Rect2(jump_pos, Vector2(jump_px, jump_px))
	_drift_rect = Rect2(drift_pos, Vector2(drift_px, drift_px))
	if _btn_boost != null:
		_btn_boost.position = boost_pos
		_btn_boost.size = Vector2(boost_px, boost_px)
	if _btn_jump != null:
		_btn_jump.position = jump_pos
		_btn_jump.size = Vector2(jump_px, jump_px)
	if _btn_drift != null:
		_btn_drift.position = drift_pos
		_btn_drift.size = Vector2(drift_px, drift_px)

func _apply_visuals() -> void:
	var idle_a: float = opacity_idle
	for btn in [_btn_boost, _btn_jump, _btn_drift]:
		if btn != null:
			btn.modulate.a = idle_a
			btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_update_pressed_visual("boost", _boost_pressed)
	_update_pressed_visual("jump", _jump_pressed)
	_update_pressed_visual("drift", _drift_pressed)

func _update_pressed_visual(button: String, pressed: bool) -> void:
	var btn: Control = null
	match button:
		"boost": btn = _btn_boost
		"jump": btn = _btn_jump
		"drift": btn = _btn_drift
	if btn == null:
		return
	btn.modulate.a = opacity_pressed if pressed else opacity_idle
	if pressed:
		btn.scale = Vector2(0.95, 0.95)
	else:
		btn.scale = Vector2(1.0, 1.0)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		var local_pos: Vector2 = t.position - get_global_position()
		if t.pressed:
			_handle_press(t.index, local_pos)
		else:
			_handle_release(t.index)
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		var local_pos2: Vector2 = d.position - get_global_position()
		_handle_drag(d.index, local_pos2)

func _hit_test(local_pos: Vector2) -> String:
	if _boost_rect.has_point(local_pos):
		return "boost"
	if _jump_rect.has_point(local_pos):
		return "jump"
	if _drift_rect.has_point(local_pos):
		return "drift"
	return ""

func _handle_press(touch_id: int, local_pos: Vector2) -> void:
	if _touch_owners.has(touch_id):
		return
	var hit := _hit_test(local_pos)
	if hit == "":
		return
	_touch_owners[touch_id] = hit
	_button_touch[hit] = touch_id
	_set_button(hit, true)
	_perf_samples += 1
	accept_event()

func _handle_drag(touch_id: int, local_pos: Vector2) -> void:
	if not _touch_owners.has(touch_id):
		return
	var owned: String = _touch_owners[touch_id]
	var rect: Rect2 = _rect_for(owned)
	if not rect.has_point(local_pos):
		var new_hit := _hit_test(local_pos)
		if new_hit != "" and new_hit != owned and _button_touch.get(new_hit, -1) == -1:
			_set_button(owned, false)
			_touch_owners[touch_id] = new_hit
			_button_touch[owned] = -1
			_button_touch[new_hit] = touch_id
			_set_button(new_hit, true)
		else:
			var hysteresis: float = 8.0 * _scale
			var expanded := rect.grow(hysteresis)
			if not expanded.has_point(local_pos):
				_handle_release(touch_id)
				return
	_perf_samples += 1

func _handle_release(touch_id: int) -> void:
	if not _touch_owners.has(touch_id):
		return
	var owned: String = _touch_owners[touch_id]
	_touch_owners.erase(touch_id)
	_button_touch[owned] = -1
	_set_button(owned, false)
	_perf_samples += 1
	accept_event()

func _rect_for(button: String) -> Rect2:
	match button:
		"boost": return _boost_rect
		"jump": return _jump_rect
		"drift": return _drift_rect
	return Rect2()

func _set_button(button: String, pressed: bool) -> void:
	var changed: bool = false
	match button:
		"boost":
			if _boost_pressed != pressed:
				_boost_pressed = pressed
				changed = true
				_push_boost(pressed)
				boost_state_changed.emit(pressed)
				if pressed:
					_haptics_boost()
		"jump":
			if _jump_pressed != pressed:
				_jump_pressed = pressed
				changed = true
				_push_jump(pressed)
				jump_state_changed.emit(pressed)
				if pressed:
					_haptics_jump()
		"drift":
			if _drift_pressed != pressed:
				_drift_pressed = pressed
				changed = true
				_push_drift(pressed)
				drift_state_changed.emit(pressed)
				if pressed:
					_haptics_drift()
	if changed:
		_update_pressed_visual(button, pressed)

func _get_input_service() -> Node:
	if get_tree() == null:
		return null
	var svc: Node = get_tree().root.get_node_or_null("InputService")
	if svc != null:
		return svc
	if Engine.has_singleton("InputService"):
		return Engine.get_singleton("InputService") as Node
	return null

func _push_boost(pressed: bool) -> void:
	var svc := _get_input_service()
	if svc != null and svc.has_method("set_touch_boost"):
		svc.call("set_touch_boost", pressed)
		_input_calls += 1

func _push_jump(pressed: bool) -> void:
	var svc := _get_input_service()
	if svc != null and svc.has_method("set_touch_jump"):
		svc.call("set_touch_jump", pressed)
		_input_calls += 1

func _push_drift(pressed: bool) -> void:
	var svc := _get_input_service()
	if svc != null and svc.has_method("set_touch_drift"):
		svc.call("set_touch_drift", pressed)
		_input_calls += 1

func _get_haptics() -> Node:
	if get_tree() == null:
		return null
	var h: Node = get_tree().root.get_node_or_null("Haptics")
	if h != null:
		return h
	if Engine.has_singleton("Haptics"):
		return Engine.get_singleton("Haptics") as Node
	return null

func _haptics_boost() -> void:
	var h := _get_haptics()
	if h == null:
		return
	_haptics_calls += 1
	if h.has_method("on_boost_start"):
		h.call("on_boost_start")
	elif h.has_method("play"):
		h.call("play", 3)
	elif h.has_method("light_tap"):
		h.call("light_tap")

func _haptics_jump() -> void:
	var h := _get_haptics()
	if h == null:
		return
	_haptics_calls += 1
	if h.has_method("on_jump"):
		h.call("on_jump")
	elif h.has_method("play"):
		h.call("play", 1)
	elif h.has_method("medium_tap"):
		h.call("medium_tap")

func _haptics_drift() -> void:
	var h := _get_haptics()
	if h == null:
		return
	_haptics_calls += 1
	if h.has_method("on_drift_start"):
		h.call("on_drift_start")
	elif h.has_method("play"):
		h.call("play", 0)
	elif h.has_method("light_tap"):
		h.call("light_tap")

func is_boost_pressed() -> bool:
	return _boost_pressed

func is_jump_pressed() -> bool:
	return _jump_pressed

func is_drift_pressed() -> bool:
	return _drift_pressed

func get_button_rect(button: String) -> Rect2:
	return _rect_for(button)

func get_dp_scale() -> float:
	return _scale

func reset_all() -> void:
	for tid in _touch_owners.keys():
		var btn: String = _touch_owners[tid]
		_set_button(btn, false)
	_touch_owners.clear()
	_button_touch = {"boost": -1, "jump": -1, "drift": -1}
	_boost_pressed = false
	_jump_pressed = false
	_drift_pressed = false
	_push_boost(false)
	_push_jump(false)
	_push_drift(false)
	_apply_visuals()

func debug_export() -> Dictionary:
	return {
		"boost_pressed": _boost_pressed,
		"jump_pressed": _jump_pressed,
		"drift_pressed": _drift_pressed,
		"touch_owners": _touch_owners.duplicate(),
		"button_touch": _button_touch.duplicate(),
		"boost_rect": _boost_rect,
		"jump_rect": _jump_rect,
		"drift_rect": _drift_rect,
		"boost_size_dp": boost_size_dp,
		"jump_size_dp": jump_size_dp,
		"drift_size_dp": drift_size_dp,
		"gap_dp": gap_dp,
		"min_target_dp": min_target_dp,
		"safe_padding_dp": safe_padding_dp,
		"scale": _scale,
		"haptics_calls": _haptics_calls,
		"input_calls": _input_calls,
		"perf_samples": _perf_samples,
	}

func perf_mark() -> Dictionary:
	_perf_samples += 1
	var estimated_draw_calls: int = 4
	if _btn_boost != null:
		estimated_draw_calls = get_child_count() + 1
		if estimated_draw_calls > 12:
			estimated_draw_calls = 12
	var active_count: int = int(_boost_pressed) + int(_jump_pressed) + int(_drift_pressed)
	return {
		"samples": _perf_samples,
		"active_buttons": active_count,
		"boost": _boost_pressed,
		"jump": _jump_pressed,
		"drift": _drift_pressed,
		"estimated_draw_calls": estimated_draw_calls,
		"budget_draw_calls": 12,
		"within_budget": estimated_draw_calls < 12,
		"haptics_calls": _haptics_calls,
		"input_calls": _input_calls,
		"event_driven": true,
		"has_process": false,
	}
