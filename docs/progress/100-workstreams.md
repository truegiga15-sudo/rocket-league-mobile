# Rocket League Mobile — 100 Workstreams (Live Tracker)
Source of truth: this file + `docs/progress/workstreams.json`
Rule: exactly 100 distinct, non-overlapping, independently judgeable workstreams. Builder + fresh critic per WS. Sequential waves by dependencies, not 200 at once.

Legend: State = todo | in_progress | in_review | converged | blocked
Gap = critic's single largest gap (actionable). Blind A/B = critic picks OUR vs RL (shuffled).

| # | Workstream | Builder | Critic | Dependencies | State | Gap | Blind A/B | Tests | Regression | Integration | Commits/PRs | Converged |
|---|------------|---------|--------|--------------|-------|-----|-----------|-------|------------|-------------|-------------|-----------|
| 01 | Repo, Branch/Merge Rules, CI | unassigned | unassigned | — | todo | — | — | — | — | — | — | no |
| 02 | Project Structure & Scene Ownership | unassigned | unassigned | 01 | todo | — | — | — | — | — | — | no |
| 03 | Asset Import Pipeline & Naming | unassigned | unassigned | 01,02 | todo | — | — | — | — | — | — | no |
| 04 | Coordinate, Units, Scale | unassigned | unassigned | 01 | todo | — | — | — | — | — | — | no |
| 05 | Time Step & Determinism | unassigned | unassigned | 04 | todo | — | — | — | — | — | — | no |
| 06 | Input Abstraction Layer | unassigned | unassigned | 02 | todo | — | — | — | — | — | — | no |
| 07 | Physics Conventions & Collision Layers | unassigned | unassigned | 04,05 | todo | — | — | — | — | — | — | no |
| 08 | Save/Config Interfaces | unassigned | unassigned | 02 | todo | — | — | — | — | — | — | no |
| 09 | Telemetry & Test Hooks | unassigned | unassigned | 02 | todo | — | — | — | — | — | — | no |
| 10 | Performance Budgets & Profiling Harness | unassigned | unassigned | 02,09 | todo | — | — | — | — | — | — | no |
| 11 | Car Chassis Physics & Mass Distribution | unassigned | unassigned | 04,05,07 | todo | — | — | — | — | — | — | no |
| 12 | Suspension & Wheel Raycasts | unassigned | unassigned | 11 | todo | — | — | — | — | — | — | no |
| 13 | Tire Friction Model | unassigned | unassigned | 12 | todo | — | — | — | — | — | — | no |
| 14 | Engine Power Curve & Throttle | unassigned | unassigned | 11 | todo | — | — | — | — | — | — | no |
| 15 | Steering, Drift & Handbrake | unassigned | unassigned | 12,13 | todo | — | — | — | — | — | — | no |
| 16 | Jump / Double Jump | unassigned | unassigned | 11 | todo | — | — | — | — | — | — | no |
| 17 | Dodge / Flip Mechanics | unassigned | unassigned | 16 | todo | — | — | — | — | — | — | no |
| 18 | Boost System (accel, consumption, pads) | unassigned | unassigned | 11,14 | todo | — | — | — | — | — | — | no |
| 19 | Ball Physics (mass, bounce, spin) | unassigned | unassigned | 07 | todo | — | — | — | — | — | — | no |
| 20 | Ball-Car Contact & Impulse Transfer | unassigned | unassigned | 11,19 | todo | — | — | — | — | — | — | no |
| 21 | Arena Collision Geometry & Curved Walls | unassigned | unassigned | 07 | todo | — | — | — | — | — | — | no |
| 22 | Goal Detection & Scoring Logic | unassigned | unassigned | 21 | todo | — | — | — | — | — | — | no |
| 23 | World Physics Integration & Fixed Tick | unassigned | unassigned | 05,07 | todo | — | — | — | — | — | — | no |
| 24 | Air Control & Aerial Mechanics | unassigned | unassigned | 11,16,18 | todo | — | — | — | — | — | — | no |
| 25 | Supersonic & Demo Mechanics | unassigned | unassigned | 11,18 | todo | — | — | — | — | — | — | no |
| 26 | Touch Joystick (movement) | unassigned | unassigned | 06 | todo | — | — | — | — | — | — | no |
| 27 | Camera Joystick & Orbit | unassigned | unassigned | 06 | todo | — | — | — | — | — | — | no |
| 28 | Boost/Jump/Drift Button Cluster & Haptics | unassigned | unassigned | 06 | todo | — | — | — | — | — | — | no |
| 29 | Camera Follow Algorithm | unassigned | unassigned | 06 | todo | — | — | — | — | — | — | no |
| 30 | Camera Shake & Impact Feedback | unassigned | unassigned | 29 | todo | — | — | — | — | — | — | no |
| 31 | Ball Cam vs Car Cam Toggle | unassigned | unassigned | 29 | todo | — | — | — | — | — | — | no |
| 32 | Touch Responsiveness & Dead Zones | unassigned | unassigned | 26,27,28 | todo | — | — | — | — | — | — | no |
| 33 | Orientation Change Handling | unassigned | unassigned | 06,29 | todo | — | — | — | — | — | — | no |
| 34 | Input Latency Measurement | unassigned | unassigned | 06,09 | todo | — | — | — | — | — | — | no |
| 35 | Gamepad Fallback & Mapping | unassigned | unassigned | 06 | todo | — | — | — | — | — | — | no |
| 36 | DFH Stadium Geometry (authored) | unassigned | unassigned | 04,21 | todo | — | — | — | — | — | — | no |
| 37 | Stadium Collision Mesh & OOB | unassigned | unassigned | 36 | todo | — | — | — | — | — | — | no |
| 38 | Lighting Rig (baked + probes) | unassigned | unassigned | 36 | todo | — | — | — | — | — | — | no |
| 39 | Materials & PBR Shaders | unassigned | unassigned | 38 | todo | — | — | — | — | — | — | no |
| 40 | Skybox & Atmosphere | unassigned | unassigned | 38 | todo | — | — | — | — | — | — | no |
| 41 | Crowd & Stadium Dressing | unassigned | unassigned | 36 | todo | — | — | — | — | — | — | no |
| 42 | Goal Geometry, Net & Posts | unassigned | unassigned | 36 | todo | — | — | — | — | — | — | no |
| 43 | Boost Pad Placement & Visuals | unassigned | unassigned | 21,36 | todo | — | — | — | — | — | — | no |
| 44 | Field Decals & Markings | unassigned | unassigned | 36 | todo | — | — | — | — | — | — | no |
| 45 | Environment LOD & Culling | unassigned | unassigned | 36,10 | todo | — | — | — | — | — | — | no |
| 46 | Car Mesh: Octane | unassigned | unassigned | 03,04 | todo | — | — | — | — | — | — | no |
| 47 | Car Mesh: Dominus | unassigned | unassigned | 46 | todo | — | — | — | — | — | — | no |
| 48 | Car Shader & Paint (team colors) | unassigned | unassigned | 39,46 | todo | — | — | — | — | — | — | no |
| 49 | Wheels, Trails & Attachments | unassigned | unassigned | 46 | todo | — | — | — | — | — | — | no |
| 50 | Decals & Texture Authoring | unassigned | unassigned | 48 | todo | — | — | — | — | — | — | no |
| 51 | Car Explosion Model | unassigned | unassigned | 25 | todo | — | — | — | — | — | — | no |
| 52 | Garage / Customization UI | unassigned | unassigned | 46,48 | todo | — | — | — | — | — | — | no |
| 53 | Hitbox Presets & Debug Vis | unassigned | unassigned | 11,46 | todo | — | — | — | — | — | — | no |
| 54 | Car Audio Attachment | unassigned | unassigned | 46 | todo | — | — | — | — | — | — | no |
| 55 | Car Selection & Loadout Persistence | unassigned | unassigned | 08,52 | todo | — | — | — | — | — | — | no |
| 56 | Ball Mesh, Texture, Trail | unassigned | unassigned | 19 | todo | — | — | — | — | — | — | no |
| 57 | Ball Prediction Line | unassigned | unassigned | 19 | todo | — | — | — | — | — | — | no |
| 58 | Match Timer & Overtime Rules | unassigned | unassigned | 22 | todo | — | — | — | — | — | — | no |
| 59 | Kickoff Logic & Spawn Positions | unassigned | unassigned | 22,58 | todo | — | — | — | — | — | — | no |
| 60 | Replays & Goal Replay Camera | unassigned | unassigned | 22,29 | todo | — | — | — | — | — | — | no |
| 61 | Boost Exhaust & Particles | unassigned | unassigned | 18,46 | todo | — | — | — | — | — | — | no |
| 62 | Tire Smoke & Skid Marks | unassigned | unassigned | 13 | todo | — | — | — | — | — | — | no |
| 63 | Ball Hit Impact VFX | unassigned | unassigned | 20 | todo | — | — | — | — | — | — | no |
| 64 | Explosion & Demo VFX | unassigned | unassigned | 51 | todo | — | — | — | — | — | — | no |
| 65 | Boost Pad Recharge VFX | unassigned | unassigned | 43 | todo | — | — | — | — | — | — | no |
| 66 | Wall/Ceiling Impact Sparks | unassigned | unassigned | 21 | todo | — | — | — | — | — | — | no |
| 67 | Supersonic Trail VFX | unassigned | unassigned | 25 | todo | — | — | — | — | — | — | no |
| 68 | Environmental Particles (dust) | unassigned | unassigned | 36 | todo | — | — | — | — | — | — | no |
| 69 | Engine & Acceleration Audio | unassigned | unassigned | 14 | todo | — | — | — | — | — | — | no |
| 70 | Tire Skid & Impact Audio | unassigned | unassigned | 13 | todo | — | — | — | — | — | — | no |
| 71 | Ball Hit & Bounce Audio | unassigned | unassigned | 19,20 | todo | — | — | — | — | — | — | no |
| 72 | Boost Audio (start/loop/end) | unassigned | unassigned | 18 | todo | — | — | — | — | — | — | no |
| 73 | Crowd & Stadium Ambience | unassigned | unassigned | 36 | todo | — | — | — | — | — | — | no |
| 74 | Goal Horn & Countdown Audio | unassigned | unassigned | 22,58 | todo | — | — | — | — | — | — | no |
| 75 | UI & Menu Audio, Mixer Routing | unassigned | unassigned | 08 | todo | — | — | — | — | — | — | no |
| 76 | Main Menu & Navigation Flow | unassigned | unassigned | 08 | todo | — | — | — | — | — | — | no |
| 77 | HUD: Scoreboard, Timer, Boost Meter | unassigned | unassigned | 22,58,18 | todo | — | — | — | — | — | — | no |
| 78 | Touch HUD Layout & Safe Area | unassigned | unassigned | 26,28,77 | todo | — | — | — | — | — | — | no |
| 79 | Pause, Settings, Controls Remap UI | unassigned | unassigned | 08,76 | todo | — | — | — | — | — | — | no |
| 80 | Post-Match Scoreboard & XP | unassigned | unassigned | 22,58 | todo | — | — | — | — | — | — | no |
| 81 | Loading Screens & Transitions | unassigned | unassigned | 76 | todo | — | — | — | — | — | — | no |
| 82 | Onboarding Tutorial & Hints | unassigned | unassigned | 26,28,77 | todo | — | — | — | — | — | — | no |
| 83 | Settings Persistence & Profiles | unassigned | unassigned | 08 | todo | — | — | — | — | — | — | no |
| 84 | Localization Foundation | unassigned | unassigned | 76 | todo | — | — | — | — | — | — | no |
| 85 | Accessibility & Colorblind Options | unassigned | unassigned | 78 | todo | — | — | — | — | — | — | no |
| 86 | Frame Pacing & 60fps Lock | unassigned | unassigned | 10 | todo | — | — | — | — | — | — | no |
| 87 | Memory Budget & Low-Memory Handling | unassigned | unassigned | 10 | todo | — | — | — | — | — | — | no |
| 88 | Suspend/Resume & App Lifecycle | unassigned | unassigned | 10 | todo | — | — | — | — | — | — | no |
| 89 | Offline Bot AI (basic) | unassigned | unassigned | 11,19,22 | todo | — | — | — | — | — | — | no |
| 90 | Training / Free Play Mode | unassigned | unassigned | 22,58 | todo | — | — | — | — | — | — | no |
| 91 | Local Multiplayer Stub / Net Prep | unassigned | unassigned | 05,23 | todo | — | — | — | — | — | — | no |
| 92 | Analytics & Crash Hooks | unassigned | unassigned | 09 | todo | — | — | — | — | — | — | no |
| 93 | Build Pipeline (APK/AAB Export) | unassigned | unassigned | 01,10 | todo | — | — | — | — | — | — | no |
| 94 | Icon, Splash, Permissions & Manifest | unassigned | unassigned | 93 | todo | — | — | — | — | — | — | no |
| 95 | Device Testing Matrix & Edge Cases | unassigned | unassigned | 86,87,88 | todo | — | — | — | — | — | — | no |
| 96 | Full Integration Pass | unassigned | unassigned | 01-95 | todo | — | — | — | — | — | — | no |
| 97 | Regression Suite & CI Gates | unassigned | unassigned | 96 | todo | — | — | — | — | — | — | no |
| 98 | Reference Capture Provenance & Benchmark Docs | unassigned | unassigned | 09 | todo | — | — | — | — | — | — | no |
| 99 | Final Blind Whole-Game Gauntlet Harness | unassigned | unassigned | 96,97 | todo | — | — | — | — | — | — | no |
| 100 | Release Artifact & Store Listing Prep | unassigned | unassigned | 93,96 | todo | — | — | — | — | — | — | no |

JSON version: `workstreams.json` (same data, machine-readable).
