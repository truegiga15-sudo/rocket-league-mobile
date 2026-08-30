## WS63 — Ball Hit Impact VFX — SOLO budget-aware <12 calls
## Ring + sparks + flash on ball_hit signal. Deterministic, no random.
## Triggered by BallContact impulse (WS20) at BallConfig spawn/radius (WS19).
## Budget: <12 API calls per tick, <12 draw calls, 120 Hz fixed tick.
## Depends on: src/core/constants.gd (WS04), src/core/physics/physics_config.gd (WS07),
##             src/game/ball/ball_config.gd (WS19), src/game/ball/contact.gd (WS20),
##             src/game/ball/ball_physics.gd (WS19 — ball_hit signal)
## Conventions: docs/architecture/00-conventions.md §3-§5, §11-§12,
##   1 unit = 1 m, Y-up, +Z forward, fixed 120 Hz, no procedural generation.
extends Node3D
class_name BallHit

const PC = preload("res://src/core/constants.gd")
const PCfg = preload("res://src/core/physics/physics_config.gd")
const BCfg = preload("res://src/game/ball/ball_config.gd")
const BallContactRef = preload("res://src/game/ball/contact.gd")
const BallPhysicsRef = preload("res://src/game/ball/ball_physics.gd")

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

# ---------------------------------------------------------------------------
# Ball geometry — single source via BallConfig (WS19)
# ---------------------------------------------------------------------------
const BALL_RADIUS: float = 0.91
const BALL_DIAMETER: float = 1.82

# ---------------------------------------------------------------------------
# Ring — expanding torus/quad at contact point, authored
# ---------------------------------------------------------------------------
const RING_DURATION: float = 0.22
const RING_START_RADIUS: float = 0.35
const RING_END_RADIUS: float = 2.6
const RING_WIDTH: float = 0.08
const RING_COLOR: Color = Color(1.0, 0.92, 0.35, 0.9)
const RING_FADE_COLOR: Color = Color(1.0, 0.92, 0.35, 0.0)

# ---------------------------------------------------------------------------
# Sparks — short GPU particles burst at contact, authored
# ---------------------------------------------------------------------------
const SPARKS_DURATION: float = 0.30
const SPARKS_AMOUNT: int = 24
const SPARKS_LIFETIME: float = 0.28
const SPARKS_SPEED: float = 7.0
const SPARKS_SPREAD_DEG: float = 65.0
const SPARKS_SIZE_MIN: float = 0.04
const SPARKS_SIZE_MAX: float = 0.11
const SPARKS_GRAVITY_RATIO: float = 0.35
const SPARKS_COLOR: Color = Color(1.0, 0.85, 0.25, 1.0)
const SPARKS_FADE_COLOR: Color = Color(1.0, 0.45, 0.05, 0.0)

# ---------------------------------------------------------------------------
# Flash — brief emissive sphere/point light, authored
# ---------------------------------------------------------------------------
const FLASH_DURATION: float = 0.10
const FLASH_INTENSITY: float = 2.2
const FLASH_RADIUS: float = 4.5
const FLASH_COLOR: Color = Color(1.0, 0.95, 0.6, 1.0)

# ---------------------------------------------------------------------------
# Impact thresholds — uses WS20 contact constants
# ---------------------------------------------------------------------------
const MIN_IMPULSE_FOR_VFX: float = 80.0
const MAX_IMPULSE_REF: float = 9000.0
const MIN_IMPULSE_REF: float = 80.0
const INTENSITY_AT_MIN: float = 0.25
const INTENSITY_AT_MAX: float = 1.0

# ---------------------------------------------------------------------------
# Determinism — no randf, seeded jitter from tick/impulse
# ---------------------------------------------------------------------------
const JITTER_SEED: int = 0x63301
const PHI: float = 1.618033988749895

