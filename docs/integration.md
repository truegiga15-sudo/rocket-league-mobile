# WS96 Full Integration Pass — 01–95 Wired Checklist

> **Workstream 96** — Budget-aware (<12 calls) full integration pass. Verifies every module 01–95 is wired, tick 120 Hz holds, budgets enforced, save/load round-trips, and no regressions.
> Branch: `ws96-integration` from `main` (962bc29). Single source of truth: `project.godot` + `tools/perf/budget.json` + `src/core/*.gd`.

## 0. How to Use

- Check each box only after the **Verify** command or manual step passes on `ws96-integration` head.
- Run **Quick Gate** (§8) before any PR merge. All green = WS96 converged.
- For failures, log gap in `docs/progress/100-workstreams.md` row 96 and open blocking issue before proceeding to WS97.

---

## 1. Source of Truth (single-copy, no drift)

| File | Owns | Verify |
|------|------|--------|
| `project.godot` | app name `Rocket League Mobile`, `physics_ticks_per_second=120`, autoloads, icon/splash, `gl_compatibility`, `default_env.tres` | `grep physics_ticks_per_second project.godot` == 120 |
| `export_presets.cfg` | Android Debug APK (`export_format=0`) + Release AAB (`1`), `min_sdk=24`, `target_sdk=34`, `arm64-v8a`, `screen/orientation=1`, Gradle | `grep -c "preset\." export_presets.cfg` == 2 |
| `tools/perf/budget.json` | WS10 budgets: draw<120, tris<300k, tex<350 MB (367001600 B), physics<4 ms, frame<16.6 ms, `fail_on_exceed=true` | `cat tools/perf/budget.json` matches table below |
| `src/core/constants.gd` | Units 1 m, arena 60×40×20, car/ball sizes, tick 120 Hz | `grep PHYSICS_TICKS src/core/constants.gd` |
| `src/core/physics/physics_config.gd` | Gravity 9.81, solver 12/8, friction defaults | `grep GRAVITY src/core/physics/physics_config.gd` |
| `src/core/physics/layers.gd` | Layers 1–6: world_static, car_chassis, wheels, ball, boost_pads, sensors | `cat src/core/physics/layers.gd` |

No other file re-defines a budget, tick, or layer constant — downstream imports only.

---

## 2. Tick 120 Hz — Fixed Timestep (WS05 + WS23 + WS04)

Contract: `project.godot:120` → `TimeService` accumulator → `World` fixed-step. Delta clamp [1/240, 1/30], MAX_TICKS_PER_FRAME=4.

| Check | Expected | Verify | Gate |
|-------|----------|--------|------|
| `project.godot` | `common/physics_ticks_per_second=120` | `grep physics_ticks_per_second project.godot` | ☐ |
| `src/core/constants.gd` | `PHYSICS_TICKS_PER_SECOND=120`, `TICK_DELTA=1/120` | `grep PHYSICS_TICKS src/core/constants.gd` | ☐ |
| `src/core/time_service.gd` | `PHYSICS_TICKS_PER_SECOND=120`, `TICK_DELTA`, `DELTA_MIN/MAX`, `MAX_TICKS_PER_FRAME=4`, `clamp_delta()`, `quantize_axis()` | `grep PHYSICS_TICKS src/core/time_service.gd` | ☐ |
| `src/game/world.gd` | Mirrors TimeService, `advance(delta)->ticks`, `world_ticked`/`goal_scored`, `debug_validate()` | `grep -n "advance\|debug_validate" src/game/world.gd` | ☐ |
| `src/platform/frame_pacing.gd` | `TICKS_PER_RENDER_FRAME=2` (120/60), `TARGET_FPS=60` | `grep TICKS_PER_RENDER src/platform/frame_pacing.gd` | ☐ |
| Runtime warning on drift | TimeService `_ready()` warns if ps_rate !=120 | Launch + check logcat for `[TimeService]` | ☐ |

**Regression command:**

```sh
godot --headless -s src/core/time_service_test.gd  # accumulator, clamp, advance 4-tick cap
# or GUT if present:
godot --headless -s tests/regression/perf_budget_test.gd
```

---

## 3. Performance Budgets — WS10 Gate (blocks export)

From `tools/perf/budget.json` v1 — CI `fail_on_exceed=true`:

