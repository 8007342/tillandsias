## Cycle 2026-08-04T03:00Z (linux_mutable — v0.4.260804.1 smoke, crash reproduced)

Ran the curl-install e2e to earn promotion evidence. It did not earn it, and
that is the correct outcome.

**The substrate is healthy.** Curl-install from the published release, full
`podman system reset --force`, `--init` from pristine (14 images rebuilt), forge
lane launch, and the order-298 egress assertion all came back clean. The forge
lane launching matters: it had been failing FORGE_EXIT=125 while this host sat
at 96% disk, now 59%. Suggestive for 597-fmm2, not proof.

**Lane 1 verdict was MO-SMOKE: FAIL, and every failure was a test defect.**
Three environmental (no nested podman in the forge — correctly classified by the
in-forge agent), plus two real ones now fixed:
  - `default-image-containerfile-shape` pinned a literal ARG default that commit
    4da9bb12 intentionally changed on 2026-06-13 — failing on every
    podman-hosting Linux host for seven weeks. The in-forge agent classified it
    BACKWARDS as Containerfile drift; acting on that would have "fixed" a healthy
    file. The launcher always passes BASE_IMAGE as a build-arg, so the default is
    never read.
  - `test-opencode-entrypoint-prompt.sh` inherited two env vars the forge lane
    exports, flipping two cases and reporting a regression that did not exist.
    Sanitized at script level — my first fix was per-case and the second leak
    survived it.
Instant suite now 182/182, 96/96 specs.

**Lane 2 segfaulted — and left a coredump.** Status 139. This is BigPickie's
crash, reproduced on x86_64, on a REPEAT session (lane 1 completed fine 20
minutes earlier). Not disk pressure: 59% used, 393G free.

The unlock: BigPickie's trail listed coredump capture as an OPEN question,
because opencode is PID 1 and the container dies with it. Capture is VERIFIED —
a 91.3MB dump landed on the HOST and survived, preserved at
target/smoke-e2e/preserved/. Stack is abort-at-top over an unnamed JIT frame,
matching the 2026-07-27 arm64 sighting. First symbolicatable artifact this crash
has produced. Filed 604-vmcg.

**Also spotted, unrelated and unwatched:** three squid SIGSEGV coredumps
(08-01 x2, 08-03). The enclave proxy has been crashing and nobody was looking.

**Promotion WITHHELD.** promote-stable still returns refused:no-evidence, and the
findings doc was written specifically not to trip its grep — a document that
reads as a pass would be the same false-green class this cycle spent its time
removing. v0.4.260804.1 stays a prerelease; v0.4.260728.2 remains latest.
