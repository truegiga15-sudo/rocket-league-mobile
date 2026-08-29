# SaveService — WS08 Save/Config Interfaces
# Versioned JSON + checksum persistence at user://save.json
# Godot 4.x autoload singleton. Depends on WS02 (Project Structure).
# Conventions: docs/architecture/00-conventions.md §10, docs/architecture/save-schema.md
extends Node

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Current save format version. Bump on breaking schema change.
const CURRENT_VERSION: int = 3

## Primary save path (§10: user://save.json)
const SAVE_PATH: String = "user://save.json"

## Backup path for atomic write / recovery
const BACKUP_PATH: String = "user://save.bak.json"

## Temporary path used during atomic save
const TEMP_PATH: String = "user://save.tmp.json"

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal save_loaded(data: Dictionary)
signal save_saved(data: Dictionary)
signal save_error(reason: String)
signal save_migrated(from_version: int, to_version: int)

# ---------------------------------------------------------------------------
# Default save payload factory
# ---------------------------------------------------------------------------
static func default_payload() -> Dictionary:
	return {
		"player": {
			"display_name": "",
			"created_at": 0,
			"last_played_at": 0,
			"xp": 0,
			"level": 1,
			"matches_played": 0,
			"wins": 0,
		},
		"career": {
			"season": 1,
			"division": "unranked",
			"mmr": 0,
		},
		"garage": {
			"equipped_car": "octane",
			"equipped_decal": "none",
			"equipped_wheels": "default",
			"owned_cars": ["octane"],
			"owned_decals": ["none"],
			"owned_wheels": ["default"],
		},
		"progress": {
			"tutorial_completed": false,
			"tutorial_step": 0,
			"training_completed": [],
			"achievements": {},
		},
		"stats": {
			"goals": 0,
			"saves": 0,
			"assists": 0,
			"shots": 0,
			"playtime_seconds": 0,
		},
		"meta": {
			"save_format": CURRENT_VERSION,
		}
	}

static func _default_envelope() -> Dictionary:
	return {
		"version": CURRENT_VERSION,
		"checksum": "",
		"saved_at": 0,
		"payload": default_payload(),
	}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	pass

# ---------------------------------------------------------------------------
# Public API — required by WS08 spec
# ---------------------------------------------------------------------------

## Load save from SAVE_PATH. Validates checksum, migrates if needed.
## Returns payload Dictionary (never null). On missing/corrupt returns defaults
## and emits save_error. Migrated data is re-saved automatically.
func load_save() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		var def := default_payload()
		save_loaded.emit(def)
		return def

	var raw_text := _read_text(SAVE_PATH)
	if raw_text == "":
		push_warning("[SaveService] save.json empty or unreadable — returning defaults")
		save_error.emit("empty_or_unreadable")
		return default_payload()

	var parsed: Variant = JSON.parse_string(raw_text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[SaveService] JSON parse failed — returning defaults")
		_try_restore_backup("parse_failed")
		save_error.emit("parse_failed")
		return default_payload()

	var envelope: Dictionary = parsed as Dictionary

	if not envelope.has("version") or not envelope.has("payload"):
		push_warning("[SaveService] missing version/payload — returning defaults")
		save_error.emit("missing_fields")
		return default_payload()

	var version: int = int(envelope.get("version", 0))
	var payload: Dictionary = envelope.get("payload", {}) as Dictionary
	var stored_checksum: String = str(envelope.get("checksum", ""))
	var saved_at: int = int(envelope.get("saved_at", 0))
	_ = saved_at

	if stored_checksum != "":
		var computed := _compute_checksum(payload, version)
		if computed != stored_checksum:
			push_warning("[SaveService] checksum mismatch (stored=%s computed=%s) — attempting backup" % [stored_checksum, computed])
			var backup_payload: Variant = _try_restore_backup("checksum_mismatch")
			if backup_payload != null:
				return backup_payload as Dictionary
			save_error.emit("checksum_mismatch")
			return default_payload()

	if version < CURRENT_VERSION:
		var migrated := migrate(payload, version)
		var ok := save_game(migrated)
		if ok:
			save_migrated.emit(version, CURRENT_VERSION)
		return migrated
	elif version > CURRENT_VERSION:
		push_warning("[SaveService] save version %d newer than current %d — attempting forward-compat load" % [version, CURRENT_VERSION])
		save_error.emit("future_version")
		return payload

	save_loaded.emit(payload)
	return payload

## Persist payload Dictionary to SAVE_PATH with version + checksum.
## Returns true on success, false on failure (emits save_error).
func save_game(data: Dictionary) -> bool:
	var payload: Dictionary = data.duplicate(true)
	if payload.has("meta"):
		payload["meta"]["save_format"] = CURRENT_VERSION
	else:
		payload["meta"] = {"save_format": CURRENT_VERSION}

	var envelope := {
		"version": CURRENT_VERSION,
		"payload": payload,
		"saved_at": int(Time.get_unix_time_from_system()),
	}
	envelope["checksum"] = _compute_checksum(payload, CURRENT_VERSION)

	var json_text := JSON.stringify(envelope, "\t")
	if json_text == "":
		push_error("[SaveService] JSON.stringify failed")
		save_error.emit("stringify_failed")
		return false

	var err := _write_text_atomic(json_text)
	if err != OK:
		push_error("[SaveService] atomic write failed: %d" % err)
		save_error.emit("write_failed:%d" % err)
		return false

	save_saved.emit(payload)
	return true

## Migrate payload from from_version to CURRENT_VERSION.
## Pure function — does not touch disk except via caller.
func migrate(data: Dictionary, from_version: int) -> Dictionary:
	var payload: Dictionary = data.duplicate(true)
	var v := from_version

	if v < 1:
		v = 1

	if v == 1:
		if not payload.has("garage"):
			payload["garage"] = default_payload()["garage"]
		else:
			if not payload["garage"].has("owned_cars"):
				payload["garage"]["owned_cars"] = ["octane"]
			if not payload["garage"].has("owned_decals"):
				payload["garage"]["owned_decals"] = ["none"]
			if not payload["garage"].has("owned_wheels"):
				payload["garage"]["owned_wheels"] = ["default"]
		if not payload.has("progress"):
			payload["progress"] = default_payload()["progress"]
		elif not payload["progress"].has("achievements"):
			payload["progress"]["achievements"] = {}
		if not payload.has("stats"):
			payload["stats"] = default_payload()["stats"]
		elif not payload["stats"].has("playtime_seconds"):
			payload["stats"]["playtime_seconds"] = 0
		if not payload.has("career"):
			payload["career"] = default_payload()["career"]
		elif not payload["career"].has("division"):
			payload["career"]["division"] = "unranked"
		if payload.has("meta"):
			payload["meta"]["save_format"] = 2
		v = 2

	if v == 2:
		if not payload.has("player"):
			payload["player"] = default_payload()["player"]
		else:
			if not payload["player"].has("last_played_at"):
				payload["player"]["last_played_at"] = 0
			if not payload["player"].has("level"):
				payload["player"]["level"] = 1
			if not payload["player"].has("matches_played"):
				payload["player"]["matches_played"] = 0
		if payload.has("progress") and not payload["progress"].has("training_completed"):
			payload["progress"]["training_completed"] = []
		if payload.has("stats"):
			if not payload["stats"].has("assists"):
				payload["stats"]["assists"] = 0
			if not payload["stats"].has("shots"):
				payload["stats"]["shots"] = 0
		if payload.has("meta"):
			payload["meta"]["save_format"] = 3
		v = 3

	if payload.has("meta"):
		payload["meta"]["save_format"] = CURRENT_VERSION
	else:
		payload["meta"] = {"save_format": CURRENT_VERSION}

	return payload

# ---------------------------------------------------------------------------
# Convenience helpers
# ---------------------------------------------------------------------------

func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)

