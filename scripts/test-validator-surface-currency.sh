#!/usr/bin/env bash
# @trace order:1287-h6qn
#
# The validator surface is a CONTENT probe, and these arms pin the two ways that
# can rot: a hash that moves when nothing changed (the defect this row fixes),
# and a hash that fails to move when something did (the same defect wearing the
# fix's clothes, and the more dangerous direction — it lies toward healthy).
#
# Runs against the RESOLVED release binary. Skips BY NAME when it cannot be
# found or is too old to carry the subcommand: a skip that reads as a pass is
# what 1287-h6qn is about.
set -uo pipefail

# RESOLVE THROUGH THE SHARED PROBE (704-zcgi, 721-nyev, 751-vega), never a
# hardcoded target/ path: inside a forge CARGO_TARGET_DIR is exported and the
# binary is not where this script would have guessed, so a hardcoded path finds
# nothing and the fixture skips itself into a green that means nothing. An
# executable bit is a claim; running the binary is evidence.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
BIN="$(resolve_plan_binary)"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  [OK]   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }

if [ ! -x "$BIN" ]; then
    echo "skip:validator-surface-currency:no-binary — $BIN is missing or not executable"
    exit 0
fi
if ! "$BIN" validator-surface-hash >/dev/null 2>&1; then
    echo "skip:validator-surface-currency:no-subcommand — $BIN predates 1287-h6qn"
    exit 0
fi

MANIFEST=crates/tillandsias-plan/validator-surface.manifest
[ -f "$MANIFEST" ] || { echo "FAIL: $MANIFEST is missing — the surface has no single definition"; exit 1; }

# 1925-ided: THE LIVE CHECKOUT IS NOT A FIXTURE. Record the mtimes of the
# surface files before any arm runs; the guard at the end refuses if one moved.
# A touched Cargo.lock reads as "sources newer than the binary" to the pre-push
# lane's mtime fallback, and every later fixture in the same gate that pushes
# through that lane was refused STALE (claims-fleet-visible 9/22, v56.10.30.1 cut).
LIVE_GUARDED="Cargo.lock crates/tillandsias-plan/Cargo.toml $MANIFEST crates/tillandsias-plan/src/main.rs"
live_mtimes() { for f in $LIVE_GUARDED; do printf '%s %s\n' "$f" "$(stat -c %Y.%y "$f" 2>/dev/null || stat -f %m "$f")"; done; }
LIVE_BEFORE="$(live_mtimes)"

# ── 1. The binary agrees with the checkout it was built from ────────────────
if "$BIN" validator-surface-hash --check >/dev/null 2>&1; then
    ok "the resolved binary's embedded surface matches this checkout"
else
    bad "the resolved binary is stale against this checkout — rebuild before running this fixture"
fi

EMBEDDED="$("$BIN" validator-surface-hash 2>/dev/null)"
LIVE_CURRENT="$("$BIN" validator-surface-hash --current 2>/dev/null)"
[ -n "$EMBEDDED" ] && [ -n "$LIVE_CURRENT" ] || { echo "FAIL: could not read both hashes"; exit 1; }

