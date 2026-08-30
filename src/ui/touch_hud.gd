## WS78 — Touch HUD Layout + Safe Area (budget-aware, <12 calls)
## Composes WS26 Joystick (left 35%), WS28 ButtonCluster (bottom-right triangle), WS77 HUD (score/timer/boost).
## Safe area insets from DisplayServer/Window applied at runtime; respects touch_layout.json zones.
## Budget: <12 draw calls, <12 API calls/tick, no per-frame alloc, 120 Hz safe. Duo-safe stateless helpers.
extends CanvasLayer
class_name TouchHUD

const JoystickRef = preload("res://src/ui/touch/joystick.gd")
const ButtonClusterRef = preload("res://src/ui/touch/button_cluster.gd")
const HUDRef = preload("res://src/ui/hud.gd")

# ---------------------------------------------------------------------------
# Budget & tick — must match WS77 / PC / TimeService 120 Hz
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = 12
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
# Layout composes 3 sub-layers: joystick (1), button cluster (1), HUD (4) = ~6 draw calls
const ESTIMATED_DRAW_CALLS: int = 6
const BUDGET_PHYSICS_MS: float = 4.0
const ESTIMATED_PHYSICS_MS: float = 0.12

# ---------------------------------------------------------------------------
# Layout constants — mirrors touch_layout.json + WS26/WS28/WS77
# ---------------------------------------------------------------------------
## Left joystick zone: 35% width, 100% height, anchor left_center (WS26)
const JOYSTICK_WIDTH_PERCENT: float = 35.0
const JOYSTICK_HEIGHT_PERCENT: float = 100.0
const JOYSTICK_ANCHOR: String = "left_center"
const JOYSTICK_RADIUS_DP: float = 120.0
const JOYSTICK_DEADZONE_DP: float = 12.0

## Button cluster zone: bottom-right 35%x50% triangle (WS28)
const CLUSTER_WIDTH_PERCENT: float = 35.0
const CLUSTER_HEIGHT_PERCENT: float = 50.0
const CLUSTER_X_PERCENT: float = 65.0
const CLUSTER_Y_PERCENT: float = 50.0
const CLUSTER_MIN_TARGET_DP: float = 56.0
const CLUSTER_GAP_DP: float = 8.0
const CLUSTER_SAFE_PADDING_DP: float = 12.0

## HUD zone: top-center score/timer + bottom-right boost (WS77)
const HUD_LAYER: int = 10
const HUD_ANCHOR_TOP: String = "top_center"
const HUD_ANCHOR_BOOST: String = "bottom_right"

## Safe area
const SAFE_AREA_FALLBACK_INSET: int = 0

# ---------------------------------------------------------------------------
# State — deterministic, no alloc per frame
# ---------------------------------------------------------------------------
var _safe_insets: Rect2i = Rect2i(0, 0, 0, 0) # x=left, y=top, w=right, h=bottom as Rect2i
var _safe_rect: Rect2i = Rect2i(0, 0, 0, 0)
var _viewport_size: Vector2i = Vector2i.ZERO
var _layout_version: int = 0
var _call_count: int = 0
var _root_control: Control = null
var _joystick: Control = null
var _button_cluster: Control = null
var _hud: CanvasLayer = null
var _initialized: bool = false

signal layout_applied(version: int, viewport: Vector2i, safe_rect: Rect2i)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	layer = HUD_LAYER
	_viewport_size = _get_viewport_size()
	_safe_rect = _get_safe_area_rect()
	_safe_insets = _compute_safe_insets(_viewport_size, _safe_rect)
	_ensure_ui()
	_apply_layout()
	_initialized = true
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[TouchHUD] debug_validate: %s" % e)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_viewport_size = _get_viewport_size()
		_safe_rect = _get_safe_area_rect()
		_safe_insets = _compute_safe_insets(_viewport_size, _safe_rect)
		_apply_layout()

