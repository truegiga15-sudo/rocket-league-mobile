# TelemetryService — WS09 Telemetry & Test Hooks
# Autoload singleton: TelemetryService
# Exposes event(event_name, dict), perf_mark(label), debug_export() per §11.
# Writes JSON-lines to user://telemetry.log for offline analysis and critic harness.
# Depends on WS02 (Project Structure). No downstream imports.
extends Node

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
const LOG_PATH: String = "user://telemetry.log"
const MAX_BUFFER: int = 512
const MAX_FILE_LINES: int = 20000

var _session_id: String = ""
var _start_ticks_msec: int = 0
var _start_unix: int = 0

var _event_count: int = 0
var _perf_mark_count: int = 0
var _file: FileAccess = null
var _buffer: Array[Dictionary] = []
var _last_event: Dictionary = {}
var _enabled: bool = true

signal event_logged(event_name: String, payload: Dictionary)

func _ready() -> void:
	_start_ticks_msec = Time.get_ticks_msec()
	_start_unix = int(Time.get_unix_time_from_system())
	_session_id = _make_session_id()
	_ensure_file()
	event("session_start", {
		"session_id": _session_id,
		"engine": Engine.get_version_info(),
		"locale": OS.get_locale(),
	})

func _exit_tree() -> void:
	_flush_buffer()
	if _file != null:
		_file.flush()
		_file = null
	event("session_end", {"session_id": _session_id, "events": _event_count})

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_EXIT_TREE:
		_flush_buffer()

# Public API — required by 00-conventions.md §11
func event(event_name: String, payload: Dictionary = {}) -> void:
	if not _enabled:
		return
	if event_name == "":
		push_warning("[TelemetryService] event() called with empty name — ignored")
		return
	var sanitized := _sanitize_payload(payload)
	var mono_ms: int = Time.get_ticks_msec()
	var rel_ms: int = mono_ms - _start_ticks_msec
	var entry := {
		"t_mono_ms": mono_ms,
		"t_rel_ms": rel_ms,
		"t_unix": int(Time.get_unix_time_from_system()),
		"frame": Engine.get_process_frames(),
		"session": _session_id,
		"event": event_name,
		"payload": sanitized,
	}
	_event_count += 1
	_last_event = entry.duplicate(true)
	_buffer.append(entry)
	event_logged.emit(event_name, sanitized)
	_write_entry(entry)
	if _buffer.size() > MAX_BUFFER:
		_buffer.pop_front()

func perf_mark(label: String = "") -> Dictionary:
	var s := _sample_perf(label)
	_perf_mark_count += 1
	event("perf_mark", s)
	return s

func debug_export() -> Dictionary:
	var file_exists := FileAccess.file_exists(LOG_PATH)
	var file_size := -1
	if file_exists:
		var fa := FileAccess.open(LOG_PATH, FileAccess.READ)
		if fa != null:
			file_size = int(fa.get_length())
	return {
		"log_path": LOG_PATH,
		"enabled": _enabled,
		"session_id": _session_id,
		"start_unix": _start_unix,
		"start_ticks_msec": _start_ticks_msec,
		"event_count": _event_count,
		"perf_mark_count": _perf_mark_count,
		"last_event": _last_event.duplicate(true) if not _last_event.is_empty() else {},
		"buffer_size": _buffer.size(),
		"file_exists": file_exists,
		"file_size_bytes": file_size,
		"uptime_ms": Time.get_ticks_msec() - _start_ticks_msec,
	}

func set_enabled(v: bool) -> void:
	_enabled = v

func is_enabled() -> bool:
	return _enabled

func get_session_id() -> String:
	return _session_id

func get_event_count() -> int:
	return _event_count

func get_log_path() -> String:
	return LOG_PATH

func clear_log() -> bool:
	_flush_buffer()
	if _file != null:
		_file = null
	var fa := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if fa == null:
		push_warning("[TelemetryService] clear_log() cannot open %s: %d" % [LOG_PATH, FileAccess.get_open_error()])
		return false
	fa.store_string("")
	fa.flush()
	fa = null
	_event_count = 0
	_perf_mark_count = 0
	_buffer.clear()
	_last_event.clear()
	_ensure_file()
	return true

