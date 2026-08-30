#!/usr/bin/env python3
import argparse, re, struct, subprocess, sys
from pathlib import Path
LFS_THRESHOLD_BYTES = 1_048_576
LFS_REVIEW_THRESHOLD_BYTES = 52_428_800
LFS_EXTENSIONS = {".glb", ".gltf", ".fbx", ".png", ".wav", ".ogg", ".mp3", ".mp4", ".webp", ".jpg", ".jpeg"}
RE_ASSET_AUTHORED = re.compile(r"^[a-z0-9]+(?:_[a-z0-9]+){2,}_v\d{2}\.[a-z0-9]+$")
POWER_OF_TWO_SIZES = {2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096}
AUTHORED_DIR_PART = "assets/authored"
IGNORE_DIRS = {".git", ".godot", ".import", "__pycache__", ".venv", "venv", ".hermes", "export"}
IGNORE_FILES = {".DS_Store", "thumbs.db"}
RE_PROCEDURAL = re.compile(r"(OpenSimplexNoise|FastNoiseLite|NoiseTexture|procedural\s*generat|generate_noise|Perlin|Simplex)", re.IGNORECASE)
def is_power_of_two(n): return n>0 and (n & (n-1))==0
def parse_png_dimensions(path):
    try:
        with path.open("rb") as f:
            if f.read(8)!=b"\x89PNG\r\n\x1a\n": return None
            while True:
                h=f.read(8)
                if len(h)<8: return None
                l=struct.unpack(">I",h[:4])[0]; ct=h[4:8]
                if ct==b"IHDR":
                    d=f.read(13)
                    if len(d)<13: return None
                    w=struct.unpack(">I",d[0:4])[0]; hh=struct.unpack(">I",d[4:8])[0]; return (w,hh)
                else: f.seek(l+4,1)
                if ct==b"IEND": return None
    except: return None
def parse_jpeg_dimensions(path):
    try:
        d=path.read_bytes()
        if len(d)<4 or d[0:2]!=b"\xff\xd8": return None
        i=2
        while i < len(d)-9:
            if d[i]!=0xFF: i+=1; continue
            while i<len(d) and d[i]==0xFF: i+=1
            if i>=len(d): break
            m=d[i]; i+=1
            if m==0xD9: break
            if 0xD0 <= m <= 0xD7 or m==0x01: continue
            if i+1>=len(d): break
            l=struct.unpack(">H",d[i:i+2])[0]
            if l<2: break
            if m in (0xC0,0xC1,0xC2,0xC3,0xC5,0xC6,0xC7,0xC9,0xCA,0xCB,0xCD,0xCE,0xCF):
                if i+7 < len(d):
                    h=struct.unpack(">H",d[i+3:i+5])[0]; w=struct.unpack(">H",d[i+5:i+7])[0]; return (w,h)
            i+=l
        return None
    except: return None
def get_image_dimensions(path):
    s=path.suffix.lower()
    if s==".png": return parse_png_dimensions(path)
    if s in (".jpg",".jpeg"): return parse_jpeg_dimensions(path)
    try:
        from PIL import Image
        with Image.open(path) as im: return (im.width, im.height)
    except: return None
def load_lfs_patterns(repo_root):
    p=[]
    g=repo_root / ".gitattributes"
    if g.exists():
        for line in g.read_text().splitlines():
            line=line.strip()
            if not line or line.startswith("#"): continue
            if "filter=lfs" in line: p.append(line.split()[0])
    return p
def is_lfs_tracked_by_attributes(rel, pats):
    import fnmatch
    for pat in pats:
        if "**" in pat:
            pre=pat.split("**")[0].rstrip("/")
            if rel.startswith(pre): return True
        elif fnmatch.fnmatch(rel, pat) or fnmatch.fnmatch(Path(rel).name, pat): return True
        if pat.startswith("*.") and rel.endswith(pat[1:]): return True
    return False
def check_lfs_via_git(repo_root, rel):
    try:
        out=subprocess.check_output(["git","check-attr","filter","--",rel],cwd=repo_root,text=True,stderr=subprocess.DEVNULL)
        return "lfs" in out
    except: return None
def check_authored_naming(path, repo_root):
    rel=path.relative_to(repo_root).as_posix() if path.is_absolute() else path.as_posix()
    if AUTHORED_DIR_PART not in rel: return None
    if path.name in ("README.md",".keep",".gitkeep"): return None
    if path.is_dir(): return None
    if not RE_ASSET_AUTHORED.match(path.name): return f"authored asset '{rel}' name '{path.name}' does not match category_name_variant_author_v01.ext (e.g. car_octane_body_a_v01.glb)"
    return None
def check_power_of_two(path):
    e=[]
    if path.suffix.lower() not in (".png",".jpg",".jpeg",".webp"): return e
    dims=get_image_dimensions(path)
    if dims is None: return e
    w,h=dims
    if not is_power_of_two(w): e.append(f"texture '{path.name}' width {w} is not power-of-two (allowed: sorted {sorted(POWER_OF_TWO_SIZES)})")
    if not is_power_of_two(h): e.append(f"texture '{path.name}' height {h} is not power-of-two (allowed: sorted {sorted(POWER_OF_TWO_SIZES)})")
    if w>4096 or h>4096: e.append(f"texture '{path.name}' {w}x{h} exceeds max 4096x4096")
    return e
