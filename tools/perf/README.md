# tools/perf — Performance Harness

**Owner:** WS10 Budgets (lead), WS86 Frame Pacing, WS87 Memory
**Branches:** `ws10-*`, `ws86-*`, `ws87-*`

## Budgets (from `00-conventions.md` §12)
- Draw calls <120, tris <300k, texture <350 MB, physics <4 ms, frame <16.6 ms

## Contents (to be added by WS10)
- `bench.py` — headless perf marks, CI gate
- `budgets.json` — machine-readable budgets

Every WS must expose `perf_mark()` for this harness.
Budgets enforced in CI — PR fails if exceeded.
