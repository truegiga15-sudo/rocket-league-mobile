# Save & Config Schema — WS08

Spec: `docs/architecture/00-conventions.md §10` — `SaveService` at `user://save.json`, `ConfigService` at `user://config.json`. Versioned JSON + checksum, atomic writes, migrations.

No procedural generation — all defaults are explicit literals.

---

## 1. File Locations

| Service | Path | Format |
|---------|------|--------|
| SaveService | `user://save.json` | enveloped JSON (version, checksum, payload, saved_at) |
| SaveService backup | `user://save.bak.json` | previous primary copy |
| SaveService temp | `user://save.tmp.json` | atomic write staging |
| ConfigService | `user://config.json` | enveloped JSON |
| ConfigService backup/temp | `user://config.bak.json` / `user://config.tmp.json` | same |

`user://` resolves to `~/.local/share/godot/app_userdata/Rocket League Mobile/` (desktop) / `app_userdata` (Android).

---

## 2. Envelope (save.json / config.json)

Both files use the same envelope shape:

```json
{
  "version": 3,
  "checksum": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "saved_at": 1724470000,
  "payload": { /* ... */ }
}
```

| Field | Type | Notes |
|-------|------|-------|
| `version` | int | `CURRENT_VERSION` of writer. Required. |
| `checksum` | string | hex SHA256 of `"<version>:<canonical_payload_json>"`. Empty means no validation (legacy v1). |
| `saved_at` | int | Unix seconds (`Time.get_unix_time_from_system()`). For display / conflict resolution. |
| `payload` | object | Actual data (schema below). |

### Checksum algorithm (both services)

```
canonical = JSON.stringify(payload)          // no pretty-print, deterministic
to_hash   = str(version) + ":" + canonical  // e.g. "3:{\"player\":{...}}"
digest    = SHA256(to_hash.to_utf8_buffer()) // via HashingContext.HASH_SHA256
checksum  = hex(digest)                      // lowercase hex, 64 chars
```

On mismatch the service tries `*.bak.json`; if that also fails it emits `save_error("checksum_mismatch")` and returns defaults.

### Atomic write

1. Write new envelope to `*.tmp.json`.
2. Copy current primary to `*.bak.json` (if exists).
3. Copy `*.tmp.json` → primary.
4. Delete `*.tmp.json`.

---

## 3. Save Schema (payload at `save.json`)

`CURRENT_VERSION = 3`. `src/core/save_service.gd` is the owner.

```json
{
  "player": {
    "display_name": "",
    "created_at": 0,
    "last_played_at": 0,
    "xp": 0,
    "level": 1,
    "matches_played": 0,
    "wins": 0
  },
  "career": {
    "season": 1,
    "division": "unranked",
    "mmr": 0
  },
  "garage": {
    "equipped_car": "octane",
    "equipped_decal": "none",
    "equipped_wheels": "default",
    "owned_cars": ["octane"],
    "owned_decals": ["none"],
    "owned_wheels": ["default"]
  },
  "progress": {
    "tutorial_completed": false,
    "tutorial_step": 0,
    "training_completed": [],
    "achievements": {}
  },
  "stats": {
    "goals": 0,
    "saves": 0,
    "assists": 0,
    "shots": 0,
    "playtime_seconds": 0
  },
  "meta": {
    "save_format": 3
  }
}
```

### Save Migrations

| From | To | Change |
|------|----|--------|
| 0 (no version) | 1 | Wrap bare dict into envelope; stamp `meta.save_format=1`. |
| 1 | 2 | Add `garage.owned_*`, `progress.achievements`, `stats.playtime_seconds`, `career.division`. |
| 2 | 3 | Add `player.last_played_at/level/matches_played`, `progress.training_completed`, `stats.assists/shots`. |

`SaveService.migrate(payload, from_version)` is pure; `load_save()` calls it then re-saves.

---

## 4. Config Schema (payload at `config.json`)

`CURRENT_VERSION = 2`. `src/core/config_service.gd` is the owner.

```json
{
  "version": 2,
  "graphics": {
    "quality": 1,
    "quality_name": "medium",
    "vsync": true,
    "fps_limit": 60,
    "resolution_scale": 1.0,
    "shadows": true,
    "msaa": 1,
    "bloom": true,
    "motion_blur": false
  },
  "audio": {
    "master_volume": 1.0,
    "music_volume": 0.8,
    "sfx_volume": 1.0,
    "crowd_volume": 0.9,
    "ui_volume": 0.9,
    "master_muted": false,
    "music_muted": false
  },
  "controls": {
    "sensitivity": 1.0,
    "invert_y": false,
    "vibration": true,
    "deadzone_move": 0.12,
    "deadzone_look": 0.12,
    "ball_cam_toggle": true,
    "layout_preset": "default"
  },
  "general": {
    "language": "en",
    "show_fps": false,
    "safe_area_applied": true
  }
}
```

