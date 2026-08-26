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

# ── 888-p3kt: the gate is now PER-PLATFORM ───────────────────────────────────
# Every pre-existing case below asserted "some evidence exists". That is no
# longer sufficient on its own, so cases expecting a promotion seed all three
# platforms via this helper and the NEW cases pin the platform logic itself.
# The helper writes the shape the e2e skill really emits: identity in the
# filename, verdict+version on a heading, platform in the title.
seed_platform() { # seed_platform <platform> <version> [verdict]
    local plat="$1" ver="$2" verdict="${3:-PASS}"
    cat >"$WORK/root/plan/issues/smoke-e2e-findings-${ver}-2026-08-17-${plat}.md" <<EOF
# curl-install e2e — ${ver} on ${plat} — findings

## Run 2026-08-17T17:58Z — **${verdict}** (tag ${ver}, build commit 0bba6525f)
EOF
}
seed_all_platforms() { # seed_all_platforms <version>
    seed_platform linux "$1"; seed_platform macos "$1"; seed_platform windows "$1"
}

# 1. THE REGRESSION CASE: the exact shape the e2e skill writes. Words "smoke"
#    and "e2e" only in the filename; PASS and version on a heading together.
fresh_root
seed_all_platforms "$VER"
run_case "real e2e-skill evidence shape (was BROKEN)" '^would-promote:'

# 2. No evidence anywhere.
fresh_root
echo "nothing relevant here" >"$WORK/root/plan/issues/unrelated.md"
run_case "no evidence at all" '^refused:no-evidence:'

# 3. THE ONE THAT KEEPS THE FIX HONEST: right filename, FAIL verdict.
fresh_root
seed_platform linux "$VER"; seed_platform macos "$VER"
seed_platform windows "$VER" FAIL
run_case "correctly named file but FAIL verdict" '^refused:no-evidence:.*missing=windows'

# 4. A PASS, but for a different version.
fresh_root
cat >"$WORK/root/plan/issues/smoke-e2e-findings-v0.4.260810.1-2026-08-10.md" <<'EOF'
## Run 2026-08-10 — **PASS** (tag v0.4.260810.1)
EOF
run_case "PASS exists but for a different version" '^refused:no-evidence:'

# 5. Backward compatibility: the old single-line shape must still pass.
fresh_root
# The legacy shape is identity+verdict+version on ONE line. It is still
# accepted — but only inside a file that NAMES itself a report. 888-p3kt
# removed the old "any file under plan/" pass; see case 12 for why.
for _p in linux macos windows; do
    echo "curl-install e2e smoke PASS for 0.4.260817.1 on ${_p}" \
        >"$WORK/root/plan/issues/smoke-e2e-findings-legacy-${_p}.md"
done
run_case "legacy single-line evidence still accepted" '^would-promote:'

# 6. Dot-escaping. Unescaped, 0.4.260817.1 as a regex also matches
#    0X4X260817X1 — on a release gate, accidental permissiveness is the wrong
#    way to be wrong. Filename carries the literal version (glob dots are
#    literal); only the CONTENT is the near-miss.
fresh_root
seed_platform linux "$VER"; seed_platform macos "$VER"
cat >"$WORK/root/plan/issues/smoke-e2e-findings-windows-2026-08-17.md" <<'EOF'
# e2e findings on windows

## Run — **PASS** (tag v0X4X260817X1)
EOF
run_case "regex dots do not match arbitrary chars" '^refused:no-evidence:.*missing=windows'

# ---------------------------------------------------------------- 864-8tqv --
# 7-9. The dry-run's own grammar, and the demote path (864-mk2p).
fresh_root
seed_all_platforms "$VER"
run_case "flags parse in either order"        '^would-promote:' "$VER" --dry-run --force
run_case "bad tag refused before any gh call" '^refused:bad-tag:' "not-a-tag" --dry-run
run_case "demote dry-run names the restore"   '^would-demote:v0\.4\.260817\.1:latest-would-be:v0\.4\.260810\.1' \
         demote "$VER" --to v0.4.260810.1 --dry-run
