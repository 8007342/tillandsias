#!/usr/bin/env bash
# Deterministic bash-dialect gate (761-g36m).
#
# Apple ships bash 3.2 and /usr/bin/env bash resolves to it on macOS, so a
# bash-4-only construct in a shared script fails there as a silent bad
# substitution or an empty verdict — the class that blocked every macOS push
# on 2026-08-16 (agent-identity.sh, fixed) and produced an empty windows
# sources verdict on 2026-08-14 (723-b9cn). This gate rejects NEW instances:
# every scripts/*.sh must be bash-3.2-clean OR refuse loudly (an executable
# BASH_VERSINFO major-version check in its first 40 lines).
#
# Grammar (falsifiable, one line on stdout):
#   ok:bash-dialect-clean | blocked:bash4-unguarded:<count>
# Exit 0 exactly on ok. Detail per offending file goes to stderr.
#
# Fixture: scripts/test-check-bash-dialect.sh (two directions: an unguarded
# bash-4-ism FAILS, a guarded one PASSES).
# freshness: auditor=macos-tlatoanis-macbook-air-fable5 date=2026-08-16 verdict=refreshed scope=761-g36m authoring
set -u

SCAN_DIR="${TILLANDSIAS_DIALECT_SCAN_DIR:-scripts}"
SELF_NAME="check-bash-dialect.sh"

# Burndown allowlist for known-legacy carriers. EMPTY since 2026-08-16
# (761-g36m criterion 1 complete: the last three carriers were rewritten
# 3.2-clean — string sets for the two `declare -A` uses, while-read append
# for the mapfile). Never add to this list: a new entry means a new
# unguarded bash-4-ism shipped, which is what this gate exists to refuse.
ALLOWLIST=""

