# ConfigService — WS08 Settings (graphics, audio, controls)
# Persists to user://config.json (JSON + checksum, versioned).
# Godot 4.x autoload singleton.
extends Node

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
const CURRENT_VERSION: int = 2
const CONFIG_PATH: String = "user://config.json"
const BACKUP_PATH: String = "user://config.bak.json"
const TEMP_PATH: String = "user://config.tmp.json"

enum GraphicsQuality { LOW = 0, MEDIUM = 1, HIGH = 2, ULTRA = 3 }

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal setting_changed(section: String, key: String, value: Variant)
signal config_loaded(config: Dictionary)
signal config_saved(config: Dictionary)
signal config_error(reason: String)

# ---------------------------------------------------------------------------
# In-memory config
# ---------------------------------------------------------------------------
var _config: Dictionary = {}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
static func default_config() -> Dictionary:
	return {
		"version": CURRENT_VERSION,
		"graphics": {
			"quality": GraphicsQuality.MEDIUM,
			"quality_name": "medium",
			"vsync": true,
			"fps_limit": 60,
			"resolution_scale": 1.0,
			"shadows": true,
			"msaa": 1,
			"bloom": true,
			"motion_blur": false,
		},
		"audio": {
			"master_volume": 1.0,
			"music_volume": 0.8,
			"sfx_volume": 1.0,
			"crowd_volume": 0.9,
			"ui_volume": 0.9,
			"master_muted": false,
			"music_muted": false,
		},
		"controls": {
			"sensitivity": 1.0,
			"invert_y": false,
			"vibration": true,
			"deadzone_move": 0.12,
			"deadzone_look": 0.12,
			"ball_cam_toggle": true,
			"layout_preset": "default",
		},
		"general": {
			"language": "en",
			"show_fps": false,
			"safe_area_applied": true,
		}
	}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_config = load_config()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func load_config() -> Dictionary:
	if not FileAccess.file_exists(CONFIG_PATH):
		_config = default_config()
		_config = _strip_envelope(_config)
		config_loaded.emit(_config)
		return _config.duplicate(true)

	var txt := _read_text(CONFIG_PATH)
	if txt == "":
		push_warning("[ConfigService] config.json empty — using defaults")
		config_error.emit("empty_or_unreadable")
		_config = _defaults_payload()
		return _config.duplicate(true)

	var parsed: Variant = JSON.parse_string(txt)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[ConfigService] JSON parse failed — using defaults")
		var restored: Variant = _try_restore_backup("parse_failed")
		if restored != null:
			_config = restored as Dictionary
			return _config.duplicate(true)
		config_error.emit("parse_failed")
		_config = _defaults_payload()
		return _config.duplicate(true)

	var envelope: Dictionary = parsed as Dictionary
	var version: int
	var payload: Dictionary
	var stored_checksum: String = ""

	if envelope.has("payload") and envelope.has("version"):
		version = int(envelope.get("version", CURRENT_VERSION))
		payload = envelope.get("payload", {}) as Dictionary
		stored_checksum = str(envelope.get("checksum", ""))
		if stored_checksum != "":
			var computed := _compute_checksum(payload, version)
			if computed != stored_checksum:
				push_warning("[ConfigService] checksum mismatch — trying backup")
				var backup: Variant = _try_restore_backup("checksum_mismatch")
				if backup != null:
					_config = backup as Dictionary
					return _config.duplicate(true)
				config_error.emit("checksum_mismatch")
				_config = _defaults_payload()
				return _config.duplicate(true)
	else:
		version = int(envelope.get("version", 1))
		payload = envelope
		payload.erase("checksum")
		payload.erase("saved_at")

	if version < CURRENT_VERSION:
		payload = _migrate(payload, version)
		_config = payload
		save_config()
		config_loaded.emit(_config)
		return _config.duplicate(true)
	elif version > CURRENT_VERSION:
		push_warning("[ConfigService] config version %d newer than %d — loading compat" % [version, CURRENT_VERSION])
		config_error.emit("future_version")

	_config = _merge_with_defaults(payload)
	_apply_all()
	config_loaded.emit(_config)
	return _config.duplicate(true)

func save_config() -> bool:
	return save_config_dict(_config)

