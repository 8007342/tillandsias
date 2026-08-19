## Cycle 2026-08-18T12:37Z — 820-c8q8 closed, 827-uh6t filed, 819-s92y advanced; likely the night's last working cycle

**Result: the timeout-attribution fix landed, a latent budget bug fell out of
trying to test it, and 819-s92y's absence claim now covers the built image.**

- **820-c8q8 (closed).** A litmus `[TIMEOUT]` now reports the runqueue against
  the core count at kill time and classifies: SATURATED ("re-run before
  treating this as a regression"), NOT saturated ("genuinely too slow for its
  Ns budget"), or UNCLASSIFIED when neither reading is available — named, not
  guessed. The verdict is unchanged; only the cause is stated.

  **The packet's own proposal was partly wrong and the closure says so.** It
  led with "report elapsed vs budget", which cannot discriminate: a killed step
  always elapses its budget, so a genuine 41s regression and a starved 0s
  fixture both print ~30s/30s. Load was the signal it listed second.

- **827-uh6t (filed, p3).** Found while trying to force a timeout:
  `timeout_sec=$(( ms / 1000 ))` floors any sub-second budget to **0**, and GNU
  `timeout` documents 0 as *disabled*. A step asking for `timeout_ms: 250` runs
  **unbounded**. No corpus step declares one today, so it is latent — but the
  next person writing a fast assertion will reach for exactly that.

- **819-s92y advanced, deliberately not closed.** I looked inside the image the
  destructive e2e rebuilt from scratch: `/opt/skills` is present and populated,
  and nothing in `/home/forge/.config`, `.config-overlay` or `/etc` names it —
  including opencode's own config.json. Still not excluded: a built-in default
  that scans the path with no config entry. The binary is not on PATH in a bare
  `sh`, so settling it needs a real lane. The decisive test is written into the
  note for whoever has the budget.

- **767-qrbv not attempted.** Its deliverable is a harness variant running two
  consecutive forge lanes; implementing *and* verifying that needs more than a
  final cycle has, and a half-built harness is worse than none.

### What I did NOT verify tonight, collected in one place

- 820-c8q8's classification has never been seen at the end of a live 124 exit —
  verified by driving the script's own extracted case block, not in the wild.
- 406 was closed on a **reconstructed** launch (the script tears the stack down
  13s after spawning), and no model was confirmed resident in VRAM.
- 798-c4mq's lane was proven to publish in the `local-only` state only; the
  `authorized`/`denied` path against a real upstream remains 809-w2xy's.
- 818-cgpn and 822-4vwa are verified live, but only on this host.

### Host state left behind

vault, dev-inference and the git mirror running and healthy. **The mirror was
started by hand** with the args the fixed orchestration produces — it is not
lane-managed, and `orchestrate-enclave.sh` tears the stack down at the end of
its own run by design, so a mirror outliving a lane is my doing.

The spec-index volume the reset destroyed has not been rebuilt; the next expert
build pays a cold index, exactly as recorded in the 801-a2by closure before the
destruction rather than discovered after it.

### For the operator

- **809-w2xy** — the root blocker all night. Nothing that pushes upstream can
  close until you re-seed the mirror's GitHub credential.
- **808-zrzz** — still wants a recorded decision. The e2e reached §2/§3 tonight,
  so the cost of wiring the forge lane in series is now measured, not argued.
- **801-x1nx**, **814-iyu7** — still yours.
- Ready and filed tonight: **815-gdjk**, **819-s92y**, **822-4vwa**,
  **823-u3k9**, **827-uh6t**.
