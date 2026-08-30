## WS13 — Tire Friction (Pacejka-ish lateral/longitudinal curves)
## Pacejka Magic Formula friction for 4 raycast wheels.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07),
##             src/core/physics/physics_config.gd (WS07), src/core/time_service.gd (WS05),
##             src/game/car/suspension.gd (WS12), src/game/car/engine.gd (WS14)
## Conventions: docs/architecture/00-conventions.md §3-§4, 1 unit = 1 m, Y-up, +Z forward.
## Physics tick 120 Hz, raycasts via PhysicsLayers BIT_WHEELS / MASK_WHEELS.
## No procedural generation — all values authored/deterministic. No new physics engine.
## Budget: <4 ms per physics tick for 4 wheels (conventions §12).
extends RefCounted
class_name TireFriction

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const SuspensionRef = preload("res://src/game/car/suspension.gd")
const EngineRef = preload("res://src/game/car/engine.gd")

# ---------------------------------------------------------------------------
# Time / tick — 120 Hz fixed (must match suspension + TimeService)
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Physics layers — never hardcode numbers, always via PhysicsLayers (§4)
# ---------------------------------------------------------------------------
static func get_friction_mask() -> int:
	return PL.MASK_WHEELS

static func get_friction_layer() -> int:
	return PL.BIT_WHEELS

# ---------------------------------------------------------------------------
# Authored friction constants — single source for WS13
# ---------------------------------------------------------------------------

## Peak friction (D) — lateral typically ~1.0 (rubber on asphalt at 1 m scale)
## Load sensitivity handled via mu scaling; D is base mu at nominal load.
const LATERAL_D: float = 1.05
const LONGITUDINAL_D: float = 1.15

## Shape (C) — 1.3-2.4 typical; higher = sharper peak / faster fall-off after.
const LATERAL_C: float = 1.35
const LONGITUDINAL_C: float = 1.65

## Stiffness (B) — controls initial slope. Higher = stiffer response at low slip.
const LATERAL_B: float = 11.0
const LONGITUDINAL_B: float = 13.5

## Curvature (E) — controls peak shape / fall-off. 0..1, near 1 = flat near peak.
const LATERAL_E: float = 0.35
const LONGITUDINAL_E: float = 0.25

## Aliases for API compat (some WS expect these names)
const LATERAL_STIFFNESS: float = LATERAL_B
const LONGITUDINAL_STIFFNESS: float = LONGITUDINAL_B
const LATERAL_SHAPE: float = LATERAL_C
const LONGITUDINAL_SHAPE: float = LONGITUDINAL_C
const LATERAL_PEAK: float = LATERAL_D
const LONGITUDINAL_PEAK: float = LONGITUDINAL_D
const LATERAL_CURVATURE: float = LATERAL_E
const LONGITUDINAL_CURVATURE: float = LONGITUDINAL_E

## Slip scaling — slip angle input in radians, slip ratio in 0..1.
## At 12 deg (~0.21 rad) lateral force peaks; at 0.15 slip ratio longitudinal peaks.
const SLIP_ANGLE_PEAK_RAD: float = 0.21  # ~12 deg
const SLIP_RATIO_PEAK: float = 0.15

## Load sensitivity — mu falls ~8% per doubling of normal load.
const LOAD_SENSITIVITY: float = 0.08

## Nominal wheel load (N) — quarter car 180kg => ~441N per wheel static.
## Used as reference for D scaling; actual load from suspension compression.
const NOMINAL_LOAD: float = 441.0  # MASS(180)*GRAVITY(9.81)/4 * load_scale

## Combined friction (friction ellipse) exponent — 2.0 = circular, <2 flatter.
const ELLIPSE_EXPONENT: float = 2.0

## Damping on friction ramps to avoid jitter at low load / zero slip.
const FRICTION_RAMP_RATE: float = 18.0

## Minimum normal load threshold below which no friction is applied (N).
const MIN_LOAD_FOR_FRICTION: float = 5.0

## Maximum friction force clamp per wheel (N) — prevents explosion at high load.
const MAX_FRICTION_PER_WHEEL: float = 5500.0

## Surface mu multiplier (for different arena materials; default 1.0).
const SURFACE_MU: float = 1.0

# ---------------------------------------------------------------------------
# Pacejka Magic Formula core — budget-aware (no allocations per tick)
# ---------------------------------------------------------------------------

## Pacejka Magic Formula: F = D * sin(C * atan(B*x - E*(B*x - atan(B*x))))
## x: slip (radians for lateral, ratio for longitudinal). Returns normalized -1..1 scaled by D.
static func pacejka(slip: float, B: float, C: float, D: float, E: float) -> float:
	var bx: float = B * slip
	var atan_bx: float = atan(bx)
	var inner: float = bx - E * (bx - atan_bx)
	return D * sin(C * atan(inner))