| Metric | Max | Source | Enforce | Verify |
|--------|-----|--------|---------|--------|
| draw_calls | 120 /frame | `Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME` | true | ☐ |
| tris | 300 000 /frame | `Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME` | true | ☐ |
| texture_mem | 350 MB (367001600 B) | `Performance.RENDER_TEXTURE_MEM_USED` | true | ☐ |
| physics_ms | 4.0 ms | `Performance.TIME_PHYSICS_PROCESS *1000` | true | ☐ |
| frame_ms | 16.6 ms (60 fps) | `TIME_PROCESS+TIME_PHYSICS_PROCESS` | true | ☐ |

Budget-aware services: `src/platform/frame_pacing.gd`, `src/platform/memory.gd`, `tools/perf/profiler.gd` each cap at **11 Performance calls/frame** (<12).

**Gate:**

```sh
godot --headless -s tests/regression/perf_budget_test.gd
cat tools/perf/budget.json | python3 -c "import json,sys; b=json.load(open('tools/perf/budget.json')); assert b['budgets']['draw_calls']['max']==120"
```

---

## 4. Save / Load Round-Trip (WS08 + WS83 + WS55)

Owner: `src/core/save_service.gd` (autoload `SaveService`), `src/core/config_service.gd`, `src/core/settings_profiles.gd`.

| Check | Expected | Verify | Gate |
|-------|----------|--------|------|
| Paths | `SAVE_PATH=user://save.json`, `BACKUP=user://save.bak.json`, `TEMP=user://save.tmp.json` | `grep SAVE_PATH src/core/save_service.gd` | ☐ |
| Version | `CURRENT_VERSION=3`, envelope `{version, checksum, saved_at, payload}` | `grep CURRENT_VERSION src/core/save_service.gd` | ☐ |
| Atomic write | temp→rename, checksum SHA256 of payload JSON | `grep -n "checksum\|TEMP_PATH" src/core/save_service.gd` | ☐ |
| Migration | `save_migrated` signal, auto re-save on version bump | `grep -n "migrate\|save_migrated" src/core/save_service.gd` | ☐ |
| Default payload | `player/garage/progress/stats/meta` keys exist | `grep -A2 "default_payload" src/core/save_service.gd` | ☐ |
| Garage loadout | `src/game/car/loadout.gd` reads `SaveService` → `equipped_car` | `grep -n "SaveService\|loadout" src/game/car/loadout.gd src/ui/garage.gd` | ☐ |
| Settings profiles | `src/core/settings_profiles.gd` persists quality/shadows/msaa/fps | `grep -n "settings_profiles\|quality" src/core/settings_profiles.gd` | ☐ |
| ConfigService | `user://config.json`, graphics/audio/control keys | `grep -n "config" src/core/config_service.gd | head` | ☐ |

**Manual smoke:**

```gdscript
var p = SaveService.default_payload()
SaveService.save_game(p)
var q = SaveService.load_save()
assert(q["garage"]["equipped_car"] == p["garage"]["equipped_car"])
# Corrupt test: write bad JSON → load returns defaults + save_error emitted
```

---

## 5. Full Wiring Checklist — WS01–WS95

> Each row: **Wired** = file(s) present + imported by `World`/autoload/UI. **Verify** = one-liner to confirm.

### Wave 0 — Foundation (01–10)

