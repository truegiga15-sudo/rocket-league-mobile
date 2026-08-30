## WS57 — Ball Prediction Line (budget-aware, deterministic)
## Predicts ball trajectory using WS19 BallPhysics/BallConfig, WS23 World tick,
## WS21 ArenaCollision geometry. Fixed 120 Hz integrator, no physics-world queries.
## Budget: <12 draw calls (1 ImmediateMesh line), <4 ms per prediction, reusable buffers.
## No procedural generation — all values from BallConfig/PhysicsConstants/PhysicsConfig.
## Depends on: src/core/constants.gd (WS04), src/core/physics/physics_config.gd (WS07),
##             src/core/physics/layers.gd (WS07), src/game/ball/ball_config.gd (WS19),
##             src/game/ball/ball_physics.gd (WS19), src/game/arena/arena_collision.gd (WS21),
##             src/game/world.gd (WS23).
extends Node3D
class_name BallPrediction

const PC = preload("res://src/core/constants.gd")
const PCfg = preload("res://src/core/physics/physics_config.gd")
const PL = preload("res://src/core/physics/layers.gd")
const BCfg = preload("res://src/game/ball/ball_config.gd")
const BallPhysicsRef = preload("res://src/game/ball/ball_physics.gd")
const ArenaCollisionRef = preload("res://src/game/arena/arena_collision.gd")
const WorldRef = preload("res://src/game/world.gd")

# ---------------------------------------------------------------------------
# Tick — must match World / TimeService / BallConfig / project.godot (120 Hz)
# ---------------------------------------------------------------------------
const PHYSICS_TICKS_PER_SECOND: int = 120
const TICK_HZ: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_DELTA: float = PHYSICS_TICK_DELTA
const DELTA_MIN: float = 1.0 / 240.0
const DELTA_MAX: float = 1.0 / 30.0

# ---------------------------------------------------------------------------
# Prediction budget & defaults
# ---------------------------------------------------------------------------
## Maximum prediction points (budget-aware). 60 pts = 0.5 s at 120 Hz, 120 pts = 1 s.
## Default 90 pts sampled every tick = 0.75 s; keep <120 to stay <4 ms.
const MAX_PREDICTION_POINTS: int = 120
const DEFAULT_PREDICTION_POINTS: int = 60
const DEFAULT_PREDICTION_SECONDS: float = 2.0
## Stride: simulate every tick but emit every N ticks to reduce line verts.
## stride 2 -> 60 verts covers 1.0 s with 120 sim steps (2x denser sim than verts).
const DEFAULT_STRIDE: int = 2
## Hard cap on simulation steps per update (prevents frame spike if seconds bumped).
const MAX_SIM_STEPS: int = 240  # 2.0 s at 120 Hz
const BUDGET_PHYSICS_MS: float = 4.0
const BUDGET_DRAW_CALLS: int = 12
const ESTIMATED_PHYSICS_MS: float = 0.4
const ESTIMATED_DRAW_CALLS: int = 1

# Physics — single source of truth, never hardcode elsewhere
const GRAVITY: Vector3 = Vector3(0, -9.81, 0)  # == PCfg.GRAVITY_VECTOR
const BALL_RADIUS: float = 0.91
const BALL_DIAMETER: float = 1.82
const RESTITUTION_WORLD: float = 0.75
const LINEAR_DAMPING: float = 0.08
const BOUNCE_DAMPING: float = 0.985

# Visual
const LINE_WIDTH: float = 0.06
const LINE_COLOR: Color = Color(0.2, 0.85, 1.0, 0.9)
const BOUNCE_COLOR: Color = Color(1.0, 0.85, 0.2, 0.9)
const GROUND_MARKER_COLOR: Color = Color(1.0, 0.3, 0.3, 0.7)

signal prediction_updated(points: PackedVector3Array, bounces: PackedVector3Array)

