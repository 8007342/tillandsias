#!/usr/bin/env bash
# @trace spec:ci-release
# test-promote-stable-evidence-gate.sh — pin the promote-stable.sh evidence gate.
#
# WHY THIS EXISTS. On 2026-08-23 the gate was found to be structurally unable to
# see the evidence its own sibling skill produces. It required "e2e"|"smoke" AND
# "PASS" AND the version to co-occur on ONE line, because grep is line-scoped.
# What /smoke-curl-install-and-test-e2e actually writes is
#   plan/issues/smoke-e2e-findings-v<version>-<date>.md
# containing
#   ## Run 2026-08-17T17:58Z→18:06Z — **PASS** (tag v0.4.260817.1, build …)
# "smoke"/"e2e" are in the FILENAME; the verdict line never repeats them. So a
# real, dated PASS for v0.4.260817.1 sat in plan/ from 2026-08-17 while the gate
# reported "No e2e PASS evidence" — and because nothing was promoted, hosts then
# skipped running the e2e ("no release newer than last tested evidence"), so the
# stall fed itself.
#
# The fix widened WHERE the "this is e2e evidence" signal may come from (the
# filename) but NOT what counts as a verdict: a file must still assert PASS for
# THIS EXACT version. Case 3 is the one that matters — a correctly named file
# whose content is a FAIL must still be refused. Without it, the fix would have
# traded a false-negative gate for a false-positive one, which on a release gate
# is the strictly worse direction.
#
# Hermetic: fixture REPO_ROOT (the script derives it from BASH_SOURCE). No
# network, no real repo, no promotion.
#
# ORDER 864-8tqv CHANGED WHAT THIS TEST IS. It used to drive the REAL promotion
# path and rely on permissive `gh`/`git` STUBS to absorb the mutations — so a
# passing gate really did call `gh release edit`, and only the stub stopped it
# reaching GitHub. Now every case runs `--dry-run`, and the PATH entries are
# TRIPWIRES rather than stubs: `git` fails on any invocation at all, and `gh`
# serves reads but records any write verb as a violation. After each case the
# violation log must be EMPTY.
#
# That inverts the guarantee. Before: "the stub absorbed whatever it did."
# After: "it did nothing, and the harness would have caught it if it had."
# The mutation control at the end proves the tripwire is real by running the
# PRE-864-8tqv script through it and requiring it to trip.
set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/promote-stable-gate-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

pass=0; fail=0
VER="v0.4.260817.1"

# TRIPWIRES, not stubs. A stub absorbs a mutation and lets the test pass; a
# tripwire records it so the test can FAIL on it.
mkdir -p "$WORK/bin"
VIOLATIONS="$WORK/violations.log"
: > "$VIOLATIONS"
export VIOLATIONS

cat >"$WORK/bin/gh" <<'TRIP'
#!/usr/bin/env bash
# Reads are served. Writes are recorded as violations AND still refused, so a
# dry-run that leaks a mutation fails loudly instead of being absorbed.
case "$1 ${2:-}" in
    "release view")
        # `release view <tag> --json targetCommitish --jq ...` wants a commit.
        printf '%s\n' "deadbeef"; exit 0 ;;
    "repo view")   printf '%s\n' "8007342/tillandsias"; exit 0 ;;
    "release edit")
        echo "MUTATION gh $*" >> "$VIOLATIONS"; exit 1 ;;
esac
if [ "$1" = "api" ]; then
    case " $* " in
        *" -X PATCH "*|*" -X POST "*|*" -X DELETE "*)
            echo "MUTATION gh $*" >> "$VIOLATIONS"; exit 1 ;;
    esac
    # read-only api: releases/tags/<t> -> id, releases/latest -> tag_name
    case " $* " in
        *"releases/latest"*) printf '%s\n' "v0.0.0.0"; exit 0 ;;
        *"releases/tags/"*)  printf '%s\n' "12345";    exit 0 ;;
    esac
    exit 0
fi
exit 0
TRIP

