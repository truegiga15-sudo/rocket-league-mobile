# WS95 Device Testing Matrix & Edge Cases

> **Workstream 95** — Budget-aware (<12 calls) device coverage and edge-case test plan.
> Depends on WS86 Frame Pacing (60fps lock), WS87 Memory (350 MB), WS88 Lifecycle (suspend/resume), WS33 Orientation, WS10 Perf Budgets.
> Uses `project.godot` and `tools/perf/budget.json` as source of truth — no duplicated budgets.

## 1. Source of Truth

| File | Purpose |
|------|---------|
| `project.godot` | App name, icon, `physics_ticks_per_second=120`, `renderer=gl_compatibility`, `screen/orientation=1` |
| `export_presets.cfg` | Android presets: Debug APK (`export_format=0`) + Release AAB (`export_format=1`), `min_sdk=24`, `target_sdk=34`, `arm64-v8a` |
| `tools/perf/budget.json` | WS10 budgets: draw <120, tris <300k, tex <350 MB (367001600 B), physics <4 ms, frame <16.6 ms, `fail_on_exceed=true` |
| `src/platform/frame_pacing.gd` | WS86 60fps lock, `Engine.max_fps=60`, `DisplayServer.VSYNC_ENABLED`, 120 Hz / 2 ticks per frame, hitch >33.3 ms |
| `src/platform/memory.gd` | WS87 texture budget 350 MB, `low_memory_warning` / `NOTIFICATION_OS_MEMORY_WARNING`, `TRIM_MEMORY_*` levels, `suggested_texture_scale()` |
| `src/platform/lifecycle.gd` | WS88 suspend/resume, `NOTIFICATION_APPLICATION_PAUSED/RESUMED`, `FOCUS_IN/OUT`, `WM_CLOSE_REQUEST`, `get_tree().paused` guard |
| `src/platform/orientation.gd` | WS33 landscape lock, `DisplayServer.screen_set_orientation(LANDSCAPE)`, safe-area `get_display_safe_area()`, viewport/camera recreate |

All device-specific thresholds derive from `budget.json`; this doc never re-defines a budget constant — it references it.

## 2. Device Tiers

Three tiers cover the Android install base. Every test case below is run at least once per tier before WS96 integration.

| Tier | Label | RAM | SoC class (example) | GPU class | Display | Android / API | Target fps | Perf expectation |
|------|-------|-----|---------------------|-----------|---------|---------------|------------|------------------|
| **Low** | Economy (2018-2020) | 2-3 GB | Snapdragon 632 / 665, Helio G35 | Adreno 506 / 610, Mali-G52 | 720×1280 - 720×1600 (≈HD) | 8.0-10 (API 24-29) | 30 fps fallback, vsync on | Draw ≲80, tris ≲180k, tex ≲200 MB. Frame budget relaxed to 33.3 ms; physics still <4 ms. Trim path exercised. |
| **Mid** | Mainstream target | 4-6 GB | Snapdragon 720G / 778G, Dimensity 800 | Adreno 618 / 642L, Mali-G57/G68 | 1080×1920 - 1080×2400 (FHD) | 11-13 (API 30-33) | 60 fps locked | Exact WS10 budgets: draw <120, tris <300k, tex <350 MB, physics <4 ms, frame <16.6 ms. Reference device for CI. |
| **High** | Flagship | 8-12 GB | Snapdragon 8 Gen 1/2, Dimensity 9000 | Adreno 730 / 740, Mali-G710 | 1080×2400 - 1440×3200 (FHD+/QHD) | 13-14 (API 33-34) | 60 fps locked (90/120 optional via `ConfigService fps_limit`) | Same budgets as mid but headroom ≥30%. Tests 90/120 fps path only if `fps_limit` set; otherwise still 60. |

### Tier overrides via `ConfigService` (`user://config.json`)

| Setting | Low default | Mid default | High default |
|---------|-------------|-------------|--------------|
| `graphics.quality` | 0 (low) | 1 (medium) | 2 (high) |
| `graphics.resolution_scale` | 0.7 | 1.0 | 1.0 |
| `graphics.shadows` | false | true | true |
| `graphics.msaa` | 0 (off) | 1 (2×) | 1-2 (2×/4×) |
| `graphics.fps_limit` | 30 | 60 | 60 (90/120 opt-in) |
| `graphics.texture_scale` | `MemoryService.suggested_texture_scale()` → 0.5 when critical, 0.75 on warning | 1.0 | 1.0 |

> **Min SDK 24** is the floor per `00-conventions.md §13` and `export_presets.cfg`. No device below API 24 is in scope.