func delete_save() -> bool:
	var ok := true
	if FileAccess.file_exists(SAVE_PATH):
		var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
		if err != OK:
			var fa := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
			if fa != null:
				fa.store_string("")
			else:
				ok = false
	if FileAccess.file_exists(BACKUP_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(BACKUP_PATH))
	if FileAccess.file_exists(TEMP_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_PATH))
	return ok

func validate_payload(payload: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	if not payload.has("player"):
		errors.append("missing player")
	if not payload.has("garage"):
		errors.append("missing garage")
	if not payload.has("progress"):
		errors.append("missing progress")
	if not payload.has("stats"):
		errors.append("missing stats")
	return {"ok": errors.is_empty(), "errors": errors}

# ---------------------------------------------------------------------------
# Telemetry / test hooks (§11)
# ---------------------------------------------------------------------------
func debug_export() -> Dictionary:
	var exists := FileAccess.file_exists(SAVE_PATH)
	var payload := default_payload()
	if exists:
		var txt := _read_text(SAVE_PATH)
		var parsed: Variant = JSON.parse_string(txt) if txt != "" else null
		if parsed != null and typeof(parsed) == TYPE_DICTIONARY and (parsed as Dictionary).has("payload"):
			payload = (parsed as Dictionary)["payload"] as Dictionary
	return {
		"path": SAVE_PATH,
		"exists": exists,
		"version": CURRENT_VERSION,
		"payload_keys": payload.keys(),
	}

func perf_mark() -> Dictionary:
	return {"has_save": has_save()}

# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _compute_checksum(payload: Dictionary, version: int) -> String:
	var canonical := JSON.stringify(payload)
	var to_hash := "%d:%s" % [version, canonical]
	var ctx := HashingContext.new()
	var err := ctx.start(HashingContext.HASH_SHA256)
	if err != OK:
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

func _write_text_atomic(json_text: String) -> int:
	var fa := FileAccess.open(TEMP_PATH, FileAccess.WRITE)
	if fa == null:
		return FileAccess.get_open_error()
	fa.store_string(json_text)
	fa.flush()
	fa = null

	if FileAccess.file_exists(SAVE_PATH):
		var existing := _read_text(SAVE_PATH)
		if existing != "":
			var bf := FileAccess.open(BACKUP_PATH, FileAccess.WRITE)
			if bf != null:
				bf.store_string(existing)
				bf.flush()

	var read_back := _read_text(TEMP_PATH)
	var out := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
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
	if not env.has("payload"):
		return null
	var payload: Dictionary = env["payload"] as Dictionary
	var version: int = int(env.get("version", CURRENT_VERSION))
	var stored: String = str(env.get("checksum", ""))
	if stored != "":
		var computed := _compute_checksum(payload, version)
		if computed != stored:
			push_warning("[SaveService] backup also failed checksum (%s)" % reason)
			return null
	if version < CURRENT_VERSION:
		payload = migrate(payload, version)
	var restored := save_game(payload)
	if restored:
		push_warning("[SaveService] restored from backup after %s" % reason)
		return payload
	return null