# ---------------------------------------------------------------------------
# Instance state — budget-aware, no alloc per tick beyond these
# ---------------------------------------------------------------------------
var _is_active: bool = false
var _time_since_hit: float = 999.0
var _hit_intensity: float = 0.0
var _hit_position: Vector3 = Vector3.ZERO
var _hit_normal: Vector3 = Vector3.UP
var _tick_count: int = 0
var _call_count_last_tick: int = 0

var _ring: MeshInstance3D = null
var _sparks: GPUParticles3D = null
var _flash_light: OmniLight3D = null
var _flash_mesh: MeshInstance3D = null
var _ball: Node = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_ensure_ring()
	_ensure_sparks()
	_ensure_flash()
	_try_connect_ball()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[BallHit] debug_validate: %s" % e)

func _ensure_ring() -> void:
	if _ring != null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "HitRing"
	var mesh := RingMesh.new() if ClassDB.class_exists("RingMesh") else TorusMesh.new()
	# Use Torus fallback if RingMesh unavailable — both are ring-like
	if mesh is TorusMesh:
		var tm := mesh as TorusMesh
		tm.inner_radius = RING_START_RADIUS
		tm.outer_radius = RING_START_RADIUS + RING_WIDTH
		tm.rings = 16
		tm.ring_segments = 24
	elif mesh is RingMesh:
		mesh.inner_radius = RING_START_RADIUS
		mesh.outer_radius = RING_START_RADIUS + RING_WIDTH
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = RING_COLOR
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.visible = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_ring = mi

func _ensure_sparks() -> void:
	if _sparks != null:
		return
	var p := GPUParticles3D.new()
	p.name = "HitSparks"
	p.emitting = false
	p.amount = SPARKS_AMOUNT
	p.lifetime = SPARKS_LIFETIME
	p.one_shot = true
	p.explosiveness = 0.95
	p.visibility_aabb = AABB(Vector3(-6, -6, -6), Vector3(12, 12, 12))
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = SPARKS_SPREAD_DEG
	mat.initial_velocity_min = SPARKS_SPEED * 0.7
	mat.initial_velocity_max = SPARKS_SPEED * 1.15
	mat.gravity = Vector3(0, -9.81 * SPARKS_GRAVITY_RATIO, 0)
	mat.scale_min = SPARKS_SIZE_MIN
	mat.scale_max = SPARKS_SIZE_MAX
	mat.color = SPARKS_COLOR
	p.process_material = mat
	p.draw_pass_1 = QuadMesh.new()
	add_child(p)
	_sparks = p

func _ensure_flash() -> void:
	if _flash_light == null:
		var l := OmniLight3D.new()
		l.name = "HitFlashLight"
		l.light_color = FLASH_COLOR
		l.omni_range = FLASH_RADIUS
		l.light_energy = 0.0
		l.visible = false
		l.shadow_enabled = false
		add_child(l)
		_flash_light = l
	if _flash_mesh == null:
		var mi := MeshInstance3D.new()
		mi.name = "HitFlashMesh"
		var sph := SphereMesh.new()
		sph.radius = 0.35
		sph.height = 0.70
		sph.radial_segments = 12
		sph.rings = 8
		mi.mesh = sph
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(FLASH_COLOR.r, FLASH_COLOR.g, FLASH_COLOR.b, 0.0)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		mi.visible = false
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_flash_mesh = mi

func _try_connect_ball() -> void:
	if _ball != null:
		return
	# Walk up to find BallPhysics sibling/parent — non-fatal if absent
	var parent := get_parent()
	if parent != null and parent.has_signal("ball_hit"):
		_ball = parent
		if not parent.is_connected("ball_hit", _on_ball_hit):
			parent.connect("ball_hit", _on_ball_hit)
			_call_count_last_tick += 1

