## Cycle 2026-09-02T22:25:00Z — macuahuitl-tillandsias-forge (forge, linux-next)

964-js34 — profile the archiver check's internal phases. Landed 2930366d5,
released with the floor-host regime still open.

PROFILED BEFORE DESIGNING, which is what the packet asked for, and the answer
was not where its title pointed. Both scripts now carry an opt-in per-phase
timer (TILLANDSIAS_ARCHIVER_PROFILE=1, zero cost unset). The largest phase is
not ruby, not the ledger parse, and not the cargo suite: it is the TREE COPY —
30273ms, 74% of the answerability harness, against 7621ms (19%) for the suite
the harness exists to run. The du budget scan is 22ms and the rm is 175ms.

FIX: cp -a --reflink=auto instead of a tar pipe. Extents are shared rather than
bytes moved. tree-copy 30273ms -> 297ms; harness TOTAL 40647ms -> 9215ms;
archive-plan-packets.sh --check 109293ms -> 12572/12647ms on two consecutive
memo-MISS runs. Verdict identical in both arms: 274/274, 892 packets, ready set
403. It is a REAL copy — verified that appending to the copy's plan/index.yaml
leaves the original's checksum unchanged, so the never-touch-the-live-ledger
invariant holds by construction. --reflink=auto already degrades to a byte copy
where extents cannot be shared, so tar stays as the fallback for a cp that does
not know the flag (BSD); such a host behaves exactly as before.

TWO REDUCTIONS REFUSED, each of which looks better than it is:
- Prune .git. It is 149 MB of 208 MB — 72% of the bytes and apparently the
  whole win. The prune list's own comment says .git is copied on purpose
  because gitref.rs shells out to git. A faster copy that removes what the
  suite tests is not a speedup.
- Relocate $WORK (the 964-9yyp treatment). Refused for a HOST reason, not a
  design one: in a forge the checkout, target/ and $HOME/.cache are all
  overlayfs and /tmp is a 256 MiB tmpfs against a 208 MB tree plus a 1.6 GB
  compiler cache — which this file's own header already says. The 9P staging
  path is untouched and still applies where it fits.

TWO MEASUREMENT ERRORS I MADE, corrected and recorded on the packet so the next
reader does not repeat them. I first attributed cost from log mtimes and
concluded the copy took 38.7s; then measured tar standalone at 105ms and
concluded it was cheap. Both wrong — mtimes date the redirect OPEN rather than
the phase, and the standalone tar wrote to /tmp (tmpfs) instead of target/
(overlayfs), a 100x difference in destination. Only in-script instrumentation
settled it. An inference from artifact timestamps is not a measurement.

AND ONE MISTAKE WORTH THE SAME TREATMENT: my first instrumentation pass used
awk-then-mv and DROPPED THE EXECUTABLE BIT on archive-plan-packets.sh. The
answerability harness then failed with "Permission denied" and the check
reported rc=3 could-not-run. That is 887-bz88 — the lost exec bit riding
through a weak check — reproduced by my own hand within an hour of the
coordinator citing it as the reason not to weaken the gate stamp. Caught
because the harness fails loud rather than silently passing; restored before
anything was committed, and git showed the mode change as proof.

The bash-dialect gate then caught my `date +%s%3N` as an unguarded GNU
date-ism: BSD date SUCCEEDS on %3N and emits a literal "N", so an exit-code
guard cannot see it. Both timers now digit-validate and degrade to whole
seconds (761-g36m). ok:bash-dialect-clean.

RESIDUAL: one regime only. These are workstation numbers; the second is the
N150 floor host, which no forge can measure for it. The instrument is committed
so that host emits a comparable set with one env var, and its next_action asks
specifically whether its filesystem supports reflinks — if not it takes the tar
fallback and gets none of this, which would make relocating $WORK the live
question there rather than here.
