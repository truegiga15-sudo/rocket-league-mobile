# docs/architecture — Architecture Decision Records

**Owner:** WS01 (lead), all WS may propose RFCs
**Branch:** `ws01-*` for conventions, `ws02-*` for structure

## Documents
- `00-conventions.md` — shared conventions (source of truth)
- `scene-ownership.md` — per-file/WS ownership (WS02) ← you are here
- `blind-ab-harness.md` — critic harness spec (WS99)
- `save-schema.md` — save/config schema (WS08)
- `dependency-graph.md` — (future, WS01) wave/dependency visualization

Scene ownership: one scene per WS owner. No two WS edit same file without PR. `src/core/*` requires RFC.
