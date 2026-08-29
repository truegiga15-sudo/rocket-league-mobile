# Scene & File Ownership — WS02 Project Structure

**Owner:** WS02 Project Structure & Scene Ownership
**Branch:** `ws02-project-structure`
**Status:** Foundation — defines exclusive ownership to prevent parallel WS conflicts
**Source of truth:** this file + `docs/architecture/00-conventions.md` §1, §14

## 1. Principle

> **One scene / file — one owning workstream.** No two WS edit the same file without a PR and owner review. `src/core/*` is shared and requires an RFC.

- Each entry lists **exclusive owner** (single WS) and **allowed readers** (all downstream).
- **Integration branches** `integrate/wave-N` may merge cross-WS changes only after each owner WS has converged.
- Violations are blocked by `tools/validate_naming.py` (ownership check) and CI `CODEOWNERS` (future WS01).

## 2. Directory Ownership Table

| Path | Owner WS | Branch Pattern | Description | Allowed Dependents |
|---|---|---|---|---|
| `src/core/` | WS01, WS04-WS10 (shared, RFC) | `ws01-*`…`ws10-*` | Physics constants, time, save, telemetry, perf budgets | ALL |
| `src/core/physics/` | WS07 | `ws07-*` | Collision layers 0-5, constants.gd | WS11-WS25 |
| `src/core/time/` | WS05 | `ws05-*` | Fixed 120 Hz, determinism, delta clamp | ALL |
| `src/core/input/` | WS06 | `ws06-*` | InputService spec (`touch_layout.json`) | WS26-WS35 |
| `src/core/save/` | WS08 | `ws08-*` | SaveService/ConfigService, migrations | WS52, WS55, WS76, WS79 |
| `src/core/telemetry/` | WS09 | `ws09-*` | debug_export, perf_mark, replay log | WS10, WS99 |
| `src/core/perf/` | WS10 | `ws10-*` | Budgets, profiler | WS45, WS86-WS87 |
| `src/game/car/` | WS11-WS18, WS24-WS25, WS46-WS55 | `ws11-*`… | Chassis, suspension, engine, car meshes | WS53 |
| `src/game/ball/` | WS19-WS20, WS56-WS57 | `ws19-*`… | Ball physics, contact, mesh, prediction | WS20, WS63 |
| `src/game/arena/` | WS21-WS22, WS36-WS45 | `ws21-*`… | Collision geometry, stadium, goals, pads, LOD | WS58-WS60 |
| `src/game/rules/` | WS58-WS60 (future) | `ws58-*` | Match timer, kickoff, replays | WS76-WS80 |
| `src/render/` | WS38-WS40, WS45 | `ws38-*`… | Materials, shaders, lighting, skybox | WS39, WS46-WS50 |
| `src/audio/` | WS69-WS75 | `ws69-*`… | Mixer buses, banks, AudioService | — |
| `src/ui/` | WS76-WS85 | `ws76-*`… | HUD, menus, touch layout, theme.tres | WS52 |
| `src/platform/android/` | WS88, WS93-WS94, WS28 | `ws88-*`… | Lifecycle, haptics, manifests, Gradle | ALL |
| `assets/authored/` | Per-WS subdirs (see §3) | `ws36-*`… | Deterministic committed assets only | Render/Audio |
| `tools/critic/` | WS99 | `ws99-*` | Blind A/B harness, shuffle, secrets | — |
| `tools/perf/` | WS10, WS86-WS87 | `ws10-*`… | Perf harness, bench.py, budgets.json | CI |
| `tests/regression/` | WS97 | `ws97-*` | Deterministic regression cases | CI |
| `docs/architecture/` | WS01-WS02 | `ws01-*`, `ws02-*` | Conventions, ownership, dependency graph | ALL |

## 3. Asset Ownership (No Procedural Generation)

Per `00-conventions.md` §16 — every asset is authored and committed. No runtime noise.

| Asset path | Owner WS | Naming example |
|---|---|---|
| `assets/authored/car_octane/` | WS46 | `car_octane_body_a_v01.glb` |
| `assets/authored/car_dominus/` | WS47 | `car_dominus_body_a_v01.glb` |
| `assets/authored/stadium/` | WS36 | `stadium_floor_c_v02.png` |
| `assets/authored/ball/` | WS56 | `ball_mesh_a_v01.glb` |
| `assets/authored/vfx_boost/` | WS61 | `vfx_boost_exhaust_a_v01.png` |
| `assets/authored/audio_engine/` | WS69 | `audio_engine_loop_a_v01.ogg` |

