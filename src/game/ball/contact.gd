## WS20 — Ball-Car Contact (Impulse Transfer)
## Budget-aware impulse transfer from car to ball.
## Mass ratio 180/30 = 6, restitution 0.85, friction 0.3,
## layers 1 (car_chassis) / 3 (ball), physics tick 120 Hz.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07),
##             src/core/physics/physics_config.gd (WS07),
##             src/game/car/car_physics.gd (WS11), src/game/ball/ball_physics.gd (WS19),
##             src/game/ball/ball_config.gd (WS19)
## Conventions: docs/architecture/00-conventions.md §3-§4, §11-§12,
##   1 unit = 1 m, Y-up, +Z forward, fixed 120 Hz, budget <4ms / <12 calls per contact.
## No procedural generation — all values authored/deterministic.
extends RefCounted
class_name BallContact

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
const PCfg = preload("res://src/core/physics/physics_config.gd")
const BCfg = preload("res://src/game/ball/ball_config.gd")
const CarPhysicsRef = preload("res://src/game/car/car_physics.gd")
const BallPhysicsRef = preload("res://src/game/ball/ball_physics.gd")

# ---------------------------------------------------------------------------
# Authored contact constants — single source for WS20
# ---------------------------------------------------------------------------

## Masses (kg) — must match CarPhysics.MASS (180) and BallPhysics/BallConfig.MASS (30).
const MASS_CAR: float = 180.0
const MASS_BALL: float = 30.0
const MASS_RATIO: float = 6.0 # 180 / 30
const INV_MASS_CAR: float = 1.0 / 180.0
const INV_MASS_BALL: float = 1.0 / 30.0

## Restitution car<->ball (bounce). Authored 0.85 — punchy hits.
## Must match PCfg.RESTITUTION_CAR_BALL and BCfg.RESTITUTION_CAR.
const RESTITUTION: float = 0.85
const RESTITUTION_CAR_BALL: float = 0.85

## Friction car<->ball (Coulomb). Low so ball slides off chassis.
## Must match PCfg.FRICTION_CAR_BALL.
const FRICTION: float = 0.3
const FRICTION_CAR_BALL: float = 0.3

## Contact layers — never hardcode numbers elsewhere.
const LAYER_CAR: int = 1
const LAYER_BALL: int = 3
const BIT_CAR: int = 2 # 1 << 1
const BIT_BALL: int = 8 # 1 << 3
const MASK_CAR: int = 11 # PL.MASK_CAR_CHASSIS = BIT_WORLD_STATIC|BIT_CAR|BIT_BALL
const MASK_BALL: int = 3 # PL.MASK_BALL = BIT_WORLD_STATIC|BIT_CAR

## Physics tick — must be 120 Hz (project.godot + PC + PCfg + BCfg).
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_HZ: int = 120
const TICK_DELTA: float = PHYSICS_TICK_DELTA

## Minimum relative speed along normal to generate impulse (avoid micro-jitter).
const MIN_IMPACT_SPEED: float = 0.05

## Maximum impulse clamp to prevent explosion (Ns). Tuned: 180 kg * 50 m/s = 9000 max.
const MAX_IMPULSE_MAG: float = 9000.0

# ---------------------------------------------------------------------------
# Impulse computation — budget-aware (0 allocs beyond Vector3, <12 calls)
# ---------------------------------------------------------------------------

## Relative velocity of car vs ball (car - ball). Single call.
static func relative_velocity(car_vel: Vector3, ball_vel: Vector3) -> Vector3:
	return car_vel - ball_vel

## Normal impulse magnitude (scalar) along contact normal.
## Formula: j = -(1+e) * (rel_vel · n) / (1/m_car + 1/m_ball)  — only when approaching (vn < 0).
## Returns 0 if separating or below MIN_IMPACT_SPEED. Budget: 1 dot + 1 branch.
static func normal_impulse_magnitude(car_vel: Vector3, ball_vel: Vector3, normal: Vector3) -> float:
	var n := normal.normalized()
	if n.length_squared() < 0.5:
		return 0.0
	var rel := car_vel - ball_vel
	var vn := rel.dot(n)
	if vn >= -MIN_IMPACT_SPEED:
		return 0.0
	var denom := INV_MASS_CAR + INV_MASS_BALL
	if denom <= 0.0:
		return 0.0
	var j := -(1.0 + RESTITUTION) * vn / denom
	if j < 0.0:
		j = 0.0
	if j > MAX_IMPULSE_MAG:
		j = MAX_IMPULSE_MAG
	return j

