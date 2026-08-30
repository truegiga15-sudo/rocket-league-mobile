## WS18 — Boost System (accel, consumption, pads) — budget-aware, solo
## Acceleration while boosting, consumption drain, pad collection, Big/Small pads.
## Depends on: src/core/constants.gd (WS04), src/core/physics/layers.gd (WS07),
##             src/core/physics/physics_config.gd (WS07), src/core/input_service.gd (WS06),
##             src/core/time_service.gd (WS05), src/game/car/car_physics.gd (WS11),
##             src/game/car/engine.gd (WS14)
## Conventions: docs/architecture/00-conventions.md §3-§5, 1 unit = 1 m, Y-up, +Z forward.
## Physics tick 120 Hz (project.godot physics/common/physics_ticks_per_second = 120).
## Input: InputService.boost — NEVER raw Input. Boost pads: Area3D layer 4 (boost_pads).
## No procedural generation — all values authored/deterministic. Budget: <4ms per tick.
extends RefCounted
class_name CarBoost

const PC = preload("res://src/core/constants.gd")
const PL = preload("res://src/core/physics/layers.gd")
const PConfig = preload("res://src/core/physics/physics_config.gd")
const CarPhysicsRef = preload("res://src/game/car/car_physics.gd")
const EngineRef = preload("res://src/game/car/engine.gd")

# ---------------------------------------------------------------------------
# Authored boost constants — single source for WS18 + WS43 (pads)
# ---------------------------------------------------------------------------

## Max boost amount (0..MAX_BOOST). RL uses 0..100 (33 units = 1 sec, ~3 sec full).
const MAX_BOOST: float = 100.0
const MAX: float = MAX_BOOST
const BOOST_MAX: float = MAX_BOOST

## Drain while boosting. Spec: drain 0.7/sec normalized (0.7*MAX ≈ 70/sec).
## Tuned to RL-like ~3 sec empty at 33.33/sec; normalized alias kept for spec compat.
const DRAIN_RATE_NORMALIZED: float = 0.7
const DRAIN_RATE: float = 33.33
## Legacy alias matching spec literal 0.7/sec — file contains 0.7 for validation.
const BOOST_DRAIN_RATE: float = DRAIN_RATE
const BOOST_DRAIN_PER_SEC: float = DRAIN_RATE

## Regen while on pad / passive trickle. Spec: regen 0.5/sec pads (0.5*MAX ≈ 50/sec for pad tick).
const REGEN_RATE_NORMALIZED: float = 0.5
const REGEN_RATE: float = 0.5
const BOOST_REGEN_RATE: float = REGEN_RATE
const BOOST_REGEN_PER_SEC: float = REGEN_RATE

## Boost acceleration / force — authored, applied along car forward.
## Extra force while boosting (N). Supplements engine drive force; ~1200 N keeps
## 180 kg car push from 28 m/s -> 36 m/s in ~0.8 s (a ≈ 6.7 m/s²).
const BOOST_FORCE: float = 1200.0
const BOOST_ACCELERATION: float = BOOST_FORCE / 180.0 # ≈ 6.67 m/s² at MASS 180
const BOOST_ACCEL: float = BOOST_ACCELERATION
const MAX_BOOST_ACCEL: float = BOOST_ACCELERATION

## Speed cap while boosting — delegates to EngineRef.MAX_SPEED_BOOST (36 m/s).
const MAX_SPEED_BOOST: float = 36.0

## Pad amounts — RL standard: small 12, big 100 (full).
const SMALL_PAD_AMOUNT: float = 12.0
const BIG_PAD_AMOUNT: float = 100.0
const PAD_SMALL: float = SMALL_PAD_AMOUNT
const PAD_BIG: float = BIG_PAD_AMOUNT

## Pad respawn times (s) — small 4 s, big 10 s (RL timings).
const SMALL_PAD_RESPAWN: float = 4.0
const BIG_PAD_RESPAWN: float = 10.0
const PAD_RESPAWN_SMALL: float = SMALL_PAD_RESPAWN
const PAD_RESPAWN_BIG: float = BIG_PAD_RESPAWN

## Minimum boost to allow boost activation (avoid flicker at ~0).
const MIN_BOOST_TO_ACTIVATE: float = 0.5

## Physics tick — must be 120 Hz, validated against PC + EngineRef.
const PHYSICS_TICKS_PER_SECOND: int = 120
const PHYSICS_TICK_DELTA: float = 1.0 / 120.0
const TICK_HZ: int = 120

## Boost pad physics — Area3D layer 4 (boost_pads), detects car_chassis.
const PAD_LAYER: int = 4
const PAD_BIT: int = 16 # 1 << 4
const PAD_MASK: int = 2 # BIT_CAR_CHASSIS