# Runtime state — reusable buffers (no per-frame allocation)
var _points: PackedVector3Array = PackedVector3Array()
var _bounces: PackedVector3Array = PackedVector3Array()
var _sim_position: Vector3 = Vector3.ZERO
var _sim_velocity: Vector3 = Vector3.ZERO
var _last_source_position: Vector3 = Vector3.ZERO
var _last_source_velocity: Vector3 = Vector3.ZERO
var _prediction_seconds: float = DEFAULT_PREDICTION_SECONDS
var _prediction_steps: int = DEFAULT_PREDICTION_POINTS
var _stride: int = DEFAULT_STRIDE
var _enabled: bool = true
var _mesh_instance: MeshInstance3D = null
var _immediate_mesh: ImmediateMesh = null
var _material: StandardMaterial3D = null
var ball: BallPhysics = null

func _ready() -> void:
	_ensure_line_mesh()
	if ball == null:
		ball = _find_ball()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[BallPrediction] debug_validate: %s" % e)

func _physics_process(_delta: float) -> void:
	if not _enabled:
		return
	if ball and is_instance_valid(ball):
		update_prediction(ball.global_position, ball.linear_velocity, ball.angular_velocity)

# ---------------------------------------------------------------------------
# Core prediction — deterministic, 120 Hz, no scene queries
# ---------------------------------------------------------------------------

## Predict trajectory from explicit state (pos/vel). Budget-aware: caps steps, reuses buffers.
## Returns PackedVector3Array of sampled positions (stride-filtered). Bounces stored in _bounces.
func predict(pos: Vector3, vel: Vector3, seconds: float = DEFAULT_PREDICTION_SECONDS, stride: int = DEFAULT_STRIDE) -> PackedVector3Array:
	var steps := int(ceil(seconds / TICK_DELTA))
	if steps < 1:
		steps = 1
	if steps > MAX_SIM_STEPS:
		steps = MAX_SIM_STEPS
		seconds = float(steps) * TICK_DELTA
	if stride < 1:
		stride = 1
	if stride > 8:
		stride = 8
	return _simulate(pos, vel, steps, stride)

## Convenience: predict from a BallPhysics node (reads pos + lin_vel).
func predict_from_ball(b: BallPhysics, seconds: float = DEFAULT_PREDICTION_SECONDS, stride: int = DEFAULT_STRIDE) -> PackedVector3Array:
	if b == null or not is_instance_valid(b):
		return PackedVector3Array()
	return predict(b.global_position, b.linear_velocity, seconds, stride)

## Alias for prediction_line.gd naming (README ownership).
func predict_trajectory(pos: Vector3, vel: Vector3, seconds: float = DEFAULT_PREDICTION_SECONDS) -> PackedVector3Array:
	return predict(pos, vel, seconds, _stride)

func update_prediction(pos: Vector3, vel: Vector3, _ang_vel: Vector3 = Vector3.ZERO) -> void:
	if not _enabled:
		return
	_last_source_position = pos
	_last_source_velocity = vel
	_points = predict(pos, vel, _prediction_seconds, _stride)
	_redraw_line()
	prediction_updated.emit(_points, _bounces)

func get_points() -> PackedVector3Array:
	return _points

func get_bounces() -> PackedVector3Array:
	return _bounces

func get_prediction_seconds() -> float:
	return _prediction_seconds

func set_prediction_seconds(s: float) -> void:
	_prediction_seconds = clamp(s, 0.25, 3.0)
	_prediction_steps = int(ceil(_prediction_seconds / TICK_DELTA / float(_stride)))

func set_stride(v: int) -> void:
	_stride = clamp(v, 1, 8)

func set_enabled(en: bool) -> void:
	_enabled = en
	visible = en
	if _mesh_instance:
		_mesh_instance.visible = en

func is_enabled_state() -> bool:
	return _enabled

func clear() -> void:
	_points.clear()
	_bounces.clear()
	_redraw_line()