# 1925-ided: arms 2-4 touch, mutate and widen surface files, so they run on a
# SCRATCH COPY of the surface (the manifest, every file it names, Cargo.lock)
# reached through TILLANDSIAS_SURFACE_ROOT, never on the live checkout. The
# root test is ".git exists + manifest is a file", so an empty .git dir is
# enough. Same scratch base as the other plan fixtures.
case "${CARGO_TARGET_DIR:-}" in
    /*) _scratch_base="${CARGO_TARGET_DIR%/}/plan-scratch" ;;
    ?*) _scratch_base="$PWD/${CARGO_TARGET_DIR%/}/plan-scratch" ;;
    *)  _scratch_base="$PWD/target/plan-scratch" ;;
esac
mkdir -p "$_scratch_base" && SCRATCH="$(mktemp -d "$_scratch_base/validator-surface-currency.XXXXXX")" \
    || { echo "FAIL: cannot make a scratch surface copy"; exit 1; }
cleanup_scratch() { rm -rf "$SCRATCH"; }
trap cleanup_scratch EXIT INT TERM HUP PIPE
mkdir -p "$SCRATCH/.git"
for f in "$MANIFEST" Cargo.lock $(awk '/^file /{print $2}' "$MANIFEST"); do
    mkdir -p "$SCRATCH/$(dirname "$f")" && cp -p "$f" "$SCRATCH/$f" \
        || { echo "FAIL: cannot copy $f into the scratch surface"; exit 1; }
done
export TILLANDSIAS_SURFACE_ROOT="$SCRATCH"
CURRENT="$("$BIN" validator-surface-hash --current 2>/dev/null)"
if [ -n "$CURRENT" ] && [ "$CURRENT" = "$LIVE_CURRENT" ]; then
    ok "the scratch surface copy hashes identically to the live checkout (the arms below ask the same question)"
else
    bad "the scratch surface copy hashes '$CURRENT', the live checkout '$LIVE_CURRENT' — the copy is not the surface"
fi

# ── 2. THE ARM THIS ROW EXISTS FOR ──────────────────────────────────────────
# `git rebase` rewrites every file it touches with a fresh mtime and identical
# bytes. Under the retired mtime rule that condemned a byte-correct binary and
# cost a 66s rebuild that produced a functionally identical binary.
FIRST_FILE="$(awk '/^file /{print $2; exit}' "$MANIFEST")"
if [ -n "$FIRST_FILE" ] && [ -f "$SCRATCH/$FIRST_FILE" ]; then
    touch "$SCRATCH/$FIRST_FILE" "$SCRATCH/Cargo.lock"
    AFTER_TOUCH="$("$BIN" validator-surface-hash --current 2>/dev/null)"
    if [ "$AFTER_TOUCH" = "$CURRENT" ]; then
        ok "touching a surface file without changing it does NOT move the hash (the rebase case)"
    else
        bad "an mtime-only touch moved the hash — the content probe is reading mtimes"
    fi
else
    bad "the manifest names no readable file — cannot run the rebase arm"
fi

# ── 3. MUTATION ARM: a real content change MUST move it ─────────────────────
PROBE=crates/tillandsias-plan/Cargo.toml
if grep -qxF "file $PROBE" "$MANIFEST"; then
    cp -p "$SCRATCH/$PROBE" "$SCRATCH/$PROBE.1287probe" || { echo "FAIL: cannot back up the scratch $PROBE"; exit 1; }
    printf '\n# 1287-h6qn mutation arm\n' >> "$SCRATCH/$PROBE"
    MUTATED="$("$BIN" validator-surface-hash --current 2>/dev/null)"
    if [ -n "$MUTATED" ] && [ "$MUTATED" != "$CURRENT" ]; then
        ok "a real content edit to a surface file MOVES the hash"
    else
        bad "a real content edit did not move the hash — the probe is blind"
    fi
    if ! "$BIN" validator-surface-hash --check >/dev/null 2>&1; then
        ok "--check refuses while the surface differs"
    else
        bad "--check passed against a mutated surface"
    fi
    NO_OUT="$("$BIN" next-order 2>&1)"
    if [ $? -ne 0 ] && grep -q 'stale-plan-binary' <<<"$NO_OUT"; then
        ok "next-order refuses to mint from a binary the lane would refuse (output 2)"
    else
        bad "next-order did not refuse as stale-plan-binary: ${NO_OUT%%$'\n'*}"
    fi
    mv -f "$SCRATCH/$PROBE.1287probe" "$SCRATCH/$PROBE"
else
    bad "$PROBE is not on the surface manifest — the mutation arm has no subject"
fi

# ── 4. NEGATIVE CONTROL ON THE MANIFEST ITSELF ──────────────────────────────
# One definition, or the two hashes drift the way two lists always do.
BEFORE_ADD="$("$BIN" validator-surface-hash --current 2>/dev/null)"
cp -p "$SCRATCH/$MANIFEST" "$SCRATCH/$MANIFEST.1287probe" || { echo "FAIL: cannot back up the scratch manifest"; exit 1; }
cp -p README.md "$SCRATCH/README.md" 2>/dev/null || true
echo "file README.md" >> "$SCRATCH/$MANIFEST"
WIDENED="$("$BIN" validator-surface-hash --current 2>/dev/null)"
if [ -n "$WIDENED" ] && [ "$WIDENED" != "$BEFORE_ADD" ]; then
    ok "adding a file to the manifest changes the computed hash (one definition, read from one place)"
else
    bad "widening the manifest did not change the hash — the list is not being read"
fi
mv -f "$SCRATCH/$MANIFEST.1287probe" "$SCRATCH/$MANIFEST"
unset TILLANDSIAS_SURFACE_ROOT

# ── 5. "CANNOT ASK" IS NOT "FRESH" ──────────────────────────────────────────
# The REAL no-checkout case is an INSTALLED binary — one with no .git above it,
# the ~/.local/bin shape — not merely a different cwd. The first draft of this
# arm ran the binary from / and passed on the error "read plan/index.yaml: No
# such file or directory", which is a missing LEDGER, not a missing checkout:
# the arm was green while testing nothing it claimed to. find_repo_root anchors
# on the executable, so only moving the executable asks the question.
OUTSIDE="$(mktemp -d)" || { echo "FAIL: cannot make a temp dir"; exit 1; }
# shellcheck disable=SC2064
trap "rm -rf '$OUTSIDE'; cleanup_scratch" EXIT INT TERM HUP PIPE
# 1925-xbpv: since 1745-ntuq the binary also walks up from the cwd and then
# falls back to the checkout it was BUILT from, so a copied binary still reaches
# a ledger here. The arm runs from outside the checkout and switches the build
# fallback off by its test-only env; the control below runs the same command
# WITH the fallback and must reach a ledger, which proves the switch is what
# makes the arm ask the cannot-ask question.
no_ledger() { (cd "$OUTSIDE" && env -u TILLANDSIAS_SURFACE_ROOT TILLANDSIAS_SURFACE_NO_BUILD_CHECKOUT="$1" ./tillandsias-plan validator-surface-hash --check 2>&1); }
if cp "$BIN" "$OUTSIDE/tillandsias-plan" 2>/dev/null; then
    CTRL="$(no_ledger 0)"
    case "$CTRL" in
        unknown:validator-surface*)
            bad "control: with the build-checkout fallback on, the binary still could not reach a ledger — the arm below would prove nothing" ;;
        *)
            ok "control: with the build-checkout fallback on, the copied binary reaches a ledger" ;;
    esac
    if OUT="$(no_ledger 1)"; then
        bad "--check passed from a binary with no checkout above it — cannot-ask read as fresh"
    else
        case "$OUT" in
            unknown:validator-surface*)
                ok "an installed binary with no checkout answers unknown, never fresh" ;;
            *)
                bad "non-zero, but the wrong answer: ${OUT%%$'\n'*}" ;;
        esac
    fi
    # And the embedded hash is still readable there — the binary carries it.
    if [ -n "$("$OUTSIDE/tillandsias-plan" validator-surface-hash 2>/dev/null)" ]; then
        ok "the embedded hash travels with the binary (no stamp file to leave behind)"
    else
        bad "the embedded hash is unreadable once the binary moves"
    fi
else
    bad "could not copy the binary outside the checkout — arm not run"
fi
rm -rf "$OUTSIDE"
trap cleanup_scratch EXIT INT TERM HUP PIPE

# ── 6. GUARD: the live checkout's surface files were never touched ──────────
LIVE_AFTER="$(live_mtimes)"
if [ "$LIVE_AFTER" = "$LIVE_BEFORE" ]; then
    ok "the live checkout's Cargo.lock and surface files keep their mtimes (arms ran on a scratch copy)"
else
    bad "the fixture changed live-checkout mtimes: $(diff <(printf '%s\n' "$LIVE_BEFORE") <(printf '%s\n' "$LIVE_AFTER") | grep '^>' | tr '\n' ' ')"
fi

printf 'validator-surface-currency %d/%d\n' "$pass" "$((pass+fail))"
[ "$fail" -eq 0 ] || exit 1
echo "ok:validator-surface-currency:$pass/$pass"
