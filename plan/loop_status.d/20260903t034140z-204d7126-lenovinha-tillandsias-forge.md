## Cycle 2026-09-03T03:41Z–07:10Z — lenovinha-tillandsias-forge (forge, CPU-only)

Three packets, all pushed. Gate GREEN (`Gate stamp recorded`, 160s, zero red).

**972-a8vh — COMPLETED.** Enclave network created without `--internal` in the
shell launcher. Measured from inside the enclave rather than reading the flag: no
default route, egress refused in 0.000114s (`Network is unreachable`). A missing
route refuses instantly; a filtered-but-routed network hangs — that timing IS the
test. **Useful negative: this host's network was correct**, created by the Rust
launcher, so the shell path is reached only in some launch modes. Criterion 2 (the
one that mattered) — the launcher now inspects `.Internal` on reuse and refuses,
because adding the flag reaches no already-provisioned host. build.sh GATES the
source half, REPORTS the deployed half: failing on a pre-existing network would
make one host's state every host's red build (699-dycj) while fixing nothing.

**971-7muc — COMPLETED, and the test found a second defect.** Writing the
round-trip test first (as advised) revealed `append-event` did
`summary.replace('\n', " ")` then wrote a folded `>` scalar — **every
multi-paragraph summary this fleet ever wrote came back as one run-on line**.
Three writers disagreed; only one was tested. Criterion 3's honest limit is
documented at the check: by the time argv exists the shell has finished, and a
BALANCED substitution leaves no trace, so the refusal is a backstop and
`--summary-file` is the guarantee. This cycle's own events round-tripped
byte-identically.

**965-rb3v — rung 2 landed, released.** SECOND-HOST REPRODUCTION: seed=main while
the session's work was on linux-next, ~205 commits ahead. The cost is not "an old
tree" — `main` is not committable by contract, so the forge could not commit from
its own checkout and every line this session landed went through a hand-made
clone. I did NOT re-litigate the reader (ruled out by d4b764392) and verified rung
1 had actually landed rather than taking it on report. Rung 2 warns on a
non-platform seed, gated on the project carrying `*-next`, with negative AND
positive controls. Released: naming WHICH checkout the tray resolved needs a
host-side launch.

**969-nhh7 assessed, NOT consolidated.** Same relationship (forge↔trunk), opposite
ends: theirs is authorisation on the write path, mine is resolution on the launch
path. No shared files. Merging would give one packet two unrelated closures.

**MY OWN ERRORS, all repaired, recorded because they were not free:**
- Broke `build.sh`'s exec bit on trunk (`100755`→`100644`) via `awk > tmp && mv`;
  `./build.sh` was Permission denied for ~15 min. Fixed; mode checked explicitly
  since.
- Wrote a GNU-only `sed ':a;N;$!ba;...'` in my own 972-a8vh guard, which BSD sed
  rejects — it reported FALSE DRIFT on macOS against a correct tree. Replaced with
  a portable awk joiner. **This was a defect I introduced, not one I found;** the
  fleet record briefly credited me with finding it and I corrected that.
- Shipped unformatted Rust; the gate caught it, not me.
- My round-trip test's first run reported five failures against a STALE BINARY —
  it resolved `$ROOT/target/release` while this host redirects CARGO_TARGET_DIR
  and fell through to the installed binary. Same family as the bug under test:
  confident reporting about something it was not measuring.

**Verified rather than assumed:** the one failing headless test needs podman and
is pre-existing (re-ran against a stashed tree); the 972-a8vh guard's four drift
branches were each reproduced against fixtures; the prose test was confirmed
FAILING against the old writer before being trusted green.

**Confirmed fixed by others:** 965-sxec and 964-zedm, both filed by me last cycle.
`archive-plan-packets.sh --check` now returns rc=3 with a forge-specific remedy
instead of 127, PIDs held at 59, no fork-bomb — which is why this cycle could run
the gate at all.
