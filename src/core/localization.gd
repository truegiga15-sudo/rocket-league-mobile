## WS84 — Localization Foundation (budget-aware <12 calls)
## CSV-backed translations for en, es, fr. Keys cover menu/hud/settings.
## Deterministic, headless-safe, 120 Hz safe. Single CSV at res://assets/localization.csv
## Budget: <12 draw/logic calls per tick, Duo-safe, no per-frame alloc.
## Depends on: ConfigService WS08 (general.language), SaveService WS08 optional.
extends Node
class_name LocalizationService

const PC = preload("res://src/core/constants.gd")

# ---------------------------------------------------------------------------
# Budget — WS10 global, <12 per subsystem (Duo-safe)
# ---------------------------------------------------------------------------
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const ESTIMATED_DRAW_CALLS: int = 1  # label text swaps, no extra draw
const MAX_TRIS_BUDGET: int = 0
const ESTIMATED_TRIS: int = 0
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = 12
const BUDGET_PHYSICS_MS: float = 4.0
const ESTIMATED_PHYSICS_MS: float = 0.05

# ---------------------------------------------------------------------------
# Locale config — authored only, deterministic
# ---------------------------------------------------------------------------
const SUPPORTED_LOCALES: Array[String] = ["en", "es", "fr"]
const DEFAULT_LOCALE: String = "en"
const CSV_PATH: String = "res://assets/localization.csv"
const FALLBACK_LOCALE: String = "en"

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal locale_changed(to_locale: String)
signal translations_loaded(count: int, locale: String)
signal localization_error(reason: String)

# ---------------------------------------------------------------------------
# State — in-memory deterministic table: key -> { en: str, es: str, fr: str }
# ---------------------------------------------------------------------------
var _translations: Dictionary = {}  # String -> Dictionary locale->String
var _current_locale: String = DEFAULT_LOCALE
var _loaded: bool = false
var _call_count: int = 0

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_load_translations(CSV_PATH)
	_sync_from_config_service()
	_loaded = true
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[Localization] debug_validate: %s" % e)

# ---------------------------------------------------------------------------
# Public API — locale
# ---------------------------------------------------------------------------
func get_supported_locales() -> Array[String]:
	return SUPPORTED_LOCALES.duplicate()

func is_supported_locale(locale: String) -> bool:
	return locale in SUPPORTED_LOCALES

func get_locale() -> String:
	return _current_locale

func set_locale(locale: String) -> bool:
	var loc := locale.strip_edges().to_lower()
	if not is_supported_locale(loc):
		localization_error.emit("unsupported_locale:%s" % locale)
		push_warning("[Localization] unsupported locale: %s" % locale)
		return false
	if loc == _current_locale:
		return true
	_current_locale = loc
	_call_count += 1
	locale_changed.emit(_current_locale)
	_persist_to_config_service(_current_locale)
	return true

# ---------------------------------------------------------------------------
# Public API — translation
# ---------------------------------------------------------------------------
## Translate key for current locale (or override). Falls back to en, then key.
func t(key: String, locale_override: String = "") -> String:
	_call_count += 1
	var loc := _current_locale
	if locale_override != "":
		loc = locale_override.strip_edges().to_lower()
		if not is_supported_locale(loc):
			loc = FALLBACK_LOCALE
	if _translations.has(key):
		var entry: Dictionary = _translations[key] as Dictionary
		if entry.has(loc) and str(entry[loc]).strip_edges() != "":
			return str(entry[loc])
		if entry.has(FALLBACK_LOCALE) and str(entry[FALLBACK_LOCALE]).strip_edges() != "":
			return str(entry[FALLBACK_LOCALE])
	return key

## Alias for t() — GDScript Object.tr compatibility shim
func translate(key: String, locale_override: String = "") -> String:
	return t(key, locale_override)

func has_key(key: String) -> bool:
	return _translations.has(key)

func key_count() -> int:
	return _translations.size()

func get_all_keys() -> Array[String]:
	var keys: Array[String] = []
	for k in _translations.keys():
		keys.append(str(k))
	keys.sort()
	return keys

# ---------------------------------------------------------------------------
# CSV loading — deterministic, headless-safe
# ---------------------------------------------------------------------------
func _load_translations(path: String = CSV_PATH) -> int:
	_translations.clear()
	if not FileAccess.file_exists(path):
		push_warning("[Localization] CSV not found: %s" % path)
		localization_error.emit("csv_missing:%s" % path)
		return 0
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		push_warning("[Localization] cannot open CSV: %s err=%d" % [path, FileAccess.get_open_error()])
		localization_error.emit("csv_open_failed:%s" % path)
		return 0
	var text := fa.get_as_text()
	fa.close()
	return load_from_string(text)