| # | Workstream | Key Files | Verify | Wired |
|---|------------|-----------|--------|-------|
| 01 | Repo, Branch/Merge Rules, CI | `README.md`, `.github/`, `docs/architecture/00-conventions.md §14` | `git branch -a \| grep ws` | ☐ |
| 02 | Project Structure & Scene Ownership | `src/*`, `docs/architecture/scene-ownership.md` | `ls src/core src/game src/ui src/platform` | ☐ |
| 03 | Asset Import Pipeline & Naming | `src/core/asset_import.gd`, `tools/validate_*` | `ls tools/validate* assets/authored/` | ☐ |
| 04 | Coordinate, Units, Scale | `src/core/constants.gd`, `src/core/units.md` | `grep CAR_LENGTH src/core/constants.gd` | ☐ |
| 05 | Time Step & Determinism | `src/core/time_service.gd`, `src/core/determinism.md`, `src/core/time_service_test.gd` | `grep TICK_DELTA src/core/time_service.gd` | ☐ |
| 06 | Input Abstraction Layer | `src/core/input_service.gd`, `src/core/input/touch_layout.json`, `src/core/gamepad.gd` | `grep -n "move\|look\|boost\|jump" src/core/input_service.gd | head` | ☐ |
| 07 | Physics Conventions & Collision Layers | `src/core/physics/layers.gd`, `src/core/physics/physics_config.gd`, `src/core/physics/constants.gd` | `cat src/core/physics/layers.gd` | ☐ |
| 08 | Save/Config Interfaces | `src/core/save_service.gd`, `src/core/config_service.gd` | `grep SAVE_PATH src/core/save_service.gd` | ☐ |
| 09 | Telemetry & Test Hooks | `src/core/telemetry_service.gd`, `src/core/test_hooks.gd`, `src/core/analytics.gd`, `docs/architecture/telemetry.md` | `grep -n "perf_mark\|debug_export" src/core/telemetry_service.gd` | ☐ |
| 10 | Performance Budgets & Profiling Harness | `tools/perf/budget.json`, `tools/perf/profiler.gd`, `tests/regression/perf_budget_test.gd` | `cat tools/perf/budget.json` | ☐ |

### Wave 1 — Physics & Input/Camera (11–35)

| # | Workstream | Key Files | Verify | Wired |
|---|------------|-----------|--------|-------|
| 11 | Car Chassis Physics & Mass | `src/game/car/car_physics.gd`, `car_chassis.tscn` | `grep -n "mass\|debug_validate" src/game/car/car_physics.gd | head` | ☐ |
| 12 | Suspension & Wheel Raycasts | `src/game/car/suspension.gd`, `src/game/car/wheels.gd`, `Wheel.tscn` | `grep -n "raycast\|suspension" src/game/car/suspension.gd | head` | ☐ |
| 13 | Tire Friction Model | `src/game/car/friction.gd` | `grep -n "friction" src/game/car/friction.gd | head` | ☐ |
| 14 | Engine Power Curve & Throttle | `src/game/car/engine.gd`, `engine_curve.gd/.tres` | `cat src/game/car/engine_curve.tres | head` | ☐ |
| 15 | Steering, Drift & Handbrake | `src/game/car/steering.gd` | `grep -n "steer\|drift" src/game/car/steering.gd | head` | ☐ |
| 16 | Jump / Double Jump | `src/game/car/jump.gd` | `grep -n "jump" src/game/car/jump.gd | head` | ☐ |
| 17 | Dodge / Flip Mechanics | `src/game/car/dodge.gd` | `grep -n "dodge\|flip" src/game/car/dodge.gd | head` | ☐ |
| 18 | Boost System | `src/game/car/boost.gd`, `boost_pad.gd`, `BoostPad*.tscn` | `grep -n "boost" src/game/car/boost.gd | head` | ☐ |
| 19 | Ball Physics | `src/game/ball/ball_physics.gd`, `ball_config.gd`, `ball.tscn` | `grep -n "mass\|bounce\|spin" src/game/ball/ball_physics.gd | head` | ☐ |
| 20 | Ball-Car Contact & Impulse | `src/game/ball/contact.gd` | `grep -n "impulse\|contact" src/game/ball/contact.gd | head` | ☐ |
| 21 | Arena Collision & Curved Walls | `src/game/arena/arena_collision.gd`, `stadium_collision.gd`, `.tscn` | `grep -n "collision" src/game/arena/arena_collision.gd | head` | ☐ |
| 22 | Goal Detection & Scoring | `src/game/arena/goal.gd`, `goal_geometry.gd` | `grep -n "goal_scored" src/game/arena/goal.gd` | ☐ |
| 23 | World Physics Integration & Fixed Tick | `src/game/world.gd` | `grep -n "PHYSICS_TICKS\|world_ticked" src/game/world.gd` | ☐ |
| 24 | Air Control & Aerial | `src/game/car/air_control.gd` | `grep -n "air_control" src/game/car/air_control.gd | head` | ☐ |
| 25 | Supersonic & Demo | `src/game/car/supersonic.gd`, `explosion_model.gd` | `grep -n "supersonic\|demo" src/game/car/supersonic.gd | head` | ☐ |
| 26 | Touch Joystick (movement) | `src/core/input_service.gd` touch region, `touch_layout.json` | `cat src/core/input/touch_layout.json` | ☐ |
| 27 | Camera Joystick & Orbit | `src/game/camera/camera_rig.gd` | `grep -n "orbit\|look" src/game/camera/camera_rig.gd | head` | ☐ |
| 28 | Boost/Jump/Drift Cluster & Haptics | `src/platform/android/haptics.gd` | `grep -n "haptic\|vibrat" src/platform/android/haptics.gd | head` | ☐ |
| 29 | Camera Follow Algorithm | `src/game/camera/camera_rig.gd` | `grep -n "follow\|lerp" src/game/camera/camera_rig.gd | head` | ☐ |
| 30 | Camera Shake & Impact | `src/game/camera/shake.gd` | `cat src/game/camera/shake.gd | head -40` | ☐ |
| 31 | Ball Cam vs Car Cam Toggle | `src/game/camera/ball_cam.gd` | `grep -n "ball_cam" src/game/camera/ball_cam.gd` | ☐ |
| 32 | Touch Responsiveness & Dead Zones | `src/core/input_service.gd` (12dp deadzone), `src/core/latency.gd` | `grep -n "deadzone" src/core/input_service.gd` | ☐ |
| 33 | Orientation Change Handling | `src/platform/orientation.gd` | `grep -n "orientation\|LANDSCAPE" src/platform/orientation.gd | head` | ☐ |
| 34 | Input Latency Measurement | `src/core/latency.gd` | `cat src/core/latency.gd | head -40` | ☐ |
| 35 | Gamepad Fallback & Mapping | `src/core/gamepad.gd` | `grep -n "gamepad\|joypad" src/core/gamepad.gd | head` | ☐ |

