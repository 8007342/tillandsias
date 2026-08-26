# @trace spec:litmus-framework
# (formerly spec:litmus-runner — a ghost name no spec file ever carried; the
# stdlib is part of the litmus framework and traces to its spec, order 877)
#
# litmus-stdlib.sh — portable building-block primitives for litmus command: fields
#
# Source this file from scripts/run-litmus-test.sh to make the 8 core
# mf_* functions available in every litmus step's bash -c invocation.
# Each function wraps a common pattern (literal grep, regex grep, threshold
# check, etc.) with implicit per-OS dialect branching so authors write
# stable commands without knowing GNU-vs-BSD tool details.
#
# Authoring guide: docs/cheatsheets/litmus-stdlib-authoring.md

if [ -n "${LITMUS_STDLIB_LOADED:-}" ]; then
  return 0
fi
LITMUS_STDLIB_LOADED=1

# Detect OS dialect family
_litmus_os() {
  case "$(uname -s)" in
    Darwin) echo "bsd" ;;
    Linux)  echo "gnu"  ;;
    *)      echo "other" ;;
  esac
}

# mf_literal FILE PATTERN
#   Quiet literal-substring existence check. Exit 0 if PATTERN is found
#   anywhere in FILE, 1 if not found. Equivalent to `grep -qF`.
mf_literal() {
  local file="$1" pat="$2"
  grep -qF -- "$pat" "$file"
}

# mf_literal_count FILE PATTERN
#   Print count of lines in FILE containing PATTERN (literal match).
#   Equivalent to `grep -cF`.
mf_literal_count() {
  local file="$1" pat="$2"
  grep -cF -- "$pat" "$file"
}

# mf_regex FILE PATTERN
#   Quiet extended-regex existence check. Exit 0 if PATTERN is found, 1
#   if not. Handles GNU vs BSD grep -E dialect internally so authors can
#   write standard ERE (e.g. `(Foo|Bar)`, `\.`, `\|`) without worrying
#   about which host runs the litmus.
mf_regex() {
  local file="$1" pat="$2"
  local os
  os=$(_litmus_os)
  case "$os" in
    bsd)
      # BSD grep -E accepts ERE metacharacters as-is: `|`, `(`, `)`, `[`
      grep -qE -- "$pat" "$file"
      ;;
    gnu|other)
      # GNU grep -E also accepts standard ERE, but historically needed
      # `\|` for alternation in basic mode. In -E mode, `|` is alternation.
      grep -qE -- "$pat" "$file"
      ;;
  esac
}

# mf_regex_count FILE PATTERN
#   Print count of lines in FILE matching PATTERN (extended regex).
mf_regex_count() {
  local file="$1" pat="$2"
  local os
  os=$(_litmus_os)
  case "$os" in
    bsd)
      grep -cE -- "$pat" "$file"
      ;;
    gnu|other)
      grep -cE -- "$pat" "$file"
      ;;
  esac
}

# mf_absent FILE PATTERN
#   Assert absence: exit 0 if PATTERN is NOT found in FILE, 1 if found.
#   Equivalent to `! grep -qF`.
mf_absent() {
  local file="$1" pat="$2"
  ! grep -qF -- "$pat" "$file"
}

# mf_threshold FILE PATTERN MIN_COUNT
#   Exit 0 if the number of lines in FILE matching PATTERN is >= MIN_COUNT,
#   1 otherwise. Silent — no output.
mf_threshold() {
  local file="$1" pat="$2" min="$3"
  local count
  count=$(grep -cF -- "$pat" "$file") || true
  [ "$count" -ge "$min" ] 2>/dev/null
}

# mf_file_exists FILE
#   Exit 0 if FILE exists and is a regular file, 1 otherwise.
mf_file_exists() {
  [ -f "$1" ]
}

# mf_assert_count ACTUAL EXPECTED
#   Exit 0 if ACTUAL equals EXPECTED (numeric equality). Prints nothing
#   on success; prints "FAIL: ACTUAL != EXPECTED" on failure.
mf_assert_count() {
  local actual="$1" expected="$2"
  if [ "$actual" -eq "$expected" ] 2>/dev/null; then
    return 0
  else
    echo "FAIL: $actual != $expected"
    return 1
  fi
}

# mf_threshold_std COUNT MIN
#   Like mf_threshold but takes a pre-computed count as first arg.
#   Useful in pipelines: `count=$(mf_literal_count ...); mf_threshold_std $count 10`
mf_threshold_std() {
  local count="$1" min="$2"
  [ "$count" -ge "$min" ] 2>/dev/null
}

# mf_touch_age_minutes FILE MINUTES
#   Set FILE's mtime to MINUTES ago. GNU touch understands relative -d;
#   BSD/macOS touch does not, so fall back to an absolute -t stamp derived
#   with BSD date -v. Tests must use this instead of `touch -d 'N minutes
#   ago'` directly — that idiom is GNU-only.
mf_touch_age_minutes() {
  touch -d "$2 minutes ago" "$1" 2>/dev/null \
    || touch -t "$(date -v -"$2"M +%Y%m%d%H%M.%S)" "$1"
}

# mf_plan_binary
#   Print the tillandsias-plan the CURRENT HOST can actually run, or print
#   nothing and return 1. Steps use it as:
#
#     P="$(mf_plan_binary)" || { echo 'fail: no runnable tillandsias-plan'; exit 1; }
#
#   WHY THIS EXISTS (order 751-vega). Fourteen litmus files resolved the binary
#   by hand, almost all of them as a bare `./target/release/tillandsias-plan`.
#   On a shared Windows/WSL checkout that path holds a **Linux ELF** left by a
#   WSL build, sitting beside the runnable `.exe`:
#
#     -rw-r--r--  target/release/tillandsias-plan      (Linux ELF, not executable here)
#     -rwxr-xr-x  target/release/tillandsias-plan.exe  (the one that runs)
#
#   Measured on windows 2026-08-15: two tests in methodology-accountability were
#   red for this and nothing else -- one exiting 126 (found, not executable) and
#   one reporting `: command not found` because the `[ -x ] || command -v`
#   fallback chain left the variable EMPTY. A resolution bug wearing a
#   missing-tool costume. A third direction exists: where the ELF DOES carry the
#   executable bit, `[ -x ]` selects it and the step runs the wrong
#   architecture.
#
#   This is the same class of host-dialect difference the mf_* helpers already
#   absorb -- an author should not have to know the Windows/WSL target/ layout
#   to write a step, any more than they should have to know GNU vs BSD `touch`.
#
#   It DELEGATES to scripts/plan-binary-probe.sh rather than reimplementing the
#   search. That is the entire point of 704-zcgi: three scripts independently
#   wrote the same wrong probe, so a fourth copy here -- even a correct one --
#   would be the defect repeating itself one directory over.
#
#   RUNNING A STEP BY HAND: `source scripts/litmus-stdlib.sh` first, exactly as
#   for any mf_* helper. The runner does it for you in the suite.
mf_plan_binary() {
  local probe="${LITMUS_PLAN_PROBE:-scripts/plan-binary-probe.sh}"
  [ -f "$probe" ] || return 1
  # shellcheck source=scripts/plan-binary-probe.sh
  . "$probe" || return 1
  resolve_plan_binary
}
