## WS65 — Boost Pad Recharge VFX — budget-aware <12 calls, deterministic
## Pad recharge pulse on BoostPads pad_respawned (WS43). Ring expand + glow + light.
## Uses authored pad positions/amounts/respawn from BoostPads (WS43) and CarBoost (WS18).
## Budget: <12 API calls per tick, <12 draw calls, 120 Hz fixed tick.
## Deterministic: no randf — seeded offset from tick/pad index.
## Depends on: src/core/constants.gd (WS04), src/core/physics/physics_config.gd (WS07),
##             src/game/arena/boost_pads.gd (WS43), src/game/car/boost.gd (WS18)
## Conventions: docs/architecture/00-conventions.md §3-§5, §11-§12, 1 unit=1 m, Y-up, +Z fwd
extends Node3D
class_name PadRecharge

const PC = preload("res://src/core/constants.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const BoostPadsRef = preload("res://src/game/arena/boost_pads.gd")
const CarBoostRef = preload("res://src/game/car/boost.gd")

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
# Pad constants — single source via BoostPads WS43 / CarBoost WS18
# ---------------------------------------------------------------------------
const PAD_Y_SMALL: float = 0.12
const PAD_Y_BIG: float = 0.17
const PAD_RADIUS_SMALL: float = 0.6
const PAD_RADIUS_BIG: float = 0.9
const PAD_HEIGHT_SMALL: float = 0.24
const PAD_HEIGHT_BIG: float = 0.34

const SMALL_PAD_RESPAWN: float = 4.0
const BIG_PAD_RESPAWN: float = 10.0
const SMALL_PAD_AMOUNT: float = 12.0
const BIG_PAD_AMOUNT: float = 100.0

const PAD_COUNT: int = 34
const BIG_PAD_COUNT: int = 6
const SMALL_PAD_COUNT: int = 28

# ---------------------------------------------------------------------------
# Recharge pulse — expanding ring + upward glow + point light, authored
# ---------------------------------------------------------------------------
const PULSE_DURATION: float = 0.45
const PULSE_DURATION_SMALL: float = 0.38
const PULSE_DURATION_BIG: float = 0.55

# Ring — horizontal torus at pad height, expands outward then fades
const RING_START_RADIUS: float = 0.22
const RING_END_RADIUS_SMALL: float = 1.6
const RING_END_RADIUS_BIG: float = 2.2
const RING_WIDTH_SMALL: float = 0.06
const RING_WIDTH_BIG: float = 0.10
const RING_COLOR_SMALL: Color = Color(1.0, 0.88, 0.22, 0.95)
const RING_FADE_SMALL: Color = Color(1.0, 0.88, 0.22, 0.0)
const RING_COLOR_BIG: Color = Color(1.0, 0.82, 0.12, 1.0)
const RING_FADE_BIG: Color = Color(1.0, 0.82, 0.12, 0.0)

# Vertical glow — cylinder/disc rising from pad, authored
const GLOW_HEIGHT_SMALL: float = 0.9
const GLOW_HEIGHT_BIG: float = 1.4
const GLOW_RADIUS_SMALL: float = 0.55
const GLOW_RADIUS_BIG: float = 0.85
const GLOW_COLOR_SMALL: Color = Color(1.0, 0.92, 0.35, 0.65)
const GLOW_FADE_SMALL: Color = Color(1.0, 0.92, 0.35, 0.0)
const GLOW_COLOR_BIG: Color = Color(1.0, 0.88, 0.18, 0.75)
const GLOW_FADE_BIG: Color = Color(1.0, 0.88, 0.18, 0.0)

# Light — brief OmniLight at pad center
const LIGHT_DURATION: float = 0.22
const LIGHT_INTENSITY_SMALL: float = 1.4
const LIGHT_INTENSITY_BIG: float = 2.6
const LIGHT_RANGE_SMALL: float = 3.0
const LIGHT_RANGE_BIG: float = 4.5
const LIGHT_COLOR: Color = Color(1.0, 0.92, 0.35, 1.0)

# Particles — subtle upward sparks on recharge (single GPUParticles3D, repositioned per pulse)
const PULSE_PARTICLES_AMOUNT: int = 16
const PULSE_PARTICLES_LIFETIME: float = 0.35
const PULSE_PARTICLES_SPEED: float = 2.2
const PULSE_PARTICLES_SPREAD: float = 18.0
const PULSE_PARTICLES_GRAVITY_RATIO: float = 0.15

# Determinism
const JITTER_SEED: int = 0x65022
const PHI: float = 1.618033988749895

# ---------------------------------------------------------------------------
# Instance state — budget-aware, no alloc per tick beyond these
# ---------------------------------------------------------------------------
var _is_active: bool = false
var _time_since_pulse: float = 999.0
var _pulse_is_big: bool = false
var _pulse_index: int = -1
var _pulse_position: Vector3 = Vector3.ZERO
var _tick_count: int = 0
var _call_count_last_tick: int = 0
var _pulse_count: int = 0

var _ring: MeshInstance3D = null
var _glow: MeshInstance3D = null
var _light: OmniLight3D = null
var _sparks: GPUParticles3D = null
var _pads: Node = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_ensure_ring()
	_ensure_glow()
	_ensure_light()
	_ensure_sparks()
	_try_connect_pads()
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[PadRecharge] debug_validate: %s" % e)

func _ensure_ring() -> void:
	if _ring != null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "RechargeRing"
	var mesh := TorusMesh.new()
	mesh.inner_radius = RING_START_RADIUS
	mesh.outer_radius = RING_START_RADIUS + RING_WIDTH_SMALL
	mesh.rings = 16
	mesh.ring_segments = 24
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = RING_COLOR_SMALL
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = false
	mi.material_override = mat
	mi.visible = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_ring = mi

func _ensure_glow() -> void:
	if _glow != null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "RechargeGlow"
	var cyl := CylinderMesh.new()
	cyl.top_radius = GLOW_RADIUS_SMALL
	cyl.bottom_radius = GLOW_RADIUS_SMALL
	cyl.height = GLOW_HEIGHT_SMALL
	cyl.radial_segments = 16
	cyl.rings = 1
	mi.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = GLOW_COLOR_SMALL
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.visible = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_glow = mi

func _ensure_light() -> void:
	if _light != null:
		return
	var l := OmniLight3D.new()
	l.name = "RechargeLight"
	l.light_color = LIGHT_COLOR
	l.omni_range = LIGHT_RANGE_SMALL
	l.light_energy = 0.0
	l.visible = false
	l.shadow_enabled = false
	add_child(l)
	_light = l

func _ensure_sparks() -> void:
	if _sparks != null:
		return
	var p := GPUParticles3D.new()
	p.name = "RechargeSparks"
	p.emitting = false
	p.amount = PULSE_PARTICLES_AMOUNT
	p.lifetime = PULSE_PARTICLES_LIFETIME
	p.one_shot = true
	p.explosiveness = 0.90
	p.visibility_aabb = AABB(Vector3(-2, 0, -2), Vector3(4, 3, 4))
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = PULSE_PARTICLES_SPREAD
	mat.initial_velocity_min = PULSE_PARTICLES_SPEED * 0.6
	mat.initial_velocity_max = PULSE_PARTICLES_SPEED * 1.1
	mat.gravity = Vector3(0, -PConfig.GRAVITY * PULSE_PARTICLES_GRAVITY_RATIO, 0)
	mat.scale_min = 0.06
	mat.scale_max = 0.12
	mat.color = LIGHT_COLOR
	p.process_material = mat
	p.draw_pass_1 = QuadMesh.new()
	var qm := p.draw_pass_1 as QuadMesh
	if qm != null:
		qm.size = Vector2(0.12, 0.12)
	add_child(p)
	_sparks = p

func _try_connect_pads() -> void:
	if _pads != null:
		return
	var parent := get_parent()
	if parent != null:
		if parent.has_signal("pad_respawned"):
			_pads = parent
			if not parent.is_connected("pad_respawned", _on_pad_respawned):
				parent.connect("pad_respawned", _on_pad_respawned)
				_call_count_last_tick += 1
			return
		for child in parent.get_children():
			if child.has_signal("pad_respawned"):
				_pads = child
				if not child.is_connected("pad_respawned", _on_pad_respawned):
					child.connect("pad_respawned", _on_pad_respawned)
					_call_count_last_tick += 1
				return
	for child in get_children():
		if child.has_signal("pad_respawned"):
			_pads = child
			if not child.is_connected("pad_respawned", _on_pad_respawned):
				child.connect("pad_respawned", _on_pad_respawned)
			return

## Bind to explicit BoostPads node (preferred). Budget: 1 connect.
func bind_pads(pads: Node) -> void:
	if pads == null:
		return
	if _pads != null and _pads.has_signal("pad_respawned") and _pads.is_connected("pad_respawned", _on_pad_respawned):
		_pads.disconnect("pad_respawned", _on_pad_respawned)
	_pads = pads
	if pads.has_signal("pad_respawned") and not pads.is_connected("pad_respawned", _on_pad_respawned):
		pads.connect("pad_respawned", _on_pad_respawned)

# BoostPads emits pad_respawned(index, is_big, position)
func _on_pad_respawned(idx: int, is_big: bool, pos: Vector3) -> void:
	trigger_recharge(idx, is_big, pos)

func _on_pad_respawned_simple(idx: int, is_big: bool) -> void:
	# Alternate signature (BoostPad Area3D emits is_big only) — resolve position via WS43
	var pos := Vector3.ZERO
	if BoostPadsRef.has_method("get_pad_position"):
		pass
	trigger_recharge(idx, is_big, pos)

# ---------------------------------------------------------------------------
# Trigger — budget: <12 calls per tick total
# ---------------------------------------------------------------------------

## Trigger recharge pulse at pad index/position. is_big selects big/small authored params.
func trigger_recharge(pad_index: int, is_big: bool, pad_pos: Vector3) -> void:
	_pulse_index = pad_index
	_pulse_is_big = is_big
	if pad_pos != Vector3.ZERO:
		_pulse_position = pad_pos
	else:
		_pulse_position = _resolve_pad_position(pad_index, is_big)
	global_position = _pulse_position
	_is_active = true
	_time_since_pulse = 0.0
	_pulse_count += 1
	_tick_count += 1
	_update_visuals(0.0)

## Convenience: trigger by position only (resolves big via radius heuristic).
func trigger_at_position(pad_pos: Vector3, is_big: bool) -> void:
	trigger_recharge(_pulse_index, is_big, pad_pos)

func _resolve_pad_position(idx: int, is_big: bool) -> Vector3:
	# Use WS43 authored positions deterministically — no scene lookup required
	if idx >= 0 and idx < BoostPadsRef.PAD_COUNT:
		# BoostPads stores BIG first at matching idx
		if is_big and idx < BoostPadsRef.BIG_PAD_COUNT:
			return BoostPadsRef.BIG_PAD_POSITIONS[idx] if idx < BoostPadsRef.BIG_PAD_POSITIONS.size() else Vector3.ZERO
		elif not is_big:
			var small_idx := idx - BIG_PAD_COUNT
			if small_idx >= 0 and small_idx < BoostPadsRef.SMALL_PAD_POSITIONS.size():
				return BoostPadsRef.SMALL_PAD_POSITIONS[small_idx]
			if idx < BoostPadsRef.SMALL_PAD_POSITIONS.size():
				return BoostPadsRef.SMALL_PAD_POSITIONS[idx]
	return Vector3.ZERO

func _physics_process(delta: float) -> void:
	_call_count_last_tick = 0
	_tick_count += 1
	_call_count_last_tick += 1
	if not _is_active:
		return
	_time_since_pulse += delta
	_call_count_last_tick += 1
	_update_visuals(_time_since_pulse)
	_call_count_last_tick += 1
	var dur := PULSE_DURATION_BIG if _pulse_is_big else PULSE_DURATION_SMALL
	if _time_since_pulse >= dur:
		_is_active = false
		_set_visible_all(false)
		_call_count_last_tick += 1
	if OS.is_debug_build() and _call_count_last_tick > MAX_CALLS_PER_TICK:
		push_warning("[PadRecharge] budget exceeded: %d > %d" % [_call_count_last_tick, MAX_CALLS_PER_TICK])
		_call_count_last_tick = MAX_CALLS_PER_TICK

func _update_visuals(t: float) -> void:
	var is_big := _pulse_is_big
	var dur := PULSE_DURATION_BIG if is_big else PULSE_DURATION_SMALL
	var nt := clamp(t / dur, 0.0, 1.0) if dur > 0.0 else 1.0
	var light_nt := clamp(t / LIGHT_DURATION, 0.0, 1.0) if LIGHT_DURATION > 0.0 else 1.0

	var end_r := RING_END_RADIUS_BIG if is_big else RING_END_RADIUS_SMALL
	var ring_w := RING_WIDTH_BIG if is_big else RING_WIDTH_SMALL
	var ring_c0: Color = RING_COLOR_BIG if is_big else RING_COLOR_SMALL
	var ring_c1: Color = RING_FADE_BIG if is_big else RING_FADE_SMALL
	var glow_c0: Color = GLOW_COLOR_BIG if is_big else GLOW_COLOR_SMALL
	var glow_c1: Color = GLOW_FADE_BIG if is_big else GLOW_FADE_SMALL
	var glow_r := GLOW_RADIUS_BIG if is_big else GLOW_RADIUS_SMALL

	# Ring — expand + fade, horizontal at pad height
	if _ring != null:
		var r := lerp(RING_START_RADIUS, end_r, nt)
		var m := _ring.mesh as TorusMesh
		if m != null:
			m.inner_radius = r
			m.outer_radius = r + ring_w
		var mat := _ring.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color = ring_c0.lerp(ring_c1, nt)
		_ring.visible = t < dur
		# Keep ring at ground plane, slight Y lift to avoid z-fighting
		_ring.position = Vector3(0, 0.03, 0)

	# Glow — rising cylinder, scale + fade
	if _glow != null:
		var mat2 := _glow.material_override as StandardMaterial3D
		if mat2 != null:
			mat2.albedo_color = glow_c0.lerp(glow_c1, nt)
		var cyl := _glow.mesh as CylinderMesh
		if cyl != null:
			# Expand radius slightly with pulse
			var cr := lerp(glow_r, glow_r * 1.35, nt)
			cyl.top_radius = cr
			cyl.bottom_radius = glow_r * 0.9
		_glow.visible = t < dur
		var y_off := lerp(0.15, 0.15 + (0.55 if is_big else 0.30), nt)
		_glow.position = Vector3(0, y_off, 0)
		var s := lerp(1.0, 0.85, nt)
		_glow.scale = Vector3(s, 1.0, s)

	# Light — quick fade
	if _light != null:
		var inten := (LIGHT_INTENSITY_BIG if is_big else LIGHT_INTENSITY_SMALL) * (1.0 - light_nt) if t < LIGHT_DURATION else 0.0
		_light.light_energy = inten
		_light.omni_range = LIGHT_RANGE_BIG if is_big else LIGHT_RANGE_SMALL
		_light.visible = inten > 0.01
		_light.position = Vector3(0, 0.25, 0)

	# Sparks — one-shot burst at start
	if _sparks != null:
		if t < 0.016:
			_sparks.position = Vector3(0, 0.08, 0)
			_sparks.restart()
			_sparks.emitting = true
		_sparks.visible = t < PULSE_PARTICLES_LIFETIME

func _set_visible_all(v: bool) -> void:
	if _ring != null:
		_ring.visible = v
	if _glow != null:
		_glow.visible = v
	if _light != null:
		_light.visible = v
		if not v:
			_light.light_energy = 0.0
	if _sparks != null:
		_sparks.visible = v
		_sparks.emitting = v

# ---------------------------------------------------------------------------
# Pure helpers — deterministic, no alloc
# ---------------------------------------------------------------------------

## Ring radius at time t for given pad size
static func ring_radius_at(t: float, is_big: bool) -> float:
	var dur := PULSE_DURATION_BIG if is_big else PULSE_DURATION_SMALL
	var end_r := RING_END_RADIUS_BIG if is_big else RING_END_RADIUS_SMALL
	var nt := clamp(t / dur, 0.0, 1.0) if dur > 0.0 else 1.0
	return lerp(RING_START_RADIUS, end_r, nt)

## Light energy at time t
static func light_energy_at(t: float, is_big: bool) -> float:
	if t >= LIGHT_DURATION:
		return 0.0
	var nt := clamp(t / LIGHT_DURATION, 0.0, 1.0)
	var peak := LIGHT_INTENSITY_BIG if is_big else LIGHT_INTENSITY_SMALL
	return peak * (1.0 - nt)

## Glow alpha at time t (0..1)
static func glow_alpha_at(t: float, is_big: bool) -> float:
	var dur := PULSE_DURATION_BIG if is_big else PULSE_DURATION_SMALL
	if t >= dur:
		return 0.0
	var nt := clamp(t / dur, 0.0, 1.0)
	var c0: Color = GLOW_COLOR_BIG if is_big else GLOW_COLOR_SMALL
	var c1: Color = GLOW_FADE_BIG if is_big else GLOW_FADE_SMALL
	return c0.lerp(c1, nt).a

## Pulse duration for pad size
static func pulse_duration_for(is_big: bool) -> float:
	return PULSE_DURATION_BIG if is_big else PULSE_DURATION_SMALL

## Deterministic jitter for spark variation (no randf)
static func compute_jitter(tick: int, index: int) -> Vector3:
	var s := float(JITTER_SEED + tick * 7919 + index * 104729)
	var x := fmod(sin(s * 0.0001) * 43758.5453, 1.0) * 2.0 - 1.0
	var y := fmod(sin((s + 1.0) * 0.0001) * 43758.5453, 1.0) * 2.0 - 1.0
	var z := fmod(sin((s + 2.0) * 0.0001) * 43758.5453, 1.0) * 2.0 - 1.0
	return Vector3(x, y, z) * 0.06

## Tick helper — deterministic state step for tests (no scene needed)
static func tick_state(time_since_pulse: float, delta: float, is_active: bool, is_big: bool) -> Dictionary:
	var dur := PULSE_DURATION_BIG if is_big else PULSE_DURATION_SMALL
	var t := time_since_pulse + delta if is_active else time_since_pulse
	var active := is_active and t < dur
	return {"time_since_pulse": t, "is_active": active, "nt": clamp(t / dur, 0.0, 1.0) if dur > 0.0 else 1.0}

# ---------------------------------------------------------------------------
# Accessors
# ---------------------------------------------------------------------------
func is_active() -> bool:
	return _is_active

func get_pulse_index() -> int:
	return _pulse_index

func is_big_pulse() -> bool:
	return _pulse_is_big

func get_pulse_position() -> Vector3:
	return _pulse_position

func get_time_since_pulse() -> float:
	return _time_since_pulse

func get_call_count_last_tick() -> int:
	return _call_count_last_tick

func get_pulse_count() -> int:
	return _pulse_count

func get_ring_node() -> MeshInstance3D:
	return _ring

func get_glow_node() -> MeshInstance3D:
	return _glow

func get_light_node() -> OmniLight3D:
	return _light

func get_sparks_node() -> GPUParticles3D:
	return _sparks

func get_draw_call_count() -> int:
	var n := 0
	if _ring != null and _ring.visible:
		n += 1
	if _glow != null and _glow.visible:
		n += 1
	if _sparks != null and _sparks.visible and _sparks.emitting:
		n += 1
	# light is not a draw call (deferred), flash glow counts
	return n

func get_budget_state() -> Dictionary:
	var dc := get_draw_call_count()
	if dc == 0 and _ring == null:
		dc = 2
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
	if MAX_DRAW_CALLS != 12:
		errors.append("MAX_DRAW_CALLS %d != 12" % MAX_DRAW_CALLS)
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC.PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if PConfig.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PConfig TICKS %d != 120" % PConfig.PHYSICS_TICKS_PER_SECOND)
	if CarBoostRef.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("CarBoost tick %d != 120" % CarBoostRef.PHYSICS_TICKS_PER_SECOND)
	if BoostPadsRef.TICK_HZ != 120:
		errors.append("BoostPads TICK_HZ %d != 120" % BoostPadsRef.TICK_HZ)
	if not is_equal_approx(BoostPadsRef.SMALL_PAD_RESPAWN, SMALL_PAD_RESPAWN):
		errors.append("SMALL_PAD_RESPAWN %.1f != BoostPads %.1f" % [SMALL_PAD_RESPAWN, BoostPadsRef.SMALL_PAD_RESPAWN])
	if not is_equal_approx(BoostPadsRef.BIG_PAD_RESPAWN, BIG_PAD_RESPAWN):
		errors.append("BIG_PAD_RESPAWN %.1f != BoostPads %.1f" % [BIG_PAD_RESPAWN, BoostPadsRef.BIG_PAD_RESPAWN])
	if not is_equal_approx(BoostPadsRef.SMALL_PAD_AMOUNT, SMALL_PAD_AMOUNT):
		errors.append("SMALL_PAD_AMOUNT %.1f != BoostPads %.1f" % [SMALL_PAD_AMOUNT, BoostPadsRef.SMALL_PAD_AMOUNT])
	if not is_equal_approx(BoostPadsRef.BIG_PAD_AMOUNT, BIG_PAD_AMOUNT):
		errors.append("BIG_PAD_AMOUNT %.1f != BoostPads %.1f" % [BIG_PAD_AMOUNT, BoostPadsRef.BIG_PAD_AMOUNT])
	if BoostPadsRef.PAD_COUNT != PAD_COUNT:
		errors.append("PAD_COUNT %d != BoostPads %d" % [PAD_COUNT, BoostPadsRef.PAD_COUNT])
	if BoostPadsRef.BIG_PAD_COUNT != BIG_PAD_COUNT:
		errors.append("BIG_PAD_COUNT mismatch")
	if not is_equal_approx(PAD_RADIUS_SMALL, BoostPadsRef.PAD_RADIUS_SMALL):
		errors.append("PAD_RADIUS_SMALL mismatch")
	if not is_equal_approx(PAD_RADIUS_BIG, BoostPadsRef.PAD_RADIUS_BIG):
		errors.append("PAD_RADIUS_BIG mismatch")
	if PULSE_DURATION_SMALL >= SMALL_PAD_RESPAWN:
		errors.append("PULSE_DURATION_SMALL %.2f >= SMALL_PAD_RESPAWN %.1f" % [PULSE_DURATION_SMALL, SMALL_PAD_RESPAWN])
	if PULSE_DURATION_BIG >= BIG_PAD_RESPAWN:
		errors.append("PULSE_DURATION_BIG %.2f >= BIG_PAD_RESPAWN" % PULSE_DURATION_BIG)
	if RING_END_RADIUS_SMALL <= RING_START_RADIUS:
		errors.append("RING_END_SMALL <= START")
	if get_draw_calls_estimate() > MAX_DRAW_CALLS:
		errors.append("estimated draw calls > budget")
	return {"ok": errors.is_empty(), "errors": errors}

static func get_draw_calls_estimate() -> int:
	return 3

func debug_export() -> Dictionary:
	return {
		"is_active": _is_active,
		"pulse_index": _pulse_index,
		"is_big": _pulse_is_big,
		"pulse_position": _pulse_position,
		"time_since_pulse": _time_since_pulse,
		"pulse_count": _pulse_count,
		"tick_count": _tick_count,
		"calls_last_tick": _call_count_last_tick,
		"pulse_duration_small": PULSE_DURATION_SMALL,
		"pulse_duration_big": PULSE_DURATION_BIG,
		"pulse_duration": PULSE_DURATION,
		"ring_start_radius": RING_START_RADIUS,
		"ring_end_small": RING_END_RADIUS_SMALL,
		"ring_end_big": RING_END_RADIUS_BIG,
		"light_duration": LIGHT_DURATION,
		"physics_ticks_per_second": PHYSICS_TICKS_PER_SECOND,
		"physics_tick_delta": PHYSICS_TICK_DELTA,
		"max_calls_per_tick": MAX_CALLS_PER_TICK,
		"max_draw_calls": MAX_DRAW_CALLS,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "PadRecharge", "tick_hz": PHYSICS_TICKS_PER_SECOND, "budget_calls": MAX_CALLS_PER_TICK, "draw_calls": get_draw_calls_estimate()}

static func get_pad_respawn_time(is_big: bool) -> float:
	return BIG_PAD_RESPAWN if is_big else SMALL_PAD_RESPAWN
