# Smoke e2e findings — release v0.4.260804.1 — 2026-08-04

- **Host:** linux_mutable (macuahuitl), channel `daily`
- **Skill:** `/smoke-curl-install-and-test-e2e`
- **Resolved:** `v0.4.260804.1` from
  `https://github.com/8007342/tillandsias/releases/download/v0.4.260804.1`

## VERDICT: NOT PROMOTABLE

**`MO-SMOKE: FAIL` on lane 1; lane 2 died with SIGSEGV (status 139).**

`scripts/promote-stable.sh v0.4.260804.1` must continue to REFUSE, and this
document must not be read as the evidence that unblocks it. Promotion needs a
clean run; this was not one.

That said, **no defect was found in the released artifact.** The distinction
matters and is spelled out below, because "the release is fine" and "the smoke
passed" are different claims and only the first one is true here.

## Substrate steps — all clean

| Step | Result | Note |
|---|---|---|
| §1 curl-install from the published release | clean | `Tillandsias v0.4.260804.1`, matches the resolved tag |
| §2 `podman system reset --force` | clean | containers/volumes/images all 0 afterward |
| §3 `--debug --init` from pristine | clean, rc=0 | Vault bootstrapped, 14 enclave images rebuilt |
| §4 forge lane launch (lane 1) | clean | full enclave up incl. `tillandsias-tillandsias-forge` |
| §4b first-launch egress (order 298) | clean | `tillandsias-proxy` survived launch |
| §4 forge lane launch (lane 2) | **crashed** | status 139 mid-run — see finding 3 |

The forge lane launching at all is notable: `litmus:opencode-prompt-e2e-shape`
step 3 had been failing `FORGE_EXIT=125` while this host sat at 96% disk. It is
now at 59%. Suggestive for 597-fmm2, **not proof** — the release, the images and
the whole substrate changed too.

## Findings

### Work Packet: smoke-finding/default-image-containerfile-shape-stale
- id: `smoke-finding/default-image-containerfile-shape-stale`
- owner_host: linux
- capability_tags: [testing, podman, release]
- status: **fixed in this cycle** (commit on linux-next 2026-08-04)
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260804.1`
- evidence: in-forge litmus, `litmus:default-image-containerfile-shape` STEP 2
- what it was: the step pinned the literal
  `ARG BASE_IMAGE=localhost/tillandsias-forge-base:latest`. Commit `4da9bb12`
  (2026-06-13) intentionally dropped `:latest`, and the test was never updated —
  so it had been failing on every podman-hosting Linux host for seven weeks.
- **the in-forge agent classified this backwards.** It called the Containerfile
  the drift. The launcher ALWAYS supplies `--build-arg BASE_IMAGE=<versioned
  tag>` (`main.rs:1518` canonical_tag, `:1818` versioned_image_tag), so the ARG
  default is never used on the real build path; `check-container-bases.sh:60`
  already asserted the variable form and agreed with the current file. The test
  was stale, not the product. Recorded because acting on the agent's direction
  would have "fixed" a healthy Containerfile.
- next_action: none — the step now pins the contract (ARG exists, FROM consumes
  it) instead of a default nothing reads.

### Work Packet: smoke-finding/opencode-entrypoint-test-not-hermetic
- id: `smoke-finding/opencode-entrypoint-test-not-hermetic`
- owner_host: linux
- capability_tags: [testing]
- status: **fixed in this cycle**
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260804.1`
- evidence: in-forge litmus, `litmus:forge-opencode-onboarding-shape` STEP 4
- what it was: `scripts/test-opencode-entrypoint-prompt.sh` inherited
  `TILLANDSIAS_OPENCODE_PROMPT` and `TILLANDSIAS_AGENT_RESULT_FORMAT` from the
  environment. Run inside a forge lane — which exports both — two cases flipped
  and the suite reported a product regression that did not exist. The entrypoint
  was correct to honour them.
- next_action: none — sanitized once at script level. A per-case fix was written
  first and the second leak survived it, which is why the unset is at the top.

### Work Packet: smoke-finding/opencode-segfault-lane-2
- id: `smoke-finding/opencode-segfault-lane-2`
- owner_host: linux
- capability_tags: [forge, opencode, bun, crash]
- status: ready — filed as ledger packet **604-vmcg**
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260804.1`
- evidence: lane exited status 139 (128+11, SIGSEGV);
  `coredumpctl` PID 3450686, 91.3MB dump PRESERVED at
  `target/smoke-e2e/preserved/core.opencode.1000.*.3450686.*.zst`
- why it matters beyond this release: BigPickie's trail listed coredump capture
  as an OPEN question because opencode is PID 1 and the container dies with it.
  Capture is now verified — the dump lands on the HOST and survives. First
  symbolicatable artifact this crash has ever produced.
- **not a regression in this release.** The crash is in `opencode.exe` (Bun
  v1.3.14), a runtime dependency installed inside the forge, and matches the
  arm64 sighting of 2026-07-27. Lane 1 completed normally ~20 min earlier, so it
  reproduces on a REPEAT session.
- **not disk pressure:** 59% used, 393G free at the time.
- next_action: symbolicate the preserved dump (see 604-vmcg).

### Environmental, not defects — do not file
Three litmus specs (`forge-standalone-runtime-shape`,
`podman-path-availability`, `runtime-diagnostics-stream-shape`) fail inside the
forge because there is no nested podman there. All three pass when run manually.
The in-forge agent classified these correctly.

Also observed and NOT part of this story: `coredumpctl` lists **three squid
SIGSEGVs** (2026-08-01 18:59, 2026-08-01 21:50, 2026-08-03 17:41). squid is the
enclave proxy and nobody has been watching it crash. Wants its own packet after
someone establishes whether it restarted silently or degraded.

## What a promotable run needs

1. `604-vmcg` understood well enough to know whether a repeat-lane segfault is
   acceptable in a shipped runtime, or must be pinned/supervised first.
2. A lane-1-and-lane-2 smoke that reaches `MO-SMOKE: PASS`, now that the two test
   defects above are fixed.
3. Cross-platform evidence from `603-jn5m` (Windows + macOS end-user install).
