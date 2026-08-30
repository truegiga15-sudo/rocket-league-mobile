# assets/authored/arena — WS36 DFH Stadium Geometry

**Owner:** WS36 Stadium Geometry
**Branch:** `ws36-stadium`
**Source:** Authored placeholder — CC0 procedural box scaled to PhysicsConstants (60×40×20 m), not a Psyonix rip.
**License:** CC0 — placeholder geometry, deterministic import, no runtime noise.

## Contents

| File | Description | Source |
|------|-------------|--------|
| `stadium_dfh_mesh_a_v01.glb` | DFH stadium placeholder mesh (floor + walls + ceiling, single material, <12 draw calls) | Authored box mesh, triangulated, 1 unit = 1 meter, Y-up +Z forward |
| `stadium_dfh_floor_a_v01.png` | Optional floor texture placeholder 512×512 POT, compressed | Authored solid color, CC0 |

## Conventions

- Arena centered at origin, Y-up, right-handed, 1 unit = 1 m.
- Dimensions from `src/core/constants.gd`: ARENA_LENGTH 60.0 (Z), ARENA_WIDTH 40.0 (X), ARENA_HEIGHT 20.0 (Y).
- No procedural generation at runtime — all geometry is authored and committed.
- Mesh is triangulated, scale 1.0, ensures tangents, <12 MeshInstance3D in `stadium.tscn`.
- Git LFS: files >1 MB tracked via `.gitattributes` (`assets/authored/** filter=lfs`).
- Deterministic: clean clone + `git lfs pull` + Godot import = identical render.
