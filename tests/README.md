# tests — Regression & Integration

**Owner:** WS97 Regression Suite (lead), WS96 Integration Pass
**Branches:** `ws97-*`, `ws96-*`

## Layout
- `tests/regression/` — deterministic regression cases, `regression.sh` entry point
- `tests/integration/` — (future) cross-WS integration tests (WS96)

PRs must pass `tests/regression.sh` per branch rules.
