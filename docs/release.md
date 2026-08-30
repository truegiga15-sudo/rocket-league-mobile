# WS100 Release — v0.1.0 Store Listing & Artifact Prep

> **Workstream 100** — Release artifact & store listing preparation. Version `0.1.0` (versionCode 1), package `com.rocketleague.mobile`.
> Depends on **WS93 Build Pipeline** (`export_presets.cfg` + `tools/build/export.sh`) and **WS96 Full Integration Pass** (`docs/integration.md`).
> Budget-aware (<12 calls). Branch `ws100-release` from `main` (194863f).

## 1. Version & Package

| Field | Value | Source |
|-------|-------|--------|
| App name | `Rocket League Mobile` | `project.godot: application/name` |
| Package | `com.rocketleague.mobile` | `export_presets.cfg: package/unique_name` |
| Version name | `0.1.0` | `export_presets.cfg: version/name` + `project.godot: application/config/version` |
| versionCode | `1` | `export_presets.cfg: version/code` (CI auto-increments on tag `v0.x.y`) |
| Godot | `4.4` | `project.godot: config/features` |
| Min SDK | `24` (Android 7.0) | `export_presets.cfg: gradle_build/min_sdk` |
| Target SDK | `34` (Android 14) | `export_presets.cfg: gradle_build/target_sdk` |
| Architecture | `arm64-v8a` only | `export_presets.cfg: architectures/arm64-v8a=true` |
| Orientation | Landscape locked | `export_presets.cfg: screen/orientation=1`, `src/platform/orientation.gd` |
| Physics tick | `120 Hz` | `project.godot: physics/common/physics_ticks_per_second` |
| Renderer | `gl_compatibility` | `project.godot: renderer/rendering_method` |

Tag scheme: `v0.1.0` on `main` after WS96 gate passes. CI stamps `version/code` from commit count.

## 2. Store Listing

### 2.1 Short Description (80 chars)
> Fast-paced car-soccer action. Boost, fly, and score — built for mobile.

### 2.2 Full Description
```
Rocket League Mobile — car-soccer, rebuilt for touch.

Boost across the arena, launch off walls, and smash the ball into the net.
Tuned physics at 120 Hz, 60 fps frame pacing, and full touch + gamepad support.

• Quick matches — 5-minute rounds, instant kickoff, overtime rules
• Garage — Octane & Dominus presets, team colors, decals (SaveService persistence)
• Touch HUD — dual joysticks, boost/jump/drift cluster, safe-area aware
• Performance aware — low/mid/high quality profiles, 350 MB texture budget,
  suspend/resume safe, landscape locked

Built in Godot 4.4. No ads, no pay-to-win. Offline play with bots.
Feedback welcome — this is v0.1.0 early access.
```

### 2.3 Keywords / Tags
`car soccer`, `sports`, `arcade`, `multiplayer`, `offline`, `controller support`, `60fps`

### 2.4 Category & Content Rating
- Category: `Game > Sports` (secondary: `Racing`)
- Content rating: `Everyone` / `PEGI 3` — no gambling, no chat, no user-generated uploads
- Privacy: no PII collected; analytics opt-in only via `SaveService` consent flag (WS92 `AnalyticsService`)

### 2.5 Contact & Links
- Support URL: `https://github.com/<org>/rocket-league-mobile/issues`
- Privacy URL: `https://github.com/<org>/rocket-league-mobile/blob/main/docs/reference/provenance.md`
- Source of truth repo: GitHub `main` (this repo)

## 3. Screenshots & Assets

Captures are **lawful only** per `docs/reference/provenance.md` (WS98). No redistributed Psyonix binaries.

| # | Shot | Scene / State | Capture Command | Required |
|---|------|---------------|-----------------|----------|
| 1 | Main menu | `src/ui/main_menu.tscn` idle | Manual — 16:9 landscape | ✅ |
| 2 | Kickoff | `src/game/world.tscn` — ball centered, cars spawned (WS59) | Manual / `godot --headless --export-debug` + screen grab | ✅ |
| 3 | Mid-match | HUD visible (`src/ui/hud.tscn`: scoreboard, timer, boost meter WS77) | Manual | ✅ |
| 4 | Garage | `src/ui/garage.gd` — Octane equipped | Manual | ✅ |
| 5 | Goal replay | `src/game/world.tscn` goal event (WS60 replay camera) | Manual | ✅ |
| 6 | Touch HUD layout | `src/ui/touch/` + `src/ui/touch_hud.gd` safe-area insets (WS78) | Manual — include on-screen controls | ✅ |

**Specs (Google Play):**
- Phone: at least 2 screenshots, 16:9 or 9:16, 1080×1920 min, PNG/JPEG, max 8
- Feature graphic: `1024×500` PNG (assets/store/feature-graphic.png — to be authored, solid bg `Color(0.05,0.05,0.08,1)` from `project.godot: boot_splash/bg_color`)
- Icon: `512×512` PNG, from `project.godot: config/icon` (`assets/icon.png` / `assets/authored/icon/icon.png`) — WS94
- Splash: `assets/splash.png` / `boot_splash/image` — WS94

Place raw captures under `docs/reference/captures.md` registry before submitting to store (WS98 workflow).

## 4. Changelog — v0.1.0 (Initial Release)

