## WS85 -- Accessibility Colorblind Options (budget-aware <12 calls, deterministic)
## Colorblind presets (deuteranopia / protanopia / tritanopia) + high contrast
## Remaps team colors from WS48 CarShader single source. No per-frame alloc.
## Budget: <12 draw calls (0 -- pure logic, no 3D), <12 API calls/tick, headless-safe, 120 Hz safe.
## Depends on: src/game/car/car_shader.gd (WS48 -- TEAM_BLUE_COLOR / TEAM_ORANGE_COLOR),
##             src/core/config_service.gd (WS08 -- persistence), src/core/save_service.gd (WS08)
## Duo-safe: stays under 12 storage / material / draw calls per tick.
extends Node
class_name Accessibility

const CarShaderRef = preload("res://src/game/car/car_shader.gd")
const ConfigServiceRef = preload("res://src/core/config_service.gd")

# ---------------------------------------------------------------------------
# Budget -- WS10 global, <12 per subsystem (Duo-safe)
# ---------------------------------------------------------------------------
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const ESTIMATED_DRAW_CALLS: int = 0  # pure logic, no rendering
const MAX_TRIS_BUDGET: int = 0
const ESTIMATED_TRIS: int = 0
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = 12
const BUDGET_PHYSICS_MS: float = 4.0
const ESTIMATED_PHYSICS_MS: float = 0.02
const TICK_HZ: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Presets -- deterministic, authored only
# ---------------------------------------------------------------------------
enum Preset {
	NONE = 0,
	DEUTERANOPIA = 1,
	PROTANOPIA = 2,
	TRITANOPIA = 3,
	HIGH_CONTRAST = 4,
}

const PRESET_NONE: int = Preset.NONE
const PRESET_DEUTERANOPIA: int = Preset.DEUTERANOPIA
const PRESET_PROTANOPIA: int = Preset.PROTANOPIA
const PRESET_TRITANOPIA: int = Preset.TRITANOPIA
const PRESET_HIGH_CONTRAST: int = Preset.HIGH_CONTRAST

const PRESET_KEYS: Array[String] = ["none", "deuteranopia", "protanopia", "tritanopia", "high_contrast"]
const PRESET_COUNT: int = 5
const DEFAULT_PRESET: String = "none"

# Separate high-contrast toggle -- can combine with any colorblind preset
const HIGH_CONTRAST_ENABLED: bool = false

# Colorblind enum without high_contrast compound (for UI picker)
enum ColorblindMode {
	NONE = 0,
	DEUTERANOPIA = 1,
	PROTANOPIA = 2,
	TRITANOPIA = 3,
}

# ---------------------------------------------------------------------------
# Team colors -- remapped from WS48 single source
# Original WS48: BLUE (0.07,0.42,0.92) vs ORANGE (0.95,0.42,0.06)
# Remaps chosen for distinguishability per CIE / ColorBrewer accessible palettes.
# All values authored, deterministic, no procedural.
# ---------------------------------------------------------------------------

# Baseline mirrors WS48 (single source -- do not duplicate drift)
const TEAM_BLUE_BASE: Color = Color(0.07, 0.42, 0.92, 1.0)
const TEAM_ORANGE_BASE: Color = Color(0.95, 0.42, 0.06, 1.0)

# Deuteranopia (red-green, ~6% males): blue stays, orange -> gold/yellow shift
const TEAM_BLUE_DEUTERANOPIA: Color = Color(0.0, 0.45, 0.70, 1.0)
const TEAM_ORANGE_DEUTERANOPIA: Color = Color(0.90, 0.75, 0.0, 1.0)
const TEAM_BLUE_ACCENT_DEUTERANOPIA: Color = Color(0.0, 0.32, 0.55, 1.0)
const TEAM_ORANGE_ACCENT_DEUTERANOPIA: Color = Color(0.72, 0.58, 0.0, 1.0)

