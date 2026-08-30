## WS18 — Boost Pad (Area3D, layer 4 boost_pads) — budget-aware
## Detects car_chassis (mask 2), gives boost amount, respawns after cooldown.
## Depends on: src/core/physics/layers.gd (WS07), src/game/car/boost.gd (WS18)
## Physics: Area3D on layer 4 (BIT_BOOST_PADS=16), mask car_chassis. 120 Hz tick not needed — event-driven.
extends Area3D

const PL = preload("res://src/core/physics/layers.gd")
const BoostRef = preload("res://src/game/car/boost.gd")

@export var is_big_pad: bool = false
@export var amount: float = 12.0
@export var respawn_time: float = 4.0

var _available: bool = true
var _respawn_timer: float = 0.0

signal pad_collected(is_big: bool, amount: float)
signal pad_respawned(is_big: bool)

func _ready() -> void:
	_configure_physics()
	_sync_amount()
	body_entered.connect(_on_body_entered)
	if OS.is_debug_build():
		var v := debug_validate()
		if not v["ok"]:
			for e in v["errors"]:
				push_warning("[BoostPad] debug_validate: %s" % e)

func _physics_process(delta: float) -> void:
	if not _available:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			_respawn()

func _configure_physics() -> void:
	collision_layer = PL.BIT_BOOST_PADS # 16 — layer 4
	collision_mask = PL.MASK_BOOST_PADS # 2 — detects car_chassis
	monitoring = true
	monitorable = true
	# Ensure Area3D triggers, not solid
	if has_node("CollisionShape3D"):
		var cs := get_node("CollisionShape3D") as CollisionShape3D
		if cs != null:
			cs.disabled = false

func _sync_amount() -> void:
	if is_big_pad:
		amount = BoostRef.BIG_PAD_AMOUNT # 100
		respawn_time = BoostRef.BIG_PAD_RESPAWN # 10
	else:
		amount = BoostRef.SMALL_PAD_AMOUNT # 12
		respawn_time = BoostRef.SMALL_PAD_RESPAWN # 4

func _on_body_entered(body: Node) -> void:
	if not _available:
		return
	if body == null:
		return
	# Only cars (group car_chassis or CarPhysics) can collect
	var is_car := false
	if body.is_in_group("car_chassis") or body.is_in_group("car"):
		is_car = true
	elif body is RigidBody3D:
		# Heuristic: check collision layer includes car_chassis bit
		var rb := body as RigidBody3D
		if (rb.collision_layer & PL.BIT_CAR_CHASSIS) != 0:
			is_car = true
	if not is_car:
		return
	_collect(body)

func _collect(car: Node) -> void:
	# Try to give boost to car's CarBoost instance if present
	var boosted := false
	if car.has_method("add_boost"):
		car.call("add_boost", amount)
		boosted = true
	elif "boost" in car:
		var b = car.get("boost")
		if b != null and b.has_method("add_boost"):
			b.add_boost(amount)
			boosted = true
	# Also try CarBoost collect directly via body_entered signal users
	_available = false
	_respawn_timer = respawn_time
	visible = false
	if has_node("CollisionShape3D"):
		var cs := get_node("CollisionShape3D") as CollisionShape3D
		if cs != null:
			cs.disabled = true
	# Visual feedback placeholder — hide mesh
	for child in get_children():
		if child is MeshInstance3D:
			child.visible = false
	pad_collected.emit(is_big_pad, amount)

func _respawn() -> void:
	_available = true
	_respawn_timer = 0.0
	visible = true
	if has_node("CollisionShape3D"):
		var cs := get_node("CollisionShape3D") as CollisionShape3D
		if cs != null:
			cs.disabled = false
	for child in get_children():
		if child is MeshInstance3D:
			child.visible = true
	pad_respawned.emit(is_big_pad)

func is_available() -> bool:
	return _available

func force_respawn() -> void:
	_respawn()

func set_big(is_big: bool) -> void:
	is_big_pad = is_big
	_sync_amount()

static func debug_validate() -> Dictionary:
	var errors: Array[String] = []
	if PL.LAYER_BOOST_PADS != 4:
		errors.append("LAYER_BOOST_PADS != 4")
	if PL.BIT_BOOST_PADS != 16:
		errors.append("BIT_BOOST_PADS != 16")
	if PL.MASK_BOOST_PADS != PL.BIT_CAR_CHASSIS:
		errors.append("MASK_BOOST_PADS != BIT_CAR_CHASSIS")
	if not is_equal_approx(BoostRef.SMALL_PAD_AMOUNT, 12.0):
		errors.append("SMALL_PAD_AMOUNT != 12")
	if not is_equal_approx(BoostRef.BIG_PAD_AMOUNT, 100.0):
		errors.append("BIG_PAD_AMOUNT != 100")
	if not is_equal_approx(BoostRef.SMALL_PAD_RESPAWN, 4.0):
		errors.append("SMALL_PAD_RESPAWN != 4")
	if not is_equal_approx(BoostRef.BIG_PAD_RESPAWN, 10.0):
		errors.append("BIG_PAD_RESPAWN != 10")
	return {"ok": errors.is_empty(), "errors": errors}

func debug_export() -> Dictionary:
	return {
		"is_big_pad": is_big_pad,
		"amount": amount,
		"respawn_time": respawn_time,
		"available": _available,
		"respawn_timer": _respawn_timer,
		"collision_layer": collision_layer,
		"collision_mask": collision_mask,
	}

static func perf_mark() -> Dictionary:
	return {"scope": "BoostPad", "layer": PL.LAYER_BOOST_PADS, "bit": PL.BIT_BOOST_PADS}