# Constructs bash 3.2 cannot parse or lacks. Plain literals are safe: this
# file is excluded from the scan by name, so self-matching cannot happen.
PAT_EXPANSION='\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^)'
PAT_BUILTIN='(^|[^A-Za-z0-9_])(mapfile|readarray)([^A-Za-z0-9_]|$)'
# -A (assoc, 4.0), -g (global, 4.2), -n (nameref, 4.3) — including combined
# flags like -gA, which slipped past the earlier literal 'declare -A' and
# crashed trace-coverage.sh on this host (766-tdij follow-on).
# `local -A` and `typeset -A` are the same bash-4 feature as `declare -A`, and
# `local` is how it actually appears inside functions — which is where it hid:
# scripts/hooks/pre-commit-openspec.sh used `local -A`, so on bash 3.2 the
# declaration errored and the lookups degenerated to index 0 (always set), and
# the zero-trace check silently passed EVERY spec (784-dwkh).
PAT_ASSOC='(declare|local|typeset|readonly) +-[a-zA-Z]*[Agn]'
PAT_PRINTF_T='%\([^)]*\)T'
# GNU-date-only forms (766-tdij). BSD date SUCCEEDS on an unknown %-format,
# passing it through literally, so exit-code guards never fire — the 765
# phase telemetry crashed every macOS gate run exactly this way. Scoped to
# date invocations so %N in awk/printf formats elsewhere never trips it.
# Line-level exemption: a raw-line comment `# gnu-date: ok (<reason>)` for
# digit-validated fallbacks (build.sh _now_ms is the exemplar) or sites
# where garbage output is provably harmless.
# The -d arm allows INTERVENING flags: the first cut required -d to be date's
# first flag, so `date -u -d "@$epoch"` slipped through — and did, in
# scripts/test-ledger-ts-guard.sh, where it returned empty on BSD and made the
# whole fixture for the ledger timestamp guard fail silently on macOS
# (found by the cycle-22 freshness audit, 784-dwkh).
PAT_GNUDATE='(^|[^A-Za-z0-9_])date[^|;&()]*\+[^ "]*%-?[0-9]*N|(^|[^A-Za-z0-9_])date( +-[A-Za-z-]+)* +(-d|--date)[ =]'
GNUDATE_EXEMPT='# gnu-date: ok'
# GNU-du-only forms. `du -b` / `--bytes` does not exist in BSD du, which
# REFUSES the flag rather than ignoring it — so the usual shape
# `bytes="$(du -sb "$d" 2>/dev/null | cut -f1)"` yields the empty string and
# whatever `|| bytes=0` fallback sits beside it silently becomes the answer.
# Measured on tlatoanis-macbook-air 2026-08-25: check-build-cache-sweep.sh
# reported `bytes=0:gib=0` for a 14 GiB target/, so its size trigger could
# never fire on macOS, and its litmus passed anyway because the size case
# pinned the threshold comparison rather than the measurement.
# `du -sk` is POSIX and works on both; multiply by 1024.
# Same exemption convention as the date rule: `# gnu-du: ok (<reason>)`.
PAT_GNUDU='(^|[^A-Za-z0-9_])du( +-[A-Za-z-]+)* +-[A-Za-z]*b|(^|[^A-Za-z0-9_])du[^|;&()]* --bytes'
GNUDU_EXEMPT='# gnu-du: ok'
# GNU-sed-only PERL CHARACTER CLASSES (\S \s \w \W \b \B \d \D). BSD sed does
# not implement them, and — this is the dangerous part — it does not error
# either: the pattern simply fails to match, so a substitution silently leaves
# the input UNCHANGED and whatever consumed it gets the whole line instead of
# the captured field.
#
# This is the family behind 803-bqte, the GNU-sed `\b` extension that made
# three markers write-only on macOS while every self-test passed on Linux —
# cited in the comments of this very file and, until now, not guarded by it.
# Measured again 2026-08-26 on tlatoanis-macbook-air: the curl-install e2e
# runbook parsed SMOKE_BASE with `sed -E 's/.* base:(\S+)$/\1/'` while the
# line directly above it used the portable `[^ ]+`. On macOS SMOKE_BASE became
# the entire `channel:… tag:… base:…` line and every release URL built from it
# was malformed. Two adjacent lines, one portable, one not, and only one lane
# ever ran them.
#
# Use a bracket expression (`[^ ]`, `[[:space:]]`, `[[:alnum:]_]`) instead.
# Scoped to sed invocations so a `\d` in an awk or grep -P call elsewhere does
# not trip it. Line-level exemption: `# gnu-sed: ok (<reason>)`.
PAT_GNUSED='(^|[^A-Za-z0-9_])sed[^|;&()]*\\[SsWwBbDd]'
GNUSED_EXEMPT='# gnu-sed: ok'