```
v0.1.0 — 2026-08-31 — Initial early-access release
- Foundation: repo, scene ownership, asset pipeline, units (1 m), tick 120 Hz,
  input abstraction, collision layers, save/config, telemetry, perf budgets (WS01–10)
- Physics: chassis, suspension/raycasts, friction, engine power curve, steering/drift,
  jump/double-jump, dodge/flip, boost, ball physics & contact (WS11–20)
- Arena & match: collision geometry, goals/scoring, world fixed-tick, kickoff/spawns,
  timer/overtime (WS21–23, WS58–59)
- Controls: touch joysticks, camera orbit/follow/shake, ball-cam toggle,
  dead zones, gamepad fallback (WS06, WS26–35)
- Visuals: DFH stadium geometry, collision mesh, lighting, PBR, skybox, crowd,
  goals, boost pads, decals, LOD/culling (WS36–45)
- Cars: Octane/Dominus meshes, paint, hitboxes, garage & loadout persistence (WS46–55)
- Ball: mesh/trail, prediction line (WS56–57); VFX: boost exhaust, smoke, hit,
  explosion, pad recharge, supersonic trails (WS61–68)
- Audio: engine, tire, ball hit, boost, crowd, goal horn, mixer (WS69–75)
- UI: main menu, HUD, touch layout/safe-area, pause/settings, post-match XP,
  loading, tutorial, localization, accessibility (WS76–85)
- Platform: 60 fps lock, memory budget (350 MB), suspend/resume,
  bot AI, training/free-play, analytics hooks (WS86–92)
- Build & QA: APK/AAB pipeline (WS93), icon/splash/manifest (WS94),
  device matrix low/mid/high + edge cases (WS95), full integration pass (WS96),
  regression/CI gates (WS97), reference provenance (WS98)
- Docs: architecture, build, integration, testing-matrix, provenance
```

## 5. Artifacts — APK / AAB (WS93 Build Pipeline)

Source of truth: `export_presets.cfg` (config_version=5) + `project.godot` + `tools/perf/budget.json`.

| Preset | Format | Artifact Path | Signing |
|--------|--------|---------------|---------|
| `Android - Debug APK` | `export_format=0` (APK) | `build/android/RocketLeagueMobile-debug.apk` | debug keystore |
| `Android - Release AAB` | `export_format=1` (AAB) | `build/android/RocketLeagueMobile-release.aab` | CI `BUILD_KEYSTORE_*` secrets — never commit |

### 5.1 How to Build

```sh
# Prerequisites: Godot 4.4, Android SDK, export templates installed
godot --import
godot --headless --export-debug  "Android - Debug APK"   build/android/RocketLeagueMobile-debug.apk
godot --headless --export-release "Android - Release AAB" build/android/RocketLeagueMobile-release.aab

# Or wrapper (includes budget gate):
tools/build/export.sh --preset debug    # APK
tools/build/export.sh --preset release  # AAB — requires BUILD_KEYSTORE_* env
```

### 5.2 Pre-export Gate (WS10 + WS96)

Must pass before any release artifact is accepted:

```sh
godot --headless -s tests/regression/perf_budget_test.gd  # draw<120 tris<300k tex<350MB physics<4ms frame<16.6ms
cat tools/perf/budget.json | python3 -c "import json; b=json.load(open('tools/perf/budget.json')); assert b['budgets']['draw_calls']['max']==120"
grep -q "physics_ticks_per_second=120" project.godot && echo "tick OK"
grep -c "preset\." export_presets.cfg  # expect 2
# WS96 quick gate: docs/integration.md §8 — all boxes green
```

CI enforces `fail_on_exceed=true` from `budget.json`. Low-tier uses quality=0 overrides (see `docs/testing-matrix.md`).

### 5.3 Play Console Upload
- Upload **AAB only** for production (`build/android/RocketLeagueMobile-release.aab`)
- APK is for local testing / sideload — do not upload APK to Play
- Version code must increment per upload; version name `0.1.0` shown to users
- Signing: Play App Signing recommended; upload key via `BUILD_KEYSTORE_*`

## 6. Integration Dependency (WS96)

This release is cut **only** when `docs/integration.md` WS96 converges:

- Tick 120 Hz holds (`TimeService` + `World.advance` + `FramePacing` 2 ticks/frame)
- Budgets enforced (WS10 gate §3)
- Save/load round-trip (`SaveService` atomic write + checksum + migration)
- Modules 01–95 wired checklist all green (`docs/integration.md` §8 Quick Gate)

If any WS96 box is red, do not tag `v0.1.0` — log gap in `docs/progress/100-workstreams.md` row 96.

## 7. Release Checklist

- [ ] WS96 quick gate all green (`docs/integration.md` §8)
- [ ] Perf budget headless test passes on mid tier
- [ ] `version/name=0.1.0` and `version/code=1` in `export_presets.cfg`
- [ ] Icon `512×512` and splash from `project.godot` verified (WS94)
- [ ] Screenshots captured (6 required) and logged in `docs/reference/captures.md`
- [ ] Feature graphic `1024×500` authored
- [ ] AAB built via `tools/build/export.sh --preset release` and tested on device
- [ ] Tag `v0.1.0` pushed, GitHub Release notes = changelog §4
- [ ] Play Console listing filled (§2), AAB uploaded to internal track

## 8. Verification

```sh
cat docs/release.md | grep -q "0.1.0" && echo "version OK"
grep -q "WS93" docs/release.md && grep -q "WS96" docs/release.md && echo "deps OK"
ls export_presets.cfg project.godot tools/perf/budget.json docs/build.md docs/integration.md >/dev/null && echo "sources OK"
```
