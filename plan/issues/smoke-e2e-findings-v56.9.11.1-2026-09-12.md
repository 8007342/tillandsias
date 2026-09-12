# Smoke E2E — release `v56.9.11.1`, macOS lane, 2026-09-12

PASS — `v56.9.11.1` on darwin 25.6.0, Apple Silicon (host `tlatoanis-macbook-air`,
bare-metal macOS workstation, branch `osx-next` at `cffa03101`): curl-install
clean, substrate destroyed with zero residue, `--provision` from pristine clean,
`--diagnose --json` green. No findings.

This is the first curl-install smoke of the published macOS artifacts since
2026-09-06. The `v56.9.11.1` ledger row itself records "no macOS/Windows host
smoke, both hosts down since 2026-09-06", so this run closes exactly the gap
that row names — for macOS only. Windows remains unsmoked and that release has
no Windows tray at all (1122-xi2f).

## Regime

- host_id `tlatoanis-macbook-air`, macos, bare-metal, kernel 25.6.0, Apple Silicon
- installed from the published release, NOT a local `target/` build
- artifacts exercised: `install-macos.sh`, `tillandsias-tray-56.9.11.1-macos-arm64.tar.gz`
- `Tillandsias.dmg` is PUBLISHED and was verified present on the release, but
  this lane installs via `install-macos.sh`, which takes the tarball. The DMG
  was NOT opened, mounted, or installed from. See NOT CHECKED below — the
  assignment named the DMG, and "published" is not "tested".

## Destructive-step authorization

This host is an operator workstation, not a dedicated smoke host. The substrate
destroyed by §2 held 13 GB of VM state (`rootfs.img`, a live guest, nvram) plus
a 1.6 GB model cache. Per the skill's own rule, the coordinator's instruction to
run the procedure was NOT treated as consent to destroy this machine; the
operator was asked directly and authorized the destruction for this run before
§2 executed.

## Steps

| Step | Result | Evidence |
|---|---|---|
| §0 ledger row | FOUND (exact row, not a distilled span) | `README.md:114` |
| §1 curl-install | PASS `install_exit=0` | `target/smoke-e2e/01-install-macos.log` |
| §1 sha256 | PASS `25f2ef9ec14a1639c3d55cb7673030c32aefe75062a488e2f1f99e543540724c` | same |
| §1 install path | PASS `/Applications`, no `~/Applications` fallback | same |
| §1 exact tag | PASS `tillandsias-tray 56.9.11.1 (git f1f7c01bc, built 2026-09-11T22:16:43Z)` | `01-version.txt` |
| §2 destruction | PASS, zero residue | `02-macos-residue.txt` |
| §3 provision | PASS `provision_exit=0` | `03-provision.log` |
| §3 freshness | PASS `rootfs.img` postdates the destruction marker — fresh, not a survivor | `03-destruction-marker` |
| §3 diagnose | PASS `diagnose_exit=0`; `provisioned==true`, `rootfs_present==true`, `version=="56.9.11.1"` | `03-diagnose.json` |
| §4 forge lane | NOT APPLICABLE — the `--opencode` forge lane is Linux/Podman | — |

The install re-downloaded and re-converted the 528 MB Fedora Cloud image from
nothing, so this was a genuinely cold provision. `guest_binary_staged_matches_bundle`
is `true`: the staged guest binary matches the bundle.

## Ledger claims

The `v56.9.11.1` row's claims, each under exactly one heading.

### EXERCISED

- **`635-bhkb` version truthfulness** (implicit in every row since): the tray
  reports `56.9.11.1`, not the frozen `0.1.0`, on BOTH surfaces — `--version`
  and the `.version` field of `--diagnose --json`. This is what makes every
  other assertion in this report attributable to a specific artifact.
- **`1109-t8kw` committable-branch fixture sets its own git identity**:
  `scripts/check-committable-branch.sh` ran green (`ok:branch-osx-next`) on this
  release's tree during the landing cycle that preceded this smoke.
- **`1116-vps5` `+x` restored on `finalize-cycle.sh`**: verified present in this
  tree — `-rwxr-xr-x scripts/finalize-cycle.sh`.
- **macOS install path and artifact integrity**: SHA256 verified by the
  installer against `SHA256SUMS-macos`; extraction to `/Applications` confirmed
  by assertion rather than assumption.

### NOT APPLICABLE

- **`1122-xi2f` Windows release placeholder / Windows job FAILED** — Windows lane.
- **forge `/home/forge/src` tmpfs mode 0777** (440cde994) — Linux forge container.
- **`1120-s3e5` three fixtures red in-gate only** — Linux gate lane.
- **`1119-w2rj` cloud-mode Observatorium leaf / `is_cloud` inference** — cloud lane.
- **`776-jcf3` host-checkout elimination for cloud launches** — cloud launch path;
  this lane performs no cloud launch.

### NOT CHECKED

These this lane could have reached and did not. Naming them is the point.

- **`Tillandsias.dmg`**. Verified present on the release; never mounted or
  installed from. The DMG is a SEPARATE install path from the tarball that
  `install-macos.sh` consumes, and a working tarball is not evidence for it.
  The assignment named the DMG explicitly, so this is the largest gap in the run.
- **`1122-6sqz` the release gate reinstalls the launcher on the host that runs
  it**. The gate log for this cycle carries only an ADVISORY naming the packet
  (`.git/tillandsias-land-gate-attempt-1.log:4096`), not a reproduction. This
  smoke reinstalled `/Applications/Tillandsias.app` by design, so a
  gate-caused launcher overwrite is not separable from the smoke's own install
  on this run. Reproducing it needs a cycle that gates WITHOUT installing.
- **`1074-96z9` memo-hit observability**, **`1105-h8vr` answer-rate fixture cost
  fix**, **`1114-p2ht` capability-manifest fixture isolation**, **`1025-a896`
  OAuth 10-token-cap**, **`1119-6wn6` sub-agent and token budget rules**,
  **`889` fragment ledger compaction**, **ephemeral-guarantee spec**,
  **`1080-4deb` ARM 1 ledger-write reachability gate step**. All are gate- or
  plan-layer claims checkable from this checkout; this lane exercised the
  release BINARY and did not run the gate suite against them.
- **Guest liveness**. `--diagnose` alone reports `guest_version: null` and
  `metrics_status: unsupported:no-live-wire-handle` BY DESIGN — those need
  `--with-metrics`, which boots the VM and is a mutating step, so the runbook
  puts it out of scope for the LAST health check. This run therefore proves the
  guest was PROVISIONED, not that it BOOTS AND REACHES READY. Given that
  `1084-x8ya` is open on exactly "provisioning completes but never reaches
  Ready", that distinction matters and this report does not claim otherwise.

## Observations (not findings)

- `kernel_present: false` / `initrd_present: false` in the diagnose report,
  alongside `rootfs_present: true` and `provisioned: true`. Expected for the
  qcow2 boot path (`release_tag: fedora-44`, `manifest_pin_aarch64_qcow2:
  55c60a3b80d3`); recorded so a future reader does not re-derive it.
- The DESTROYED substrate contained a `crashloop.state` dated 2026-09-11 18:44
  next to a heartbeat at 18:51. It was pre-existing state from before this run
  and was deleted by §2 before being read, so its contents are unrecoverable and
  no claim is made about them. Noted only because `1084-x8ya` concerns a guest
  that provisions but never reaches Ready; if that packet's investigation wants
  macOS crashloop evidence, this host no longer has any and a future run should
  read that file BEFORE §2.