in_allowlist() {
  case " $ALLOWLIST " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

has_refusal_guard() {
  # Either an executable early refusal (a BASH_VERSINFO check in the head),
  # or the dual-dialect marker for files that feature-PROBE the bash-4 form
  # and carry a working 3.2 fallback on the probe's failure branch
  # (agent-identity.sh's timestamp probe is the exemplar). The marker is a
  # visible, greppable claim — reviewers police that the fallback is real.
  head -40 "$1" 2>/dev/null | grep -qE 'BASH_VERSINFO|# bash-dialect: dual'
}

# Strip comments so documentation ABOUT a construct never trips the gate —
# only code does. Crude (a # inside a string also strips) but strictly
# conservative for a lint: it can only under-match inside strings, and a
# bash-4 expansion inside a string is not executed anyway.
code_of() {
  sed 's/#.*$//' "$1" 2>/dev/null
}

unguarded=0
allowlisted_hits=0
# build.sh carries the gate's own phase telemetry, so it is scanned too
# (766-tdij) — unless a fixture redirects the scan dir.
# Subdirectories too (784-dwkh): scripts/hooks/, scripts/test-support/ and
# scripts/fixtures/ were invisible to the first cut, and scripts/hooks/ is
# where a dialect bug hurts most — pre-commit-openspec.sh's `date -d` failure
# landed on a `|| continue`, so its staleness warning could never fire on
# macOS and looked exactly like "nothing is stale".
SCAN_FILES=""
# A SINGLE FILE is a legitimate scan target: a litmus pinning one script wants
# that script judged, not the whole tree beside it. Until 798-tk7b it was not
# handled — a file fell through both globs below, matched nothing, and the
# script printed `ok:bash-dialect-clean`. Measured 2026-08-18 against a copy
# carrying BOTH `${v^^}` and `declare -A`: reported clean, rc=0.
if [ -f "$SCAN_DIR" ]; then
  SCAN_FILES="$SCAN_DIR"
else
  for _c in "$SCAN_DIR"/*.sh "$SCAN_DIR"/*/*.sh; do
    [ -f "$_c" ] && SCAN_FILES="$SCAN_FILES $_c"
  done
fi
if [ -z "${TILLANDSIAS_DIALECT_SCAN_DIR:-}" ] && [ -f build.sh ]; then
  SCAN_FILES="$SCAN_FILES build.sh"
fi

# A SCAN THAT CONSIDERED NOTHING IS NOT A CLEAN SCAN. With the file case fixed
# above, the remaining way to reach zero files is a SCAN_DIR that does not
# exist — a typo, or a directory renamed out from under a caller — and that
# used to yield a confident green from a gate wired into ./build.sh --check.
# Same family as everything else this gate guards against: the answer was not
# missing, it was wrong.
if [ -z "$SCAN_FILES" ]; then
  echo "blocked:bash-dialect:scan-empty"
  echo "[check-bash-dialect] TILLANDSIAS_DIALECT_SCAN_DIR='${SCAN_DIR}' matched no .sh file." >&2
  echo "  CAUSE: the path is neither a readable file nor a directory containing *.sh or */*.sh. Nothing was judged." >&2
  echo "  REMEDY: point it at an existing directory or a single .sh file. Do not read this as a passing dialect check — no file was read at all." >&2
  exit 1
fi

for f in $SCAN_FILES; do
  [ -f "$f" ] || continue
  base="${f##*/}"
  [ "$base" = "$SELF_NAME" ] && continue
  case "$base" in test-check-bash-dialect*) continue ;; esac
  hits="$(code_of "$f" | grep -nE "$PAT_EXPANSION|$PAT_BUILTIN|$PAT_ASSOC|$PAT_PRINTF_T" || true)"
  if [ -n "$hits" ]; then
    if has_refusal_guard "$f"; then
      :
    elif in_allowlist "$base"; then
      allowlisted_hits=$((allowlisted_hits + 1))
    else
      echo "[check-bash-dialect] UNGUARDED bash-4-ism in '$f' (first hits):" >&2
      printf '%s\n' "$hits" | head -3 >&2
      unguarded=$((unguarded + 1))
    fi
  elif in_allowlist "$base"; then
    echo "[check-bash-dialect] note: '$base' is allowlisted but carries no bash-4-ism any more — shrink the allowlist (761-g36m burndown)" >&2
  fi

  # GNU-date-isms (766-tdij): the BASH_VERSINFO guard and the allowlist say
  # nothing about date(1), so these are judged per line — exempt only via a
  # raw-line `# gnu-date: ok (<reason>)` marking a digit-validated fallback
  # or provably-harmless garbage.
  gnudate_bad=""
  _gd="$(code_of "$f" | grep -nE "$PAT_GNUDATE" || true)"
  if [ -n "$_gd" ]; then
    while IFS= read -r _h; do
      [ -n "$_h" ] || continue
      _ln="${_h%%:*}"
      # A BSD arm (date -v / -j / -jf / -r / -f) on the same LOGICAL command
      # makes the line self-portable — the GNU form fails on BSD and the
      # `||` chain catches it. Three things the first cut got wrong, all
      # found against the real corpus (784-dwkh):
      #   - intervening flags: `date -j -u -f '%s' …`, `date -u -r "$e"`
      #   - attached values:   `date -v-30d +%s`
      #   - CONTINUATION LINES: the arm often sits on the next line after a
      #     trailing backslash, so a strictly same-line search flagged three
      #     already-portable files and buried the one real defect.
      # Scanning a small following window is deliberately generous: a lint
      # that cries wolf gets muted, and the true positive is what matters.
      if sed -n "${_ln},$((_ln + 2))p" "$f" 2>/dev/null \
           | grep -qE 'date( +-[A-Za-z-]+)* +-(v|j|jf|r|f)'; then
        continue
      fi
      if sed -n "${_ln}p" "$f" | grep -qF "$GNUDATE_EXEMPT"; then
        continue
      fi
      gnudate_bad="${gnudate_bad}${_h}
