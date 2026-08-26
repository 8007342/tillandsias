#!/usr/bin/env bash
# @trace order:723-whrx, spec:dev-build
set -uo pipefail

# Fixture for build.sh's macOS install refusal and --init build ordering
# (order 723-whrx).
#
# WHAT WAS BROKEN. `grep -niE 'darwin|uname|OSTYPE'` over build.sh matched
# NOTHING — it had no host branch at all. On macOS `--install` therefore built
# an x86_64 Linux musl launcher and tried to EXECUTE it, while the readiness
# guard reported the host as ready. `--ci-full --install` is the phased gate the
# release and meta-orchestration runbooks treat as the strong evidence path, so
# on macOS that path was not merely unsupported, it was unsupported SILENTLY —
# which is what lets a "builds from scratch on macOS" claim get made. Separately
# `--init` executed target/debug/tillandsias without ever building it, so from a
# clean tree it failed on ANY platform, and only AFTER require_podman had run
# and _bump_build_version had dirtied VERSION.
#
# PLACEMENT IS THE PROPERTY, for both halves, which is why the ordering
# assertions below matter more than the message ones:
#   * the install refusal must precede _bump_build_version, _check_trace_coverage
#     and _prepare_ci_full_install_inputs, or it still dirties VERSION and
#     build.sh then tells the operator not to commit the dirt it just made;
#   * the --init binary build must precede require_podman and
#     _bump_build_version, or a missing artifact still reports as a podman
#     problem and still leaves a dirty tree.
#
# PLATFORM SCOPE, stated because it constrains what this can assert: the
# behavioural arm runs ONLY on Darwin. Invoking `./build.sh --install` on Linux
# would start a real install, so on every other host this falls back to source
# ordering. That is a real limit, not a formality — the negative control "the
# refusal does NOT fire on Linux" is asserted structurally (the guard is
# conjoined with a Darwin test) rather than by running it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build.sh"
fail=0

check() {
    if [ "$2" = "0" ]; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi
}

[ -f "$BUILD" ] || { echo "FAIL: no build.sh at $BUILD"; exit 1; }
bash -n "$BUILD"; check "build-sh-parses" "$?"

# ── Source ordering: the properties that survive on every host ───────────────
src="$(cat "$BUILD")"

line_of() { grep -n -- "$1" "$BUILD" | head -1 | cut -d: -f1; }

refusal_line="$(line_of 'Error: --install is not supported on macOS.')"
[ -n "$refusal_line" ]; check "darwin-install-refusal-exists" "$?"

# It must be conjoined with a Darwin test — otherwise it would fire on Linux,
# which is the one regression that would break every other host in the fleet.
guard_line="$(line_of 'uname -s.*Darwin.*FLAG_INSTALL')"
[ -n "$guard_line" ]; check "refusal-is-gated-on-darwin-AND-install" "$?"

# ORDERING 1: the refusal precedes every install-path mutation.
bump_first="$(grep -n '^    _bump_build_version' "$BUILD" | head -1 | cut -d: -f1)"
prep_line="$(grep -n '^_prepare_ci_full_install_inputs()' "$BUILD" | head -1 | cut -d: -f1)"
if [ -n "$refusal_line" ] && [ -n "$bump_first" ] && [ "$refusal_line" -lt "$bump_first" ]; then
    check "refusal-precedes-the-first-version-bump" 0
else
    echo "FAIL: refusal-precedes-the-first-version-bump (refusal=$refusal_line bump=$bump_first)"
    fail=1
fi
if [ -n "$refusal_line" ] && [ -n "$prep_line" ] && [ "$refusal_line" -lt "$prep_line" ]; then
    check "refusal-precedes-ci-full-install-prep" 0
else
    echo "FAIL: refusal-precedes-ci-full-install-prep (refusal=$refusal_line prep=$prep_line)"
    fail=1
fi

# The message must name the macOS path, or the refusal strands the operator.
grep -qF 'scripts/build-macos-tray.sh' "$BUILD"
check "refusal-names-the-macos-build-script" "$?"

# ORDERING 2: --init builds before the podman gate and the version bump.
#
# COMMENTS ARE STRIPPED FIRST, and that is not incidental tidiness. The first
# draft of this fixture matched its own explanatory comment inside the --init
# block — which mentions require_podman and _bump_build_version while describing
# the bug — and reported the ordering as broken while the behavioural arm passed.
# A source-shape assertion that cannot tell code from prose about code is worse
# than none: it fails on correct code and would pass on a block whose only
# mention of the gate is a comment.
init_block="$(awk '/^if \[\[ "\$FLAG_INIT" == true \]\]; then/,/^fi$/' "$BUILD" \
    | grep -v '^[[:space:]]*#')"
build_idx="$(printf '%s\n' "$init_block" | grep -n 'building it first (723-whrx)' | head -1 | cut -d: -f1)"
podman_idx="$(printf '%s\n' "$init_block" | grep -n 'require_podman' | head -1 | cut -d: -f1)"
bump_idx="$(printf '%s\n' "$init_block" | grep -n '_bump_build_version' | head -1 | cut -d: -f1)"
if [ -n "$build_idx" ] && [ -n "$podman_idx" ] && [ "$build_idx" -lt "$podman_idx" ]; then
    check "init-builds-before-the-podman-gate" 0
else
    echo "FAIL: init-builds-before-the-podman-gate (build=$build_idx podman=$podman_idx)"
    fail=1
fi
if [ -n "$build_idx" ] && [ -n "$bump_idx" ] && [ "$build_idx" -lt "$bump_idx" ]; then
    check "init-builds-before-the-version-bump" 0
else
    echo "FAIL: init-builds-before-the-version-bump (build=$build_idx bump=$bump_idx)"
    fail=1
fi

# ── Behavioural arm: Darwin only, because elsewhere this would really install ─
if [ "$(uname -s)" = "Darwin" ]; then
    out="$(cd "$ROOT" && TILLANDSIAS_SKIP_VERSION_BUMP=1 ./build.sh --install 2>&1)"
    rc=$?
    [ "$rc" -ne 0 ]; check "darwin-install-exits-nonzero" "$?"
    printf '%s' "$out" | grep -q 'not supported on macOS'
    check "darwin-install-says-why" "$?"
    printf '%s' "$out" | grep -q 'scripts/build-macos-tray.sh'
    check "darwin-install-names-the-alternative" "$?"

    # THE PLACEMENT PROPERTY, measured: refusing must leave the tree clean.
    dirt="$(cd "$ROOT" && git diff --name-only -- VERSION Cargo.toml Cargo.lock 2>/dev/null)"
    [ -z "$dirt" ]; check "darwin-install-leaves-no-version-dirt" "$?"

    out2="$(cd "$ROOT" && ./build.sh --ci-full --install 2>&1)"
    rc2=$?
    [ "$rc2" -ne 0 ]; check "darwin-ci-full-install-refuses-too" "$?"
else
    echo "ok: behavioural-arm-skipped-off-darwin (running ./build.sh --install here would really install)"
fi

if [ "$fail" -eq 0 ]; then
    echo "ok: build-sh-darwin-install-refusal"
    exit 0
fi
echo "FAIL: build-sh-darwin-install-refusal had failures"
exit 1
