# AnalyticsService — WS92 Analytics & Crash Hooks
# Autoload singleton: AnalyticsService (optional — register in project.godot [autoload])
# Routes high-level analytics events via TelemetryService (WS09), persists queue/consent
# via SaveService (WS08) + local file fallback, exposes crash hooks / breadcrumbs.
# Budget: <12 external calls per flush — batched, debounced, sampling-gated.
# Godot 4.x — depends on WS08 (SaveService) and WS09 (TelemetryService). No downstream imports.
extends Node

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
const ANALYTICS_VERSION: int = 1
const QUEUE_PATH: String = "user://analytics.json"
const CRASH_PATH: String = "user://crash.log"
const MAX_QUEUE: int = 256
const MAX_BREADCRUMBS: int = 32
const MAX_CRASH_LINES: int = 200
const FLUSH_INTERVAL_S: float = 15.0

# Canonical event allowlist — funnel + lifecycle + crash
const EVENT_SCREEN_VIEW: String = "screen_view"
const EVENT_MATCH_START: String = "match_start"
const EVENT_MATCH_END: String = "match_end"
const EVENT_GOAL: String = "goal"
const EVENT_SAVE: String = "save"
const EVENT_CRASH: String = "crash"
const EVENT_ERROR: String = "error"

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal event_tracked(event_name: String, params: Dictionary)
signal crash_captured(report: Dictionary)
signal consent_changed(enabled: bool)

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var _enabled: bool = true
var _consent: bool = true
var _session_id: String = ""
var _start_msec: int = 0
var _queue: Array[Dictionary] = []
var _breadcrumbs: Array[Dictionary] = []
var _crash_count: int = 0
var _event_count: int = 0
var _flush_timer: float = 0.0
var _installed: bool = false

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_start_msec = Time.get_ticks_msec()
	_session_id = _make_session_id()
	_load_persisted()
	_install_crash_hooks()

func _process(delta: float) -> void:
	if not _enabled or not _consent:
		return
	_flush_timer += delta
	if _flush_timer >= FLUSH_INTERVAL_S and not _queue.is_empty():
		flush()
		_flush_timer = 0.0

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_EXIT_TREE:
		flush()

# ---------------------------------------------------------------------------
# Public API — Analytics events (via TelemetryService WS09)
# ---------------------------------------------------------------------------

## High-level analytics track. Sanitizes, enqueues, forwards to TelemetryService.
## Budget-aware: sampling (sample_rate 0..1), queue-bounded, no-op when disabled.
func track(event_name: String, params: Dictionary = {}, sample_rate: float = 1.0) -> bool:
	if not _enabled or not _consent:
		return false
	if event_name == "":
		push_warning("[AnalyticsService] track() empty event_name — ignored")
		return false
	if sample_rate < 1.0:
		if randf() > sample_rate:
			return false
	var sanitized := _sanitize(params)
	sanitized["_analytics_v"] = ANALYTICS_VERSION
	var entry := {
		"t_mono_ms": Time.get_ticks_msec(),
		"t_rel_ms": Time.get_ticks_msec() - _start_msec,
		"t_unix": int(Time.get_unix_time_from_system()),
		"frame": Engine.get_process_frames(),
		"session": _session_id,
		"event": event_name,
		"params": sanitized,
		"breadcrumbs": _breadcrumbs.duplicate(true) if event_name == EVENT_CRASH or event_name == EVENT_ERROR else [],
	}
	_event_count += 1
	_queue.append(entry)
	if _queue.size() > MAX_QUEUE:
		_queue.pop_front()
	_persist_queue()
	_forward_to_telemetry(event_name, sanitized, entry)
	event_tracked.emit(event_name, sanitized)
	return true

## Convenience: screen_view analytics
func screen_view(screen_name: String, extra: Dictionary = {}) -> bool:
	var p := {"screen": screen_name}
	for k in extra.keys():
		p[k] = extra[k]
	return track(EVENT_SCREEN_VIEW, p)

## Funnel helper: match_start / match_end / goal / save
func match_start(mode: String = "casual", extra: Dictionary = {}) -> bool:
	var p := {"mode": mode}
	for k in extra.keys():
		p[k] = extra[k]
	return track(EVENT_MATCH_START, p)

func match_end(result: String = "", extra: Dictionary = {}) -> bool:
	var p := {"result": result}
	for k in extra.keys():
		p[k] = extra[k]
	return track(EVENT_MATCH_END, p)

