#!/usr/bin/env bash
# @trace order:1321-2ixp
#
# test-salvage-preserves-exec-bits.sh — order 1321-2ixp, items 2 and 3.
#
# WHAT IT PROTECTS. A Windows checkout cannot express the executable bit —
# core.filemode is false and a NEW file stages as 100644 whatever it is — so a
# fixture written there and handed over by scripts/salvage-dirty-worktree.sh
# reaches the relaying host with the bit already gone, and NOTHING downstream can
# tell "100644 on purpose" from "the substrate could not say otherwise".
#
# MEASURED: scripts/test-windows-host-lane-refusal.sh and its controls arrived
# through a salvage relay at 100644. Every ./build.sh --check passed for a day of
# Linux lands, and the v56.9.20.1 release gate refused
# litmus:windows-host-lane-refusal step 1 (`test -x`) on the first tier that runs
# it — 45 minutes in, on a defect a one-second decider could have named.
#
# WHY THE SALVAGE SIDE AND NOT THE RELAY SIDE. Restoring on the relay fixes the
# file in front of you and leaves the next Windows salvage carrying the same
# defect; ff82d1001 did exactly that for one file, which is why this row stayed
# open after it. Snapshot time is the last moment anyone knows the bit was meant.
#
# HERMETIC: every arm runs in a throwaway repo under $TMPDIR with its own
# GIT_INDEX_FILE. Nothing here reads or writes the tillandsias worktree, and no
# arm needs a Windows host — `git update-index --chmod=-x` reproduces exactly what
# a core.filemode=false checkout produces, which is how this row's controlled
# pairs were measured in the first place.
#
# GRAMMAR — one line:
#   ^(ok:salvage-exec-bits:[0-9]+/[0-9]+|violation:salvage-exec-bits:.*|refused:salvage-exec-bits:.*)$
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/build.sh" ] && [ -d "$ROOT/crates" ] || {
    echo "refused:salvage-exec-bits:root-is-not-a-tillandsias-checkout-$ROOT"
    exit 1
}
SALVAGE="$ROOT/scripts/salvage-dirty-worktree.sh"
[ -f "$SALVAGE" ] || {
    echo "refused:salvage-exec-bits:missing:$SALVAGE"
    exit 1
}

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/salvage-exec-bits.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT

# The restore block, extracted and run against a scaffold index. Running the
# whole salvage tool would need a remote to push to; what this row changed is the
# staging-to-tree step, and that is what the arms exercise. The block is sourced
# FROM THE TOOL rather than restated here — a copy would pass while the tool
# regressed, which is this milestone's own failure class.
extract_restore_block() {
    awk '/^restored=0$/,/^done$/' "$SALVAGE"
}

scaffold() {  # $1 = repo dir
    mkdir -p "$1" && cd "$1" || return 1
    git init -q . 2>/dev/null || return 1
    git config user.email s@t && git config user.name s
    printf 'seed\n' > seed.txt && git add seed.txt && git commit -qm seed
}

run_restore() {  # runs the tool's own block over paths_to_stage in $PWD
    local block; block="$(extract_restore_block)"
    [ -n "$block" ] || { echo "__NO_BLOCK__"; return 1; }
    paths_to_stage=()
    while IFS= read -r -d '' _e; do paths_to_stage+=("${_e:3}"); done \
        < <(git status --porcelain=v1 --untracked-files=all -z 2>/dev/null)
    for p in ${paths_to_stage[@]+"${paths_to_stage[@]}"}; do git add -A -- "$p" 2>/dev/null; done
    eval "$block"
}

# ── ARM 1: a shebang script staged at 100644 reaches the tree at 100755 ──────
( scaffold "$W/a" >/dev/null 2>&1 || exit 1
  printf '#!/usr/bin/env bash\necho hi\n' > scripts_test_x.sh
  git add -A -- scripts_test_x.sh 2>/dev/null
  git update-index --chmod=-x -- scripts_test_x.sh 2>/dev/null   # what a Windows checkout produces
  out="$(run_restore 2>&1)"
  mode="$(git ls-files -s -- scripts_test_x.sh | cut -d' ' -f1)"
  printf '%s\n%s\n' "$mode" "$out" > "$W/a.out"
) >/dev/null 2>&1
a_mode="$(head -1 "$W/a.out" 2>/dev/null)"
if [ "$a_mode" = "100755" ]; then
    ok "a shebang file staged at 100644 reaches the tree at 100755"
else
    bad "a shebang file staged at 100644 did NOT reach 100755 (got '${a_mode:-none}')"
fi
if grep -q '^note:exec-bit-restored:scripts_test_x.sh$' "$W/a.out" 2>/dev/null; then
    ok "and the salvage names each file it restored, so the change is not silent"
else
    bad "no note:exec-bit-restored line for the restored file: $(cat "$W/a.out" 2>/dev/null)"
fi

# ── ARM 2, THE NEGATIVE CONTROL: no shebang, no restore ─────────────────────
# Without this the tool could flip every 100644 file it stages and arm 1 would
# still pass. A salvage that silently makes data files executable inside a
# recovery copy is editing the worktree it exists to preserve.
( scaffold "$W/b" >/dev/null 2>&1 || exit 1
  printf 'key: value\n' > data.yaml
  git add -A -- data.yaml 2>/dev/null
  out="$(run_restore 2>&1)"
  mode="$(git ls-files -s -- data.yaml | cut -d' ' -f1)"
  printf '%s\n%s\n' "$mode" "$out" > "$W/b.out"
) >/dev/null 2>&1
b_mode="$(head -1 "$W/b.out" 2>/dev/null)"
if [ "$b_mode" = "100644" ] && ! grep -q '^note:exec-bit-restored:' "$W/b.out" 2>/dev/null; then
    ok "a file with no shebang keeps 100644 and is not named as restored"
else
    bad "a file with no shebang was altered (mode '${b_mode:-none}'): $(cat "$W/b.out" 2>/dev/null)"
fi

# ── ARM 3: the tool still carries the block these arms run ──────────────────
# The arms above eval a block EXTRACTED from the tool, so a tool that lost it
# would make them vacuous rather than red. This arm is what stops that: it fails
# when the extraction finds nothing, which is the only way arms 1 and 2 can
# silently stop testing the product.
if [ -n "$(extract_restore_block)" ] && grep -q 'note:exec-bit-restored' "$SALVAGE"; then
    ok "salvage-dirty-worktree.sh still carries the restore the arms above ran"
else
    bad "the restore block is gone from the tool — arms 1 and 2 above tested nothing"
fi

total=$((pass + fail))
if [ "$fail" -gt 0 ]; then
    echo "violation:salvage-exec-bits:$pass/$total"
    exit 1
fi
echo "ok:salvage-exec-bits:$pass/$total"
