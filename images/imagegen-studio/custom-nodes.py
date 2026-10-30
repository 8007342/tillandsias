#!/usr/bin/env python3
# @trace order:1921-7aa5 (spec: openspec/changes/local-image-generation, not yet archived)
"""Install and verify the studio's custom nodes from custom-nodes.toml.

  install <manifest> <custom_nodes>    clone each node at its pinned commit,
                                       install its hashed lock, stamp the commit
  verify  <manifest> <custom_nodes> <root>
                                       fail on a node dir not in the manifest,
                                       a node at a different commit, a missing
                                       node, or any ComfyUI-Manager path under root

Exit 0 and one ok: line on success; exit 1 and one violation: line per finding.
"""
import os
import subprocess
import sys
import tomllib

STAMP = ".tillandsias-node-commit"
# Dirs ComfyUI itself may create next to the nodes; never nodes.
IGNORED = {"__pycache__"}


def load(manifest):
    with open(manifest, "rb") as f:
        nodes = tomllib.load(f).get("node", [])
    for n in nodes:
        for key in ("name", "repo", "commit", "license", "lock"):
            if not n.get(key):
                sys.exit(f"violation:custom-nodes:manifest-entry-missing-{key}:{n.get('name', '?')}")
        if len(n["commit"]) != 40:
            sys.exit(f"violation:custom-nodes:commit-not-a-full-sha:{n['name']}")
    return nodes


def run(*argv):
    subprocess.run(argv, check=True)


def install(manifest, custom_nodes):
    base = os.path.dirname(os.path.abspath(manifest))
    for n in load(manifest):
        dest = os.path.join(custom_nodes, n["name"])
        run("git", "clone", "--filter=blob:none", "--quiet", n["repo"], dest)
        run("git", "-C", dest, "checkout", "--quiet", "--detach", n["commit"])
        head = subprocess.run(["git", "-C", dest, "rev-parse", "HEAD"],
                              check=True, capture_output=True, text=True).stdout.strip()
        if head != n["commit"]:
            sys.exit(f"violation:custom-nodes:clone-not-at-pinned-commit:{n['name']}:{head}")
        run("rm", "-rf", os.path.join(dest, ".git"))
        with open(os.path.join(dest, STAMP), "w") as f:
            f.write(n["commit"] + "\n")
        run(sys.executable, "-m", "pip", "install", "--no-cache-dir", "--require-hashes",
            "--no-deps", "-r", os.path.join(base, n["lock"]))
    run(sys.executable, "-m", "pip", "check")
    print("ok:custom-nodes:installed")


def manager_paths(root):
    for dirpath, dirnames, filenames in os.walk(root):
        # Stay on this filesystem: /proc and friends are not the image.
        dirnames[:] = [d for d in dirnames
                       if not os.path.ismount(os.path.join(dirpath, d))]
        for name in dirnames + filenames:
            if "comfyui-manager" in name.lower() or "comfyui_manager" in name.lower():
                yield os.path.join(dirpath, name)


def verify(manifest, custom_nodes, root):
    want = {n["name"]: n["commit"] for n in load(manifest)}
    findings = []
    have = sorted(d for d in os.listdir(custom_nodes)
                  if os.path.isdir(os.path.join(custom_nodes, d)) and d not in IGNORED)
    for d in have:
        if d not in want:
            findings.append(f"violation:custom-nodes:not-in-manifest:{d}")
            continue
        try:
            with open(os.path.join(custom_nodes, d, STAMP)) as f:
                got = f.read().strip()
        except OSError:
            got = "unstamped"
        if got != want[d]:
            findings.append(f"violation:custom-nodes:wrong-commit:{d}:{got}")
    for d in sorted(set(want) - set(have)):
        findings.append(f"violation:custom-nodes:missing:{d}")
    for p in manager_paths(root):
        findings.append(f"violation:custom-nodes:comfyui-manager-path:{p}")
    for line in findings:
        print(line)
    if findings:
        return 1
    print(f"ok:custom-nodes:{len(have)}-pinned")
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "install":
        install(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 5 and sys.argv[1] == "verify":
        sys.exit(verify(sys.argv[2], sys.argv[3], sys.argv[4]))
    else:
        sys.exit(__doc__)