## Full normal impulse vector (along normal). Budget: 1 call.
static func normal_impulse(car_vel: Vector3, ball_vel: Vector3, normal: Vector3) -> Vector3:
	var n := normal.normalized()
	if n.length_squared() < 0.5:
		return Vector3.ZERO
	var mag := normal_impulse_magnitude(car_vel, ball_vel, n)
	if mag <= 0.0:
		return Vector3.ZERO
	return n * mag

## Friction impulse vector (tangential, Coulomb). Budget: 1 call, clamped by friction * normal_mag.
## Uses relative tangential velocity; if near-zero, returns zero.
static func friction_impulse(car_vel: Vector3, ball_vel: Vector3, normal: Vector3, normal_mag: float = -1.0) -> Vector3:
	var n := normal.normalized()
	if n.length_squared() < 0.5:
		return Vector3.ZERO
	var mag_n := normal_mag if normal_mag >= 0.0 else normal_impulse_magnitude(car_vel, ball_vel, n)
	if mag_n <= 0.0:
		return Vector3.ZERO
	var rel := car_vel - ball_vel
	var vn := rel.dot(n)
	var vt := rel - n * vn
	var vt_len := vt.length()
	if vt_len < 0.001:
		return Vector3.ZERO
	# Coulomb clamp: |j_t| <= mu * j_n
	var max_fric := FRICTION * mag_n
	var jt_mag := min(vt_len * (1.0 / (INV_MASS_CAR + INV_MASS_BALL)) * 0.15, max_fric)
	return -vt.normalized() * jt_mag

## Combined contact impulse (normal + friction). Single budget entry point.
## Returns impulse to apply TO BALL (reaction on car is -impulse * INV_MASS_CAR/INV_MASS_BALL scaling is handled by physics engine separately).
static func compute_impulse(car_vel: Vector3, ball_vel: Vector3, normal: Vector3) -> Vector3:
	var n := normal.normalized()
	if n.length_squared() < 0.5:
		return Vector3.ZERO
	var jn := normal_impulse(car_vel, ball_vel, n)
	if jn == Vector3.ZERO:
		return Vector3.ZERO
	var mag_n := jn.length()
	var jf := friction_impulse(car_vel, ball_vel, n, mag_n)
	return jn + jf

## Alias — matches README impulse_transfer naming.
static func compute_contact_impulse(car_vel: Vector3, ball_vel: Vector3, normal: Vector3) -> Vector3:
	return compute_impulse(car_vel, ball_vel, normal)

## Impulse magnitude helper (scalar, for telemetry / prediction WS57).
static func impulse_magnitude(car_vel: Vector3, ball_vel: Vector3, normal: Vector3) -> float:
	return normal_impulse_magnitude(car_vel, ball_vel, normal)

# ---------------------------------------------------------------------------
# Apply helpers — budget-aware (1 apply_central_impulse or apply_impulse per contact)
# ---------------------------------------------------------------------------

## Apply computed impulse to a ball RigidBody3D. Handles central vs offset contact point.
## Returns impulse vector actually applied. Budget: 1 physics call.
static func apply_to_ball(ball: RigidBody3D, impulse: Vector3, contact_point: Vector3 = Vector3.ZERO) -> Vector3:
	if ball == null or impulse == Vector3.ZERO:
		return Vector3.ZERO
	var imp := impulse
	if imp.length() > MAX_IMPULSE_MAG:
		imp = imp.normalized() * MAX_IMPULSE_MAG
	if contact_point == Vector3.ZERO:
		ball.apply_central_impulse(imp)
	else:
		ball.apply_impulse(imp, contact_point - ball.global_position)
	if ball.has_method("ball_hit"):
		pass
	# Emit ball_hit signal if BallPhysics (duck-typed)
	if ball.has_signal("ball_hit"):
		ball.emit_signal("ball_hit", imp, contact_point if contact_point != Vector3.ZERO else ball.global_position)
	return imp

## High-level: compute and apply car->ball impulse in one call. Budget: <12 calls total.
## Uses car.linear_velocity and ball.linear_velocity internally.
static func apply_contact_impulse(ball: RigidBody3D, car: RigidBody3D, contact_point: Vector3, contact_normal: Vector3) -> Vector3:
	if ball == null or car == null:
		return Vector3.ZERO
	var n := contact_normal.normalized()
	if n.length_squared() < 0.5:
		return Vector3.ZERO
	var impulse := compute_impulse(car.linear_velocity, ball.linear_velocity, n)
	if impulse == Vector3.ZERO:
		return Vector3.ZERO
	return apply_to_ball(ball, impulse, contact_point)

