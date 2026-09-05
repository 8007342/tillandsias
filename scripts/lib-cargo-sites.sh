#!/usr/bin/env bash
# ORDER 1005-m6rz. THE ONE PLACE THE CARGO ASSUMPTION IS WRITTEN DOWN.
#
# Four scripts have independently assumed `cargo` is on the non-interactive
# PATH. Each was found on the floor, one at a time, by a host where it was not:
#
#   scripts/cycle-preflight.sh          876-irn7. Declared cargo-absent on a host
#                                       carrying cargo 1.98.0, because rustup
#                                       writes its PATH edit into ~/.bashrc and
#                                       no agent tool call is a login shell.
#                                       CANONICAL: it carries the resolution loop
#                                       inline and is pinned by
#                                       test-cycle-preflight-cargo-resolution.sh.
#   scripts/check-cheatsheet-tiers.sh   1005-m6rz. Printed a bare
#                                       `cargo: command not found` as a
#                                       validation ERROR on the commit hook.
#   scripts/host-capability-probe.sh    1005-m6rz. Refuses without a runnable
#                                       tillandsias binary, so a cargo-less host
#                                       cannot publish its capability row.
#   build.sh (gate)                     Refuses at the container boundary before
#                                       reaching a compiler at all; see the
#                                       toolbox note below.
#
# ADD TO THIS LIST WHEN YOU FIND THE NEXT ONE. That is the whole point: the
# packet's exit criterion is that the next site is added here rather than
# discovered on a floor host mid-cycle, and a list nobody has to touch to add a
# site is a list that goes stale. `cargo_sites` below is consumed by the fixture,
# so an entry that stops being true fails a test rather than misleading a reader.
#
# WHY THIS IS A LIBRARY AND NOT A COMMENT BLOCK. A doc listing four scripts is
# advisory; a shared resolver those scripts CALL is load-bearing. Sourcing this
# gets a site the same resolution cycle-preflight has, so "add the next site"
# means "call cargo_resolve" rather than "copy nine lines and hope".
#
# CYCLE-PREFLIGHT DELIBERATELY DOES NOT SOURCE THIS. Its loop is pinned by a
# fixture that greps the shipped script for the literal loop
# (test-cycle-preflight-cargo-resolution.sh), because 876-irn7's lesson was that
# a test pinning a paraphrase pins nothing. Refactoring it to call this would
# delete that pin to save nine lines. The duplication is the price of the pin
# and is recorded here so it reads as a decision rather than an oversight.
#
# A TOOLCHAIN IN A TOOLBOX IS NOT ON THE HOST. On a host whose gate re-execs
# into a container (Silverblue, CachyOS with tillandsias-builder, Windows with
# the WSL2 distro), a host-side `cargo` and the gate's `cargo` are different
# programs, and a host-built binary may not even RUN in the container: measured
# on pirria 2026-09-05, a host-built tillandsias-plan gave
# `/lib64/libm.so.6: version 'GLIBC_2.44' not found` inside fedora-toolbox:42.
# So resolving cargo here answers "can THIS process compile", never "is the gate
# able to run".

# cargo_resolve — put a resolvable cargo on PATH for the REST OF THIS PROCESS.
# Same order and same guards as cycle-preflight.sh: CARGO_HOME first (a host that
# set it meant it), then the rustup default. Returns 0 if cargo is usable
# afterwards, 1 if it is genuinely absent — which is a real verdict, not a
# fallback to guess around.
cargo_resolve() {
    if command -v cargo >/dev/null 2>&1; then
        return 0
    fi
    local _cargo_dir
    for _cargo_dir in "${CARGO_HOME:-}/bin" "$HOME/.cargo/bin"; do
        # An unset CARGO_HOME expands to exactly "/bin"; probing it would accept
        # some unrelated /bin/cargo as a CARGO_HOME hit.
        case "$_cargo_dir" in /bin) continue ;; esac
        if [ -x "$_cargo_dir/cargo" ]; then
            PATH="$_cargo_dir:$PATH"
            export PATH
            return 0
        fi
    done
    return 1
}

# cargo_sites — the registry above, one path per line, for the fixture and for
# anyone asking "where else does this assumption live".
cargo_sites() {
    cat <<'SITES'
scripts/cycle-preflight.sh
scripts/check-cheatsheet-tiers.sh
scripts/host-capability-probe.sh
build.sh
SITES
}

# Standalone: `scripts/lib-cargo-sites.sh sites` prints the registry.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-sites}" in
        sites) cargo_sites ;;
        resolve) cargo_resolve && command -v cargo || { echo "absent:cargo"; exit 1; } ;;
        *) echo "usage: $0 sites|resolve" >&2; exit 2 ;;
    esac
fi
