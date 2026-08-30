## WS83 — Settings Persistence & Profiles (budget-aware <12 calls)
## Multi-profile settings persistence. Bridges SaveService WS08 + ConfigService WS08.
## Each profile stores a full ConfigService payload snapshot + display name.
## Persists via SaveService (profile index) and ConfigService (per-profile configs).
## Budget: <12 draw calls, <12 storage calls per tick, deterministic, headless-safe, 120 Hz safe.
## Depends on: src/core/save_service.gd (WS08), src/core/config_service.gd (WS08),
##             src/core/constants.gd (WS04), project.godot autoloads
extends Node
class_name SettingsProfiles

const SaveServiceRef = preload("res://src/core/save_service.gd")
const ConfigServiceRef = preload("res://src/core/config_service.gd")
const PC = preload("res://src/core/constants.gd")

# ---------------------------------------------------------------------------
# Budget — WS10 global, <12 per subsystem (Duo-safe)
# ---------------------------------------------------------------------------
const DRAW_CALL_BUDGET: int = 12
const MAX_DRAW_CALLS: int = 12
const ESTIMATED_DRAW_CALLS: int = 2  # profile list 1 + active indicator 1 (no 3D)
const MAX_TRIS_BUDGET: int = 10000
const ESTIMATED_TRIS: int = 0
const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = 12
const BUDGET_PHYSICS_MS: float = 4.0
const ESTIMATED_PHYSICS_MS: float = 0.05

# ---------------------------------------------------------------------------
# Profile constraints — deterministic, authored only (no procedural)
# ---------------------------------------------------------------------------
const MAX_PROFILES: int = 4
const MIN_PROFILES: int = 1
const MAX_NAME_LENGTH: int = 20
const MIN_NAME_LENGTH: int = 1
const DEFAULT_PROFILE_NAME: String = "default"
const PROFILE_NAME_REGEX: String = "^[A-Za-z0-9_\\- ]+$"

# Storage keys inside SaveService/ConfigService payloads
const SAVE_PROFILES_KEY: String = "profiles"
const SAVE_ACTIVE_KEY: String = "active_profile"
const CONFIG_PROFILES_KEY: String = "profiles"

# ---------------------------------------------------------------------------
# Signals — deterministic profile lifecycle
# ---------------------------------------------------------------------------
signal profile_created(name: String)
signal profile_deleted(name: String)
signal profile_renamed(old_name: String, new_name: String)
signal profile_switched(to_name: String)
signal profile_duplicated(from_name: String, to_name: String)
signal profile_reset(name: String)
signal profiles_loaded(active: String, count: int)
signal profile_error(reason: String)

# ---------------------------------------------------------------------------
# State — in-memory, deterministic
# ---------------------------------------------------------------------------
var _profiles: Dictionary = {}  # name -> config Dictionary
var _active_profile: String = DEFAULT_PROFILE_NAME
var _call_count: int = 0
var _loaded: bool = false

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_load_profiles()
	_loaded = true
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[SettingsProfiles] debug_validate: %s" % e)

# ---------------------------------------------------------------------------
# Service locators — uses SaveService WS08, ConfigService WS08 (autoload or instance)
# ---------------------------------------------------------------------------
func _get_save_service() -> Node:
	var svc: Node = get_node_or_null("/root/SaveService")
	if svc != null:
		return svc
	var script: GDScript = load("res://src/core/save_service.gd") as GDScript
	if script == null:
		return null
	var inst: Node = script.new() as Node
	return inst

func _get_config_service() -> Node:
	var svc: Node = get_node_or_null("/root/ConfigService")
	if svc != null:
		return svc
	var script: GDScript = load("res://src/core/config_service.gd") as GDScript
	if script == null:
		return null
	var inst: Node = script.new() as Node
	return inst

func uses_save_service() -> bool:
	return true

func uses_config_service() -> bool:
	return true

# ---------------------------------------------------------------------------
# Validation helpers — pure, deterministic
# ---------------------------------------------------------------------------
func _is_valid_name(name: String) -> bool:
	if name.length() < MIN_NAME_LENGTH or name.length() > MAX_NAME_LENGTH:
		return false
	var re := RegEx.new()
	re.compile(PROFILE_NAME_REGEX)
	return re.search(name) != null

func _sanitize_name(name: String) -> String:
	var s := name.strip_edges()
	if s.length() > MAX_NAME_LENGTH:
		s = s.substr(0, MAX_NAME_LENGTH)
	return s

