#!/usr/bin/env bash
# Fixture for order 901-jtvi — the litmus step model (mf_run/mf_stage/mf_holds/
# mf_first) in scripts/litmus-stdlib.sh.
#
# WHAT IT PINS, and every arm is a property the PIPED idiom cannot hold:
#   1. a failing producer becomes the verdict, instead of being swallowed
#   2. a passing producer is unchanged (the negative control that stops this
#      becoming "make everything red")
#   3. an INTENTIONAL non-zero producer is expressible — the case blanket
#      `pipefail` cannot distinguish from a real failure, and the reason
#      pipefail produced 4 false positives and 0 true ones on this corpus
#   4. first-N does not kill the producer
#   5. stderr is captured, not silently dropped
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
. scripts/litmus-stdlib.sh
fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

# 1. THE MASKING, and its removal. The piped form is asserted too, so this arm
#    fails if the hazard ever stops being real — a guard whose premise has
#    quietly gone away should say so rather than keep passing.
# Explicitly WITHOUT pipefail: this fixture sets it, and the premise is about
# the litmus runner's step shell, which does NOT. Asserting the hazard under
# this file's own options measured the wrong shell and failed — the premise
# check needs the environment it is a premise about.
if bash -c 'set +o pipefail; sh -c '"'"'echo "cargo build"; exit 7'"'"' | grep -q "cargo build"'; then
    ok "premise holds: in a pipefail-less shell (the runner's), the piped form masks exit 7"
else
    bad "the piped form no longer masks — this fixture's premise is stale"
fi
if mf_stage "producer" 0 SRC -- sh -c 'echo "cargo build"; exit 7' 2>/dev/null; then
    bad "mf_stage accepted a producer that exited 7"
else
    ok "mf_stage makes the producer's failure the verdict"
fi

# 2. NEGATIVE CONTROL: a genuinely passing producer still passes.
if mf_stage "producer" 0 OK1 -- sh -c 'echo "cargo build"' && mf_holds OK1 'cargo build'; then
    ok "a passing producer is unchanged"
else
    bad "a passing producer regressed"
fi

# 3. AN INTENTIONAL NON-ZERO IS EXPRESSIBLE. `script --bogus` exits 2 by
#    design; blanket pipefail calls that a failure, a step model lets it be
#    stated. This is the arm that distinguishes the two approaches.
if mf_stage "usage" 2 U -- sh -c 'echo "usage: capability"; exit 2' && mf_holds U 'capability'; then
    ok "an intentional non-zero exit is expressible, not a false positive"
else
    bad "could not express a producer whose non-zero exit is the point"
fi

# 4. NO SIGPIPE: taking the first N lines must not kill the producer. 5000
#    lines is well past a pipe buffer, so a live `| head -2` would signal it.
if mf_stage "long" 0 BIG -- sh -c 'i=1; while [ $i -le 5000 ]; do echo "line $i"; i=$((i+1)); done'; then
    got="$(mf_first BIG 2 | tr '\n' ',')"
    if [ "$got" = "line 1,line 2," ]; then
        ok "first-N reads a finished buffer; the producer survived (rc=$BIG_rc)"
    else
        bad "mf_first returned '$got'"
    fi
else
    bad "the long producer was killed — rc=$BIG_rc (SIGPIPE is 141)"
fi

# 5. STDERR IS CAPTURED, NOT DROPPED. Defect (4) in this packet's list was a
#    `2>/dev/null` that hid `ps: unknown option`, so a broken primitive returned
#    a confident wrong verdict. Discarding stderr must be a decision, not a
#    default.
mf_run E -- sh -c 'echo "to-stderr" >&2; exit 0'
if mf_holds E 'to-stderr'; then
    ok "stderr is captured by default"
else
    bad "stderr was dropped — a broken primitive would fail silently"
fi

# 6. BASH 3.2 / PORTABILITY: no PIPESTATUS anywhere in the model. It is
#    bash-only and EMPTY under zsh 5.9 (macOS's default shell) — defect (3) in
#    this packet's list, where the workaround for one platform silently failed
#    on another.
# COMMENT LINES EXCLUDED, and that exclusion is itself a finding: the first
# version of this arm was tripped by the step model's own comment explaining
# that it avoids PIPESTATUS. A guard fired by the documentation of the decision
# it guards — the same shape this repo has now recorded a dozen times. Assert
# the BEHAVIOUR (an actual reference), never the string.
if grep -vE '^[[:space:]]*#' scripts/litmus-stdlib.sh | grep -q 'PIPESTATUS'; then
    bad "litmus-stdlib.sh references PIPESTATUS — empty under zsh, breaks macOS"
else
    ok "no PIPESTATUS in the step model (portable to zsh/BSD)"
fi

if [ "$fail" -ne 0 ]; then
    echo "litmus-step-model: FAIL"
    exit 1
fi
echo "ok:litmus-step-model:all"
