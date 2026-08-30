# assets/authored/car -- WS46 Octane / WS47 Dominus Mesh
**Owner:** WS46 Octane / WS47 Dominus
**Branch:** `ws46-octane` / `ws47-dominus`
**Source:** Authored placeholder -- CC0 box scaled to PhysicsConstants car 4.2x2.1x1.5 m.
**License:** CC0 -- placeholder geometry, deterministic import, no runtime noise.
## Contents
| File | Description | Source |
|------|-------------|--------|
| `octane_mesh_a_v01.glb` | Octane car placeholder mesh (single body, 1 material, ~1.8k tris, <12 draw calls) | Authored box mesh, triangulated, scale 1.0, 1 unit = 1 m, Y-up +Z forward |
| `dominus_mesh_a_v01.glb` | Dominus car placeholder mesh (single body, 1 material, ~1.8k tris, <12 draw calls) | Authored box mesh, triangulated, scale 1.0, 1 unit = 1 m, Y-up +Z forward |
## Conventions
- Car centered at origin, Y-up, right-handed, 1 unit = 1 m.
- Dimensions from `src/core/constants.gd`: CAR_LENGTH 4.2 (Z), CAR_WIDTH 2.1 (X), CAR_HEIGHT 1.5 (Y).
- No procedural generation at runtime -- all geometry is authored and committed.
- Mesh is triangulated, scale 1.0, <12 MeshInstance3D.
- Git LFS: files >1 MB tracked via `.gitattributes` (`assets/authored/** filter=lfs`).
- Deterministic: clean clone + `git lfs pull` + Godot import = identical render.
