## WS07 — Physics Configuration (gravity, friction, restitution, solver)
## Single source of truth for physics tuning. All workstreams MUST import this file;
## never hardcode gravity/friction/restitution elsewhere.
##
## Depends on: src/core/constants.gd (WS04) for units/time and
##             src/core/physics/layers.gd (WS07) for collision matrix.
##
## Units: meters, seconds, m/s (1 unit = 1 m). Gravity in m/s².
## Tick: 120 Hz fixed (project.godot: physics/common/physics_ticks_per_second).
##
## No procedural generation — values here are authored/tuned, not randomized.
extends RefCounted
class_name PhysicsConfig

# ---------------------------------------------------------------------------
# Gravity — tuned to RL-like feel at 1 m = 1 unit scale.
# RL in-engine gravity is ~650 uu/s² (≈ 6.5 m/s² at 100 uu = 1 m), but our
# arena is authored at 1:1 meters (60×40×20 m). At 9.81 m/s² the ball arc
# matches earth parabolas; a 1.1-1.3× multiplier gives snappier RL gameplay.
# Default stays at earth 9.81 for determinism; gameplay WS may apply GRAVITY_SCALE.
# ---------------------------------------------------------------------------
const GRAVITY_EARTH: float = 9.81
const GRAVITY_SCALE: float = 1.0  # gameplay multiplier — bump to 1.15 for RL-like snap
const GRAVITY: float = GRAVITY_EARTH * GRAVITY_SCALE  # effective m/s² (9.81)
const GRAVITY_VECTOR: Vector3 = Vector3(0, -9.81, 0)

## RL-tuned alternative (if gameplay wants heavier feel without editing code):
## Use GRAVITY_RL_TUNED = 13.5 (≈ 650/48) for WS19 ball tuning experiments.
const GRAVITY_RL_TUNED: float = 13.5
const GRAVITY_VECTOR_RL_TUNED: Vector3 = Vector3(0, -13.5, 0)

## Helper to get gravity vector with a custom scale (e.g. low-gravity mutator).
static func gravity_vector(scale: float = GRAVITY_SCALE) -> Vector3:
	return Vector3(0, -GRAVITY_EARTH * scale, 0)

# ---------------------------------------------------------------------------
# Solver / iteration counts — Godot/Jolt 3D defaults, tuned for 120 Hz.
# Higher iterations = more stable stacking/contact at cost of phys ms.
# Budget: physics < 4 ms (conventions §12). These values stay within budget.
# ---------------------------------------------------------------------------
const SOLVER_ITERATIONS: int = 12  # position iterations per step (Godot default 8-16)
const SOLVER_VELOCITY_ITERATIONS: int = 8  # velocity iterations (if exposed)
const CONTACT_SOLVER_BIAS: float = 0.3  # Baumgarte bias factor

## Physics tick linkage (mirrors PhysicsConstants, re-exported for convenience).
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0  # ≈ 0.008333 s

# ---------------------------------------------------------------------------
# Default contact materials — per-pair tuning lives in downstream WS,
# but these are safe defaults so nothing is frictionless/bouncy by accident.
# ---------------------------------------------------------------------------

## Friction coefficients (Coulomb, 0 = ice, 1 = rubber on asphalt).
const DEFAULT_FRICTION: float = 0.8
const FRICTION_WORLD_CAR: float = 0.9  # tire contact (raycast suspension uses curves in WS13)
const FRICTION_WORLD_BALL: float = 0.6
const FRICTION_CAR_BALL: float = 0.3  # low so ball slides off chassis
const FRICTION_BALL_WORLD: float = 0.6  # alias for symmetry

## Restitution (bounciness, 0 = dead, 1 = elastic).
const DEFAULT_RESTITUTION: float = 0.4
const RESTITUTION_WORLD_BALL: float = 0.75  # ball bounces off ground/walls
const RESTITUTION_CAR_BALL: float = 0.85  # punchy hits
const RESTITUTION_WORLD_CAR: float = 0.15  # car doesn't bounce off walls
const RESTITUTION_BALL_BALL: float = 1.0  # not used (single ball), but correct

## Contact bias / damping helpers
const CONTACT_DAMPING: float = 0.05
const CONTACT_BIAS: float = 0.0

