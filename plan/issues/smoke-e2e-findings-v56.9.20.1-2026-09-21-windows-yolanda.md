# Smoke: curl-install e2e — v56.9.20.1 — windows / yolanda — 2026-09-21

- run_start: `2026-09-21T01:10:43Z`
- evidence_dir: `target/smoke-e2e` (prior run archived under `_archived-20260920T181043Z/`)
- channel: daily (prerelease), pinned with `TILLANDSIAS_VERSION=v56.9.20.1`
- tag: `cc9efe7ad`; README row on `origin/windows-next` at `c49a320df` (row proof = 1)
- host: yolanda-windows, Windows 11 26200.9457, Ryzen 7, 16 GiB (15.16 GiB visible)
- WSL regime: **8 GB / 4 CPUs** (changed today from 5 GB / 16 vCPUs — see §4)
- status: **PASS**, with two could-not-exercise items and one process deviation
  I caused, all below.

## CONSENT, quoted verbatim before the destructive step is discussed

From the operator, on this host's own channel, 2026-09-20:

> "If the wsl or any of its contents needs to be destructively recreated that
> is by design from our platform, and I approve of it. It'll likely be expected
> later that macuahuitl will ask for a destructive test, wiping and recreating
> the wsl distro and its contents from scratch."

And, when the §2 scope was put to them explicitly — naming the unregister of the
`tillandsias` distro, the deletion of `vault-shamir-share-v1` and
`vault-root-token-v1` from Credential Manager, the preservation of
`tillandsias-vm-uuid`, and that §1 itself bootstraps a Vault — they chose:

> "Run the full documented smoke"

The coordinator's relay of this consent is not the consent; the above is from
the operator directly, on this channel, today.

## A PROCESS DEVIATION I CAUSED, stated before the verdicts

The go said: run §1, quote the consent, then §2. **On Windows that sequence no
longer exists, because of my own change.** 1286-4437 moved the reset INTO the
installer, so `install-windows.ps1` performs the unregister, the credential
clear and the reprovision *during §1*. The destruction therefore happened
before I had written the consent quote into this report.

The action was authorised — the consent above predates the run and covers it
exactly — but the *gate* the coordinator attached to §2 was bypassed by
sequencing, not by a decision. Anyone re-running this lane should know the
consent gate now belongs BEFORE §1 on Windows, not before §2. That is a
consequence of my arm that neither of us had noticed until it ran.

## Verdicts

