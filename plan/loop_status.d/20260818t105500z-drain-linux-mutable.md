## Cycle 2026-08-18T10:37Z — 826-gsjg + 406 closed, and a sibling's packet closed on the evidence they named

**Result: the fourth drift in `orchestrate-enclave.sh` found and fixed, 406
closed on measured CUDA evidence, and 798-c4mq — held open by a sibling for a
specific missing measurement — closed by taking that measurement.**

- **826-gsjg (closed).** The script passed **no `--device` and no tier** to the
  inference container, so a stack brought up through it ran ollama on the CPU
  of a host with an RTX A5000, silently. The product passes
  `--device nvidia.com/gpu=all` (main.rs:4201) with a source-window test at
  :15308 pinning it. Fixed by reusing `dev-inference-ensure.sh`'s resolution
  rather than writing a second one — a second copy is how the first three
  drifts happened. **Conditional on the tier**, because the fleet is gaining
  CDI-less hosts where an unconditional `--device` is a hard start failure,
  i.e. a worse bug than the one being fixed.

- **406 (closed).** On a host provisioned from a destroyed substrate hours
  earlier, the stack image with the fixed args reports
  `library=CUDA compute=8.6 name=CUDA0 "NVIDIA RTX A5000" cuda_v13 driver=13.3
  total="23.5 GiB"` and serves `/api/tags`. Three limits written into the
  closure rather than left implied: `--init` produces **no** inference
  container so the packet's literal question answers no; I **reconstructed**
  the launch rather than intercepting one (the script tears the stack down 13s
  after spawning); and I did not verify any model is resident in VRAM, only
  present and served.

- **798-c4mq (closed — the implementation is the sibling's).** They held it at
  progress for one stated reason: *"NOT CLAIMED … that the lane WORKS once the
  mirror runs. That still needs the stack up under the destructive e2e."* This
  host has now done that. The mirror reached Up (healthy) in 15s on the cold
  substrate and the lane published
  `refs/tillandsias/upstream-auth/local-only/1787049495` — 45s old against a
  900s ceiling, **exactly one ref**, confirming publish() supersedes rather
  than accumulates.

  Scope stated: the state is `local-only`, correct for a mirror volume created
  minutes earlier with no upstream remote. What is proven is the publishing
  MECHANISM. That it publishes `authorized`/`denied` correctly against a real
  upstream is 809-w2xy's territory and is **not** claimed.

  I also declined to re-derive the PRECONDITION ladder live: this host returns
  `ok:gh-keyring` and short-circuits before the forge branch, and manufacturing
  that path by stripping gh from PATH would have tested my harness rather than
  the code — the trap that cost two fixtures earlier tonight. The sibling had
  already verified all six states hermetically; re-deriving it badly would have
  subtracted evidence.

- **767-nkkq left at `implemented`, deliberately.** Its deliverable needs a
  harness crash handled live with preserved evidence. Tonight's forge run was a
  clean pass, which exercises only the happy path the fixture already covers.
  Crashing an agent inside a forge is a deliberate destructive act and in-forge
  work is supposed to be surgical; I am not doing it as a drive-by at 03:50.

- **802-2536 corroborated, not advanced**: the live capabilities probe reports
  `accel_npu=present-unusable accel_reason=engine-missing` on this host, which
  is that packet's claim confirmed from the product's own mouth. It still needs
  an engine, which is real work and cross-host.

### Host state left behind

vault, dev-inference and the git mirror are running and healthy. **The mirror
was started BY HAND** with the args the fixed orchestration now produces, so
the next cycle should know it is not lane-managed; `orchestrate-enclave.sh`
tears the stack down at the end of its run by design, so a mirror outliving a
lane is my doing, not the product's.

### For the operator

- **809-w2xy** — unchanged, still the root blocker for anything that pushes.
- **808-zrzz** — still wants a recorded decision; the e2e reached §2/§3 tonight,
  so the cost of the series wiring is now concrete.
- **801-x1nx**, **814-iyu7** — still yours.
- Filed tonight and ready: **815-gdjk**, **819-s92y**, **820-c8q8**,
  **822-4vwa**, **823-u3k9**.
