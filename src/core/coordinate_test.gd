## WS04 — Coordinate / Units / Scale self-test
## Run headless: godot --headless --script res://src/core/coordinate_test.gd
## Or attach as Autoload / instance in a scene and call run_checks().
extends SceneTree

const PC = preload("res://src/core/constants.gd")

func _init() -> void:
	var result := run_checks()
	# Always log deterministically for CI
	for line in result["log"]:
		print(line)
	if result["ok"]:
		print("[WS04] ALL CHECKS PASSED")
	else:
		printerr("[WS04] CHECKS FAILED")
		for e in result["errors"]:
			printerr("  - " + e)
	# Exit code for headless runs
	quit(0 if result["ok"] else 1)

static func run_checks() -> Dictionary:
	var log: Array[String] = []
	var errors: Array[String] = []

	func add_log(msg: String) -> void:
		log.append(msg)

	log.append("[WS04] Coordinate / Units / Scale checks")
	log.append("  Basis: right-handed Y-up +Z forward | 1 unit = 1 m | tick=120Hz")

	# 1) Basis vectors orthonormal & handedness
	var up := PC.UP
	var fwd := PC.FORWARD
	var right := PC.RIGHT
	log.append("  UP=%s FORWARD=%s RIGHT=%s" % [str(up), str(fwd), str(right)])
	if not is_equal_approx(up.length(), 1.0):
		errors.append("UP not unit length")
	if not is_equal_approx(fwd.length(), 1.0):
		errors.append("FORWARD not unit length")
	if not is_equal_approx(right.length(), 1.0):
		errors.append("RIGHT not unit length")
	if not is_equal_approx(up.dot(fwd), 0.0):
		errors.append("UP·FORWARD != 0")
	if not is_equal_approx(up.dot(right), 0.0):
		errors.append("UP·RIGHT != 0")
	if not is_equal_approx(fwd.dot(right), 0.0):
		errors.append("FORWARD·RIGHT != 0")
	# Right-handed: RIGHT cross FORWARD should be -UP? Check RIGHT x UP = -FORWARD etc.
	# For Y-up right-handed (+X right, +Y up, +Z forward): X cross Y = Z? Actually Godot: X cross Y = Z? Check: RIGHT(1,0,0) cross UP(0,1,0) = (0,0,1)=FORWARD => correct.
	var cross := right.cross(up)
	if not cross.is_equal_approx(-fwd):
		# RIGHT cross UP = FORWARD in our mapping, so RIGHT.cross(UP) == FORWARD
		if not right.cross(up).is_equal_approx(fwd):
			errors.append("RIGHT x UP != FORWARD (handedness broken): got %s" % str(right.cross(up)))
	# Explicit: RIGHT x UP == FORWARD for right-handed Y-up
	if not right.cross(up).is_equal_approx(fwd):
		errors.append("Handedness: RIGHT.cross(UP) expected FORWARD, got %s" % str(right.cross(up)))
	else:
		log.append("  Handedness OK: RIGHT x UP = FORWARD")

	# 2) Units identity
	var m := 3.5
	var u: float = PC.meters_to_units(m)
	var m2: float = PC.units_to_meters(u)
	log.append("  Units: %.2f m -> %.2f u -> %.2f m" % [m, u, m2])
	if not is_equal_approx(m, m2):
		errors.append("meters<->units roundtrip failed: %.6f vs %.6f" % [m, m2])
	if not is_equal_approx(PC.UNITS_PER_METER, 1.0):
		errors.append("UNITS_PER_METER != 1.0")
	if not is_equal_approx(PC.METERS_PER_UNIT, 1.0):
		errors.append("METERS_PER_UNIT != 1.0")

	# 3) Time
	log.append("  Physics tick: %d Hz delta=%.6f clamp=[%.6f, %.6f]" % [PC.PHYSICS_TICKS_PER_SECOND, PC.PHYSICS_TICK_DELTA, PC.DELTA_MIN, PC.DELTA_MAX])
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND != 120")
	if not is_equal_approx(PC.PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA mismatch")
	if not is_equal_approx(PC.DELTA_MIN, 1.0 / 240.0):
		errors.append("DELTA_MIN mismatch")
	if not is_equal_approx(PC.DELTA_MAX, 1.0 / 30.0):
		errors.append("DELTA_MAX mismatch")

	# 4) Car
	log.append("  Car size=%s half=%s" % [str(PC.car_size()), str(PC.CAR_HALF_EXTENTS)])
	if not is_equal_approx(PC.CAR_LENGTH, 4.2):
		errors.append("CAR_LENGTH != 4.2")
	if not is_equal_approx(PC.CAR_WIDTH, 2.1):
		errors.append("CAR_WIDTH != 2.1")
	if not is_equal_approx(PC.CAR_HEIGHT, 1.5):
		errors.append("CAR_HEIGHT != 1.5")

	# 5) Ball
	log.append("  Ball d=%.2f r=%.2f circ=%.4f" % [PC.BALL_DIAMETER, PC.BALL_RADIUS, PC.BALL_CIRCUMFERENCE])
	if not is_equal_approx(PC.BALL_DIAMETER, 1.82):
		errors.append("BALL_DIAMETER != 1.82")
	if not is_equal_approx(PC.BALL_RADIUS, 0.91):
		errors.append("BALL_RADIUS != 0.91")
	if not is_equal_approx(PC.BALL_RADIUS * 2.0, PC.BALL_DIAMETER):
		errors.append("BALL_RADIUS*2 != BALL_DIAMETER")

	# 6) Arena
	log.append("  Arena size=%s half=%s aabb=%s" % [str(PC.ARENA_SIZE), str(PC.ARENA_HALF_SIZE), str(PC.arena_aabb())])
	if not is_equal_approx(PC.ARENA_LENGTH, 60.0):
		errors.append("ARENA_LENGTH != 60")
	if not is_equal_approx(PC.ARENA_WIDTH, 40.0):
		errors.append("ARENA_WIDTH != 40")
	if not is_equal_approx(PC.ARENA_HEIGHT, 20.0):
		errors.append("ARENA_HEIGHT != 20")
	# Inside checks
	var origin_inside: bool = PC.is_inside_arena(Vector3.ZERO)
	var outside: bool = PC.is_inside_arena(Vector3(25, 1, 35))
	log.append("  is_inside_arena(0,0,0)=%s is_inside(25,1,35)=%s" % [str(origin_inside), str(outside)])
	if not origin_inside:
		errors.append("origin should be inside arena")
	if outside:
		errors.append("(25,1,35) should be outside arena")
	# Clamp
	var clamped := PC.clamp_to_arena(Vector3(100, -5, 100))
	log.append("  clamp_to_arena(100,-5,100)=%s" % str(clamped))
	if not clamped.is_equal_approx(Vector3(20, 0, 30)):
		errors.append("clamp_to_arena failed: got %s expected (20,0,30)" % str(clamped))

	# 7) UV roundtrip
	var p := Vector3(10, 2, -15)
	var uv: Vector2 = PC.world_to_arena_uv(p)
	var p2: Vector3 = PC.arena_uv_to_world(uv, p.y)
	log.append("  UV roundtrip: %s -> %s -> %s" % [str(p), str(uv), str(p2)])
	if not is_equal_approx(p.x, p2.x) or not is_equal_approx(p.z, p2.z) or not is_equal_approx(p.y, p2.y):
		errors.append("UV roundtrip mismatch: %s vs %s" % [str(p), str(p2)])
	# Corners map to (0,0) and (1,1)
	var uv_min: Vector2 = PC.world_to_arena_uv(Vector3(-20, 0, -30))
	var uv_max: Vector2 = PC.world_to_arena_uv(Vector3(20, 0, 30))
	log.append("  UV corners: min=%s max=%s" % [str(uv_min), str(uv_max)])
	if not uv_min.is_equal_approx(Vector2.ZERO):
		errors.append("world_to_arena_uv min corner != (0,0): %s" % str(uv_min))
	if not uv_max.is_equal_approx(Vector2.ONE):
		errors.append("world_to_arena_uv max corner != (1,1): %s" % str(uv_max))

	# 8) Goals
	log.append("  Goal W=%.2f H=%.2f D=%.2f halfW=%.2f centerY=%.2f" % [PC.GOAL_WIDTH, PC.GOAL_HEIGHT, PC.GOAL_DEPTH, PC.GOAL_HALF_WIDTH, PC.GOAL_CENTER_Y])
	if not is_equal_approx(PC.GOAL_WIDTH, 7.3):
		errors.append("GOAL_WIDTH != 7.3")
	if not is_equal_approx(PC.GOAL_HEIGHT, 2.1):
		errors.append("GOAL_HEIGHT != 2.1")
	var g_pos: Vector3 = PC.goal_center(true)
	var g_neg: Vector3 = PC.goal_center(false)
	log.append("  goal_center(+Z)=%s goal_center(-Z)=%s" % [str(g_pos), str(g_neg)])
	if not is_equal_approx(g_pos.z, 30.0) or not is_equal_approx(g_neg.z, -30.0):
		errors.append("goal_center Z mismatch: %s / %s" % [str(g_pos), str(g_neg)])
	var inside_goal: bool = PC.is_inside_goal(g_pos, true)
	log.append("  is_inside_goal(center,+Z)=%s" % str(inside_goal))
	if not inside_goal:
		errors.append("goal center should be inside goal AABB")
	var outside_goal: bool = PC.is_inside_goal(Vector3(10, 1, 30), true)
	if outside_goal:
		errors.append("(10,1,30) should be outside goal")
	# Goal fits inside arena opening
	if PC.GOAL_WIDTH > PC.ARENA_WIDTH:
		errors.append("GOAL_WIDTH > ARENA_WIDTH")
	if PC.GOAL_HEIGHT > PC.ARENA_HEIGHT:
		errors.append("GOAL_HEIGHT > ARENA_HEIGHT")

	# 9) debug_validate
	var v: Dictionary = PC.debug_validate()
	log.append("  debug_validate ok=%s errors=%s" % [str(v["ok"]), str(v["errors"])])
	if not v["ok"]:
		for e in v["errors"]:
			errors.append("debug_validate: " + str(e))

	var ok: bool = errors.is_empty()
	return {"ok": ok, "errors": errors, "log": log}
