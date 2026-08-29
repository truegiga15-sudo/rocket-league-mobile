# src/audio — Mixer & Banks

**Owner:** WS69-WS75 Audio (lead WS75 Mixer Routing)
**Branches:** `ws69-*`…`ws75-*`

## Buses
Master -> [Music, SFX, Crowd, UI] — see `docs/architecture/00-conventions.md` §8.

## Contents
- `audio_service.gd` — sole entry point; no raw `AudioStreamPlayer` in gameplay
- `banks/` — authored audio banks (CC0/licensed, committed)
- `mixer.tres` — bus layout

## Rules
- All SFX through `AudioService`. Gameplay WS emit events, audio WS subscribes.
- Naming: `audio_<event>_<variant>_a_v01.ogg` e.g. `audio_boost_start_a_v01.ogg`.
