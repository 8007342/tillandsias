#!/usr/bin/env bash
# Census (advisory, never refuses) of litmus specs under openspec/litmus-tests
# whose declared `size` or `phase` disagrees with what their critical_path
# commands actually run. Filed as 1443-2ef7: the integration-layer classifier
# (1443-b85g) routes on `size` and `phase`, so a spec that claims `instant`
# but launches a forge, or claims `pre-build` but runs inside a guest/VM,
# gets routed to the wrong layer. This script only names them; it never
# fails the build (the corpus is prose, not a contract).
#
# 1443-gk4t: the original matcher did a plain substring grep against the
# WHOLE command line, so it could not tell "this command RUNS X" from "this
# command's ARGUMENT NAMES X" — a grep pattern, a doc string, or a crate path
# (crates/tillandsias-vm-layer/... contains "vm-layer" as a path segment, not
# a VM launch). Every one of 1443-2ef7's 10 live hits was that shape (see
# plan/issues/1443-2ef7-census-audit-false-positives-2026-09-27.md). The
# matcher below tokenises each command into sub-commands, resolves the
# EXECUTED launcher word of each (unwrapping a `bash script.sh` wrapper,
# skipping a `bash -n` syntax check), skips sub-commands whose launcher is a
# text-processing/test-helper tool (grep and friends: their arguments are
# DATA, never something they execute), and matches a token only against a
# survived sub-command's launcher and its own real arguments.
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

# Launchers whose arguments are DATA (a pattern, a path, a doc string), never
# something the launcher itself executes.
FILTER_LAUNCHERS=(grep egrep fgrep rg awk sed cat printf echo test mf_stage mf_holds mf_holds_ere)

is_filter_launcher() {
  local l="$1" f
  for f in "${FILTER_LAUNCHERS[@]}"; do
    [ "$l" = "$f" ] && return 0
  done
  return 1
}

# effective_launcher SUBCOMMAND
# Prints "<launcher>\x1f<rest of the real args, space-joined>" for a
# sub-command that is a real invocation, and nothing for one that is a
# syntax check (`bash -n` / `sh -n`) or a text-processing/test-helper call
# whose arguments are data rather than something it runs.
effective_launcher() {
  local subcmd="$1"
  local -a words
  read -ra words <<<"$subcmd"
  [ "${#words[@]}" -gt 0 ] || return 0
  local launcher="${words[0]}"
  local -a rest=("${words[@]:1}")

  case "$launcher" in
  bash | sh | ./bash | ./sh)
    if [ "${rest[0]:-}" = "-n" ]; then
      return 0
    fi
    # Unwrap: the wrapped script is the real launcher.
    launcher="${rest[0]:-}"
    rest=("${rest[@]:1}")
    ;;
  esac

  launcher="${launcher##*/}"
  [ -n "$launcher" ] || return 0
  is_filter_launcher "$launcher" && return 0

  printf '%s\x1f%s\n' "$launcher" "${rest[*]:-}"
}

# token_matches TOKEN LAUNCHER REST
token_matches() {
  local token="$1" launcher="$2" rest="$3"
  case "$token" in
  "run-forge-standalone.sh")
    [ "$launcher" = "run-forge-standalone.sh" ]
    ;;
  "tillandsias --init")
    [ "$launcher" = "tillandsias" ] && grep -qF -- "--init" <<<"$rest"
    ;;
  "podman run")
    [ "$launcher" = "podman" ] && [ "${rest%% *}" = "run" ]
    ;;
  "build.sh --ci-full")
    [ "$launcher" = "build.sh" ] && grep -qF -- "--ci-full" <<<"$rest"
    ;;
  "guest-agent")
    [ "$launcher" = "guest-agent" ]
    ;;
  "vm-layer")
    [ "$launcher" = "vm-layer" ]
    ;;
  "launch_vm")
    [[ "$launcher" == *launch_vm* ]]
    ;;
  *)
    return 1
    ;;
  esac
}

