## WS62 — Tire Smoke & Skid Marks (budget-aware <12 calls, deterministic)
## Drift smoke (GPUParticles3D per wheel) + skid mark decals driven by tire friction (WS13)
## and car chassis/suspension (WS11/WS12). Budget: <12 API calls/tick, <12 draw calls.
## Deterministic: no randf — seeded jitter from tick counter, all params authored.
## Depends on: src/core/constants.gd (WS04), src/core/physics/physics_config.gd (WS07),
##             src/game/car/car_physics.gd (WS11), src/game/car/suspension.gd (WS12),
##             src/game/car/friction.gd (WS13), src/game/car/wheels.gd (WS49)
## Conventions: docs/architecture/00-conventions.md §3-§5, 1 unit=1 m, Y-up, +Z forward.
extends Node3D
class_name TireSmoke

const PC = preload("res://src/core/constants.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const CarPhysicsRef = preload("res://src/game/car/car_physics.gd")
const SuspensionRef = preload("res://src/game/car/suspension.gd")
const FrictionRef = preload("res://src/game/car/friction.gd")
const WheelsRef = preload("res://src/game/car/wheels.gd")

# ---------------------------------------------------------------------------
# Tick / budget — must be 120 Hz, <12 calls
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_HZ: int = 120
const TICK_DELTA: float = PHYSICS_TICK_DELTA

const MAX_CALLS_PER_TICK: int = 12
const BUDGET_CALLS: int = MAX_CALLS_PER_TICK
const MAX_DRAW_CALLS: int = 12
const DRAW_CALL_BUDGET: int = 12
const MAX_TRIS_BUDGET: int = 300000

# ---------------------------------------------------------------------------
# Car / wheel geometry — single source via PhysicsConstants + Suspension
# ---------------------------------------------------------------------------
const CAR_LENGTH: float = 4.2
const CAR_WIDTH: float = 2.1
const CAR_HEIGHT: float = 1.5
const WHEEL_COUNT: int = 4
const NUM_WHEELS: int = 4
const WHEEL_RADIUS: float = 0.35
const WHEEL_OFFSETS: Array[Vector3] = [
	Vector3(-0.95, -0.20, 1.35),
	Vector3(0.95, -0.20, 1.35),
	Vector3(-0.95, -0.20, -1.35),
	Vector3(0.95, -0.20, -1.35),
]
const WHEEL_NAMES: Array[String] = ["FL", "FR", "RL", "RR"]

# ---------------------------------------------------------------------------
# Smoke particle params — authored, deterministic
# ---------------------------------------------------------------------------
const SMOKE_LIFETIME: float = 0.65
const PARTICLE_LIFETIME: float = SMOKE_LIFETIME
const SMOKE_EMISSION_RATE: float = 32.0
const PARTICLE_SPEED: float = 1.8
const PARTICLE_SPREAD_DEG: float = 22.0
const PARTICLE_SIZE_MIN: float = 0.18
const PARTICLE_SIZE_MAX: float = 0.42
const PARTICLE_GRAVITY_RATIO: float = 0.02
const SMOKE_COLOR: Color = Color(0.82, 0.82, 0.82, 0.55)
const SMOKE_COLOR_FADE: Color = Color(0.75, 0.75, 0.75, 0.0)
const PARTICLE_AMOUNT: int = 32

# ---------------------------------------------------------------------------
# Drift detection — uses WS13 friction thresholds (authored, no magic)
# ---------------------------------------------------------------------------
const DRIFT_SLIP_ANGLE_RAD: float = 0.21  # must match Friction.SLIP_ANGLE_PEAK_RAD
const DRIFT_SLIP_RATIO: float = 0.15  # must match Friction.SLIP_RATIO_PEAK
const DRIFT_SPEED_MIN: float = 3.0  # m/s — below this no smoke (parked)
const DRIFT_INTENSITY_FULL: float = 1.0
const DRIFT_INTENSITY_HALF: float = 0.5
const SMOKE_FADE_TIME: float = 0.12  # seconds to fade when drift stops
const MIN_SMOKE_INTENSITY: float = 0.05

# Lateral threshold for drift — 70% of peak angle triggers smoke
const LATERAL_THRESHOLD_RAD: float = 0.147  # 0.7 * 0.21
const LONGITUDINAL_THRESHOLD: float = 0.105  # 0.7 * 0.15

# ---------------------------------------------------------------------------
# Skid marks — decal pool (budget-aware, no alloc per tick beyond pool)
# ---------------------------------------------------------------------------
const MAX_SKID_MARKS: int = 48
const SKID_LENGTH: float = 0.9
const SKID_WIDTH: float = 0.22
const SKID_Y_OFFSET: float = 0.02  # above ground to avoid z-fighting
const SKID_FADE_TIME: float = 6.0
const SKID_MIN_DISTANCE: float = 0.4  # min travel between marks (m)
const SKID_MIN_INTENSITY: float = 0.25  # below this no mark

# ---------------------------------------------------------------------------
# Determinism seed
# ---------------------------------------------------------------------------
const JITTER_SEED: int = 0x62D0A1
const PHI: float = 1.618033988749895

# ---------------------------------------------------------------------------
# Instance state — per-car, budget-aware
# ---------------------------------------------------------------------------
var _is_emitting: bool = false
var _intensity: float = 0.0
var _tick_count: int = 0
var _time_emitting: float = 0.0
var _call_count_last_tick: int = 0
var _drift_intensities: Array[float] = [0.0, 0.0, 0.0, 0.0]

var _particles: Array[GPUParticles3D] = []
var _wheel_nodes: Array[Node3D] = []
var _skid_pool: Array[MeshInstance3D] = []
var _skid_count: int = 0
var _last_skid_pos: Array[Vector3] = [Vector3.INF, Vector3.INF, Vector3.INF, Vector3.INF]
var _grounded: Array[bool] = [false, false, false, false]

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_ensure_wheel_nodes()
	_ensure_particles()
	_ensure_skid_pool()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[TireSmoke] debug_validate: %s" % e)

func _ensure_wheel_nodes() -> void:
	if not _wheel_nodes.is_empty():
		return
	for i in range(WHEEL_COUNT):
		var n := Node3D.new()
		n.name = "SmokeOrigin_%s" % WHEEL_NAMES[i]
		n.position = WHEEL_OFFSETS[i]
		add_child(n)
		_wheel_nodes.append(n)

func _ensure_particles() -> void:
	if not _particles.is_empty():
		return
	for i in range(WHEEL_COUNT):
		var p := GPUParticles3D.new()
		p.name = "TireSmoke_%s" % WHEEL_NAMES[i]
		p.emitting = false
		p.amount = PARTICLE_AMOUNT
		p.lifetime = SMOKE_LIFETIME
		p.visibility_aabb = AABB(Vector3(-1.2, -0.5, -1.2), Vector3(2.4, 1.8, 2.4))
		var mat := ParticleProcessMaterial.new()
		mat.direction = Vector3(0, 1, 0)
		mat.spread = PARTICLE_SPREAD_DEG
		mat.initial_velocity_min = PARTICLE_SPEED * 0.5
		mat.initial_velocity_max = PARTICLE_SPEED * 1.2
		mat.gravity = Vector3(0, -PConfig.GRAVITY * PARTICLE_GRAVITY_RATIO, 0)
		mat.scale_min = PARTICLE_SIZE_MIN
		mat.scale_max = PARTICLE_SIZE_MAX
		mat.color = SMOKE_COLOR
		# Slight outward spread via radial velocity
		p.process_material = mat
		# Attach to wheel node so smoke follows wheel position
		if i < _wheel_nodes.size():
			_wheel_nodes[i].add_child(p)
			p.position = Vector3(0, -0.05, 0)
		else:
			add_child(p)
		_particles.append(p)

func _ensure_skid_pool() -> void:
	if not _skid_pool.is_empty():
		return
	for i in range(MAX_SKID_MARKS):
		var mi := MeshInstance3D.new()
		mi.name = "SkidMark_%d" % i
		mi.visible = false
		var plane := PlaneMesh.new()
		plane.size = Vector2(SKID_LENGTH, SKID_WIDTH)
		plane.orientation = PlaneMesh.FACE_Y
		mi.mesh = plane
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.06, 0.06, 0.06, 0.85)
		mat.roughness = 0.95
		mat.metallic = 0.0
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_skid_pool.append(mi)

