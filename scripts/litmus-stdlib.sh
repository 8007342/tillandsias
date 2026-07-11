# @trace spec:litmus-runner
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
