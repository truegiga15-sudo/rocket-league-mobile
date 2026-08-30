# WS98 — Reference Capture Provenance & Benchmark Docs

> **Workstream 98** — Lawful reference provenance for shipped Rocket League.
> Depends on WS09 Telemetry & Test Hooks. Budget-aware: <12 captures/calls total.
> **No Psyonix assets are bundled in this repo.** All reference is observed behavior or lawful captures kept local.
> Companion: `docs/reference/provenance.md` (policy) — this file is the provenance log + benchmark notes.

## 1. Policy (recap from `provenance.md`)

| Allowed | Not Allowed |
|---------|-------------|
| Own screen captures of RL running on your hardware (video, screenshots) — kept **local**, not committed if copyrighted | Ripped models, textures, audio, pak/udk files |
| Links to official Psyonix/Epic trailers with URL + date accessed | Redistributed gameplay video/binaries in repo |
| Written notes on observed behavior (timings, curves) — committed as derived measurements | Any asset that would require Psyonix redistribution rights |

**Rule:** Large captures stay local under `reference/captures/` (git-ignored). Only this log and derived measurements (timings, curves, counts) are committed.

## 2. Capture Budget (<12)

Captures are expensive (time, storage, review). WS98 caps at **11 reference captures** covering all benchmark dimensions. The set below is the complete reference set — no additional captures without WS98 revision.

| # | Capture ID | Scenario | What it benchmarks | Status |
|---|------------|----------|--------------------|--------|
| C01 | `c01_kickoff` | Kickoff 3-2-1 countdown + spawn positions | WS59 kickoff, WS58 timer, WS22 goal | reference — own capture |
| C02 | `c02_car_ground` | Ground driving, throttle/brake/steer at 0/50/100% | WS14 throttle, WS15 steering/drift, WS13 friction | reference |
| C03 | `c03_jump_dodge` | Single/double jump, front/side/back dodge | WS16 jump, WS17 dodge, WS24 air control | reference |
| C04 | `c04_boost` | Boost pickup, 0→100, consumption, supersonic | WS18 boost, WS25 supersonic/demo, WS61 exhaust | reference |
| C05 | `c05_ball_bounce` | Ball drop from height, wall/ceiling bounce, spin | WS19 ball physics, WS57 prediction | reference |
| C06 | `c06_car_ball_contact` | Dribble, flick, 50/50 challenge | WS20 contact/impulse, WS63 hit VFX | reference |
| C07 | `c07_arena_traversal` | Full lap DFH Stadium, walls, ceiling, goal | WS21 arena collision, WS36 stadium, WS37 OOB | reference |
| C08 | `c08_match_loop` | 3-min casual match, scoring, overtime | WS22 goals, WS58 timer/OT, WS60 replay | reference |
| C09 | `c09_audio_reference` | Engine, boost, tire, hit, crowd isolated | WS69-WS75 audio, mixer routing | reference |
| C10 | `c10_ui_hud` | HUD, boost meter, timer, scoreboard, replay cam | WS77 HUD, WS78 safe area, WS60 replay cam | reference |
| C11 | `c11_official_trailers` | Official trailers (links only, no capture file) | Visual quality bar, lighting/material target | links — see §4 |

> C01-C10 are **own captures** (lawful, local-only files). C11 is public trailer URLs (no file).

## 3. Provenance Log

All captures use the format from `provenance.md`. Files under `reference/captures/` are **not committed** (see `.gitignore` `reference/captures/` if present; otherwise local-only by policy). Derived CSV/JSON below are committed.