"
    done <<< "$_gd"
  fi
  if [ -n "$gnudate_bad" ]; then
    echo "[check-bash-dialect] UNEXEMPTED GNU-date-ism in '$f' (BSD date succeeds with garbage output — exit-code guards cannot catch it):" >&2
    printf '%s' "$gnudate_bad" | head -3 >&2
    unguarded=$((unguarded + 1))
  fi

  # GNU-du-isms. Judged per line like the date rule, and for the same reason:
  # neither the version guard nor the allowlist says anything about du(1).
  # A BSD-portable arm on the same logical command (a `du -sk`/`-sm`/`-sh`
  # fallback in a `||` chain) makes the line self-portable, so scan a small
  # following window before flagging — a lint that cries wolf gets muted.
  gnudu_bad=""
  _du="$(code_of "$f" | grep -nE "$PAT_GNUDU" || true)"
  if [ -n "$_du" ]; then
    while IFS= read -r _h; do
      [ -n "$_h" ] || continue
      _ln="${_h%%:*}"
      if sed -n "${_ln},$((_ln + 2))p" "$f" 2>/dev/null \
           | grep -qE 'du( +-[A-Za-z-]+)* +-[A-Za-z]*(k|m|h)'; then
        continue
      fi
      if sed -n "${_ln}p" "$f" | grep -qF "$GNUDU_EXEMPT"; then
        continue
      fi
      gnudu_bad="${gnudu_bad}${_h}
"
    done <<< "$_du"
  fi
  if [ -n "$gnudu_bad" ]; then
    echo "[check-bash-dialect] UNEXEMPTED GNU-du-ism in '$f' (BSD du REFUSES -b, so the substitution is empty and a '|| n=0' fallback silently becomes the answer):" >&2
    printf '%s' "$gnudu_bad" | head -3 >&2
    unguarded=$((unguarded + 1))
  fi

  # GNU-sed perl classes. Judged per line like the date and du rules. No
  # following-window escape here: unlike `du`, there is no portable sed arm you
  # can put beside a non-portable one — the substitution either uses a bracket
  # expression or it does not. Exempt only via the raw-line marker.
  gnused_bad=""
  _gs="$(code_of "$f" | grep -nE "$PAT_GNUSED" || true)"
  if [ -n "$_gs" ]; then
    while IFS= read -r _h; do
      [ -n "$_h" ] || continue
      _ln="${_h%%:*}"
      if sed -n "${_ln}p" "$f" | grep -qF "$GNUSED_EXEMPT"; then
        continue
      fi
      gnused_bad="${gnused_bad}${_h}
"
    done <<< "$_gs"
  fi
  if [ -n "$gnused_bad" ]; then
    echo "[check-bash-dialect] UNEXEMPTED GNU-sed class in '$f' (BSD sed does not implement \\S \\s \\w \\b \\d and does NOT error — the substitution silently leaves the input unchanged, so the consumer gets the whole line; see 803-bqte):" >&2
    printf '%s' "$gnused_bad" | head -3 >&2
    unguarded=$((unguarded + 1))
  fi
done

if [ "$unguarded" -gt 0 ]; then
  echo "[check-bash-dialect] $unguarded file(s) carry bash-4-only constructs with no BASH_VERSINFO refusal guard and no allowlist entry. Either write the script bash-3.2-clean (see agent-identity.sh's case-table lowercase) or add an early exit-nonzero version refusal. Do NOT extend the allowlist — it is a burndown list (761-g36m)." >&2
  echo "blocked:bash4-unguarded:$unguarded"
  exit 1
fi
[ "$allowlisted_hits" -gt 0 ] && \
  echo "[check-bash-dialect] $allowlisted_hits allowlisted legacy carrier(s) remain (761-g36m burndown)" >&2
echo "ok:bash-dialect-clean"
exit 0
