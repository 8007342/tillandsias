#!/usr/bin/env bash
# @trace spec:ci-release
#
# test-guest-binaries-nix-lane.sh — hermetic scenarios for order 790-mbk9:
# build-guest-binaries.sh's nix lane must test CAPABILITY, not presence, and
# must route through scripts/nix-toolbox.sh so a daemonless host uses the rung
# that works instead of a doomed bare `nix build`.
#
# WHAT THIS DOES AND DOES NOT COVER. Every scenario runs the REAL
# build-guest-binaries.sh inside a sandbox $ROOT with a stub `nix` on PATH that
# records its argv. The assertions are about ROUTING (which flags reached nix,
# which lane ran, what the operator was told) — not about the produced ELF,
# because verify_binaries legitimately demands statically linked musl binaries
# with a matching version stamp, and faking those would test the fake. The real
# artifact path is proven by an actual chroot-store build, cited in the packet's
# closure evidence.
#
# GRAMMAR (last line)
#   ok:guest-binaries-nix-lane-fixture:<n>
#   fail:guest-binaries-nix-lane-fixture:<failed scenario names>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TDIR="$(mktemp -d)"
trap "rm -rf '$TDIR'" EXIT

passed=0
failed=""

note_fail() { # <scenario> <detail>
    echo "FAIL: $1 — $2" >&2
    failed="$failed $1"
}
note_ok() { echo "ok: $1"; passed=$((passed + 1)); }

# Build a sandbox ROOT: the real script, a stub nix-toolbox, a stub nix and a
# stub cargo, all recording what they were asked to do.
#   $1 sandbox name
#   $2 nix-toolbox `ensure` stdout
#   $3 nix-toolbox `ensure` exit code
#   $4 nix-toolbox `nix-args` stdout (empty => the subcommand fails, as it does
#      for the toolbox rung)
#   $5 "workingnix" | "daemonlessnix" — whether the stub nix can build without
#      a --store argument (daemonlessnix reproduces this host: refuses unless
#      --store is present, exactly as a dead daemon socket does)
make_sandbox() {
    local name="$1" ensure_out="$2" ensure_rc="$3" args_out="$4" nixmode="$5"
    local sb="$TDIR/$name"
    mkdir -p "$sb/scripts" "$sb/bin"
    cp "$REAL_ROOT/scripts/build-guest-binaries.sh" "$sb/scripts/"
    printf '0.0.0\n' > "$sb/VERSION"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'case "${1:-ensure}" in\n'
        printf '  ensure) printf %%s\\\\n %s; exit %s ;;\n' "'$ensure_out'" "$ensure_rc"
        if [ -n "$args_out" ]; then
            printf '  nix-args) printf %%s\\\\n %s; exit 0 ;;\n' "'$args_out'"
        else
            printf '  nix-args) echo "blocked:nix-toolbox:toolbox" >&2; exit 1 ;;\n'
        fi
        printf 'esac\n'
    } > "$sb/scripts/nix-toolbox.sh"
    chmod +x "$sb/scripts/nix-toolbox.sh"

    # Stub nix: records argv, honours --out-link, and (in daemonlessnix mode)
    # refuses unless a --store argument routed it away from the dead daemon.
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$*" >> "%s/nix-argv.log"\n' "$sb"
        if [ "$nixmode" = "daemonlessnix" ]; then
            printf 'case "$*" in\n'
            printf '  *--store*) : ;;\n'
            printf '  *) echo "error: cannot connect to socket at '"'"'/nix/var/nix/daemon-socket/socket'"'"': Connection refused" >&2; exit 1 ;;\n'
            printf 'esac\n'
        fi
        printf 'link=""; store=""\n'
        printf 'while [ $# -gt 0 ]; do\n'
        printf '  if [ "$1" = "--out-link" ]; then link="$2"; fi\n'
        printf '  if [ "$1" = "--store" ]; then store="$2"; fi\n'
        printf '  shift\n'
        printf 'done\n'
        printf '[ -n "$link" ] || exit 0\n'
        if [ "$nixmode" = "danglingonly" ]; then
            # Build "succeeds" but produces no bytes anywhere — the negative
            # control for the store-root translation.
            printf 'ln -sfn "/nix/store/deadbeef-absent" "$link"\n'
        elif [ "$nixmode" = "chrootstore" ]; then
            # Reproduce the MEASURED chroot behaviour: the out-link is a symlink
            # to the LOGICAL store path (which dangles on this host) while the
            # bytes live under <store>/nix/store/... .
            printf 'logical="/nix/store/deadbeef-$(basename "$link")"\n'
            printf 'mkdir -p "$store$logical/bin"\n'
            printf 'printf "stub\\n" > "$store$logical/bin/tillandsias"\n'
            printf 'chmod +x "$store$logical/bin/tillandsias"\n'
            printf 'ln -sfn "$logical" "$link"\n'
        else
            printf 'mkdir -p "$link/bin"\n'
            printf 'printf "stub\\n" > "$link/bin/tillandsias"\n'
            printf 'chmod +x "$link/bin/tillandsias"\n'
        fi
    } > "$sb/bin/nix"
    chmod +x "$sb/bin/nix"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$*" >> "%s/cargo-argv.log"\n' "$sb"
        printf 'exit 1\n'
    } > "$sb/bin/cargo"
    chmod +x "$sb/bin/cargo"

    printf '%s\n' "$sb"
}

