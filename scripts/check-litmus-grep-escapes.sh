#!/usr/bin/env bash
# @trace order:901-jtvi
#
# check-litmus-grep-escapes.sh — refuse regex escapes GNU grep does not define,
# inside litmus step commands.
#
# ── WHAT HAPPENED, AND WHY A LINT RATHER THAN A LESSON ──────────────────────
#
# 2026-09-04. Two litmus steps matched a TAB-separated projection with
#   grep -qE '^hardware\t[a-z0-9-]+\tloci=[0-9]+\tcontrol=(yes|no)\t'
# They failed in the runner and passed every hand-check their author ran. The
# author reported the failure as SIGPIPE — reasonably, from a comment block read
# minutes earlier — and three hosts then spent an afternoon measuring pipe
# buffers. It was never SIGPIPE. GNU grep's ERE does not define `\t`: it warns
# `stray \ before t` on stderr and matches a literal `t`, so `^hardware\t` means
# `^hardwaret` and cannot match a real tab. rc=1, no match, step fails.
#
# THE REASON EVERY HAND-CHECK PASSED, and it is the part worth guarding:
#
#   interactive shell : `type grep` -> a FUNCTION (a ugrep compat wrapper)
#                       ugrep DOES interpret \t as a tab, so the pattern works
#   the runner        : /usr/bin/grep, GNU grep 3.12, which does not
#
# Shell functions are not exported, so a nested `bash -c` honestly reports
# /usr/bin/grep while the author's very next interactive command still gets
# ugrep. "I ran the command and it worked" was true and meant nothing. MEASURED
# ON THREE OF THREE LINUX HOSTS (lenovinha, yoga, macuahuitl); the function's
# origin was searched for and NOT located on any of them — not in ~/.bashrc,
# ~/.bash_profile, ~/.profile, /etc/bashrc, /etc/profile or /etc/profile.d.
# That is recorded as an unexplained condition rather than explained away,
# because a wrong pointer here would send the next reader to open those files,
# find nothing, and conclude the shadow was gone.
#
# Check your own host in three lines:
#   type grep
#   /usr/bin/grep --version | head -1
#   env -i /bin/bash -c 'command -v grep'
#
# ── THE ALLOWLIST IS MEASURED, NOT REMEMBERED ───────────────────────────────
#
# The rule this packet was scoped with was "refuse \t \d \s \w". HALF OF THAT IS
# WRONG, and shipping it would have flagged ten working lines across six files.
# Measured against /usr/bin/grep 3.12 by checking for the `stray \` warning:
#
#   defined (GNU extensions): \s \S \w \W \b \B \< \>  and \1..\9 backrefs
#   UNDEFINED (warns stray) : \t \d \n \r \0 \p \x \u \e \a
#
# `\s` and `\w` are GNU extensions and work correctly; `\t` and `\d` do not
# exist and silently mean the bare letter. So the refusal set is the second row,
# expressed as an allowlist of the first so a future GNU release adding an
# escape does not turn this guard into a false positive generator.
#
# A guard that fires on working code gets switched off, which is why the
# allowlist was derived by running the binary rather than by recalling PCRE.
#
# ── WHAT IS DELIBERATELY NOT REFUSED ────────────────────────────────────────
#
# `$(printf '\t')` is the CORRECT idiom and appears twelve times in
# litmus-cycle-batch-triage-shape.yaml. There the backslash is consumed by
# printf in the shell and grep receives a real tab, so grep's escape handling is
# never involved. Refusing it would refuse the fix. Those substitutions are
# removed before the line is examined.
#
# SIGPIPE is NOT this guard's business. The class is real — measured against
# /usr/bin/grep: a multi-line producer into `grep -q` OR `grep -qx` gives 141,
# while a single 4 MB line drains and gives 0/1 — but it is not what happened
# here, and 792-ksr8 owns that surface.
#
# GRAMMAR (one line on stdout)
#   ok:litmus-grep-escapes:<n> checked
#   violation:litmus-grep-escapes:<count>

set -uo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

DIR="${1:-openspec/litmus-tests}"
[ -d "$DIR" ] || { echo "ok:litmus-grep-escapes:0 checked (no $DIR)"; exit 0; }

# The rule lives in scripts/lib/litmus-grep-escapes.awk so the fixture can run it
# against controls without re-implementing the extraction. A second copy of the
# parser is a second thing to drift — the mistake 704-zcgi centralised the podman
# probe to stop making, and the reason the spec-index resolution block is pinned
# byte-identical across its carriers.
AWK_RULE="$REPO_ROOT/scripts/lib/litmus-grep-escapes.awk"
if [ ! -r "$AWK_RULE" ]; then
    echo "blocked:litmus-grep-escapes:rule-missing:$AWK_RULE" >&2
    exit 2
fi

checked="$(find "$DIR" -name '*.yaml' -type f | wc -l)"
hits="$(find "$DIR" -name '*.yaml' -type f | sort | xargs awk -f "$AWK_RULE" 2>/dev/null)"

if [ -z "$hits" ]; then
    echo "ok:litmus-grep-escapes:${checked} checked"
    exit 0
fi

printf '%s\n' "$hits" | sed 's/^/  /'
echo "      GNU grep warns 'stray \\ before <c>' and matches the BARE LETTER, so"
echo "      '^col\\t' means '^colt' and never matches a tab. Your interactive shell"
echo "      may resolve a DIFFERENT grep than the runner does — see this script's"
echo "      header, and check with: type grep; env -i /bin/bash -c 'command -v grep'"
echo "      Fix: \"\$(printf '\\t')\", or awk -F'\\t', or a case pattern."
echo "violation:litmus-grep-escapes:$(printf '%s\n' "$hits" | wc -l)"
exit 1