## Parse CSV string directly — testable, no FS needed. Returns entry count.
func load_from_string(csv_text: String) -> int:
	_translations.clear()
	var lines := csv_text.split("\n")
	if lines.size() == 0:
		return 0
	# header
	var header := _parse_csv_line(lines[0].strip_edges())
	if header.size() < 4 or header[0].to_lower() != "key":
		push_warning("[Localization] invalid header: %s" % lines[0])
		localization_error.emit("csv_bad_header")
		return 0
	var locale_cols: Array[String] = []
	for i in range(1, header.size()):
		var h := header[i].strip_edges().to_lower()
		if h in SUPPORTED_LOCALES:
			locale_cols.append(h)
	if locale_cols.size() == 0:
		push_warning("[Localization] no supported locale columns found")
		localization_error.emit("csv_no_locale_cols")
		return 0
	var count := 0
	for li in range(1, lines.size()):
		var raw := lines[li].strip_edges()
		if raw == "" or raw.begins_with("#"):
			continue
		var cols := _parse_csv_line(raw)
		if cols.size() == 0:
			continue
		var key := cols[0].strip_edges()
		if key == "":
			continue
		var entry: Dictionary = {}
		for ci in range(locale_cols.size()):
			var csv_idx := ci + 1
			var val := ""
			if csv_idx < cols.size():
				val = cols[csv_idx].strip_edges()
			entry[locale_cols[ci]] = val
		# ensure all supported locales present (empty -> fallback at t())
		for loc in SUPPORTED_LOCALES:
			if not entry.has(loc):
				entry[loc] = ""
		_translations[key] = entry
		count += 1
	translations_loaded.emit(count, _current_locale)
	return count

# Minimal CSV parser handling quoted fields with commas and escaped quotes
func _parse_csv_line(line: String) -> Array[String]:
	var out: Array[String] = []
	var cur := ""
	var in_quotes := false
	var i := 0
	while i < line.length():
		var c := line[i]
		if in_quotes:
			if c == "\"":
				if i + 1 < line.length() and line[i + 1] == "\"":
					cur += "\""
					i += 1
				else:
					in_quotes = false
			else:
				cur += c
		else:
			if c == "\"":
				in_quotes = true
			elif c == ",":
				out.append(cur)
				cur = ""
			else:
				cur += c
		i += 1
	out.append(cur)
	return out

# ---------------------------------------------------------------------------
# ConfigService bridge — optional, headless-safe
# ---------------------------------------------------------------------------
func _sync_from_config_service() -> void:
	var svc := _get_config_service()
	if svc == null:
		return
	if svc.has_method("load_config") or " _config" in svc:
		var cfg: Dictionary = {}
		if svc.has_method("get_config"):
			cfg = svc.call("get_config") as Dictionary
		elif svc.has_method("load_config"):
			cfg = svc.call("load_config") as Dictionary
		else:
			return
		var general: Dictionary = cfg.get("general", {}) as Dictionary
		var lang: String = str(general.get("language", DEFAULT_LOCALE)).to_lower().strip_edges()
		if is_supported_locale(lang):
			_current_locale = lang

func _persist_to_config_service(locale: String) -> void:
	var svc := _get_config_service()
	if svc == null:
		return
	if svc.has_method("set_value"):
		svc.call("set_value", "general", "language", locale)
	elif svc.has_method("set_setting"):
		svc.call("set_setting", "general", "language", locale)

func _get_config_service() -> Node:
	var svc: Node = get_node_or_null("/root/ConfigService")
	if svc != null:
		return svc
	# fallback instance for headless/tests
	if not FileAccess.file_exists("res://src/core/config_service.gd"):
		return null
	var script: GDScript = load("res://src/core/config_service.gd") as GDScript
	if script == null:
		return null
	return null  # don't instantiate autoload duplicate; just sync when available

# ---------------------------------------------------------------------------
# Validation — pure, deterministic, budget-aware
# ---------------------------------------------------------------------------
func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	if _translations.is_empty():
		# try load once for validation
		if FileAccess.file_exists(CSV_PATH):
			_load_translations(CSV_PATH)
		if _translations.is_empty():
			errors.append("no translations loaded from %s" % CSV_PATH)
		else:
			warnings.append("translations lazy-loaded during validate")
	if not is_supported_locale(_current_locale):
		errors.append("current locale %s not in SUPPORTED_LOCALES" % _current_locale)
	if SUPPORTED_LOCALES.size() != 3:
		errors.append("SUPPORTED_LOCALES must be [en,es,fr] got %s" % str(SUPPORTED_LOCALES))
	for k in _translations.keys():
		var entry: Dictionary = _translations[k] as Dictionary
		for loc in SUPPORTED_LOCALES:
			if not entry.has(loc):
				errors.append("key %s missing locale %s" % [k, loc])
			elif str(entry[loc]).strip_edges() == "":
				warnings.append("key %s empty for %s (will fallback to en)" % [k, loc])
		if str(k).strip_edges() == "":
			errors.append("empty key found")
	if MAX_CALLS_PER_TICK != 12 or BUDGET_CALLS != 12:
		errors.append("budget violated: MAX_CALLS_PER_TICK/BUDGET_CALLS must be 12")
	if ESTIMATED_DRAW_CALLS > MAX_DRAW_CALLS:
		errors.append("ESTIMATED_DRAW_CALLS %d > MAX" % ESTIMATED_DRAW_CALLS)
	return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings, "key_count": _translations.size(), "locale": _current_locale, "supported": SUPPORTED_LOCALES.duplicate()}

static func static_validate(csv_text: String) -> Dictionary:
	var inst := LocalizationService.new()
	var n := inst.load_from_string(csv_text)
	var v := inst.debug_validate()
	v["loaded"] = n
	inst.free()
	return v
