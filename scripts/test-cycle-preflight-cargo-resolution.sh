#!/usr/bin/env bash
# @trace order:876-irn7
#
# test-cycle-preflight-cargo-resolution.sh — pin the 876-irn7 fix: a rustup
# toolchain that is not on the NON-INTERACTIVE PATH is not an absent toolchain.
#
# WHY THIS ARM AND NOT ANOTHER. `blocked:preflight:plan:cargo-absent` is the
# terminal verdict — the skill's own rule is that a `blocked:preflight:*` cycle
# must not start, "because the tool it would reason WITH is the stale thing".
# So a false positive here does not degrade a cycle, it deletes it, every fire,
# forever, on a host whose toolchain is fine. Measured on pirria 2026-08-25.
#
# Hermetic: a stub `cargo` in a scratch directory, PATH scrubbed of any real
# one, HOME and CARGO_HOME redirected into the scratch tree. Nothing compiles,
# nothing touches the real toolchain, and CYCLE_PREFLIGHT_SKIP_BUILD is NOT set
# — the arm under test lives on the build path.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="$ROOT/scripts/cycle-preflight.sh"
fail=0; pass=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/preflight-cargo-test.XXXXXX")"

# HERMETIC ON EVERY HOST — DERIVE THE SCRATCH PATH FROM THE TOOLS THE FIXTURE
# NEEDS, NEVER FROM A NAMED PAIR OF DIRECTORIES.
#
# This has now failed twice in opposite directions, both times from assuming a
# platform's tool set:
#   1. The absence arms dropped PATH to /usr/bin:/bin and called cargo absent.
#      On macuahuitl (Fedora 44) /usr/bin/cargo exists, so "absent" read
#      "found" and the mutation control read the same — four arms red the first
#      time this suite ran inside a gate (2026-09-05, the day 1005-m6rz bound
#      it).
#   2. Scrubbing to /usr/bin:/bin then made the 1005-m6rz identity arms
#      IMPOSSIBLE on Windows: git there is /mingw64/bin/git, outside the pair,
#      so the guard could not find git at all and answered
#      `blocked:not-a-git-repo` — never reaching the identity question the arms
#      exist to pin. Measured on esmeraldinha 2026-09-05, 3 arms red.
#
# Same defect in opposite coats: a hardcoded directory list is a guess about
# the host. The fix is not a better guess — it is to stop needing one, by
# giving each arm the SMALLEST PATH that expresses what it is actually testing.
#
# THE SOURCE DIRECTORIES ARE DERIVED FROM THE TOOLS, NOT NAMED. The fixture
# needs bash (env -i must resolve it by name) and git (the identity arms), so
# it mirrors the directories those two actually live in on THIS host and
# excludes exactly one thing: cargo. On Fedora that is /usr/bin; on MSYS it is
# /usr/bin plus /mingw64/bin. Nothing is hardcoded, so no host's layout is
# assumed.
#
# THREE REJECTED ALTERNATIVES, every one measured rather than reasoned about:
#   - a named pair (/usr/bin:/bin): on Fedora /usr/bin/cargo made "absent" read
#     "found" (4 arms red inside the gate, 2026-09-05); scrubbing to it then
#     made the identity arms IMPOSSIBLE on Windows, where git is
#     /mingw64/bin/git, so the guard answered `blocked:not-a-git-repo` and never
#     reached the identity question (3 arms red, esmeraldinha, same day). Same
#     defect in opposite coats.
#   - mirroring the host's WHOLE PATH minus cargo: FUNCTIONALLY CORRECT — the
#     scratch set it builds has cargo absent and git present, verified — but it
#     costs 6,628 symlinks here (Windows carries system32 and the WinGet dirs)
#     and takes about 25 MINUTES over drvfs with MSYS symlink emulation. It ran
#     past a 600 s timeout and completed in the background. That is longer than
#     the whole gate this fixture is bound into (~24 min), so it is rejected on
#     COST, not on correctness — a distinction worth keeping, because if drvfs
#     ever stops being the floor's regime this becomes the cleanest option.
#   - an empty PATH with bash copied in: `env -i PATH=... bash -c` needs bash by
#     name, and an MSYS bash.exe COPIED away from its directory cannot start —
#     it loads msys-2.0.dll from alongside itself. Symlinks resolve to the real
#     path and keep working; copies silently produce nothing at all (8 arms red,
#     no error text).
NOCARGO="$W/nopath"; mkdir -p "$NOCARGO"
for _t in bash git; do
    _p="$(command -v "$_t" 2>/dev/null)" || continue
    [ -n "$_p" ] || continue
    _d="$(cd "$(dirname "$_p")" && pwd)" || continue
    [ -d "$_d" ] || continue
    for _x in "$_d"/*; do
        _n="${_x##*/}"
        case "$_n" in cargo|cargo.exe) continue ;; esac
        [ -e "$NOCARGO/$_n" ] || ln -s "$_x" "$NOCARGO/$_n" 2>/dev/null || true
    done
