# tools — Developer Tooling (no runtime dependencies)

**Owner:** WS01 (harness), WS02/WS03 (naming/assets), WS09 (telemetry hooks), WS10 (perf)

## Subdirectories
- `critic/` — blind A/B harness (WS99) — see `docs/architecture/blind-ab-harness.md`
- `perf/` — performance harness, budget enforcement (WS10, WS86-WS87)
- `validate_naming.py` — naming convention validator (WS02/WS03)
- `validate_assets.py` — asset pipeline validator: naming + LFS + power-of-two (WS03) — see `docs/architecture/asset-pipeline.md` §8

Tools must not be imported by `src/` at runtime.