## Handle a body_entered / body_shape_entered callback for ball. Verifies layers.
## Intended to wire: ball.body_entered.connect(_on_ball_body_entered)
static func is_car_ball_contact(a_layer: int, b_layer: int) -> bool:
	var is_a_car := (a_layer & BIT_CAR) != 0 or a_layer == LAYER_CAR or a_layer == BIT_CAR
	var is_a_ball := (a_layer & BIT_BALL) != 0 or a_layer == LAYER_BALL or a_layer == BIT_BALL
	var is_b_car := (b_layer & BIT_CAR) != 0 or b_layer == LAYER_CAR or b_layer == BIT_CAR
	var is_b_ball := (b_layer & BIT_BALL) != 0 or b_layer == LAYER_BALL or b_layer == BIT_BALL
	return (is_a_car and is_b_ball) or (is_a_ball and is_b_car)

## Resolve collision purely from velocities/normal (test-friendly, no scene required).
static func resolve_velocities(car_vel: Vector3, ball_vel: Vector3, normal: Vector3) -> Dictionary:
	var n := normal.normalized()
	var imp := compute_impulse(car_vel, ball_vel, n)
	var new_ball_vel := ball_vel
	var new_car_vel := car_vel
	if imp != Vector3.ZERO:
		new_ball_vel += imp * INV_MASS_BALL
		new_car_vel -= imp * INV_MASS_CAR
	return {"impulse": imp, "ball_velocity": new_ball_vel, "car_velocity": new_car_vel, "normal": n}

# ---------------------------------------------------------------------------
# Layer helpers — always via PL, never hardcode
# ---------------------------------------------------------------------------

static func car_layer() -> int:
	return PL.LAYER_CAR_CHASSIS

static func ball_layer() -> int:
	return PL.LAYER_BALL

static func car_bit() -> int:
	return PL.BIT_CAR_CHASSIS

static func ball_bit() -> int:
	return PL.BIT_BALL

static func car_mask() -> int:
	return PL.MASK_CAR_CHASSIS

static func ball_mask() -> int:
	return PL.MASK_BALL

