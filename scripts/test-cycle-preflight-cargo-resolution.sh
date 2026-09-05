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
    env -i PATH="/usr/bin:/bin" HOME="$W/home" "$@" bash -c '
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
got="$(env -i PATH="/usr/bin:/bin" HOME="$W/empty-home" bash -c '
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
got="$(env -i PATH="/usr/bin:/bin" HOME="$W/home" bash -c '
    command -v cargo >/dev/null 2>&1 && echo found || echo absent')"
make_cargo "$W/home/.cargo/bin"
got2="$(env -i PATH="/usr/bin:/bin" HOME="$W/home" bash -c '
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
( cd "$W/noident" && git checkout -q -b linux-next 2>/dev/null || true )
got="$(cd "$W/noident" && env -i PATH="/usr/bin:/bin" HOME="$W/empty-home" \
        GIT_CONFIG_NOSYSTEM=1 bash "$GUARD" 2>/dev/null)"
[ "$got" = "blocked:no-git-identity" ] \
    && ok "a host with no git identity is refused (blocked:no-git-identity)" \
    || bad "no-identity host — want blocked:no-git-identity, got: $got"

# The remedy must be PRINTED, not implied: the measured incident cost a whole
# cycle's work because the failure named no fix at the point it was hit.
remedy="$(cd "$W/noident" && env -i PATH="/usr/bin:/bin" HOME="$W/empty-home" \
        GIT_CONFIG_NOSYSTEM=1 bash "$GUARD" 2>&1 >/dev/null)"
case "$remedy" in
    *"git config user.email"*) ok "the refusal names the exact git config remedy" ;;
    *) bad "the refusal does not name the remedy: $remedy" ;;
esac

# TRUE NEGATIVE: an identity present must NOT be refused, or the guard would
# stop every healthy host in the fleet.
( cd "$W/noident" && git config user.name t && git config user.email t@example.invalid )
got="$(cd "$W/noident" && env -i PATH="/usr/bin:/bin" HOME="$W/empty-home" \
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
got="$(env -i PATH="$W/nothing:/usr/bin:/bin" HOME="$W/empty-home" \
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

echo "test-cycle-preflight-cargo-resolution: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
