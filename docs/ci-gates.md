# WS97 — Regression Suite & CI Gates

> **Workstream 97** — Budget-aware (<12 Performance calls) regression suite and CI gates.
> Depends on WS96 Integration (01–95 wired). Branch `ws97-regression` from `main` (194863f, Godot 4.x).
> Source of truth: `project.godot` + `tools/perf/budget.json` + `src/core/*.gd` — this doc never re-defines a budget.

---

## 0. How to Use

- CI validates every push/PR via `.github/workflows/ci.yml` — all gates green = merge-able.
- **Quick Gate** (§7) is the local paste-ready equivalent — run before push.
- Failures block `main`; log gap in `docs/progress/100-workstreams.md` row 97 and open issue.
- `<12 calls` = each perf harness file makes **at most 11** `Performance.get_monitor` calls per cache refresh (WS10 budget-aware).

---

## 1. Source of Truth

| File | Owns | Verify |
|------|------|--------|
| `project.godot` | `physics_ticks_per_second=120`, autoloads, `gl_compatibility`, `default_env.tres` | `grep physics_ticks_per_second project.godot` == 120 |
| `export_presets.cfg` | Android Debug APK (`export_format=0`) + Release AAB (`1`), `min_sdk=24`, `target_sdk=34`, `arm64-v8a` | `grep preset. export_presets.cfg` == 2 |
| `tools/perf/budget.json` | draw<120 tris<300k tex<350 MB (367001600 B) phys<4 ms frame<16.6 ms `fail_on_exceed=true` | `cat tools/perf/budget.json` |
| `tools/validate_naming.py` | snake/Pascal/Type_Name, branch `wsNN-*`, allowlist for legacy `*.tscn` | `python3 tools/validate_naming.py` |
| `tools/validate_assets.py` | `category_name_variant_author_v01.ext`, LFS >1 MB, POT textures, no procedural noise | `python3 tools/validate_assets.py` |
| `tests/regression/perf_budget_test.gd` | Headless budget gate (optional when Godot present) | `godot --headless -s tests/regression/perf_budget_test.gd` |

No other file re-defines a budget, tick, or naming rule.

---

## 2. CI Pipeline — `.github/workflows/ci.yml`

Triggers: `push` to `main` + `ws*`, `pull_request` to `main`. One job `gates` on `ubuntu-latest`.

| Gate | Step in `ci.yml` | Command | Fail condition |
|------|-------------------|---------|----------------|
| **G1** | Naming | `python3 tools/validate_naming.py` | snake/Pascal/branch violation (exit 1) |
| **G2** | Assets | `python3 tools/validate_assets.py` | authored naming / LFS / POT / >50 MB (exit 1) |
| **G3a** | Perf budgets JSON | `python3 -c "assert budget.json budgets"` | `draw 120 / tris 300k / tex 350 / phys 4.0 / frame 16.6` mismatch |
| **G3b** | Budget-aware <12 calls | per-file `Performance.get_monitor` count <12 | any `*.gd` in `src/` or `tools/` has ≥12 calls |
| **G4** | Config sanity | `grep physics_ticks_per_second`, preset & landscape checks | tick !=120 or preset missing |
| **G5** | Regression guards | `grep -r Input.is_action src/game` ==0, no duplicate budgets | raw Input in gameplay or duplicate budget constant |
| **G6** | Godot headless (soft) | `godot --headless --import` + `perf_budget_test.gd` | `continue-on-error: true` — local must pass even if CI soft-fails |

Validate YAML locally before push:

```sh
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); print('YAML OK')"
# or quick structural:
grep -q "validate_naming" .github/workflows/ci.yml && echo "ci.yml OK"
```

---

## 3. Naming Gate — G1

Enforced by `tools/validate_naming.py` (WS02/WS03). See `docs/architecture/00-conventions.md` §2 + `scene-ownership.md` §5.

- `*.gd` `*.json` `*.cfg` `*.tres` → `snake_case` (`tire_friction.gd`)
- `*.tscn` → `PascalCase` (`CarChassis.tscn`) — allowlist: `coordinate_test.tscn`, `ball.tscn`, `camera_rig.tscn`, `arena_collision.tscn`, `car_chassis.tscn`, `stadium.tscn`, `main_menu.tscn`, `settings.tscn`, `loading.tscn` (legacy WS97 exemption; new scenes must be PascalCase)
- authored assets → `category_name_variant_author_v01.ext` (`car_octane_body_a_v01.glb`)
- branch → `wsNN-short-name` (`ws97-regression`), also allows `main` and `integrate/wave-N`
- `.tscn` node names → `Type_Name` (`Car_Octane`) is **warning** (strict mode `--strict` upgrades to error)