## Alias used by debug/tests
static func magic_formula(slip: float, B: float, C: float, D: float, E: float) -> float:
	return pacejka(slip, B, C, D, E)

## Lateral normalized friction factor (-1..1) for a given slip angle (rad).
static func lateral_factor(slip_angle_rad: float) -> float:
	# Symmetric; sign follows slip angle sign
	var f: float = pacejka(absf(slip_angle_rad), LATERAL_B, LATERAL_C, LATERAL_D, LATERAL_E)
	return signf(slip_angle_rad) * clamp(f / LATERAL_D, -1.0, 1.0)

## Longitudinal normalized friction factor (-1..1) for a given slip ratio.
static func longitudinal_factor(slip_ratio: float) -> float:
	var f: float = pacejka(absf(slip_ratio), LONGITUDINAL_B, LONGITUDINAL_C, LONGITUDINAL_D, LONGITUDINAL_E)
	return signf(slip_ratio) * clamp(f / LONGITUDINAL_D, -1.0, 1.0)

## Load-sensitive peak scaling: D_eff = D * (1 - LOAD_SENSITIVITY * ln(load/nominal))
static func load_scaled_D(base_D: float, normal_load: float) -> float:
	if normal_load <= 0.0:
		return 0.0
	var ratio: float = clamp(normal_load / NOMINAL_LOAD, 0.1, 4.0)
	var scale: float = 1.0 - LOAD_SENSITIVITY * log(ratio)
	return clamp(base_D * scale, 0.25, 1.6)

## Lateral friction curve sampled at slip angle (alias for external consumers).
static func lateral_friction_curve(slip_angle_rad: float, normal_load: float = NOMINAL_LOAD) -> float:
	var D_eff: float = load_scaled_D(LATERAL_D, normal_load)
	return pacejka(slip_angle_rad, LATERAL_B, LATERAL_C, D_eff, LATERAL_E)

## Longitudinal friction curve sampled at slip ratio.
static func longitudinal_friction_curve(slip_ratio: float, normal_load: float = NOMINAL_LOAD) -> float:
	var D_eff: float = load_scaled_D(LONGITUDINAL_D, normal_load)
	return pacejka(slip_ratio, LONGITUDINAL_B, LONGITUDINAL_C, D_eff, LONGITUDINAL_E)

## Full lateral force (N) for slip angle + normal load.
static func lateral_force(slip_angle_rad: float, normal_load: float, surface_mu: float = SURFACE_MU) -> float:
	if normal_load < MIN_LOAD_FOR_FRICTION:
		return 0.0
	var f: float = lateral_friction_curve(slip_angle_rad, normal_load)
	# Magic formula already includes D_eff; force = f * normal_load (mu analogy scaled)
	# Normalize: f is in -D_eff..D_eff, so force = f * (normal_load / NOMINAL_LOAD) * NOMINAL_LOAD?
	# Simpler: friction force = normalized_factor * mu * normal_load where mu ~1.
	# Our D_eff is mu, so force = D_eff * lateral_factor * normal_load
	# lateral_friction_curve == D_eff * lateral_factor; return that * (normal_load factor? no double-count)
	# To keep units correct: force = curve_value * normal_load scaling is not needed; curve is mu.
	# Instead: factor = lateral_factor(angle); force = factor * D_eff * normal_load
	# But pacejka already returns D_eff*factor, so divide out and multiply by load:
	# We return pacejka scaled to force: mu * N. Since mu = D_eff * factor, force = mu * N
	# pacejka result is mu in same units; multiply by surface_mu and clamp later.
	var mu: float = f  # already D_eff * factor
	var force: float = mu * (normal_load / max(NOMINAL_LOAD, 1.0)) * NOMINAL_LOAD
	# Equivalent to mu * normal_load (since mu already accounts) -> use directly:
	force = f * normal_load / max(load_scaled_D(LATERAL_D, normal_load), 0.25) * load_scaled_D(LATERAL_D, normal_load)
	# Simplify to: mu_force = lateral_factor * D_eff * normal_load
	var fac: float = lateral_factor(slip_angle_rad)
	force = fac * D_eff * normal_load * surface_mu
	return clamp(force, -MAX_FRICTION_PER_WHEEL, MAX_FRICTION_PER_WHEEL)