# ---------------------------------------------------------------------------
# Safe area — respects DisplayServer + Window insets (notched devices)
# ---------------------------------------------------------------------------
func _get_viewport_size() -> Vector2i:
	var vp: Vector2 = get_viewport().get_visible_rect().size if get_viewport() != null else Vector2.ZERO
	if vp.x > 0 and vp.y > 0:
		return Vector2i(int(vp.x), int(vp.y))
	var win_size: Vector2i = DisplayServer.window_get_size() if DisplayServer.get_screen_count() >= 0 else Vector2i.ZERO
	if win_size.x > 0:
		return win_size
	return Vector2i(1280, 720)

func _get_safe_area_rect() -> Rect2i:
	# Priority: DisplayServer.get_display_safe_area (Android/iOS notch), then Window safe area, fallback full viewport
	if DisplayServer.get_screen_count() > 0:
		var sa: Rect2i = DisplayServer.get_display_safe_area()
		if sa.size.x > 0 and sa.size.y > 0:
			return sa
	var vp := get_viewport()
	if vp != null and vp.has_method("get_display_safe_area"):
		# Godot 4.4 Window helper (some platforms)
		var r: Rect2i = vp.get_display_safe_area() as Rect2i
		if r.size.x > 0:
			return r
	# Fallback: full viewport = no inset
	var vs: Vector2i = _get_viewport_size()
	return Rect2i(0, 0, vs.x, vs.y)

func _compute_safe_insets(viewport: Vector2i, safe_rect: Rect2i) -> Rect2i:
	if viewport.x <= 0 or viewport.y <= 0:
		return Rect2i(0, 0, 0, 0)
	if safe_rect.size.x <= 0 or safe_rect.size.y <= 0:
		return Rect2i(0, 0, 0, 0)
	var left: int = safe_rect.position.x
	var top: int = safe_rect.position.y
	var right: int = viewport.x - (safe_rect.position.x + safe_rect.size.x)
	var bottom: int = viewport.y - (safe_rect.position.y + safe_rect.size.y)
	left = maxi(left, 0)
	top = maxi(top, 0)
	right = maxi(right, 0)
	bottom = maxi(bottom, 0)
	return Rect2i(left, top, right, bottom)

func get_safe_insets() -> Rect2i:
	return _safe_insets

func get_safe_area_rect() -> Rect2i:
	return _safe_rect

func get_viewport_for_layout() -> Vector2i:
	return _viewport_size

# ---------------------------------------------------------------------------
# UI construction — budget: 3 nodes, <12 calls
# ---------------------------------------------------------------------------
func _ensure_ui() -> void:
	if _root_control != null and is_instance_valid(_root_control):
		return
	var root := Control.new()
	root.name = "TouchHUD_Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_root_control = root

	# Joystick — left 35% (WS26)
	var joy := JoystickRef.new() if JoystickRef != null else Control.new()
	joy.name = "MoveJoystick"
	if joy.has_method("set_script"):
		pass
	root.add_child(joy)
	_joystick = joy as Control

	# Button cluster — bottom-right 35%x50% (WS28)
	var cluster := ButtonClusterRef.new() if ButtonClusterRef != null else Control.new()
	cluster.name = "ButtonCluster"
	root.add_child(cluster)
	_button_cluster = cluster as Control

	# HUD — top-center + boost (WS77)
	var hud := HUDRef.new() if HUDRef != null else CanvasLayer.new()
	if hud is CanvasLayer:
		# HUD is CanvasLayer; add as child of this layer's root control via sub-layer
		# Instead, instance as sibling CanvasLayer would stack; we keep as child Control wrapper
		# For composition, add HUD as child CanvasLayer sibling to TouchHUD
		# Simpler: if HUD is CanvasLayer, add as child to TouchHUD's parent handled in _apply_layout
		# Here we treat it as child CanvasLayer of this node (nested CanvasLayer is valid)
		add_child(hud)
		_hud = hud as CanvasLayer
	else:
		root.add_child(hud)
		_hud = null