run_case "demote without --to is refused"     '^refused:missing-target:' demote "$VER" --dry-run

# ═══ 888-p3kt: PER-PLATFORM EVIDENCE ═════════════════════════════════════════
# The gate used to ask "does SOME file assert a PASS for this version". Ship
# three platforms, accept one platform's word for all three. These cases pin
# the two halves the coordinator measured on 2026-08-25: platform-blindness,
# and the gate passing on incidental co-occurrence.

# 10. THE HEADLINE NEGATIVE CONTROL: one platform must NOT satisfy three.
#     Measured live: v0.4.260817.1 has exactly one conforming report (windows),
#     and the old gate promoted it anyway.
for _only in linux macos windows; do
    fresh_root
    seed_platform "$_only" "$VER"
    run_case "ONLY ${_only} passed -> refused, names the other two" \
             "^refused:no-evidence:.*missing="
done

# 11. Two of three is still not three — the off-by-one a "some evidence" gate
#     cannot express at all.
fresh_root
seed_platform linux "$VER"; seed_platform macos "$VER"
run_case "two of three platforms -> refused naming windows" \
         '^refused:no-evidence:.*missing=windows'

# 12. THE JUNK CONTROL. Both files that satisfied the old gate for
#     v0.4.260817.1 were bookkeeping, not reports:
#       - plan/index.yaml, whose packet body DESCRIBES this gate's own defect,
#         so "smoke" + "PASS" + the version co-occur while describing a BUG;
#       - a freshness-audit line in a loop_status entry.
#     Neither may count, even though both still contain the words. A ledger is
#     not a report.
fresh_root
mkdir -p "$WORK/root/plan/loop_status.d"
cat >"$WORK/root/plan/index.yaml" <<EOF
packets:
  - packet_id: describes-the-gate-defect
    summary: |
      the smoke evidence gate reported PASS for ${VER} on linux, macos and
      windows without checking any of them — see the incident
EOF
cat >"$WORK/root/plan/loop_status.d/20260823t215305z-x-lenovinha.md" <<EOF
## Cycle
freshness audit: scripts/run-smoke-e2e.sh litmus suite PASS ${VER} linux macos windows
EOF
run_case "ledger co-occurrence is NOT evidence (index.yaml + loop_status)" \
         '^refused:no-evidence:.*missing=linux,macos,windows'

# 13. A work-queue log line is not a report either — and this one is the
#     sharpest case in the suite. Measured on the real
#     plan/issues/windows-next-work-queue-2026-07.md, the removed second pass
#     accepted a line reading "run PASS end-to-end ... but promotion verdict
#     for the tag UNCHANGED (morning FAIL)". A line that says the promotion
#     verdict is FAIL was counting as promotion evidence.
fresh_root
seed_platform linux "$VER"; seed_platform macos "$VER"
cat >"$WORK/root/plan/issues/windows-next-work-queue-2026-07.md" <<EOF
- 2026-08-16T06:05Z FULL curl-install smoke ${VER} (windows): run PASS
  end-to-end — but promotion verdict for the tag UNCHANGED (morning FAIL).
EOF
run_case "work-queue log line is not a report (says FAIL, said PASS)" \
         '^refused:no-evidence:.*missing=windows'

# 14. PLATFORM DETECTION IS SCOPED, and this is the subtle one. The real
#     windows report contains the sentence "that lane is Linux/Podman per the
#     skill's §0.1". A whole-file grep for "linux" marks it as linux evidence
#     too — reproducing the incidental-co-occurrence bug one level down, now
#     deciding COVERAGE instead of existence. Platform is read from the
#     filename and the first heading only.
fresh_root
seed_platform macos "$VER"
cat >"$WORK/root/plan/issues/smoke-e2e-findings-${VER}-2026-08-17-windows.md" <<EOF
# curl-install e2e — ${VER} on Windows — findings

