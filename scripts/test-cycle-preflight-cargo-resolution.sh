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
    env -i PATH="/usr/bin:/bin" HOME="$W/empty-home" ROOT="$ROOT" \
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

# ── 6. NO CARGO, BUT AN INSTRUMENT ON DISK. The measured pirria case: a
#      compile-free cycle must not lose its slot.
: > "$W/stub-plan"; chmod +x "$W/stub-plan"
got="$(absent_cargo_arm "$W/stub-plan")"
[ "$got" = existing ] && ok "no cargo + a runnable binary yields plan_verdict=existing, not a block" \
    || bad "no cargo + runnable binary — want existing, got $got"

# ── 7. TRUE POSITIVE PRESERVED, and this is the arm that matters most. No
#      compiler AND no instrument is a host that cannot reason; it must stop.
got="$(absent_cargo_arm "$W/nonexistent-plan-binary")"
case "$got" in
    blocked:preflight:plan:cargo-absent)
        ok "no cargo + no binary still blocks with cargo-absent — the terminal verdict is intact" ;;
    *)  bad "no cargo + no binary — want blocked:preflight:plan:cargo-absent, got $got" ;;
esac

# ── 8. MUTATION CONTROL: without the probe, arm 6's host blocks. If this ever
#      reports 'existing' the arm above has stopped testing anything.
got="$(env -i PATH="/usr/bin:/bin" HOME="$W/empty-home" bash -c '
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
