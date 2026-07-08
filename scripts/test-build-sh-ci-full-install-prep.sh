#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SH="$ROOT/build.sh"

bash -n "$BUILD_SH"

grep -F '_prepare_ci_full_install_inputs' "$BUILD_SH" >/dev/null
grep -F 'scripts/build-guest-binaries.sh' "$BUILD_SH" >/dev/null

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

echo "ci-full-install-prep: ok"
