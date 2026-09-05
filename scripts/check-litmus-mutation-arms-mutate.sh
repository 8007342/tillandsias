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

python3 - "$DIR" <<'PY'
import re, sys, glob, os

d = sys.argv[1]
NAMED = re.compile(r'MUTATION|SABOTAGE')          # case-sensitive: the corpus shouts them

# Verbs that change something, or restore it. Redirections to /dev/null and to
# fd 2 are excluded deliberately -- see the header.
WRITE = re.compile(r"""(
      \bsed\s+-i\b | \btee\b | \bcp\b | \bmv\b | \brm\b | \bchmod\b | \bchown\b
    | \binstall\b | \bmkdir\b | \btouch\b | \btrap\b | \bmktemp\b | \btruncate\b
    | \bgit\s+(?:checkout|restore|stash|apply|revert|reset|init|commit|add|clone)\b
    | \bpatch\b | \bcat\s*<< | \bprintf\b[^|;&]*>(?!\s*(?:/dev/null|&\s*2))
    | \becho\b[^|;&]*>(?!\s*(?:/dev/null|&\s*2))
    | >>(?!\s*(?:/dev/null|&\s*2))
)""", re.X)

# Delegation: the command hands off to a repo script, which is where the
# mutation lives. Treated as mutating.
DELEGATE = re.compile(r'(?:^|[\s;&|(])(?:bash\s+|sh\s+|\./)?scripts/[\w.-]+\.sh\b')

def strip_shell_comments(s: str) -> str:
    # Best effort: a '#' that starts a token. Keeps '#' inside words (e.g. a
    # sha or a printf format) so real code is not eaten. Criterion 3: what the
    # command DOES, not what it mentions.
    return re.sub(r'(?:^|\s)#[^\n]*', ' ', s)

steps = 0
named = 0
bad = []

for f in sorted(glob.glob(os.path.join(d, '*.yaml'))):
    lines = open(f, encoding='utf-8').read().split('\n')
    i = 0
    while i < len(lines):
        m = re.match(r'\s*-?\s*step:\s*(.*)', lines[i])
        if not m:
            i += 1
            continue
        steps += 1
        name = m.group(1).strip()
        j = i + 1
        body = []
        while j < len(lines) and not re.match(r'\s*-\s*step:', lines[j]):
            body.append(lines[j])
            j += 1
        cmd = '\n'.join(l for l in body if re.match(r'\s*(command|expected_behavior)?\s*:', l) or l.strip())
        if NAMED.search(name):
            named += 1
            probe = strip_shell_comments(cmd)
            if not (WRITE.search(probe) or DELEGATE.search(probe)):
                bad.append((f, name))
        i = j

if bad:
    print(f"violation:litmus-mutation-arm-mutates-nothing:{len(bad)}")
    import sys as _s
    for f, n in bad:
        print(f"  {f}", file=_s.stderr)
        print(f"    step: {n[:160]}", file=_s.stderr)
    print("  A step NAMED for a mutation must perform one, or delegate to a", file=_s.stderr)
    print("  fixture that does. The remedy is a RENAME (SOURCE PIN, or what the", file=_s.stderr)
    print("  command actually asserts), not a deletion and not an exception —", file=_s.stderr)
    print("  every instance so far was renamed (1059-pb2j).", file=_s.stderr)
    sys.exit(1)

print(f"ok:litmus-mutation-arms:0 of {named} named arms, {steps} steps scanned")
PY
