# WS93 Build Pipeline -- Android APK/AAB Export

> **Workstream 93** -- Budget-aware (<12 calls) Android build pipeline for Godot 4.x.
> Uses `project.godot` as source of truth, enforces WS10 perf budgets, Gradle-based export.

## 1. Source of Truth

| File | Purpose |
|------|---------|
| `project.godot` | App name, icon, boot splash, physics tick (120 Hz), autoloads; `config_version=5` / `features=PackedStringArray("4.4")` |
| `export_presets.cfg` | Godot Android export presets (APK debug + AAB release) |
| `tools/perf/budget.json` | WS10 budgets (draw <120, tris <300k, tex <350MB, physics <4ms, frame <16.6ms) |
| `tools/build/export.sh` | Optional CLI wrapper around `godot --headless --export-*` |

`project.godot` defines:

```ini
name="Rocket League Mobile"
run/main_scene="res://src/ui/main_menu.tscn"
config/icon="res://assets/authored/icon/icon.png"
boot_splash/bg_color=Color(0.05,0.05,0.08,1)
renderer/rendering_method="gl_compatibility"
```

Export presets inherit name/package/version from `project.godot` -- do not duplicate.

## 2. Version

- **Godot:** 4.4 (`config/features` in `project.godot`)
- **App version:** `version/name` from Project Settings -> `application/config/version` (default `0.1.0` until tagged). Export presets set `version/code` = auto-incremented `versionCode` for Play Store; `version/name` mirrors `application/config/version`.
- Tag releases as `v0.x.y`; CI stamps `version/code` from commit count.

## 3. Orientation & Display

- **Landscape locked** -- required by `docs/architecture/00-conventions.md` section 6 (portrait shows rotate prompt).
- `export_presets.cfg` sets `screen/orientation=1` (landscape) for Android presets.
- Safe-area insets respected (see `src/ui/`); suspend/resume preserves match state.

## 4. Android Export Presets (`export_presets.cfg`)

File is Godot 4.x `config_version=5` format. Two presets:

| Preset | Export Type | Artifact | Signing |
|--------|-------------|----------|---------|
| `Android - Debug APK` | `debug` | `build/android/RocketLeagueMobile-debug.apk` | debug keystore |
| `Android - Release AAB` | `release` | `build/android/RocketLeagueMobile-release.aab` | CI secrets keystore (`BUILD_KEYSTORE_*`) |

Key fields (see `export_presets.cfg`):

```ini
[preset.0]
name="Android - Debug APK"
platform="Android"
runnable=true
export_path="build/android/RocketLeagueMobile-debug.apk"

[preset.0.options]
gradle_build/use_gradle_build=true
gradle_build/export_format=0   # 0=APK, 1=AAB
gradle_build/min_sdk=24
gradle_build/target_sdk=34
architectures/arm64-v8a=true
screen/orientation=1
version/code=1
version/name="0.1.0"
package/unique_name="com.rocketleague.mobile"
```

Release preset switches `export_format=1` (AAB) and `export_path` to `.aab`. Icon and splash come from `project.godot` (`config/icon`, `boot_splash/bg_color`).

> **Min SDK 24** per `docs/architecture/00-conventions.md` section 13. Signing via `BUILD_KEYSTORE_*` secrets in CI -- never commit keystore.

## 5. WS10 Perf Budget Gate

Build fails if budgets exceeded -- enforced by:

- `tools/perf/budget.json` (budgets + `ci.fail_on_exceed=true`)
- `tools/perf/profiler.gd` (runtime harness)
- `tests/regression/perf_budget_test.gd` (GUT headless: `godot --headless -s tests/regression/perf_budget_test.gd`)

Run before export:

```sh
godot --headless -s tests/regression/perf_budget_test.gd
./tools/build/export.sh  # wraps gradle + budget check
```

Budgets: draw_calls<120, tris<300k, texture_mem<350 MB (367001600 B), physics<4 ms, frame<16.6 ms (60 fps).

## 6. Local Build

```sh
# prerequisites: Godot 4.4, Android SDK, export templates
godot --import
godot --headless --export-debug "Android - Debug APK" build/android/RocketLeagueMobile-debug.apk
godot --headless --export-release "Android - Release AAB" build/android/RocketLeagueMobile-release.aab

# or wrapper
tools/build/export.sh --preset debug   # APK
tools/build/export.sh --preset release # AAB (requires keystore env)
```

Artifacts go to `build/android/` (gitignored). Gradle build handled by Godot (`gradle_build/use_gradle_build=true`).

## 7. CI

- `main` protected; each WS on `wsNN-*` branch; PR requires `tests/regression.sh` pass.
- CI steps: `godot --import` -> perf test -> `godot --headless --export-*` -> upload APK/AAB artifact -> no store deploy on PR.
- Large assets via Git LFS; `export_filter="all_resources"` ensures authored assets in `assets/authored/` are included.

## 8. Validation Checklist (WS93)

- [ ] `export_presets.cfg` exists, `config_version` matches Godot 4.x, two Android presets present
- [ ] `screen/orientation=1` (landscape), `min_sdk=24`, `use_gradle_build=true`, `export_format` 0/1
- [ ] `project.godot` is single source for name/icon/splash (no duplication drift)
- [ ] `tools/perf/budget.json` gate passes before export
- [ ] `godot --headless --import` succeeds; `tests/regression/perf_budget_test.gd` passes