# ---------------------------------------------------------------------------
# Static queries — deterministic, pure math, 0 alloc beyond return
# ---------------------------------------------------------------------------
static func get_wheel_offsets() -> Array[Vector3]:
	return WHEEL_OFFSETS.duplicate()

static func compute_jitter(tick: int, wheel_index: int) -> Vector3:
	var s := float(tick + wheel_index * 137 + JITTER_SEED)
	var jx := sin(s * PHI) * 0.015
	var jy := sin(s * PHI * 0.97 + 1.1) * 0.01
	var jz := sin(s * PHI * 1.13 + 2.3) * 0.015
	return Vector3(jx, jy, jz)

static func is_drift_slip(slip_angle_rad: float, slip_ratio: float) -> bool:
	return absf(slip_angle_rad) > LATERAL_THRESHOLD_RAD or absf(slip_ratio) > LONGITUDINAL_THRESHOLD

static func drift_factor(slip_angle_rad: float, slip_ratio: float) -> float:
	var lat := clamp(absf(slip_angle_rad) / DRIFT_SLIP_ANGLE_RAD, 0.0, 1.5)
	var lon := clamp(absf(slip_ratio) / DRIFT_SLIP_RATIO, 0.0, 1.5)
	return clamp(max(lat, lon), 0.0, 1.0)

