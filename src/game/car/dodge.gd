## WS17 — Dodge / Flip Mechanics (budget-aware, solo)
## Directional dodge/flip within 0.15s window after first jump, torque 800Nm.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07),
##             src/core/physics/physics_config.gd (WS07), src/core/time_service.gd (WS05),
##             src/core/input_service.gd (WS06) -> InputService.jump + move,
##             src/game/car/car_physics.gd (WS11), src/game/car/jump.gd (WS16)
## Conventions: docs/architecture/00-conventions.md §3-§4, 1 unit = 1 m, Y-up, +Z forward.
## Physics tick 120 Hz (project.godot: physics/common/physics_ticks_per_second).
## Input: InputService.jump (jump_just_pressed) + move Vector2 — NEVER raw Input.
## Budget: <4 ms per tick, <12 calls per dodge (conventions §12).
## No procedural generation — all values authored/deterministic.
extends RefCounted
class_name CarDodge

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const CarPhysicsRef = preload("res://src/game/car/car_physics.gd")
const CarJumpRef = preload("res://src/game/car/jump.gd")
const TimeServiceRef = preload("res://src/core/time_service.gd")

# ---------------------------------------------------------------------------
# Authored dodge constants — single source for WS17
# ---------------------------------------------------------------------------

## Dodge window after first jump (s). Must dodge within this; 0.15 s = 18 ticks at 120 Hz.
const DODGE_WINDOW: float = 0.15
const FLIP_WINDOW: float = DODGE_WINDOW

## Torque magnitude applied on dodge (Nm). RL flip torque ~800 Nm at 180 kg.
const DODGE_TORQUE: float = 800.0
const FLIP_TORQUE: float = DODGE_TORQUE

## Linear dodge speed boost (m/s) applied along dodge direction. Authored to feel snappy.
## Impulse = MASS * DODGE_SPEED ≈ 1530 Ns forward/side.
const DODGE_SPEED: float = 8.5
const DODGE_IMPULSE_MAG: float = 1530.0 # 180 * 8.5

## Mass — must match CarPhysics.MASS and CarJump.MASS (single source).
const MASS: float = 180.0

## Minimum move Vector2 length to count as directional dodge input (deadzone).
const DODGE_INPUT_THRESHOLD: float = 0.20
const INPUT_DEADZONE: float = DODGE_INPUT_THRESHOLD

## Cooldown between dodges / jumps (s). Reuse CarJump.COOLDOWN (0.15 s).
const COOLDOWN: float = 0.15

## Dodge duration (s) — time controls are locked during flip (optional, not enforced here).
const DODGE_DURATION: float = 0.5

## Physics tick — must be 120 Hz (validated against PC + CarJump + TimeService).
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_DELTA: float = PHYSICS_TICK_DELTA

# ---------------------------------------------------------------------------
# Instance state — per-car
# ---------------------------------------------------------------------------

var _time: float = 0.0
var _first_jump_time: float = -999.0
var _last_dodge_time: float = -999.0
var _has_dodged: bool = false
var _is_dodging: bool = false
var _dodge_dir: Vector2 = Vector2.ZERO
var _dodge_world_dir: Vector3 = Vector3.ZERO
var _jump: CarJumpRef = null
var _is_grounded: bool = false
var _last_ground_time: float = -999.0
var _dodge_count: int = 0

# ---------------------------------------------------------------------------
# InputService integration — NEVER call Input.* directly
# ---------------------------------------------------------------------------

static func _get_input_service() -> Node:
	if Engine.has_singleton("InputService"):
		return Engine.get_singleton("InputService")
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		if tree.root != null:
			var svc := tree.root.get_node_or_null("InputService")
			if svc != null:
				return svc
		var alt := tree.get_root().get_node_or_null("/root/InputService")
		if alt != null:
			return alt
	return null

static func is_jump_just_pressed() -> bool:
	var svc := _get_input_service()
	if svc == null:
		return false
	if "jump_just_pressed" in svc:
		return bool(svc.jump_just_pressed)
	if "jump" in svc:
		return bool(svc.jump)
	return false