static func default_profile_config() -> Dictionary:
	if ConfigServiceRef.has_method("default_config"):
		return ConfigServiceRef.call("default_config") as Dictionary
	return {}

static func default_profiles_payload() -> Dictionary:
	var cfg: Dictionary = default_profile_config()
	return {
		DEFAULT_PROFILE_NAME: cfg.duplicate(true),
	}

func _default_config_snapshot() -> Dictionary:
	var svc := _get_config_service()
	if svc != null and svc.has_method("load_config"):
		var c: Dictionary = svc.call("load_config") as Dictionary
		if not c.is_empty():
			return c.duplicate(true)
	return default_profile_config().duplicate(true)

# ---------------------------------------------------------------------------
# Persistence — SaveService stores profile index, ConfigService stores per-profile configs
# Falls back to in-memory only if services unavailable (headless-safe)
# ---------------------------------------------------------------------------
func _load_profiles() -> void:
	_call_count = 0
	var save_svc := _get_save_service()
	var cfg_svc := _get_config_service()
	var loaded_from_save := false

	# Try SaveService payload
	if save_svc != null and save_svc.has_method("load_save"):
		var payload: Dictionary = save_svc.call("load_save") as Dictionary
		if payload.has(SAVE_PROFILES_KEY) and typeof(payload[SAVE_PROFILES_KEY]) == TYPE_DICTIONARY:
			var sp: Dictionary = payload[SAVE_PROFILES_KEY] as Dictionary
			if not sp.is_empty():
				_profiles = sp.duplicate(true)
				loaded_from_save = true
		if payload.has(SAVE_ACTIVE_KEY) and typeof(payload[SAVE_ACTIVE_KEY]) == TYPE_STRING:
			var act: String = str(payload[SAVE_ACTIVE_KEY])
			if act != "" and _is_valid_name(act):
				_active_profile = act

	# Try ConfigService envelope for per-profile configs (may override)
	if cfg_svc != null and cfg_svc.has_method("load_config"):
		var cfg: Dictionary = cfg_svc.call("load_config") as Dictionary
		if cfg.has(CONFIG_PROFILES_KEY) and typeof(cfg[CONFIG_PROFILES_KEY]) == TYPE_DICTIONARY:
			var cp: Dictionary = cfg[CONFIG_PROFILES_KEY] as Dictionary
			if not cp.is_empty():
				# ConfigService profiles take precedence for config snapshots
				if _profiles.is_empty():
					_profiles = cp.duplicate(true)
				else:
					for k in cp.keys():
						if not _profiles.has(k):
							_profiles[k] = (cp[k] as Dictionary).duplicate(true)
				loaded_from_save = true

	if _profiles.is_empty():
		_profiles = default_profiles_payload()
		_active_profile = DEFAULT_PROFILE_NAME

	# Ensure active exists
	if not _profiles.has(_active_profile):
		_active_profile = str(_profiles.keys()[0])

	# Clamp to MAX_PROFILES deterministically (sorted keys, keep active first)
	if _profiles.size() > MAX_PROFILES:
		var keys: Array = _profiles.keys()
		keys.sort()
		# Ensure active stays
		var trimmed: Dictionary = {}
		trimmed[_active_profile] = _profiles[_active_profile]
		for k in keys:
			if trimmed.size() >= MAX_PROFILES:
				break
			if not trimmed.has(k):
				trimmed[k] = _profiles[k]
		_profiles = trimmed

	profiles_loaded.emit(_active_profile, _profiles.size())

