# Rocket League Mobile — Shared Architecture & Conventions
Git source of truth: `rocket-league-mobile` (to be created via GitHub)
Status: Phase 0 — before parallel implementation

## 1. Project Structure
```
/docs/architecture/     conventions, interfaces, dependency graph
/docs/progress/         100-workstream live tracker
/docs/reference/        provenance logs for RL captures (no copyrighted binaries)
/src/core/              physics, input, time, save, telemetry
/src/game/              car, ball, arena, rules
/src/render/            materials, shaders, lighting
/src/audio/             mixer, banks
/src/ui/                HUD, menus, touch layout
/src/platform/android/  lifecycle, permissions, haptics
/assets/authored/       committed deterministic assets only (no procedural)
/tools/                 blind A/B harness, perf harness
/tests/                 regression, integration
```

Scene ownership: one scene per workstream owner. No two workstreams edit same file without PR. `src/core/*` is shared and requires RFC.

## 2. Naming
- files: `snake_case`, scenes: `PascalCase`, nodes: `Type_Name` (e.g. `Car_Octane`)
- assets: `category_name_variant_author_v01.ext` e.g. `car_octane_body_a_v01.glb`
- branches: `wsNN-short-name` e.g. `ws11-car-chassis` . PR title: `[WS11] description`

## 3. Coordinate / Units / Time
- Engine: Godot 4.x (fallback: engine-agnostic spec so we can swap). Units = meters. 1 unit = 1m. Car length ~4.2m, ball diameter 1.82m (RL standard).
- Right-handed, Y-up, Z forward. Arena centered at origin.
- Fixed physics tick 120 Hz, render variable. No frame-dependent physics. Delta clamped 1/240 .. 1/30.
- Determinism: physics inputs quantized, replay via input log.

## 4. Physics Conventions
- Physics engine: Godot Jolt/ Bullet wrapper. Collision layers:
  0 world static, 1 car chassis, 2 wheels, 3 ball, 4 boost pads, 5 sensors (goal, out-of-bounds)
- Raycast suspension, not rigid wheels. Friction curves authored per tire compound.
- Never reinvent: all workstreams import `src/core/physics/layers.gd` and `constants.gd`.

## 5. Input Abstraction
- `InputService` singleton: exposes `move: Vector2`, `look: Vector2`, `boost: bool`, `jump: bool`, `drift: bool`, `ballCam: bool`.
- Sources: touch -> InputService, gamepad -> InputService, keyboard -> InputService. Game code never reads raw Input.
- Touch conventions: left 35% screen = move joystick (120dp radius, 12dp deadzone), right 35% = camera, bottom-right cluster = boost/jump/drift (56dp min target, 8dp gap). Haptics via `platform/android/haptics.gd`.

## 6. Mobile Touch / Ergonomics
- Safe area insets respected. 60fps target, 30fps fallback. No control <48dp.
- Orientation: landscape locked, portrait shows rotate prompt. Suspend/resume must not lose match state.

## 7. UI Architecture
- UI in `src/ui/` with view-model separation. HUD is overlay, not world-space. All text via localization keys.
- Theme tokens in `src/ui/theme.tres`, not hardcoded colors.

## 8. Audio Routing
- Buses: Master -> [Music, SFX, Crowd, UI]. All SFX through `AudioService`.
- No raw `AudioStreamPlayer` in gameplay code.

## 9. Animation
- Car rig: single skeleton, boost/jump/drift as state machines. Ball has no skeleton. All clips authored/imported.

## 10. Save/Config
- `SaveService` (JSON + checksum) at `user://save.json`. Versioned migrations.

## 11. Telemetry / Test Hooks
- Every workstream exposes `debug_export()` and `perf_mark()`. Input replay logs for critic harness.

## 12. Performance Budgets
- Draw calls <120, tris <300k, texture memory <350MB on mid device, physics <4ms, frame <16.6ms. Budget enforced in CI.

## 13. Build / Export
- Android: Gradle via Godot export, AAB + APK, minSdk 24. Signing via keystore in CI secrets.

## 14. Branch / Merge Rules
- `main` protected. Every WS on its own branch. PR requires: builds, `tests/regression.sh` passes, no asset >50MB without LFS review.
- Integration branch `integrate/wave-N` for cross-WS merges. Regressions fixed before dependent WS starts.

## 15. Inter-Workstream APIs
- Core exports: `PhysicsConstants`, `InputService`, `TimeService`, `SaveService`, `AudioService`, `Telemetry`.
- Car/Ball/Arena depend on Core only. VFX/Audio depend on Game events, never direct physics.

## 16. Asset Rules (No Procedural Generation)
- Every mesh/material/animation/VFX/audio authored, sourced (CC0/licensed), imported, and committed as deterministic asset in `/assets/authored/<ws>/`.
- Procedural noise at runtime forbidden as content substitute. Use authored textures.
- Large assets: use Git LFS. Do NOT delete locally after push to "free space" — local copy needed to build/test. If storage low, use `git lfs prune` or shallow clone on CI, not `rm`.

## 17. Reference Benchmarking
- RL footage/screenshots captured by us, provenance logged in `docs/reference/provenance.md` (date, hardware, build, lawfulness). No redistributed Psyonix binaries/assets in repo.
- Critics run blind A/B harness: two videos/replays shuffled, judge picks A/B + single largest gap.

## 18. Dependency Order (waves)
Wave 0: WS01-10 (foundation) must land before any gameplay.
Wave 1: WS11-25 (physics), WS26-35 (input/camera) in parallel after Wave 0.
Wave 2: WS36-45 (arena), WS46-55 (cars) after physics.
Wave 3: WS56-68 (ball feel + VFX) after arena/cars.
Wave 4: WS69-85 (audio + UI) can parallelize with Wave 3 but needs events.
Wave 5: WS86-95 (platform/perf) + WS96-100 (integration) last.
