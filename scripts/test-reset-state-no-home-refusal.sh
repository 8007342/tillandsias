#!/usr/bin/env bash
# ORDER 1315-d4qd — a destructive path has no silent default.
#
# With HOME unset, image_root resolves to /tmp/Library/Application Support/
# tillandsias. For a READER that is a defensible "answer something rather than
# panic", and --diagnose keeps answering — but it must SAY which question it
# answered, because the answer it gives is false about the real host: MEASURED on
# macneo 2026-09-20, rootfs_present=false over 1.2 GiB of real guest state, with
# the HOME-set run one second earlier as the control.
#
# For a DESTRUCTIVE caller there is no defensible default. --reset-state builds
# its announcement from the same root it removes from, so with the fallback both
# halves are wrong TOGETHER: it names /tmp paths, does exactly what it named,
# exits 0, and the operator is told the local state was cleared while it sits
# untouched. The two halves agreeing is what makes it unreadable as a failure —
# which is why the refusal must precede the ANNOUNCEMENT, not just the deletion.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo 'FAIL: run under bash'; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FAIL=0
ok()   { printf 'ok: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; FAIL=1; }
skip() { printf 'SKIP(%s): %s\n' "$1" "$2"; }

SRC=crates/tillandsias-macos-tray/src/reset_state.rs
DIAG=crates/tillandsias-macos-tray/src/diagnose.rs

# ---- ARMS 1-2: the label, run against the REAL binary -----------------------
TRAY=target/debug/tillandsias-tray
if [ ! -x "$TRAY" ]; then
    # NAMED SKIP. A check that could not run must never claim what it would have
    # found (965-sxec). These two arms need a built binary; the source arms below
    # do not and still run.
    skip "tray-not-built" "ARMS 1-2 need $TRAY (cargo build -p tillandsias-macos-tray); NOT a pass"
else
    OUT_UNSET="$(env -u HOME "$TRAY" --diagnose --json 2>/dev/null)"
    if printf '%s' "$OUT_UNSET" | grep -q '"image_root_source": "fallback:/tmp:HOME-unset"'; then
        ok "ARM1 with HOME unset, --diagnose LABELS its fallback root"
    else
        bad "ARM1 no fallback label in --diagnose output with HOME unset"
    fi
    # CONTROL. Without this, ARM 1 would pass just as well if the field were
    # hard-coded to the fallback string, which would be a different defect
    # wearing this fix's clothes.
    OUT_SET="$("$TRAY" --diagnose --json 2>/dev/null)"
    if printf '%s' "$OUT_SET" | grep -q '"image_root_source": "home"'; then
        ok "ARM2 CONTROL — with HOME set the same binary reports source=home"
    else
        bad "ARM2 control failed: HOME is set but source is not 'home'"
    fi
fi

# ---- ARM 3: the refusal precedes the ANNOUNCEMENT ---------------------------
# Source order, not behaviour, and deliberately so: the property is that nothing
# is SHOWN to the operator before the root is known good. A test that only
# checked "nothing was deleted" would pass a version that announced /tmp paths
# and then refused, which is already the false report.
R="$(grep -n 'image_root_for_destruction()' "$SRC" | grep -v '^\s*//' | head -1 | cut -d: -f1)"
A="$(grep -n 'announce_reset_plan(&d, &p)' "$SRC" | head -1 | cut -d: -f1)"
D="$(grep -n 'wipe_provisioned_artifacts()' "$SRC" | head -1 | cut -d: -f1)"
if [ -n "$R" ] && [ -n "$A" ] && [ -n "$D" ] && [ "$R" -lt "$A" ] && [ "$A" -lt "$D" ]; then
    ok "ARM3 refusal ($R) precedes announcement ($A) precedes destruction ($D)"
else
    bad "ARM3 ordering wrong: refusal=$R announce=$A destroy=$D"
fi

# ---- ARM 4: the destructive resolver refuses, the reader does not ------------
if grep -q 'fn image_root_for_destruction() -> Result<PathBuf, String>' "$DIAG" \
   && grep -q 'refused:reset-state:no-home' "$DIAG"; then
    ok "ARM4 the destructive resolver returns Result and names its refusal"
else
    bad "ARM4 image_root_for_destruction is missing or does not name refused:reset-state:no-home"
fi
if grep -qE '^pub\(crate\) fn image_root\(\) -> PathBuf|^    resolve_image_root\(\)\.0' "$DIAG"; then
    ok "ARM5 the READER still answers infallibly (a diagnostic that panics helps nobody)"
else
    bad "ARM5 the reader path no longer answers infallibly"
fi

# ---- ARM 6: the twin is gone ------------------------------------------------
# status_item::default_image_root carried a byte-identical copy of the fallback
# and is what the LIVE TRAY reads, so a fix to diagnose alone left the running
# process resolving to /tmp with nothing saying so.
if grep -q 'PathBuf::from("/tmp")' crates/tillandsias-macos-tray/src/status_item.rs; then
    bad "ARM6 status_item still carries its own /tmp fallback — two copies of one rule"
else
    ok "ARM6 status_item delegates to the single resolver"
fi

# ---- ARM 7: MUTATION, both directions ---------------------------------------
# ARM 3 is a line-order check and would pass trivially if its greps stopped
# matching. This reproduces the defect in a COPY and requires the check to fail.
MUT="$(mktemp -d)"; trap 'rm -rf "$MUT"' EXIT
sed 's/crate::diagnose::image_root_for_destruction()?/crate::diagnose::image_root()/' "$SRC" > "$MUT/m.rs"
MR="$(grep -n 'image_root_for_destruction()' "$MUT/m.rs" | grep -v '^\s*//' | head -1 | cut -d: -f1)"
if [ -z "$MR" ]; then
    ok "ARM7 MUTATION — removing the refusal makes ARM3 unable to find it, i.e. FAIL"
else
    bad "ARM7 the mutation did not remove the refusal (line $MR); ARM3 cannot be discriminating"
fi

[ "$FAIL" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "FAILED"; exit 1; }