def check_procedural_markers(path):
    w=[]
    if path.suffix.lower() not in (".gd",".cs",".json",".tres",".tscn",".gdshader",".shader"): return w
    try: t=path.read_text(encoding="utf-8",errors="ignore")
    except: return w
    for m in RE_PROCEDURAL.finditer(t): w.append(f"file '{path.as_posix()}' contains procedural marker '{m.group(0)}' — authored assets only (§16)"); break
    return w
def collect_files(repo_root, check_path):
    root=check_path if check_path else repo_root
    files=[]
    if root.is_file(): return [root]
    for p in root.rglob("*"):
        if not p.is_file(): continue
        try: rel=p.relative_to(repo_root)
        except: rel=p
        if any(part in IGNORE_DIRS for part in rel.parts): continue
        if p.name in IGNORE_FILES: continue
        files.append(p)
    return files
def main():
    parser=argparse.ArgumentParser(description="Validate WS03 Asset Import Pipeline")
    parser.add_argument("--check",type=str,default=None); parser.add_argument("--strict",action="store_true"); parser.add_argument("--fix",action="store_true")
    args=parser.parse_args()
    sp=Path(__file__).resolve(); repo_root=sp.parent.parent
    if not (repo_root / "project.godot").exists(): repo_root=Path.cwd()
    lfs_patterns=load_lfs_patterns(repo_root)
    check_path=None
    if args.check:
        check_path=(repo_root / args.check).resolve()
        if not check_path.exists(): print(f"error: --check path does not exist: {args.check}",file=sys.stderr); sys.exit(2)
    files=collect_files(repo_root, check_path)
    errors=[]; warnings=[]
    for f in sorted(files):
        try: rel=f.relative_to(repo_root).as_posix()
        except: rel=f.as_posix()
        if f.name in (".keep",".gitkeep"): continue
        if f.name=="README.md" and AUTHORED_DIR_PART not in rel: continue
        msg=check_authored_naming(f, repo_root)
        if msg: errors.append(msg)
        if f.suffix.lower() in LFS_EXTENSIONS:
            try: size=f.stat().st_size
            except: size=0
            if size > LFS_REVIEW_THRESHOLD_BYTES: errors.append(f"asset '{rel}' is {size} bytes ({size/1048576:.1f} MiB) >50MB — requires LFS review before commit (§14)")
            elif size > LFS_THRESHOLD_BYTES:
                tracked_by_attr=is_lfs_tracked_by_attributes(rel,lfs_patterns); git_tracked=check_lfs_via_git(repo_root,rel); is_tracked=tracked_by_attr or (git_tracked is True)
                if not is_tracked:
                    if git_tracked is False: errors.append(f"asset '{rel}' is {size} bytes ({size/1048576:.1f} MiB) >1MB but not LFS-tracked (git check-attr filter != lfs). Add pattern to .gitattributes")
                    elif not tracked_by_attr: errors.append(f"asset '{rel}' is {size} bytes ({size/1048576:.1f} MiB) >1MB but no LFS pattern in .gitattributes matches it (patterns: {lfs_patterns})")
        if AUTHORED_DIR_PART in rel or f.suffix.lower() in (".png",".jpg",".jpeg",".webp"):
            for e in check_power_of_two(f): errors.append(f"{rel}: {e}")
        if AUTHORED_DIR_PART in rel and f.suffix.lower() in (".glb",".gltf",".png",".jpg",".jpeg",".webp",".wav",".ogg",".mp3"):
            imp=Path(str(f)+".import")
            if not imp.exists(): warnings.append(f"authored asset '{rel}' has no .import preset — import settings not yet authored (deterministic import required)")
        warnings.extend(check_procedural_markers(f))
    if warnings:
        print(f"\nWarnings ({len(warnings)}):")
        for w in warnings: print(f"  WARN: {w}")
    if errors:
        print(f"\nErrors ({len(errors)}):")
        for e in errors: print(f"  ERROR: {e}")
        if args.fix:
            print("\nFix guidance:")
            print("  - Rename assets to category_name_variant_author_v01.ext  e.g. car_octane_body_a_v01.glb")
            print("    Regex: ^[a-z0-9]+(_[a-z0-9]+){2,}_v\\d{2}\\.[a-z0-9]+$")
            print("  - Textures must be power-of-two (e.g. 256, 512, 1024, 2048) and <=4096")
            print("  - Files >1MB with .glb/.png/.wav/.ogg/.mp3/.mp4 must be LFS-tracked. Add to .gitattributes or run: git lfs track \"*.ext\"")
            print("  - Files >50MB require review — split or compress.")
            print("  - Re-export meshes triangulated, scale 1.0, no ngons.")
            print("  - Generate .import presets in Godot and commit them (do not .gitignore *.import).")
            print("  - Remove procedural noise (OpenSimplexNoise/FastNoiseLite) — use authored textures.")
        print(f"\nValidation FAILED: {len(errors)} error(s), {len(warnings)} warning(s)"); sys.exit(1)
    else:
        if warnings and args.strict: print(f"\nStrict mode: {len(warnings)} warning(s) treated as errors — FAILED"); sys.exit(1)
        if warnings: print(f"\nValidation passed with {len(warnings)} warning(s).")
        else: print("Validation passed — asset pipeline conforms to WS03 spec.")
        print(f"LFS patterns loaded: {lfs_patterns}"); sys.exit(0)
if __name__=="__main__": main()