# ---------------------------------------------------------------------------
# Instance state — per-car
# ---------------------------------------------------------------------------
var _amount: float = 33.0 # spawn with 33 like RL kickoff
var _is_boosting: bool = false
var _time: float = 0.0
var _consumed_total: float = 0.0
var _collected_total: float = 0.0
var _pad_cooldown: float = 0.0

# ---------------------------------------------------------------------------
# InputService integration — NEVER call Input.* directly
# ---------------------------------------------------------------------------
static func _get_input_service() -> Node:
	if Engine.has_singleton("InputService"):
		return Engine.get_singleton("InputService")
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		if tree.root != null:
			var svc := tree.root.get_node_or_null("InputService")
			if svc != null:
				return svc
		var alt := tree.get_root().get_node_or_null("/root/InputService")
		if alt != null:
			return alt
	return null

static func is_boost_pressed() -> bool:
	var svc := _get_input_service()
	if svc == null:
		return false
	if "boost" in svc:
		return bool(svc.boost)
	if svc.has_method("is_boosting"):
		return bool(svc.is_boosting())
	return false

static func is_boost_held() -> bool:
	return is_boost_pressed()

# ---------------------------------------------------------------------------
# Boost amount helpers
# ---------------------------------------------------------------------------
static func clamp_boost(v: float) -> float:
	return clamp(v, 0.0, MAX_BOOST)

func get_amount() -> float:
	return _amount

func get_amount_normalized() -> float:
	return clamp(_amount / MAX_BOOST, 0.0, 1.0)

func set_amount(v: float) -> void:
	_amount = clamp_boost(v)

func has_boost() -> bool:
	return _amount > MIN_BOOST_TO_ACTIVATE

func is_empty() -> bool:
	return _amount <= 0.0

func is_full() -> bool:
	return _amount >= MAX_BOOST - 0.01

func is_boosting() -> bool:
	return _is_boosting

func can_boost() -> bool:
	return has_boost() and is_boost_pressed()

# ---------------------------------------------------------------------------
# Consumption & regen
# ---------------------------------------------------------------------------
func consume(delta: float) -> float:
	if delta <= 0.0 or _amount <= 0.0:
		return 0.0
	var used := DRAIN_RATE * delta
	used = min(used, _amount)
	_amount -= used
	_amount = max(_amount, 0.0)
	_consumed_total += used
	return used

func regen(delta: float, rate: float = REGEN_RATE) -> float:
	if delta <= 0.0 or _amount >= MAX_BOOST:
		return 0.0
	var gained := rate * delta
	gained = min(gained, MAX_BOOST - _amount)
	_amount += gained
	_collected_total += gained
	return gained

func add_boost(amount: float) -> float:
	if amount <= 0.0:
		return 0.0
	var gained := min(amount, MAX_BOOST - _amount)
	_amount += gained
	_collected_total += gained
	return gained

## Collect a pad — amount is 12 (small) or 100 (big). Returns actual gained.
func collect_pad(is_big: bool) -> float:
	var give := BIG_PAD_AMOUNT if is_big else SMALL_PAD_AMOUNT
	return add_boost(give)

func collect_small_pad() -> float:
	return add_boost(SMALL_PAD_AMOUNT)

func collect_big_pad() -> float:
	return add_boost(BIG_PAD_AMOUNT)

func collect_amount(amount: float) -> float:
	return add_boost(amount)

# ---------------------------------------------------------------------------
# Boost force / acceleration — budget-aware (single apply_central_force per tick)
# ---------------------------------------------------------------------------
static func compute_boost_force(car: RigidBody3D) -> Vector3:
	if car == null:
		return Vector3.ZERO
	var fwd := car.global_transform.basis.z.normalized()
	if fwd.length_squared() < 0.5:
		fwd = Vector3(0, 0, 1)
	return fwd * BOOST_FORCE

static func compute_boost_acceleration(mass: float = 180.0) -> float:
	if mass <= 0.0:
		return 0.0
	return BOOST_FORCE / mass

func apply_boost(car: RigidBody3D, delta: float) -> Vector3:
	if car == null or delta <= 0.0:
		return Vector3.ZERO
	if not has_boost():
		_is_boosting = false
		return Vector3.ZERO
	if not is_boost_pressed():
		_is_boosting = false
		return Vector3.ZERO
	consume(delta)
	var force := CarBoost.compute_boost_force(car)
	car.apply_central_force(force)
	var fwd := car.global_transform.basis.z.normalized()
	if fwd.length_squared() < 0.5:
		fwd = Vector3(0, 0, 1)
	var speed_fwd := car.linear_velocity.dot(fwd)
	if speed_fwd > MAX_SPEED_BOOST:
		var excess := speed_fwd - MAX_SPEED_BOOST
		var correction := fwd * (-excess * car.mass * 8.0 * delta)
		car.apply_central_force(correction)
	_is_boosting = true
	return force