### Wave 2 — Arena & Cars (36–55)

| # | Workstream | Key Files | Verify | Wired |
|---|------------|-----------|--------|-------|
| 36 | DFH Stadium Geometry | `src/game/arena/stadium.gd/.tscn`, `assets/authored/arena/stadium_dfh_*` | `ls assets/authored/arena/` | ☐ |
| 37 | Stadium Collision Mesh & OOB | `src/game/arena/stadium_collision.gd` | `grep -n "OOB\|collision" src/game/arena/stadium_collision.gd | head` | ☐ |
| 38 | Lighting Rig | `src/game/arena/lighting.gd` | `cat src/game/arena/lighting.gd | head -30` | ☐ |
| 39 | Materials & PBR Shaders | `src/game/arena/materials.gd`, `src/game/car/car_shader.gd` | `grep -n "shader\|PBR" src/game/arena/materials.gd | head` | ☐ |
| 40 | Skybox & Atmosphere | `src/game/arena/skybox.gd` | `cat src/game/arena/skybox.gd | head -20` | ☐ |
| 41 | Crowd & Stadium Dressing | `src/game/arena/crowd.gd` | `cat src/game/arena/crowd.gd | head -20` | ☐ |
| 42 | Goal Geometry, Net & Posts | `src/game/arena/goal_geometry.gd` | `grep -n "net\|post" src/game/arena/goal_geometry.gd | head` | ☐ |
| 43 | Boost Pad Placement & Visuals | `src/game/arena/boost_pads.gd`, `BoostPad*.tscn` | `grep -n "boost_pad" src/game/arena/boost_pads.gd | head` | ☐ |
| 44 | Field Decals & Markings | `src/game/arena/decals.gd` | `cat src/game/arena/decals.gd | head -20` | ☐ |
| 45 | Environment LOD & Culling | `src/game/arena/lod.gd` | `grep -n "LOD\|cull" src/game/arena/lod.gd | head` | ☐ |
| 46 | Car Mesh: Octane | `src/game/car/octane.gd`, `assets/authored/car/octane_mesh_a_v01.glb` | `ls assets/authored/car/octane*` | ☐ |
| 47 | Car Mesh: Dominus | `src/game/car/dominus.gd`, `dominus_mesh_a_v01.glb` | `ls assets/authored/car/dominus*` | ☐ |
| 48 | Car Shader & Paint | `src/game/car/car_shader.gd` | `grep -n "paint\|team" src/game/car/car_shader.gd | head` | ☐ |
| 49 | Wheels, Trails & Attachments | `src/game/car/wheels.gd`, `decals.gd` | `grep -n "wheel" src/game/car/wheels.gd | head` | ☐ |
| 50 | Decals & Texture Authoring | `src/game/car/decals.gd`, `assets/authored/car/` | `ls assets/authored/car/` | ☐ |
| 51 | Car Explosion Model | `src/game/car/explosion_model.gd`, `assets/authored/car/explosion/` | `ls assets/authored/car/explosion/` | ☐ |
| 52 | Garage / Customization UI | `src/ui/garage.gd` | `grep -n "garage\|equipped" src/ui/garage.gd | head` | ☐ |
| 53 | Hitbox Presets & Debug Vis | `src/game/car/hitbox.gd` | `cat src/game/car/hitbox.gd | head -30` | ☐ |
| 54 | Car Audio Attachment | `src/game/car/car_audio.gd` | `grep -n "audio" src/game/car/car_audio.gd | head` | ☐ |
| 55 | Car Selection & Loadout Persistence | `src/game/car/loadout.gd` | `grep -n "SaveService\|equipped" src/game/car/loadout.gd | head` | ☐ |