func _apply_layout() -> void:
	if _root_control == null:
		return
	_layout_version += 1
	_call_count += 1
	var vp: Vector2i = _viewport_size
	if vp.x <= 0:
		vp = Vector2i(1280, 720)
	var insets: Rect2i = _safe_insets

	# Zone calculations — all in pixels, dp conversion handled by sub-nodes
	var joy_w: float = float(vp.x) * JOYSTICK_WIDTH_PERCENT / 100.0
	var joy_h: float = float(vp.y) * JOYSTICK_HEIGHT_PERCENT / 100.0
	var cluster_w: float = float(vp.x) * CLUSTER_WIDTH_PERCENT / 100.0
	var cluster_h: float = float(vp.y) * CLUSTER_HEIGHT_PERCENT / 100.0
	var cluster_x: float = float(vp.x) * CLUSTER_X_PERCENT / 100.0
	var cluster_y: float = float(vp.y) * CLUSTER_Y_PERCENT / 100.0

	# Apply safe insets: shrink/offset zones inward
	# Left inset pushes joystick right edge inward; right inset shrinks cluster; top/bottom push HUD
	var safe_left: float = float(insets.position.x)
	var safe_right: float = float(insets.size.x)
	var safe_top: float = float(insets.position.y)
	var safe_bottom: float = float(insets.size.y)

	# Joystick rect — left 35%, but inset-aware (add left padding, reduce width by right overlap if needed)
	if _joystick != null and is_instance_valid(_joystick):
		var jx: float = safe_left
		var jy: float = safe_top
		var jw: float = joy_w - safe_left
		# Ensure minimum width: at least radius*2
		jw = max(jw, JOYSTICK_RADIUS_DP * 2.0)
		var jh: float = float(vp.y) - safe_top - safe_bottom
		_joystick.position = Vector2(jx, jy)
		_joystick.size = Vector2(jw, jh)
		# Anchor preset: left 35% — override anchors to fixed inset
		_joystick.anchor_left = 0.0
		_joystick.anchor_top = 0.0
		_joystick.anchor_right = 0.0
		_joystick.anchor_bottom = 0.0
		_joystick.offset_left = jx
		_joystick.offset_top = jy
		_joystick.offset_right = jx + jw
		_joystick.offset_bottom = jy + jh

	# Button cluster rect — bottom-right 35%x50%, inset-aware
	if _button_cluster != null and is_instance_valid(_button_cluster):
		var cx: float = cluster_x
		var cy: float = cluster_y + safe_top * 0.0 # y zone starts at 50%, safe_top already excluded via vp
		var cw: float = cluster_w - safe_right
		var ch: float = cluster_h - safe_bottom
		# Clamp to viewport with safe padding
		if cx + cw > float(vp.x) - safe_right:
			cw = float(vp.x) - safe_right - cx
		if cy + ch > float(vp.y) - safe_bottom:
			ch = float(vp.y) - safe_bottom - cy
		cw = max(cw, CLUSTER_MIN_TARGET_DP * 3.0)
		ch = max(ch, CLUSTER_MIN_TARGET_DP * 3.0)
		_button_cluster.position = Vector2(cx, cy)
		_button_cluster.size = Vector2(cw, ch)
		_button_cluster.anchor_left = 0.0
		_button_cluster.anchor_top = 0.0
		_button_cluster.anchor_right = 0.0
		_button_cluster.anchor_bottom = 0.0
		_button_cluster.offset_left = cx
		_button_cluster.offset_top = cy
		_button_cluster.offset_right = cx + cw
		_button_cluster.offset_bottom = cy + ch

	# HUD already does its own layout (top-center timer/score, bottom-right boost)
	# Nudge HUD root if needed for safe insets: HUD's _root_control offsets are handled via HUD itself,
	# but we can apply safe margin via canvas layer offset if HUD exposes method
	if _hud != null and is_instance_valid(_hud):
		if _hud.has_method("apply_safe_insets"):
			_hud.call("apply_safe_insets", insets)
		# Fallback: offset HUD layer's root control via position if accessible
		if _hud.has_method("get_root_control"):
			var hr: Control = _hud.call("get_root_control") as Control
			if hr != null and is_instance_valid(hr):
				hr.offset_left = safe_left
				hr.offset_right = -safe_right
				hr.offset_top = safe_top
				hr.offset_bottom = -safe_bottom

	layout_applied.emit(_layout_version, vp, _safe_rect)

