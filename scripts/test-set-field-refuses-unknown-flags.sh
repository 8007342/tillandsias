#!/usr/bin/env bash
# @trace order:1285-vz27, spec:spec-traceability
#
# THE DEFECT. set-field's positional scan skipped `i += 2` for ANY token
# starting with `--`, which is two bugs in one line:
#
#   an UNKNOWN flag silently ate the next token — so a typo, or a flag borrowed
#   from a sibling subcommand, vanished along with its argument; and
#
#   a VALUELESS flag (--append/--replace/--backfill) ate the token after it,
#   which is normally the NEXT FLAG'S NAME, shifting every later token left and
#   promoting some unrelated string to the positional VALUE.
#
# Both then WROTE, and printed a success-shaped line. Measured on macneo
# 2026-09-19: a p1 row's next_action was overwritten with the literal
# `tlatoanis-macbook-neo`, and `tillandsias-plan check` reported ok, ids unique,
# references sound — every validator passing over a field that had just been
# replaced by a hostname. The prose the field was meant to carry was never
# written and nothing said so.
#
# IT HAPPENED TWICE. On 2026-09-20 this session ran a `--dry-run` probe against
# set-field to read the status vocabulary; --dry-run is not a set-field flag, it
# was absorbed in silence, and a note fragment was written against a row that was
# not being edited. Caught only because the writer looked at `git status`
# afterwards. A caller who trusts the success line cannot tell that from a
# correct write, which is why this is a ledger defect and not a usability nit.
#
# PRE-FIX / POST-FIX, measured here against a THROWAWAY ledger copy:
#   pre-fix  set-field <ref> notes "probe" --append --host H --ts T --dry-run
#            -> "[ts H] probe (…fragment.yaml)", fragments 1266 -> 1267
#   post-fix -> "error: unknown flag '--dry-run' … REFUSED before any write",
#               fragments unchanged
#
# EVERY ARM WRITES TO A COPY. The real plan/ is never touched: the fixture
# copies the ledger to a temp dir and passes --index. A test for a tool whose
# defect is an unwanted write must not be able to produce one.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"

