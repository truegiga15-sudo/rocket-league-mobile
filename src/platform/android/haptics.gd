# Haptics — Android stub (WS06)
# Real implementation uses Android VibrationEffect / InputDevice vibrator.
# This stub runs on all platforms; no-ops on non-Android, safe to call from UI.
extends Node

enum HapticType {
	LIGHT_TAP,
	MEDIUM_TAP,
	HEAVY_TAP,
	LIGHT_CONTINUOUS,
	SELECTION,
	SUCCESS,
	WARNING,
	FAILURE
}

var _enabled: bool = true
var _available: bool = false

func _ready() -> void:
	_available = OS.has_feature("android") and _check_vibrator()

func _check_vibrator() -> bool:
	if Engine.has_singleton("GodotAndroidHaptics"):
		return true
	return OS.has_feature("android")

func is_available() -> bool:
	return _available

func set_enabled(v: bool) -> void:
	_enabled = v

func is_enabled() -> bool:
	return _enabled

func vibrate(pattern_ms: Array[int] = [], amplitudes: Array[int] = []) -> void:
	if not _enabled or not _available:
		return
	if Engine.has_singleton("GodotAndroidHaptics"):
		var singleton = Engine.get_singleton("GodotAndroidHaptics")
		if singleton and singleton.has_method("vibrate"):
			singleton.vibrate(pattern_ms, amplitudes)
			return
	if OS.has_feature("android") and pattern_ms.size() > 0:
		Input.vibrate_handheld(int(pattern_ms[0]))

func light_tap() -> void:
	vibrate([20], [64])

func medium_tap() -> void:
	vibrate([30], [128])

func heavy_tap() -> void:
	vibrate([50], [255])

func play(type: HapticType) -> void:
	match type:
		HapticType.LIGHT_TAP:
			light_tap()
		HapticType.MEDIUM_TAP:
			medium_tap()
		HapticType.HEAVY_TAP:
			heavy_tap()
		HapticType.LIGHT_CONTINUOUS:
			vibrate([15], [48])
		HapticType.SELECTION:
			light_tap()
		HapticType.SUCCESS:
			vibrate([20, 30, 20], [64, 0, 64])
		HapticType.WARNING:
			vibrate([40, 30, 40], [128, 0, 128])
		HapticType.FAILURE:
			vibrate([60, 40, 60], [200, 0, 200])
		_:
			light_tap()

func on_boost_start() -> void:
	if _enabled:
		play(HapticType.LIGHT_CONTINUOUS)

func on_jump() -> void:
	if _enabled:
		play(HapticType.MEDIUM_TAP)

func on_drift_start() -> void:
	if _enabled:
		play(HapticType.LIGHT_TAP)

func on_ball_cam_toggle() -> void:
	if _enabled:
		play(HapticType.SELECTION)

func debug_export() -> Dictionary:
	return {"enabled": _enabled, "available": _available}

func perf_mark() -> Dictionary:
	return {"haptics_enabled": _enabled}
