# macOS (Apple Silicon, darwin) curl-install e2e — v0.4.260826.1

## Run 2026-08-26T02:55Z→03:00Z — **PASS** (tag v0.4.260826.1, commit 341ab0010)

RESULT: PASS — release 0.4.260826.1 installed, destroyed, re-provisioned and verified end to end on macos.

- **Host**: tlatoanis-macbook-air, macOS 26.6.2, arm64 (Apple M5), branch `osx-next`
- **Agent**: `macos-tlatoanis-macbook-air-opus5-20260826t025916z`
- **Run**: 2026-08-26T02:59:16Z
- **Skill**: `/smoke-curl-install-and-test-e2e`, channel `daily`
- **Artifact**: `tillandsias-tray-0.4.260826.1-macos-arm64.tar.gz`, sha256 `0701fe67d14c89776a4c53c8eef80b8340f68def813881614ae968997b0121a7`

## PASS — clean end to end

**Steps 0-3 all green; step 4 (`--opencode` forge) is Linux/Podman-only and does not apply to this lane.**

```
step 0  resolve            PASS   tag:v0.4.260826.1, SMOKE_BASE parsed correctly
step 1  install exit 0     PASS
        bundle /Applications PASS
        no ~/Applications fallback PASS
        --version exit 0   PASS
        EXACT tag match    PASS   tillandsias-tray 0.4.260826.1 (git 341ab0010, built 2026-08-26T02:43:10Z)
step 2  tray stopped       PASS
        substrate destroyed PASS  (both dirs EXISTED before -- a real clean room, not a no-op)
        no residue         PASS
step 3  provision exit 0   PASS
        image exists       PASS
        image FRESH        PASS   img 19:58:00Z > marker 19:56:57Z
        diagnose exit 0    PASS
        provisioned==true  PASS
        rootfs_present     PASS
        diagnose.version==tag PASS
```

**THIS IS THE FIRST RELEASE THE macOS LANE COULD CONFIRM THE IDENTITY OF, EVEN IN PRINCIPLE.** Before 635-bhkb closed earlier tonight, every macOS build answered `tillandsias-tray 0.1.0` regardless of release, so an exact-tag assertion was not expressible and 624-q4jj step 5's `--version >=` could not bind. The version line above — carrying both the tag and the release commit `341ab0010` — is the thing this project has never previously been able to check on this platform. **It also bounds what every previous macOS "pass" was worth: none of them verified which artifact they tested.**

Two runbook defects that would have invalidated this run were found and fixed BEFORE it, during meta-orchestration, not during the smoke: the `|| true` swallowing a failed install and a failed `--version`, and the GNU-only `\S` in the `SMOKE_BASE` parse that would have fed every curl a malformed URL — which the `|| true` would then have hidden. Both were in the executed path.

---

### Work Packet: smoke-finding/runbook-pipestatus-is-bash-only

- id: `smoke-finding/runbook-pipestatus-is-bash-only`
- owner_host: any
- capability_tags: [testing, release, portability, macos]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260826.1`
- evidence:
  - Measured on this host: `false | tee /dev/null; echo ${PIPESTATUS[0]}` prints **empty** under zsh 5.9 and `1` under bash.
  - The runbook uses `${PIPESTATUS[0]}` in every lane (steps 1, 2, 3) as the sole capture of an install/reset/provision exit status.
- repro:
  - `zsh -c 'false | tee /dev/null >/dev/null; echo "[${PIPESTATUS[0]}]"'` -> `[]`
- detail: >
    zsh names the array `pipestatus` and indexes it from 1; `PIPESTATUS[0]` is
    unset. **macOS has defaulted to zsh since Catalina**, so an agent or operator
    running these blocks in the platform's default shell gets an EMPTY exit
    status feeding `test "$INSTALL_RC" -eq 0`. That errors rather than passing
    silently, so it is loud — but it means the assertions 727-kmks added, and
    the ones added to the macOS lane tonight, do not do what they say in the
    shell this lane most likely runs in. This run was executed under explicit
    `bash -c` for exactly this reason.
    Same family as the `TIMEFORMAT`/`TIMEFMT` and PE32+/ELF splits recorded
    on 890-nkdz: the runbook names a construct without naming the interpreter.
- next_action: >
    State the required shell at the top of the runbook, or make the blocks
    shell-agnostic (`set -o pipefail` plus a direct exit check, or run the
    command without a pipe and `tee` the saved output afterwards). A litmus leg
    should execute one block under zsh and assert the captured status is a
    non-empty integer.
- events:
  - type: discovered
    ts: `2026-08-26T02:59:16Z`
    agent_id: `macos-tlatoanis-macbook-air-opus5-20260826t025916z`
    host: macos

---

### Work Packet: smoke-finding/macos-installer-autolaunches-before-destruction

- id: `smoke-finding/macos-installer-autolaunches-before-destruction`
- owner_host: macos
- capability_tags: [macos, release, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260826.1`
- evidence:
  - `target/smoke-e2e/01-install-macos.log`: `Launching Tillandsias (--init / VM provisioning runs automatically on first launch)...` / `Tray started.` / `(Provisioning runs in the background on first launch — no extra step needed.)`
  - Immediately after step 1 a live tray was observed (`pgrep` -> PID 59321) actively writing the VM directory (`cidata.iso`, `console.log` timestamped during the run).