func save_config_dict(data: Dictionary) -> bool:
	var payload := _merge_with_defaults(data)
	payload["version"] = CURRENT_VERSION
	if payload.has("graphics") and payload["graphics"].has("quality"):
		payload["graphics"]["quality_name"] = _quality_to_name(int(payload["graphics"]["quality"]))

	var envelope := {
		"version": CURRENT_VERSION,
		"saved_at": int(Time.get_unix_time_from_system()),
		"payload": payload,
	}
	envelope["checksum"] = _compute_checksum(payload, CURRENT_VERSION)

	var text := JSON.stringify(envelope, "\t")
	if text == "":
		push_error("[ConfigService] JSON.stringify failed")
		config_error.emit("stringify_failed")
		return false

	var err := _write_atomic(text)
	if err != OK:
		push_error("[ConfigService] atomic write failed: %d" % err)
		config_error.emit("write_failed:%d" % err)
		return false

	_config = payload.duplicate(true)
	_apply_all()
	config_saved.emit(_config)
	return true

func get_setting(section: String, key: String, default: Variant = null) -> Variant:
	if not _config.has(section):
		return default
	var sec: Dictionary = _config[section] as Dictionary
	return sec.get(key, default)

func set_setting(section: String, key: String, value: Variant, persist: bool = true) -> bool:
	if not _config.has(section):
		push_warning("[ConfigService] unknown section: %s" % section)
		return false
	var sec: Dictionary = _config[section] as Dictionary
	if not sec.has(key):
		push_warning("[ConfigService] unknown key %s.%s — adding" % [section, key])

	var clamped: Variant = _validate_and_clamp(section, key, value)
	var old: Variant = sec.get(key, null)
	if old == clamped:
		return false
	sec[key] = clamped
	if section == "graphics" and key == "quality":
		sec["quality_name"] = _quality_to_name(int(clamped))
	_config[section] = sec
	setting_changed.emit(section, key, clamped)
	if persist:
		save_config()
		_apply(section, key, clamped)
	return true

func reset_to_defaults(persist: bool = true) -> Dictionary:
	_config = _defaults_payload()
	if persist:
		save_config()
	config_loaded.emit(_config)
	return _config.duplicate(true)

func reset_section(section: String, persist: bool = true) -> bool:
	var defaults := _defaults_payload()
	if not defaults.has(section):
		return false
	_config[section] = (defaults[section] as Dictionary).duplicate(true)
	if persist:
		save_config()
	for k in (_config[section] as Dictionary).keys():
		setting_changed.emit(section, k, _config[section][k])
	return true

func load_save() -> Dictionary:
	return load_config()

func save_game(data: Dictionary) -> bool:
	return save_config_dict(data)

# ---------------------------------------------------------------------------
# Apply helpers
# ---------------------------------------------------------------------------
func _apply_all() -> void:
	_apply_graphics()
	_apply_audio()
	_apply_controls()

func _apply(section: String, key: String, _value: Variant) -> void:
	match section:
		"graphics":
			_apply_graphics()
		"audio":
			_apply_audio()
		"controls":
			_apply_controls()
		_:
			pass

func _apply_graphics() -> void:
	if _config.is_empty():
		return
	var g: Dictionary = _config.get("graphics", {}) as Dictionary
	var vsync: bool = bool(g.get("vsync", true))
	if Engine.has_singleton("DisplayServer"):
		DisplayServer.window_set_vsync_mode(
			DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED
		)
	var fps_limit: int = int(g.get("fps_limit", 60))
	Engine.max_fps = fps_limit if fps_limit > 0 else 0
	var msaa: int = int(g.get("msaa", 1))
	var vp := get_viewport()
	if vp != null:
		match msaa:
			0: vp.msaa_3d = Viewport.MSAA_DISABLED
			1: vp.msaa_3d = Viewport.MSAA_2X
			2: vp.msaa_3d = Viewport.MSAA_4X
			_: vp.msaa_3d = Viewport.MSAA_2X

