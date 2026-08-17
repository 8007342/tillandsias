## Cycle 2026-08-17T02:24Z (linux-immutable yoga — cycle 8, hourly fleet loop)

626-p4xd PARTIAL SLICE landed (0cabca46b) — criteria 1, 2, 4, 5 met; only
criterion 3 (cold-cache repro, needs a destructive e2e slot) left open.

The defect in one line: every harness gate asked "does the binary start and
honour our flags?" and none loaded the RENDERER, so a build whose TUI cannot
initialize passed every gate, got installed, AND was recorded as last-good —
after which the rollback path re-validated with the same blind probe and
could restore-and-certify another broken snapshot. The user met the failure;
the gate never did.

opencode_render_contract_ok asserts POSITIVELY — within a budget the binary
must emit an alt-screen switch or truecolor SGR and must not have exited
nonzero — rather than grepping upstream's error text, which rots the moment
upstream rewords it. Wired into harness_probe so all THREE consumers inherit
it in one edit; memoized on the binary's sha256 so a launch's three probes
cost one render while a reinstall still re-probes (gating a NEW artifact is
the point). The 20s ceiling is sized for the bun single-file executable the
curl channel actually ships, whose first run pays a cold asset extraction —
not for the ELF the scoping timings came from.

The lock was ONE-SIDED, not absent as filed: ensure_forge_harnesses took it
while require_opencode wrote the same path in the foreground without it.
Extracted harness_update_lock_acquire/_release; the second writer now takes
the same lock, and failing to acquire is deliberately non-fatal there since
the other holder is installing the same binary.

Two things this cycle caught in its own work, both worth recording:
(a) The change broke litmus:harness-curl-install-shape, whose step asserted
the curl call within a THREE-LINE window after require_opencode. The lock
pushed it to line four and the step went red without the routing changing at
all. Widened to scan the function body — pin the property, not the source
layout (634-39ik). That pin was a latent tripwire for anyone editing that
function, not a defect I introduced.
(b) The cycle's timing telemetry named my own new litmus the slowest
instant-tier step in the corpus (20.3s) because it re-ran two sibling
fixtures that already run in the same suite. Removed; 20.3s -> 10.7s. The
telemetry earned its keep by catching the author.

Integration note: the leader merged a CONVERGENT CARGO_TARGET_DIR probe fix —
Windows found the same defect I fixed last cycle, same day, different cause
(their with-wsl2-builder.sh points CARGO_TARGET_DIR at a distro-native path
so target/ never lands on 9p). The merge kept one implementation and folded
both rationales into the comment, which is the right outcome: two independent
causes converging on one line is the argument for fixing it in the shared
probe rather than at either call site. My fixture still passes 5/5 over it.

Metrics (verbatim): experts: calls=1745 answered=1744 unsupported=1 degraded=0
errors=0 answer_rate=99% | expert_accuracy: pass=21 total=21 rate=100% |
mcp: servers=3 per_server=cli=1734;forge-plan=11;project-info=7 health=ok |
flow: cycles=7 avg_completed_per_cycle=1.57 avg_commits_per_cycle=4.57
overhead_ratio=2.91 | timing: steps=103 build_check_ms_avg=16479
litmus_ms_avg=4312 | plan: packets=980 ready=347 | experts_substitution:
unknown. Advisories: stranded=0, fragments compacted last cycle, cheatsheet
derived tree in sync. Forge e2e rate-limited until ~04:24Z.