cat >"$WORK/bin/git" <<'TRIP'
#!/usr/bin/env bash
# --dry-run must never reach git at all: no tag, no push, nothing.
echo "MUTATION git $*" >> "$VIOLATIONS"
exit 1
TRIP
chmod +x "$WORK/bin/gh" "$WORK/bin/git"

# run_case <name> <expected-regex> -- then the caller has already populated
# $WORK/root/plan with the fixture evidence.
# run_case <name> <expected-regex> [args...]  — defaults to `$VER --dry-run`.
# Two assertions per case: the verdict line, and that NOTHING was mutated.
run_case() {
    local name="$1" expect="$2"; shift 2
    local out rc
    [ $# -gt 0 ] || set -- "$VER" --dry-run
    : > "$VIOLATIONS"
    out="$(PATH="$WORK/bin:$PATH" VIOLATIONS="$VIOLATIONS" \
           bash "$WORK/root/scripts/promote-stable.sh" "$@" 2>/dev/null)"
    rc=$?
    local last; last="$(printf '%s\n' "$out" | grep -E '^(promoted|would-promote|would-demote|demoted|refused):' | tail -1)"
    local viol; viol="$(wc -l < "$VIOLATIONS" | tr -d ' ')"
    if ! printf '%s' "$last" | grep -Eq "$expect"; then
        printf 'FAIL %-52s -> %s (expected %s, rc=%s)\n' "$name" "${last:-<none>}" "$expect" "$rc"
        fail=$((fail + 1)); return
    fi
    if [ "$viol" != "0" ]; then
        printf 'FAIL %-52s -> %s but MUTATED: %s\n' "$name" "$last" "$(tr '\n' ';' < "$VIOLATIONS")"
        fail=$((fail + 1)); return
    fi
    printf 'ok   %-52s -> %s (0 mutations)\n' "$name" "${last:-<none>}"
    pass=$((pass + 1))
}

fresh_root() {
    rm -rf "$WORK/root"
    mkdir -p "$WORK/root/scripts" "$WORK/root/plan/issues"
    cp "$REAL_ROOT/scripts/promote-stable.sh" "$WORK/root/scripts/"
}

# 1. THE REGRESSION CASE: the exact shape the e2e skill writes. Words "smoke"
#    and "e2e" only in the filename; PASS and version on a heading together.
fresh_root
cat >"$WORK/root/plan/issues/smoke-e2e-findings-${VER}-2026-08-17.md" <<EOF
# curl-install e2e findings

## Run 2026-08-17T17:58Z→18:06Z — **PASS** (tag ${VER}, build commit 0bba6525f)
EOF
run_case "real e2e-skill evidence shape (was BROKEN)" '^would-promote:'

# 2. No evidence anywhere.
fresh_root
echo "nothing relevant here" >"$WORK/root/plan/issues/unrelated.md"
run_case "no evidence at all" '^refused:no-evidence:'

# 3. THE ONE THAT KEEPS THE FIX HONEST: right filename, FAIL verdict.
fresh_root
cat >"$WORK/root/plan/issues/smoke-e2e-findings-${VER}-2026-08-17.md" <<EOF
## Run 2026-08-17T17:58Z→18:06Z — **FAIL** (tag ${VER}) install aborted
EOF
run_case "correctly named file but FAIL verdict" '^refused:no-evidence:'

# 4. A PASS, but for a different version.
fresh_root
cat >"$WORK/root/plan/issues/smoke-e2e-findings-v0.4.260810.1-2026-08-10.md" <<'EOF'
## Run 2026-08-10 — **PASS** (tag v0.4.260810.1)
EOF
run_case "PASS exists but for a different version" '^refused:no-evidence:'

# 5. Backward compatibility: the old single-line shape must still pass.
fresh_root
echo "curl-install e2e smoke PASS for 0.4.260817.1 on silverblue" \
    >"$WORK/root/plan/issues/legacy-note.md"
run_case "legacy single-line evidence still accepted" '^would-promote:'

# 6. Dot-escaping. Unescaped, 0.4.260817.1 as a regex also matches
#    0X4X260817X1 — on a release gate, accidental permissiveness is the wrong
#    way to be wrong. Filename carries the literal version (glob dots are
#    literal); only the CONTENT is the near-miss.
fresh_root
cat >"$WORK/root/plan/issues/smoke-e2e-findings-${VER}-2026-08-17.md" <<'EOF'
## Run — **PASS** (tag v0X4X260817X1)
EOF
run_case "regex dots do not match arbitrary chars" '^refused:no-evidence:'

# ---------------------------------------------------------------- 864-8tqv --
# 7-9. The dry-run's own grammar, and the demote path (864-mk2p).
fresh_root
cat >"$WORK/root/plan/issues/smoke-e2e-findings-${VER}-2026-08-17.md" <<EOF
## Run 2026-08-17T17:58Z — **PASS** (tag ${VER}, build 123)
EOF
run_case "flags parse in either order"        '^would-promote:' "$VER" --dry-run --force
run_case "bad tag refused before any gh call" '^refused:bad-tag:' "not-a-tag" --dry-run
run_case "demote dry-run names the restore"   '^would-demote:v0\.4\.260817\.1:latest-would-be:v0\.4\.260810\.1' \
         demote "$VER" --to v0.4.260810.1 --dry-run
run_case "demote without --to is refused"     '^refused:missing-target:' demote "$VER" --dry-run

# --------------------------------------------------------- MUTATION CONTROL --
# A gate you have not seen go RED is not a gate. Every case above asserts "0
# mutations"; that is worth nothing unless the harness can SEE a mutation.
#
# THIS USED TO READ `git show HEAD:scripts/promote-stable.sh`, i.e. the pre-fix
# script — and it worked exactly until the fix was committed, at which point
# HEAD BECAME THE FIXED SCRIPT, the "pre-fix" copy no longer mutated, and this
# case failed. A control that only holds while its own fix is uncommitted is
# not a control. It is self-contained now: take the CURRENT script and defeat
# ONLY its guard (--dry-run stops setting DRY_RUN), so the assertion is "this
# exact script, with its dry-run guard removed, mutates — and the tripwire
# catches it". That stays true for every future version of the script.
fresh_root
cat >"$WORK/root/plan/issues/smoke-e2e-findings-${VER}-2026-08-17.md" <<EOF
## Run 2026-08-17T17:58Z — **PASS** (tag ${VER}, build 123)
EOF
sed 's/--dry-run)  DRY_RUN=1 ;;/--dry-run)  DRY_RUN=0 ;;/' \
    "$REAL_ROOT/scripts/promote-stable.sh" > "$WORK/root/scripts/promote-stable.sh"
if ! grep -q 'DRY_RUN=0 ;;' "$WORK/root/scripts/promote-stable.sh"; then
    printf 'FAIL %-52s -> could not defeat the guard; the arg-parser line moved, so this control is not testing what it claims\n' \
        "MUTATION CONTROL: guard-defeated script trips wire"
    fail=$((fail + 1))
else
    : > "$VIOLATIONS"
    PATH="$WORK/bin:$PATH" VIOLATIONS="$VIOLATIONS" \
        bash "$WORK/root/scripts/promote-stable.sh" "$VER" --dry-run >/dev/null 2>&1 || true
    if [ -s "$VIOLATIONS" ]; then
        printf 'ok   %-52s -> tripwire fired: %s\n' \
            "MUTATION CONTROL: guard-defeated script trips wire" \
            "$(head -1 "$VIOLATIONS")"
        pass=$((pass + 1))
    else
        printf 'FAIL %-52s -> guard-defeated script mutated NOTHING; the tripwire cannot see writes, so every "0 mutations" above is vacuous\n' \
            "MUTATION CONTROL: guard-defeated script trips wire"
        fail=$((fail + 1))
    fi
fi

# ------------------------------------------------- 864-8tqv criterion 2 -----
# OPT-IN ONLINE CHECK: PROMOTE_DRYRUN_ONLINE=1.
#
# The criterion asks that the release's prerelease flag and the stable tag be
# byte-identical before and after a --dry-run of a PROMOTABLE tag — i.e. against
# the real path, not a fixture. Doing that naively means pointing the script at
# the live channel and trusting the guard under test, which is the exact risk
# this packet exists to remove. So `gh` here is a REFUSING PASSTHROUGH: reads
# exec the real binary, writes are recorded and cannot execute. The real
# release-existence read happens; a leaked mutation is physically impossible.
if [ "${PROMOTE_DRYRUN_ONLINE:-0}" = "1" ]; then
    ONLINE_TAG="${PROMOTE_DRYRUN_TAG:-v0.4.260817.1}"
    mkdir -p "$WORK/online"
    cat >"$WORK/online/gh" <<'PASS'
#!/usr/bin/env bash
case "$1 ${2:-}" in
    "release edit") echo "MUTATION gh $*" >> "$VIOLATIONS"; exit 1 ;;
