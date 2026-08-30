## WS19 — Ball Physics (RigidBody3D)
## Authoritative ball RigidBody: mass 30 kg, sphere r=0.91 m (d=1.82 m),
## friction 0.6, bounce 0.75 (world) / 0.85 (car), damping lin 0.08 ang 0.12,
## CCD enabled threshold 0.5, spawn (0,2,0). Integrates with fixed 120 Hz tick.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd &
##             src/core/physics/physics_config.gd (WS07), src/core/time_service.gd (WS05).
extends RigidBody3D
class_name BallPhysics

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
const PCfg = preload("res://src/core/physics/physics_config.gd")
const BCfg = preload("res://src/game/ball/ball_config.gd")

@export var spawn_position: Vector3 = Vector3(0, 2, 0)
@export var reset_on_ready: bool = true

var _initial_spawn: Vector3 = BCfg.SPAWN_POSITION

signal ball_spawned(position: Vector3)
signal ball_reset(position: Vector3)
signal ball_hit(impulse: Vector3, contact_point: Vector3)

func _ready() -> void:
	_configure_physics()
	if reset_on_ready:
		reset_to_spawn()
	contact_monitor = true
	max_contacts_reported = 8
	ball_spawned.emit(global_position)

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	pass

func _configure_physics() -> void:
	mass = BCfg.MASS
	linear_damp = BCfg.LINEAR_DAMPING
	angular_damp = BCfg.ANGULAR_DAMPING
	gravity_scale = 1.0
	collision_layer = BCfg.COLLISION_LAYER
	collision_mask = BCfg.COLLISION_MASK
	continuous_cd = BCfg.CCD_ENABLED
	if BCfg.CCD_ENABLED:
		continuous_cd = true
	if physics_material_override == null:
		physics_material_override = BCfg.physics_material()
	else:
		physics_material_override.friction = BCfg.FRICTION
		physics_material_override.bounce = BCfg.RESTITUTION_WORLD
	can_sleep = true
	sleeping = false
	axis_lock_linear_x = false
	axis_lock_linear_y = false
	axis_lock_linear_z = false
	axis_lock_angular_x = false
	axis_lock_angular_y = false
	axis_lock_angular_z = false
	_ensure_sphere_shape()

func _ensure_sphere_shape() -> void:
	for child in get_children():
		if child is CollisionShape3D:
			var cs := child as CollisionShape3D
			if cs.shape is SphereShape3D:
				var sph := cs.shape as SphereShape3D
				if not is_equal_approx(sph.radius, BCfg.BALL_RADIUS):
					sph.radius = BCfg.BALL_RADIUS
				return
			else:
				var s := SphereShape3D.new()
				s.radius = BCfg.BALL_RADIUS
				cs.shape = s
				return
	var cs_new := CollisionShape3D.new()
	cs_new.name = "CollisionShape3D"
	var sph2 := SphereShape3D.new()
	sph2.radius = BCfg.BALL_RADIUS
	cs_new.shape = sph2
	add_child(cs_new)

func reset_to_spawn() -> void:
	reset_state(BCfg.SPAWN_POSITION, BCfg.SPAWN_LINEAR_VELOCITY, BCfg.SPAWN_ANGULAR_VELOCITY)

func reset_state(pos: Vector3, lin_vel: Vector3 = Vector3.ZERO, ang_vel: Vector3 = Vector3.ZERO) -> void:
	global_position = pos
	linear_velocity = lin_vel
	angular_velocity = ang_vel
	sleeping = false
	ball_reset.emit(pos)

func kickoff_spawn() -> void:
	reset_to_spawn()

func teleport(pos: Vector3) -> void:
	reset_state(pos, linear_velocity, angular_velocity)

func apply_ball_impulse(impulse: Vector3, contact_point: Vector3 = Vector3.ZERO) -> void:
	if contact_point == Vector3.ZERO:
		apply_central_impulse(impulse)
	else:
		apply_impulse(impulse, contact_point - global_position)
	ball_hit.emit(impulse, contact_point if contact_point != Vector3.ZERO else global_position)

func set_spin(angular_vel: Vector3) -> void:
	angular_velocity = angular_vel

func add_spin(spin_delta: Vector3) -> void:
	angular_velocity += spin_delta

func get_spin() -> Vector3:
	return angular_velocity

func get_spin_axis() -> Vector3:
	return BCfg.spin_axis(angular_velocity)

func get_spin_rate_rad() -> float:
	return BCfg.spin_rate_rad_per_s(angular_velocity)

func get_speed() -> float:
	return linear_velocity.length()

