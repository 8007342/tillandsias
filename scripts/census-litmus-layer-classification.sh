#!/usr/bin/env bash
# Census (advisory, never refuses) of litmus specs under openspec/litmus-tests
# whose declared `size` or `phase` disagrees with what their critical_path
# commands actually run. Filed as 1443-2ef7: the integration-layer classifier
# (1443-b85g) routes on `size` and `phase`, so a spec that claims `instant`
# but launches a forge, or claims `pre-build` but runs inside a guest/VM,
# gets routed to the wrong layer. This script only names them; it never
# fails the build (the corpus is prose, not a contract).
set -euo pipefail

# Token tables. Kept identical between --self-test and the live census so
# the self-test actually exercises the matcher the live run uses.
SIZE_INSTANT_TOKENS=(
  "run-forge-standalone.sh"
  "tillandsias --init"
  "podman run"
  "build.sh --ci-full"
)

PHASE_PREBUILD_TOKENS=(
  "guest-agent"
  "vm-layer"
  "launch_vm"
  "run-forge-standalone.sh"
)

# match_token HAYSTACK TOKEN...
# Prints the first token found as a substring of HAYSTACK and returns 0;
# returns 1 with no output if none match.
match_token() {
  local hay="$1"
  shift
  local t
  for t in "$@"; do
    if grep -qF -- "$t" <<<"$hay"; then
      printf '%s' "$t"
      return 0
    fi
  done
  return 1
}

# run_census DIR
# Scans DIR/*.yaml (top-level only) and prints one misclassified:... line
# per disagreement found, then the summary line. Always returns 0: this is
# a census, not a gate.
run_census() {
  local dir="$1"
  local specs=0
  local misclassified=0
  local f name size phase commands tok

  for f in "$dir"/*.yaml; do
    [ -f "$f" ] || continue
    specs=$((specs + 1))
    name=$(basename "$f" .yaml)
    size=$(grep -m1 -E '^size:[[:space:]]*' "$f" | sed -E 's/^size:[[:space:]]*//' || true)
    phase=$(grep -m1 -E '^phase:[[:space:]]*' "$f" | sed -E 's/^phase:[[:space:]]*//' || true)
    commands=$(grep -oP '(?<=command:[[:space:]]").*?(?=")' "$f" 2>/dev/null || true)

    if [ "$size" = "instant" ]; then
      if tok=$(match_token "$commands" "${SIZE_INSTANT_TOKENS[@]}"); then
        echo "misclassified:${name}:size=instant:runs=${tok}"
        misclassified=$((misclassified + 1))
      fi
    fi

    if [ "$phase" = "pre-build" ]; then
      if tok=$(match_token "$commands" "${PHASE_PREBUILD_TOKENS[@]}"); then
        echo "misclassified:${name}:phase=pre-build:runs=${tok}"
        misclassified=$((misclassified + 1))
      fi
    fi
  done

  echo "census:litmus-layer:specs=${specs} misclassified=${misclassified}"
}

self_test() {
  local tmp pass out
  tmp=$(mktemp -d)
  pass=0

  mkdir -p "$tmp/arm1" "$tmp/arm2" "$tmp/arm3"

  cat >"$tmp/arm1/arm1.yaml" <<'EOF'
name: litmus:arm1
spec: arm1
phase: pre-build
size: instant
critical_path:
  - step: "run heavy thing"
    command: "bash scripts/run-forge-standalone.sh"
EOF

  cat >"$tmp/arm2/arm2.yaml" <<'EOF'
name: litmus:arm2
spec: arm2
phase: pre-build
size: full
critical_path:
  - step: "launch vm"
    command: "scripts/launch_vm.sh --profile default"
EOF

  cat >"$tmp/arm3/arm3.yaml" <<'EOF'
name: litmus:arm3
spec: arm3
phase: pre-build
size: instant
critical_path:
  - step: "cheap check"
    command: "grep -Fq foo bar.md && echo ok"
EOF

  out=$(run_census "$tmp/arm1")
  if grep -q "^misclassified:arm1:size=instant:runs=run-forge-standalone.sh$" <<<"$out"; then
    pass=$((pass + 1))
  else
    echo "[census-litmus-layer-classification] self-test arm1 FAILED: $out" >&2
  fi

  out=$(run_census "$tmp/arm2")
  if grep -q "^misclassified:arm2:phase=pre-build:runs=launch_vm$" <<<"$out"; then
    pass=$((pass + 1))
  else
    echo "[census-litmus-layer-classification] self-test arm2 FAILED: $out" >&2
  fi

  out=$(run_census "$tmp/arm3")
  if ! grep -q "^misclassified:arm3:" <<<"$out" && grep -q "^census:litmus-layer:specs=1 misclassified=0$" <<<"$out"; then
    pass=$((pass + 1))
  else
    echo "[census-litmus-layer-classification] self-test arm3 FAILED: $out" >&2
  fi

  echo "ok:litmus-layer-census-self-test:${pass}/3"
  rm -rf "$tmp"
  [ "$pass" -eq 3 ]
}

main() {
  if [ "${1:-}" = "--self-test" ]; then
    self_test
    return $?
  fi
  run_census "openspec/litmus-tests"
  return 0
}

main "$@"