# ---------------------------------------------------------------------------
# Rigid body defaults — mass, damping, sleep thresholds
# ---------------------------------------------------------------------------

## Mass (kg) — authored at 1:1 RL ratios (car ~180 kg, ball ~30 kg keeps impulse sane).
const MASS_CAR: float = 180.0
const MASS_BALL: float = 30.0

## Linear / angular damping (0 = no damping, 1 = full stop per second).
const LINEAR_DAMPING_CAR: float = 0.15
const ANGULAR_DAMPING_CAR: float = 0.35
const LINEAR_DAMPING_BALL: float = 0.08
const ANGULAR_DAMPING_BALL: float = 0.12

## Sleep thresholds — let resting bodies sleep to save physics ms.
const SLEEP_LINEAR_THRESHOLD: float = 0.1  # m/s
const SLEEP_ANGULAR_THRESHOLD: float = 0.1  # rad/s
const SLEEP_TIME_THRESHOLD: float = 0.5  # seconds before sleep

## Continuous collision detection (CCD) — required for fast ball.
const CCD_ENABLED_BALL: bool = true
const CCD_MOTION_THRESHOLD_BALL: float = 0.5  # m per step before CCD

# ---------------------------------------------------------------------------
# Arena / world bounds helpers (re-exported from PhysicsConstants for ergonomics)
# ---------------------------------------------------------------------------
const ARENA_FLOOR_Y: float = 0.0
const ARENA_CEILING_Y: float = 20.0

# ---------------------------------------------------------------------------
# Validation / debug (conventions §11)
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if GRAVITY_EARTH <= 0.0:
		errors.append("GRAVITY_EARTH must be > 0")
	if GRAVITY_SCALE <= 0.0:
		errors.append("GRAVITY_SCALE must be > 0")
	if DEFAULT_FRICTION < 0.0 or DEFAULT_FRICTION > 1.5:
		errors.append("DEFAULT_FRICTION out of sane range [0,1.5]")
	if DEFAULT_RESTITUTION < 0.0 or DEFAULT_RESTITUTION > 1.0:
		errors.append("DEFAULT_RESTITUTION must be in [0,1]")
	if SOLVER_ITERATIONS < 1 or SOLVER_ITERATIONS > 64:
		errors.append("SOLVER_ITERATIONS out of range [1,64]")
	if MASS_CAR <= 0.0 or MASS_BALL <= 0.0:
		errors.append("MASS must be > 0")
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND must be 120 (project.godot)")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"gravity": GRAVITY,
		"gravity_vector": GRAVITY_VECTOR,
		"gravity_earth": GRAVITY_EARTH,
		"gravity_scale": GRAVITY_SCALE,
		"gravity_rl_tuned": GRAVITY_RL_TUNED,
		"friction": {
			"default": DEFAULT_FRICTION,
			"world_car": FRICTION_WORLD_CAR,
			"world_ball": FRICTION_WORLD_BALL,
			"car_ball": FRICTION_CAR_BALL,
		},
		"restitution": {
			"default": DEFAULT_RESTITUTION,
			"world_ball": RESTITUTION_WORLD_BALL,
			"car_ball": RESTITUTION_CAR_BALL,
			"world_car": RESTITUTION_WORLD_CAR,
		},
		"solver": {
			"iterations": SOLVER_ITERATIONS,
			"velocity_iterations": SOLVER_VELOCITY_ITERATIONS,
			"bias": CONTACT_SOLVER_BIAS,
		},
		"mass": {"car": MASS_CAR, "ball": MASS_BALL},
		"damping": {
			"car_linear": LINEAR_DAMPING_CAR,
			"car_angular": ANGULAR_DAMPING_CAR,
			"ball_linear": LINEAR_DAMPING_BALL,
			"ball_angular": ANGULAR_DAMPING_BALL,
		},
		"tick": {"hz": PHYSICS_TICKS_PER_SECOND, "delta": PHYSICS_TICK_DELTA},
	}

static func perf_mark() -> Dictionary:
	return {"scope": "PhysicsConfig", "tick_hz": PHYSICS_TICKS_PER_SECOND, "gravity": GRAVITY}
