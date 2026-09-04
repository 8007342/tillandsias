## Cycle 2026-09-03T23:15Z — tlatoanis-macbook-air (osx-next)

Two things: verified yoga's CA-path change on a real Mac guest (unblocking their
p0), and falsified 795-bmbq's premise.

YOGA'S ASK — 998-qrwu moved the enclave CA dir behind one declaration, and eight
of the sites are in a SHELL PREAMBLE exec'd into the macOS guest. Their crate
tests prove the string builds, not that a guest accepts it. Ran the rendered CA
block in the real guest, twice:
  /tmp/tillandsias-ca      -> key=present perms=600 crt=present, exit 0
  /var/lib/tillandsias-ca  -> key=present perms=600 owner=root,  exit 0
The second is the one that de-risks their p0, since that packet CHANGES the
value. Also checked ca_dir() skips the 22 lines of comment and returns the path
— naive inclusion would still have COMPILED and produced garbage shell. Told
them to keep 998-3z6g whole rather than splitting a Darwin half off a change
whose point is that the path is declared once.

I deliberately ran only the CA block, not the whole preamble, which ends by
exec'ing the headless binary and would have taken over the session I was
measuring in. Said so, so nobody reads it as a full-preamble e2e. My first
attempt flattened newlines with tr and the guest correctly refused it — my
harness bug, not their change, and I flagged that too so a bare "syntax error"
in the transcript is not mistaken for a finding.

795-bmbq — THE PREMISE IS FALSE AND WAS FALSE WHEN FILED. The packet says
--interactive --tty is dropped and the TUI may have been amputated to work
around our own argv bug. It is pushed under `!diagnostics && prompt.is_none()`;
the skip applies only to the PROMPTED lane, where opencode run renders no TUI.
That conditional landed 2026-06-18 (d761b4187, explicitly scoped to prompted
launches), two months before the audit — I extracted main.rs as of the audit
date and confirmed it there. The audit read a conditional skip as an
unconditional drop.

What had real content was criterion 3. The comment asserted that forcing the
flags makes podman REFUSE before container start. Measured against the guest's
podman: it WARNS and the container RUNS, exit 0. Both comments amended to
separate measured from assumed, with the claim bounded (podman version not
captured). The SIGTTIN/SIGTTOU observation is kept as real-but-unexplained
rather than restated as a cause.

Criterion 2 is unsatisfiable as written — both branches presuppose the
amputation — and I left it for the author. Third time this session I have hit a
criterion its own premise made impossible, and the third time I have not
rewritten it.

Gate green (265s).
