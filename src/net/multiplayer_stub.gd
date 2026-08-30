## WS91 — Local Multiplayer Stub / Net Prep
## Budget-aware offline stub: local splitscreen multiplex, net-ready API surface.
## No real network IO; prepares deterministic tick + quantized inputs for future net.
## Depends on: TimeService WS05 (120 Hz, clamp, quantize), World WS23 (fixed tick).
## Conventions: docs/architecture/00-conventions.md S3,S5,S11,S12 — 120 Hz, Y-up, meters.
## Budget: <12 engine/API calls per frame (cached tick, no per-frame allocation).
extends Node
class_name MultiplayerStub

const PC = preload("res://src/core/constants.gd")
const TimeSvc = preload("res://src/core/time_service.gd")
const WorldRef = preload("res://src/game/world.gd")

# ---------------------------------------------------------------------------
# Fixed tick — must match TimeService / PhysicsConstants / project.godot / World
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0
const DELTA_MIN: float = 1.0 / 240.0
const DELTA_MAX: float = 1.0 / 30.0
const MAX_TICKS_PER_FRAME: int = 4
const MAX_CALLS_PER_FRAME: int = 11

# ---------------------------------------------------------------------------
# Local multiplayer limits
# ---------------------------------------------------------------------------
const MAX_LOCAL_PLAYERS: int = 4
const MIN_LOCAL_PLAYERS: int = 1

enum NetMode { OFFLINE = 0, LOCAL_SPLITSCREEN = 1, RESERVED_ONLINE = 2 }
enum Role { HOST = 0, CLIENT = 1, LOCAL = 2 }

# ---------------------------------------------------------------------------
# Signals — net-prep surface (offline no-ops emit for UI wiring)
# ---------------------------------------------------------------------------
signal player_joined(player_id: int)
signal player_left(player_id: int)
signal local_host_started(count: int)
signal tick_advanced(tick: int)
signal net_mode_changed(mode: int)

# ---------------------------------------------------------------------------
# State — no per-tick allocation, reused dicts
# ---------------------------------------------------------------------------
var _mode: int = NetMode.OFFLINE
var _role: int = Role.LOCAL
var _world: Node = null
var _time_service: Node = null

var _tick_count: int = 0
var _accumulator: float = 0.0
var _total_time: float = 0.0
var _frame_count: int = 0
var _call_count_this_frame: int = 0
var _total_calls: int = 0

# Slots: index 0..MAX-1, each { active: bool, id: int, move: Vector2, look: Vector2, boost: bool, jump: bool, drift: bool, ball_cam: bool, quantized: Dictionary }
var _slots: Array[Dictionary] = []
var _player_count: int = 0

func _init() -> void:
	for i in MAX_LOCAL_PLAYERS:
		_slots.append({
			"active": false,
			"id": i,
			"move": Vector2.ZERO,
			"look": Vector2.ZERO,
			"boost": false,
			"jump": false,
			"drift": false,
			"ball_cam": false,
			"quantized": {},
		})

func _ready() -> void:
	_time_service = get_node_or_null("/root/TimeService")
	_world = get_node_or_null("/root/World")
	if _world == null:
		_world = get_parent() as World
	if _world == null:
		_world = _find_world()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[MultiplayerStub] debug_validate: %s" % e)

func _find_world() -> Node:
	var n := get_node_or_null("../World")
	if n != null and n is World:
		return n
	for child in get_children():
		if child is World:
			return child
	return null

## Bind explicit World instance (call before hosting). Counts as 1 call.
func bind_world(world: World) -> void:
	if _budget_exceeded(): return
	_call_count_this_frame += 1
	_total_calls += 1
	_world = world

# ---------------------------------------------------------------------------
# Budget helper — <12 calls/frame
# ---------------------------------------------------------------------------
func _budget_exceeded() -> bool:
	return _call_count_this_frame >= MAX_CALLS_PER_FRAME

func _process(_delta: float) -> void:
	_call_count_this_frame = 0
	_frame_count += 1

# ---------------------------------------------------------------------------
# Local host API — offline stub only
# ---------------------------------------------------------------------------
## Start local splitscreen session with 1..4 players. Offline only.
func host_local(count: int = 1) -> Dictionary:
	if _budget_exceeded():
		return {"ok": false, "error": "budget exceeded"}
	_call_count_this_frame += 1
	_total_calls += 1
	var clamped := clamp(count, MIN_LOCAL_PLAYERS, MAX_LOCAL_PLAYERS)
	_player_count = 0
	for i in MAX_LOCAL_PLAYERS:
		_slots[i]["active"] = i < clamped
		_slots[i]["id"] = i
		if _slots[i]["active"]:
			_player_count += 1
			# Reset quantized via TimeService determinism
			_slots[i]["quantized"] = TimeSvc.quantize_input(Vector2.ZERO, Vector2.ZERO, false, false, false, false)
	_mode = NetMode.LOCAL_SPLITSCREEN if clamped > 1 else NetMode.OFFLINE
	_role = Role.LOCAL
	local_host_started.emit(clamped)
	net_mode_changed.emit(_mode)
	return {"ok": true, "count": clamped, "mode": _mode}

