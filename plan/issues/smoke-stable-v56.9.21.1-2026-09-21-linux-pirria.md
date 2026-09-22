# Stable-channel one-shot smoke — v56.9.21.1 — Linux — pirria

- run_start — 2026-09-21T20:58:41Z
- channel: **stable** (the one-shot the runbook asks for right after a promotion)
- resolved: `/releases/latest` → `v56.9.21.1`, matching the promoted tag
- evidence_dir: target/smoke-e2e (prior run archived under `_archived-20260921t205841z/`)

**VERDICT: PASS.** The promoted artifact installs and rebuilds an enclave from
nothing.

AUTHORISATION: pirria is the dedicated Linux smoke host and destructive steps are
pre-authorised by the operator. §1 IS a destructive step on this release —
`install.sh` calls `--reset-state` itself (1286-4437) — so the pre-state was
banked before §1.

REGIME, and it is unusual enough to state: the host was running a **trunk build
(v56.9.21.2)** when the smoke began, and the smoke replaced it with the stable
release. That is the correct thing for a stable-channel test and it means the
mirror-lane fixes are absent from the installed binary until trunk is reinstalled.

## What ran

| Step | Result |
|---|---|
| §0 pre-flight | PASS — evidence archived, pre-state banked, zero stale files survived |
| §1 curl-install (DESTRUCTIVE) | **PASS — `install_exit=0`, `Tillandsias v56.9.21.1`, zero `Unsupported option`** |
| §2 reset + credential clear | PASS — clean room on all four surfaces |
| §3 pristine init | PASS — `init_exit=0`, vault healthy, 15 images rebuilt from nothing |

### The reset contract, measured

| | pre | post |
|---|---|---|
| containers | 4 | 0 → 1 (vault) |
| volumes | 9 | 0 → 2 |
| images | 17 | 0 → 15 |
| model cache | 49 files, digest `2666828800` | **identical** |

## ORDER 1312-i6da — both arms, on a real host rather than a stub

**ARM 2 — rebuild from nothing after `podman system reset --force`.** This
smoke's §2 and §3 are exactly that arm. The reset emptied all four surfaces
(0 containers, 0 volumes, 0 images, `vault-data` absent) and the reprovision
rebuilt 15 images and brought vault up healthy, `init_exit=0`.

**ARM 1 — the bring-up runs twice with no container recreated.** Ran
`tillandsias --ensure-enclave` twice and compared `podman inspect
--format '{{.Created}}'` between runs:

```
RUN 1  tillandsias-proxy   2026-09-21 14:12:48.927367772 -0700 PDT
       tillandsias-vault   2026-09-21 14:12:30.842546313 -0700 PDT
RUN 2  tillandsias-proxy   2026-09-21 14:12:48.927367772 -0700 PDT
       tillandsias-vault   2026-09-21 14:12:30.842546313 -0700 PDT
```

Byte-identical to the nanosecond, both runs exit 0. Nothing was torn down and
recreated. That is the fact a stub cannot supply: a stub can report that a
command was a no-op, but only a live runtime can show that the thing which
already existed was left alone.

**THE BARE-METAL VERDICT LINE, and it does not carry `lane=` — that is not a
defect.** `scripts/check-bare-metal-host-initialized.sh` answers:

```
todo:initialize-bare-metal-host:mirror:TILLANDSIAS_HOST_PROJECT_ROOT=$HOME/claudia tillandsias --bash tillandsias
```

exit 1, correctly. The mirror is PER-PROJECT and comes up at lane launch, which
this smoke does not perform. The `lane=` field exists in the script (it resolves
`off` / `unwired:sshd-not-running` / `wired:<principal>`) but is emitted only on
the `ok:` line, so it is structurally unreachable from a `todo:` verdict. A host
that has not launched a lane cannot report its lane state through this instrument.

## A correction to the morning report, and it is mine

`plan/issues/smoke-e2e-findings-v56.9.21.1-2026-09-21-linux-pirria.md` claims:

> images | 16 | 15 | **all recreated** — 0 predate run_start

The MEASUREMENT was sound and correctly scoped: its evidence file holds 20 lines,
every one a `localhost/` image, all post-dating run_start. The SENTENCE is
broader than the measurement. Of the 15 images counted, 5 are pulled BASE images
— `alpine:3.20`, `alpine:3.22`, `caddy:2-alpine`, `hashicorp/vault:1.18`,
`fedora-minimal:44` — and a pulled image's `CreatedAt` is its **upstream build
date**, not when this host fetched it. `alpine:3.20` reports 2026-04-16 however
freshly it was pulled, so those five predate run_start by construction and always
will.

So "0 predate run_start" is only a meaningful test for locally BUILT images. On
this run: 30 `localhost/` tag-rows, 0 predating run_start; 5 base images, all
predating by definition. The substantive conclusion is unchanged and correct —
the reset destroyed and rebuilt the enclave — but the claim as written covers
images the evidence never examined, in a report that fed a promotion decision.

FOR THE RUNBOOK: the image-recreation check should say `localhost/` explicitly,
or a future reader will either report a false failure (counting base images) or
repeat this overstatement (not counting them but claiming all).

## Findings reproduced from the morning run

- **The cold-state probe is time-dependent**, as its packet says. Run BEFORE
  init this time it answers `credential-cold`; run after init this morning it
  answered `credential-warm` about a share that run had created. Same host, same
  probe, opposite verdicts, decided entirely by when it was asked.
- **The clearer still prints `preserved: keychain:installation-uuid-v1`** on a
  host with no such item.

## Not checked

The forge lane (§4) and egress (§4b) — not run on this one-shot; the morning
daily-channel smoke covered them on the same tag. `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`
runtime behaviour. Signature verification: cosign remains absent on this host.
