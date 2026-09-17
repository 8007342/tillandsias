#!/usr/bin/env bash
# freshness: added by yoga (order 1118-zvai)
# @trace order:1118-zvai, order:972-a8vh, spec:enclave-network
#
# test-enclave-network-internal-discovery.sh — does the enclave guard's
# repo-wide discovery find the launchers it must, and stay silent about the
# ones it must not?
#
# ── REGIME ───────────────────────────────────────────────────────────────────
# HERMETIC. Every case builds a throwaway git repository under a mktemp -d and
# runs the guard in `source` mode against it. Nothing reads or writes the real
# checkout, nothing calls podman, and no case depends on this host's deployed
# network — the deployed half is host state and is not what this fixture is
# about. No absolute timestamp appears anywhere in here: the fixture asserts a
# property of the guard, and a property does not expire on a date.
#
# ── WHY THESE CASES ──────────────────────────────────────────────────────────
# The guard replaced a HARDCODED three-file list with a sweep. A sweep fails in
# the opposite direction from a list: a list misses things (which is how
# run-forge-project.sh and diagnose-proxy.sh created the enclave network with
# NAT egress while the check was green), and a sweep ACCUSES things. Both
# directions are tested here, and the accusation cases are the ones that took
# real work — widening the Rust arm to the tree named four tillandsias-logging
# files whose only sin was the word "network" in a log field.
#
# A guard that only ever proves it can say "drift" is half tested.

set -u

GUARD="$(cd "$(dirname "$0")" && pwd)/check-enclave-network-internal.sh"
[ -r "$GUARD" ] || { echo "FAIL: guard not found at $GUARD"; exit 1; }

pass=0; fail=0
_ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
_bad() { fail=$((fail+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }

# Build a throwaway repo. Every case gets a fresh one so no case can pass on
# another's leftovers.
_mkrepo() {
    d="$(mktemp -d)"
    mkdir -p "$d/scripts" "$d/crates/x/src"
    # The sweep lists *.sh and *.rs, so each repo needs at least one of each or
    # the guard's own empty-discovery refusal fires and every case reports
    # `unavailable` — which would look like a pass to a test that only checks
    # for absence of drift.
    printf '#!/usr/bin/env bash\necho placeholder\n' > "$d/scripts/placeholder.sh"
    printf 'fn placeholder() {}\n' > "$d/crates/x/src/placeholder.rs"
    git -C "$d" init -q 2>/dev/null
    git -C "$d" add -A 2>/dev/null
    printf '%s\n' "$d"
}

# Run the guard inside a prepared repo and echo its single verdict line.
_verdict() {
    ( cd "$1" && bash "$GUARD" source 2>&1 | tail -1 )
}
_rc() {
    ( cd "$1" && bash "$GUARD" source >/dev/null 2>&1; echo $? )
}

# ── 1. MUST CATCH: a shell launcher that creates the enclave net unisolated ──
d="$(_mkrepo)"
# THE VERB IS ASSEMBLED, NOT WRITTEN LITERALLY, and that is not a trick to
# duck the guard — it is the only honest way to say what this line is. A
# repo-wide sweep reads THIS fixture too, and a literal unisolated create call
# in here is indistinguishable, to any matcher, from a real launcher: the guard
# refused its own fixture on the first gate after the sweep landed. The
# offending string is test DATA that must exist in the temp repo and must not
# exist as an invocation in the tree. Building it at runtime says exactly that.
# An exemption marker was tried first and was worse: the marker would have had
# to travel into the generated file, where it would have suppressed the very
# drift case 1 asserts.
{
    printf '#!/usr/bin/env bash\n'
    printf 'ENCLAVE_NET="tillandsias-enclave"\n'
    printf 'podman network %s --driver bridge --subnet "10.0.42.0/24" "$ENCLAVE_NET"\n' create
} > "$d/scripts/bad-launcher.sh"
git -C "$d" add -A 2>/dev/null
v="$(_verdict "$d")"
case "$v" in
    drift:launcher-omits-internal:*bad-launcher.sh*) _ok "1 names an unisolated shell launcher" ;;
    *) _bad "1 names an unisolated shell launcher" "drift naming bad-launcher.sh" "$v" ;;