# match_token COMMANDS TOKEN...
# Scans every command line in COMMANDS (one per line), splits each on
# &&/||/;/| into sub-commands, and returns the first TOKEN whose executed
# launcher (per effective_launcher/token_matches) matches. Prints that token
# and returns 0; returns 1 with no output if none match.
match_token() {
  local commands="$1"
  shift
  local cmdline subcmd launcher rest entry t

  while IFS= read -r cmdline; do
    [ -n "$cmdline" ] || continue
    while IFS= read -r subcmd; do
      subcmd="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$subcmd")"
      [ -n "$subcmd" ] || continue
      entry="$(effective_launcher "$subcmd")" || true
      [ -n "$entry" ] || continue
      launcher="${entry%%$'\x1f'*}"
      rest="${entry#*$'\x1f'}"
      for t in "$@"; do
        if token_matches "$t" "$launcher" "$rest"; then
          printf '%s' "$t"
          return 0
        fi
      done
    done <<<"$(sed -E 's/(&&|\|\||[;|])/\n/g' <<<"$cmdline")"
  done <<<"$commands"
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

  mkdir -p "$tmp/arm1" "$tmp/arm2" "$tmp/arm3" "$tmp/arm4" "$tmp/arm5" "$tmp/arm6"

  cat >"$tmp/arm1/arm1.yaml" <<'EOF'
name: selftest-arm1
spec: arm1
phase: pre-build
size: instant
critical_path:
  - step: "run heavy thing"
    command: "bash scripts/run-forge-standalone.sh"
EOF

  cat >"$tmp/arm2/arm2.yaml" <<'EOF'
name: selftest-arm2
spec: arm2
phase: pre-build
size: full
critical_path:
  - step: "launch vm"
    command: "scripts/launch_vm.sh --profile default"
EOF

  cat >"$tmp/arm3/arm3.yaml" <<'EOF'
name: selftest-arm3
spec: arm3
phase: pre-build
size: instant
critical_path:
  - step: "cheap check"
    command: "grep -Fq foo bar.md && echo ok"
EOF

  # Arm 4: greps a script's TEXT for the literal string 'podman run' — never
  # executes podman. Must NOT be flagged (the exact 1443-2ef7 false-positive
  # shape).
  cat >"$tmp/arm4/arm4.yaml" <<'EOF'
name: selftest-arm4
spec: arm4
phase: pre-build
size: instant
critical_path:
  - step: "grep for the string, don't run it"
    command: "grep -F 'exec podman run' run-forge-standalone.sh"
EOF

  # Arm 5 (positive control): actually runs `podman run`. Must still be
  # flagged — proving the fix does not overcorrect to "never flag podman".
  cat >"$tmp/arm5/arm5.yaml" <<'EOF'
name: selftest-arm5
spec: arm5
phase: pre-build
size: instant
critical_path:
  - step: "actually launch a container"
    command: "podman run --rm busybox true"
EOF

  # Arm 6: a cargo test invocation whose -p argument names a crate
  # containing "vm-layer" as a path/name substring — not a VM launch. Must
  # NOT be flagged (the exact litmus-vsock-exec-heartbeat false positive).
  cat >"$tmp/arm6/arm6.yaml" <<'EOF'
name: selftest-arm6
spec: arm6
phase: pre-build
size: full
critical_path:
  - step: "unit test, not a VM"
    command: "cargo test -p tillandsias-vm-layer 'vsock_exec::tests'"
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

  out=$(run_census "$tmp/arm4")
  if ! grep -q "^misclassified:arm4:" <<<"$out" && grep -q "^census:litmus-layer:specs=1 misclassified=0$" <<<"$out"; then
    pass=$((pass + 1))
  else
    echo "[census-litmus-layer-classification] self-test arm4 FAILED: $out" >&2
  fi

  out=$(run_census "$tmp/arm5")
  if grep -q "^misclassified:arm5:size=instant:runs=podman run$" <<<"$out"; then
    pass=$((pass + 1))
  else
    echo "[census-litmus-layer-classification] self-test arm5 FAILED: $out" >&2
  fi

  out=$(run_census "$tmp/arm6")
  if ! grep -q "^misclassified:arm6:" <<<"$out" && grep -q "^census:litmus-layer:specs=1 misclassified=0$" <<<"$out"; then
    pass=$((pass + 1))
  else
    echo "[census-litmus-layer-classification] self-test arm6 FAILED: $out" >&2
  fi

  echo "ok:litmus-layer-census-self-test:${pass}/6"
  rm -rf "$tmp"
  [ "$pass" -eq 6 ]
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
