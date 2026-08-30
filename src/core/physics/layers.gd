## WS07 — Physics Collision Layers & Masks
## Single source of truth for collision layers. All workstreams MUST import this file;
## never hardcode layer numbers or bit shifts elsewhere (conventions §4).
##
## Layers 0-5 (Godot 3D physics layers are 1-indexed in the editor, 0-indexed in code):
##   0 = World static (floor, walls, ceiling, arena collision mesh)
##   1 = Car chassis (rigid body, hitbox)
##   2 = Wheels (raycast suspension proxies — NOT rigid wheels)
##   3 = Ball (sphere rigid body)
##   4 = Boost pads (Area3D triggers — collectible)
##   5 = Sensors (goal volume, out-of-bounds, kickoff triggers — Area3D)
##
## Godot maps layer index -> bit (1 << index). This file exposes both forms
## plus helpers for masks and a default collision matrix tuned for RL-like play.
extends RefCounted
class_name PhysicsLayers

# ---------------------------------------------------------------------------
# Layer indices (0-5) — use these as canonical identifiers
# ---------------------------------------------------------------------------
const LAYER_WORLD_STATIC: int = 0
const LAYER_CAR_CHASSIS: int = 1
const LAYER_WHEELS: int = 2
const LAYER_BALL: int = 3
const LAYER_BOOST_PADS: int = 4
const LAYER_SENSORS: int = 5

const LAYER_COUNT: int = 6
const LAYER_MAX: int = 5  # inclusive
const LAYER_MIN: int = 0

## Human-readable names indexed by layer (size == LAYER_COUNT)
const LAYER_NAMES: Array[String] = [
	"world_static",
	"car_chassis",
	"wheels",
	"ball",
	"boost_pads",
	"sensors",
]

# ---------------------------------------------------------------------------
# Bit flags (1 << layer) — what Godot actually stores in collision_layer/mask
# ---------------------------------------------------------------------------
const BIT_WORLD_STATIC: int = 1 << LAYER_WORLD_STATIC  # 1
const BIT_CAR_CHASSIS: int = 1 << LAYER_CAR_CHASSIS    # 2
const BIT_WHEELS: int = 1 << LAYER_WHEELS              # 4
const BIT_BALL: int = 1 << LAYER_BALL                  # 8
const BIT_BOOST_PADS: int = 1 << LAYER_BOOST_PADS      # 16
const BIT_SENSORS: int = 1 << LAYER_SENSORS            # 32

## All defined layers as a combined mask (bits 0-5 set)
const MASK_ALL: int = BIT_WORLD_STATIC | BIT_CAR_CHASSIS | BIT_WHEELS | BIT_BALL | BIT_BOOST_PADS | BIT_SENSORS  # 63

# ---------------------------------------------------------------------------
# Default collision masks — which layers each layer collides/scans against.
# Tuned for RL-like behavior: raycast wheels only scan world, boost/sensors
# are triggers scanned by car/ball, not solid colliders themselves.
# ---------------------------------------------------------------------------

## World static is solid: collides with chassis, ball, and wheel raycasts.
## (Wheels are not rigid bodies; their raycasts query this layer.)
const MASK_WORLD_STATIC: int = BIT_CAR_CHASSIS | BIT_BALL

## Car chassis: solid vs world, other cars, ball. Does NOT collide with
## trigger layers directly (boost pads / sensors use Area overlap).
const MASK_CAR_CHASSIS: int = BIT_WORLD_STATIC | BIT_CAR_CHASSIS | BIT_BALL

## Wheels: raycast suspension — only needs to query world static.
## Keep separate from chassis so wheel raycasts don't hit cars/ball.
const MASK_WHEELS: int = BIT_WORLD_STATIC

## Ball: solid vs world and cars. Fast sphere — needs continuous detection.
const MASK_BALL: int = BIT_WORLD_STATIC | BIT_CAR_CHASSIS

## Boost pads: Area3D triggers. No physics response; they *detect* cars.
## Collision mask here means "which bodies can trigger this Area".
## Set on the Area's collision_mask, not collision_layer.
const MASK_BOOST_PADS: int = BIT_CAR_CHASSIS

## Sensors (goal, OOB, kickoff): Area3D triggers detecting ball + cars.
const MASK_SENSORS: int = BIT_BALL | BIT_CAR_CHASSIS

## Convenience: lookup default mask by layer index
const DEFAULT_MASKS: Array[int] = [
	MASK_WORLD_STATIC,  # 0
	MASK_CAR_CHASSIS,   # 1
	MASK_WHEELS,        # 2
	MASK_BALL,          # 3
	MASK_BOOST_PADS,    # 4
	MASK_SENSORS,       # 5
]