func _apply_audio() -> void:
	if _config.is_empty():
		return
	var a: Dictionary = _config.get("audio", {}) as Dictionary
	var volumes := {
		"Master": float(a.get("master_volume", 1.0)) if not bool(a.get("master_muted", false)) else 0.0,
		"Music": float(a.get("music_volume", 0.8)),
		"Crowd": float(a.get("crowd_volume", 0.9)),
		"SFX": float(a.get("sfx_volume", 1.0)),
		"UI": float(a.get("ui_volume", 0.9)),
	}
	for bus_name in volumes.keys():
		var idx := AudioServer.get_bus_index(bus_name)
		if idx == -1:
			continue
		var vol: float = float(volumes[bus_name])
		if bus_name == "Music" and bool(a.get("music_muted", false)):
			vol = 0.0
		var db: float = linear_to_db(clampf(vol, 0.0, 1.0)) if vol > 0.001 else -80.0
		AudioServer.set_bus_volume_db(idx, db)
		AudioServer.set_bus_mute(idx, vol <= 0.001 and (bus_name == "Master" or bus_name == "Music"))

func _apply_controls() -> void:
	pass

# ---------------------------------------------------------------------------
# Accessors
# ---------------------------------------------------------------------------
func get_graphics_quality() -> int:
	return int(get_setting("graphics", "quality", GraphicsQuality.MEDIUM))

func get_master_volume() -> float:
	return float(get_setting("audio", "master_volume", 1.0))

func get_sensitivity() -> float:
	return float(get_setting("controls", "sensitivity", 1.0))

# ---------------------------------------------------------------------------
# Validation / clamping
# ---------------------------------------------------------------------------
func _validate_and_clamp(section: String, key: String, value: Variant) -> Variant:
	match section:
		"graphics":
			match key:
				"quality":
					return clampi(int(value), 0, 3)
				"quality_name":
					return str(value)
				"vsync":
					return bool(value)
				"fps_limit":
					var v := int(value)
					if v != 0 and v not in [30, 60, 90, 120, 144]:
						var allowed: Array[int] = [0, 30, 60, 90, 120, 144]
						var best := allowed[0]
						var best_d := abs(v - best)
						for a in allowed:
							if abs(v - a) < best_d:
								best_d = abs(v - a)
								best = a
						return best
					return v
				"resolution_scale":
					return clampf(float(value), 0.5, 1.0)
				"shadows", "bloom", "motion_blur":
					return bool(value)
				"msaa":
					return clampi(int(value), 0, 2)
		"audio":
			match key:
				"master_volume", "music_volume", "sfx_volume", "crowd_volume", "ui_volume":
					return clampf(float(value), 0.0, 1.0)
				"master_muted", "music_muted":
					return bool(value)
		"controls":
			match key:
				"sensitivity":
					return clampf(float(value), 0.2, 3.0)
				"invert_y":
					return bool(value)
				"vibration":
					return bool(value)
				"deadzone_move", "deadzone_look":
					return clampf(float(value), 0.0, 0.5)
				"ball_cam_toggle":
					return bool(value)
				"layout_preset":
					var s := str(value)
					if s not in ["default", "left_handed", "claw"]:
						return "default"
					return s
		"general":
			match key:
				"language":
					return str(value)
				"show_fps", "safe_area_applied":
					return bool(value)
	return value

# ---------------------------------------------------------------------------
# Migration
# ---------------------------------------------------------------------------
func _migrate(payload: Dictionary, from_version: int) -> Dictionary:
	var p: Dictionary = payload.duplicate(true)
	var v := from_version
	if v < 1:
		v = 1
	if v == 1:
		if not p.has("general"):
			p["general"] = default_config()["general"]
		if p.has("graphics"):
			if not p["graphics"].has("bloom"):
				p["graphics"]["bloom"] = true
			if not p["graphics"].has("motion_blur"):
				p["graphics"]["motion_blur"] = false
			if not p["graphics"].has("msaa"):
				p["graphics"]["msaa"] = 1
			if not p["graphics"].has("quality_name"):
				p["graphics"]["quality_name"] = _quality_to_name(int(p["graphics"].get("quality", 1)))
		if p.has("audio"):
			if not p["audio"].has("crowd_volume"):
				p["audio"]["crowd_volume"] = 0.9
			if not p["audio"].has("ui_volume"):
				p["audio"]["ui_volume"] = 0.9
			if not p["audio"].has("music_muted"):
				p["audio"]["music_muted"] = false
		if p.has("controls"):
			if not p["controls"].has("layout_preset"):
				p["controls"]["layout_preset"] = "default"
			if not p["controls"].has("ball_cam_toggle"):
				p["controls"]["ball_cam_toggle"] = true
		p["version"] = 2
		v = 2
	return _merge_with_defaults(p)

