# Smoke: curl-install e2e — v56.9.20.1 — DAILY channel — macOS / macneo — 2026-09-21

- run_start: `2026-09-21T01:14:34Z`
- evidence_dir: `target/smoke-e2e` (prior runs archived under `_archived-<ts>/`)
- channel: **daily**, `SMOKE_BASE` pinned to the tag's download URL
- host: macneo (`Tlatoanis-MacBook-Neo.local`), macOS 27.0, arm64, branch `osx-next`
- authorisation: recorded in `00-authorisation.md` **before §1**, because since
  1286-4437 the destruction happens INSIDE §1 — the installer calls
  `--reset-state` itself. Operator pre-authorisation, quoted verbatim there.

## VERDICT: PASS

`smoke:macneo:v56.9.20.1:PASS`

## Verdicts by section

| § | verdict | evidence |
|---|---|---|
| §1 curl-install (now destructive) | **PASS** | `install_exit=0`; installer sha256 recorded; announcement captured before destruction |
| §1 reset contract (row claim 1) | **PASS, asserted** | see "Claim 1" below — state re-created, not reused |
| §2 destructive substrate | **PASS** | `ok:e2e-step2-macos:destroyed`, `STEP2_RC=0`; image_root and caches gone, `nvram.bin` gone |
| §3 pristine provision | **PASS** | `provision_exit=0`, `{"status":"provisioned"}` from a fully wiped substrate |
| §3b diagnose | **PASS** | `diagnose_exit=0`, `provisioned=true`, `rootfs_bytes=268435456000` |
| version line (row claim 2) | **PASS** | `tillandsias-tray 56.9.20.1 (git cc9efe7ad, …)`; sha matches the tag |
| plan binary (row claim 3) | **PASS** | `ok:validator-surface:content-verified` |

## Claim (1) — the install reset contract. Asserted, not assumed.

The trap: I measured **after** the provision that follows the reset, so "the file
is still there" is ambiguous between *never destroyed* and *destroyed and
re-created* — opposite verdicts from identical evidence. Resolved by mtime
against `00-run-start.txt`:

| file | verdict |
|---|---|
| `rootfs.img`, `rootfs.qcow2`, `console.log`, `cidata.iso`, `heartbeat.state`, `provision/` | written during this run — **destroyed and re-created** |
| `nvram.bin` | pre-dates the run — **preserved, as announced** |

`nvram.bin` is the **built-in control**: if the mtime method were broken and
everything read as new, it would read as new too. It does not. Corroborated by
102 `Downloading Fedora Cloud image` lines (a genuine re-fetch), by the
pre-existing `test-signal-*.lock` files being gone from the cache dir, and by
`fallback_vault-shamir-share-v1`, `fallback_vault-root-token-v1` and
`vault-data` all being gone. Both vault keychain items were cleared.

**The announcement fired before any destruction**, naming both lists and the
single opt-out (`03-announcement.txt`).

## Findings

### F1 (mine, cosmetic-but-operator-facing) — the announcement contradicts itself
The destroyed list names the image_root **twice**, same path, two different
parentheticals, so it reads as two separate things. Worse, it names the
**directory** as destroyed when only specific files inside it go — and then
lists `nvram.bin`, which lives inside that directory, as preserved. Behaviour is
correct; the text is self-contradictory to anyone reading it. Mine to fix.

### F2 (mine) — `installation-uuid-v1` announced as preserved while absent
Measured before the run: the anchor was **absent** (rc=44), while both
credentials the reset clears were **present** — the invariant inverted. The
announcement still printed "WILL BE PRESERVED: keychain: installation-uuid-v1".
Preserving nothing is a no-op, but an operator reads that line as confirmation
the anchor exists and their vault stays derivable. It does not and it is not.
The announcement states intent; it should state observation, or say "if present".

### F3 (host/product) — two installed copies, different versions
`/Applications/Tillandsias.app` = 56.9.20.1 (new). `~/Applications/Tillandsias.app`
= **56.9.11.1**, ten days old. The installer writes `/Applications` and never
looks at `~/Applications`, so the stale copy is never upgraded, removed, or
mentioned. Two apps of one bundle id. LaunchServices resolved to `/Applications`
on THIS host (evidence and its caveat in `13-launchservices.txt`) — not claimed
in general. It interacts with 1286-4437: `--reset-state` hardcodes its
reprovision path to `/Applications/...`, so an operator installed under
`~/Applications` gets `REFUSING to destroy anything` — right about the path it
was told to check, wrong about the host.