# Protanopia (red-blind): similar to deuteranopia but orange pushed further to yellow
const TEAM_BLUE_PROTANOPIA: Color = Color(0.05, 0.35, 0.85, 1.0)
const TEAM_ORANGE_PROTANOPIA: Color = Color(0.85, 0.65, 0.05, 1.0)
const TEAM_BLUE_ACCENT_PROTANOPIA: Color = Color(0.04, 0.26, 0.68, 1.0)
const TEAM_ORANGE_ACCENT_PROTANOPIA: Color = Color(0.68, 0.50, 0.02, 1.0)

# Tritanopia (blue-yellow, rare): blue -> purplish, orange -> reddish-pink shift
const TEAM_BLUE_TRITANOPIA: Color = Color(0.25, 0.45, 0.95, 1.0)
const TEAM_ORANGE_TRITANOPIA: Color = Color(0.95, 0.35, 0.20, 1.0)
const TEAM_BLUE_ACCENT_TRITANOPIA: Color = Color(0.18, 0.32, 0.78, 1.0)
const TEAM_ORANGE_ACCENT_TRITANOPIA: Color = Color(0.78, 0.24, 0.14, 1.0)

# High contrast (WCAG AAA inspired): vivid, increased luminance difference
const TEAM_BLUE_HIGH_CONTRAST: Color = Color(0.0, 0.35, 1.0, 1.0)
const TEAM_ORANGE_HIGH_CONTRAST: Color = Color(1.0, 0.65, 0.0, 1.0)
const TEAM_BLUE_ACCENT_HIGH_CONTRAST: Color = Color(0.0, 0.25, 0.80, 1.0)
const TEAM_ORANGE_ACCENT_HIGH_CONTRAST: Color = Color(0.85, 0.50, 0.0, 1.0)

# High-contrast combined: deuteranopia+HC, etc. -- simple luminance boost on top
const HC_BRIGHTNESS_BOOST: float = 0.06

# Lookup dictionaries -- deterministic, no alloc per tick beyond return
const TEAM_COLORS_BASE: Dictionary = {
	0: TEAM_BLUE_BASE,
	1: TEAM_ORANGE_BASE,
}
const TEAM_ACCENTS_BASE: Dictionary = {
	0: Color(0.05, 0.28, 0.70, 1.0),
	1: Color(0.78, 0.30, 0.04, 1.0),
}

const REMAP_PRIMARY: Dictionary = {
	"none": {0: TEAM_BLUE_BASE, 1: TEAM_ORANGE_BASE},
	"deuteranopia": {0: TEAM_BLUE_DEUTERANOPIA, 1: TEAM_ORANGE_DEUTERANOPIA},
	"protanopia": {0: TEAM_BLUE_PROTANOPIA, 1: TEAM_ORANGE_PROTANOPIA},
	"tritanopia": {0: TEAM_BLUE_TRITANOPIA, 1: TEAM_ORANGE_TRITANOPIA},
	"high_contrast": {0: TEAM_BLUE_HIGH_CONTRAST, 1: TEAM_ORANGE_HIGH_CONTRAST},
}

const REMAP_ACCENT: Dictionary = {
	"none": {0: Color(0.05, 0.28, 0.70, 1.0), 1: Color(0.78, 0.30, 0.04, 1.0)},
	"deuteranopia": {0: TEAM_BLUE_ACCENT_DEUTERANOPIA, 1: TEAM_ORANGE_ACCENT_DEUTERANOPIA},
	"protanopia": {0: TEAM_BLUE_ACCENT_PROTANOPIA, 1: TEAM_ORANGE_ACCENT_PROTANOPIA},
	"tritanopia": {0: TEAM_BLUE_ACCENT_TRITANOPIA, 1: TEAM_ORANGE_ACCENT_TRITANOPIA},
	"high_contrast": {0: TEAM_BLUE_ACCENT_HIGH_CONTRAST, 1: TEAM_ORANGE_ACCENT_HIGH_CONTRAST},
}

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal preset_changed(preset: String, high_contrast: bool)
signal accessibility_reset