# ---------------------------------------------------------------------------
# Helpers — always use these instead of raw bit math
# ---------------------------------------------------------------------------

## Convert a layer index (0-5) to its Godot bit flag (1 << layer).
static func layer_bit(layer: int) -> int:
	assert(layer >= LAYER_MIN and layer <= LAYER_MAX, "PhysicsLayers.layer_bit: layer %d out of range 0-5" % layer)
	return 1 << layer

## Build a combined mask from an array of layer indices.
## Example: mask_for_layers([LAYER_WORLD_STATIC, LAYER_BALL]) == 0b1001 == 9
static func mask_for_layers(layers: Array) -> int:
	var mask: int = 0
	for l in layers:
		var li: int = int(l)
		assert(li >= LAYER_MIN and li <= LAYER_MAX, "PhysicsLayers.mask_for_layers: layer %d out of range" % li)
		mask |= 1 << li
	return mask

## Variadic-friendly: build mask from up to 6 explicit layer args (use -1 to skip).
static func mask_for(l0: int, l1: int = -1, l2: int = -1, l3: int = -1, l4: int = -1, l5: int = -1) -> int:
	var mask: int = 0
	for l in [l0, l1, l2, l3, l4, l5]:
		if l >= 0:
			assert(l >= LAYER_MIN and l <= LAYER_MAX, "PhysicsLayers.mask_for: layer %d out of range" % l)
			mask |= 1 << l
	return mask

## Test whether a mask includes a given layer.
static func mask_has(mask: int, layer: int) -> bool:
	assert(layer >= LAYER_MIN and layer <= LAYER_MAX, "PhysicsLayers.mask_has: layer %d out of range" % layer)
	return (mask & (1 << layer)) != 0

## Test whether two masks share any layer in common.
static func masks_overlap(a: int, b: int) -> bool:
	return (a & b) != 0

## Human-readable name for a layer index. Returns "unknown_N" if out of range.
static func layer_name(layer: int) -> String:
	if layer >= 0 and layer < LAYER_NAMES.size():
		return LAYER_NAMES[layer]
	return "unknown_%d" % layer

## Return the default collision mask for a given layer (see DEFAULT_MASKS).
static func default_mask_for_layer(layer: int) -> int:
	assert(layer >= LAYER_MIN and layer <= LAYER_MAX, "PhysicsLayers.default_mask_for_layer: layer %d out of range" % layer)
	return DEFAULT_MASKS[layer]

## Human-readable list of layer names present in a mask, e.g. "world_static|ball".
static func mask_to_names(mask: int) -> String:
	var parts: Array[String] = []
	for i in range(LAYER_COUNT):
		if (mask & (1 << i)) != 0:
			parts.append(LAYER_NAMES[i])
	if parts.is_empty():
		return "(none)"
	return "|".join(parts)

## Validate a mask contains only defined layers (bits 0-5). Returns true if valid.
static func is_valid_mask(mask: int) -> bool:
	return (mask & ~MASK_ALL) == 0

## Debug helper: validate layer index.
static func is_valid_layer(layer: int) -> bool:
	return layer >= LAYER_MIN and layer <= LAYER_MAX

## Return all layer indices as an array [0,1,2,3,4,5].
static func all_layers() -> Array[int]:
	return [0, 1, 2, 3, 4, 5] as Array[int]

## Debug export for telemetry / test hooks (conventions §11).
static func debug_export() -> Dictionary:
	return {
		"layers": {
			"world_static": LAYER_WORLD_STATIC,
			"car_chassis": LAYER_CAR_CHASSIS,
			"wheels": LAYER_WHEELS,
			"ball": LAYER_BALL,
			"boost_pads": LAYER_BOOST_PADS,
			"sensors": LAYER_SENSORS,
		},
		"bits": {
			"world_static": BIT_WORLD_STATIC,
			"car_chassis": BIT_CAR_CHASSIS,
			"wheels": BIT_WHEELS,
			"ball": BIT_BALL,
			"boost_pads": BIT_BOOST_PADS,
			"sensors": BIT_SENSORS,
		},
		"default_masks": {
			"world_static": MASK_WORLD_STATIC,
			"car_chassis": MASK_CAR_CHASSIS,
			"wheels": MASK_WHEELS,
			"ball": MASK_BALL,
			"boost_pads": MASK_BOOST_PADS,
			"sensors": MASK_SENSORS,
		},
		"mask_all": MASK_ALL,
	}

## Performance mark stub (conventions §11).
static func perf_mark() -> Dictionary:
	return {"scope": "PhysicsLayers", "layers": LAYER_COUNT}