done

trap 'rm -rf "$W"' EXIT INT TERM

# A stub cargo that satisfies `command -v` and makes the build step succeed
# cheaply. Its presence on PATH is the ONLY thing these arms vary.
make_cargo() { # make_cargo <dir>
    mkdir -p "$1"
    cat > "$1/cargo" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$1/cargo"
}

# Run the resolution arm in isolation. We re-execute just the block under test
# rather than the whole preflight, because the rest of the script rebuilds a
# real binary and refreshes a real inference endpoint — neither is hermetic and
# neither is what 876-irn7 changed.
resolve_arm() { # resolve_arm <extra-env...> ; echoes "found" | "absent"
    env -i PATH="$NOCARGO" HOME="$W/home" "$@" bash -c '
        if ! command -v cargo >/dev/null 2>&1; then
            for _cargo_dir in "${CARGO_HOME:-}/bin" "$HOME/.cargo/bin"; do
                case "$_cargo_dir" in /bin) continue ;; esac
                if [ -x "$_cargo_dir/cargo" ]; then
                    PATH="$_cargo_dir:$PATH"; export PATH; break
                fi
            done
        fi
        command -v cargo >/dev/null 2>&1 && echo found || echo absent
    '
}

# The block under test must be the one that SHIPS, not a copy that drifted.
# Extract it from the script and compare — a test that pins a paraphrase pins
# nothing.
if grep -q 'for _cargo_dir in "${CARGO_HOME:-}/bin" "$HOME/.cargo/bin"; do' "$PREFLIGHT"; then
    ok "the shipped preflight carries the resolution loop this suite pins"
else
    bad "cycle-preflight.sh no longer contains the loop under test — this suite is stale"
fi

# ── 1. THE MEASURED INCIDENT: rustup installed, ~/.cargo/bin off PATH. ──────
make_cargo "$W/home/.cargo/bin"
got="$(resolve_arm)"
[ "$got" = found ] && ok "rustup at ~/.cargo/bin resolves despite an empty PATH" \
    || bad "rustup at ~/.cargo/bin — want found, got $got"

# ── 2. CARGO_HOME is honoured, and honoured FIRST. A host that set it meant it.
make_cargo "$W/altcargo/bin"
got="$(resolve_arm CARGO_HOME="$W/altcargo")"
[ "$got" = found ] && ok "CARGO_HOME/bin resolves" \
    || bad "CARGO_HOME/bin — want found, got $got"

# ── 3. TRUE POSITIVE PRESERVED. This narrows a false positive; it must not
#      weaken the verdict that exists for a genuinely missing toolchain.
rm -rf "$W/home/.cargo" "$W/altcargo"
got="$(resolve_arm)"
[ "$got" = absent ] && ok "a genuinely absent cargo still reports absent" \
    || bad "absent toolchain — want absent, got $got"

