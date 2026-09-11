#!/usr/bin/env bash
# @trace order:1059-pb2j
#
# A litmus step whose NAME promises a MUTATION or SABOTAGE must have a COMMAND
# that performs one.
#
# THE SHAPE. The step's name carries the guarantee and its command does not. A
# reader auditing the suite reads names; a reader auditing the commands is doing
# the work the name was supposed to save them. That gap is why this is
# mechanised rather than corrected case by case.
#
# THREE INSTANCES, EACH FOUND A DIFFERENT WAY, none by looking for this class:
#
#   1029-5wvd  a mutation that silently FAILED TO APPLY. The arm ran, the edit
#              did not land, and the green was indistinguishable from a blind
#              guard's green. Taught: a mutation arm must observe the failure
#              it causes, not merely attempt it.
#   1033-ev5r  a sabotage arm whose text AVOIDED the literal string it was meant
#              to trip, so it exercised a shape already refused and never
#              reached the branch the change had added. Found in a second-host
#              review; the author's own negative control missed it. Taught: an
#              arm can be well-formed and still test the wrong thing.
#   1059-pb2j  litmus-lww-channel-fields-alias.yaml, found by the standing
#              freshness audit 2026-09-05. Named "MUTATION: with the alias
#              removed from the reader, the fixture must FAIL" over a command
#              that was a `grep -q` for a source string: it removed nothing,
#              re-ran nothing, and observed no failure. Renamed to SOURCE PIN at
#              5083b2649 rather than deleted, because a source pin has smaller
#              real value. Taught: the remedy is a RENAME, so this guard refuses
#              the NAME, never the technique.
#
# NOT A CLAIM THAT EVERY SUCH ARM IS WRONG. A step may legitimately be named for
# the defect it pins while asserting a source shape — that is what the renamed
# arm now is. The defect is the MISMATCH between a name promising a behavioural
# mutation and a command performing none.
#
# DELEGATION COUNTS AS MUTATING, and this is the distinction that keeps the
# guard usable. litmus-fragment-status-loss-attribution-shape.yaml has a
# MUTATION CONTROL whose command is `bash scripts/test-fragment-status-loss.sh`
# — the mutation happens inside that fixture. Refusing it would force a rename
# of a correct arm, and a guard that flags correct work gets switched off.
#
# WHAT COUNTS AS A WRITE, and why redirections mostly do not. `>/dev/null`,
# `2>&1` and `>&2` are the commonest tokens in this corpus and none of them
# changes anything under test; an early draft of the SIZING for this packet
# counted them and reported 0 candidates out of 3, which is how a sweep can be
# both precise and worthless.
#
# SABOTAGE IS IN THE NAME PATTERN AND HAS ZERO INSTANCES TODAY, measured across
# all 413 litmus files. It is kept because the packet names the class that way
# and because a pattern that only matches what already exists cannot catch the
# next one.
#
# Grammar (one line on stdout):
#   ok:litmus-mutation-arms:<flagged> of <named> named arms, <steps> steps scanned
#   violation:litmus-mutation-arm-mutates-nothing:<n>
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

DIR="${1:-openspec/litmus-tests}"

