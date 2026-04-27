#!/usr/bin/env bash
# check-cheatsheet-tiers.sh — tier-aware validation of cheatsheet frontmatter
# and pull-on-demand stub completeness.
#
# Usage:
#   scripts/check-cheatsheet-tiers.sh [--quiet]
#
# Validates (per cheatsheets-license-tiered spec):
#   1. tier:             must be one of: bundled | distro-packaged | pull-on-demand
#                        (or absent — validator infers from cheatsheets/license-allowlist.toml,
#                         safe default pull-on-demand)
#   2. tier-conditional fields:
#                        - tier=bundled        → image_baked_sha256 + structural_drift_fingerprint set at build (warn if pre-build)
#                        - tier=distro-packaged → package: present, local: present
#                        - tier=pull-on-demand → pull_recipe: see-section-pull-on-demand
#                                                AND ## Pull on Demand section present
#                                                AND license SPDX + license URL in ### Source block
#   3. CRDT override discipline:
#                        - if shadows_forge_default set → require all of override_reason +
#                          override_consequences + override_fallback (non-empty)
#
# Exits 0 only if all ERROR-level checks pass.
# Warnings are printed but do not cause a non-zero exit.
#
# Complement to scripts/check-cheatsheet-sources.sh (the legacy verbatim-source
# validator); they overlap on cheatsheet enumeration but apply orthogonal
# checks. Once the verbatim source layer is fully retired (Wave 4 tombstones),
# this script becomes the canonical validator.
#
# @trace spec:cheatsheets-license-tiered

set -euo pipefail

QUIET=0
if [[ "${1:-}" == "--quiet" ]]; then
    QUIET=1
elif [[ -n "${1:-}" ]]; then
    echo "usage: $0 [--quiet]" >&2
    exit 2
fi

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

CHEATSHEETS_DIR="${REPO_ROOT}/cheatsheets"

if [[ ! -d "${CHEATSHEETS_DIR}" ]]; then
    echo "ERROR: cheatsheets/ directory not found at ${CHEATSHEETS_DIR}" >&2
    exit 1
fi

# @trace spec:cheatsheets-license-tiered
QUIET="${QUIET}" python3 - "${CHEATSHEETS_DIR}" << 'PYEOF'
import os
import re
import sys
from pathlib import Path

cheatsheets_dir = Path(sys.argv[1])
quiet = os.environ.get("QUIET") == "1"

ALLOWED_TIERS = {"bundled", "distro-packaged", "pull-on-demand"}
SHADOW_FIELDS = ("override_reason", "override_consequences", "override_fallback")

errors = []
warnings = []
checked = 0
by_tier = {"bundled": 0, "distro-packaged": 0, "pull-on-demand": 0, "unset": 0}

def parse_frontmatter(text):
    """Return dict of frontmatter fields, or None if no frontmatter."""
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---\n", 4)
    if end < 0:
        return None
    block = text[4:end]
    fm = {}
    current_key = None
    current_multiline = []
    for line in block.split("\n"):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        # multi-line continuation (block scalar |)
        if current_key is not None and (line.startswith("  ") or line.startswith("\t")):
            current_multiline.append(line.strip())
            continue
        # flush previous multi-line
        if current_key is not None and current_multiline:
            fm[current_key] = "\n".join(current_multiline)
            current_multiline = []
        current_key = None
        m = re.match(r"^([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*(.*)$", line)
        if not m:
            continue
        k, v = m.group(1), m.group(2).strip()
        if v == "|":
            current_key = k
            continue
        fm[k] = v
    if current_key is not None and current_multiline:
        fm[current_key] = "\n".join(current_multiline)
    return fm, text[end + 5:]

