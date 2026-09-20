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

BIN="${TILLANDSIAS_PLAN_BIN:-./target/release/tillandsias-plan}"
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

# ── 1. The binary agrees with the checkout it was built from ────────────────
if "$BIN" validator-surface-hash --check >/dev/null 2>&1; then
    ok "the resolved binary's embedded surface matches this checkout"
else
    bad "the resolved binary is stale against this checkout — rebuild before running this fixture"
fi

EMBEDDED="$("$BIN" validator-surface-hash 2>/dev/null)"
CURRENT="$("$BIN" validator-surface-hash --current 2>/dev/null)"
[ -n "$EMBEDDED" ] && [ -n "$CURRENT" ] || { echo "FAIL: could not read both hashes"; exit 1; }

# ── 2. THE ARM THIS ROW EXISTS FOR ──────────────────────────────────────────
# `git rebase` rewrites every file it touches with a fresh mtime and identical
# bytes. Under the retired mtime rule that condemned a byte-correct binary and
# cost a 66s rebuild that produced a functionally identical binary.
FIRST_FILE="$(awk '/^file /{print $2; exit}' "$MANIFEST")"
if [ -n "$FIRST_FILE" ] && [ -f "$FIRST_FILE" ]; then
    touch "$FIRST_FILE" Cargo.lock
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
    cp "$PROBE" "$PROBE.1287probe" || { echo "FAIL: cannot back up $PROBE"; exit 1; }
    # shellcheck disable=SC2064
    trap "mv -f '$PROBE.1287probe' '$PROBE' 2>/dev/null || true" EXIT INT TERM HUP PIPE
    printf '\n# 1287-h6qn mutation arm\n' >> "$PROBE"
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
    if ! "$BIN" next-order >/dev/null 2>&1; then
        ok "next-order refuses to mint from a binary the lane would refuse (output 2)"
    else
        bad "next-order minted an identifier from a stale binary"
    fi
    mv -f "$PROBE.1287probe" "$PROBE"
    trap - EXIT INT TERM HUP PIPE
else
    bad "$PROBE is not on the surface manifest — the mutation arm has no subject"
fi

# ── 4. NEGATIVE CONTROL ON THE MANIFEST ITSELF ──────────────────────────────
# One definition, or the two hashes drift the way two lists always do.
BEFORE_ADD="$("$BIN" validator-surface-hash --current 2>/dev/null)"
cp "$MANIFEST" "$MANIFEST.1287probe" || { echo "FAIL: cannot back up the manifest"; exit 1; }
# shellcheck disable=SC2064
trap "mv -f '$MANIFEST.1287probe' '$MANIFEST' 2>/dev/null || true" EXIT INT TERM HUP PIPE
echo "file README.md" >> "$MANIFEST"
WIDENED="$("$BIN" validator-surface-hash --current 2>/dev/null)"
if [ -n "$WIDENED" ] && [ "$WIDENED" != "$BEFORE_ADD" ]; then
    ok "adding a file to the manifest changes the computed hash (one definition, read from one place)"
else
    bad "widening the manifest did not change the hash — the list is not being read"
fi
mv -f "$MANIFEST.1287probe" "$MANIFEST"
trap - EXIT INT TERM HUP PIPE

# ── 5. "CANNOT ASK" IS NOT "FRESH" ──────────────────────────────────────────
# The REAL no-checkout case is an INSTALLED binary — one with no .git above it,
# the ~/.local/bin shape — not merely a different cwd. The first draft of this
# arm ran the binary from / and passed on the error "read plan/index.yaml: No
# such file or directory", which is a missing LEDGER, not a missing checkout:
# the arm was green while testing nothing it claimed to. find_repo_root anchors
# on the executable, so only moving the executable asks the question.
OUTSIDE="$(mktemp -d)" || { echo "FAIL: cannot make a temp dir"; exit 1; }
# shellcheck disable=SC2064
trap "rm -rf '$OUTSIDE'" EXIT INT TERM HUP PIPE
if cp "$BIN" "$OUTSIDE/tillandsias-plan" 2>/dev/null; then
    if OUT="$("$OUTSIDE/tillandsias-plan" validator-surface-hash --check 2>&1)"; then
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
trap - EXIT INT TERM HUP PIPE

printf 'validator-surface-currency %d/%d\n' "$pass" "$((pass+fail))"
[ "$fail" -eq 0 ] || exit 1
echo "ok:validator-surface-currency:$pass/$pass"
