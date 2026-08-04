#!/usr/bin/env bash
# @trace spec:cheatsheet-tooling, spec:default-image
# stage-image-cheatsheets.sh — single source of truth for materialising the
# forge build context's DERIVED cheatsheet tree (images/default/cheatsheets/).
#
# WHY THIS EXISTS (order 448)
# ---------------------------
# images/default/cheatsheets/ is not authored: it is a straight copy of the
# canonical host tree cheatsheets/, regenerated into the podman build context
# immediately before every forge image build, and listed in .gitignore. A check
# that merely runs `diff -qr cheatsheets images/default/cheatsheets` therefore
# asserts "somebody ran a forge build on this host after the last cheatsheet
# edit" — which is FALSE on a fresh clone, on CI, and on any workstation that
# edited a cheatsheet since its last build. litmus:cheatsheet-host-image-sync
# burned three preflights that way. A check that cannot pass on a fresh clone
# is not a check.
#
# The fix is REGENERATE-then-assert, not skip: the tree is cheap (a few hundred
# small files), purely derived, and regenerating it is exactly what the build
# does. Skipping when the tree is absent would make the check vacuous in the
# most common case (fresh clone / CI), i.e. it would protect nothing where it
# matters most. Regenerating keeps the check meaningful everywhere because what
# it then asserts is the STAGING MECHANISM, not host build history:
#
#   V1 the canonical tree exists and is non-empty
#   V2 a fresh stage reproduces the canonical tree byte-for-byte
#      (a filtering/partial-copy regression in the stage step fails here)
#   V3 the on-disk build-context tree equals canonical after staging
#   V4 scripts/build-image.sh delegates staging to THIS script, so the tree the
#      litmus verified is the tree the image actually receives
#   V5 the Containerfile still COPYs the staged directory into the image
#
# Modes:
#   --stage    (default) regenerate the build-context tree from canonical
#   --verify   regenerate if absent/stale, then assert V1..V5
#
# Falsifiable verdict lines (stdout, exactly one terminal verdict):
#   cheatsheet-image-stage:ok            --stage completed
#   cheatsheet-image-sync:ok             staging already matched canonical
#   cheatsheet-image-sync:regenerated    staging was absent/stale, rebuilt
#   cheatsheet-image-sync:drift <reason> genuine defect, exit 1
#   cheatsheet-image-sync:advisory ...   non-fatal hygiene note

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CANONICAL_DIR="$ROOT/cheatsheets"
STAGE_DIR="$ROOT/images/default/cheatsheets"
CONTAINERFILE="$ROOT/images/default/Containerfile"
BUILD_IMAGE_SH="$ROOT/scripts/build-image.sh"

MODE="stage"

usage() {
    cat <<'EOF'
Usage: scripts/stage-image-cheatsheets.sh [--stage|--verify]

  --stage    Regenerate images/default/cheatsheets/ from cheatsheets/ (default).
             Idempotent; the destination is removed and rewritten.
  --verify   Regenerate if absent/stale, then assert the staging invariants.
             Exits non-zero only on a genuine defect, never on host state.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) MODE="stage"; shift ;;
        --verify) MODE="verify"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

_drift() {
    # $1 = machine-readable reason, $2 = human detail
    printf 'cheatsheet-image-sync:drift %s\n' "$1"
    printf 'FAIL: %s\n' "$2" >&2
    printf 'Remedy: %s\n' "${3:-inspect the staging path above}" >&2
    exit 1
}

# THE staging operation. build-image.sh calls this script so that there is
# exactly one implementation of "what the forge image receives".
_stage_into() {
    local dest="$1"
    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    cp -rp "$CANONICAL_DIR" "$dest"
}

# V1 — canonical tree must exist and carry content. This is the only genuinely
# unrecoverable state: nothing derived can be produced without a source.
if [[ ! -d "$CANONICAL_DIR" ]]; then
    _drift "canonical-missing" \
        "canonical cheatsheet tree not found: $CANONICAL_DIR" \
        "restore cheatsheets/ from git"
fi
canonical_md_count="$(find "$CANONICAL_DIR" -type f -name '*.md' | wc -l | tr -d ' ')"
if [[ "$canonical_md_count" -lt 1 ]]; then
    _drift "canonical-empty" \
        "canonical cheatsheet tree has no .md files: $CANONICAL_DIR" \
        "restore cheatsheets/ from git"
fi