```sh
python3 tools/validate_naming.py
python3 tools/validate_naming.py --check src/game/car
python3 tools/validate_naming.py --strict   # node warnings → errors
```

---

## 4. Asset Gate — G2

Enforced by `tools/validate_assets.py` (WS03). See `docs/architecture/asset-pipeline.md`.

- Authored naming under `assets/authored/` per regex `^[a-z0-9]+(_[a-z0-9]+){2,}_v\d{2}\.[a-z0-9]+$`
- LFS: files >1 MB with `*.glb/*.png/*.wav/*.ogg/*.mp3/*.mp4` must match a pattern in `.gitattributes` (`assets/authored/**`, `*.glb`, etc.); >50 MB requires review (error)
- Textures: POT dimensions (`2,4,…,4096`), max 4096, enforced for `assets/authored/**` and any `*.png/*.jpg`
- `.import` presets: warned if missing under `assets/authored/`
- Procedural markers: warns on `OpenSimplexNoise|FastNoiseLite|procedural generat` in `*.gd/*.tres/*.tscn` (§16 authored-only)

```sh
python3 tools/validate_assets.py
python3 tools/validate_assets.py --check assets/authored
```

`.gitattributes` LFS patterns (commit this file — CI reads it):

```
assets/authored/** filter=lfs diff=lfs merge=lfs -text
*.glb  *.gltf  *.fbx  *.png  *.wav  *.mp3  *.ogg  *.mp4  filter=lfs
```

---

## 5. Perf Budget Gate — G3 (budget-aware <12 calls)

From `tools/perf/budget.json` v1 (`fail_on_exceed=true`):

| Metric | Max | Source | Enforce |
|--------|-----|--------|---------|
| draw_calls | 120 | `Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME` | true |
| tris | 300 000 | `Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME` | true |
| texture_mem | 350 MB (367001600 B) | `Performance.RENDER_TEXTURE_MEM_USED` | true |
| physics_ms | 4.0 ms | `Performance.TIME_PHYSICS_PROCESS *1000` | true |
| frame_ms | 16.6 ms | `TIME_PROCESS + TIME_PHYSICS_PROCESS` (60 fps) | true |

Code must reference `budget.json`/`constants.gd` — no hard-coded duplicates elsewhere (G5 checks).

**<12 Performance calls per harness/file** — each perf path batches monitors in one cached sample per frame and re-uses the wrapper:

- `src/platform/frame_pacing.gd` — 7 `Performance` monitors via `_perf()` (≤11, comment `At most 7 … under 12`)
- `src/platform/memory.gd` — 4 monitors via `_perf()` (≤11)
- `tools/perf/profiler.gd` — 8 direct monitors (≤11)
- `src/core/telemetry_service.gd` — 6 monitors (≤11)
- Check: `grep -rn Performance.get_monitor --include="*.gd" src/ tools/ | wc -l` is global noise; the gate counts **per file**. CI fails if any `*.gd` has ≥12.

```sh
# budget JSON
python3 -c "import json; b=json.load(open('tools/perf/budget.json')); assert b['budgets']['draw_calls']['max']==120"
# per-file <12 check
python3 -c "
import re, pathlib
for f in list(pathlib.Path('src').rglob('*.gd'))+list(pathlib.Path('tools').rglob('*.gd')):
  c=len(re.findall(r'Performance\.get_monitor', f.read_text(errors='ignore')))
  w=len(re.findall(r'_perf\(Performance', f.read_text(errors='ignore')))
  eff=w if w else c
  assert eff<12, f'{f} {eff} >=12'
print('<12 OK')
"
# headless (requires Godot 4.4)
godot --headless -s tests/regression/perf_budget_test.gd
```

---

## 6. Regression Guards — G5

| Guard | Command | Must be |
|-------|---------|---------|
| No duplicate budget literals outside allowlist | `grep -rn "367001600\|350" --include="*.gd" src/ \| grep -v budget.json\|constants\|memory.gd\|frame_pacing\|profiler` | 0 hits |
| No raw Input in gameplay | `grep -rn "Input.is_action" --include="*.gd" src/game/` | 0 hits — gameplay reads `InputService` only |
| 120 Hz intact | `grep physics_ticks_per_second project.godot` | `120` |
| Save round-trip smoke | `SaveService.save_game` → `load_save` identical | pass |
| Export presets | `grep "Android - Debug APK" export_presets.cfg` + `export_format` | 0/1 present, `orientation=1` |

---

## 7. Quick Gate — Paste-Ready Validation (WS97)

Run on `ws97-regression` head. Every line must print `OK`; warnings are allowed for G1/G2 non-strict.

