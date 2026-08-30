# WS03 — Asset Import Pipeline & Naming (Authoritative)

**Owner:** WS03 Asset Import Pipeline & Naming  
**Branch:** `ws03-asset-pipeline`  
**Status:** Foundation — deterministic imports only  
**Source of truth:** this file + `docs/architecture/00-conventions.md` §2, §16 + `docs/architecture/scene-ownership.md` §3, §5  
**Validators:** `src/core/asset_import.gd` (GDScript) and `tools/validate_assets.py` (CI/Python) — must stay in sync.

## 1. Principle — Deterministic Imports Only
> Every mesh/material/texture/animation/VFX/audio is authored, sourced (CC0/licensed), imported, and committed under `assets/authored/<ws>/`. Runtime procedural noise as content substitute is forbidden.
- No `OpenSimplexNoise`/`FastNoiseLite`/`NoiseTexture` as content.
- Reproducible: clean clone + `git lfs pull` + Godot import = identical assets.
- Do NOT delete locally after push — use `git lfs prune`.

```
assets/authored/
  car_octane/       WS46  car_octane_body_a_v01.glb
  stadium/          WS36  stadium_floor_c_v02.png
  ball/             WS56  ball_mesh_a_v01.glb
  vfx_boost/        WS61  vfx_boost_exhaust_a_v01.png
  audio_engine/     WS69  audio_engine_loop_a_v01.ogg
```

## 2. Git LFS — >1 MB and >50 MB Rules
**Rule:** Any `.glb/.gltf/.fbx/.png/.wav/.ogg/.mp3/.mp4/.webp/.jpg/.jpeg` >1 MiB MUST be LFS-tracked. >50 MiB requires review (§14).

`.gitattributes`:
```
# WS03 Asset Pipeline — LFS tracking (deterministic assets only)
assets/authored/** filter=lfs diff=lfs merge=lfs -text
*.glb filter=lfs diff=lfs merge=lfs -text
*.gltf filter=lfs diff=lfs merge=lfs -text
*.fbx filter=lfs diff=lfs merge=lfs -text
*.png filter=lfs diff=lfs merge=lfs -text
*.wav filter=lfs diff=lfs merge=lfs -text
*.mp3 filter=lfs diff=lfs merge=lfs -text
*.ogg filter=lfs diff=lfs merge=lfs -text
*.mp4 filter=lfs diff=lfs merge=lfs -text
```
Validate: `git check-attr filter -- <path>` must be `lfs` for >1MB; `tools/validate_assets.py` enforces.

## 3. Naming — `category_name_variant_author_v01.ext`
**Regex:** `^[a-z0-9]+(?:_[a-z0-9]+){2,}_v\d{2}\.[a-z0-9]+$`
Segments: `category` + `name` + `variant` + `author` + `vNN` + `.ext` (lowercase).
Examples: `car_octane_body_a_v01.glb`, `stadium_floor_c_v02.png`, `audio_engine_loop_a_v01.ogg`
Invalid: `CarOctane.glb`, `car_body_v1.glb`, `CAR_BODY_A_V01.GLB`

## 4. Textures — Power-of-Two
Both dimensions in `[2,4,8,16,32,64,128,256,512,1024,2048,4096]`, max 4096, mipmaps on, VRAM Compressed.

## 5. Meshes — Triangulated
Fully triangulated, no ngons, scale 1.0 (1 unit=1m), Y-up +Z forward.

## 6. No Procedural Generation
`OpenSimplexNoise|FastNoiseLite|NoiseTexture|Perlin` fails CI.

## 7. Import Presets
- texture: `compress/mode=2`, `mipmaps/generate=true`, `max_size=4096`
- mesh: `require_triangulated=true`, `scale=1.0`, `meshes/ensure_tangents=true`
- audio: `bus=SFX`, `import/wav/trim=false`
Committed as `.import` files; missing warns.

## 8. Validation
```bash
python3 tools/validate_assets.py
python3 tools/validate_assets.py --check assets/authored/stadium
python3 tools/validate_naming.py
```

## 9. Workflow
1. `git checkout -b wsNN-short-name` 2. Author triangulated scale 1.0 3. Export `category_name_variant_author_v01.ext` into `assets/authored/<ws>/` 4. `git check-attr filter -- assets/...` → `lfs` if >1MB 5. Import in Godot, set preset, commit `.import` 6. `python3 tools/validate_assets.py --check assets/authored/<ws>`

## 10. Verification Checklist
- [x] `src/core/asset_import.gd`  - [x] `tools/validate_assets.py`  - [x] `.gitattributes`  - [x] `assets/authored/.gitkeep`  - [x] This file  - [x] Validators pass

## 11. Mirroring Rule
`src/core/asset_import.gd` and `tools/validate_assets.py` share `LFS_THRESHOLD_BYTES=1048576`, `RE_ASSET_AUTHORED`, `POWER_OF_TWO_SIZES`.