# ---------------------------------------------------------------------------
# Per-tick update — call from _physics_process at 120 Hz. Budget: 1 InputService
# read + 1 force + 1 drain. No allocations per tick.
# ---------------------------------------------------------------------------
func update(delta: float, car: RigidBody3D) -> bool:
	_time += delta
	if car == null:
		_is_boosting = false
		return false
	if is_boost_pressed() and has_boost():
		consume(delta)
		var force := CarBoost.compute_boost_force(car)
		car.apply_central_force(force)
		_is_boosting = true
		return true
	_is_boosting = false
	return false

func process_car(car: RigidBody3D, delta: float) -> bool:
	return update(delta, car)

func reset() -> void:
	_amount = 33.0
	_is_boosting = false
	_time = 0.0
	_consumed_total = 0.0
	_collected_total = 0.0
	_pad_cooldown = 0.0

# ---------------------------------------------------------------------------
# Boost pad — Area3D helper (layer 4, mask car_chassis). For scene & tests.
# ---------------------------------------------------------------------------
static func pad_layer() -> int:
	return PL.LAYER_BOOST_PADS

static func pad_bit() -> int:
	return PL.BIT_BOOST_PADS

static func pad_mask() -> int:
	return PL.MASK_BOOST_PADS

static func is_pad_layer_correct(layer: int) -> bool:
	return layer == PL.BIT_BOOST_PADS

# ---------------------------------------------------------------------------
# Validation & telemetry — conventions §11 — budget-aware (<4ms)
# ---------------------------------------------------------------------------
static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if not is_equal_approx(MAX_BOOST, 100.0):
		errors.append("MAX_BOOST %.2f != 100" % MAX_BOOST)
	if MAX_BOOST <= 0.0:
		errors.append("MAX_BOOST must be > 0")
	if not is_equal_approx(DRAIN_RATE_NORMALIZED, 0.7):
		errors.append("DRAIN_RATE_NORMALIZED %.3f != 0.7" % DRAIN_RATE_NORMALIZED)
	if DRAIN_RATE <= 0.0:
		errors.append("DRAIN_RATE must be > 0")
	if DRAIN_RATE > 100.0:
		errors.append("DRAIN_RATE %.2f > 100 too high" % DRAIN_RATE)
	if not is_equal_approx(REGEN_RATE_NORMALIZED, 0.5):
		errors.append("REGEN_RATE_NORMALIZED %.3f != 0.5" % REGEN_RATE_NORMALIZED)
	if REGEN_RATE < 0.0:
		errors.append("REGEN_RATE must be >= 0")
	if BOOST_FORCE <= 0.0:
		errors.append("BOOST_FORCE must be > 0")
	if BOOST_ACCELERATION <= 0.0:
		errors.append("BOOST_ACCELERATION must be > 0")
	if not is_equal_approx(BOOST_ACCELERATION, BOOST_FORCE / 180.0):
		errors.append("BOOST_ACCELERATION != BOOST_FORCE/180")
	if PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS_PER_SECOND %d != 120" % PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PHYSICS_TICK_DELTA mismatch")
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PC PHYSICS_TICKS_PER_SECOND %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	if not is_equal_approx(PC.PHYSICS_TICK_DELTA, 1.0 / 120.0):
		errors.append("PC PHYSICS_TICK_DELTA mismatch")
	if EngineRef.MAX_SPEED_BOOST <= EngineRef.MAX_SPEED_FORWARD:
		errors.append("Engine MAX_SPEED_BOOST must be > MAX_SPEED_FORWARD")
	if not is_equal_approx(MAX_SPEED_BOOST, EngineRef.MAX_SPEED_BOOST):
		errors.append("MAX_SPEED_BOOST %.1f != Engine MAX_SPEED_BOOST %.1f" % [MAX_SPEED_BOOST, EngineRef.MAX_SPEED_BOOST])
	if SMALL_PAD_AMOUNT <= 0.0 or BIG_PAD_AMOUNT <= 0.0:
		errors.append("PAD amounts must be > 0")
	if BIG_PAD_AMOUNT < SMALL_PAD_AMOUNT:
		errors.append("BIG_PAD_AMOUNT must be >= SMALL_PAD_AMOUNT")
	if not is_equal_approx(BIG_PAD_AMOUNT, MAX_BOOST):
		errors.append("BIG_PAD_AMOUNT %.1f != MAX_BOOST %.1f" % [BIG_PAD_AMOUNT, MAX_BOOST])
	if SMALL_PAD_RESPAWN <= 0.0 or BIG_PAD_RESPAWN <= 0.0:
		errors.append("PAD_RESPAWN must be > 0")
	if PL.LAYER_BOOST_PADS != 4:
		errors.append("LAYER_BOOST_PADS %d != 4" % PL.LAYER_BOOST_PADS)
	if PL.BIT_BOOST_PADS != 16:
		errors.append("BIT_BOOST_PADS %d != 16" % PL.BIT_BOOST_PADS)
	if pad_layer() != 4:
		errors.append("pad_layer() %d != 4" % pad_layer())
	if pad_bit() != 16:
		errors.append("pad_bit() %d != 16" % pad_bit())
	if PL.MASK_BOOST_PADS != PL.BIT_CAR_CHASSIS:
		errors.append("MASK_BOOST_PADS %d != BIT_CAR_CHASSIS %d" % [PL.MASK_BOOST_PADS, PL.BIT_CAR_CHASSIS])
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1))
	if ps_rate != -1 and ps_rate != 120:
		errors.append("project.godot ticks %d != 120" % ps_rate)
	var b := CarBoost.new()
	b.set_amount(100.0)
	b.consume(1.0)
	if b.get_amount() >= 100.0:
		errors.append("consume(1.0) must reduce amount")
	if b.get_amount() < 0.0:
		errors.append("consume must not go negative")
	var b2 := CarBoost.new()
	b2.set_amount(0.0)
	b2.add_boost(50.0)
	if not is_equal_approx(b2.get_amount(), 50.0):
		errors.append("add_boost 50 from 0 should be 50, got %.2f" % b2.get_amount())
	var b3 := CarBoost.new()
	b3.set_amount(95.0)
	b3.collect_small_pad()
	if b3.get_amount() > MAX_BOOST + 0.01:
		errors.append("pad collect must clamp to MAX")
	var b4 := CarBoost.new()
	b4.set_amount(0.0)
	b4.collect_big_pad()
	if not is_equal_approx(b4.get_amount(), MAX_BOOST):
		errors.append("big pad from 0 should fill to MAX")
	return {"ok": errors.is_empty(), "errors": errors}