## Full longitudinal force (N) for slip ratio + normal load.
static func longitudinal_force(slip_ratio: float, normal_load: float, surface_mu: float = SURFACE_MU) -> float:
	if normal_load < MIN_LOAD_FOR_FRICTION:
		return 0.0
	var D_eff: float = load_scaled_D(LONGITUDINAL_D, normal_load)
	var fac: float = longitudinal_factor(slip_ratio)
	var force: float = fac * D_eff * normal_load * surface_mu
	return clamp(force, -MAX_FRICTION_PER_WHEEL, MAX_FRICTION_PER_WHEEL)

# ---------------------------------------------------------------------------
# Slip kinematics helpers
# ---------------------------------------------------------------------------

## Slip angle (rad) from lateral vs forward velocity components at wheel.
## Positive = sliding to right. Budget: single atan2.
static func slip_angle(lateral_vel: float, forward_vel: float) -> float:
	var fwd: float = absf(forward_vel)
	if fwd < 0.3:
		# At near-zero speed, scale lateral_vel directly to avoid singularity
		return clamp(lateral_vel * 0.35, -0.55, 0.55)
	return atan2(lateral_vel, fwd)

## Slip ratio = (wheel_surface_speed - ground_speed) / max(|ground_speed|, wheel_speed_eps)
## Drive slip positive when wheel spins faster than ground.
static func slip_ratio(wheel_angular_vel: float, wheel_radius: float, ground_forward_vel: float) -> float:
	var wheel_lin: float = wheel_angular_vel * wheel_radius
	var denom: float = max(absf(ground_forward_vel), 1.0)
	var sr: float = (wheel_lin - ground_forward_vel) / denom
	return clamp(sr, -1.0, 1.0)

## Simplified slip ratio from throttle/speed when wheel angular vel not tracked.
static func slip_ratio_from_throttle(throttle: float, ground_speed: float) -> float:
	var clamped_t: float = clamp(throttle, -1.0, 1.0)
	if absf(clamped_t) < 0.02:
		return 0.0
	# At low speed high slip; at high speed low slip for same throttle
	var speed_factor: float = clamp(1.0 / max(absf(ground_speed), 2.0), 0.15, 1.0)
	return clamp(clamped_t * 0.22 * speed_factor * 5.0, -0.5, 0.5)

# ---------------------------------------------------------------------------
# Combined friction (friction ellipse) — couples lat/long
# ---------------------------------------------------------------------------

## Combine lateral and longitudinal forces via friction ellipse.
## Returns Vector2(lon_scale, lat_scale) multipliers in 0..1 that keep inside ellipse.
static func ellipse_scales(lat_force: float, lon_force: float, normal_load: float) -> Vector2:
	if normal_load < MIN_LOAD_FOR_FRICTION:
		return Vector2.ZERO
	var max_lat: float = LATERAL_D * normal_load
	var max_lon: float = LONGITUDINAL_D * normal_load
	if max_lat <= 0.0 or max_lon <= 0.0:
		return Vector2.ZERO
	var norm_lat: float = lat_force / max_lat
	var norm_lon: float = lon_force / max_lon
	var combined: float = pow(absf(norm_lat), ELLIPSE_EXPONENT) + pow(absf(norm_lon), ELLIPSE_EXPONENT)
	if combined <= 1.0:
		return Vector2.ONE
	var scale: float = 1.0 / sqrt(combined)
	# pow correction for non-2 exponent approximated via sqrt for budget
	return Vector2(scale, scale)

## Apply ellipse to force pair; returns clamped Vector2(lon, lat)
static func combine_forces(longitudinal: float, lateral: float, normal_load: float) -> Vector2:
	var s: Vector2 = ellipse_scales(lateral, longitudinal, normal_load)
	return Vector2(longitudinal * s.x, lateral * s.y)

# ---------------------------------------------------------------------------
# Per-wheel friction computation — integrates with Suspension normal loads
# ---------------------------------------------------------------------------

## Compute normal load per wheel from suspension compression (N).
## Uses SuspensionRef.spring_force + gravity distribution.
static func normal_load_from_compression(compression: float, is_grounded: bool) -> float:
	if not is_grounded:
		return 0.0
	var f: float = SuspensionRef.spring_force(compression)
	# Spring force is up; add static quarter-weight baseline so compressed wheels bear more
	var static_share: float = PConfig.MASS_CAR * PConfig.GRAVITY / float(SuspensionRef.WHEEL_COUNT)
	# Blend: 60% spring, 40% static share + clamp
	var load: float = max(f, 0.0) * 0.75 + static_share * 0.35
	# At rest compression ~0.05 => load ~= 120-200N; at full compression 0.18 => ~1300N
	# Clamp to sane range so friction doesn't explode
	return clamp(load, 0.0, 2600.0)