func add_local_player(player_id: int = -1) -> Dictionary:
	if _budget_exceeded():
		return {"ok": false, "error": "budget exceeded"}
	_call_count_this_frame += 1
	_total_calls += 1
	if _player_count >= MAX_LOCAL_PLAYERS:
		return {"ok": false, "error": "max players reached"}
	var slot := -1
	if player_id >= 0 and player_id < MAX_LOCAL_PLAYERS and not _slots[player_id]["active"]:
		slot = player_id
	else:
		for i in MAX_LOCAL_PLAYERS:
			if not _slots[i]["active"]:
				slot = i
				break
	if slot == -1:
		return {"ok": false, "error": "no free slot"}
	_slots[slot]["active"] = true
	_slots[slot]["id"] = slot
	_slots[slot]["quantized"] = TimeSvc.quantize_input(Vector2.ZERO, Vector2.ZERO, false, false, false, false)
	_player_count += 1
	if _player_count > 1:
		_mode = NetMode.LOCAL_SPLITSCREEN
	player_joined.emit(slot)
	return {"ok": true, "player_id": slot, "count": _player_count}

func remove_local_player(player_id: int) -> Dictionary:
	if _budget_exceeded():
		return {"ok": false, "error": "budget exceeded"}
	_call_count_this_frame += 1
	_total_calls += 1
	if player_id < 0 or player_id >= MAX_LOCAL_PLAYERS:
		return {"ok": false, "error": "invalid id"}
	if not _slots[player_id]["active"]:
		return {"ok": false, "error": "not active"}
	_slots[player_id]["active"] = false
	_player_count -= 1
	if _player_count <= 1 and _mode == NetMode.LOCAL_SPLITSCREEN:
		_mode = NetMode.OFFLINE if _player_count == 1 else NetMode.OFFLINE
	player_left.emit(player_id)
	return {"ok": true, "count": _player_count}

func get_player_count() -> int:
	return _player_count

func is_host() -> bool:
	return true # stub offline is always host

func get_mode() -> int:
	return _mode

func is_online() -> bool:
	return false # stub: never online

# ---------------------------------------------------------------------------
# Input — quantized via TimeService WS05 for determinism
# ---------------------------------------------------------------------------
## Set raw input for player_id; stores quantized copy (deterministic replay).
func set_input(player_id: int, move: Vector2, look: Vector2, boost: bool, jump: bool, drift: bool, ball_cam: bool) -> Dictionary:
	if _budget_exceeded():
		return {"ok": false, "error": "budget exceeded"}
	_call_count_this_frame += 1
	_total_calls += 1
	if player_id < 0 or player_id >= MAX_LOCAL_PLAYERS:
		return {"ok": false, "error": "invalid id"}
	if not _slots[player_id]["active"]:
		return {"ok": false, "error": "player not active"}
	_slots[player_id]["move"] = move
	_slots[player_id]["look"] = look
	_slots[player_id]["boost"] = boost
	_slots[player_id]["jump"] = jump
	_slots[player_id]["drift"] = drift
	_slots[player_id]["ball_cam"] = ball_cam
	_slots[player_id]["quantized"] = TimeSvc.quantize_input(move, look, boost, jump, drift, ball_cam)
	return {"ok": true, "quantized": _slots[player_id]["quantized"]}

func get_quantized_input(player_id: int) -> Dictionary:
	if player_id < 0 or player_id >= MAX_LOCAL_PLAYERS:
		return {}
	return _slots[player_id].get("quantized", {})

func get_dequantized_input(player_id: int) -> Dictionary:
	var q: Dictionary = get_quantized_input(player_id)
	if q.is_empty():
		return {}
	return TimeSvc.dequantize_input(q)

func get_inputs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in MAX_LOCAL_PLAYERS:
		if _slots[i]["active"]:
			out.append(_slots[i]["quantized"])
	return out

