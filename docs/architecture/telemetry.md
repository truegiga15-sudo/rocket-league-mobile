# Telemetry & Test Hooks — WS09

Owner: WS09 · Branch: `ws09-telemetry-hooks` · Depends on: WS02
Conventions: `docs/architecture/00-conventions.md §11`

---

## 1. Purpose

Every workstream exposes `debug_export()` and `perf_mark()` for uniform
observability. WS09 provides the **central aggregator** (`TelemetryService`)
and the **deterministic replay harness** (`TestHooks`) that all other
workstreams use.

- **TelemetryService** — append-only JSON-lines log at `user://telemetry.log`
  plus live `debug_export()` state.
- **TestHooks** — deterministic RNG, input recording/replay, fixed-tick
  control for regression tests and the blind A/B critic harness
  (`tools/critic/harness.py`).

Both are Godot autoload singletons (registered in `project.godot`) so they
are available before any scene loads.

```ini
[autoload]
TelemetryService="*res://src/core/telemetry_service.gd"
TestHooks="*res://src/core/test_hooks.gd"
```

---

## 2. TelemetryService (`src/core/telemetry_service.gd`)

### 2.1 Autoload name

`TelemetryService`

### 2.2 File location

`user://telemetry.log` — JSON-lines (one JSON object per line, UTF-8).
Lines starting with `#` are comments (trim marker) and ignored by `read_log()`.

File is **bounded**: when `> 20 000` lines it is trimmed to the last
`10 000` plus a `# trimmed ...` marker.

### 2.3 Public API

```gdscript
func event(event_name: String, payload: Dictionary = {}) -> void
func perf_mark(label: String = "") -> Dictionary
func debug_export() -> Dictionary
func set_enabled(v: bool) -> void
func is_enabled() -> bool
func get_session_id() -> String
func get_event_count() -> int
func get_log_path() -> String  # -> "user://telemetry.log"
func clear_log() -> bool
func read_log(max_lines: int = 5000) -> Array[Dictionary]
func flush() -> void
signal event_logged(event_name: String, payload: Dictionary)
```

#### `event(event_name, payload)`

Written line shape:

```json
{"t_mono_ms": 12345, "t_rel_ms": 1200, "t_unix": 1724470000, "frame": 720,
 "session": "a1b2c3d4e5f6a7b8", "event": "goal_scored",
 "payload": {"team": 1, "speed_mps": 22.4}}
```

On `_ready()` a `session_start` event is emitted automatically.

#### `perf_mark(label)`

Samples `Performance` monitors and returns:

```gdscript
{"label": "pre_physics", "t_mono_ms": ..., "t_rel_ms": ..., "frame": ...,
 "fps": 60.0, "frame_ms": 14.2, "physics_ms": 1.8,
 "draw_calls": 42, "tris": 18000, "texture_mem_mb": 86.4}
```

Also logs it as `event("perf_mark", sample)`.

#### `debug_export()`

```gdscript
{"log_path": "user://telemetry.log", "enabled": true,
 "session_id": "a1b2…", "start_unix": 1724470000, "start_ticks_msec": 12345,
 "event_count": 42, "perf_mark_count": 7,
 "last_event": {...}, "buffer_size": 12,
 "file_exists": true, "file_size_bytes": 8192, "uptime_ms": 5400}
```

---

## 3. TestHooks (`src/core/test_hooks.gd`)

Deterministic replay for regression tests and the critic harness.
Records the normalized `move/look/boost/jump/drift/ballCam` frame that
`InputService` exposes and re-injects it on playback. Physics stays
deterministic because `Engine.physics_ticks_per_second` is locked and
the RNG is seeded (`seed()`).

### 3.1 Replay file

`user://replay.json` — versioned envelope:

```json
{
  "version": 1,
  "seed": 1337,
  "deterministic": true,
  "fixed_delta": 0.008333333,
  "created_unix": 1724470000,
  "frame_count": 360,
  "frames": [
    {"ticks_msec": 100, "frame": 1, "tick": 0,
     "move": "(0.2, 0.0)", "look": "(0, 0)",
     "boost": false, "jump": false, "drift": false, "ballCam": true}
  ]
}
```

### 3.2 Public API

```gdscript
# Deterministic mode
func enable_deterministic(p_seed: int = 1337, p_fixed_delta: float = -1.0) -> void
func disable_deterministic() -> void
func is_deterministic() -> bool
func get_seed() -> int
func set_seed(p_seed: int) -> void
func get_fixed_delta() -> float
func set_fixed_delta(v: float) -> void
func enable_test_mode(p_seed: int = 1337) -> void
func disable_test_mode() -> void
func is_test_mode() -> bool

# Recording
func start_recording(clear_existing: bool = true) -> void
func stop_recording() -> Array[Dictionary]
func is_recording() -> bool
func get_recorded_inputs() -> Array[Dictionary]
func clear_recording() -> void
func save_replay(path: String = "user://replay.json") -> bool
func load_replay(path: String = "user://replay.json") -> Dictionary

# Replay
func start_replay(frames: Array = []) -> bool
func start_replay_from_file(path: String = "user://replay.json") -> bool
func stop_replay() -> void
func is_replaying() -> bool
func get_replay_progress() -> Dictionary
func peek_next_frame() -> Dictionary
func step_replay() -> Dictionary
func inject_input(frame: Dictionary) -> void

# Helpers
func quantize_input(v: Vector2, steps: int = 100) -> Vector2
func deterministic_randf() -> float
func deterministic_randi_range(from: int, to: int) -> int
func debug_export() -> Dictionary
func perf_mark(_label: String = "") -> Dictionary
```

### 3.3 Example

```gdscript
TestHooks.enable_deterministic(42, 1.0/120.0)
TestHooks.start_recording()
# ... drive for 60 physics ticks ...
var frames := TestHooks.stop_recording()
TestHooks.save_replay("user://regression_turn.json")

TestHooks.start_replay(frames)
while TestHooks.is_replaying():
    TestHooks.step_replay()
    await get_tree().physics_frame
```

---

## 4. Verification Checklist

- [ ] `TelemetryService.event("test", {"x": 1})` appends JSON line to `user://telemetry.log`
- [ ] `TelemetryService.perf_mark("label")` returns dict with `fps`, `frame_ms`, logs `perf_mark`
- [ ] `TelemetryService.debug_export()` has `log_path`, `session_id`, `event_count`
- [ ] `TelemetryService.clear_log()` truncates file
- [ ] `TestHooks.enable_deterministic(123)` seeds RNG, `disable_deterministic()` restores 120 Hz
- [ ] `TestHooks.start_recording()` → `stop_recording()` captures frames
- [ ] `TestHooks.save_replay()` then `load_replay()` round-trips
- [ ] `TestHooks.start_replay(frames)` → `step_replay()` injects into `InputService`

---

## 5. References

- `src/core/telemetry_service.gd`
- `src/core/test_hooks.gd`
- `src/core/input_service.gd`
- `tools/perf/profiler.gd` + `tools/perf/budget.json` (WS10)
- `docs/architecture/00-conventions.md §11`