func _merge_with_defaults(payload: Dictionary) -> Dictionary:
	var defaults := default_config()
	var out: Dictionary = defaults.duplicate(true)
	for section in payload.keys():
		if section in ["version", "checksum", "saved_at"]:
			continue
		if out.has(section) and typeof(out[section]) == TYPE_DICTIONARY and typeof(payload[section]) == TYPE_DICTIONARY:
			for k in (payload[section] as Dictionary).keys():
				out[section][k] = payload[section][k]
		else:
			out[section] = payload[section]
	out["version"] = CURRENT_VERSION
	return _strip_envelope(out)

func _defaults_payload() -> Dictionary:
	var d := default_config()
	return _strip_envelope(d)

func _strip_envelope(cfg: Dictionary) -> Dictionary:
	if cfg.has("payload"):
		return (cfg["payload"] as Dictionary).duplicate(true)
	var c := cfg.duplicate(true)
	c["version"] = CURRENT_VERSION
	return c

# ---------------------------------------------------------------------------
# Checksum / I/O
# ---------------------------------------------------------------------------
func _compute_checksum(payload: Dictionary, version: int) -> String:
	var canonical := JSON.stringify(payload)
	var to_hash := "%d:%s" % [version, canonical]
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		return str(to_hash.hash())
	ctx.update(to_hash.to_utf8_buffer())
	var digest: PackedByteArray = ctx.finish()
	var hex := ""
	for b in digest:
		hex += "%02x" % b
	return hex

func _read_text(path: String) -> String:
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return ""
	return fa.get_as_text()

func _write_atomic(text: String) -> int:
	var fa := FileAccess.open(TEMP_PATH, FileAccess.WRITE)
	if fa == null:
		return FileAccess.get_open_error()
	fa.store_string(text)
	fa.flush()
	fa = null
	if FileAccess.file_exists(CONFIG_PATH):
		var existing := _read_text(CONFIG_PATH)
		if existing != "":
			var bf := FileAccess.open(BACKUP_PATH, FileAccess.WRITE)
			if bf != null:
				bf.store_string(existing)
				bf.flush()
	var read_back := _read_text(TEMP_PATH)
	var out := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if out == null:
		return FileAccess.get_open_error()
	out.store_string(read_back)
	out.flush()
	out = null
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_PATH))
	return OK

func _try_restore_backup(reason: String) -> Variant:
	if not FileAccess.file_exists(BACKUP_PATH):
		return null
	var txt := _read_text(BACKUP_PATH)
	if txt == "":
		return null
	var parsed: Variant = JSON.parse_string(txt)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return null
	var env: Dictionary = parsed as Dictionary
	var payload: Dictionary
	var version: int
	var stored: String = ""
	if env.has("payload"):
		payload = env["payload"] as Dictionary
		version = int(env.get("version", CURRENT_VERSION))
		stored = str(env.get("checksum", ""))
		if stored != "":
			var computed := _compute_checksum(payload, version)
			if computed != stored:
				push_warning("[ConfigService] backup checksum failed (%s)" % reason)
				return null
	else:
		payload = env
		version = int(env.get("version", 1))
	if version < CURRENT_VERSION:
		payload = _migrate(payload, version)
	payload = _merge_with_defaults(payload)
	var _ok := save_config_dict(payload)
	if _ok:
		push_warning("[ConfigService] restored from backup after %s" % reason)
		return payload
	return null

func _quality_to_name(q: int) -> String:
	match q:
		0: return "low"
		1: return "medium"
		2: return "high"
		3: return "ultra"
		_: return "medium"

# ---------------------------------------------------------------------------
# Telemetry / test hooks (§11)
# ---------------------------------------------------------------------------
func debug_export() -> Dictionary:
	return {
		"path": CONFIG_PATH,
		"exists": FileAccess.file_exists(CONFIG_PATH),
		"version": CURRENT_VERSION,
		"config": _config.duplicate(true),
	}

func perf_mark() -> Dictionary:
	return {"has_config": FileAccess.file_exists(CONFIG_PATH)}
