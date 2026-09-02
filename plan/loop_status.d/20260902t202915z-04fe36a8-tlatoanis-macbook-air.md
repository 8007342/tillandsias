## Cycle 2026-09-02T20:29Z — tlatoanis-macbook-air (osx-next)

Cycle: osx-next union merge (345 commits behind linux-next) + macOS union-red repair.

Merge from origin/linux-next was CLEAN (no conflicts) and the union was still
red five times over — the 731-eupn shape, every failure a GNU/Linux assumption
in code that had never executed on a Mac:

- accel_probe.rs `enumerate_npus` ungated while called only from a cfg(linux)
  arm; -D dead-code failed workspace clippy on macOS and Windows.
- check-litmus-bindings.sh used `\+` in a BRE. BSD sed matches a literal plus,
  so the newly-bound-name extraction returned NOTHING and the gate reported ok
  while enforcing nothing. A gate that silently stops gating on one platform is
  worse than one that fails there.
- run-litmus-test.sh sourced timing-log.sh with `2>/dev/null || true`. bash 3.2
  ABORTS a non-interactive shell on a failed `.` and `|| true` does not save it
  (bash 4.4+ does not, which is why it survived on Linux), so a best-effort
  timing side-channel was killing the runner before it parsed anything.
- the three 956-llei fixtures build a temp PROJECT_ROOT with an empty target/,
  so the runner's metadata reads fell back to yq — absent on every macOS host —
  and every arm failed as `No litmus tests bound to spec`.
- test-bound-litmus-is-runnable.sh used bare `sed -i` and `\n` in an s///.

All five fixed; `TILLANDSIAS_FORCE_CHECK=1 ./build.sh --check` green (149s);
osx-next pushed 9466bac67..48b815dc4, now current with linux-next.

Filed: plan/issues/macos-union-red-956-llei-family-2026-09-02.md and 964-zgga,
which extends the 761-g36m dialect scanner to the two idioms it passed over
(`\+` in a BRE, unguarded `.`) — the one instrument that could have caught
these on the authoring host rather than 345 commits later.

Maintenance: capability row was `stale:drifted` (committed row carried no
engines while the probe sees cpu/host-native/gpu ollama) — republished.
Daily maintenance stamped. Build cache 29G, not due. Stranded 0/7 in_progress.

Not started this cycle: 702-6jza (macOS terminal-attach) and 935-6fzk
(signing/notarization) — the merge was the assigned first cycle.