run_sandbox() { # <sandbox> ; prints combined output, returns the script's rc
    local sb="$1"
    PATH="$sb/bin:$PATH" bash "$sb/scripts/build-guest-binaries.sh" 2>&1
}

CHROOT_ARGS='--extra-experimental-features
nix-command flakes
--store
/tmp/fixture-store'
DAEMON_ARGS='--extra-experimental-features
nix-command flakes'

# ── 1. chroot rung: the --store flag must reach nix ─────────────────────────
sb="$(make_sandbox chroot 'ok:nix-toolbox:chroot' 0 "$CHROOT_ARGS" daemonlessnix)"
out="$(run_sandbox "$sb")"
if grep -q -- '--store /tmp/fixture-store' "$sb/nix-argv.log" 2>/dev/null; then
    note_ok "chroot-rung-passes-store-to-nix"
else
    note_fail "chroot-rung-passes-store-to-nix" "nix never saw --store; argv: $(cat "$sb/nix-argv.log" 2>/dev/null)"
fi
if printf '%s' "$out" | grep -q 'DEGRADED to the local Cargo fallback'; then
    note_fail "chroot-rung-does-not-degrade" "degraded despite a working chroot rung"
else
    note_ok "chroot-rung-does-not-degrade"
fi

# ── 2. MUTATION CONTROL: the pre-fix bare call on this same host ────────────
# A bare `nix build` (no --store) against the daemonless stub is exactly the
# 790-mbk9 defect. Proves scenario 1 is non-vacuous: the stub really does
# refuse the un-routed call.
if PATH="$sb/bin:$PATH" "$sb/bin/nix" build -L '.#x' --out-link "$TDIR/mutcheck" >/dev/null 2>&1; then
    note_fail "mutation-bare-nix-fails-daemonless" "the stub accepted a bare call, so scenario 1 proves nothing"
else
    note_ok "mutation-bare-nix-fails-daemonless"
fi

# ── 3. daemon rung: NOT diverted — no --store injected ──────────────────────
sb="$(make_sandbox daemon 'ok:nix-toolbox:daemon' 0 "$DAEMON_ARGS" workingnix)"
out="$(run_sandbox "$sb")"
if grep -q -- '--store' "$sb/nix-argv.log" 2>/dev/null; then
    note_fail "daemon-rung-not-diverted" "a --store argument was injected on a daemon host"
else
    note_ok "daemon-rung-not-diverted"
fi
if grep -q -- '--extra-experimental-features' "$sb/nix-argv.log" 2>/dev/null; then
    note_ok "daemon-rung-still-carries-feature-flags"
else
    note_fail "daemon-rung-still-carries-feature-flags" "argv: $(cat "$sb/nix-argv.log" 2>/dev/null)"
fi

# ── 4. no usable rung: named refusal, then a NAMED degradation ──────────────
sb="$(make_sandbox blocked 'blocked:nix-toolbox:no-nix-and-no-toolbox' 1 "$DAEMON_ARGS" workingnix)"
out="$(run_sandbox "$sb")"
if printf '%s' "$out" | grep -q 'nix lane UNAVAILABLE: blocked:nix-toolbox:no-nix-and-no-toolbox'; then
    note_ok "blocked-rung-names-the-verdict"