pass=0; fail=0; skipped=0
ok()      { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad()     { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }
skiparm() { printf 'skip: %s\n' "$1"; skipped=$((skipped + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The binary under test is the BUILT one, never whatever is on PATH: an
# installed copy may predate this change and would make every arm below report
# on code that is not in this tree.
#
# RESOLVED THROUGH THE SHARED PROBE (721-nyev), not a hardcoded target/ path.
# The first version of this line looked under ./target/release then
# ./target/debug, and the gate refused it: every forge exports CARGO_TARGET_DIR
# so ./target does not exist in the mounted checkout at all, and a probe that
# looks only there cannot see the binary that was just built. The probe also
# honours TILLANDSIAS_PLAN_BIN, which is how a caller names a binary rather than
# offering a candidate.
. "$ROOT/scripts/plan-binary-probe.sh"
BIN="$(resolve_plan_binary)" || BIN=""
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    printf 'skip:set-field-unknown-flags:no-built-binary (cargo build -p tillandsias-plan)\n'
    exit 0
fi

# A throwaway ledger. Fragments are copied too, so a packet that lives only in
# the overlay still resolves.
LED="$TMP/plan"; mkdir -p "$LED"
cp "$ROOT/plan/index.yaml" "$LED/" 2>/dev/null || {
    printf 'skip:set-field-unknown-flags:no-ledger-to-copy\n'; exit 0; }
cp -r "$ROOT/plan/index.d" "$LED/" 2>/dev/null || true
IDX="$LED/index.yaml"
frags() { ls "$LED/index.d" 2>/dev/null | wc -l; }

# A row to write against: any packet the folded ledger resolves. Picked from the
# ledger itself rather than hardcoded, so this fixture does not rot when a
# particular order is archived.
REF="$("$BIN" --index "$IDX" ready 2>/dev/null | grep -oE '^[0-9]{3,4}-[a-z0-9]{4}' | head -1)"
if [ -z "$REF" ]; then
    printf 'skip:set-field-unknown-flags:no-resolvable-row-in-the-copy\n'
    exit 0
fi
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------- ARM 1
# AN UNKNOWN FLAG IS REFUSED, BY NAME, BEFORE ANY WRITE.
b="$(frags)"
out="$("$BIN" --index "$IDX" set-field "$REF" notes "arm1" --append --host yoga --ts "$TS" --dry-run 2>&1)"
a="$(frags)"
if [ "$a" -ne "$b" ]; then
    bad "ARM 1: an unknown flag still WROTE ($b -> $a fragments) — the ledger-corrupting path is open"
elif printf '%s' "$out" | grep -q "unknown flag '--dry-run'"; then
    ok "ARM 1: --dry-run is refused BY NAME and nothing is written (pre-fix: absorbed in silence, write landed)"
else
    bad "ARM 1: no write, but the refusal does not name the flag: $(printf '%s' "$out" | head -1)"
fi

# The refusal must also say what IS accepted, or a caller learns only that they
# were wrong and not what to type.
if printf '%s' "$out" | grep -q -- '--value-file' && printf '%s' "$out" | grep -q -- '--append'; then
    ok "ARM 1b: the refusal lists the accepted flags, value-taking and valueless separately"
else
    bad "ARM 1b: the refusal names the bad flag but not the accepted set"
fi

# ---------------------------------------------------------------- ARM 2
# A VALUELESS FLAG NO LONGER EATS THE NEXT FLAG'S NAME. --append is followed by
# --ts; pre-fix, --append consumed `--ts` and the ISO became the positional
# VALUE, so the field was written with a timestamp.
b="$(frags)"
out="$("$BIN" --index "$IDX" set-field "$REF" notes "arm2 real value" --append --ts "$TS" --host yoga 2>&1)"
a="$(frags)"
if [ "$a" -le "$b" ]; then
    bad "ARM 2: an ordinary --append write did not land ($b -> $a) — the parse now refuses something it should accept: $(printf '%s' "$out" | head -1)"
elif printf '%s' "$out" | grep -Fq 'arm2 real value'; then
    ok "ARM 2: --append followed by --ts writes the POSITIONAL value, not the timestamp"
else
    bad "ARM 2: the write landed but the value is not the positional one: $(printf '%s' "$out" | tail -1)"
fi

# ---------------------------------------------------------------- ARM 3
# PROSE FROM A FILE, so no shell ever sees the text. The probe deliberately
# carries the metacharacters that make shell-quoted prose dangerous.
printf 'prose with $HOME and `backticks` and "quotes" & a pipe |\n' > "$TMP/value.txt"
b="$(frags)"
out="$("$BIN" --index "$IDX" set-field "$REF" notes --value-file "$TMP/value.txt" --append --ts "$TS" --host yoga 2>&1)"
a="$(frags)"
if [ "$a" -le "$b" ]; then
    bad "ARM 3: --value-file did not write ($b -> $a): $(printf '%s' "$out" | head -1)"
elif printf '%s' "$out" | grep -Fq 'prose with $HOME and `backticks`'; then
    ok "ARM 3: --value-file carries prose verbatim, metacharacters and all, with no shell in the path"
else
    bad "ARM 3: --value-file wrote something other than the file's contents: $(printf '%s' "$out" | tail -1)"
fi

# Passing both a positional value and --value-file is ambiguous and must refuse
# rather than silently prefer one.
b="$(frags)"
out="$("$BIN" --index "$IDX" set-field "$REF" notes "positional too" --value-file "$TMP/value.txt" --host yoga 2>&1)"
if [ "$(frags)" -eq "$b" ] && printf '%s' "$out" | grep -q 'REFUSED'; then
    ok "ARM 3b: a positional value AND --value-file together are refused, not silently resolved"
else
    bad "ARM 3b: the ambiguous form was accepted — one of the two values was chosen without saying which"
fi

# ---------------------------------------------------------------- ARM 4
# THE OBSERVABLE SIGNATURE. When a flag ate the wrong token, the value that
# landed was byte-identical to another flag's argument on the same line.
b="$(frags)"
out="$("$BIN" --index "$IDX" set-field "$REF" notes "yoga" --host yoga --ts "$TS" 2>&1)"
if [ "$(frags)" -eq "$b" ] && printf '%s' "$out" | grep -q 'byte-identical'; then
    ok "ARM 4: a value byte-identical to another flag's argument is refused — the misparse's fingerprint"
else
    bad "ARM 4: a value identical to the --host argument was accepted; the signature that caught the original incident is unguarded"
fi

# ---------------------------------------------------------------- ARM 5
# THE MUTANT the row asks for: restore the permissive parse and prove the defect
# returns. It is OPT-IN because it requires rebuilding the crate (~40s here) and
# patching a source file, which is not something a gate step should do to a
# working tree. The result is MEASURED and recorded on 1285-vz27 rather than
# asserted: with the pre-fix binary, the ARM 1 command line printed a success
# line and the fragment count went 1266 -> 1267; with this one it refuses and
# the count is unchanged.
if [ "${TILLANDSIAS_SET_FIELD_MUTANT:-0}" != "1" ]; then
    skiparm "ARM 5 (MUTANT): opt-in — set TILLANDSIAS_SET_FIELD_MUTANT=1 to rebuild with the permissive parse; the pre-fix measurement is recorded on 1285-vz27"
else
    MUT="$TMP/mutant"; mkdir -p "$MUT"
    if ! command -v cargo >/dev/null 2>&1; then
        skiparm "ARM 5 (MUTANT): cargo is not on PATH here, so the permissive parse cannot be rebuilt"
    else
        cp "$ROOT/crates/tillandsias-plan/src/main.rs" "$MUT/main.rs.orig"
        # Restore the single line the fix replaced.
        if perl -0pi -e 's/if VALUE_FLAGS\.contains\(&a\) \{\n\s*i \+= 2;\n\s*\} else if BOOL_FLAGS\.contains\(&a\) \{\n\s*i \+= 1;\n\s*\} else \{/if true { i += 2; } else if false {/s' \
             "$ROOT/crates/tillandsias-plan/src/main.rs" 2>/dev/null; then
            cargo build --release -p tillandsias-plan >/dev/null 2>&1
            b="$(frags)"
            "$BIN" --index "$IDX" set-field "$REF" notes "mutant" --append --host yoga --ts "$TS" --dry-run >/dev/null 2>&1
            if [ "$(frags)" -gt "$b" ]; then
                ok "ARM 5 (MUTANT): with the permissive parse restored, the unknown flag is absorbed and the write LANDS — the fixture observes the defect"
            else
                bad "ARM 5 (MUTANT): the permissive parse did not reproduce the write, so ARMs 1-4 are not exercising what they claim"
            fi
        else
            skiparm "ARM 5 (MUTANT): the patch did not apply — the parse has been restructured and this arm needs updating"
        fi
        cp "$MUT/main.rs.orig" "$ROOT/crates/tillandsias-plan/src/main.rs"
        cargo build --release -p tillandsias-plan >/dev/null 2>&1
    fi
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
    if [ "$skipped" -gt 0 ]; then
        printf 'ok:set-field-unknown-flags:%d/%d (%d skipped)\n' "$pass" "$((pass + fail))" "$skipped"
    else
        printf 'ok:set-field-unknown-flags:%d/%d\n' "$pass" "$((pass + fail))"
    fi
    exit 0
fi
printf 'blocked:set-field-unknown-flags:%d-failed-of-%d\n' "$fail" "$((pass + fail))"
exit 1
