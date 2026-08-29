# tests/regression — Deterministic Regression Suite

**Owner:** WS97 (lead)
**Branch:** `ws97-*`

## Purpose
Deterministic replay + snapshot tests. Every bugfix adds a regression case here.

## Entry Point
```bash
bash tests/regression.sh        # CI gate — must pass for any PR to main
python3 tools/validate_naming.py # naming gate (WS02)
```

## Conventions
- Cases are input logs + expected snapshots, not flaky timing tests.
- Physics tests run at 120 Hz fixed tick, delta clamped 1/240..1/30.
- Large fixtures use LFS if >50 MB.
