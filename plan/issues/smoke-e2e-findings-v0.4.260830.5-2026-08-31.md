# Clean-room curl-install smoke — v0.4.260830.5 (daily) — lenovinha, 2026-08-31

Host: linux / Fedora Silverblue (immutable), AMD Cezanne iGPU + NVIDIA RTX 3070.
Channel: `daily`. Resolved tag: `v0.4.260830.5`.
Run by `/smoke-curl-install-and-test-e2e`, requested by macuahuitl-fedora for
the fleet blessing of the daily.

## PASS

`v0.4.260830.5` — install clean, reset clean, **init clean**, forge lane clean.

| step | result | evidence |
|---|---|---|
| 1 curl-install | exit 0; `tillandsias --version` = `0.4.260830.5`, matching the resolved tag exactly | `01-install-exit.txt`, `01-version.txt` |
| 2 `podman system reset --force` | exit 0; containers/volumes/images all empty afterwards | `02-reset-exit.txt`, `02-empty-store.txt` |
| 3 pristine `--debug --init` | exit 0; 3881 log lines; no panic, no `Error:`, no `FAILED`; 10 images built from scratch, zero build failures | `03-init.log`, `03-init-exit.txt` |
| 3 Vault re-init | `vault healthy (initialized=true sealed=false v=1.18.5)`, bootstrap complete — the keychain↔volume resync brick (`738059bc`) did NOT recur | `03-init.log` |
| 4 forge lane | full stack up: vault, router, proxy, git-tillandsias, inference, forge; OpenCode agent launched and orienting under meta-orchestration | `04-opencode.log` |
| 4b egress assertion | **proxy alive alongside the lane** — order-298 regression did not recur | `04b-containers.txt` |

**Accelerator lane reached `Proof::Placed`, not merely "reachable":** after a
generation on `qwen2.5:0.5b`, `/api/ps` reports
`size=524602571 size_vram=524602571` with `runner.inference="[{ID:0
Library:CUDA}]"` and a `CUDA0 compute buffer`. A full model resident in discrete
VRAM, from a pristine clean-room install of the published artifact.

## Ledger claims (order 380)

**There is no ledger row for this release**, so there are no claims to account
for. That absence is itself a finding — see the first packet below. Recorded
under the required headings anyway so the shape of the gap is explicit:

- **EXERCISED** — none; no claims were available to exercise.
- **NOT APPLICABLE** — none.
- **NOT CHECKED** — *unknown, and unknowable from here.* Whatever this release
  fixed is undocumented, so this run cannot say which of its intentions it
  covered. The PASS above means "the release installs, wipes, re-provisions and
  runs a forge lane", NOT "the release does what it set out to do".

---

### Work Packet: smoke-finding/smoke-ledger-row-check-always-reports-missing

- id: `smoke-finding/smoke-ledger-row-check-always-reports-missing`
- owner_host: any
- capability_tags: [testing, release, docs]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260830.5`
- evidence:
  - `skills/smoke-curl-install-and-test-e2e/SKILL.md` §0.2b — the awk reads
    `daily ~ "^\\| " tag "( |\\()"`. `daily` is an UNDEFINED awk variable, so
    the match is against the empty string and never fires. It should be `$0`.
  - Proof it is unconditional, not merely wrong today: `v0.4.260815.1` HAS a
    row in `README.md`, and the step as written still prints
    `NO LEDGER ROW for v0.4.260815.1`. With `$0` substituted, the row prints.
- repro:
  - `awk -v tag="v0.4.260815.1" 'daily ~ "^\\| " tag "( |\\()" {print; found=1} END{if(!found) print "NO LEDGER ROW for " tag}' README.md`
- next_action: >
    Replace `daily` with `$0`. Then decide whether the step should FAIL the run
    on a missing row rather than print a line: the skill says "A MISSING ROW IS
    A FINDING, NOT A SKIP", but nothing enforces it, and the check that was
    supposed to notice has never once evaluated its input. Same class as
    943-7dn5 / 943-3xyf / 944-vim8 — a check whose verdict is independent of
    the thing it checks.
- events:
  - type: discovered
    ts: `2026-08-31T01:35:00Z`
    agent_id: `linux-lenovinha-claude-20260831t011443z`
    host: linux

### Work Packet: smoke-finding/release-ledger-rows-missing-since-v0.4.260815.1

- id: `smoke-finding/release-ledger-rows-missing-since-v0.4.260815.1`
- owner_host: any
- capability_tags: [release, docs]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260830.5`
- evidence:
  - `target/smoke-e2e/00-ledger-row.txt` — no `README.md` row for
    `v0.4.260830.5`.
  - `README.md` — newest release row is `v0.4.260815.1`; the releases since it
    (including the one under test) carry no RELEASE / INTENDED FEATURES /
    BUGFIXES entry.
- repro:
  - `grep -nE "^\| v0\.4\.2608" README.md | tail -3`
- next_action: >
    Either append the missing rows, or record that the daily channel is exempt
    from the ledger table and correct §0.2b's "A MISSING ROW IS A FINDING"
    accordingly. Until one or the other, every daily smoke produces a PASS that
    cannot speak to what the release intended — which is precisely what order
    380 added the step to prevent. NOTE the interaction with the packet above:
    this gap could never have been detected by the step meant to detect it,
    because that step reports "missing" unconditionally.
- events:
  - type: discovered
    ts: `2026-08-31T01:35:00Z`
    agent_id: `linux-lenovinha-claude-20260831t011443z`
    host: linux

---

## Cross-host datapoints captured during this run (order 793-zumy, for yoga)

Not findings; measurements taken while the pristine container was fresh.

- **The image does not ship the inference backends — ollama fetches them at
  runtime.** `engine payload: need 'core+cuda_v13' (have 'core')` →
  `installed (846M libs) into model cache`. Available backends offered:
  `cuda_v12 cuda_v13 vulkan`. So "the image ships no ROCm/HIP backend" is the
  wrong frame: the image ships `core`, and the runtime installs a
  tier-appropriate payload — and **no rocm/hip appears in the available set**.
- **No Vulkan userspace in the published artifact**: both
  `/usr/lib64/libvulkan.so.1` and `/usr/share/vulkan/icd.d/` are absent, and
  `OLLAMA_VULKAN:false` in the server config. Confirms from a second host that
  the gap exists in the shipped daily, not just in a local tree.
- **No iGPU-drop line at all on a discrete-GPU host.** `OLLAMA_IGPU_ENABLE` is
  empty and discovery reports `GPU: NVIDIA (1 device(s))`, verifying only
  `"NVIDIA GeForce RTX 3070 Laptop GPU" compute=8.6 pci_id=0000:01:00.0`. The
  Cezanne is never enumerated-then-dropped here; the discrete card is simply
  found.
- **`--init` BUILDS images locally, from the RELEASE'S BUNDLED ASSETS**, not
  from the operator's checkout: `runtime assets ready at
  ~/.local/share/tillandsias/runtime/0.4.260830.5`. So a Containerfile fix
  reaches operators only when a new release bundles it — a local rebuild reads
  the release's own snapshot.