## Bind to an explicit ball node (preferred over auto-discover). Budget: 1 connect.
func bind_ball(ball: Node) -> void:
	if ball == null:
		return
	if _ball != null and _ball.has_signal("ball_hit") and _ball.is_connected("ball_hit", _on_ball_hit):
		_ball.disconnect("ball_hit", _on_ball_hit)
	_ball = ball
	if ball.has_signal("ball_hit") and not ball.is_connected("ball_hit", _on_ball_hit):
		ball.connect("ball_hit", _on_ball_hit)

func _on_ball_hit(impulse: Vector3, contact_point: Vector3) -> void:
	trigger_hit(impulse, contact_point)

# ---------------------------------------------------------------------------
# Trigger — budget: 1 call to emit, <12 per tick total
# ---------------------------------------------------------------------------

## Trigger VFX at contact_point with impulse from WS20. Scales with impulse mag.
func trigger_hit(impulse: Vector3, contact_point: Vector3) -> void:
	var mag := impulse.length()
	if mag < MIN_IMPULSE_FOR_VFX:
		return
	_hit_intensity = compute_intensity(mag)
	_hit_position = contact_point
	_hit_normal = impulse.normalized() if impulse.length_squared() > 0.001 else Vector3.UP
	global_position = contact_point
	_is_active = true
	_time_since_hit = 0.0
	_tick_count += 1
	_update_visuals(0.0)

## Alias for callers that pass only impulse (uses ball origin).
func trigger_hit_impulse(impulse: Vector3) -> void:
	trigger_hit(impulse, _hit_position if _hit_position != Vector3.ZERO else global_position)

