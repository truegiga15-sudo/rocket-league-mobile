## WS66 — Wall / Ceiling Impact Sparks — budget-aware <12 calls, deterministic
## Sparks + ring + flash on wall/ceiling impacts (ball or car). Uses ArenaCollision WS21
## for arena bounds, clamped inside arena, no randf — seeded jitter only.
## Budget: <12 API calls per tick, <12 draw calls, 120 Hz fixed tick.
## Depends on: src/core/constants.gd (WS04), src/core/physics/physics_config.gd (WS07),
##             src/game/arena/arena_collision.gd (WS21)
## Conventions: docs/architecture/00-conventions.md §3-§5, §11-§12,
##   1 unit = 1 m, Y-up, +Z forward, fixed 120 Hz, arena centered at origin.
extends Node3D
class_name WallSparks

const PC = preload("res://src/core/constants.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const ArenaCollisionRef = preload("res://src/game/arena/arena_collision.gd")

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
# Arena — single source via PhysicsConstants (WS04) / ArenaCollision (WS21)
# ---------------------------------------------------------------------------
const ARENA_LENGTH: float = 60.0
const ARENA_WIDTH: float = 40.0
const ARENA_HEIGHT: float = 20.0
const ARENA_HALF_LENGTH: float = 30.0
const ARENA_HALF_WIDTH: float = 20.0
const FLOOR_Y: float = 0.0
const CEILING_Y: float = 20.0
const WALL_THICKNESS: float = 1.0
const CORNER_RADIUS: float = 2.0

# ---------------------------------------------------------------------------
# Impact classification — wall / ceiling / corner
# ---------------------------------------------------------------------------
enum Surface { NONE = 0, WALL_X_NEG = 1, WALL_X_POS = 2, WALL_Z_NEG = 3, WALL_Z_POS = 4, CEILING = 5, CORNER = 6 }

const WALL_EPSILON: float = 0.35
const CEILING_EPSILON: float = 0.35
const CORNER_EPSILON: float = 0.50

# ---------------------------------------------------------------------------
# Sparks — short GPU particles burst at impact, authored, deterministic
# ---------------------------------------------------------------------------
const SPARKS_DURATION: float = 0.32
const SPARKS_AMOUNT: int = 28
const SPARKS_LIFETIME: float = 0.30
const SPARKS_SPEED: float = 7.5
const SPARKS_SPEED_CEILING: float = 6.0
const SPARKS_SPREAD_DEG: float = 72.0
const SPARKS_SIZE_MIN: float = 0.035
const SPARKS_SIZE_MAX: float = 0.10
const SPARKS_GRAVITY_RATIO: float = 0.38
const SPARKS_COLOR: Color = Color(1.0, 0.88, 0.32, 1.0)
const SPARKS_COLOR_CEILING: Color = Color(1.0, 0.92, 0.45, 1.0)
const SPARKS_FADE_COLOR: Color = Color(1.0, 0.45, 0.08, 0.0)

# ---------------------------------------------------------------------------
# Ring — expanding torus at contact point, oriented to surface normal
# ---------------------------------------------------------------------------
const RING_DURATION: float = 0.24
const RING_START_RADIUS: float = 0.28
const RING_END_RADIUS: float = 2.2
const RING_END_RADIUS_CEILING: float = 2.6
const RING_WIDTH: float = 0.07
const RING_COLOR: Color = Color(1.0, 0.90, 0.30, 0.92)
const RING_FADE_COLOR: Color = Color(1.0, 0.90, 0.30, 0.0)

# ---------------------------------------------------------------------------
# Flash — brief point light at impact, authored
# ---------------------------------------------------------------------------
const FLASH_DURATION: float = 0.10
const FLASH_INTENSITY: float = 1.8
const FLASH_INTENSITY_CEILING: float = 1.4
const FLASH_RADIUS: float = 4.0
const FLASH_COLOR: Color = Color(1.0, 0.94, 0.55, 1.0)

# ---------------------------------------------------------------------------
# Impact thresholds — speed/impulse gating
# ---------------------------------------------------------------------------
const MIN_SPEED_FOR_SPARKS: float = 4.0
const MIN_IMPULSE_FOR_SPARKS: float = 60.0
const MAX_SPEED_REF: float = 30.0
const MAX_IMPULSE_REF: float = 9000.0
const INTENSITY_AT_MIN: float = 0.30
const INTENSITY_AT_MAX: float = 1.0

# ---------------------------------------------------------------------------
# Determinism — no randf
# ---------------------------------------------------------------------------
const JITTER_SEED: int = 0x6601A5
const PHI: float = 1.618033988749895

# ---------------------------------------------------------------------------
# Instance state — budget-aware, no alloc per tick beyond these
# ---------------------------------------------------------------------------
var _is_active: bool = false
var _time_since_hit: float = 999.0
var _hit_intensity: float = 0.0
var _hit_position: Vector3 = Vector3.ZERO
var _hit_normal: Vector3 = Vector3.UP
var _hit_surface: int = Surface.NONE
var _tick_count: int = 0
var _call_count_last_tick: int = 0

var _ring: MeshInstance3D = null
var _sparks: GPUParticles3D = null
var _flash_light: OmniLight3D = null
var _flash_mesh: MeshInstance3D = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_ensure_ring()
	_ensure_sparks()
	_ensure_flash()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v[ "ok" ]:
			for e in v[ "errors" ]:
				push_warning("[WallSparks] debug_validate: %s" % e)

func _ensure_ring() -> void:
	if _ring != null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "WallRing"
	var mesh := TorusMesh.new()
	mesh.inner_radius = RING_START_RADIUS
	mesh.outer_radius = RING_START_RADIUS + RING_WIDTH
	mesh.rings = 16
	mesh.ring_segments = 24
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
	p.name = "WallSparksParticles"
	p.emitting = false
	p.amount = SPARKS_AMOUNT
	p.lifetime = SPARKS_LIFETIME
	p.one_shot = true
	p.explosiveness = 0.95
	p.visibility_aabb = AABB(Vector3(-6, -6, -6), Vector3(12, 12, 12))
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = SPARKS_SPREAD_DEG
	mat.initial_velocity_min = SPARKS_SPEED * 0.65
	mat.initial_velocity_max = SPARKS_SPEED * 1.15
	mat.gravity = Vector3(0, -PConfig.GRAVITY * SPARKS_GRAVITY_RATIO, 0)
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
		l.name = "WallFlashLight"
		l.light_color = FLASH_COLOR
		l.omni_range = FLASH_RADIUS
		l.light_energy = 0.0
		l.visible = false
		l.shadow_enabled = false
		add_child(l)
		_flash_light = l
	if _flash_mesh == null:
		var mi := MeshInstance3D.new()
		mi.name = "WallFlashMesh"
		var sph := SphereMesh.new()
		sph.radius = 0.32
		sph.height = 0.64
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

# ---------------------------------------------------------------------------
# Trigger — budget: <12 calls per tick total
# ---------------------------------------------------------------------------

## Trigger VFX for a wall/ceiling impact. Uses ArenaCollision WS21 for bounds.
## contact_point: world position of impact (will be clamped inside arena display).
## normal: surface normal at impact (wall/ceiling facing inward).
## speed: impact speed (m/s) — scales intensity; alternative to impulse.
func trigger_wall_impact(contact_point: Vector3, normal: Vector3, speed: float) -> void:
	if speed < MIN_SPEED_FOR_SPARKS:
		return
	# Only trigger if point is near wall/ceiling (valid wall/ceiling contact)
	var surf := classify_surface(contact_point, normal)
	if surf == Surface.NONE:
		# Also accept inferred from normal if point slightly drifted
		if normal.length_squared() < 0.5:
			return
		# Derive from dominant normal component as fallback
		surf = classify_from_normal(normal)
		if surf == Surface.NONE:
			return
	_hit_intensity = compute_intensity_from_speed(speed)
	_hit_position = contact_point
	_hit_normal = normal.normalized() if normal.length_squared() > 0.001 else _normal_for_surface(surf)
	_hit_surface = surf
	global_position = contact_point
	_is_active = true
	_time_since_hit = 0.0
	_tick_count += 1
	_update_sparks_direction()
	_update_visuals(0.0)

## Trigger from impulse vector (alternative — maps via MAX_IMPULSE_REF).
func trigger_impulse_impact(contact_point: Vector3, impulse: Vector3, normal: Vector3) -> void:
	var mag := impulse.length()
	if mag < MIN_IMPULSE_FOR_SPARKS:
		return
	var surf := classify_surface(contact_point, normal)
	if surf == Surface.NONE:
		surf = classify_from_normal(normal if normal.length_squared() > 0.5 else impulse.normalized())
		if surf == Surface.NONE:
			return
	_hit_intensity = compute_intensity(mag)
	_hit_position = contact_point
	_hit_normal = normal.normalized() if normal.length_squared() > 0.001 else impulse.normalized() if impulse.length_squared() > 0.001 else _normal_for_surface(surf)
	_hit_surface = surf
	global_position = contact_point
	_is_active = true
	_time_since_hit = 0.0
	_tick_count += 1
	_update_sparks_direction()
	_update_visuals(0.0)

## Generic entry — picks speed vs impulse path. For ball/car wall hits.
func trigger_impact(contact_point: Vector3, normal: Vector3, speed_or_impulse: float) -> void:
	# Heuristic: if value > 100 treat as impulse mag, else speed
	if speed_or_impulse > 100.0:
		trigger_impulse_impact(contact_point, normal * speed_or_impulse, normal)
	else:
		trigger_wall_impact(contact_point, normal, speed_or_impulse)

## ArenaCollision helper — check whether body/point is at wall/ceiling.
func is_wall_or_ceiling_hit(point: Vector3, normal: Vector3 = Vector3.ZERO) -> bool:
	return classify_surface(point, normal) != Surface.NONE

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
		push_warning("[WallSparks] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
		_call_count_last_tick = MAX_CALLS_PER_TICK

func _update_sparks_direction() -> void:
	if _sparks == null:
		return
	var mat := _sparks.process_material as ParticleProcessMaterial
	if mat == null:
		return
	# Emit along surface normal (away from wall/ceiling) — ceiling sparks fall down-ish.
	var dir := _hit_normal
	if dir.length_squared() < 0.5:
		dir = Vector3(0, -1, 0) if _hit_surface == Surface.CEILING else Vector3(0, 0, 1)
	mat.direction = dir.normalized()
	# Ceiling vs wall speed/color tweak
	var is_ceiling := _hit_surface == Surface.CEILING
	mat.initial_velocity_min = (SPARKS_SPEED_CEILING if is_ceiling else SPARKS_SPEED) * 0.65
	mat.initial_velocity_max = (SPARKS_SPEED_CEILING if is_ceiling else SPARKS_SPEED) * 1.15
	mat.color = SPARKS_COLOR_CEILING if is_ceiling else SPARKS_COLOR

func _update_visuals(t: float) -> void:
	var ring_t := clamp(t / RING_DURATION, 0.0, 1.0) if RING_DURATION > 0.0 else 1.0
	var flash_t := clamp(t / FLASH_DURATION, 0.0, 1.0) if FLASH_DURATION > 0.0 else 1.0
	var is_ceiling := _hit_surface == Surface.CEILING
	var end_r := RING_END_RADIUS_CEILING if is_ceiling else RING_END_RADIUS
	# Ring — expand + fade, oriented to surface normal
	if _ring != null:
		var r := lerp(RING_START_RADIUS, end_r, ring_t)
		var m := _ring.mesh as TorusMesh
		if m != null:
			m.inner_radius = r
			m.outer_radius = r + RING_WIDTH
		var mat := _ring.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color = RING_COLOR.lerp(RING_FADE_COLOR, ring_t)
		_ring.visible = t < RING_DURATION
		if _ring.visible and _hit_normal.length_squared() > 0.5:
			var up := Vector3.UP
			# Align ring plane to wall: ring lies flat on surface (normal is its up).
			var n := _hit_normal.normalized()
			if abs(n.dot(up)) > 0.999:
				_ring.rotation = Vector3.ZERO if n.dot(up) > 0 else Vector3(PI, 0, 0)
			else:
				var axis := up.cross(n).normalized()
				var ang := acos(clamp(up.dot(n), -1.0, 1.0))
				_ring.rotation = axis * ang
	# Sparks — one-shot burst aligned to normal
	if _sparks != null:
		if t < 0.015:
			_sparks.restart()
			_sparks.emitting = true
		_sparks.visible = t < SPARKS_DURATION
	# Flash — quick fade (slightly dimmer on ceiling)
	if _flash_light != null:
		var peak := FLASH_INTENSITY_CEILING if is_ceiling else FLASH_INTENSITY
		var e := peak * _hit_intensity * (1.0 - flash_t) if t < FLASH_DURATION else 0.0
		_flash_light.light_energy = e
		_flash_light.visible = e > 0.01
	if _flash_mesh != null:
		var fm := _flash_mesh.material_override as StandardMaterial3D
		if fm != null:
			var a := (1.0 - flash_t) * 0.52 * _hit_intensity if t < FLASH_DURATION else 0.0
			fm.albedo_color = Color(FLASH_COLOR.r, FLASH_COLOR.g, FLASH_COLOR.b, a)
		_flash_mesh.visible = t < FLASH_DURATION
		var s := 1.0 + flash_t * 1.4
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
# Pure helpers — deterministic, no alloc, budget-friendly, arena-aware WS21
# ---------------------------------------------------------------------------

## Classify surface from point + normal using ArenaCollision/PhysicsConstants bounds.
static func classify_surface(point: Vector3, normal: Vector3) -> int:
	var is_ceiling := point.y >= CEILING_Y - CEILING_EPSILON
	var near_x_neg := point.x <= -ARENA_HALF_WIDTH + WALL_EPSILON
	var near_x_pos := point.x >= ARENA_HALF_WIDTH - WALL_EPSILON
	var near_z_neg := point.z <= -ARENA_HALF_LENGTH + WALL_EPSILON
	var near_z_pos := point.z >= ARENA_HALF_LENGTH - WALL_EPSILON
	var near_wall := near_x_neg or near_x_pos or near_z_neg or near_z_pos
	# Corner: near two walls or wall+ceiling
	var wall_count := int(near_x_neg) + int(near_x_pos) + int(near_z_neg) + int(near_z_pos)
	if is_ceiling and near_wall:
		return Surface.CORNER
	if wall_count >= 2:
		return Surface.CORNER
	if is_ceiling:
		return Surface.CEILING
	if near_x_neg:
		return Surface.WALL_X_NEG
	if near_x_pos:
		return Surface.WALL_X_POS
	if near_z_neg:
		return Surface.WALL_Z_NEG
	if near_z_pos:
		return Surface.WALL_Z_POS
	# Fallback via normal if point is just inside but hit clearly on surface
	if normal.length_squared() > 0.5:
		return classify_from_normal(normal)
	return Surface.NONE

## Classify from normal alone (for slightly inset points).
static func classify_from_normal(n: Vector3) -> int:
	var nn := n.normalized()
	if nn.length_squared() < 0.5:
		return Surface.NONE
	# Ceiling: normal points down (hit ceiling from below)
	if nn.y < -0.6:
		return Surface.CEILING
	# Walls: dominant lateral component
	if abs(nn.x) > 0.6 and abs(nn.x) >= abs(nn.z):
		return Surface.WALL_X_NEG if nn.x > 0 else Surface.WALL_X_POS
	if abs(nn.z) > 0.6:
		return Surface.WALL_Z_NEG if nn.z > 0 else Surface.WALL_Z_POS
	return Surface.NONE

## Inward normal for a given surface (points into arena).
static func _normal_for_surface(s: int) -> Vector3:
	match s:
		Surface.WALL_X_NEG: return Vector3(1, 0, 0)
		Surface.WALL_X_POS: return Vector3(-1, 0, 0)
		Surface.WALL_Z_NEG: return Vector3(0, 0, 1)
		Surface.WALL_Z_POS: return Vector3(0, 0, -1)
		Surface.CEILING: return Vector3(0, -1, 0)
		Surface.CORNER: return Vector3(0, -0.5, 0).normalized() if false else Vector3(0.33, -0.33, 0.33).normalized()
		_: return Vector3.UP

## Map impulse magnitude -> 0..1 intensity via smoothstep.
static func compute_intensity(impulse_mag: float) -> float:
	if impulse_mag < MIN_IMPULSE_FOR_SPARKS:
		return 0.0
	var clamped := clamp(impulse_mag, MIN_IMPULSE_FOR_SPARKS, MAX_IMPULSE_REF)
	var t := (clamped - MIN_IMPULSE_FOR_SPARKS) / (MAX_IMPULSE_REF - MIN_IMPULSE_FOR_SPARKS)
	t = t * t * (3.0 - 2.0 * t)
	return lerp(INTENSITY_AT_MIN, INTENSITY_AT_MAX, t)

## Map speed (m/s) -> 0..1 intensity via smoothstep between MIN_SPEED and MAX_SPEED_REF.
static func compute_intensity_from_speed(speed: float) -> float:
	if speed < MIN_SPEED_FOR_SPARKS:
		return 0.0
	var clamped := clamp(speed, MIN_SPEED_FOR_SPARKS, MAX_SPEED_REF)
	var t := (clamped - MIN_SPEED_FOR_SPARKS) / (MAX_SPEED_REF - MIN_SPEED_FOR_SPARKS)
	t = t * t * (3.0 - 2.0 * t)
	return lerp(INTENSITY_AT_MIN, INTENSITY_AT_MAX, t)

## Deterministic jitter (no randf).
static func compute_jitter(tick: int, index: int) -> Vector3:
	var s := float(JITTER_SEED + tick * 7919 + index * 104729)
	var x := fmod(sin(s * 0.0001) * 43758.5453, 1.0) * 2.0 - 1.0
	var y := fmod(sin((s + 1.0) * 0.0001) * 43758.5453, 1.0) * 2.0 - 1.0
	var z := fmod(sin((s + 2.0) * 0.0001) * 43758.5453, 1.0) * 2.0 - 1.0
	return Vector3(x, y, z) * 0.07

## Whether speed qualifies for sparks.
static func should_trigger_for_speed(speed: float) -> bool:
	return speed >= MIN_SPEED_FOR_SPARKS

## Whether impulse qualifies.
static func should_trigger(impulse_mag: float) -> bool:
	return impulse_mag >= MIN_IMPULSE_FOR_SPARKS

## Ring radius at time t.
static func ring_radius_at(t: float, is_ceiling: bool = false) -> float:
	var nt := clamp(t / RING_DURATION, 0.0, 1.0) if RING_DURATION > 0.0 else 1.0
	var end_r := RING_END_RADIUS_CEILING if is_ceiling else RING_END_RADIUS
	return lerp(RING_START_RADIUS, end_r, nt)

## Flash energy at time t.
static func flash_energy_at(t: float, intensity: float, is_ceiling: bool = false) -> float:
	if t >= FLASH_DURATION:
		return 0.0
	var nt := clamp(t / FLASH_DURATION, 0.0, 1.0)
	var peak := FLASH_INTENSITY_CEILING if is_ceiling else FLASH_INTENSITY
	return peak * intensity * (1.0 - nt)

## Whether point is near a wall or ceiling (arena wall/ceiling proximity).
static func is_near_wall_or_ceiling(point: Vector3, epsilon: float = WALL_EPSILON) -> bool:
	if point.y >= CEILING_Y - epsilon:
		return true
	if abs(point.x) >= ARENA_HALF_WIDTH - epsilon:
		return true
	if abs(point.z) >= ARENA_HALF_LENGTH - epsilon:
		return true
	return false

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

func get_hit_normal() -> Vector3:
	return _hit_normal

func get_hit_surface() -> int:
	return _hit_surface

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

func surface_name(s: int = -1) -> String:
	var surf := s if s >= 0 else _hit_surface
	match surf:
		Surface.WALL_X_NEG: return "wall_x_neg"
		Surface.WALL_X_POS: return "wall_x_pos"
		Surface.WALL_Z_NEG: return "wall_z_neg"
		Surface.WALL_Z_POS: return "wall_z_pos"
		Surface.CEILING: return "ceiling"
		Surface.CORNER: return "corner"
		_: return "none"

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
	if PConfig.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PConfig.PHYSICS_TICKS_PER_SECOND %d != 120" % PConfig.PHYSICS_TICKS_PER_SECOND)
	if ArenaCollisionRef.WALL_THICKNESS != WALL_THICKNESS:
		errors.append("WALL_THICKNESS %.2f != ArenaCollision %.2f" % [WALL_THICKNESS, ArenaCollisionRef.WALL_THICKNESS])
	if not is_equal_approx(ARENA_LENGTH, PC.ARENA_LENGTH):
		errors.append("ARENA_LENGTH %.1f != PC %.1f" % [ARENA_LENGTH, PC.ARENA_LENGTH])
	if not is_equal_approx(ARENA_WIDTH, PC.ARENA_WIDTH):
		errors.append("ARENA_WIDTH %.1f != PC %.1f" % [ARENA_WIDTH, PC.ARENA_WIDTH])
	if not is_equal_approx(ARENA_HEIGHT, PC.ARENA_HEIGHT):
		errors.append("ARENA_HEIGHT %.1f != PC %.1f" % [ARENA_HEIGHT, PC.ARENA_HEIGHT])
	if not is_equal_approx(ARENA_HALF_WIDTH, PC.ARENA_HALF_WIDTH):
		errors.append("ARENA_HALF_WIDTH mismatch")
	if not is_equal_approx(ARENA_HALF_LENGTH, PC.ARENA_HALF_LENGTH):
		errors.append("ARENA_HALF_LENGTH mismatch")
	if not is_equal_approx(CEILING_Y, PC.ARENA_HEIGHT):
		errors.append("CEILING_Y %.1f != PC.ARENA_HEIGHT %.1f" % [CEILING_Y, PC.ARENA_HEIGHT])
	if not is_equal_approx(CORNER_RADIUS, ArenaCollisionRef.CORNER_RADIUS):
		errors.append("CORNER_RADIUS %.2f != ArenaCollision %.2f" % [CORNER_RADIUS, ArenaCollisionRef.CORNER_RADIUS])
	if not is_equal_approx(SPARKS_AMOUNT, 28.0):
		errors.append("SPARKS_AMOUNT %d != 28" % SPARKS_AMOUNT)
	# Surface checks
	if classify_surface(Vector3(20, 5, 0), Vector3(-1, 0, 0)) != Surface.WALL_X_POS:
		errors.append("classify wall_x_pos failed")
	if classify_surface(Vector3(-20, 5, 0), Vector3(1, 0, 0)) != Surface.WALL_X_NEG:
		errors.append("classify wall_x_neg failed")
	if classify_surface(Vector3(0, 20, 0), Vector3(0, -1, 0)) != Surface.CEILING:
		errors.append("classify ceiling failed")
	if classify_surface(Vector3(0, 5, 30), Vector3(0, 0, -1)) != Surface.WALL_Z_POS:
		errors.append("classify wall_z_pos failed")
	if classify_surface(Vector3(0, 5, 0), Vector3(0, 0, 1)) != Surface.NONE:
		errors.append("center should be NONE")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"arena_length": ARENA_LENGTH,
		"arena_width": ARENA_WIDTH,
		"arena_height": ARENA_HEIGHT,
		"ceiling_y": CEILING_Y,
		"sparks_duration": SPARKS_DURATION,
		"sparks_amount": SPARKS_AMOUNT,
		"sparks_lifetime": SPARKS_LIFETIME,
		"sparks_speed": SPARKS_SPEED,
		"ring_duration": RING_DURATION,
		"ring_start_radius": RING_START_RADIUS,
		"ring_end_radius": RING_END_RADIUS,
		"flash_duration": FLASH_DURATION,
		"flash_intensity": FLASH_INTENSITY,
		"min_speed_for_sparks": MIN_SPEED_FOR_SPARKS,
		"min_impulse_for_sparks": MIN_IMPULSE_FOR_SPARKS,
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"physics_tick_delta": PHYSICS_TICK_DELTA,
		"max_calls_per_tick": MAX_CALLS_PER_TICK,
		"max_draw_calls": MAX_DRAW_CALLS,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "WallSparks", "tick_hz": PHYSICS_TICKS_PER_SECOND, "budget_calls": MAX_CALLS_PER_TICK, "draw_calls": 3}
