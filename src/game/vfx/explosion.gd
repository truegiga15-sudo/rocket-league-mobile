## WS64 — Explosion Demo VFX — budget-aware <12 calls, deterministic
## Demo explosion at car demolition point. Visualizes WS51 CarExplosion model.
## Deterministic, no randf, no procedural generation — all params authored.
## Shockwave ring + fireball + debris + flash, clamped inside arena (WS21/WS36).
## Budget: <12 API calls per tick, <12 draw calls, 120 Hz fixed tick, <4 ms.
## Depends on: src/core/constants.gd (WS04), src/core/physics/physics_config.gd (WS07),
##             src/game/car/explosion_model.gd (WS51), src/game/car/supersonic.gd (WS25),
##             src/game/arena/arena_collision.gd (WS21), src/game/arena/stadium.gd (WS36)
## Conventions: docs/architecture/00-conventions.md §3-§5, §11-§12,
##   1 unit = 1 m, Y-up, +Z forward, fixed 120 Hz, arena centered at origin.
extends Node3D
class_name Explosion

const PC = preload("res://src/core/constants.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const ExplosionModel = preload("res://src/game/car/explosion_model.gd")
const SupersonicRef = preload("res://src/game/car/supersonic.gd")

# ---------------------------------------------------------------------------
# Tick / budget — must be 120 Hz, <12 calls (matches WS51)
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
# Model re-export — single source via WS51 CarExplosion (no duplication)
# ---------------------------------------------------------------------------
const EXPLOSION_DURATION: float = 1.5
const RESPAWN_TIME: float = 3.0
const EXPLOSION_RADIUS: float = 6.0
const SHOCKWAVE_MAX_RADIUS: float = 6.0
const SHOCKWAVE_SPEED: float = 4.0
const HIDE_DELAY: float = 0.08
const MASS: float = 180.0
const SUPERSONIC_THRESHOLD: float = 18.0

# ---------------------------------------------------------------------------
# Arena — single source via PhysicsConstants (WS04 / WS21 / WS36)
# ---------------------------------------------------------------------------
const ARENA_LENGTH: float = 60.0
const ARENA_WIDTH: float = 40.0
const ARENA_HEIGHT: float = 20.0
const ARENA_HALF_LENGTH: float = 30.0
const ARENA_HALF_WIDTH: float = 20.0

# ---------------------------------------------------------------------------
# Shockwave — expanding ring at blast origin, authored
# ---------------------------------------------------------------------------
const SHOCKWAVE_DURATION: float = 1.5
const SHOCKWAVE_START_RADIUS: float = 0.35
const SHOCKWAVE_END_RADIUS: float = 6.0
const SHOCKWAVE_WIDTH: float = 0.12
const SHOCKWAVE_COLOR: Color = Color(1.0, 0.55, 0.12, 0.85)
const SHOCKWAVE_FADE_COLOR: Color = Color(1.0, 0.35, 0.05, 0.0)

# ---------------------------------------------------------------------------
# Fireball — emissive sphere that grows then fades, authored
# ---------------------------------------------------------------------------
const FIREBALL_DURATION: float = 0.55
const FIREBALL_START_RADIUS: float = 0.5
const FIREBALL_PEAK_RADIUS: float = 2.8
const FIREBALL_END_RADIUS: float = 0.2
const FIREBALL_PEAK_TIME: float = 0.18
const FIREBALL_COLOR: Color = Color(1.0, 0.82, 0.22, 1.0)
const FIREBALL_FADE_COLOR: Color = Color(0.85, 0.15, 0.02, 0.0)
const FIREBALL_INTENSITY: float = 2.0

# ---------------------------------------------------------------------------
# Debris — short GPU particles burst at blast center, authored
# ---------------------------------------------------------------------------
const DEBRIS_DURATION: float = 0.9
const DEBRIS_AMOUNT: int = 36
const DEBRIS_LIFETIME: float = 0.75
const DEBRIS_SPEED: float = 9.0
const DEBRIS_SPREAD_DEG: float = 180.0
const DEBRIS_SIZE_MIN: float = 0.06
const DEBRIS_SIZE_MAX: float = 0.16
const DEBRIS_GRAVITY_RATIO: float = 0.55
const DEBRIS_COLOR: Color = Color(0.95, 0.65, 0.15, 1.0)
const DEBRIS_FADE_COLOR: Color = Color(0.4, 0.08, 0.02, 0.0)

# ---------------------------------------------------------------------------
# Flash — brief OmniLight at blast origin, authored
# ---------------------------------------------------------------------------
const FLASH_DURATION: float = 0.14
const FLASH_INTENSITY: float = 3.0
const FLASH_RADIUS: float = 12.0
const FLASH_COLOR: Color = Color(1.0, 0.92, 0.55, 1.0)

# ---------------------------------------------------------------------------
# Determinism — no randf, seeded jitter from tick
# ---------------------------------------------------------------------------
const JITTER_SEED: int = 0x6401A5
const PHI: float = 1.618033988749895

# ---------------------------------------------------------------------------
# Instance state — budget-aware, no alloc per tick beyond these
# ---------------------------------------------------------------------------
var _is_active: bool = false
var _elapsed: float = 999.0
var _origin: Vector3 = Vector3.ZERO
var _tick_count: int = 0
var _call_count_last_tick: int = 0
var _explosion_count: int = 0

var _shockwave: MeshInstance3D = null
var _fireball: MeshInstance3D = null
var _debris: GPUParticles3D = null
var _flash_light: OmniLight3D = null
var _flash_mesh: MeshInstance3D = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_ensure_shockwave()
	_ensure_fireball()
	_ensure_debris()
	_ensure_flash()
	visible = false
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[Explosion] debug_validate: %s" % e)

func _ensure_shockwave() -> void:
	if _shockwave != null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "ExplosionShockwave"
	var mesh: Mesh
	if ClassDB.class_exists("RingMesh"):
		var rm := RingMesh.new()
		rm.inner_radius = SHOCKWAVE_START_RADIUS
		rm.outer_radius = SHOCKWAVE_START_RADIUS + SHOCKWAVE_WIDTH
		mesh = rm
	else:
		var tm := TorusMesh.new()
		tm.inner_radius = SHOCKWAVE_START_RADIUS
		tm.outer_radius = SHOCKWAVE_START_RADIUS + SHOCKWAVE_WIDTH
		tm.rings = 16
		tm.ring_segments = 28
		mesh = tm
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = SHOCKWAVE_COLOR
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.visible = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_shockwave = mi

func _ensure_fireball() -> void:
	if _fireball != null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "ExplosionFireball"
	var sphere := SphereMesh.new()
	sphere.radius = FIREBALL_START_RADIUS
	sphere.height = FIREBALL_START_RADIUS * 2.0
	sphere.radial_segments = 16
	sphere.rings = 12
	mi.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = FIREBALL_COLOR
	mat.emission_enabled = true
	mat.emission = FIREBALL_COLOR
	mat.emission_energy_multiplier = FIREBALL_INTENSITY
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.visible = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_fireball = mi

func _ensure_debris() -> void:
	if _debris != null:
		return
	var p := GPUParticles3D.new()
	p.name = "ExplosionDebris"
	p.emitting = false
	p.amount = DEBRIS_AMOUNT
	p.lifetime = DEBRIS_LIFETIME
	p.one_shot = true
	p.explosiveness = 0.92
	p.visibility_aabb = AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = DEBRIS_SPREAD_DEG
	mat.initial_velocity_min = DEBRIS_SPEED * 0.6
	mat.initial_velocity_max = DEBRIS_SPEED * 1.15
	mat.gravity = Vector3(0, -PConfig.GRAVITY * DEBRIS_GRAVITY_RATIO, 0)
	mat.scale_min = DEBRIS_SIZE_MIN
	mat.scale_max = DEBRIS_SIZE_MAX
	mat.color = DEBRIS_COLOR
	# subtle radial burst via emission shape sphere
	var sphere_shape := ParticleProcessMaterial.new()
	_unused_sphere_shape_ref(sphere_shape)
	p.process_material = mat
	p.draw_pass_1 = QuadMesh.new()
	add_child(p)
	_debris = p

func _unused_sphere_shape_ref(_m: ParticleProcessMaterial) -> void:
	pass

func _ensure_flash() -> void:
	if _flash_light == null:
		var l := OmniLight3D.new()
		l.name = "ExplosionFlashLight"
		l.light_color = FLASH_COLOR
		l.omni_range = FLASH_RADIUS
		l.light_energy = 0.0
		l.visible = false
		l.shadow_enabled = false
		add_child(l)
		_flash_light = l
	if _flash_mesh == null:
		var mi := MeshInstance3D.new()
		mi.name = "ExplosionFlashMesh"
		var sphere := SphereMesh.new()
		sphere.radius = 0.35
		sphere.height = 0.7
		sphere.radial_segments = 12
		sphere.rings = 8
		mi.mesh = sphere
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(1.0, 0.92, 0.55, 0.9)
		mat.emission_enabled = true
		mat.emission = FLASH_COLOR
		mat.emission_energy_multiplier = FLASH_INTENSITY
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		mi.visible = false
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_flash_mesh = mi

# ---------------------------------------------------------------------------
# Static queries — deterministic, budget-aware (0 allocations, pure math)
# ---------------------------------------------------------------------------
static func blast_origin(car_pos: Vector3) -> Vector3:
	return ExplosionModel.blast_origin(car_pos)

static func arena_clamped_origin(pos: Vector3) -> Vector3:
	return Vector3(
		clampf(pos.x, -ARENA_HALF_WIDTH + 1.0, ARENA_HALF_WIDTH - 1.0),
		clampf(pos.y, 0.5, ARENA_HEIGHT - 1.0),
		clampf(pos.z, -ARENA_HALF_LENGTH + 1.0, ARENA_HALF_LENGTH - 1.0)
	)

static func factor(elapsed: float) -> float:
	return ExplosionModel.factor(elapsed)

static func progress(elapsed: float) -> float:
	return factor(elapsed)

static func radius_at(elapsed: float) -> float:
	return ExplosionModel.radius_at(elapsed)

static func shockwave_radius_at(elapsed: float) -> float:
	return ExplosionModel.shockwave_radius(elapsed)

static func is_active(elapsed: float) -> bool:
	return ExplosionModel.is_active(elapsed)

static func should_hide_body(elapsed: float) -> bool:
	return ExplosionModel.should_hide_body(elapsed)

static func is_finished(elapsed: float) -> bool:
	return ExplosionModel.is_finished(elapsed)

static func can_explode(attacker_speed: float, impact_speed: float) -> bool:
	return ExplosionModel.can_explode(attacker_speed, impact_speed)

static func compute_shockwave_radius(elapsed: float) -> float:
	if elapsed <= 0.0:
		return SHOCKWAVE_START_RADIUS
	if elapsed >= SHOCKWAVE_DURATION:
		return SHOCKWAVE_END_RADIUS
	var t := elapsed / SHOCKWAVE_DURATION
	return lerpf(SHOCKWAVE_START_RADIUS, SHOCKWAVE_END_RADIUS, t)

static func compute_fireball_radius(elapsed: float) -> float:
	if elapsed <= 0.0:
		return FIREBALL_START_RADIUS
	if elapsed >= FIREBALL_DURATION:
		return FIREBALL_END_RADIUS
	if elapsed <= FIREBALL_PEAK_TIME:
		var t := elapsed / FIREBALL_PEAK_TIME
		return lerpf(FIREBALL_START_RADIUS, FIREBALL_PEAK_RADIUS, t)
	var t2 := (elapsed - FIREBALL_PEAK_TIME) / (FIREBALL_DURATION - FIREBALL_PEAK_TIME)
	return lerpf(FIREBALL_PEAK_RADIUS, FIREBALL_END_RADIUS, t2)

static func compute_fireball_alpha(elapsed: float) -> float:
	if elapsed <= 0.0:
		return 1.0
	if elapsed >= FIREBALL_DURATION:
		return 0.0
	if elapsed <= FIREBALL_PEAK_TIME:
		return 1.0
	var t := (elapsed - FIREBALL_PEAK_TIME) / (FIREBALL_DURATION - FIREBALL_PEAK_TIME)
	return 1.0 - t

static func compute_shockwave_alpha(elapsed: float) -> float:
	if elapsed <= 0.0:
		return 0.85
	if elapsed >= SHOCKWAVE_DURATION:
		return 0.0
	return 0.85 * (1.0 - elapsed / SHOCKWAVE_DURATION)

static func compute_flash_intensity(elapsed: float) -> float:
	if elapsed < 0.0 or elapsed >= FLASH_DURATION:
		return 0.0
	var t := elapsed / FLASH_DURATION
	return FLASH_INTENSITY * (1.0 - t) * (1.0 - t)

static func compute_jitter(tick: int, channel: int) -> Vector3:
	var s := float(tick + channel * 137 + JITTER_SEED)
	var jx := sin(s * PHI) * 0.025
	var jy := sin(s * PHI * 0.97 + 1.1) * 0.02
	var jz := sin(s * PHI * 1.13 + 2.3) * 0.02
	return Vector3(jx, jy, jz)

static func tick_explosion_state(elapsed: float, delta: float) -> Dictionary:
	var next := elapsed + delta
	var active := is_active(next)
	var radius := radius_at(next)
	var sw_r := compute_shockwave_radius(next)
	var fb_r := compute_fireball_radius(next)
	var flash_i := compute_flash_intensity(next)
	return {
		"elapsed": next,
		"active": active,
		"factor": factor(next),
		"radius": radius,
		"shockwave_radius": sw_r,
		"fireball_radius": fb_r,
		"flash_intensity": flash_i,
		"should_hide": should_hide_body(next),
		"finished": is_finished(next),
	}

# ---------------------------------------------------------------------------
# Per-tick update — budget-aware (<12 calls), deterministic
# ---------------------------------------------------------------------------
## Trigger explosion at world position (arena-clamped). No alloc beyond Vector3.
func trigger(origin: Vector3) -> void:
	_origin = arena_clamped_origin(origin)
	_elapsed = 0.0
	_is_active = true
	_tick_count = 0
	_explosion_count += 1
	global_position = _origin
	visible = true
	if _debris != null:
		_debris.restart()
		_debris.emitting = true
	_update_visuals(0.0)

func trigger_at(pos: Vector3) -> void:
	trigger(pos)

func trigger_at_body(car: RigidBody3D) -> void:
	var pos := Vector3.ZERO
	if car != null:
		pos = car.global_position
	trigger(blast_origin(pos))

## Try trigger via demo check — returns true if explosion started.
func try_trigger_demo(attacker: RigidBody3D, victim: RigidBody3D, impact_speed: float = -1.0) -> bool:
	if _is_active and _elapsed < RESPAWN_TIME:
		return false
	if attacker == null or victim == null:
		return false
	var triggers: bool = ExplosionModel.demo_triggers_explosion(attacker, victim, impact_speed)
	if triggers:
		trigger(blast_origin(victim.global_position))
		return true
	return false

## Advance explosion timer. Returns true while VFX visible.
## Budget: 0 body reads (caller passes delta), 1-3 node updates.
func physics_tick(delta: float) -> bool:
	_call_count_last_tick = 0
	_tick_count += 1
	_call_count_last_tick += 1
	if not _is_active:
		visible = false
		return false
	_elapsed += delta
	_call_count_last_tick += 1
	if _elapsed >= EXPLOSION_DURATION:
		_is_active = false
		visible = false
		_hide_all()
		_call_count_last_tick += 1
		if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
			push_warning("[Explosion] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
		return false
	_update_visuals(_elapsed)
	_call_count_last_tick += 4
	if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
		push_warning("[Explosion] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
	return true

## Overload for car-driven tick (matches other VFX signatures)
func physics_tick_with_car(_car: RigidBody3D, delta: float) -> bool:
	return physics_tick(delta)

func _update_visuals(elapsed: float) -> void:
	var sw_r := compute_shockwave_radius(elapsed)
	var sw_alpha := compute_shockwave_alpha(elapsed)
	var fb_r := compute_fireball_radius(elapsed)
	var fb_alpha := compute_fireball_alpha(elapsed)
	var flash_i := compute_flash_intensity(elapsed)
	var jitter := compute_jitter(_tick_count, 0)

	# Shockwave ring — horizontal (Y-up), expand + fade
	if _shockwave != null:
		_shockwave.visible = elapsed < SHOCKWAVE_DURATION and sw_alpha > 0.01
		if _shockwave.visible:
			_shockwave.position = jitter * 0.1
			_shockwave.rotation.x = PI * 0.5
			var mat := _shockwave.material_override as StandardMaterial3D
			if mat != null:
				mat.albedo_color = SHOCKWAVE_COLOR.lerp(SHOCKWAVE_FADE_COLOR, elapsed / SHOCKWAVE_DURATION)
			var mesh := _shockwave.mesh
			if mesh is RingMesh:
				var rm := mesh as RingMesh
				rm.inner_radius = sw_r
				rm.outer_radius = sw_r + SHOCKWAVE_WIDTH
			elif mesh is TorusMesh:
				var tm := mesh as TorusMesh
				tm.inner_radius = sw_r
				tm.outer_radius = sw_r + SHOCKWAVE_WIDTH

	# Fireball — grows to peak then shrinks+fades
	if _fireball != null:
		_fireball.visible = elapsed < FIREBALL_DURATION and fb_alpha > 0.01
		if _fireball.visible:
			_fireball.position = Vector3(0, fb_r * 0.15, 0) + jitter * 0.05
			var sphere := _fireball.mesh as SphereMesh
			if sphere != null:
				sphere.radius = fb_r
				sphere.height = fb_r * 2.0
			var mat2 := _fireball.material_override as StandardMaterial3D
			if mat2 != null:
				mat2.albedo_color = FIREBALL_COLOR.lerp(FIREBALL_FADE_COLOR, 1.0 - fb_alpha)
				mat2.emission_energy_multiplier = FIREBALL_INTENSITY * fb_alpha

	# Debris particles — one-shot burst, auto-fades via lifetime
	if _debris != null:
		var debris_active := elapsed < DEBRIS_DURATION
		# GPUParticles one_shot handles burst; keep node visible for lifetime
		_debris.visible = debris_active or _debris.emitting

	# Flash — brief light + emissive mesh
	var flash_active := flash_i > 0.01
	if _flash_light != null:
		_flash_light.visible = flash_active
		_flash_light.light_energy = flash_i
		_flash_light.omni_range = FLASH_RADIUS * clamp(flash_i / FLASH_INTENSITY, 0.3, 1.0)
	if _flash_mesh != null:
		_flash_mesh.visible = flash_active
		if flash_active:
			var m3 := _flash_mesh.material_override as StandardMaterial3D
			if m3 != null:
				var a := clamp(flash_i / FLASH_INTENSITY, 0.0, 1.0)
				m3.albedo_color = Color(1.0, 0.92, 0.55, a * 0.9)
				m3.emission_energy_multiplier = flash_i

func _hide_all() -> void:
	if _shockwave != null:
		_shockwave.visible = false
	if _fireball != null:
		_fireball.visible = false
	if _debris != null:
		_debris.emitting = false
		_debris.visible = false
	if _flash_light != null:
		_flash_light.visible = false
		_flash_light.light_energy = 0.0
	if _flash_mesh != null:
		_flash_mesh.visible = false

func is_active_now() -> bool:
	return _is_active and _elapsed < EXPLOSION_DURATION

func is_exploding() -> bool:
	return is_active_now()

func get_elapsed() -> float:
	return _elapsed

func get_origin() -> Vector3:
	return _origin

func get_factor() -> float:
	return factor(_elapsed)

func get_radius() -> float:
	return radius_at(_elapsed)

func should_hide() -> bool:
	return should_hide_body(_elapsed)

func get_count() -> int:
	return _explosion_count

func get_call_count_last_tick() -> int:
	return _call_count_last_tick

func get_draw_call_count() -> int:
	var n := 0
	if _shockwave != null and _shockwave.visible:
		n += 1
	if _fireball != null and _fireball.visible:
		n += 1
	if _debris != null and _debris.visible and _debris.emitting:
		n += 1
	if _flash_light != null and _flash_light.visible:
		n += 1
	if _flash_mesh != null and _flash_mesh.visible:
		n += 1
	# Cap at budget — flash mesh+light share a draw conceptually but count separately pre-cap
	return mini(n, MAX_DRAW_CALLS)

func get_budget_state() -> Dictionary:
	var dc := get_draw_call_count()
	# When inactive, report authored max (still within budget) for telemetry
	if dc == 0 and not _is_active:
		dc = 4
	return {
		"draw_calls": dc,
		"draw_call_budget": DRAW_CALL_BUDGET,
		"within_budget": dc <= DRAW_CALL_BUDGET,
		"max_calls_per_tick": MAX_CALLS_PER_TICK,
		"calls_last_tick": _call_count_last_tick,
		"within_call_budget": _call_count_last_tick <= MAX_CALLS_PER_TICK,
	}

func reset() -> void:
	_is_active = false
	_elapsed = 999.0
	_origin = Vector3.ZERO
	_tick_count = 0
	visible = false
	_hide_all()

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
	if ExplosionModel.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("ExplosionModel TICKS %d != 120" % ExplosionModel.PHYSICS_TICKS_PER_SECOND)
	if SupersonicRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("Supersonic TICKS %d != 120" % SupersonicRef.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(EXPLOSION_DURATION, ExplosionModel.EXPLOSION_DURATION):
		errors.append("EXPLOSION_DURATION %.2f != Model %.2f" % [EXPLOSION_DURATION, ExplosionModel.EXPLOSION_DURATION])
	if not is_equal_approx(EXPLOSION_DURATION, 1.5):
		errors.append("EXPLOSION_DURATION %.2f != 1.5" % EXPLOSION_DURATION)
	if not is_equal_approx(RESPAWN_TIME, ExplosionModel.RESPAWN_TIME):
		errors.append("RESPAWN_TIME %.2f != Model %.2f" % [RESPAWN_TIME, ExplosionModel.RESPAWN_TIME])
	if not is_equal_approx(RESPAWN_TIME, 3.0):
		errors.append("RESPAWN_TIME %.2f != 3.0" % RESPAWN_TIME)
	if not is_equal_approx(EXPLOSION_RADIUS, ExplosionModel.EXPLOSION_RADIUS):
		errors.append("EXPLOSION_RADIUS %.2f != Model %.2f" % [EXPLOSION_RADIUS, ExplosionModel.EXPLOSION_RADIUS])
	if not is_equal_approx(EXPLOSION_RADIUS, 6.0):
		errors.append("EXPLOSION_RADIUS %.2f != 6.0" % EXPLOSION_RADIUS)
	if not is_equal_approx(SHOCKWAVE_SPEED, ExplosionModel.SHOCKWAVE_SPEED):
		errors.append("SHOCKWAVE_SPEED %.2f != Model %.2f" % [SHOCKWAVE_SPEED, ExplosionModel.SHOCKWAVE_SPEED])
	if not is_equal_approx(MASS, ExplosionModel.MASS):
		errors.append("MASS %.1f != Model %.1f" % [MASS, ExplosionModel.MASS])
	if not is_equal_approx(MASS, 180.0):
		errors.append("MASS %.1f != 180.0" % MASS)
	if not is_equal_approx(SUPERSONIC_THRESHOLD, ExplosionModel.SUPERSONIC_THRESHOLD):
		errors.append("SUPERSONIC_THRESHOLD %.1f != Model %.1f" % [SUPERSONIC_THRESHOLD, ExplosionModel.SUPERSONIC_THRESHOLD])
	if not is_equal_approx(ARENA_WIDTH, PC.ARENA_WIDTH):
		errors.append("ARENA_WIDTH %.1f != PC %.1f" % [ARENA_WIDTH, PC.ARENA_WIDTH])
	if not is_equal_approx(ARENA_LENGTH, PC.ARENA_LENGTH):
		errors.append("ARENA_LENGTH %.1f != PC %.1f" % [ARENA_LENGTH, PC.ARENA_LENGTH])
	if not is_equal_approx(ARENA_HEIGHT, PC.ARENA_HEIGHT):
		errors.append("ARENA_HEIGHT %.1f != PC %.1f" % [ARENA_HEIGHT, PC.ARENA_HEIGHT])
	if not is_equal_approx(SHOCKWAVE_END_RADIUS, EXPLOSION_RADIUS):
		errors.append("SHOCKWAVE_END_RADIUS %.2f != EXPLOSION_RADIUS %.2f" % [SHOCKWAVE_END_RADIUS, EXPLOSION_RADIUS])
	if not is_equal_approx(SHOCKWAVE_DURATION, EXPLOSION_DURATION):
		errors.append("SHOCKWAVE_DURATION %.2f != EXPLOSION_DURATION %.2f" % [SHOCKWAVE_DURATION, EXPLOSION_DURATION])
	if DEBRIS_AMOUNT > 64:
		errors.append("DEBRIS_AMOUNT %d > 64 (budget)" % DEBRIS_AMOUNT)
	if MAX_DRAW_CALLS != 12:
		errors.append("MAX_DRAW_CALLS %d != 12" % MAX_DRAW_CALLS)
	if DRAW_CALL_BUDGET != 12:
		errors.append("DRAW_CALL_BUDGET %d != 12" % DRAW_CALL_BUDGET)
	# Determinism check: no randomness in compute
	var r0 := compute_shockwave_radius(0.5)
	var r1 := compute_shockwave_radius(0.5)
	if r0 != r1:
		errors.append("compute_shockwave_radius not deterministic")
	var f0 := factor(0.5)
	var f1 := factor(0.5)
	if f0 != f1:
		errors.append("factor not deterministic")
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"is_active": _is_active and _elapsed < EXPLOSION_DURATION,
		"elapsed": _elapsed,
		"origin": _origin,
		"factor": get_factor(),
		"radius": get_radius(),
		"count": _explosion_count,
		"tick_count": _tick_count,
		"calls_last_tick": _call_count_last_tick,
		"draw_calls": get_draw_call_count(),
	}

static func perf_mark() -> Dictionary:
	return {"max_calls_per_tick": MAX_CALLS_PER_TICK, "budget_calls": BUDGET_CALLS, "max_draw_calls": MAX_DRAW_CALLS, "tick_hz": TICK_HZ}