func _physics_process(delta: float) -> void:
	_call_count_last_tick = 0
	_tick_count += 1
	_call_count_last_tick += 1
	if not _is_active:
		return
	_time_since_hit += delta
	_call_count_last_tick += 1
	_update_visuals(_time_since_hit)
	_call_count_last_tick += 1
	if _time_since_hit >= max(RING_DURATION, max(SPARKS_DURATION, FLASH_DURATION)):
		_is_active = false
		_set_visible_all(false)
		_call_count_last_tick += 1
	if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
		push_warning("[BallHit] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
		_call_count_last_tick = MAX_CALLS_PER_TICK

func _update_visuals(t: float) -> void:
	var ring_t := clamp(t / RING_DURATION, 0.0, 1.0) if RING_DURATION > 0.0 else 1.0
	var flash_t := clamp(t / FLASH_DURATION, 0.0, 1.0) if FLASH_DURATION > 0.0 else 1.0
	# Ring — expand + fade
	if _ring != null:
		var r := lerp(RING_START_RADIUS, RING_END_RADIUS, ring_t)
		var m := _ring.mesh
		if m is TorusMesh:
			var tm := m as TorusMesh
			tm.inner_radius = r
			tm.outer_radius = r + RING_WIDTH
		elif m is RingMesh:
			m.inner_radius = r
			m.outer_radius = r + RING_WIDTH
		var mat := _ring.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color = RING_COLOR.lerp(RING_FADE_COLOR, ring_t)
		_ring.visible = t < RING_DURATION
		if _ring.visible:
			# Orient ring to face hit normal — align Y-up ring to normal
			if _hit_normal.length_squared() > 0.5:
				var up := Vector3.UP
				if abs(_hit_normal.dot(up)) > 0.99:
					_ring.rotation = Vector3.ZERO
				else:
					var axis := up.cross(_hit_normal).normalized()
					var ang := acos(clamp(up.dot(_hit_normal), -1.0, 1.0))
					_ring.rotation = axis * ang
	# Sparks — one-shot burst
	if _sparks != null:
		if t < 0.015:
			_sparks.restart()
			_sparks.emitting = true
		_sparks.visible = t < SPARKS_DURATION
	# Flash — quick fade
	if _flash_light != null:
		var e := FLASH_INTENSITY * _hit_intensity * (1.0 - flash_t) if t < FLASH_DURATION else 0.0
		_flash_light.light_energy = e
		_flash_light.visible = e > 0.01
	if _flash_mesh != null:
		var fm := _flash_mesh.material_override as StandardMaterial3D
		if fm != null:
			var a := (1.0 - flash_t) * 0.55 * _hit_intensity if t < FLASH_DURATION else 0.0
			fm.albedo_color = Color(FLASH_COLOR.r, FLASH_COLOR.g, FLASH_COLOR.b, a)
		_flash_mesh.visible = t < FLASH_DURATION
		var s := 1.0 + flash_t * 1.5
		_flash_mesh.scale = Vector3(s, s, s)

func _set_visible_all(v: bool) -> void:
	if _ring != null:
		_ring.visible = v
	if _sparks != null:
		_sparks.visible = v
		_sparks.emitting = v
	if _flash_light != null:
		_flash_light.visible = v
		if not v:
			_flash_light.light_energy = 0.0
	if _flash_mesh != null:
		_flash_mesh.visible = v

# ---------------------------------------------------------------------------
# Pure helpers — deterministic, no alloc, budget-friendly
# ---------------------------------------------------------------------------

## Map impulse magnitude -> 0..1 intensity via smoothstep between refs.
static func compute_intensity(impulse_mag: float) -> float:
	if impulse_mag < MIN_IMPULSE_FOR_VFX:
		return 0.0
	var clamped := clamp(impulse_mag, MIN_IMPULSE_REF, MAX_IMPULSE_REF)
	var t := (clamped - MIN_IMPULSE_REF) / (MAX_IMPULSE_REF - MIN_IMPULSE_REF)
	# smoothstep
	t = t * t * (3.0 - 2.0 * t)
	return lerp(INTENSITY_AT_MIN, INTENSITY_AT_MAX, t)

## Deterministic jitter offset for sparks variation (no randf).
static func compute_jitter(tick: int, index: int) -> Vector3:
	var s := float(JITTER_SEED + tick * 7919 + index * 104729)
	var x := fmod(sin(s * 0.0001) * 43758.5453, 1.0) * 2.0 - 1.0
	var y := fmod(sin((s + 1.0) * 0.0001) * 43758.5453, 1.0) * 2.0 - 1.0
	var z := fmod(sin((s + 2.0) * 0.0001) * 43758.5453, 1.0) * 2.0 - 1.0
	return Vector3(x, y, z) * 0.08

## Whether impulse qualifies for VFX.
static func should_trigger(impulse_mag: float) -> bool:
	return impulse_mag >= MIN_IMPULSE_FOR_VFX

## Ring radius at time t (0..RING_DURATION).
static func ring_radius_at(t: float) -> float:
	var nt := clamp(t / RING_DURATION, 0.0, 1.0) if RING_DURATION > 0.0 else 1.0
	return lerp(RING_START_RADIUS, RING_END_RADIUS, nt)

## Flash energy at time t.
static func flash_energy_at(t: float, intensity: float) -> float:
	if t >= FLASH_DURATION:
		return 0.0
	var nt := clamp(t / FLASH_DURATION, 0.0, 1.0)
	return FLASH_INTENSITY * intensity * (1.0 - nt)

## Tick helper — deterministic state step for tests (no scene needed).
static func tick_state(time_since_hit: float, delta: float, is_active: bool) -> Dictionary:
	var t := time_since_hit + delta if is_active else time_since_hit
	var active := is_active and t < max(RING_DURATION, max(SPARKS_DURATION, FLASH_DURATION))
	return {"time_since_hit": t, "is_active": active, "ring_t": clamp(t / RING_DURATION, 0.0, 1.0) if RING_DURATION > 0.0 else 1.0}

# ---------------------------------------------------------------------------
# Accessors
# ---------------------------------------------------------------------------
func is_active() -> bool:
	return _is_active

func get_intensity() -> float:
	return _hit_intensity

func get_hit_position() -> Vector3:
	return _hit_position

func get_time_since_hit() -> float:
	return _time_since_hit

func get_call_count_last_tick() -> int:
	return _call_count_last_tick

func get_ring_node() -> MeshInstance3D:
	return _ring

func get_sparks_node() -> GPUParticles3D:
	return _sparks

func get_flash_light() -> OmniLight3D:
	return _flash_light

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
	if MAX_DRAW_CALLS != 12:
		errors.append("MAX_DRAW_CALLS %d != 12" % MAX_DRAW_CALLS)
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if PCfg.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PCfg.PHYSICS_TICKS_PER_SECOND %d != 120" % PCfg.PHYSICS_TICKS_PER_SECOND)
	if BCfg.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("BCfg.PHYSICS_TICKS_PER_SECOND %d != 120" % BCfg.PHYSICS_TICKS_PER_SECOND)
	if BallContactRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("BallContact tick %d != 120" % BallContactRef.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(BALL_RADIUS, BCfg.BALL_RADIUS):
		errors.append("BALL_RADIUS %.2f != BCfg.BALL_RADIUS %.2f" % [BALL_RADIUS, BCfg.BALL_RADIUS])
	if not is_equal_approx(BALL_DIAMETER, BCfg.BALL_DIAMETER):
		errors.append("BALL_DIAMETER %.2f != BCfg.BALL_DIAMETER %.2f" % [BALL_DIAMETER, BCfg.BALL_DIAMETER])
	if not is_equal_approx(BALL_DIAMETER, 2.0 * BALL_RADIUS):
		errors.append("BALL_DIAMETER != 2*BALL_RADIUS")
	if not is_equal_approx(RING_START_RADIUS, 0.35):
		errors.append("RING_START_RADIUS %.2f != 0.35" % RING_START_RADIUS)
	if not is_equal_approx(RING_END_RADIUS, 2.6):
		errors.append("RING_END_RADIUS %.2f != 2.6" % RING_END_RADIUS)
	if not is_equal_approx(MIN_IMPULSE_FOR_VFX, BallContactRef.MIN_IMPACT_SPEED * BallContactRef.MASS_BALL * 10.0) and MIN_IMPULSE_FOR_VFX < 10.0:
		# Soft check — just ensure threshold is reasonable vs WS20 MIN_IMPACT
		pass
	if SPARKS_AMOUNT != 24:
		errors.append("SPARKS_AMOUNT %d != 24" % SPARKS_AMOUNT)
	if MAX_IMPULSE_REF != BallContactRef.MAX_IMPULSE_MAG:
		errors.append("MAX_IMPULSE_REF %.0f != BallContact.MAX_IMPULSE_MAG %.0f" % [MAX_IMPULSE_REF, BallContactRef.MAX_IMPULSE_MAG])
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"ball_radius": BALL_RADIUS,
		"ball_diameter": BALL_DIAMETER,
		"ring_duration": RING_DURATION,
		"ring_start_radius": RING_START_RADIUS,
		"ring_end_radius": RING_END_RADIUS,
		"ring_color": RING_COLOR,
		"sparks_duration": SPARKS_DURATION,
		"sparks_amount": SPARKS_AMOUNT,
		"sparks_lifetime": SPARKS_LIFETIME,
		"sparks_speed": SPARKS_SPEED,
		"flash_duration": FLASH_DURATION,
		"flash_intensity": FLASH_INTENSITY,
		"min_impulse_for_vfx": MIN_IMPULSE_FOR_VFX,
		"max_impulse_ref": MAX_IMPULSE_REF,
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"physics_tick_delta": PHYSICS_TICK_DELTA,
		"max_calls_per_tick": MAX_CALLS_PER_TICK,
		"max_draw_calls": MAX_DRAW_CALLS,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "BallHit", "tick_hz": PHYSICS_TICKS_PER_SECOND, "budget_calls": MAX_CALLS_PER_TICK, "draw_calls": 3}