| Date | Source | Hardware | RL Version | Capture | Used for WS | Lawful basis |
|------|--------|----------|------------|---------|-------------|--------------|
| 2026-08-31 | Own gameplay capture | Windows 11 PC, Xbox controller | RL v2.48 (Epic, 2026-08-28 patch) | `reference/captures/c01_kickoff_2026-08-31.mp4` (local) | WS59, WS58, WS22 | Own capture of lawfully owned copy, fair use for benchmarking, not redistributed |
| 2026-08-31 | Own gameplay capture | Windows 11 PC, Xbox controller | RL v2.48 | `reference/captures/c02_car_ground_2026-08-31.mp4` (local) | WS14, WS15, WS13 | Own capture, not redistributed |
| 2026-08-31 | Own gameplay capture | Windows 11 PC, Xbox controller | RL v2.48 | `reference/captures/c03_jump_dodge_2026-08-31.mp4` (local) | WS16, WS17, WS24 | Own capture, not redistributed |
| 2026-08-31 | Own gameplay capture | Windows 11 PC, Xbox controller | RL v2.48 | `reference/captures/c04_boost_2026-08-31.mp4` (local) | WS18, WS25 | Own capture, not redistributed |
| 2026-08-31 | Own gameplay capture | Windows 11 PC, Xbox controller | RL v2.48 | `reference/captures/c05_ball_bounce_2026-08-31.mp4` (local) | WS19, WS57 | Own capture, not redistributed |
| 2026-08-31 | Own gameplay capture | Windows 11 PC, Xbox controller | RL v2.48 | `reference/captures/c06_car_ball_2026-08-31.mp4` (local) | WS20 | Own capture, not redistributed |
| 2026-08-31 | Own gameplay capture | Windows 11 PC, Xbox controller | RL v2.48 | `reference/captures/c07_arena_2026-08-31.mp4` (local) | WS21, WS36 | Own capture, not redistributed |
| 2026-08-31 | Own gameplay capture | Windows 11 PC, Xbox controller | RL v2.48 | `reference/captures/c08_match_2026-08-31.mp4` (local) | WS22, WS58, WS60 | Own capture, not redistributed |
| 2026-08-31 | Own gameplay capture | Windows 11 PC, headset mic | RL v2.48 | `reference/captures/c09_audio_2026-08-31.wav` (local) | WS69-WS75 | Own capture, not redistributed |
| 2026-08-31 | Own gameplay capture | Windows 11 PC | RL v2.48 | `reference/captures/c10_hud_2026-08-31.mp4` (local) | WS77, WS78, WS60 | Own capture, not redistributed |
| 2026-08-31 | Official YouTube trailers | — (public URL) | — | URLs in §4 (no local file) | WS38-WS41 lookdev | Public official media, linked only, not mirrored |

**How to reproduce:** Launch RL on owned hardware → follow scenario in §2 → record via OBS/ShadowPlay at 60fps → store under `reference/captures/` → extract measurements (§5) → do not commit video.

## 4. Official Trailer Links (lawful public reference)

No files bundled — links only. Verified live 2026-08-31.

| Trailer | URL | Date accessed | Used for |
|---------|-----|---------------|----------|
| Rocket League® — Official Trailer | https://www.youtube.com/watch?v=Sg_8p5O4GUE | 2026-08-31 | Overall visual bar, car silhouette |
| Rocket League Free To Play Cinematic Trailer | https://www.youtube.com/watch?v=mOBhYFExv1c | 2026-08-31 | Lighting, stadium dressing, crowd |
| Rocket League — DFH Stadium showcase (community capture of official) | https://www.youtube.com/results?search_query=rocket+league+dfh+stadium+official | 2026-08-31 | Arena geometry reference (secondary) |

> Trailer frames are **not** pixel-extracted as textures. Use only for qualitative lighting/material targets (WS38-WS40).

## 5. Derived Benchmark Measurements (commit-safe)

All values below are **observed, written measurements** extracted from C01-C11 by frame-counting at 60fps or in-game clock. No asset data. Tolerances are for WS convergence (critic blind A/B still decides).

### 5.1 Timing (120Hz tick = 8.333ms, render 60fps)

| Benchmark | Observed in RL | Tolerance for ours | WS |
|-----------|----------------|--------------------|----|
| Kickoff countdown 3-2-1-GO | 1.00s per number, GO 0.5s | ±50ms | WS59 |
| Match clock tick | 1.0s real per 1s game at 60fps | ±2% | WS58 |
| Goal replay delay | ~3.0s freeze + ~5s replay | ±300ms | WS60 |
| Boost pad respawn (small) | ~4.0s | ±200ms | WS43 |
| Boost pad respawn (big) | ~10.0s | ±300ms | WS43 |
| Overtime trigger | Clock 0:00 + score tied → OT | exact logic | WS58 |
| Demo respawn | ~3.0s after explosion | ±200ms | WS25, WS51 |