esac
if [ "$1" = "api" ]; then
    case " $* " in
        *" -X PATCH "*|*" -X POST "*|*" -X DELETE "*)
            echo "MUTATION gh $*" >> "$VIOLATIONS"; exit 1 ;;
    esac
fi
exec /usr/bin/gh "$@"
PASS
    # Real `gh` shells out to git to resolve the remote (`git remote -v`), so
    # online the invariant is "no git WRITES", not "no git". Hermetically the
    # blunt tripwire above is correct, because nothing shells out there.
    cat >"$WORK/online/git" <<'PASS'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        tag|push|commit|update-ref|fetch|reset|checkout)
            echo "MUTATION git $*" >> "$VIOLATIONS"; exit 1 ;;
    esac
done
exec /usr/bin/git "$@"
PASS
    chmod +x "$WORK/online/gh" "$WORK/online/git"

    # isLatest is NOT a gh field — asking for it errors and yields "", which
    # made an earlier version of this check compare "" to "" and pass VACUOUSLY.
    # Read valid fields, and read /releases/latest separately since that is the
    # channel a promotion actually moves.
    _read_state() {
        /usr/bin/gh release view "$ONLINE_TAG" --json isPrerelease,isDraft,tagName 2>/dev/null
        /usr/bin/gh api repos/8007342/tillandsias/releases/latest --jq .tag_name 2>/dev/null
    }
    before_flags="$(_read_state)"
    before_tag="$(git -C "$REAL_ROOT" rev-parse refs/tags/stable 2>/dev/null || echo none)"
    : > "$VIOLATIONS"
    online_out="$(PATH="$WORK/online:$PATH" VIOLATIONS="$VIOLATIONS" \
        bash "$REAL_ROOT/scripts/promote-stable.sh" "$ONLINE_TAG" --dry-run 2>/dev/null | tail -1)"
    after_flags="$(_read_state)"
    after_tag="$(git -C "$REAL_ROOT" rev-parse refs/tags/stable 2>/dev/null || echo none)"

    if [ -z "$before_flags" ]; then
        printf 'FAIL %-52s -> state read returned NOTHING; the comparison would be vacuous\n' \
            "online dry-run mutates nothing"
        fail=$((fail + 1))
    elif [ -s "$VIOLATIONS" ]; then
        printf 'FAIL %-52s -> attempted %s\n' "online dry-run mutates nothing" "$(head -1 "$VIOLATIONS")"
        fail=$((fail + 1))
    elif [ "$before_flags" != "$after_flags" ] || [ "$before_tag" != "$after_tag" ]; then
        printf 'FAIL %-52s -> flags/tag CHANGED (%s / %s -> %s / %s)\n' \
            "online dry-run mutates nothing" "$before_flags" "$before_tag" "$after_flags" "$after_tag"
        fail=$((fail + 1))
    else
        printf 'ok   %-52s -> %s; flags %s and stable tag byte-identical\n' \
            "online dry-run mutates nothing (real gh reads)" "${online_out:-<none>}" "$before_flags"
        pass=$((pass + 1))
    fi
fi

printf '\n%s/%s passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]
