#!/usr/bin/env python3
"""
tools/validate_naming.py — WS02/WSo3 Naming Convention Validator

Enforces docs/architecture/00-conventions.md §2 and scene-ownership.md §5:

- files: snake_case   (e.g. tire_friction.gd, ball_physics.gd)
- scenes: PascalCase  (e.g. CarChassis.tscn, Stadium.tscn)
- nodes: Type_Name    (e.g. Car_Octane) — tscn inspection, warning level
- assets: category_name_variant_author_v01.ext  (e.g. car_octane_body_a_v01.glb)
- branches: wsNN-short-name (e.g. ws11-car-chassis)

Usage:
  python3 tools/validate_naming.py
  python3 tools/validate_naming.py --check src/game/car
  python3 tools/validate_naming.py --strict   # node naming = error instead of warn
  python3 tools/validate_naming.py --fix      # prints guidance (no auto-rename)

Exit codes: 0 pass, 1 violations, 2 usage error
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Regexes
# ---------------------------------------------------------------------------
RE_SNAKE_FILE = re.compile(r"^[a-z0-9]+(?:_[a-z0-9]+)*\.[a-z0-9]+$")
RE_SNAKE_BASENAME = re.compile(r"^[a-z0-9]+(?:_[a-z0-9]+)*$")
# Scene files: PascalCase.tscn  (allow numbers, e.g. StadiumV2.tscn)
RE_PASCAL_TSCN = re.compile(r"^[A-Z][A-Za-z0-9]*\.tscn$")
# Asset authored: category_name_variant_author_v01.ext  (must end with _vNN.ext)
RE_ASSET_AUTHORED = re.compile(
    r"^[a-z0-9]+(?:_[a-z0-9]+){2,}_v\d{2}\.[a-z0-9]+$"
)
# Branch: wsNN-short-name  (NN 1-100, short name kebab-case)
RE_BRANCH = re.compile(r"^ws\d{1,3}-[a-z0-9]+(?:-[a-z0-9]+)*$")
# Node name in tscn: [node name="Type_Name" ...]  -> Type_Name
RE_TSCN_NODE = re.compile(r'\[node\s+name="([^"]+)"')

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
# File extensions that must be snake_case (code, resources, audio, etc.)
SNAKE_EXTS = {
    ".gd", ".cs", ".json", ".cfg", ".tres", ".res", ".tscn", ".scn",
    ".glb", ".gltf", ".png", ".jpg", ".jpeg", ".webp", ".svg",
    ".ogg", ".wav", ".mp3", ".ttf", ".otf", ".import", ".remap",
    ".md", ".py", ".sh", ".gdshader", ".shader",
}

# Scene files are PascalCase, not snake — exempt from snake check
SCENE_EXT = ".tscn"

# Asset directory that uses authored naming
AUTHORED_DIR_PART = "assets/authored"

# Paths to ignore entirely (git internals, imports, caches)
IGNORE_DIRS = {".git", ".godot", ".import", "__pycache__", ".venv", "venv", ".hermes"}
IGNORE_FILES = {".DS_Store", "thumbs.db"}

# Allowlist: files that are known exceptions (project.godot is Pascal? no, keep snake)
ALLOWLIST_FILES = {
    "project.godot",
    "export_presets.cfg",
    ".gitattributes",
    ".gitignore",
    ".gitkeep",
    ".keep",
    "README.md",  # top-level docs allow Pascal-ish README
}

# WS03: scene files that are legacy test fixtures allowed as snake_case (enforced as warning, not error)
ALLOWLIST_TSCN_SNAKE = {
    "coordinate_test.tscn",  # WS04 test fixture — lower snake is intentional for test parity with _test.gd
    "ball.tscn",  # WS19 ball physics — spec mandates snake_case per task; allowed as exception (ownership table)
}

# README.md is allowed to be Pascal-like inside any dir (common convention)
ALLOW_README = True

# ---------------------------------------------------------------------------
def is_ignored(path: Path, repo_root: Path) -> bool:
    parts = path.relative_to(repo_root).parts if path.is_absolute() else path.parts
    for p in parts:
        if p in IGNORE_DIRS:
            return True
    if path.name in IGNORE_FILES:
        return True
    return False

def check_snake_file(path: Path, repo_root: Path) -> str | None:
    """Return error message if snake check fails, else None."""
    name = path.name
    # Allowlist exact match
    if name in ALLOWLIST_FILES:
        return None
    if ALLOW_README and name == "README.md":
        return None
    # Scene files have separate Pascal check
    if path.suffix == SCENE_EXT:
        return None  # handled in check_pascal_scene
    # Only check extensions we care about; skip unknown exts silently
    if path.suffix.lower() not in SNAKE_EXTS:
        # Still enforce snake for unknown? Be permissive — only check if suffix looks like code/asset
        # For safety, enforce snake on any file with extension
        pass
    # Strip extension, check basename is snake + extension lower
    # Use full name check
    # Special case: .keep files
    if name == ".keep":
        return None
    # Check full name is snake_case.ext
    # Allow dotfiles like .gitignore already handled
    if name.startswith("."):
        return None
    # For files like budget.json — must be snake
    if not RE_SNAKE_FILE.match(name):
        # Provide more specific hint
        stem = path.stem
        if not RE_SNAKE_BASENAME.match(stem):
            return f"file '{name}' stem '{stem}' is not snake_case (expected ^[a-z0-9]+(_[a-z0-9]+)*$)"
        # Extension must be lowercase
        if path.suffix != path.suffix.lower():
            return f"file '{name}' extension not lowercase"
        return f"file '{name}' does not match snake_case.ext pattern"
    return None

def check_pascal_scene(path: Path) -> str | None:
    if path.suffix != SCENE_EXT:
        return None
    name = path.name
    if name in ALLOWLIST_TSCN_SNAKE:
        return None
    if not RE_PASCAL_TSCN.match(name):
        return f"scene '{name}' is not PascalCase (expected ^[A-Z][A-Za-z0-9]*\\.tscn$, e.g. CarChassis.tscn)"
    return None

def check_authored_asset(path: Path, repo_root: Path) -> str | None:
    rel = path.relative_to(repo_root).as_posix() if path.is_absolute() else path.as_posix()
    if AUTHORED_DIR_PART not in rel:
        return None
    # Only check files directly under assets/authored/** (not READMEs)
    if path.name == "README.md" or path.name == ".keep" or path.name == ".gitkeep":
        return None
    # Directories under authored are per-WS, allow snake dir names but not strict
    if path.is_dir():
        return None
    name = path.name
    if not RE_ASSET_AUTHORED.match(name):
        return (
            f"authored asset '{rel}' name '{name}' does not match "
            f"category_name_variant_author_v01.ext (e.g. car_octane_body_a_v01.glb)"
        )
    return None

def check_tscn_nodes(path: Path) -> list[str]:
    """Inspect .tscn for node naming Type_Name. Returns list of warnings."""
    warnings = []
    if path.suffix != SCENE_EXT:
        return warnings
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return warnings
    for m in RE_TSCN_NODE.finditer(text):
        node_name = m.group(1)
        # Allow single-word Passthrough? Convention says Type_Name (underscore, Pascal both sides)
        # We warn if node name is not Type_Name or PascalCase single? Be strict: must contain underscore and both parts start uppercase
        if "_" not in node_name:
            # Check if it's a common Godot default like "Node" or "Control" — warn less?
            # Still warn as info
            warnings.append(
                f"scene '{path.name}' node '{node_name}' missing Type_Name underscore (expected e.g. Car_Octane)"
            )
        else:
            parts = node_name.split("_")
            for part in parts:
                if not part or not part[0].isupper():
                    warnings.append(
                        f"scene '{path.name}' node '{node_name}' part '{part}' should be PascalCase"
                    )
                    break
    return warnings

def check_branch_name(branch: str) -> str | None:
    branch = branch.strip()
    if not branch:
        return "could not determine branch name (detached HEAD?)"
    # Allow main, integrate/wave-N, and wsNN-*
    if branch in {"main", "master"}:
        return None
    if branch.startswith("integrate/wave-"):
        return None
    if not RE_BRANCH.match(branch):
        return (
            f"branch '{branch}' does not match wsNN-short-name "
            f"(e.g. ws02-project-structure, ws11-car-chassis) or integrate/wave-N"
        )
    return None

def get_current_branch(repo_root: Path) -> str:
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=repo_root,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return out
    except Exception:
        return ""

def collect_files(repo_root: Path, check_path: Path | None) -> list[Path]:
    root = check_path if check_path else repo_root
    files = []
    if root.is_file():
        files = [root]
    else:
        for p in root.rglob("*"):
            if p.is_file():
                # Skip ignored dirs via string check on relative
                try:
                    rel = p.relative_to(repo_root)
                except ValueError:
                    rel = p
                if any(part in IGNORE_DIRS for part in rel.parts):
                    continue
                if p.name in IGNORE_FILES:
                    continue
                files.append(p)
    return files

def main():
    parser = argparse.ArgumentParser(description="Validate naming conventions (WS02)")
    parser.add_argument("--check", type=str, default=None, help="Path to check (relative to repo root)")
    parser.add_argument("--strict", action="store_true", help="Treat tscn node warnings as errors")
    parser.add_argument("--fix", action="store_true", help="Print fix guidance (no auto-rename)")
    args = parser.parse_args()

    script_path = Path(__file__).resolve()
    # repo root is parent of tools/
    repo_root = script_path.parent.parent
    if not (repo_root / "project.godot").exists():
        # fallback: cwd
        repo_root = Path.cwd()

    check_path = None
    if args.check:
        check_path = (repo_root / args.check).resolve()
        if not check_path.exists():
            print(f"error: --check path does not exist: {args.check}", file=sys.stderr)
            sys.exit(2)

    files = collect_files(repo_root, check_path)
    errors = []
    warnings = []

    for f in sorted(files):
        # Relative for messages
        try:
            rel = f.relative_to(repo_root).as_posix()
        except ValueError:
            rel = f.as_posix()

        # Skip allowlisted top files
        if f.name in ALLOWLIST_FILES and len(Path(rel).parts) == 1:
            continue
        if f.name == "README.md" and ALLOW_README:
            continue
        if f.name in (".keep", ".gitkeep"):
            continue

        # 1. snake_case for general files (tolerant, scene handled separately)
        # Only enforce for source-adjacent files; skip e.g. .py in tools? Still enforce but tools are snake already
        if f.suffix == SCENE_EXT:
            msg = check_pascal_scene(f)
            if msg:
                errors.append(f"{rel}: {msg}")
            # Also check authored asset if under authored (unlikely for tscn)
            msg2 = check_authored_asset(f, repo_root)
            if msg2:
                errors.append(f"{rel}: {msg2}")
            # Node naming
            node_warns = check_tscn_nodes(f)
            for w in node_warns:
                if args.strict:
                    errors.append(f"{rel}: {w}")
                else:
                    warnings.append(f"{rel}: {w}")
        else:
            # General file snake check
            # Skip assets/authored strict? That has its own regex
            if AUTHORED_DIR_PART in rel:
                msg = check_authored_asset(f, repo_root)
                if msg:
                    errors.append(f"{rel}: {msg}")
                continue
            # Outside authored, enforce snake
            # Only enforce for known relevant extensions to reduce noise
            relevant = f.suffix.lower() in SNAKE_EXTS or f.suffix == ""
            # Docs: allow README, but other md should be snake? e.g. blind-ab-harness.md uses kebab — actually our docs use kebab with dashes
            # Conventions say files snake_case, but docs use kebab? Be tolerant: allow kebab for docs
            if "docs/" in rel:
                # docs files like 00-conventions.md, blind-ab-harness.md — allow kebab
                continue
            if relevant or f.suffix:
                msg = check_snake_file(f, repo_root)
                if msg:
                    errors.append(f"{rel}: {msg}")

    # Branch name check (always, unless --check is a single file?)
    branch = get_current_branch(repo_root)
    branch_err = check_branch_name(branch)
    if branch_err:
        errors.append(f"branch: {branch_err}")

    # Report
    if warnings:
        print(f"\nWarnings ({len(warnings)}):")
        for w in warnings:
            print(f"  WARN: {w}")

    if errors:
        print(f"\nErrors ({len(errors)}):")
        for e in errors:
            print(f"  ERROR: {e}")
        if args.fix:
            print("\nFix guidance:")
            print("  - Rename files to snake_case: e.g. tireFriction.gd -> tire_friction.gd")
            print("  - Rename scenes to PascalCase: e.g. car_chassis.tscn -> CarChassis.tscn")
            print("  - Rename assets to category_name_variant_author_v01.ext: e.g. Car.glb -> car_octane_body_a_v01.glb")
            print("  - Rename branch to wsNN-short-name: e.g. git branch -m ws02-project-structure")
            print("  - Nodes inside .tscn should be Type_Name: e.g. Car_Octane, Ball_Main")
        print(f"\nValidation FAILED: {len(errors)} error(s), {len(warnings)} warning(s)")
        sys.exit(1)
    else:
        if warnings:
            print(f"\nValidation passed with {len(warnings)} warning(s).")
        else:
            print("Validation passed — all naming conventions satisfied.")
        # Also print branch ok
        if branch and not branch_err:
            print(f"Branch '{branch}' naming OK.")
        sys.exit(0)

if __name__ == "__main__":
    main()