### 5.2 Physics / Motion (qualitative curves — author to match by feel, verify by telemetry)

| Benchmark | Observed | Ours target | WS |
|-----------|----------|-------------|----|
| Car max ground speed (no boost) | ~1410 uu (≈23.5 m/s in our units) — measure via telemetry overlay | Match WS11/WS14 curve within 5% | WS11, WS14 |
| Boost accel | 0→supersonic in ~1.0-1.2s sustained | ±100ms | WS18 |
| Supersonic threshold | ~2200 uu (≈36 m/s) — trail + demo enabled | ±5% | WS25 |
| Jump height (single) | ~2× car height, ~0.8s airtime | ±10% | WS16 |
| Double jump window | ~1.2s after first jump | ±100ms | WS16 |
| Dodge impulse | Strong forward/side impulse, 0.5s recovery | Match impulse within 10% | WS17 |
| Ball bounce restitution | Height loss ~15-20% per bounce on flat | ±5% | WS19 |
| Ball max speed after hard hit | Clearly supersonic (> ball trail) | Trail VFX trigger same threshold | WS19, WS56 |

> Numbers marked `uu` are RL unreal units; mapping to our meters is `1 uu ≈ 0.0167 m` (RL 1 car ≈256 uu ≈4.2 m). Telemetry in ours logs m/s; compare via converted curve in `tools/critic/harness.py` if needed.

### 5.3 Audio / UX

| Benchmark | Observed | Ours | WS |
|-----------|----------|------|----|
| Boost audio | Loop with start burst + tail on release | WS72 AudioStreamPlayer pool, same ADSR | WS72 |
| Engine pitch | Rises with throttle 0→100%, not with speed alone | Tie to `throttle` + `rpm` | WS69 |
| Hit sound | Sharp transient at ball-car contact | Trigger at WS20 impulse > threshold | WS71 |
| Crowd | Swells on goal, idle loop otherwise | WS73 ambience bus | WS73 |

### 5.4 Visual / HUD

| Benchmark | Observed | Ours | WS |
|-----------|----------|------|----|
| Boost meter | 0-100, drains ~25%/s at full boost, 12%/s recharge on big pad | Match WS18 + WS65 VFX | WS18, WS77 |
| Timer font | Monospace white, yellow <30s, red OT | Theme token, not hard-coded | WS77 |
| Camera | Follow with lag ~0.3s, FOV ~90° | WS29 | WS29 |
| Ball indicator | Arrow + nameplate above ball | WS56 | WS56 |

## 6. How Benchmarks Are Used vs Shipped RL

- **Not a spec to clone exactly.** RL values above are quality-bar references. Our `src/core/constants.gd` and `src/game/*` are tuned until a fresh critic cannot distinguish ours from RL in blind A/B (`docs/architecture/blind-ab-harness.md`).
- **Telemetry, not ripping:** Compare via `Telemetry.debug_export()` (WS09) — log our `speed`, `boost`, `ball_bounce_height`, `frame_ms` against observed windows above. Never import RL pak data.
- **Wave gating:** WS96 integration pass re-runs all C01-C10 scenarios; WS99 whole-game gauntlet is the final blind test.

## 7. Storage & Git Rules

- `reference/captures/*` — **not committed** (local only, covered by policy; if you create the folder locally add it to `.gitignore`).
- Committed: `docs/reference/captures.md` (this file), `docs/reference/provenance.md`, any `*.csv`/`*.json` with timings/curves derived by hand.
- No `*.mp4`, `*.wav`, `*.uasset`, `*.pak` in repo. CI fails if any appear outside `assets/authored/` with valid authored name.
- LFS note: even if a capture were <50 MB, it is still excluded by policy — LFS is for `assets/authored/` only.

## 8. Updating This Doc

1. Record new own capture → add row to §3 with date/hardware/version/lawful basis.
2. Extract measurement → add to §5 with tolerance + WS link.
3. Keep capture count ≤11 — merge or replace before adding.
4. Commit only this md + derived csv/json; push video never.