func read_log(max_lines: int = 5000) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not FileAccess.file_exists(LOG_PATH):
		return out
	var fa := FileAccess.open(LOG_PATH, FileAccess.READ)
	if fa == null:
		return out
	var text := fa.get_as_text()
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed == "" or trimmed.begins_with("#"):
			continue
		var parsed: Variant = JSON.parse_string(trimmed)
		if parsed != null and typeof(parsed) == TYPE_DICTIONARY:
			out.append(parsed as Dictionary)
			if out.size() >= max_lines:
				break
	return out

func flush() -> void:
	_flush_buffer()
	if _file != null:
		_file.flush()

func _ensure_file() -> void:
	if _file != null:
		return
	if FileAccess.file_exists(LOG_PATH):
		_trim_if_needed()
		_file = FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
		if _file != null:
			_file.seek_end()
		else:
			push_warning("[TelemetryService] cannot open %s for append: %d" % [LOG_PATH, FileAccess.get_open_error()])
	else:
		_file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
		if _file == null:
			push_warning("[TelemetryService] cannot create %s: %d" % [LOG_PATH, FileAccess.get_open_error()])

func _write_entry(entry: Dictionary) -> void:
	_ensure_file()
	if _file == null:
		return
	var line := JSON.stringify(entry)
	_file.store_line(line)
	if _event_count % 10 == 0:
		_file.flush()

func _flush_buffer() -> void:
	if _file != null:
		_file.flush()

func _trim_if_needed() -> void:
	var fa := FileAccess.open(LOG_PATH, FileAccess.READ)
	if fa == null:
		return
	var lines := fa.get_as_text().split("\n")
	var count := 0
	for l in lines:
		if l.strip_edges() != "" and not l.strip_edges().begins_with("#"):
			count += 1
	if count <= MAX_FILE_LINES:
		return
	var keep := MAX_FILE_LINES / 2
	var start := maxi(0, lines.size() - keep)
	var trimmed: Array[String] = []
	trimmed.append("# trimmed %s — kept last %d of %d lines" % [Time.get_datetime_string_from_system(), keep, count])
	for i in range(start, lines.size()):
		var t := lines[i].strip_edges()
		if t != "":
			trimmed.append(lines[i])
	var out := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if out != null:
		for l in trimmed:
			out.store_line(l)
		out.flush()

func _sample_perf(label: String) -> Dictionary:
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var proc_s := Performance.get_monitor(Performance.TIME_PROCESS)
	var phys_s := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var tris := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var tex_bytes := int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))
	var label_clean := label.strip_edges()
	return {
		"label": label_clean,
		"t_mono_ms": Time.get_ticks_msec(),
		"t_rel_ms": Time.get_ticks_msec() - _start_ticks_msec,
		"frame": Engine.get_process_frames(),
		"fps": fps,
		"frame_ms": (proc_s + phys_s) * 1000.0 if (proc_s + phys_s) > 0.0 else 0.0,
		"physics_ms": phys_s * 1000.0,
		"draw_calls": draw_calls,
		"tris": tris,
		"texture_mem_mb": tex_bytes / 1048576.0,
	}

func _sanitize_payload(payload: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in payload.keys():
		var key := str(k)
		var v: Variant = payload[k]
		match typeof(v):
			TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
				out[key] = v
			TYPE_ARRAY, TYPE_DICTIONARY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_FLOAT32_ARRAY:
				var probe := JSON.stringify({ "v": v })
				if probe != "":
					out[key] = v
				else:
					out[key] = str(v)
			TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR, TYPE_RECT2, TYPE_TRANSFORM3D:
				out[key] = str(v)
			_:
				out[key] = str(v)
	return out

func _make_session_id() -> String:
	var t := Time.get_ticks_usec()
	var r := randi()
	var raw := "%d:%d:%d" % [t, r, _start_unix]
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) == OK:
		ctx.update(raw.to_utf8_buffer())
		var digest: PackedByteArray = ctx.finish()
		var hex := ""
		for i in range(mini(8, digest.size())):
			hex += "%02x" % digest[i]
		return hex
	return "%d-%d" % [t % 1000000, r % 1000000]