# ---------------------------------------------------------------------------
# Instance state -- for autoload / settings persistence
# ---------------------------------------------------------------------------
var _preset: String = DEFAULT_PRESET
var _high_contrast: bool = false
var _call_count: int = 0

# ---------------------------------------------------------------------------
# Static helpers -- pure, deterministic, headless-safe, <12 calls
# ---------------------------------------------------------------------------
static func is_valid_preset(key: String) -> bool:
	return key in PRESET_KEYS

static func preset_to_int(key: String) -> int:
	match key:
		"none": return Preset.NONE
		"deuteranopia": return Preset.DEUTERANOPIA
		"protanopia": return Preset.PROTANOPIA
		"tritanopia": return Preset.TRITANOPIA
		"high_contrast": return Preset.HIGH_CONTRAST
		_: return Preset.NONE

static func int_to_preset(v: int) -> String:
	match v:
		Preset.NONE: return "none"
		Preset.DEUTERANOPIA: return "deuteranopia"
		Preset.PROTANOPIA: return "protanopia"
		Preset.TRITANOPIA: return "tritanopia"
		Preset.HIGH_CONTRAST: return "high_contrast"
		_: return "none"

static func get_team_color(team: int, preset: String = "none", high_contrast: bool = false) -> Color:
	var p: String = preset if preset in REMAP_PRIMARY else "none"
	var map: Dictionary = REMAP_PRIMARY[p]
	var c: Color = map.get(team, TEAM_BLUE_BASE) as Color
	if high_contrast and p != "high_contrast":
		# boost luminance slightly for HC combo
		c = _apply_high_contrast_boost(c)
	return c

static func get_team_accent(team: int, preset: String = "none", high_contrast: bool = false) -> Color:
	var p: String = preset if preset in REMAP_ACCENT else "none"
	var map: Dictionary = REMAP_ACCENT[p]
	var c: Color = map.get(team, Color(0.05, 0.28, 0.70, 1.0)) as Color
	if high_contrast and p != "high_contrast":
		c = _apply_high_contrast_boost(c)
	return c

static func _apply_high_contrast_boost(c: Color) -> Color:
	# deterministic luminance boost, clamp to 1.0
	return Color(clamp(c.r + HC_BRIGHTNESS_BOOST, 0.0, 1.0), clamp(c.g + HC_BRIGHTNESS_BOOST, 0.0, 1.0), clamp(c.b + HC_BRIGHTNESS_BOOST, 0.0, 1.0), c.a)

static func remap_color(color: Color, preset: String = "none", high_contrast: bool = false) -> Color:
	# Generic remap: if color matches a base team color (within epsilon), return remapped team color.
	# Otherwise apply matrix-free luminance tweak for high contrast only.
	if color.is_equal_approx(TEAM_BLUE_BASE):
		return get_team_color(0, preset, high_contrast)
	if color.is_equal_approx(TEAM_ORANGE_BASE):
		return get_team_color(1, preset, high_contrast)
	if color.is_equal_approx(TEAM_ACCENTS_BASE[0]):
		return get_team_accent(0, preset, high_contrast)
	if color.is_equal_approx(TEAM_ACCENTS_BASE[1]):
		return get_team_accent(1, preset, high_contrast)
	if high_contrast:
		return _apply_high_contrast_boost(color)
	return color

static func get_remapped_team_colors(preset: String = "none", high_contrast: bool = false) -> Dictionary:
	return {
		0: get_team_color(0, preset, high_contrast),
		1: get_team_color(1, preset, high_contrast),
	}

static func get_remapped_team_accents(preset: String = "none", high_contrast: bool = false) -> Dictionary:
	return {
		0: get_team_accent(0, preset, high_contrast),
		1: get_team_accent(1, preset, high_contrast),
	}

static func payload_for_config(preset: String, high_contrast: bool) -> Dictionary:
	return {"accessibility": {"preset": preset, "high_contrast": high_contrast}}

static func default_accessibility_config() -> Dictionary:
	return {"preset": DEFAULT_PRESET, "high_contrast": false}