| Section | Key | Range / enum | Default |
|---------|-----|--------------|---------|
| graphics.quality | 0=low 1=medium 2=high 3=ultra | `1` |
| graphics.fps_limit | 0,30,60,90,120,144 (snaps) | `60` |
| graphics.resolution_scale | 0.5..1.0 | `1.0` |
| graphics.msaa | 0=off 1=2x 2=4x | `1` |
| audio.*_volume | 0.0..1.0 linear | master 1.0, music 0.8, etc |
| controls.sensitivity | 0.2..3.0 | `1.0` |
| controls.layout_preset | `default` `left_handed` `claw` | `default` |
| general.language | BCP-47 | `en` |

Setters clamp — e.g. sensitivity 10 → 3.0, fps 77 → 90.

### Config migrations

| From | To | Change |
|------|----|--------|
| 1 | 2 | Add `general`, `graphics.bloom/motion_blur/msaa/quality_name`, `audio.crowd/ui_volume`+`music_muted`, `controls.layout_preset`+`ball_cam_toggle`. |

### Side effects on load/set

- **Graphics**: `DisplayServer.window_set_vsync_mode`, `Engine.max_fps`, `Viewport.msaa_3d`.
- **Audio**: `AudioServer.set_bus_volume_db` for `Master, Music, SFX, Crowd, UI`.
- **Controls**: no direct engine call; `InputService` reads sensitivity/deadzone via getter.

---

## 5. Public APIs

### SaveService (`src/core/save_service.gd`, autoload `SaveService`)

```gdscript
func load_save() -> Dictionary
func save_game(data: Dictionary) -> bool
func migrate(data: Dictionary, from_version: int) -> Dictionary
func has_save() -> bool
func delete_save() -> bool
func validate_payload(payload: Dictionary) -> Dictionary
func debug_export() -> Dictionary
func perf_mark() -> Dictionary
signal save_loaded(data: Dictionary)
signal save_saved(data: Dictionary)
signal save_error(reason: String)
signal save_migrated(from_version: int, to_version: int)
```

### ConfigService (`src/core/config_service.gd`, autoload `ConfigService`)

```gdscript
func load_config() -> Dictionary
func save_config() -> bool
func save_config_dict(data: Dictionary) -> bool
func get_setting(section: String, key: String, default: Variant = null) -> Variant
func set_setting(section: String, key: String, value: Variant, persist: bool = true) -> bool
func reset_to_defaults(persist: bool = true) -> Dictionary
func reset_section(section: String, persist: bool = true) -> bool
func debug_export() -> Dictionary
func perf_mark() -> Dictionary
signal setting_changed(section: String, key: String, value: Variant)
signal config_loaded(config: Dictionary)
signal config_saved(config: Dictionary)
signal config_error(reason: String)
```

---

## 6. Error Handling

| Condition | Result |
|-----------|--------|
| File missing | return defaults |
| Empty / unreadable | `save_error` + defaults |
| JSON parse fail | try backup; else defaults |
| Checksum mismatch | try backup; else defaults + `checksum_mismatch` |
| Future version | warn, `future_version`, return payload as-is |
| Write fail | `save_error("write_failed:<code>")` → false |

---

## 7. Autoload Registration

```ini
[autoload]
SaveService="*res://src/core/save_service.gd"
ConfigService="*res://src/core/config_service.gd"
```

Order: `SaveService` before `ConfigService`.

---

## 8. Testing Checklist

- [ ] Fresh install → `load_save()` returns defaults without creating file.
- [ ] `save_game(payload)` then `load_save()` round-trips, checksum passes.
- [ ] Corrupt `save.json` → defaults, backup tried.
- [ ] Tamper one byte → checksum fails, backup restored if valid.
- [ ] v1 fixture → migrate → v3 has new keys.
- [ ] `set_setting("graphics","fps_limit",77)` snaps to nearest allowed.
- [ ] Clamp: `set_setting("controls","sensitivity",10.0)` → `3.0`.
- [ ] `reset_to_defaults()` clears custom values.
- [ ] `debug_export()` / `perf_mark()` shapes correct.

---

## 9. No Procedural Generation

Persistence is deterministic JSON. No runtime noise.

---

## 10. References

- `src/core/save_service.gd`
- `src/core/config_service.gd`
- `docs/architecture/00-conventions.md §10`
- Godot 4.x `FileAccess`, `JSON`, `HashingContext`, `AudioServer`, `DisplayServer`