static func get_move_vector() -> Vector2:
	var svc := _get_input_service()
	if svc == null:
		return Vector2.ZERO
	if "move" in svc:
		return svc.move as Vector2
	if svc.has_method("get_move_vector"):
		return svc.get_move_vector() as Vector2
	return Vector2.ZERO

## Normalized dodge direction from raw move Vector2 (InputService.move).
## Returns Vector2.ZERO if below threshold (no directional input => no dodge, allow vertical double jump).
static func dodge_direction_from_move_vector(move: Vector2) -> Vector2:
	var l := move.length()
	if l < DODGE_INPUT_THRESHOLD:
		return Vector2.ZERO
	return move.normalized()

## Convenience: probe InputService directly.
static func get_dodge_direction_from_service() -> Vector2:
	return dodge_direction_from_move_vector(get_move_vector())

static func has_dodge_input(move: Vector2 = Vector2.INF) -> bool:
	var m := move if move != Vector2.INF else get_move_vector()
	return dodge_direction_from_move_vector(m) != Vector2.ZERO

# ---------------------------------------------------------------------------
# Dodge eligibility
# ---------------------------------------------------------------------------

## Can dodge at time t? Requires: airborne, not yet dodged, within window, cooldown elapsed, has directional input.
func can_dodge(time: float = -1.0, move: Vector2 = Vector2.INF) -> bool:
	var t := _time if time < 0.0 else time
	if _has_dodged:
		return false
	if _is_grounded:
		return false
	if _first_jump_time < -900.0:
		return false
	if t - _first_jump_time > DODGE_WINDOW + 0.001:
		return false
	if t - _first_jump_time < -0.001:
		return false
	if t - _last_dodge_time < COOLDOWN:
		return false
	var dir := dodge_direction_from_move_vector(move if move != Vector2.INF else get_move_vector())
	if dir == Vector2.ZERO:
		return false
	return true

## Can dodge with explicit direction vector (already normalized).
func can_dodge_with_dir(dir: Vector2, time: float = -1.0) -> bool:
	var t := _time if time < 0.0 else time
	if _has_dodged:
		return false
	if _is_grounded:
		return false
	if _first_jump_time < -900.0:
		return false
	if t - _first_jump_time > DODGE_WINDOW + 0.001:
		return false
	if t - _last_dodge_time < COOLDOWN:
		return false
	if dir.length() < 0.5:
		return false
	return true

# ---------------------------------------------------------------------------
# World-space helpers — direction + torque
# ---------------------------------------------------------------------------

## Convert 2D dodge direction to world-space unit vector (Y = 0, horizontal).
## Uses car basis: forward = +Z, right = +X. move.y: -1 = forward, +1 = back.
static func world_dodge_direction(car: RigidBody3D, dodge_dir: Vector2) -> Vector3:
	if car == null:
		return Vector3.ZERO
	if dodge_dir == Vector2.ZERO:
		return Vector3.ZERO
	var fwd := car.global_transform.basis.z.normalized()
	if fwd.length_squared() < 0.1:
		fwd = Vector3(0, 0, 1)
	var right := car.global_transform.basis.x.normalized()
	if right.length_squared() < 0.1:
		right = Vector3(1, 0, 0)
	# move.x -> right, move.y -> forward (inverted: -y is forward)
	var world := right * dodge_dir.x + fwd * (-dodge_dir.y)
	world.y = 0.0
	if world.length_squared() < 0.001:
		return Vector3.ZERO
	return world.normalized()

