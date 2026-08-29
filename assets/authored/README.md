# assets/authored — Committed Deterministic Assets

**Owner:** Per-WS — each WS writes only to `assets/authored/<ws-short-name>/`
**Branches:** asset WS branches only

## Rules (strict)
- Every mesh/material/animation/VFX/audio must be authored, sourced (CC0/licensed), imported, and committed as deterministic asset.
- **No procedural generation at runtime** as content substitute — use authored textures.
- Naming: `category_name_variant_author_v01.ext` (e.g. `car_octane_body_a_v01.glb`, `stadium_floor_c_v02.png`, `boost_loop_a_v01.ogg`)
- Large assets: use Git LFS. Do NOT delete locally after push to free space — use `git lfs prune`.
- Provenance for RL captures logged in `docs/reference/provenance.md`.

## Example Layout
```
assets/authored/
  car_octane/       WS46
  stadium/          WS36
  ball/             WS56
  vfx_boost/        WS61
  audio_engine/     WS69
```

Each subdirectory must contain its own README.md stating source/license.