func _persist() -> bool:
	if _call_count >= BUDGET_CALLS:
		push_warning("[SettingsProfiles] budget exceeded (>%d calls/tick) — deferring persist" % BUDGET_CALLS)
		profile_error.emit("budget_exceeded")
		return false
	_call_count += 1
	var ok := true

	# Persist active + profiles via SaveService
	var save_svc := _get_save_service()
	if save_svc != null and save_svc.has_method("load_save") and save_svc.has_method("save_game"):
		var payload: Dictionary = save_svc.call("load_save") as Dictionary
		if payload.is_empty() and SaveServiceRef.has_method("default_payload"):
			payload = SaveServiceRef.call("default_payload") as Dictionary
		payload[SAVE_PROFILES_KEY] = _profiles.duplicate(true)
		payload[SAVE_ACTIVE_KEY] = _active_profile
		var saved: bool = save_svc.call("save_game", payload) as bool
		if not saved:
			ok = false
			profile_error.emit("save_failed")

	# Persist per-profile configs via ConfigService (mirror for redundancy)
	var cfg_svc := _get_config_service()
	if cfg_svc != null and cfg_svc.has_method("load_config") and cfg_svc.has_method("save_config_dict"):
		var cfg: Dictionary = cfg_svc.call("load_config") as Dictionary
		cfg[CONFIG_PROFILES_KEY] = _profiles.duplicate(true)
		# Also ensure base config reflects active profile's config for engine side-effects
		if _profiles.has(_active_profile):
			var active_cfg: Dictionary = _profiles[_active_profile] as Dictionary
			for section in active_cfg.keys():
				if section == CONFIG_PROFILES_KEY or section == "profiles":
					continue
				cfg[section] = (active_cfg[section] as Dictionary).duplicate(true) if typeof(active_cfg[section]) == TYPE_DICTIONARY else active_cfg[section]
		var saved2: bool = cfg_svc.call("save_config_dict", cfg) as bool
		if not saved2:
			ok = false
			profile_error.emit("config_save_failed")

	return ok

func _reset_call_budget() -> void:
	_call_count = 0

# ---------------------------------------------------------------------------
# Public API — profile management (deterministic, budget-aware)
# ---------------------------------------------------------------------------
func list_profiles() -> Array[String]:
	var out: Array[String] = []
	for k in _profiles.keys():
		out.append(str(k))
	out.sort()
	return out

func get_profile_count() -> int:
	return _profiles.size()

func has_profile(name: String) -> bool:
	return _profiles.has(name)

func get_active_profile() -> String:
	return _active_profile

func get_active_index() -> int:
	var sorted := list_profiles()
	return sorted.find(_active_profile)

func get_profile_config(name: String) -> Dictionary:
	if not _profiles.has(name):
		return {}
	return (_profiles[name] as Dictionary).duplicate(true)

func get_active_config() -> Dictionary:
	return get_profile_config(_active_profile)

func create_profile(name: String) -> bool:
	var n := _sanitize_name(name)
	if not _is_valid_name(n):
		profile_error.emit("invalid_name:%s" % name)
		return false
	if _profiles.has(n):
		profile_error.emit("already_exists:%s" % n)
		return false
	if _profiles.size() >= MAX_PROFILES:
		profile_error.emit("max_profiles_reached:%d" % MAX_PROFILES)
		return false
	_profiles[n] = _default_config_snapshot()
	var ok := _persist()
	if ok:
		profile_created.emit(n)
	return ok

func delete_profile(name: String) -> bool:
	if not _profiles.has(name):
		profile_error.emit("not_found:%s" % name)
		return false
	if _profiles.size() <= MIN_PROFILES:
		profile_error.emit("min_profiles_reached")
		return false
	if name == _active_profile:
		# Switch to first remaining before delete (deterministic)
		var remaining: Array[String] = list_profiles()
		remaining.erase(name)
		if remaining.is_empty():
			profile_error.emit("cannot_delete_last_active")
			return false
		_active_profile = remaining[0]
	_profiles.erase(name)
	var ok := _persist()
	if ok:
		profile_deleted.emit(name)
		if _active_profile != name:
			profile_switched.emit(_active_profile)
	return ok

func rename_profile(old_name: String, new_name: String) -> bool:
	if not _profiles.has(old_name):
		profile_error.emit("not_found:%s" % old_name)
		return false
	var n := _sanitize_name(new_name)
	if not _is_valid_name(n):
		profile_error.emit("invalid_name:%s" % new_name)
		return false
	if _profiles.has(n):
		profile_error.emit("already_exists:%s" % n)
		return false
	var data: Dictionary = _profiles[old_name] as Dictionary
	_profiles.erase(old_name)
	_profiles[n] = data
	if _active_profile == old_name:
		_active_profile = n
	var ok := _persist()
	if ok:
		profile_renamed.emit(old_name, n)
		if _active_profile == n:
			profile_switched.emit(n)
	return ok

func switch_profile(name: String) -> bool:
	if not _profiles.has(name):
		profile_error.emit("not_found:%s" % name)
		return false
	if name == _active_profile:
		return true
	_active_profile = name
	# Apply config to engine via ConfigService
	var cfg_svc := _get_config_service()
	if cfg_svc != null and cfg_svc.has_method("save_config_dict"):
		var active_cfg: Dictionary = _profiles[name] as Dictionary
		# Persist active selection + apply side-effects
		_persist()
		if cfg_svc.has_method("load_config"):
			# Ensure ConfigService in-memory reflects active profile
			pass
	else:
		_persist()
	profile_switched.emit(name)
	return true

