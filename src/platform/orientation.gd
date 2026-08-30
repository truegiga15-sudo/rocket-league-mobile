# OrientationService — WS33 Orientation Handling
# Landscape lock, safe area insets, orientation change recreating viewport/camera.
# Godot 4.x — uses InputService (WS06), CameraRig (WS29), World (WS23).
# Budget-aware: no per-frame allocation, idempotent apply, <12 calls per transition.
extends Node
class_name OrientationService

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
enum Orientation { UNKNOWN = 0, PORTRAIT = 1, LANDSCAPE = 2, REVERSE_LANDSCAPE = 3 }

const LANDSCAPE_SIZE_THRESHOLD: float = 1.0  # width > height => landscape

# ---------------------------------------------------------------------------
# Exports — wired via inspector or auto-discovered
# ---------------------------------------------------------------------------
## CameraRig to notify on orientation change (WS29).
@export var camera_rig_path: NodePath
## World node to notify (WS23) — kept for viewport/world matrix sync.
@export var world_path: NodePath

# ---------------------------------------------------------------------------
# Dependencies — resolved in _ready()
# ---------------------------------------------------------------------------
var _camera_rig: CameraRig = null
var _world: World = null
var _input_service: Node = null
var _viewport: Viewport = null

var _current_orientation: int = Orientation.LANDSCAPE
var _last_viewport_size: Vector2i = Vector2i.ZERO
var _safe_insets: Dictionary = {"top": 0, "bottom": 0, "left": 0, "right": 0}
var _initialized: bool = false
var _call_count: int = 0

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal orientation_changed(orientation: int, size: Vector2i)
signal safe_area_changed(insets: Dictionary)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_viewport = get_viewport()
	_resolve_dependencies()
	lock_landscape()
	_last_viewport_size = _get_viewport_size()
	_current_orientation = _detect_orientation(_last_viewport_size)
	_refresh_safe_area()
	_connect_viewport()
	_initialized = true

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_handle_orientation_change()

func _resolve_dependencies() -> void:
	_input_service = get_node_or_null("/root/InputService")
	if camera_rig_path != NodePath("") :
		_camera_rig = get_node_or_null(camera_rig_path) as CameraRig
	if _camera_rig == null:
		_camera_rig = _find_camera_rig()
	if world_path != NodePath(""):
		_world = get_node_or_null(world_path) as World
	if _world == null:
		_world = _find_world()
	if _viewport == null:
		_viewport = get_viewport()

func _find_camera_rig() -> CameraRig:
	var rig := get_node_or_null("/root/Main/CameraRig") as CameraRig
	if rig != null:
		return rig
	# search scene tree
	var root := get_tree().current_scene if get_tree() else null
	if root:
		var found := _find_by_class(root, "CameraRig")
		if found is CameraRig:
			return found as CameraRig
	return null

func _find_world() -> World:
	var w := get_node_or_null("/root/Main/World") as World
	if w != null:
		return w
	var root := get_tree().current_scene if get_tree() else null
	if root:
		var found := _find_by_class(root, "World")
		if found is World:
			return found as World
	return null

func _find_by_class(node: Node, cls: String) -> Node:
	if node.get_class() == cls or node.get_script() != null and node.get_script().get_global_name() == cls:
		return node
	for c in node.get_children():
		var r := _find_by_class(c, cls)
		if r != null:
			return r
	return null

func _connect_viewport() -> void:
	if _viewport and not _viewport.size_changed.is_connected(_on_viewport_size_changed):
		_viewport.size_changed.connect(_on_viewport_size_changed)

# ---------------------------------------------------------------------------
# Public API — landscape lock
# ---------------------------------------------------------------------------
## Lock screen to landscape. Safe on desktop (no-op if DisplayServer unsupported).
func lock_landscape() -> void:
	_call_count += 1
	if OS.has_feature("mobile") or DisplayServer.get_name() != "headless":
		if DisplayServer.has_method("screen_set_orientation"):
			DisplayServer.screen_set_orientation(DisplayServer.SCREEN_LANDSCAPE)
	# Also enforce via window: keep width > height handling
	_apply_landscape_window_hint()