## Compute 4-wheel friction forces (world lateral + longitudinal) given chassis state.
## chassis_transform: body transform; chassis_vel: world velocity; yaw_rate: rad/s;
## wheel_contact/compression arrays from suspension; throttle in -1..1; steer rad.
## Returns Array[Vector3] of 4 world-space friction forces to apply at wheel positions.
static func compute_forces(
	chassis_transform: Transform3D,
	chassis_vel: Vector3,
	suspension: SuspensionRef,
	throttle: float = 0.0,
	steer_angle: float = 0.0,
	surface_mu: float = SURFACE_MU
) -> Array[Vector3]:
	var out: Array[Vector3] = []
	out.resize(SuspensionRef.WHEEL_COUNT)
	var fwd: Vector3 = -chassis_transform.basis.z.normalized()
	var right: Vector3 = chassis_transform.basis.x.normalized()
	# Project velocity into chassis frame
	var v_fwd: float = chassis_vel.dot(fwd)
	var v_lat: float = chassis_vel.dot(right)
	# Baseline slip
	var base_slip_angle: float = slip_angle(v_lat, v_fwd)
	var base_slip_ratio: float = slip_ratio_from_throttle(throttle, v_fwd)
	for i in range(SuspensionRef.WHEEL_COUNT):
		if suspension == null or not suspension.wheel_contact[i]:
			out[i] = Vector3.ZERO
			continue
		var n_load: float = normal_load_from_compression(suspension.wheel_compression[i], true)
		if n_load < MIN_LOAD_FOR_FRICTION:
			out[i] = Vector3.ZERO
			continue
		# Front wheels add steer angle to slip
		var is_front: bool = (i == 0 or i == 1)
		var slip_a: float = base_slip_angle + (steer_angle if is_front else 0.0)
		# Rear wheels carry more drive slip; front less if FWD? Assume RWD bias
		var is_rear: bool = (i == 2 or i == 3)
		var drive_scale: float = 1.0 if is_rear else 0.35
		var slip_r: float = base_slip_ratio * drive_scale
		var lat_f: float = lateral_force(slip_a, n_load, surface_mu)
		var lon_f: float = longitudinal_force(slip_r, n_load, surface_mu)
		var combined: Vector2 = combine_forces(lon_f, lat_f, n_load)
		lon_f = combined.x
		lat_f = combined.y
		# Map back to world: lateral along right, longitudinal along fwd
		var world_force: Vector3 = right * (-lat_f) + fwd * lon_f
		out[i] = world_force
	return out

## Apply friction forces to a CarPhysics RigidBody3D (budget-aware, calls Suspension offset loop).
static func apply_to_car(car: RigidBody3D, suspension: SuspensionRef, throttle: float = 0.0, steer_angle: float = 0.0, surface_mu: float = SURFACE_MU) -> Array[Vector3]:
	if car == null or suspension == null:
		return []
	var tr: Transform3D = car.global_transform
	var vel: Vector3 = Vector3.ZERO
	if "linear_velocity" in car:
		vel = car.linear_velocity as Vector3
	var forces: Array[Vector3] = compute_forces(tr, vel, suspension, throttle, steer_angle, surface_mu)
	for i in range(SuspensionRef.WHEEL_COUNT):
		var f: Vector3 = forces[i]
		if f == Vector3.ZERO:
			continue
		var local_off: Vector3 = SuspensionRef.WHEEL_OFFSETS[i]
		var world_pos: Vector3 = tr * local_off
		# Offset from center of mass
		var rel: Vector3 = world_pos - car.global_position
		car.apply_force(f, rel)
	return forces