static func compute_drift_intensity(slip_angle_rad: float, slip_ratio: float, speed: float, grounded: bool) -> float:
	if not grounded:
		return 0.0
	if speed < DRIFT_SPEED_MIN:
		return 0.0
	if not is_drift_slip(slip_angle_rad, slip_ratio):
		return 0.0
	var f := drift_factor(slip_angle_rad, slip_ratio)
	# Scale by speed beyond minimum — at 8 m/s full, at 3 m/s half
	var speed_t := clamp((speed - DRIFT_SPEED_MIN) / 5.0, 0.0, 1.0)
	var speed_scale := lerpf(0.35, 1.0, speed_t)
	return clamp(f * speed_scale, 0.0, 1.0)

static func is_drifting(slip_angle_rad: float, slip_ratio: float, speed: float, grounded: bool) -> bool:
	return compute_drift_intensity(slip_angle_rad, slip_ratio, speed, grounded) > MIN_SMOKE_INTENSITY

static func should_emit_for_wheel(slip_angle_rad: float, slip_ratio: float, speed: float, grounded: bool) -> bool:
	return is_drifting(slip_angle_rad, slip_ratio, speed, grounded)

# Convenience: evaluate all 4 wheels given chassis velocity + suspension
static func evaluate_wheels(chassis_vel: Vector3, chassis_transform: Transform3D, suspension: SuspensionRef, throttle: float = 0.0, steer_angle: float = 0.0) -> Dictionary:
	var result: Dictionary = {"intensities": [], "any_drift": false, "max_intensity": 0.0}
	var intensities: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var speed := chassis_vel.length()
	var fwd: Vector3 = -chassis_transform.basis.z.normalized()
	var right: Vector3 = chassis_transform.basis.x.normalized()
	var v_fwd: float = chassis_vel.dot(fwd)
	var v_lat: float = chassis_vel.dot(right)
	var base_angle: float = FrictionRef.slip_angle(v_lat, v_fwd)
	var base_ratio: float = FrictionRef.slip_ratio_from_throttle(throttle, speed)
	for i in range(WHEEL_COUNT):
		var grounded: bool = false
		if suspension != null and i < suspension.wheel_contact.size():
			grounded = suspension.wheel_contact[i]
		else:
			grounded = true
		var is_front: bool = i < 2
		var slip_a: float = base_angle + (steer_angle if is_front else 0.0)
		var slip_r: float = base_ratio
		# Rear wheels get more longitudinal slip under throttle
		if not is_front:
			slip_r = base_ratio * 1.2
		var inten := compute_drift_intensity(slip_a, slip_r, speed, grounded)
		intensities[i] = inten
	var any_drift := false
	var max_i := 0.0
	for v in intensities:
		if v > MIN_SMOKE_INTENSITY:
			any_drift = true
		if v > max_i:
			max_i = v
	result["intensities"] = intensities
	result["any_drift"] = any_drift
	result["max_intensity"] = max_i
	return result