### Wave 3 — Ball Feel + VFX (56–68)

| # | Workstream | Key Files | Verify | Wired |
|---|------------|-----------|--------|-------|
| 56 | Ball Mesh, Texture, Trail | `src/game/ball/ball_mesh.gd`, `assets/authored/ball/` | `ls assets/authored/ball/` | ☐ |
| 57 | Ball Prediction Line | `src/game/ball/prediction.gd`, `prediction_line.gd` | `grep -n "prediction" src/game/ball/prediction.gd | head` | ☐ |
| 58 | Match Timer & Overtime | `src/game/match_timer.gd` | `grep -n "timer\|overtime" src/game/match_timer.gd | head` | ☐ |
| 59 | Kickoff Logic & Spawns | `src/game/kickoff.gd` | `grep -n "kickoff\|spawn" src/game/kickoff.gd | head` | ☐ |
| 60 | Replays & Goal Replay Camera | `src/game/replay.gd` | `cat src/game/replay.gd | head -30` | ☐ |
| 61 | Boost Exhaust & Particles | `src/game/vfx/boost_exhaust.gd` | `cat src/game/vfx/boost_exhaust.gd | head -20` | ☐ |
| 62 | Tire Smoke & Skid Marks | `src/game/vfx/tire_smoke.gd` | `cat src/game/vfx/tire_smoke.gd | head -20` | ☐ |
| 63 | Ball Hit Impact VFX | `src/game/vfx/ball_hit.gd` | `cat src/game/vfx/ball_hit.gd | head -20` | ☐ |
| 64 | Explosion & Demo VFX | `src/game/vfx/explosion.gd` | `cat src/game/vfx/explosion.gd | head -20` | ☐ |
| 65 | Boost Pad Recharge VFX | `src/game/vfx/pad_recharge.gd` | `cat src/game/vfx/pad_recharge.gd | head -20` | ☐ |
| 66 | Wall/Ceiling Impact Sparks | `src/game/vfx/wall_sparks.gd` | `cat src/game/vfx/wall_sparks.gd | head -20` | ☐ |
| 67 | Supersonic Trail VFX | `src/game/vfx/supersonic_trail.gd` | `cat src/game/vfx/supersonic_trail.gd | head -20` | ☐ |
| 68 | Environmental Particles (dust) | `src/game/vfx/dust.gd` | `cat src/game/vfx/dust.gd | head -20` | ☐ |

### Wave 4 — Audio + UI (69–85)

