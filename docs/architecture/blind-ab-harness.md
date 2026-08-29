# Blind A/B Critic Harness
## Rule: critic never knows which is ours while judging

### Procedure per workstream
1. Builder produces artifact + `critic_input/`:
   - video (30-60s gameplay, same scenario as RL capture)
   - input replay JSON (so critic can verify feel, not just look)
   - perf trace if relevant (frame time, memory)

2. Harness shuffles: `A = shuffle(ours, rl)`, records secret mapping in `critic_secrets/<ws>.json` (not visible to critic)

3. Fresh-context critic receives:
   - prompt: "You are judging WORKSTREAM <N>: <name>. Two artifacts A and B, one is authentic Rocket League, one is our game. Identities hidden. Compare actual experience on relevant dimensions: <list from spec>. Choose A or B, and state SINGLE largest gap as actionable sentence grounded in observed difference. No scores, no vague praise."

4. Critic returns: `choice: A|B`, `largest_gap: "..."`, `confidence: high|medium|low`

5. If critic picks RL -> builder fixes largest gap, rebuild, re-shuffle, re-judge. If picks ours -> WS converged.

### Whole-game Gauntlet (WS99)
Same shuffle, but artifact is full 3-minute match played as player (touch input, camera, audio, VFX together). Critic tests as player.

### Storage
- `tools/critic/harness.py` does shuffling and secret mapping
- `docs/progress/critic_findings/<ws>.md` logs each round
