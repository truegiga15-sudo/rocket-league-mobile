# Rocket League Mobile
Mobile port treating shipped Rocket League as visual + mechanical quality bar. GitHub is source of truth.

## Architecture
See `docs/architecture/00-conventions.md` and `docs/architecture/blind-ab-harness.md`

## 100 Workstreams
Tracker: `docs/progress/100-workstreams.md`

## Waves (sequential, not 200 at once)
- Wave 0: WS01-10 foundation
- Wave 1: WS11-35 physics + input
- Wave 2: WS36-55 arena + cars
- Wave 3: WS56-68 ball + VFX
- Wave 4: WS69-85 audio + UI
- Wave 5: WS86-100 platform + integration

Each WS: branch `wsNN-name`, builder PR, fresh critic blind A/B, iterate until critic picks ours.

## No Procedural Generation
All assets in `assets/authored/` are deterministic and committed. Large assets via Git LFS. Do not delete local assets after push — use `git lfs prune` if low on space.

## Reference Material
See `docs/reference/provenance.md` — lawful captures only, provenance logged, no redistributed Psyonix binaries.

## Quick Start (Godot 4.x)
```
# after gh auth login + repo creation
git clone <repo>
godot --import
# Android export via Godot editor or `tools/build/export.sh`
```

## Current Status
Phase 0 scaffold complete locally at `~/rocket-league-mobile`. Awaiting `gh auth login` to create/push GitHub repo.