func is_at_rest(linear_eps: float = 0.05, angular_eps: float = 0.05) -> bool:
	return linear_velocity.length_squared() < linear_eps * linear_eps and angular_velocity.length_squared() < angular_eps * angular_eps

func get_radius() -> float:
	return BCfg.BALL_RADIUS

func get_diameter() -> float:
	return BCfg.BALL_DIAMETER

func get_mass() -> float:
	return mass

func get_restitution_world() -> float:
	return BCfg.RESTITUTION_WORLD

func get_restitution_car() -> float:
	return BCfg.RESTITUTION_CAR

func get_friction() -> float:
	return BCfg.FRICTION

func snapshot() -> Dictionary:
	return {
		"position": BCfg.quantize_position(global_position),
		"linear_velocity": BCfg.quantize_velocity(linear_velocity),
		"angular_velocity": BCfg.quantize_velocity(angular_velocity),
		"mass": mass,
		"timestamp_tick": -1,
	}

func snapshot_with_tick(tick: int) -> Dictionary:
	var s := snapshot()
	s["timestamp_tick"] = tick
	return s

func debug_export() -> Dictionary:
	var base := BCfg.debug_export()
	base["node"] = {
		"name": name,
		"global_position": global_position,
		"linear_velocity": linear_velocity,
		"angular_velocity": angular_velocity,
		"mass_runtime": mass,
		"linear_damp_runtime": linear_damp,
		"angular_damp_runtime": angular_damp,
		"collision_layer_runtime": collision_layer,
		"collision_mask_runtime": collision_mask,
		"continuous_cd_runtime": continuous_cd,
		"contact_monitor_runtime": contact_monitor,
		"gravity_scale_runtime": gravity_scale,
		"physics_material_bounce": physics_material_override.bounce if physics_material_override else -1.0,
		"physics_material_friction": physics_material_override.friction if physics_material_override else -1.0,
		"is_at_rest": is_at_rest(),
		"speed": get_speed(),
	}
	base["physics_config"] = PCfg.debug_export()
	base["layers"] = PL.debug_export()
	return base

func perf_mark() -> Dictionary:
	return {"scope": "BallPhysics", "speed": get_speed(), "spin_rate": get_spin_rate_rad(), "is_at_rest": is_at_rest(), "layer": PL.LAYER_BALL}

func validate_runtime() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(mass, BCfg.MASS):
		errors.append("mass %.3f != BallConfig.MASS %.3f" % [mass, BCfg.MASS])
	if not is_equal_approx(linear_damp, BCfg.LINEAR_DAMPING):
		errors.append("linear_damp %.3f != %.3f" % [linear_damp, BCfg.LINEAR_DAMPING])
	if not is_equal_approx(angular_damp, BCfg.ANGULAR_DAMPING):
		errors.append("angular_damp %.3f != %.3f" % [angular_damp, BCfg.ANGULAR_DAMPING])
	if collision_layer != BCfg.COLLISION_LAYER:
		errors.append("collision_layer %d != %d" % [collision_layer, BCfg.COLLISION_LAYER])
	if collision_mask != BCfg.COLLISION_MASK:
		errors.append("collision_mask %d != %d" % [collision_mask, BCfg.COLLISION_MASK])
	if continuous_cd != BCfg.CCD_ENABLED:
		errors.append("continuous_cd %s != %s" % [str(continuous_cd), str(BCfg.CCD_ENABLED)])
	if physics_material_override == null:
		errors.append("physics_material_override is null")
	else:
		if not is_equal_approx(physics_material_override.friction, BCfg.FRICTION):
			errors.append("material friction %.3f != %.3f" % [physics_material_override.friction, BCfg.FRICTION])
		if not is_equal_approx(physics_material_override.bounce, BCfg.RESTITUTION_WORLD):
			errors.append("material bounce %.3f != %.3f" % [physics_material_override.bounce, BCfg.RESTITUTION_WORLD])
	var found_sphere := false
	for child in get_children():
		if child is CollisionShape3D:
			var cs := child as CollisionShape3D
			if cs.shape is SphereShape3D:
				found_sphere = true
				var sph := cs.shape as SphereShape3D
				if not is_equal_approx(sph.radius, BCfg.BALL_RADIUS):
					errors.append("sphere radius %.3f != %.3f" % [sph.radius, BCfg.BALL_RADIUS])
	if not found_sphere:
		errors.append("no SphereShape3D child found")
	if PL.LAYER_BALL != 3:
		errors.append("PL.LAYER_BALL != 3")
	var v := BCfg.debug_validate()
	if not v["ok"]:
		for e in v["errors"]:
			errors.append("BallConfig: " + str(e))
	return {"ok": errors.is_empty(), "errors": errors}