### F4 (test defect, found and fixed during the run) — an overloaded exit code
`cli_unknown_flags::supported_flag_is_not_swallowed_by_the_unknown_flag_guard`
asserted `--diagnose` does not exit 2. Exit 2 is **overloaded**: it is the
unknown-flag refusal AND `--diagnose`'s "not provisioned" verdict. Measured
mid-run: `DIAG_EXIT=2`, zero occurrences of `unknown flag`, last line
`Status: NOT PROVISIONED`. The test went red having found nothing wrong with the
guard it names. Latent until 1286-4437 made reset-then-provision the default
install path, which puts every macOS host in that state for the length of a
provision. Now asserts the absence of the refusal string; mutation-checked.

### F5 (minor) — `e2e-step2-macos.sh` prints no usage
Missing `<LOG_DIR>` yields `line 24: $1: unbound variable`. It fails before
touching anything, so it is safe — just unhelpful. Usage exists in a comment.

## What this lane exercised / could not reach / did not look at

**Exercised:** claims (1), (2), (3) above; the announce-before-destroy contract;
the reset's actual effect on VM state, caches, host credentials and the keychain;
a pristine provision from nothing.

**Could not reach (not applicable to this lane):** the front door, the operator
skills, the mirror-server half, the Linux/Windows arms of `--reset-state`.

**Did not look at:** the guest's internal state after provisioning (no boot
verification beyond the provision's own status); Vault re-initialisation and the
keychain↔volume resync, which needs a boot; the forge lane.

**Stated limit of the diagnostic used:** `--diagnose` in this cut has **no**
`image_root_source` field (1315-d4qd is not in this tag), so every
`rootfs_present` reading here is unlabelled as to which root produced it. With
HOME unset it would have reported on `/tmp` with nothing saying so. HOME was set
throughout this run.

## Side effect to record

The LaunchServices probe launched the tray (pid 71034 from `/Applications`) and
timed out on the AppleEvent. Unintended; the running tray is nonetheless the
normal post-install state, since the installer itself ends with `open -a`.

## Instrument corrections made during this run — the correct forms, for the next reader

Both of my first attempts produced confident wrong answers. Neither was caught
by the probe failing; both were caught by the result looking odd.

### A keychain query on the wrong field manufactures a uniform clean negative

```bash
# WRONG — matches nothing, reports every credential as absent
security find-generic-password -s installation-uuid-v1

# RIGHT — the target is the ACCOUNT, under the service `tillandsias`
security find-generic-password -a installation-uuid-v1 -s tillandsias
```

`installation_uuid.rs` stores the target as `-a <target> -s KEYCHAIN_SERVICE`
where `KEYCHAIN_SERVICE = "tillandsias"`. The wrong form returned "absent" for
all three credentials, which reads as a clean, consistent result — and it is
exactly what would have hidden F2, because F2 is the difference between two of
them being present and the third absent. **Never `-w`**: it prints the secret,
and two live tokens reached transcripts that way on 2026-08-25. The corrected
probe discriminates (two present, one absent with an explicit rc=44), and a
metadata scan finding 6 entries is its positive control.

### A trailing space means prefix, not whole line

```bash
# WRONG — demands the version line be EXACTLY this and nothing more
... | grep -qxF "tillandsias-tray 56.9.20.1 "

# RIGHT — it is a prefix; the line legitimately continues with git sha and build time
case "$L" in "tillandsias-tray 56.9.20.1 "*) ... esac
```

The expected string ends in a space, which is the tell that it is a prefix. The
binary was right and the assertion was wrong; a failing assertion about a
correct binary is as costly as the reverse, because it sends the next reader
looking for a defect that is not there.

## Note on consent ordering

The authorisation in `00-authorisation.md` was written **before §1**, because
since 1286-4437 the installer calls `--reset-state` itself and §1 is therefore
the destructive step on this lane. The runbook still places its authorisation
text at §2, which is after the fact. Recorded here; yolanda is filing the
runbook fix, and the same reordering applies to all three lanes.