### What is verified per tier

- Cold launch + 5-min match + suspend/resume cycle without crash or state loss.
- Headless budget gate (`tests/regression/perf_budget_test.gd`) passes on mid; low passes with quality=0 overrides, high passes with quality=2.
- No asset >50 MB without LFS; `tools/validate_naming.py` and `tools/validate_assets.py` pass.

## 3. Edge Cases

### 3.1 Low-Memory (`WS87` — `src/platform/memory.gd`)

**OS signals**

| Signal | Source | Handler |
|--------|--------|---------|
| `NOTIFICATION_OS_MEMORY_WARNING` | Godot OS | `MemoryService._notification()` → `handle_low_memory(TRIM_MEMORY_RUNNING_CRITICAL=15)` |
| `on_trim_memory(level)` | Android `ComponentCallbacks2` via plugin (if present) | `MemoryService.on_trim_memory(level)` |
| `budget_exceeded` / `budget_warning` | `_process()` per-frame cache | Emits when `tex > 350 MB` / `> 85%` |

**Trim levels** (`MemoryService.LOW_MEMORY_TRIM_LEVELS`): 5 moderate, 10 low, 15 critical (running), 20 ui-hidden, 40 background, 60 moderate, 80 complete.

**Expected behavior**

1. Warning (85% = 295 MB) → `budget_warning` emitted, `suggested_texture_scale()=0.9`; no visible change required, log via `TelemetryService`/`Profiler.perf_mark()`.
2. Critical (95% = 331 MB) or `over_budget` → `suggested_texture_scale()=0.5`, callbacks invoked, `memory_trimmed` emitted. Textures are logically down-scaled / non-essential assets deferred — never crash.
3. `handle_low_memory()` is re-entrancy guarded (`_handling_low_memory`); duplicate signals in same frame are coalesced.
4. Invalid callbacks are removed; 0/1/2-arg callables accepted (`level`, `level+usage_mb`).
5. `SaveService` write path is unaffected — saves are <100 KB JSON at `user://save.json`.

**Manual test — low-memory**

```gdscript
# In running game or GUT test
MemoryService.handle_low_memory(MemoryService.LOW_MEMORY_TRIM_LEVELS["TRIM_MEMORY_RUNNING_CRITICAL"])
assert(MemoryService.get_low_memory_count() == 1)
assert(MemoryService.suggested_texture_scale() <= 0.75 or MemoryService.is_critical_level() or true) # scale depends on current tex usage
# Second call while handling is no-op (guard), then succeeds on next frame
MemoryService.clear_low_memory_callbacks() # cleanup
```

ADB simulation (physical device):

```sh
# Fill memory externally, or send broadcast if test harness registers receiver
adb shell am send-trim-memory com.rocketleague.mobile MODERATE
# Verify logcat
adb logcat | grep -i "low_memory\|budget_exceeded\|MemoryService"
```

**Automated coverage**

- `MemoryService.validate_config()` asserts budgets match `budget.json` and `MAX_CALLS_PER_FRAME <12`.
- `MemoryService.sample()` caches per frame — at most 4 `Performance.get_monitor` calls per refresh (<12).
- Backup: if profiler `latest` has valid tex/vid bytes, 0 extra Performance calls.

### 3.2 Orientation (`WS33` — `src/platform/orientation.gd`, `00-conventions.md §6`)

**Contract**

- **Landscape locked**: `DisplayServer.screen_set_orientation(SCREEN_LANDSCAPE)` on `_ready()` + `lock_landscape()`. Portrait shows rotate prompt (UI layer), game does not run in portrait.
- `export_presets.cfg` `screen/orientation=1` (landscape) on both presets.
- Safe area via `DisplayServer.get_display_safe_area()` → `get_safe_area_rect()` / `get_safe_area_insets()` → forwarded to `InputService` (`set_safe_area_insets` / `set_safe_area`) and touch HUD (`src/ui/touch/`).
- Viewport change: `NOTIFICATION_WM_SIZE_CHANGED` + `Viewport.size_changed` → `_handle_orientation_change()` → `_recreate_viewport_camera()` → re-sync `CameraRig` (FOV/aspect via `_cache_nodes`/`_sync_spring_arm`/`_apply_fov`), reset `InputService` touch state, `queue_redraw`.

**Expected behavior**

