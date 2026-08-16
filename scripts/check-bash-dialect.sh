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
# freshness: filed 2026-08-16 macos 761-g36m
set -u

SCAN_DIR="${TILLANDSIAS_DIALECT_SCAN_DIR:-scripts}"
SELF_NAME="check-bash-dialect.sh"

# Known-legacy carriers, each pre-dating this gate (761-g36m residual — burn
# this list DOWN, never add to it; a new entry means a new unguarded
# bash-4-ism shipped, which is what this gate exists to refuse).
#
# The gate's first live run shrank this from the sweep's 8 candidates to 3:
# five carried the constructs in COMMENTS only (the raw sweep grep did not
# strip comments; this checker does).
ALLOWLIST="check-running-image-freshness.sh loop-success-probe.sh \
selective-tillandsias-reset.sh"

# Constructs bash 3.2 cannot parse or lacks. Plain literals are safe: this
# file is excluded from the scan by name, so self-matching cannot happen.
PAT_EXPANSION='\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^)'
PAT_BUILTIN='(^|[^A-Za-z0-9_])(mapfile|readarray)([^A-Za-z0-9_]|$)'
PAT_ASSOC='declare -A'
PAT_PRINTF_T='%\([^)]*\)T'

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
for f in "$SCAN_DIR"/*.sh; do
  [ -f "$f" ] || continue
  base="${f##*/}"
  [ "$base" = "$SELF_NAME" ] && continue
  case "$base" in test-check-bash-dialect*) continue ;; esac
  hits="$(code_of "$f" | grep -nE "$PAT_EXPANSION|$PAT_BUILTIN|$PAT_ASSOC|$PAT_PRINTF_T" || true)"
  [ -n "$hits" ] || {
    if in_allowlist "$base"; then
      echo "[check-bash-dialect] note: '$base' is allowlisted but carries no bash-4-ism any more — shrink the allowlist (761-g36m burndown)" >&2
    fi
    continue
  }
  if has_refusal_guard "$f"; then
    continue
  fi
  if in_allowlist "$base"; then
    allowlisted_hits=$((allowlisted_hits + 1))
    continue
  fi
  echo "[check-bash-dialect] UNGUARDED bash-4-ism in '$f' (first hits):" >&2
  printf '%s\n' "$hits" | head -3 >&2
  unguarded=$((unguarded + 1))
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