# ---------------------------------------------------------------------------
# Validation / debug / perf (budget + convention §11)
# ---------------------------------------------------------------------------

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA != 1/120")
	# Cross-validate with suspension + physics config
	if SuspensionRef.PHYSICS_TICKS_PER_SECOND != PHYSICS_TICKS_PER_SECOND:
		errors.append("tick mismatch with SuspensionRef")
	if PC.PHYSICS_TICKS_PER_SECOND != PHYSICS_TICKS_PER_SECOND:
		errors.append("tick mismatch with PhysicsConstants")
	if PL.MASK_WHEELS != (1 << PL.LAYER_WHEELS):
		errors.append("PL.MASK_WHEELS mismatch")
	if get_friction_mask() != PL.MASK_WHEELS:
		errors.append("get_friction_mask != PL.MASK_WHEELS")
	if LATERAL_B <= 0.0 or LONGITUDINAL_B <= 0.0:
		errors.append("B must be > 0")
	if LATERAL_C <= 0.0 or LONGITUDINAL_C <= 0.0:
		errors.append("C must be > 0")
	if LATERAL_D <= 0.0 or LONGITUDINAL_D <= 0.0:
		errors.append("D (peak mu) must be > 0")
	if LATERAL_E < 0.0 or LATERAL_E > 1.0:
		errors.append("LATERAL_E out of [0,1]")
	if LONGITUDINAL_E < 0.0 or LONGITUDINAL_E > 1.0:
		errors.append("LONGITUDINAL_E out of [0,1]")
	if NOMINAL_LOAD <= 0.0:
		errors.append("NOMINAL_LOAD must be > 0")
	if MIN_LOAD_FOR_FRICTION < 0.0:
		errors.append("MIN_LOAD_FOR_FRICTION < 0")
	if MAX_FRICTION_PER_WHEEL <= 0.0:
		errors.append("MAX_FRICTION_PER_WHEEL <= 0")
	# Pacejka sanity: 0 slip => 0 force
	if not is_equal_approx(pacejka(0.0, LATERAL_B, LATERAL_C, LATERAL_D, LATERAL_E), 0.0):
		errors.append("pacejka(0) != 0")
	# At peak slip, factor ~1
	var lat_peak: float = lateral_factor(SLIP_ANGLE_PEAK_RAD)
	if absf(lat_peak) < 0.75 or absf(lat_peak) > 1.05:
		errors.append("lateral_factor at peak out of [0.75,1.05]: %.3f" % lat_peak)
	var lon_peak: float = longitudinal_factor(SLIP_RATIO_PEAK)
	if absf(lon_peak) < 0.75 or absf(lon_peak) > 1.05:
		errors.append("longitudinal_factor at peak out of [0.75,1.05]: %.3f" % lon_peak)
	# Symmetry
	if not is_equal_approx(lateral_factor(0.12), -lateral_factor(-0.12)):
		errors.append("lateral_factor not antisymmetric")
	if not is_equal_approx(longitudinal_factor(0.10), -longitudinal_factor(-0.10)):
		errors.append("longitudinal_factor not antisymmetric")
	# Load scaling monotonic
	if load_scaled_D(LATERAL_D, NOMINAL_LOAD * 2.0) >= load_scaled_D(LATERAL_D, NOMINAL_LOAD):
		errors.append("load_scaled_D should decrease with load")
	# Engine / suspension integration check
	if EngineRef.MAX_SPEED_FORWARD <= 0.0:
		errors.append("EngineRef MAX_SPEED invalid")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"tick_delta": TICK_DELTA,
		"lateral": {"B": LATERAL_B, "C": LATERAL_C, "D": LATERAL_D, "E": LATERAL_E, "peak_rad": SLIP_ANGLE_PEAK_RAD},
		"longitudinal": {"B": LONGITUDINAL_B, "C": LONGITUDINAL_C, "D": LONGITUDINAL_D, "E": LONGITUDINAL_E, "peak_ratio": SLIP_RATIO_PEAK},
		"aliases": {"LATERAL_STIFFNESS": LATERAL_STIFFNESS, "LONGITUDINAL_STIFFNESS": LONGITUDINAL_STIFFNESS},
		"load": {"nominal": NOMINAL_LOAD, "sensitivity": LOAD_SENSITIVITY, "min_for_friction": MIN_LOAD_FOR_FRICTION, "max_per_wheel": MAX_FRICTION_PER_WHEEL},
		"ellipse_exponent": ELLIPSE_EXPONENT,
		"surface_mu": SURFACE_MU,
		"ray_mask": get_friction_mask(),
		"ray_layer": get_friction_layer(),
		"suspension_rest_length": SuspensionRef.REST_LENGTH,
		"suspension_ray_length": SuspensionRef.RAY_LENGTH,
		"engine_max_speed": EngineRef.MAX_SPEED_FORWARD,
	}

static func perf_mark() -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	# Micro-bench: 4 wheels worth of pacejka (budget target < 0.2 ms)
	for i in range(4):
		var _a: float = pacejka(0.12, LATERAL_B, LATERAL_C, LATERAL_D, LATERAL_E)
		var _b: float = pacejka(0.10, LONGITUDINAL_B, LONGITUDINAL_C, LONGITUDINAL_D, LONGITUDINAL_E)
	var dt: float = float(Time.get_ticks_usec() - t0) / 1000.0
	return {"pacejka_8x_ms": dt, "budget_ms": 4.0, "within_budget": dt < 4.0, "ticks_per_second": PHYSICS_TICKS_PER_SECOND}
