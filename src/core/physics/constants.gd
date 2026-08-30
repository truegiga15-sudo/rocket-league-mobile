## WS07 shim — re-exports PhysicsConfig for legacy import path.
## Preferred import is `src/core/physics/physics_config.gd`.
extends RefCounted
const PhysicsConfig = preload("res://src/core/physics/physics_config.gd")
