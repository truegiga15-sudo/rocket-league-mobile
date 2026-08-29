# Critic Package Layout
- `tools/critic/critic_input/<ws>/` — builder drops ours.mp4 + rl.mp4 + replay.json (same scenario)
- `tools/critic/critic_secrets/<ws>.json` — hidden mapping, never shown to critic
- `tools/critic/critic_package/<ws>/` — shuffled A.mp4, B.mp4, prompt.txt given to fresh critic
- `docs/progress/critic_findings/<ws>.md` — log each round

Usage:
python tools/critic/harness.py prepare ws11
python tools/critic/harness.py judge ws11 --choice A
python tools/critic/harness.py reveal ws11