## Run 2026-08-17T17:58Z — **PASS** (tag ${VER})
Step 4 (the --opencode forge lane) is not run here — that lane is Linux/Podman
per the skill's §0.1.
EOF
run_case "body mentioning Linux does not make a windows report linux evidence" \
         '^refused:no-evidence:.*missing=linux'

# 15. --force STILL OVERRIDES, and is NOT weakened by any of the above. The
#     operator override is the pressure valve that keeps the gate from being
#     bypassed wholesale; a stricter gate without a working override is how
#     --no-verify culture starts.
fresh_root
seed_platform windows "$VER"
run_case "--force overrides incomplete per-platform evidence" \
         '^would-promote:' "$VER" --dry-run --force

# 16. ...and the override is LOUD: it must name the missing platforms on
#     stderr, so the record says what was overridden rather than merely that
#     something was.
fresh_root
seed_platform windows "$VER"
: > "$VIOLATIONS"
_force_err="$(PATH="$WORK/bin:$PATH" VIOLATIONS="$VIOLATIONS" \
    bash "$WORK/root/scripts/promote-stable.sh" "$VER" --dry-run --force 2>&1 >/dev/null)"
if printf '%s' "$_force_err" | grep -q 'missing platform(s): linux,macos'; then
    printf 'ok   %-52s -> names linux,macos\n' "--force warning names what was overridden"
    pass=$((pass + 1))
else
    printf 'FAIL %-52s -> %s\n' "--force warning names what was overridden" "$_force_err"
    fail=$((fail + 1))
fi

# 17. The disclaimer WARNING (coordinator ruling 2026-08-25: matcher counts a
#     PASS as a PASS; reading intent out of prose is a rule that rots — but the
#     operator must SEE it). Advisory, never a gate: the promotion still goes
#     through, and the report is named.
fresh_root
seed_all_platforms "$VER"
cat >"$WORK/root/plan/issues/smoke-e2e-findings-${VER}-2026-08-17-windows.md" <<EOF
# smoke — ${VER} — windows FULL lane re-run — PASS (run-scoped; does NOT clear promotion)

## Run 2026-08-17T17:58Z — **PASS** (tag ${VER})
EOF
: > "$VIOLATIONS"
_disc_out="$(PATH="$WORK/bin:$PATH" VIOLATIONS="$VIOLATIONS" \
    bash "$WORK/root/scripts/promote-stable.sh" "$VER" --dry-run 2>"$WORK/disc.err")"
_disc_err="$(cat "$WORK/disc.err")"
if printf '%s' "$_disc_out" | grep -q '^would-promote:' \
   && printf '%s' "$_disc_err" | grep -q 'disclaiming'; then
    printf 'ok   %-52s -> promoted + warned\n' "PASS-but-disclaimed counts, and warns loudly"
    pass=$((pass + 1))
else
    printf 'FAIL %-52s -> out=%s err=%s\n' "PASS-but-disclaimed counts, and warns loudly" \
        "$_disc_out" "$_disc_err"
    fail=$((fail + 1))
fi

# 18. NEGATIVE CONTROL for 17: a clean three-platform set must NOT emit the
#     disclaimer warning. A warning that fires on every run is one nobody reads.
fresh_root
seed_all_platforms "$VER"
: > "$VIOLATIONS"
PATH="$WORK/bin:$PATH" VIOLATIONS="$VIOLATIONS" \
    bash "$WORK/root/scripts/promote-stable.sh" "$VER" --dry-run >/dev/null 2>"$WORK/clean.err"
if grep -q 'disclaiming' "$WORK/clean.err"; then
    printf 'FAIL %-52s -> warned with nothing to warn about\n' "clean evidence does not warn"
    fail=$((fail + 1))
else
    printf 'ok   %-52s -> silent\n' "clean evidence does not warn"
    pass=$((pass + 1))
fi