# ---------------------------------------------------------------------------
# Public API — layout queries (stateless helpers, <12 calls)
# ---------------------------------------------------------------------------
func get_joystick_rect(viewport: Vector2i = Vector2i.ZERO) -> Rect2:
	var vp: Vector2i = viewport if viewport.x > 0 else _viewport_size
	if vp.x <= 0:
		vp = Vector2i(1280, 720)
	var insets: Rect2i = _safe_insets
	var jx: float = float(insets.position.x)
	var jw: float = float(vp.x) * JOYSTICK_WIDTH_PERCENT / 100.0 - jx
	jw = max(jw, JOYSTICK_RADIUS_DP * 2.0)
	var jh: float = float(vp.y) - float(insets.position.y) - float(insets.size.y)
	return Rect2(Vector2(jx, float(insets.position.y)), Vector2(jw, jh))

func get_button_cluster_rect(viewport: Vector2i = Vector2i.ZERO) -> Rect2:
	var vp: Vector2i = viewport if viewport.x > 0 else _viewport_size
	if vp.x <= 0:
		vp = Vector2i(1280, 720)
	var insets: Rect2i = _safe_insets
	var cx: float = float(vp.x) * CLUSTER_X_PERCENT / 100.0
	var cy: float = float(vp.y) * CLUSTER_Y_PERCENT / 100.0
	var cw: float = float(vp.x) * CLUSTER_WIDTH_PERCENT / 100.0 - float(insets.size.x)
	var ch: float = float(vp.y) * CLUSTER_HEIGHT_PERCENT / 100.0 - float(insets.size.y)
	if cx + cw > float(vp.x) - float(insets.size.x):
		cw = float(vp.x) - float(insets.size.x) - cx
	if cy + ch > float(vp.y) - float(insets.size.y):
		ch = float(vp.y) - float(insets.size.y) - cy
	return Rect2(Vector2(cx, cy), Vector2(cw, ch))

func get_hud_safe_rect(viewport: Vector2i = Vector2i.ZERO) -> Rect2i:
	var vp: Vector2i = viewport if viewport.x > 0 else _viewport_size
	if vp.x <= 0:
		vp = Vector2i(1280, 720)
	var insets: Rect2i = _safe_insets
	return Rect2i(insets.position.x, insets.position.y, vp.x - insets.position.x - insets.size.x, vp.y - insets.position.y - insets.size.y)

static func compute_joystick_rect_static(viewport: Vector2i, insets: Rect2i) -> Rect2:
	var jx: float = float(insets.position.x)
	var jw: float = float(viewport.x) * 35.0 / 100.0 - jx
	jw = max(jw, 120.0 * 2.0)
	var jh: float = float(viewport.y) - float(insets.position.y) - float(insets.size.y)
	return Rect2(Vector2(jx, float(insets.position.y)), Vector2(jw, jh))

static func compute_cluster_rect_static(viewport: Vector2i, insets: Rect2i) -> Rect2:
	var cx: float = float(viewport.x) * 65.0 / 100.0
	var cy: float = float(viewport.y) * 50.0 / 100.0
	var cw: float = float(viewport.x) * 35.0 / 100.0 - float(insets.size.x)
	var ch: float = float(viewport.y) * 50.0 / 100.0 - float(insets.size.y)
	if cx + cw > float(viewport.x) - float(insets.size.x):
		cw = float(viewport.x) - float(insets.size.x) - cx
	if cy + ch > float(viewport.y) - float(insets.size.y):
		ch = float(viewport.y) - float(insets.size.y) - cy
	return Rect2(Vector2(cx, cy), Vector2(cw, ch))

static func compute_safe_insets_static(viewport: Vector2i, safe_rect: Rect2i) -> Rect2i:
	if viewport.x <= 0 or safe_rect.size.x <= 0:
		return Rect2i(0, 0, 0, 0)
	var left: int = safe_rect.position.x
	var top: int = safe_rect.position.y
	var right: int = viewport.x - (safe_rect.position.x + safe_rect.size.x)
	var bottom: int = viewport.y - (safe_rect.position.y + safe_rect.size.y)
	return Rect2i(maxi(left, 0), maxi(top, 0), maxi(right, 0), maxi(bottom, 0))

# ---------------------------------------------------------------------------
# Accessors
# ---------------------------------------------------------------------------
func get_joystick() -> Control:
	return _joystick