esac
[ "$(_rc "$d")" = "1" ] || _bad "1 exits 1 on drift" "1" "$(_rc "$d")"
rm -rf "$d"

# ── 2. MUST NOT ACCUSE: the same launcher, compliant ─────────────────────────
d="$(_mkrepo)"
cat > "$d/scripts/good-launcher.sh" <<'EOF'
#!/usr/bin/env bash
ENCLAVE_NET="tillandsias-enclave"
podman network create --driver bridge --internal --subnet "10.0.42.0/24" "$ENCLAVE_NET"
EOF
git -C "$d" add -A 2>/dev/null
v="$(_verdict "$d")"
case "$v" in
    ok:enclave-network-internal:source*) _ok "2 a compliant launcher is clean" ;;
    *) _bad "2 a compliant launcher is clean" "ok:…:source" "$v" ;;
esac
rm -rf "$d"

# ── 3. MUST NOT ACCUSE: a compliant create split across continuations ────────
# The flag is on a different physical line from the verb. An unfolded matcher
# reports drift here, and a dialect-specific fold (the GNU-only sed label form
# this guard used to carry) emits nothing at all on BSD and reports drift for
# the opposite reason.
d="$(_mkrepo)"
cat > "$d/scripts/multiline.sh" <<'EOF'
#!/usr/bin/env bash
ENCLAVE_NET="tillandsias-enclave"
podman network create \
    --driver bridge \
    --internal \
    --subnet "10.0.42.0/24" \
    "$ENCLAVE_NET"
EOF
git -C "$d" add -A 2>/dev/null
v="$(_verdict "$d")"
case "$v" in
    ok:*) _ok "3 a folded multi-line compliant create is clean" ;;
    *) _bad "3 a folded multi-line compliant create is clean" "ok:…" "$v" ;;
esac
rm -rf "$d"

# ── 4. MUST NOT ACCUSE: a COMMENT quoting a non-compliant example ────────────
# Documentation inside a script is not an invocation. This is the shape that
# makes a guard accuse the file that explains it.
d="$(_mkrepo)"
cat > "$d/scripts/commented.sh" <<'EOF'
#!/usr/bin/env bash
# Historically this said:
#     podman network create tillandsias-enclave
# which was wrong; it now reads:
podman network create --internal tillandsias-enclave
EOF
git -C "$d" add -A 2>/dev/null
v="$(_verdict "$d")"
case "$v" in
    ok:*) _ok "4 a commented-out bad example is not an offence" ;;
    *) _bad "4 a commented-out bad example is not an offence" "ok:…" "$v" ;;
esac
rm -rf "$d"

# ── 5. MUST NOT ACCUSE: the verb as DATA, with no podman on the line ─────────
# scripts/test-podman-mock-refusal.sh iterates over "network create
# tillandsias-enclave" as a string. It creates nothing.
d="$(_mkrepo)"
cat > "$d/scripts/data.sh" <<'EOF'
#!/usr/bin/env bash
for verb in "network create tillandsias-enclave" "compose up -d"; do
    echo "$verb"
done
EOF
git -C "$d" add -A 2>/dev/null
v="$(_verdict "$d")"
case "$v" in
    ok:*) _ok "5 the verb as a data string is not an invocation" ;;
    *) _bad "5 the verb as a data string is not an invocation" "ok:…" "$v" ;;
esac
rm -rf "$d"