- Large assets >50 MB use Git LFS and require review.
- Do NOT delete locally after push — use `git lfs prune` if low on space.

## 4. Scene Ownership (Godot `*.tscn`)

| Scene file | Owner WS | Notes |
|---|---|---|
| `src/ui/main_menu.tscn` | WS76 | `project.godot` run/main_scene |
| `src/game/car/car_chassis.tscn` | WS11 | Chassis + mass distribution |
| `src/game/car/octane.tscn` | WS46 | Mesh instance of chassis |
| `src/game/car/dominus.tscn` | WS47 | |
| `src/game/ball/ball.tscn` | WS19 | Ball physics |
| `src/game/arena/stadium.tscn` | WS36 | DFH Stadium geometry |
| `src/game/arena/arena_collision.tscn` | WS21 | Curved walls, ground |
| `src/game/arena/boost_pad.tscn` | WS43 | Pad placement & visuals |
| `src/render/default_env.tres` | WS38 | Referenced in `project.godot` |
| `src/ui/hud/hud.tscn` | WS77 | Scoreboard, timer, boost meter |
| `src/ui/touch/touch_hud.tscn` | WS78 | Joysticks + button cluster |
| `src/ui/menus/pause_menu.tscn` | WS79 | |
| `src/platform/android/lifecycle.tscn` | WS88 | Suspend/resume |

**Node naming:** `Type_Name` e.g. `Car_Octane`, `Ball_Main`, `Arena_Stadium`. Enforced by validator.

## 5. File Naming Conventions (Enforced)

From `00-conventions.md` §2:

- **Files:** `snake_case` (`tire_friction.gd`, `ball_physics.gd`)
- **Scenes:** `PascalCase` (`CarChassis.tscn`, `Stadium.tscn`) — exception: Godot prefers PascalCase for scenes, validator checks `^[A-Z][A-Za-z0-9]*\.tscn$`
- **Nodes (inside scenes):** `Type_Name` (`Car_Octane`) — manual review, validator warns on `name="lowercase"` in tscn
- **Assets:** `category_name_variant_author_v01.ext` lower snake + `_vNN` (`car_octane_body_a_v01.glb`)
- **Branches:** `wsNN-short-name` (`ws11-car-chassis`), PR title `[WS11] description`

Run:

```bash
python3 tools/validate_naming.py          # check whole repo
python3 tools/validate_naming.py --fix    # (no auto-fix, prints guidance)
python3 tools/validate_naming.py --check src/game/car
```

CI fails on validator errors.

## 6. Conflict Resolution

1. If two WS need same file, the owning WS in this table is the **writer**. The other WS opens an RFC issue and submits a PR against the owner's branch.
2. `src/core/*` changes require RFC + approval from at least 2 dependent WS owners.
3. `integrate/wave-N` branches are created by WS96 Integration Pass only, after all constituent WS are `converged`.
4. Never force-push to `main`. Every WS lands via PR with: build passes, `tests/regression.sh` passes, validator passes, asset <50 MB or LFS-approved.

## 7. Wave Dependencies (Summary)

```
Wave 0 (foundation, before anything): WS01-WS10  ← WS02 lives here
Wave 1: WS11-WS25 (physics), WS26-WS35 (input/camera) — after Wave 0
Wave 2: WS36-WS45 (arena), WS46-WS55 (cars) — after physics
Wave 3: WS56-WS68 (ball+VFX) — after arena/cars
Wave 4: WS69-WS85 (audio+UI) — parallel with Wave 3, needs events
Wave 5: WS86-WS100 (platform/perf/integration) — last
```

See `docs/progress/100-workstreams.md` for full dependency graph.

## 8. Verification Checklist (WS02 Done When)

- [x] All directories from §2 exist with `README.md` explaining ownership
- [x] This file (`scene-ownership.md`) committed
- [x] `tools/validate_naming.py` passes on clean repo
- [x] Branch `ws02-project-structure` pushed, PR ready
- [x] `git status` clean, `ls -R` shows no missing scaffold
- [x] No procedural generation — all assets under `assets/authored/` are deterministic placeholders