else
    note_fail "blocked-rung-names-the-verdict" "output: $out"
fi
if printf '%s' "$out" | grep -q 'DEGRADED to the local Cargo fallback'; then
    note_ok "blocked-rung-degrades-loudly-by-name"
else
    note_fail "blocked-rung-degrades-loudly-by-name" "the fallback was reached silently"
fi
if [ -s "$sb/cargo-argv.log" ]; then
    note_ok "blocked-rung-actually-reaches-cargo"
else
    note_fail "blocked-rung-actually-reaches-cargo" "cargo was never invoked"
fi
if [ -s "$sb/nix-argv.log" ]; then
    note_fail "blocked-rung-never-calls-nix" "nix was called despite no usable rung: $(cat "$sb/nix-argv.log")"
else
    note_ok "blocked-rung-never-calls-nix"
fi

# ── 5. toolbox rung: refused BY NAME, not silently attempted ────────────────
# nix-args serves no host-side flags for this rung, and the container's paths
# are not this checkout's — staging from here would be wrong.
sb="$(make_sandbox toolbox 'ok:nix-toolbox:toolbox' 0 '' workingnix)"
out="$(run_sandbox "$sb")"
if printf '%s' "$out" | grep -q 'serves no host-side store arguments'; then
    note_ok "toolbox-rung-refused-by-name"
else
    note_fail "toolbox-rung-refused-by-name" "output: $out"
fi
if [ -s "$sb/nix-argv.log" ]; then
    note_fail "toolbox-rung-does-not-guess" "nix was invoked with unverified container paths"
else
    note_ok "toolbox-rung-does-not-guess"
fi

# ── 6. chroot store: a DANGLING out-link is still staged correctly ──────────
# The measured shape (macuahuitl 2026-08-17): the link points at the logical
# /nix/store path, the bytes live under <store>/nix/store. Staging must follow
# the store root, not the dangling link.
CHROOT_STORE_ARGS='--extra-experimental-features
nix-command flakes
--store
'"$TDIR/fakestore"
sb="$(make_sandbox chrootstore 'ok:nix-toolbox:chroot' 0 "$CHROOT_STORE_ARGS" chrootstore)"
out="$(run_sandbox "$sb")"
if [ -f "$sb/target-guest/tillandsias-headless-x86_64-unknown-linux-musl" ] \
   && [ -f "$sb/target-guest/tillandsias-headless-aarch64-unknown-linux-musl" ]; then
    note_ok "chroot-dangling-out-link-is-staged-from-the-store-root"
else
    note_fail "chroot-dangling-out-link-is-staged-from-the-store-root" "nothing staged; output: $out"
fi
if printf '%s' "$out" | grep -q 'DEGRADED to the local Cargo fallback'; then
    note_fail "chroot-dangling-link-does-not-degrade" "degraded although the bytes were present in the store"
else
    note_ok "chroot-dangling-link-does-not-degrade"
fi

# ── 7. a genuinely absent artifact still fails LOUD ─────────────────────────
# Negative control for scenario 6: the translation must not invent a path. With
# a store root that holds nothing, staging must refuse rather than stage air.
sb="$(make_sandbox emptystore 'ok:nix-toolbox:chroot' 0 '--extra-experimental-features
nix-command flakes
--store
'"$TDIR/emptystore-root" danglingonly)"
out="$(run_sandbox "$sb")"
if printf '%s' "$out" | grep -q 'out-link does not resolve to a binary'; then
    note_ok "missing-artifact-fails-loud-not-silently"
else
    note_fail "missing-artifact-fails-loud-not-silently" "output: $out"
fi

# ── 8. the gate no longer trusts mere presence ──────────────────────────────
# Match EXECUTABLE lines only — the fix's own comment quotes the old gate, and
# a naive grep flags that (it did, on the first run of this fixture).
if grep -vE '^[[:space:]]*#' "$REAL_ROOT/scripts/build-guest-binaries.sh" | grep -q 'command -v nix'; then
    note_fail "gate-tests-capability-not-presence" "build_with_nix still gates on \`command -v nix\`"
else
    note_ok "gate-tests-capability-not-presence"
fi

if [ -n "$failed" ]; then
    echo "fail:guest-binaries-nix-lane-fixture:$failed"
    exit 1
fi
echo "ok:guest-binaries-nix-lane-fixture:$passed"