# REWRITTEN FROM PYTHON TO AWK, 2026-09-06. `tlatoani_hard_no_python` forbids
# a Python runtime in committed scripts (methodology.yaml:170); this file
# shipped one at bde83aa26 and blocked the v56.9.6.1 release gate. Rewritten
# rather than exception-requested, because the logic needs no Python.
#
# THE ONE TRANSLATION THAT IS NOT MECHANICAL. The Python WRITE pattern used
# negative lookahead — `printf[^|;&]*>(?!\s*(?:/dev/null|&\s*2))` — to say "a
# redirect that is not to /dev/null or fd 2". POSIX ERE has no lookahead, and
# awk uses ERE. Rather than approximate it, the excluded redirections are
# DELETED FROM THE PROBE FIRST; after that a plain `>` means a real write and
# no lookahead is needed. Same decision expressed as normalisation instead of
# as a negative assertion, and exactly equivalent because the only reason the
# lookahead existed was to skip those two forms. Verified: an arm whose only
# redirect is `>/dev/null` is still flagged.
#
# WORD BOUNDARIES ARE EXPLICIT because `\b` is a GNU extension: mawk and the
# BSD awks lack it, and a boundary that silently never matches turns this into
# a guard reporting `ok` over an unexamined corpus. B and E are those classes.
#
# VERIFIED IDENTICAL to the Python it replaces, on the real corpus:
#   ok:litmus-mutation-arms:0 of 4 named arms, 2494 steps scanned
awk -v q="\"'" '
function strip(s) {
    # A `#` that starts a token. `#` inside a word (a sha, a printf format) is
    # kept, so real code is not eaten: criterion 3 is what the command DOES.
    gsub(/(^|[ \t])#[^\n]*/, " ", s)
    # Redirections that change nothing under test. Deleting them is what
    # removes the need for lookahead below.
    gsub(/>>?[ \t]*(\/dev\/null|&[ \t]*2)/, " ", s)
    return s
}
function mutates(s,   B, E, simple) {
    B = "(^|[^A-Za-z0-9_./-])"
    E = "([^A-Za-z0-9_-]|$)"
    simple = "(tee|cp|mv|rm|chmod|chown|install|mkdir|touch|trap|mktemp|truncate|patch)"
    if (s ~ B simple E) return 1
    if (s ~ B "sed[ \t]+-i" E) return 1
    if (s ~ B "git[ \t]+(checkout|restore|stash|apply|revert|reset|init|commit|add|clone)" E) return 1
    if (s ~ B "cat[ \t]*<<") return 1
    if (s ~ B "printf[^|;&]*>") return 1
    if (s ~ B "echo[^|;&]*>") return 1
    if (s ~ />>/) return 1
    # DELEGATION COUNTS AS MUTATING — the mutation lives inside the fixture the
    # command hands off to. The boundary class MUST include the quote
    # characters: a litmus command is a YAML scalar, so the character before
    # the path is very often `"`. With whitespace only, `"bash scripts/x.sh"`
    # matched via the space after bash but `"scripts/x.sh"` did not, and order
    # 147 hit exactly that — a delegating MUTATION arm refused as mutating
    # nothing, by a guard pinning a quoting style rather than the property.
    if (s ~ "(^|[ \t;&|(" q "])((bash|sh)[ \t]+|\\./)?scripts/[A-Za-z0-9_.-]+\\.sh") return 1
    return 0
}
function flush_step(   probe) {
    if (name == "") return
    steps++
    if (name ~ /MUTATION|SABOTAGE/) {          # case-sensitive: the corpus shouts them
        named++
        probe = strip(body)
        if (!mutates(probe)) {
            bad++
            badfile[bad] = file
            badname[bad] = substr(name, 1, 160)
        }
    }
    name = ""; body = ""
}
FNR == 1 { flush_step(); file = FILENAME }
{
    # THE ORIGINAL IS ASYMMETRIC AND THIS REPRODUCES IT DELIBERATELY. The
    # Python began a step on `\s*-?\s*step:` (dash OPTIONAL) but ended a body
    # on `\s*-\s*step:` (dash REQUIRED), so a dash-less `step:` inside a body
    # was absorbed as body text rather than counted. Treating both alike counts
    # one extra step across the corpus (2495 vs 2494), measured. Whether the
    # asymmetry is right is a separate question from whether this port changed
    # behaviour, and a language port is the wrong place to settle it.
    if (match($0, /^[ \t]*-[ \t]*step:[ \t]*/) ||
        (name == "" && match($0, /^[ \t]*step:[ \t]*/))) {
        flush_step()
        name = substr($0, RSTART + RLENGTH)
        sub(/[ \t]+$/, "", name)
        next
    }
    if (name != "") body = body "\n" $0
}
END {
    flush_step()
    if (bad > 0) {
        printf "violation:litmus-mutation-arm-mutates-nothing:%d\n", bad
        for (k = 1; k <= bad; k++) {
            printf "  %s\n", badfile[k] > "/dev/stderr"
            printf "    step: %s\n", badname[k] > "/dev/stderr"
        }
        print "  A step NAMED for a mutation must perform one, or delegate to a" > "/dev/stderr"
        print "  fixture that does. The remedy is a RENAME (SOURCE PIN, or what the" > "/dev/stderr"
        print "  command actually asserts), not a deletion and not an exception —" > "/dev/stderr"
        print "  every instance so far was renamed (1059-pb2j)." > "/dev/stderr"
        exit 1
    }
    printf "ok:litmus-mutation-arms:0 of %d named arms, %d steps scanned\n", named, steps
}
' "$DIR"/*.yaml
