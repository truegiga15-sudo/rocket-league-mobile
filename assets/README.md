# assets — Authored Deterministic Assets Only

**Owner:** All asset WS (WS36-WS55, WS56, WS61-WS68, WS69-WS75) — per-subdirectory
**Rule:** No procedural generation (see `docs/architecture/00-conventions.md` §16)

## Structure
- `assets/authored/<ws>/` — committed deterministic assets: glb, png, wav, ogg, tres
- Large assets >50 MB require LFS review; tracked via `.gitattributes`

Naming: `category_name_variant_author_v01.ext` e.g. `car_octane_body_a_v01.glb`