## Local torque vector (car space) for a given dodge direction. Magnitude = DODGE_TORQUE.
## Forward flip = pitch around X, side flip = roll around Z. Diagonal blended and normalized to 800.
static func local_dodge_torque(dodge_dir: Vector2) -> Vector3:
	if dodge_dir == Vector2.ZERO:
		return Vector3.ZERO
	# Map: pitch = -dir.y (forward => +pitch), roll = -dir.x (right => -roll)
	var pitch := -dodge_dir.y
	var roll := -dodge_dir.x
	var v2 := Vector2(pitch, roll)
	if v2.length_squared() < 0.001:
		return Vector3.ZERO
	v2 = v2.normalized() * DODGE_TORQUE
	return Vector3(v2.x, 0.0, v2.y)

## Compute world torque impulse vector to apply.
static func compute_dodge_torque(car: RigidBody3D, dodge_dir: Vector2) -> Vector3:
	var local := local_dodge_torque(dodge_dir)
	if car == null:
		return local
	# Transform local torque by car basis (world space)
	var basis := car.global_transform.basis
	return basis * local

## Compute linear dodge impulse vector (Ns) to apply.
static func compute_dodge_impulse(car: RigidBody3D, dodge_dir: Vector2, mass: float = MASS) -> Vector3:
	var world_dir := world_dodge_direction(car, dodge_dir)
	if world_dir == Vector3.ZERO:
		return Vector3.ZERO
	return world_dir * mass * DODGE_SPEED

# ---------------------------------------------------------------------------
# Dodge execution — budget-aware: single torque impulse + single velocity/impulse write
# ---------------------------------------------------------------------------

## Apply dodge torque + impulse to car. Caller must have checked can_dodge. Returns true if applied.
func do_dodge(car: RigidBody3D, dodge_dir: Vector2 = Vector2.INF, time: float = -1.0) -> bool:
	var t := _time if time < 0.0 else time
	var dir: Vector2 = dodge_dir
	if dir == Vector2.INF:
		dir = get_dodge_direction_from_service()
	if dir == Vector2.ZERO:
		return false
	if not can_dodge_with_dir(dir, t):
		return false
	_apply_dodge(car, dir)
	_last_dodge_time = t
	_has_dodged = true
	_is_dodging = true
	_dodge_dir = dir
	_dodge_world_dir = world_dodge_direction(car, dir)
	_dodge_count += 1
	return true

## Try dodge by polling InputService (jump + move). Returns true if dodged.
func try_dodge(car: RigidBody3D, time: float = -1.0) -> bool:
	if not is_jump_just_pressed():
		return false
	var t := _time if time < 0.0 else time
	var dir := get_dodge_direction_from_service()
	if dir == Vector2.ZERO:
		return false
	return do_dodge(car, dir, t)

## Notify that a first jump just occurred at time t — opens the dodge window.
func notify_jump(time: float = -1.0) -> void:
	var t := _time if time < 0.0 else time
	_first_jump_time = t
	_has_dodged = false
	_is_dodging = false
	_dodge_dir = Vector2.ZERO

## Bind an external CarJump instance for ground/window sync (optional).
func set_jump(jump: CarJumpRef) -> void:
	_jump = jump

static func _apply_dodge(car: RigidBody3D, dodge_dir: Vector2) -> void:
	if car == null or dodge_dir == Vector2.ZERO:
		return
	# Torque impulse (budget: single call)
	var world_torque := CarDodge.compute_dodge_torque(car, dodge_dir)
	if world_torque != Vector3.ZERO:
		if car.has_method("apply_torque_impulse"):
			car.apply_torque_impulse(world_torque)
		else:
			car.apply_torque(world_torque)
	# Linear impulse / velocity boost (budget: single call)
	var impulse := CarDodge.compute_dodge_impulse(car, dodge_dir, MASS)
	if impulse != Vector3.ZERO:
		# Prefer velocity write for determinism if already airborne; impulse is physics-step dependent.
		# Use apply_central_impulse for Godot physics correctness; fallback to velocity add.
		if car.has_method("apply_central_impulse"):
			car.apply_central_impulse(impulse)
		else:
			car.linear_velocity += impulse / max(car.mass if "mass" in car else MASS, 1.0)

# ---------------------------------------------------------------------------
# Per-tick update — call from _physics_process(delta) at 120 Hz. Budget-aware.
# ---------------------------------------------------------------------------