# ── 6. MUST NOT ACCUSE: a non-enclave network created without --internal ─────
# Unknown callers go silent, not wrong. A network this repository does not
# claim to isolate is not this guard's business, and guessing at it is how a
# guard earns the reputation that gets it skipped.
d="$(_mkrepo)"
cat > "$d/scripts/other-net.sh" <<'EOF'
#!/usr/bin/env bash
podman network create --driver bridge some-unrelated-testing-net
EOF
git -C "$d" add -A 2>/dev/null
v="$(_verdict "$d")"
case "$v" in
    ok:*) _ok "6 an unrelated network is out of scope, not an offence" ;;
    *) _bad "6 an unrelated network is out of scope, not an offence" "ok:…" "$v" ;;
esac
rm -rf "$d"

# ── 7. MUST CATCH: a Rust arg-builder with no --internal ─────────────────────
d="$(_mkrepo)"
cat > "$d/crates/x/src/net.rs" <<'EOF'
fn args() -> Vec<String> {
    vec!["network".into(), "create".into(), "tillandsias-enclave".into()]
}
EOF
git -C "$d" add -A 2>/dev/null
v="$(_verdict "$d")"
case "$v" in
    drift:launcher-omits-internal:*net.rs*) _ok "7 names a Rust arg-builder missing the flag" ;;
    *) _bad "7 names a Rust arg-builder missing the flag" "drift naming net.rs" "$v" ;;
esac
rm -rf "$d"

# ── 8. MUST NOT ACCUSE: Rust prose that merely says "network" ────────────────
# THE REGRESSION THIS CASE EXISTS FOR. The first repo-wide draft tested for the
# quoted literal "network" alone and accused four tillandsias-logging files
# whose only sin is a log field name. A matcher that was safe against a
# hand-picked list of three podman files was false the moment its radius grew,
# and nothing about the matcher changed — only what it was pointed at.
d="$(_mkrepo)"
cat > "$d/crates/x/src/logging.rs" <<'EOF'
fn emit() {
    let field = "network";
    log(field, "network created");
}
EOF
git -C "$d" add -A 2>/dev/null
v="$(_verdict "$d")"
case "$v" in
    ok:*) _ok "8 a log field named network is not an arg-builder" ;;
    *) _bad "8 a log field named network is not an arg-builder" "ok:…" "$v" ;;
esac
rm -rf "$d"

# ── 9. AN EMPTY SWEEP IS A REFUSAL, NOT A PASS ───────────────────────────────
# A lister that returns nothing looks exactly like a repository with nothing
# wrong. The guard must refuse instead of reporting ok, or every later failure
# of discovery reads as a clean tree.
d="$(mktemp -d)"
git -C "$d" init -q 2>/dev/null
v="$( cd "$d" && bash "$GUARD" source 2>&1 | tail -1 )"
rc="$( cd "$d" && bash "$GUARD" source >/dev/null 2>&1; echo $? )"
case "$v" in
    unavailable:source-discovery-empty-*) _ok "9 an empty sweep refuses rather than passing" ;;
    *) _bad "9 an empty sweep refuses rather than passing" "unavailable:source-discovery-empty-…" "$v" ;;
esac
[ "$rc" = "2" ] || _bad "9 an empty sweep exits 2" "2" "$rc"
rm -rf "$d"

# ── 10. THE VERDICT CARRIES ITS OWN SCOPE ────────────────────────────────────
# An `ok:` with no scope cannot be distinguished from an `ok:` over four files.
d="$(_mkrepo)"
v="$(_verdict "$d")"
case "$v" in
    *"rust=file-scoped"*declined=docs*) _ok "10 the ok verdict declares its sweep and its limits" ;;
    *) _bad "10 the ok verdict declares its sweep and its limits" "scope carrying rust=file-scoped,declined=docs" "$v" ;;
esac
rm -rf "$d"

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf 'PASS: enclave network discovery (%d/%d)\n' "$pass" "$pass"
    exit 0
fi
printf 'FAIL: enclave network discovery (%d passed, %d failed)\n' "$pass" "$fail"
exit 1