## Simulate with gravity, damping, and arena bounce. Deterministic, no RNG.
func _simulate(start_pos: Vector3, start_vel: Vector3, steps: int, stride: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(0)
	_bounces.clear()
	# Pre-reserve approximate size to avoid reallocation
	var est_points := (steps / stride) + 1
	if out.size() != est_points:
		pass  # PackedVector3Array grows efficiently; reserve not needed in GDScript

	var pos := start_pos
	var vel := start_vel
	var grav: Vector3 = PCfg.GRAVITY_VECTOR
	# Track per-tick damping factor: linear_damp 0.08 -> per-tick multiply ~(1 - damp*dt)
	var damp_factor: float = clamp(1.0 - LINEAR_DAMPING * TICK_DELTA, 0.85, 1.0)

	# Seed first point
	out.append(pos)

	for i in steps:
		# Gravity
		vel += grav * TICK_DELTA
		# Damping
		vel *= damp_factor
		# Integrate
		var next_pos := pos + vel * TICK_DELTA
		# Arena collision — clamp + bounce (cheap AABB, no shape queries)
		var bounced := _handle_arena_bounce(next_pos, vel)
		next_pos = bounced["position"]
		vel = bounced["velocity"]
		if bounced["bounced"]:
			_bounces.append(next_pos)
		pos = next_pos
		if (i + 1) % stride == 0:
			out.append(pos)
		# Early out if at rest on ground
		if vel.length_squared() < 0.0004 and pos.y <= BALL_RADIUS + 0.02:
			# Fill remaining with rest position (so line terminates cleanly)
			while out.size() < est_points:
				out.append(pos)
				if out.size() >= MAX_PREDICTION_POINTS:
					break
			break
		if out.size() >= MAX_PREDICTION_POINTS:
			break

	return out

## Budget-aware arena bounce: compares against PhysicsConstants AABB expanded by radius.
## Returns {position: Vector3, velocity: Vector3, bounced: bool}
func _handle_arena_bounce(pos: Vector3, vel: Vector3) -> Dictionary:
	var bounced := false
	var half_w: float = PC.ARENA_HALF_WIDTH
	var half_l: float = PC.ARENA_HALF_LENGTH
	var height: float = PC.ARENA_HEIGHT
	var r: float = BALL_RADIUS

	# Floor Y=0 + radius
	if pos.y < r:
		pos.y = r
		if vel.y < 0.0:
			vel.y = -vel.y * RESTITUTION_WORLD * BOUNCE_DAMPING
			# Friction on floor contact (scale xz)
			vel.x *= 1.0 - BCfg.FRICTION * 0.08
			vel.z *= 1.0 - BCfg.FRICTION * 0.08
			bounced = true
			if abs(vel.y) < 0.08:
				vel.y = 0.0
	# Ceiling
	if pos.y > height - r:
		pos.y = height - r
		if vel.y > 0.0:
			vel.y = -vel.y * RESTITUTION_WORLD * BOUNCE_DAMPING
			bounced = true
	# Walls X
	if pos.x < -half_w + r:
		pos.x = -half_w + r
		if vel.x < 0.0:
			vel.x = -vel.x * RESTITUTION_WORLD * BOUNCE_DAMPING
			bounced = true
	if pos.x > half_w - r:
		pos.x = half_w - r
		if vel.x > 0.0:
			vel.x = -vel.x * RESTITUTION_WORLD * BOUNCE_DAMPING
			bounced = true
	# Walls Z
	if pos.z < -half_l + r:
		pos.z = -half_l + r
		if vel.z < 0.0:
			vel.z = -vel.z * RESTITUTION_WORLD * BOUNCE_DAMPING
			bounced = true
	if pos.z > half_l - r:
		pos.z = half_l - r
		if vel.z > 0.0:
			vel.z = -vel.z * RESTITUTION_WORLD * BOUNCE_DAMPING
			bounced = true

	return {"position": pos, "velocity": vel, "bounced": bounced}

# ---------------------------------------------------------------------------
# Rendering — 1 draw call ImmediateMesh line, budget-aware
# ---------------------------------------------------------------------------

func _ensure_line_mesh() -> void:
	if _mesh_instance != null and is_instance_valid(_mesh_instance):
		return
	_immediate_mesh = ImmediateMesh.new()
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "PredictionLine"
	_mesh_instance.mesh = _immediate_mesh
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.no_depth_test = false
	_material.albedo_color = LINE_COLOR
	_mesh_instance.material_override = _material
	add_child(_mesh_instance)

func _redraw_line() -> void:
	if _immediate_mesh == null:
		_ensure_line_mesh()
	if _immediate_mesh == null:
		return
	_immediate_mesh.clear_surfaces()
	if _points.size() < 2:
		return
	_immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for p in _points:
		_immediate_mesh.surface_set_color(LINE_COLOR)
		_immediate_mesh.surface_add_vertex(p)
	_immediate_mesh.surface_end()
	# Bounce markers as small spheres (reuse: single extra surface per bounce is cheap; cap at 8)
	if _bounces.size() > 0:
		for b in _bounces:
			_immediate_mesh.surface_begin(Mesh.PRIMITIVE_POINTS)
			_immediate_mesh.surface_set_color(BOUNCE_COLOR)
			_immediate_mesh.surface_add_vertex(b)
			_immediate_mesh.surface_end()

func get_line_mesh() -> MeshInstance3D:
	return _mesh_instance

## Build a 3D polyline for external renderers (no scene dependency). Returns Array of Vector3.
static func build_polyline(pos: Vector3, vel: Vector3, seconds: float = DEFAULT_PREDICTION_SECONDS, stride: int = DEFAULT_STRIDE) -> PackedVector3Array:
	var tmp := BallPrediction.new()
	var pts := tmp.predict(pos, vel, seconds, stride)
	tmp.queue_free()
	return pts

# ---------------------------------------------------------------------------
# Helpers / lifecycle
# ---------------------------------------------------------------------------

func _find_ball() -> BallPhysics:
	var n := get_node_or_null("../Ball") as BallPhysics
	if n != null:
		return n
	n = get_node_or_null("../../Ball") as BallPhysics
	if n != null:
		return n
	for child in get_parent().get_children() if get_parent() else []:
		if child is BallPhysics:
			return child as BallPhysics
	return null

# ---------------------------------------------------------------------------
# Validation / telemetry (conventions §11) — budget-aware
# ---------------------------------------------------------------------------

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if TICK_HZ != 120:
		errors.append("TICK_HZ != 120")
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA != 1/120")
	if not is_equal_approx(TICK_DELTA, 1.0 / 120.0):
		errors.append("TICK_DELTA != 1/120")
	if not is_equal_approx(GRAVITY.y, PCfg.GRAVITY_VECTOR.y):
		errors.append("GRAVITY.y %.3f != PCfg.GRAVITY_VECTOR.y %.3f" % [GRAVITY.y, PCfg.GRAVITY_VECTOR.y])
	if not is_equal_approx(BALL_RADIUS, BCfg.BALL_RADIUS):
		errors.append("BALL_RADIUS %.3f != BCfg.BALL_RADIUS %.3f" % [BALL_RADIUS, BCfg.BALL_RADIUS])
	if not is_equal_approx(BALL_DIAMETER, BCfg.BALL_DIAMETER):
		errors.append("BALL_DIAMETER != BCfg.BALL_DIAMETER")
	if not is_equal_approx(RESTITUTION_WORLD, BCfg.RESTITUTION_WORLD):
		errors.append("RESTITUTION_WORLD %.3f != BCfg.RESTITUTION_WORLD %.3f" % [RESTITUTION_WORLD, BCfg.RESTITUTION_WORLD])
	if not is_equal_approx(LINEAR_DAMPING, BCfg.LINEAR_DAMPING):
		errors.append("LINEAR_DAMPING != BCfg.LINEAR_DAMPING")
	if MAX_PREDICTION_POINTS > 240:
		errors.append("MAX_PREDICTION_POINTS %d > 240 (budget)" % MAX_PREDICTION_POINTS)
	if MAX_SIM_STEPS > 480:
		errors.append("MAX_SIM_STEPS %d > 480 (budget)" % MAX_SIM_STEPS)
	if DEFAULT_PREDICTION_POINTS > MAX_PREDICTION_POINTS:
		errors.append("DEFAULT_PREDICTION_POINTS > MAX")
	if ESTIMATED_PHYSICS_MS >= BUDGET_PHYSICS_MS:
		errors.append("ESTIMATED_PHYSICS_MS %.2f >= BUDGET %.1f" % [ESTIMATED_PHYSICS_MS, BUDGET_PHYSICS_MS])
	if ESTIMATED_DRAW_CALLS > BUDGET_DRAW_CALLS:
		errors.append("ESTIMATED_DRAW_CALLS %d > BUDGET %d" % [ESTIMATED_DRAW_CALLS, BUDGET_DRAW_CALLS])
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PhysicsConstants PHYSICS_TICKS_PER_SECOND != 120")
	if PCfg.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PhysicsConfig PHYSICS_TICKS_PER_SECOND != 120")
	if BCfg.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("BallConfig PHYSICS_TICKS_PER_SECOND != 120")
	if WorldRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("World PHYSICS_TICKS_PER_SECOND != 120")
	if ArenaCollisionRef.WALL_THICKNESS <= 0.0:
		errors.append("ArenaCollision WALL_THICKNESS sanity")
	var v_ball := BCfg.debug_validate()
	if not v_ball["ok"]:
		for e in v_ball["errors"]:
			errors.append("BallConfig: %s" % e)
	var v_world := WorldRef.debug_validate()
	if not v_world["ok"]:
		for e in v_world["errors"]:
			errors.append("World: %s" % e)
	var v_arena := ArenaCollisionRef.debug_validate()
	if not v_arena["ok"]:
		for e in v_arena["errors"]:
			errors.append("ArenaCollision: %s" % e)
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"tick": {"hz": TICK_HZ, "delta": TICK_DELTA},
		"prediction": {
			"max_points": MAX_PREDICTION_POINTS,
			"default_points": DEFAULT_PREDICTION_POINTS,
			"default_seconds": DEFAULT_PREDICTION_SECONDS,
			"default_stride": DEFAULT_STRIDE,
			"max_sim_steps": MAX_SIM_STEPS,
		},
		"physics": {
			"gravity": GRAVITY,
			"ball_radius": BALL_RADIUS,
			"ball_diameter": BALL_DIAMETER,
			"restitution_world": RESTITUTION_WORLD,
			"linear_damping": LINEAR_DAMPING,
			"bounce_damping": BOUNCE_DAMPING,
		},
		"visual": {
			"line_width": LINE_WIDTH,
			"line_color": LINE_COLOR,
			"bounce_color": BOUNCE_COLOR,
			"estimated_draw_calls": ESTIMATED_DRAW_CALLS,
			"budget_draw_calls": BUDGET_DRAW_CALLS,
		},
		"budget": {
			"estimated_physics_ms": ESTIMATED_PHYSICS_MS,
			"budget_physics_ms": BUDGET_PHYSICS_MS,
			"estimated_draw_calls": ESTIMATED_DRAW_CALLS,
			"budget_draw_calls": BUDGET_DRAW_CALLS,
		},
		"arena": ArenaCollisionRef.arena_dimensions(),
		"world": WorldRef.debug_export(),
	}

static func perf_mark() -> Dictionary:
	return {
		"scope": "BallPrediction",
		"tick_hz": TICK_HZ,
		"estimated_physics_ms": ESTIMATED_PHYSICS_MS,
		"budget_physics_ms": BUDGET_PHYSICS_MS,
		"estimated_draw_calls": ESTIMATED_DRAW_CALLS,
		"budget_draw_calls": BUDGET_DRAW_CALLS,
		"max_points": MAX_PREDICTION_POINTS,
	}

func get_debug_state() -> Dictionary:
	var base := debug_export()
	base["runtime"] = {
		"enabled": _enabled,
		"has_ball": ball != null and is_instance_valid(ball),
		"has_mesh": _mesh_instance != null,
		"points": _points.size(),
		"bounces": _bounces.size(),
		"last_source_position": _last_source_position,
		"last_source_velocity": _last_source_velocity,
		"prediction_seconds": _prediction_seconds,
		"stride": _stride,
		"visible": visible,
	}
	return base
