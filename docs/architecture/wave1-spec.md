# Wave 1 — Core Simulation Spec (WS11-25) + Input/Camera (WS26-35)
Depends on Wave 0 (WS01-10) — dispatch immediately after WS03/05/07/09 merge.

## Execution Order (dependency-safe batches)
Batch 1a (can start together): WS11 Car Chassis, WS19 Ball Physics, WS21 Arena Collision, WS26 Touch Joystick, WS29 Camera Follow
Batch 1b (after 11): WS12 Suspension, WS14 Engine/Throttle, WS16 Jump, WS20 Ball-Car Contact
Batch 1c (after 12): WS13 Friction, WS15 Steering/Drift, WS17 Dodge/Flip
Batch 1d (after 16/18): WS18 Boost, WS24 Air Control, WS25 Supersonic/Demo

## Interface Contracts (must not be reinvented)
- All physics reads/writes via src/core/constants.gd + src/core/physics/layers.gd + src/core/time_service.gd
- Car uses RigidBody3D + raycast suspension, not wheel rigid bodies
- Ball is RigidBody3D layer 3, mass ~6kg equivalent, restitution 0.6, friction 0.3
- Input via InputService (WS06) only — no raw Input.get_vector in gameplay
- Telemetry via TelemetryService perf_mark/debug_export

## Blind A/B per WS
Each WS builder must produce:
- video: 15s isolated test (e.g. WS11: car drop + mass distribution, WS19: ball bounce)
- rl.mp4: own capture of RL same test, provenance logged in docs/reference/provenance.md
- critic_package shuffled via tools/critic/harness.py prepare wsNN

## Performance Gates
- Physics <4ms per frame, 120Hz fixed tick, no frame-dependent forces

## Assets
All meshes/materials deterministic in assets/authored/<ws>/ — no procedural gen. LFS for .glb/.png.