# ── 4. An unset CARGO_HOME must not make the loop probe /bin. The naive form
#      "${CARGO_HOME:-}/bin" expands to exactly that, and /bin/cargo on some
#      host would be silently accepted as a CARGO_HOME hit.
mkdir -p "$W/fakebin"; make_cargo "$W/fakebin"
got="$(env -i PATH="$NOCARGO" HOME="$W/empty-home" bash -c '
    probed=""
    if ! command -v cargo >/dev/null 2>&1; then
        for _cargo_dir in "${CARGO_HOME:-}/bin" "$HOME/.cargo/bin"; do
            case "$_cargo_dir" in /bin) continue ;; esac
            probed="$probed $_cargo_dir"
        done
    fi
    echo "$probed"
')"
case "$got" in
    *" /bin"*) bad "an unset CARGO_HOME probes /bin — the guard clause is missing" ;;
    *) ok "an unset CARGO_HOME does not probe /bin" ;;
esac

# ── 5. MUTATION CONTROL: without the loop, arm 1 must fail. ────────────────
got="$(env -i PATH="$NOCARGO" HOME="$W/home" bash -c '
    command -v cargo >/dev/null 2>&1 && echo found || echo absent')"
make_cargo "$W/home/.cargo/bin"
got2="$(env -i PATH="$NOCARGO" HOME="$W/home" bash -c '
    command -v cargo >/dev/null 2>&1 && echo found || echo absent')"
[ "$got2" = absent ] \
    && ok "MUTATION: without the loop the same host reads absent — arm 1 has teeth" \
    || bad "mutation control did not reproduce the pre-fix behaviour (got $got2)"

# ══ ORDER 1005-m6rz ═══════════════════════════════════════════════════════
# Three arms the 876-irn7 suite did not carry: the git-identity preamble check,
# the cheatsheet-tiers cargo resolution, and the site registry that is supposed
# to stop the next one being found on a floor host.

# ── 6. IDENTITY: a host that cannot author a commit is refused BEFORE claiming.
#      Hermetic — a scratch repo with no identity reachable, which is what a
#      fresh or re-imaged host looks like. GIT_CONFIG_NOSYSTEM and an empty HOME
#      remove the global and system files; without both, the runner's own
#      identity leaks in and the arm passes for the wrong reason.
GUARD="$ROOT/scripts/check-committable-branch.sh"
mkdir -p "$W/norepo"
git init -q "$W/noident"
# HOST-REGIME NOTE. On pirria the hostname is `pirria.(none)` and git refuses
# to auto-detect an identity; on macuahuitl the hostname is a resolvable FQDN
# and git auto-detects one happily, so with nothing configured this arm read
# ok:branch-linux-next there. The guard's refusal path is what this arm pins,
# and git's own switch for "do not guess" is user.useConfigOnly: with it set,
# `git var GIT_AUTHOR_IDENT` fails exactly as a commit would on a host that
# cannot auto-detect, regardless of what the fixture host's hostname is.
( cd "$W/noident" && git config user.useConfigOnly true )
( cd "$W/noident" && git checkout -q -b linux-next 2>/dev/null || true )
got="$(cd "$W/noident" && env -i PATH="$NOCARGO" HOME="$W/empty-home" \
        GIT_CONFIG_NOSYSTEM=1 bash "$GUARD" 2>/dev/null)"
[ "$got" = "blocked:no-git-identity" ] \
    && ok "a host with no git identity is refused (blocked:no-git-identity)" \
    || bad "no-identity host — want blocked:no-git-identity, got: $got"

# The remedy must be PRINTED, not implied: the measured incident cost a whole
# cycle's work because the failure named no fix at the point it was hit.
remedy="$(cd "$W/noident" && env -i PATH="$NOCARGO" HOME="$W/empty-home" \
        GIT_CONFIG_NOSYSTEM=1 bash "$GUARD" 2>&1 >/dev/null)"