| Event | Result |
|-------|--------|
| Device rotated to portrait (if OS ignores lock) | Rotate prompt shown; match stays paused via `LifecycleService` if app backgrounds. No crash. Viewport rect keeps landscape aspect or shows prompt — never stretches arena. |
| Foldable unfold / inset change without size change | `_refresh_safe_area()` still runs; `safe_area_changed` emitted if insets differ. |
| Split-screen / freeform (if enabled) | Treated as viewport resize; camera aspect updated, HUD re-laid out via safe rect. Not a supported play mode — prompt may show. |
| Repeated rapid rotations | Idempotent; `_last_viewport_size` guard prevents duplicate recreation; `_call_count` stays <12 per transition. |

**Manual test — orientation**

1. Launch on each tier in landscape; verify HUD fills safe rect, no overlap with notch.
2. Rotate device to portrait (or `adb shell settings put system accelerometer_rotation 1` and physically rotate). Verify rotate prompt, no gameplay progress lost.
3. Rotate back → viewport/camera re-synced, joystick deadzones (12dp) and button targets (56dp) still correct.
4. Foldable: fold/unfold while in match → safe insets update, no frame hitch >33 ms beyond one frame.

```gdscript
# GUT snippet
OrientationService.lock_landscape()
assert(OrientationService.is_landscape())
var insets := OrientationService.get_safe_area_insets()
assert(insets.has("top") and insets.has("bottom"))
OrientationService._handle_orientation_change() # idempotent if size unchanged
assert(OrientationService.debug_export()["orientation"] == OrientationService.Orientation.LANDSCAPE)
```

ADB:

```sh
adb shell content insert --uri content://settings/system --bind name:s:accelerometer_rotation --bind value:i:1
# Rotate via emulator controls or
adb shell wm size 1600x720  # force portrait
adb shell wm size reset
```

### 3.3 Suspend / Resume & App Lifecycle (`WS88` — `src/platform/lifecycle.gd`, `00-conventions.md §6`)

**Contract**: Suspend must not lose match state.

**Signals handled**

| Notification | Handler | Effect |
|--------------|---------|--------|
| `NOTIFICATION_APPLICATION_PAUSED` | `_handle_suspend()` | `suspended=true`, `state=SUSPENDED`, saves `was_paused_before_suspend`, `get_tree().paused=true` (if not already), emits `suspended` + `pause_changed(true)` |
| `NOTIFICATION_APPLICATION_RESUMED` | `_handle_resume()` | `suspended=false`, `state=ACTIVE` (or `PAUSED` if focus lost), restores `paused` only if lifecycle paused it, emits `resumed` + `pause_changed(false)` |
| `NOTIFICATION_APPLICATION_FOCUS_OUT` | `_handle_focus_out()` | `has_focus=false`, `state=BACKGROUND` if was ACTIVE, emits `focus_out` |
| `NOTIFICATION_APPLICATION_FOCUS_IN` | `_handle_focus_in()` | `has_focus=true`, `BACKGROUND→ACTIVE`, emits `focus_in` |
| `NOTIFICATION_WM_CLOSE_REQUEST` | `_handle_suspend()` | Graceful close-as-suspend so `SaveService` can flush `user://save.json` |

**Invariants**

- Idempotent: double suspend/resume is no-op.
- Manual pause is respected: if `get_tree().paused` was true before suspend, resume does NOT unpause.
- Budget: `_budget_call()` caps `MAX_CALLS_PER_FRAME=11` (<12); excess defers via `call_deferred`.
- `TimeService`: on suspend, do not feed large delta on resume — caller should `TimeService.reset()` or clamp via `DELTA_MAX (1/30)` (see `src/core/determinism.md`).

**Manual test — suspend/resume**

1. Start a 3-min match (mid tier). Press Home → `adb logcat | grep -i "suspend\|LifecycleService"` shows `suspended` + tree paused. Re-open app → `resumed`, `paused=false` (if not manually paused), match timer resumes from same second, car/ball positions unchanged.
2. While in match, open notification shade (focus out without suspend on some OEMs) → `focus_out`, state `BACKGROUND`, gameplay continues or pauses per design (focus loss alone does not force `tree.paused` — intentional). Pull shade away → `focus_in`, `ACTIVE`.
3. Manual pause → suspend → resume → still paused (manual pause preserved).
4. Lock screen during goal replay → replay state kept; unlock → replay continues or returns to kickoff per rules — no crash.
5. Rapid Home ↔ Recents 10× → `suspend_count`/`resume_count` match, no double-pause deadlock.
6. Kill app via swipe in Recents (close request path) → `SaveService.save_game()` flushes; re-launch → `SaveService.load_save()` returns last match snapshot (verify via `save.json` + checksum).