# ---------------------------------------------------------------------------
# Consent / enable (persists via SaveService WS08 + local file fallback)
# ---------------------------------------------------------------------------
func set_enabled(v: bool) -> void:
	_enabled = v
	if has_node("/root/TelemetryService"):
		var ts: Node = get_node("/root/TelemetryService")
		if ts.has_method("set_enabled"):
			ts.set_enabled(v)

func is_enabled() -> bool:
	return _enabled and _consent

func set_consent(granted: bool) -> void:
	if _consent == granted:
		return
	_consent = granted
	_persist_consent()
	consent_changed.emit(granted)
	track("consent_changed", {"granted": granted}, 1.0)
	if not granted:
		clear_queue(false)

func has_consent() -> bool:
	return _consent

func get_session_id() -> String:
	return _session_id

func get_event_count() -> int:
	return _event_count

# ---------------------------------------------------------------------------
# Breadcrumbs
# ---------------------------------------------------------------------------
func add_breadcrumb(message: String, category: String = "general", data: Dictionary = {}) -> void:
	if message == "":
		return
	var crumb := {
		"t_mono_ms": Time.get_ticks_msec(),
		"t_rel_ms": Time.get_ticks_msec() - _start_msec,
		"msg": message.substr(0, 512),
		"category": category,
		"data": _sanitize(data),
	}
	_breadcrumbs.append(crumb)
	if _breadcrumbs.size() > MAX_BREADCRUMBS:
		_breadcrumbs.pop_front()

func get_breadcrumbs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for b in _breadcrumbs:
		out.append(b.duplicate(true))
	return out

func clear_breadcrumbs() -> void:
	_breadcrumbs.clear()

# ---------------------------------------------------------------------------
# Crash hooks
# ---------------------------------------------------------------------------

## Install crash/error hooks — idempotent
func install_crash_handler() -> void:
	_install_crash_hooks()

func _install_crash_hooks() -> void:
	if _installed:
		return
	_installed = true
	# Godot has no global uncaught-exception hook; we expose report_error / capture_exception
	# and wire logger callback if available. Also connect to Tree's error if engine forwards.
	add_breadcrumb("crash_handler_installed", "lifecycle")

## Manual crash report — call from try/catch or error handlers
func report_crash(error_msg: String, stack: String = "", extra: Dictionary = {}) -> Dictionary:
	_crash_count += 1
	var report := {
		"t_mono_ms": Time.get_ticks_msec(),
		"t_rel_ms": Time.get_ticks_msec() - _start_msec,
		"t_unix": int(Time.get_unix_time_from_system()),
		"frame": Engine.get_process_frames(),
		"session": _session_id,
		"error": error_msg.substr(0, 2048),
		"stack": stack.substr(0, 4096),
		"extra": _sanitize(extra),
		"breadcrumbs": _breadcrumbs.duplicate(true),
		"crash_index": _crash_count,
	}
	_write_crash_log(report)
	track(EVENT_CRASH, {"error": error_msg.substr(0, 512), "crash_index": _crash_count})
	track(EVENT_ERROR, {"error": error_msg.substr(0, 512), "stack": stack.substr(0, 1024)})
	crash_captured.emit(report)
	# Also forward directly to TelemetryService for offline analysis
	if has_node("/root/TelemetryService"):
		var ts: Node = get_node("/root/TelemetryService")
		if ts.has_method("event"):
			ts.event("crash", report)
	return report

## Capture GDScript error (e.g. from _notification or assert)
func capture_error(err: String, context: String = "", extra: Dictionary = {}) -> Dictionary:
	add_breadcrumb(err.substr(0, 256), "error", {"context": context})
	return report_crash(err, context, extra)

## Capture exception object / Variant
func capture_exception(exception: Variant, context: String = "") -> Dictionary:
	var msg := str(exception).substr(0, 2048)
	var stack := context.substr(0, 4096)
	return report_crash(msg, stack, {"type": typeof(exception)})

func get_crash_count() -> int:
	return _crash_count

func read_crash_log(max_lines: int = 100) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not FileAccess.file_exists(CRASH_PATH):
		return out
	var fa := FileAccess.open(CRASH_PATH, FileAccess.READ)
	if fa == null:
		return out
	var text := fa.get_as_text()
	var count := 0
	for line in text.split("\n"):
		var t := line.strip_edges()
		if t == "" or t.begins_with("#"):
			continue
		var p: Variant = JSON.parse_string(t)
		if p != null and typeof(p) == TYPE_DICTIONARY:
			out.append(p as Dictionary)
			count += 1
			if count >= max_lines:
				break
	return out

