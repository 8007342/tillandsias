#!/usr/bin/env bash
# @trace spec:spec-traceability, spec:methodology-accountability
# @trace order:976-suab
#
# Fixture for the requirement-id generator and validator.
#
# IT DRIVES A TEMPORARY CORPUS, and that is not incidental. The generator's
# first version derived its root from BASH_SOURCE and cd'd there
# unconditionally, so a "test" pointed at a copied corpus stamped the LIVE specs
# instead — measured, on this script's first run. TILLANDSIAS_SPEC_ROOT exists
# because of that, and this fixture is what would have caught it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$REPO_ROOT/scripts/stamp-requirement-ids.sh"
CHECK="$REPO_ROOT/scripts/check-requirement-ids.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

mkcorpus() {
    rm -rf "$TMP/openspec"
    mkdir -p "$TMP/openspec/specs/alpha" "$TMP/openspec/specs/beta"
    cat > "$TMP/openspec/specs/alpha/spec.md" <<'EOF'
# alpha Specification

## Requirements

### Requirement: A-1 — the first obligation

The system MUST do the first thing.

### Requirement: A-2 — the second obligation

The system MUST do the second thing.
EOF
    # A TOMBSTONED spec that still carries a requirement. 29 of the 30
    # tombstoned specs have had their bodies stripped; one has not, and
    # exempting tombstones would leave its requirements uncounted forever.
    cat > "$TMP/openspec/specs/beta/spec.md" <<'EOF'
<!-- @tombstone superseded:alpha -->
# beta Specification (Tombstone)

### Requirement: B-1 — a retired obligation that must stay countable
EOF
}

run_stamp() { TILLANDSIAS_SPEC_ROOT="$TMP" bash "$STAMP" 2>&1; }
run_check() { TILLANDSIAS_SPEC_ROOT="$TMP" bash "$CHECK" 2>&1; }

# 1. A fresh corpus fails the validator before it is stamped. The negative
#    control for the guard itself.
mkcorpus
out="$(run_check)"; rc=$?
[ "$rc" = 1 ] || fail "unstamped corpus should fail the validator (got rc=$rc: $out)"
case "$out" in *"violation:requirement-ids-missing:3"*) ;; *) fail "expected 3 missing, got: $out" ;; esac

# 2. Stamping makes it pass, and the TOMBSTONED requirement is stamped too.
out="$(run_stamp)"
case "$out" in *"3 new"*) ;; *) fail "expected 3 new, got: $out" ;; esac
out="$(run_check)"; rc=$?
[ "$rc" = 0 ] || fail "stamped corpus should pass (got rc=$rc: $out)"
grep -q '<!-- req-id: [0-9a-f]\{8\} -->' "$TMP/openspec/specs/beta/spec.md" \
    || fail "the tombstoned spec's requirement was not stamped"

# 3. IDEMPOTENCE — the contract. A second run stamps nothing and leaves the
#    corpus byte-identical. A generator that reshuffled identifiers would still
#    report success and would rebuild the original problem in a new shape.
before="$(cat "$TMP/openspec/specs/alpha/spec.md" "$TMP/openspec/specs/beta/spec.md")"
out="$(run_stamp)"
case "$out" in *"0 new, 3 already had one, 0 file(s) rewritten"*) ;; *) fail "second run was not a no-op: $out" ;; esac
after="$(cat "$TMP/openspec/specs/alpha/spec.md" "$TMP/openspec/specs/beta/spec.md")"
[ "$before" = "$after" ] || fail "second run changed the corpus"

# 4. NEVER REASSIGN: a hand-written identifier survives stamping untouched.
sed -i 's/<!-- req-id: [0-9a-f]* -->/<!-- req-id: deadbeef -->/' "$TMP/openspec/specs/beta/spec.md"
run_stamp >/dev/null
grep -q 'req-id: deadbeef' "$TMP/openspec/specs/beta/spec.md" \
    || fail "an existing identifier was reassigned"

# 5. A new requirement appended by hand is stamped, and the ones already there
#    keep their identifiers. This is the real-world path: nobody re-stamps a
#    corpus, they add one requirement.
kept="$(grep -oE 'req-id: [0-9a-f]{8}' "$TMP/openspec/specs/alpha/spec.md" | head -1)"
printf '\n### Requirement: A-3 — added by hand\n' >> "$TMP/openspec/specs/alpha/spec.md"
out="$(run_stamp)"
case "$out" in *"1 new"*) ;; *) fail "a hand-added requirement was not stamped: $out" ;; esac
grep -q "$kept" "$TMP/openspec/specs/alpha/spec.md" || fail "stamping a new requirement disturbed an existing identifier"

# 6. DUPLICATES ARE A VIOLATION, and worse than absence: a missing identifier is
#    visibly absent, a duplicate silently merges two obligations into one row.
sed -i '0,/<!-- req-id: [0-9a-f]* -->/s//<!-- req-id: deadbeef -->/' "$TMP/openspec/specs/alpha/spec.md"
out="$(run_check)"; rc=$?
[ "$rc" = 1 ] || fail "a duplicate identifier should fail the validator (got rc=$rc)"
case "$out" in *"violation:requirement-ids-duplicated:1"*) ;; *) fail "expected a duplicate verdict, got: $out" ;; esac

if [ "$failures" -gt 0 ]; then
    echo "FAILED: $failures case(s)"
    exit 1
fi
echo "ok: requirement-id generator and validator fixture 6/6"
