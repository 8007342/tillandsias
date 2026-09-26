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
sed 's/<!-- req-id: [0-9a-f]* -->/<!-- req-id: deadbeef -->/' "$TMP/openspec/specs/beta/spec.md" > "$TMP/openspec/specs/beta/spec.md.tmp" && mv "$TMP/openspec/specs/beta/spec.md.tmp" "$TMP/openspec/specs/beta/spec.md"
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
# FIRST occurrence only, in awk. `sed '0,/re/s//.../'` is a GNU extension twice
# over — the 0 address and the empty-regex back-reference — and BSD sed applies
# neither, so on macOS the file was left UNCHANGED, no duplicate was created,
# and the arm failed claiming the validator had missed one. The fixture was
# testing sed's dialect, not the validator.
awk '!done && sub(/<!-- req-id: [0-9a-f]* -->/, "<!-- req-id: deadbeef -->") { done = 1 } { print }' \
    "$TMP/openspec/specs/alpha/spec.md" > "$TMP/openspec/specs/alpha/spec.md.tmp" \
    && mv "$TMP/openspec/specs/alpha/spec.md.tmp" "$TMP/openspec/specs/alpha/spec.md"
out="$(run_check)"; rc=$?
[ "$rc" = 1 ] || fail "a duplicate identifier should fail the validator (got rc=$rc)"
case "$out" in *"violation:requirement-ids-duplicated:1"*) ;; *) fail "expected a duplicate verdict, got: $out" ;; esac

# 7. THE NUMBERED DIALECT IS A REQUIREMENT TOO (order 1396-35we). Four active
#    specs wrote `### Requirement <n>: <title>`, which the colon-only matcher
#    never saw: their 29 requirements were neither counted nor checked, and the
#    CentiColon extractor listed them as unkeyed. A numbered heading without an
#    id must be reported MISSING.
#    PRE-FIX RESULT: FAILS, ok:requirement-ids:3 (the numbered one is invisible).
mkcorpus
run_stamp >/dev/null
mkdir -p "$TMP/openspec/specs/gamma"
cat > "$TMP/openspec/specs/gamma/spec.md" <<'EOF'
# gamma Specification

### Requirement 1: G-1 — a numbered obligation

The system MUST do the numbered thing.
EOF
out="$(run_check)"; rc=$?
[ "$rc" = 1 ] || fail "a numbered requirement without an id should fail the validator (got rc=$rc: $out)"
case "$out" in *"violation:requirement-ids-missing:1"*) ;; *) fail "expected missing:1 for the numbered heading, got: $out" ;; esac

# 8. ...and the stamper mints it a NEW random id in the corpus format (8 hex),
#    leaves every existing id alone, and a second run is a no-op.
before_alpha="$(grep -h 'req-id' "$TMP/openspec/specs/alpha/spec.md")"
run_stamp >/dev/null
gid="$(sed -n 's/^<!-- req-id: \([0-9a-f]*\) -->$/\1/p' "$TMP/openspec/specs/gamma/spec.md")"
case "$gid" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) fail "the numbered heading should get one 8-hex id, got '$gid'" ;;
esac
[ "$(grep -h 'req-id' "$TMP/openspec/specs/alpha/spec.md")" = "$before_alpha" ] \
    || fail "stamping the numbered heading reassigned an existing id"
out="$(run_check)"; rc=$?
[ "$rc" = 0 ] || fail "after stamping, the numbered corpus should pass (got rc=$rc: $out)"
case "$out" in *"ok:requirement-ids:4 "*) ;; *) fail "expected 4 requirements counted, got: $out" ;; esac
snap="$(cat "$TMP/openspec/specs/gamma/spec.md")"
run_stamp >/dev/null
[ "$(cat "$TMP/openspec/specs/gamma/spec.md")" = "$snap" ] || fail "a second stamp changed the numbered spec"

if [ "$failures" -gt 0 ]; then
    echo "FAILED: $failures case(s)"
    exit 1
fi
echo "ok: requirement-id generator and validator fixture 8/8"