func clear_crash_log() -> bool:
	if FileAccess.file_exists(CRASH_PATH):
		var fa := FileAccess.open(CRASH_PATH, FileAccess.WRITE)
		if fa == null:
			return false
		fa.store_string("")
		fa.flush()
	_crash_count = 0
	return true

# ---------------------------------------------------------------------------
# Queue / flush (budget-aware: <12 calls — batched file + telemetry)
# ---------------------------------------------------------------------------
func flush() -> int:
	if _queue.is_empty():
		return 0
	var count := _queue.size()
	# TelemetryService already received events via _forward_to_telemetry on track().
	# Flush ensures file persistence + TelemetryService flush in one call.
	_persist_queue()
	if has_node("/root/TelemetryService"):
		var ts: Node = get_node("/root/TelemetryService")
		if ts.has_method("flush"):
			ts.flush()
	_flush_timer = 0.0
	return count

func get_queue_size() -> int:
	return _queue.size()

func get_queued_events() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in _queue:
		out.append(e.duplicate(true))
	return out

func clear_queue(persist: bool = true) -> void:
	_queue.clear()
	if persist:
		_persist_queue()

# ---------------------------------------------------------------------------
# Observability — §11 debug_export / perf_mark
# ---------------------------------------------------------------------------
func debug_export() -> Dictionary:
	return {
		"analytics_version": ANALYTICS_VERSION,
		"enabled": _enabled,
		"consent": _consent,
		"session_id": _session_id,
		"start_msec": _start_msec,
		"event_count": _event_count,
		"queue_size": _queue.size(),
		"breadcrumbs_size": _breadcrumbs.size(),
		"crash_count": _crash_count,
		"installed": _installed,
		"queue_path": QUEUE_PATH,
		"crash_path": CRASH_PATH,
		"uptime_ms": Time.get_ticks_msec() - _start_msec,
	}

func perf_mark(label: String = "") -> Dictionary:
	var d := {
		"label": label,
		"t_mono_ms": Time.get_ticks_msec(),
		"t_rel_ms": Time.get_ticks_msec() - _start_msec,
		"frame": Engine.get_process_frames(),
		"queue_size": _queue.size(),
		"crash_count": _crash_count,
	}
	track("perf_mark", {"label": label, "queue_size": _queue.size()}, 1.0)
	return d

# ---------------------------------------------------------------------------
# Internals — TelemetryService bridge (WS09) + SaveService persistence (WS08)
# ---------------------------------------------------------------------------
func _forward_to_telemetry(event_name: String, params: Dictionary, _entry: Dictionary) -> void:
	if not has_node("/root/TelemetryService"):
		return
	var ts: Node = get_node("/root/TelemetryService")
	if ts.has_method("event"):
		# Prefix to namespace analytics vs raw telemetry
		ts.event("analytics." + event_name, params)

func _persist_queue() -> void:
	var payload := {
		"version": ANALYTICS_VERSION,
		"session": _session_id,
		"consent": _consent,
		"enabled": _enabled,
		"queue": _queue,
		"breadcrumbs": _breadcrumbs,
		"crash_count": _crash_count,
		"event_count": _event_count,
		"saved_at": int(Time.get_unix_time_from_system()),
	}
	var text := JSON.stringify(payload)
	if text == "":
		return
	var fa := FileAccess.open(QUEUE_PATH, FileAccess.WRITE)
	if fa != null:
		fa.store_string(text)
		fa.flush()
	# Mirror consent into SaveService payload when available (WS08)
	_mirror_consent_to_save()

func _persist_consent() -> void:
	_persist_queue()

func _mirror_consent_to_save() -> void:
	if not has_node("/root/SaveService"):
		return
	var ss: Node = get_node("/root/SaveService")
	if not ss.has_method("load_save"):
		return
	# Best-effort: read, patch analytics_opt_in, save. Failures are silent — local file is source of truth.
	var payload: Dictionary = ss.call("load_save") as Dictionary
	if payload.has("progress"):
		payload["progress"]["analytics_consent"] = _consent
		if ss.has_method("save_game"):
			ss.call("save_game", payload)