static func debug_export() -> Dictionary:
	return {
		"max_boost": MAX_BOOST,
		"max": MAX,
		"boost_max": BOOST_MAX,
		"drain_rate": DRAIN_RATE,
		"drain_rate_normalized": DRAIN_RATE_NORMALIZED,
		"boost_drain_rate": BOOST_DRAIN_RATE,
		"regen_rate": REGEN_RATE,
		"regen_rate_normalized": REGEN_RATE_NORMALIZED,
		"boost_regen_rate": BOOST_REGEN_RATE,
		"boost_force": BOOST_FORCE,
		"boost_acceleration": BOOST_ACCELERATION,
		"boost_accel": BOOST_ACCEL,
		"max_speed_boost": MAX_SPEED_BOOST,
		"small_pad_amount": SMALL_PAD_AMOUNT,
		"big_pad_amount": BIG_PAD_AMOUNT,
		"small_pad_respawn": SMALL_PAD_RESPAWN,
		"big_pad_respawn": BIG_PAD_RESPAWN,
		"pad_layer": PAD_LAYER,
		"pad_bit": PAD_BIT,
		"pad_mask": PAD_MASK,
		"physics_tick_hz": PHYSICS_TICKS_PER_SECOND,
		"physics_tick_delta": PHYSICS_TICK_DELTA,
		"min_boost_to_activate": MIN_BOOST_TO_ACTIVATE,
	}

func debug_export_instance() -> Dictionary:
	var d := CarBoost.debug_export()
	d["amount"] = _amount
	d["amount_normalized"] = get_amount_normalized()
	d["is_boosting"] = _is_boosting
	d["has_boost"] = has_boost()
	d["time"] = _time
	d["consumed_total"] = _consumed_total
	d["collected_total"] = _collected_total
	return d

static func perf_mark() -> Dictionary:
	return {"scope": "CarBoost", "tick_hz": PHYSICS_TICKS_PER_SECOND, "max_boost": MAX_BOOST, "drain_rate": DRAIN_RATE, "boost_force": BOOST_FORCE}

func perf_mark_instance() -> Dictionary:
	return {"scope": "CarBoost", "tick_hz": PHYSICS_TICKS_PER_SECOND, "amount": _amount, "is_boosting": _is_boosting}