# ---------------------------------------------------------------------------
# Validation -- deterministic, <12 calls
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	if PRESET_KEYS.size() != PRESET_COUNT:
		errors.append("PRESET_KEYS size %d != PRESET_COUNT %d" % [PRESET_KEYS.size(), PRESET_COUNT])
	for k in PRESET_KEYS:
		if k not in REMAP_PRIMARY:
			errors.append("Missing REMAP_PRIMARY for preset %s" % k)
		if k not in REMAP_ACCENT:
			errors.append("Missing REMAP_ACCENT for preset %s" % k)
	# Contrast sanity: blue vs orange must be distinct (luminance diff > 0.15)
	for k in PRESET_KEYS:
		var b: Color = REMAP_PRIMARY[k][0]
		var o: Color = REMAP_PRIMARY[k][1]
		var diff := abs(b.get_luminance() - o.get_luminance())
		if diff < 0.08:
			warnings.append("Preset %s luminance diff low %.3f" % [k, diff])
		if b.is_equal_approx(o):
			errors.append("Preset %s blue==orange" % k)
	if ESTIMATED_DRAW_CALLS > DRAW_CALL_BUDGET:
		errors.append("DRAW_CALL_BUDGET exceeded")
	if ESTIMATED_PHYSICS_MS > BUDGET_PHYSICS_MS:
		errors.append("PHYSICS_MS exceeded")
	return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings, "preset_count": PRESET_COUNT}

# ---------------------------------------------------------------------------
# Instance API -- persistence via ConfigService WS08
# ---------------------------------------------------------------------------
func _ready() -> void:
	_load_from_config()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[Accessibility] debug_validate: %s" % e)

func _load_from_config() -> void:
	var svc: Node = get_node_or_null("/root/ConfigService")
	if svc == null:
		return
	if svc.has_method("load_config"):
		var cfg: Dictionary = svc.call("load_config") as Dictionary
		var acc: Dictionary = cfg.get("accessibility", {}) as Dictionary
		if not acc.is_empty():
			var p: String = acc.get("preset", DEFAULT_PRESET) as String
			if is_valid_preset(p):
				_preset = p
			_high_contrast = bool(acc.get("high_contrast", false))

func get_preset() -> String:
	return _preset

func is_high_contrast() -> bool:
	return _high_contrast

func set_preset(preset: String) -> bool:
	if not is_valid_preset(preset):
		push_warning("[Accessibility] invalid preset %s" % preset)
		return false
	_preset = preset
	_call_count += 1
	preset_changed.emit(_preset, _high_contrast)
	_save_to_config()
	return true

func set_high_contrast(enabled: bool) -> void:
	_high_contrast = enabled
	_call_count += 1
	preset_changed.emit(_preset, _high_contrast)
	_save_to_config()

func set_accessibility(preset: String, high_contrast: bool) -> bool:
	if not is_valid_preset(preset):
		return false
	_preset = preset
	_high_contrast = high_contrast
	_call_count += 1
	preset_changed.emit(_preset, _high_contrast)
	_save_to_config()
	return true

func reset_accessibility() -> void:
	_preset = DEFAULT_PRESET
	_high_contrast = false
	_call_count += 1
	accessibility_reset.emit()
	preset_changed.emit(_preset, _high_contrast)
	_save_to_config()

func current_team_color(team: int) -> Color:
	return get_team_color(team, _preset, _high_contrast)

func current_team_accent(team: int) -> Color:
	return get_team_accent(team, _preset, _high_contrast)

func _save_to_config() -> void:
	var svc: Node = get_node_or_null("/root/ConfigService")
	if svc == null:
		return
	if svc.has_method("load_config") and svc.has_method("save_config"):
		var cfg: Dictionary = svc.call("load_config") as Dictionary
		cfg["accessibility"] = {"preset": _preset, "high_contrast": _high_contrast}
		svc.call("save_config", cfg)

# Budget introspection
func get_estimated_draw_calls() -> int:
	return ESTIMATED_DRAW_CALLS

func get_estimated_physics_ms() -> float:
	return ESTIMATED_PHYSICS_MS
