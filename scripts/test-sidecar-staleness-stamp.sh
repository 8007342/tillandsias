#!/usr/bin/env bash
# @trace spec:opencode-web-session-otp, spec:methodology-accountability
# @trace order:765-5efu
#
# Hermetic fixture for build-sidecar.sh's content-addressed staleness stamp.
#
# WHY A STUB CARGO RATHER THAN A REAL BUILD. The property under test is the
# staleness DECISION, not the compiler: whether the script invokes a build at
# all. A real musl build costs ~15s cold, which would make this fixture too
# expensive to run in the gate and would measure cargo's fingerprinting rather
# than ours. The stub records every invocation to a counter file, so each
# scenario asserts the exact thing that matters — "did this cost a build?" —
# in milliseconds.
#
# NON-VACUITY IS ENFORCED, not assumed (the discipline 765-8hc3 set): the
# build-expected scenarios assert the counter INCREMENTS. A stamp that made
# the script skip everything would pass the skip scenarios and fail these, and
# a script that never consulted the stamp would fail the skip scenarios. Both
# directions have to hold for the suite to be green.
#
# Run: scripts/test-sidecar-staleness-stamp.sh   (exit 0 = pass)
set -uo pipefail

ROOT_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap "rm -rf '$SANDBOX'" EXIT

fail=0
ok()   { echo "ok: $1"; }
bad()  { echo "FAIL: $1" >&2; fail=1; }

# ── Sandbox repo mirroring the real input set ───────────────────────────────
R="$SANDBOX/repo"
mkdir -p "$R/crates/tillandsias-router-sidecar/src" \
         "$R/crates/tillandsias-otp/src" \
         "$R/crates/tillandsias-control-wire/src" \
         "$R/images/router" \
         "$SANDBOX/bin"
printf 'fn main() {}\n'        > "$R/crates/tillandsias-router-sidecar/src/main.rs"
printf 'pub fn otp() {}\n'     > "$R/crates/tillandsias-otp/src/lib.rs"
printf 'pub fn wire() {}\n'    > "$R/crates/tillandsias-control-wire/src/lib.rs"
printf '[workspace]\n'         > "$R/Cargo.toml"
printf 'version = 4\n'         > "$R/Cargo.lock"
printf '0.4.260817.1\n'        > "$R/VERSION"
cp "$ROOT_REAL/scripts/build-sidecar.sh" "$R/scripts-build-sidecar.sh" 2>/dev/null || {
    echo "FAIL: cannot copy build-sidecar.sh" >&2; exit 1; }
mkdir -p "$R/scripts"
mv "$R/scripts-build-sidecar.sh" "$R/scripts/build-sidecar.sh"
chmod +x "$R/scripts/build-sidecar.sh"

COUNTER="$SANDBOX/cargo-invocations"
: > "$COUNTER"

# Stub cargo: records the invocation and emits an ELF-magic file where the
# script expects its output, so the real `file`-based ELF assert still runs.
# Writes BOTH candidate output paths — with and without the target-triple
# subdirectory — so the fixture is agnostic to whether the host has the musl
# target installed (which decides the script's USE_TARGET branch, and would
# otherwise make this fixture pass or fail on host toolchain state rather than
# on the behaviour under test).
cat > "$SANDBOX/bin/cargo" <<'STUB'
#!/usr/bin/env bash
echo "build" >> "$CARGO_INVOCATION_COUNTER"
payload="${STUB_CARGO_PAYLOAD:-default}"
# The stub ELF must carry a REAL e_machine for the host: 723-ji4v made the
# script refuse wrong-arch artifacts at staging via `file -b`, and the old
# magic-only header (no machine bytes) reads as arch-less — so every stage
# was refused, no stamp was written, and all seven skip/stage scenarios went
# red while the counter kept climbing. The header below is the minimal
# 64-bit LSB executable `file` names by architecture (e_machine 0x3E x86-64
# / 0xB7 aarch64).
case "$(uname -m)" in
    arm64|aarch64) _em='\267' ;;
    *)             _em='\076' ;;
esac
for out in \
    "${CARGO_TARGET_DIR}/release/tillandsias-router-sidecar" \
    "${CARGO_TARGET_DIR}/x86_64-unknown-linux-musl/release/tillandsias-router-sidecar" \
    "${CARGO_TARGET_DIR}/aarch64-unknown-linux-musl/release/tillandsias-router-sidecar"; do
    mkdir -p "$(dirname "$out")"
    printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000'"$_em"'\000\001\000\000\000stub-sidecar-%s\n' "$payload" > "$out"
done
exit 0
STUB
chmod +x "$SANDBOX/bin/cargo"
# No rustup in PATH -> the script takes its documented host-target fallback,
# which keeps the stub's output path predictable.
cat > "$SANDBOX/bin/strip" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$SANDBOX/bin/strip"