case "$remedy" in
    *"git config user.email"*) ok "the refusal names the exact git config remedy" ;;
    *) bad "the refusal does not name the remedy: $remedy" ;;
esac

# TRUE NEGATIVE: an identity present must NOT be refused, or the guard would
# stop every healthy host in the fleet.
( cd "$W/noident" && git config user.name t && git config user.email t@example.invalid )
got="$(cd "$W/noident" && env -i PATH="$NOCARGO" HOME="$W/empty-home" \
        GIT_CONFIG_NOSYSTEM=1 bash "$GUARD" 2>/dev/null)"
case "$got" in
    ok:branch-*) ok "an identity present passes the guard ($got)" ;;
    *) bad "identity present — want ok:branch-*, got: $got" ;;
esac

# ── 7. CHEATSHEET-TIERS resolves cargo, and SKIPS rather than printing a bare
#      command-not-found when it is genuinely absent.
if grep -q 'cargo_resolve' "$ROOT/scripts/check-cheatsheet-tiers.sh"; then
    ok "check-cheatsheet-tiers resolves cargo through the shared resolver"
else
    bad "check-cheatsheet-tiers still assumes cargo is on PATH"
fi
got="$(env -i PATH="$W/nothing:$NOCARGO" HOME="$W/empty-home" \
        bash "$ROOT/scripts/check-cheatsheet-tiers.sh" 2>&1 | head -1)"
case "$got" in
    skip:cheatsheet-tiers:cargo-absent*) ok "absent cargo reads as a SKIP, not an ERROR ($got)" ;;
    *"command not found"*) bad "still prints a bare command-not-found: $got" ;;
    *) ok "cheatsheet-tiers ran (cargo resolvable here): ${got:0:48}" ;;
esac

# ── 8. THE REGISTRY. Its entries must be real files, or the list that is
#      supposed to stop the next discovery is itself the next thing to discover.
. "$ROOT/scripts/lib-cargo-sites.sh"
missing=""
while IFS= read -r site; do
    [ -n "$site" ] || continue
    [ -e "$ROOT/$site" ] || missing="$missing $site"
done <<EOF
$(cargo_sites)
EOF
[ -z "$missing" ] && ok "every cargo-assumption site in the registry exists ($(cargo_sites | tr -d ' ' | grep -c .) listed)" \
    || bad "registry names files that do not exist:$missing"

# The three sites the packet names must all be listed — a registry that quietly
# dropped one would pass the existence arm above while losing the point.
for want in scripts/cycle-preflight.sh scripts/check-cheatsheet-tiers.sh scripts/host-capability-probe.sh; do
    cargo_sites | grep -qx "$want" \
        && ok "registry lists $want" \
        || bad "registry is missing $want"
done

# ══ ORDER 1004-ws5q (esmeraldinha) — merged beside 1005-m6rz's arms; renumbered 9–11 ═════
# ── ORDER 1004-ws5q ────────────────────────────────────────────────────────
# 876-irn7 narrowed WHEN cargo is called absent. This orders WHAT HAPPENS NEXT:
# a host with no compiler but a runnable instrument keeps its cycle, and only a
# host with neither is stopped. The arms below pin all three regimes.
#
# TILLANDSIAS_PLAN_BIN is the honest lever here: plan-binary-probe.sh honours the
# override on EXISTENCE ALONE (its own comment says probing it would collapse the
# stale-vs-absent distinction 704-zcgi preserves), so these arms vary exactly one
# thing — whether an instrument is resolvable — without compiling anything.
absent_cargo_arm() { # absent_cargo_arm <TILLANDSIAS_PLAN_BIN value> ; echoes verdict|blocked:...
    env -i PATH="$NOCARGO" HOME="$W/empty-home" ROOT="$ROOT" \
        TILLANDSIAS_PLAN_BIN="$1" bash -c '
        plan_verdict="skipped"
        if ! command -v cargo >/dev/null 2>&1; then
            . "$ROOT/scripts/plan-binary-probe.sh"
            if plan_bin="$(resolve_plan_binary)"; then
                plan_verdict="existing"
            else
                echo "blocked:preflight:plan:cargo-absent"; exit 1
            fi
        fi
        echo "$plan_verdict"
    '
}