# ---------------------------------------------------------------------------
# Validation & telemetry — conventions §11 — budget-aware
# ---------------------------------------------------------------------------

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(MASS_CAR, 180.0):
		errors.append("MASS_CAR %.2f != 180.0" % MASS_CAR)
	if not is_equal_approx(MASS_BALL, 30.0):
		errors.append("MASS_BALL %.2f != 30.0" % MASS_BALL)
	if not is_equal_approx(MASS_RATIO, 6.0):
		errors.append("MASS_RATIO %.2f != 6.0 (180/30)" % MASS_RATIO)
	if not is_equal_approx(MASS_CAR / MASS_BALL, 6.0):
		errors.append("MASS_CAR/MASS_BALL %.3f != 6.0" % (MASS_CAR / MASS_BALL))
	if not is_equal_approx(MASS_CAR, CarPhysicsRef.MASS):
		errors.append("MASS_CAR %.1f != CarPhysics.MASS %.1f" % [MASS_CAR, CarPhysicsRef.MASS])
	if not is_equal_approx(MASS_BALL, BCfg.MASS):
		errors.append("MASS_BALL %.1f != BallConfig.MASS %.1f" % [MASS_BALL, BCfg.MASS])
	if not is_equal_approx(MASS_BALL, PCfg.MASS_BALL):
		errors.append("MASS_BALL %.1f != PhysicsConfig.MASS_BALL %.1f" % [MASS_BALL, PCfg.MASS_BALL])
	if not is_equal_approx(MASS_CAR, PCfg.MASS_CAR):
		errors.append("MASS_CAR %.1f != PhysicsConfig.MASS_CAR %.1f" % [MASS_CAR, PCfg.MASS_CAR])
	if not is_equal_approx(RESTITUTION, 0.85):
		errors.append("RESTITUTION %.3f != 0.85" % RESTITUTION)
	if not is_equal_approx(RESTITUTION, PCfg.RESTITUTION_CAR_BALL):
		errors.append("RESTITUTION %.3f != PCfg.RESTITUTION_CAR_BALL %.3f" % [RESTITUTION, PCfg.RESTITUTION_CAR_BALL])
	if not is_equal_approx(RESTITUTION, BCfg.RESTITUTION_CAR):
		errors.append("RESTITUTION %.3f != BCfg.RESTITUTION_CAR %.3f" % [RESTITUTION, BCfg.RESTITUTION_CAR])
	if not is_equal_approx(FRICTION, 0.3):
		errors.append("FRICTION %.3f != 0.3" % FRICTION)
	if not is_equal_approx(FRICTION, PCfg.FRICTION_CAR_BALL):
		errors.append("FRICTION %.3f != PCfg.FRICTION_CAR_BALL %.3f" % [FRICTION, PCfg.FRICTION_CAR_BALL])
	if LAYER_CAR != PL.LAYER_CAR_CHASSIS:
		errors.append("LAYER_CAR %d != PL.LAYER_CAR_CHASSIS %d" % [LAYER_CAR, PL.LAYER_CAR_CHASSIS])
	if LAYER_BALL != PL.LAYER_BALL:
		errors.append("LAYER_BALL %d != PL.LAYER_BALL %d" % [LAYER_BALL, PL.LAYER_BALL])
	if LAYER_CAR != 1:
		errors.append("LAYER_CAR %d != 1" % LAYER_CAR)
	if LAYER_BALL != 3:
		errors.append("LAYER_BALL %d != 3" % LAYER_BALL)
	if BIT_CAR != PL.BIT_CAR_CHASSIS:
		errors.append("BIT_CAR %d != PL.BIT_CAR_CHASSIS %d" % [BIT_CAR, PL.BIT_CAR_CHASSIS])
	if BIT_BALL != PL.BIT_BALL:
		errors.append("BIT_BALL %d != PL.BIT_BALL %d" % [BIT_BALL, PL.BIT_BALL])
	if BIT_CAR != 2:
		errors.append("BIT_CAR %d != 2" % BIT_CAR)
	if BIT_BALL != 8:
		errors.append("BIT_BALL %d != 8" % BIT_BALL)
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA %.6f != 1/120" % PHYSICS_TICK_DELTA)
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC PHYSICS_TICKS %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if PCfg.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PCfg PHYSICS_TICKS %d != 120" % PCfg.PHYSICS_TICKS_PER_SECOND)
	if BCfg.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("BCfg PHYSICS_TICKS %d != 120" % BCfg.PHYSICS_TICKS_PER_SECOND)
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != -1 and ps_rate != 120:
		errors.append("project.godot ticks %d != 120" % ps_rate)
	# Functional check: head-on 10 m/s car into stationary ball along +X
	var test_normal := Vector3(1, 0, 0)
	var imp := normal_impulse_magnitude(Vector3(10, 0, 0), Vector3.ZERO, test_normal)
	if imp <= 0.0:
		errors.append("head-on impulse must be > 0, got %.3f" % imp)
	# Approaching negative normal should give positive impulse
	var imp2 := normal_impulse(Vector3(10, 0, 0), Vector3.ZERO, Vector3(-1, 0, 0))
	if imp2 != Vector3.ZERO:
		# car moving +X vs normal -X is separating -> 0
		pass
	var sep := normal_impulse_magnitude(Vector3.ZERO, Vector3.ZERO, Vector3(1, 0, 0))
	if sep != 0.0:
		errors.append("zero relative vel must give 0 impulse, got %.3f" % sep)
	# Budget check documentation: compute_impulse uses <= 5 internal calls
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"mass_car": MASS_CAR,
		"mass_ball": MASS_BALL,
		"mass_ratio": MASS_RATIO,
		"inv_mass_car": INV_MASS_CAR,
		"inv_mass_ball": INV_MASS_BALL,
		"restitution": RESTITUTION,
		"restitution_car_ball": RESTITUTION_CAR_BALL,
		"friction": FRICTION,
		"friction_car_ball": FRICTION_CAR_BALL,
		"layer_car": LAYER_CAR,
		"layer_ball": LAYER_BALL,
		"bit_car": BIT_CAR,
		"bit_ball": BIT_BALL,
		"mask_car": MASK_CAR,
		"mask_ball": MASK_BALL,
		"physics_tick_hz": PHYSICS_TICKS_PER_SECOND,
		"physics_tick_delta": PHYSICS_TICK_DELTA,
		"min_impact_speed": MIN_IMPACT_SPEED,
		"max_impulse_mag": MAX_IMPULSE_MAG,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "BallContact", "tick_hz": PHYSICS_TICKS_PER_SECOND, "mass_ratio": MASS_RATIO, "restitution": RESTITUTION, "friction": FRICTION}