| # | Workstream | Key Files | Verify | Wired |
|---|------------|-----------|--------|-------|
| 69 | Engine & Acceleration Audio | `src/audio/engine_audio.gd` | `grep -n "engine" src/audio/engine_audio.gd | head` | ☐ |
| 70 | Tire Skid & Impact Audio | `src/audio/tire_audio.gd` | `cat src/audio/tire_audio.gd | head -20` | ☐ |
| 71 | Ball Hit & Bounce Audio | `src/audio/ball_audio.gd` | `cat src/audio/ball_audio.gd | head -20` | ☐ |
| 72 | Boost Audio | `src/audio/boost_audio.gd` | `cat src/audio/boost_audio.gd | head -20` | ☐ |
| 73 | Crowd & Stadium Ambience | `src/audio/crowd_audio.gd` | `cat src/audio/crowd_audio.gd | head -20` | ☐ |
| 74 | Goal Horn & Countdown Audio | `src/audio/goal_audio.gd` | `cat src/audio/goal_audio.gd | head -20` | ☐ |
| 75 | UI & Menu Audio, Mixer Routing | `src/audio/mixer.tres`, `src/audio/ui_audio.gd` | `cat src/audio/mixer.tres | head -20` | ☐ |
| 76 | Main Menu & Navigation Flow | `src/ui/main_menu.gd/.tscn` | `grep -n "main_menu" src/ui/main_menu.gd | head` | ☐ |
| 77 | HUD: Scoreboard, Timer, Boost Meter | `src/ui/hud.gd` | `grep -n "HUD\|boost\|timer" src/ui/hud.gd | head` | ☐ |
| 78 | Touch HUD Layout & Safe Area | `src/ui/hud.gd` + `src/platform/orientation.gd` | `grep -n "safe_area" src/ui/hud.gd src/platform/orientation.gd` | ☐ |
| 79 | Pause, Settings, Controls Remap | `src/ui/main_menu.gd` + `src/core/settings_profiles.gd` | `grep -n "pause\|remap" src/ui/main_menu.gd | head` | ☐ |
| 80 | Post-Match Scoreboard & XP | `src/ui/post_match.gd` | `cat src/ui/post_match.gd | head -30` | ☐ |
| 81 | Loading Screens & Transitions | `src/ui/loading.gd/.tscn` | `cat src/ui/loading.gd | head -20` | ☐ |
| 82 | Onboarding Tutorial & Hints | `src/game/training.gd` | `grep -n "tutorial\|training" src/game/training.gd | head` | ☐ |
| 83 | Settings Persistence & Profiles | `src/core/settings_profiles.gd`, `src/core/config_service.gd` | `grep -n "profile" src/core/settings_profiles.gd | head` | ☐ |
| 84 | Localization Foundation | `src/core/localization.gd`, `assets/localization.csv` | `grep -n "localization\|tr(" src/core/localization.gd | head` | ☐ |
| 85 | Accessibility & Colorblind | `src/core/accessibility.gd` | `cat src/core/accessibility.gd | head -30` | ☐ |

### Wave 5 — Platform / Perf (86–95)

| # | Workstream | Key Files | Verify | Wired |
|---|------------|-----------|--------|-------|
| 86 | Frame Pacing & 60fps Lock | `src/platform/frame_pacing.gd` | `grep -n "TARGET_FPS\|vsync" src/platform/frame_pacing.gd | head` | ☐ |
| 87 | Memory Budget & Low-Memory | `src/platform/memory.gd` | `grep -n "BUDGET_TEXTURE\|low_memory" src/platform/memory.gd | head` | ☐ |
| 88 | Suspend/Resume & Lifecycle | `src/platform/lifecycle.gd` | `grep -n "NOTIFICATION_APPLICATION" src/platform/lifecycle.gd` | ☐ |
| 89 | Offline Bot AI (basic) | `src/game/bot.gd` | `cat src/game/bot.gd | head -30` | ☐ |
| 90 | Training / Free Play Mode | `src/game/training.gd` | `grep -n "free_play\|training" src/game/training.gd | head` | ☐ |
| 91 | Local Multiplayer Stub / Net Prep | `src/net/multiplayer_stub.gd` | `cat src/net/multiplayer_stub.gd | head -30` | ☐ |
| 92 | Analytics & Crash Hooks | `src/core/analytics.gd` | `grep -n "analytics\|crash" src/core/analytics.gd | head` | ☐ |
| 93 | Build Pipeline (APK/AAB) | `export_presets.cfg`, `tools/build/export.sh`, `docs/build.md` | `cat docs/build.md | head -20` | ☐ |
| 94 | Icon, Splash, Permissions & Manifest | `assets/icon.png`, `assets/splash.png`, `export_presets.cfg` permissions | `grep -n "launcher_icons\|permissions" export_presets.cfg` | ☐ |
| 95 | Device Testing Matrix & Edge Cases | `docs/testing-matrix.md`, `src/platform/memory.gd` + `orientation.gd` + `lifecycle.gd` | `head -30 docs/testing-matrix.md` | ☐ |

**WS96 itself:** this file. Gated on all above wiring + §8 gate.

---

## 6. Cross-Module Wiring — Integration Points

These are the only allowed cross-cutting edges. Any other import is a regression.