builds() { wc -l < "$COUNTER" | tr -d ' '; }

run_sidecar() {
    ( cd "$R" && PATH="$SANDBOX/bin:$PATH" \
        CARGO_INVOCATION_COUNTER="$COUNTER" \
        bash "$R/scripts/build-sidecar.sh" >/dev/null 2>&1 )
}

expect_build() { # <label> <before>
    local label="$1" before="$2" after
    after="$(builds)"
    if [ "$after" -gt "$before" ]; then ok "$label"; else
        bad "$label — expected a build, counter stayed at $after"; fi
}
expect_skip() { # <label> <before>
    local label="$1" before="$2" after
    after="$(builds)"
    if [ "$after" -eq "$before" ]; then ok "$label"; else
        bad "$label — expected NO build, counter went $before -> $after"; fi
}

STAMP="$R/images/router/.sidecar.stamp"
DEST="$R/images/router/tillandsias-router-sidecar"

# 1. Cold: nothing staged -> must build, and must leave a stamp.
b="$(builds)"; run_sidecar; expect_build "cold build with nothing staged" "$b"
[ -f "$DEST" ]  || bad "cold build did not stage a binary"
[ -f "$STAMP" ] || bad "cold build did not write the evaluation stamp"
grep -q '^inputs=' "$STAMP" 2>/dev/null || bad "stamp carries no inputs= digest"
grep -q '^output=' "$STAMP" 2>/dev/null || bad "stamp carries no output= digest"

# 2. Unchanged inputs -> skip.
b="$(builds)"; run_sidecar; expect_skip "unchanged inputs skip the build" "$b"

# 3. THE PACKET'S CASE: mtime churn with identical content -> skip.
#    A git merge/checkout rewrites mtimes on byte-identical files; the old
#    `find -newer` probe rebuilt for that alone.
touch "$R/crates/tillandsias-router-sidecar/src/main.rs" "$R/Cargo.lock" \
      "$R/Cargo.toml" "$R/VERSION" "$R/crates/tillandsias-otp/src/lib.rs"
b="$(builds)"; run_sidecar; expect_skip "mtime churn on identical content skips the build" "$b"

# 4. NEGATIVE: a real content change must rebuild.
printf 'fn main() { /* changed */ }\n' > "$R/crates/tillandsias-router-sidecar/src/main.rs"
b="$(builds)"; run_sidecar; expect_build "a real source change rebuilds" "$b"

# 5. NEGATIVE: VERSION content change must rebuild (710-w9kc version-matching).
printf '0.4.260817.2\n' > "$R/VERSION"
b="$(builds)"; run_sidecar; expect_build "a VERSION bump rebuilds" "$b"

# 6. NEGATIVE: a file ADDED to the input set must rebuild (set change, not just
#    content) — the manifest covers paths, so this cannot slip through.
printf 'pub fn extra() {}\n' > "$R/crates/tillandsias-otp/src/extra.rs"
b="$(builds)"; run_sidecar; expect_build "a new source file rebuilds" "$b"

# 7. STRICT IMPROVEMENT over the mtime probe: a tampered/wrong staged artifact
#    must not be trusted. mtime says nothing about WHICH bytes are staged, so
#    the old probe served this as up-to-date (the hazard 723-b9cn named).
printf 'TAMPERED' >> "$DEST"
b="$(builds)"; run_sidecar; expect_build "a tampered staged artifact is rebuilt, not trusted" "$b"

# 8. A missing stamp must rebuild (fresh checkout / CI / release lane).
rm -f "$STAMP"
b="$(builds)"; run_sidecar; expect_build "a missing stamp rebuilds" "$b"

# 9. A truncated/garbage stamp must rebuild, never be half-trusted.
printf 'inputs=\n' > "$STAMP"
b="$(builds)"; run_sidecar; expect_build "an unreadable stamp rebuilds" "$b"

# 10. The operator override forces a rebuild even when everything matches.
b="$(builds)"
( cd "$R" && PATH="$SANDBOX/bin:$PATH" CARGO_INVOCATION_COUNTER="$COUNTER" \
    TILLANDSIAS_SIDECAR_FORCE_REBUILD=1 bash "$R/scripts/build-sidecar.sh" >/dev/null 2>&1 )
expect_build "TILLANDSIAS_SIDECAR_FORCE_REBUILD=1 bypasses the stamp" "$b"

# 11. …and with the override unset again, the very next run skips — proving 10
#     forced the build rather than the tree simply being dirty.
b="$(builds)"; run_sidecar; expect_skip "the run after a forced rebuild skips again" "$b"

if [ "$fail" -eq 0 ]; then
    echo "ok:sidecar-staleness-stamp-fixture:11"
    exit 0
fi
echo "fail: sidecar-staleness-stamp fixture scenarios failed" >&2
exit 1