def check_pull_on_demand_section(rel, body):
    """Validate stub-completeness for pull-on-demand cheatsheets."""
    if "## Pull on Demand" not in body:
        errors.append(f"{rel}: tier=pull-on-demand but missing ## Pull on Demand section")
        return
    pod = body[body.index("## Pull on Demand"):]
    if "### Source" not in pod:
        errors.append(f"{rel}: pull-on-demand stub missing ### Source sub-heading")
    if "### Materialize recipe" not in pod:
        errors.append(f"{rel}: pull-on-demand stub missing ### Materialize recipe sub-heading")
    if "### Generation guidelines" not in pod:
        errors.append(f"{rel}: pull-on-demand stub missing ### Generation guidelines sub-heading")
    # license url must appear in pod section (anywhere — typically Source block)
    has_license = "License:" in pod or "license:" in pod
    has_url = "https://" in pod
    if not (has_license and has_url):
        errors.append(f"{rel}: pull-on-demand stub must declare license + license URL in ## Pull on Demand")
    # recipe must be a non-empty fenced bash block
    if "```bash" not in pod and "```sh" not in pod:
        errors.append(f"{rel}: pull-on-demand recipe must include a fenced bash/sh code block")

for path in sorted(cheatsheets_dir.rglob("*.md")):
    if path.name in ("INDEX.md", "TEMPLATE.md"):
        continue
    rel = str(path.relative_to(cheatsheets_dir.parent))
    try:
        text = path.read_text(encoding="utf-8")
    except Exception as e:
        warnings.append(f"{rel}: read failed: {e}")
        continue
    parsed = parse_frontmatter(text)
    if parsed is None:
        warnings.append(f"{rel}: no YAML frontmatter")
        continue
    fm, body = parsed
    checked += 1

    tier = fm.get("tier", "").strip()
    if not tier:
        by_tier["unset"] += 1
        # validator infers from license-allowlist.toml at build time; warn here
        warnings.append(f"{rel}: tier not set — will be inferred from license-allowlist.toml (safe default: pull-on-demand)")
    elif tier not in ALLOWED_TIERS:
        errors.append(f"{rel}: invalid tier '{tier}' (must be one of {sorted(ALLOWED_TIERS)})")
        continue
    else:
        by_tier[tier] += 1

    # Tier-conditional checks
    if tier == "distro-packaged":
        if not fm.get("package"):
            errors.append(f"{rel}: tier=distro-packaged requires 'package:' field")
        if not fm.get("local"):
            errors.append(f"{rel}: tier=distro-packaged requires 'local:' field")
    elif tier == "pull-on-demand":
        recipe = fm.get("pull_recipe", "").strip()
        if recipe != "see-section-pull-on-demand":
            errors.append(f"{rel}: tier=pull-on-demand requires 'pull_recipe: see-section-pull-on-demand' (got '{recipe}')")
        check_pull_on_demand_section(rel, body)
    elif tier == "bundled":
        # image_baked_sha256 + structural_drift_fingerprint set at forge build
        # — pre-build cheatsheets won't have them, so warn-only here.
        if not fm.get("image_baked_sha256"):
            warnings.append(f"{rel}: tier=bundled has no image_baked_sha256 yet (set at forge build)")

    # CRDT override discipline
    if fm.get("shadows_forge_default", "").strip():
        for f in SHADOW_FIELDS:
            v = fm.get(f, "").strip()
            if not v:
                errors.append(f"{rel}: shadows_forge_default set but '{f}' is missing or empty")

# Report
if not quiet:
    print(f"check-cheatsheet-tiers: {checked} cheatsheets validated")
    print(f"  by tier: bundled={by_tier['bundled']}, distro-packaged={by_tier['distro-packaged']}, pull-on-demand={by_tier['pull-on-demand']}, unset={by_tier['unset']}")
    if warnings:
        print(f"\nWarnings ({len(warnings)}):")
        for w in warnings:
            print(f"  WARN: {w}")

if errors:
    print(f"\nErrors ({len(errors)}):")
    for e in errors:
        print(f"  ERROR: {e}")
    sys.exit(1)

if not quiet:
    print("OK: all tier checks passed.")
PYEOF