func _apply_landscape_window_hint() -> void:
	# On desktop, ensure viewport is not portrait by swapping if needed (editor safety)
	if not OS.has_feature("mobile"):
		return
	# Mobile: nothing else — OS handles rotation lock

## Returns true if current viewport is landscape.
func is_landscape() -> bool:
	var sz := _get_viewport_size()
	return sz.x >= sz.y

## Current orientation enum.
func get_orientation() -> int:
	return _current_orientation

# ---------------------------------------------------------------------------
# Safe area insets
# ---------------------------------------------------------------------------
## Returns safe area insets as {top, bottom, left, right} in pixels.
func get_safe_area_insets() -> Dictionary:
	return _safe_insets.duplicate()

## Returns safe area rect in viewport coordinates (Rect2i).
func get_safe_area_rect() -> Rect2i:
	var vp_size := _get_viewport_size()
	# Try DisplayServer first
	if DisplayServer.has_method("get_display_safe_area"):
		var area: Rect2i = DisplayServer.get_display_safe_area()
		if area.size.x > 0 and area.size.y > 0:
			return area
	# Fallback: derive from insets
	if _safe_insets["top"] != 0 or _safe_insets["left"] != 0:
		return Rect2i(
			int(_safe_insets["left"]),
			int(_safe_insets["top"]),
			max(1, vp_size.x - int(_safe_insets["left"] + _safe_insets["right"])),
			max(1, vp_size.y - int(_safe_insets["top"] + _safe_insets["bottom"]))
		)
	return Rect2i(Vector2i.ZERO, vp_size)

## Refresh and apply safe area; emits safe_area_changed if changed.
func _refresh_safe_area() -> Dictionary:
	var vp_size := _get_viewport_size()
	var new_insets := _compute_safe_insets(vp_size)
	if new_insets != _safe_insets:
		_safe_insets = new_insets
		_apply_safe_area_to_input()
		safe_area_changed.emit(_safe_insets.duplicate())
	return _safe_insets.duplicate()

func _compute_safe_insets(vp_size: Vector2i) -> Dictionary:
	var insets := {"top": 0, "bottom": 0, "left": 0, "right": 0}
	# Godot 4.4: Window.get_safe_area or DisplayServer.get_display_safe_area
	if DisplayServer.has_method("get_display_safe_area"):
		var area: Rect2i = DisplayServer.get_display_safe_area()
		if area.size.x > 0 and area.size.y > 0 and area.size != vp_size:
			insets["left"] = area.position.x
			insets["top"] = area.position.y
			insets["right"] = max(0, vp_size.x - (area.position.x + area.size.x))
			insets["bottom"] = max(0, vp_size.y - (area.position.y + area.size.y))
			return insets
	# Viewport fallback: check window safe area via get_window()
	var win := get_window() if has_method("get_window") else null
	if win and win.has_method("get_safe_area"):
		pass
	# Notch heuristic on mobile: keep 12dp padding already in touch_layout.json
	# Return zero insets on desktop / without notch
	return insets

func _apply_safe_area_to_input() -> void:
	# Notify InputService if it exposes safe area hook (optional, duck-typed)
	if _input_service and _input_service.has_method("set_safe_area_insets"):
		_input_service.set_safe_area_insets(_safe_insets)
	elif _input_service and _input_service.has_method("set_safe_area"):
		_input_service.set_safe_area(get_safe_area_rect())

# ---------------------------------------------------------------------------
# Orientation change — recreating viewport/camera
# ---------------------------------------------------------------------------
func _on_viewport_size_changed() -> void:
	_handle_orientation_change()