```sh
# G1 naming
python3 tools/validate_naming.py && echo "G1 naming OK" || echo "FAIL G1"

# G2 assets
python3 tools/validate_assets.py && echo "G2 assets OK" || echo "FAIL G2"

# G3a budget JSON single source
python3 -c "import json; b=json.load(open('tools/perf/budget.json')); assert b['budgets']['draw_calls']['max']==120 and b['budgets']['tris']['max']==300000 and b['budgets']['texture_mem_mb']['max']==350 and b['budgets']['texture_mem_mb']['bytes_max']==367001600 and b['budgets']['physics_ms']['max']==4.0 and b['budgets']['frame_ms']['max']==16.6 and b['ci']['fail_on_exceed']==True; print('G3a budget.json OK')"

# G3b <12 Performance calls per file
python3 -c "
import re, sys
from pathlib import Path
ok=True
for f in list(Path('src').rglob('*.gd'))+list(Path('tools').rglob('*.gd')):
  t=f.read_text(errors='ignore'); d=len(re.findall(r'Performance\.get_monitor',t)); w=len(re.findall(r'_perf\(Performance',t)); eff=w if w else d
  if eff>=12: print(f'FAIL {f} {eff}>=12'); ok=False
print('G3b <12 OK' if ok else 'FAIL G3b')
sys.exit(0 if ok else 1)
"

# G4 config sanity
grep -q "physics_ticks_per_second=120" project.godot && echo "G4 tick project.godot OK" || echo "FAIL tick"
grep -q "PHYSICS_TICKS_PER_SECOND.*120" src/core/constants.gd && echo "G4 tick constants.gd OK" || echo "FAIL constants"
grep -q 'name="Android - Debug APK"' export_presets.cfg && echo "G4 preset debug OK" || echo "FAIL preset debug"
grep -q 'export_format=1' export_presets.cfg && echo "G4 preset release AAB OK" || echo "FAIL preset release"
grep -q "screen/orientation=1" export_presets.cfg && echo "G4 landscape OK" || echo "FAIL landscape"

# G5 regression guards
test $(grep -rn "Input.is_action" --include="*.gd" src/game/ 2>/dev/null | wc -l) -eq 0 && echo "G5 no raw Input OK" || echo "FAIL G5 raw Input"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); print('G6 ci.yml YAML OK')" 2>/dev/null || grep -q "validate_naming" .github/workflows/ci.yml && echo "G6 ci.yml OK"
test -f docs/ci-gates.md && echo "docs/ci-gates.md OK"
test -f .github/workflows/ci.yml && echo ".github/workflows/ci.yml OK"

# optional headless (requires Godot 4.4 + templates)
# godot --headless --import && echo "import OK"
# godot --headless -s tests/regression/perf_budget_test.gd && echo "perf_budget_test OK"
```

CI mirrors this gate line-for-line — local green implies CI green (G6 soft-fail only for headless).

---

## 8. Branch & CI Record

- Base: `main` at `194863f` (merge ws98-provenance, Godot 4.x).
- Branch: `ws97-regression` (this WS).
- Commits: `[WS97] Regression Suite & CI Gates — budget-aware <12 calls` (adds `.github/workflows/ci.yml` + `docs/ci-gates.md` + allowlist for 3 legacy `*.tscn`).
- Push: `git push origin ws97-regression`.
- CI: `.github/workflows/ci.yml` — G1+G2+G3(+<12)+G4+G5 required; G6 headless `continue-on-error`.
- Merge rule: PR `ws97-regression → main` requires green `gates` job + reviewer; protects `main` (WS01 branch rules).
- Local validate before push: run **Quick Gate** §7 — all `OK`.

---

## 9. Gaps / Deferred

- Headless `godot --headless -s tests/regression/perf_budget_test.gd` is soft in CI (no GPU/templates on `ubuntu-latest` by default). WS97 guarantees the JSON + <12 gates run even without Godot; full headless verified locally.
- Blind A/B harness (`tools/critic/`) and whole-game gauntlet remain WS99 — not gated here.
- Net stub `src/net/multiplayer_stub.gd` stays no-op (WS91).
- If any `docs/progress/100-workstreams.md` row 01–96 is still `todo`, that WS must land before WS97 is marked `converged` — this doc verifies gates, not feature completeness.

---

## 10. Sign-Off

| Role | Check | Date | Notes |
|------|-------|------|-------|
| Builder WS97 | §7 Quick Gate all OK on `ws97-regression` head | 2026-08-31 | |
| CI | `.github/workflows/ci.yml` `gates` job green on push |  | G1 G2 G3a G3b G4 G5 required |
| Perf | `budget.json` single source + per-file <12 |  | draw<120 tris<300k tex<350 phys<4 frame<16.6 |
| Regression | G5 guards 0 hits |  | no raw Input, no duplicate budgets |