- repro:
  - Run step 1 of this runbook on macOS and `pgrep -f 'Tillandsias.app/Contents/MacOS/tillandsias-tray'` immediately afterwards.
- detail: >
    Step 1 installs and the installer then LAUNCHES THE TRAY, which begins
    provisioning in the background. Step 2 then destroys the VM directory. So
    the runbook's own ordering has a destruction racing a live writer, and the
    runbook never mentions that the install auto-launches.
    Step 2's `pkill` handles it, but does NOT WAIT for the process to exit —
    `pkill` returns as soon as the signal is sent, so `rm -rf` can begin while
    the tray is still flushing. This run added a bounded wait loop (30s, then
    SIGKILL) and verified the process was gone before destroying; the runbook
    as written has no such wait.
    Not a release defect — the auto-launch is intended product behaviour. It is
    a runbook-ordering defect that only appears on a lane that had never run.
- next_action: >
    Either add the wait-for-exit loop to step 2's macOS block, or move the
    destruction before the install so the installer's auto-launch provisions
    the clean room directly. The second is simpler and removes the race
    entirely; it changes what step 1's assertions mean, so it needs thought
    rather than a mechanical swap.
- events:
  - type: discovered
    ts: `2026-08-26T02:59:16Z`
    agent_id: `macos-tlatoanis-macbook-air-opus5-20260826t025916z`
    host: macos

---

### Work Packet: smoke-finding/install-macos-logs-wrong-channel