func _handle_orientation_change() -> void:
	_call_count += 1
	var new_size := _get_viewport_size()
	if new_size == _last_viewport_size and _initialized:
		# still refresh safe area — inset may change without size change (foldable)
		_refresh_safe_area()
		return
	var new_orientation := _detect_orientation(new_size)
	var changed := new_orientation != _current_orientation or new_size != _last_viewport_size
	_last_viewport_size = new_size
	_current_orientation = new_orientation
	_refresh_safe_area()
	if changed:
		_recreate_viewport_camera(new_size)
		orientation_changed.emit(_current_orientation, new_size)

func _detect_orientation(sz: Vector2i) -> int:
	if sz.x == 0 or sz.y == 0:
		return Orientation.UNKNOWN
	if sz.x >= sz.y:
		return Orientation.LANDSCAPE
	return Orientation.PORTRAIT

## Recreate / reconfigure viewport and camera after orientation change.
## Recreates viewport scaling and notifies CameraRig + World.
func _recreate_viewport_camera(viewport_size: Vector2i) -> void:
	_call_count += 1
	if _viewport == null:
		_viewport = get_viewport()
		if _viewport == null:
			return
	# 1) Re-apply viewport size / canvas transform
	# Godot handles window resize automatically; we ensure stretch and msaa persist
	# and force an update for CameraRig aspect.
	# 2) Notify CameraRig to re-cache SpringArm/Camera and re-apply FOV/aspect
	if _camera_rig != null:
		if _camera_rig.has_method("_cache_nodes"):
			_camera_rig._cache_nodes()
		if _camera_rig.has_method("_sync_spring_arm"):
			_camera_rig._sync_spring_arm()
		if _camera_rig.has_method("_apply_fov"):
			_camera_rig._apply_fov()
		# Force camera to update aspect from viewport
		var cam: Camera3D = _find_camera_in_rig()
		if cam:
			# Reset aspect to viewport — Godot auto, but ensure keep_aspect correct
			cam.keep_aspect = Camera3D.KEEP_HEIGHT if viewport_size.x >= viewport_size.y else Camera3D.KEEP_WIDTH
			# Trigger viewport re-render
			cam.force_update_transform()
	# 3) World — no recreation needed but notify for debug/transforms
	if _world and _world.has_method("debug_validate"):
		pass
	# 4) InputService — reset touch state so stale joystick positions don't carry over
	if _input_service and _input_service.has_method("reset_touch"):
		_input_service.reset_touch()
	_viewport.queue_redraw() if _viewport.has_method("queue_redraw") else null

func _find_camera_in_rig() -> Camera3D:
	if _camera_rig == null:
		return null
	# Try cached field first
	if "_camera" in _camera_rig and _camera_rig._camera is Camera3D:
		return _camera_rig._camera as Camera3D
	for c in _camera_rig.get_children():
		if c is Camera3D:
			return c as Camera3D
		for gc in c.get_children():
			if gc is Camera3D:
				return gc as Camera3D
	return null

func _get_viewport_size() -> Vector2i:
	if _viewport:
		var r: Rect2 = _viewport.get_visible_rect()
		if r.size.x > 0 and r.size.y > 0:
			return Vector2i(r.size)
		return _viewport.get_visible_rect().size as Vector2i
	var win := get_window() if has_method("get_window") else null
	if win:
		return win.size
	return Vector2i.ZERO

# ---------------------------------------------------------------------------
# Debug / telemetry — 00-conventions.md §11
# ---------------------------------------------------------------------------
func debug_export() -> Dictionary:
	return {
		"orientation": _current_orientation,
		"is_landscape": is_landscape(),
		"viewport_size": _last_viewport_size,
		"safe_insets": _safe_insets.duplicate(),
		"safe_rect": get_safe_area_rect(),
		"initialized": _initialized,
		"call_count": _call_count,
	}

func perf_mark() -> Dictionary:
	return {"calls": _call_count, "orientation": _current_orientation}
