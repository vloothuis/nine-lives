#!/usr/bin/env python3
"""Writes the licence notices of every crate built into nl-engine, from the crates' own licence files.

Usage: scripts/engine-notices.py <output file>. Run after Engine/vendor.sh.
"""
import json, os, subprocess, sys

engine = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Engine")
meta = json.loads(subprocess.check_output(
    ["cargo", "metadata", "--format-version", "1", "--locked", "--filter-platform", "aarch64-apple-darwin",
     "--manifest-path", os.path.join(engine, "Cargo.toml")]))
# Only crates that end up in the binary: follow normal dependencies from nl-engine.
nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
root = meta["resolve"]["root"]
keep, todo = set(), [root]
while todo:
    i = todo.pop()
    if i in keep:
        continue
    keep.add(i)
    for d in nodes[i]["deps"]:
        if any(k["kind"] is None for k in d["dep_kinds"]):
            todo.append(d["pkg"])
keep.discard(root)

mit_text = None
for p in meta["packages"]:
    f = os.path.join(os.path.dirname(p["manifest_path"]), "LICENSE-MIT")
    if p["name"] == "serde" and os.path.isfile(f):
        mit_text = open(f).read().strip()

out = ["Nine Lives includes nl-engine, which is built from the following open source crates.", ""]
missing = []
for p in sorted((p for p in meta["packages"] if p["id"] in keep), key=lambda p: (p["name"], p["version"])):
    d = os.path.dirname(p["manifest_path"])
    files = sorted(f for f in os.listdir(d)
                   if f.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE", "UNLICENSE")))
    out += ["=" * 78, f'{p["name"]} {p["version"]}  ({p.get("license") or "see below"})', "=" * 78]
    if not files:
        # Every such crate allows MIT, so its notice is the MIT text with its authors.
        if "MIT" not in (p.get("license") or "") or mit_text is None:
            sys.exit(f'no licence file and no MIT option for {p["name"]}')
        authors = ", ".join(p.get("authors") or [f'the {p["name"]} authors'])
        out += ["", f"Used under the MIT licence. Copyright (c) {authors}.", "", mit_text, ""]
        missing.append(p["name"])
    for f in files:
        path = os.path.join(d, f)
        if os.path.isfile(path):
            out += ["", open(path, encoding="utf-8", errors="replace").read().strip(), ""]
open(sys.argv[1], "w").write("\n".join(out) + "\n")
print(f"{len(keep)} crates, {len(missing)} given the MIT text", file=sys.stderr)
