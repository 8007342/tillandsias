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

    # ORDER 754-kptj. Two lead-ins that are execution sites and were invisible
    # to every pattern below. Defined ONCE, and as NAMED variables rather than
    # inlined four times, so litmus:script-exec-bit-shape can grep for the
    # widening the same way it already greps for `yamlcmd`.
    #
    # MEASURED before landing, over all 384 tracked scripts promoted to
    # candidates so every latent noise shape fired: 127 paths flagged before,
    # 129 after. The two new rows are both genuine — run-observatorium.sh
    # (litmus-clickable-trace-index-observatorium-skeleton.yaml:23) and
    # test-image-build-convergence.sh (litmus-image-build-convergence-shape
    # .yaml:16). Zero false positives.
    #
    # EXPLICIT NON-GOALS, so the next reader does not "complete" the set: a
    # backtick `scripts/x.sh` is NOT matched — all 16 occurrences in the corpus
    # are Markdown prose inside descriptions, and widening for them would be
    # pure noise. Neither is $VAR/scripts/x.sh. The narrowness of this checker
    # is the reason it is trusted.
    dotslash = "(\\./)?"
    envpfx   = "([A-Za-z_][A-Za-z_0-9]*=[^[:space:]]*[[:space:]]+)*"

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
        bare  = "(^|[;&|(])[[:space:]]*\"?" dotslash p "([[:space:]\"]|$)"
        subst = "\\$\\([[:space:]]*\"?" dotslash p "([[:space:]\")]|$)"
        # A litmus step's `command:` is an execution site, but its path is
        # preceded by ": \"" -- a lead-in none of the shell delimiters above
        # accept, so every litmus-only caller was invisible and the guard
        # reported a clean tree it had not examined (order 770-dyqr; live case
        # 2026-08-16, two scripts at mode 100644 invoked from
        # litmus-release-artifact-integrity.yaml STEP 5, rc=126 at runtime
        # while this checker printed ok). Keyed on the literal `command:` and
        # not on a general ":" lead-in, because ":" appears throughout prose and
        # the narrowness of this checker is the reason it is trusted.
        # envpfx uses `*` and not `+` deliberately: zero assignments must stay
        # legal, or the plain `command: "scripts/x.sh"` form — the 770-dyqr
        # breach case this line was added for — stops matching entirely.
        yamlcmd = "command:[[:space:]]*\"?" envpfx dotslash p "([[:space:]\"]|$)"
        if (content !~ bare && content !~ subst && content !~ yamlcmd) continue

        # Naming an interpreter works at any mode; sourcing is not execution.
        #
        # The `dotslash` here is DEFENSIVE, NOT load-bearing, and this comment
        # says so because the first draft claimed the opposite. Measured: with
        # `bash ./scripts/x.sh`, none of the three positive patterns match in
        # the first place — each requires the path immediately after its lead-in,
        # and `bash ` intervenes — so this exclusion is never consulted for the
        # ./ form, and removing the `dotslash` from it changes no verdict on
        # this corpus. It is kept so the exclusion stays at least as wide as the
        # patterns it guards, which is the invariant that matters if those ever
        # widen again. Do NOT write a fixture scenario asserting this line is
        # load-bearing: such a scenario passes whatever this line says, and a
        # control that cannot fail is worse than no control.
        if (content ~ ("(bash|sh|source|\\.)[[:space:]]+\"?" dotslash p)) continue

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