# The block under test must be the one that SHIPS. Pin its two load-bearing
# halves: the probe is consulted, and the terminal verdict is inside the else.
if grep -q 'if plan_bin="$(resolve_plan_binary)"; then' "$PREFLIGHT" \
   && grep -q 'plan_verdict="existing"' "$PREFLIGHT"; then
    ok "the shipped preflight probes for a binary before declaring cargo absent"
else
    bad "cycle-preflight.sh no longer probes before the cargo-absent exit — this suite is stale"
fi

# ── 9. NO CARGO, BUT AN INSTRUMENT ON DISK. The measured pirria case: a
#      compile-free cycle must not lose its slot.
: > "$W/stub-plan"; chmod +x "$W/stub-plan"
got="$(absent_cargo_arm "$W/stub-plan")"
[ "$got" = existing ] && ok "no cargo + a runnable binary yields plan_verdict=existing, not a block" \
    || bad "no cargo + runnable binary — want existing, got $got"

# ── 10. TRUE POSITIVE PRESERVED, and this is the arm that matters most. No
#      compiler AND no instrument is a host that cannot reason; it must stop.
got="$(absent_cargo_arm "$W/nonexistent-plan-binary")"
case "$got" in
    blocked:preflight:plan:cargo-absent)
        ok "no cargo + no binary still blocks with cargo-absent — the terminal verdict is intact" ;;
    *)  bad "no cargo + no binary — want blocked:preflight:plan:cargo-absent, got $got" ;;
esac

# ── 11. CARGO PRESENT still yields the build path, not the probe path. The
#      third regime 1004-ws5q's exit criteria name: the fix must not divert a
#      host that CAN compile onto an instrument that happens to be lying around.
#      `existing` is for hosts with no compiler; a host with one still rebuilds.
#      PATH is the fixture's scrubbed $NOCARGO with a stub cargo PREPENDED, so
#      "present" is a property of this arm rather than of the host running it —
#      the same reason the absence arms use $NOCARGO.
make_cargo "$W/present-cargo"
: > "$W/stub-plan"; chmod +x "$W/stub-plan"
got="$(env -i PATH="$W/present-cargo:$NOCARGO" HOME="$W/empty-home" ROOT="$ROOT" \
    TILLANDSIAS_PLAN_BIN="$W/stub-plan" bash -c '
    plan_verdict="skipped"
    if ! command -v cargo >/dev/null 2>&1; then
        . "$ROOT/scripts/plan-binary-probe.sh"
        if plan_bin="$(resolve_plan_binary)"; then plan_verdict="existing"
        else echo "blocked:preflight:plan:cargo-absent"; exit 1; fi
    fi
    # cargo present: the real script builds here and sets rebuilt.
    [ "$plan_verdict" = skipped ] && echo "build-path" || echo "$plan_verdict"
')"
[ "$got" = build-path ] \
    && ok "cargo present takes the build path even with a resolvable binary — existing does not shadow rebuilt" \
    || bad "cargo present — want build-path, got $got"

# ── 12. MUTATION CONTROL: without the probe, arm 9's host blocks. If this ever
#      reports 'existing' the arm above has stopped testing anything.
got="$(env -i PATH="$NOCARGO" HOME="$W/empty-home" bash -c '
    if ! command -v cargo >/dev/null 2>&1; then
        echo "blocked:preflight:plan:cargo-absent"; exit 1
    fi
    echo rebuilt
')"
[ "$got" = "blocked:preflight:plan:cargo-absent" ] \
    && ok "MUTATION: without the probe the same host blocks — arm 6 has teeth" \
    || bad "mutation control did not reproduce the pre-fix behaviour (got $got)"

echo "test-cycle-preflight-cargo-resolution: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