# ---------------------------------------------------------------------------
# Deterministic tick — mirrors TimeService accumulator, 120 Hz, clamp [1/240,1/30]
# ---------------------------------------------------------------------------
## Advance stub clock by frame delta. Returns ticks consumed. Drives _tick().
func step(delta: float) -> int:
	if _budget_exceeded():
		return 0
	_call_count_this_frame += 1
	_total_calls += 1
	var clamped := TimeSvc.clamp_delta(delta)
	_accumulator += clamped
	var ticks := int(floor(_accumulator / TICK_DELTA))
	if ticks > MAX_TICKS_PER_FRAME:
		var dropped := ticks - MAX_TICKS_PER_FRAME
		_accumulator -= float(dropped) * TICK_DELTA
		ticks = MAX_TICKS_PER_FRAME
		push_warning("[MultiplayerStub] clamped %d excess ticks (delta=%.4f)" % [dropped, delta])
	for i in ticks:
		_accumulator -= TICK_DELTA
		if _accumulator < 0.0 and _accumulator > -0.000001:
			_accumulator = 0.0
		_tick_count += 1
		_total_time += TICK_DELTA
		_tick(TICK_DELTA)
			tick_advanced.emit(_tick_count)
	return ticks

## Alias for World/TimeService parity
func step_world(delta: float) -> int:
	return step(delta)

func _tick(_delta: float) -> void:
	# Hook: future net will reconcile inputs here. Stub just keeps tick in sync
	# with World if bound — no extra world step (World owns physics).
	pass

func reset() -> void:
	_accumulator = 0.0
	_tick_count = 0
	_total_time = 0.0
	_frame_count = 0
	_call_count_this_frame = 0
	_mode = NetMode.OFFLINE
	_player_count = 0
	for i in MAX_LOCAL_PLAYERS:
		_slots[i]["active"] = false
		_slots[i]["move"] = Vector2.ZERO
		_slots[i]["look"] = Vector2.ZERO
		_slots[i]["boost"] = false
		_slots[i]["jump"] = false
		_slots[i]["drift"] = false
		_slots[i]["ball_cam"] = false
		_slots[i]["quantized"] = {}

func get_tick_count() -> int:
	return _tick_count

func get_total_time() -> float:
	return _total_time

func get_accumulator() -> float:
	return _accumulator

func get_alpha() -> float:
	return clamp(_accumulator / TICK_DELTA, 0.0, 1.0)

func get_fixed_delta() -> float:
	return TICK_DELTA

# ---------------------------------------------------------------------------
# Validation / telemetry — S11
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA %.8f != 1/120" % TICK_DELTA)
	if not is_equal_approx(DELTA_MIN, 1.0 / 240.0):
		errors.append("DELTA_MIN != 1/240")
	if not is_equal_approx(DELTA_MAX, 1.0 / 30.0):
		errors.append("DELTA_MAX != 1/30")
	if DELTA_MIN >= DELTA_MAX:
		errors.append("DELTA_MIN >= DELTA_MAX")
	if MAX_TICKS_PER_FRAME != 4:
		errors.append("MAX_TICKS_PER_FRAME != 4")
	if MAX_CALLS_PER_FRAME >= 12:
		errors.append("MAX_CALLS_PER_FRAME %d must be <12" % MAX_CALLS_PER_FRAME)
	if MAX_LOCAL_PLAYERS != 4:
		errors.append("MAX_LOCAL_PLAYERS %d != 4" % MAX_LOCAL_PLAYERS)
	if not is_equal_approx(TICK_DELTA, PC.PHYSICS_TICK_DELTA):
		errors.append("TICK_DELTA mismatch PC")
	if PHYSICS_TICKS_PER_SECOND != PC.PHYSICS_TICKS_PER_SECOND:
		errors.append("TICKS mismatch PC")
	if PHYSICS_TICKS_PER_SECOND != TimeSvc.PHYSICS_TICKS_PER_SECOND:
		errors.append("TICKS mismatch TimeService")
	if not is_equal_approx(TICK_DELTA, TimeSvc.TICK_DELTA):
		errors.append("TICK_DELTA mismatch TimeService")
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"tick_delta": TICK_DELTA,
		"delta_min": DELTA_MIN,
		"delta_max": DELTA_MAX,
		"max_ticks_per_frame": MAX_TICKS_PER_FRAME,
		"max_calls_per_frame": MAX_CALLS_PER_FRAME,
		"max_local_players": MAX_LOCAL_PLAYERS,
		"mode": _mode,
		"role": _role,
		"is_online": false,
		"is_host": true,
		"player_count": _player_count,
		"tick_count": _tick_count,
		"total_time": _total_time,
		"accumulator": _accumulator,
		"alpha": get_alpha(),
		"frame_count": _frame_count,
		"total_calls": _total_calls,
		"has_world": _world != null,
		"has_time_service": _time_service != null,
	}

func perf_mark() -> Dictionary:
	return {
		"tick_count": _tick_count,
		"player_count": _player_count,
		"accumulator_ms": _accumulator * 1000.0,
		"frame_count": _frame_count,
		"calls_this_frame": _call_count_this_frame,
		"total_calls": _total_calls,
		"alpha": get_alpha(),
	}