func get_button_cluster() -> Control:
	return _button_cluster

func get_hud() -> CanvasLayer:
	return _hud

func get_root_control() -> Control:
	return _root_control

func get_layout_version() -> int:
	return _layout_version

# Force re-layout (e.g., after orientation change) — budget: 1 call
func refresh_layout() -> void:
	_viewport_size = _get_viewport_size()
	_safe_rect = _get_safe_area_rect()
	_safe_insets = _compute_safe_insets(_viewport_size, _safe_rect)
	_apply_layout()

# Apply externally computed insets (for tests / platform bridge) — 1 call
func apply_safe_insets_override(insets: Rect2i, viewport: Vector2i = Vector2i.ZERO) -> void:
	if viewport.x > 0:
		_viewport_size = viewport
	_safe_insets = insets
	# Recompute safe_rect from insets+viewport for consistency
	_safe_rect = Rect2i(insets.position.x, insets.position.y, _viewport_size.x - insets.position.x - insets.size.x, _viewport_size.y - insets.position.y - insets.size.y)
	_apply_layout()

# ---------------------------------------------------------------------------
# Validation & perf — budget-aware (<12 calls, duo-safe)
# ---------------------------------------------------------------------------
func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	if JOYSTICK_WIDTH_PERCENT != 35.0:
		errors.append("JOYSTICK_WIDTH_PERCENT must be 35.0 (WS26) got %s" % str(JOYSTICK_WIDTH_PERCENT))
	if CLUSTER_WIDTH_PERCENT != 35.0 or CLUSTER_HEIGHT_PERCENT != 50.0:
		errors.append("Cluster must be 35%x50% at 65%,50% (WS28)")
	if CLUSTER_X_PERCENT != 65.0 or CLUSTER_Y_PERCENT != 50.0:
		errors.append("Cluster anchor must be 65%,50% got %s,%s" % [str(CLUSTER_X_PERCENT), str(CLUSTER_Y_PERCENT)])
	if DRAW_CALL_BUDGET != 12 or MAX_CALLS_PER_TICK != 12:
		errors.append("Budget must be <12 calls/draws")
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("Estimated %d draw calls exceeds budget %d" % [ESTIMATED_DRAW_CALLS, DRAW_CALL_BUDGET])
	if JOYSTICK_RADIUS_DP != 120.0:
		warnings.append("Joystick radius expected 120dp")
	if CLUSTER_MIN_TARGET_DP < 48.0:
		warnings.append("Cluster min target <48dp violates a11y")
	if HUD_LAYER != 10:
		warnings.append("HUD_LAYER expected 10 to match WS77")
	if _safe_insets.position.x < 0 or _safe_insets.position.y < 0 or _safe_insets.size.x < 0 or _safe_insets.size.y < 0:
		errors.append("Safe insets negative: %s" % str(_safe_insets))
	# Check composition
	if not _initialized and Engine.is_editor_hint() == false:
		warnings.append("Not yet _ready — layout pending")
	var ok: bool = errors.is_empty()
	return {"ok": ok, "errors": errors, "warnings": warnings, "estimated_draw_calls": ESTIMATED_DRAW_CALLS, "budget_draw_calls": DRAW_CALL_BUDGET, "within_budget": ESTIMATED_DRAW_CALLS <= DRAW_CALL_BUDGET, "layout_version": _layout_version, "safe_insets": _safe_insets, "safe_rect": _safe_rect, "viewport": _viewport_size}

func perf_mark() -> Dictionary:
	return {
		"estimated_draw_calls": ESTIMATED_DRAW_CALLS,
		"budget_draw_calls": DRAW_CALL_BUDGET,
		"within_budget": ESTIMATED_DRAW_CALLS <= DRAW_CALL_BUDGET,
		"calls_per_tick": 1,
		"budget_calls": BUDGET_CALLS,
		"estimated_physics_ms": ESTIMATED_PHYSICS_MS,
		"budget_physics_ms": BUDGET_PHYSICS_MS,
		"layout_version": _layout_version,
		"has_process": false,
		"event_driven": true,
	}

func get_budget_report() -> Dictionary:
	return perf_mark()
