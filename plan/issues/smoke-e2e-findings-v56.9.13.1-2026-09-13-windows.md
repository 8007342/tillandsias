# /smoke-curl-install-and-test-e2e — v56.9.13.1 — 2026-09-13 — windows (esmeraldinha)

**PASS with one divergence recorded.** Release `v56.9.13.1`, channel `daily`,
Windows row. Curl-install clean, destructive reset clean, fresh provision clean,
wire Ready with `podman_ready: true`. One observation diverges from the
2026-08-16 record and is written up below rather than filed as a defect.

Authorization: the operator granted a standing approval for destructive runs
requested by macuahuitl-fedora, with the blast radius restated and corrected
before they confirmed. macuahuitl requested this run against this tag. The
no-pause clause was followed at the reset step per that ruling; every
workstation courtesy was kept.

## Blast radius (stated before the run, as the standing approval requires)

- **DESTROYED**: the `tillandsias` enclave guest — `wsl --terminate` then
  `--unregister`, taking its Vault sealed store, project mirrors, images and
  the in-guest model cache with the `ext4.vhdx`; plus `vault-shamir-share-v1`
  and `vault-root-token-v1` cleared from Windows Credential Manager.
- **PRESERVED**: `tillandsias-vm-uuid` — it anchors the INSTALLATION, not the
  guest, and the in-VM Vault derives its master key from it.
- **UNTOUCHED**: `tillandsias-build` — the gate lane, cargo cache, models and
  `ollama serve`. Verified Running immediately after the reset. `--terminate`
  was used rather than `wsl --shutdown` precisely to hold that boundary
  (802-bajv).
- Unpushed work was salvaged to a git bundle outside the checkout before the
  reset; nothing was lost.

## Ledger claims (order 380)

Row read from `README.md` at §0.2b — and the first read said **NO LEDGER ROW**,
which was a false finding from a stale checkout: trunk carried the row, this
tree did not. Merging trunk produced it. A report filed on the first read would
have accused the release of shipping undescribed.

**EXERCISED**

- *the capability-row guard no longer fails open on age and names a remedy that
  cannot run where the verdict fires (1154-8ywc, 1165-xkjh)* — checked on this
  host before the run: the Windows side answers
  `stale:capability-row-expired:esmeraldinha:age=1866506s` rc=1 where it
  previously answered `ok:capability-row-reported` rc=0, and the stderr
  constraint line is present there and absent on a locus whose probe runs. The
  row's framing is confirmed: this is the fix working, not a regression.
- *the envelope names whether it was measured or served (1139-xe5m)* —
  `scripts/test-capabilities-envelope-names-its-source.sh` passes 6/6 standalone
  on this tree.
- *ten fixtures restored to mode 755 after landing 644 from Windows* — this
  lane's own new scripts were committed at `100755` via
  `git update-index --chmod=+x`, so the class did not recur here.

**NOT APPLICABLE**

- Linux clean-room credential-cold claim (900-z3kv), the land tool's auth-blip
  retry (1164-cftu), the meta-orchestration loop items (1119-6wn6, 1144-jfr5,
  1141-vf9w, 1150-q462, 829-dkuc), Silverblue akmods (1165-g6wx), and the macOS
  items (1135-z8gn, 1137-rgfm) — other platforms or other lanes.
- *1171-ccf2 — the Windows zip does not yet carry `tillandsias-headless.exe`* —
  named in the row as KNOWN AND UNFIXED in this cut. The probe's loud refusal on
  this host is therefore expected and is not what this run measures.
- *1159-g96c — `due:no-capability-row` from a third context* — named in the row
  as known and unfixed; reproduced here from the builder distro, as predicted.

**NOT CHECKED**

- *the Windows probe refuses a runnable-but-stale binary by vocabulary, never
  mtime (1172-dyvd)* — this lane did not exercise it, and could have. Worth
  noting that this run independently hit the same trap from the other side: a
  binary was judged stale by mtime and was current by content.
- *yolanda's wrong row republished with the Radeon 860M and the NPU (1172-dyvd)*
  — another host's row; not visible from here.
- *the compaction and LWW-channel fixes (1156-eif4, 1157-ghmi, 1158-y3ad)*,
  *the dead-env detector's blind spots (1166-99mk…1169-zw44)*, *the salvage net
  gaps (1146-8j7i, 1148-3439)*, *the credential-helper host pin (1161-42pc,
  1118-bscs)*, *env-var test races (1146-z8ux)* — none exercised by this lane.
- *the reaper's SIGPIPE-under-pipefail flake (1076-kft9 class)* — not exercised
  here, though this host measured that class separately.
- **Steps 3b, 4, 4a–4c** (substrate stop with clean container exits, forge
  continuous-enhancement run, egress assertion, final health check) — NOT RUN.
  This report covers §0–§3 only.

## Steps

1. **Pre-flight** — host esmeraldinha, branch `windows-next`, channel `daily`,
   tag `v56.9.13.1`. All five Windows assets confirmed present on the release
   before anything was destroyed: the tray zip, `tillandsias-windows-x64.zip`,
   `tillandsias-tray.exe`, `install-windows.ps1`, `SHA256SUMS-windows`.
2. **Curl-install** (`01-install-windows.log`, `01-install-exit.txt`) —
   `install_exit=0`. SHA-256 verified
   (`9ae819c5469d9d8a9f5d883d5a030a9fe806d05910f8924cdaa0cc015a4add4e`), backup
   of the prior install taken, Start Menu shortcut written, registered in
   Installed Software. Tray resolves at
   `%LOCALAPPDATA%\Programs\Tillandsias\tillandsias-tray.exe` — NOT on PATH, as
   the runbook's 1004-vsh2 note warns. `--version` reports
   `tillandsias-tray 56.9.13.1 (6b8342f3f)`, exact match to the pinned tag.