- id: `smoke-finding/install-macos-logs-wrong-channel`
- owner_host: any
- capability_tags: [release, install, diagnostics]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260826.1`
- evidence:
  - `target/smoke-e2e/01-install-macos.log` opens with `channel: stable` and `resolving latest release`, then downloads `.../v0.4.260826.1/tillandsias-tray-0.4.260826.1-macos-arm64.tar.gz` — a **prerelease**, pinned via `TILLANDSIAS_RELEASE_BASE`.
- repro:
  - `curl -fsSL "$BASE/install-macos.sh" | TILLANDSIAS_RELEASE_BASE="$BASE" bash` with $BASE pinned to a prerelease tag.
- detail: >
    The installer honours the pin correctly — the right artifact was fetched and
    its sha256 verified. Only the log line is wrong: it reports the DEFAULT
    channel rather than the one in effect. Cosmetic in isolation, and not
    cosmetic in an evidence file: this log is what a smoke report cites to prove
    which channel was exercised, and it currently states the opposite of the
    truth. A reader auditing this run's evidence would conclude it tested stable.
- next_action: >
    Print the effective channel after applying `TILLANDSIAS_RELEASE_BASE`, or
    print the resolved base URL instead of a channel name.
- events:
  - type: discovered
    ts: `2026-08-26T02:59:16Z`
    agent_id: `macos-tlatoanis-macbook-air-opus5-20260826t025916z`
    host: macos

---

## Observations (not defects)

- `guest_binary_staged_matches_bundle: true` — the staged guest binary matches the bundle in a fresh install.
- `vm_owner_live: false` at diagnose time, consistent with the tray having been stopped in step 2 and `--provision` not leaving a VM running.
- `release_tag: fedora-44` is the **guest image** tag, not the release version. Recorded because it is an inviting wrong assertion — comparing it to `$SMOKE_TAG` fails on a healthy release.
- The Linux musl release job took ~36 minutes against ~15 for the previous release (macuahuitl's measurement, cited not reproduced). Plausibly a Nix cache miss across 2312 commits; not investigated here.

---

## Appendix — raw outputs

`target/smoke-e2e/` is not committed, so the evidence the packets cite is reproduced here verbatim. Without this the citations would point at files that do not survive the cycle — the same shape as a report whose proof lives only in a transcript.

**Pre-run state (proves the destruction was a real clean room, not a no-op):**
```
host: Tlatoanis-MacBook-Air  macOS 26.6.2  arm64
VERSION (confound-remover, not a dependency): 0.4.260826.1
TILLANDSIAS_DESTRUCTIVE_RESET_OK=[unset]
substrate to be destroyed: 12G  ~/Library/Application Support/tillandsias
DIR-EXISTED-BEFORE: appsupport=yes caches=yes
installed app BEFORE: tillandsias-tray 0.1.0 (git 0548ee1f2, built 2026-08-15T06:05:26Z)
stale ~/Applications: absent (preserved as .pre-e2e-20260825)
live tray: none          disk: 806Gi free
```
The `0.1.0` on the pre-run line is the defect 635-bhkb fixed, visible one last time.

**Step 0 resolve:**
```
channel:daily tag:v0.4.260826.1 base:https://github.com/8007342/tillandsias/releases/download/v0.4.260826.1
SMOKE_TAG=[v0.4.260826.1]
SMOKE_BASE=[https://github.com/8007342/tillandsias/releases/download/v0.4.260826.1]
sibling heads: main 341ab0010  linux-next f8a7ff0c2  windows-next 4f8845ce9  osx-next 171239dcf
```

**Step 1 install (excerpt):**
```
asset: tillandsias-tray-0.4.260826.1-macos-arm64.tar.gz
sha256: ok (0701fe67d14c89776a4c53c8eef80b8340f68def813881614ae968997b0121a7)
backing up existing app to Tillandsias.app.bak
extracting to /Applications/Tillandsias.app
installed: version=0.4.260826.1 pin=55c60a3b80d3
Launching Tillandsias (--init / VM provisioning runs automatically on first launch)...
install_exit=0
```

**Step 1 version — the line this lane has never before been able to check:**
```
tillandsias-tray 0.4.260826.1 (git 341ab0010, built 2026-08-26T02:43:10Z)
```

**Step 2 destruction:**
```
tray stopped (after bounded wait; PID 59321 had been auto-launched by the installer)
[macos-residue]          <- empty
```

**Step 3 provision (excerpt) and freshness proof:**
```
{"phase":"Downloading Fedora Cloud image 528/528 MB (100%)"}
{"phase":"Converting Fedora Cloud image"}
Image resized.
{"phase":"Fedora Cloud image ready"}
{"status":"provisioned","path":"/Users/tlatoani/Library/Application Support/tillandsias/rootfs.img"}
provision_exit=0
img mtime:    19:58:00Z
marker mtime: 19:56:57Z     <- image is NEWER than the post-destruction marker
```

**Step 3 diagnose (taken last, after every mutating step):**
```json
{
  "version": "0.4.260826.1",
  "release_tag": "fedora-44",
  "provisioned": true,
  "rootfs_present": true,
  "rootfs_bytes": 268435456000,
  "vm_owner_live": false,
  "guest_binary_staged_matches_bundle": true
}
```

**What this run does NOT establish**, stated so nobody reads more into a PASS than it carries:
- Step 4 (`--opencode` forge lane) is Linux/Podman-only and was not exercised. No claim is made about the forge on macOS.
- The VM was provisioned but never BOOTED. `--provision` writes the image; it does not start the guest. So guest-side behaviour, the control wire, vault init and the guest/tray version skew check are all untested here — `guest_version` is `null` for exactly that reason.
- Gatekeeper/notarisation was not exercised beyond the absence of a quarantine xattr on a curl-downloaded tarball.
- codesign verification of the installed bundle was not performed by this runbook.
