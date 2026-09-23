## Cycle 2026-09-23T22:38Z — macneo — scheduled slot, session cron 703761cd

LANDED: three ledger writes, all on trunk through the plan-only lane. No packet
claimed and no code written — a release cut had just completed and this cycle's
value was in unblocking the selector, not in shipping.

SELECTION. Same batch and seed as the 20:05Z slot (the seed is date-derived), so
1084-x8ya was the top pick for the THIRD consecutive time on this host.

1. 1084-x8ya — FLIPPED ready -> blocked, retryable (trunk 00e02bb6a).
   The 20:05Z slot corrected its next_action and the 22:38Z selector handed it
   back anyway, because THE SELECTOR DOES NOT READ next_action — it reads
   status, role and urgency. Correcting the prose was necessary and not
   sufficient. The blocker is named and checkable: criterion (c) needs a macOS
   host with a guest that fails to reach ready, and none has been reported since
   the original reproduction on 2026-09-05. Parts (a) and (b) are landed
   (42ce602a4). Any host that reproduces flips it back with one set-field.
   Control: tillandsias-plan next macos --limit 8 | grep -c 1084-x8ya -> 0.

2. 1132-r4mt — macneo MEASURED AS NOT REPRODUCING (trunk 490cc6e19).
   ruby /usr/bin/ruby 2.6.10p210, system ruby, no toolbox on this regime; memo
   state miss:ledger-or-instrument-changed, so the archiver would genuinely have
   run; scripts/archive-plan-packets.sh --check under the gate's PATH -> rc=0,
   ok:archive-answerability:333/333. One host eliminated, not the row advanced.

3. THE CONFOUND THAT FOUND ITSELF, recorded on 1132-r4mt because that row is
   investigated by hand-running the archiver. My FIRST invocation returned rc=1,
   "cargo: command not found" at check-archive-answerability.sh:324 — not the
   archiver, not ruby. build.sh:130-131 prepends $HOME/.cargo/bin to PATH as
   part of its preamble, and bare cargo is not on this host's default PATH. Same
   command with that PATH prepended -> rc=0. A HAND-RUN STEP IS NOT THE GATE'S
   CONDITIONS. Any rc reported on that row from a direct invocation should be
   re-read for it. Checked build.sh rather than filing against it: the gate
   supplies the PATH, so this is not a gate defect.

INSTRUMENTS. check-fleet-membership ok:ran=9 skipped=2, no todos.
cycle-preflight ok:rebuilt+expert-absent+services-no-podman.
Checkout lock acquired and released. Boundary snapshot taken before any write.
The plan lane refused once — plan binary stale against a moved Cargo.lock
(built-from=4333f7dcd checkout=f5f3e7f01) — which is the lane validating the
bytes with a current binary; rebuilt (39s) and it went clean.

READ PATH: experts first; fell back to files for VERIFICATION twice, reading
1084-x8ya's and 1132-r4mt's cited fragments before acting on them.

tokens: subagent_tokens=0 agents=0
