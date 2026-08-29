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

# ─────────────────────────────────────────────────────────────────────────────
# ORDER 901-jtvi — THE STEP MODEL: per-stage exit codes, no SIGPIPE.
#
# THE DEFECT, measured on lenovinha 2026-08-29 over the litmus corpus:
#
#   piped `command:` lines                                        1290
#   of those, piping into an EARLY-EXIT consumer                   698  (54%)
#     …into head                                                   235
#     …into tail                                                    93
#     …into `grep -q`                                              418   <- the largest class
#
# `grep -q` IS A TRUNCATING CONSUMER, and that is the part everyone (including
# this packet's own filing, and my own first count) misses. It exits the instant
# it decides, closes the pipe, and SIGPIPEs its producer — exactly like `head`.
# Measured, on a real step from litmus:forge-plan-expert-build-shape:
#
#   sed -n '/^ensure_forge_experts() {/,/^}/p' … | grep -q 'cargo build' && echo ok
#     without pipefail : "ok: no-python-cargo-only", rc=0
#     with    pipefail : no output,                  rc=141   (128+13 = SIGPIPE)
#
# So the exposed population is not the 273 head/tail sites the head-count
# suggests. It is 698, and the biggest slice is the idiom authors reach for
# precisely BECAUSE it looks safe.
#
# WHY `set -o pipefail` IS NOT THE FIX, and this is the load-bearing result of
# the 901-jtvi measurement. Enabling it in the step shell and re-running the
# pre-build/instant suite moved 4 tests from PASS to FAIL — and ALL FOUR ARE
# FALSE POSITIVES. Classified individually:
#
#   forge-plan-expert-build-shape   `| grep -q` SIGPIPEd a healthy `sed`
#   inference-container-…-shape     `| head -1` SIGPIPEd a healthy `grep`
#   nix-capability-probe            producer exits 2 BY DESIGN (a usage probe)
#   installer-wsl-preflight-shape   `grep -q` non-match used as a boolean
#
# ZERO masked producer failures were found in 249 executed tests. That is a real
# and reportable outcome about how much this cluster actually cost HERE, and it
# is the opposite of what a reader would assume from five field incidents: the
# incidents were real, and this suite is not where they live. Turning on
# pipefail would have bought four red tests and no additional truth.
#
# THE ACTUAL FIX, which is the operator's shape: the consumer must read a
# COMPLETE stream, never truncate a live one. Truncation becomes a property of
# the consumer's input, not a signal delivered to the producer's throat. Then
# the producer's status is its own, observable, and separate.
#
# BASH 3.2 CLEAN. No PIPESTATUS — it is bash-only and empty under zsh 5.9,
# macOS's default shell, which is defect (3) in this packet's own list.

# mf_run VAR -- CMD [ARGS...]
#   Run CMD to COMPLETION, capturing stdout+stderr into $VAR and its exit code
#   into ${VAR}_rc. Never truncates, so the producer can never be SIGPIPEd by
#   its consumer. Returns the command's own status.
#
#   Both streams are captured together on purpose: a discarded stderr is the
#   fourth defect in this packet's list (`2>/dev/null` on a probe hid
#   `ps: unknown option`, and a broken primitive returned a confident wrong
#   verdict). A step that genuinely wants stderr dropped must say so explicitly
#   rather than get it by default.
mf_run() {
  _mfr_var="$1"; shift
  [ "${1:-}" = "--" ] && shift
  _mfr_out="$("$@" 2>&1)"; _mfr_rc=$?
  eval "$_mfr_var=\$_mfr_out"
  eval "${_mfr_var}_rc=\$_mfr_rc"
  return "$_mfr_rc"
}

# mf_stage NAME EXPECTED_RC VAR -- CMD [ARGS...]
#   mf_run with an ASSERTED exit code, and a diagnosis naming the stage when it
#   disagrees. EXPECTED_RC of `any` accepts anything — for the usage-probe case
#   (`script --bogus` exits 2 by design) that pipefail cannot distinguish from a
#   real failure. THE POINT IS THAT THE STEP SAYS WHICH IT MEANT.
mf_stage() {
  _mfs_name="$1"; _mfs_want="$2"; _mfs_var="$3"; shift 3
  [ "${1:-}" = "--" ] && shift
  mf_run "$_mfs_var" -- "$@"
  eval "_mfs_rc=\$${_mfs_var}_rc"
  if [ "$_mfs_want" = "any" ] || [ "$_mfs_rc" = "$_mfs_want" ]; then
    return 0
  fi
  echo "FAIL: stage '${_mfs_name}' exited ${_mfs_rc}, expected ${_mfs_want}" >&2
  eval "printf '%s\\n' \"\$${_mfs_var}\"" | sed -n '1,20p' >&2
  return 1
}

# mf_holds VAR PATTERN   — does the captured stream match PATTERN?
# mf_lacks VAR PATTERN   — …or not?
#   Consumers over an ALREADY-COMPLETE buffer. This is the `| grep -q`
#   replacement: same question, no live pipe, so nothing upstream can be
#   killed and the producer's status was already checked by its stage.
mf_holds() { eval "printf '%s\\n' \"\$$1\"" | grep -qE "$2"; }
mf_lacks() { ! mf_holds "$1" "$2"; }

# mf_first VAR N — the first N lines of a captured stream.
#   The `| head -N` replacement. Truncation is a property of the CONSUMER
#   reading a finished buffer, which is the whole design in one function.
mf_first() { eval "printf '%s\\n' \"\$$1\"" | sed -n "1,${2}p"; }