| From → To | Via | Check |
|-----------|-----|-------|
| `World` → `TimeService` | `get_node("/root/TimeService")` + accumulator | `grep TimeService src/game/world.gd` |
| `World` → `Car/Ball/Arena/Goal` | `preload` + `_find_*()` + `world_ticked` | `grep "CarPhysicsRef\|BallPhysicsRef" src/game/world.gd` |
| `Car/*` → `PhysicsConfig` + `PhysicsConstants` + `layers.gd` | `preload("res://src/core/physics/...")` | `grep "PhysicsConfig" src/game/car/*.gd` |
| `Ball/*` → `PhysicsConfig` | `preload("res://src/core/physics/physics_config.gd")` | `grep PhysicsConfig src/game/ball/*.gd` |
| `VFX/*` → Game events | `goal_scored`, `ball_hit`, `boost_started` signals — never direct physics | `grep "goal_scored\|world_ticked" src/game/vfx/*.gd` |
| `Audio/*` → Game events | `AudioService`/bus, `goal_audio`, `boost_audio` signals | `grep "AudioService\|bus" src/audio/*.gd` |
| `HUD/Garage` → `SaveService`/`ConfigService` | Autoload singleton | `grep SaveService src/ui/*.gd src/game/car/loadout.gd` |
| `FramePacing/Memory/Lifecycle` → `budget.json`/`Profiler` | Cached single `Performance` sample/frame, <12 calls | `grep MAX_CALLS src/platform/*.gd` |
| `InputService` ← `Touch/Gamepad/Keyboard` | Game code never reads `Input` directly | `grep -r "Input\.is_action" src/game/ | wc -l` should be 0 |
| `Touch HUD` ↔ `Orientation` | `DisplayServer.screen_set_orientation(LANDSCAPE)` + safe area | `grep orientation src/platform/orientation.gd` |

**Anti-patterns (must be 0):**

- Hardcoded `9.81`/`120`/`350` outside `constants.gd`/`budget.json`/`physics_config.gd`
- `src/game/*` calling `Performance.*` directly (use `Profiler`/`MemoryService`)
- `src/game/car/*` editing `src/game/ball/*` files (scene ownership violation)

---

## 7. No-Regressions Guard

| Gate | Command | Expected |
|------|---------|----------|
| Project loads | `godot --headless --import` | exit 0, no `SCRIPT ERROR` |
| Perf budget | `godot --headless -s tests/regression/perf_budget_test.gd` | PASS, budgets hold |
| Time determinism | `godot --headless -s src/core/time_service_test.gd` | PASS |
| Naming/assets | `python3 tools/validate_naming.py` (if present) / `tools/validate_assets.py` | PASS |
| No duplicate budgets | `grep -r "350\|367001600" src/ --include="*.gd" | grep -v "budget.json\|constants\|memory.gd\|MemoryService"` | 0 hits |
| No raw Input in gameplay | `grep -r "Input\.is_action" src/game/` | 0 hits |
| 120 Hz intact | `grep physics_ticks_per_second project.godot` | 120 |
| Save round-trip | manual §4 smoke | payload identical |
| Export smoke | `godot --headless --export-debug "Android - Debug APK" /tmp/smoke.apk` (CI only) | APK produced if templates present |

---

## 8. Quick Gate — Paste-Ready Validation (WS96)

Run on `ws96-integration` head. All lines must print `OK`:

```sh
# 1. Tick 120Hz everywhere
grep -q "physics_ticks_per_second=120" project.godot && echo "tick project.godot OK" || echo "FAIL tick"
grep -q "PHYSICS_TICKS_PER_SECOND.*120" src/core/constants.gd && echo "tick constants.gd OK" || echo "FAIL constants"
grep -q "PHYSICS_TICKS_PER_SECOND.*120" src/core/time_service.gd && echo "tick time_service OK" || echo "FAIL time_service"
grep -q "PHYSICS_TICKS_PER_SECOND.*120" src/game/world.gd && echo "tick world.gd OK" || echo "FAIL world"

# 2. Budgets single source
python3 -c "import json; b=json.load(open('tools/perf/budget.json')); assert b['budgets']['draw_calls']['max']==120 and b['budgets']['tris']['max']==300000 and b['budgets']['texture_mem_mb']['max']==350 and b['budgets']['physics_ms']['max']==4.0 and b['budgets']['frame_ms']['max']==16.6; print('budget.json OK')"
test -f tools/perf/budget.json && echo "budget file OK"

# 3. SaveService wiring
grep -q "SAVE_PATH.*user://save.json" src/core/save_service.gd && echo "save path OK"
grep -q "CURRENT_VERSION.*3" src/core/save_service.gd && echo "save version OK"
grep -q 'InputService\|TimeService\|SaveService\|ConfigService' project.godot && echo "autoloads OK"

# 4. World integration
grep -q "class_name World" src/game/world.gd && echo "world class OK"
grep -q "world_ticked\|goal_scored" src/game/world.gd && echo "world signals OK"

# 5. Platform budgets <12 calls
grep -q "MAX_CALLS_PER_FRAME.*11" src/platform/frame_pacing.gd && echo "frame_pacing budget OK"
grep -q "MAX_CALLS_PER_FRAME.*11" src/platform/memory.gd && echo "memory budget OK"

# 6. Build presets
grep -q 'name="Android - Debug APK"' export_presets.cfg && echo "preset debug OK"
grep -q 'export_format=1' export_presets.cfg && echo "preset release AAB OK"
grep -q "screen/orientation=1" export_presets.cfg && echo "landscape OK"

# 7. Integration doc itself
test -f docs/integration.md && echo "docs/integration.md OK"

# 8. Optional headless (requires Godot 4.4)
# godot --headless -s tests/regression/perf_budget_test.gd && echo "perf_budget_test OK"
```

---

## 9. Manual Playthrough — 5-Min Match (post-gate)

1. Cold launch → Main Menu appears, no `SCRIPT ERROR` in `adb logcat`.
2. Start match: car drives, ball bounces, goals increment HUD (`src/ui/hud.gd`).
3. Verify 60 fps locked (no hitch >33.3 ms) via `FramePacingService` log / `Profiler.perf_mark()`.
4. Pause via `NOTIFICATION_APPLICATION_PAUSED` (home button) → `get_tree().paused==true` → resume restores positions (WS88).
5. Rotate attempt → landscape lock holds, portrait shows rotate prompt (WS33).
6. Spend boost, hit boost pad → recharge + VFX + audio all fire (WS18/43/61/65/72).
7. Score → goal horn + replay camera + explosion VFX (WS22/60/64/74).
8. Garage: change Octane↔Dominus → `SaveService.save_game()` → kill app → relaunch → loadout persists (WS55/08).
9. Low-memory trim: `adb shell am send-trim-memory com.rocketleague.mobile MODERATE` → `MemoryService` callback, no crash (WS87).
10. Exit to Post-Match → XP/stats update → `save.json` checksum valid.

Log result in `docs/testing-matrix.md` per-tier table.

---

## 10. Branch & CI Record

- Base: `main` at `962bc29` (merge ws95-testing).
- Branch: `ws96-integration` (this WS).
- Commit: `[WS96] Full Integration Pass — 01–95 wired checklist, tick/budget/save gates`.
- Push: `git push origin ws96-integration`.
- CI: `godot --import` + `perf_budget_test.gd` + `time_service_test.gd` must pass; no store deploy on PR.
- Merge rule: requires reviewer + green CI + this checklist §8 Quick Gate all OK. Protects `main`.

---

## 11. Gaps / Deferred

- WS01 CI YAML not yet in repo — `.github/workflows/` is convention placeholder; real CI provisioned in WS97 Regression Suite.
- Blind A/B harness (`tools/blind_ab/`) is spec-only (`docs/architecture/blind-ab-harness.md`); real WS99 harness pending.
- Net stub (`src/net/multiplayer_stub.gd`) is intentionally no-op until beyond WS91.
- If any §5 row is still `todo` in `docs/progress/100-workstreams.md`, that WS must land before WS96 is marked `converged` — this doc verifies wiring, not feature completeness.

---

## 12. Sign-Off

| Role | Check | Date | Notes |
|------|-------|------|-------|
| Builder WS96 | §8 Quick Gate all OK | | |
| Critic (fresh) | Spot-check 3 random WS rows + 5-min playthrough | | Single largest gap: |
| Perf | `perf_budget_test.gd` PASS | | |
| Save/Load | §4 smoke PASS | | |

> WS96 converged only when all three sign-offs are `yes` and no §7 regression fires.
