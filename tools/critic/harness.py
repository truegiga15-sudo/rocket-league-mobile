#!/usr/bin/env python3
"""
Blind A/B Critic Harness — Rocket League Mobile vs Shipped Rocket League
Shuffles ours vs RL artifact, hides identity, records secret mapping.
"""
import json, random, shutil, hashlib, argparse
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
SECRETS_DIR = ROOT / "tools" / "critic" / "critic_secrets"
PACKAGE_DIR = ROOT / "tools" / "critic" / "critic_package"
def prepare(ws: str, seed: str = None):
    ws = ws.lower()
    inp = ROOT / "tools" / "critic" / "critic_input" / ws
    ours = inp / "ours.mp4"
    rl = inp / "rl.mp4"
    if not ours.exists() or not rl.exists():
        raise FileNotFoundError(f"missing {ours} or {rl} — builder must provide both")
    h = hashlib.sha256(f"{ws}:{seed or random.randint(0,1<<30)}".encode()).hexdigest()
    ours_is_A = int(h,16) % 2 == 0
    mapping = {"ws": ws, "A": "ours" if ours_is_A else "rl", "B": "rl" if ours_is_A else "ours", "hash": h[:8]}
    SECRETS_DIR.mkdir(parents=True, exist_ok=True)
    (SECRETS_DIR / f"{ws}.json").write_text(json.dumps(mapping, indent=2))
    pkg = PACKAGE_DIR / ws
    pkg.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ours if ours_is_A else rl, pkg / "A.mp4")
    shutil.copyfile(rl if ours_is_A else ours, pkg / "B.mp4")
    for f in inp.glob("*.json"):
        shutil.copyfile(f, pkg / f.name)
    prompt = f"""You are judging {ws} — blind A/B.\nTwo artifacts A and B: one is authentic Rocket League, one is our game. Identities hidden.\nCompare actual experience on relevant dimensions (visual, physics, feel, controls, animation, timing, VFX, audio, camera, UI, responsiveness, performance, mobile ergonomics, polish).\nChoose A or B — which is higher quality?\nState SINGLE largest gap as one actionable sentence grounded in observed difference.\nNo scores, no vague praise.\nReturn JSON: {{\"choice\":\"A\"|\"B\", \"largest_gap\":\"...\", \"confidence\":\"high\"|\"medium\"|\"low\"}}"""
    (pkg / "prompt.txt").write_text(prompt)
    print(f"[{ws}] A={mapping['A']} B={mapping['B']} hash={h[:8]} -> {pkg}")
    return mapping
def reveal(ws: str):
    p = SECRETS_DIR / f"{ws.lower()}.json"
    print(p.read_text() if p.exists() else f"no secret for {ws}")
def judge_result(ws: str, choice: str):
    ws = ws.lower()
    mapping = json.loads((SECRETS_DIR / f"{ws}.json").read_text())
    pick = choice.strip().upper()
    actual = mapping[pick]
    print(f"[{ws}] critic picked {pick} ({actual}) -> ours_won={actual=='ours'} mapping={mapping}")
    return actual=="ours"
if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["prepare","reveal","judge"])
    ap.add_argument("ws", help="e.g. ws11")
    ap.add_argument("--choice")
    ap.add_argument("--seed")
    a = ap.parse_args()
    ws = a.ws.lower()
    if not ws.startswith("ws"): ws = "ws"+ws
    if a.cmd=="prepare": prepare(ws,a.seed)
    elif a.cmd=="reveal": reveal(ws)
    elif a.cmd=="judge":
        if not a.choice: ap.error("--choice required")
        judge_result(ws,a.choice)
