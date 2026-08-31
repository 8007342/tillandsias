#!/usr/bin/env bash
set -euo pipefail


# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
if command -v resolve_tool >/dev/null 2>&1; then
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi

# Portable SHA-256 (851-28b5): coreutils sha256sum on Linux/forge/WSL; stock
# macOS before 13 ships only `shasum`. Identical "<hex>  <name>" output.
if command -v sha256sum >/dev/null 2>&1; then
    PORTABLE_SHA256=(sha256sum)
else
    PORTABLE_SHA256=(shasum -a 256)
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SH="$ROOT/build.sh"
EVIDENCE_SCRIPT="$ROOT/scripts/generate-evidence-bundle.sh"
DASHBOARD_SCRIPT="$ROOT/scripts/update-convergence-dashboard.sh"

bash -n "$BUILD_SH" "$EVIDENCE_SCRIPT" "$DASHBOARD_SCRIPT"

grep -F '_prepare_ci_full_install_inputs' "$BUILD_SH" >/dev/null
grep -F 'scripts/build-guest-binaries.sh' "$BUILD_SH" >/dev/null

if [[ "$(grep -cF 'local -a command=(bash "$SCRIPT_DIR/scripts/local-ci.sh" "$@")' "$BUILD_SH")" -ne 1 ]]; then
    echo "ci-full-install-prep: every build-driven local CI run must use the redirected helper" >&2
    exit 1
fi

# The rule this enforces is "the CYCLE's own build must not bump tracked release
# state", not "build.sh may never reference the bump script".
#
# Those were the same assertion until 2026-07-31, when methodology/versioning.yaml's
# long-unimplemented increment_rule was finally wired up: "Build: local monotonic
# build counter — increments on every local build (./build.sh)". A flat grep
# prohibition makes that rule unimplementable, so the two committed artifacts
# contradicted each other and this fixture caught the collision immediately.
#
# Resolution: developer dispatches bump (methodology + the operator's stated
# semantics — "even local builds should have incremented build versions,
# versions stay monotonically increasing"), while _prepare_ci_full_install_inputs
# — the meta-orchestration cycle's own build — must not. A cycle has to exit with
# a clean worktree, and unlike a regenerated trace index (which is derived and
# converges), a monotonic counter never converges to a value a second cycle would
# agree on.
#
# So assert the SCOPED rule: the prep function must not bump.
prep_block="$(awk '/^_prepare_ci_full_install_inputs\(\) \{/,/^\}/' "$BUILD_SH")"
if [[ -z "$prep_block" ]]; then
    echo "ci-full-install-prep: _prepare_ci_full_install_inputs not found" >&2
    exit 1
fi
# Strip comments before matching: the prep function documents WHY it does not
# bump, and a naive grep matches that explanation and fails on the very comment
# that records the rule.
if grep -vE '^[[:space:]]*#' <<<"$prep_block" \
    | grep -qE '_bump_build_version|scripts/bump-version\.sh'; then
    echo "ci-full-install-prep: the cycle's own build must not bump tracked release versions" >&2
    exit 1
fi
# And the bump must remain SUPPRESSIBLE, so any other caller that must not mutate
# the checkout has an escape hatch rather than needing this file edited again.
if ! grep -F 'TILLANDSIAS_SKIP_VERSION_BUMP' "$BUILD_SH" >/dev/null; then
    echo "ci-full-install-prep: the build counter must honour TILLANDSIAS_SKIP_VERSION_BUMP" >&2
    exit 1
fi

if ! grep -F 'scripts/generate-traces.sh' "$BUILD_SH" >/dev/null; then
    echo "ci-full-install-prep: non-test/check builds must regenerate trace indexes" >&2
    exit 1
fi

for output in \
    'MD_OUT="$SCRIPT_DIR/target/convergence/centicolon-dashboard.md"' \
    'JSON_OUT="$SCRIPT_DIR/target/convergence/centicolon-dashboard.json"' \
    'SUMMARY_OUT="$SCRIPT_DIR/target/convergence/summary.md"'; do
    if ! grep -F "$output" "$BUILD_SH" >/dev/null; then
        echo "ci-full-install-prep: local CI output is not redirected to target/: $output" >&2
        exit 1
    fi
done

grep -F 'DASHBOARD_FILE="$SCRIPT_DIR/target/convergence/centicolon-dashboard.json"' "$BUILD_SH" >/dev/null
grep -F 'DASHBOARD_FILE="${DASHBOARD_FILE:-$PROJECT_ROOT/docs/convergence/centicolon-dashboard.json}"' "$EVIDENCE_SCRIPT" >/dev/null
grep -F 'TILLANDSIAS_STATUS_CHECK_BIN="$INSTALL_BIN"' "$BUILD_SH" >/dev/null
grep -F '"$INSTALL_BIN" --init' "$BUILD_SH" >/dev/null

prep_line="$(grep -nF '_prepare_ci_full_install_inputs' "$BUILD_SH" | tail -1 | cut -d: -f1)"
ci_gate_line="$(grep -nF '_run_local_ci_gate "${CI_ARGS[@]}" "${CI_ARG_LIST[@]}"' "$BUILD_SH" | head -1 | cut -d: -f1)"

if [[ -z "$prep_line" || -z "$ci_gate_line" ]]; then
    echo "ci-full-install-prep: missing prep or CI gate line" >&2
    exit 1
fi

if (( prep_line >= ci_gate_line )); then
    echo "ci-full-install-prep: prep must run before local-ci pre-build gate" >&2
    exit 1
fi

if grep -F 'python3' "$ROOT/scripts/with-tillandsias-builder.sh" >/dev/null; then
    echo "ci-full-install-prep: Silverblue builder must not install Python" >&2
    exit 1
fi

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/tillandsias-dashboard-local.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
tracked_md="$ROOT/docs/convergence/centicolon-dashboard.md"
tracked_json="$ROOT/docs/convergence/centicolon-dashboard.json"
tracked_md_before="$("${PORTABLE_SHA256[@]}" "$tracked_md")"
tracked_json_before="$("${PORTABLE_SHA256[@]}" "$tracked_json")"

SOURCE=/dev/null \
    MD_OUT="$fixture_dir/centicolon-dashboard.md" \
    JSON_OUT="$fixture_dir/centicolon-dashboard.json" \
    SUMMARY_OUT="$fixture_dir/summary.md" \
    TERMINAL_PREVIEW=0 \
    bash "$DASHBOARD_SCRIPT" >/dev/null

test -s "$fixture_dir/centicolon-dashboard.md"
"$JQ" -e . "$fixture_dir/centicolon-dashboard.json" >/dev/null
test "$("${PORTABLE_SHA256[@]}" "$tracked_md")" = "$tracked_md_before"
test "$("${PORTABLE_SHA256[@]}" "$tracked_json")" = "$tracked_json_before"

echo "ci-full-install-prep: ok"