func update(delta: float, car: RigidBody3D, auto_poll_input: bool = false, space_state: PhysicsDirectSpaceState3D = null) -> bool:
	_time += delta
	var grounded := _is_grounded
	# Sync grounded from CarJump if bound, else raycast/height check via CarJump helpers
	if _jump != null:
		# CarJump tracks grounded; mirror its _is_grounded if accessible, else recompute
		if "_is_grounded" in _jump:
			grounded = bool(_jump.get("_is_grounded"))
		else:
			grounded = CarJumpRef.is_grounded(car, space_state)
	else:
		grounded = CarJumpRef.is_grounded(car, space_state)
	_update_grounded(grounded, _time)
	# Expire dodging flag after duration
	if _is_dodging and _time - _last_dodge_time > DODGE_DURATION:
		_is_dodging = false
	# Auto expire dodge window
	if _first_jump_time > -900.0 and _time - _first_jump_time > DODGE_WINDOW and not _has_dodged:
		# Window expired without dodge — treat as consumed (no second jump dodge)
		# Do not auto-reset _has_dodged here; can_dodge will just return false. Keep for telemetry.
		pass
	if auto_poll_input:
		if is_jump_just_pressed():
			# If we are within window and have direction, dodge; else ignore (let CarJump handle double jump)
			var dir := get_dodge_direction_from_service()
			if dir != Vector2.ZERO and can_dodge_with_dir(dir, _time):
				return do_dodge(car, dir, _time)
	return false

func _update_grounded(grounded: bool, t: float) -> void:
	if grounded:
		_last_ground_time = t
		if not _is_grounded:
			# Just landed — reset dodge state
			_has_dodged = false
			_is_dodging = false
			_first_jump_time = -999.0
			_dodge_dir = Vector2.ZERO
			_dodge_world_dir = Vector3.ZERO
		_is_grounded = true
	else:
		if _is_grounded:
			_is_grounded = false

func set_grounded(grounded: bool, t: float = -1.0) -> void:
	var tt := _time if t < 0.0 else t
	_update_grounded(grounded, tt)

## Direct setter for first jump time (for tests / determinism harness).
func set_first_jump_time(t: float) -> void:
	_first_jump_time = t
	_has_dodged = false

func reset() -> void:
	_time = 0.0
	_first_jump_time = -999.0
	_last_dodge_time = -999.0
	_has_dodged = false
	_is_dodging = false
	_dodge_dir = Vector2.ZERO
	_dodge_world_dir = Vector3.ZERO
	_is_grounded = false
	_last_ground_time = -999.0
	_dodge_count = 0

# ---------------------------------------------------------------------------
# Process car helper — full dodge + jump integration (single call per tick)
# ---------------------------------------------------------------------------

## Poll InputService.jump + move and apply dodge if eligible.
## Returns Dictionary {dodged: bool, dir: Vector2, torque: Vector3, impulse: Vector3}
func process_car(car: RigidBody3D, delta: float, space_state: PhysicsDirectSpaceState3D = null) -> Dictionary:
	_time += delta
	var grounded := false
	if _jump != null and "_is_grounded" in _jump:
		grounded = bool(_jump.get("_is_grounded"))
	else:
		grounded = CarJumpRef.is_grounded(car, space_state)
	_update_grounded(grounded, _time)
	if _is_dodging and _time - _last_dodge_time > DODGE_DURATION:
		_is_dodging = false
	if is_jump_just_pressed():
		var dir := get_dodge_direction_from_service()
		if dir != Vector2.ZERO and can_dodge_with_dir(dir, _time):
			var ok := do_dodge(car, dir, _time)
			if ok:
				return {"dodged": true, "dir": dir, "torque": compute_dodge_torque(car, dir), "impulse": compute_dodge_impulse(car, dir)}
	return {"dodged": false, "dir": Vector2.ZERO, "torque": Vector3.ZERO, "impulse": Vector3.ZERO}