func _load_persisted() -> void:
	if not FileAccess.file_exists(QUEUE_PATH):
		_try_load_consent_from_save()
		return
	var fa := FileAccess.open(QUEUE_PATH, FileAccess.READ)
	if fa == null:
		_try_load_consent_from_save()
		return
	var text := fa.get_as_text()
	if text.strip_edges() == "":
		return
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return
	var d: Dictionary = parsed as Dictionary
	_consent = bool(d.get("consent", true))
	_enabled = bool(d.get("enabled", true))
	_crash_count = int(d.get("crash_count", 0))
	_event_count = int(d.get("event_count", 0))
	var q: Variant = d.get("queue", [])
	if typeof(q) == TYPE_ARRAY:
		var arr: Array = q as Array
		_queue.clear()
		for item in arr:
			if typeof(item) == TYPE_DICTIONARY:
				_queue.append(item as Dictionary)
				if _queue.size() >= MAX_QUEUE:
					break
	var bc: Variant = d.get("breadcrumbs", [])
	if typeof(bc) == TYPE_ARRAY:
		_breadcrumbs.clear()
		for b in bc as Array:
			if typeof(b) == TYPE_DICTIONARY:
				_breadcrumbs.append(b as Dictionary)
				if _breadcrumbs.size() >= MAX_BREADCRUMBS:
					break
	# SaveService consent takes precedence if it exists and differs (user toggled via settings)
	_try_load_consent_from_save()

func _try_load_consent_from_save() -> void:
	if not has_node("/root/SaveService"):
		return
	var ss: Node = get_node("/root/SaveService")
	if not ss.has_method("load_save"):
		return
	var payload: Dictionary = ss.call("load_save") as Dictionary
	if payload.has("progress") and (payload["progress"] as Dictionary).has("analytics_consent"):
		_consent = bool(payload["progress"]["analytics_consent"])

func _write_crash_log(report: Dictionary) -> void:
	var line := JSON.stringify(report)
	var fa: FileAccess = null
	if FileAccess.file_exists(CRASH_PATH):
		fa = FileAccess.open(CRASH_PATH, FileAccess.READ_WRITE)
		if fa != null:
			fa.seek_end()
	else:
		fa = FileAccess.open(CRASH_PATH, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_line(line)
	fa.flush()
	_trim_crash_if_needed()

func _trim_crash_if_needed() -> void:
	var fa := FileAccess.open(CRASH_PATH, FileAccess.READ)
	if fa == null:
		return
	var lines := fa.get_as_text().split("\n")
	var count := 0
	for l in lines:
		if l.strip_edges() != "" and not l.strip_edges().begins_with("#"):
			count += 1
	if count <= MAX_CRASH_LINES:
		return
	var keep := MAX_CRASH_LINES / 2
	var start := maxi(0, lines.size() - keep)
	var trimmed: Array[String] = []
	trimmed.append("# trimmed %s — kept last %d of %d" % [Time.get_datetime_string_from_system(), keep, count])
	for i in range(start, lines.size()):
		var t := lines[i].strip_edges()
		if t != "":
			trimmed.append(lines[i])
	var out := FileAccess.open(CRASH_PATH, FileAccess.WRITE)
	if out != null:
		for l in trimmed:
			out.store_line(l)
		out.flush()

func _sanitize(payload: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in payload.keys():
		var key := str(k).substr(0, 64)
		var v: Variant = payload[k]
		match typeof(v):
			TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
				if typeof(v) == TYPE_STRING:
					out[key] = str(v).substr(0, 1024)
				else:
					out[key] = v
			TYPE_ARRAY, TYPE_DICTIONARY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_FLOAT32_ARRAY:
				var probe := JSON.stringify({"v": v})
				if probe != "":
					out[key] = v
				else:
					out[key] = str(v).substr(0, 1024)
			TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR, TYPE_RECT2, TYPE_TRANSFORM3D:
				out[key] = str(v)
			_:
				out[key] = str(v).substr(0, 1024)
	return out

func _make_session_id() -> String:
	var t := Time.get_ticks_usec()
	var r := randi()
	var raw := "analytics:%d:%d:%d" % [t, r, _start_msec]
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) == OK:
		ctx.update(raw.to_utf8_buffer())
		var digest: PackedByteArray = ctx.finish()
		var hex := ""
		for i in range(mini(8, digest.size())):
			hex += "%02x" % digest[i]
		return hex
	return "%d-%d" % [t % 1000000, r % 1000000]
