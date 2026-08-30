# assets/authored/ball -- WS56 Ball Mesh Texture Trail
**Owner:** WS56 Ball Mesh Texture Trail
**Branch:** `ws56-ball-mesh`
**Source:** Authored placeholder -- CC0 sphere r=0.91 m (d=1.82 m), deterministic import.
**License:** CC0 -- placeholder geometry, deterministic import, no runtime noise.
## Contents
| File | Description | Source |
|------|-------------|--------|
| `ball_mesh_a_v01.glb` | Ball placeholder mesh -- sphere r0.91 m, triangulated, scale 1.0, 1 unit = 1 m, Y-up +Z forward, ~640 tris, 1 draw call | Authored minimal glTF placeholder, pending final art |
| `ball_texture_a_v01.png` | (optional) Authored ball texture -- POT, 1024x1024, mips on, VRAM compressed | Placeholder solid; committed when authored |
## Conventions
- Ball centered at origin, Y-up, right-handed, 1 unit = 1 m.
- Dimensions from `src/core/constants.gd` + `src/game/ball/ball_config.gd`: BALL_RADIUS 0.91 (Z/Y/X uniform), BALL_DIAMETER 1.82.
- No procedural generation at runtime -- all geometry authored and committed.
- Mesh is triangulated, scale 1.0, <12 MeshInstance3D, <300k tris.
- Trail: lightweight Node3D `BallTrail` toggled via `BallMesh.set_trail_enabled()` -- deterministic, no RNG.
- Git LFS: files >1 MB tracked via `.gitattributes` (`assets/authored/** filter=lfs`).
- Deterministic: clean clone + `git lfs pull` + Godot import = identical render.
- 120 Hz tick (`project.godot` physics/common/physics_ticks_per_second).