# 19. The requirement set is configurable, so a future platform is a config
#     change rather than a rewrite — and so this suite can prove the mechanism
#     is genuinely driven by the list rather than hardcoded to three.
fresh_root
seed_platform linux "$VER"
: > "$VIOLATIONS"
_one_out="$(PATH="$WORK/bin:$PATH" VIOLATIONS="$VIOLATIONS" TILLANDSIAS_REQUIRED_PLATFORMS="linux" \
    bash "$WORK/root/scripts/promote-stable.sh" "$VER" --dry-run 2>/dev/null \
    | grep -E '^(would-promote|refused):' | tail -1)"
if printf '%s' "$_one_out" | grep -q '^would-promote:'; then
    printf 'ok   %-52s -> would-promote\n' "REQUIRED_PLATFORMS=linux is satisfied by linux"
    pass=$((pass + 1))
else
    printf 'FAIL %-52s -> %s\n' "REQUIRED_PLATFORMS=linux is satisfied by linux" "$_one_out"
    fail=$((fail + 1))
fi

# 20. The accept path NAMES the evidence it relied on. A PASS proves the run
#     completed, not that its preconditions held — a smoke that silently skips
#     its destruction step still reports a clean room. The gate does not verify
#     preconditions (a different, larger packet), but it must not be anonymous
#     about what it trusted.
#
#     This case once asserted the output cited 889-bx99. That packet was
#     FALSIFIED and withdrawn, so the assertion was removed rather than
#     re-pointed at a substitute: pinning a citation the gate does not need
#     would make a future correction fail this test for no reason.
fresh_root
seed_all_platforms "$VER"
: > "$VIOLATIONS"
PATH="$WORK/bin:$PATH" VIOLATIONS="$VIOLATIONS" \
    bash "$WORK/root/scripts/promote-stable.sh" "$VER" --dry-run >/dev/null 2>"$WORK/named.err"
_named=1
for _p in linux macos windows; do
    grep -qE "^  ${_p}[[:space:]]+plan/issues/.*${_p}" "$WORK/named.err" || _named=0
done
grep -q 'preconditions held' "$WORK/named.err" || _named=0
# NEGATIVE CONTROL: the gate's OUTPUT must not cite the retracted packet.
# Scoped to the output, not the source: the script's comments legitimately
# explain WHY 889-bx99 is not cited, and that explanation is what stops someone
# re-adding it. A control that forbade the word outright would delete its own
# reason for existing.
grep -q '889-bx99' "$WORK/named.err" && _named=0
if [ "$_named" = 1 ]; then
    printf 'ok   %-52s -> all three named + caveat\n' "accept path names the evidence per platform"
    pass=$((pass + 1))
else
    printf 'FAIL %-52s -> %s\n' "accept path names the evidence per platform" "$(tr '\n' '|' < "$WORK/named.err")"
    fail=$((fail + 1))
fi

# 21. NEGATIVE CONTROL for 20: a REFUSED promotion must not print an evidence
#     list, or the refusal reads as though something was accepted.
fresh_root
seed_platform linux "$VER"
: > "$VIOLATIONS"
PATH="$WORK/bin:$PATH" VIOLATIONS="$VIOLATIONS" \
    bash "$WORK/root/scripts/promote-stable.sh" "$VER" --dry-run >/dev/null 2>"$WORK/ref.err"
if grep -q 'Evidence satisfying this promotion' "$WORK/ref.err"; then
    printf 'FAIL %-52s -> listed evidence on a refusal\n' "refusal does not print an evidence list"
    fail=$((fail + 1))
else
    printf 'ok   %-52s -> silent\n' "refusal does not print an evidence list"
    pass=$((pass + 1))
fi

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
# The control must REACH the mutating code, so the evidence gate has to pass:
# seed all three platforms (888-p3kt). Before that, this seeded one unplatformed
# file, the per-platform gate refused, the script exited early and the tripwire
# never fired — which reported as "the tripwire cannot see writes" and would have
# been read as the harness being broken rather than the fixture being stale.
seed_all_platforms "$VER"
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