| § | verdict | evidence |
|---|---|---|
| §1 curl-install | **PASS** | `install_exit=0`; sha256 ok `e3a4aa3da0c905a8bdb24c247dd1f84ffb9ba041c4c3dd169efddb903725c51f`; `tillandsias-tray 56.9.20.1 (cc9efe7ad)` exact |
| §1b install-bits diagnose (esme's 1258-8wfb) | **PASS** | `diagnose: version=56.9.20.1 commit=cc9efe7ad (--diagnose exit 2)`; exit 2 proceeds by design, only exit 1 aborts |
| §2 reset (now inside §1) | **PASS** | announced preserved-then-destroyed before destroying; distro unregistered and recreated; `removed download cache`; `reset-state: provisioned and ready (exit 0)` |
| §3 provision | **PASS** | `RESULT: VM Ready — control wire up ✓`; distro `tillandsias` Running afterwards |
| §4 forge lane | not applicable | Linux/Podman lane |

## The row's claims this lane could reach

**EXERCISED — the install reset contract on Windows (1286-4437).** This is the
first proof of it on a PUBLISHED artifact. The installer called `--reset-state`,
the tray announced what it would preserve (`tillandsias-vm-uuid`) before what it
would destroy, unregistered the pre-existing distro, removed the download cache,
reprovisioned to Ready and exited 0. A pre-existing distro was NOT reused: it
was destroyed and a fresh one registered.

**EXERCISED — the exact tray version.** `tillandsias-tray 56.9.20.1 (cc9efe7ad)`,
and `--diagnose --json` independently reports `version=56.9.20.1
commit=cc9efe7ad`.

**EXERCISED — 1295-b4i8's invariant.** The BUILDER distro's disk is untouched:
`%LOCALAPPDATA%\tillandsias\wsl-build\ext4.vhdx`, 156991750144 bytes, mtime
2026-09-20T16:02:51, unchanged across the run. The reset named the child
(`...\tillandsias\cache`) and not the shared parent.

**COULD NOT EXERCISE — the credential CLEARING path.** The reset logged
`no host-side vault credentials to clear`: they were already absent, cleared by
the previous smoke. Both `vault-shamir-share-v1` and `vault-root-token-v1` read
PRESENT *after* this run, which is correct and is not the clearing being tested
— the fresh guest's vault bootstrap created NEW ones. `tillandsias-vm-uuid` was
present throughout, as designed. So this run says nothing about whether stale
credentials are cleared; the previous smoke did test that, this one did not.

**NOT LOOKED AT:** the front door, the plan binary, the operator skills and the
mirror lane are not reachable from this lane.

## Probe demonstration (1323-5taw), on the published tray

| probe | result |
|---|---|
| sound: `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 --reset-state` | **exit 0**, prints the skip line, provisions without wiping — ACCEPTED |
| control: `--reset-stat` (nonsense) | **exit 2**, `Error: unknown flag --reset-stat` — REFUSED |
| unsound: does `--help` mention `--reset-state`? | **True** |

On THIS binary all three agree, because the Windows tray's allow-list contains
the flag. The divergence is what matters: on v56.9.20.1's published Linux
headless, the unsound probe answers True while the parser exits 2
(`Unsupported option: --reset-state`, pirria). That is the specimen behind
1323-5taw, and this table is the demonstration that attempting the flag
distinguishes what reading `--help` cannot.

## §4 — the WSL-cap measurement 1308-9ej7 asked for, and what I failed to capture

**REGIME:** `.wslconfig` `memory=8GB` + `processors=4` (changed 2026-09-20 from
`memory=5GB` with no `processors` line, i.e. 16 vCPUs in 4.8 GiB). Host 15.16
GiB visible, Windows 11 build 26200.9457. Guest after the change: MemTotal
8133228 kB, nproc 4. build.sh's memory-derived job cap still engages (7 GiB by
its integer divide, 7 < 16).

**OUTCOME: ALIVE.** The first gate-sized run under the new cap completed — the
install, the destructive reset, and a cold reprovision to Ready — with no reap.
Under the old regime four runs were killed by the harness for host memory.

**WHAT I DID NOT CAPTURE, and it is my error:**

- **Peak host memory during the run.** I armed a PowerShell sampler job, but
  each PowerShell tool call is a separate process, so the job died with the
  process that started it. The peak is simply not measured. A post-run reading
  (guest up, idle) is host free 2.96 GB of 15.16 = **19.5%**, vmmemWSL 3.51 GB
  — close to the 18.3% seen at the last reap, which suggests the margin is
  still thin and that "alive" may owe as much to 4 vCPUs not spawning 16
  compilers as to the extra GB.
- **Provision-to-Ready wall time.** I tried to derive it from the log file's
  timestamps and got 743934 s, which is nonsense: Windows preserved the
  CreationTime of the previous run's log through the overwrite (file
  tunnelling). The real elapsed was not recorded.

So this run answers 1308-9ej7's qualitative question (alive vs reaped) and
**not** its quantitative one. The next run should sample from a process that
outlives the measurement — a `Start-Job` inside one tool call cannot — and take
timing from explicit clock reads, not file metadata.

## Recorded, not findings

- §1 still ends by launching the tray, leaving a process running and the distro
  Running. Fifth instance, third on Windows; unchanged and still 1286-4437's
  original pre-fix shape for the *launch*, now harmless because the reset
  already provisioned synchronously and exited with its status.
- `--diagnose` exit 2 at install time is expected and correct: the check runs
  before the tray is launched, so the distro is not yet up. esme's block
  proceeds on 0, 2 and 3 and aborts only on 1.