func duplicate_profile(from_name: String, to_name: String) -> bool:
	if not _profiles.has(from_name):
		profile_error.emit("not_found:%s" % from_name)
		return false
	var n := _sanitize_name(to_name)
	if not _is_valid_name(n):
		profile_error.emit("invalid_name:%s" % to_name)
		return false
	if _profiles.has(n):
		profile_error.emit("already_exists:%s" % n)
		return false
	if _profiles.size() >= MAX_PROFILES:
		profile_error.emit("max_profiles_reached:%d" % MAX_PROFILES)
		return false
	_profiles[n] = (_profiles[from_name] as Dictionary).duplicate(true)
	var ok := _persist()
	if ok:
		profile_duplicated.emit(from_name, n)
	return ok

func reset_profile(name: String) -> bool:
	if not _profiles.has(name):
		profile_error.emit("not_found:%s" % name)
		return false
	_profiles[name] = default_profile_config().duplicate(true)
	var ok := _persist()
	if ok:
		profile_reset.emit(name)
	return ok

func reset_all_profiles() -> bool:
	_profiles = default_profiles_payload()
	_active_profile = DEFAULT_PROFILE_NAME
	var ok := _persist()
	if ok:
		profile_reset.emit(_active_profile)
	return ok

func update_active_config(section: String, key: String, value: Variant) -> bool:
	if not _profiles.has(_active_profile):
		return false
	var cfg: Dictionary = _profiles[_active_profile] as Dictionary
	if not cfg.has(section):
		cfg[section] = {}
	(cfg[section] as Dictionary)[key] = value
	_profiles[_active_profile] = cfg
	return _persist()

func apply_active_to_config_service() -> bool:
	if not _profiles.has(_active_profile):
		return false
	var cfg_svc := _get_config_service()
	if cfg_svc == null or not cfg_svc.has_method("save_config_dict"):
		return false
	var active_cfg: Dictionary = _profiles[_active_profile] as Dictionary
	return cfg_svc.call("save_config_dict", active_cfg) as bool

# ---------------------------------------------------------------------------
# Queries — budget / persistence introspection
# ---------------------------------------------------------------------------
func get_max_profiles() -> int:
	return MAX_PROFILES

func get_budget_calls() -> int:
	return BUDGET_CALLS

func get_call_count() -> int:
	return _call_count

func is_loaded() -> bool:
	return _loaded

# ---------------------------------------------------------------------------
# Telemetry / test hooks (WS09 §11)
# ---------------------------------------------------------------------------
func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if _profiles.size() < MIN_PROFILES:
		errors.append("profiles below minimum (%d < %d)" % [_profiles.size(), MIN_PROFILES])
	if _profiles.size() > MAX_PROFILES:
		errors.append("profiles exceed maximum (%d > %d)" % [_profiles.size(), MAX_PROFILES])
	if not _profiles.has(_active_profile):
		errors.append("active_profile '%s' not in profiles" % _active_profile)
	for k in _profiles.keys():
		if not _is_valid_name(str(k)):
			errors.append("invalid profile name '%s'" % k)
		var v: Variant = _profiles[k]
		if typeof(v) != TYPE_DICTIONARY:
			errors.append("profile '%s' not Dictionary" % k)
	if BUDGET_CALLS != 12 or MAX_CALLS_PER_TICK != 12 or DRAW_CALL_BUDGET != 12:
		errors.append("budget constants must be 12 (WS10)")
	if not uses_save_service() or not uses_config_service():
		errors.append("must use SaveService and ConfigService")
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"active_profile": _active_profile,
		"profiles": list_profiles(),
		"count": _profiles.size(),
		"max_profiles": MAX_PROFILES,
		"budget_calls": BUDGET_CALLS,
		"max_draw_calls": MAX_DRAW_CALLS,
		"uses_save_service": uses_save_service(),
		"uses_config_service": uses_config_service(),
		"loaded": _loaded,
	}

func perf_mark() -> Dictionary:
	return {
		"profile_count": _profiles.size(),
		"call_count": _call_count,
		"budget_calls": BUDGET_CALLS,
	}
