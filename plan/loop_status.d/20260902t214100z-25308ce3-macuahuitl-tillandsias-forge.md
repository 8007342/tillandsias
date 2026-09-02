## Cycle 2026-09-02T21:41:00Z — macuahuitl-tillandsias-forge (forge, linux-next)

Third story this session: 966-7umc — append-event wrote the folded
plan/index.yaml, outside the plan-only push lane. Landed 823e3ac0d, released.

DECIDED, not assumed: the FRAGMENT becomes the default write target, rather
than teaching the lane to admit a bounded index append. The lane admits only
NEW files under the four overlay dirs because each has a closure needing no
compiler. Admitting an append to plan/index.yaml would mean diffing a 31k-line
YAML file to decide whether a change is a pure append to one packet's event
list — a validator with more surface than the thing it protects, whose bugs are
silent. The overlay exists, set-field already writes to it, and the fold reads
events from fragments identically. The ASYMMETRY between the two write paths
was the defect; there was no missing feature.

SECOND DEFECT, same place: this path never called verify_written_parses, which
set-field has had since 775-b4qz. A fragment the fold skips is INVISIBLE — the
write prints success and the finding is absent from every answer, strictly
worse than a refusal, and exactly what today's hand-authored fragment did to
the fleet. The fix that removes the incentive to hand-write and the fix that
catches a bad write belong together.

The base is no longer read here at all — it was read only to locate the
packet's block for an in-place append. A scout writing four lines no longer
pulls a 31k-line ledger into memory.

FALSIFICATION SET, as instructed: forge-pids-ceiling-512 and
litmus-low-end-instrument (esmeraldinha WSL2 floor host) and
cpu-only-forge-expert-system-integration-gaps (lenovinha CPU-only forge) —
the three packets whose findings were hand-authored today — each now accept
append-event and produce a lane-eligible fragment with plan/index.yaml
byte-identical.

CLOSURE: two arms on litmus:plan-only-push-lane-shape driving the REAL binary
and a REAL git push from a forge-shaped environment. One ACCEPT, one MUTATION
proving the same finding written into the base is still refused — without the
second, the first would be agreeing with the lane rather than demonstrating the
fix. 12/12 steps, spec 18/18.

FOURTH INSTANCE of the ambient-fixture pattern, found because this spec had to
go green here and worth stating plainly: eight arms of the plan-only lane
litmus install a hook at <fixture>/.git/hooks/pre-push, which the forge's
global core.hooksPath replaces. The hook never ran, the push SUCCEEDED
UNVALIDATED (rc=0), and the arm failed only on its missing markers. A lane test
that was not testing the lane, on any forge. Pinned in all eleven fixture
repos. Same root cause as the test-pre-push-empty-ref-list instance fixed this
morning — two independent fixtures, one global setting, found a day apart.

Pirria's generalisation recorded on the pattern issue, and it is the sharp
form: a fixture must pin every environment variable and git setting its subject
branches on, because the ambient value is set by the very protocol the fixture
exists to serve. The dangerous variables are not random noise — they are
precisely the ones this project sets on purpose.

RESIDUAL: `compact` still rewrites the base and is correctly outside the lane.
Nothing here changes that and nothing should.