if [[ "$MODE" == "stage" ]]; then
    _stage_into "$STAGE_DIR"
    printf 'cheatsheet-image-stage:ok files=%s dest=%s\n' \
        "$(find "$STAGE_DIR" -type f | wc -l | tr -d ' ')" \
        "${STAGE_DIR#"$ROOT"/}"
    exit 0
fi

# ── --verify ────────────────────────────────────────────────────────────────
PROBE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cheatsheet-stage-probe.XXXXXX")"
trap 'rm -rf "$PROBE_ROOT"' EXIT

# V2 — a fresh stage must reproduce canonical exactly. Canonical is the
# independent reference, so a stage step that filters, flattens or drops files
# fails here even though it would be self-consistent.
_stage_into "$PROBE_ROOT/cheatsheets"
if ! diff -qr "$CANONICAL_DIR" "$PROBE_ROOT/cheatsheets" >"$PROBE_ROOT/probe.diff" 2>&1; then
    _drift "stage-does-not-reproduce-canonical" \
        "a fresh stage differs from the canonical tree:
$(cat "$PROBE_ROOT/probe.diff")" \
        "fix _stage_into() in scripts/stage-image-cheatsheets.sh"
fi

# V3 — the build-context tree must equal canonical. Absent or stale is HOST
# STATE, not a defect: regenerate and say so.
verdict="ok"
stage_detail="build-context tree already matched canonical"
if [[ ! -d "$STAGE_DIR" ]]; then
    verdict="regenerated"
    stage_detail="build-context tree was absent (fresh clone / clean checkout)"
elif ! diff -qr "$CANONICAL_DIR" "$STAGE_DIR" >"$PROBE_ROOT/stage.diff" 2>&1; then
    verdict="regenerated"
    stage_detail="build-context tree was stale ($(wc -l <"$PROBE_ROOT/stage.diff" | tr -d ' ') difference(s)) and has been rebuilt"
fi

if [[ "$verdict" == "regenerated" ]]; then
    _stage_into "$STAGE_DIR"
    if ! diff -qr "$CANONICAL_DIR" "$STAGE_DIR" >"$PROBE_ROOT/rewrite.diff" 2>&1; then
        _drift "stage-write-failed" \
            "regeneration did not produce a matching tree:
$(cat "$PROBE_ROOT/rewrite.diff")" \
            "check permissions/disk under images/default/"
    fi
fi

# V4 — the build must use THIS staging path, otherwise everything above
# verified a tree the image never sees.
if [[ ! -f "$BUILD_IMAGE_SH" ]]; then
    _drift "build-image-missing" \
        "scripts/build-image.sh not found" \
        "restore scripts/build-image.sh from git"
fi
if ! grep -Fq 'stage-image-cheatsheets.sh' "$BUILD_IMAGE_SH"; then
    _drift "build-image-not-delegating" \
        "scripts/build-image.sh no longer stages cheatsheets through stage-image-cheatsheets.sh; the verified tree is not the tree the image receives" \
        "restore the stage-image-cheatsheets.sh --stage call in build-image.sh"
fi

# V5 — the image must still bake the staged directory.
if ! grep -Fq 'COPY cheatsheets/ /opt/cheatsheets-image/' "$CONTAINERFILE"; then
    _drift "containerfile-copy-missing" \
        "images/default/Containerfile no longer COPYs cheatsheets/ into /opt/cheatsheets-image/" \
        "restore the COPY cheatsheets/ /opt/cheatsheets-image/ line"
fi

# Hygiene advisory (non-fatal): the derived tree is .gitignore'd but some files
# were force-added in the past, so git still tracks a second, drifting copy of
# every cheatsheet. Regeneration makes that copy harmless at build time, but it
# should be dropped from the index (git rm -r --cached images/default/cheatsheets).
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tracked_count="$(git -C "$ROOT" ls-files -- 'images/default/cheatsheets' | wc -l | tr -d ' ')"
    if [[ "$tracked_count" -gt 0 ]]; then
        printf 'cheatsheet-image-sync:advisory tracked-derived-tree=%s (gitignored but force-added; drop with: git rm -r --cached images/default/cheatsheets)\n' \
            "$tracked_count"
    fi
fi

printf 'cheatsheet-image-sync:%s files=%s (%s)\n' \
    "$verdict" \
    "$(find "$STAGE_DIR" -type f | wc -l | tr -d ' ')" \
    "$stage_detail"
