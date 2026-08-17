#!/usr/bin/env bash
# @trace spec:cheatsheet-tooling, spec:default-image
# stage-image-cheatsheets.sh — single source of truth for materialising the
# forge build context's DERIVED cheatsheet tree (images/default/cheatsheets/).
#
# WHY THIS EXISTS (order 448)
# ---------------------------
# images/default/cheatsheets/ is not authored: it is a straight copy of the
# canonical host tree cheatsheets/, regenerated into the podman build context
# immediately before every forge image build.
#
# IT IS ALSO TRACKED BY GIT, ON PURPOSE (decision 2026-08-16,
# plan/issues/cheatsheet-derived-tree-tracking-decision-2026-08-16.md).
# The `.gitignore` entry keeps ad-hoc local regenerations from dirtying the
# tree; it does NOT mean the tree is untracked, and gitignore is inert against
# the 230 files that were already tracked when the rule landed. The tracked
# copy is a BUILD INPUT: crates/tillandsias-headless/build.rs embeds images/
# recursively into the binary, ./build.sh never stages cheatsheets, and the
# end-user lane builds the forge image from the EMBEDDED snapshot, where no
# authored tree and no staging script exist. Untracking this tree therefore
# ships an image whose `COPY cheatsheets/` has nothing to copy — it would
# break `tillandsias --init` for every curl-installed user, and turn
# every_containerfile_copy_source_exists_in_embedded_assets red on a fresh
# clone. (images/default/skills/ IS safely untracked because build.rs:199
# explicitly excludes it from asset collection. Cheatsheets have no such
# exclusion. That asymmetry is the whole story.)
#
# NEVER hand-edit the derived tree: the next --stage reverts it. On 2026-07-21
# commit 79b3e82da edited ONLY the derived copy of
# runtime/codex-agent-entrypoints.md, so the tracked tree carried
# `last_verified: 2026-07-21` while its own authored source still said
# 2026-05-20 — attribution flowing backwards for three days until the next
# build silently reverted it. A check
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

# V6 — the TRACKED derived tree must equal the authored tree.
#
# This is the check the previous advisory got backwards. It used to tell the
# reader to run `git rm -r --cached images/default/cheatsheets`, which would
# break end-user installs (see the header). The real hazard is the opposite:
# V3 above repairs the WORKING tree and leaves the INDEX stale, silently, so a
# tracked copy that is missing files sails through every gate while the binary
# embeds it and the shipped INDEX.md advertises cheatsheets the image does not
# contain — an expert that can cite what it cannot open.
#
# Compares git's INDEX view of both trees — path + blob hash. The index, not
# HEAD: a gate that reads HEAD can only report a divergence one commit AFTER
# it lands, whereas this one refuses while the fix is still `git add`. It is
# also independent of working-tree staging state, so a fresh clone and a
# freshly-staged workstation give the same verdict.
_tree_manifest() {
    git -C "$ROOT" ls-files -s -- "$1" |
        awk -F'\t' -v p="$1/" '{ split($1, m, " "); path=$2; sub("^"p, "", path); print m[2], path }' |
        sort
}
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tracked_count="$(git -C "$ROOT" ls-files -- 'images/default/cheatsheets' | wc -l | tr -d ' ')"
    if [[ "$tracked_count" -eq 0 ]]; then
        _drift "derived-tree-untracked" \
            "images/default/cheatsheets/ has no tracked files; the binary embeds this tree and the end-user image build has no other source" \
            "restore it (git add -f images/default/cheatsheets) — see plan/issues/cheatsheet-derived-tree-tracking-decision-2026-08-16.md"
    fi
    if ! diff <(_tree_manifest cheatsheets) <(_tree_manifest images/default/cheatsheets) \
        >"$PROBE_ROOT/index.diff" 2>&1; then
        _drift "derived-tree-index-stale" \
            "the TRACKED derived tree does not equal the authored tree ($(grep -c '^[<>]' "$PROBE_ROOT/index.diff") differing entr(y|ies)):
$(head -10 "$PROBE_ROOT/index.diff")" \
            "scripts/stage-image-cheatsheets.sh --stage && git add -f images/default/cheatsheets"
    fi
fi

printf 'cheatsheet-image-sync:%s files=%s (%s)\n' \
    "$verdict" \
    "$(find "$STAGE_DIR" -type f | wc -l | tr -d ' ')" \
    "$stage_detail"
