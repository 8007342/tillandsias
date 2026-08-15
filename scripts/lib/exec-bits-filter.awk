# @trace order:758-jw6v, spec:ci-release
#
# Filter half of scripts/check-script-exec-bits.sh.
#
# Usage: awk -f exec-bits-filter.awk <candidates-file> <hits-file>
#   candidates-file: one candidate script path per line
#   hits-file:       `grep -nH` output over the caller corpus
#   stdout:          "<path>\t<first matching caller line>" per offending path
#
# WHY THIS IS A FILE AND NOT AN INLINE PROGRAM. The inline version was written
# twice at 5am and broken twice, both times by shell quoting rather than by
# logic: the regexes carry backslashes and double quotes that have to survive
# interpolation, and an apostrophe in a COMMENT silently closed the
# single-quoted program. In a file, the shell never sees any of it.
#
# WHY IT EXISTS AT ALL. The checker ran `xargs grep` over all 612 caller files
# once PER candidate — about sixteen thousand file-greps — and then a
# four-process filter chain per candidate on top. Measured 16.3s standalone and
# 30s inside ./build.sh --check, which a cycle runs three or four times. On this
# host a process spawn costs far more than the work it does, so the fix is the
# same one 734-sjb3 applied twice: stop doing per-item subprocesses.
#
# THE ANCHORING RULE THAT MATTERS. The positive pattern must be applied to the
# FILE CONTENT, never to grep's "file:lineno:content" output line. Its "^"
# alternative means start-of-source-line; matched against the output line, "^"
# anchors at the filename, and a bare invocation at the start of a line stops
# matching entirely. A first attempt got this wrong and still looked correct,
# because "echo hi | scripts/x.sh" kept matching on its pipe.
#
# The "^path:" exclusion is the opposite: it IS about the output line, since it
# drops a script that merely matched inside itself.

NR == FNR {
    if ($0 != "") cand[++n] = $0
    next
}

{
    line = $0
    if (line == "") next

    # Strip grep's "file:lineno:" prefix to recover the source line.
    content = line
    if (match(content, /^[^:]*:[0-9]+:/)) content = substr(content, RSTART + RLENGTH)

    for (i = 1; i <= n; i++) {
        p = cand[i]
        if (p in found) continue

        # Two alternatives, deliberately not one wider character class.
        # Command substitution ends in ")", so a single pattern ending
        # ([[:space:]"]|$) could never see $(scripts/x.sh) -- the very form the
        # checker exists to catch. But allowing ")" generally makes "(path)" in
        # PROSE match, because "(" is already a leading delimiter, and that
        # flagged three comments including a sourced library that must stay
        # non-executable. So ")" is permitted only after "$(".
        bare  = "(^|[;&|(])[[:space:]]*\"?" p "([[:space:]\"]|$)"
        subst = "\\$\\([[:space:]]*\"?" p "([[:space:]\")]|$)"
        if (content !~ bare && content !~ subst) continue

        # Naming an interpreter works at any mode; sourcing is not execution.
        if (content ~ ("(bash|sh|source|\\.)[[:space:]]+\"?" p)) continue

        # The script matching inside itself is not a caller.
        if (line ~ ("^" p ":")) continue

        found[p] = line
    }
}

END {
    # Emit in candidate order so the output is stable across runs; awk's
    # for-in iteration order is not specified and a checker whose output
    # reorders between runs is a diff generator.
    for (i = 1; i <= n; i++) {
        p = cand[i]
        if (p in found) print p "\t" found[p]
    }
}