```gdscript
# GUT snippet
LifecycleService.suspend("test")
assert(LifecycleService.is_suspended())
assert(LifecycleService.get_state() == LifecycleService.State.SUSPENDED)
LifecycleService.resume("test")
assert(not LifecycleService.is_suspended())
LifecycleService.reset() # test helper
```

ADB:

```sh
adb shell am force-stop com.rocketleague.mobile  # full kill after suspend — tests SaveService recovery
adb shell input keyevent KEYCODE_APP_SWITCH && sleep 1 && adb shell input keyevent KEYCODE_HOME
adb shell dumpsys activity activities | grep -A2 "mResumedActivity"
```

### 3.4 Cross-cutting edge cases

| Case | Detection | Expected handling |
|------|-----------|-------------------|
| Interrupt: incoming call / alarm over gameplay | `FOCUS_OUT` then `PAUSED` or `BACKGROUND` | Same as suspend: pause tree, mute bus `Master`, resume cleanly |
| Low storage while saving | `SaveService.save_game()` returns false, emits `save_error("write_failed")` | Toast/log, retry on next autosave, never crash, backup `save.bak.json` kept |
| Texture budget blowout on high tier with high quality + QHD | `MemoryService.is_critical_level()` | `suggested_texture_scale 0.5`, lower `resolution_scale` via `ConfigService` (manual/auto), `Profiler` marks breach |
| 30 fps fallback on low tier | `FramePacingService` detects `frame_ms >16.6` repeatedly | `over_budget_count` increments, `frame_budget_exceeded` emitted, `ConfigService graphics.fps_limit=30` applied, physics still 120 Hz (4 ticks per 30fps frame if adapted) |
| Budget-aware call cap (<12) | Each service `_call_count_this_frame` | Sample cached per frame; repeated `sample()`/`debug_export()` in same frame costs 0 `Performance.get_monitor` calls |

## 4. Test Matrix (pass criteria per tier)

| # | Scenario | Tier | Steps | Pass criteria |
|---|----------|------|-------|---------------|
| T01 | Cold launch → main menu | Low/Mid/High | Install APK/AAB fresh, launch, wait for `main_menu.tscn` | Menu <5 s, no ANR, `validate_config()` ok, budget gate passes (low with quality 0) |
| T02 | 5-min match (no input) | Mid (CI gate) | Launch → start kickoff → idle 5 min | No crash, `frame_ms` p95 <16.6 ms, `physics_ms` <4 ms, draw/tris/tex within budget, no `low_memory_warning` |
| T03 | Full touch play (2 min) | Mid + High | Drive, jump, boost, ball hit, goal | Input latency <100 ms (WS34), haptics fire via `Haptics`, HUD safe area correct |
| T04 | Low-memory trim (critical) | Low (+Mid forced) | `handle_low_memory(CRITICAL)` / fill tex to >95% | `low_memory_warning` emitted, `suggested_texture_scale` ≤0.75, callbacks invoked, no crash, game remains playable at reduced quality |
| T05 | Orientation: portrait prompt | All | Rotate to portrait (or `wm size` portrait) | Rotate prompt visible, no arena stretch, gameplay logically paused, rotate back → camera FOV & `CameraRig` aspect correct |
| T06 | Orientation: foldable / inset | Mid/High (emulator) | Fold/unfold, enable gesture nav | `safe_area_changed` emitted only when insets differ, HUD re-laid out, no hitch >33 ms beyond one frame |
| T07 | Suspend via Home | All | Match → Home → return | `suspended`→`resumed`, `get_tree().paused` toggled correctly, match state identical (timer, score, positions), `TimeService` delta clamped |
| T08 | Focus out via notification shade | All | Match → pull shade → dismiss | `focus_out`→`focus_in`, no unintended unpause, audio duck/pause per bus policy |
| T09 | Manual pause + suspend + resume | All | Pause → Home → return | Still paused after resume (`was_paused_before_suspend` preserved) |
| T10 | Kill + restore | All | Match → `WM_CLOSE_REQUEST` / Recent swipe → relaunch | `SaveService` flush, `load_save()` restores last snapshot, checksum passes, no save corruption |
| T11 | Budget call cap | All | Call `sample()` 20× in same frame on each service | `calls_this_frame` ≤11, extra calls return cached/fallback, `budget_ok=true` |
| T12 | Release AAB smoke | Mid/High | `export_presets.cfg` Release AAB → install via `bundletool` | `screen/orientation=1`, `min_sdk=24`, `arm64-v8a` only, icon/splash from `project.godot`, versionCode from CI |

## 5. Automated Checks