# ---------------------------------------------------------------------------
# Validation & telemetry — conventions §11 — budget-aware (<12 calls)
# ---------------------------------------------------------------------------

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(DODGE_WINDOW, 0.15):
		errors.append("DODGE_WINDOW %.3f != 0.15" % DODGE_WINDOW)
	if DODGE_WINDOW <= 0.0 or DODGE_WINDOW > 0.5:
		errors.append("DODGE_WINDOW %.3f outside (0,0.5]" % DODGE_WINDOW)
	if not is_equal_approx(FLIP_WINDOW, DODGE_WINDOW):
		errors.append("FLIP_WINDOW %.3f != DODGE_WINDOW %.3f" % [FLIP_WINDOW, DODGE_WINDOW])
	if not is_equal_approx(DODGE_TORQUE, 800.0):
		errors.append("DODGE_TORQUE %.1f != 800.0" % DODGE_TORQUE)
	if DODGE_TORQUE <= 0.0:
		errors.append("DODGE_TORQUE must be > 0")
	if not is_equal_approx(FLIP_TORQUE, DODGE_TORQUE):
		errors.append("FLIP_TORQUE %.1f != DODGE_TORQUE" % FLIP_TORQUE)
	if DODGE_TORQUE < 100.0 or DODGE_TORQUE > 5000.0:
		errors.append("DODGE_TORQUE %.1f outside sane [100,5000]" % DODGE_TORQUE)
	if not is_equal_approx(MASS, CarPhysicsRef.MASS):
		errors.append("MASS %.1f != CarPhysics.MASS %.1f" % [MASS, CarPhysicsRef.MASS])
	if not is_equal_approx(MASS, CarJumpRef.MASS):
		errors.append("MASS %.1f != CarJump.MASS %.1f" % [MASS, CarJumpRef.MASS])
	if not is_equal_approx(MASS, PConfig.MASS_CAR):
		errors.append("MASS %.1f != PConfig.MASS_CAR %.1f" % [MASS, PConfig.MASS_CAR])
	if DODGE_SPEED <= 0.0 or DODGE_SPEED > 20.0:
		errors.append("DODGE_SPEED %.2f outside (0,20]" % DODGE_SPEED)
	if not is_equal_approx(DODGE_IMPULSE_MAG, MASS * DODGE_SPEED):
		errors.append("DODGE_IMPULSE_MAG %.1f != MASS*DODGE_SPEED %.1f" % [DODGE_IMPULSE_MAG, MASS * DODGE_SPEED])
	if DODGE_INPUT_THRESHOLD < 0.0 or DODGE_INPUT_THRESHOLD > 0.5:
		errors.append("DODGE_INPUT_THRESHOLD %.3f outside [0,0.5]" % DODGE_INPUT_THRESHOLD)
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA mismatch")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PC.PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PC PHYSICS_TICK_DELTA mismatch")
	if TimeServiceRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("TimeService PHYSICS_TICKS %d != 120" % TimeServiceRef.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TimeServiceRef.TICK_DELTA, 1.0 / 120.0):
		errors.append("TimeService TICK_DELTA mismatch")
	if CarJumpRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("CarJump PHYSICS_TICKS %d != 120" % CarJumpRef.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(CarJumpRef.DOUBLE_JUMP_WINDOW, 1.5):
		errors.append("CarJump DOUBLE_JUMP_WINDOW != 1.5")
	if DODGE_WINDOW > CarJumpRef.DOUBLE_JUMP_WINDOW:
		errors.append("DODGE_WINDOW %.3f must be <= CarJump DOUBLE_JUMP_WINDOW %.3f" % [DODGE_WINDOW, CarJumpRef.DOUBLE_JUMP_WINDOW])
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != -1 and ps_rate != 120:
		errors.append("project.godot ticks %d != 120" % ps_rate)
	# Input mapping sanity
	var dir_fwd := dodge_direction_from_move_vector(Vector2(0, -1))
	if dir_fwd == Vector2.ZERO or not is_equal_approx(dir_fwd.length(), 1.0):
		errors.append("dodge_direction forward should be normalized non-zero")
	var dir_none := dodge_direction_from_move_vector(Vector2.ZERO)
	if dir_none != Vector2.ZERO:
		errors.append("dodge_direction ZERO should be ZERO")
	var dir_small := dodge_direction_from_move_vector(Vector2(0.05, 0.05))
	if dir_small != Vector2.ZERO:
		errors.append("dodge_direction small input should be ZERO (threshold)")
	# Torque sanity
	var t_fwd := local_dodge_torque(Vector2(0, -1))
	if t_fwd.length() < 799.0 or t_fwd.length() > 801.0:
		errors.append("local_dodge_torque forward length %.1f != 800" % t_fwd.length())
	var t_side := local_dodge_torque(Vector2(1, 0))
	if t_side.length() < 799.0 or t_side.length() > 801.0:
		errors.append("local_dodge_torque side length %.1f != 800" % t_side.length())
	var t_diag := local_dodge_torque(Vector2(0.707, -0.707))
	if t_diag.length() < 799.0 or t_diag.length() > 801.0:
		errors.append("local_dodge_torque diag length %.1f != 800 (must normalize)" % t_diag.length())
	# Window logic sanity
	var d := CarDodge.new()
	d._time = 0.2
	d._first_jump_time = 0.1
	d._is_grounded = false
	d._has_dodged = false
	d._last_dodge_time = -999.0
	if not d.can_dodge(0.2, Vector2(1, 0)):
		errors.append("can_dodge should be true within window with dir")
	if d.can_dodge(0.3, Vector2(1, 0)):
		errors.append("can_dodge should be false after window (0.3 > 0.1+0.15)")
	if d.can_dodge(0.15, Vector2.ZERO):
		errors.append("can_dodge should be false without dir")
	d._has_dodged = true
	if d.can_dodge(0.12, Vector2(1, 0)):
		errors.append("can_dodge should be false after already dodged")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"dodge_window": DODGE_WINDOW,
		"flip_window": FLIP_WINDOW,
		"dodge_torque": DODGE_TORQUE,
		"flip_torque": FLIP_TORQUE,
		"dodge_speed": DODGE_SPEED,
		"dodge_impulse_mag": DODGE_IMPULSE_MAG,
		"mass": MASS,
		"dodge_input_threshold": DODGE_INPUT_THRESHOLD,
		"input_deadzone": INPUT_DEADZONE,
		"cooldown": COOLDOWN,
		"dodge_duration": DODGE_DURATION,
		"physics_tick_hz": PHYSICS_TICKS_PER_SECOND,
		"physics_tick_delta": PHYSICS_TICK_DELTA,
		"tick_delta": TICK_DELTA,
	}

func debug_export_instance() -> Dictionary:
	var d := CarDodge.debug_export()
	d["time"] = _time
	d["first_jump_time"] = _first_jump_time
	d["last_dodge_time"] = _last_dodge_time
	d["has_dodged"] = _has_dodged
	d["is_dodging"] = _is_dodging
	d["dodge_dir"] = _dodge_dir
	d["dodge_world_dir"] = _dodge_world_dir
	d["is_grounded"] = _is_grounded
	d["dodge_count"] = _dodge_count
	d["can_dodge_now"] = can_dodge(_time, get_move_vector())
	return d

static func perf_mark() -> Dictionary:
	return {"scope": "CarDodge", "tick_hz": PHYSICS_TICKS_PER_SECOND, "dodge_window": DODGE_WINDOW, "torque": DODGE_TORQUE, "speed": DODGE_SPEED}

func perf_mark_instance() -> Dictionary:
	return {"scope": "CarDodge", "tick_hz": PHYSICS_TICKS_PER_SECOND, "has_dodged": _has_dodged, "is_dodging": _is_dodging, "dodge_count": _dodge_count}