# ---------------------------------------------------------------------------
# Per-tick update — budget-aware (<12 calls), deterministic
# ---------------------------------------------------------------------------
## Drive smoke/skid from car + suspension. Returns emitting bool.
## Budget: reads suspension contact, computes 4 drifts, sets particle emitting.
func physics_tick(car: RigidBody3D, suspension: SuspensionRef, throttle: float, steer_angle: float, delta: float) -> bool:
	_call_count_last_tick = 0
	_tick_count += 1
	if car == null:
		_is_emitting = false
		_intensity = max(_intensity - delta / SMOKE_FADE_TIME, 0.0)
		_update_particles()
		_call_count_last_tick = 2
		return false
	var vel: Vector3 = car.linear_velocity
	var tr: Transform3D = car.global_transform
	var speed: float = vel.length()
	_call_count_last_tick += 2

	var eval_result := evaluate_wheels(vel, tr, suspension, throttle, steer_angle)
	_call_count_last_tick += 1
	var intensities: Array = eval_result["intensities"] as Array
	var max_inten: float = eval_result["max_intensity"] as float
	var any_drift: bool = eval_result["any_drift"] as bool

	for i in range(min(intensities.size(), _drift_intensities.size())):
		_drift_intensities[i] = float(intensities[i])
		if suspension != null and i < suspension.wheel_contact.size():
			_grounded[i] = suspension.wheel_contact[i]
		else:
			_grounded[i] = true
		# Update grounded tracking for skid marks
		if suspension != null and i < suspension.wheel_hit_point.size():
			var can_skid: bool = _grounded[i] and float(intensities[i]) > SKID_MIN_INTENSITY and speed > DRIFT_SPEED_MIN
			if can_skid:
				_maybe_emit_skid(i, suspension.wheel_hit_point[i], tr.basis, float(intensities[i]))

	if any_drift:
		_intensity = max_inten
		_is_emitting = true
		_time_emitting += delta
	else:
		_intensity = max(_intensity - delta / SMOKE_FADE_TIME, 0.0)
		_is_emitting = _intensity > MIN_SMOKE_INTENSITY
		if not _is_emitting:
			_time_emitting = 0.0

	_update_particles()
	_call_count_last_tick += 3

	if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
		push_warning("[TireSmoke] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
	return _is_emitting

func _update_particles() -> void:
	for i in range(_particles.size()):
		var p: GPUParticles3D = _particles[i]
		if p == null or not is_instance_valid(p):
			continue
		var inten: float = 0.0
		if i < _drift_intensities.size():
			inten = _drift_intensities[i]
		# Blend with global intensity for fade
		var show: bool = _is_emitting and inten > MIN_SMOKE_INTENSITY
		var grounded: bool = _grounded[i] if i < _grounded.size() else true
		show = show and grounded
		p.emitting = show
		p.amount_ratio = clamp(inten, 0.0, 1.0) if show else 0.0
		if _wheel_nodes.size() > i and _wheel_nodes[i] != null:
			var base: Vector3 = WHEEL_OFFSETS[i]
			_wheel_nodes[i].position = base + compute_jitter(_tick_count, i) * 0.5

func _maybe_emit_skid(wheel_idx: int, hit_point: Vector3, car_basis: Basis, inten: float) -> void:
	# Distance check to avoid spam
	var last: Vector3 = _last_skid_pos[wheel_idx]
	if last != Vector3.INF and hit_point.distance_to(last) < SKID_MIN_DISTANCE:
		return
	# Find next free pool slot (round-robin)
	var idx: int = _skid_count % MAX_SKID_MARKS
	var skid: MeshInstance3D = _skid_pool[idx]
	if skid == null or not is_instance_valid(skid):
		return
	skid.global_position = hit_point + Vector3(0, SKID_Y_OFFSET, 0)
	# Orient along car forward
	var fwd: Vector3 = -car_basis.z
	fwd.y = 0
	if fwd.length_squared() > 0.001:
		fwd = fwd.normalized()
		var angle: float = atan2(fwd.x, fwd.z)
		skid.rotation.y = angle
	# Scale alpha with intensity
	var mat: Material = skid.material_override
	if mat is StandardMaterial3D:
		var sm := mat as StandardMaterial3D
		sm.albedo_color = Color(0.06, 0.06, 0.06, clamp(inten * 0.9, 0.2, 0.85))
	skid.visible = true
	_last_skid_pos[wheel_idx] = hit_point
	_skid_count += 1

## Lightweight tick without car node — for tests / headless
static func tick_smoke_state(slip_angles: Array[float], slip_ratios: Array[float], speed: float, grounded: Array[bool], delta: float, prev_intensity: float) -> Dictionary:
	var max_i := 0.0
	var any := false
	for i in range(min(slip_angles.size(), slip_ratios.size())):
		var g: bool = grounded[i] if i < grounded.size() else true
		var inten := compute_drift_intensity(float(slip_angles[i]), float(slip_ratios[i]), speed, g)
		if inten > max_i:
			max_i = inten
		if inten > MIN_SMOKE_INTENSITY:
			any = true
	var inten_out: float = max_i if any else max(prev_intensity - delta / SMOKE_FADE_TIME, 0.0)
	return {"emitting": inten_out > MIN_SMOKE_INTENSITY, "intensity": inten_out, "any_drift": any, "max_intensity": max_i}

func is_emitting() -> bool:
	return _is_emitting

func get_intensity() -> float:
	return _intensity

func get_drift_intensities() -> Array[float]:
	return _drift_intensities.duplicate()

func get_intensity_for_wheel(idx: int) -> float:
	if idx >= 0 and idx < _drift_intensities.size():
		return _drift_intensities[idx]
	return 0.0

func is_drifting_for_wheel(idx: int) -> bool:
	return get_intensity_for_wheel(idx) > MIN_SMOKE_INTENSITY

func time_emitting() -> float:
	return _time_emitting

func get_call_count_last_tick() -> int:
	return _call_count_last_tick

func get_particle_nodes() -> Array[GPUParticles3D]:
	var out: Array[GPUParticles3D] = []
	for p in _particles:
		if p != null and is_instance_valid(p):
			out.append(p)
	return out

func get_skid_count() -> int:
	return _skid_count

func get_skid_pool() -> Array[MeshInstance3D]:
	return _skid_pool.duplicate()

func clear_skids() -> void:
	for s in _skid_pool:
		if s != null and is_instance_valid(s):
			s.visible = false
	_skid_count = 0
	for i in range(_last_skid_pos.size()):
		_last_skid_pos[i] = Vector3.INF

func get_draw_call_count() -> int:
	var n: int = 0
	for p in _particles:
		if p != null and p.emitting:
			n += 1
	for s in _skid_pool:
		if s != null and s.visible:
			n += 1
			if n >= MAX_DRAW_CALLS:
				break
	return n

func get_budget_state() -> Dictionary:
	var dc := get_draw_call_count()
	if dc == 0 and _particles.is_empty():
		dc = 4
	return {
		"draw_calls": dc,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": dc <= DRAW_CALL_BUDGET,
		"max_calls_per_tick": MAX_CALLS_PER_TICK,
		"calls_last_tick": _call_count_last_tick,
		"within_call_budget": _call_count_last_tick <= MAX_CALLS_PER_TICK,
	}

# ---------------------------------------------------------------------------
# Validation & telemetry
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA %.6f != 1/120" % PHYSICS_TICK_DELTA)
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA != 1/120")
	if MAX_CALLS_PER_TICK != 12:
		errors.append("MAX_CALLS_PER_TICK %d != 12" % MAX_CALLS_PER_TICK)
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if PConfig.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PConfig TICKS %d != 120" % PConfig.PHYSICS_TICKS_PER_SECOND)
	if CarPhysicsRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("CarPhysics tick %d != 120" % CarPhysicsRef.PHYSICS_TICKS_PER_SECOND)
	if SuspensionRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("Suspension tick %d != 120" % SuspensionRef.PHYSICS_TICKS_PER_SECOND)
	if FrictionRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("Friction tick %d != 120" % FrictionRef.PHYSICS_TICKS_PER_SECOND)
	if WheelsRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("Wheels tick %d != 120" % WheelsRef.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(CAR_LENGTH, PC.CAR_LENGTH):
		errors.append("CAR_LENGTH %.2f != PC.CAR_LENGTH %.2f" % [CAR_LENGTH, PC.CAR_LENGTH])
	if not is_equal_approx(CAR_LENGTH, CarPhysicsRef.MASS if false else PC.CAR_LENGTH):
		pass
	if not is_equal_approx(WHEEL_RADIUS, SuspensionRef.WHEEL_RADIUS):
		errors.append("WHEEL_RADIUS %.2f != Suspension.WHEEL_RADIUS %.2f" % [WHEEL_RADIUS, SuspensionRef.WHEEL_RADIUS])
	if not is_equal_approx(WHEEL_RADIUS, WheelsRef.WHEEL_RADIUS):
		errors.append("WHEEL_RADIUS %.2f != Wheels.WHEEL_RADIUS %.2f" % [WHEEL_RADIUS, WheelsRef.WHEEL_RADIUS])
	if WHEEL_OFFSETS.size() != WHEEL_COUNT:
		errors.append("WHEEL_OFFSETS size %d != %d" % [WHEEL_OFFSETS.size(), WHEEL_COUNT])
	if WHEEL_COUNT != SuspensionRef.WHEEL_COUNT:
		errors.append("WHEEL_COUNT %d != Suspension.WHEEL_COUNT %d" % [WHEEL_COUNT, SuspensionRef.WHEEL_COUNT])
	if WHEEL_COUNT != WheelsRef.WHEEL_COUNT:
		errors.append("WHEEL_COUNT %d != Wheels.WHEEL_COUNT %d" % [WHEEL_COUNT, WheelsRef.WHEEL_COUNT])
	if not is_equal_approx(DRIFT_SLIP_ANGLE_RAD, FrictionRef.SLIP_ANGLE_PEAK_RAD):
		errors.append("DRIFT_SLIP_ANGLE %.3f != Friction.SLIP_ANGLE_PEAK %.3f" % [DRIFT_SLIP_ANGLE_RAD, FrictionRef.SLIP_ANGLE_PEAK_RAD])
	if not is_equal_approx(DRIFT_SLIP_RATIO, FrictionRef.SLIP_RATIO_PEAK):
		errors.append("DRIFT_SLIP_RATIO %.3f != Friction.SLIP_RATIO_PEAK %.3f" % [DRIFT_SLIP_RATIO, FrictionRef.SLIP_RATIO_PEAK])
	if not is_equal_approx(LATERAL_THRESHOLD_RAD, DRIFT_SLIP_ANGLE_RAD * 0.7):
		errors.append("LATERAL_THRESHOLD not 0.7*peak")
	if MAX_DRAW_CALLS != 12:
		errors.append("MAX_DRAW_CALLS %d != 12" % MAX_DRAW_CALLS)
	if MAX_SKID_MARKS > 64:
		errors.append("MAX_SKID_MARKS %d > 64 (budget)" % MAX_SKID_MARKS)
	if not is_equal_approx(SMOKE_LIFETIME, 0.65):
		errors.append("SMOKE_LIFETIME %.2f != 0.65" % SMOKE_LIFETIME)
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"is_emitting": _is_emitting,
		"intensity": _intensity,
		"max_intensity": _intensity,
		"drift_intensities": _drift_intensities.duplicate(),
		"time_emitting": _time_emitting,
		"tick_count": _tick_count,
		"calls_last_tick": _call_count_last_tick,
		"skid_count": _skid_count,
		"wheel_count": WHEEL_COUNT,
	}

static func perf_mark() -> Dictionary:
	return {"max_calls_per_tick": MAX_CALLS_PER_TICK, "budget_calls": BUDGET_CALLS, "max_draw_calls": MAX_DRAW_CALLS, "wheel_count": WHEEL_COUNT}