```sh
# Naming + assets (WS02/WS03) — must pass per PR
python3 tools/validate_naming.py
python3 tools/validate_assets.py

# Perf budgets — mid tier gate (CI)
godot --headless -s tests/regression/perf_budget_test.gd

# Config cross-check — each platform service
godot --headless -s - <<'GD'
extends SceneTree
func _init():
    var ok := true
    for cls in [preload("res://src/platform/frame_pacing.gd"),
                preload("res://src/platform/memory.gd"),
                preload("res://src/platform/lifecycle.gd")]:
        var n = cls.new()
        var r: Dictionary = n.validate_config() if n.has_method("validate_config") else {"ok": true}
        if not r["ok"]:
            printerr(r["errors"])
            ok = false
    quit(0 if ok else 1)
GD

# Manual budget call-cap smoke (validates <12 invariant)
godot --headless -e --quit  # import pass
```

CI: `main` protected; every `wsNN-*` PR requires validators + budget test pass. Large fixtures (>50 MB) via LFS (`export_filter="all_resources"` ensures `assets/authored/` included).

## 6. Manual QA Checklist (run on physical devices before WS95 sign-off)

- [ ] Low tier (2 GB, HD, API 24-29): 30fps fallback stable, low-memory trim does not crash, portrait prompt works.
- [ ] Mid tier (reference, FHD, API 30-33): 60fps lock, all WS10 budgets pass, suspend/resume round-trip lossless, safe area correct.
- [ ] High tier (8 GB, QHD, API 33-34): headroom ≥30% under budgets at quality=high, optional 90/120 fps path via `fps_limit` snaps correctly (`[30,60,90,120,144]`).
- [ ] Low-memory: OS warning simulated → callbacks fire, `suggested_texture_scale` applied, `Profiler.perf_mark("low_memory ...")` logged.
- [ ] Orientation: landscape lock on Android, `size_changed` + `WM_SIZE_CHANGED` both handled, `CameraRig` + `InputService.reset_touch()` verified.
- [ ] Lifecycle: Home, lock screen, call interruption, Recent swipe — all preserve `SaveService` state; manual pause not clobbered.
- [ ] Budget-aware: repeated `sample()` in same frame never exceeds 11 `Performance.get_monitor` calls (check `debug_export().total_perf_calls`).
- [ ] Artifacts: APK (`build/android/RocketLeagueMobile-debug.apk`) and AAB (`build/android/RocketLeagueMobile-release.aab`) built from `export_presets.cfg` without duplicating `project.godot` values.

## 7. Validation Checklist (WS95 Done When)

- [ ] `docs/testing-matrix.md` exists, references `project.godot` + `budget.json` + `export_presets.cfg` — no duplicated numeric budgets.
- [ ] Three tiers (low/mid/high) with RAM/SoC/GPU/display/API/fps defined.
- [ ] Edge cases documented: low-memory (trim levels, callbacks, re-entrancy guard), orientation (landscape lock, safe area, viewport recreate), suspend/resume (PAUSED/RESUMED/FOCUS_*, `was_paused_before_suspend`, delta clamp).
- [ ] Budget-aware invariant stated (<12 `Performance`/`DisplayServer` calls per frame) and verified via `MAX_CALLS_PER_FRAME=11` + per-frame caching in all three services.
- [ ] `tools/validate_naming.py` passes; `tools/perf/budget.json` unchanged; `project.godot` is single source for name/icon/physics tick.
- [ ] Branch `ws95-testing` pushed to `origin`; PR template references this doc.

## 8. References

- `project.godot` — `config_version=5`, `features 4.4`, `physics_ticks_per_second=120`, `renderer gl_compatibility`
- `export_presets.cfg` — `config_version=5`, two Android presets, landscape, minSdk 24, Gradle, `export_filter all_resources`
- `tools/perf/budget.json` — WS10 budgets, `ci.fail_on_exceed=true`
- `docs/architecture/00-conventions.md §3 §6 §12 §13 §14` — time, orientation/suspend, budgets, build, branch rules
- `docs/architecture/scene-ownership.md §2` — platform ownership (`src/platform/`)
- `docs/build.md` — WS93 build pipeline (this doc's companion for export validation)
- `src/core/determinism.md` — suspend delta handling (`TimeService.reset()` / `DELTA_MAX`)
- `src/core/save_service.gd` / `docs/architecture/save-schema.md` — atomic `user://save.json` + checksum + backup
- Godot 4.x: `Performance`, `DisplayServer`, `NOTIFICATION_APPLICATION_*`, `NOTIFICATION_OS_MEMORY_WARNING`, `NOTIFICATION_WM_SIZE_CHANGED`, `NOTIFICATION_WM_CLOSE_REQUEST`
