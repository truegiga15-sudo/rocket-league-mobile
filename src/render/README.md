# src/render — Materials, Shaders, Lighting

**Owner:** WS38 Lighting (lead), WS39 Materials/PBR, WS40 Skybox, WS45 LOD/Culling
**Branches:** `ws38-*`, `ws39-*`, `ws40-*`, `ws45-*`

## Contents
- `default_env.tres` — default environment (referenced in `project.godot`)
- `materials/`, `shaders/` — PBR shaders, authored textures only
- `lighting/` — baked probes, light rigs

## Rules
- No procedural noise as content substitute — authored textures in `assets/authored/`.
- Budgets: draw calls <120, tris <300k, texture <350 MB (enforced in CI per WS10).
- Theme tokens live in `src/ui/theme.tres`, not here.