3. **Destructive reset** — tray killed, `wsl --terminate tillandsias` exit 0,
   `wsl --unregister tillandsias` exit 0. `tillandsias-build` verified Running
   afterwards. Both guest vault credentials cleared and verified absent with the
   echo-counting predicate (the localized-text predicate is wrong per
   1004-vsh2); `tillandsias-vm-uuid` verified still present. The host credential
   store was genuinely cold — the step the 2026-08-17 run got wrong.
4. **Fresh provision** (`03-provision.log`, `03-provision-exit.txt`) —
   `provision_exit=0` in **99 s** cold, ending `RESULT: VM Ready — control wire
   up ✓`. Comparable to the 117 s recorded for v56.9.2.1 on this host. Distro
   re-registered; the rootfs `ext4.vhdx` postdates the destruction marker, so
   this is a genuinely fresh provision and not a survivor.
5. **Wire** — after a warm `--provision-once` (**17 s**, against 18 s recorded
   for v56.9.2.1), `--status-once --json` returns `reachable: true`,
   `wire_version: 3`, `phase: Ready`, `podman_ready: true`,
   `last_event: tillandsias-in-vm`.
6. **Cold Vault bootstrap observed** — the cleared credential store forced a
   genuine cold bootstrap inside the guest: `[tillandsias-vault] bootstrap
   complete` with all twelve policies enumerated. This is the clean-room
   property working as designed.

## Divergence from the 2026-08-16 record — recorded, not filed

The 2026-08-16 Windows report already documents the post-provision
idle-shutdown: a status probe about a minute after `--provision-once` exits
returns `reachable:false … WSA_ERROR(10060)` because WSL idle-stops the distro
once nothing holds it open, and that entry states plainly **"Expected
lifecycle, not a defect; recorded so the next agent doesn't misread a 10060
immediately after a one-shot provision as a wedge."** That record did its job:
this run reproduced the symptom and the de-duplication grep found the prior
entry before a duplicate packet was filed.

One detail differs and is worth the next reader's attention. The 2026-08-16
entry says *"Restarting the distro brought the wire back with zero
intervention."* On this run it did not. Waking the guest with
`wsl -d tillandsias -- true` (exit 0) left it Running with
`tillandsias-headless.service` **active**, `tillandsias-headless-ready.service`
active, `vsock_loopback` loaded and Vault bootstrapped — and the wire stayed
unreachable across **seven polls over four minutes**, every one
`WSA_ERROR(10060)`. Only a warm `--provision-once` restored it, in 17 s, after
which the wire was immediately Ready.

Two readings, and this run cannot separate them: either the behaviour changed
between `v0.4.260815.1` and `v56.9.13.1`, or "restarting the distro" in the
2026-08-16 entry meant something other than a bare `wsl -- true` — a tray-driven
restart, for instance, which would re-establish the wire the way a provision
does. The entry does not say which, and I am not going to infer it.

`--diagnose --json` (run LAST, as the runbook requires) exits 2 and reports
`distro_registered: True`, `distro_running: False`,
`ready_history: observed-ready`, and the same unreachable wire — i.e. the guest
had idled out again between a successful status poll and the diagnose call,
within about a minute. So on this host the window in which one-shot CLI calls
see a live wire is roughly the WSL idle timeout, and nothing in the §3 sequence
holds it open. `.wslconfig` here sets `memory=8GB`, `processors=4` and
`autoMemoryReclaim=gradual`, with no explicit `vmIdleTimeout`.

**Why this is recorded rather than filed**: the symptom is documented as
expected lifecycle, and the only new fact is that one stated remedy did not
work on this run. That is a divergence in a recorded expectation, not a defect
in the release, and the honest disposition is to write it where the next
Windows smoke will read it.

## Runbook finding — §3's PowerShell block aborts on a benign stderr line

Not a release defect; a defect in this runbook's Windows block, filed here
because the next Windows run will hit it.

§3's block opens with `$ErrorActionPreference = 'Stop'` and pipes the tray
through `*>&1`. Under Windows PowerShell 5.1 a native command's stderr is
wrapped in an `ErrorRecord` (`NativeCommandError`), so **any** stderr line
becomes a terminating error. The tray emits `Failed to set locale, defaulting
to "C.UTF-8"` on this host, which is benign — and it aborted
`--provision-once` **mid-provision**, leaving a half-provisioned guest that had
to be unregistered and redone.

The failure is doubly misleading: the abort is attributed to the tray, and the
partial guest then satisfies the destruction-marker assertion (its rootfs
postdates the marker), so a re-run would look like a fresh provision while
being a resumed one.

Repro: `$ErrorActionPreference='Stop'; & $tray --provision-once *>&1 | Tee-Object log`
on a host where the tray writes any stderr line.

Next action: drop `*>&1` in favour of `Start-Process -Wait -PassThru` with
`-RedirectStandardOutput`/`-RedirectStandardError`, which is what this run used
after the abort. It reports a real `ExitCode` and does not conflate stderr with
failure. This lane additionally ran a channel canary first —
`cmd /c exit 7` must report 7 — because `$LASTEXITCODE` was observed EMPTY for a
native call in this harness, which would have made every exit-code assertion in
the block vacuous.

## Metrics

- install: exit 0
- reset: terminate 0, unregister 0, credentials cold, `tillandsias-build` Running
- provision cold: exit 0, 99 s
- provision warm: exit 0, 17 s
- status: `reachable: true`, `wire_version: 3`, `phase: Ready`, `podman_ready: true`
- diagnose: exit 2 (guest idled between calls; see divergence above)
- steps covered: §0, §1, §2, §3. Steps 3b and 4–4c NOT RUN.
